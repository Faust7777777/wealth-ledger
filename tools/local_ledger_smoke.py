"""End-to-end smoke test for the real-local JSON ledger seam.

The test uses a temporary ledger file, starts the Rust server with
`--ledger-path`, performs product-critical writes through the HTTP API, and
then verifies the derived read models. It never touches the user's real ledger
and never contacts external services.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
RUST_MANIFEST = ROOT / "server-rs" / "Cargo.toml"


def request_json(
    base: str,
    path: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    expected_status: int = 200,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            status = response.status
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        status = exc.code
        payload = exc.read().decode("utf-8")

    if status != expected_status:
        raise AssertionError(f"{method} {path}: expected {expected_status}, got {status}: {payload}")
    if not payload:
        return {}
    return json.loads(payload)


def unwrap_data(payload: dict[str, Any]) -> Any:
    assert payload["ok"] is True, payload
    return payload["data"]


def cargo_path() -> str:
    cargo = shutil.which("cargo")
    if cargo:
        return cargo
    fallback = Path.home() / ".cargo" / "bin" / "cargo.exe"
    if fallback.exists():
        return str(fallback)
    raise RuntimeError("cargo was not found on PATH")


def rust_env(port: int) -> dict[str, str]:
    env = os.environ.copy()
    extra_paths = [
        Path.home() / ".cargo" / "bin",
        Path.home() / "scoop" / "apps" / "mingw" / "current" / "bin",
    ]
    env["PATH"] = os.pathsep.join([*(str(p) for p in extra_paths), env.get("PATH", "")])
    env["FINWEALTH_RS_ADDR"] = f"127.0.0.1:{port}"
    return env


@contextmanager
def rust_server(port: int, ledger_path: Path) -> Iterator[str]:
    process = subprocess.Popen(
        [
            cargo_path(),
            "run",
            "--quiet",
            "--manifest-path",
            str(RUST_MANIFEST),
            "--",
            "--port",
            str(port),
            "--ledger-path",
            str(ledger_path),
        ],
        cwd=ROOT,
        env=rust_env(port),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    base = f"http://127.0.0.1:{port}"
    try:
        wait_until_ready(base, process)
        yield base
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def wait_until_ready(base: str, process: subprocess.Popen[str]) -> None:
    last_error: Exception | None = None
    for _ in range(60):
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise RuntimeError(f"rust server exited early with {process.returncode}: {output}")
        try:
            health = request_json(base, "/v1/health")
            if health.get("ok") is True:
                return
        except Exception as exc:
            last_error = exc
            time.sleep(0.25)
    raise RuntimeError(f"rust server did not become ready: {last_error}")


def create_account(base: str, name: str, amount: str, *, account_type: str = "bank") -> dict[str, Any]:
    return unwrap_data(
        request_json(
            base,
            "/v1/accounts",
            method="POST",
            expected_status=201,
            body={
                "displayName": name,
                "institutionName": "local-ledger-smoke",
                "accountType": account_type,
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": True,
                "balanceMode": "cash_balance",
                "openingBalances": [
                    {
                        "currency": "CNY",
                        "amount": amount,
                        "quality": "exact",
                    }
                ],
            },
        )
    )


def create_and_confirm_manual_expense(base: str, account_id: str) -> dict[str, Any]:
    draft = unwrap_data(
        request_json(
            base,
            "/v1/movements/drafts",
            method="POST",
            expected_status=201,
            body={
                "type": "expense",
                "occurredAt": "2026-06-27T10:00:00Z",
                "title": "local smoke coffee",
                "entries": [
                    {
                        "accountId": account_id,
                        "amount": "12.34",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source",
                    }
                ],
            },
        )
    )
    movement_id = draft["id"]
    atomic_group_id = draft["atomicGroupId"]

    review = unwrap_data(
        request_json(base, f"/v1/movements/{movement_id}/submit-review", method="POST")
    )
    assert review["id"] == atomic_group_id

    confirmation = unwrap_data(
        request_json(base, f"/v1/atomic-groups/{atomic_group_id}/confirm", method="POST")
    )
    assert confirmation["ledgerWrite"] is True
    assert movement_id in confirmation["confirmedMovementIds"]

    confirmed = unwrap_data(request_json(base, f"/v1/movements/{movement_id}"))
    assert confirmed["status"] == "confirmed"
    return confirmed


def create_dca_and_mark_executed(base: str, account_id: str) -> dict[str, Any]:
    plan = unwrap_data(
        request_json(
            base,
            "/v1/dca/plans",
            method="POST",
            expected_status=201,
            body={
                "displayName": "local smoke DCA",
                "targetInstrumentId": "inst_local_smoke_fund",
                "fundingAccountId": account_id,
                "plannedAmount": {"amount": "100.00", "currency": "CNY"},
                "frequency": "monthly",
                "nextDueDate": "2026-06-27",
                "note": "smoke only; record-only, no order",
            },
        )
    )
    reminders = unwrap_data(request_json(base, "/v1/dca/reminders/due"))
    reminder = next(item for item in reminders if item["planId"] == plan["id"])

    group = unwrap_data(
        request_json(
            base,
            f"/v1/dca/reminders/{reminder['id']}/mark-executed-as-proposal",
            method="POST",
        )
    )
    assert group["status"] == "pending"
    assert group["warnings"][0]["code"] == "record_only_no_order"

    confirmed = unwrap_data(
        request_json(base, f"/v1/atomic-groups/{group['id']}/confirm", method="POST")
    )
    assert confirmed["ledgerWrite"] is True
    assert len(confirmed["confirmedMovementIds"]) == 1

    due_after = unwrap_data(request_json(base, "/v1/dca/reminders/due"))
    assert all(item["id"] != reminder["id"] for item in due_after)
    return plan


def create_and_confirm_ai_csv(base: str, account_id: str) -> dict[str, Any]:
    proposal = unwrap_data(
        request_json(
            base,
            "/v1/ai/proposals/from-csv",
            method="POST",
            body={
                "csv": (
                    "occurredAt,title,amount,currency,direction,type\n"
                    "2026-06-27,CSV smoke income,88.00,CNY,in,income\n"
                ),
                "selectedAccountIds": [account_id],
                "defaultCurrency": "CNY",
            },
        )
    )
    assert proposal["source"]["kind"] == "csv_import"
    group = proposal["atomicGroups"][0]

    confirmation = unwrap_data(
        request_json(base, f"/v1/ai/atomic-groups/{group['id']}/approve", method="POST")
    )
    assert confirmation["ledgerWrite"] is True
    assert len(confirmation["confirmedMovementIds"]) == 1

    pending = unwrap_data(request_json(base, "/v1/ai/proposals/pending"))
    assert proposal["id"] not in {item["id"] for item in pending}
    return proposal


def create_image_proposal_without_writing(base: str) -> None:
    tiny_png = base64.b64encode(
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    ).decode("ascii")
    proposal = unwrap_data(
        request_json(
            base,
            "/v1/ai/proposals/from-image",
            method="POST",
            body={
                "fileName": "local-smoke.png",
                "mimeType": "image/png",
                "imageBase64": tiny_png,
            },
        )
    )
    assert proposal["source"]["kind"] == "user_image"
    assert proposal["status"] == "pending"


def run_smoke(base: str, ledger_path: Path) -> None:
    assert unwrap_data(request_json(base, "/v1/accounts")) == []

    cash = create_account(base, "Smoke Cash", "1000.00")
    reserve = create_account(base, "Smoke Reserve", "250.00", account_type="wallet")
    assert cash["cashBalances"][0]["amount"] == "1000.00"

    updated = unwrap_data(
        request_json(
            base,
            f"/v1/accounts/{reserve['id']}",
            method="PATCH",
            body={"displayName": "Smoke Reserve Updated"},
        )
    )
    assert updated["displayName"] == "Smoke Reserve Updated"

    expense = create_and_confirm_manual_expense(base, cash["id"])
    assert expense["title"] == "local smoke coffee"

    create_dca_and_mark_executed(base, cash["id"])
    create_and_confirm_ai_csv(base, cash["id"])
    create_image_proposal_without_writing(base)

    snapshot = unwrap_data(
        request_json(
            base,
            "/v1/snapshots/manual",
            method="POST",
            body={"reason": "baseline"},
        )
    )
    assert snapshot["netWorth"]["amount"] == "1325.66", snapshot

    overview = unwrap_data(request_json(base, "/v1/portfolio/overview"))
    assert overview["latestSnapshot"]["netWorth"]["amount"] == "1325.66", overview
    assert overview["pendingSummary"]["aiPendingCount"] == 1

    allocation = unwrap_data(request_json(base, "/v1/portfolio/allocation"))
    assert allocation["netWorth"]["amount"] == "1325.66", allocation

    movements = unwrap_data(request_json(base, "/v1/movements"))
    confirmed_ids = {item["id"] for item in movements if item["status"] == "confirmed"}
    assert expense["id"] in confirmed_ids
    assert len(confirmed_ids) >= 3

    forbidden = request_json(
        base,
        "/v1/broker/orders",
        method="POST",
        body={},
        expected_status=403,
    )
    assert forbidden["ok"] is False
    assert forbidden["error"]["code"] == "forbidden_product_boundary"

    persisted = json.loads(ledger_path.read_text(encoding="utf-8"))
    assert len(persisted["accounts"]) == 2
    assert len(persisted["snapshots"]) == 1
    assert any(item["source"]["kind"] == "ai_proposal" for item in persisted["movements"])


def main() -> None:
    parser = argparse.ArgumentParser(description="Run real-local JSON ledger smoke checks.")
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument(
        "--keep-ledger",
        action="store_true",
        help="Keep the temporary ledger file and print its path after the smoke run.",
    )
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="finwealth_local_ledger_smoke_") as tmp:
        ledger_path = Path(tmp) / "ledger.json"
        with rust_server(args.port, ledger_path) as base:
            run_smoke(base, ledger_path)
        if args.keep_ledger:
            kept = ROOT / "tmp" / "local_ledger_smoke.ledger.json"
            kept.parent.mkdir(exist_ok=True)
            shutil.copy2(ledger_path, kept)
            print(f"OK: real-local ledger smoke passed; ledger kept at {kept}")
        else:
            print("OK: real-local ledger smoke passed")


if __name__ == "__main__":
    main()

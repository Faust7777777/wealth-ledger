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
import uuid
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
    idempotency_key: str | None = None,
    expected_headers: dict[str, str | None] | None = None,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if method in {"POST", "PATCH", "PUT", "DELETE"}:
        headers["Idempotency-Key"] = idempotency_key or f"smoke-{uuid.uuid4()}"
    request = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            status = response.status
            response_headers = response.headers
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        status = exc.code
        response_headers = exc.headers
        payload = exc.read().decode("utf-8")

    if status != expected_status:
        raise AssertionError(f"{method} {path}: expected {expected_status}, got {status}: {payload}")
    for name, expected in (expected_headers or {}).items():
        actual = response_headers.get(name)
        if actual != expected:
            raise AssertionError(
                f"{method} {path}: expected header {name}={expected!r}, got {actual!r}"
            )
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


def create_account(
    base: str,
    name: str,
    amount: str,
    *,
    account_type: str = "bank",
    currency: str = "CNY",
    balance_mode: str = "cash_balance",
    idempotency_key: str | None = None,
) -> dict[str, Any]:
    return unwrap_data(
        request_json(
            base,
            "/v1/accounts",
            method="POST",
            expected_status=201,
            idempotency_key=idempotency_key,
            body={
                "displayName": name,
                "institutionName": "local-ledger-smoke",
                "accountType": account_type,
                "defaultCurrency": currency,
                "supportedCurrencies": [currency],
                "includeInNetWorth": True,
                "balanceMode": balance_mode,
                "openingBalances": [
                    {
                        "currency": currency,
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


def create_and_confirm_multileg_correction(
    base: str, source_account_id: str, destination_account_id: str
) -> None:
    original = unwrap_data(
        request_json(
            base,
            "/v1/movements/drafts",
            method="POST",
            expected_status=201,
            body={
                "type": "transfer",
                "occurredAt": "2026-06-27T09:00:00Z",
                "title": "local smoke corrected transfer",
                "entries": [
                    {
                        "accountId": source_account_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source",
                    },
                    {
                        "accountId": destination_account_id,
                        "amount": "40.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination",
                    },
                ],
            },
        )
    )
    unwrap_data(
        request_json(
            base,
            f"/v1/atomic-groups/{original['atomicGroupId']}/confirm",
            method="POST",
        )
    )
    correction = unwrap_data(
        request_json(
            base,
            "/v1/movements/corrections",
            method="POST",
            body={
                "targetMovementId": original["id"],
                "reason": "local smoke actual transfer was 25",
                "replacementEntries": [
                    {
                        "accountId": source_account_id,
                        "amount": "25.00",
                        "currency": "CNY",
                        "direction": "out",
                        "role": "source",
                    },
                    {
                        "accountId": destination_account_id,
                        "amount": "25.00",
                        "currency": "CNY",
                        "direction": "in",
                        "role": "destination",
                    },
                ],
            },
        )
    )
    assert correction["operation"] == "correction"
    assert len(correction["proposedMovements"][0]["entries"]) == 4
    before_confirm_source = unwrap_data(
        request_json(base, f"/v1/accounts/{source_account_id}")
    )
    before_confirm_destination = unwrap_data(
        request_json(base, f"/v1/accounts/{destination_account_id}")
    )
    assert before_confirm_source["cashBalances"][0]["amount"] == "960.00"
    assert before_confirm_destination["cashBalances"][0]["amount"] == "290.00"

    confirmed = unwrap_data(
        request_json(
            base,
            f"/v1/atomic-groups/{correction['id']}/confirm",
            method="POST",
        )
    )
    assert confirmed["ledgerWrite"] is True
    after_source = unwrap_data(request_json(base, f"/v1/accounts/{source_account_id}"))
    after_destination = unwrap_data(
        request_json(base, f"/v1/accounts/{destination_account_id}")
    )
    assert after_source["cashBalances"][0]["amount"] == "975.00"
    assert after_destination["cashBalances"][0]["amount"] == "275.00"
    unchanged_original = unwrap_data(
        request_json(base, f"/v1/movements/{original['id']}")
    )
    assert [entry["amount"] for entry in unchanged_original["entries"]] == [
        "40.00",
        "40.00",
    ]


def create_dca_and_mark_executed(
    base: str, funding_account_id: str, holding_account_id: str
) -> dict[str, Any]:
    plan = unwrap_data(
        request_json(
            base,
            "/v1/dca/plans",
            method="POST",
            expected_status=201,
            body={
                "displayName": "local smoke DCA",
                "targetInstrumentId": "inst_local_smoke_fund",
                "fundingAccountId": funding_account_id,
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
            body={
                "holdingAccountId": holding_account_id,
                "quantity": "4",
                "totalCost": {"amount": "100.00", "currency": "CNY"},
                "quoteCurrency": "CNY",
                "executedAt": "2026-06-27T10:00:00Z",
            },
        )
    )
    assert group["status"] == "pending"
    assert group["warnings"][0]["code"] == "record_only_no_order"
    movement = group["proposedMovements"][0]
    assert movement["entries"][0]["amount"] == "100.00"
    assert movement["entries"][1]["amount"] == "4"

    confirmed = unwrap_data(
        request_json(base, f"/v1/atomic-groups/{group['id']}/confirm", method="POST")
    )
    assert confirmed["ledgerWrite"] is True
    assert len(confirmed["confirmedMovementIds"]) == 1
    holdings = unwrap_data(request_json(base, "/v1/holdings"))
    holding = next(item for item in holdings if item["accountId"] == holding_account_id)
    assert holding["quantity"] == "4"
    assert holding["costBasisTotal"]["amount"] == "100.00"

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


def create_subscription(
    base: str,
    account_id: str,
    *,
    display_name: str,
    provider: str,
    plan_name: str,
    start_date: str,
) -> dict[str, Any]:
    return unwrap_data(
        request_json(
            base,
            "/v1/subscriptions",
            method="POST",
            expected_status=201,
            body={
                "displayName": display_name,
                "provider": provider,
                "planName": plan_name,
                "amount": {"amount": "20.00", "currency": "USD"},
                "paymentAccountId": account_id,
                "billingCycle": {"unit": "month", "interval": 1},
                "startDate": start_date,
                "duration": {"unit": "month", "count": 3},
                "autoRenew": False,
                "reminderDaysBefore": 3,
            },
        )
    )


def create_and_confirm_due_subscription_charge(
    base: str, account_id: str, ledger_path: Path
) -> dict[str, Any]:
    due = create_subscription(
        base,
        account_id,
        display_name="ChatGPT Plus due-scan smoke",
        provider="OpenAI",
        plan_name="Plus",
        start_date="2026-01-31",
    )
    future = create_subscription(
        base,
        account_id,
        display_name="Claude Pro future smoke",
        provider="Anthropic",
        plan_name="Pro",
        start_date="2026-08-31",
    )
    assert due["nextChargeDate"] == "2026-01-31"
    assert future["nextChargeDate"] == "2026-08-31"

    before = unwrap_data(request_json(base, f"/v1/accounts/{account_id}"))
    due_before = unwrap_data(request_json(base, f"/v1/subscriptions/{due['id']}"))
    future_before = unwrap_data(request_json(base, f"/v1/subscriptions/{future['id']}"))
    assert before["cashBalances"][0]["amount"] == "100.00"
    assert due_before.get("lastChargeDate") is None
    assert future_before.get("lastChargeDate") is None

    scan_path = "/v1/subscriptions/charge-proposals/due-scan"
    scan_key = "smoke-subscription-due-scan-replay"
    scan_body = {"throughDate": "2026-07-13", "limit": 1}
    scan = unwrap_data(
        request_json(
            base,
            scan_path,
            method="POST",
            body=scan_body,
            idempotency_key=scan_key,
            expected_headers={"Idempotency-Replayed": None},
        )
    )
    assert scan["throughDate"] == "2026-07-13"
    assert scan["createdCount"] == 1
    assert scan["alreadyPendingCount"] == 0
    assert scan["blockedCount"] == 0
    assert scan["remainingEligibleCount"] == 0
    assert scan["hasMore"] is False
    assert scan["skipped"] == []
    group = scan["created"][0]
    assert group["subscriptionId"] == due["id"]
    assert group["scheduledChargeDate"] == "2026-01-31"
    assert len(group["proposedMovements"]) == 1
    movement_id = group["proposedMovements"][0]["id"]

    replay = unwrap_data(
        request_json(
            base,
            scan_path,
            method="POST",
            body=scan_body,
            idempotency_key=scan_key,
            expected_headers={"Idempotency-Replayed": "true"},
        )
    )
    assert replay == scan

    reused = request_json(
        base,
        scan_path,
        method="POST",
        body={"throughDate": "2026-07-13", "limit": 2},
        idempotency_key=scan_key,
        expected_status=409,
    )
    assert reused["ok"] is False
    assert reused["error"]["code"] == "idempotency_key_reused"

    after_scan = unwrap_data(request_json(base, f"/v1/accounts/{account_id}"))
    due_after_scan = unwrap_data(request_json(base, f"/v1/subscriptions/{due['id']}"))
    future_after_scan = unwrap_data(request_json(base, f"/v1/subscriptions/{future['id']}"))
    assert after_scan["cashBalances"][0]["amount"] == "100.00"
    assert due_after_scan.get("lastChargeDate") is None
    assert due_after_scan["nextChargeDate"] == "2026-01-31"
    assert future_after_scan.get("lastChargeDate") is None
    assert future_after_scan["nextChargeDate"] == "2026-08-31"

    pending = unwrap_data(request_json(base, "/v1/ai/proposals/pending"))
    synthetic = next(
        proposal
        for proposal in pending
        if any(item["id"] == group["id"] for item in proposal["atomicGroups"])
    )
    assert synthetic["id"] == f"proposal_movement_{movement_id}"
    synthetic_detail = unwrap_data(
        request_json(base, f"/v1/ai/proposals/{synthetic['id']}")
    )
    assert synthetic_detail == synthetic

    persisted_pending = json.loads(ledger_path.read_text(encoding="utf-8"))
    assert sum(item["id"] == movement_id for item in persisted_pending["movements"]) == 1
    assert all(
        movement_id not in json.dumps(proposal, sort_keys=True)
        for proposal in persisted_pending["aiProposals"]
    )

    confirmed = unwrap_data(
        request_json(base, f"/v1/atomic-groups/{group['id']}/confirm", method="POST")
    )
    assert confirmed["ledgerWrite"] is True
    after = unwrap_data(request_json(base, f"/v1/accounts/{account_id}"))
    assert after["cashBalances"][0]["amount"] == "80.00"

    refreshed = unwrap_data(request_json(base, f"/v1/subscriptions/{due['id']}"))
    assert refreshed["lastChargeDate"] == "2026-01-31"
    assert refreshed["nextChargeDate"] == "2026-02-28"
    assert refreshed.get("pendingChargeMovementId") is None
    pending_after = unwrap_data(request_json(base, "/v1/ai/proposals/pending"))
    assert synthetic["id"] not in {item["id"] for item in pending_after}
    return {
        "confirmed": refreshed,
        "future": future_after_scan,
        "movementId": movement_id,
    }


def run_smoke(base: str, ledger_path: Path) -> None:
    assert unwrap_data(request_json(base, "/v1/accounts")) == []

    bootstrap = unwrap_data(request_json(base, "/v1/ledger/bootstrap"))
    assert bootstrap["syncCursor"] == "local_cursor_0000"
    genesis_pull = unwrap_data(
        request_json(base, "/v1/sync/changes?since=local_cursor_0000")
    )
    assert genesis_pull["cursor"] == "local_cursor_0000"
    assert genesis_pull["changes"] == []
    request_json(
        base,
        "/v1/sync/ack",
        method="POST",
        body={"cursor": "local_cursor_0000"},
        expected_status=204,
    )
    unknown_cursor = request_json(
        base,
        "/v1/sync/changes?since=local_change_missing",
        expected_status=400,
    )
    assert unknown_cursor["error"]["code"] == "invalid_sync_cursor"

    account_retry_key = "smoke-account-create-retry"
    cash = create_account(
        base,
        "Smoke Cash",
        "1000.00",
        idempotency_key=account_retry_key,
    )
    replayed_cash = create_account(
        base,
        "Smoke Cash",
        "1000.00",
        idempotency_key=account_retry_key,
    )
    assert replayed_cash == cash
    reserve = create_account(base, "Smoke Reserve", "250.00", account_type="wallet")
    brokerage = create_account(
        base,
        "Smoke Brokerage",
        "0.00",
        account_type="brokerage",
        balance_mode="mixed",
    )
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

    sync = unwrap_data(request_json(base, "/v1/sync/changes"))
    account_changes = [item for item in sync["changes"] if item["entityType"] == "account"]
    assert len(account_changes) >= 3
    assert account_changes[0]["operation"] == "create"
    assert account_changes[-1]["operation"] == "update"
    assert account_changes[-1]["payload"]["displayName"] == "Smoke Reserve Updated"
    sync_after_cursor = unwrap_data(request_json(base, f"/v1/sync/changes?since={sync['cursor']}"))
    assert sync_after_cursor["changes"] == []

    create_and_confirm_multileg_correction(base, cash["id"], reserve["id"])

    expense = create_and_confirm_manual_expense(base, cash["id"])
    assert expense["title"] == "local smoke coffee"
    sync_after_expense = unwrap_data(
        request_json(base, f"/v1/sync/changes?since={sync['cursor']}")
    )
    expense_changes = [
        item
        for item in sync_after_expense["changes"]
        if item["entityType"] == "movement" and item["entityId"] == expense["id"]
    ]
    assert len(expense_changes) == 1
    assert expense_changes[0]["operation"] == "create"
    assert expense_changes[0]["payload"]["status"] == "confirmed"
    assert expense_changes[0]["payload"]["title"] == "local smoke coffee"

    create_dca_and_mark_executed(base, cash["id"], brokerage["id"])
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

    subscription_account = create_account(
        base,
        "Smoke USD Card",
        "100.00",
        account_type="virtual_card",
        currency="USD",
    )
    subscription_result = create_and_confirm_due_subscription_charge(
        base, subscription_account["id"], ledger_path
    )
    assert subscription_result["confirmed"]["lastChargeDate"] == "2026-01-31"

    movements = unwrap_data(request_json(base, "/v1/movements"))
    confirmed_ids = {item["id"] for item in movements if item["status"] == "confirmed"}
    assert expense["id"] in confirmed_ids
    assert len(confirmed_ids) >= 3

    remote_push = unwrap_data(
        request_json(
            base,
            "/v1/sync/push",
            method="POST",
            body={
                "deviceId": "dev_unauthenticated_device",
                "changes": [
                    {
                        "id": "smoke_remote_change_000001",
                        "deviceId": "dev_unauthenticated_device",
                        "entityType": "account",
                        "entityId": "acct_smoke_remote",
                        "operation": "create",
                        "baseVersion": 0,
                        "payload": {
                            "id": "acct_smoke_remote",
                            "displayName": "Smoke Remote Account",
                            "accountType": "bank",
                            "defaultCurrency": "USD",
                            "supportedCurrencies": ["USD"],
                            "includeInNetWorth": True,
                            "visibility": "normal",
                            "status": "active",
                            "balanceMode": "cash_balance",
                            "cashBalances": [],
                            "tags": [],
                            "createdAt": "2026-06-28T00:00:00Z",
                            "updatedAt": "2026-06-28T00:00:00Z",
                        },
                        "createdAt": "2026-06-28T00:00:00Z",
                    }
                ],
            },
        )
    )
    assert remote_push["acceptedChangeIds"] == ["smoke_remote_change_000001"]
    assert remote_push["appliedChangeIds"] == ["smoke_remote_change_000001"]
    assert remote_push["skippedChangeIds"] == []
    assert len(unwrap_data(request_json(base, "/v1/accounts"))) == 5

    final_sync = unwrap_data(request_json(base, "/v1/sync/changes"))
    assert final_sync["cursor"].startswith("local_change_")
    assert any(item["entityType"] == "movement" for item in final_sync["changes"])
    assert any(
        item.get("sourceChangeId") == "smoke_remote_change_000001"
        for item in final_sync["changes"]
    )
    ack_response = request_json(
        base,
        "/v1/sync/ack",
        method="POST",
        body={"cursor": final_sync["cursor"]},
        expected_status=204,
    )
    assert ack_response == {}

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
    assert len(persisted["accounts"]) == 5
    assert any(account["id"] == "acct_smoke_remote" for account in persisted["accounts"])
    assert len(persisted["subscriptions"]) == 2
    assert len(persisted["snapshots"]) == 1
    assert persisted["syncState"]["pendingChangeIds"] == []
    assert len(persisted["syncChanges"]) >= len(final_sync["changes"])
    assert any(item["source"]["kind"] == "ai_proposal" for item in persisted["movements"])
    assert all(
        subscription_result["movementId"] not in json.dumps(proposal, sort_keys=True)
        for proposal in persisted["aiProposals"]
    )
    assert len(persisted["idempotencyState"]["records"]) >= 1
    assert account_retry_key not in ledger_path.read_text(encoding="utf-8")


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

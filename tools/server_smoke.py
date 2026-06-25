"""Smoke tests for Finwealth local API servers.

This script starts the local read-only mock API and/or dev server on localhost,
checks a small set of contract-critical endpoints, then shuts the processes
down. It performs no writes to the ledger and does not contact external
services.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class ServerSpec:
    name: str
    script: str
    port: int


MOCK = ServerSpec("mock", "tools/mock_api_server.py", 8787)
DEV = ServerSpec("dev", "server/dev_server.py", 8788)
RUST = ServerSpec("rust", "server-rs/Cargo.toml", 8790)


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
        with urllib.request.urlopen(request, timeout=2) as response:
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


def start_server(spec: ServerSpec, port: int) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [sys.executable, spec.script, "--port", str(port)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def start_rust_server(port: int) -> subprocess.Popen[str]:
    cargo = shutil.which("cargo") or str(Path.home() / ".cargo" / "bin" / "cargo.exe")
    env = os.environ.copy()
    env["PATH"] = (
        str(Path.home() / ".cargo" / "bin")
        + os.pathsep
        + str(Path.home() / "scoop" / "apps" / "mingw" / "current" / "bin")
        + os.pathsep
        + env.get("PATH", "")
    )
    env["FINWEALTH_RS_ADDR"] = f"127.0.0.1:{port}"
    return subprocess.Popen(
        [cargo, "run", "--quiet", "--manifest-path", RUST.script],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def wait_until_ready(base: str, process: subprocess.Popen[str]) -> None:
    last_error: Exception | None = None
    for _ in range(40):
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise RuntimeError(f"server exited early with {process.returncode}: {output}")
        try:
            payload = request_json(base, "/v1/health")
            if payload.get("ok") is True:
                return
        except Exception as exc:
            last_error = exc
            time.sleep(0.2)
    raise RuntimeError(f"server did not become ready: {last_error}")


def stop_server(process: subprocess.Popen[str]) -> None:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def run_with_server(spec: ServerSpec, port: int, test: Callable[[str], None]) -> None:
    process = start_rust_server(port) if spec.name == "rust" else start_server(spec, port)
    base = f"http://127.0.0.1:{port}"
    try:
        wait_until_ready(base, process)
        test(base)
    finally:
        stop_server(process)


def check_forbidden_endpoint(base: str) -> None:
    payload = request_json(
        base,
        "/v1/broker/orders",
        method="POST",
        body={},
        expected_status=403,
    )
    assert payload["ok"] is False
    assert payload["error"]["code"] == "forbidden_product_boundary"


def smoke_mock(base: str) -> None:
    degraded = request_json(base, "/v1/portfolio/overview?scenario=degraded")
    assert degraded["data"]["pendingSummary"]["aiPendingCount"] == 2

    dca = request_json(
        base,
        "/v1/dca/reminders/reminder_001/mark-executed-as-proposal",
        method="POST",
        body={},
    )
    assert dca["data"]["proposedMovements"][0]["status"] == "pending_review"

    quotes = request_json(base, "/v1/quotes/refresh", method="POST", body={})
    quote_statuses = {item["status"] for item in quotes["data"]["quotes"]}
    fx_statuses = {item["status"] for item in quotes["data"]["fxRates"]}
    assert "stale" in quote_statuses
    assert "offline_cached" in fx_statuses

    check_forbidden_endpoint(base)


def smoke_dev(base: str) -> None:
    login = request_json(
        base,
        "/v1/auth/login",
        method="POST",
        body={"username": "dev", "password": "not-logged", "deviceName": "server-smoke"},
    )
    assert login["data"]["accessToken"].startswith("dev_")

    bootstrap = request_json(base, "/v1/ledger/bootstrap")
    assert bootstrap["data"]["accounts"] == []

    degraded = request_json(base, "/v1/portfolio/overview?scenario=degraded")
    assert degraded["data"]["pendingSummary"]["dcaDueCount"] == 1

    sync = request_json(base, "/v1/sync/changes")
    assert sync["data"]["changes"] == []

    check_forbidden_endpoint(base)


def smoke_rust(base: str) -> None:
    degraded = request_json(base, "/v1/portfolio/overview?scenario=degraded")
    assert degraded["data"]["pendingSummary"]["aiPendingCount"] == 2

    default_accounts = request_json(base, "/v1/accounts")
    assert default_accounts["data"] == []

    accounts = request_json(base, "/v1/accounts?scenario=degraded")
    assert len(accounts["data"]) == 4
    assert accounts["data"][3]["accountType"] == "loan"

    broker = request_json(base, "/v1/accounts/acct_us_broker?scenario=degraded")
    assert broker["data"]["displayName"] == "美股券商"

    holdings = request_json(base, "/v1/accounts/acct_us_broker/holdings?scenario=degraded")
    assert holdings["data"][0]["accountId"] == "acct_us_broker"

    holdings_alias = request_json(base, "/v1/holdings?scenario=degraded")
    assert holdings_alias["data"][0]["id"] == "holding_nvda_us_broker"

    movements_alias = request_json(base, "/v1/movements/recent?scenario=degraded")
    assert len(movements_alias["data"]) >= 2

    movement = request_json(base, "/v1/movements/mov_luckin_001?scenario=degraded")
    assert movement["data"]["amountBreakdown"]["paidAmount"]["amount"] == "18.00"

    ai_pending = request_json(base, "/v1/ai/proposals/pending?scenario=degraded")
    assert ai_pending["data"][0]["id"] == "proposal_ai_001"

    quote_summary = request_json(base, "/v1/quotes/summary?scenario=degraded")
    assert quote_summary["data"]["staleCount"] == 2

    dca = request_json(
        base,
        "/v1/dca/reminders/reminder_001/mark-executed-as-proposal",
        method="POST",
        body={},
    )
    assert dca["data"]["proposedMovements"][0]["status"] == "pending_review"

    login = request_json(
        base,
        "/v1/auth/login",
        method="POST",
        body={"username": "dev", "password": "not-logged", "deviceName": "server-smoke"},
    )
    assert login["data"]["accessToken"].startswith("dev_")

    check_forbidden_endpoint(base)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run local server smoke checks.")
    parser.add_argument("--target", choices=["all", "mock", "dev", "rust"], default="all")
    parser.add_argument("--mock-port", type=int, default=8787)
    parser.add_argument("--dev-port", type=int, default=8788)
    parser.add_argument("--rust-port", type=int, default=8790)
    args = parser.parse_args()

    if args.target in {"all", "mock"}:
        run_with_server(MOCK, args.mock_port, smoke_mock)
        print("OK: mock server smoke passed")

    if args.target in {"all", "dev"}:
        run_with_server(DEV, args.dev_port, smoke_dev)
        print("OK: dev server smoke passed")

    if args.target in {"all", "rust"}:
        run_with_server(RUST, args.rust_port, smoke_rust)
        print("OK: rust server smoke passed")


if __name__ == "__main__":
    main()

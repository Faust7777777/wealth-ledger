#!/usr/bin/env python3
"""Verify due automation recovery across a sidecar restart using isolated state."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


PORT = 8793
BASE = f"http://127.0.0.1:{PORT}/v1/agent"
TIMEOUT_SECONDS = 600
NONCE = secrets.token_hex(8)
USER_ID = f"usr_automation_restart_smoke_{NONCE}"


def token() -> str:
    value = os.environ.get("FINWEALTH_AGENT_INTERNAL_TOKEN", "").strip()
    if not value:
        raise RuntimeError("FINWEALTH_AGENT_INTERNAL_TOKEN is required")
    return value


def headers(*, key: str | None = None) -> dict[str, str]:
    result = {
        "x-finwealth-internal-token": token(),
        "x-finwealth-user-id": USER_ID,
        "x-finwealth-ledger-id": "ledger_default",
        "x-finwealth-device-id": "vps_automation_restart_smoke",
    }
    if key:
        result["idempotency-key"] = key
    return result


def request(
    method: str,
    path: str,
    *,
    body: object | None = None,
    key: str | None = None,
) -> object:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request_headers = headers(key=key)
    if data is not None:
        request_headers["content-type"] = "application/json"
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{BASE}{path}",
            data=data,
            headers=request_headers,
            method=method,
        ),
        timeout=30,
    ) as response:
        return json.loads(response.read().decode("utf-8"))["data"]


def start_sidecar(state_dir: Path) -> subprocess.Popen[bytes]:
    env = os.environ.copy()
    env["FINWEALTH_AGENT_ADDR"] = f"127.0.0.1:{PORT}"
    env["FINWEALTH_AGENT_STATE_DIR"] = str(state_dir)
    process = subprocess.Popen(
        ["/usr/bin/node", "/opt/finwealth/agent-service/dist/main.js"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"isolated sidecar exited early: {process.returncode}")
        try:
            status = request("GET", "/status")
            if isinstance(status, dict) and status.get("configured") is True:
                return process
        except (urllib.error.URLError, ConnectionError):
            pass
        time.sleep(0.1)
    stop_sidecar(process)
    raise TimeoutError("isolated sidecar did not become ready")


def stop_sidecar(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def main() -> None:
    with tempfile.TemporaryDirectory(
        prefix="finwealth-agent-automation-restart-", dir="/tmp"
    ) as directory:
        state_dir = Path(directory).resolve()
        if state_dir.parent != Path("/tmp") or not state_dir.name.startswith(
            "finwealth-agent-automation-restart-"
        ):
            raise RuntimeError("unsafe temporary Agent state path")
        process = start_sidecar(state_dir)
        try:
            models = request("GET", "/models")
            model = next(item for item in models if item.get("provider") == "lore")
            conversations = request("GET", "/conversations")
            primary = next(item for item in conversations if item.get("isPrimary") is True)
            request(
                "PATCH",
                f"/conversations/{primary['id']}",
                body={"modelId": model["id"]},
                key=f"restart-smoke-model-{NONCE}",
            )
            due = datetime.now(timezone.utc) + timedelta(seconds=4)
            due_at = due.isoformat(timespec="milliseconds").replace("+00:00", "Z")
            automation = request(
                "POST",
                "/automations",
                body={
                    "kind": "financial_summary",
                    "intervalHours": 24,
                    "enabled": True,
                    "startAt": due_at,
                },
                key=f"restart-smoke-create-{NONCE}",
            )
            assert isinstance(automation, dict)
        finally:
            stop_sidecar(process)

        remaining = due.timestamp() - datetime.now(timezone.utc).timestamp()
        if remaining > 0:
            time.sleep(remaining + 0.5)
        process = start_sidecar(state_dir)
        try:
            deadline = time.monotonic() + TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                automations = request("GET", "/automations")
                current = next(
                    (item for item in automations if item.get("id") == automation["id"]),
                    None,
                )
                notifications = request("GET", "/notifications")
                if current and current.get("lastStatus") == "failed":
                    raise RuntimeError(
                        "restarted automation failed: "
                        f"{current.get('lastErrorCode', 'unknown')}"
                    )
                if current and current.get("lastStatus") == "success":
                    if not any(
                        item.get("kind") == "financial_summary"
                        and item.get("action") == "agent"
                        and item.get("title") == "财务总结已生成"
                        for item in notifications
                    ):
                        raise RuntimeError(
                            "restarted automation succeeded without its notification"
                        )
                    if datetime.fromisoformat(
                        current["nextRunAt"].replace("Z", "+00:00")
                    ) <= due:
                        raise RuntimeError("restarted automation did not advance its schedule")
                    print(
                        "OK: due financial summary completed and notified after sidecar restart."
                    )
                    return
                time.sleep(0.25)
            raise TimeoutError("restarted automation did not finish")
        finally:
            stop_sidecar(process)


if __name__ == "__main__":
    main()

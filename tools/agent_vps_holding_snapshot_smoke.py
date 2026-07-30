#!/usr/bin/env python3
"""Real-Grok image-to-holding-snapshot smoke for isolated Rust/Agent instances.

The caller must point both base URLs at temporary services backed by temporary
state. This script deliberately refuses the production ports so it cannot add
test accounts, instruments, or pending movements to the self-use ledger.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import time
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation
from pathlib import Path


TIMEOUT_SECONDS = 600
EXPECTED_QUANTITIES = {
    "BTC": "0.25",
    "ETH": "3.2",
    "USDT": "1250",
    "SOL": "5.5",
}


def normalized_base(env_name: str, default: str, forbidden_port: int) -> str:
    value = os.environ.get(env_name, default).rstrip("/")
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"}:
        raise RuntimeError(f"{env_name} must use a loopback HTTP origin")
    port = parsed.port
    if port is None or port == forbidden_port:
        raise RuntimeError(f"{env_name} must use a non-production temporary port")
    expected_path = "/v1/agent" if "AGENT" in env_name else ""
    if parsed.path != expected_path or parsed.params or parsed.query or parsed.fragment:
        raise RuntimeError(f"{env_name} has an unexpected path or URL component")
    return value


AGENT_BASE = normalized_base(
    "FINWEALTH_SMOKE_AGENT_BASE_URL", "http://127.0.0.1:19092/v1/agent", 8792
)
SERVER_BASE = normalized_base(
    "FINWEALTH_SMOKE_SERVER_BASE_URL", "http://127.0.0.1:19090", 8790
)
NONCE = secrets.token_hex(8)
USER_ID = f"usr_holding_snapshot_smoke_{NONCE}"


def internal_token() -> str:
    value = os.environ.get("FINWEALTH_AGENT_INTERNAL_TOKEN", "").strip()
    if not value:
        raise RuntimeError("FINWEALTH_AGENT_INTERNAL_TOKEN is required")
    return value


def headers(*, agent: bool, idempotency_key: str | None = None) -> dict[str, str]:
    result = {"x-finwealth-internal-token": internal_token()}
    if agent:
        result.update(
            {
                "x-finwealth-user-id": USER_ID,
                "x-finwealth-ledger-id": "ledger_smoke",
                "x-finwealth-device-id": "vps_holding_snapshot_smoke",
            }
        )
    if idempotency_key:
        result["idempotency-key"] = idempotency_key
    return result


def request(
    method: str,
    base: str,
    path: str,
    *,
    body: object | None = None,
    raw_body: bytes | None = None,
    content_type: str = "application/json",
    agent: bool,
    idempotency_key: str | None = None,
) -> object:
    data = raw_body
    if data is None and body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    request_headers = headers(agent=agent, idempotency_key=idempotency_key)
    if data is not None:
        request_headers["content-type"] = content_type
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{base}{path}", data=data, headers=request_headers, method=method
        ),
        timeout=30,
    ) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["data"]


def server_request(
    method: str, path: str, *, body: object | None = None, key: str | None = None
) -> object:
    return request(
        method,
        SERVER_BASE,
        path,
        body=body,
        agent=False,
        idempotency_key=key,
    )


def agent_request(
    method: str,
    path: str,
    *,
    body: object | None = None,
    key: str | None = None,
) -> object:
    return request(
        method,
        AGENT_BASE,
        path,
        body=body,
        agent=True,
        idempotency_key=key,
    )


def upload_image(path: Path) -> str:
    content = path.read_bytes()
    if not content.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError("holding snapshot smoke fixture must be a PNG")
    boundary = f"----finwealth-{secrets.token_hex(16)}"
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'.encode(),
            b"Content-Type: image/png\r\n\r\n",
            content,
            f"\r\n--{boundary}--\r\n".encode(),
        ]
    )
    metadata = request(
        "POST",
        AGENT_BASE,
        "/attachments",
        raw_body=body,
        content_type=f"multipart/form-data; boundary={boundary}",
        agent=True,
        idempotency_key=f"holding-smoke-upload-{NONCE}",
    )
    if not isinstance(metadata, dict) or not isinstance(metadata.get("id"), str):
        raise RuntimeError("Agent returned invalid attachment metadata")
    return metadata["id"]


def completed_tools(conversation_id: str, run_id: str) -> list[str]:
    event_type = ""
    result: list[str] = []
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{AGENT_BASE}/conversations/{conversation_id}/events?after=0",
            headers=headers(agent=True),
            method="GET",
        ),
        timeout=30,
    ) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").rstrip("\r\n")
            if line.startswith("event: "):
                event_type = line[7:]
            elif line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("runId") != run_id:
                    continue
                if event_type == "tool.completed":
                    result.append(
                        f"{data.get('name', 'unknown')}:{data.get('isError') is True}"
                    )
                if event_type in {"run.completed", "run.failed"}:
                    return result
    return result


def wait_for_run(conversation_id: str, run_id: str) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        messages = agent_request(
            "GET", f"/conversations/{conversation_id}/messages"
        )
        assistant = next(
            (
                item
                for item in messages
                if item.get("role") == "assistant" and item.get("runId") == run_id
            ),
            None,
        )
        if assistant and assistant.get("status") == "failed":
            raise RuntimeError(
                f"holding snapshot Agent run failed: {assistant.get('errorCode', 'unknown')}"
            )
        if assistant and assistant.get("status") == "completed":
            return
        time.sleep(0.25)
    raise TimeoutError("holding snapshot Agent run timed out")


def pending_groups() -> list[dict[str, object]]:
    proposals = server_request("GET", "/v1/ai/proposals/pending")
    return [
        group
        for proposal in proposals
        for group in proposal.get("atomicGroups", [])
        if isinstance(group, dict)
    ]


def run(image: Path) -> None:
    deadline = time.monotonic() + 30
    while True:
        try:
            status = agent_request("GET", "/status")
            if isinstance(status, dict) and status.get("configured") is True:
                break
        except OSError:
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError("temporary Agent did not load the production Grok connection")
        time.sleep(0.25)

    account = server_request(
        "POST",
        "/v1/accounts",
        body={
            "displayName": "Holding Snapshot Smoke Exchange",
            "accountType": "exchange",
            "defaultCurrency": "CNY",
            "supportedCurrencies": ["CNY"],
            "includeInNetWorth": True,
            "balanceMode": "holdings",
            "openingBalances": [],
        },
        key=f"holding-smoke-account-{NONCE}",
    )
    account_id = account["id"]
    before_quotes = server_request("GET", "/v1/quotes/summary")

    conversation = agent_request(
        "POST",
        "/conversations",
        body={"title": f"Holding snapshot smoke {NONCE}"},
        key=f"holding-smoke-conversation-{NONCE}",
    )
    models = agent_request("GET", "/models")
    model = next((item for item in models if item.get("provider") == "xai"), None)
    if model is None:
        raise RuntimeError("temporary Agent did not expose an xai/Grok model")
    conversation = agent_request(
        "PATCH",
        f"/conversations/{conversation['id']}",
        body={"modelId": model["id"]},
        key=f"holding-smoke-model-{NONCE}",
    )
    attachment_id = upload_image(image)
    accepted = agent_request(
        "POST",
        f"/conversations/{conversation['id']}/messages",
        body={
            "text": (
                "这是 Holding Snapshot Smoke Exchange 的完整 OKX 持仓截图。"
                "先查询 accounts 和 holdings；然后把截图中的全部资产代码和当前总数量"
                "一次性调用 finwealth_propose_holding_snapshot，生成一个待审核持仓快照。"
                "工具参数只提交 symbol 和 targetQuantity。不得确认、批准或采用报价。"
                "最后只说明已加入待确认。"
            ),
            "attachmentIds": [attachment_id],
        },
        key=f"holding-smoke-message-{NONCE}",
    )
    wait_for_run(conversation["id"], accepted["runId"])
    tools = completed_tools(conversation["id"], accepted["runId"])
    if "finwealth_propose_holding_snapshot:False" not in tools:
        raise RuntimeError(f"holding snapshot tool did not complete successfully: {tools}")

    instruments = server_request("GET", "/v1/instruments")
    by_symbol = {
        item.get("symbol", "").upper(): item
        for item in instruments
        if isinstance(item.get("symbol"), str)
    }
    missing = sorted(set(EXPECTED_QUANTITIES) - set(by_symbol))
    if missing:
        raise RuntimeError(f"snapshot did not ensure expected symbols: {missing}")
    if by_symbol["SOL"].get("quoteCurrency") != "USDT":
        raise RuntimeError("discovered SOL instrument was not USDT quoted")

    account_after = server_request("GET", f"/v1/accounts/{account_id}")
    if account_after.get("defaultCurrency") != "CNY":
        raise RuntimeError("crypto registration changed the account display currency")
    supported = set(account_after.get("supportedCurrencies", []))
    if not {"CNY", "USDT"}.issubset(supported):
        raise RuntimeError("account does not support its display and market quote currencies")
    if server_request("GET", f"/v1/accounts/{account_id}/holdings"):
        raise RuntimeError("Agent changed confirmed holdings before review")

    groups = [
        group
        for group in pending_groups()
        if group.get("targetType") == "holding" and group.get("targetId") == account_id
    ]
    if len(groups) != 1:
        raise RuntimeError(f"Agent created {len(groups)} holding review groups instead of one")
    movements = groups[0].get("proposedMovements", [])
    if len(movements) != len(EXPECTED_QUANTITIES):
        raise RuntimeError("holding review group did not contain all image assets")
    if any("holding_snapshot" not in item.get("tags", []) for item in movements):
        raise RuntimeError("holding review group contains a non-snapshot movement")
    symbols_by_id = {
        item["id"]: symbol
        for symbol, item in by_symbol.items()
        if symbol in EXPECTED_QUANTITIES
    }
    observed_quantities: dict[str, Decimal] = {}
    for movement in movements:
        adjustment = movement.get("holdingAdjustment", {})
        symbol = symbols_by_id.get(adjustment.get("instrumentId"))
        if symbol is None:
            raise RuntimeError("holding review group contains an unexpected instrument")
        try:
            observed_quantities[symbol] = Decimal(adjustment["targetQuantity"])
        except (InvalidOperation, KeyError):
            raise RuntimeError("holding review group contains an invalid target quantity")
    expected_quantities = {
        symbol: Decimal(quantity) for symbol, quantity in EXPECTED_QUANTITIES.items()
    }
    if observed_quantities != expected_quantities:
        raise RuntimeError("Grok did not preserve the quantities shown in the image")
    if server_request("GET", "/v1/quotes/summary") != before_quotes:
        raise RuntimeError("holding snapshot smoke changed authoritative quotes")

    print(
        "OK: isolated production Grok created one four-asset review-only holding snapshot."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    image = args.image.resolve(strict=True)
    if not image.is_file():
        raise RuntimeError("holding snapshot fixture must be a regular file")
    run(image)


if __name__ == "__main__":
    main()

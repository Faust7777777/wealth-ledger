#!/usr/bin/env python3
"""Real-Grok image-to-valued-holdings smoke for isolated Rust/Agent instances.

The caller must point both base URLs at temporary services backed by temporary
state. The model may only create review candidates; the harness then simulates
explicit user approvals and verifies the resulting valuation. This script
deliberately refuses the production ports so it cannot add test accounts,
instruments, quotes, or movements to the self-use ledger.
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
EXPECTED_CRYPTO_QUANTITIES = {
    "BTC": "0.25",
    "ETH": "3.2",
    "USDT": "1250",
    "SOL": "5.5",
}
EXPECTED_INVESTMENTS = {
    "AAPL": {
        "type": "equity",
        "market": "NASDAQ",
        "quoteCurrency": "USD",
        "quantity": "12",
    },
    "510300": {
        "type": "fund",
        "market": "SSE",
        "quoteCurrency": "CNY",
        "quantity": "100",
    },
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


def run(image: Path, *, investment: bool) -> None:
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

    account_name = (
        "Investment Snapshot Smoke Brokerage"
        if investment
        else "Holding Snapshot Smoke Exchange"
    )
    account = server_request(
        "POST",
        "/v1/accounts",
        body={
            "displayName": account_name,
            "accountType": "brokerage" if investment else "exchange",
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
    if agent_request("GET", "/quote-candidates"):
        raise RuntimeError("temporary Agent state unexpectedly contains quote candidates")

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
    prompt = (
        "这是 Investment Snapshot Smoke Brokerage 的完整券商持仓截图。"
        "先查询 accounts、instruments 和 holdings；然后把截图中的全部投资代码、名称、"
        "类型、市场、计价币和当前总数量一次性调用 "
        "finwealth_propose_investment_holding_snapshot，生成一个待审核持仓快照。"
        "不得提交或编造 instrumentId，不得确认、批准或采用报价。最后只说明已加入待确认。"
        if investment
        else (
            "这是 Holding Snapshot Smoke Exchange 的完整 OKX 持仓截图。"
            "先查询 accounts 和 holdings；然后把截图中的全部资产代码和当前总数量"
            "一次性调用 finwealth_propose_holding_snapshot，生成一个待审核持仓快照。"
            "工具参数只提交 symbol 和 targetQuantity。不得确认、批准或采用报价。"
            "最后只说明已加入待确认。"
        )
    )
    accepted = agent_request(
        "POST",
        f"/conversations/{conversation['id']}/messages",
        body={
            "text": prompt,
            "attachmentIds": [attachment_id],
        },
        key=f"holding-smoke-message-{NONCE}",
    )
    wait_for_run(conversation["id"], accepted["runId"])
    tools = completed_tools(conversation["id"], accepted["runId"])
    expected_tool = (
        "finwealth_propose_investment_holding_snapshot"
        if investment
        else "finwealth_propose_holding_snapshot"
    )
    if f"{expected_tool}:False" not in tools:
        raise RuntimeError(f"holding snapshot tool did not complete successfully: {tools}")

    instruments = server_request("GET", "/v1/instruments")
    by_symbol = {
        item.get("symbol", "").upper(): item
        for item in instruments
        if isinstance(item.get("symbol"), str)
    }
    expected_symbols = set(EXPECTED_INVESTMENTS if investment else EXPECTED_CRYPTO_QUANTITIES)
    missing = sorted(expected_symbols - set(by_symbol))
    if missing:
        raise RuntimeError(f"snapshot did not ensure expected symbols: {missing}")
    if investment:
        for symbol, expected in EXPECTED_INVESTMENTS.items():
            instrument = by_symbol[symbol]
            if any(instrument.get(field) != expected[field] for field in ("type", "market", "quoteCurrency")):
                raise RuntimeError(f"registered investment identity is wrong for {symbol}")
            if instrument.get("sourceRef") != "finwealth_agent_source_instrument":
                raise RuntimeError(f"registered investment source is wrong for {symbol}")
    elif by_symbol["SOL"].get("quoteCurrency") != "USDT":
        raise RuntimeError("discovered SOL instrument was not USDT quoted")

    account_after = server_request("GET", f"/v1/accounts/{account_id}")
    if account_after.get("defaultCurrency") != "CNY":
        raise RuntimeError("crypto registration changed the account display currency")
    supported = set(account_after.get("supportedCurrencies", []))
    expected_supported = {"CNY", "USD" if investment else "USDT"}
    if not expected_supported.issubset(supported):
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
    if len(movements) != len(expected_symbols):
        raise RuntimeError("holding review group did not contain all image assets")
    if any("holding_snapshot" not in item.get("tags", []) for item in movements):
        raise RuntimeError("holding review group contains a non-snapshot movement")
    symbols_by_id = {
        item["id"]: symbol
        for symbol, item in by_symbol.items()
        if symbol in expected_symbols
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
    expected_quantities = (
        {
            symbol: Decimal(str(item["quantity"]))
            for symbol, item in EXPECTED_INVESTMENTS.items()
        }
        if investment
        else {
            symbol: Decimal(quantity)
            for symbol, quantity in EXPECTED_CRYPTO_QUANTITIES.items()
        }
    )
    if observed_quantities != expected_quantities:
        raise RuntimeError("Grok did not preserve the quantities shown in the image")
    candidates = agent_request("GET", "/quote-candidates")
    if not isinstance(candidates, list):
        raise RuntimeError("Agent returned invalid quote candidate state")
    if any(item.get("status") != "suggested" for item in candidates):
        raise RuntimeError("snapshot quote candidates were applied without review")
    expected_instrument_ids = {
        by_symbol[symbol]["id"] for symbol in expected_symbols
    }
    instrument_candidates = {
        item.get("instrumentId")
        for item in candidates
        if item.get("kind") == "instrument"
    }
    if instrument_candidates != expected_instrument_ids:
        raise RuntimeError("snapshot did not create one quote candidate per source asset")
    expected_fx_pairs = (
        {("USD", "CNY")}
        if investment
        else {("USDT", "USD"), ("USD", "CNY")}
    )
    fx_candidates = {
        (item.get("baseCurrency"), item.get("quoteCurrency"))
        for item in candidates
        if item.get("kind") == "fx"
    }
    if fx_candidates != expected_fx_pairs:
        raise RuntimeError("snapshot did not create the required valuation FX candidates")
    if len(candidates) != len(expected_instrument_ids) + len(expected_fx_pairs):
        raise RuntimeError("snapshot created duplicate or unrelated quote candidates")
    if server_request("GET", "/v1/quotes/summary") != before_quotes:
        raise RuntimeError("holding snapshot smoke changed authoritative quotes")

    server_request(
        "POST",
        f"/v1/atomic-groups/{groups[0]['id']}/confirm",
        key=f"holding-smoke-confirm-{NONCE}",
    )
    confirmed_holdings = server_request("GET", f"/v1/accounts/{account_id}/holdings")
    if len(confirmed_holdings) != len(expected_symbols):
        raise RuntimeError("explicit snapshot confirmation did not create all holdings")
    if any(item.get("marketValue") is not None for item in confirmed_holdings):
        raise RuntimeError("holdings were valued before quote candidates were approved")

    for candidate in candidates:
        reviewed = agent_request(
            "POST",
            f"/quote-candidates/{candidate['id']}/review",
            body={"decision": "apply"},
            key=f"holding-smoke-quote-{candidate['id']}",
        )
        if reviewed.get("status") != "applied":
            raise RuntimeError("explicit quote approval did not apply the candidate")
    valued_holdings = server_request("GET", f"/v1/accounts/{account_id}/holdings")
    if any(
        not isinstance(item.get("marketValue"), dict)
        or item["marketValue"].get("currency") != "CNY"
        or not isinstance(item.get("accountMarketValue"), dict)
        or item["accountMarketValue"].get("currency") != "CNY"
        for item in valued_holdings
    ):
        raise RuntimeError("approved quote and FX candidates did not value every holding in CNY")
    if server_request("GET", "/v1/quotes/summary") == before_quotes:
        raise RuntimeError("explicit quote approvals did not change authoritative quotes")

    label = "non-crypto investment" if investment else "four-asset crypto"
    print(
        f"OK: isolated production Grok created one review-only {label} holding "
        "snapshot and separate suggested valuation candidates; explicit harness "
        "approvals produced fully valued CNY holdings."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("--investment", action="store_true")
    args = parser.parse_args()
    image = args.image.resolve(strict=True)
    if not image.is_file():
        raise RuntimeError("holding snapshot fixture must be a regular file")
    run(image, investment=args.investment)


if __name__ == "__main__":
    main()

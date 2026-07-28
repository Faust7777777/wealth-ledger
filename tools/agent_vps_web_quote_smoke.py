#!/usr/bin/env python3
"""Verify that the production Pi model can research a web FX quote safely."""

from __future__ import annotations

import json
import os
import secrets
import shutil
import time
import urllib.request
from pathlib import Path


AGENT_BASE = "http://127.0.0.1:8792/v1/agent"
SOURCE_URL = "https://api.frankfurter.app/latest?from=USD&to=CNY"
TIMEOUT_SECONDS = 600
NONCE = secrets.token_hex(8)
USER_ID = f"usr_web_quote_smoke_{NONCE}"


def token() -> str:
    value = os.environ.get("FINWEALTH_AGENT_INTERNAL_TOKEN", "").strip()
    if not value:
        raise RuntimeError("FINWEALTH_AGENT_INTERNAL_TOKEN is required")
    return value


def agent_headers(*, idempotency_key: str | None = None) -> dict[str, str]:
    result = {
        "x-finwealth-internal-token": token(),
        "x-finwealth-user-id": USER_ID,
        "x-finwealth-ledger-id": "ledger_default",
        "x-finwealth-device-id": "vps_web_quote_smoke",
    }
    if idempotency_key:
        result["idempotency-key"] = idempotency_key
    return result


def request(method: str, path: str, *, body: object | None = None) -> object:
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = agent_headers(idempotency_key=f"web-quote-{NONCE}-{path}")
    if data is not None:
        headers["content-type"] = "application/json"
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{AGENT_BASE}{path}", data=data, headers=headers, method=method
        ),
        timeout=30,
    ) as response:
        return json.loads(response.read().decode("utf-8"))["data"]


def authoritative_quote_summary() -> object:
    server = os.environ.get("FINWEALTH_SERVER_BASE_URL", "").rstrip("/")
    if not server:
        raise RuntimeError("FINWEALTH_SERVER_BASE_URL is required")
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{server}/v1/quotes/summary",
            headers={"x-finwealth-internal-token": token()},
            method="GET",
        ),
        timeout=30,
    ) as response:
        return json.loads(response.read().decode("utf-8"))["data"]


def completed_tools(conversation_id: str, run_id: str) -> list[str]:
    event_type = ""
    result: list[str] = []
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{AGENT_BASE}/conversations/{conversation_id}/events?after=0",
            headers=agent_headers(),
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


def cleanup() -> None:
    state_dir = Path(
        os.environ.get("FINWEALTH_AGENT_STATE_DIR", "/var/lib/finwealth-agent")
    ).resolve()
    users = (state_dir / "users").resolve()
    target = (users / USER_ID).resolve()
    if target.parent != users or not target.name.startswith("usr_web_quote_smoke_"):
        raise RuntimeError("refusing unsafe smoke state cleanup")
    if target.exists():
        shutil.rmtree(target)


def main() -> None:
    before = authoritative_quote_summary()
    conversation = request(
        "POST", "/conversations", body={"title": f"Web quote smoke {NONCE}"}
    )
    assert isinstance(conversation, dict)
    models = request("GET", "/models")
    model = next(item for item in models if item.get("provider") == "lore")
    request(
        "PATCH",
        f"/conversations/{conversation['id']}",
        body={"modelId": model["id"]},
    )
    prompt = (
        "调用隔离 bash，用 curl -fsSL 读取 "
        f"{SOURCE_URL}。取其中 USD/CNY 的 rate 和 date，然后调用 "
        "finwealth_suggest_quote 创建 kind=fx、baseCurrency=USD、"
        "quoteCurrency=CNY 的待审核候选；rate 使用网页原值，asOf 使用网页日期"
        "的 UTC 零点，source=Frankfurter，sourceUrl 使用实际读取的完整 URL。"
        "最后只回复完成。"
    )
    accepted = request(
        "POST",
        f"/conversations/{conversation['id']}/messages",
        body={"text": prompt, "attachmentIds": []},
    )
    assert isinstance(accepted, dict)
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        messages = request("GET", f"/conversations/{conversation['id']}/messages")
        assistant = next(
            (
                item
                for item in messages
                if item.get("role") == "assistant"
                and item.get("runId") == accepted["runId"]
            ),
            None,
        )
        if assistant and assistant.get("status") == "failed":
            raise RuntimeError(
                f"web quote Agent run failed: {assistant.get('errorCode', 'unknown')}"
            )
        if assistant and assistant.get("status") == "completed":
            break
        time.sleep(0.25)
    else:
        raise TimeoutError("web quote Agent run timed out")

    tools = completed_tools(conversation["id"], accepted["runId"])
    if "bash:False" not in tools or "finwealth_suggest_quote:False" not in tools:
        raise RuntimeError(f"web quote tools did not complete successfully: {tools}")
    candidates = request("GET", "/quote-candidates")
    if not isinstance(candidates, list) or len(candidates) != 1:
        raise RuntimeError("web quote smoke did not create exactly one candidate")
    candidate = candidates[0]
    if (
        candidate.get("kind") != "fx"
        or candidate.get("baseCurrency") != "USD"
        or candidate.get("quoteCurrency") != "CNY"
        or candidate.get("status") != "suggested"
        or candidate.get("sourceUrl") != SOURCE_URL
        or float(candidate.get("rate", "0")) <= 0
    ):
        raise RuntimeError("web quote candidate fields are invalid")
    if authoritative_quote_summary() != before:
        raise RuntimeError("suggesting a web quote changed authoritative valuation")
    print("OK: production Pi model created one reviewed web FX quote candidate.")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()

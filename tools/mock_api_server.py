"""Read-only local mock API server for Finwealth contracts.

This server is for local UI/API shape checks only.

Rules:
- Binds to 127.0.0.1 by default.
- Reads JSON examples from docs/contracts/examples.
- Does not write files.
- Does not persist POST side effects.
- Does not implement transfer/order/AI auto-write endpoints.
"""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "docs" / "contracts" / "examples"

FORBIDDEN_PATHS = {
    "/v1/transfers/execute",
    "/v1/broker/orders",
    "/v1/broker/buy",
    "/v1/broker/sell",
    "/v1/ai/auto-approve",
    "/v1/ai/write-ledger-directly",
    "/v1/coupons/plan",
}


def read_example(name: str) -> bytes:
    path = EXAMPLES / name
    return path.read_bytes()


def json_bytes(payload: object) -> bytes:
    return json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")


class MockApiHandler(BaseHTTPRequestHandler):
    server_version = "FinwealthMockApi/0.1"

    def _send_json(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Finwealth-Mock", "true")
        self.end_headers()
        self.wfile.write(body)

    def _not_found(self) -> None:
        self._send_json(
            404,
            json_bytes(
                {
                    "ok": False,
                    "error": {
                        "code": "mock_not_found",
                        "message": "No mock response is configured for this endpoint.",
                        "severity": "warning",
                        "retryable": False,
                    },
                }
            ),
        )

    def _forbidden(self) -> None:
        self._send_json(
            403,
            json_bytes(
                {
                    "ok": False,
                    "error": {
                        "code": "forbidden_product_boundary",
                        "message": "This product does not expose transfer, order, coupon planning, or AI auto-write endpoints.",
                        "severity": "critical",
                        "retryable": False,
                    },
                }
            ),
        )

    def _consume_request_body(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 0:
            self.rfile.read(length)

    def do_GET(self) -> None:  # noqa: N802 - stdlib hook
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path in FORBIDDEN_PATHS:
            self._forbidden()
            return

        if path == "/v1/health":
            self._send_json(
                200,
                json_bytes(
                    {
                        "ok": True,
                        "data": {
                            "status": "ok",
                            "serverTime": "2026-06-25T12:00:00+08:00",
                            "version": "mock-0.1.0",
                        },
                    }
                ),
            )
            return

        if path == "/v1/ledger/bootstrap":
            self._send_json(200, read_example("ledger_bootstrap_empty.response.json"))
            return

        if path == "/v1/portfolio/overview":
            scenario = query.get("scenario", ["empty"])[0]
            if scenario == "degraded":
                self._send_json(200, read_example("portfolio_overview_degraded.response.json"))
            else:
                self._send_json(200, read_example("portfolio_overview_empty.response.json"))
            return

        if path == "/v1/ai/proposals/pending":
            self._send_json(200, json_bytes({"ok": True, "data": []}))
            return

        if path == "/v1/quotes/summary":
            self._send_json(
                200,
                json_bytes(
                    {
                        "ok": True,
                        "data": {
                            "freshCount": 0,
                            "staleCount": 0,
                            "offlineCachedCount": 0,
                            "unpriceableCount": 0,
                            "errorCount": 0,
                        },
                    }
                ),
            )
            return

        self._not_found()

    def do_POST(self) -> None:  # noqa: N802 - stdlib hook
        parsed = urlparse(self.path)
        path = parsed.path
        self._consume_request_body()

        if path in FORBIDDEN_PATHS:
            self._forbidden()
            return

        if path == "/v1/ai/proposals/from-text":
            self._send_json(200, read_example("ai_modify_movement_diff.response.json"))
            return

        if path == "/v1/ai/proposals/from-image":
            self._send_json(200, read_example("ai_modify_movement_diff.response.json"))
            return

        if path == "/v1/ai/proposals/from-csv":
            self._send_json(200, read_example("ai_modify_movement_diff.response.json"))
            return

        if path.endswith("/mark-executed-as-proposal") and path.startswith("/v1/dca/reminders/"):
            self._send_json(200, read_example("dca_mark_executed_proposal.response.json"))
            return

        if path == "/v1/quotes/refresh":
            self._send_json(200, read_example("quote_refresh_stale.response.json"))
            return

        self._not_found()

    def log_message(self, format: str, *args: object) -> None:
        print(f"[mock-api] {self.address_string()} - {format % args}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Finwealth read-only mock API server.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8787, type=int)
    args = parser.parse_args()

    if args.host not in {"127.0.0.1", "localhost"}:
        raise SystemExit("Refusing to bind mock API server to a non-localhost address.")

    server = ThreadingHTTPServer((args.host, args.port), MockApiHandler)
    print(f"Finwealth mock API listening on http://{args.host}:{args.port}")
    print("Read-only mock: no files are written, no real AI/quote/sync calls are made.")
    server.serve_forever()


if __name__ == "__main__":
    main()

"""Finwealth local dev server skeleton.

This is not the production server. It is a dependency-free, localhost-only
HTTP skeleton that follows the contract boundaries:

- no transfer execution
- no broker order endpoints
- no AI direct ledger writes
- no coupon planning
- no persistence
- no real auth, AI, quotes, or sync
"""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
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


def example(name: str) -> Any:
    return json.loads((EXAMPLES / name).read_text(encoding="utf-8"))


def envelope(data: Any) -> dict[str, Any]:
    return {"ok": True, "data": data}


def error(code: str, message: str, severity: str = "warning", retryable: bool = False) -> dict[str, Any]:
    return {
        "ok": False,
        "error": {
            "code": code,
            "message": message,
            "severity": severity,
            "retryable": retryable,
        },
    }


class DevServerHandler(BaseHTTPRequestHandler):
    server_version = "FinwealthDevServer/0.1"

    def send_json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Finwealth-Server", "dev-skeleton")
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self) -> None:
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Finwealth-Server", "dev-skeleton")
        self.end_headers()

    def read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8"))
        except Exception:
            return {}
        return value if isinstance(value, dict) else {}

    def forbid_if_needed(self, path: str) -> bool:
        if path not in FORBIDDEN_PATHS:
            return False
        self.send_json(
            403,
            error(
                "forbidden_product_boundary",
                "This product does not expose transfer, broker order, coupon planning, or AI auto-write endpoints.",
                severity="critical",
            ),
        )
        return True

    def not_found(self) -> None:
        self.send_json(
            404,
            error("not_found", "No dev-server route is configured for this endpoint."),
        )

    def not_implemented_yet(self) -> None:
        self.send_json(
            501,
            error(
                "dev_route_not_implemented",
                "This endpoint exists in the API contract but is not implemented in the dev skeleton yet.",
                retryable=False,
            ),
        )

    def do_GET(self) -> None:  # noqa: N802 - stdlib hook
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if self.forbid_if_needed(path):
            return

        if path == "/v1/health":
            self.send_json(
                200,
                envelope(
                    {
                        "status": "ok",
                        "serverTime": "2026-06-25T12:00:00+08:00",
                        "version": "dev-skeleton-0.1.0",
                    }
                ),
            )
            return

        if path == "/v1/ledger/bootstrap":
            self.send_json(200, example("ledger_bootstrap_empty.response.json"))
            return

        if path == "/v1/portfolio/overview":
            scenario = query.get("scenario", ["empty"])[0]
            if scenario == "degraded":
                self.send_json(200, example("portfolio_overview_degraded.response.json"))
            else:
                self.send_json(200, example("portfolio_overview_empty.response.json"))
            return

        if path in {
            "/v1/auth/devices",
            "/v1/accounts",
            "/v1/accounts/anomalies",
            "/v1/portfolio/holdings",
            "/v1/movements",
            "/v1/dca/plans",
            "/v1/dca/reminders/due",
            "/v1/ai/proposals/pending",
            "/v1/quotes",
            "/v1/fx-rates",
            "/v1/snapshots",
            "/v1/categories",
            "/v1/counterparties",
        }:
            self.send_json(200, envelope([]))
            return

        if path == "/v1/portfolio/allocation":
            self.send_json(200, envelope({}))
            return

        if path == "/v1/quotes/summary":
            self.send_json(
                200,
                envelope(
                    {
                        "freshCount": 0,
                        "staleCount": 0,
                        "offlineCachedCount": 0,
                        "unpriceableCount": 0,
                        "errorCount": 0,
                    }
                ),
            )
            return

        if path == "/v1/snapshots/latest":
            self.send_json(200, envelope(None))
            return

        if path == "/v1/sync/bootstrap":
            self.send_json(200, envelope({"cursor": "dev_cursor_0001"}))
            return

        if path == "/v1/sync/changes":
            self.send_json(200, envelope({"cursor": "dev_cursor_0001", "changes": [], "conflicts": []}))
            return

        if path.startswith("/v1/accounts/") and path.endswith("/holdings"):
            self.send_json(200, envelope([]))
            return

        if path.startswith("/v1/instruments/") and path.endswith("/historical-prices"):
            self.send_json(200, envelope([]))
            return

        self.not_found()

    def do_POST(self) -> None:  # noqa: N802 - stdlib hook
        parsed = urlparse(self.path)
        path = parsed.path
        body = self.read_json_body()

        if self.forbid_if_needed(path):
            return

        if path == "/v1/auth/login":
            if not body.get("username") or not body.get("password") or not body.get("deviceName"):
                self.send_json(400, error("invalid_login_request", "username, password, and deviceName are required."))
                return
            self.send_json(
                200,
                envelope(
                    {
                        "accessToken": "dev_access_token_not_for_production",
                        "refreshToken": "dev_refresh_token_not_for_production",
                        "expiresAt": "2026-06-25T13:00:00+08:00",
                        "deviceId": "dev_device_001",
                    }
                ),
            )
            return

        if path == "/v1/auth/refresh":
            self.send_json(
                200,
                envelope(
                    {
                        "accessToken": "dev_access_token_not_for_production",
                        "refreshToken": "dev_refresh_token_not_for_production",
                        "expiresAt": "2026-06-25T13:00:00+08:00",
                        "deviceId": "dev_device_001",
                    }
                ),
            )
            return

        if path == "/v1/auth/logout" or path == "/v1/sync/ack":
            self.send_no_content()
            return

        if path.startswith("/v1/auth/devices/") and path.endswith("/revoke"):
            self.send_no_content()
            return

        if path == "/v1/quotes/refresh":
            self.send_json(200, example("quote_refresh_stale.response.json"))
            return

        if path in {
            "/v1/ai/proposals/from-text",
            "/v1/ai/proposals/from-image",
            "/v1/ai/proposals/from-csv",
        }:
            self.send_json(200, example("ai_modify_movement_diff.response.json"))
            return

        if path.startswith("/v1/dca/reminders/") and path.endswith("/mark-executed-as-proposal"):
            self.send_json(200, example("dca_mark_executed_proposal.response.json"))
            return

        if path.startswith("/v1/dca/reminders/") and (path.endswith("/skip") or path.endswith("/snooze")):
            self.not_implemented_yet()
            return

        if path == "/v1/sync/push":
            self.send_json(200, envelope({"cursor": "dev_cursor_0001", "conflicts": []}))
            return

        if path.startswith("/v1/atomic-groups/") or path.startswith("/v1/ai/atomic-groups/"):
            self.not_implemented_yet()
            return

        self.not_implemented_yet()

    def do_PATCH(self) -> None:  # noqa: N802 - stdlib hook
        parsed = urlparse(self.path)
        if self.forbid_if_needed(parsed.path):
            return
        self.read_json_body()
        self.not_implemented_yet()

    def log_message(self, format: str, *args: object) -> None:
        print(f"[dev-server] {self.address_string()} - {format % args}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Finwealth local dev server skeleton.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8788, type=int)
    args = parser.parse_args()

    if args.host not in {"127.0.0.1", "localhost"}:
        raise SystemExit("Refusing to bind dev server to a non-localhost address.")

    server = ThreadingHTTPServer((args.host, args.port), DevServerHandler)
    print(f"Finwealth dev server listening on http://{args.host}:{args.port}")
    print("No persistence, no real auth, no real AI, no real quotes, no sync side effects.")
    server.serve_forever()


if __name__ == "__main__":
    main()

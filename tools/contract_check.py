"""Contract checks for finwealth.

This script is intentionally read-only. It verifies that the Markdown contract
index, HTTP API Markdown, and OpenAPI draft stay aligned enough for parallel
frontend/backend work.
"""

from __future__ import annotations

import re
import sys
import json
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "docs" / "contracts"
README = CONTRACTS / "README.md"
HTTP_MD = CONTRACTS / "HTTP_API_V1.md"
OPENAPI = CONTRACTS / "openapi_v1.yaml"
EXAMPLES = CONTRACTS / "examples"
MOCK_SERVER = ROOT / "tools" / "mock_api_server.py"
DEV_SERVER = ROOT / "server" / "dev_server.py"
RUST_SERVER = ROOT / "server-rs" / "src" / "main.rs"
RUST_MANIFEST = ROOT / "server-rs" / "Cargo.toml"
SERVER_SMOKE = ROOT / "tools" / "server_smoke.py"
DEPLOY_ENV_EXAMPLE = ROOT / "deploy" / "finwealth-server.env.example"
SYSTEMD_SERVICE = ROOT / "deploy" / "systemd" / "finwealth-server.service"

FORBIDDEN_ENDPOINTS = {
    "/transfers/execute",
    "/broker/orders",
    "/broker/buy",
    "/broker/sell",
    "/ai/auto-approve",
    "/ai/write-ledger-directly",
    "/coupons/plan",
}

HTTP_METHODS = {"GET", "POST", "PATCH", "PUT", "DELETE"}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def warn(message: str) -> None:
    print(f"WARN: {message}")


def ok(message: str) -> None:
    print(f"OK: {message}")


def load_openapi() -> dict:
    try:
        import yaml  # type: ignore
    except Exception as exc:  # pragma: no cover - environment-dependent
        fail(f"PyYAML is required to parse {OPENAPI}: {exc}")

    try:
        with OPENAPI.open("r", encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
    except Exception as exc:
        fail(f"Unable to parse {OPENAPI}: {exc}")

    if not isinstance(doc, dict):
        fail(f"{OPENAPI} did not parse to a mapping")
    if doc.get("openapi") != "3.1.0":
        fail("OpenAPI version must be 3.1.0")
    if not isinstance(doc.get("paths"), dict):
        fail("OpenAPI document must contain a paths object")
    if not isinstance(doc.get("components", {}).get("schemas"), dict):
        fail("OpenAPI document must contain components.schemas")
    return doc


def indexed_contract_files() -> list[Path]:
    text = README.read_text(encoding="utf-8")
    names = sorted(set(re.findall(r"`([^`]+\.(?:md|yaml))`", text)))
    names = [name for name in names if name != "API_CONTRACT_V1.md"]
    return [CONTRACTS / name for name in names]


def top_level_contract_files() -> list[Path]:
    return sorted(
        path
        for path in CONTRACTS.iterdir()
        if path.is_file() and path.suffix in {".md", ".yaml"}
    )


def extract_http_markdown_endpoints() -> set[str]:
    text = HTTP_MD.read_text(encoding="utf-8")
    allowed_text = text.split("## 13. 明确禁止的 HTTP 端点", maxsplit=1)[0]
    endpoints: set[str] = set()

    for line in allowed_text.splitlines():
        stripped = line.strip()
        match = re.match(r"^(GET|POST|PATCH|PUT|DELETE)\s+(/v1/[^\s?]+)", stripped)
        if not match:
            continue
        method, path = match.groups()
        if method not in HTTP_METHODS:
            continue
        endpoints.add(path.removeprefix("/v1"))
    return endpoints


def load_json(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"Unable to parse JSON example {path}: {exc}")


def require_path(obj: object, path: str) -> object:
    current = obj
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
            continue
        fail(f"JSON example missing path `{path}`")
    return current


def check_examples() -> None:
    if not EXAMPLES.exists():
        fail(f"Missing examples directory: {EXAMPLES}")

    example_paths = sorted(EXAMPLES.glob("*.json"))
    if not example_paths:
        fail("No JSON examples found")

    examples = {path.name: load_json(path) for path in example_paths}
    ok(f"JSON examples parsed: {len(examples)}")

    for name, payload in examples.items():
        if "fixture" in json.dumps(payload, ensure_ascii=False).lower():
            fail(f"Example {name} must not be labelled as fixture seed")

    empty_bootstrap = examples.get("ledger_bootstrap_empty.response.json")
    if empty_bootstrap is None:
        fail("Missing ledger_bootstrap_empty.response.json")
    accounts = require_path(empty_bootstrap, "data.accounts")
    if accounts != []:
        fail("Empty bootstrap must not contain accounts")
    capabilities = require_path(empty_bootstrap, "data.capabilities")
    if capabilities.get("canWriteConfirmedLedger") is not False:
        fail("Empty bootstrap capabilities must not claim confirmed-ledger writes")
    if capabilities.get("proposalPersistence") != "memory":
        fail("Empty bootstrap capabilities must declare memory proposal persistence")

    ai_diff = examples.get("ai_modify_movement_diff.response.json")
    if ai_diff is None:
        fail("Missing ai_modify_movement_diff.response.json")
    groups = require_path(ai_diff, "data.atomicGroups")
    if not isinstance(groups, list) or not groups:
        fail("AI diff example must contain at least one atomic group")
    diffs = groups[0].get("diffs") if isinstance(groups[0], dict) else None
    if not diffs:
        fail("AI modify example must contain old -> new diffs")

    dca = examples.get("dca_mark_executed_proposal.response.json")
    if dca is None:
        fail("Missing dca_mark_executed_proposal.response.json")
    dca_text = json.dumps(dca, ensure_ascii=False)
    if (
        "不下单" not in dca_text
        or "不转账" not in dca_text
        or "确认前不影响正式账本" not in dca_text
    ):
        fail("DCA example must state no order, no transfer, and no confirmed-ledger effect before confirmation")
    proposed = require_path(dca, "data.proposedMovements")
    if not isinstance(proposed, list) or not proposed:
        fail("DCA example must create a proposed movement")
    if proposed[0].get("status") != "pending_review":
        fail("DCA proposed movement must be pending_review")

    quote = examples.get("quote_refresh_stale.response.json")
    if quote is None:
        fail("Missing quote_refresh_stale.response.json")
    statuses = {
        item.get("status")
        for item in require_path(quote, "data.quotes")
        if isinstance(item, dict)
    }
    fx_statuses = {
        item.get("status")
        for item in require_path(quote, "data.fxRates")
        if isinstance(item, dict)
    }
    if "stale" not in statuses:
        fail("Quote example must include stale quote")
    if "offline_cached" not in fx_statuses:
        fail("Quote example must include offline_cached FX rate")

    ok("Example invariants passed")


def check_mock_server() -> None:
    if not MOCK_SERVER.exists():
        fail(f"Missing mock API server: {MOCK_SERVER}")

    text = MOCK_SERVER.read_text(encoding="utf-8")
    required_snippets = [
        'default="127.0.0.1"',
        "Refusing to bind mock API server to a non-localhost address.",
        "FORBIDDEN_PATHS",
        "X-Finwealth-Mock",
        "read_example",
        '"/v1/holdings"',
        '"/v1/movements/recent"',
        '"ledgerWrite": False',
    ]
    missing = [snippet for snippet in required_snippets if snippet not in text]
    if missing:
        fail("Mock API server missing required safety snippets: " + ", ".join(missing))

    for endpoint in FORBIDDEN_ENDPOINTS:
        full_endpoint = f"/v1{endpoint}"
        if f'"{full_endpoint}"' not in text:
            fail(f"Mock API server does not explicitly list forbidden endpoint {full_endpoint}")

    ok("Mock API server safety checks passed")


def check_dev_server() -> None:
    if not DEV_SERVER.exists():
        fail(f"Missing dev server skeleton: {DEV_SERVER}")

    text = DEV_SERVER.read_text(encoding="utf-8")
    required_snippets = [
        'default="127.0.0.1"',
        "Refusing to bind dev server to a non-localhost address.",
        "FORBIDDEN_PATHS",
        "dev_access_token_not_for_production",
        "No persistence, no real auth, no real AI, no real quotes, no sync side effects.",
        '"/v1/holdings"',
        '"/v1/movements/recent"',
        '"ledgerWrite": False',
    ]
    missing = [snippet for snippet in required_snippets if snippet not in text]
    if missing:
        fail("Dev server missing required safety snippets: " + ", ".join(missing))

    for endpoint in FORBIDDEN_ENDPOINTS:
        full_endpoint = f"/v1{endpoint}"
        if f'"{full_endpoint}"' not in text:
            fail(f"Dev server does not explicitly list forbidden endpoint {full_endpoint}")

    ok("Dev server safety checks passed")


def check_rust_server() -> None:
    if not RUST_SERVER.exists():
        fail(f"Missing Rust server skeleton: {RUST_SERVER}")
    if not RUST_MANIFEST.exists():
        fail(f"Missing Rust server manifest: {RUST_MANIFEST}")

    text = RUST_SERVER.read_text(encoding="utf-8")
    manifest = RUST_MANIFEST.read_text(encoding="utf-8")
    required_snippets = [
        "refusing to bind Rust server to a non-localhost address",
        "forbidden_product_boundary",
        "include_str!",
        "/v1/dca/reminders/{reminder_id}/mark-executed-as-proposal",
        "random_token(if dev_mode",
        '"dev_access_"',
        '"dev_refresh_"',
        "refreshTokenHash",
        "accessTokenHash",
        "token_hash(&refresh_token)",
        "token_hash(&access_token)",
        "revoke_access_token",
        "ledger_scenario_forbidden",
        "host_header_forbidden",
        "FINWEALTH_ALLOWED_HOSTS",
        "validate_auth_config",
        "FINWEALTH_REQUIRE_AUTH=true requires FINWEALTH_AUTH_USERNAME",
        "FINWEALTH_REQUIRE_AUTH=true requires FINWEALTH_AUTH_PASSWORD_HASH",
        "plaintext fallback is not allowed when FINWEALTH_REQUIRE_AUTH=true",
    ]
    missing = [snippet for snippet in required_snippets if snippet not in text]
    if missing:
        fail("Rust server missing required safety snippets: " + ", ".join(missing))

    if "dev_access_token_not_for_production" in text:
        fail("Rust server must not use the old fixed dev access token")

    local_ledger_text = (ROOT / "server-rs" / "src" / "local_ledger.rs").read_text(
        encoding="utf-8"
    )
    ledger_lock_snippets = [
        "LEDGER_WRITE_LOCKS",
        "with_ledger_write_lock",
        "normalized_lock_path",
        "syncChanges",
        "list_sync_changes",
        "ack_sync_changes",
        "ingest_sync_push",
        "append_sync_change",
        "sync_operation_for_movement",
    ]
    missing_lock_snippets = [
        snippet for snippet in ledger_lock_snippets if snippet not in local_ledger_text
    ]
    if missing_lock_snippets:
        fail(
            "Rust local ledger missing write-serialization snippets: "
            + ", ".join(missing_lock_snippets)
        )

    if 'axum = "0.8"' not in manifest:
        fail("Rust server must use the expected Axum dependency line")

    for endpoint in FORBIDDEN_ENDPOINTS:
        full_endpoint = f"/v1{endpoint}"
        if f'"{full_endpoint}"' not in text:
            fail(f"Rust server does not explicitly list forbidden endpoint {full_endpoint}")

    ok("Rust server safety checks passed")


def check_server_smoke() -> None:
    if not SERVER_SMOKE.exists():
        fail(f"Missing server smoke script: {SERVER_SMOKE}")

    text = SERVER_SMOKE.read_text(encoding="utf-8")
    required_snippets = [
        "tools/mock_api_server.py",
        "server/dev_server.py",
        "server-rs/Cargo.toml",
        "/v1/broker/orders",
        "forbidden_product_boundary",
        "pending_review",
        "offline_cached",
    ]
    missing = [snippet for snippet in required_snippets if snippet not in text]
    if missing:
        fail("Server smoke script missing required checks: " + ", ".join(missing))

    ok("Server smoke script checks passed")


def check_deploy_security_defaults() -> None:
    if not DEPLOY_ENV_EXAMPLE.exists():
        fail(f"Missing deploy env example: {DEPLOY_ENV_EXAMPLE}")
    if not SYSTEMD_SERVICE.exists():
        fail(f"Missing systemd service: {SYSTEMD_SERVICE}")

    env_text = DEPLOY_ENV_EXAMPLE.read_text(encoding="utf-8")
    if "FINWEALTH_QUOTE_PROVIDER=none" not in env_text:
        fail("Deploy env example must default FINWEALTH_QUOTE_PROVIDER to none")

    service_text = SYSTEMD_SERVICE.read_text(encoding="utf-8")
    required_snippets = [
        "UMask=0077",
        "StateDirectory=finwealth",
        "StateDirectoryMode=0700",
        "NoNewPrivileges=true",
        "CapabilityBoundingSet=",
        "PrivateDevices=true",
        "ProtectSystem=strict",
        "RestrictSUIDSGID=true",
    ]
    missing = [snippet for snippet in required_snippets if snippet not in service_text]
    if missing:
        fail("Systemd service missing hardening snippets: " + ", ".join(missing))

    ok("Deploy security defaults passed")


def missing_items(items: Iterable[Path]) -> list[Path]:
    return [item for item in items if not item.exists()]


def main() -> None:
    for required in (README, HTTP_MD, OPENAPI):
        if not required.exists():
            fail(f"Missing required contract file: {required}")

    doc = load_openapi()
    paths = set(doc["paths"].keys())
    schemas = set(doc["components"]["schemas"].keys())
    ok(f"OpenAPI parsed: {len(paths)} paths, {len(schemas)} schemas")

    missing_indexed = missing_items(indexed_contract_files())
    if missing_indexed:
        fail("README references missing contract files: " + ", ".join(map(str, missing_indexed)))
    ok("README contract file references exist")

    indexed = {path.resolve() for path in indexed_contract_files()}
    missing_from_index = [
        path for path in top_level_contract_files()
        if path.resolve() not in indexed and path.name != "README.md"
    ]
    if missing_from_index:
        fail("Top-level contract files missing from README index: " + ", ".join(path.name for path in missing_from_index))
    ok("README indexes all top-level contract files")

    forbidden_present = sorted(path for path in paths if path in FORBIDDEN_ENDPOINTS)
    if forbidden_present:
        fail("Forbidden endpoints exist in OpenAPI: " + ", ".join(forbidden_present))
    ok("OpenAPI contains no forbidden endpoints")

    http_md_paths = extract_http_markdown_endpoints()
    missing_from_openapi = sorted(http_md_paths - paths)
    if missing_from_openapi:
        fail("HTTP_API_V1.md endpoints missing from OpenAPI: " + ", ".join(missing_from_openapi))
    ok(f"HTTP_API_V1.md endpoints covered by OpenAPI: {len(http_md_paths)}")

    if "/dca/reminders/{reminderId}/mark-executed-as-proposal" not in paths:
        fail("DCA executed flow must create a proposal endpoint")
    if "/ai/atomic-groups/{atomicGroupId}/approve" not in paths:
        fail("AI approval endpoint must remain atomic-group based")
    if "/holdings" not in paths:
        fail("OpenAPI must document the local-server holdings alias /holdings")
    if "/movements/recent" not in paths:
        fail("OpenAPI must document the local-server recent movements alias /movements/recent")
    if "AiFieldDiff" not in schemas:
        fail("OpenAPI must expose AiFieldDiff for old -> new review")
    confirm_result = doc["components"]["schemas"].get("ConfirmResult", {})
    confirm_required = set(confirm_result.get("required", []))
    if "ledgerWrite" not in confirm_required:
        fail("ConfirmResult must require ledgerWrite so clients do not guess write semantics")
    categories_post_schema = doc["paths"]["/categories"]["post"]["requestBody"]["content"]["application/json"]["schema"].get("$ref")
    if categories_post_schema != "#/components/schemas/CreateCategoryInput":
        fail("POST /categories must use CreateCategoryInput, not the response Category schema")
    counterparties_post_schema = doc["paths"]["/counterparties"]["post"]["requestBody"]["content"]["application/json"]["schema"].get("$ref")
    if counterparties_post_schema != "#/components/schemas/CreateCounterpartyInput":
        fail("POST /counterparties must use CreateCounterpartyInput, not the response Counterparty schema")
    ok("Critical AI/DCA invariants are represented")

    check_examples()
    check_mock_server()
    check_dev_server()
    check_rust_server()
    check_server_smoke()
    check_deploy_security_defaults()

    if not forbidden_present and not missing_from_openapi:
        ok("Contract check passed")


if __name__ == "__main__":
    main()

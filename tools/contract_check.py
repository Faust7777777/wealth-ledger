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
LOCAL_LEDGER_FORMAT = CONTRACTS / "LOCAL_LEDGER_FORMAT_V1.md"
EXAMPLES = CONTRACTS / "examples"
MOCK_SERVER = ROOT / "tools" / "mock_api_server.py"
DEV_SERVER = ROOT / "server" / "dev_server.py"
RUST_SERVER = ROOT / "server-rs" / "src" / "main.rs"
RUST_LOCAL_LEDGER = ROOT / "server-rs" / "src" / "local_ledger.rs"
RUST_LEDGER_MIGRATIONS = ROOT / "server-rs" / "src" / "ledger_migrations.rs"
RUST_LEDGER_LEASE = ROOT / "server-rs" / "src" / "ledger_lease.rs"
RUST_MANIFEST = ROOT / "server-rs" / "Cargo.toml"
RUST_SERVER_README = ROOT / "server-rs" / "README.md"
SERVER_SMOKE = ROOT / "tools" / "server_smoke.py"
LOCAL_LEDGER_SMOKE = ROOT / "tools" / "local_ledger_smoke.py"
PRODUCTION_TOPOLOGY_SMOKE = ROOT / "tools" / "production_topology_smoke.py"
FRONTEND_LOCAL_SERVER_SMOKE = ROOT / "tools" / "frontend_local_server_smoke.ps1"
LOCAL_SERVER_SUBSCRIPTION_TEST = (
    ROOT / "test" / "local_server_subscription_integration_test.dart"
)
PYTHON_REQUIREMENTS = ROOT / "tools" / "requirements.txt"
DEPLOY_ENV_EXAMPLE = ROOT / "deploy" / "finwealth-server.env.example"
SYSTEMD_SERVICE = ROOT / "deploy" / "systemd" / "finwealth-server.service"
SYSTEMD_DOCKER_PROXY_SOCKET = (
    ROOT / "deploy" / "systemd" / "finwealth-docker-proxy@.socket"
)
SYSTEMD_DOCKER_PROXY_SERVICE = (
    ROOT / "deploy" / "systemd" / "finwealth-docker-proxy@.service"
)
CADDY_FINWEALTH_SITE = ROOT / "deploy" / "caddy" / "finwealth-wuwaidut.com.caddy"
VPS_INSTALL = ROOT / "tools" / "install_vps_systemd.sh"
VPS_BUNDLE_INSTALL = ROOT / "tools" / "install_vps_bundle.sh"
VPS_PACKAGE = ROOT / "tools" / "package_vps_server.sh"
VPS_AUTH_CONFIGURE = ROOT / "tools" / "configure_vps_auth.sh"
VPS_READINESS = ROOT / "tools" / "check_vps_readiness.sh"
VPS_BACKUP = ROOT / "tools" / "backup_vps_ledger.sh"
VPS_RESTORE = ROOT / "tools" / "restore_vps_ledger.sh"
VPS_BACKUP_RESTORE_SMOKE = ROOT / "tools" / "vps_backup_restore_smoke.sh"
LOCAL_BACKUP = ROOT / "tools" / "backup_local_ledger.ps1"
LOCAL_RESTORE = ROOT / "tools" / "restore_local_ledger.ps1"
LOCAL_BACKUP_RESTORE_SMOKE = ROOT / "tools" / "local_backup_restore_smoke.ps1"
PACKAGE_SCRIPT = ROOT / "tools" / "package_release.ps1"
PACKAGE_INTEGRITY_SMOKE = ROOT / "tools" / "package_integrity_smoke.ps1"
WINDOWS_LAUNCHER = ROOT / "tools" / "windows_self_use_launcher.ps1"
WINDOWS_LAUNCHER_CMD = ROOT / "tools" / "windows_self_use_launcher.cmd"
WINDOWS_PACKAGE_DOC = ROOT / "docs" / "deploy" / "WINDOWS_SELF_USE_PACKAGE.md"
REMOTE_PACKAGE_SCRIPT = ROOT / "tools" / "package_remote_windows.ps1"
REMOTE_WINDOWS_LAUNCHER = ROOT / "tools" / "windows_remote_launcher.ps1"
REMOTE_WINDOWS_LAUNCHER_CMD = ROOT / "tools" / "windows_remote_launcher.cmd"
REMOTE_WINDOWS_PACKAGE_DOC = ROOT / "docs" / "deploy" / "WINDOWS_SERVER_CLIENT_PACKAGE.md"
REMOTE_ANDROID_PACKAGE_SCRIPT = ROOT / "tools" / "package_remote_android.ps1"
REMOTE_ANDROID_PACKAGE_DOC = ROOT / "docs" / "deploy" / "ANDROID_SERVER_CLIENT_PACKAGE.md"
ANDROID_MANIFEST = ROOT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
SERVER_MODE_ALGORITHMS = CONTRACTS / "SERVER_MODE_ALGORITHMS_V1.md"
PACKAGE_WORKFLOW = ROOT / ".github" / "workflows" / "package.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
GITIGNORE = ROOT / ".gitignore"
GITATTRIBUTES = ROOT / ".gitattributes"

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
LEDGER_WRITE_METHODS = {"post", "patch", "put", "delete"}


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
    if require_path(empty_bootstrap, "data.syncCursor") != "local_cursor_0000":
        fail("Empty bootstrap must use the local sync genesis cursor")

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
        fail(f"Missing Rust server implementation: {RUST_SERVER}")
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
        "ConstantTimeEq",
        "token_hash_eq",
        "device_id_for_access_token",
        "AuthenticatedDevice",
        "DEV_UNAUTHENTICATED_DEVICE_ID",
        '"--validate-auth-state"',
        "parse_auth_state_timestamp",
        "parse_movement_list_query",
        "invalid_movement_query",
        "parse_optional_snapshot_range",
        "invalid_snapshot_range",
    ]
    missing = [snippet for snippet in required_snippets if snippet not in text]
    if missing:
        fail("Rust server missing required safety snippets: " + ", ".join(missing))

    if "dev_access_token_not_for_production" in text:
        fail("Rust server must not use the old fixed dev access token")

    local_ledger_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    ledger_lock_snippets = [
        "LEDGER_WRITE_LOCKS",
        "with_ledger_write_lock",
        "normalized_lock_path",
        "syncChanges",
        "list_sync_changes",
        "ack_sync_changes",
        "ingest_sync_push",
        "validate_inbound_account_payload",
        "account_create_sync_conflict",
        '"appliedChangeIds"',
        "append_sync_change",
        "sync_operation_for_movement",
        "LOCAL_SYNC_GENESIS_CURSOR",
        "stored_sequence.max(fallback_sequence)",
        "idempotencyState",
        "idempotent_ledger_write",
        "IdempotencyKeyReused",
        "IDEMPOTENCY_MAX_RECORDS",
        "recover_unpublished_document",
        "temporary.sync_all()",
        "sync_parent_directory",
        "recovery temp is invalid",
        "subscription patch must contain at least one field",
        "duration and endDate are mutually exclusive",
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


def check_ledger_migration_boundary() -> None:
    if not RUST_LEDGER_MIGRATIONS.exists():
        fail(f"Missing Rust ledger migration registry: {RUST_LEDGER_MIGRATIONS}")

    rust_text = RUST_SERVER.read_text(encoding="utf-8")
    local_ledger_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    migration_text = RUST_LEDGER_MIGRATIONS.read_text(encoding="utf-8")

    if "mod ledger_migrations;" not in rust_text:
        fail("Rust server must compile the ledger_migrations module")
    if "local_ledger::validate_supported_ledger(&path)?" not in rust_text:
        fail("--validate-ledger must use the supported-version read-only validator")
    if "pub const LEDGER_VERSION: i64 = 1;" not in local_ledger_text:
        fail("This slice must keep the persisted ledgerVersion at 1")

    migration_snippets = [
        "pub(crate) type MigrationApply",
        "pub(crate) struct MigrationSpec",
        "pub(crate) const MIGRATION_REGISTRY",
        "pub(crate) fn validate_registry(",
        "pub(crate) fn plan_migrations(",
        "pub(crate) fn validate_history(",
        "pub(crate) fn apply_migration_plan(",
        "pub(crate) fn migrate_document(",
        '"id": migration.id',
        '"fromVersion": migration.from',
        '"toVersion": migration.to',
        '"appliedAt": applied_at',
        "duplicate migration id",
        "migration fork at version",
        "migration registry gap between versions",
    ]
    missing = [
        snippet for snippet in migration_snippets if snippet not in migration_text
    ]
    if missing:
        fail("Rust migration registry skeleton is incomplete: " + ", ".join(missing))

    empty_registry = re.search(
        r"pub\(crate\)\s+const\s+MIGRATION_REGISTRY\s*:\s*"
        r"&\s*\[\s*MigrationSpec\s*\]\s*=\s*&\s*\[\s*\]\s*;",
        migration_text,
        flags=re.DOTALL,
    )
    if empty_registry is None:
        fail("Current ledgerVersion 1 slice must keep MIGRATION_REGISTRY empty")

    compatibility_signature = "fn apply_v1_read_compatibility(document: &mut Value)"
    compatibility_start = local_ledger_text.find(compatibility_signature)
    compatibility_end = local_ledger_text.find(
        "\n#[derive(Debug)]", compatibility_start
    )
    if compatibility_start < 0 or compatibility_end < 0:
        fail("Rust local ledger must keep an explicit v1 read-compatibility function")
    compatibility_text = local_ledger_text[compatibility_start:compatibility_end]

    compatible_top_level_fields = (
        "subscriptions",
        "syncChanges",
        "idempotencyState",
    )
    for field in compatible_top_level_fields:
        if re.search(rf'\.entry\s*\(\s*"{field}"', compatibility_text) is None:
            fail(f"V1 read compatibility must preserve the missing-{field} default")
    if re.search(
        r'\.get_mut\s*\(\s*"syncState"\s*\)', compatibility_text
    ) is None:
        fail("V1 read compatibility must inspect an existing syncState object")
    if re.search(
        r'\.entry\s*\(\s*"nextChangeSequence"', compatibility_text
    ) is None:
        fail("V1 read compatibility may default existing syncState.nextChangeSequence")

    forbidden_sync_rebuilds = ("syncState", "cursor", "pendingChangeIds")
    for field in forbidden_sync_rebuilds:
        if re.search(rf'\.entry\s*\(\s*"{field}"', compatibility_text):
            fail(
                "V1 read compatibility must fail closed instead of rebuilding "
                f"{field}"
            )

    if local_ledger_text.count("prepare_document_for_read(&mut document") < 2:
        fail("Primary and recovery ledger reads must share version-aware read rules")
    for snippet in (
        "LedgerReadPolicy::Current",
        "LedgerReadPolicy::SupportedForValidation",
        "plan_migrations(MIGRATION_REGISTRY, version, LEDGER_VERSION)",
        "1 => apply_v1_read_compatibility(document)",
        "validate_document_for_version(document, version)",
    ):
        if snippet not in local_ledger_text:
            fail(f"Rust version-aware ledger reads are missing: {snippet}")
    read_start = local_ledger_text.find("pub fn read_document(path: &Path)")
    read_end = local_ledger_text.find("\npub fn write_document(", read_start)
    if read_start < 0 or read_end < 0:
        fail("Unable to inspect the Rust local-ledger read boundary")
    read_text = local_ledger_text[read_start:read_end]
    if "write_document(" in read_text or "migrate_document(" in read_text:
        fail("Ordinary ledger reads must not migrate or rewrite the on-disk document")
    if "load_or_initialize(path)?" in local_ledger_text:
        fail("Request-time ledger operations must not recreate a missing primary ledger")

    compatibility_test_snippets = [
        "read_document_applies_narrow_v1_compatibility_without_rewriting",
        "read_document_fails_closed_when_required_sync_state_is_missing",
        "read_document_rejects_invalid_or_unsupported_versions_without_rewriting",
        "runtime_reads_and_writes_do_not_recreate_a_missing_primary_ledger",
        "ordinary reads must not rewrite compatibility fields or migration history",
    ]
    missing = [
        snippet
        for snippet in compatibility_test_snippets
        if snippet not in local_ledger_text
    ]
    if missing:
        fail("Rust v1 compatibility regression coverage is incomplete: " + ", ".join(missing))

    ok("Ledger migration registry and fail-closed v1 read compatibility passed")


def check_ledger_lease_boundary() -> None:
    if not RUST_LEDGER_LEASE.exists():
        fail(f"Missing Rust local-ledger lease module: {RUST_LEDGER_LEASE}")

    rust_text = RUST_SERVER.read_text(encoding="utf-8")
    lease_text = RUST_LEDGER_LEASE.read_text(encoding="utf-8")
    manifest = RUST_MANIFEST.read_text(encoding="utf-8")
    ledger_format_text = LOCAL_LEDGER_FORMAT.read_text(encoding="utf-8")
    server_readme_text = RUST_SERVER_README.read_text(encoding="utf-8")

    rust_version_match = re.search(
        r'^rust-version\s*=\s*"(\d+)\.(\d+)(?:\.(\d+))?"\s*$',
        manifest,
        flags=re.MULTILINE,
    )
    if rust_version_match is None:
        fail("Rust server manifest must declare rust-version for file locking")
    rust_version = tuple(
        int(part or 0) for part in rust_version_match.groups(default="0")
    )
    if rust_version < (1, 89, 0):
        fail("Rust standard-library ledger locking requires rust-version >= 1.89")

    main_snippets = [
        "mod ledger_lease;",
        "_ledger_lease: Option<Arc<ledger_lease::LedgerLease>>",
        "fn local_with_lease(path: PathBuf, lease: Arc<ledger_lease::LedgerLease>)",
        "Self::local_state(path, Some(lease))",
        "_ledger_lease: lease",
        "let auth_state_path = default_auth_state_path(&path);",
        "AuthStore::from_env_or_dev_with_default_state_path(Some(auth_state_path))",
        "ledger_lease::acquire_ledger_lease(&requested_path)",
        "AppState::local_with_lease(path, Arc::new(lease))",
    ]
    missing = [snippet for snippet in main_snippets if snippet not in rust_text]
    if missing:
        fail("Rust server does not retain the ledger lease for AppState: " + ", ".join(missing))

    startup_start = rust_text.find("let state = read_ledger_path(env::args())")
    startup_end = rust_text.find("let local_ledger_enabled", startup_start)
    if startup_start < 0 or startup_end < 0:
        fail("Unable to inspect real-local server startup ordering")
    startup_text = rust_text[startup_start:startup_end]
    startup_steps = (
        "ledger_lease::acquire_ledger_lease(&requested_path)",
        "local_ledger::load_or_initialize(&path)",
        "AppState::local_with_lease(path, Arc::new(lease))",
    )
    positions = [startup_text.find(step) for step in startup_steps]
    if any(position < 0 for position in positions) or positions != sorted(positions):
        fail("Server must acquire the lease before opening ledger and sibling auth state")

    lease_snippets = [
        "pub(crate) const DEFAULT_LEDGER_LEASE_TIMEOUT: Duration = Duration::from_secs(3);",
        "pub(crate) struct LedgerLease",
        "_file: File",
        "pub(crate) fn acquire_ledger_lease(",
        "pub(crate) fn acquire_ledger_lease_with_timeout(",
        "pub(crate) fn normalized_ledger_path(",
        "file.try_lock()",
        'lock_path.push(".lock")',
        "ledger is already in use",
        "regular non-symlink file",
        "default_timeout_is_three_seconds",
        "different_ledgers_can_be_leased_concurrently",
        "non_file_sidecar_is_rejected_fail_closed",
        "second_handle_times_out_while_first_lease_is_held",
        "drop_releases_lock_immediately_and_preserves_sidecar",
        "relative_parent_alias_conflicts_with_absolute_path",
    ]
    combined_lease_text = lease_text + "\n" + rust_text
    missing = [
        snippet for snippet in lease_snippets if snippet not in combined_lease_text
    ]
    if missing:
        fail("Rust ledger lease boundary is incomplete: " + ", ".join(missing))
    if "remove_file" in lease_text:
        fail("Ledger lease implementation must preserve the permanent .lock sidecar")

    ledger_format_snippets = [
        "ledger.json.lock",
        "Arc<LedgerLease>",
        "默认最多等待 3 秒",
        "active-active",
        "最低 Rust 版本必须为 1.89",
    ]
    missing = [
        snippet for snippet in ledger_format_snippets if snippet not in ledger_format_text
    ]
    if missing:
        fail("Local-ledger format must document the process lease: " + ", ".join(missing))
    server_readme_snippets = [
        "ledger.json.lock",
        "ledger is already in use",
        "three seconds",
        "active-active",
        "Rust 1.89",
    ]
    missing = [
        snippet for snippet in server_readme_snippets if snippet not in server_readme_text
    ]
    if missing:
        fail("Rust server README must document the process lease: " + ", ".join(missing))

    ok("Cross-process service-lifetime ledger lease checks passed")


def check_dca_execution_input(doc: dict) -> None:
    schemas = doc["components"]["schemas"]
    execution = schemas.get("DcaExecutionInput", {})
    required = {"holdingAccountId", "quantity", "totalCost", "quoteCurrency"}
    if execution.get("type") != "object":
        fail("DcaExecutionInput must be an object")
    if execution.get("additionalProperties") is not False:
        fail("DcaExecutionInput must reject undocumented fields")
    if set(execution.get("required", [])) != required:
        fail("DcaExecutionInput required fields drifted")
    properties = execution.get("properties", {})
    if set(properties) != required | {"executedAt"}:
        fail("DcaExecutionInput properties drifted")

    operation = doc["paths"]["/dca/reminders/{reminderId}/mark-executed-as-proposal"][
        "post"
    ]
    request_body = operation.get("requestBody", {})
    if request_body.get("required") is not True:
        fail("DCA mark-executed request body must be required")
    schema = (
        request_body.get("content", {})
        .get("application/json", {})
        .get("schema", {})
    )
    if schema.get("$ref") != "#/components/schemas/DcaExecutionInput":
        fail("DCA mark-executed must use DcaExecutionInput")

    rust_text = RUST_SERVER.read_text(encoding="utf-8")
    for snippet in [
        "body: Option<Json<Value>>",
        "idempotency_request(&headers, &operation, &input, &now)",
        "local_ledger::mark_dca_executed_as_proposal(",
    ]:
        if snippet not in rust_text:
            fail(f"Rust DCA execution handler is incomplete: {snippet}")

    local_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    for snippet in [
        '"holdingAccountId" | "quantity" | "totalCost" | "quoteCurrency" | "executedAt"',
        '"quantity must be a positive decimal string"',
        '"totalCost.amount must be a positive decimal string"',
        'Some("holdings" | "mixed")',
        '"DCA reminder already has a pending execution proposal',
        '"amount": total_cost_amount',
        '"amount": quantity',
        "validate_dca_entities(document, &mut errors)",
        '"duplicate DCA plan id:',
        '"DCA plan has more than one open reminder:',
        '"recorded DCA reminder must reference exactly one confirmed movement:',
    ]:
        if snippet not in local_text:
            fail(f"Rust DCA execution implementation is incomplete: {snippet}")

    smoke_text = LOCAL_LEDGER_SMOKE.read_text(encoding="utf-8")
    for snippet in [
        '"holdingAccountId": holding_account_id',
        '"quantity": "4"',
        'holding["costBasisTotal"]["amount"] == "100.00"',
    ]:
        if snippet not in smoke_text:
            fail(f"Local-ledger smoke must verify real DCA execution semantics: {snippet}")

    ok("DCA real-execution contract and implementation checks passed")


def check_investment_fee_semantics(doc: dict) -> None:
    local_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    for snippet in [
        'Some("fee" | "tax")',
        '"{movement_type} fee/tax entries must use the principal cash account and currency"',
        '"sell fee/tax total must not exceed gross proceeds"',
        "let total_cash_out = cash_amount + fee_total;",
        "cash_amount - fee_total",
        "cost_amount: total_cash_out",
    ]:
        if snippet not in local_text:
            fail(f"Investment fee/tax implementation is incomplete: {snippet}")

    rust_tests = RUST_SERVER.read_text(encoding="utf-8")
    for snippet in [
        '"role": "fee"',
        '"role": "tax"',
        '"103.00"',
        '"61.80"',
        '"996.80"',
    ]:
        if snippet not in rust_tests:
            fail(f"Investment fee/tax regression coverage is incomplete: {snippet}")

    http_text = HTTP_MD.read_text(encoding="utf-8")
    for snippet in [
        "principal + fee + tax",
        "gross proceeds - fee - tax",
        "费用/税费总额不得超过 gross proceeds",
    ]:
        if snippet not in http_text:
            fail(f"HTTP investment fee/tax contract is incomplete: {snippet}")

    draft_description = doc["components"]["schemas"]["CreateMovementDraftInput"].get(
        "description", ""
    )
    for snippet in [
        "principal cash leg",
        "optional fee/tax cash outflow legs",
        "principal + fee + tax",
        "gross proceeds - fee - tax",
    ]:
        if snippet not in draft_description:
            fail(f"OpenAPI investment fee/tax semantics are incomplete: {snippet}")

    ok("Investment fee/tax accounting checks passed")


def check_subscription_due_scan(doc: dict) -> None:
    path = "/subscriptions/charge-proposals/due-scan"
    path_item = doc["paths"].get(path)
    if not isinstance(path_item, dict):
        fail(f"OpenAPI must document subscription due scan path {path}")

    documented_methods = HTTP_METHODS.intersection(
        method.upper() for method in path_item if isinstance(method, str)
    )
    if documented_methods != {"POST"}:
        fail("Subscription due scan must be documented as POST only")
    operation = path_item.get("post")
    if not isinstance(operation, dict):
        fail("Subscription due scan POST operation is missing")

    request_body = operation.get("requestBody", {})
    if request_body.get("required") is not True:
        fail("Subscription due scan request body must be required")
    request_ref = (
        request_body.get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if request_ref != "#/components/schemas/SubscriptionDueScanRequest":
        fail("Subscription due scan must use SubscriptionDueScanRequest")

    schemas = doc["components"]["schemas"]
    request_schema = schemas.get("SubscriptionDueScanRequest", {})
    request_properties = request_schema.get("properties", {})
    if request_schema.get("type") != "object":
        fail("SubscriptionDueScanRequest must be an object")
    if request_schema.get("additionalProperties") is not False:
        fail("SubscriptionDueScanRequest must reject unknown fields")
    if set(request_schema.get("required", [])) != {"throughDate"}:
        fail("SubscriptionDueScanRequest must require only throughDate")
    if set(request_properties) != {"throughDate", "limit"}:
        fail("SubscriptionDueScanRequest fields must be throughDate and limit")
    if request_properties["throughDate"].get("$ref") != "#/components/schemas/ISODate":
        fail("Subscription due scan throughDate must use ISODate")
    limit_schema = request_properties["limit"]
    expected_limit = {
        "type": "integer",
        "minimum": 1,
        "maximum": 200,
        "default": 100,
    }
    for key, expected in expected_limit.items():
        if limit_schema.get(key) != expected:
            fail(f"Subscription due scan limit must document {key}={expected}")

    response_ref = (
        operation.get("responses", {})
        .get("200", {})
        .get("content", {})
        .get("application/json", {})
        .get("schema", {})
        .get("$ref")
    )
    if response_ref != "#/components/schemas/SubscriptionDueScanResponse":
        fail("Subscription due scan 200 response must use SubscriptionDueScanResponse")
    response_schema = schemas.get("SubscriptionDueScanResponse", {})
    if set(response_schema.get("required", [])) != {"ok", "data"}:
        fail("SubscriptionDueScanResponse must require ok and data")
    response_properties = response_schema.get("properties", {})
    if set(response_properties) != {"ok", "data"}:
        fail("SubscriptionDueScanResponse must expose only ok and data")
    if response_properties.get("ok", {}).get("const") is not True:
        fail("SubscriptionDueScanResponse.ok must be true")
    if (
        response_properties.get("data", {}).get("$ref")
        != "#/components/schemas/SubscriptionDueScanResult"
    ):
        fail("SubscriptionDueScanResponse.data must use SubscriptionDueScanResult")

    result_schema = schemas.get("SubscriptionDueScanResult", {})
    result_fields = {
        "throughDate",
        "createdCount",
        "alreadyPendingCount",
        "blockedCount",
        "remainingEligibleCount",
        "hasMore",
        "created",
        "skipped",
    }
    if result_schema.get("type") != "object":
        fail("SubscriptionDueScanResult must be an object")
    if result_schema.get("additionalProperties") is not False:
        fail("SubscriptionDueScanResult must reject undocumented response fields")
    if set(result_schema.get("required", [])) != result_fields:
        fail("SubscriptionDueScanResult must require all eight response fields")
    result_properties = result_schema.get("properties", {})
    if set(result_properties) != result_fields:
        fail("SubscriptionDueScanResult must expose exactly eight response fields")
    if result_properties["throughDate"].get("$ref") != "#/components/schemas/ISODate":
        fail("SubscriptionDueScanResult.throughDate must use ISODate")
    for field in (
        "createdCount",
        "alreadyPendingCount",
        "blockedCount",
        "remainingEligibleCount",
    ):
        if result_properties[field].get("type") != "integer":
            fail(f"SubscriptionDueScanResult.{field} must be an integer")
        if result_properties[field].get("minimum") != 0:
            fail(f"SubscriptionDueScanResult.{field} must be non-negative")
    if result_properties["hasMore"].get("type") != "boolean":
        fail("SubscriptionDueScanResult.hasMore must be boolean")
    if result_properties["created"].get("type") != "array":
        fail("SubscriptionDueScanResult.created must be an array")
    if (
        result_properties["created"].get("items", {}).get("$ref")
        != "#/components/schemas/SubscriptionDueScanCreated"
    ):
        fail("SubscriptionDueScanResult.created items must use SubscriptionDueScanCreated")
    if result_properties["skipped"].get("type") != "array":
        fail("SubscriptionDueScanResult.skipped must be an array")
    if (
        result_properties["skipped"].get("items", {}).get("$ref")
        != "#/components/schemas/SubscriptionDueScanSkip"
    ):
        fail("SubscriptionDueScanResult.skipped items must use SubscriptionDueScanSkip")

    created_schema = schemas.get("SubscriptionDueScanCreated", {})
    created_all_of = created_schema.get("allOf", [])
    if not any(
        isinstance(part, dict)
        and part.get("$ref") == "#/components/schemas/AiAtomicGroup"
        for part in created_all_of
    ):
        fail("SubscriptionDueScanCreated must extend AiAtomicGroup")
    created_extension = next(
        (
            part
            for part in created_all_of
            if isinstance(part, dict) and part.get("type") == "object"
        ),
        {},
    )
    created_fields = {"subscriptionId", "scheduledChargeDate"}
    if set(created_extension.get("required", [])) != created_fields:
        fail("SubscriptionDueScanCreated must require subscriptionId and scheduledChargeDate")
    created_properties = created_extension.get("properties", {})
    if set(created_properties) != created_fields:
        fail("SubscriptionDueScanCreated must document subscriptionId and scheduledChargeDate")
    if created_properties["subscriptionId"].get("$ref") != "#/components/schemas/ID":
        fail("SubscriptionDueScanCreated.subscriptionId must use ID")
    if (
        created_properties["scheduledChargeDate"].get("$ref")
        != "#/components/schemas/ISODate"
    ):
        fail("SubscriptionDueScanCreated.scheduledChargeDate must use ISODate")

    skip_reason = schemas.get("SubscriptionDueScanSkipReason", {})
    expected_reasons = {
        "already_pending",
        "payment_account_unavailable",
        "payment_currency_unsupported",
    }
    if skip_reason.get("type") != "string" or set(skip_reason.get("enum", [])) != expected_reasons:
        fail("SubscriptionDueScanSkipReason must document all three stable skip reasons")
    skip_schema = schemas.get("SubscriptionDueScanSkip", {})
    skip_fields = {"subscriptionId", "scheduledChargeDate", "reason"}
    if skip_schema.get("type") != "object":
        fail("SubscriptionDueScanSkip must be an object")
    if skip_schema.get("additionalProperties") is not False:
        fail("SubscriptionDueScanSkip must reject undocumented item fields")
    if set(skip_schema.get("required", [])) != skip_fields:
        fail("SubscriptionDueScanSkip must require subscriptionId, scheduledChargeDate, and reason")
    skip_properties = skip_schema.get("properties", {})
    if set(skip_properties) != skip_fields:
        fail("SubscriptionDueScanSkip must expose exactly its three item fields")
    expected_skip_refs = {
        "subscriptionId": "#/components/schemas/ID",
        "scheduledChargeDate": "#/components/schemas/ISODate",
        "reason": "#/components/schemas/SubscriptionDueScanSkipReason",
    }
    for field, expected_ref in expected_skip_refs.items():
        if skip_properties[field].get("$ref") != expected_ref:
            fail(f"SubscriptionDueScanSkip.{field} must use {expected_ref.rsplit('/', 1)[-1]}")

    rust_text = RUST_SERVER.read_text(encoding="utf-8")
    rust_route_snippets = [
        '"/v1/subscriptions/charge-proposals/due-scan"',
        "post(create_due_subscription_charge_proposals)",
        "async fn create_due_subscription_charge_proposals(",
        'let operation = "POST /v1/subscriptions/charge-proposals/due-scan";',
        "local_ledger::create_due_subscription_charge_proposals(",
        'local_ledger_error(error, "invalid_subscription_due_scan")',
    ]
    missing = [snippet for snippet in rust_route_snippets if snippet not in rust_text]
    if missing:
        fail("Rust subscription due scan route/handler is incomplete: " + ", ".join(missing))

    local_ledger_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    implementation_snippets = [
        "pub fn create_due_subscription_charge_proposals<F>(",
        "parse_subscription_due_scan_input(&input)?",
        "idempotent_ledger_write(path, idempotency, 200",
        '"throughDate" | "limit"',
        "Date::parse(value, &Iso8601::DATE).is_ok()",
        "None => Some(100_usize)",
        "Some(value @ 1..=200) => Some(value)",
        'Some("trial" | "active")',
        "date <= through_date.as_str()",
        "left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1))",
        "created.len() >= limit",
        "create_subscription_charge_proposal_in_document(",
        '"throughDate": through_date',
        '"createdCount": created.len()',
        '"alreadyPendingCount": already_pending_count',
        '"blockedCount": blocked_count',
        '"remainingEligibleCount": remaining_eligible_count',
        '"hasMore": remaining_eligible_count > 0',
        '"created": created',
        '"skipped": skipped',
        '"already_pending"',
        '"payment_account_unavailable"',
        '"payment_currency_unsupported"',
    ]
    missing = [
        snippet for snippet in implementation_snippets if snippet not in local_ledger_text
    ]
    if missing:
        fail("Rust subscription due scan implementation is incomplete: " + ", ".join(missing))

    if not LOCAL_LEDGER_SMOKE.exists():
        fail(f"Missing real local-ledger smoke: {LOCAL_LEDGER_SMOKE}")
    smoke_text = LOCAL_LEDGER_SMOKE.read_text(encoding="utf-8")
    smoke_snippets = [
        "def create_and_confirm_due_subscription_charge(",
        '"/v1/subscriptions/charge-proposals/due-scan"',
        "subscription_result = create_and_confirm_due_subscription_charge(",
    ]
    missing = [snippet for snippet in smoke_snippets if snippet not in smoke_text]
    if missing:
        fail("Local-ledger smoke must exercise subscription due scan: " + ", ".join(missing))

    ok("Subscription due-scan contract and implementation checks passed")


def check_multileg_correction(doc: dict) -> None:
    schemas = doc["components"]["schemas"]
    correction = schemas.get("CreateCorrectionInput", {})
    alternatives = {
        tuple(option.get("required", []))
        for option in correction.get("anyOf", [])
        if isinstance(option, dict)
    }
    if alternatives != {("proposedDiffs",), ("replacementEntries",)}:
        fail("CreateCorrectionInput must require proposedDiffs or replacementEntries")
    replacement = correction.get("properties", {}).get("replacementEntries", {})
    if replacement.get("minItems") != 1:
        fail("replacementEntries must be documented as non-empty")
    if replacement.get("items", {}).get("$ref") != "#/components/schemas/MovementEntryInput":
        fail("replacementEntries must use MovementEntryInput")
    entry_input = schemas.get("MovementEntryInput", {})
    if set(entry_input.get("required", [])) != {
        "accountId",
        "amount",
        "currency",
        "direction",
        "role",
    }:
        fail("MovementEntryInput must require the five ledger entry fields")
    if "id" in entry_input.get("properties", {}):
        fail("MovementEntryInput must not accept a persisted entry id")

    local_ledger_text = RUST_LOCAL_LEDGER.read_text(encoding="utf-8")
    required_implementation = [
        "correction_entries_for_replacement(",
        "movement_entry_effects(",
        "pending_correction_exists(",
        '"replacementEntries must change the target movement ledger effect"',
        '"target movement already has a pending correction',
        '"entry_{movement_id}_reversal_{index}"',
    ]
    missing = [item for item in required_implementation if item not in local_ledger_text]
    if missing:
        fail("Rust multi-leg correction implementation is incomplete: " + ", ".join(missing))

    smoke_text = LOCAL_LEDGER_SMOKE.read_text(encoding="utf-8")
    required_smoke = [
        "def create_and_confirm_multileg_correction(",
        '"replacementEntries": [',
        "create_and_confirm_multileg_correction(base, cash[\"id\"], reserve[\"id\"])",
    ]
    missing = [item for item in required_smoke if item not in smoke_text]
    if missing:
        fail("Real-local smoke must exercise multi-leg correction: " + ", ".join(missing))

    http_text = HTTP_MD.read_text(encoding="utf-8")
    if "完整 `replacementEntries` 更正多腿交易" not in http_text:
        fail("HTTP contract must document complete multi-leg replacement correction")
    ok("Multi-leg correction contract and implementation checks passed")


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


def check_production_topology_smoke() -> None:
    if not PRODUCTION_TOPOLOGY_SMOKE.exists():
        fail(f"Missing production topology smoke: {PRODUCTION_TOPOLOGY_SMOKE}")
    text = PRODUCTION_TOPOLOGY_SMOKE.read_text(encoding="utf-8")
    snippets = [
        "ssl.TLSVersion.TLSv1_2",
        "--check-production-config",
        "host_header_forbidden",
        "auth_required",
        "idempotency-replayed",
        "/v1/subscriptions/charge-proposals/due-scan",
        "--validate-ledger",
        "--validate-auth-state",
        "/v1/auth/refresh",
        "production TLS/auth/persistence topology smoke passed",
    ]
    missing = [snippet for snippet in snippets if snippet not in text]
    if missing:
        fail("Production topology smoke missing critical coverage: " + ", ".join(missing))
    for workflow in (CI_WORKFLOW, PACKAGE_WORKFLOW):
        if "production_topology_smoke.py" not in workflow.read_text(encoding="utf-8"):
            fail(f"Workflow does not run production topology smoke: {workflow}")
    ok("Production TLS/auth/persistence topology smoke checks passed")


def check_frontend_local_server_smoke() -> None:
    for required in (FRONTEND_LOCAL_SERVER_SMOKE, LOCAL_SERVER_SUBSCRIPTION_TEST):
        if not required.exists():
            fail(f"Missing local-server frontend integration artifact: {required}")

    smoke_text = FRONTEND_LOCAL_SERVER_SMOKE.read_text(encoding="utf-8")
    smoke_snippets = [
        "finwealth-server.exe",
        "--ledger-path",
        "LOCAL_SERVER_API_BASE",
        "local_server_subscription_integration_test.dart",
        "Stop-Process",
    ]
    missing = [snippet for snippet in smoke_snippets if snippet not in smoke_text]
    if missing:
        fail(
            "Frontend local-server smoke missing required behavior: "
            + ", ".join(missing)
        )

    test_text = LOCAL_SERVER_SUBSCRIPTION_TEST.read_text(encoding="utf-8")
    test_snippets = [
        "ChatGPT Plus integration",
        "currency: 'USD'",
        "2026-01-31",
        "2026-02-28",
        "updateSubscription",
        "2026-04-30",
        "ApiConflictException",
        "ledgerWrite",
        "SubscriptionStatus.cancelled",
    ]
    missing = [snippet for snippet in test_snippets if snippet not in test_text]
    if missing:
        fail(
            "Local-server subscription test missing regression coverage: "
            + ", ".join(missing)
        )

    ok("Frontend local-server subscription smoke checks passed")


def check_deploy_security_defaults() -> None:
    if not DEPLOY_ENV_EXAMPLE.exists():
        fail(f"Missing deploy env example: {DEPLOY_ENV_EXAMPLE}")
    for required in (
        SYSTEMD_SERVICE,
        SYSTEMD_DOCKER_PROXY_SOCKET,
        SYSTEMD_DOCKER_PROXY_SERVICE,
        CADDY_FINWEALTH_SITE,
        VPS_INSTALL,
        VPS_BUNDLE_INSTALL,
        VPS_PACKAGE,
        VPS_AUTH_CONFIGURE,
        VPS_READINESS,
        VPS_BACKUP,
        VPS_RESTORE,
        VPS_BACKUP_RESTORE_SMOKE,
        LOCAL_BACKUP,
        LOCAL_RESTORE,
        LOCAL_BACKUP_RESTORE_SMOKE,
    ):
        if not required.exists():
            fail(f"Missing deploy safety artifact: {required}")

    env_text = DEPLOY_ENV_EXAMPLE.read_text(encoding="utf-8")
    if "FINWEALTH_QUOTE_PROVIDER=none" not in env_text:
        fail("Deploy env example must default FINWEALTH_QUOTE_PROVIDER to none")

    install_text = VPS_INSTALL.read_text(encoding="utf-8")
    if "--check-production-config" not in install_text or "EnvironmentFile" not in install_text:
        fail("VPS installer must validate production configuration through systemd")

    bundle_install_text = VPS_BUNDLE_INSTALL.read_text(encoding="utf-8")
    bundle_install_snippets = [
        "sha256sum -c SHA256SUMS",
        "PACKAGE_ARCH",
        "HOST_ARCH",
        "--check-bundle-only",
        "change-me",
        "--check-production-config",
        "EnvironmentFile",
    ]
    missing = [
        snippet
        for snippet in bundle_install_snippets
        if snippet not in bundle_install_text
    ]
    if missing:
        fail("Prebuilt VPS installer missing safety gates: " + ", ".join(missing))

    vps_package_text = VPS_PACKAGE.read_text(encoding="utf-8")
    vps_package_snippets = [
        "Source worktree is dirty",
        "cargo build",
        "--release --locked",
        "x86_64-unknown-linux-musl",
        "Requesting program interpreter",
        "bundle-execution-smoke",
        "sourceCommit",
        "sourceDirty",
        '"libc":"musl"',
        '"linkage":"static"',
        "SHA256SUMS",
        "sha256sum -c SHA256SUMS",
        "install_vps_bundle.sh",
        "--check-bundle-only",
    ]
    missing = [
        snippet for snippet in vps_package_snippets if snippet not in vps_package_text
    ]
    if missing:
        fail("VPS bundle packaging missing provenance gates: " + ", ".join(missing))

    auth_configure_text = VPS_AUTH_CONFIGURE.read_text(encoding="utf-8")
    auth_configure_snippets = [
        "read -rsp",
        "PASSWORD_CONFIRM",
        "minimum 12",
        "--hash-password-stdin",
        "mktemp",
        "EnvironmentFile=$TEMP_ENV",
        "--check-production-config",
        "mv -f -- \"$TEMP_ENV\" \"$ENV_FILE\"",
        "systemctl enable --now",
    ]
    missing = [
        snippet
        for snippet in auth_configure_snippets
        if snippet not in auth_configure_text
    ]
    if missing:
        fail("Interactive VPS auth configuration missing safety gates: " + ", ".join(missing))

    readiness_text = VPS_READINESS.read_text(encoding="utf-8")
    readiness_snippets = [
        "--check-production-config",
        "--validate-ledger",
        "--validate-auth-state",
        "systemctl is-active",
        "127.0.0.1:8790/v1/health",
        "--public-base-url",
    ]
    missing = [snippet for snippet in readiness_snippets if snippet not in readiness_text]
    if missing:
        fail("VPS readiness check missing production gates: " + ", ".join(missing))

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

    proxy_socket_text = SYSTEMD_DOCKER_PROXY_SOCKET.read_text(encoding="utf-8")
    for snippet in ("ListenStream=%I", "Accept=no", "Requires=docker.service"):
        if snippet not in proxy_socket_text:
            fail(f"Docker bridge proxy socket missing safety setting: {snippet}")

    proxy_service_text = SYSTEMD_DOCKER_PROXY_SERVICE.read_text(encoding="utf-8")
    proxy_service_snippets = [
        "User=finwealth",
        "systemd-socket-proxyd 127.0.0.1:8790",
        "Requires=finwealth-server.service",
        "NoNewPrivileges=true",
        "ProtectSystem=strict",
    ]
    missing = [
        snippet for snippet in proxy_service_snippets if snippet not in proxy_service_text
    ]
    if missing:
        fail("Docker bridge proxy service missing hardening: " + ", ".join(missing))

    caddy_site_text = CADDY_FINWEALTH_SITE.read_text(encoding="utf-8")
    caddy_site_snippets = [
        "wuwaidut.com {",
        "remote_ip 173.245.48.0/20",
        "reverse_proxy 172.19.0.1:8791",
        "@finwealth",
        "path /v1/accounts",
        "reverse_proxy cli-proxy-api:8317",
        "@relayManagement path /management.html",
        'respond "Not Found" 404',
        "header_up Host {host}",
        "CF-Connecting-IP",
        'respond "Forbidden" 403',
    ]
    missing = [
        snippet for snippet in caddy_site_snippets if snippet not in caddy_site_text
    ]
    if missing:
        fail("Finwealth Caddy site missing origin safeguards: " + ", ".join(missing))

    backup_text = VPS_BACKUP.read_text(encoding="utf-8")
    backup_snippets = [
        "umask 077",
        "systemctl stop",
        "--validate-ledger",
        "--validate-auth-state",
        "SHA256SUMS",
        "mktemp -d",
        'mv -- "$STAGING" "$TARGET"',
        "stop_proxy_companions",
        "start_proxy_sockets",
        "finwealth-docker-proxy@*.socket",
    ]
    missing = [snippet for snippet in backup_snippets if snippet not in backup_text]
    if missing:
        fail("VPS backup script missing consistency safeguards: " + ", ".join(missing))

    restore_text = VPS_RESTORE.read_text(encoding="utf-8")
    restore_snippets = [
        "verify_backup_directory",
        "EXPECTED_LEDGER_HASH",
        "AUTH_ACTION",
        "COMMIT_STARTED",
        "ROLLBACK_PERFORMED",
        "rolling back current state",
        "systemctl stop",
        "systemctl start",
        "--allow-unverified",
        "stop_proxy_companions",
        "start_proxy_sockets",
        "finwealth-docker-proxy@*.socket",
    ]
    missing = [snippet for snippet in restore_snippets if snippet not in restore_text]
    if missing:
        fail("VPS restore script missing consistency safeguards: " + ", ".join(missing))

    local_backup_text = LOCAL_BACKUP.read_text(encoding="utf-8")
    local_backup_snippets = [
        "Assert-RegularFile",
        "ReparsePoint",
        "--validate-ledger",
        "--validate-auth-state",
        "SHA256SUMS",
        ".staging",
        "changed while the backup was being copied",
        "Move-Item -LiteralPath $staging -Destination $target",
    ]
    missing = [
        snippet for snippet in local_backup_snippets if snippet not in local_backup_text
    ]
    if missing:
        fail(
            "Local Windows backup script missing consistency safeguards: "
            + ", ".join(missing)
        )

    local_restore_text = LOCAL_RESTORE.read_text(encoding="utf-8")
    local_restore_snippets = [
        "Acquire-LedgerRestoreLease",
        "[System.IO.FileShare]::None",
        "$stream.Lock(0, 1)",
        "Release-LedgerRestoreLease",
        "Read-ManifestValue",
        "AllowUnverified",
        "expectedLedgerHash",
        "authAction",
        "Install-StagedFile",
        "File]::Replace",
        "rolling back current state",
        "pre-restore",
    ]
    missing = [
        snippet for snippet in local_restore_snippets if snippet not in local_restore_text
    ]
    if missing:
        fail(
            "Local Windows restore script missing consistency safeguards: "
            + ", ".join(missing)
        )

    local_smoke_text = LOCAL_BACKUP_RESTORE_SMOKE.read_text(encoding="utf-8")
    local_smoke_snippets = [
        "restore unexpectedly replaced a ledger while its lock was held",
        "restore removed the permanent ledger lock sidecar",
        "checksum mismatch",
        "includesAuth=false",
        "FINWEALTH_TEST_FAIL_AFTER_LEDGER_REPLACE",
        "did not roll back ledger",
        "direct ledger restore unexpectedly bypassed",
    ]
    missing = [
        snippet for snippet in local_smoke_snippets if snippet not in local_smoke_text
    ]
    if missing:
        fail(
            "Local Windows backup/restore smoke missing regression coverage: "
            + ", ".join(missing)
        )

    ok("Deploy security defaults passed")


def check_release_packaging() -> None:
    for required in (
        PACKAGE_SCRIPT,
        PACKAGE_INTEGRITY_SMOKE,
        FRONTEND_LOCAL_SERVER_SMOKE,
        PYTHON_REQUIREMENTS,
        WINDOWS_LAUNCHER,
        WINDOWS_LAUNCHER_CMD,
        WINDOWS_PACKAGE_DOC,
        REMOTE_PACKAGE_SCRIPT,
        REMOTE_WINDOWS_LAUNCHER,
        REMOTE_WINDOWS_LAUNCHER_CMD,
        REMOTE_WINDOWS_PACKAGE_DOC,
        REMOTE_ANDROID_PACKAGE_SCRIPT,
        REMOTE_ANDROID_PACKAGE_DOC,
        ANDROID_MANIFEST,
        SERVER_MODE_ALGORITHMS,
        VPS_BUNDLE_INSTALL,
        VPS_PACKAGE,
        PACKAGE_WORKFLOW,
        CI_WORKFLOW,
    ):
        if not required.exists():
            fail(f"Missing self-use packaging artifact: {required}")

    if PYTHON_REQUIREMENTS.read_text(encoding="utf-8").strip() != "PyYAML==6.0.3":
        fail("Python tooling must pin the reviewed PyYAML version")

    package_text = PACKAGE_SCRIPT.read_text(encoding="utf-8")
    required_package_snippets = [
        "--dart-define=DATA_SOURCE=local_server",
        "--dart-define=API_BASE=$WindowsApiBase",
        "cargo.exe",
        "--release",
        "finwealth-server.exe",
        "finwealth.build-config.json",
        "package-manifest.json",
        "[System.Uri]::TryCreate",
        "stale APK could be mislabeled",
        "CLIENT_IDEMPOTENCY_BLOCKER",
        "auth_client_test.dart",
        "flutterExe test $testPath",
        "AllowDirtySource",
        "sourceCommit",
        "clientSha256",
        "launcherPowerShellSha256",
        "buildConfigSha256",
        "Expand-Archive",
        '"$ZipPath.sha256"',
        "CheckReadinessOnly",
        "AndroidReadOnlyPreview",
        "android-readonly-preview-debug.apk",
    ]
    missing = [
        snippet for snippet in required_package_snippets if snippet not in package_text
    ]
    if missing:
        fail("Windows package script missing paired-build safeguards: " + ", ".join(missing))

    launcher_text = WINDOWS_LAUNCHER.read_text(encoding="utf-8")
    required_launcher_snippets = [
        "LOCALAPPDATA",
        "--hash-password-stdin",
        "FINWEALTH_REQUIRE_AUTH",
        "FINWEALTH_AUTH_PASSWORD_HASH",
        "FINWEALTH_QUOTE_PROVIDER",
        "Get-FileHash",
        "serverSha256",
        "clientSha256",
        "launcherPowerShellSha256",
        "buildConfigSha256",
        "PackageIntegrityOnly",
        "packageFormat -ne 2",
        "finwealth.build-config.json",
        "--ledger-path",
        "Wait-Health",
        "Stop-Process",
    ]
    missing = [
        snippet for snippet in required_launcher_snippets if snippet not in launcher_text
    ]
    if missing:
        fail("Windows self-use launcher missing safety behavior: " + ", ".join(missing))

    remote_package_text = REMOTE_PACKAGE_SCRIPT.read_text(encoding="utf-8")
    remote_package_snippets = [
        "--dart-define=DATA_SOURCE=api_remote",
        "endpointMode",
        "remote_server_setup_test.dart",
        "$parsedApiBase.Scheme -ceq \"https\"",
        "sourceCommit",
        "sourceDirty",
        "serverBundled = $false",
        "packageFormat = 3",
        "PackageIntegrityOnly",
        "windows-server-client-x64",
    ]
    missing = [
        snippet for snippet in remote_package_snippets if snippet not in remote_package_text
    ]
    if missing:
        fail("Windows remote package script missing safeguards: " + ", ".join(missing))

    remote_launcher_text = REMOTE_WINDOWS_LAUNCHER.read_text(encoding="utf-8")
    remote_launcher_snippets = [
        "packageFormat -ne 3",
        "dataSource -cne \"api_remote\"",
        "endpointMode",
        "Test-HttpsApiBase",
        "Get-FileHash",
        "/v1/health",
        "Start-Process",
    ]
    missing = [
        snippet for snippet in remote_launcher_snippets if snippet not in remote_launcher_text
    ]
    if missing:
        fail("Windows remote launcher missing safety behavior: " + ", ".join(missing))

    remote_android_text = REMOTE_ANDROID_PACKAGE_SCRIPT.read_text(encoding="utf-8")
    remote_android_snippets = [
        "--dart-define=DATA_SOURCE=api_remote",
        "endpointMode",
        "remote_server_setup_test.dart",
        "debug-self-use",
        "apkanalyzer",
        "networkPolicyVerified",
        "apkSha256",
        "manifest.json",
    ]
    missing = [
        snippet for snippet in remote_android_snippets if snippet not in remote_android_text
    ]
    if missing:
        fail("Android remote package script missing safeguards: " + ", ".join(missing))

    android_manifest_text = ANDROID_MANIFEST.read_text(encoding="utf-8")
    for snippet in (
        "android.permission.INTERNET",
        'android:usesCleartextTraffic="false"',
        'android:allowBackup="false"',
    ):
        if snippet not in android_manifest_text:
            fail(f"Android server client manifest missing security setting: {snippet}")

    package_integrity_smoke_text = PACKAGE_INTEGRITY_SMOKE.read_text(encoding="utf-8")
    package_integrity_smoke_snippets = [
        "PackageIntegrityOnly",
        "unexpectedly touched user state",
        "tampered client",
        "Windows package integrity smoke passed",
    ]
    missing = [
        snippet
        for snippet in package_integrity_smoke_snippets
        if snippet not in package_integrity_smoke_text
    ]
    if missing:
        fail("Package integrity smoke missing regression coverage: " + ", ".join(missing))

    workflow_text = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
    required_workflow_snippets = [
        "finwealth-windows-self-use-x64",
        "verify-windows-source:",
        "verify-linux-server:",
        "cargo clippy",
        "python tools/contract_check.py",
        "tools/requirements.txt",
        "python tools/local_ledger_smoke.py",
        "python tools/production_topology_smoke.py",
        "local_backup_restore_smoke.ps1",
        "package_integrity_smoke.ps1",
        "frontend_local_server_smoke.ps1",
        "flutter analyze",
        "flutter test",
        "flutter-version: 3.44.4",
        "Verify source remained clean",
        "needs: [verify-windows-source, verify-linux-server]",
        "*-windows-self-use-x64.zip.sha256",
        "include_android_readonly_preview",
        "AndroidReadOnlyPreview",
        "android-readonly-preview-debug",
        "remote_api_base",
        "package_remote_windows.ps1",
        "finwealth-windows-server-client-x64",
        "include_android_server_client",
        "package_remote_android.ps1",
        "android-server-client-debug",
        "package-linux-server:",
        "package_vps_server.sh",
        "finwealth-linux-x86_64-vps-server",
        "*-linux-x86_64-vps.tar.gz.sha256",
        "x86_64-unknown-linux-musl",
        "package-linux-server-arm64:",
        "ubuntu-24.04-arm",
        "finwealth-linux-aarch64-vps-server",
        "*-linux-aarch64-vps.tar.gz.sha256",
        "aarch64-unknown-linux-musl",
        "musl-tools",
    ]
    missing = [
        snippet for snippet in required_workflow_snippets if snippet not in workflow_text
    ]
    if missing:
        fail("Package workflow does not preserve package-mode boundaries: " + ", ".join(missing))

    ci_workflow_text = CI_WORKFLOW.read_text(encoding="utf-8")
    if "CLIENT_IDEMPOTENCY_BLOCKER" in ci_workflow_text:
        fail("CI must not swallow the client idempotency packaging blocker")
    if "package_release.ps1 -WindowsOnly -OutputDir" not in ci_workflow_text:
        fail("CI must build the paired Windows package rather than readiness-check only")
    if "frontend_local_server_smoke.ps1" not in ci_workflow_text:
        fail("CI must run the real Flutter and Rust subscription smoke")
    if "python tools/contract_check.py" not in ci_workflow_text:
        fail("CI must execute the contract checks")
    if "tools/requirements.txt" not in ci_workflow_text:
        fail("CI must install the pinned Python tooling dependencies")
    if "flutter-version: 3.44.4" not in ci_workflow_text:
        fail("CI must pin the reviewed Flutter toolchain version")

    ok("Self-use release packaging checks passed")


def check_repository_hygiene() -> None:
    if not GITIGNORE.exists():
        fail(f"Missing repository ignore policy: {GITIGNORE}")
    lines = {
        line.strip()
        for line in GITIGNORE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    required_patterns = [
        ".env",
        ".env.*",
        "*.pem",
        "*.pfx",
        "*.keystore",
        "ledger.json",
        "ledger.json.tmp",
        "ledger.auth.json",
        "ledger.json.lock",
        "backups/",
        "dist/",
    ]
    missing = [pattern for pattern in required_patterns if pattern not in lines]
    if missing:
        fail("Repository ignore policy is missing sensitive patterns: " + ", ".join(missing))
    if not GITATTRIBUTES.exists():
        fail(f"Missing repository line-ending policy: {GITATTRIBUTES}")
    attributes = GITATTRIBUTES.read_text(encoding="utf-8")
    for generated in (
        "windows/flutter/generated_plugin_registrant.cc text eol=lf",
        "windows/flutter/generated_plugin_registrant.h text eol=lf",
        "windows/flutter/generated_plugins.cmake text eol=lf",
    ):
        if generated not in attributes:
            fail(f"Generated Windows plugin file lacks LF policy: {generated}")
    ok("Repository sensitive-file ignore policy passed")


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
    movement_parameters = {
        parameter.get("name"): parameter
        for parameter in doc["paths"]["/movements"]["get"].get("parameters", [])
        if isinstance(parameter, dict)
    }
    movement_limit_schema = movement_parameters.get("limit", {}).get("schema", {})
    if movement_limit_schema.get("minimum") != 1 or movement_limit_schema.get("maximum") != 200:
        fail("Movement limit must stay bounded to 1..200")
    recent_parameters = {
        parameter.get("name"): parameter
        for parameter in doc["paths"]["/movements/recent"]["get"].get("parameters", [])
        if isinstance(parameter, dict)
    }
    if recent_parameters.get("limit", {}).get("schema", {}).get("default") != 20:
        fail("Recent movements must document the server default limit of 20")
    snapshot_parameters = {
        parameter.get("name"): parameter
        for parameter in doc["paths"]["/snapshots"]["get"].get("parameters", [])
        if isinstance(parameter, dict)
    }
    if set(snapshot_parameters) != {"from", "to"}:
        fail("Snapshot list must document paired from/to filters")
    if any(parameter.get("required") is True for parameter in snapshot_parameters.values()):
        fail("Snapshot from/to filters must remain optional as a pair")
    if "AiFieldDiff" not in schemas:
        fail("OpenAPI must expose AiFieldDiff for old -> new review")
    idempotency_parameter = doc["components"].get("parameters", {}).get(
        "idempotencyKey", {}
    )
    idempotency_schema = idempotency_parameter.get("schema", {})
    if idempotency_schema.get("minLength") != 1:
        fail("Idempotency-Key must document minLength 1")
    if idempotency_schema.get("maxLength") != 128:
        fail("Idempotency-Key must document maxLength 128")
    missing_idempotency: list[str] = []
    for path, path_item in doc["paths"].items():
        if path.startswith("/auth/") or not isinstance(path_item, dict):
            continue
        for method in LEDGER_WRITE_METHODS:
            operation = path_item.get(method)
            if not isinstance(operation, dict):
                continue
            parameters = operation.get("parameters", [])
            if not any(
                isinstance(parameter, dict)
                and parameter.get("$ref")
                == "#/components/parameters/idempotencyKey"
                for parameter in parameters
            ):
                missing_idempotency.append(f"{method.upper()} {path}")
    if missing_idempotency:
        fail(
            "Ledger write operations missing Idempotency-Key: "
            + ", ".join(sorted(missing_idempotency))
        )
    ok("All documented ledger writes require Idempotency-Key")
    confirm_result = doc["components"]["schemas"].get("ConfirmResult", {})
    confirm_required = set(confirm_result.get("required", []))
    if "ledgerWrite" not in confirm_required:
        fail("ConfirmResult must require ledgerWrite so clients do not guess write semantics")
    update_subscription = doc["components"]["schemas"].get(
        "UpdateSubscriptionRequest", {}
    )
    if update_subscription.get("minProperties") != 1:
        fail("UpdateSubscriptionRequest must reject an empty PATCH body")
    update_subscription_description = update_subscription.get("description", "")
    for required_phrase in (
        "Two non-null values conflict",
        "non-null duration computes endDate",
        "two null values clear the finite schedule",
    ):
        if required_phrase not in update_subscription_description:
            fail("UpdateSubscriptionRequest must document nullable schedule replacement semantics")
    categories_post_schema = doc["paths"]["/categories"]["post"]["requestBody"]["content"]["application/json"]["schema"].get("$ref")
    if categories_post_schema != "#/components/schemas/CreateCategoryInput":
        fail("POST /categories must use CreateCategoryInput, not the response Category schema")
    counterparties_post_schema = doc["paths"]["/counterparties"]["post"]["requestBody"]["content"]["application/json"]["schema"].get("$ref")
    if counterparties_post_schema != "#/components/schemas/CreateCounterpartyInput":
        fail("POST /counterparties must use CreateCounterpartyInput, not the response Counterparty schema")
    bearer_format = doc["components"]["securitySchemes"]["bearerAuth"].get("bearerFormat")
    if bearer_format != "opaque":
        fail("Bearer auth must be documented as opaque tokens, not JWT")
    logout = doc["paths"]["/auth/logout"]["post"]
    if {} not in logout.get("security", []):
        fail("POST /auth/logout must allow refresh-token logout without bearer auth")
    logout_schema = logout.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema", {})
    if "refreshToken" not in logout_schema.get("properties", {}):
        fail("POST /auth/logout must document its optional refreshToken body")
    sync_push_request = doc["components"]["schemas"].get("SyncPushRequest", {})
    sync_push_change_ref = (
        sync_push_request.get("properties", {})
        .get("changes", {})
        .get("items", {})
        .get("$ref")
    )
    if sync_push_change_ref != "#/components/schemas/InboundAccountCreateSyncChange":
        fail("Sync push must be narrowed to InboundAccountCreateSyncChange")
    inbound_account_create = doc["components"]["schemas"].get(
        "InboundAccountCreateSyncChange", {}
    )
    inbound_required = set(inbound_account_create.get("required", []))
    if "baseVersion" not in inbound_required:
        fail("Inbound account create sync changes must require baseVersion")
    inbound_properties = inbound_account_create.get("properties", {})
    if inbound_properties.get("entityType", {}).get("const") != "account":
        fail("Inbound sync entityType must be constrained to account")
    if inbound_properties.get("operation", {}).get("const") != "create":
        fail("Inbound sync operation must be constrained to create")
    if inbound_properties.get("baseVersion", {}).get("const") != 0:
        fail("Inbound account create baseVersion must be constrained to 0")
    sync_push_result = doc["components"]["schemas"].get(
        "SyncPushResultResponse", {}
    )
    sync_push_data = sync_push_result.get("properties", {}).get("data", {})
    if "appliedChangeIds" not in set(sync_push_data.get("required", [])):
        fail("Sync push response must require appliedChangeIds")
    created_operations = (
        ("/accounts", "post"),
        ("/movements/drafts", "post"),
        ("/dca/plans", "post"),
        ("/categories", "post"),
        ("/counterparties", "post"),
    )
    for path, method in created_operations:
        if "201" not in doc["paths"][path][method].get("responses", {}):
            fail(f"{method.upper()} {path} must document the server's 201 response")
    for path in ("/categories/{categoryId}", "/counterparties/{counterpartyId}"):
        if "get" not in doc["paths"][path]:
            fail(f"OpenAPI must document the implemented detail route GET {path}")
    for path, method in (("/sync/changes", "get"), ("/sync/ack", "post")):
        responses = doc["paths"][path][method].get("responses", {})
        if "400" not in responses:
            fail(f"{method.upper()} {path} must document invalid cursor responses")
    ok("Critical AI/DCA invariants are represented")

    check_dca_execution_input(doc)
    check_investment_fee_semantics(doc)
    check_subscription_due_scan(doc)
    check_multileg_correction(doc)
    check_examples()
    check_mock_server()
    check_dev_server()
    check_rust_server()
    check_ledger_migration_boundary()
    check_ledger_lease_boundary()
    check_server_smoke()
    check_production_topology_smoke()
    check_frontend_local_server_smoke()
    check_deploy_security_defaults()
    check_release_packaging()
    check_repository_hygiene()

    if not forbidden_present and not missing_from_openapi:
        ok("Contract check passed")


if __name__ == "__main__":
    main()

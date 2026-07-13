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
PACKAGE_WORKFLOW = ROOT / ".github" / "workflows" / "package.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

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
        "LOCAL_SYNC_GENESIS_CURSOR",
        "stored_sequence.max(fallback_sequence)",
        "idempotencyState",
        "idempotent_ledger_write",
        "IdempotencyKeyReused",
        "IDEMPOTENCY_MAX_RECORDS",
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
    for required in (
        SYSTEMD_SERVICE,
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

    backup_text = VPS_BACKUP.read_text(encoding="utf-8")
    backup_snippets = [
        "umask 077",
        "systemctl stop",
        "--validate-ledger",
        "--validate-auth-state",
        "SHA256SUMS",
        "mktemp -d",
        'mv -- "$STAGING" "$TARGET"',
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
        WINDOWS_LAUNCHER,
        WINDOWS_LAUNCHER_CMD,
        WINDOWS_PACKAGE_DOC,
        PACKAGE_WORKFLOW,
        CI_WORKFLOW,
    ):
        if not required.exists():
            fail(f"Missing self-use packaging artifact: {required}")

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
        "cargo clippy",
        "python tools/contract_check.py",
        "python tools/local_ledger_smoke.py",
        "local_backup_restore_smoke.ps1",
        "package_integrity_smoke.ps1",
        "flutter analyze",
        "flutter test",
        "needs: verify-windows-source",
        "*-windows-self-use-x64.zip.sha256",
        "include_android_readonly_preview",
        "AndroidReadOnlyPreview",
        "android-readonly-preview-debug",
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

    ok("Self-use release packaging checks passed")


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

    check_examples()
    check_mock_server()
    check_dev_server()
    check_rust_server()
    check_server_smoke()
    check_deploy_security_defaults()
    check_release_packaging()

    if not forbidden_present and not missing_from_openapi:
        ok("Contract check passed")


if __name__ == "__main__":
    main()

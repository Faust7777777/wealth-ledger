#!/usr/bin/env bash
set -euo pipefail
umask 077

FORCE="false"
ALLOW_UNVERIFIED="false"
while [ "${1:-}" != "" ] && [[ "${1:-}" == --* ]]; do
  case "$1" in
    --force)
      FORCE="true"
      ;;
    --allow-unverified)
      ALLOW_UNVERIFIED="true"
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

BACKUP_PATH="${1:-}"
LEDGER_PATH="${2:-/var/lib/finwealth/ledger.json}"
PRE_RESTORE_ROOT="${FINWEALTH_PRE_RESTORE_BACKUP_DIR:-/var/backups/finwealth/pre-restore}"
SERVER_BIN="${FINWEALTH_SERVER_BIN:-/opt/finwealth/finwealth-server}"
APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"
STOP_SERVICE="${FINWEALTH_RESTORE_STOP_SERVICE:-true}"
ALLOW_UNVALIDATED="${FINWEALTH_ALLOW_UNVALIDATED_RESTORE:-false}"

if [ -z "$BACKUP_PATH" ]; then
  echo "usage: sudo bash tools/restore_vps_ledger.sh [--force] [--allow-unverified] <backup-dir-or-ledger-json> [ledger-path]" >&2
  exit 2
fi
if [ ! -e "$BACKUP_PATH" ] || [ -L "$BACKUP_PATH" ]; then
  echo "backup path must exist and must not be a symlink: $BACKUP_PATH" >&2
  exit 2
fi

if [[ "$LEDGER_PATH" == *.json ]]; then
  AUTH_TARGET="${LEDGER_PATH%.json}.auth.json"
else
  AUTH_TARGET="${LEDGER_PATH}.auth.json"
fi

BACKUP_IS_DIRECTORY="false"
INCLUDES_AUTH="false"
AUTH_ACTION="keep"
EXPECTED_LEDGER_HASH=""
EXPECTED_AUTH_HASH=""
if [ -d "$BACKUP_PATH" ]; then
  BACKUP_IS_DIRECTORY="true"
  BACKUP_LEDGER="$BACKUP_PATH/ledger.json"
  BACKUP_AUTH="$BACKUP_PATH/ledger.auth.json"
else
  BACKUP_LEDGER="$BACKUP_PATH"
  BACKUP_AUTH=""
fi
if [ ! -f "$BACKUP_LEDGER" ] || [ -L "$BACKUP_LEDGER" ]; then
  echo "backup ledger must be a regular non-symlink file: $BACKUP_LEDGER" >&2
  exit 2
fi
if [ "$(realpath -m "$BACKUP_LEDGER")" = "$(realpath -m "$LEDGER_PATH")" ]; then
  echo "backup ledger and restore target must be different files" >&2
  exit 2
fi

manifest_value() {
  local key="$1"
  local file="$2"
  local count
  count="$(grep -c "^${key}=" "$file" || true)"
  if [ "$count" -ne 1 ]; then
    echo "manifest must contain exactly one ${key}= entry" >&2
    return 1
  fi
  grep "^${key}=" "$file" | cut -d= -f2-
}

verify_backup_directory() {
  local manifest="$BACKUP_PATH/manifest.txt"
  local checksums="$BACKUP_PATH/SHA256SUMS"
  if [ ! -f "$manifest" ] || [ -L "$manifest" ] || [ ! -f "$checksums" ] || [ -L "$checksums" ]; then
    echo "backup directory must contain regular manifest.txt and SHA256SUMS files" >&2
    return 1
  fi
  if [ "$(manifest_value backupFormat "$manifest")" != "1" ]; then
    echo "unsupported or missing backupFormat in manifest" >&2
    return 1
  fi
  INCLUDES_AUTH="$(manifest_value includesAuth "$manifest")"
  if [ "$INCLUDES_AUTH" != "true" ] && [ "$INCLUDES_AUTH" != "false" ]; then
    echo "manifest includesAuth must be true or false" >&2
    return 1
  fi

  declare -A seen=()
  local line expected name actual
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ ! "$line" =~ ^([[:xdigit:]]{64})[[:space:]][[:space:]*](ledger\.json|ledger\.auth\.json)$ ]]; then
      echo "SHA256SUMS contains an invalid or unsafe entry" >&2
      return 1
    fi
    expected="${BASH_REMATCH[1],,}"
    name="${BASH_REMATCH[2]}"
    if [ "${seen[$name]:-false}" = "true" ]; then
      echo "SHA256SUMS contains duplicate entry: $name" >&2
      return 1
    fi
    seen[$name]="true"
    if [ ! -f "$BACKUP_PATH/$name" ] || [ -L "$BACKUP_PATH/$name" ]; then
      echo "checksummed backup file missing or is a symlink: $name" >&2
      return 1
    fi
    actual="$(sha256sum "$BACKUP_PATH/$name" | awk '{print tolower($1)}')"
    if [ "$actual" != "$expected" ]; then
      echo "checksum mismatch for backup file: $name" >&2
      return 1
    fi
    if [ "$name" = "ledger.json" ]; then
      EXPECTED_LEDGER_HASH="$expected"
    else
      EXPECTED_AUTH_HASH="$expected"
    fi
  done < "$checksums"

  if [ -z "$EXPECTED_LEDGER_HASH" ]; then
    echo "SHA256SUMS must include ledger.json" >&2
    return 1
  fi
  if [ "$INCLUDES_AUTH" = "true" ]; then
    if [ -z "$EXPECTED_AUTH_HASH" ] || [ ! -f "$BACKUP_AUTH" ] || [ -L "$BACKUP_AUTH" ]; then
      echo "manifest requires a checksummed ledger.auth.json" >&2
      return 1
    fi
    AUTH_ACTION="restore"
  else
    if [ -n "$EXPECTED_AUTH_HASH" ] || [ -e "$BACKUP_AUTH" ]; then
      echo "manifest excludes auth state but backup contains ledger.auth.json" >&2
      return 1
    fi
    AUTH_ACTION="remove"
  fi
}

if [ "$BACKUP_IS_DIRECTORY" = "true" ]; then
  if ! verify_backup_directory; then
    if [ "$ALLOW_UNVERIFIED" != "true" ]; then
      exit 2
    fi
    echo "warning: proceeding with an unverified backup directory" >&2
    EXPECTED_LEDGER_HASH=""
    EXPECTED_AUTH_HASH=""
    if [ -f "$BACKUP_AUTH" ] && [ ! -L "$BACKUP_AUTH" ]; then
      INCLUDES_AUTH="true"
      AUTH_ACTION="restore"
    else
      INCLUDES_AUTH="false"
      AUTH_ACTION="remove"
    fi
  fi
elif [ "$ALLOW_UNVERIFIED" != "true" ]; then
  echo "direct ledger files have no checksum manifest; pass --allow-unverified to restore one" >&2
  exit 2
else
  echo "warning: restoring a direct ledger file without a checksum manifest" >&2
fi

if [ -x "$SERVER_BIN" ]; then
  "$SERVER_BIN" --validate-ledger "$BACKUP_LEDGER"
  if [ "$AUTH_ACTION" = "restore" ]; then
    "$SERVER_BIN" --validate-auth-state "$BACKUP_AUTH"
  fi
elif [ "$ALLOW_UNVALIDATED" != "true" ]; then
  echo "$SERVER_BIN not found; refusing a restore without semantic validation" >&2
  echo "set FINWEALTH_ALLOW_UNVALIDATED_RESTORE=true only for emergency recovery" >&2
  exit 2
fi

if [ "$FORCE" != "true" ]; then
  cat <<EOF
About to restore:
  from:        $BACKUP_LEDGER
  to:          $LEDGER_PATH
  auth action: $AUTH_ACTION

The service will be stopped when active, and current state will be backed up first.
EOF
  read -r -p "Type RESTORE to continue: " answer
  if [ "$answer" != "RESTORE" ]; then
    echo "Restore cancelled."
    exit 0
  fi
fi

SERVICE_WAS_ACTIVE="false"
ACTIVE_PROXY_SOCKETS=()
LEDGER_TMP=""
AUTH_TMP=""
ROLLBACK_DIR=""
COMMIT_STARTED="false"
COMMIT_SUCCEEDED="false"
LEDGER_EXISTED="false"
AUTH_EXISTED="false"
ROLLBACK_PERFORMED="false"

stop_proxy_companions() {
  mapfile -t ACTIVE_PROXY_SOCKETS < <(
    systemctl list-units \
      --type=socket \
      --state=active \
      --plain \
      --no-legend \
      'finwealth-docker-proxy@*.socket' 2>/dev/null | awk '{print $1}'
  )
  local socket service
  for socket in "${ACTIVE_PROXY_SOCKETS[@]}"; do
    service="${socket%.socket}.service"
    systemctl stop "$socket" "$service"
  done
}

start_proxy_sockets() {
  if [ "${#ACTIVE_PROXY_SOCKETS[@]}" -gt 0 ]; then
    systemctl start "${ACTIVE_PROXY_SOCKETS[@]}"
  fi
}

rollback_current_state() {
  if [ "$COMMIT_STARTED" != "true" ] || [ "$ROLLBACK_PERFORMED" = "true" ]; then
    return 0
  fi
  echo "restore failed after replacement began; rolling back current state" >&2
  local rollback_status=0
  if [ "$LEDGER_EXISTED" = "true" ] && [ -f "$ROLLBACK_DIR/ledger.json" ]; then
    cp -a -- "$ROLLBACK_DIR/ledger.json" "$LEDGER_PATH" || rollback_status=1
  else
    rm -f -- "$LEDGER_PATH" || rollback_status=1
  fi
  if [ "$AUTH_EXISTED" = "true" ] && [ -f "$ROLLBACK_DIR/ledger.auth.json" ]; then
    cp -a -- "$ROLLBACK_DIR/ledger.auth.json" "$AUTH_TARGET" || rollback_status=1
  else
    rm -f -- "$AUTH_TARGET" || rollback_status=1
  fi
  ROLLBACK_PERFORMED="true"
  return "$rollback_status"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$COMMIT_STARTED" = "true" ] && [ "$COMMIT_SUCCEEDED" != "true" ]; then
    rollback_current_state || status=1
  fi
  if [ "$SERVICE_WAS_ACTIVE" = "true" ]; then
    if systemctl start "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
      :
    else
      echo "failed to return $SERVICE_NAME to active state after restore" >&2
      if [ "$COMMIT_STARTED" = "true" ] && [ "$ROLLBACK_PERFORMED" != "true" ]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        if rollback_current_state; then
          if systemctl start "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "restored the pre-restore files after service startup failure" >&2
          else
            echo "failed to restart $SERVICE_NAME even after restoring the prior files" >&2
          fi
        else
          echo "failed to restore the prior files after service startup failure" >&2
        fi
      fi
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    if ! start_proxy_sockets; then
      echo "failed to restore Finwealth Docker bridge proxy sockets after restore" >&2
      status=1
    fi
  fi
  [ -z "$LEDGER_TMP" ] || rm -f -- "$LEDGER_TMP"
  [ -z "$AUTH_TMP" ] || rm -f -- "$AUTH_TMP"
  [ -z "$ROLLBACK_DIR" ] || rm -rf -- "$ROLLBACK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$STOP_SERVICE" = "true" ] && [ -n "$SERVICE_NAME" ]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; refusing an online restore" >&2
    exit 2
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    SERVICE_WAS_ACTIVE="true"
    stop_proxy_companions
    systemctl stop "$SERVICE_NAME"
  fi
fi

if [ -f "$LEDGER_PATH" ]; then
  FINWEALTH_ALLOW_UNVALIDATED_BACKUP=true \
    bash "$(dirname "$0")/backup_vps_ledger.sh" "$LEDGER_PATH" "$PRE_RESTORE_ROOT"
fi

TARGET_DIR="$(dirname "$LEDGER_PATH")"
if id "$APP_USER" >/dev/null 2>&1; then
  install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$TARGET_DIR"
else
  install -d -m 0700 "$TARGET_DIR"
fi
ROLLBACK_DIR="$(mktemp -d "$TARGET_DIR/.restore-rollback.XXXXXX")"
if [ -f "$LEDGER_PATH" ]; then
  LEDGER_EXISTED="true"
  cp -a -- "$LEDGER_PATH" "$ROLLBACK_DIR/ledger.json"
fi
if [ -f "$AUTH_TARGET" ]; then
  AUTH_EXISTED="true"
  cp -a -- "$AUTH_TARGET" "$ROLLBACK_DIR/ledger.auth.json"
fi

LEDGER_TMP="$(mktemp "$TARGET_DIR/.ledger.restore.XXXXXX")"
install -m 0600 "$BACKUP_LEDGER" "$LEDGER_TMP"
if [ "$AUTH_ACTION" = "restore" ]; then
  AUTH_TMP="$(mktemp "$TARGET_DIR/.auth.restore.XXXXXX")"
  install -m 0600 "$BACKUP_AUTH" "$AUTH_TMP"
fi
if id "$APP_USER" >/dev/null 2>&1; then
  chown "$APP_USER:$APP_USER" "$LEDGER_TMP"
  [ -z "$AUTH_TMP" ] || chown "$APP_USER:$APP_USER" "$AUTH_TMP"
fi

if [ -n "$EXPECTED_LEDGER_HASH" ]; then
  staged_ledger_hash="$(sha256sum "$LEDGER_TMP" | awk '{print tolower($1)}')"
  if [ "$staged_ledger_hash" != "$EXPECTED_LEDGER_HASH" ]; then
    echo "staged ledger checksum mismatch" >&2
    exit 2
  fi
fi
if [ -n "$EXPECTED_AUTH_HASH" ]; then
  staged_auth_hash="$(sha256sum "$AUTH_TMP" | awk '{print tolower($1)}')"
  if [ "$staged_auth_hash" != "$EXPECTED_AUTH_HASH" ]; then
    echo "staged auth checksum mismatch" >&2
    exit 2
  fi
fi
if [ -x "$SERVER_BIN" ]; then
  "$SERVER_BIN" --validate-ledger "$LEDGER_TMP"
  [ -z "$AUTH_TMP" ] || "$SERVER_BIN" --validate-auth-state "$AUTH_TMP"
fi

COMMIT_STARTED="true"
mv -f -- "$LEDGER_TMP" "$LEDGER_PATH"
LEDGER_TMP=""
case "$AUTH_ACTION" in
  restore)
    mv -f -- "$AUTH_TMP" "$AUTH_TARGET"
    AUTH_TMP=""
    ;;
  remove)
    rm -f -- "$AUTH_TARGET"
    ;;
  keep)
    ;;
esac

if [ -x "$SERVER_BIN" ]; then
  "$SERVER_BIN" --validate-ledger "$LEDGER_PATH"
  if [ -f "$AUTH_TARGET" ]; then
    "$SERVER_BIN" --validate-auth-state "$AUTH_TARGET"
  fi
fi
COMMIT_SUCCEEDED="true"

echo "Restore complete: $LEDGER_PATH (auth: $AUTH_ACTION)"

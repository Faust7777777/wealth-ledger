#!/usr/bin/env bash
set -euo pipefail

FORCE="false"
if [ "${1:-}" = "--force" ]; then
  FORCE="true"
  shift
fi

BACKUP_PATH="${1:-}"
LEDGER_PATH="${2:-/var/lib/finwealth/ledger.json}"
PRE_RESTORE_ROOT="${FINWEALTH_PRE_RESTORE_BACKUP_DIR:-/var/backups/finwealth/pre-restore}"
SERVER_BIN="${FINWEALTH_SERVER_BIN:-/opt/finwealth/finwealth-server}"
APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"

if [ -z "$BACKUP_PATH" ]; then
  echo "usage: sudo bash tools/restore_vps_ledger.sh [--force] <backup-dir-or-ledger-json> [ledger-path]" >&2
  exit 2
fi

if [ ! -e "$BACKUP_PATH" ]; then
  echo "backup path not found: $BACKUP_PATH" >&2
  exit 2
fi

if [ -d "$BACKUP_PATH" ]; then
  BACKUP_LEDGER="$BACKUP_PATH/ledger.json"
  BACKUP_AUTH="$BACKUP_PATH/ledger.auth.json"
else
  BACKUP_LEDGER="$BACKUP_PATH"
  BACKUP_AUTH=""
fi

if [ ! -f "$BACKUP_LEDGER" ]; then
  echo "backup ledger not found: $BACKUP_LEDGER" >&2
  exit 2
fi

if [ -x "$SERVER_BIN" ]; then
  "$SERVER_BIN" --validate-ledger "$BACKUP_LEDGER"
else
  echo "warning: $SERVER_BIN not found; restoring without ledger validation" >&2
fi

if [ "$FORCE" != "true" ]; then
  cat <<EOF
About to restore:
  from: $BACKUP_LEDGER
  to:   $LEDGER_PATH

Current ledger will be backed up first if it exists.
EOF
  read -r -p "Type RESTORE to continue: " answer
  if [ "$answer" != "RESTORE" ]; then
    echo "Restore cancelled."
    exit 0
  fi
fi

if [ -f "$LEDGER_PATH" ]; then
  bash "$(dirname "$0")/backup_vps_ledger.sh" "$LEDGER_PATH" "$PRE_RESTORE_ROOT"
fi

install -d -m 0750 "$(dirname "$LEDGER_PATH")"
install -m 0600 "$BACKUP_LEDGER" "$LEDGER_PATH"
if id "$APP_USER" >/dev/null 2>&1; then
  chown "$APP_USER:$APP_USER" "$LEDGER_PATH"
fi

if [[ "$LEDGER_PATH" == *.json ]]; then
  AUTH_TARGET="${LEDGER_PATH%.json}.auth.json"
else
  AUTH_TARGET="${LEDGER_PATH}.auth.json"
fi

if [ -n "$BACKUP_AUTH" ] && [ -f "$BACKUP_AUTH" ]; then
  install -m 0600 "$BACKUP_AUTH" "$AUTH_TARGET"
  if id "$APP_USER" >/dev/null 2>&1; then
    chown "$APP_USER:$APP_USER" "$AUTH_TARGET"
  fi
fi

echo "Restore complete: $LEDGER_PATH"

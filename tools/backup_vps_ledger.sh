#!/usr/bin/env bash
set -euo pipefail

LEDGER_PATH="${1:-/var/lib/finwealth/ledger.json}"
BACKUP_ROOT="${2:-/var/backups/finwealth}"
SERVER_BIN="${FINWEALTH_SERVER_BIN:-/opt/finwealth/finwealth-server}"

if [ ! -f "$LEDGER_PATH" ]; then
  echo "ledger file not found: $LEDGER_PATH" >&2
  exit 2
fi

if [ -x "$SERVER_BIN" ]; then
  "$SERVER_BIN" --validate-ledger "$LEDGER_PATH"
else
  echo "warning: $SERVER_BIN not found; copying without ledger validation" >&2
fi

if [[ "$LEDGER_PATH" == *.json ]]; then
  AUTH_PATH="${LEDGER_PATH%.json}.auth.json"
else
  AUTH_PATH="${LEDGER_PATH}.auth.json"
fi

TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
TARGET="$BACKUP_ROOT/$TIMESTAMP"
install -d -m 0700 "$TARGET"

install -m 0600 "$LEDGER_PATH" "$TARGET/ledger.json"
FILES=("$TARGET/ledger.json")

if [ -f "$AUTH_PATH" ]; then
  install -m 0600 "$AUTH_PATH" "$TARGET/ledger.auth.json"
  FILES+=("$TARGET/ledger.auth.json")
fi

{
  echo "createdAt=$(date -u --iso-8601=seconds)"
  echo "sourceLedger=$LEDGER_PATH"
  echo "sourceAuth=$AUTH_PATH"
  echo "validated=$([ -x "$SERVER_BIN" ] && echo true || echo false)"
  echo
  echo "sha256:"
  for file in "${FILES[@]}"; do
    (cd "$TARGET" && sha256sum "$(basename "$file")")
  done
} > "$TARGET/manifest.txt"
chmod 0600 "$TARGET/manifest.txt"

echo "Backup created: $TARGET"

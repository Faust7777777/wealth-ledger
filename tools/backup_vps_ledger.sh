#!/usr/bin/env bash
set -euo pipefail
umask 077

LEDGER_PATH="${1:-/var/lib/finwealth/ledger.json}"
BACKUP_ROOT="${2:-/var/backups/finwealth}"
SERVER_BIN="${FINWEALTH_SERVER_BIN:-/opt/finwealth/finwealth-server}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"
STOP_SERVICE="${FINWEALTH_BACKUP_STOP_SERVICE:-true}"
ALLOW_UNVALIDATED="${FINWEALTH_ALLOW_UNVALIDATED_BACKUP:-false}"

STAGING=""
SERVICE_WAS_ACTIVE="false"
ACTIVE_PROXY_SOCKETS=()

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

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
    rm -rf -- "$STAGING"
  fi
  if [ "$SERVICE_WAS_ACTIVE" = "true" ]; then
    if ! systemctl start "$SERVICE_NAME"; then
      echo "failed to restart $SERVICE_NAME after backup" >&2
      status=1
    fi
  fi
  if [ "$status" -eq 0 ]; then
    if ! start_proxy_sockets; then
      echo "failed to restore Finwealth Docker bridge proxy sockets after backup" >&2
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$LEDGER_PATH" ] || [ -L "$LEDGER_PATH" ]; then
  echo "ledger must be a regular non-symlink file: $LEDGER_PATH" >&2
  exit 2
fi

if [[ "$LEDGER_PATH" == *.json ]]; then
  AUTH_PATH="${LEDGER_PATH%.json}.auth.json"
else
  AUTH_PATH="${LEDGER_PATH}.auth.json"
fi
if [ -L "$AUTH_PATH" ]; then
  echo "auth state must not be a symlink: $AUTH_PATH" >&2
  exit 2
fi

if [ "$STOP_SERVICE" = "true" ] && [ -n "$SERVICE_NAME" ]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; set FINWEALTH_BACKUP_STOP_SERVICE=false only for an already-offline ledger" >&2
    exit 2
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    SERVICE_WAS_ACTIVE="true"
    stop_proxy_companions
    systemctl stop "$SERVICE_NAME"
  fi
fi

install -d -m 0700 "$BACKUP_ROOT"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
STAGING="$(mktemp -d "$BACKUP_ROOT/.backup-$TIMESTAMP.XXXXXX")"

install -m 0600 "$LEDGER_PATH" "$STAGING/ledger.json"
FILES=("ledger.json")
INCLUDES_AUTH="false"
if [ -f "$AUTH_PATH" ]; then
  install -m 0600 "$AUTH_PATH" "$STAGING/ledger.auth.json"
  FILES+=("ledger.auth.json")
  INCLUDES_AUTH="true"
fi

VALIDATED_LEDGER="false"
VALIDATED_AUTH="not_present"
if [ -x "$SERVER_BIN" ]; then
  if "$SERVER_BIN" --validate-ledger "$STAGING/ledger.json"; then
    VALIDATED_LEDGER="true"
  elif [ "$ALLOW_UNVALIDATED" = "true" ]; then
    echo "warning: copied ledger failed validation; preserving it as an unvalidated emergency backup" >&2
  else
    exit 2
  fi
  if [ "$INCLUDES_AUTH" = "true" ]; then
    if "$SERVER_BIN" --validate-auth-state "$STAGING/ledger.auth.json"; then
      VALIDATED_AUTH="true"
    elif [ "$ALLOW_UNVALIDATED" = "true" ]; then
      VALIDATED_AUTH="false"
      echo "warning: copied auth state failed validation; preserving it as an unvalidated emergency backup" >&2
    else
      exit 2
    fi
  fi
elif [ "$ALLOW_UNVALIDATED" != "true" ]; then
  echo "$SERVER_BIN not found; refusing an unvalidated backup" >&2
  echo "set FINWEALTH_ALLOW_UNVALIDATED_BACKUP=true only for an emergency copy" >&2
  exit 2
fi

(
  cd "$STAGING"
  sha256sum "${FILES[@]}" > SHA256SUMS
)
chmod 0600 "$STAGING/SHA256SUMS"

{
  echo "backupFormat=1"
  echo "createdAt=$(date -u --iso-8601=seconds)"
  echo "ledgerFile=ledger.json"
  echo "includesAuth=$INCLUDES_AUTH"
  if [ "$INCLUDES_AUTH" = "true" ]; then
    echo "authFile=ledger.auth.json"
  fi
  echo "validatedLedger=$VALIDATED_LEDGER"
  echo "validatedAuth=$VALIDATED_AUTH"
  echo "serviceStopped=$SERVICE_WAS_ACTIVE"
} > "$STAGING/manifest.txt"
chmod 0600 "$STAGING/manifest.txt"

TARGET="$BACKUP_ROOT/$TIMESTAMP"
suffix=1
while [ -e "$TARGET" ]; do
  TARGET="$BACKUP_ROOT/$TIMESTAMP-$suffix"
  suffix=$((suffix + 1))
done
mv -- "$STAGING" "$TARGET"
STAGING=""

echo "Backup created: $TARGET"

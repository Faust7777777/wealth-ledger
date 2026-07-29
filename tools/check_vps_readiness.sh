#!/usr/bin/env bash
set -euo pipefail

APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
APP_DIR="${FINWEALTH_DEPLOY_DIR:-/opt/finwealth}"
DATA_DIR="${FINWEALTH_DATA_DIR:-/var/lib/finwealth}"
CONFIG_DIR="${FINWEALTH_CONFIG_DIR:-/etc/finwealth}"
ENV_FILE="${FINWEALTH_ENV_FILE:-$CONFIG_DIR/server.env}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"
BIN="$APP_DIR/finwealth-server"
LEDGER="$DATA_DIR/ledger.json"
AUTH_STATE="$DATA_DIR/ledger.auth.json"
UPDATE_DIR="${FINWEALTH_CLIENT_UPDATE_DIR:-/var/lib/finwealth-updates}"
PUBLIC_BASE_URL=""

if [ "${1:-}" = "--public-base-url" ]; then
  PUBLIC_BASE_URL="${2:-}"
  shift 2
fi
if [ "$#" -ne 0 ]; then
  echo "usage: sudo bash tools/check_vps_readiness.sh [--public-base-url https://api.example.com]" >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root so file ownership and the system service can be verified." >&2
  exit 2
fi

fail() {
  echo "VPS readiness failed: $1" >&2
  exit 1
}

[ -x "$BIN" ] || fail "installed server binary is missing"
[ -f "$ENV_FILE" ] || fail "server.env is missing"
[ ! -L "$ENV_FILE" ] || fail "server.env must not be a symbolic link"
[ "$(stat -c '%a' "$ENV_FILE")" = "600" ] || fail "server.env mode must be 0600"
[ "$(stat -c '%U:%G' "$ENV_FILE")" = "root:root" ] || fail "server.env must be owned by root:root"
if grep -q "change-me" "$ENV_FILE"; then
  fail "server.env still contains a placeholder"
fi
[ -d "$DATA_DIR" ] || fail "data directory is missing"
[ ! -L "$DATA_DIR" ] || fail "data directory must not be a symbolic link"
[ "$(stat -c '%a' "$DATA_DIR")" = "700" ] || fail "data directory mode must be 0700"
[ "$(stat -c '%U:%G' "$DATA_DIR")" = "$APP_USER:$APP_USER" ] || fail "data directory owner is incorrect"
[ -d "$UPDATE_DIR" ] || fail "client update directory is missing"
[ ! -L "$UPDATE_DIR" ] || fail "client update directory must not be a symbolic link"
[ "$(stat -c '%a' "$UPDATE_DIR")" = "755" ] || fail "client update directory mode must be 0755"
[ "$(stat -c '%U:%G' "$UPDATE_DIR")" = "root:$APP_USER" ] || fail "client update directory owner is incorrect"

systemd-run \
  --wait \
  --pipe \
  --quiet \
  --collect \
  --unit="finwealth-readiness-config-$$" \
  --property="User=$APP_USER" \
  --property="Group=$APP_USER" \
  --property="EnvironmentFile=$ENV_FILE" \
  "$BIN" --check-production-config

[ -f "$LEDGER" ] || fail "ledger.json is missing"
runuser -u "$APP_USER" -- "$BIN" --validate-ledger "$LEDGER" >/dev/null
if [ -e "$AUTH_STATE" ]; then
  [ -f "$AUTH_STATE" ] || fail "auth state is not a regular file"
  [ ! -L "$AUTH_STATE" ] || fail "auth state must not be a symbolic link"
  runuser -u "$APP_USER" -- "$BIN" --validate-auth-state "$AUTH_STATE" >/dev/null
fi

systemctl is-active --quiet "$SERVICE_NAME" || fail "service is not active"
curl --fail --silent --show-error --max-time 10 \
  http://127.0.0.1:8790/v1/health >/dev/null || fail "loopback health check failed"

if command -v ss >/dev/null 2>&1; then
  if ss -ltnH | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\[::\]):8790([[:space:]]|$)'; then
    fail "ledger server is listening on a wildcard public address"
  fi
  ss -ltnH | grep -Eq '127\.0\.0\.1:8790([[:space:]]|$)' ||
    fail "ledger server is not listening on 127.0.0.1:8790"
fi

if [ -n "$PUBLIC_BASE_URL" ]; then
  case "$PUBLIC_BASE_URL" in
    https://* ) ;;
    * ) fail "public base URL must use HTTPS" ;;
  esac
  if printf '%s' "${PUBLIC_BASE_URL#https://}" | grep -q '/'; then
    fail "public base URL must be an origin without a path"
  fi
  curl --fail --silent --show-error --max-time 15 \
    "$PUBLIC_BASE_URL/v1/health" >/dev/null || fail "public HTTPS health check failed"
  UPDATE_STATUS="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 \
    "$PUBLIC_BASE_URL/v1/client-updates/android/stable/latest")"
  case "$UPDATE_STATUS" in
    200|404) ;;
    *) fail "public client update route returned HTTP $UPDATE_STATUS" ;;
  esac
fi

echo "Finwealth VPS readiness passed."

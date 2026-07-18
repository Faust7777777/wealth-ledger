#!/usr/bin/env bash
set -euo pipefail

USERNAME="${1:-}"
ALLOWED_HOST="${2:-}"
APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
APP_DIR="${FINWEALTH_DEPLOY_DIR:-/opt/finwealth}"
CONFIG_DIR="${FINWEALTH_CONFIG_DIR:-/etc/finwealth}"
ENV_FILE="${FINWEALTH_ENV_FILE:-$CONFIG_DIR/server.env}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash tools/configure_vps_auth.sh USERNAME PUBLIC_HOST" >&2
  exit 2
fi
if [ -z "$USERNAME" ] || [ -z "$ALLOWED_HOST" ]; then
  echo "Usage: $0 USERNAME PUBLIC_HOST" >&2
  exit 2
fi
if ! [[ "$USERNAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "Username must contain only letters, numbers, dot, underscore or hyphen." >&2
  exit 2
fi
if ! [[ "$ALLOWED_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Public host is invalid." >&2
  exit 2
fi
if [ ! -x "$APP_DIR/finwealth-server" ]; then
  echo "Installed Finwealth server binary is missing." >&2
  exit 2
fi

read -rsp 'Finwealth password (minimum 12 characters): ' PASSWORD
echo
read -rsp 'Confirm Finwealth password: ' PASSWORD_CONFIRM
echo
if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
  unset PASSWORD PASSWORD_CONFIRM
  echo "Passwords do not match." >&2
  exit 2
fi
if [ "${#PASSWORD}" -lt 12 ]; then
  unset PASSWORD PASSWORD_CONFIRM
  echo "Password must be at least 12 characters." >&2
  exit 2
fi

PASSWORD_HASH="$(printf '%s' "$PASSWORD" | "$APP_DIR/finwealth-server" --hash-password-stdin)"
unset PASSWORD PASSWORD_CONFIRM
if [[ "$PASSWORD_HASH" != \$argon2* ]]; then
  unset PASSWORD_HASH
  echo "Server did not produce an Argon2 password hash." >&2
  exit 2
fi

umask 077
install -d -m 0750 "$CONFIG_DIR"
TEMP_ENV="$(mktemp "$CONFIG_DIR/.server.env.XXXXXX")"
cleanup() {
  rm -f -- "$TEMP_ENV"
  unset PASSWORD_HASH
}
trap cleanup EXIT

{
  printf 'FINWEALTH_REQUIRE_AUTH=true\n'
  printf 'FINWEALTH_AUTH_USERNAME=%s\n' "$USERNAME"
  printf 'FINWEALTH_AUTH_PASSWORD_HASH=%s\n' "$PASSWORD_HASH"
  printf 'FINWEALTH_RS_ADDR=127.0.0.1:8790\n'
  printf 'FINWEALTH_ALLOWED_HOSTS=%s\n' "$ALLOWED_HOST"
  printf 'FINWEALTH_QUOTE_PROVIDER=none\n'
  printf 'FINWEALTH_AI_PROVIDER=none\n'
} >"$TEMP_ENV"
chown root:root "$TEMP_ENV"
chmod 0600 "$TEMP_ENV"

echo "Validating production configuration before publishing it..."
systemd-run \
  --wait \
  --pipe \
  --quiet \
  --collect \
  --unit="finwealth-auth-config-check-$$" \
  --property="User=$APP_USER" \
  --property="Group=$APP_USER" \
  --property="EnvironmentFile=$TEMP_ENV" \
  "$APP_DIR/finwealth-server" --check-production-config

if [ -f "$ENV_FILE" ]; then
  BACKUP="$ENV_FILE.before-auth-$(date -u +%Y%m%dT%H%M%SZ)"
  cp --preserve=mode,ownership,timestamps "$ENV_FILE" "$BACKUP"
  chmod 0600 "$BACKUP"
fi
mv -f -- "$TEMP_ENV" "$ENV_FILE"
trap - EXIT
unset PASSWORD_HASH

systemctl enable --now "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME"
echo "Finwealth production authentication configured and service started."

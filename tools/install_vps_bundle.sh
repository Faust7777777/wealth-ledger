#!/usr/bin/env bash
set -euo pipefail

APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
APP_DIR="${FINWEALTH_DEPLOY_DIR:-/opt/finwealth}"
DATA_DIR="${FINWEALTH_DATA_DIR:-/var/lib/finwealth}"
CONFIG_DIR="${FINWEALTH_CONFIG_DIR:-/etc/finwealth}"
UPDATE_DIR="${FINWEALTH_CLIENT_UPDATE_DIR:-/var/lib/finwealth-updates}"
ENV_FILE="${FINWEALTH_ENV_FILE:-$CONFIG_DIR/server.env}"
SERVICE_FILE="${FINWEALTH_SERVICE_FILE:-/etc/systemd/system/finwealth-server.service}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"
CHECK_ONLY=false
if [ "${1:-}" = "--check-bundle-only" ]; then
  CHECK_ONLY=true
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--check-bundle-only]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/finwealth-server"

if [ ! -f "$ROOT/SHA256SUMS" ]; then
  echo "Bundle SHA256SUMS is missing." >&2
  exit 2
fi
(
  cd "$ROOT"
  sha256sum -c SHA256SUMS
)

PACKAGE_ARCH="$(sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p' "$ROOT/package-manifest.json")"
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH="x86_64" ;;
  aarch64|arm64) HOST_ARCH="aarch64" ;;
  *) echo "Unsupported VPS architecture: $(uname -m)" >&2; exit 2 ;;
esac
if [ "$PACKAGE_ARCH" != "$HOST_ARCH" ]; then
  echo "Bundle architecture $PACKAGE_ARCH does not match VPS architecture $HOST_ARCH." >&2
  exit 2
fi

if [ "$CHECK_ONLY" = true ]; then
  echo "Finwealth VPS bundle integrity and architecture checks passed."
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash tools/install_vps_bundle.sh" >&2
  exit 2
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

install -d -m 0755 "$APP_DIR" "$APP_DIR/tools"
install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$DATA_DIR"
install -d -m 0755 -o root -g "$APP_USER" "$UPDATE_DIR"
install -d -m 0750 "$CONFIG_DIR"
install -m 0755 "$BIN" "$APP_DIR/finwealth-server"
install -m 0755 "$ROOT/tools/check_vps_readiness.sh" "$APP_DIR/tools/"
install -m 0755 "$ROOT/tools/configure_vps_auth.sh" "$APP_DIR/tools/"
install -m 0755 "$ROOT/tools/backup_vps_ledger.sh" "$APP_DIR/tools/"
install -m 0755 "$ROOT/tools/restore_vps_ledger.sh" "$APP_DIR/tools/"
install -m 0755 "$ROOT/tools/publish_client_update.py" "$APP_DIR/tools/"
install -m 0755 "$ROOT/tools/patch_vps_caddy_client_update_route.py" "$APP_DIR/tools/"

if [ ! -f "$ENV_FILE" ]; then
  install -m 0600 "$ROOT/deploy/finwealth-server.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from example."
fi
if ! grep -q '^FINWEALTH_CLIENT_UPDATE_DIR=' "$ENV_FILE"; then
  printf '\nFINWEALTH_CLIENT_UPDATE_DIR=%s\n' "$UPDATE_DIR" >>"$ENV_FILE"
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

install -m 0644 "$ROOT/deploy/systemd/finwealth-server.service" "$SERVICE_FILE"
install -m 0644 "$ROOT/deploy/systemd/finwealth-docker-proxy@.socket" \
  /etc/systemd/system/finwealth-docker-proxy@.socket
install -m 0644 "$ROOT/deploy/systemd/finwealth-docker-proxy@.service" \
  /etc/systemd/system/finwealth-docker-proxy@.service
systemctl daemon-reload

if grep -q "change-me" "$ENV_FILE"; then
  cat >&2 <<EOF
Installed the prebuilt Finwealth server, but did not start it because
$ENV_FILE still has change-me placeholders.

Generate an Argon2 password hash without storing plaintext:
  read -rsp 'Finwealth password: ' FINWEALTH_PASSWORD; echo
  printf '%s' "\$FINWEALTH_PASSWORD" | $APP_DIR/finwealth-server --hash-password-stdin
  unset FINWEALTH_PASSWORD

Then edit $ENV_FILE and start $SERVICE_NAME.
EOF
  exit 0
fi

echo "Validating production configuration..."
systemd-run \
  --wait \
  --pipe \
  --quiet \
  --collect \
  --unit="finwealth-config-check-$$" \
  --property="User=$APP_USER" \
  --property="Group=$APP_USER" \
  --property="EnvironmentFile=$ENV_FILE" \
  "$APP_DIR/finwealth-server" --check-production-config

systemctl enable --now "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager

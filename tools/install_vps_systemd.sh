#!/usr/bin/env bash
set -euo pipefail

APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
APP_DIR="${FINWEALTH_DEPLOY_DIR:-/opt/finwealth}"
DATA_DIR="${FINWEALTH_DATA_DIR:-/var/lib/finwealth}"
CONFIG_DIR="${FINWEALTH_CONFIG_DIR:-/etc/finwealth}"
ENV_FILE="${FINWEALTH_ENV_FILE:-$CONFIG_DIR/server.env}"
SERVICE_FILE="${FINWEALTH_SERVICE_FILE:-/etc/systemd/system/finwealth-server.service}"
SERVICE_NAME="${FINWEALTH_SERVICE_NAME:-finwealth-server.service}"
BIN_NAME="finwealth-server"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash tools/install_vps_systemd.sh" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/server-rs/Cargo.toml"
RELEASE_BIN="$ROOT/server-rs/target/release/$BIN_NAME"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust with rustup before running this script." >&2
  exit 2
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

install -d -m 0755 "$APP_DIR"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$DATA_DIR"
install -d -m 0750 "$CONFIG_DIR"

echo "Building release binary..."
cargo build --manifest-path "$MANIFEST" --release
install -m 0755 "$RELEASE_BIN" "$APP_DIR/$BIN_NAME"

if [ ! -f "$ENV_FILE" ]; then
  install -m 0600 "$ROOT/deploy/finwealth-server.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from example."
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

install -m 0644 "$ROOT/deploy/systemd/finwealth-server.service" "$SERVICE_FILE"
systemctl daemon-reload

if grep -q "change-me" "$ENV_FILE"; then
  cat >&2 <<EOF
Installed $BIN_NAME, but did not start the service because $ENV_FILE still has change-me placeholders.

Generate a password hash:
  read -rsp 'Finwealth password: ' FINWEALTH_PASSWORD; echo
  printf '%s' "\$FINWEALTH_PASSWORD" | $APP_DIR/$BIN_NAME --hash-password-stdin
  unset FINWEALTH_PASSWORD

Then edit:
  sudoedit $ENV_FILE

Finally start:
  sudo systemctl enable --now $SERVICE_NAME
EOF
  exit 0
fi

systemctl enable --now "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager

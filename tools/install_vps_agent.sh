#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${FINWEALTH_DEPLOY_DIR:-/opt/finwealth}"
CONFIG_DIR="${FINWEALTH_CONFIG_DIR:-/etc/finwealth}"
DATA_DIR="${FINWEALTH_AGENT_STATE_DIR:-/var/lib/finwealth-agent}"
APP_USER="${FINWEALTH_DEPLOY_USER:-finwealth}"
ENV_FILE="${FINWEALTH_AGENT_ENV_FILE:-$CONFIG_DIR/agent.env}"
SERVICE_FILE="${FINWEALTH_AGENT_SERVICE_FILE:-/etc/systemd/system/finwealth-agent.service}"

start_proxy_sockets() {
  local socket
  while read -r socket; do
    [ -n "$socket" ] && systemctl start "$socket"
  done < <(
    find /etc/systemd/system -maxdepth 3 -type l \
      -name 'finwealth-docker-proxy@*.socket' -printf '%f\n' | sort -u
  )
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash tools/install_vps_agent.sh" >&2
  exit 2
fi
for command in node npm bwrap pdftotext unzip python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required for the Finwealth Agent service (Debian/Ubuntu packages: bubblewrap poppler-utils unzip python3)." >&2
    exit 2
  }
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "Node.js 22 or newer is required." >&2
  exit 2
fi
bash "$ROOT/tools/agent_workspace_sandbox_smoke.sh"
if ! id "$APP_USER" >/dev/null 2>&1; then
  echo "Finwealth service user $APP_USER does not exist; install the Rust server first." >&2
  exit 2
fi

cd "$ROOT/agent-service"
npm ci
npm run check
npm test
npm run build
npm audit --omit=dev --audit-level=high

install -d -m 0755 "$APP_DIR/agent-service"
install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$DATA_DIR"
install -d -m 0750 "$CONFIG_DIR"
rm -rf "$APP_DIR/agent-service/dist" "$APP_DIR/agent-service/node_modules"
cp -a dist "$APP_DIR/agent-service/"
install -m 0644 package.json package-lock.json "$APP_DIR/agent-service/"
cd "$APP_DIR/agent-service"
npm ci --omit=dev --ignore-scripts

if [ ! -f "$ENV_FILE" ]; then
  install -m 0600 "$ROOT/deploy/finwealth-agent.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from example."
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"
install -m 0644 "$ROOT/deploy/systemd/finwealth-agent.service" "$SERVICE_FILE"
systemctl daemon-reload

if grep -q "change-me" "$ENV_FILE"; then
  echo "Agent files installed but not started: replace change-me in $ENV_FILE and add the matching token to server.env." >&2
  exit 0
fi
if ! grep -q '^FINWEALTH_AGENT_INTERNAL_TOKEN=' "$CONFIG_DIR/server.env"; then
  echo "$CONFIG_DIR/server.env does not contain the matching FINWEALTH_AGENT_INTERNAL_TOKEN; refusing to start." >&2
  exit 2
fi
systemctl enable --now finwealth-agent.service
systemctl restart finwealth-server.service
start_proxy_sockets
systemctl status finwealth-agent.service --no-pager

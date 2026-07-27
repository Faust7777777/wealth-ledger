#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${1:-/var/lib/finwealth-agent}"
BACKUP_ROOT="${2:-/var/backups/finwealth-agent}"
SERVICE_NAME="${FINWEALTH_AGENT_SERVICE_NAME:-finwealth-agent.service}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash tools/backup_vps_agent.sh" >&2
  exit 2
fi
if [ ! -d "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
  echo "Agent state directory must be a real directory: $STATE_DIR" >&2
  exit 2
fi
mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
STAGING="$(mktemp -d "$BACKUP_ROOT/.backup-$TIMESTAMP.XXXXXX")"
TARGET="$BACKUP_ROOT/$TIMESTAMP"
WAS_ACTIVE=false
cleanup() {
  rm -rf -- "$STAGING"
  if [ "$WAS_ACTIVE" = true ]; then systemctl start "$SERVICE_NAME"; fi
}
trap cleanup EXIT
if systemctl is-active --quiet "$SERVICE_NAME"; then
  WAS_ACTIVE=true
  systemctl stop "$SERVICE_NAME"
fi

tar --numeric-owner -C "$STATE_DIR" -czf "$STAGING/agent-state.tar.gz" .
cat >"$STAGING/manifest.txt" <<EOF
backupFormat=1
createdAt=$TIMESTAMP
source=$STATE_DIR
containsModelCredentials=true
EOF
(
  cd "$STAGING"
  sha256sum agent-state.tar.gz manifest.txt >SHA256SUMS
  sha256sum -c SHA256SUMS
)
chmod -R go-rwx "$STAGING"
mv "$STAGING" "$TARGET"
trap - EXIT
if [ "$WAS_ACTIVE" = true ]; then systemctl start "$SERVICE_NAME"; fi
echo "Finwealth Agent backup: $TARGET"

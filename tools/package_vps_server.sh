#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/dist}"
MANIFEST="$ROOT/server-rs/Cargo.toml"
BIN="$ROOT/server-rs/target/release/finwealth-server"

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "Source worktree is dirty; refusing to package a VPS server bundle." >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) echo "Unsupported packaging architecture: $(uname -m)" >&2; exit 2 ;;
esac

VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$MANIFEST" | head -n 1)"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="finwealth-server-${VERSION}-${STAMP}-linux-${ARCH}-vps"

mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d)"
trap 'rm -rf -- "$STAGING"' EXIT
BUNDLE="$STAGING/$NAME"
mkdir -p "$BUNDLE/bin" "$BUNDLE/deploy/systemd" "$BUNDLE/tools" "$BUNDLE/docs"

cargo build --manifest-path "$MANIFEST" --release --locked
cp "$BIN" "$BUNDLE/bin/finwealth-server"
if command -v strip >/dev/null 2>&1; then
  strip "$BUNDLE/bin/finwealth-server"
fi

cp "$ROOT/deploy/finwealth-server.env.example" "$BUNDLE/deploy/"
cp "$ROOT/deploy/systemd/finwealth-server.service" "$BUNDLE/deploy/systemd/"
cp "$ROOT/tools/install_vps_bundle.sh" "$BUNDLE/tools/"
cp "$ROOT/tools/check_vps_readiness.sh" "$BUNDLE/tools/"
cp "$ROOT/tools/backup_vps_ledger.sh" "$BUNDLE/tools/"
cp "$ROOT/tools/restore_vps_ledger.sh" "$BUNDLE/tools/"
cp "$ROOT/docs/deploy/VPS_DEPLOYMENT.md" "$BUNDLE/docs/"

cat >"$BUNDLE/package-manifest.json" <<EOF
{"packageFormat":1,"serverVersion":"$VERSION","createdAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","sourceCommit":"$SOURCE_COMMIT","sourceDirty":false,"platform":"linux","architecture":"$ARCH"}
EOF

cat >"$BUNDLE/README.md" <<'EOF'
# Finwealth prebuilt VPS server bundle

Verify and install as root:

```bash
sha256sum -c SHA256SUMS
bash tools/install_vps_bundle.sh
```

The installer preserves an existing `/etc/finwealth/server.env` and ledger.
With the example `change-me` values it installs files but intentionally does not
start the service. Follow `docs/VPS_DEPLOYMENT.md` to configure authentication
and the HTTPS reverse proxy.
EOF

chmod 0755 "$BUNDLE/bin/finwealth-server" "$BUNDLE/tools/"*.sh
(
  cd "$BUNDLE"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
  sha256sum -c SHA256SUMS
  bash tools/install_vps_bundle.sh --check-bundle-only
)

ARCHIVE="$OUTPUT_DIR/$NAME.tar.gz"
tar -C "$STAGING" -czf "$ARCHIVE" "$NAME"
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"

echo "VPS server bundle: $ARCHIVE"
echo "VPS server bundle SHA-256: $(sha256sum "$ARCHIVE" | awk '{print $1}')"

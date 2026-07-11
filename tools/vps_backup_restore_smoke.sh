#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
DATA_DIR="$TMP/data"
BACKUP_ROOT="$TMP/backups"
PRE_RESTORE_ROOT="$TMP/pre-restore"
STATE_FILE="$TMP/systemctl.state"
SYSTEMCTL_LOG="$TMP/systemctl.log"
FAIL_MARKER="$TMP/fail-live-validation"
START_FAIL_MARKER="$TMP/fail-service-start"
mkdir -p "$FAKE_BIN" "$DATA_DIR" "$BACKUP_ROOT"
printf '%s\n' active > "$STATE_FILE"
: > "$SYSTEMCTL_LOG"

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "${1:-}" in
  is-active)
    [ "$(cat "$FAKE_SYSTEMCTL_STATE")" = "active" ]
    ;;
  stop)
    printf '%s\n' inactive > "$FAKE_SYSTEMCTL_STATE"
    ;;
  start)
    if [ -n "${FAKE_START_FAIL_MARKER:-}" ] && [ -f "$FAKE_START_FAIL_MARKER" ]; then
      rm -f -- "$FAKE_START_FAIL_MARKER"
      printf '%s\n' inactive > "$FAKE_SYSTEMCTL_STATE"
      exit 1
    fi
    printf '%s\n' active > "$FAKE_SYSTEMCTL_STATE"
    ;;
  *)
    echo "unexpected fake systemctl command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "$FAKE_BIN/systemctl"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    cat > "$FAKE_BIN/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
directory_mode="false"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      directory_mode="true"
      shift
      ;;
    -m|-o|-g)
      shift 2
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ "$directory_mode" = "true" ]; then
  mkdir -p -- "${args[@]}"
else
  if [ "${#args[@]}" -ne 2 ]; then
    echo "unexpected fake install arguments: ${args[*]}" >&2
    exit 2
  fi
  cp -- "${args[0]}" "${args[1]}"
fi
EOF
    chmod 0755 "$FAKE_BIN/install"
    ;;
esac

cat > "$FAKE_BIN/finwealth-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --validate-ledger|--validate-auth-state)
    "$FAKE_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$2"
    if [ "${FAKE_FAIL_PATH:-}" = "$2" ] && [ -f "${FAKE_FAIL_MARKER:-/nonexistent}" ]; then
      rm -f -- "$FAKE_FAIL_MARKER"
      echo "injected post-commit validation failure" >&2
      exit 1
    fi
    ;;
  *)
    echo "unexpected validator command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "$FAKE_BIN/finwealth-server"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
  FAKE_PYTHON="$(command -v python3)"
else
  FAKE_PYTHON="$(command -v python)"
fi
export FAKE_PYTHON
export FAKE_SYSTEMCTL_STATE="$STATE_FILE"
export FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG"
export FAKE_START_FAIL_MARKER="$START_FAIL_MARKER"
export PATH="$FAKE_BIN:$PATH"

LEDGER="$DATA_DIR/ledger.json"
AUTH="$DATA_DIR/ledger.auth.json"
printf '%s\n' '{"ledgerVersion":1,"state":"backup-source"}' > "$LEDGER"
printf '%s\n' '{"version":1,"devices":[]}' > "$AUTH"

run_backup() {
  FINWEALTH_SERVER_BIN="$FAKE_BIN/finwealth-server" \
  FINWEALTH_SERVICE_NAME="finwealth-test.service" \
    bash "$ROOT/tools/backup_vps_ledger.sh" "$LEDGER" "$1"
}

run_restore() {
  FINWEALTH_SERVER_BIN="$FAKE_BIN/finwealth-server" \
  FINWEALTH_SERVICE_NAME="finwealth-test.service" \
  FINWEALTH_DEPLOY_USER="finwealth-test-user-does-not-exist" \
  FINWEALTH_PRE_RESTORE_BACKUP_DIR="$PRE_RESTORE_ROOT" \
    bash "$ROOT/tools/restore_vps_ledger.sh" --force "$1" "$LEDGER"
}

latest_backup() {
  find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print | sort | tail -n 1
}

run_backup "$BACKUP_ROOT"
FIRST_BACKUP="$(latest_backup "$BACKUP_ROOT")"
[ -f "$FIRST_BACKUP/ledger.json" ]
[ -f "$FIRST_BACKUP/ledger.auth.json" ]
[ -f "$FIRST_BACKUP/manifest.txt" ]
[ -f "$FIRST_BACKUP/SHA256SUMS" ]
(cd "$FIRST_BACKUP" && sha256sum -c SHA256SUMS >/dev/null)
grep -qx 'backupFormat=1' "$FIRST_BACKUP/manifest.txt"
grep -qx 'includesAuth=true' "$FIRST_BACKUP/manifest.txt"
[ "$(cat "$STATE_FILE")" = "active" ]
grep -q '^stop finwealth-test.service$' "$SYSTEMCTL_LOG"
grep -q '^start finwealth-test.service$' "$SYSTEMCTL_LOG"

CORRUPT_BACKUP="$TMP/corrupt-backup"
cp -R "$FIRST_BACKUP" "$CORRUPT_BACKUP"
printf '%s\n' '{"ledgerVersion":1,"state":"tampered"}' > "$CORRUPT_BACKUP/ledger.json"
if run_restore "$CORRUPT_BACKUP" >/dev/null 2>&1; then
  echo "restore unexpectedly accepted a checksum mismatch" >&2
  exit 1
fi

printf '%s\n' '{"ledgerVersion":1,"state":"new-live-state"}' > "$LEDGER"
printf '%s\n' '{"version":1,"devices":[{"id":"new"}]}' > "$AUTH"
run_restore "$FIRST_BACKUP"
cmp -s "$FIRST_BACKUP/ledger.json" "$LEDGER"
cmp -s "$FIRST_BACKUP/ledger.auth.json" "$AUTH"
[ "$(cat "$STATE_FILE")" = "active" ]

NO_AUTH_ROOT="$TMP/no-auth-backups"
rm -f -- "$AUTH"
printf '%s\n' '{"ledgerVersion":1,"state":"no-auth-source"}' > "$LEDGER"
run_backup "$NO_AUTH_ROOT"
NO_AUTH_BACKUP="$(latest_backup "$NO_AUTH_ROOT")"
grep -qx 'includesAuth=false' "$NO_AUTH_BACKUP/manifest.txt"
printf '%s\n' '{"version":1,"devices":[]}' > "$AUTH"
run_restore "$NO_AUTH_BACKUP"
[ ! -e "$AUTH" ]

printf '%s\n' '{"ledgerVersion":1,"state":"rollback-original"}' > "$LEDGER"
printf '%s\n' '{"version":1,"devices":[]}' > "$AUTH"
export FAKE_FAIL_PATH="$LEDGER"
export FAKE_FAIL_MARKER="$FAIL_MARKER"
: > "$FAIL_MARKER"
if run_restore "$FIRST_BACKUP" >/dev/null 2>&1; then
  echo "restore unexpectedly survived injected post-commit validation failure" >&2
  exit 1
fi
grep -q '"rollback-original"' "$LEDGER"
grep -q '"devices":\[\]' "$AUTH"
[ "$(cat "$STATE_FILE")" = "active" ]

printf '%s\n' '{"ledgerVersion":1,"state":"service-rollback-original"}' > "$LEDGER"
printf '%s\n' '{"version":1,"devices":[]}' > "$AUTH"
: > "$START_FAIL_MARKER"
if run_restore "$FIRST_BACKUP" >/dev/null 2>&1; then
  echo "restore unexpectedly survived injected service startup failure" >&2
  exit 1
fi
grep -q '"service-rollback-original"' "$LEDGER"
grep -q '"devices":\[\]' "$AUTH"
[ "$(cat "$STATE_FILE")" = "active" ]

if FINWEALTH_SERVER_BIN="$FAKE_BIN/finwealth-server" \
  FINWEALTH_SERVICE_NAME="finwealth-test.service" \
  bash "$ROOT/tools/restore_vps_ledger.sh" --force "$FIRST_BACKUP/ledger.json" "$LEDGER" \
  >/dev/null 2>&1; then
  echo "direct ledger restore unexpectedly bypassed --allow-unverified" >&2
  exit 1
fi

echo "OK: VPS backup/restore smoke passed"

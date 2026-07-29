#!/usr/bin/env bash
set -euo pipefail

command -v bwrap >/dev/null 2>&1 || {
  echo "bubblewrap is required" >&2
  exit 2
}
ROOT="$(mktemp -d)"
WORKSPACE="$ROOT/workspace"
mkdir -p "$WORKSPACE"
printf 'outside' >"$ROOT/outside.txt"
cleanup() { rm -rf -- "$ROOT"; }
trap cleanup EXIT

ARGS=(
  --die-with-parent
  --new-session
  --unshare-all
  --share-net
  --proc /proc
  --dev /dev
  --tmpfs /tmp
)
for path in \
  /usr /bin /lib /lib64 \
  /etc/ssl /etc/resolv.conf /etc/hosts /etc/nsswitch.conf \
  /etc/passwd /etc/group /etc/localtime; do
  if [ -e "$path" ]; then ARGS+=(--ro-bind "$path" "$path"); fi
done
ARGS+=(
  --bind "$WORKSPACE" /workspace
  --chdir /workspace
  --setenv HOME /workspace
  --setenv PATH /usr/local/bin:/usr/bin:/bin
  -- /bin/bash -lc
  'test "$PWD" = /workspace
   test ! -e /etc/finwealth
   test ! -e "'"$ROOT"'/outside.txt"
   printf inside > note.txt
   test "$(cat note.txt)" = inside'
)
bwrap "${ARGS[@]}"
test "$(cat "$WORKSPACE/note.txt")" = inside
echo "OK: Agent workspace bubblewrap boundary passed."

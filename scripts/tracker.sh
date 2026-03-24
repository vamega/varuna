#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools/opentracker"
RUNTIME_DIR="$TOOLS_DIR/runtime"
HOST="127.0.0.1"
PORT="6969"
WHITELIST_HASHES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --whitelist-hash)
      WHITELIST_HASHES+=("$2")
      shift 2
      ;;
    *)
      echo "unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$TOOLS_DIR" "$RUNTIME_DIR"

ensure_package() {
  local package="$1"
  local marker="$TOOLS_DIR/.${package}.ready"
  if [[ -f "$marker" ]]; then
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  (
    cd "$tmpdir"
    apt-get download "$package" >/dev/null
    dpkg-deb -x ./*.deb "$TOOLS_DIR"
  )

  touch "$marker"
  trap - RETURN
  rm -rf "$tmpdir"
}

ensure_package "libowfat0t64"
ensure_package "opentracker"

WHITELIST_FILE="$RUNTIME_DIR/whitelist.txt"
CONFIG_PATH="$RUNTIME_DIR/opentracker.conf"

{
  cat <<EOF
listen.tcp $HOST:$PORT
tracker.rootdir $RUNTIME_DIR
tracker.user $(id -un)
EOF
  if [[ "${#WHITELIST_HASHES[@]}" -gt 0 ]]; then
    printf 'access.whitelist %s\n' "$WHITELIST_FILE"
  fi
} >"$CONFIG_PATH"

if [[ "${#WHITELIST_HASHES[@]}" -gt 0 ]]; then
  printf '%s\n' "${WHITELIST_HASHES[@]}" >"$WHITELIST_FILE"
fi

echo "HTTP tracker: http://$HOST:$PORT/announce"
if [[ "${#WHITELIST_HASHES[@]}" -gt 0 ]]; then
  echo "whitelist hashes: ${#WHITELIST_HASHES[@]}"
else
  echo "warning: no whitelist hashes configured; this opentracker build will reject announces"
fi
exec env \
  LD_LIBRARY_PATH="$TOOLS_DIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$TOOLS_DIR/usr/bin/opentracker" \
  -f "$CONFIG_PATH"

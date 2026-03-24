#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.tools/opentracker"
RUNTIME_DIR="$TOOLS_DIR/runtime"
HOST="127.0.0.1"
PORT="6969"

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

cat >"$RUNTIME_DIR/opentracker.conf" <<EOF
listen.tcp $HOST:$PORT
tracker.rootdir $RUNTIME_DIR
tracker.user $(id -un)
EOF

echo "HTTP tracker: http://$HOST:$PORT/announce"
exec env \
  LD_LIBRARY_PATH="$TOOLS_DIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$TOOLS_DIR/usr/bin/opentracker" \
  -f "$RUNTIME_DIR/opentracker.conf"

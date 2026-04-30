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

# Resolve an opentracker binary. Two paths supported, in priority order:
#
#   1. Pre-staged Ubuntu .deb under .tools/opentracker/usr/bin/opentracker
#      (the original packaging path; uses apt-get + dpkg-deb).
#   2. `opentracker` on $PATH (covers nix-based environments where the
#      `nix shell nixpkgs#opentracker` flake adds it directly).
#
# This keeps the script portable across both Ubuntu/Debian CI and the
# nix-based dev shell used by the worktree harness, without forcing a
# package mirror to be reachable at run time.
ensure_package() {
  local package="$1"
  local marker="$TOOLS_DIR/.${package}.ready"
  if [[ -f "$marker" ]]; then
    return
  fi

  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
    # apt-get path unavailable — fall through to PATH lookup.
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

OPENTRACKER_BIN="$TOOLS_DIR/usr/bin/opentracker"
OPENTRACKER_LIBPATH="$TOOLS_DIR/usr/lib"
if [[ ! -x "$OPENTRACKER_BIN" ]]; then
  # Fall back to a system / nix-installed opentracker.
  if command -v opentracker >/dev/null 2>&1; then
    OPENTRACKER_BIN="$(command -v opentracker)"
    OPENTRACKER_LIBPATH=""
  else
    echo "tracker.sh: opentracker not found (no apt-get path, not on PATH); install via 'nix shell nixpkgs#opentracker' or apt" >&2
    exit 1
  fi
fi

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
if [[ -n "$OPENTRACKER_LIBPATH" ]]; then
  exec env \
    LD_LIBRARY_PATH="$OPENTRACKER_LIBPATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$OPENTRACKER_BIN" \
    -f "$CONFIG_PATH"
else
  exec "$OPENTRACKER_BIN" -f "$CONFIG_PATH"
fi

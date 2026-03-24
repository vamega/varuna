#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-swarm-XXXXXX)}"
TRACKER_PORT="${TRACKER_PORT:-6969}"
SEED_PORT="${SEED_PORT:-6881}"
DOWNLOAD_PORT="${DOWNLOAD_PORT:-6882}"
TRACKER_PID=""
SEED_PID=""

cleanup() {
  if [[ -n "$SEED_PID" ]] && kill -0 "$SEED_PID" 2>/dev/null; then
    kill "$SEED_PID" 2>/dev/null || true
    wait "$SEED_PID" 2>/dev/null || true
  fi

  if [[ -n "$TRACKER_PID" ]] && kill -0 "$TRACKER_PID" 2>/dev/null; then
    kill "$TRACKER_PID" 2>/dev/null || true
    wait "$TRACKER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_tcp() {
  local host="$1"
  local port="$2"

  for _ in $(seq 1 200); do
    if bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done

  echo "timed out waiting for $host:$port" >&2
  return 1
}

wait_for_log() {
  local file="$1"
  local pattern="$2"

  for _ in $(seq 1 200); do
    if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then
      return 0
    fi
    sleep 0.05
  done

  echo "timed out waiting for '$pattern' in $file" >&2
  return 1
}

mkdir -p "$WORK_DIR/seed-root" "$WORK_DIR/download-root"
PAYLOAD_PATH="$WORK_DIR/seed-root/fixture.bin"
TORRENT_PATH="$WORK_DIR/fixture.torrent"
TRACKER_LOG="$WORK_DIR/tracker.log"
SEED_LOG="$WORK_DIR/seed.log"
DOWNLOAD_LOG="$WORK_DIR/download.log"

printf 'hello from varuna swarm demo\n' >"$PAYLOAD_PATH"

mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
  --input "$PAYLOAD_PATH" \
  --output "$TORRENT_PATH" \
  --announce "http://127.0.0.1:$TRACKER_PORT/announce"

mise exec -- zig build >/dev/null

INFO_HASH="$("$ROOT_DIR/zig-out/bin/varuna" inspect "$TORRENT_PATH" | awk -F= '/^info_hash=/{print $2}')"
if [[ -z "$INFO_HASH" ]]; then
  echo "failed to extract torrent info hash" >&2
  exit 1
fi

"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH" >"$TRACKER_LOG" 2>&1 &
TRACKER_PID="$!"
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

"$ROOT_DIR/zig-out/bin/varuna" seed "$TORRENT_PATH" "$WORK_DIR/seed-root" --port "$SEED_PORT" >"$SEED_LOG" 2>&1 &
SEED_PID="$!"
wait_for_log "$SEED_LOG" "seed announce accepted"

"$ROOT_DIR/zig-out/bin/varuna" download "$TORRENT_PATH" "$WORK_DIR/download-root" --port "$DOWNLOAD_PORT" | tee "$DOWNLOAD_LOG"

wait "$SEED_PID"
SEED_PID=""

cmp "$PAYLOAD_PATH" "$WORK_DIR/download-root/fixture.bin"

cat <<EOF
swarm demo succeeded
work dir: $WORK_DIR
tracker log: $TRACKER_LOG
seed log: $SEED_LOG
download log: $DOWNLOAD_LOG
EOF

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-daemon-swarm-XXXXXX)}"
TRACKER_PORT="${TRACKER_PORT:-6971}"
SEED_PORT="${SEED_PORT:-6883}"
API_PORT="${API_PORT:-8080}"
DAEMON_PID=""
TRACKER_PID=""
SEED_PID=""

cleanup() {
  [[ -n "${DAEMON_PID:-}" ]] && kill "$DAEMON_PID" 2>/dev/null || true
  [[ -n "${SEED_PID:-}" ]] && kill "$SEED_PID" 2>/dev/null || true
  [[ -n "${TRACKER_PID:-}" ]] && kill "$TRACKER_PID" 2>/dev/null || true
  sleep 0.3
  wait "$DAEMON_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait "$TRACKER_PID" 2>/dev/null || true
}
trap cleanup EXIT

wait_for_tcp() {
  local host="$1"
  local port="$2"
  for _ in $(seq 1 100); do
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

# Create 100KB random payload
dd if=/dev/urandom of="$WORK_DIR/seed-root/payload.bin" bs=1024 count=100 2>/dev/null

mise exec -- zig build >/dev/null

"$ROOT_DIR/zig-out/bin/varuna-tools" create \
  -a "http://127.0.0.1:$TRACKER_PORT/announce" \
  -o "$WORK_DIR/test.torrent" \
  "$WORK_DIR/seed-root/payload.bin"

INFO_HASH="$("$ROOT_DIR/zig-out/bin/varuna-tools" inspect "$WORK_DIR/test.torrent" | awk -F= '/^info_hash=/{print $2}')"
if [[ -z "$INFO_HASH" ]]; then
  echo "failed to extract torrent info hash" >&2
  exit 1
fi

# Start tracker
"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH" >"$WORK_DIR/tracker.log" 2>&1 &
TRACKER_PID="$!"
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

# Start seeder
"$ROOT_DIR/zig-out/bin/varuna-tools" seed "$WORK_DIR/test.torrent" "$WORK_DIR/seed-root" --port "$SEED_PORT" >"$WORK_DIR/seed.log" 2>&1 &
SEED_PID="$!"
wait_for_log "$WORK_DIR/seed.log" "seed announce accepted"

# Start daemon
"$ROOT_DIR/zig-out/bin/varuna" >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID="$!"
wait_for_tcp 127.0.0.1 "$API_PORT"

# Add torrent via API
"$ROOT_DIR/zig-out/bin/varuna-ctl" add "$WORK_DIR/test.torrent" --save-path "$WORK_DIR/download-root"

# Wait for download to complete (up to 30 seconds)
for i in $(seq 1 60); do
  sleep 0.5
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "daemon crashed" >&2
    cat "$WORK_DIR/daemon.log" >&2
    exit 1
  fi
  STATS=$("$ROOT_DIR/zig-out/bin/varuna-ctl" list 2>/dev/null) || continue
  PROGRESS=$(echo "$STATS" | grep -o '"progress":[0-9.]*' | head -1 | cut -d: -f2)
  STATE=$(echo "$STATS" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ "$STATE" == "seeding" ]] || [[ "$PROGRESS" == "1.0000" ]]; then
    break
  fi
done

# Verify file
cmp "$WORK_DIR/seed-root/payload.bin" "$WORK_DIR/download-root/payload.bin"

cat <<EOF
daemon swarm demo succeeded
work dir: $WORK_DIR
tracker log: $WORK_DIR/tracker.log
seed log: $WORK_DIR/seed.log
daemon log: $WORK_DIR/daemon.log
EOF

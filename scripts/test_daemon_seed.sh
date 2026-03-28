#!/usr/bin/env bash
# Test that the varuna daemon can serve pieces to peers after completing a download.
#
# Flow:
#   1. Create a 50KB payload and .torrent file
#   2. Start opentracker, an initial varuna-tools seeder, and the varuna daemon
#   3. Add the torrent to the daemon via varuna-ctl (daemon downloads from seeder)
#   4. Wait for the daemon to finish downloading and transition to seeding
#   5. Kill the original seeder
#   6. Start a new varuna-tools downloader that fetches from the daemon
#   7. Verify the new downloader gets the correct file
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-daemon-seed-XXXXXX)}"
TRACKER_PORT="${TRACKER_PORT:-7090}"
SEED_PORT="${SEED_PORT:-7091}"
API_PORT="${API_PORT:-8080}"
# The daemon listens for peer connections on its default config port (6881).
DAEMON_PEER_PORT=6881
DL2_PORT="${DL2_PORT:-7093}"

TRACKER_PID=""
SEED_PID=""
DAEMON_PID=""
DL2_PID=""

cleanup() {
  for pid_var in DL2_PID DAEMON_PID SEED_PID TRACKER_PID; do
    local pid="${!pid_var:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.3
  for pid_var in DL2_PID DAEMON_PID SEED_PID TRACKER_PID; do
    local pid="${!pid_var:-}"
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
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

echo "=== daemon seeding test ==="
echo "work dir: $WORK_DIR"

mkdir -p "$WORK_DIR/seed-root" "$WORK_DIR/daemon-download" "$WORK_DIR/dl2-root"

PAYLOAD="$WORK_DIR/seed-root/payload.bin"
TORRENT="$WORK_DIR/test.torrent"
TRACKER_LOG="$WORK_DIR/tracker.log"
SEED_LOG="$WORK_DIR/seed.log"
DAEMON_LOG="$WORK_DIR/daemon.log"
DL2_LOG="$WORK_DIR/dl2.log"

# --- Step 1: Create 50KB payload and .torrent ---
dd if=/dev/urandom of="$PAYLOAD" bs=1024 count=50 2>/dev/null
echo "created 50KB payload"

mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
  --input "$PAYLOAD" \
  --output "$TORRENT" \
  --announce "http://127.0.0.1:$TRACKER_PORT/announce"
echo "created .torrent file"

# --- Build ---
mise exec -- zig build >/dev/null
echo "build complete"

INFO_HASH="$("$ROOT_DIR/zig-out/bin/varuna-tools" inspect "$TORRENT" | awk -F= '/^info_hash=/{print $2}')"
if [[ -z "$INFO_HASH" ]]; then
  echo "FAIL: could not extract info hash" >&2
  exit 1
fi
echo "info hash: $INFO_HASH"

# --- Step 2: Start tracker ---
"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH" >"$TRACKER_LOG" 2>&1 &
TRACKER_PID="$!"
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"
echo "tracker running on port $TRACKER_PORT"

# --- Step 3: Start initial seeder (varuna-tools seed) ---
"$ROOT_DIR/zig-out/bin/varuna-tools" seed "$TORRENT" "$WORK_DIR/seed-root" --port "$SEED_PORT" >"$SEED_LOG" 2>&1 &
SEED_PID="$!"
wait_for_log "$SEED_LOG" "seed announce accepted"
echo "initial seeder running on port $SEED_PORT"

# --- Step 4: Start the varuna daemon ---
"$ROOT_DIR/zig-out/bin/varuna" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID="$!"
wait_for_tcp 127.0.0.1 "$API_PORT"
echo "daemon running (API on $API_PORT, peer port $DAEMON_PEER_PORT)"

# --- Step 5: Add torrent to daemon ---
"$ROOT_DIR/zig-out/bin/varuna-ctl" add "$TORRENT" --save-path "$WORK_DIR/daemon-download"
echo "torrent added to daemon"

# --- Step 6: Wait for daemon to complete download (up to 30s) ---
echo "waiting for daemon to finish downloading..."
DOWNLOAD_OK=0
for i in $(seq 1 60); do
  sleep 0.5
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "FAIL: daemon crashed during download" >&2
    echo "--- daemon log ---" >&2
    cat "$DAEMON_LOG" >&2
    exit 1
  fi
  STATS=$("$ROOT_DIR/zig-out/bin/varuna-ctl" list 2>/dev/null) || continue
  STATE=$(echo "$STATS" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
  PROGRESS=$(echo "$STATS" | grep -o '"progress":[0-9.]*' | head -1 | cut -d: -f2)
  if [[ "$STATE" == "seeding" ]] || [[ "${PROGRESS:-0}" == "1.0000" ]]; then
    DOWNLOAD_OK=1
    break
  fi
done

if [[ "$DOWNLOAD_OK" -ne 1 ]]; then
  echo "FAIL: daemon did not complete download within 30s" >&2
  echo "last state: ${STATE:-unknown}, progress: ${PROGRESS:-unknown}" >&2
  echo "--- daemon log ---" >&2
  cat "$DAEMON_LOG" >&2
  exit 1
fi
echo "daemon finished downloading (state=$STATE, progress=$PROGRESS)"

# Verify daemon downloaded correctly
cmp "$PAYLOAD" "$WORK_DIR/daemon-download/payload.bin"
echo "daemon download verified correct"

# --- Step 7: Kill the original seeder ---
kill "$SEED_PID" 2>/dev/null || true
wait "$SEED_PID" 2>/dev/null || true
SEED_PID=""
echo "original seeder killed"

# Give the tracker a moment to notice the seeder is gone
sleep 1

# --- Step 8: Start a new downloader that downloads FROM the daemon ---
echo "starting new downloader (port $DL2_PORT) to download from daemon..."
"$ROOT_DIR/zig-out/bin/varuna-tools" download "$TORRENT" "$WORK_DIR/dl2-root" --port "$DL2_PORT" >"$DL2_LOG" 2>&1 &
DL2_PID="$!"

# Wait for second download to complete (up to 30s)
DL2_OK=0
for i in $(seq 1 60); do
  sleep 0.5
  if ! kill -0 "$DL2_PID" 2>/dev/null; then
    # Process exited -- check if it succeeded
    wait "$DL2_PID" 2>/dev/null && DL2_OK=1 || true
    DL2_PID=""
    break
  fi
done

if [[ "$DL2_OK" -ne 1 ]]; then
  echo "FAIL: second downloader did not complete within 30s" >&2
  echo "--- dl2 log ---" >&2
  cat "$DL2_LOG" >&2
  echo "--- daemon log (tail) ---" >&2
  tail -50 "$DAEMON_LOG" >&2
  exit 1
fi

# --- Step 9: Verify the new download matches the original ---
cmp "$PAYLOAD" "$WORK_DIR/dl2-root/payload.bin"
echo "second download verified correct"

cat <<EOF

=== daemon seeding test PASSED ===
work dir:    $WORK_DIR
tracker log: $TRACKER_LOG
seed log:    $SEED_LOG
daemon log:  $DAEMON_LOG
dl2 log:     $DL2_LOG
EOF

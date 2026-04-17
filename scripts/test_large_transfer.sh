#!/usr/bin/env bash
set -euo pipefail

# Stress test for large file transfers at multiple piece sizes.
# Verifies data integrity with cmp after each transfer.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-stress-XXXXXX)}"
TOOLS_BIN="$ROOT_DIR/zig-out/bin/varuna-tools"
TIMEOUT="${TIMEOUT:-45}"

# Test matrix: "payload_bytes piece_bytes label"
TESTS=(
  "1048576    16384   1MB/16KB"
  "1048576    65536   1MB/64KB"
  "5242880    65536   5MB/64KB"
  "5242880    262144  5MB/256KB"
)

PASS=0
FAIL=0
FAILURES=()

# Port base -- each test gets 100-port spacing to avoid TIME_WAIT conflicts
PORT_BASE="${PORT_BASE:-40000}"

cleanup_pids() {
  local pid
  for pid in "$@"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.2
  # Force-kill anything still alive
  for pid in "$@"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  for pid in "$@"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  # Verify all dead
  for pid in "$@"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "  warning: process $pid still alive after cleanup" >&2
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

wait_for_port_free() {
  local port="$1"
  for _ in $(seq 1 40); do
    if ! bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "  warning: port $port still in use after 4s" >&2
  return 1
}

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

echo "=== varuna large-transfer stress test ==="
echo "work dir: $WORK_DIR"
echo ""

# Build first
echo "building varuna-tools..."
(cd "$ROOT_DIR" && mise exec -- zig build) >/dev/null
echo "build complete"
echo ""

# Kill any lingering processes from THIS worktree's previous runs.
# Only kill processes whose command line references this ROOT_DIR to avoid
# interfering with other concurrent test runs from different worktrees.
for pid in $(pgrep -f "$ROOT_DIR/zig-out/bin/varuna-tools (seed|download)" 2>/dev/null || true); do
  [[ "$pid" == "$$" ]] && continue
  kill -9 "$pid" 2>/dev/null || true
done
for pid in $(pgrep -f "$ROOT_DIR/.tools/opentracker" 2>/dev/null || true); do
  kill -9 "$pid" 2>/dev/null || true
done
sleep 1

test_index=0
for entry in "${TESTS[@]}"; do
  read -r payload_bytes piece_bytes label <<<"$entry"
  test_index=$((test_index + 1))

  tracker_port=$((PORT_BASE + test_index * 100))
  seed_port=$((PORT_BASE + test_index * 100 + 1))
  download_port=$((PORT_BASE + test_index * 100 + 2))

  expected_pieces=$(( (payload_bytes + piece_bytes - 1) / piece_bytes ))

  echo "--- test $test_index: $label ($expected_pieces pieces) ---"

  # Verify tracker port is free before starting
  if ! wait_for_port_free "$tracker_port"; then
    echo "  FAIL: port $tracker_port still in use"
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: port conflict")
    continue
  fi

  TEST_DIR="$WORK_DIR/test-$test_index"
  mkdir -p "$TEST_DIR/seed-root" "$TEST_DIR/download-root"

  PAYLOAD_PATH="$TEST_DIR/seed-root/fixture.bin"
  TORRENT_PATH="$TEST_DIR/fixture.torrent"
  TRACKER_LOG="$TEST_DIR/tracker.log"
  SEED_LOG="$TEST_DIR/seed.log"
  DOWNLOAD_LOG="$TEST_DIR/download.log"

  TRACKER_PID=""
  SEED_PID=""
  DOWNLOAD_PID=""

  run_cleanup() {
    cleanup_pids "$DOWNLOAD_PID" "$SEED_PID" "$TRACKER_PID"
  }

  # Generate random payload
  dd if=/dev/urandom of="$PAYLOAD_PATH" bs="$payload_bytes" count=1 2>/dev/null
  actual_size=$(stat -c%s "$PAYLOAD_PATH")
  echo "  payload: $actual_size bytes, piece size: $piece_bytes"

  # Create torrent
  "$TOOLS_BIN" create \
    -a "http://127.0.0.1:$tracker_port/announce" \
    -l "$piece_bytes" \
    -o "$TORRENT_PATH" \
    "$PAYLOAD_PATH" >/dev/null

  # Extract info hash
  INFO_HASH="$("$TOOLS_BIN" inspect "$TORRENT_PATH" | awk -F= '/^info_hash=/{print $2}')"
  if [[ -z "$INFO_HASH" ]]; then
    echo "  FAIL: could not extract info hash"
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: no info hash")
    continue
  fi
  echo "  info hash: $INFO_HASH"

  # Start tracker
  "$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$tracker_port" \
    --whitelist-hash "$INFO_HASH" >"$TRACKER_LOG" 2>&1 &
  TRACKER_PID="$!"

  if ! wait_for_tcp 127.0.0.1 "$tracker_port"; then
    echo "  FAIL: tracker did not start"
    run_cleanup
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: tracker timeout")
    continue
  fi

  # Start seeder
  "$TOOLS_BIN" seed "$TORRENT_PATH" "$TEST_DIR/seed-root" \
    --port "$seed_port" >"$SEED_LOG" 2>&1 &
  SEED_PID="$!"

  if ! wait_for_log "$SEED_LOG" "seed announce accepted"; then
    echo "  FAIL: seeder did not announce"
    echo "  seed log tail:"
    tail -5 "$SEED_LOG" 2>/dev/null | sed 's/^/    /' || true
    run_cleanup
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: seed announce timeout")
    continue
  fi

  # Start downloader with timeout
  download_ok=false
  "$TOOLS_BIN" download "$TORRENT_PATH" "$TEST_DIR/download-root" \
    --port "$download_port" --max-peers 1 >"$DOWNLOAD_LOG" 2>&1 &
  DOWNLOAD_PID="$!"

  # Wait for download to finish with timeout
  deadline=$((SECONDS + TIMEOUT))
  while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
    if [[ $SECONDS -ge $deadline ]]; then
      echo "  FAIL: download timed out after ${TIMEOUT}s"
      run_cleanup
      DOWNLOAD_PID=""
      FAIL=$((FAIL + 1))
      FAILURES+=("$label: download timeout")
      break
    fi
    sleep 0.5
  done

  # If we broke out due to timeout, skip verification
  if [[ -n "$DOWNLOAD_PID" ]] && ! kill -0 "$DOWNLOAD_PID" 2>/dev/null; then
    wait "$DOWNLOAD_PID" && download_ok=true || true
    DOWNLOAD_PID=""
  elif [[ -z "$DOWNLOAD_PID" ]]; then
    # timed out, already handled
    sleep 0.5
    continue
  fi

  # Verify
  DOWNLOADED_PATH="$TEST_DIR/download-root/fixture.bin"
  if [[ ! -f "$DOWNLOADED_PATH" ]]; then
    echo "  FAIL: downloaded file does not exist"
    echo "  download log tail:"
    tail -10 "$DOWNLOAD_LOG" 2>/dev/null | sed 's/^/    /' || true
    run_cleanup
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: no output file")
    sleep 0.5
    continue
  fi

  if cmp -s "$PAYLOAD_PATH" "$DOWNLOADED_PATH"; then
    echo "  PASS: files match"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: files differ"
    echo "  source size: $(stat -c%s "$PAYLOAD_PATH")"
    echo "  download size: $(stat -c%s "$DOWNLOADED_PATH")"
    # Find first differing byte
    first_diff=$(cmp "$PAYLOAD_PATH" "$DOWNLOADED_PATH" 2>&1 | head -1) || true
    echo "  first difference: $first_diff"
    echo "  download log tail:"
    tail -10 "$DOWNLOAD_LOG" 2>/dev/null | sed 's/^/    /' || true
    FAIL=$((FAIL + 1))
    FAILURES+=("$label: data mismatch")
  fi

  run_cleanup
  # Brief pause for socket TIME_WAIT cleanup between tests
  sleep 0.5
  echo ""
done

echo "=== results ==="
echo "passed: $PASS / $((PASS + FAIL))"
if [[ $FAIL -gt 0 ]]; then
  echo "FAILURES:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  echo ""
  echo "work dir preserved: $WORK_DIR"
  exit 1
else
  echo "all tests passed"
  rm -rf "$WORK_DIR"
  exit 0
fi

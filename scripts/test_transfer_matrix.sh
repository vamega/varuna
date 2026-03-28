#!/usr/bin/env bash
# Comprehensive transfer test matrix for verifying data integrity.
# Tests various file sizes, piece sizes, and multi-file torrents.
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

# Base port — each test increments by 10 to avoid conflicts
BASE_PORT="${BASE_PORT:-7200}"

cleanup_test() {
  local pids="$1"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.3
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
}

wait_for_tcp() {
  local port="$1"
  for _ in $(seq 1 100); do
    bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

wait_for_log() {
  local file="$1" pattern="$2"
  for _ in $(seq 1 200); do
    [[ -f "$file" ]] && grep -q "$pattern" "$file" && return 0
    sleep 0.05
  done
  return 1
}

# Run a single-file transfer test
# Args: test_name payload_size_kb piece_length_bytes timeout_secs
run_single_file_test() {
  local name="$1" size_kb="$2" piece_len="$3" timeout_s="${4:-60}"
  local port_base=$BASE_PORT
  BASE_PORT=$((BASE_PORT + 10))

  local tp=$port_base sp=$((port_base+1)) dp=$((port_base+2))
  local W=$(mktemp -d -t "vt-${name}-XXXXXX")
  local pids=""

  echo -n "  $name (${size_kb}KB, piece=${piece_len})... "

  mkdir -p "$W/seed" "$W/dl"
  dd if=/dev/urandom of="$W/seed/payload.bin" bs=1024 count="$size_kb" 2>/dev/null

  mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
    --input "$W/seed/payload.bin" \
    --output "$W/test.torrent" \
    --announce "http://127.0.0.1:$tp/announce" \
    --piece-length "$piece_len" >/dev/null 2>&1

  local H
  H=$("$ROOT_DIR/zig-out/bin/varuna-tools" inspect "$W/test.torrent" 2>/dev/null | awk -F= '/^info_hash=/{print $2}')
  if [[ -z "$H" ]]; then
    echo "SKIP (inspect failed)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name")
    rm -rf "$W"
    return
  fi

  "$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  pids="$!"
  wait_for_tcp "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  "$ROOT_DIR/zig-out/bin/varuna-tools" seed "$W/test.torrent" "$W/seed" --port "$sp" >"$W/seed.log" 2>&1 &
  pids="$pids $!"
  wait_for_log "$W/seed.log" "seed announce accepted" || { echo "SKIP (seed)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  if timeout "$timeout_s" "$ROOT_DIR/zig-out/bin/varuna-tools" download "$W/test.torrent" "$W/dl" --port "$dp" >"$W/dl.log" 2>&1; then
    if cmp -s "$W/seed/payload.bin" "$W/dl/payload.bin"; then
      echo "PASS"
      PASS_COUNT=$((PASS_COUNT + 1))
      RESULTS+=("PASS $name")
    else
      echo "FAIL (data mismatch)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("FAIL $name (data mismatch)")
    fi
  else
    local rc=$?
    if [[ $rc -eq 124 ]]; then
      echo "FAIL (timeout ${timeout_s}s)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("FAIL $name (timeout)")
    else
      echo "FAIL (exit $rc)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("FAIL $name (exit $rc)")
    fi
  fi

  cleanup_test "$pids"
  rm -rf "$W"
}

# Run a multi-file (directory) transfer test
# Args: test_name file_specs piece_length_bytes timeout_secs
# file_specs is "size1_kb:name1,size2_kb:name2,..."
run_multi_file_test() {
  local name="$1" file_specs="$2" piece_len="$3" timeout_s="${4:-60}"
  local port_base=$BASE_PORT
  BASE_PORT=$((BASE_PORT + 10))

  local tp=$port_base sp=$((port_base+1)) dp=$((port_base+2))
  local W=$(mktemp -d -t "vt-${name}-XXXXXX")
  local pids=""

  echo -n "  $name (multi-file, piece=${piece_len})... "

  mkdir -p "$W/seed/content" "$W/dl"

  # Create files from spec
  IFS=',' read -ra specs <<< "$file_specs"
  local total_kb=0
  for spec in "${specs[@]}"; do
    local sz_kb="${spec%%:*}"
    local fname="${spec##*:}"
    # Support subdirectories
    local fdir=$(dirname "$fname")
    [[ "$fdir" != "." ]] && mkdir -p "$W/seed/content/$fdir"
    dd if=/dev/urandom of="$W/seed/content/$fname" bs=1024 count="$sz_kb" 2>/dev/null
    total_kb=$((total_kb + sz_kb))
  done

  mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
    --input "$W/seed/content" \
    --output "$W/test.torrent" \
    --announce "http://127.0.0.1:$tp/announce" \
    --piece-length "$piece_len" >/dev/null 2>&1

  local H
  H=$("$ROOT_DIR/zig-out/bin/varuna-tools" inspect "$W/test.torrent" 2>/dev/null | awk -F= '/^info_hash=/{print $2}')
  if [[ -z "$H" ]]; then
    echo "SKIP (inspect failed)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name")
    rm -rf "$W"
    return
  fi

  "$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  pids="$!"
  wait_for_tcp "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  # Multi-file torrents: pass parent dir so PieceStore finds <torrent_name>/<file_path>
  "$ROOT_DIR/zig-out/bin/varuna-tools" seed "$W/test.torrent" "$W/seed" --port "$sp" >"$W/seed.log" 2>&1 &
  pids="$pids $!"
  wait_for_log "$W/seed.log" "seed announce accepted" || { echo "SKIP (seed)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  if timeout "$timeout_s" "$ROOT_DIR/zig-out/bin/varuna-tools" download "$W/test.torrent" "$W/dl" --port "$dp" >"$W/dl.log" 2>&1; then
    # Verify each file
    local all_match=true
    for spec in "${specs[@]}"; do
      local fname="${spec##*:}"
      if ! cmp -s "$W/seed/content/$fname" "$W/dl/content/$fname" 2>/dev/null; then
        all_match=false
        break
      fi
    done
    if $all_match; then
      echo "PASS (${total_kb}KB across ${#specs[@]} files)"
      PASS_COUNT=$((PASS_COUNT + 1))
      RESULTS+=("PASS $name")
    else
      echo "FAIL (data mismatch)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      RESULTS+=("FAIL $name (data mismatch)")
    fi
  else
    local rc=$?
    if [[ $rc -eq 124 ]]; then
      echo "FAIL (timeout ${timeout_s}s)"
    else
      echo "FAIL (exit $rc)"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("FAIL $name")
  fi

  cleanup_test "$pids"
  rm -rf "$W"
}

# ─── Main ───────────────────────────────────────────────

echo "varuna transfer test matrix"
echo "==========================="
echo ""

# Build
zig build >/dev/null 2>&1

# Kill any lingering processes
pkill -9 -f "varuna-tools seed" 2>/dev/null; true
pkill -9 opentracker 2>/dev/null; true
sleep 1

# ── Small files ──────────────────────────────────────────
echo "Small files (< 100KB):"
run_single_file_test "tiny-1piece"      1    16384   15
run_single_file_test "small-16k"       32    16384   15
run_single_file_test "small-64k"       32    65536   15
run_single_file_test "small-exact"     64    65536   15  # exactly 1 piece

# ── Medium files ─────────────────────────────────────────
echo ""
echo "Medium files (100KB - 10MB):"
run_single_file_test "med-100k-16k"   100    16384   30
run_single_file_test "med-100k-64k"   100    65536   30
run_single_file_test "med-500k-16k"   500    16384   30
run_single_file_test "med-500k-64k"   500    65536   30
run_single_file_test "med-1m-16k"    1024    16384   30
run_single_file_test "med-1m-64k"    1024    65536   30
run_single_file_test "med-1m-256k"   1024   262144   30
run_single_file_test "med-5m-64k"    5120    65536   60
run_single_file_test "med-5m-256k"   5120   262144   60
run_single_file_test "med-10m-64k"  10240    65536   90
run_single_file_test "med-10m-256k" 10240   262144   60

# ── Large files ──────────────────────────────────────────
echo ""
echo "Large files (> 10MB):"
run_single_file_test "large-20m-64k"  20480    65536  120
run_single_file_test "large-20m-256k" 20480   262144   90
run_single_file_test "large-50m-256k" 51200   262144  180
run_single_file_test "large-100m-256k" 102400 262144  300

# ── Multi-file torrents ──────────────────────────────────
echo ""
echo "Multi-file torrents:"
run_multi_file_test "multi-2files-small"    "10:a.bin,20:b.bin"                16384  30
run_multi_file_test "multi-3files-mixed"    "1:tiny.txt,100:medium.bin,500:large.dat" 65536 60
run_multi_file_test "multi-5files-various"  "5:a.bin,50:b.bin,200:c.bin,500:d.bin,1024:e.bin" 65536 90
run_multi_file_test "multi-subdir"          "100:sub1/file1.bin,200:sub1/file2.bin,300:sub2/data.bin" 65536 60
run_multi_file_test "multi-large-256k"      "1024:video.bin,2048:audio.bin,512:subs.txt" 262144 120

# ── Summary ──────────────────────────────────────────────
echo ""
echo "==========================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo ""
for r in "${RESULTS[@]}"; do
  echo "  $r"
done
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"

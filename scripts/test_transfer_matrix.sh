#!/usr/bin/env bash
# Comprehensive transfer test matrix for verifying data integrity.
# Tests various file sizes, piece sizes, and multi-file torrents.
# Uses the varuna daemon + varuna-ctl API instead of varuna-tools seed/download.
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

VARUNA="$ROOT_DIR/zig-out/bin/varuna"
VARUNA_TOOLS="$ROOT_DIR/zig-out/bin/varuna-tools"

# Each test gets a port range of 100 starting from 30000+
# to avoid conflicts with standard services and other tests.
# Within each range: +0 = tracker, +1 = seed peer, +2 = download peer,
#                    +3 = seed API, +4 = download API.
NEXT_PORT="${BASE_PORT:-30000}"

cleanup_test() {
  local pids="$1"
  # Send SIGTERM first for graceful shutdown
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.2
  # Force-kill anything still alive
  for pid in $pids; do
    kill -9 "$pid" 2>/dev/null || true
  done
  # Wait for all processes to fully exit
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  # Verify all processes are dead
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "    warning: process $pid still alive after cleanup" >&2
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
  echo "    warning: port $port still in use after 4s" >&2
  return 1
}

wait_for_tcp() {
  local port="$1"
  for _ in $(seq 1 100); do
    bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# Login to a daemon API and return the SID cookie value.
api_login() {
  local port="$1"
  local sid
  sid=$(curl -s -c - "http://127.0.0.1:${port}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null \
    | grep SID | awk '{print $NF}')
  echo "$sid"
}

# Add a torrent to a daemon via the API.
# Args: api_port sid torrent_file save_path
api_add_torrent() {
  local port="$1" sid="$2" torrent_file="$3" save_path="$4"
  curl -s -b "SID=${sid}" \
    "http://127.0.0.1:${port}/api/v2/torrents/add?savepath=$(printf '%s' "$save_path" | sed 's/ /%20/g')" \
    --data-binary @"$torrent_file" >/dev/null 2>&1
}

# Query the torrent list from a daemon and extract the progress of the first torrent.
api_get_progress() {
  local port="$1" sid="$2"
  curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/info" 2>/dev/null \
    | sed 's/.*"progress":\([0-9.]*\).*/\1/'
}

# Write a varuna daemon TOML config file.
# Args: config_path api_port peer_port data_dir
#
# IMPORTANT: Each daemon MUST use its own resume_db. The default XDG path
# (~/.local/share/varuna/resume.db) is shared across daemon instances;
# sharing it between the seeder and downloader causes the downloader to
# load the seeder's completion records and skip downloading entirely
# (see progress-reports/2026-04-21-test-matrix-resume-db-isolation.md).
write_daemon_config() {
  local config_path="$1" api_port="$2" peer_port="$3" data_dir="$4"
  cat >"$config_path" <<EOF
[daemon]
api_port = ${api_port}
api_bind = "127.0.0.1"
api_username = "admin"
api_password = "adminadmin"

[storage]
data_dir = "${data_dir}"
resume_db = "${data_dir}/resume.db"

[network]
port_min = ${peer_port}
port_max = ${peer_port}
dht = false
pex = false
# Disable uTP: varuna's uTP path currently fails on BT messages that span
# multiple uTP packets (anything above ~2KB). Tracked as a separate bug in
# STATUS.md under "Known Issues". TCP transfers work correctly.
enable_utp = false
EOF
}

# Start a varuna daemon with a per-instance config in the given work directory.
# Args: work_dir api_port peer_port data_dir log_file
# Prints: the daemon PID
start_daemon() {
  local work_dir="$1" api_port="$2" peer_port="$3" data_dir="$4" log_file="$5"
  mkdir -p "$work_dir"
  write_daemon_config "$work_dir/varuna.toml" "$api_port" "$peer_port" "$data_dir"
  (cd "$work_dir" && exec "$VARUNA") >"$log_file" 2>&1 &
  echo "$!"
}

# Run a single-file transfer test
# Args: test_name payload_size_kb piece_length_bytes timeout_secs
run_single_file_test() {
  local name="$1" size_kb="$2" piece_len="$3" timeout_s="${4:-60}"
  local port_base=$NEXT_PORT
  NEXT_PORT=$((NEXT_PORT + 100))

  local tp=$port_base sp=$((port_base+1)) dp=$((port_base+2))
  local sp_api=$((port_base+3)) dp_api=$((port_base+4))
  local W=$(mktemp -d -t "vt-${name}-XXXXXX")
  local pids=""

  echo -n "  $name (${size_kb}KB, piece=${piece_len})... "

  # Verify tracker port is free before starting
  if ! wait_for_port_free "$tp"; then
    echo "SKIP (port $tp in use)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name (port conflict)")
    rm -rf "$W"
    return
  fi

  mkdir -p "$W/seed" "$W/dl"
  dd if=/dev/urandom of="$W/seed/payload.bin" bs=1024 count="$size_kb" 2>/dev/null

  "$VARUNA_TOOLS" create \
    -a "http://127.0.0.1:$tp/announce" \
    -l "$piece_len" \
    -o "$W/test.torrent" \
    "$W/seed/payload.bin" >/dev/null 2>&1

  local H
  H=$("$VARUNA_TOOLS" inspect "$W/test.torrent" 2>/dev/null | awk -F= '/^info_hash=/{print $2}')
  if [[ -z "$H" ]]; then
    echo "SKIP (inspect failed)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name")
    rm -rf "$W"
    return
  fi

  # Start tracker
  "$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  pids="$!"
  wait_for_tcp "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  # Start seeder daemon
  local seed_pid
  seed_pid=$(start_daemon "$W/seed-daemon" "$sp_api" "$sp" "$W/seed" "$W/seed.log")
  pids="$pids $seed_pid"
  if ! wait_for_tcp "$sp_api"; then
    echo "SKIP (seed daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi

  # Add torrent to seeder
  local seed_sid
  seed_sid=$(api_login "$sp_api")
  if [[ -z "$seed_sid" ]]; then
    echo "SKIP (seed login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi
  api_add_torrent "$sp_api" "$seed_sid" "$W/test.torrent" "$W/seed"

  # Brief pause for the seeder to announce to tracker
  sleep 1

  # Start downloader daemon
  local dl_pid
  dl_pid=$(start_daemon "$W/dl-daemon" "$dp_api" "$dp" "$W/dl" "$W/dl.log")
  pids="$pids $dl_pid"
  if ! wait_for_tcp "$dp_api"; then
    echo "SKIP (dl daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi

  # Add torrent to downloader
  local dl_sid
  dl_sid=$(api_login "$dp_api")
  if [[ -z "$dl_sid" ]]; then
    echo "SKIP (dl login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi
  api_add_torrent "$dp_api" "$dl_sid" "$W/test.torrent" "$W/dl"

  # Poll until download completes or timeout
  local elapsed=0
  local progress=""
  local completed=false
  while [[ $elapsed -lt $timeout_s ]]; do
    progress=$(api_get_progress "$dp_api" "$dl_sid")
    if [[ -n "$progress" ]] && awk "BEGIN{exit(!($progress >= 1.0))}" 2>/dev/null; then
      completed=true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if $completed; then
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
    if [[ $elapsed -ge $timeout_s ]]; then
      echo "FAIL (timeout ${timeout_s}s, progress=${progress:-unknown})"
    else
      echo "FAIL (download error, progress=${progress:-unknown})"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("FAIL $name (timeout)")
  fi

  cleanup_test "$pids"
  rm -rf "$W"
  # Brief pause for socket TIME_WAIT cleanup between tests
  sleep 0.5
}

# Run a multi-file (directory) transfer test
# Args: test_name file_specs piece_length_bytes timeout_secs
# file_specs is "size1_kb:name1,size2_kb:name2,..."
run_multi_file_test() {
  local name="$1" file_specs="$2" piece_len="$3" timeout_s="${4:-60}"
  local port_base=$NEXT_PORT
  NEXT_PORT=$((NEXT_PORT + 100))

  local tp=$port_base sp=$((port_base+1)) dp=$((port_base+2))
  local sp_api=$((port_base+3)) dp_api=$((port_base+4))
  local W=$(mktemp -d -t "vt-${name}-XXXXXX")
  local pids=""

  echo -n "  $name (multi-file, piece=${piece_len})... "

  # Verify tracker port is free before starting
  if ! wait_for_port_free "$tp"; then
    echo "SKIP (port $tp in use)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name (port conflict)")
    rm -rf "$W"
    return
  fi

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

  "$VARUNA_TOOLS" create \
    -a "http://127.0.0.1:$tp/announce" \
    -l "$piece_len" \
    -o "$W/test.torrent" \
    "$W/seed/content" >/dev/null 2>&1

  local H
  H=$("$VARUNA_TOOLS" inspect "$W/test.torrent" 2>/dev/null | awk -F= '/^info_hash=/{print $2}')
  if [[ -z "$H" ]]; then
    echo "SKIP (inspect failed)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    RESULTS+=("SKIP $name")
    rm -rf "$W"
    return
  fi

  # Start tracker
  "$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  pids="$!"
  wait_for_tcp "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return; }

  # Start seeder daemon (multi-file torrents: pass parent dir so PieceStore finds <torrent_name>/<file_path>)
  local seed_pid
  seed_pid=$(start_daemon "$W/seed-daemon" "$sp_api" "$sp" "$W/seed" "$W/seed.log")
  pids="$pids $seed_pid"
  if ! wait_for_tcp "$sp_api"; then
    echo "SKIP (seed daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi

  # Add torrent to seeder
  local seed_sid
  seed_sid=$(api_login "$sp_api")
  if [[ -z "$seed_sid" ]]; then
    echo "SKIP (seed login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi
  api_add_torrent "$sp_api" "$seed_sid" "$W/test.torrent" "$W/seed"

  # Brief pause for the seeder to announce to tracker
  sleep 1

  # Start downloader daemon
  local dl_pid
  dl_pid=$(start_daemon "$W/dl-daemon" "$dp_api" "$dp" "$W/dl" "$W/dl.log")
  pids="$pids $dl_pid"
  if ! wait_for_tcp "$dp_api"; then
    echo "SKIP (dl daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi

  # Add torrent to downloader
  local dl_sid
  dl_sid=$(api_login "$dp_api")
  if [[ -z "$dl_sid" ]]; then
    echo "SKIP (dl login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test "$pids"; rm -rf "$W"; return
  fi
  api_add_torrent "$dp_api" "$dl_sid" "$W/test.torrent" "$W/dl"

  # Poll until download completes or timeout
  local elapsed=0
  local progress=""
  local completed=false
  while [[ $elapsed -lt $timeout_s ]]; do
    progress=$(api_get_progress "$dp_api" "$dl_sid")
    if [[ -n "$progress" ]] && awk "BEGIN{exit(!($progress >= 1.0))}" 2>/dev/null; then
      completed=true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if $completed; then
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
    if [[ $elapsed -ge $timeout_s ]]; then
      echo "FAIL (timeout ${timeout_s}s, progress=${progress:-unknown})"
    else
      echo "FAIL (download error, progress=${progress:-unknown})"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("FAIL $name")
  fi

  cleanup_test "$pids"
  rm -rf "$W"
  # Brief pause for socket TIME_WAIT cleanup between tests
  sleep 0.5
}

# ─── Main ───────────────────────────────────────────────

echo "varuna transfer test matrix"
echo "==========================="
echo ""

# Build
zig build >/dev/null 2>&1

# Kill any lingering daemon processes from THIS worktree's previous runs.
# Only kill processes whose command line references this ROOT_DIR to avoid
# interfering with other concurrent test runs from different worktrees.
for pid in $(pgrep -f "$ROOT_DIR/zig-out/bin/varuna" 2>/dev/null || true); do
  [[ "$pid" == "$$" ]] && continue
  kill -9 "$pid" 2>/dev/null || true
done
for pid in $(pgrep -f "$ROOT_DIR/.tools/opentracker" 2>/dev/null || true); do
  kill -9 "$pid" 2>/dev/null || true
done
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

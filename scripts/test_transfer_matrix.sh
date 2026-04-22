#!/usr/bin/env bash
# Comprehensive transfer test matrix for verifying data integrity.
# Tests various file sizes, piece sizes, and multi-file torrents.
# Uses the varuna daemon + varuna-ctl API instead of varuna-tools seed/download.
#
# ── Isolation model ───────────────────────────────────────────────────────
# Each test gets a fresh loopback /24 inside 127.0.0.0/8:
#   tracker    → 127.0.${TEST_INDEX}.1 : 6969
#   seeder     → 127.0.${TEST_INDEX}.2 : 6881 (peer) / 8081 (api)
#   downloader → 127.0.${TEST_INDEX}.3 : 6882 (peer) / 8082 (api)
#
# Every (src_ip, src_port, dst_ip, dst_port) 4-tuple is therefore disjoint
# across tests, so nothing the kernel keeps from test N (TIME_WAIT,
# half-closed CLOSE_WAIT, syncache, etc.) can influence test N+1 even if
# it lingers for the full TIME_WAIT window. Port re-use across tests is
# fine because the IPs differ.
#
# Daemons bind to their per-test IP via [network] bind_address. Tracker
# HTTP announces honor this bind (see src/io/http_executor.zig), so
# opentracker registers the peer at the correct address and the other
# side can connect.
#
# Teardown uses POST /api/v2/app/shutdown?timeout=0 on every registered
# daemon, waits up to 2 s for a clean FIN-based exit, then SIGKILLs
# anything still alive (tracker, or a stuck daemon past the drain).
# ─────────────────────────────────────────────────────────────────────────
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

VARUNA="$ROOT_DIR/zig-out/bin/varuna"
VARUNA_TOOLS="$ROOT_DIR/zig-out/bin/varuna-tools"

# Per-test counter: used to pick a unique 127.0.${TEST_INDEX}.x /24 for
# each test. Linux routes all of 127/8 to lo, so every value in [1, 255]
# is a valid loopback subnet.
TEST_INDEX=0

# Per-test lists, reset at the start of every run_*_test invocation.
# DAEMON_PIDS holds PIDs of every background process launched (daemons + tracker).
# DAEMON_SHUTDOWN_CMDS holds ready-to-eval curl invocations for graceful shutdown.
DAEMON_PIDS=()
DAEMON_SHUTDOWN_CMDS=()

reset_test_state() {
  DAEMON_PIDS=()
  DAEMON_SHUTDOWN_CMDS=()
}

# Register a background PID so cleanup_test waits for and kills it.
register_pid() {
  DAEMON_PIDS+=("$1")
}

# Register a (host, api_port, sid) tuple so cleanup_test can POST a
# graceful shutdown to this daemon before resorting to SIGKILL.
register_shutdown() {
  local host="$1" port="$2" sid="$3"
  DAEMON_SHUTDOWN_CMDS+=("curl -s -b 'SID=${sid}' -X POST 'http://${host}:${port}/api/v2/app/shutdown?timeout=0'")
}

# Shut down every registered daemon cleanly, then wait for every registered
# PID, falling back to SIGKILL if any still live after the grace period.
# This closes sockets with a proper FIN handshake so the next test starts
# from a clean kernel state (no lingering TIME_WAIT tying up ports).
cleanup_test() {
  # 1. Ask every daemon to shut down through the API (best-effort).
  for cmd in "${DAEMON_SHUTDOWN_CMDS[@]}"; do
    eval "$cmd" >/dev/null 2>&1 || true
  done

  # 2. Give processes up to 2s to exit on their own after API shutdown.
  local pids=("${DAEMON_PIDS[@]}")
  for _ in 1 2 3 4; do
    local any_alive=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        any_alive=1
        break
      fi
    done
    (( any_alive == 0 )) && break
    sleep 0.5
  done

  # 3. SIGKILL whatever is still alive (tracker, or a stuck daemon).
  for pid in "${pids[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

wait_for_tcp() {
  local host="$1" port="$2"
  for _ in $(seq 1 100); do
    bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# Login to a daemon API and return the SID cookie value.
# Args: api_host api_port
api_login() {
  local host="$1" port="$2"
  local sid
  sid=$(curl -s -c - "http://${host}:${port}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null \
    | grep SID | awk '{print $NF}')
  echo "$sid"
}

# Add a torrent to a daemon via the API.
# Args: api_host api_port sid torrent_file save_path
api_add_torrent() {
  local host="$1" port="$2" sid="$3" torrent_file="$4" save_path="$5"
  curl -s -b "SID=${sid}" \
    "http://${host}:${port}/api/v2/torrents/add?savepath=$(printf '%s' "$save_path" | sed 's/ /%20/g')" \
    --data-binary @"$torrent_file" >/dev/null 2>&1
}

# Query the torrent list from a daemon and extract the progress of the first torrent.
# Args: api_host api_port sid
api_get_progress() {
  local host="$1" port="$2" sid="$3"
  curl -s -b "SID=${sid}" "http://${host}:${port}/api/v2/torrents/info" 2>/dev/null \
    | sed 's/.*"progress":\([0-9.]*\).*/\1/'
}

# Write a varuna daemon TOML config file.
# Args: config_path host api_port peer_port data_dir
#
# api_bind and [network] bind_address both pin the daemon to the test's
# loopback address so its API, peer listener, outbound peer connects,
# and (via the HttpExecutor bind plumbing) tracker announces all go
# through the same 127.0.N.x address. Without bind_address the tracker
# announce would originate from 127.0.0.1 and opentracker would
# register the peer at the wrong IP.
#
# Each daemon MUST use its own resume_db. The default XDG path
# (~/.local/share/varuna/resume.db) is shared across daemon instances;
# sharing it between the seeder and downloader causes the downloader to
# load the seeder's completion records and skip downloading entirely
# (see progress-reports/2026-04-21-test-matrix-resume-db-isolation.md).
write_daemon_config() {
  local config_path="$1" host="$2" api_port="$3" peer_port="$4" data_dir="$5"
  cat >"$config_path" <<EOF
[daemon]
api_port = ${api_port}
api_bind = "${host}"
api_username = "admin"
api_password = "adminadmin"

[storage]
data_dir = "${data_dir}"
resume_db = "${data_dir}/resume.db"

[network]
bind_address = "${host}"
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
# Args: work_dir host api_port peer_port data_dir log_file
# Prints: the daemon PID
start_daemon() {
  local work_dir="$1" host="$2" api_port="$3" peer_port="$4" data_dir="$5" log_file="$6"
  mkdir -p "$work_dir"
  local config_path="$work_dir/varuna.toml"
  write_daemon_config "$config_path" "$host" "$api_port" "$peer_port" "$data_dir"
  "$VARUNA" --config "$config_path" >"$log_file" 2>&1 &
  echo "$!"
}

# Run a single-file transfer test
# Args: test_name payload_size_kb piece_length_bytes timeout_secs
run_single_file_test() {
  local name="$1" size_kb="$2" piece_len="$3" timeout_s="${4:-60}"

  TEST_INDEX=$((TEST_INDEX + 1))
  reset_test_state

  # Unique loopback /24 per test: tracker .1, seeder .2, downloader .3.
  local tracker_host="127.0.${TEST_INDEX}.1"
  local seed_host="127.0.${TEST_INDEX}.2"
  local dl_host="127.0.${TEST_INDEX}.3"
  # Ports are identical across tests because IPs differ; no 4-tuple collision.
  local tp=6969 sp=6881 dp=6882 sp_api=8081 dp_api=8082
  local W
  W=$(mktemp -d -t "vt-${name}-XXXXXX")

  echo -n "  $name (${size_kb}KB, piece=${piece_len})... "

  mkdir -p "$W/seed" "$W/dl"
  dd if=/dev/urandom of="$W/seed/payload.bin" bs=1024 count="$size_kb" 2>/dev/null

  "$VARUNA_TOOLS" create \
    -a "http://${tracker_host}:$tp/announce" \
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

  # Start tracker on the test's tracker IP
  "$ROOT_DIR/scripts/tracker.sh" --host "$tracker_host" --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  register_pid "$!"
  wait_for_tcp "$tracker_host" "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return; }

  # Start seeder daemon bound to its per-test IP
  local seed_pid
  seed_pid=$(start_daemon "$W/seed-daemon" "$seed_host" "$sp_api" "$sp" "$W/seed" "$W/seed.log")
  register_pid "$seed_pid"
  if ! wait_for_tcp "$seed_host" "$sp_api"; then
    echo "SKIP (seed daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi

  # Add torrent to seeder
  local seed_sid
  seed_sid=$(api_login "$seed_host" "$sp_api")
  if [[ -z "$seed_sid" ]]; then
    echo "SKIP (seed login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi
  register_shutdown "$seed_host" "$sp_api" "$seed_sid"
  api_add_torrent "$seed_host" "$sp_api" "$seed_sid" "$W/test.torrent" "$W/seed"

  # Wait for the seeder to finish its jittered initial tracker announce
  # (varuna applies up to ~5s of jitter to the first announce).
  sleep 6

  # Start downloader daemon bound to its per-test IP
  local dl_pid
  dl_pid=$(start_daemon "$W/dl-daemon" "$dl_host" "$dp_api" "$dp" "$W/dl" "$W/dl.log")
  register_pid "$dl_pid"
  if ! wait_for_tcp "$dl_host" "$dp_api"; then
    echo "SKIP (dl daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi

  # Add torrent to downloader
  local dl_sid
  dl_sid=$(api_login "$dl_host" "$dp_api")
  if [[ -z "$dl_sid" ]]; then
    echo "SKIP (dl login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi
  register_shutdown "$dl_host" "$dp_api" "$dl_sid"
  api_add_torrent "$dl_host" "$dp_api" "$dl_sid" "$W/test.torrent" "$W/dl"

  # Poll until download completes or timeout
  local elapsed=0
  local progress=""
  local completed=false
  while [[ $elapsed -lt $timeout_s ]]; do
    progress=$(api_get_progress "$dl_host" "$dp_api" "$dl_sid")
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

  cleanup_test
  rm -rf "$W"
}

# Run a multi-file (directory) transfer test
# Args: test_name file_specs piece_length_bytes timeout_secs
# file_specs is "size1_kb:name1,size2_kb:name2,..."
run_multi_file_test() {
  local name="$1" file_specs="$2" piece_len="$3" timeout_s="${4:-60}"

  TEST_INDEX=$((TEST_INDEX + 1))
  reset_test_state

  local tracker_host="127.0.${TEST_INDEX}.1"
  local seed_host="127.0.${TEST_INDEX}.2"
  local dl_host="127.0.${TEST_INDEX}.3"
  local tp=6969 sp=6881 dp=6882 sp_api=8081 dp_api=8082
  local W
  W=$(mktemp -d -t "vt-${name}-XXXXXX")

  echo -n "  $name (multi-file, piece=${piece_len})... "

  mkdir -p "$W/seed/content" "$W/dl"

  # Create files from spec
  IFS=',' read -ra specs <<< "$file_specs"
  local total_kb=0
  for spec in "${specs[@]}"; do
    local sz_kb="${spec%%:*}"
    local fname="${spec##*:}"
    local fdir
    fdir=$(dirname "$fname")
    [[ "$fdir" != "." ]] && mkdir -p "$W/seed/content/$fdir"
    dd if=/dev/urandom of="$W/seed/content/$fname" bs=1024 count="$sz_kb" 2>/dev/null
    total_kb=$((total_kb + sz_kb))
  done

  "$VARUNA_TOOLS" create \
    -a "http://${tracker_host}:$tp/announce" \
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

  "$ROOT_DIR/scripts/tracker.sh" --host "$tracker_host" --port "$tp" --whitelist-hash "$H" >"$W/tracker.log" 2>&1 &
  register_pid "$!"
  wait_for_tcp "$tracker_host" "$tp" || { echo "SKIP (tracker)"; SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return; }

  local seed_pid
  seed_pid=$(start_daemon "$W/seed-daemon" "$seed_host" "$sp_api" "$sp" "$W/seed" "$W/seed.log")
  register_pid "$seed_pid"
  if ! wait_for_tcp "$seed_host" "$sp_api"; then
    echo "SKIP (seed daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi

  local seed_sid
  seed_sid=$(api_login "$seed_host" "$sp_api")
  if [[ -z "$seed_sid" ]]; then
    echo "SKIP (seed login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi
  register_shutdown "$seed_host" "$sp_api" "$seed_sid"
  api_add_torrent "$seed_host" "$sp_api" "$seed_sid" "$W/test.torrent" "$W/seed"

  sleep 6

  local dl_pid
  dl_pid=$(start_daemon "$W/dl-daemon" "$dl_host" "$dp_api" "$dp" "$W/dl" "$W/dl.log")
  register_pid "$dl_pid"
  if ! wait_for_tcp "$dl_host" "$dp_api"; then
    echo "SKIP (dl daemon)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi

  local dl_sid
  dl_sid=$(api_login "$dl_host" "$dp_api")
  if [[ -z "$dl_sid" ]]; then
    echo "SKIP (dl login)"
    SKIP_COUNT=$((SKIP_COUNT+1)); RESULTS+=("SKIP $name"); cleanup_test; rm -rf "$W"; return
  fi
  register_shutdown "$dl_host" "$dp_api" "$dl_sid"
  api_add_torrent "$dl_host" "$dp_api" "$dl_sid" "$W/test.torrent" "$W/dl"

  local elapsed=0
  local progress=""
  local completed=false
  while [[ $elapsed -lt $timeout_s ]]; do
    progress=$(api_get_progress "$dl_host" "$dp_api" "$dl_sid")
    if [[ -n "$progress" ]] && awk "BEGIN{exit(!($progress >= 1.0))}" 2>/dev/null; then
      completed=true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if $completed; then
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

  cleanup_test
  rm -rf "$W"
}

# ─── Main ───────────────────────────────────────────────

echo "varuna transfer test matrix"
echo "==========================="
echo ""

# Build
zig build >/dev/null 2>&1

# Kill any lingering daemon processes from THIS worktree's previous runs.
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

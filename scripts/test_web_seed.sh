#!/usr/bin/env bash
# test_web_seed.sh — End-to-end test for BEP 19 web seed downloads.
#
# Runs three scenarios testing multi-piece batched HTTP Range requests:
#
# Scenario 1: Entire torrent in one request
#   - Small file (1MB, 256KB pieces = 4 pieces)
#   - web_seed_max_request_bytes >= file size
#   - Expects exactly 1 HTTP Range request
#
# Scenario 2: Multiple batched requests
#   - Larger file (4MB, 256KB pieces = 16 pieces)
#   - web_seed_max_request_bytes = 1048576 (1 MB, ~4 requests of 4 pieces)
#
# Scenario 3: Many small requests exceeding slot count
#   - Large file (8MB, 256KB pieces = 32 pieces)
#   - web_seed_max_request_bytes = 524288 (512KB, many small batches)
#
# Usage:
#   ./scripts/test_web_seed.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARUNA="$ROOT_DIR/zig-out/bin/varuna"
VARUNA_TOOLS="$ROOT_DIR/zig-out/bin/varuna-tools"
WORK_DIR=$(mktemp -d -t varuna-webseed-XXXXXX)

TRACKER_PORT=7969
WEB_SEED_PORT=7888
API_PORT=7082
PEER_PORT=7882

TRACKER_PID=""
WEB_SEED_PID=""
DAEMON_PID=""

cleanup() {
    for pid_var in DAEMON_PID WEB_SEED_PID TRACKER_PID; do
        local pid="${!pid_var}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

wait_for_tcp() {
    local host="$1" port="$2"
    for _ in $(seq 1 100); do
        bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "timed out waiting for $host:$port" >&2
    return 1
}

get_sid() {
    local port="$1"
    curl -s -c - "http://127.0.0.1:${port}/api/v2/auth/login" \
        -d "username=admin&password=adminadmin" 2>/dev/null | grep SID | awk '{print $NF}'
}

add_torrent() {
    local port="$1" sid="$2" torrent="$3"
    curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/add" \
        --data-binary @"$torrent" >/dev/null
}

set_web_seed_max() {
    local port="$1" sid="$2" max_bytes="$3"
    curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/app/setPreferences" \
        -d "json={\"web_seed_max_request_bytes\":${max_bytes}}" >/dev/null
}

wait_for_download() {
    local port="$1" sid="$2" timeout="$3"
    local start elapsed progress last=""
    start=$(date +%s)

    while true; do
        elapsed=$(( $(date +%s) - start ))

        local info
        info=$(curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/info" 2>/dev/null)
        progress=$(echo "$info" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d:
        t = d[0]
        pct = t['progress'] * 100
        print(f'{pct:.1f}%')
        if t['progress'] >= 1.0:
            print('DONE', file=sys.stderr)
    else:
        print('waiting...')
except Exception as e:
    print(f'error: {e}')
" 2>/tmp/ws_status.txt)

        if [[ "$progress" != "$last" ]]; then
            printf "\r  [%3ds] %s   " "$elapsed" "$progress"
            last="$progress"
        fi

        if grep -q DONE /tmp/ws_status.txt 2>/dev/null; then
            echo ""
            echo "  Download complete in ${elapsed}s"
            return 0
        fi

        if [[ $elapsed -ge $timeout ]]; then
            echo ""
            echo "  TIMEOUT after ${timeout}s (progress: ${progress})" >&2
            return 1
        fi

        sleep 1
    done
}

delete_all_torrents() {
    local port="$1" sid="$2"
    local hashes
    hashes=$(curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/info" 2>/dev/null | \
        python3 -c "import sys,json; [print(t['hash']) for t in json.load(sys.stdin)]" 2>/dev/null || true)
    for hash in $hashes; do
        curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/delete" \
            -d "hashes=${hash}&deleteFiles=true" >/dev/null 2>&1 || true
    done
    sleep 1
}

get_request_count() {
    curl -s "http://127.0.0.1:${WEB_SEED_PORT}/_stats" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['range_request_count'])" 2>/dev/null || echo "?"
}

reset_request_count() {
    curl -s "http://127.0.0.1:${WEB_SEED_PORT}/_reset" >/dev/null 2>&1 || true
}

echo "================================================================"
echo "  Web Seed E2E Test (BEP 19) — Multi-Piece Batching"
echo "================================================================"
echo ""
echo "Work dir: $WORK_DIR"

mkdir -p "$WORK_DIR/seed-files" "$WORK_DIR/download-root" "$WORK_DIR/daemon"

# ── Kill any leftover processes on our ports ──────────────
pkill -9 -f "web_seed_server.*${WEB_SEED_PORT}" 2>/dev/null || true
pkill -9 -f "varuna.*${API_PORT}" 2>/dev/null || true
pkill -9 -f "opentracker.*${TRACKER_PORT}" 2>/dev/null || true
sleep 0.5

# ── Start web seed HTTP server ───────────────────────────
python3 "$ROOT_DIR/scripts/web_seed_server.py" \
    --port "$WEB_SEED_PORT" \
    --dir "$WORK_DIR/seed-files" \
    --bind 127.0.0.1 &
WEB_SEED_PID=$!
wait_for_tcp 127.0.0.1 "$WEB_SEED_PORT"
echo "Web seed server started (PID $WEB_SEED_PID)"

# ── Write daemon config ─────────────────────────────────
cat >"$WORK_DIR/daemon/varuna.toml" <<EOF
[daemon]
api_port = ${API_PORT}
api_bind = "127.0.0.1"
api_username = "admin"
api_password = "adminadmin"

[storage]
data_dir = "$WORK_DIR/download-root"
resume_db = ":memory:"

[network]
port_min = ${PEER_PORT}
port_max = ${PEER_PORT}
dht = false
pex = false
encryption = "disabled"
enable_utp = false
web_seed_max_request_bytes = 4194304
EOF

# ── Start downloader daemon ──────────────────────────────
(cd "$WORK_DIR/daemon" && exec "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_for_tcp 127.0.0.1 "$API_PORT"
echo "Daemon started (PID $DAEMON_PID)"
SID=$(get_sid "$API_PORT")

PASSED=0
FAILED=0

# ────────────────────────────────────────────────────────
# Scenario 1: Entire torrent in one request
# ────────────────────────────────────────────────────────
echo ""
echo "─── Scenario 1: Entire torrent in one request ───────────────"

SIZE_1=$((1 * 1024 * 1024))  # 1 MB
PAYLOAD_1="$WORK_DIR/seed-files/scenario1.bin"
dd if=/dev/urandom of="$PAYLOAD_1" bs=1024 count=$((SIZE_1 / 1024)) 2>/dev/null
echo "  File: scenario1.bin (${SIZE_1} bytes, 4 pieces @ 256KB)"

TORRENT_1="$WORK_DIR/scenario1.torrent"
WEB_SEED_URL_1="http://127.0.0.1:${WEB_SEED_PORT}/scenario1.bin"
TRACKER_URL="http://127.0.0.1:${TRACKER_PORT}/announce"

"$VARUNA_TOOLS" create \
    -a "$TRACKER_URL" \
    -w "$WEB_SEED_URL_1" \
    -l 262144 \
    -o "$TORRENT_1" \
    "$PAYLOAD_1"

INFO_HASH_1=$("$VARUNA_TOOLS" inspect "$TORRENT_1" | awk -F= '/^info_hash=/{print $2}')
echo "  Info hash: $INFO_HASH_1"

# Start tracker for this scenario
"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH_1" >"$WORK_DIR/tracker.log" 2>&1 &
TRACKER_PID=$!
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

# Set max_request_bytes large enough for entire file
set_web_seed_max "$API_PORT" "$SID" "$((8 * 1024 * 1024))"
reset_request_count

add_torrent "$API_PORT" "$SID" "$TORRENT_1"
echo "  Torrent added, downloading..."

if wait_for_download "$API_PORT" "$SID" 120; then
    DOWNLOADED_1="$WORK_DIR/download-root/scenario1.bin"
    RANGE_REQS=$(get_request_count)
    echo "  Range requests: $RANGE_REQS"

    if [[ -f "$DOWNLOADED_1" ]] && cmp -s "$PAYLOAD_1" "$DOWNLOADED_1"; then
        echo "  PASSED: File verified"
        PASSED=$((PASSED + 1))
    else
        echo "  FAILED: File mismatch or not found" >&2
        FAILED=$((FAILED + 1))
    fi
else
    echo "  FAILED: Download timed out" >&2
    tail -10 "$WORK_DIR/daemon.log" >&2
    FAILED=$((FAILED + 1))
fi

# Clean up for next scenario
# Restart daemon and tracker between scenarios for clean state
kill -9 "$DAEMON_PID" 2>/dev/null || true
kill -9 "$TRACKER_PID" 2>/dev/null || true
# Also pkill in case kill didn't reach the process (WSL2 subprocess issue)
pkill -9 -f "varuna.*${API_PORT}" 2>/dev/null || true
pkill -9 -f "opentracker.*${TRACKER_PORT}" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
wait "$TRACKER_PID" 2>/dev/null || true
DAEMON_PID=""
TRACKER_PID=""
sleep 1
rm -rf "$WORK_DIR/download-root"/*
(cd "$WORK_DIR/daemon" && exec "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_for_tcp 127.0.0.1 "$API_PORT"
SID=$(get_sid "$API_PORT")

# ────────────────────────────────────────────────────────
# Scenario 2: Multiple batched requests (1 MB max per request)
# ────────────────────────────────────────────────────────
echo ""
echo "─── Scenario 2: Multiple batched requests (1MB max) ─────────"

SIZE_2=$((4 * 1024 * 1024))  # 4 MB
PAYLOAD_2="$WORK_DIR/seed-files/scenario2.bin"
dd if=/dev/urandom of="$PAYLOAD_2" bs=1024 count=$((SIZE_2 / 1024)) 2>/dev/null
echo "  File: scenario2.bin (${SIZE_2} bytes, 16 pieces @ 256KB)"

TORRENT_2="$WORK_DIR/scenario2.torrent"
WEB_SEED_URL_2="http://127.0.0.1:${WEB_SEED_PORT}/scenario2.bin"

"$VARUNA_TOOLS" create \
    -a "$TRACKER_URL" \
    -w "$WEB_SEED_URL_2" \
    -l 262144 \
    -o "$TORRENT_2" \
    "$PAYLOAD_2"

INFO_HASH_2=$("$VARUNA_TOOLS" inspect "$TORRENT_2" | awk -F= '/^info_hash=/{print $2}')
echo "  Info hash: $INFO_HASH_2"

"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH_2" >"$WORK_DIR/tracker.log" 2>&1 &
TRACKER_PID=$!
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

# Set max_request_bytes to 1 MB (4 pieces per batch = ~4 requests)
set_web_seed_max "$API_PORT" "$SID" "$((1 * 1024 * 1024))"
reset_request_count

add_torrent "$API_PORT" "$SID" "$TORRENT_2"
echo "  Torrent added, downloading..."

if wait_for_download "$API_PORT" "$SID" 120; then
    DOWNLOADED_2="$WORK_DIR/download-root/scenario2.bin"
    RANGE_REQS=$(get_request_count)
    echo "  Range requests: $RANGE_REQS"

    if [[ -f "$DOWNLOADED_2" ]] && cmp -s "$PAYLOAD_2" "$DOWNLOADED_2"; then
        echo "  PASSED: File verified"
        PASSED=$((PASSED + 1))
    else
        echo "  FAILED: File mismatch or not found" >&2
        FAILED=$((FAILED + 1))
    fi
else
    echo "  FAILED: Download timed out" >&2
    tail -10 "$WORK_DIR/daemon.log" >&2
    FAILED=$((FAILED + 1))
fi

# Restart daemon and tracker between scenarios for clean state
kill -9 "$DAEMON_PID" 2>/dev/null || true
kill -9 "$TRACKER_PID" 2>/dev/null || true
# Also pkill in case kill didn't reach the process (WSL2 subprocess issue)
pkill -9 -f "varuna.*${API_PORT}" 2>/dev/null || true
pkill -9 -f "opentracker.*${TRACKER_PORT}" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
wait "$TRACKER_PID" 2>/dev/null || true
DAEMON_PID=""
TRACKER_PID=""
sleep 1
rm -rf "$WORK_DIR/download-root"/*
(cd "$WORK_DIR/daemon" && exec "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_for_tcp 127.0.0.1 "$API_PORT"
SID=$(get_sid "$API_PORT")

# ────────────────────────────────────────────────────────
# Scenario 3: Many small requests (512KB max per request)
# ────────────────────────────────────────────────────────
echo ""
echo "─── Scenario 3: Many small requests (512KB max) ─────────────"

SIZE_3=$((8 * 1024 * 1024))  # 8 MB
PAYLOAD_3="$WORK_DIR/seed-files/scenario3.bin"
dd if=/dev/urandom of="$PAYLOAD_3" bs=1024 count=$((SIZE_3 / 1024)) 2>/dev/null
echo "  File: scenario3.bin (${SIZE_3} bytes, 32 pieces @ 256KB)"

TORRENT_3="$WORK_DIR/scenario3.torrent"
WEB_SEED_URL_3="http://127.0.0.1:${WEB_SEED_PORT}/scenario3.bin"

"$VARUNA_TOOLS" create \
    -a "$TRACKER_URL" \
    -w "$WEB_SEED_URL_3" \
    -l 262144 \
    -o "$TORRENT_3" \
    "$PAYLOAD_3"

INFO_HASH_3=$("$VARUNA_TOOLS" inspect "$TORRENT_3" | awk -F= '/^info_hash=/{print $2}')
echo "  Info hash: $INFO_HASH_3"

"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH_3" >"$WORK_DIR/tracker.log" 2>&1 &
TRACKER_PID=$!
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

# Set max_request_bytes to 512 KB (2 pieces per batch = many requests)
set_web_seed_max "$API_PORT" "$SID" "$((512 * 1024))"
reset_request_count

add_torrent "$API_PORT" "$SID" "$TORRENT_3"
echo "  Torrent added, downloading..."

if wait_for_download "$API_PORT" "$SID" 120; then
    DOWNLOADED_3="$WORK_DIR/download-root/scenario3.bin"
    RANGE_REQS=$(get_request_count)
    echo "  Range requests: $RANGE_REQS"

    if [[ -f "$DOWNLOADED_3" ]] && cmp -s "$PAYLOAD_3" "$DOWNLOADED_3"; then
        echo "  PASSED: File verified"
        PASSED=$((PASSED + 1))
    else
        echo "  FAILED: File mismatch or not found" >&2
        FAILED=$((FAILED + 1))
    fi
else
    echo "  FAILED: Download timed out" >&2
    tail -10 "$WORK_DIR/daemon.log" >&2
    FAILED=$((FAILED + 1))
fi

# ── Final results ───────────────────────────────────────
echo ""
echo "================================================================"
if [[ $FAILED -eq 0 ]]; then
    echo "  ALL ${PASSED}/3 SCENARIOS PASSED"
else
    echo "  FAILED: ${FAILED}/3 scenarios failed (${PASSED} passed)"
fi
echo "================================================================"

rm -f /tmp/ws_status.txt

[[ $FAILED -eq 0 ]]

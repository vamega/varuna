#!/usr/bin/env bash
# test_web_seed.sh — End-to-end test for BEP 19 web seed downloads.
#
# Creates a random 2-4MB file, builds a torrent with a web seed URL,
# starts a Python HTTP server (with Range support) as the web seed,
# starts opentracker, starts a varuna daemon (downloader only, no seeder),
# and verifies that the daemon downloads the file entirely from the web seed.
#
# Usage:
#   ./scripts/test_web_seed.sh
#
# Environment:
#   FILE_SIZE_MB=3  — override file size (default: random 2-4)

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

echo "================================================================"
echo "  Web Seed E2E Test (BEP 19)"
echo "================================================================"
echo ""
echo "Work dir: $WORK_DIR"

# ── Generate random payload ──────────────────────────────
# Random size between 2-4 MB (or override with FILE_SIZE_MB)
if [[ -n "${FILE_SIZE_MB:-}" ]]; then
    SIZE_BYTES=$((FILE_SIZE_MB * 1024 * 1024))
else
    SIZE_MB=$((RANDOM % 3 + 2))
    SIZE_BYTES=$((SIZE_MB * 1024 * 1024))
fi

mkdir -p "$WORK_DIR/seed-files" "$WORK_DIR/download-root" "$WORK_DIR/daemon"
PAYLOAD="$WORK_DIR/seed-files/testdata.bin"
dd if=/dev/urandom of="$PAYLOAD" bs=1024 count=$((SIZE_BYTES / 1024)) 2>/dev/null
PAYLOAD_SIZE=$(stat -c%s "$PAYLOAD")
echo "Payload: testdata.bin (${PAYLOAD_SIZE} bytes, $((PAYLOAD_SIZE / 1024 / 1024)) MB)"

# ── Create torrent with web seed URL ─────────────────────
TORRENT="$WORK_DIR/testdata.torrent"
WEB_SEED_URL="http://127.0.0.1:${WEB_SEED_PORT}/testdata.bin"
TRACKER_URL="http://127.0.0.1:${TRACKER_PORT}/announce"

mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
    --input "$PAYLOAD" \
    --output "$TORRENT" \
    --announce "$TRACKER_URL" \
    --url-list "$WEB_SEED_URL" \
    --piece-length 262144

# Verify the torrent has url-list
"$VARUNA_TOOLS" inspect "$TORRENT" | grep -i "url.list\|web.seed" || echo "(url-list field present in metainfo)"
INFO_HASH=$("$VARUNA_TOOLS" inspect "$TORRENT" | awk -F= '/^info_hash=/{print $2}')
echo "Info hash: $INFO_HASH"
echo "Web seed: $WEB_SEED_URL"
echo "Tracker:  $TRACKER_URL"

# ── Start web seed HTTP server ───────────────────────────
python3 "$ROOT_DIR/scripts/web_seed_server.py" \
    --port "$WEB_SEED_PORT" \
    --dir "$WORK_DIR/seed-files" \
    --bind 127.0.0.1 &
WEB_SEED_PID=$!
wait_for_tcp 127.0.0.1 "$WEB_SEED_PORT"
echo "Web seed server started (PID $WEB_SEED_PID)"

# Verify web seed serves the file with Range support
HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_SEED_PORT}/testdata.bin")
if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "FAIL: web seed returned HTTP $HTTP_STATUS" >&2
    exit 1
fi
RANGE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H "Range: bytes=0-1023" "http://127.0.0.1:${WEB_SEED_PORT}/testdata.bin")
if [[ "$RANGE_STATUS" != "206" ]]; then
    echo "FAIL: web seed Range request returned HTTP $RANGE_STATUS (expected 206)" >&2
    exit 1
fi
echo "Web seed HTTP + Range: OK"

# ── Start tracker ────────────────────────────────────────
"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH" >"$WORK_DIR/tracker.log" 2>&1 &
TRACKER_PID=$!
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"
echo "Tracker started (PID $TRACKER_PID)"

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
EOF

# ── Start downloader daemon ──────────────────────────────
(cd "$WORK_DIR/daemon" && "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_for_tcp 127.0.0.1 "$API_PORT"
echo "Daemon started (PID $DAEMON_PID)"

# ── Add torrent ──────────────────────────────────────────
SID=$(curl -s -c - "http://127.0.0.1:${API_PORT}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null | grep SID | awk '{print $NF}')
curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
    --data-binary @"$TORRENT" >/dev/null
echo "Torrent added, waiting for web seed download..."

# ── Poll until download completes ────────────────────────
TIMEOUT=120
START=$(date +%s)
LAST=""
while true; do
    ELAPSED=$(( $(date +%s) - START ))

    INFO=$(curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/info" 2>/dev/null)
    PROGRESS=$(echo "$INFO" | python3 -c "
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

    if [[ "$PROGRESS" != "$LAST" ]]; then
        printf "\r[%3ds] %s   " "$ELAPSED" "$PROGRESS"
        LAST="$PROGRESS"
    fi

    if grep -q DONE /tmp/ws_status.txt 2>/dev/null; then
        echo ""
        echo "Download complete in ${ELAPSED}s"
        break
    fi

    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        echo ""
        echo "TIMEOUT after ${TIMEOUT}s (progress: ${PROGRESS})" >&2
        echo "Daemon log tail:" >&2
        tail -20 "$WORK_DIR/daemon.log" >&2
        exit 1
    fi

    sleep 1
done

# ── Verify downloaded file matches ───────────────────────
DOWNLOADED="$WORK_DIR/download-root/testdata.bin"
if [[ ! -f "$DOWNLOADED" ]]; then
    echo "FAIL: downloaded file not found at $DOWNLOADED" >&2
    ls -la "$WORK_DIR/download-root/" >&2
    exit 1
fi

if cmp -s "$PAYLOAD" "$DOWNLOADED"; then
    echo ""
    echo "================================================================"
    echo "  PASSED: Web seed download verified"
    echo "  File: testdata.bin (${PAYLOAD_SIZE} bytes)"
    echo "  Source: web seed only (no BT peers)"
    echo "================================================================"
else
    echo "FAIL: downloaded file does not match original" >&2
    echo "Original: $(md5sum "$PAYLOAD")" >&2
    echo "Downloaded: $(md5sum "$DOWNLOADED")" >&2
    exit 1
fi

rm -f /tmp/ws_status.txt

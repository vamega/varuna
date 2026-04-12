#!/usr/bin/env bash
# End-to-end integration test for the varuna daemon.
#
# Tests: daemon startup, torrent add via API, download progress monitoring,
# multi-torrent simultaneous downloads, speed reporting, and cleanup.
#
# Usage:
#   ./scripts/test_e2e_downloads.sh                    # run all tests
#   ./scripts/test_e2e_downloads.sh single <torrent>   # single torrent test
#   ./scripts/test_e2e_downloads.sh multi              # multi-torrent test
#
# Requires: curl, python3, varuna/varuna-ctl/varuna-tools built in zig-out/bin/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VARUNA="$PROJECT_DIR/zig-out/bin/varuna"
VARUNA_CTL="$PROJECT_DIR/zig-out/bin/varuna-ctl"
VARUNA_TOOLS="$PROJECT_DIR/zig-out/bin/varuna-tools"

API_PORT=18080
API_HOST="127.0.0.1"
PEER_PORT=16881
WORK_DIR=""
DAEMON_PID=""
SID=""

# ── Helpers ──────────────────────────────────────────

log()  { echo "$(date +%H:%M:%S) [test] $*"; }
pass() { echo "$(date +%H:%M:%S) [PASS] $*"; }
fail() { echo "$(date +%H:%M:%S) [FAIL] $*"; }

cleanup() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        log "stopping daemon (pid $DAEMON_PID)"
        kill "$DAEMON_PID" 2>/dev/null || true
        sleep 1
        # Force kill if still alive
        kill -0 "$DAEMON_PID" 2>/dev/null && kill -9 "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

start_daemon() {
    WORK_DIR=$(mktemp -d /tmp/varuna-e2e-XXXXXX)
    log "work dir: $WORK_DIR"

    # Write config
    cat > "$WORK_DIR/varuna.toml" <<EOF
[daemon]
api_port = $API_PORT
api_bind = "$API_HOST"

[network]
port_min = $PEER_PORT
dht = true
pex = true
EOF

    # Clear stale resume DB
    rm -f ~/.local/share/varuna/resume.db

    cd "$WORK_DIR"
    "$VARUNA" > "$WORK_DIR/daemon.log" 2>&1 &
    DAEMON_PID=$!
    log "daemon started (pid $DAEMON_PID)"

    # Wait for API to be ready
    for i in $(seq 1 30); do
        if curl -s "http://$API_HOST:$API_PORT/api/v2/app/version" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Login
    SID=$(curl -s -c - "http://$API_HOST:$API_PORT/api/v2/auth/login" \
        -d 'username=admin&password=adminadmin' -D - 2>/dev/null \
        | grep -oP 'SID=\K[a-f0-9]+' || true)

    if [ -z "$SID" ]; then
        fail "could not login to daemon API"
        cat "$WORK_DIR/daemon.log"
        exit 1
    fi
    log "logged in (SID=$SID)"
}

api_get() {
    curl -s -b "SID=$SID" "http://$API_HOST:$API_PORT$1" 2>/dev/null
}

api_post() {
    curl -s -b "SID=$SID" "http://$API_HOST:$API_PORT$1" -d "$2" 2>/dev/null
}

add_torrent() {
    local torrent_file="$1"
    local save_path="$2"
    mkdir -p "$save_path"
    curl -s -b "SID=$SID" \
        -F "torrents=@$torrent_file" \
        -F "savepath=$save_path" \
        "http://$API_HOST:$API_PORT/api/v2/torrents/add" >/dev/null
}

# Poll all torrents and print status. Exits 0 when all are complete.
poll_status() {
    api_get "/api/v2/torrents/info" | python3 -c "
import sys, json
try:
    torrents = json.load(sys.stdin)
except: sys.exit(1)
if not torrents: sys.exit(1)
all_done = True
for t in sorted(torrents, key=lambda x: x['name']):
    name = t['name'][:40]
    pct = t['progress'] * 100
    spd = t['dlspeed'] / 1024 / 1024
    dl = t['downloaded'] / 1024 / 1024
    total = t['total_size'] / 1024 / 1024
    peers = t['num_seeds'] + t['num_leechs']
    st = t['state']
    print(f'  {name:<40} {pct:5.1f}% | {spd:6.2f} MB/s | {dl:7.0f}/{total:.0f} MB | peers={peers:4} | {st}')
    if pct < 100: all_done = False
if all_done: sys.exit(0)
sys.exit(1)
"
}

wait_for_completion() {
    local timeout=$1
    local interval=${2:-10}
    local start=$(date +%s)

    while true; do
        local now=$(date +%s)
        local elapsed=$(( now - start ))
        if [ $elapsed -ge $timeout ]; then
            return 1
        fi
        echo "── ${elapsed}s ──"
        if poll_status; then
            return 0
        fi
        sleep "$interval"
    done
}

report() {
    log "=== Download Report ==="
    api_get "/api/v2/torrents/info" | python3 -c "
import sys, json
torrents = json.load(sys.stdin)
for t in sorted(torrents, key=lambda x: x['name']):
    name = t['name']
    dl = t['downloaded'] / 1024 / 1024
    total = t['total_size'] / 1024 / 1024
    pct = t['progress'] * 100
    state = t['state']
    seeds = t['num_seeds']
    leechs = t['num_leechs']
    print(f'  {name}')
    print(f'    status:     {state} ({pct:.1f}%)')
    print(f'    downloaded: {dl:.0f} / {total:.0f} MB')
    print(f'    peers:      {seeds} seeds + {leechs} leeches')
"
}

delete_all_torrents() {
    local hashes
    hashes=$(api_get "/api/v2/torrents/info" | python3 -c "
import sys, json
for t in json.load(sys.stdin): print(t['hash'])
" 2>/dev/null)
    for h in $hashes; do
        api_post "/api/v2/torrents/delete" "hashes=$h&deleteFiles=true" >/dev/null
    done
}

# ── Test: Single Torrent Download ──────────────────────

test_single_download() {
    local torrent_file="$1"
    local name
    name=$("$VARUNA_TOOLS" inspect "$torrent_file" 2>/dev/null | grep '^name=' | cut -d= -f2-)
    log "=== Single Download Test: $name ==="

    start_daemon
    add_torrent "$torrent_file" "$WORK_DIR/dl"

    local timeout=600  # 10 minutes
    log "waiting up to ${timeout}s for download..."

    if wait_for_completion $timeout 10; then
        report
        pass "$name downloaded successfully"
    else
        report
        fail "$name did not complete within ${timeout}s"
        log "--- daemon log tail ---"
        tail -30 "$WORK_DIR/daemon.log"
        return 1
    fi
}

# ── Test: Multi-Torrent Simultaneous Download ──────────

test_multi_download() {
    shift 2>/dev/null || true
    local torrents=("$@")

    if [ ${#torrents[@]} -eq 0 ]; then
        log "no torrent files specified for multi-download test"
        return 1
    fi

    log "=== Multi-Torrent Simultaneous Download Test ==="
    log "torrents: ${#torrents[@]}"
    for t in "${torrents[@]}"; do
        "$VARUNA_TOOLS" inspect "$t" 2>/dev/null | grep '^name=' | sed 's/^name=/  /'
    done

    start_daemon

    # Add all torrents at once
    local i=0
    for t in "${torrents[@]}"; do
        add_torrent "$t" "$WORK_DIR/dl$i"
        i=$((i + 1))
    done
    log "added ${#torrents[@]} torrents"

    local timeout=900  # 15 minutes
    local start=$(date +%s)
    log "waiting up to ${timeout}s for all downloads..."

    if wait_for_completion $timeout 15; then
        local end=$(date +%s)
        local elapsed=$(( end - start ))
        report
        pass "all ${#torrents[@]} torrents downloaded in ${elapsed}s"
    else
        local end=$(date +%s)
        local elapsed=$(( end - start ))
        report
        fail "not all torrents completed within ${timeout}s (${elapsed}s elapsed)"
        log "--- daemon log (errors only) ---"
        grep -i "error\|panic\|segfault" "$WORK_DIR/daemon.log" | tail -10 || echo "(no errors in log)"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────

main() {
    local mode="${1:-all}"

    # Check binaries exist
    for bin in "$VARUNA" "$VARUNA_CTL" "$VARUNA_TOOLS"; do
        if [ ! -x "$bin" ]; then
            log "binary not found: $bin (run 'zig build' first)"
            exit 1
        fi
    done

    case "$mode" in
        quick)
            # Quick smoke test: download the smallest torrent (LibreELEC, 275MB)
            local quick_torrent="$PROJECT_DIR/testdata/torrents/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent"
            if [ ! -f "$quick_torrent" ]; then
                log "quick torrent not found: $quick_torrent"
                exit 1
            fi
            test_single_download "$quick_torrent"
            ;;
        single)
            if [ -z "${2:-}" ]; then
                echo "usage: $0 single <torrent-file>"
                exit 1
            fi
            test_single_download "$2"
            ;;
        multi)
            shift
            test_multi_download "$@"
            ;;
        all)
            log "=== Running full E2E test suite ==="

            # Torrent files committed in testdata/torrents/ (by size):
            #   LibreELEC  275 MB  UDP tracker (fosstorrents), multiple trackers
            #   Kali       695 MB  HTTP tracker (kali.org)
            #   Debian     753 MB  HTTP tracker (debian.org)
            #   Ubuntu     5.3 GB  HTTPS tracker (ubuntu.com), returns few peers
            local torrent_dir="$PROJECT_DIR/testdata/torrents"
            local torrents=()

            # Prefer smaller torrents first for faster feedback.
            # Ubuntu excluded from default 'all' — its HTTPS tracker returns
            # very few peers and 5.3 GB at <1 MB/s exceeds the 15-min timeout.
            # Use 'full' mode to include Ubuntu.
            for f in \
                "$torrent_dir/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent" \
                "$torrent_dir/kali-linux-installer.torrent" \
                "$torrent_dir/debian-13.4.0-amd64-netinst.iso.torrent"; do
                if [ -f "$f" ]; then
                    torrents+=("$f")
                fi
            done

            if [ ${#torrents[@]} -eq 0 ]; then
                log "no torrent files found in testdata/torrents/"
                log "expected: LibreELEC, kali, debian, ubuntu torrents"
                exit 1
            fi

            log "found ${#torrents[@]} torrent files"

            # Test 1: Single torrent (smallest — LibreELEC at 275MB)
            test_single_download "${torrents[0]}"
            cleanup
            DAEMON_PID=""
            WORK_DIR=""
            sleep 1

            # Test 2: Multi-torrent simultaneous (all available)
            if [ ${#torrents[@]} -ge 2 ]; then
                test_multi_download "${torrents[@]}"
            else
                log "skipping multi-torrent test (need >= 2 torrent files)"
            fi

            log "=== E2E test suite complete ==="
            ;;
        full)
            # Like 'all' but includes Ubuntu (5.3 GB, slow tracker).
            # Expect this to take 1-2 hours depending on swarm availability.
            log "=== Running FULL E2E test suite (including Ubuntu 5.3 GB) ==="
            local torrent_dir="$PROJECT_DIR/testdata/torrents"
            local all_torrents=()
            for f in \
                "$torrent_dir/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent" \
                "$torrent_dir/kali-linux-installer.torrent" \
                "$torrent_dir/debian-13.4.0-amd64-netinst.iso.torrent" \
                "$torrent_dir/ubuntu-25.10-desktop-amd64.iso.torrent"; do
                if [ -f "$f" ]; then
                    all_torrents+=("$f")
                fi
            done
            if [ ${#all_torrents[@]} -eq 0 ]; then
                log "no torrent files found"; exit 1
            fi
            test_multi_download "${all_torrents[@]}"
            log "=== FULL E2E test suite complete ==="
            ;;
        *)
            echo "usage: $0 [quick|all|full|single <torrent>|multi <torrent1> <torrent2> ...]"
            exit 1
            ;;
    esac
}

main "$@"

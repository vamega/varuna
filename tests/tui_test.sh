#!/usr/bin/env bash
# Integration tests for varuna-tui using tmux + a mock API server.
#
# Prerequisites: tmux, python3, varuna-tui built (zig build).
#
# Runs a mock qBittorrent WebAPI server, launches varuna-tui in a tmux
# session, sends keystrokes, and verifies screen contents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TUI_BIN="$PROJECT_DIR/zig-out/bin/varuna-tui"
MOCK_SERVER="$SCRIPT_DIR/tui_mock_server.py"
MOCK_PORT=18090
SESSION="varuna-tui-test-$$"
MOCK_PID=""
PASSED=0
FAILED=0
TOTAL=0

cleanup() {
    # Kill mock server
    if [ -n "$MOCK_PID" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    # Kill tmux session
    tmux kill-session -t "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    echo "FATAL: $1" >&2
    exit 1
}

assert_screen_contains() {
    local label="$1"
    local needle="$2"
    TOTAL=$((TOTAL + 1))
    local content
    content=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || echo "")
    if echo "$content" | grep -qF "$needle"; then
        echo "  PASS: $label"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: $label -- expected to find: $needle"
        echo "  --- screen content ---"
        echo "$content" | head -20
        echo "  ----------------------"
        FAILED=$((FAILED + 1))
    fi
}

assert_screen_not_contains() {
    local label="$1"
    local needle="$2"
    TOTAL=$((TOTAL + 1))
    local content
    content=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || echo "")
    if echo "$content" | grep -qF "$needle"; then
        echo "  FAIL: $label -- should NOT find: $needle"
        FAILED=$((FAILED + 1))
    else
        echo "  PASS: $label"
        PASSED=$((PASSED + 1))
    fi
}

send_keys() {
    tmux send-keys -t "$SESSION" "$@"
}

wait_for() {
    # Wait up to N seconds for a string to appear on screen
    local needle="$1"
    local timeout="${2:-10}"
    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        local content
        content=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null || echo "")
        if echo "$content" | grep -qF "$needle"; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ── Preflight checks ────────────────────────────────────────────────

[ -x "$TUI_BIN" ] || die "varuna-tui not found at $TUI_BIN -- run 'zig build' first"
[ -f "$MOCK_SERVER" ] || die "Mock server not found at $MOCK_SERVER"
command -v tmux >/dev/null 2>&1 || die "tmux is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

echo "=== varuna-tui integration tests ==="
echo "Mock server port: $MOCK_PORT"
echo ""

# ── Start mock server ────────────────────────────────────────────────

python3 "$MOCK_SERVER" "$MOCK_PORT" &
MOCK_PID=$!
sleep 1

# Verify mock server is running
if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    die "Mock server failed to start"
fi

# ── Start TUI in tmux ───────────────────────────────────────────────

tmux new-session -d -s "$SESSION" -x 120 -y 35 \
    "$TUI_BIN --host 127.0.0.1 --port $MOCK_PORT"

# Wait for the TUI to connect and show data
echo "Waiting for TUI to connect..."
if ! wait_for "ubuntu" 15; then
    echo "WARN: TUI did not show torrent data within timeout"
    echo "Screen content:"
    tmux capture-pane -t "$SESSION" -p 2>/dev/null || true
fi

# ── Test 1: Main view shows torrent list ─────────────────────────────

echo ""
echo "Test 1: Main view torrent list"
# Title bar may use ANSI styling; check for torrent data instead
assert_screen_contains "shows ubuntu torrent" "ubuntu"
assert_screen_contains "shows arch torrent" "archlinux"
assert_screen_contains "shows Connected status" "Connected"
assert_screen_contains "shows DHT count" "DHT"

# ── Test 2: Navigation ──────────────────────────────────────────────

echo ""
echo "Test 2: Navigation with j/k"
send_keys j
sleep 0.5
# Second torrent should now be highlighted (arch)
# We can't easily verify highlight, but the screen should still show both
assert_screen_contains "both torrents visible after j" "archlinux"

send_keys k
sleep 0.5
assert_screen_contains "both torrents visible after k" "ubuntu"

# ── Test 3: Detail view ─────────────────────────────────────────────

echo ""
echo "Test 3: Detail view"
send_keys Enter
sleep 1
# Should show detail view with torrent info
assert_screen_contains "detail shows torrent name" "ubuntu"
assert_screen_contains "detail shows Status" "Status"

# Switch tabs
send_keys Tab
sleep 0.5
# Now on trackers tab
assert_screen_contains "trackers tab" "Trackers"

send_keys Tab
sleep 0.5
# Now on info tab
assert_screen_contains "info tab" "Info"

# Go back to main
send_keys q
sleep 0.5
assert_screen_contains "back to main view" "archlinux"

# ── Test 4: Add torrent dialog ───────────────────────────────────────

echo ""
echo "Test 4: Add torrent dialog"
send_keys a
sleep 0.5
assert_screen_contains "add dialog shows" "Add Torrent"
assert_screen_contains "shows magnet prompt" "Magnet"

# Type a magnet URI
send_keys "magnet:?xt=test"
sleep 0.3

# Cancel
send_keys Escape
sleep 0.5
assert_screen_contains "back to main after cancel" "ubuntu"

# ── Test 5: Delete confirmation dialog ───────────────────────────────

echo ""
echo "Test 5: Delete confirmation"
send_keys d
sleep 0.5
assert_screen_contains "delete dialog shows" "Delete Torrent"
assert_screen_contains "shows torrent name" "ubuntu"
assert_screen_contains "shows delete files option" "Delete files"

# Toggle delete files
send_keys f
sleep 0.3
assert_screen_contains "toggle shows checkbox" "[x]"

# Cancel delete
send_keys n
sleep 0.5
assert_screen_contains "back to main after cancel delete" "ubuntu"

# ── Test 6: Preferences view ────────────────────────────────────────

echo ""
echo "Test 6: Preferences view"
send_keys P
sleep 1.5
assert_screen_contains "preferences shows title" "Preferences"
assert_screen_contains "shows listen port" "Listen port"
assert_screen_contains "shows DHT setting" "DHT"

# Navigate with j/k
send_keys j
sleep 0.3
send_keys j
sleep 0.3

# Go back
send_keys q
sleep 0.5
assert_screen_contains "back to main after prefs" "ubuntu"

# ── Test 7: Filter mode ─────────────────────────────────────────────

echo ""
echo "Test 7: Filter mode"
send_keys /
sleep 0.3
assert_screen_contains "filter mode active" "Filter"

send_keys "arch"
sleep 0.3
send_keys Enter
sleep 0.5
# After filtering, only arch torrent should be visible
assert_screen_contains "filtered shows arch" "archlinux"

# Clear filter by pressing / and immediately Enter
send_keys /
sleep 0.2
send_keys Escape
sleep 0.5

# ── Test 8: Quit ────────────────────────────────────────────────────

echo ""
echo "Test 8: Quit"
send_keys q
sleep 1

# The session should have ended
if tmux has-session -t "$SESSION" 2>/dev/null; then
    # TUI might still be running, try again
    send_keys q
    sleep 1
fi

# ── Results ──────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
echo "Passed: $PASSED / $TOTAL"
echo "Failed: $FAILED / $TOTAL"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

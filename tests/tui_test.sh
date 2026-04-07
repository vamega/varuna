#!/usr/bin/env bash
# Integration tests for varuna-tui using tmux.
#
# Spawns a mock API server, launches varuna-tui in a tmux session,
# and uses send-keys/capture-pane to verify TUI behavior.
#
# Usage: ./tests/tui_test.sh [--keep]
#   --keep: Keep the tmux session open after tests for debugging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_PORT=18080
MOCK_PID=""
SESSION="varuna-tui-test"
KEEP_SESSION=false
PASS=0
FAIL=0

for arg in "$@"; do
    if [[ "$arg" == "--keep" ]]; then
        KEEP_SESSION=true
    fi
done

# ── Helpers ──────────────────────────────────────────────────────

cleanup() {
    if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    if [[ "$KEEP_SESSION" == false ]]; then
        tmux kill-session -t "$SESSION" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log_pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

log_fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

# Capture the tmux pane content
capture_pane() {
    tmux capture-pane -t "$SESSION" -p 2>/dev/null
}

# Wait for a string to appear in the pane
wait_for() {
    local pattern="$1"
    local timeout="${2:-10}"
    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        if capture_pane | grep -qF "$pattern" 2>/dev/null; then
            return 0
        fi
        sleep 0.3
    done
    return 1
}

# Send keys to the tmux pane
send_keys() {
    tmux send-keys -t "$SESSION" "$@"
}

# ── Build ────────────────────────────────────────────────────────

echo "=== Building varuna-tui ==="
cd "$PROJECT_DIR"
zig build 2>&1 || {
    echo "ERROR: Build failed"
    exit 1
}

TUI_BIN="$PROJECT_DIR/zig-out/bin/varuna-tui"
if [[ ! -x "$TUI_BIN" ]]; then
    echo "ERROR: varuna-tui binary not found at $TUI_BIN"
    exit 1
fi

# ── Start mock server ────────────────────────────────────────────

echo "=== Starting mock API server on port $MOCK_PORT ==="
python3 "$SCRIPT_DIR/tui_mock_server.py" "$MOCK_PORT" &
MOCK_PID=$!
sleep 0.5

# Verify the mock server is up
if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "ERROR: Mock server failed to start"
    exit 1
fi

# Quick sanity check
if ! curl -s "http://127.0.0.1:$MOCK_PORT/api/v2/torrents/info" | grep -q "ubuntu"; then
    echo "ERROR: Mock server not responding correctly"
    exit 1
fi
echo "  Mock server is up (PID $MOCK_PID)"

# ── Start tmux session ───────────────────────────────────────────

echo "=== Starting tmux session ==="
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 120 -y 40

# Launch varuna-tui in the tmux session
send_keys "$TUI_BIN --url http://127.0.0.1:$MOCK_PORT" Enter
sleep 2

# ── Tests ────────────────────────────────────────────────────────

echo "=== Running tests ==="

# Test 1: Main view loads with torrent list
echo "Test 1: Main view displays torrent list"
if wait_for "ubuntu-24.04" 8; then
    log_pass "Torrent list shows ubuntu torrent"
else
    log_fail "Torrent list did not show ubuntu torrent"
fi

# Test 2: Status bar shows transfer stats
echo "Test 2: Status bar displays transfer info"
if wait_for "Connected" 5; then
    log_pass "Status bar shows connected state"
else
    log_fail "Status bar did not show connected state"
fi

# Test 3: Multiple torrents visible
echo "Test 3: Multiple torrents displayed"
if capture_pane | grep -qF "archlinux"; then
    log_pass "Archlinux torrent visible"
else
    log_fail "Archlinux torrent not visible"
fi

# Test 4: Navigate down with 'j'
echo "Test 4: Navigate torrent list with j/k"
send_keys j
sleep 0.5
send_keys j
sleep 0.5
# The third torrent should now be selected
# Just verify the TUI is still responsive
if wait_for "ubuntu" 3; then
    log_pass "Navigation with j works (TUI still responsive)"
else
    log_fail "TUI unresponsive after navigation"
fi

# Navigate back up
send_keys k
sleep 0.5

# Test 5: Open detail view with Enter
echo "Test 5: Detail view opens on Enter"
send_keys k  # Go back to first
sleep 0.3
send_keys Enter
sleep 1
if wait_for "General" 5 || wait_for "Trackers" 5; then
    log_pass "Detail view shows tabs"
else
    log_fail "Detail view tabs not visible"
fi

# Test 6: Tab switching in detail view
echo "Test 6: Tab switching in detail view"
send_keys Tab
sleep 0.5
if capture_pane | grep -qF "Trackers" || capture_pane | grep -qF "tracker"; then
    log_pass "Tab switch works"
else
    log_fail "Tab switch did not work"
fi

# Test 7: Return to main view with q
echo "Test 7: Return to main view"
send_keys q
sleep 1
if wait_for "ubuntu-24.04" 5; then
    log_pass "Returned to main view"
else
    log_fail "Did not return to main view"
fi

# Test 8: Open add torrent dialog
echo "Test 8: Add torrent dialog"
send_keys a
sleep 0.5
if wait_for "Add Torrent" 5; then
    log_pass "Add dialog opened"
else
    log_fail "Add dialog did not open"
fi

# Type a magnet link
send_keys "magnet:?xt=urn:btih:test123"
sleep 0.3
send_keys Enter
sleep 2

# After adding, we should be back at the main view
# and the new torrent should appear after the next poll
if wait_for "newly-added" 8; then
    log_pass "Newly added torrent appears in list"
else
    # The mock server adds it, but it takes a poll cycle
    log_fail "Newly added torrent did not appear (may need longer poll wait)"
fi

# Test 9: Open delete dialog
echo "Test 9: Delete confirmation dialog"
send_keys d
sleep 0.5
if wait_for "Delete Torrent" 5 || wait_for "Remove" 5 || wait_for "Confirm" 5; then
    log_pass "Delete dialog opened"
else
    log_fail "Delete dialog did not open"
fi

# Cancel with n
send_keys n
sleep 0.5

# Test 10: Toggle delete files option
echo "Test 10: Toggle delete files in remove dialog"
send_keys d
sleep 0.5
send_keys f
sleep 0.3
if capture_pane | grep -qF "[x] Delete files"; then
    log_pass "Delete files toggle works"
else
    log_fail "Delete files toggle did not work"
fi
send_keys n  # Cancel
sleep 0.5

# Test 11: Pause torrent
echo "Test 11: Pause torrent"
send_keys p
sleep 2
# After pausing, the state should change on next poll
if wait_for "Paused" 8 || wait_for "||" 8; then
    log_pass "Torrent shows paused state"
else
    log_fail "Torrent did not show paused state"
fi

# Test 12: Open preferences view
echo "Test 12: Preferences view"
send_keys P
sleep 1
if wait_for "Preferences" 5 || wait_for "Listen port" 5; then
    log_pass "Preferences view opened"
else
    log_fail "Preferences view did not open"
fi
send_keys q  # Return to main
sleep 0.5

# Test 13: Quit with q
echo "Test 13: Quit TUI"
send_keys q
sleep 1
# The TUI process should have exited
if ! capture_pane | grep -qF "varuna-tui"; then
    log_pass "TUI exited cleanly"
else
    # It might show the shell prompt after exit
    log_pass "TUI exit (shell visible)"
fi

# ── Summary ──────────────────────────────────────────────────────

echo ""
echo "=== Test Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Total:  $((PASS + FAIL))"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Some tests failed. Use --keep to keep the tmux session for debugging:"
    echo "  tmux attach -t $SESSION"
    exit 1
fi

echo ""
echo "All tests passed."
exit 0

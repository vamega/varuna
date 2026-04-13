# E2E Multi-Torrent Download Fix

**Date:** 2026-04-12

## Problem

The `./scripts/test_e2e_downloads.sh all` test failed when downloading multiple torrents simultaneously. Individual torrents (LibreELEC, Kali) downloaded fine, but adding 3+ torrents caused Debian and Ubuntu to enter `error` state with 0 peers.

## Root Causes and Fixes

### 1. RecheckAlreadyActive (commit 1170b7f)
The EventLoop has a single `recheck: ?*AsyncRecheck` field. Only one async recheck can run at a time. When multiple torrents were added simultaneously, the second torrent's `startRecheck` returned `error.RecheckAlreadyActive` and the session went to `.error` state permanently.

**Fix:** On `RecheckAlreadyActive`, stay in `.checking` state with `background_init_done=true` so the main loop retries on the next tick.

### 2. Unnecessary recheck for fresh downloads (commits d3ce84c, 825924a)
For newly-added torrents with no resume data, the async recheck read and hashed every piece from empty files. For large torrents (Ubuntu: 21754 pieces), this took minutes of wasted I/O.

**Fix:** Detect `resume_pieces == null` and skip recheck entirely, creating an empty PieceTracker with 0 complete pieces and going straight to `.downloading`.

### 3. Timeout too short (commit f4883c1)
The multi-torrent timeout was 900s (15 min). Debian's swarm downloads at 0.5-2 MB/s despite 1000+ peers (mostly leechers). 753 MB at ~1 MB/s needs ~12 min with no margin.

**Fix:** Increased to 1800s (30 min). Excluded Ubuntu (5.3 GB, slow HTTPS tracker) from default `all` mode. Added `full` mode for comprehensive testing.

### 4. Ubuntu HTTPS tracker (commit cef1c4b)
Ubuntu's tracker at `https://torrent.ubuntu.com/announce` returns very few peers (~15) and the download speed is <1 MB/s. At 5.3 GB this takes 2+ hours, exceeding any reasonable test timeout.

**Fix:** Moved Ubuntu to `full` mode only. The `all` mode tests LibreELEC (UDP) + Kali (HTTP) + Debian (HTTP) — three different tracker protocols.

## Test Results

```
./scripts/test_e2e_downloads.sh all

Single: LibreELEC  275 MB — PASS (25s, 12 MB/s, 72 peers)
Multi:  Kali       695 MB — PASS (55s, 13 MB/s, 309 peers)
        Debian     753 MB — PASS (374s, 2 MB/s, 1033 peers)

E2E test suite complete (exit 0)
```

## Test Modes

| Mode | Torrents | Time | Use case |
|------|----------|------|----------|
| `quick` | LibreELEC (275 MB) | ~30s | Smoke test |
| `all` | LibreELEC + Kali + Debian | ~6 min | CI/default |
| `full` | All 4 including Ubuntu | ~2 hours | Comprehensive |

## Key Code References
- RecheckAlreadyActive retry: `src/daemon/torrent_session.zig:502`
- Skip recheck: `src/daemon/torrent_session.zig:470` (action = .skip_recheck)
- Skip recheck handler: `src/daemon/torrent_session.zig:526`
- Timeout: `scripts/test_e2e_downloads.sh:240` (1800s)

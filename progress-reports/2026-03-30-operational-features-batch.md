# Operational Features Batch

Date: 2026-03-30

## What was done

Five operational features implemented in a single batch:

### 1. systemd socket activation
- Added `listenFds()` and `isListenSocketOnPort()` to `src/daemon/systemd.zig`
- Implements the sd_listen_fds(3) protocol: checks `$LISTEN_FDS` and `$LISTEN_PID`, verifies PID match, sets FD_CLOEXEC on inherited fds
- Added `initWithFd()` to `src/rpc/server.zig` for using a pre-existing listen socket
- Updated `src/main.zig` to check for socket activation before creating sockets. Supports up to 2 inherited fds (API + peer listener)
- Static fd buffer (max 16) avoids allocation

### 2. Torrent data relocation
- Added `setLocation()` to `src/daemon/session_manager.zig`
- Pauses torrent, moves files (rename for same-fs, read/write copy for cross-fs), updates save_path, resumes
- Added `/api/v2/torrents/setLocation` POST endpoint (qBittorrent-compatible: `hashes=X&location=/new/path`)
- Added `varuna-ctl move <hash> <path>` command

### 3. Rate limit persistence
- Added `rate_limits` table to SQLite schema in `src/storage/resume.zig`
- Added `saveRateLimits()`, `loadRateLimits()`, `clearRateLimits()` methods
- `setTorrentDlLimit()` and `setTorrentUlLimit()` in SessionManager now persist to DB
- `doStart()` in TorrentSession loads persisted rate limits from DB on startup
- Added test: "resume db save and load rate limits"

### 4. Per-torrent connection diagnostics
- Added `conn_attempts`, `conn_failures`, `conn_timeout_failures`, `conn_refused_failures` counters to TorrentSession
- Counters increment during peer addition in both daemon and standalone modes
- Added `ConnDiagnostics` struct and `getConnDiagnostics()` to SessionManager
- Added `halfOpenCount()` to EventLoop
- Added `/api/v2/torrents/connDiagnostics?hash=X` GET endpoint
- Added `varuna-ctl conn-diag <hash>` command

### 5. Partial download cleanup
- Updated `handleTorrentsDelete` to parse `deleteFiles=true` parameter
- Added `removeTorrentEx()` to SessionManager: when delete_files=true, removes torrent data files and cleans up empty directories bottom-up
- Also cleans up resume DB entries (pieces, rate limits, tags, category) on delete
- Added `--delete-files` flag to `varuna-ctl delete`

## Key code references
- `src/daemon/systemd.zig:59-102` -- socket activation (listenFds, isListenSocketOnPort)
- `src/main.zig:103-125` -- socket activation integration
- `src/daemon/session_manager.zig:131-190` -- setLocation with moveDataFiles
- `src/storage/resume.zig` -- rate_limits table, saveRateLimits/loadRateLimits/clearRateLimits
- `src/daemon/session_manager.zig:335-365` -- setTorrentDlLimit/UlLimit with persistence
- `src/daemon/torrent_session.zig:137-140` -- connection diagnostic counters
- `src/daemon/session_manager.zig:218-261` -- removeTorrentEx with file cleanup

## What was learned
- Zig 0.15's `std.posix.fcntl` requires 3 arguments (fd, cmd, arg) even for GETFD which doesn't use the third -- pass 0
- `std.posix.sendfile` doesn't exist in Zig 0.15; used read/write loop for cross-filesystem file copy
- systemd socket activation is simpler than it looks: just check env vars and use fd 3+. The key detail is setting FD_CLOEXEC since systemd clears it before exec

## Remaining work
- Connection diagnostics currently only track addPeer failures. For deeper diagnostics (connect timeouts, resets), the event loop's connect completion handler would need to callback into the TorrentSession
- Data relocation could benefit from progress reporting for large cross-filesystem moves

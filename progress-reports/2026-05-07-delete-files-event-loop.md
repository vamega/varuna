# Delete Files Event-Loop Cleanup

## What Changed

- Added `DeleteJob`, a manifest-scoped event-loop state machine for `deleteFiles=true` torrent removal. It deletes listed data files with `unlinkat` and then prunes empty torrent directories with `openat` / `getdents` / `close` / `unlinkat(AT_REMOVEDIR)`.
- Rewired `SessionManager.removeTorrentEx(..., delete_files=true)` to enqueue a `DeleteJob` instead of running `std.fs.deleteFileAbsolute`, `openDirAbsolute`, or recursive directory deletion on the caller thread.
- Ticked delete jobs from the daemon main loop alongside MoveJob so deletion progress is owned by the shared IO backend.
- Added a focused `zig build test-delete-job` target and SimIO tests covering manifest-only deletion, empty-directory pruning, and sibling preservation.

## What Was Learned

- The storage manifest already has the right qBittorrent-safe relative paths for both single-file and multi-file torrents, so delete cleanup can avoid rebuilding paths from metainfo components.
- Directory pruning needs a real recursive state machine because `getdents` only reports one directory at a time and a parent can only be removed after child directories have been attempted.

## Remaining Issues

- DeleteJob currently preserves the legacy best-effort behavior for missing files and non-empty directories by logging non-fatal cleanup errors. There is no public delete-job progress API because qBittorrent's delete endpoint is fire-and-forget.
- Peer `getpeername` and per-peer socket-option setup remain separate IO-contract cleanup candidates.

## References

- `src/storage/delete_job.zig:119`
- `src/storage/delete_job.zig:240`
- `src/storage/delete_job.zig:585`
- `src/daemon/session_manager.zig:423`
- `src/daemon/session_manager.zig:488`
- `src/daemon/session_manager.zig:1247`
- `src/main.zig:439`
- `build.zig:278`

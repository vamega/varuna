# Fix critical bugs C1 and C2 -- 2026-03-30

## What was done

Fixed the two critical bugs identified in the code quality review.

### C1: Session pointer use-after-free in RPC handlers

**Root cause:** `handleTorrentsFiles`, `handleTorrentsTrackers`, and
`handleTorrentsProperties` in `src/rpc/handlers.zig` called
`SessionManager.getSession()`, which briefly locked the mutex, returned a raw
`*TorrentSession` pointer, then released the lock. The handlers then read
session fields (metainfo, file_priorities, piece_tracker bitfield, etc.)
without mutex protection. A concurrent `removeTorrent` call could free the
session while the handler was still reading from it.

**Fix:** Added three new thread-safe accessor methods to `SessionManager`
(`src/daemon/session_manager.zig`) that copy all needed data while holding
the mutex:

- `getSessionFiles()` -- returns owned `[]FileInfo` with file names, sizes,
  progress, and priorities
- `getSessionTrackers()` -- returns owned `[]TrackerInfo` with URLs, status,
  tier, and scrape stats
- `getSessionProperties()` -- returns owned `PropertiesInfo` with stats,
  comment, and piece size

Each method has a corresponding `free*` function for cleanup. The handlers now
use these methods instead of `getSession()`, so no raw `*TorrentSession`
pointer escapes the mutex.

This also fixes the related H3 issue (PieceTracker bitfield read without
synchronization) since the bitfield is now read inside the mutex in
`getSessionFiles()`.

### C2: Hasher silently drops results on OOM

**Root cause:** In `src/io/hasher.zig:207`, `completed_results.append() catch {}`
silently swallowed OOM errors, leaking the piece buffer and leaving the piece
stuck in-progress forever.

**Fix:** On append failure, the handler now:
1. Frees the piece buffer (`job.piece_buf`) to prevent the memory leak
2. Logs the error via `std.log.err`
3. Decrements `in_flight` and continues to the next job

The piece will appear stuck in-progress until the peer timeout mechanism
reclaims it, but at least memory is not leaked.

## Key files changed

- `src/daemon/session_manager.zig` -- added `FileInfo`, `TrackerInfo`,
  `PropertiesInfo` types and `getSessionFiles`, `getSessionTrackers`,
  `getSessionProperties` methods
- `src/rpc/handlers.zig` -- rewrote `handleTorrentsFiles`,
  `handleTorrentsTrackers`, `handleTorrentsProperties` to use new methods
- `src/io/hasher.zig` -- added OOM handling in `workerFn`

## Testing

`zig build` and `zig build test` both pass.

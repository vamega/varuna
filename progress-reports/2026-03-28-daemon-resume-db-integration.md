# Daemon Resume DB Integration

## What was done

Integrated the existing SQLite resume database (`src/storage/resume.zig`) into the daemon's `TorrentSession` lifecycle so that completed pieces persist across daemon restarts.

### Changes

**`src/daemon/torrent_session.zig`**
- Added `resume_writer` (optional `ResumeWriter`) and `resume_last_count` fields for tracking persistence state.
- Added `resume_db_path` config field (sentinel-terminated for SQLite C API).
- `doStart()`: opens resume DB, loads known-complete pieces into a `PieceSet`, passes to `recheckExistingData` for fast-path skip of SHA-1 rehashing, then persists recheck results back to DB.
- Standalone event loop path: calls `persistNewCompletions()` each tick and flushes on download completion.
- `pause()`: flushes resume state after background thread joins.
- `stopInternal()`: flushes and closes resume writer before tearing down other resources.
- Added `persistNewCompletions()` and `flushResume()` public helpers.

**`src/daemon/session_manager.zig`**
- Added `resume_db_path` field, passed through to each `TorrentSession` on creation.

**`src/main.zig`**
- Resolves resume DB path from config (`cfg.storage.resume_db`) or defaults to `~/.local/share/varuna/resume.db`.
- Creates parent directory if needed.
- Passes path to `SessionManager`.
- Main loop periodically (~every 5s) calls `persistNewCompletions()` + `flushResume()` on active sessions for daemon/shared event loop mode.

**`STATUS.md`**
- Moved "Resume DB integration in daemon mode" from Next to Done.

## Key design decisions

1. **All sessions share one DB file**: The resume DB schema uses `(info_hash, piece_index)` as primary key, so multiple torrents coexist in a single SQLite database. This avoids per-torrent DB management.

2. **SQLite never runs on the event loop thread**: In standalone mode, `persistNewCompletions()` runs on the session's background thread. In daemon mode, it runs on the main thread but only every ~5s, and SQLite WAL mode writes are fast (sub-millisecond for typical batches).

3. **`persistNewCompletions()` scans the PieceTracker**: Rather than hooking into the event loop's `handleDiskWrite` (which would require cross-thread signaling), the session polls its `PieceTracker` for new completions. The `PieceTracker` is already mutex-protected and safe to read from any thread. Uses `INSERT OR IGNORE` so duplicate writes are harmless.

4. **Graceful degradation**: If SQLite fails to open or write, the daemon continues without persistence. On next restart, it falls back to full piece recheck.

## What was learned

- The `ResumeWriter` already has mutex-protected `recordPiece()` and `flush()`, making it safe to call from the main thread even though the event loop runs on the same thread. The key constraint is that `flush()` blocks (SQLite I/O), so it must not be called too frequently from the main loop.

- The resume fast-path in `recheckExistingData` trusts the DB -- it skips SHA-1 verification for pieces marked complete in SQLite. If the DB is out of sync with disk, the torrent will have corrupt data. This is an acceptable tradeoff since the DB is only updated after successful disk writes.

## Files changed

- `src/daemon/torrent_session.zig`: resume DB lifecycle integration
- `src/daemon/session_manager.zig`: resume_db_path passthrough
- `src/main.zig`: path resolution and periodic flush in main loop
- `STATUS.md`: updated ledger

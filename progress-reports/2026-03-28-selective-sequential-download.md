# Selective File Download & Sequential Download Mode

**Date:** 2026-03-28

## What was done

Implemented two new features for the varuna BitTorrent daemon:

### 1. Selective file download (file priorities)

Each file in a multi-file torrent can now be assigned a priority:
- `normal` (default) -- download as usual
- `high` -- download as usual (ready for future priority ordering)
- `do_not_download` -- skip this file

The system computes a "wanted piece mask" from file priorities. A piece is wanted if ANY file overlapping it has a priority other than `do_not_download`. This correctly handles boundary pieces that span both a wanted and a skipped file -- they are still downloaded because they contain data for the wanted file.

### 2. Sequential download mode

When `sequential_download = true`, the PieceTracker returns pieces in ascending index order instead of rarest-first. This enables streaming video playback while a torrent is still downloading.

### 3. Lazy file allocation for skipped files

PieceStore now accepts optional file priorities during initialization. Files marked `do_not_download` are not created or pre-allocated. If a file's priority is later changed to wanted, `ensureFileOpen()` creates it on demand.

## Key changes

- **`src/torrent/file_priority.zig`** (new): `FilePriority` enum, `buildPieceMask()` to map file priorities to a piece bitfield, `allWanted()` helper.
- **`src/torrent/piece_tracker.zig`**: Added `wanted` bitfield, `wanted_count`, `sequential` bool. `claimPiece()` dispatches to `claimRarestFirstLocked()` or `claimSequentialLocked()`. `isComplete()` now checks wanted pieces only. New `wantedCompletedCount()` and `wantedRemaining()` helpers.
- **`src/storage/writer.zig`**: `PieceStore.files` changed from `[]std.fs.File` to `[]?std.fs.File`. Added `initWithPriorities()` and `ensureFileOpen()`. Skipped files get fd -1 in `fileHandles()`.
- **`src/daemon/torrent_session.zig`**: Added `file_priorities`, `sequential_download` fields. `doStart()` applies them to PieceTracker and PieceStore. Runtime mutation via `setFilePriorities()` and `setSequentialDownload()`. Seeding transition uses `pt.isComplete()` instead of raw piece count comparison.
- **`src/torrent/root.zig`**: Exports new `file_priority` module.

## Design decisions

- **Boundary piece rule**: A piece is wanted if ANY overlapping file is wanted. This ensures data integrity for wanted files even when adjacent files are skipped. This matches libtorrent/qBittorrent behavior.
- **Wanted bitfield ownership**: The PieceTracker owns the wanted Bitfield (caller transfers ownership via `setWanted`). This avoids lifetime issues with external references.
- **Null file handles**: Using `[]?std.fs.File` instead of sentinel values keeps the type system honest. `ensureFileOpen()` provides lazy creation.
- **isComplete semantics**: With a wanted mask, completion means "all wanted pieces done", not "all pieces done". This allows the daemon to transition to seeding when selective download finishes.

## Tests added

- `file_priority.zig`: 5 tests covering full mask, boundary pieces (both directions), `allWanted` helper.
- `piece_tracker.zig`: 5 new tests for wanted mask, sequential mode, sequential+wanted, sequential endgame, isComplete with wanted mask.
- `writer.zig`: 2 new tests for skipped file allocation and lazy file creation.

## Remaining work

- API endpoints for setting file priorities and sequential mode (qBittorrent `/api/v2/torrents/filePrio`, `/api/v2/torrents/toggleSequentialDownload`).
- Persisting file priorities in the SQLite resume DB.
- The `high` priority does not yet affect piece ordering within rarest-first (pieces from high-priority files could be preferred when availability is equal).

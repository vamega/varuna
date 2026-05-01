# Resume Durability Barrier

## What Changed

- Deferred live resume DB piece-completion persistence until the relevant piece write has crossed the existing per-torrent fsync/fdatasync sweep.
- Added per-torrent queues for completions waiting on durability and completions ready for resume persistence.
- Changed `TorrentSession.persistNewCompletions` so live event-loop torrents drain only durability-ready pieces instead of scanning every in-memory complete bit.
- Added a deterministic `EventLoopOf(SimIO)` regression proving pieces completed after a sync sweep starts are not exposed to resume persistence until the next successful sweep.

## What Was Learned

Write CQEs only prove the data reached the kernel I/O path. Before this change, the periodic resume flush could observe `PieceTracker.complete` and queue SQLite rows while `dirty_writes_since_sync` still represented data not covered by any fsync barrier. The existing sync sweep already had the right generation boundary; it needed a resume-persistence handoff tied to that boundary.

## Remaining Issues

- This fix is intentionally conservative for resume rows: if the durability-ready queue cannot be allocated, the dirty generation remains dirty and retries on a later sync sweep.
- Existing broader test-suite failures called out in the baseline were not reproduced by the requested `zig build` command in this worktree; the requested build command passed after this change.

## References

- `src/io/types.zig:245` - per-torrent pending and durable resume queues.
- `src/io/event_loop.zig:2077` - sync sweep snapshots both dirty writes and pending resume completions.
- `src/io/event_loop.zig:2131` - successful fsync drain moves only snapshotted completions into the durable resume queue.
- `src/io/event_loop.zig:2174` - event-loop APIs for marking and draining resume durability state.
- `src/io/peer_handler.zig:1014` - disk write completion now records a piece as awaiting durability instead of DB-ready.
- `src/daemon/torrent_session.zig:2408` - live session resume persistence drains only durability-ready pieces.
- `tests/torrent_sync_test.zig:196` - regression for resume rows waiting on the durability barrier.

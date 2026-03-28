# Daemon Shared Event Loop — End-to-End

**Date:** 2026-03-28

## What Was Done

### 1. Fixed Shared Event Loop Crash
The daemon crashed (abort/segfault) after `varuna-ctl add` because `event_loop.zig` had ~15 accesses to legacy `self.session.?` and `self.piece_tracker.?` fields that are null in daemon mode (`initBare()`). The `.?` unwrap panics on null.

**Fix:** Replaced all legacy field accesses with `getTorrentContext(peer.torrent_id)` lookups. Each function now resolves the correct `TorrentContext` for the peer it's handling. Functions fixed: `removePeer`, `handleDiskWrite`, `processMessage` (have/bitfield), `servePieceRequest`, `tryAssignPieces`, `startPieceDownload`, `tryFillPipeline`, `completePieceDownload`, `processHashResults`, `checkReannounce`.

### 2. Fixed Save-Path Passthrough
The API handler hardcoded `session_manager.default_save_path` and ignored whatever the client sent.

**Fix:** `varuna-ctl` now sends `--save-path` as a `?savepath=` query parameter. The handler extracts it with `extractParam()`.

### 3. Fixed State Transition
In daemon mode, `TorrentSession.state` stayed `.downloading` even at 100% progress because nothing triggered the transition. In standalone mode, the download loop checks `piece_tracker.isComplete()`, but the daemon's shared event loop completes pieces independently.

**Fix:** `getStats()` now auto-transitions to `.seeding` when `pieces_have == piece_count`.

### 4. Fixed Peer Count Reporting
`getStats()` checked `self.event_loop.peer_count` which is null in daemon mode (the per-session event loop isn't used).

**Fix:** Falls back to `self.shared_event_loop.peer_count`.

### 5. Batched Block Sends (Option C)
Previously each block request triggered a separate io_uring send. Now cache-hit responses are queued during CQE dispatch and flushed per-peer into a single combined send buffer.

For a 64KB piece with 4 blocks: 4 sends → 1 send.

## Key Lessons

- **Optional unwrap (`.?`) is a landmine in multi-mode code.** When a struct serves both "bare" and "full" configurations, every `.?` is a potential crash. The `getTorrentContext()` pattern with `orelse return` is much safer.

- **State machines need explicit transition points.** The standalone download loop managed state transitions as part of its control flow. In daemon mode, the event loop just completes pieces — nobody was watching for "all done." Adding the check in `getStats()` is simple but correct for now.

- **Batching IO at the application layer matters.** Even though io_uring batches syscalls, reducing the number of SQEs/CQEs still helps by reducing per-operation overhead (buffer allocation, tracking structures, ring slot pressure).

## Verified

- `zig build test` — all tests pass
- `scripts/demo_swarm.sh` — standalone swarm passes
- Daemon swarm: tracker + seeder + daemon download → file verified with `cmp`
- 500KB with 64KB pieces (8 pieces × 4 blocks) — verified with batched sends

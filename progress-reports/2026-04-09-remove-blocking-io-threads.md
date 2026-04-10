# Remove Blocking I/O Background Threads

**Date:** 2026-04-09
**Build:** `zig build` passes, `zig build test` passes, `zig build test-torrent-session` passes.

## What changed

Moved daemon networking and file I/O off background threads onto the io_uring event loop. Background threads now only handle SQLite and CPU-bound hashing.

### 6 commits, in order:

1. **`6f93a6a` daemon: check queue eligibility before starting torrent, not after**
   - Fixed start-then-cancel race in `resumeTorrent()` — `shouldBeActive()` now checked before `unpause()`, not after

2. **`b63b95a` io: add timerfd support for one-shot timer callbacks**
   - Added `OpType.timerfd` to event loop, `scheduleTimer(delay_ms, ctx, callback)` method
   - Uses `timerfd_create`/`timerfd_settime` with `CLOCK_MONOTONIC`, io_uring read for CQE notification
   - Replaces `Thread.sleep` for jittered announce delays

3. **`d091b26` io: add async piece recheck state machine for event loop**
   - New `src/io/recheck.zig` — `AsyncRecheck` pipelines up to 4 pieces concurrently via io_uring reads
   - Integrates with existing hasher thread pool for SHA verification
   - Added `is_recheck` flag to `Hasher.Job`/`Result` to distinguish recheck from download hashing
   - Resume fast-path: skips io_uring reads for pieces known-complete from SQLite

4. **`056d4b0` daemon: split doStart into background init + event-loop recheck phases**
   - `doStart()` → `doStartBackground()`: only Session.load, PieceStore.init, SQLite reads
   - Background thread exits in milliseconds (no disk reads, no network, no sleep)
   - `integrateIntoEventLoop()` starts `AsyncRecheck` via the ring
   - `onRecheckComplete` callback creates PieceTracker, transitions to seeding/downloading
   - Announce scheduling uses timerfd jitter instead of `Thread.sleep`
   - Initial announce goes through `scheduleAnnounceJobs()` → TrackerExecutor (ring-based)

5. **`22fa73b` io: add async BEP 9 metadata fetch state machine for event loop**
   - New `src/io/metadata_handler.zig` — `AsyncMetadataFetch` with 3 concurrent peer slots
   - Per-slot state machine: connect → handshake → ext_handshake → piece_request → piece_recv
   - All I/O via io_uring SQEs (connect, send, recv)
   - Handles partial TCP reads, BT message framing, keep-alive filtering
   - Magnet flow: background thread collects peers from tracker, event loop does metadata fetch
   - On completion: Session.load + PieceStore.init + async recheck chain

6. **`41a4845` tracker: remove blocking HTTP/UDP tracker functions, keep ring-based executors**
   - Deleted `src/tracker/multi_announce.zig` (thread-pool parallel announce)
   - Removed 7 blocking scrape functions from scrape.zig
   - Removed `scrapeViaUdp` from udp.zig
   - Removed `fetchMetadata` legacy path from torrent_session.zig
   - Preserved: `fetchAuto`/`fetchViaHttp`/`fetchViaUdp` (still used by magnet peer collection on background thread), all packet codecs, parsing, types

## What remains blocking

- **`collectMagnetPeers()`** in torrent_session.zig still calls `announce.fetchAuto` from the background thread for initial magnet peer discovery. This could be moved to use the TrackerExecutor, but requires the event loop to be active first.
- **SQLite** operations stay on background thread (by design)
- **Hasher thread pool** stays (CPU-bound, by design)
- **DNS thread pool** stays when c-ares unavailable (by design)

## New files

- `src/io/recheck.zig` — async piece verification state machine
- `src/io/metadata_handler.zig` — async BEP 9 metadata fetch state machine

## Key code references

- Timerfd: `src/io/event_loop.zig` — `scheduleTimer`, `armNextTimer`, `fireExpiredTimers`
- Async recheck: `src/io/recheck.zig` — `AsyncRecheck.start`, `handleReadCqe`, `handleHashResult`
- Metadata fetch: `src/io/metadata_handler.zig` — `AsyncMetadataFetch.handleCqe`
- Startup split: `src/daemon/torrent_session.zig` — `doStartBackground`, `onRecheckComplete`, `onMetadataFetchComplete`

# 2026-04-06: Single io_uring Ring Consolidation

## What Was Done

Consolidated the daemon from 3 separate io_uring rings down to 1 shared ring
on the main event loop thread. This eliminates cross-thread signaling, extra
kernel memory, and multiple `io_uring_enter` syscalls per tick.

## Before

| Ring | Thread | Size | Purpose |
|------|--------|------|---------|
| Main event loop | main | 256 | Peers, disk, uTP, DHT |
| API server | main (polled) | 64 | HTTP API accept/recv/send |
| Tracker executor | background | 32 | Tracker HTTP connect/send/recv |
| Announce thread | background | (blocking POSIX) | Re-announce |

## After

| Ring | Thread | Size | Purpose |
|------|--------|------|---------|
| Main event loop | main | 256 | Everything: peers, disk, uTP, DHT, API, tracker HTTP |

## Step 1: API Server → Shared Ring

- `ApiServer.ring` changed from owned `IoUring` to `*IoUring` (pointer to shared)
- Added `api_accept`, `api_recv`, `api_send` OpType variants (13-15)
- Event loop dispatch routes to `ApiServer.handleAcceptCqe/handleRecvCqe/handleSendCqe`
- User data encoding uses event loop's scheme (slot=client, context=generation)
- Removed `ApiServer.poll()` from main loop — CQEs come through shared dispatch
- `run()`/`poll()` retained for standalone test/benchmark use

## Step 2: Tracker Executor → Shared Ring

- Removed dedicated thread (`ringMain`, `std.Thread.spawn`)
- `TrackerExecutor.ring` changed from owned to `*IoUring`
- Added `TrackerExecutor.tick()` called from event loop tick
- `dispatchCqe()` handles `http_connect/http_send/http_recv` + DNS eventfd
- Job queue drained synchronously in `tick()` (no wake_fd needed)
- DNS completion via eventfd polled on the shared ring

## Step 3: Announce Thread Removed

- Deleted `announceWorkerThread` and `generateAnnounceJitter`
- Removed `announce_thread`, `announce_url`, `announce_jitter_secs` fields
- Kept `announce_result_peers` + `announce_mutex` for daemon re-announce results
- `checkReannounce` simplified to just pick up daemon results

## Bugs Fixed Along the Way

- Tracker executor ring size was 24 (not power of 2) → fixed to 32
- This was a pre-existing bug from the dns-fixes merge that caused torrent
  add to fail with `EntriesNotPowerOfTwo`

## Verification

- `zig build` + `zig build test`: all pass
- Debian ISO download: 14.88 MB/s with 38 peers
- API server responds correctly on shared ring

## Code References

- API server shared ring: `src/rpc/server.zig:17-42`
- Tracker executor shared ring: `src/daemon/tracker_executor.zig:213-247`
- OpType enum: `src/io/event_loop.zig:38-55`
- Dispatch routing: `src/io/event_loop.zig:1807-1826`
- Tracker tick: `src/io/event_loop.zig:1575`

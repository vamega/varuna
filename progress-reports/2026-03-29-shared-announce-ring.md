# Shared announce ring: stop creating io_uring per announce

## What was done

Tracker announce operations previously created a new `io_uring` ring (16 entries) for every announce -- on download completion, force-reannounce, and periodic re-announce. This was wasteful since `io_uring` ring setup involves the `io_uring_setup` syscall, memory mapping, and teardown each time.

Three call sites were changed:

1. **`src/io/event_loop.zig` -- `checkReannounce`**: Was creating a temporary `Ring.init(16)` and doing blocking HTTP *on the event loop thread*, stalling all peer I/O during the announce. Now spawns a detached background thread that uses a shared `announce_ring` field on the `EventLoop`. Results (peer addresses) are passed back via an atomic handoff (`announce_result_peers` + `announce_results_ready`) and picked up on the next tick.

2. **`src/daemon/torrent_session.zig` -- `announceCompletedWorker`**: Was creating a new `Ring.init(16)` per call. Now lazily creates `self.announce_ring` once and reuses it across announces.

3. **`src/daemon/session_manager.zig` -- `forceReannounce`**: Was spawning a joinable thread (tracked in `announce_thread`). Now uses an `announcing` atomic flag and detached threads -- no join handle to track.

## Key design decisions

- **Background thread is correct**: the former synchronous HTTP path used blocking ring operations (`submit_and_wait(1)`) and DNS resolution spawned its own thread. These cannot run on the main event loop ring without blocking peer I/O. A dedicated announce ring on a background thread is the right approach.

- **Atomic flag instead of thread handle**: Replaced `announce_thread: ?std.Thread` with `announcing: std.atomic.Value(bool)`. This avoids needing to join threads (which requires tracking lifetime) and cleanly prevents double-announcing. The `deinit` and `stop` methods spin-wait for in-flight announces to complete before tearing down the ring.

- **Lazy ring creation**: The announce ring is created on first use rather than at startup, so sessions/event loops that never announce don't pay the cost.

## Files changed

- `src/io/event_loop.zig:242-256` -- new fields for shared announce ring and result handoff
- `src/io/event_loop.zig:481-512` -- deinit cleanup for announce ring
- `src/io/event_loop.zig:1276-1380` -- rewritten `checkReannounce` + new `announceWorkerThread`
- `src/daemon/torrent_session.zig:78-79` -- replaced `announce_thread` with `announce_ring` + `announcing`
- `src/daemon/torrent_session.zig:135-147` -- deinit waits for in-flight announce
- `src/daemon/torrent_session.zig:191-203` -- stop waits for in-flight announce
- `src/daemon/torrent_session.zig:616-648` -- `checkSeedTransition` uses atomic flag + detached thread
- `src/daemon/torrent_session.zig:655-677` -- `announceCompletedWorker` reuses shared ring
- `src/daemon/session_manager.zig:167-178` -- `forceReannounce` uses atomic flag + detached thread

## Remaining issues

- The standalone mode announce in `doStart` (torrent_session.zig:424) still uses `self.ring.?` (the startup ring). This is fine since it runs on the startup background thread, but could be unified with `announce_ring` in the future.
- `announceAsSeeder` (torrent_session.zig:651) also uses `self.ring.?` for the same reason -- acceptable.

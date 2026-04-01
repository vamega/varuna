# 2026-04-01: Shared Tracker Executor And HTTP Keep-Alive

## What changed

- Added a shared daemon-side tracker executor that owns one ring, one DNS resolver, and one persistent HTTP client instead of letting each `TorrentSession` lazily create detached tracker worker resources. See `src/daemon/tracker_executor.zig:6`.
- Routed seed-transition completion announces, forced reannounce, and periodic scrape jobs through that executor when a shared executor is attached. The old detached-thread path remains as a fallback. See `src/daemon/torrent_session.zig:1211`, `src/daemon/torrent_session.zig:1273`, and `src/daemon/session_manager.zig:630`.
- Extended the tracker HTTP client with optional plain-HTTP keep-alive reuse and a small connection cache so the shared executor can reuse tracker sockets across announces and scrapes. See `src/io/http.zig:11`, `src/io/http.zig:45`, and `src/io/http.zig:120`.
- Added real announce-path benchmarks so the production path can be compared directly: `tracker_announce_fresh` and `tracker_announce_executor`. See `src/perf/workloads.zig:893` and `src/perf/workloads.zig:941`.

## What was learned

- The raw tracker transport microbenchmark was directionally useful, but it was not a fair proxy for the production path because it skipped URL building and tracker bencode parsing. The new `tracker_announce_*` workloads are the numbers to use for production decisions.
- Reusing the tracker connection is enough to deliver a real win even after queueing and parsing overhead are included:
  - `tracker_announce_fresh --iterations=2000`: `849301098 ns`, `879521023 ns`
  - `tracker_announce_executor --iterations=2000`: `427559358 ns`, `449506041 ns`
- The shared executor still owns its own ring on purpose. The current HTTP tracker client is a synchronous wrapper over io_uring. Putting those calls directly on the shared peer `EventLoop` ring would stall peer processing unless tracker I/O is first rewritten as a CQE-driven async state machine.

## Remaining work

- The executor currently reuses plain HTTP connections. HTTPS and UDP tracker requests still use one-shot transports.
- The shared executor is a single queue and worker, not a tracker subsystem integrated into the shared peer `EventLoop` ring.
- If tracker work must move onto the shared peer ring, the next step is not another queue. It is a proper async tracker request state machine with explicit CQE routing.

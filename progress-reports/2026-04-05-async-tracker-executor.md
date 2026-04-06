# Async Multiplexed TrackerExecutor

**Date:** 2026-04-05

## What was done

Replaced the serial single-worker TrackerExecutor with an async event-loop-based
executor that multiplexes many concurrent HTTP(S) tracker requests on a single
io_uring ring. Also fixed the DNS "threadpool" which was actually spawning a
thread per request.

### Changes

1. **`src/io/dns_threadpool.zig`** — Real thread pool for DNS resolution
   - Replaced thread-per-request `resolveBlocking` with a proper 4-thread pool
     using a bounded job queue and refcounted `DnsJob` for safe timeout handling
   - Added `notify_fd` to `DnsJob`: worker writes to an eventfd on completion,
     enabling non-blocking DNS integration with event loops
   - Added `resolveAsync()` to `DnsResolver`: returns immediately with either a
     resolved address (numeric IP or cache hit) or a pending `DnsJob`
   - Added `cacheResult()` for callers to cache async DNS results
   - Made `DnsJob` public with `isDone()` for non-blocking completion checks

2. **`src/io/ring.zig`** — Async io_uring methods
   - Added non-blocking SQE-queuing methods: `connect_async`, `send_async`,
     `recv_async`, `socket_async`, `close_async`, `poll_add`, `timeout_async`,
     `cancel_async`, `link_timeout_async`, `accept_multishot`
   - Added batch operations: `flush`, `flush_and_wait`, `drain_cqes`, `drain_one`
   - Made `checkCqe` public for external CQE error handling
   - Existing sync methods preserved for other callers (removal is a follow-up)

3. **`src/daemon/tracker_executor.zig`** — Complete rewrite
   - Single background thread with own `Ring` (async methods only)
   - `RequestSlot` state machine: `free → dns_resolving → connecting →
     [tls_handshaking →] sending → receiving → complete`
   - Two eventfds polled via `POLL_ADD`: `wake_fd` (new jobs) and `dns_event_fd`
     (DNS completions)
   - Per-host (`max_per_host=3`) and global (`max_concurrent=8`) concurrency limits
   - Queue scanning for deferred jobs avoids head-of-line blocking
   - HTTP connection pooling (16 connections, 60s idle timeout)
   - HTTPS fully async via BoringSSL BIO pairs (non-blocking crypto)
   - Per-request deadlines (30s), checked every 2s via periodic timeout
   - New Job API: caller provides URL + completion callback, executor owns HTTP flow

4. **`src/daemon/torrent_session.zig`** — Updated to new API
   - Builds announce/scrape URLs before submission
   - Completion callbacks parse bencoded responses on the ring thread
   - UDP tracker URLs handled separately (not through executor)

5. **`src/tracker/scrape.zig`** — Made `buildScrapeUrl` and `parseScrapeResponse` public

6. **`src/daemon/session_manager.zig`**, **`src/perf/workloads.zig`** — API updates

## What was learned

### The Ring wrapper was the root cause

The `Ring` struct in `ring.zig` wraps `linux.IoUring` but makes every operation
synchronous: queue one SQE, call `submit()`, block on `copy_cqe()`. This forced
the TrackerExecutor into a thread-pool model because you can't have two operations
in flight at the same time.

Meanwhile, the peer event loop (`event_loop.zig`) uses `linux.IoUring` directly —
it queues SQEs with user_data tags, submits in batch, and dispatches CQEs to
handlers. It handles thousands of concurrent connections on one ring. The OpTypes
`http_connect`, `http_send`, `http_recv` were already defined but unused.

**The fix**: Add async methods to Ring (queue SQE without blocking) alongside the
existing sync ones. The TrackerExecutor uses only async methods. Sync callers are
unaffected. Removing sync methods from Ring is a follow-up (~20 files to migrate).

### DNS must not block the event loop

The DNS thread pool resolve call blocks up to 5 seconds on cache misses. For a
non-blocking event loop, DNS resolution is offloaded: `resolveAsync()` checks
the cache (non-blocking mutex, microseconds), and on a miss, submits to the
thread pool and returns a pending `DnsJob`. The thread pool signals an eventfd
on completion, which the ring detects via `POLL_ADD`. This pattern is the same
as the Hasher (`src/io/hasher.zig`) which offloads SHA computations.

### BoringSSL BIO pairs enable async TLS

The TLS implementation (`src/io/tls.zig`) already uses BIO pairs where BoringSSL
never touches sockets directly. `doHandshake()`, `feedRecv()`, `pendingSend()`,
`writePlaintext()`, and `readPlaintext()` are all non-blocking crypto/buffer
operations. Network I/O goes through io_uring send/recv SQEs. This makes HTTPS
fully async on the ring thread — no worker thread needed.

### Refcounted DnsJob handles timeout safely

When the caller times out waiting for DNS, the worker thread may still be using
the DnsJob. The `DnsJob` uses atomic refcounting (initial count 2: caller + worker).
Whoever decrements to zero frees the job. This prevents use-after-free on timeout
without requiring the caller to join the worker thread.

## Key code references

- Ring async methods: `src/io/ring.zig:420-490`
- DNS thread pool + async: `src/io/dns_threadpool.zig`
- TrackerExecutor event loop: `src/daemon/tracker_executor.zig:280-320`
- RequestSlot state machine: `src/daemon/tracker_executor.zig:95-130`
- TLS handshake advancement: `src/daemon/tracker_executor.zig:465-520`

## Remaining issues / follow-up

- **Remove sync Ring methods**: ~20 files still use sync Ring methods. These should
  be migrated to either async Ring or direct POSIX syscalls, then sync methods removed.
- **Event loop migration**: The peer event loop uses raw `linux.IoUring`. It could
  migrate to Ring's async methods for consistency.
- **UDP tracker in executor**: Currently UDP tracker announces go through a separate
  sync path. Could be integrated into the executor if needed.
- **announce response handling**: The `announceComplete` callback currently parses
  the response but doesn't yet feed peers/interval back to the session. This needs
  to be wired up to the peer discovery pipeline.

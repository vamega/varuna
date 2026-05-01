# io_uring Policy: Static Violation Analysis

Audit of `std.posix` system calls in the varuna daemon that violate the
io_uring-only I/O policy documented in `AGENTS.md`. Conducted 2026-04-14.

---

## Category 1: Easy Replacements

Straightforward swaps where io_uring already has the corresponding op and the
surrounding code is already async or can trivially become so.

### 1. `posix.socket()` calls — replace with `IORING_OP_SOCKET`

All of these create sockets synchronously before submitting them to the ring.
io_uring supports `IORING_OP_SOCKET` (kernel 5.19+).

| File | Line(s) | Context |
|---|---|---|
| `src/io/event_loop.zig` | 864, 964 | Peer outbound / UDP socket creation |
| `src/rpc/server.zig` | 45 | RPC listen socket |
| `src/net/socket.zig` | 52, 60 | Socket factory used by event loop |
| `src/io/metadata_handler.zig` | 183 | Metadata peer socket |
| `src/daemon/tracker_executor.zig` | 446 | HTTP tracker socket |

### 2. `posix.close()` on sockets — replace with `IORING_OP_CLOSE`

Scattered across nearly every file. Most are `errdefer posix.close(fd)` or
cleanup paths. io_uring supports `IORING_OP_CLOSE`. These are low-risk
one-for-one swaps, though errdefer semantics need a synchronous fallback or a
ring-submitted close with a completion barrier.

Major clusters:

- `src/daemon/tracker_executor.zig` — lines 159, 188, 204, 250, 454, 595, 834
- `src/io/event_loop.zig` — lines 382, 389, 393, 1965
- `src/io/http_executor.zig` — close paths now ride through the async HTTP executor
- `src/rpc/server.zig` — lines 74, 83, 164
- `src/io/metadata_handler.zig` — line 727

### 3. `posix.bind()` and `posix.listen()` — one-time setup

These happen once at startup. They are technically violations but have zero
performance impact. io_uring has no `bind`/`listen` ops, so these **must remain
posix calls** — they are acceptable under the policy as one-time initialization.

| File | Line(s) | Call |
|---|---|---|
| `src/io/event_loop.zig` | 991 | `posix.bind` |
| `src/rpc/server.zig` | 61, 62 | `posix.bind`, `posix.listen` |
| `src/net/socket.zig` | 28 | `posix.bind` |

### 4. `posix.fdatasync()` in `storage/writer.zig:127` — replace with `IORING_OP_FSYNC`

A single call in `PieceStore.sync()`. The ring already supports fsync ops.
Straightforward replacement, just need to submit and await completion.

---

## Category 2: Moderate Effort

These require restructuring a function or call chain, but the io_uring ops exist
and patterns are established in the codebase.

### 5. `storage/writer.zig` — `pwriteAll` (line 179) and `preadAll` (line 190)

The `PieceIO.writePiece` and `PieceIO.readPiece` methods use blocking
`posix.pwrite`/`posix.pread` loops. io_uring has `IORING_OP_READ`/`IORING_OP_WRITE`
with offset support. The codebase already does ring-based piece reads in
`seed_handler.zig` and `recheck.zig` — this is the older code path that needs to
match. The loop-on-short-read/write logic needs to become a chain of SQEs or a
single fixed-buffer submission.

### 6. `io/hasher.zig:414` — `posix.pread` in hash worker threads

The hasher thread pool currently reads piece data from disk via blocking pread
and then hashes it. The file reads must move to the main io_uring ring:

1. The event loop submits `IORING_OP_READ` SQEs to read piece data from disk.
2. On completion, the read buffer is enqueued to the hasher thread pool.
3. The hasher threads only hash the already-read data and signal completion back
   via eventfd.

This is moderate rather than significant because the hasher already has a job
queue and eventfd signaling — the change is splitting the current "read + hash"
job into "hash only" and moving the read responsibility to the ring. The
`recheck.zig` path already does ring-based reads for verification, so there is
an existing pattern to follow.

### 7. `daemon/session_manager.zig:987-994` — blocking file copy

Uses `posix.read`/`posix.write` in a loop to copy torrent data files during
relocation. Could be replaced with `IORING_OP_SPLICE` or ring-based read/write,
but the function is called from `moveDataFiles` which operates on `std.fs` file
handles. Needs refactoring to use fds on the ring.

### 8. Eventfd read/write via posix on the event loop thread

The hasher and DNS subsystems signal the event loop via `posix.read`/`posix.write`
on eventfds:

- `src/io/hasher.zig:234` — `posix.read(event_fd)`
- `src/io/hasher.zig:308, 361` — `posix.write(event_fd)`
- `src/io/dns_threadpool.zig:382` — `posix.write(notify_fd)`
- `src/daemon/tracker_executor.zig:304` — `posix.read(dns_event_fd)`
- `src/daemon/udp_tracker_executor.zig:222` — `posix.read(dns_event_fd)`

The eventfd reads on the event loop thread should be ring-based
(`IORING_OP_READ` on the eventfd). The writes from background threads are
trickier — the background threads don't have ring access, so these writes are
arguably acceptable (they are just 8-byte wakeup signals). The reads, however,
should go through the ring.

---

## Category 3: Significant Rework Required

These are entire subsystems using blocking I/O patterns that need to be
redesigned as async ring-driven state machines.

### 9. HTTP tracker / web-seed client — resolved

The former synchronous HTTP network path has been removed. Production HTTP
tracker announces and web-seed range requests now run through `HttpExecutor`,
which submits socket, connect, send, recv, and TLS progress work through the
event-loop I/O contract.

### 10. `src/tracker/udp.zig` — `fetchViaUdp` (lines 440-590)

The entire UDP tracker flow is blocking:

- Line 450: `posix.socket()` — socket creation
- Line 458: `posix.connect()` — blocking UDP "connect"
- Lines 495, 517, 562: `posix.recv()` — blocking recv with `SO_RCVTIMEO`
- Line 586: `posix.send()` — blocking send

This needs to become an async state machine integrated with the ring, similar to
what `udp_tracker_executor.zig` is building. The retry/backoff logic with
`SO_RCVTIMEO` timeouts needs to be converted to ring-based recv with
timerfd-based deadlines.

### 11. `src/net/metadata_fetch.zig` — `MetadataFetcher.fetchFromPeer` (lines 301-464)

This is a fully blocking TCP client for BEP 9 metadata fetching:

- Line 306: `posix.socket()`
- Line 318: `posix.connect()` — blocking connect
- Lines 331, 354, 413, 456: `peer_wire.sendAll()` -> `posix.write()` loops
- Lines 335, 363, 370, 420, 427: `peer_wire.recvExact()` -> `posix.read()` loops

`peer_wire.zig` (lines 5-19) provides `sendAll`/`recvExact` as thin blocking
wrappers around `posix.write`/`posix.read`. The metadata handler in
`src/io/metadata_handler.zig` is the newer ring-based replacement that is
partially built. This is a full protocol state machine conversion.

### 12. `src/io/dns_cares.zig` — epoll-based c-ares integration (lines 228-320)

This uses `epoll_create1`, `epoll_ctl`, and `epoll_wait` to drive the c-ares DNS
resolver. This is a direct violation — the daemon should not use epoll at all.
Converting this requires either:

- Using c-ares's socket callback API to register fds with io_uring instead of
  epoll.
- Or replacing c-ares entirely with io_uring-native DNS (submit UDP queries as
  ring SQEs).

This is the most architecturally involved change because c-ares owns the socket
lifecycle.

### 13. `Thread.sleep` in daemon hot paths

| File | Line | Context |
|---|---|---|
| `src/main.zig` | 324 | Main event loop idle fallback (10ms) |
| `src/daemon/torrent_session.zig` | 2026 | Busy-wait for background network jobs (1ms) |

These should use timerfd on the ring. The main loop sleep is a fallback when the
ring has no completions — it should use `io_uring_enter` with a timeout instead.
The torrent session busy-wait should be replaced with eventfd signaling through
the ring.

---

## Not Violations (Acceptable Under Policy)

These are explicitly allowed by `AGENTS.md`:

- **`src/ctl/main.zig`** — CLI tool, not the daemon (std library I/O is fine).
- **`src/daemon/systemd.zig`** — one-time startup notification.
- **`src/perf/workloads.zig`** — benchmark code.
- **`src/crypto/mse.zig`** — test blocks only.
- **`src/rpc/server.zig` lines 733-807** — test blocks only.
- **`posix.write` on eventfds from background threads** — 8-byte wakeup signals;
  threads don't have ring access.

---

## Summary

| Category | Item Count | Effort |
|---|---|---|
| Easy (drop-in op swap) | ~40 call sites (socket, close, fdatasync) | Hours each |
| Moderate (function refactor) | ~15 call sites (pread/pwrite, eventfd reads, file copy, hasher read split) | Days each |
| Significant (subsystem redesign) | 3 remaining subsystems (UDP tracker, metadata_fetch, dns_cares) + 2 Thread.sleep sites | Weeks each |

The highest-value target is the **storage writer** (pread/pwrite on the piece
I/O hot path). The dns_cares epoll replacement is the most architecturally
complex.

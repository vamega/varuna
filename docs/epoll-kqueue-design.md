# EpollIO and KqueueIO — Design Survey

Research-only document. No code changes accompany it. The purpose is to give a
future implementation engineer a clear path for adding two new backends to
varuna's IO contract:

1. **`EpollIO`** — a Linux fallback used when `io_uring_*` is forbidden (seccomp
   policy, locked-down container runtimes, kernels too old for required
   features).
2. **`KqueueIO`** — a macOS-only development backend so `varuna` can build and
   run interactively on a developer's macOS laptop. Production stays Linux/io_uring.

The contract is `src/io/io_interface.zig`. Read it first; this document mirrors
its vocabulary (`Operation`, `Completion`, `Result`, `CallbackAction`).

Status: research / specification. Implementation is **not** in scope. References
read during the survey: `reference-codebases/libxev/src/backend/{epoll,kqueue}.zig`,
`reference-codebases/zio/src/ev/{loop.zig,backends/{epoll,kqueue}.zig,blocking.zig}`,
and `reference-codebases/tigerbeetle/src/io/{linux,darwin}.zig`.

---

## 0. Why this is non-trivial

io_uring is a *completion-based* (proactor) kernel API. The contract was
intentionally designed to match that shape: each method submits an asynchronous
operation, the kernel performs it, and a CQE delivers the result. SimIO mirrors
this with a deterministic in-process scheduler.

Both `epoll` and `kqueue` are *readiness-based* (reactor) APIs. They tell the
caller *when an fd is ready*; the caller still performs the syscall itself.
That gap drives every design choice below.

A second gap is bigger: neither epoll nor kqueue can deliver readiness for
**regular files**. On both platforms, files always poll ready, and the actual
read/write/fsync syscall blocks the calling thread until it returns. Any
file-I/O-heavy workload — varuna's piece store, recheck verification — has to
route those calls through a worker thread pool to keep the event loop
responsive. This is what libxev and ZIO do, and it is unavoidable.

---

## 1. EpollIO sketch (Linux fallback)

### 1.1 Top-level shape

```
pub const EpollIO = struct {
    epoll_fd: posix.fd_t,
    timer_heap: TimerHeap,                    // min-heap of pending timeouts
    eventfd_wakeup: posix.fd_t,               // wake epoll_wait from another thread
    pending_socket_ops: SockOpQueue,          // ops parked on EAGAIN
    file_pool: ?*ThreadPool,                  // for read/write/fsync/fallocate
    completed: Queue(*Completion),            // ready-to-fire callbacks
    // ... bookkeeping for active counts, in_flight markers
};
```

`tick(wait_at_least)` semantics map cleanly: drain `completed`, drain finished
thread-pool tasks, then `epoll_wait` (with the next-timer deadline as the
timeout, in ms). Each ready fd corresponds to one or more parked `Completion`s;
retry their syscall, and on success deliver via the callback path.

### 1.2 Per-method mapping

| Op | Path | Notes |
|---|---|---|
| `socket` | inline `posix.socket(SOCK_NONBLOCK\|SOCK_CLOEXEC)` | Result delivered same tick; no epoll involved. Equivalent to `IORING_OP_SOCKET` returning a CQE before the next `tick`. |
| `connect` | non-blocking `connect`; `EINPROGRESS` → register fd for `EPOLLOUT`; on readiness, `getsockopt(SO_ERROR)` to capture connect outcome. | `deadline_ns` implemented via the existing timer heap (cancel the connect's parked entry on timeout). |
| `accept` (single-shot) | non-blocking `accept4`; `EAGAIN` → register `EPOLLIN`. | After delivery, `accept_multishot=false` honors `.disarm`/`.rearm` like RealIO. |
| `accept` (multishot) | Loop: `accept4` until `EAGAIN`, deliver each fd as a separate callback invocation, then re-register `EPOLLIN` and wait for the next ready edge. | Native multishot doesn't exist on epoll. The contract's `multishot: bool` flag is honored semantically. |
| `recv` / `send` | non-blocking syscall; `EAGAIN` → register `EPOLLIN` / `EPOLLOUT`; on readiness retry. | Use `EPOLLET` (edge-triggered) plus drain-loop discipline to minimise syscalls. |
| `recvmsg` / `sendmsg` | same as recv/send but via `recvmsg`/`sendmsg`. | Used by the uTP and UDP-tracker paths. |
| `read` / `write` (with `offset`) | **Thread pool**. Submit task, on completion push to `completed` and wake epoll via `eventfd`. | Files always poll ready on epoll; readiness path is useless. |
| `fsync` / `fallocate` | Thread pool. | Same reasoning. |
| `timeout` | Insert into `timer_heap`; deadline drives the next `epoll_wait` timeout argument. | No timerfd needed for the heap-based design (libxev uses this approach too). A timerfd is still useful if the heap grows large; not required for first cut. |
| `poll` | Register fd for `op.events`; deliver `revents` from `epoll_event.events`. | Direct, native mapping. |
| `cancel` | Best-effort. Find target completion in `pending_socket_ops` or `timer_heap`; remove it; deliver `error.OperationCanceled` on the target completion and `void` on the cancel completion. If the target is in flight on a worker thread (file op), mark a "cancelled" flag and let the worker see it on its way back. | Cannot truly interrupt a syscall in progress on a worker thread. Document as a best-effort semantic. |

### 1.3 Subtleties

- **Edge-triggered vs level-triggered.** Edge-triggered (`EPOLLET`) needs the
  caller to drain until `EAGAIN` on every wakeup; level-triggered fires every
  loop until the condition clears. Most hot-path varuna sockets carry exactly
  one outstanding op per fd at a time, so level-triggered with `EPOLLONESHOT`
  is the simplest correct model and matches tigerbeetle's
  `EV.ADD | EV.ENABLE | EV.ONESHOT` choice on darwin.
- **fd lifetime.** Closing an fd while it is still in epoll is a known Linux
  footgun; remove via `EPOLL_CTL_DEL` before close. RealIO doesn't have this
  concern because the SQE/CQE pair self-tracks.
- **Wakeup eventfd.** Required so background threads (the file-op pool, DNS,
  SQLite) can wake `epoll_wait` deterministically when they push completions
  to `completed`.
- **Per-completion backend state.** Fits in `_backend_state` (64 bytes). State
  needed: linkage in pending queues + a "registered with epoll" flag + the
  retry callback. ~24-32 bytes — well under budget.

### 1.4 Where the contract holds and where it strains

- `recv`/`send`/`recvmsg`/`sendmsg`/`socket`/`connect`/`accept`/`timeout`/`poll`
  map cleanly. Same callback signature, same caller-owned-completion shape.
- `read`/`write`/`fsync`/`fallocate` map *behaviorally* but the asynchrony is
  faked by a thread pool. From the caller's perspective the only observable
  difference is latency variance and reduced parallelism vs. io_uring's
  `IORING_OP_READ_FIXED` etc.
- `cancel` is weaker: io_uring can preempt an in-flight `read`/`write` SQE;
  epoll cannot once the syscall is on the worker stack. The contract already
  documents cancel as best-effort, so no signature change is required.

---

## 2. KqueueIO sketch (macOS dev)

### 2.1 Top-level shape

Mirrors EpollIO with three substitutions:

- `kqueue_fd` instead of `epoll_fd`.
- `EVFILT_READ` / `EVFILT_WRITE` instead of `EPOLLIN` / `EPOLLOUT`.
- Wakeup via `EVFILT_USER` (or a Mach port on Apple platforms — libxev does the
  Mach-port path to avoid the additional fd) instead of an `eventfd`.

### 2.2 Per-method mapping

| Op | Path | Notes |
|---|---|---|
| `socket` | inline `posix.socket`. Set `SOCK_NONBLOCK` via `fcntl(F_SETFL, O_NONBLOCK)` and `FD_CLOEXEC` via `fcntl(F_SETFD)` — macOS lacks `accept4`/`SOCK_NONBLOCK`/`SOCK_CLOEXEC` flags. | Two extra fcntls per socket. |
| `connect` | Non-blocking connect; on `EINPROGRESS` register with `EVFILT_WRITE` + `EV_ONESHOT`. On readiness, `getsockopt(SO_ERROR)`. | Same shape as epoll. `deadline_ns` via timer heap. |
| `accept` | Register `EVFILT_READ` with `EV_ONESHOT`; on fire, accept-until-`EAGAIN`. fcntl the accepted fds non-blocking. | Multishot semantics emulated identically to EpollIO. |
| `recv` / `send` | Non-blocking syscall; `EAGAIN` → register `EVFILT_READ` / `EVFILT_WRITE`. | Identical pattern. |
| `recvmsg` / `sendmsg` | macOS `msghdr` is binary-compatible enough for the existing struct layouts; verify the `posix.msghdr` definition the contract uses already has the right fields on darwin. The TCP/IP datagram path is unchanged. | This is where macOS quirks mostly bite for varuna's uTP; spend time verifying `recvmsg` semantics on real hardware. |
| `read` / `write` (positional) | Thread pool, `pread`/`pwrite`. | Same reason as epoll. |
| `fsync` | Thread pool, `fsync` (or `fcntl(F_FULLFSYNC)` if true durability matters; macOS `fsync` is weaker). | Document the F_FULLFSYNC question; for a dev backend that's fine to ignore. |
| `fallocate` | macOS has **no** Linux-style `fallocate`. Thread-pool emulation: `fcntl(F_PREALLOCATE)` (the closest equivalent — best-effort contiguous allocation hint) followed by `ftruncate` to set size. | Behavior diverges from Linux: F_PREALLOCATE doesn't reserve blocks deterministically. Acceptable for a dev backend; document the gap. |
| `timeout` | `EVFILT_TIMER` is native, but libxev *avoids* it specifically because per-timer kqueue calls cost a syscall each. Use the same heap-of-deadlines model as EpollIO; pass the next deadline as the `kevent` timeout argument. | Single design choice across both backends. |
| `poll` | Register `EVFILT_READ` for `POLL_IN`, `EVFILT_WRITE` for `POLL_OUT`, deliver `revents` synthesised from the active filter. Map `POLL_HUP`/`POLL_ERR` from `EV.EOF` / `EV.ERROR`. | Manual translation needed because POSIX `poll` revents and kqueue filter semantics are not 1:1. |
| `cancel` | `EV.DELETE` on registered events. For thread-pool tasks, same best-effort flag. | |

### 2.3 macOS-specific quirks worth pre-flagging

- **No `IPV6_V6ONLY` default.** Linux defaults to dual-stack on a single AF_INET6
  socket; macOS may require explicit `setsockopt(IPV6_V6ONLY, 0)`. varuna's
  socket-creation path (`src/io/sockets.zig` if it exists; otherwise
  `src/daemon/listen.zig`) needs to set the option explicitly. Check whether
  the daemon already does this — if so, no work; if not, add.
- **No `accept4`, no `SOCK_NONBLOCK` flag.** Each `socket(2)` and `accept(2)`
  needs follow-up `fcntl(O_NONBLOCK)`. Two extra syscalls per accepted peer.
  Acceptable for a dev backend.
- **`sendmsg`/`recvmsg` cmsg differences.** The control-message format and
  `MSG_NOSIGNAL` / `SO_NOSIGPIPE` differ (use `setsockopt(SO_NOSIGPIPE)` to
  match `MSG_NOSIGNAL` semantics). varuna's hot path doesn't currently use
  cmsgs but worth flagging.
- **EV_RECEIPT vs blocking submission.** Kqueue submits and waits in one
  call; libxev and tigerbeetle both use the same `kevent` for both. Decide
  whether to issue zero-event "receipt" passes for batched submission or to
  fold submissions into the next wait — tigerbeetle's "fold into next wait"
  is the simpler model and is what to copy.

---

## 3. Cross-cutting concerns

### 3.1 DNS resolution

varuna currently has two DNS implementations behind a runtime toggle:
- `src/io/dns_threadpool.zig` — synchronous `getaddrinfo` on a worker thread.
- `src/io/dns_cares.zig` — c-ares with the proof-of-concept io_uring engine.

For epoll/kqueue:
- The thread-pool DNS path keeps working unmodified (it's already
  io-backend-agnostic — it returns its result via a completion the event loop
  picks up). No changes needed.
- The c-ares io_uring engine doesn't apply. To get a fully-async DNS path on
  epoll/kqueue, c-ares would be configured with its built-in *socket callback*
  hooks, which are inherently readiness-based and a natural fit for both
  backends. This is a larger follow-up; punt.

Recommendation for the first cut: keep `dns_threadpool.zig` for both backends.
Don't try to port the c-ares-on-io_uring proof-of-concept — it would be a
parallel research track.

### 3.2 SQLite

`AGENTS.md` mandates SQLite on a dedicated background thread. That mandate is
backend-independent: the constraint comes from SQLite's API surface, not from
io_uring's. No changes for epoll/kqueue.

### 3.3 `PieceStore.init`

The 2026-04-27 storage-IO refactor moved `PieceStore.init` to the contract
(`progress-reports/2026-04-27-storage-io-contract.md`). On the daemon path it
spins up a one-shot `RealIO` ring per torrent solely to drain the init's
fallocate/fsync completions, then tears it down. Cost: one
`io_uring_setup`/teardown per torrent, ~tens of µs.

For `EpollIO` and `KqueueIO`, the analog is even simpler:
- Spin up a one-shot `EpollIO`/`KqueueIO` whose only role is to drain the
  worker-thread-pool completions for the init's fallocate calls.
- Or: skip the contract entirely on first init and call the synchronous
  syscalls directly (`posix.fallocate`/`posix.ftruncate` on Linux,
  `fcntl(F_PREALLOCATE)` on macOS). Init runs once per torrent, on a
  background thread, and is short.

Recommendation: keep contract symmetry. The one-shot loop pattern works for any
backend; just route the worker pool's completions through it. The complexity
cost of two paths (contract-routed init for RealIO + ad-hoc init for
Epoll/KqueueIO) is not worth saving the ~tens-of-µs per torrent.

### 3.4 Single-threaded ownership

io_uring rings are single-thread-owned by default (`io_uring_enter` is reentrant
within the owning thread, but cross-thread submission requires shared workqueue
flags or external synchronisation). epoll fds and kqueue fds have similar
norms. The current event-loop thread is the only thread that should own the
backend's primary fd, with explicit wakeup mechanisms (`eventfd` on Linux,
`EVFILT_USER` or Mach port on macOS) for cross-thread completions from the
file-op pool / DNS / SQLite.

No contract change required — single-threaded ownership is already the
operating model.

### 3.5 Background threads — unaffected

The hasher pool (`src/io/hasher.zig`), runtime probing (`src/runtime/`), and
the multi-tracker announce thread pool are all CPU-bound or external-API-bound
work that runs off-loop regardless of the IO backend. No changes for any of
these. The "remove these violations" line in `AGENTS.md` continues to refer
specifically to the patterns it already calls out.

---

## 4. Reference implementations — survey

### 4.1 libxev

`reference-codebases/libxev/src/backend/{io_uring,epoll,kqueue}.zig`. ~2k lines
each. Single Zig library targeting Linux / macOS / BSDs / Windows / WASI from a
common loop API. Insights:

1. **Per-completion `threadpool: bool` flag.** Each `Completion` carries a
   flag that selects "submit via the readiness backend" vs "submit to the
   thread pool". File ops set the flag implicitly; socket ops don't. This
   matches the contract's caller-owned-completion model — the flag would live
   in `_backend_state` for varuna. (`epoll.zig:563+`, `kqueue.zig:716+`).
2. **Heap-based timers.** Both epoll and kqueue backends use a min-heap of
   timer completions, *not* the kernel-native primitive (timerfd / EVFILT_TIMER).
   Rationale baked into a comment in `kqueue.zig`: "we use heaps instead of
   the EVFILT_TIMER because it avoids a lot of syscalls in the case where
   there are a LOT of timers." Copy this directly.
3. **Author flagged the epoll backend as "in much poorer quality" than kqueue.**
   The kqueue backend is the canonical one to read for design patterns —
   epoll is structurally similar but rougher in libxev. Reading kqueue first
   and porting back to epoll is the recommended path.

### 4.2 ZIO

`reference-codebases/zio/src/ev/`. Newer Zig event-loop library. Insights:

1. **Compile-time backend selection via `zio_options.backend`.** A build flag
   picks between `poll` / `epoll` / `kqueue` / `io_uring` / `iocp`. Default is
   per-OS. This is exactly the pattern to copy for varuna's `-Dio=` flag
   (Section 5.3 below).
2. **Per-op `BackendCapabilities` table.** Each backend declares which ops it
   handles natively; the loop's dispatch checks the table and falls through to
   the thread pool for ops not in the capability set. Cleaner than libxev's
   per-completion flag — the engineer doesn't have to remember which ops need
   the flag set. Worth considering for the EpollIO/KqueueIO design.
3. **Unconditional thread-pool offload for file ops on poll/epoll/kqueue.**
   `zio/src/ev/loop.zig:704` (`submitFileOpToThreadPool`) confirms: every
   file-system op on the readiness backends goes through the thread pool.
   No second path. Strong signal that's the right default for varuna too.

### 4.3 tigerbeetle

`reference-codebases/tigerbeetle/src/io/{linux,darwin}.zig`. Production-grade
distributed-systems backends, not a general library. Insights:

1. **Tight, hand-rolled per-op state machines.** No abstraction layer above
   the kernel API; each method has a hand-coded `submit` + `do_operation` +
   `flush` triple. Tigerbeetle achieves portability without a unifying
   trait — three siblings of `IO` per platform.
2. **EV_ONESHOT for every kqueue registration.** The darwin backend
   uses `EV.ADD | EV.ENABLE | EV.ONESHOT` everywhere, then re-registers on
   the *next* WouldBlock. Simpler than tracking which fds are currently
   registered. ~500 lines shorter than libxev's kqueue backend. Recommend
   this approach for first-cut KqueueIO.
3. **Synchronous fsync on the event-loop thread.** Tigerbeetle calls `fsync`
   inline (`darwin.zig:496+`). They get away with this because their
   workload pattern keeps fsync rare and predictable; varuna can't (the
   piece store fsyncs on every batch). Don't copy this — use a thread pool
   for fsync.

---

## 5. Recommended implementation strategy

### 5.1 Order of work

The minimum viable EpollIO that lets varuna run under seccomp:

1. **EpollIO scaffolding**: `init`, `deinit`, `tick`, the wakeup eventfd, the
   pending-socket-ops queue, the timer heap. ~400 lines.
2. **Socket ops**: `socket`, `connect` (with deadline), `accept`
   (single-shot + multishot loop), `recv`, `send`, `sendmsg`, `recvmsg`,
   `poll`, `cancel`. ~500 lines.
3. **`timeout`**: heap-driven, no separate fd. ~50 lines.
4. **Thread-pool integration**: existing `hasher.zig`-style pool reused for
   file ops. ~200 lines.
5. **File ops**: `read`, `write`, `fsync`, `fallocate`. ~150 lines.
6. **Tests**: a backend-specific smoke test per op (echo over a real
   socketpair; verify `tick` drains correctly). The bulk of the existing
   contract-level tests run via `SimIO` and don't need duplication.

KqueueIO follows the same skeleton; on macOS, copy from libxev's kqueue (read)
and tigerbeetle's darwin (write), pick the one-shot model.

### 5.2 Contract changes needed

The contract is well-shaped for both backends, but two friction points:

- **`fallocate` on macOS has no semantic equivalent.** The op must be allowed
  to return `error.OperationNotSupported` cleanly so `PieceStore.init`'s
  existing `setEndPos` fallback fires. The `_OperationNotSupported_`
  fallback is already in place per the storage-IO progress report; KqueueIO
  just needs to deliver that errno consistently.
- **Cancel weakening for thread-pool ops.** Already documented as best-effort.
  No signature change.

No changes to method signatures or `Operation`/`Result` variants.

### 5.3 Build-time selection

Mirror ZIO's pattern:

```
-Dio=io_uring   # default on Linux ≥5.10
-Dio=epoll      # Linux fallback / seccomp-restricted environments
-Dio=kqueue     # macOS / FreeBSD developer builds
```

`build.zig` resolves to a comptime constant; the daemon defines a single
`pub const RealIO = ...` aliased to the chosen type. Daemon-side callers stay
on `XOf(RealIO)` aliases. Lazy method compilation means callers don't recompile
their bodies just because the alias changed (per pattern #10 in the existing
progress reports).

A runtime probe (`src/runtime/probe.zig`) can refuse-to-start with a clear
error if the user picks `io_uring` on a kernel that doesn't support it.

### 5.4 Test strategy

The vast majority of varuna's IO tests target `XOf(SimIO)`. Those tests are
backend-implementation-agnostic and **do not** need EpollIO or KqueueIO
variants. SimIO is the single oracle for protocol correctness, recovery
behavior, and BUGGIFY fault injection.

What does need backend-specific tests:

- **Smoke tests per backend**: a real-fd echo test per op (one socketpair
  per backend, run the same script through it). Catches integration bugs
  in the backend itself — wrong epoll flags, missed re-registration on
  EAGAIN, wrong kqueue filter.
- **Cross-backend integration**: `tests/transfer_integration_test.zig`-style
  end-to-end transfers parameterised over `RealIO` (under each backend
  build) and over the loopback. Run only in CI's "all backends" matrix.

There is no need to fork existing tests into per-backend variants. The
contract is the test surface.

### 5.5 Estimated effort

Order-of-magnitude only; engineer skill and macOS access dominate variance.

- **EpollIO (minimum viable)**: ~1 work-week. Socket ops are mechanical;
  thread-pool integration reuses existing primitives. Most of the time goes
  to wiring + smoke tests + verifying the daemon stays clean under
  `strace -f -yy -c`.
- **KqueueIO (developer build only, no production claim)**: ~1.5 work-weeks.
  The macOS-specific quirks (no SOCK_NONBLOCK, F_FULLFSYNC, F_PREALLOCATE,
  IPV6_V6ONLY default) eat half the budget. Build-system work to make
  `zig build` cross-compile cleanly for darwin from a Linux dev machine adds
  a day or two on top.
- **Both backends polished to production parity (would close the seccomp
  story for real)**: ~1 calendar month including BUGGIFY-style fault tests
  per op, verified-cancel behavior, and performance regression baselining
  vs the io_uring backend.

---

## 6. Open questions filed for the implementation engineer

1. Should the file-op thread pool be **shared** with `hasher.zig`'s hashing pool
   or kept separate? Sharing reduces context-switch surface; separating
   prevents hashing latency from gating reads. Suggested first cut: separate.
2. On macOS, is `fcntl(F_FULLFSYNC)` worth the extra latency vs `fsync`? For a
   developer backend, no. If KqueueIO is ever promoted to production, yes.
3. Is `EPOLLET` worth the additional code complexity over `EPOLLONESHOT`?
   Suggested: start with `EPOLLONESHOT`. Move to `EPOLLET` only if profile
   shows excess `epoll_wait` syscalls.
4. Where does the `truncate` follow-up (deferred from the storage-IO refactor)
   fit? On EpollIO and KqueueIO it must be thread-pooled regardless, so
   adding a `TruncateOp` to the contract becomes mandatory if we want the
   `setEndPos` fallback path to keep working uniformly.

These are not blocking — start the implementation, surface them as concrete
PRs once the scaffolding lands.

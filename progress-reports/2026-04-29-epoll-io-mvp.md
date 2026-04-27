# EpollIO MVP — sockets, timers, cancel — 2026-04-29

Branch: `worktree-epoll-io`.

Implements a minimum-viable `EpollIO` backend behind a new `-Dio=` build
flag, following `docs/epoll-kqueue-design.md` and the
`progress-reports/2026-04-27-epoll-kqueue-research.md` survey.

## What changed

Two bisectable commits on `worktree-epoll-io`:

1. **`io: add EpollIO MVP backend (sockets + timers + cancel)`** —
   `src/io/epoll_io.zig` (~720 LOC), `src/io/backend.zig` comptime
   selector (~80 LOC), `build.zig` `-Dio=` flag with
   `io_uring`/`epoll` choices (`kqueue` slot reserved for the parallel
   macOS engineer), `src/io/root.zig` test wiring.
2. **`io: add tests/epoll_io_test.zig + zig build test-epoll-io step`** —
   ~310 LOC of focused smoke tests covering multi-tick socketpair
   round-trip, multiple timers in deadline order, cancel of registered
   recv, file-op `error.Unimplemented` contract, and non-blocking-fd
   socket creation.

`zig fmt .`: clean. `zig build` (default `-Dio=io_uring`): clean.
`zig build -Dio=epoll`: clean. `zig build test`: green. `zig build test
-Dio=epoll`: green. `zig build test-epoll-io`: green. Test count delta:
**1418 → 1430 (+12)**: 6 inline tests in `src/io/epoll_io.zig`, 5 in
`tests/epoll_io_test.zig`, 1 in `src/io/backend.zig`.

## Ops implemented vs. deferred

| Op | Status | Notes |
|---|---|---|
| `socket` | ✅ | Always non-blocking + cloexec; sync completion. |
| `connect` | ✅ | Non-blocking + EAGAIN→EPOLLOUT register; SO_ERROR check on readiness. `deadline_ns` parameter is currently a no-op (caller uses explicit `cancel` from a separate timer). |
| `accept` | ✅ | Single-shot path: try once, register EPOLLIN on EAGAIN. `multishot=true` is honoured semantically via callback `.rearm`; native multishot doesn't exist on epoll. |
| `recv` | ✅ | EAGAIN→EPOLLIN→retry pattern. |
| `send` | ✅ | EAGAIN→EPOLLOUT→retry pattern. |
| `recvmsg` | ✅ | Same shape as `recv` (uses `linux.recvmsg`). |
| `sendmsg` | ✅ | Same shape as `send` (uses `linux.sendmsg`). |
| `poll` | ✅ | Direct mapping; `op.events` passed through to `epoll_event.events`. |
| `timeout` | ✅ | Heap-of-deadlines (libxev pattern). Drives `epoll_pwait` timeout argument. |
| `cancel` | ✅ | Best-effort: removes registered fd via `EPOLL_CTL_DEL` and delivers `OperationCanceled`; removes timer from heap and delivers `OperationCanceled`; otherwise `error.OperationNotFound`. |
| `read` / `write` | ❌ | `error.Unimplemented`. Requires worker thread pool. |
| `pread` / `pwrite` | ❌ | `read` and `write` carry a positional `offset` in the contract; same Unimplemented. |
| `fsync` / `fdatasync` | ❌ | `error.Unimplemented`. Thread-pool offload required. |
| `fallocate` | ❌ | `error.Unimplemented`. |
| `truncate` | ❌ | `error.Unimplemented`. |

The MVP is **enough to run the daemon's network surface** (peer wire,
RPC, tracker, DHT, uTP) but **not its storage surface**. PieceStore,
recheck, fsync-after-write, and fallocate-on-init all touch file ops
and would all fail under `-Dio=epoll`. Wiring the daemon's
`real_io.RealIO` consumers onto `backend.RealIO` is gated on the
file-op follow-up.

## Architecture decisions worth surfacing

### Self-contained submission methods (no `resubmit` cycles)

Each socket submission method runs its own `.rearm` loop. They
intentionally do **not** call back into the dispatch helper. Mutual
recursion (`recv → resubmit → recv`) would otherwise produce an
inferred-error-set cycle that Zig 0.15.2 cannot resolve. The async
path through `tick → dispatchReady → resubmit → submission method`
still works because submission methods only call `armCompletion` and
`registerFd` — neither of which feeds back into the callback chain.

This is more verbose than libxev's epoll backend (which uses Result
unions and a single `start()` dispatch table) but it matches
`real_io.zig`'s shape closely enough that the code reads as a peer.
Pattern adapted from `real_io.zig`'s `truncate` loop.

### Timer "heap" is a flat array

Linear `peekMin` over a flat array. varuna's hot path runs
~hundreds of timers; the constant-factor wins of a true binary heap
don't matter at that scale yet. Promote when profiling shows it.
Pattern call-site: `TimerHeap.peekMin` in `src/io/epoll_io.zig`.

### EPOLLONESHOT, not EPOLLET

Per the design doc's recommendation. Edge-triggered with drain-loop
discipline is a real win when many ops share an fd; varuna's hot path
has at most one outstanding op per fd, so the simpler one-shot model
suffices. Switch later if we ever multiplex.

### Single eventfd for cross-thread wakeup

Registered in epoll under `data.fd = wakeup_fd` (sentinel). Future
file-op worker threads write to it; the dispatch loop drains the
counter and continues. Currently unused (no worker threads yet) but
the wiring is in place so the file-op follow-up doesn't need to
revisit `tick`.

## What I learned

### Zig 0.15.2 and inferred-error-set cycles

The cleanest way to write the backend is to dispatch through a
`Result.recv = anyerror!usize` union with a helper that does the
syscall and returns `Either(Ok, Err)`. The naive shape — a single
`deliverInline → resubmit → submission method → deliverInline` chain —
breaks Zig's inferred-error-set resolution. Same problem `real_io.zig`
sidestepped by giving `truncate` its own loop, and same trick I used
across all socket ops here. This is worth flagging in
`docs/epoll-kqueue-design.md` for the kqueue engineer.

### `posix.SOCK.NONBLOCK` is a flag bit, not a boolean

Setting non-blocking on an existing fd via `fcntl(F_SETFL, flags |
SOCK.NONBLOCK)` works because Linux's `O_NONBLOCK` and `SOCK_NONBLOCK`
share the same bit pattern. `posix.fcntl` on Zig 0.15.2 returns
`usize`, and the OR has to go through `@bitCast` against `isize` to
satisfy the signed-vs-unsigned dance. Documented in the test fixtures.

### EPOLL_CTL_DEL semantics on a closed fd

Closing a registered fd would normally produce a wedge: epoll keeps a
reference, and the kernel's "fd auto-removed on last close" only
applies if no `dup` exists. The contract's `closeSocket` defensively
calls `EPOLL_CTL_DEL` first, ignoring `ENOENT`. This matches the
design doc's "fd lifetime footgun" call-out.

### eventfd for wakeup, not a socketpair

libxev's epoll backend uses an `eventfd` exclusively. tigerbeetle's
darwin backend uses Mach ports. socketpair would also work but takes
two fds. eventfd is one fd, one syscall to signal, and one to drain.
No reason to use anything else on Linux.

## Surprises vs. the design doc

1. **Daemon callers don't transparently switch yet.** The design doc and
   the team-lead brief both implied a one-shot wiring of
   `backend.RealIO` through the daemon. In practice that requires
   updating six files (`recheck.zig`, `writer.zig`, `rpc/server.zig`,
   `app.zig`, `perf/workloads.zig`, `storage/verify.zig`) and would
   conflict with the parallel runtime-detect-engineer's work in
   `real_io.zig`. The MVP delivers the build flag + selector + the
   backend itself; rewiring is gated on the file-op follow-up
   landing first, since without file ops the daemon would compile
   under `-Dio=epoll` but blow up at first PieceStore call.

2. **Multishot accept is a callback-driven loop, not native.** The
   contract's `multishot: bool` flag is honoured semantically — the
   caller's `.rearm` return drives re-arming. There's no kernel-side
   multishot on epoll, so this is faithful to the design doc's
   recommendation.

3. **`deadline_ns` on `connect` is currently a no-op.** Production
   callers chain a separate `timeout` completion that calls `cancel`
   on the in-flight connect; that path works today. Native deadline
   plumbing inside `connect` would require side-completion
   bookkeeping similar to RealIO's `link_timeout` pair, and was
   skipped in the MVP. Tracked below.

4. **The `Build Summary` line is suppressed on success.** In Zig
   0.15.2 + the local nix devshell, a successful `zig build test`
   exits 0 silently — there's no `tests passed` summary line at all.
   I had to confirm via `tail` and `exit=$?`. Worth flagging for the
   next round-trip.

## Remaining issues / follow-ups

These are NOT blockers — the MVP shipped is correct for what it
implements. Order roughly by impact.

1. **File ops via worker thread pool** (~1-2 days). The big one. Add
   a worker pool — separate from the hasher pool per the design doc's
   open question — and route `read`, `write`, `fsync`, `fallocate`,
   `truncate` through it via the `wakeup_fd`. Once this lands the
   daemon can actually run end-to-end under `-Dio=epoll` and we can
   migrate the storage callers onto `backend.RealIO`.

2. **Daemon caller migration to `backend.RealIO`** (~30 min once #1
   lands). Six files. Trivial mechanical change once the file ops
   work.

3. **`connect` deadline plumbing** (~1 hour). Add a side completion
   that the `connect` submission method itself manages — chain-cancel
   on deadline expiry, deliver `error.ConnectionTimedOut` on the
   parent. Mirrors RealIO's `link_timeout` pattern.

4. **Multishot accept drain loop on EPOLLIN** (~30 min). Currently
   accept fires once per `.rearm`. Native io_uring multishot delivers
   N accepts per SQE; the closest epoll equivalent is to drain
   `accept4` until EAGAIN inside `dispatchReady`. Worth doing for the
   listener's hot path under high churn.

5. **CI matrix entry for `-Dio=epoll`** (~15 min). GitHub Actions
   needs a column. `zig build test -Dio=epoll` should run alongside
   the default `zig build test`.

6. **Timer heap → real binary heap** (deferred until profiled). The
   flat-array `peekMin` is O(n) per fire; with N timers the tick cost
   is O(n²) over a sweep. varuna's hot path is small enough that this
   doesn't matter today; revisit when timer count grows.

7. **`docs/epoll-kqueue-design.md`: append a "Zig 0.15.2 inferred
   error sets" lesson** for the kqueue engineer to read first. Saved
   me a half-hour of confused refactoring; no reason for them to hit
   it independently.

## Key code references

- `src/io/epoll_io.zig:182-244` — `EpollIO.init` / `deinit` /
  `closeSocket`. Core lifecycle.
- `src/io/epoll_io.zig:246-318` — `tick` + `computeEpollTimeout` +
  `fireExpiredTimers`. Main loop.
- `src/io/epoll_io.zig:319-389` — `dispatchReady` + `resubmit`. Async
  path.
- `src/io/epoll_io.zig:392-693` — Self-contained submission methods.
- `src/io/epoll_io.zig:695-724` — File-op `Unimplemented` stubs.
  Document the gap.
- `src/io/epoll_io.zig:728-779` — `armCompletion`, `registerFd`,
  `deliverInline`. Helpers.
- `src/io/epoll_io.zig:782-852` — Per-op syscall helpers (`doRecvmsg`,
  `doSendmsg`, `doConnectComplete`, `doAccept`, `performInline`).
- `src/io/backend.zig` — Comptime selector (~80 LOC).
- `build.zig:20-46` — `-Dio=` option declaration with kqueue slot.
- `build.zig:307-326` — `test-epoll-io` step + epoll_io_tests addTest.
- `tests/epoll_io_test.zig` — Standalone smoke tests.
- `reference-codebases/libxev/src/backend/epoll.zig` — Reference
  implementation; structurally similar but the libxev author flagged
  it as "in much poorer quality" than their kqueue backend, so I
  cross-referenced both.
- `docs/epoll-kqueue-design.md` — Strategic-guidance document.

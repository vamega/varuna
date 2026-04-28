# 2026-04-30 — POSIX file-op thread pool for EpollPosixIO + KqueuePosixIO

## What changed and why

The two readiness-style backends — `EpollPosixIO` (Linux) and `KqueuePosixIO`
(macOS / BSD) — landed in the 2026-04-30 bifurcations with stub file-op
methods that returned `error.Unimplemented` (Linux) or
`error.OperationNotSupported` (macOS). Neither could run a daemon
end-to-end. This work fills that gap by adding a shared worker-thread pool
that both backends submit file ops to.

Why a thread pool: epoll and kqueue are *readiness* APIs for
*file descriptors*. For regular files, the kernel reports them as
"always ready" — the actual `pread`/`pwrite`/`fsync` call blocks the
caller while a page fault is serviced. To preserve the contract's
"submission returns immediately, the callback fires later" shape, every
file-op syscall has to run off the EL thread. `zio` and `libxev`'s
epoll backend already follow this pattern; varuna adopts it for both
readiness backends.

## Design

One module, two consumers. `src/io/posix_file_pool.zig` exposes:

- `PosixFilePool.create(allocator, .{ .worker_count, .pending_capacity })`
- `PosixFilePool.deinit()` — joins workers, cancels still-pending ops,
  frees state.
- `PosixFilePool.submit(op, *Completion)` — push a file op onto the
  pending queue. Returns `error.PendingQueueFull` past the bound.
- `PosixFilePool.drainCompletedInto(*ArrayListUnmanaged(Completed))` —
  the backend's `tick` calls this to copy out any results workers have
  pushed; iterates and fires callbacks.
- `PosixFilePool.tryCancelPending(*Completion)` — best-effort cancel
  for pending entries; workers that already picked the op up cannot
  be interrupted.
- `PosixFilePool.setWakeup(ctx, wake_fn)` — backend wires its readiness
  primitive's wake mechanism here. The pool stays decoupled.

The pool itself is platform-agnostic; only the wake hook differs:

- **EpollPosixIO**: `wakeup_fd` is an existing eventfd registered for
  `EPOLLIN`. Workers write a `u64` to it; `epoll_pwait` returns; `tick`
  reads the eventfd to drain the count and runs `drainPool`.
- **KqueuePosixIO**: registers a single `EVFILT_USER` kevent at a fixed
  ident (`0xFADEFADE`) with `EV_CLEAR` (edge-triggered) at init.
  Workers issue a `NOTE_TRIGGER` kevent against that ident; `kevent()`
  returns; `tick` recognises the user-event filter and skips the
  per-event dispatch (the result is already on `pool.completed`).

Both backends grew a `bindWakeup` method called post-`init` because the
pool's wake function needs a stable `*BackendType`, which `init`'s
return-by-value can't supply directly.

### Worker loop

Mirrors `hasher.zig`'s shape (Pattern #15 — read existing invariants):

- `pending_mutex` + `pending_cond` + `std.ArrayListUnmanaged(PendingEntry)`
- `completed_mutex` + `std.ArrayListUnmanaged(Completed)`
- `running` atomic flag
- `in_flight` atomic counter for `hasPendingWork`

Each worker waits on the condvar (with a 1-second timeout so a
`running=false` race wakes it), pops one pending entry, runs the
syscall (`posix.pread` / `pwrite` / `fsync` / Linux `fallocate` or
Darwin `fcntl(F_PREALLOCATE)` + ftruncate / `posix.ftruncate`), pushes
the result, and signals the wake hook. Capacity-based bounds are
enforced at submit-time; workers never block on a full completed queue
because `completed_capacity == pending_capacity` ensures every pending
entry has a guaranteed slot.

### Cancellation

File-op cancel through this pool is best-effort:

- If the op is still pending when `cancel` runs, we drop it and the
  pool pushes `OperationCanceled` onto its completed queue (the
  backend's next tick fires the user callback).
- If a worker has already picked it up, we cannot interrupt the
  syscall; the op's "real" result is delivered when the worker
  finishes. The cancel issuer's callback gets
  `error.OperationNotFound`.

Both readiness backends grew a fourth best-effort branch in their
`cancel` op to call `tryCancelPending` for file-op targets.

## Lifetimes

`PosixFilePool` is heap-allocated (so workers hold a stable pointer).
The backend owns the pool. Order on shutdown:

1. `Backend.deinit` calls `pool.deinit`.
2. Pool sets `running = false`, broadcasts the condvar, joins all
   workers.
3. Pool cancels any still-pending entries (pushes Cancelled onto
   completed); the backend's deinit drains them implicitly via the
   pool's swap buffer.
4. Backend closes its readiness primitive (`epoll_fd` / `wakeup_fd` /
   `kq`).

The deinit ordering is important: workers must stop before the
readiness primitive is closed so a worker-issued wake against a closed
fd doesn't panic.

## Bookkeeping

Both backends track outstanding pool work in a counter (`active` for
epoll, `pool_in_flight` for kqueue) so `tick`'s "should I block on the
readiness wait" decision considers pool work as well as parked sockets
and pending timers. `submitFileOp` bumps the counter; `dispatchPoolEntry`
clears `in_flight` on the completion's backend state and decrements the
counter before invoking the callback (mirrors RealIO's CQE-dispatch
contract — a callback that resubmits a follow-on op on the same
completion would otherwise trip `AlreadyInFlight` against itself).

## Tests

Algorithm-level (`src/io/posix_file_pool.zig`, 9 inline tests):

- create/deinit with default config
- `setWakeup` stores callback
- `submit` returns `PendingQueueFull` past bound
- `tryCancelPending` removes a pending op and pushes Cancelled
- write-then-read round-trip via the worker
- bad-fd surfaces error result (fault injection)
- 256-op stress run across 4 workers (file writes at distinct offsets)
- `hasPendingWork` tracks pending and in-flight
- `deinit` cancels still-pending submissions (testing-allocator catches
  leaks)
- wakeup callback fires after each completion

Integration (`tests/epoll_posix_io_test.zig`, 4 new tests):

- fsync / truncate / fallocate complete asynchronously via the pool
- write-then-read round-trip
- 64 concurrent writes all complete
- closed-fd fault propagates through the worker

Bridge (`tests/kqueue_posix_io_test.zig`, 2 new tests, gated behind
`is_kqueue_platform`): fsync round-trip and write-then-read round-trip.
Compile clean on Linux; exercise real kqueue on a darwin host.

The MVP-scope-marker test in `src/io/epoll_posix_io.zig` was rewritten
from "asserts Unimplemented" to "asserts real fsync via pool".

## Validation

```
zig build                                                  # default io_uring: clean
zig build -Dio=epoll_posix                                 # variant compiles
zig build -Dio=kqueue_posix                                # variant compiles
zig build -Dtarget=aarch64-macos -Dio=kqueue_posix         # cross-compile clean
zig build test                                             # green
zig build test-epoll-posix-io                              # green
zig build test-kqueue-posix-io-bridge                      # green
zig build test-kqueue-posix-io                             # green (Linux runs the
                                                            # platform-portable
                                                            # tests; macOS-gated
                                                            # tests SkipZigTest)
zig fmt .                                                  # clean
```

## What needs real-host validation

The pool itself runs on Linux today (every `posix.pread` / `pwrite` /
`fsync` / `fallocate` / `ftruncate` is real). The KqueuePosixIO
integration's runtime semantics are validated only via cross-compile;
remaining real-host concerns:

- `EVFILT_USER` + `NOTE_TRIGGER` actually breaks `kevent()` (cross-compile
  validates the type, not the runtime behaviour).
- `fcntl(F_PREALLOCATE)` error mapping under non-trivial filesystems
  (APFS will return EOPNOTSUPP for FAT32 mounts; tmpfs may have its own
  quirks).
- Worker contention under heavy fsync load on macOS — apple's
  `fcntl(F_FULLFSYNC)` is the stronger primitive; we deliberately use
  `fsync(2)` for dev-backend speed, but if profile shows correctness
  issues that decision flips.

## Surprises

1. **`deinit` use-after-free with deferred locks.** First draft used
   `defer self.completed_mutex.unlock()` followed by
   `allocator.destroy(self)`. The defer runs *after* destroy — the
   mutex memory is freed before the unlock executes. Caught by the
   testing allocator's segfault-on-UAF on the very first
   `create + deinit` test. Fixed by dropping the locks (no workers can
   race because we already joined them) and freeing `self` at the very
   end with the allocator captured in a local before destroy.
2. **Reference-codebase symlinks vs git status.** This worktree's
   `reference-codebases/` is a symlink (per `setup-worktree.sh`); the
   shared git index sees the original submodule pointers as "deleted"
   in the working tree. A `git add -u` on the second commit
   accidentally staged the deletions, dropping the gitlinks from the
   feature commit. Reset --soft + restore --staged + re-commit fixed
   it. Future commits should use explicit `git add <files>` rather
   than `-u`.
3. **NetBSD's `EVFILT.USER` constant is wrong upstream.** zio (and
   libxev) work around it with a per-platform switch. Mirrored that
   workaround. We don't ship NetBSD support but `std.c` constants
   can drift, so the explicit value protects against silent breakage.

## Files touched

- `src/io/posix_file_pool.zig` (new) — the thread pool itself.
- `src/io/root.zig` — module export + test discovery wiring.
- `src/io/epoll_posix_io.zig` — replaced 5 Unimplemented stubs;
  added pool, pool_swap, bindWakeup, drainPool, dispatchPoolEntry,
  submitFileOp; cancel grew the file-op branch.
- `src/io/kqueue_posix_io.zig` — same shape; `EVFILT_USER` registration
  in init; wakeFromPool issues `NOTE_TRIGGER`.
- `tests/epoll_posix_io_test.zig` — Unimplemented test rewritten;
  3 new tests.
- `tests/kqueue_posix_io_test.zig` — 2 new platform-gated tests.

## Follow-ups (not in scope here)

- Daemon-side rewire (`src/storage/writer.zig`, `src/io/recheck.zig`)
  onto `backend.RealIO` once the file-op coverage is mature in at
  least one non-`io_uring` backend.
- Page-fault mitigation for `EpollMmapIO` / `KqueueMmapIO` — those
  backends deliberately don't use this pool (they `memcpy` against an
  mmap on the EL thread). If profiling shows page-fault stalls, the
  same pool can be repurposed to run the `memcpy` itself.
- BUGGIFY-style fault tests for the pool (random worker delays, queue
  full at random ticks, etc.) — currently the pool has the canonical
  fault path tested (bad fd → error result), but no harness-driven
  fault injection.

## Key code references

- `src/io/posix_file_pool.zig:138+` — `PosixFilePool` struct + create/
  deinit.
- `src/io/posix_file_pool.zig:300+` — worker loop.
- `src/io/posix_file_pool.zig:340+` — `executeOp` and the per-op
  syscall functions (Linux/Darwin branching for fallocate).
- `src/io/epoll_posix_io.zig:262+` — tick with `drainPool` calls.
- `src/io/epoll_posix_io.zig:710+` — file op submission methods.
- `src/io/kqueue_posix_io.zig:230+` — init with `EVFILT_USER`
  registration.
- `src/io/kqueue_posix_io.zig:260+` — wakeFromPool and the
  cross-thread NOTE_TRIGGER.
- `src/io/kqueue_posix_io.zig:380+` — `drainPool` and
  `dispatchPoolEntry`.

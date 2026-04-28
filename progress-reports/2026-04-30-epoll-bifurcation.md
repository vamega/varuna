# 2026-04-30 — EpollIO bifurcation: file-I/O strategy as a separate axis

## What changed

The 2026-04-29 EpollIO MVP (commit `91eb57e`) implemented socket / timer /
cancel ops and stubbed file ops as `error.Unimplemented`, with the
expectation that file ops would land later via a thread pool wrapping
`pread`/`pwrite`. The user clarified the design: file-I/O strategy is its
own axis. There are TWO valid file-I/O strategies for a readiness-based
backend:

1. **POSIX**: `pread`/`pwrite`/`fsync`/`fallocate` syscalls, offloaded to a
   thread pool. Predictable, matches io_uring semantics, copies through
   syscall buffers.
2. **mmap**: file is mapped into the process address space; reads/writes
   are `memcpy`s; durability via `msync(MS_SYNC)`. Zero-copy, OS pagecache
   implicit, but page faults can stall the calling thread.

These deserve to be separate backends because they make different
tradeoffs. `EpollIO` got bifurcated into `EpollPosixIO` (rename of the
existing MVP) and `EpollMmapIO` (new). The kqueue side gets the same
split (`KqueuePosixIO` / `KqueueMmapIO`), owned by a parallel engineer;
this branch carries stub files for both so the 6-way `IoBackend`
selector compiles end-to-end.

The IoBackend enum is now 6-way:
- `io_uring` — production io_uring proactor (unchanged).
- `epoll_posix` — rename target for the previous `EpollIO` MVP. Sockets +
  timers + cancel real; file ops still `error.Unimplemented` pending the
  POSIX thread pool.
- `epoll_mmap` — new backend; readiness layer mirrors `EpollPosixIO`,
  file ops use mmap.
- `kqueue_posix`, `kqueue_mmap` — STUB files on this branch (sibling
  engineer replaces).
- `sim` — `SimIO` promoted to a top-level option. `RealIO` resolves to
  `sim_io.SimIO` for test builds that exercise the comptime selector.

## Commits

Three bisectable commits on `worktree-epoll-bifurcation`:

1. **`774a7d4` — `io: bifurcate EpollIO scaffold + extend IoBackend to
   6-way`.** File renames (`epoll_io.zig` → `epoll_posix_io.zig`,
   `tests/epoll_io_test.zig` → `tests/epoll_posix_io_test.zig`,
   `EpollIO` → `EpollPosixIO`). New scaffold for `EpollMmapIO`. New
   stubs for `KqueuePosixIO` + `KqueueMmapIO` (5-line types returning
   `error.Unimplemented` from every op). Extended `src/io/backend.zig`
   to dispatch to all six. Renamed test step
   `test-epoll-io` → `test-epoll-posix-io` in `build.zig`. SimIO wiring
   verified — its public surface conforms to the contract; `RealIO =
   sim_io.SimIO` works at the comptime selector level. `init` signatures
   still differ between backends (RealIO takes `Config{ .entries,
   .flags }`; the readiness backends and SimIO take
   `(allocator, Config)`); that's a caller-side adapter problem when /
   if a daemon caller ever moves to `backend.RealIO`. Today no daemon
   caller does — they all `@import("real_io.zig").RealIO` directly.

2. **`de100f2` — `io: build out EpollMmapIO MVP — sockets/timers/cancel +
   mmap file ops`.** Mirrors the readiness-layer code from
   `EpollPosixIO` (sockets / timers / cancel / `tick`) since epoll is
   the same axis. Adds mmap-backed file ops:

   - `pread` → `memcpy` from a per-fd lazy mmap region. `fstat` to size
     the mapping; `mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED,
     fd, 0)` then `madvise(MADV_WILLNEED)` to warm the pagecache. Reads
     past EOF return zero bytes (instead of erroring) — same semantics
     as `pread(2)`.
   - `pwrite` → `memcpy` to the region. If the file has grown past the
     existing mapping (e.g. after a `fallocate` on a fresh fd), the
     stale mapping is dropped and a remap picks up the new size.
   - `fsync` → `msync(ptr, size, MS_SYNC)` against the mapping. Stronger
     than `fdatasync` — `msync(MS_SYNC)` flushes both data and metadata
     accumulated against the mapping. Falls back to plain
     `fdatasync`/`fsync` if no mapping has been established yet.
   - `fallocate` → `posix.fallocate` synchronously; drops any stale
     mapping. `OperationNotSupported` surfaces uniformly so callers'
     existing `PieceStore.init` → `truncate` fallback path lights up
     normally.
   - `truncate` → `posix.ftruncate` synchronously; drops the mapping
     (next access remaps to the new size).

   7 inline tests pass (init/deinit, timeout, socket, recv-on-socketpair,
   cancel-on-parked-recv, pwrite/pread/fsync round-trip,
   read-past-EOF-returns-zero).

3. **`<commit 3>` — `docs/tests: progress report + STATUS milestone for
   epoll bifurcation`** (this commit). Adds
   `tests/epoll_mmap_io_test.zig` with 4 integration tests covering the
   parts the inline tests don't (remap-on-growth, msync on populated
   mapping, truncate-invalidates-mapping-and-shrinks-EOF). Wires up the
   `test-epoll-mmap-io` step. Adds this report and a STATUS milestone.

## What's actually working in EpollMmapIO

- **Sockets**: `socket`, `connect`, `accept`, `recv`, `send`, `recvmsg`,
  `sendmsg`, `poll`. Identical machinery to `EpollPosixIO` (mirror, not
  shared code — the file-op story is the only difference). Test
  coverage: socketpair recv round-trip with the recv parked on EAGAIN.
- **Timers**: heap of deadlines + `tick` epoll timeout argument.
- **Cancel**: best-effort cancel of registered fd ops (delivers
  `OperationCanceled` to the target's callback) and timer entries.
- **File ops**: full mmap-backed implementation as described above. NOT
  stubbed.

## SimIO wiring decision

**Full** — SimIO drops in cleanly at the comptime selector level. The
`init` signature differs from RealIO's, but no daemon caller currently
uses `backend.RealIO` to instantiate; they all `@import("real_io.zig")`
directly. If/when a daemon caller migrates to `backend.RealIO`, that
caller will need to handle the init-shape mismatch at the call site.
That's a separate piece of work and isn't on this branch's critical
path.

## What was learned

- **No reference uses mmap for data-path file I/O.** I checked libxev,
  tigerbeetle, and ZIO before designing the file-op story. None of them
  use mmap for data files — tigerbeetle goes through io_uring directly,
  libxev's epoll backend stubs file ops, ZIO uses mmap only for
  coroutine stacks. This is a strong signal that mmap-as-file-IO is
  novel and worth treating with caution. The MVP path-of-least-resistance
  (`madvise(MADV_WILLNEED)`, accept page-fault stalls) is reasonable for
  varuna's workload (large, sequential piece reads/writes from a small
  set of files); the fallback (memcpy on a thread pool) is documented
  as a profile-driven follow-up.

- **`MAP_SHARED` + `PROT_WRITE` requires O_RDWR.** First-pass tests
  failed with `error.AccessDenied` until the test fixture was changed
  from `tmp.dir.createFile(name, .{ .truncate = true })` (O_WRONLY by
  default in Zig 0.15.2) to
  `tmp.dir.createFile(name, .{ .truncate = true, .read = true })`
  (O_RDWR). Filed in the inline test comment so future readers don't
  rediscover this.

- **The 6-way enum was straightforward.** With `IoBackend` already
  switching on a build option, adding three new variants and a
  comptime selector was mechanical. Care needed only at the file
  ownership boundary with the parallel engineer — the kqueue stubs
  exist solely to make my branch compile, and will conflict on merge.
  The brief flagged this as expected and trivial to resolve.

## Remaining issues / follow-ups

- **`EpollPosixIO` file ops still `error.Unimplemented`.** Same status
  as the original 2026-04-29 MVP. The follow-up is a worker thread
  pool. Tracked in
  `progress-reports/2026-04-29-epoll-io-mvp.md`.

- **`EpollMmapIO` page-fault thread-pool mitigation.** Today the EL
  thread blocks on a page fault inside the `memcpy`. `madvise(WILLNEED)`
  helps but doesn't eliminate the risk. If profiling shows it matters,
  promote the `memcpy` to run on a thread pool. No daemon path
  exercises this yet (the daemon is hard-wired to `io_uring`'s
  `RealIO`).

- **Daemon callers still hard-wire `real_io.zig`.** The migration to
  `backend.RealIO` is gated on file-op coverage in a non-`io_uring`
  backend. `EpollMmapIO` provides full file-op coverage now, so this
  is technically unblocked — but the daemon-side rewire is its own
  scoped piece of work.

- **Stub `kqueue_posix_io.zig` / `kqueue_mmap_io.zig` will conflict on
  merge with the parallel engineer's real implementations.** Expected.
  Resolution: take theirs.

- **`init` signature divergence.** `RealIO` (io_uring) takes
  `Config{ .entries, .flags }`; the readiness backends and SimIO take
  `(allocator, Config{ .max_completions ... })`. Callers that go
  through `backend.RealIO` need a thin adapter at the call site if /
  when the daemon's hard-wiring to `real_io.zig` is removed.

## Key code references

- `src/io/epoll_posix_io.zig` (rename of `epoll_io.zig`) — POSIX
  variant.
- `src/io/epoll_mmap_io.zig` — mmap variant.
- `src/io/backend.zig` — 6-way comptime selector.
- `src/io/kqueue_posix_io.zig`, `src/io/kqueue_mmap_io.zig` — stubs;
  parallel engineer replaces.
- `tests/epoll_posix_io_test.zig` — renamed integration tests.
- `tests/epoll_mmap_io_test.zig` — new mmap-specific integration tests.
- `build.zig:40-44` — `-Dio=` flag with 6-way help text.
- `build.zig:1145-1190` — `IoBackend` enum.
- `build.zig:152` — `build_full_daemon = io_backend == .io_uring`.

## Validation

```
nix develop --command zig fmt .                                    # clean
nix develop --command zig build                                    # io_uring (default) — green
nix develop --command zig build -Dio=epoll_posix                   # green
nix develop --command zig build -Dio=epoll_mmap                    # green
nix develop --command zig build -Dio=kqueue_posix                  # green (stub)
nix develop --command zig build -Dio=kqueue_mmap                   # green (stub)
nix develop --command zig build -Dio=sim                           # green
nix develop --command zig build test                               # green (default io_uring)
nix develop --command zig build test -Dio=epoll_posix              # green
nix develop --command zig build test -Dio=epoll_mmap               # green
nix develop --command zig build test-epoll-posix-io                # green
nix develop --command zig build test-epoll-mmap-io                 # green
```

`sim_smart_ban_phase12_eventloop_test` shows the same intermittent
flake observed pre-bifurcation (gated on Task #26 per the test name);
unrelated to this work.

## Branch

`worktree-epoll-bifurcation`.

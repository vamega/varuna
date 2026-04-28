# Daemon rewire onto comptime IO backend selector

Date: 2026-04-28
Branch: `worktree-daemon-rewire`
Final commits: 7 bisectable

## What changed and why

The 6-way `IoBackend` enum (`io_uring`, `epoll_posix`, `epoll_mmap`,
`kqueue_posix`, `kqueue_mmap`, `sim`) compiled and the comptime selector
at `src/io/backend.zig` resolved correctly — but the daemon's hot
callers still imported `@import("real_io.zig").RealIO` directly. The
five non-`io_uring` backends were dormant capabilities the daemon
physically could not use.

This rewire routes every daemon caller through `backend.RealIO`, adds
two factory helpers (`initOneshot`, `initEventLoop`) for the per-backend
init signature mismatch, and updates `build.zig` so the daemon binary
actually installs under each production backend.

## Bisectable commits

1. `7f197ce` — `io/backend: add initOneshot helper for backend-agnostic short-lived rings`
2. `1020b8a` — `io,storage: route Category A modules through backend.RealIO alias`
3. `81f0ea6` — `daemon: route torrent_session one-shot init rings through backend.initOneshot`
4. `875586f` — `rpc,daemon: route Category C type imports through backend.RealIO`
5. `61852b4` — `storage: route writer test fixtures through backend.initOneshot`
6. `e563a9a` — `io,build: add initEventLoop helper + split build gating for daemon vs companion tools`
7. (this commit) — `docs: STATUS milestone + progress report for daemon-rewire`

Each commit compiles and passes `zig build test` (default `-Dio=io_uring`).

## What was learned

### `initOneshot` was the easy half — `initEventLoop` was the surprise

The team-lead's plan correctly identified the per-backend init-signature
mismatch as the central problem and prescribed a comptime-switching
factory in `backend.zig`. The pre-spec was almost right but had
**Config field collisions**: it suggested `RealIO.init(allocator, .{ .max_completions = 16, .file_pool_workers = 4 })`
for `kqueue_posix`, but `KqueuePosixIO.Config` doesn't have
`max_completions` — it has `timer_capacity`, `pending_capacity`,
`change_batch`, `file_pool_workers`, `file_pool_pending_capacity`.
Same shape mismatch for `kqueue_mmap` (`file_mapping_capacity`,
`advise_willneed`, no `max_completions`). Fixed by reading each
backend's `pub const Config` and matching fields exactly
(Pattern #14 — verify before writing).

The bigger surprise was `EventLoopOf(IO).initBare`. After the Category A
swap of `event_loop.zig`'s alias to `backend.RealIO`, `initBare`'s
hard-coded `RealIO.init(.{ .entries = 256, .flags = ... })` became a
type-checked compile error under `-Dio=epoll_posix` because the
io_uring-specific Config fields don't exist on `EpollPosixIO.Config`.
This wasn't in the team-lead's commit-by-commit plan but is a forced
cascade of the alias swap. Solution: a parallel `initEventLoop` helper
(longer-lived, larger-sized than `initOneshot`) that branches on the
selected backend the same way. Under `-Dio=io_uring` the io_uring
branch is byte-equivalent to the prior call (256 entries +
COOP_TASKRUN|SINGLE_ISSUER flags).

### Companion-tool cascade

Rewiring `PieceStore = PieceStoreOf(backend.RealIO)` and
`ApiServer { io: *backend.RealIO }` propagated through to
`src/app.zig` (varuna-tools), `src/perf/workloads.zig` (varuna-perf),
and `src/storage/verify.zig` (also varuna-tools). Those files still
construct `real_io.RealIO` directly — under `-Dio=epoll_posix` they
fail to compile because they pass `*real_io.RealIO` where now
`*EpollPosixIO` is expected.

Two options:

  - Rewire app.zig / verify.zig / workloads.zig to also use `backend`.
    The team-lead explicitly preferred not to: AGENTS.md exempts
    `varuna-tools` and benchmarks from the io_uring policy (they're
    allowed std-lib I/O), and the team-lead noted "preserves the
    policy boundary."
  - Skip the companion executables under non-io_uring backends.

Picked option 2. `build.zig`'s previous single flag splits into
`build_daemon` (varuna + varuna-ctl, gated on non-sim) and
`build_companion_tools` (varuna-tools + varuna-perf, gated on
io_uring). `varuna-ctl` itself has no IO references and builds under
all backends — a small bonus.

### Pattern #10 (lazy method compilation) held

Under `-Dio=io_uring` (default), the `switch (selected)` in
`initOneshot` / `initEventLoop` only compiles the io_uring branch.
The others reference `RealIO.init(allocator, .{...})` which would be
a type error if compiled, but they never are. Same lazy-compilation
shape that lets the existing `pub const RealIO = switch (...)` selector
work — verified by clean `zig build` under default.

### Test flakiness, not regressions

During iteration, `tests/sim_smart_ban_phase12_eventloop_test.zig`
("phase 2B: disconnect-rejoin one-corrupt-block") and
`tests/sim_multi_source_eventloop_test.zig` ("multi-source: peer
disconnect mid-piece") each failed once across ~7 runs. Re-running
between commits without code changes also failed intermittently on
unrelated tests (`recheck_test.AsyncRecheckOf(SimIO): all pieces
verify`). Confirmed pre-existing flakes by running 3 back-to-back
test suites: 2/3 passed, 1/3 failed on a different test each time.
Not in daemon-rewire scope.

## Validation results

Linux native (`x86_64-linux-gnu`):

  - `zig build`                    — PASS (default io_uring)
  - `zig build -Dio=epoll_posix`   — PASS (NEW: daemon binary)
  - `zig build -Dio=epoll_mmap`    — PASS (NEW: daemon binary)
  - `zig build -Dio=kqueue_posix`  — FAIL¹
  - `zig build -Dio=kqueue_mmap`   — FAIL¹
  - `zig build test`               — PASS (default; ignoring sim flake)

¹ `kqueue_*_io.zig` references `std.c.EVFILT.READ`, which is undefined
on Linux (kqueue is BSD/Darwin). Pre-existing in those backends — not
introduced by daemon-rewire. The macOS cross-compile target
(`-Dtarget=aarch64-macos -Dio=kqueue_*`) fails on three unrelated
upstream issues (`std.os.linux.IoUring.zig` Linux-only enum mismatches
leaking into the macOS build, `huge_page_cache.zig` MAP type
mismatches, SQLite TBD parsing). Those are broader macOS-support work,
not daemon-rewire scope.

## What `zig build -Dio=epoll_posix` produces now

Before this rewire: only `varuna_mod` + the per-backend test bridges.
No installed binaries.

After this rewire:

  ```
  zig-out/bin/varuna           # daemon backed by EpollPosixIO
  zig-out/bin/varuna-ctl       # RPC client (IO-agnostic)
  ```

The daemon's hot paths now go through `EpollPosixIO`'s epoll readiness
loop and `PosixFilePool` worker thread pool for file ops (per the
2026-04-30 file-thread-pool milestone). Companion tools (`varuna-tools`,
`varuna-perf`) are not installed under non-io_uring builds — their
io_uring-only call sites stay where they are under the AGENTS.md
exemption.

## Init signature collisions resolved

`backend.initOneshot(allocator)` (small short-lived ring):

  | Backend       | init call                                                         |
  |---------------|-------------------------------------------------------------------|
  | io_uring      | `RealIO.init(.{ .entries = 16 })`                                 |
  | epoll_posix   | `RealIO.init(allocator, .{ .max_completions = 16, .file_pool_workers = 4 })` |
  | epoll_mmap    | `RealIO.init(allocator, .{ .max_completions = 16 })`              |
  | kqueue_posix  | `RealIO.init(allocator, .{ .timer_capacity = 16, .file_pool_workers = 4 })`  |
  | kqueue_mmap   | `RealIO.init(allocator, .{ .timer_capacity = 16 })`               |
  | sim           | `@compileError(...)`                                              |

`backend.initEventLoop(allocator)` (long-lived production ring):

  | Backend       | init call                                                         |
  |---------------|-------------------------------------------------------------------|
  | io_uring      | `RealIO.init(.{ .entries = 256, .flags = COOP_TASKRUN | SINGLE_ISSUER })` |
  | epoll_posix   | `RealIO.init(allocator, .{ .max_completions = 1024, .file_pool_workers = 4 })` |
  | epoll_mmap    | `RealIO.init(allocator, .{ .max_completions = 1024 })`            |
  | kqueue_posix  | `RealIO.init(allocator, .{ .timer_capacity = 256, .pending_capacity = 4096, .file_pool_workers = 4 })` |
  | kqueue_mmap   | `RealIO.init(allocator, .{ .timer_capacity = 256, .pending_capacity = 4096 })` |
  | sim           | `@compileError(...)`                                              |

Both helpers `@compileError` under `-Dio=sim` because the daemon binary
isn't installed under sim builds; SimIO instances are constructed
directly by tests with their own seeded fault config.

## Remaining issues / follow-up

- Native Linux `zig build -Dio=kqueue_posix|kqueue_mmap` is broken at
  the `kqueue_*_io.zig` source level (uses `std.c.EVFILT.*` which is
  undefined on Linux). Pre-existing. Either gate kqueue backends to
  Darwin targets only, or shim the constants behind a comptime alias.
  Out of daemon-rewire scope; surface for the kqueue engineer.

- macOS cross-compile (`-Dtarget=aarch64-macos`) is broken at
  `huge_page_cache.zig` (MAP_HUGETLB / MAP_POPULATE Linux flags) and
  inside the standard library (`std.os.linux.IoUring.zig` references
  Linux errno enums even when the build target is macOS). Out of
  daemon-rewire scope.

- The companion tools (`varuna-tools`, `varuna-perf`) staying pinned
  to io_uring is intentional but means their inline tests don't
  exercise the alternate backends. If we ever want to verify
  `app.zig`'s recheck path under `epoll_posix`, that's a future rewire.

## Key code references

- `src/io/backend.zig:131-180` — `initOneshot` + `initEventLoop` factories
- `src/io/event_loop.zig:402-407` — `initBare` now uses `backend.initEventLoop`
- `src/daemon/torrent_session.zig:1272, 2023` — `PieceStore.init`
  one-shot rings via `backend.initOneshot`
- `src/storage/writer.zig:732, 771, 806, 838` — test fixtures rewired
- `src/rpc/server.zig:862, 869, 921` — test fixtures rewired
- `build.zig:158-173` — `build_daemon` vs `build_companion_tools` split

# EpollIO / KqueueIO design survey — 2026-04-27

Research-only round (epoll-research). Produced `docs/epoll-kqueue-design.md`,
a strategic-guidance document for a future implementation engineer. No source
code or tests modified.

Branch: `worktree-epoll-research`.

## What changed

- Added `docs/epoll-kqueue-design.md` (~3.1k words, five sections + appendix).
- Added a "Last Verified Milestone" entry to `STATUS.md` referencing the
  document and the headline recommendations.
- This progress report.

## What was learned

### libxev's epoll backend is the rougher of the pair

The libxev kqueue backend is well-organized and battle-tested; the epoll one
carries an explicit author note: _"this backend is a bit of a mess. It is
missing features and in general is in much poorer quality than all of the
other backends."_ Implication for varuna: read kqueue first as the canonical
pattern (intrusive queue + per-completion threadpool flag + heap-of-timers),
then port the same skeleton back to epoll. Doing the reverse — reading the
epoll backend first — would teach habits that don't generalize.

### Heap-of-timers, not native primitives, on both backends

libxev's kqueue backend deliberately avoids `EVFILT_TIMER`, with a comment
calling out _"avoids a lot of syscalls in the case where there are a LOT of
timers."_ The epoll equivalent (timerfd-per-timer, or arming a single
heap-driven timerfd) follows the same logic. varuna routinely has hundreds of
peer/timer interactions; the heap-of-deadlines pattern is the right default.
This is the single most copy-paste-able insight from the survey.

### Unconditional thread-pool offload for file ops

Both libxev and ZIO route every file-system op through a worker thread pool
on epoll/kqueue. ZIO's `BackendCapabilities` table is the cleanest expression
of this: per-op declared capability, automatic fall-through to the pool for
non-capable ops. That's the API surface to copy if/when varuna adds the
backends. Tigerbeetle's choice to fsync inline on the event-loop thread
**doesn't** generalize — they have a workload that makes it OK; varuna doesn't.

### macOS quirks are a real budget item

The ones worth pre-flagging on the implementation side:
- No `accept4`, no `SOCK_NONBLOCK` flag, no `SOCK_CLOEXEC` flag — every
  socket needs follow-up `fcntl` calls.
- `fallocate` has no Linux-equivalent semantic; `fcntl(F_PREALLOCATE)` is
  best-effort and doesn't reserve blocks deterministically. `PieceStore.init`'s
  existing `setEndPos` fallback (deferred from the 2026-04-27 storage-IO
  refactor) is the natural escape hatch.
- `IPV6_V6ONLY` defaults differ; if the daemon's listen path doesn't already
  set it explicitly, that becomes a porting bug.
- `fsync` vs `F_FULLFSYNC` — irrelevant for a developer build, mandatory if
  KqueueIO is ever production-grade.

### The contract holds

No signature changes are needed on `src/io/io_interface.zig`. Both backends
fit the existing async-shape model. The only semantic weakening is `cancel`
for thread-pool ops, which the contract already documents as best-effort.

## Surprises during the survey

1. **`reference-codebases/libxev|zio|tigerbeetle` initially appeared empty.**
   The directories under `.claude/worktrees/epoll-research/reference-codebases/`
   are empty in the worktree, but the canonical ones at
   `/home/madiath/Projects/varuna/reference-codebases/` are populated as
   submodules. Used the populated ones. Worth flagging because future research
   tasks pinned to worktrees may hit the same gotcha — submodules don't
   automatically clone into worktrees.

2. **The contract has no `close`/`shutdown` op.** The team-lead brief mentioned
   `shutdown` and `close` as ops; the actual contract uses synchronous
   `closeSocket()` (just `posix.close`) and has no shutdown op at all. This
   is fine for both backends — close is a synchronous syscall in either model.
   Documented in the design doc per actual contract surface, not the brief.

3. **The contract uses `timeout` (not `timer`) and `accept` carries a
   `multishot: bool`** rather than having a separate `accept_multishot` op.
   Same shapes ultimately, but the doc mirrors the actual op-name vocabulary
   for searchability.

4. **Storage init's one-shot ring** (per `progress-reports/2026-04-27-storage-io-contract.md`)
   carries over cleanly to a one-shot Epoll/KqueueIO, with the caveat that
   the file-op thread pool needs to be present for the init's fallocate to
   complete. Worth pre-flagging because the engineer may want to cache the
   thread-pool reference rather than spin up a new one per torrent init.

## Remaining issues / follow-ups

1. **Implementation itself.** Out of scope here. Recommended order: scaffolding →
   socket ops → timeout → thread-pool wiring → file ops → smoke tests. ~1
   work-week for minimum-viable EpollIO.

2. **`TruncateOp` on the contract** (deferred from the storage-IO round). On
   EpollIO/KqueueIO this becomes load-bearing: without `fallocate`, the
   `setEndPos` fallback path runs on every torrent and needs to be contract-routed
   so fault-injection still works. ~1-2 hours.

3. **c-ares-on-readiness DNS path.** Worth a separate research round if DNS
   becomes a bottleneck on EpollIO/KqueueIO. The proof-of-concept in
   `~/projects/c-ares` targets io_uring; epoll/kqueue would use c-ares's
   built-in socket-callback hooks instead.

4. **CI matrix.** If/when the implementation lands, GitHub Actions needs a
   macOS runner column for the KqueueIO build path. Not urgent.

## Key code references

- `src/io/io_interface.zig:65-93` — `Operation` union as the surface to map.
- `src/io/io_interface.zig:194-215` — `Result` union; one variant per op.
- `src/io/real_io.zig:184-305` — RealIO's per-method submission shape, the
  template for both new backends.
- `progress-reports/2026-04-27-storage-io-contract.md:81-127` —
  `PieceStore.init` pattern that EpollIO/KqueueIO inherits.
- `reference-codebases/libxev/src/backend/kqueue.zig:1572-1668` — the
  cleanest reference Operation union.
- `reference-codebases/zio/src/ev/loop.zig:704-778` — the
  `submitFileOpToThreadPool` dispatch, model for varuna's file-op fallback.
- `reference-codebases/tigerbeetle/src/io/darwin.zig:146-170` — the
  one-shot kqueue registration pattern (`EV_ADD | EV_ENABLE | EV_ONESHOT`),
  recommended for first-cut KqueueIO.

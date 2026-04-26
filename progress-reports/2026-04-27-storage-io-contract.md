# Storage IO Contract — fallocate + fsync via the Contract — 2026-04-27

Track (storage-io-engineer): routed `src/storage/writer.zig`'s direct
syscall paths through the IO contract. PieceStore's one-time
pre-allocation (`linux.fallocate` × 3 call sites) and its sync method
(`PieceStore.sync(io: *real_io.RealIO)`) now go through
`self.io.fallocate` / `self.io.fsync` — both BUGGIFY-injectable from
SimIO and forward-compatible with the queued EpollIO/KqueueIO
research round.

Four coherent commits, all bisectable, all green at HEAD. Test count:
**704 → 713 (+9)**. `zig build`: clean. `zig fmt .`: clean. Daemon
binary: builds.

Branch: `worktree-storage-io-engineer`.

## Commits

1. `c1dba64` — **`io: add fallocate op to contract; fault knobs for fallocate + fsync`**
   New `FallocateOp` + `Result.fallocate` variant on `io_interface.zig`.
   `RealIO.fallocate` wired to `IORING_OP_FALLOCATE` (kernel ≥5.6,
   well below varuna's runtime floor) — mirrors the existing fsync
   wiring exactly. `SimIO.fallocate` schedules synchronous completion
   through the heap; new `FaultConfig.fallocate_error_probability`
   (delivers `error.NoSpaceLeft`) and `FaultConfig.fsync_error_probability`
   (delivers `error.InputOutput`) round out the BUGGIFY surface.
   `buggifyResultFor` + `cancelResultFor` extended for the new variant.
   704 → 704 tests (mechanical contract addition; behaviour unchanged).

2. `fdd2b79` — **`tests: SimIO algorithm tests for fallocate + fsync ops`**
   Five tests in `tests/sim_socketpair_test.zig`:
   - fallocate succeeds by default
   - fallocate fault probability 1.0 → `error.NoSpaceLeft`
   - fallocate fault probability 0.5 fires roughly half the time
   - fsync fault probability 1.0 → `error.InputOutput`
   - `injectRandomFault` picks fallocate from the heap and rewrites
     its result (BUGGIFY harness path)
   704 → 709 tests (+5).

3. `efced8e` — **`storage: parameterise PieceStore over the IO backend`**
   `PieceStoreOf(comptime IO: type)` returning the existing struct,
   with the disk-syscall paths replaced by contract calls.
   `PieceStore = PieceStoreOf(RealIO)` alias preserves the daemon
   surface — daemon-side callers (`torrent_session.zig`, `app.zig`,
   `verify.zig`) keep writing `PieceStore` and don't recompile their
   method bodies (pattern #10).
   `sync` drops its `*real_io.RealIO` parameter — `self.io` is
   already typed `*IO` per instantiation. Callers go from
   `store.sync(&io)` to `store.sync()`.
   709 → 709 tests (mechanical refactor).

4. `b3ab4d5` — **`tests: PieceStoreOf(SimIO) integration tests`**
   Four tests in a new `tests/storage_writer_test.zig` (wired into
   `build.zig` as `test-storage-writer` alongside the existing
   `test-recheck` / `test-metadata-fetch` steps):
   - happy path: init creates 2 files via real `createFile`, drains
     2 fallocate completions through SimIO; sync drains 2 fsync
     completions; both succeed.
   - fault-injected fallocate → `NoSpaceLeft` propagates from init.
   - fault-injected fsync → `InputOutput` propagates from sync().
   - `do_not_download` priority skips fallocate entirely (no contract
     call submitted, so a 100% fallocate-fault knob doesn't fire).
   709 → 713 tests (+4).

## Methodology notes

### Pattern #15 — read existing invariants first

Mirrored the AsyncRecheck (commit `1394a20`) and AsyncMetadataFetch
(commit `69c9287`) refactors exactly:
- Same `pub fn FooOf(comptime IO: type) type` shape.
- Same `pub const Foo = FooOf(RealIO)` daemon alias.
- Same caller-owned-Completion shape for the new op
  (`FallocateOp` next to `FsyncOp` in `io_interface.zig`).
- Fault knobs follow the existing `read_error_probability` /
  `write_error_probability` shape, including the `buggifyResultFor`
  / `cancelResultFor` companion entries.

No new design decisions on the IO contract itself.

### Pattern #14 — investigation discipline (the `init` IO parameter)

The team-lead brief speculated `PieceStore.init` "probably already
takes an `*IO`". It didn't. Three call sites needed updating to pass
one in:

- `src/app.zig:292` (`varuna inspect`/`verify` CLI) — straightforward,
  spins up a one-shot RealIO ring just for init.
- `src/daemon/torrent_session.zig:1264` (`doStartBackground`) — runs
  on a background thread *before* event-loop integration. This was
  the awkward case: the worker has no long-lived ring of its own,
  so we spin up a small one-shot RealIO (`entries=16`) for the
  duration of init. Cost: one `io_uring_setup` + one teardown per
  torrent (~tens of µs); benefit: every disk syscall is uniformly
  contract-routed and BUGGIFY-injectable.
- `src/daemon/torrent_session.zig:2011` (post-metadata-fetch path) —
  runs on the event-loop thread. Could in principle use `&sel.io`
  (the shared event-loop ring), but using a separate one-shot ring
  there too avoids re-entrancy concerns: pumping the shared ring
  via `io.tick(1)` would deliver other peers' CQEs during init.
  One-shot ring keeps the semantic the previous synchronous
  `linux.fallocate` had — block until our fallocate(s) land, then
  return.

### Pattern #14 — keep the ftruncate fallback

The pre-refactor code had a `fallocate(...) catch { try setEndPos(...); }`
fallback for filesystems that don't support fallocate (tmpfs <5.10,
FAT32, certain FUSE FSes). The brief asked me to decide whether to
keep it.

**Kept.** Rationale: real users may have torrent download dirs on
network mounts or unusual filesystems; preserving the historical
behaviour avoids surprises on first deployment. The fallback now
fires only on `error.OperationNotSupported` (the historical
filesystem-portability case); other errors (`NoSpaceLeft`, `IoError`,
…) propagate.

The fallback uses `file.setEndPos(...)` (synchronous `ftruncate`)
rather than a new `truncate` op on the contract:
- `IORING_OP_FTRUNCATE` was added in Linux 6.9 (~2024), well above
  varuna's kernel floor.
- The fallback is a rare, one-time path on filesystems that can't
  do fallocate at all. EpollIO/KqueueIO porting will need to handle
  this either by punting fallocate to a thread internally, or by
  growing a `truncate` op when the kernel floor rises. Filed as a
  follow-up rather than chased here.

### Pattern #10 — lazy method compilation lets the migration ship

Daemon-side callers (`torrent_session.zig`, `app.zig`, `verify.zig`)
stayed on the `PieceStoreOf(RealIO)` alias without recompiling their
method bodies. Only the SimIO test paths in commit `b3ab4d5` force
the second instantiation when those tests actually call into the
state machine.

`zig build` (full daemon binary): clean. `zig build test --summary all`:
713/713 passed. Verified the daemon path picks up the
`PieceStoreOf(RealIO)` alias unchanged.

### Pattern #8 — tests pass at every commit

Four bisectable commits, each compiling and passing the full test
suite:

1. `c1dba64` — contract addition + fault knobs. 704 → 704.
2. `fdd2b79` — SimIO algorithm tests. 704 → 709 (+5).
3. `efced8e` — PieceStoreOf(IO) refactor + 10 caller updates. 709 → 709.
4. `b3ab4d5` — PieceStoreOf(SimIO) integration tests. 709 → 713 (+4).

If any commit regresses something, `git bisect` lands on it cleanly.

The brief asked for 5 commits but the contract additions
(`io_interface` + `RealIO` + `SimIO`) had to be combined — Zig's
exhaustive switch statements on `c.op` mean adding the variant to
the union without updating both backends' dispatch / resubmit / op
maps would fail to compile.

## Files touched

- `src/io/io_interface.zig` — `FallocateOp` + `Result.fallocate`
  variant.
- `src/io/real_io.zig` — `RealIO.fallocate` (`IORING_OP_FALLOCATE`),
  `buildResult` extended.
- `src/io/sim_io.zig` — `SimIO.fallocate`, fault knobs
  (`fallocate_error_probability`, `fsync_error_probability`),
  `cancelResultFor` + `buggifyResultFor` companion entries.
- `src/storage/writer.zig` — `PieceStoreOf(IO)` + alias; `init`
  takes `*IO`; `sync` drops its parameter; ftruncate fallback
  preserved on `error.OperationNotSupported`.
- `src/app.zig` — one-shot RealIO around `varuna inspect/verify`
  init.
- `src/daemon/torrent_session.zig` — one-shot RealIO around both
  `PieceStore.init` call sites (background worker + post-metadata
  fetch).
- `src/storage/verify.zig` — test fixture updated.
- `tests/sim_socketpair_test.zig` — 5 algorithm tests for the
  new ops.
- `tests/storage_writer_test.zig` — new file, 4 integration tests
  for `PieceStoreOf(SimIO)`.
- `tests/recheck_test.zig`, `tests/sim_smart_ban_eventloop_test.zig`,
  `tests/sim_smart_ban_phase12_eventloop_test.zig`,
  `tests/sim_swarm_test.zig`,
  `tests/sim_multi_source_eventloop_test.zig`,
  `tests/transfer_integration_test.zig` — pass `*IO` to
  `PieceStore.init`; `transfer_integration_test.zig` updated to
  call `store.sync()` (no arg).
- `build.zig` — `test-storage-writer` step.
- `STATUS.md` — Last Verified Milestone entry; Next follow-ups.

## Follow-ups (not in scope for this round)

### 1. `writePiece` / `readPiece` migration to the IO contract
These still use blocking `posix.pwrite` / `posix.pread`. Migrating
them is a larger refactor — they're called per-piece on every
hash-pass and would need to interleave with the ongoing event loop
(the synchronous loop blocks the EL today, but is short).
Estimated 1-2 days. Adjacent to but not blocking the EpollIO/KqueueIO
research round.

### 2. `truncate` op on the IO contract
The `setEndPos` fallback for `error.OperationNotSupported` filesystems
remains a synchronous syscall outside the contract. Adding
`TruncateOp` + `RealIO.truncate` (via `IORING_OP_FTRUNCATE`, kernel
≥6.9 — likely above varuna's floor) + `SimIO.truncate` would close
the asymmetry. Not urgent: the fallback path is a rarely-hit
defensive measure on edge-case filesystems. EpollIO/KqueueIO porting
will need it (or an equivalent thread-pool bridge). Estimated 1-2 hours.

### 3. Live-pipeline BUGGIFY harness for `PieceStoreOf(SimIO)`
Wrap `tests/storage_writer_test.zig` with the canonical BUGGIFY
shape — per-tick `injectRandomFault` + per-op `FaultConfig` over 32
seeds. Catches recovery paths the foundation tests can't see (e.g.
errdefer cleanup of partially-opened files when the 2nd of 5
fallocates fails; sync's pending-counter under fsync error storms).
Reference shape: `tests/recheck_live_buggify_test.zig`. Estimated
0.5 day.

### 4. Background-thread `init_io` cost optimisation
Currently each torrent spins up its own one-shot RealIO ring for
PieceStore.init. For a daemon with many torrents being added in
quick succession, the per-torrent `io_uring_setup` syscall is
non-zero. A shared "init pool" of pre-warmed rings, or threading
a long-lived `*RealIO` through `TorrentSession` (e.g. the daemon's
shared event-loop ring with explicit drain semantics), would
eliminate the per-torrent cost. Not urgent — the cost is tens of µs
per torrent; only a concern at very-high torrent-add rates.
Estimated 1 day if needed.

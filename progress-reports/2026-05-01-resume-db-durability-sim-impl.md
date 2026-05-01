# 2026-05-01 — Resume-DB durability vs. fsync barrier: sim impl (steps 1+2)

## Summary

Follow-up to
[`progress-reports/2026-05-01-resume-db-durability-sim-eval.md`](2026-05-01-resume-db-durability-sim-eval.md).
That eval scoped a SimIO durability extension + a single-seed bug
repro and stopped before implementing. This round lands both in
the worktree (no merge to main):

1. **`sim: add per-fd dirty/durable file model + crash op`** — SimIO
   now models the kernel pagecache barrier. Writes extend a per-fd
   `pending` byte layer; reads return the union of `durable`
   overlaid with `pending` (most-recent byte wins); fsync (success
   path) promotes the dirty pending region into `durable` and clears
   the dirty mask; fsync (fault path) leaves pending untouched; a
   new test-only `crash()` method drops every fd's pending bytes.
   `setFileBytes` now seeds `durable` and copies its input (the
   no-copy contract is gone — internal callers already kept
   buffers alive, so the loosening is safe). New test file
   `tests/sim_io_durability_test.zig` exercises the model directly
   through `zig build test-sim-io-durability` (12 algorithm-level
   tests, all pass).

2. **`tests: resume-DB durability vs. fsync barrier repro`** — single
   deterministic seed end-to-end repro at
   `tests/resume_durability_bug_test.zig`. Drives the production
   write path through `PieceStoreOf(SimIO).writePiece`, commits the
   piece into a `SimResumeBackend` exactly the way `flushResume`
   does (no fsync barrier), calls `sim.crash()` in the gap, then
   loads the bitfield from the backend (the `loadCompletePieces`
   "trust the resume DB" path) and reads the durable bytes through
   SimIO. Asserts the bug: DB says piece 0 complete; durable
   storage holds zeros. Wired through `zig build
   test-resume-durability-bug` and intentionally **excluded** from
   the default `zig build test` aggregate so CI stays green until
   the production fix lands.

The production fix (step 3) is **not** implemented per the brief.

## What changed

### SimIO (src/io/sim_io.zig)

- New `SimFile` struct (`sim_io.zig:271-380`) carrying:
  - `durable: ArrayListUnmanaged(u8)` — bytes that have been fsynced.
  - `pending: ArrayListUnmanaged(u8)` — bytes accepted by `write` but
    not yet fsynced.
  - `pending_dirty: DynamicBitSetUnmanaged` — bit-per-byte mask
    indicating which `pending[i]` entries are overlays.
  - Helpers: `readUnion`, `promotePending`, `dropPending`,
    `ensurePending`.
- `SimIO.file_state: AutoHashMap(fd, SimFile)` replaces the old
  `file_content: AutoHashMap(fd, []const u8)` (`sim_io.zig:430-456`).
- `SimIO.deinit` now iterates and frees per-fd byte buffers
  (`sim_io.zig:498-507`).
- `SimIO.setFileBytes` copies bytes into the `durable` layer
  (`sim_io.zig:521-538`). Loosened contract; existing callers
  unaffected.
- `SimIO.crash` (new) drops every fd's pending bytes
  (`sim_io.zig:543-546`).
- `SimIO.write` now extends the per-fd pending layer and marks the
  written byte range dirty (`sim_io.zig:1058-1099`). Acceptance is
  unchanged (full `op.buf.len` returned on success).
- `SimIO.fsync` success path promotes pending → durable; fault path
  leaves pending untouched (`sim_io.zig:1102-1129`).
- `SimIO.read` returns `readUnion(off, op.buf)` so reads see
  pending overlay + durable backing (`sim_io.zig:1041-1051`).

### New tests

- `tests/sim_io_durability_test.zig` (~290 lines, 12 tests). Covers:
  write-before-fsync visibility, fsync promote, crash-drops-pending,
  setFileBytes-seeds-durable, interleaved overlapping writes,
  partial-region fsync, fsync fault path leaves pending, read past
  visible length, gap reads as zero, no-op crash, copy semantics,
  per-fd isolation.
- `tests/resume_durability_bug_test.zig` (~290 lines, 1 test). The
  bug repro. Walks the production write→commit→crash→reboot
  sequence and asserts DB/storage divergence.

### build.zig

- `test-sim-io-durability` step (in default `test` aggregate).
- `test-resume-durability-bug` step (intentionally NOT in default
  `test` aggregate, with comment explaining why).

## Test output

Bug repro fires with the expected divergence:

```
test-resume-durability-bug
+- run test 0/1 passed, 1 failed
error: 'resume_durability_bug_test.test.resume DB durability bug:
       row committed before fsync survives crash, bytes don't' failed:
   RESUME-DB DURABILITY BUG REPRODUCED:
    resume DB says piece 0 complete: true
    durable storage has correct bytes: false
    actual_bytes:   00000000
    expected_bytes: 44415441
tests/resume_durability_bug_test.zig:287:9: 0x107ae2b
        return error.ResumeDbDurabilityBugReproduced;
```

`44415441` is the hex of "DATA" — the bytes that were written into
the pagecache and committed to the resume DB but never made it to
durable storage before the crash.

`zig build`, `zig build test-sim-io-durability`, `zig build
test-sim-io`, `zig build test-recheck`, `zig build
test-storage-writer`, `zig build test-storage-writer-live-buggify`
all pass clean. (Full `zig build test` aggregate run in progress at
report-write time; updates appended below if a regression appears.)

## What was learned

- **`std.fmt.fmtSliceHexLower` was removed** from Zig 0.15.2's stdlib
  shape — the test's first cut tried to use it for the divergence
  diagnostic and the build flagged it. Replaced with explicit
  per-byte `{x:0>2}` formatting. Worth noting for future progress
  reports under this Zig version.

- **`PieceStoreOf(SimIO).readPiece` surfaces
  `error.UnexpectedEndOfFile` when the durable layer is shorter than
  the requested span.** This is correct — production `pread` does
  the same when the file length is below the read offset+len. The
  bug repro had to switch to a raw `sim.read(...)` call to get the
  pre-asserted byte content rather than the error.

- **`SimResumeBackend` is exactly the right backend for this bug.**
  It commits to its in-memory tables under a single mutex. That's
  the same observability you get from a real SQLite WAL commit —
  the bug is *not* a SQLite reliability issue; it's that the daemon
  doesn't gate the commit on the fsync barrier. Picking
  `SimResumeBackend` keeps the bug isolated from any SQLite
  fault-injection noise.

- **The eval's design pass was largely accurate.** The flat
  `ArrayListUnmanaged(u8)` per layer + `DynamicBitSetUnmanaged`
  dirty mask shape from §2.1 of the eval landed unchanged. The one
  concrete change vs. the eval: the eval suggested the caller could
  keep the no-copy `setFileBytes` contract, but it's strictly
  cleaner to copy now that SimIO owns the storage anyway —
  durable and pending layers grow independently of the seed slice's
  lifetime, and existing callers passed string literals or stack
  buffers that they happened to keep alive long enough for the
  no-copy contract to hold. Documented the loosening in the
  `setFileBytes` doc-comment.

- **`crash()` is a single line per fd.** Once `pending` is a
  separately-managed buffer behind a dirty mask, "drop every
  pending write" is `pending_dirty.unsetAll()` +
  `pending.clearRetainingCapacity()`. The retained capacity is
  intentional — a power-loss in real life leaves pagecache memory
  free for the next allocation; the sim mirrors that and keeps the
  fast path zero-alloc on subsequent writes.

## Remaining issues / follow-up

- **Step 3 (production fix) landed on rebased main as
  `aee2f09 storage: gate resume completions on durability`.** The
  branch was rebased onto that commit; the now-stale single-seed
  bug repro was replaced with the 32-seed BUGGIFY harness described
  in the rebase + harness conversion section below.

## Rebase + harness conversion (2026-05-01 follow-up)

After the production fix landed, the original
`tests/resume_durability_bug_test.zig` was stale on two counts: it
asserted divergence (now fixed) and it bypassed the gate by calling
`db.markCompleteBatch(...)` directly rather than driving
`TorrentSession.persistNewCompletions`'s real path through
`drainDurableResumePieces`. Replaced it with
`tests/resume_durability_buggify_test.zig`, a 32-seed harness that
drives the production gate end-to-end.

### Shape

Per seed: boot `EventLoopOf(SimIO)` + `addTorrent` against a
synthetic 5-piece × 4-byte single-file torrent. Per piece, allocate
the canonical content, call `el.createPendingWrite(...)`, submit
`el.io.write(...)` with `peer_handler.diskWriteCompleteFor(EL)` —
the same path `peer_policy.processHashResults` uses on the real
hash-success branch. The write CQE fires
`handleDiskWriteResult` → `pt.completePiece` →
`markPieceAwaitingDurability`. At configured ticks the test calls
`el.submitTorrentSync(tid, false)` (mirrors the periodic 30 s sync
timer) and `el.drainDurableResumePieces(...)` →
`db.markCompleteBatch(...)` (mirrors `persistNewCompletions` +
`flushResume`).

The seeded RNG picks a `CrashWhen` variant — `none`,
`pre_first_sweep`, `mid_sweep`, or `post_sweep` — and a tick to
fire `sim.crash()` from the SimIO `pre_tick_hook`. The hook fires
once per seed, dropping every fd's pending bytes (un-fsynced
pagecache). After the test's drive loop ends, the invariant check
loads the DB's claimed-complete bitfield and reads each piece's
bytes through `el.io.read(...)` — which after `crash()` returns
only durable layer content. The strong assertion: every piece the
DB claims must have matching durable bytes.

### 32-seed summary output

```
RESUME-DB DURABILITY BUGGIFY summary: 32/32 seeds held invariant
  crash distribution: none=10 pre_first_sweep=9 mid_sweep=7 post_sweep=6
  aggregate: db_rows=74 durable_pieces=106
```

All 32 seeds held the invariant. Crash distribution is healthy —
all four buckets land hits, and the vacuous-pass guards in
`aggregateAndAssert` enforce minimum coverage per bucket so a
future seed-list regression that flattened the distribution would
fail loudly. `db_rows < durable_pieces` is the expected ordering:
the gate ensures rows are a subset of durable pieces. Reverse
direction (durable bytes present but DB doesn't claim them) is
fine — daemon would recheck or re-download.

### Headline finding

No regression. Every seed × crash variant satisfied the strong
invariant on top of the production fix. The mid-sweep variant in
particular exercises the corner case where `pre_tick_hook` fires
`sim.crash()` at the top of the same tick that the in-flight
fsync's `promotePending` callback would run — `crash()` runs
first, `promotePending` then has nothing dirty to promote, the
fsync result is still success, and the gate's
`durable_resume_pieces` queue gets populated with pieces whose
bytes are no longer durable. The test driver doesn't drain past
the crash point so those entries never reach the DB — exactly the
behaviour the production gate guarantees.

### Design tradeoffs

- **No EL reboot on "restart".** The brief allowed either a full
  restart-against-the-same-SimIO or the simpler "check post-crash
  state directly" model. Picked the latter: instantiating a fresh
  EL against the same `*SimIO` would have required reconstructing
  too much daemon state (PieceTracker, resume_pieces bitfield,
  TorrentContext shared_fds) for negligible extra coverage. The
  invariant under check is identical either way:
  `db.loadCompletePieces` is a subset of pieces with durable
  bytes.

- **`SimResumeBackend` instead of `SqliteBackend`.** Same call
  surface (`markCompleteBatch` / `loadCompletePieces`); the gate
  lives in `EventLoopOf(SimIO)`, not the backend. SimResumeBackend
  keeps the test free of SQLite link dependencies and makes
  determinism trivially seedable.

- **No SimHasher.** The test drives `handleDiskWriteResult`
  directly with the canonical content, bypassing hash submission.
  Hash verification is orthogonal to the durability gate, and the
  hasher path adds wall-clock-dependent thread scheduling that
  would compete with the deterministic `pre_tick_hook` crash
  timing. Future end-to-end coverage that exercises both hashing
  and the durability barrier together can layer on top.

- **5 pieces × 4 bytes.** Small enough that the per-seed run is
  ~10 ticks; large enough that the schedule has both a "before
  any sweep" window (ticks 0..3) and an "after first sweep"
  window (ticks 6..) where `post_sweep` crashes can land
  meaningfully.

- **`pre_tick_hook` for crash injection.** Same hook surface
  `tests/storage_writer_live_buggify_test.zig` uses for
  `injectRandomFault`. The hook fires once at the chosen tick;
  the rest of the loop continues so in-flight CQEs drain into
  `el.deinit` cleanly without leaking the heap-allocated
  `TorrentSyncCtx` or per-write `DiskWriteOp`.

## Key code references

- **Step 1 (SimIO durability model):**
  - `src/io/sim_io.zig:271-380` — `SimFile` struct + helpers
  - `src/io/sim_io.zig:430-456` — `file_state` field + doc-comment
  - `src/io/sim_io.zig:498-507` — `SimIO.deinit`
  - `src/io/sim_io.zig:521-538` — `SimIO.setFileBytes` (copies)
  - `src/io/sim_io.zig:543-546` — `SimIO.crash`
  - `src/io/sim_io.zig:1041-1051` — `SimIO.read` (union semantics)
  - `src/io/sim_io.zig:1058-1099` — `SimIO.write` (extends pending)
  - `src/io/sim_io.zig:1102-1129` — `SimIO.fsync` (promotes pending)

- **Step 1 (algorithm-level tests):**
  - `tests/sim_io_durability_test.zig` — 12 tests against SimIO
  - `build.zig:617-635` — `test-sim-io-durability` step

- **Step 2 (bug repro, REPLACED):** original single-seed bug repro
  at `tests/resume_durability_bug_test.zig` was removed after the
  production fix landed. See the rebase + harness conversion section.

- **Step 4 (32-seed BUGGIFY harness for the gate):**
  - `tests/resume_durability_buggify_test.zig` — 32-seed harness
  - `build.zig` `test-resume-durability-buggify` step (in default
    `test_step` aggregate)

- **Production code paths the test mirrors (unchanged):**
  - `src/daemon/torrent_session.zig:2403-2417` —
    `persistNewCompletions`
  - `src/daemon/torrent_session.zig:2423-2438` — `flushResume`
  - `src/storage/state_db.zig:127-155` — `ResumeWriter.recordPiece`
    + `flush`
  - `src/io/peer_handler.zig:978-1030` — `handleDiskWriteResult`
    (calls `pt.completePiece` + bumps `dirty_writes_since_sync`)
  - `src/io/event_loop.zig:2033-2097` — `submitTorrentSync`
    (independent fsync sweep)
  - `src/daemon/torrent_session.zig:1340` —
    `db.loadCompletePieces` "trust the DB" call site

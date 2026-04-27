# `truncate` op on the IO contract — 2026-04-28

Track (truncate-op): closed the last synchronous disk-syscall holdout
in `src/storage/writer.zig`. PieceStore's filesystem-portability
fallback (when fallocate returns `error.OperationNotSupported` on
tmpfs <5.10 / FAT32 / certain FUSE FSes) was the only `setEndPos`
left after the 2026-04-27 fallocate/fsync routing
(`progress-reports/2026-04-27-storage-io-contract.md`) and the
2026-04-28 writePiece/readPiece migration
(`progress-reports/2026-04-28-storage-rw-io-contract.md`). Now routes
through `self.io.truncate`.

Three bisectable commits, all green at HEAD. Test count:
**1413 → 1418 (+5)**. `zig build`: clean. `zig fmt .`: clean. Daemon
binary: builds.

Branch: `worktree-truncate-op`.

## Commits

1. `6150f85` — **`io: add truncate op to contract; sync RealIO + SimIO with fault knob`**
   New `TruncateOp` (fields: `fd`, `length`) + `Result.truncate`
   variant on `io_interface.zig`. RealIO implementation is
   synchronous (`posix.ftruncate(2)`, fires the callback inline)
   because `IORING_OP_FTRUNCATE` requires kernel 6.9, above varuna's
   floor (6.6 minimum / 6.8 preferred per
   `src/runtime/requirements.zig`). SimIO implementation schedules
   through the heap with a new `FaultConfig.truncate_error_probability`
   knob (delivers `error.InputOutput`); companion entries added to
   `cancelResultFor` + `buggifyResultFor`. Three algorithm tests in
   `tests/sim_socketpair_test.zig` (success, fault) plus one inline
   RealIO test asserting the file actually grew. 1413 → 1416 (+3).

2. `c058db4` — **`storage: route preallocate fallback through io.truncate`**
   Both `setEndPos` call sites in `src/storage/writer.zig` now submit
   `io.truncate`:
   - `preallocateAll`: fallocate callback flags
     `slot.needs_truncate` instead of synchronously truncating;
     after the fallocate drain, a second pass submits one truncate
     per affected slot (re-using the now-disarmed per-slot
     completion) and drains. New `TruncateCtx` + `truncateCallback`
     mirror the existing `PreallocCtx` shape.
   - `preallocateOne`: lazy `do_not_download → normal` path uses the
     same pattern with a single re-used completion.
   1416 → 1416 tests (refactor; new behaviour exercised by commit 3).

3. `9a3fdb3` — **`tests: integration tests for the PieceStore truncate fallback path`**
   New `FaultConfig.fallocate_unsupported_probability` knob on SimIO
   (delivers `error.OperationNotSupported`, distinct from the
   existing `fallocate_error_probability` which delivers
   `NoSpaceLeft`). Two integration tests in
   `tests/storage_writer_test.zig`:
   - `fallocate OperationNotSupported triggers truncate fallback`:
     fallocate forced unsupported on every call → io.truncate
     succeeds → init returns cleanly with both files open.
   - `truncate fault propagates from fallback path`: fallocate forced
     unsupported + truncate forced to InputOutput → init propagates
     InputOutput.
   1416 → 1418 (+2).

## Methodology notes

### Pattern #14 — investigation discipline

Confirmed the design choice (synchronous fallback in RealIO vs.
probe-and-prefer) before coding:

- Kernel floor is 6.6 minimum, 6.8 preferred per
  `src/runtime/requirements.zig`. `IORING_OP_FTRUNCATE` requires 6.9.
  So an unconditional `IORING_OP_FTRUNCATE` would fail on every
  supported kernel.
- The only daemon caller is `PieceStore.init` (via
  `preallocateAll` / `preallocateOne`), which `doStartBackground`
  in `src/daemon/torrent_session.zig:1264` runs on a background
  thread. Synchronous `posix.ftruncate(2)` there has zero
  event-loop-thread impact.
- AGENTS.md precedent: `IORING_OP_SETSOCKOPT` (6.7+) and
  `IORING_OP_BIND/LISTEN` (6.11+) are also kernel-floor-blocked
  and remain synchronous. Match that.

Synchronous fallback wins on simplicity. Probe-and-prefer adds
runtime branching complexity for a path that fires only on
filesystems rejecting fallocate (rare).

### Pattern #15 — read existing invariants

Mirrored the 2026-04-27 storage-io engineer's approach exactly:

- Op shape on `io_interface.zig` matches `FallocateOp` (fd + scalar);
  `Result.truncate` matches `Result.fallocate` (anyerror!void);
  `cancelResultFor` + `buggifyResultFor` extended to the new variant.
- Fault knob shape matches the existing per-op `_error_probability`
  pattern.
- `TruncateCtx` + `truncateCallback` shape in
  `src/storage/writer.zig` matches the existing `PreallocCtx` /
  `preallocCallback` shape.

No new design decisions on the IO contract itself.

### The combined-commits constraint

The brief asked for 5 commits but the contract addition + RealIO +
SimIO had to be combined into commit 1. Zig's exhaustive switches in
`buildResult` (real_io.zig), `cancelResultFor` (sim_io.zig),
`buggifyResultFor` (sim_io.zig), and the `resubmit` dispatch in both
backends mean adding the variant without updating both backends
fails to compile. Same constraint the previous storage-io rounds
hit. Final structure: 3 commits (contract+backends+algorithm,
storage replacement, integration tests).

### The synchronous-completion shape (RealIO)

This is the contract's first synchronous-completion op. Other ops
(read, write, fsync, fallocate, …) submit an SQE and the callback
fires from `dispatchCqe`. Truncate fires inline from the submission
method itself. Mirrors the pattern dispatchCqe uses:

1. `armCompletion` records op + callback + sets `in_flight = true`.
2. Call `posix.ftruncate(fd, length)` synchronously.
3. Clear `in_flight` (so a callback re-submitting on the same
   completion doesn't trip `error.AlreadyInFlight`).
4. Invoke the callback inline.
5. Honor `.rearm` via an inner loop (not recursion through
   `resubmit`) to dodge the inferred-error-set cycle that
   recursive truncate→resubmit→truncate would create.

`buildResult` returns `error.UnknownOperation` for `truncate` —
truncate completes synchronously and should never reach the CQE
dispatch path, so a CQE with `truncate` in `c.op` is a bug.

### Re-using completions in the fallback path

Both `preallocateAll` and `preallocateOne` re-use the per-slot /
single completion across the fallocate → truncate transition. Safe
because:
- After the fallocate callback returns `.disarm`, the backend
  clears `in_flight = false` (RealIO) / removes from heap (SimIO).
- `armCompletion` only rejects when `in_flight = true`.
- The completion's userdata + callback are overwritten on each arm,
  so the truncate phase re-uses the same memory cleanly.

Avoids allocating a second array of completions for the fallback
path, which would be wasted memory in the common case where
fallocate succeeds.

### Pattern #8 — bisectable commits

Three commits, each compiling and passing the full test suite:

1. `6150f85` — contract + backends + algorithm tests. 1413 → 1416.
2. `c058db4` — storage writer setEndPos → io.truncate. 1416 → 1416.
3. `9a3fdb3` — integration tests + fallocate_unsupported_probability. 1416 → 1418.

If any commit regresses something, `git bisect` lands on it cleanly.

## Files touched

- `src/io/io_interface.zig` — `TruncateOp` + `Result.truncate`
  variant; doc-comment row in the backend method contract.
- `src/io/real_io.zig` — `RealIO.truncate` (synchronous
  `posix.ftruncate(2)` + inline callback); `buildResult` extended;
  `resubmit` extended; new inline test for the on-disk side
  effect.
- `src/io/sim_io.zig` — `SimIO.truncate`; new
  `FaultConfig.truncate_error_probability` and
  `FaultConfig.fallocate_unsupported_probability` knobs;
  `cancelResultFor` + `buggifyResultFor` companion entries;
  `resubmit` extended.
- `src/storage/writer.zig` — `setEndPos` call sites at
  `preallocateAll:503` and `preallocateOne:591` replaced by
  `io.truncate` submission + drain. New `PreallocSlot.needs_truncate`
  flag, `TruncateCtx`, `truncateCallback`.
- `tests/sim_socketpair_test.zig` — 2 algorithm tests for SimIO
  truncate (success default, fault probability 1.0).
- `tests/storage_writer_test.zig` — 2 integration tests for the
  fallback path (success + truncate fault).
- `STATUS.md` — milestone entry; closed the truncate-op follow-up;
  filed new follow-up for the kernel-floor-bump-to-6.9 swap.

## Follow-ups (not in scope for this round)

### 1. Switch RealIO.truncate to `IORING_OP_FTRUNCATE` once kernel floor bumps to 6.9+
Currently RealIO.truncate is the only synchronous-completion op in
the contract. When the kernel floor rises to 6.9+, swap the body
for `self.ring.ftruncate(...)` matching the existing fallocate /
fsync shape; remove the synchronous-path comment and
`buildResult`'s `.truncate => error.UnknownOperation` placeholder
(replace with `voidOrError(cqe)`). SimIO and the contract are
already async-shaped, so no caller changes. Estimated 30 minutes.

### 2. Live-pipeline BUGGIFY harness for the truncate fallback path
The integration tests in `tests/storage_writer_test.zig` cover the
two endpoints (success / failure) of the fallback. A canonical
BUGGIFY wrapper (per-tick `injectRandomFault` + per-op `FaultConfig`
× 32 seeds with `fallocate_unsupported_probability` mid-range)
would catch recovery paths the foundation tests can't see —
specifically the partial-fail case where N-1 of N files take the
fallback successfully and the Nth truncate fails. Reference shape:
`tests/recheck_live_buggify_test.zig`. Estimated 0.5 day. Folded
into the existing `Live-pipeline BUGGIFY harness for
PieceStoreOf(SimIO)` follow-up rather than filed separately.

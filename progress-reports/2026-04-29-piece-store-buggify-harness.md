# PieceStoreOf(SimIO) live-pipeline BUGGIFY harness

Closes the open follow-up at `STATUS.md:293`. Wraps the four
`PieceStoreOf(SimIO)` integration paths with a 32-seed BUGGIFY harness
covering the recovery paths the foundation tests can't see, and adds two
new short-return fault knobs (`short_read_probability`,
`short_write_probability`) to SimIO so the per-span resubmit loops
in `writePiece` / `readPiece` get exercised.

## What changed

### `src/io/sim_io.zig` — new fault knobs

Two new `FaultConfig` fields:

- `short_read_probability` — when set, a successful `read` returns a
  uniformly-random short count in `[1, op.buf.len)` instead of the full
  buffer. Honoured on the registered-content path (the legacy "no
  content registered → 0 bytes" path is unchanged so the existing
  `setFileBytes is per-fd; unregistered fds get zero` test still
  passes). Sim_io.zig:113-119, 845-849.
- `short_write_probability` — same shape for `write`. Strict short
  (`[1, op.buf.len)`) so zero remains reserved for "no progress"
  (`writePiece` treats that as `error.UnexpectedEndOfFile`). Sim_io.zig:121-127, 877-881.

Both probabilities are independent of the corresponding `_error_probability`
knobs; the error path takes precedence (checked first), and the short
path only fires on the success path. Defaults are 0.0, so behaviour is
unchanged for callers that don't opt in.

### `tests/storage_writer_buggify_test.zig` — the harness

32-seed harness with four scenarios, each with its own per-op fault
profile and its own vacuous-pass guard. Mirrors the canonical seed list
from `tests/recheck_live_buggify_test.zig` and
`tests/sim_smart_ban_eventloop_test.zig` (same hex prefixes for cross-
harness reproduction).

#### Test A — partial-init cleanup over a 5-file torrent

Fixture: 5 files × 4 bytes, 4-byte pieces. `fallocate_error_probability
= 0.3` so each of the 5 fallocates has a ~70% chance of succeeding
individually; ~83% of seeds see at least one failure across the batch.

Asserts:
- `init` either succeeds (all 5 fallocates clean → store has 5 open
  files) or returns `error.NoSpaceLeft`.
- testing.allocator catches any leaked `files` slice or fd from the
  errdefer cleanup of partially-opened files.

Empirical: **26/32 seeds hit fault, 6/32 happy-path** (with the canonical
seed list). Vacuous-pass guard demands ≥16 hit seeds.

#### Test B — fsync error storm

Fixture: 2-file torrent. `init` runs under a clean SimIO so files open
and fallocate succeeds; then `fsync_error_probability` is set per-seed
to a value in `[0.5, 1.0]` and `sync()` is invoked. The two-fsync drain
loop must keep `pending` consistent across error completions.

Asserts:
- `sync()` either succeeds (both fsyncs cleared the per-seed
  probability) or returns `error.InputOutput`.
- testing.allocator catches any leaked completion / context buffer.

Empirical: **32/32 seeds hit fault** at p ∈ [0.5, 1.0] across 2
fsyncs. Vacuous-pass guard demands ≥16 hit seeds.

#### Test C — 3-span write/read fault injection

Fixture: 3-file torrent (alpha/beta/gamma × 3 bytes, 9-byte piece).
Each piece spans all 3 files. Per-seed RNG sets
`write_error_probability` and `read_error_probability` independently
in `[0.1, 0.7]`; spans typically see mixed success/failure across the
3-span piece, exercising the callback's `first_error` arithmetic and
the multi-completion drain path.

Asserts:
- `writePiece` either succeeds (all 3 spans cleared p_write) or
  returns `error.NoSpaceLeft`.
- `readPiece` either reconstructs the canonical piece bytes (all 3
  spans cleared p_read) or returns `error.InputOutput`.
- `pending` arithmetic is consistent (the drain returns).

Empirical: **26/32 seeds hit fault, 40 total hits** across the
write+read phases. Vacuous-pass guard demands ≥16 hit seeds.

#### Test D — short-write / short-read loops

Same 3-file fixture. `short_write_probability = 0.7` for the write
phase, `short_read_probability = 0.7` for the read phase. With 3 spans
of 3 bytes each, the expected number of short returns per span is
geometric with mean ~2.3 — plenty of resubmit-loop iterations.

Asserts:
- `writePiece` succeeds despite many short returns (loop continues from
  `state.offset += n`, not zero).
- `readPiece` succeeds despite many short returns.
- The reconstructed piece bytes match the original — i.e. the offset
  arithmetic is right, no torn writes.

Empirical: **32/32 seeds completed round-trip** under the short-return
injection. The "hits" metric is 1 per seed by construction (at p=0.7
on multi-byte spans the probability of zero shorts across 6 completions
is < 0.1%). Vacuous-pass guard demands every seed completes.

### `build.zig` — wiring

New `test-storage-writer-buggify` step (focused) plus a dependency on
`test_step` so the harness runs under `zig build test` automatically.
Mirrors the wiring shape of `test-recheck-live-buggify` /
`test-storage-writer`. build.zig:1021-1042.

## What was learned

- **PieceStore's `init` / `sync` / `writePiece` / `readPiece` are
  internal-drain functions, unlike EventLoopOf(SimIO).** The recheck
  live harness drives `el.tick()` externally, which gives the harness a
  natural per-tick injection hook. PieceStore's API drains the ring
  inside each call (`while (ctx.pending > 0) try io.tick(1)`), so
  per-tick `injectRandomFault` between submission and drain isn't
  reachable from the test harness without invasive refactors. Per-op
  `FaultConfig` probabilities are the right BUGGIFY surface here: the
  entry goes into the heap pre-faulted at submission time, which is
  functionally equivalent to per-tick injection for short-lived
  completions. The harness still calls `injectRandomFault` once per
  seed pre-call as a regression guard for the function's empty-heap
  behaviour.

- **No production bug surfaced.** With the four fault scenarios run
  over 32 seeds and 5 consecutive `zig build test` runs all green, the
  recovery paths the harness was designed to catch are clean:
  - errdefer cleanup of partially-opened files (testing.allocator
    confirms no leak).
  - sync's pending counter under fsync error storms (the drain
    terminates and surfaces the first error).
  - per-span resubmit + cancel arithmetic under read/write error
    injection (no double-decrement, no leak).
  - writePiece/readPiece short-write/short-read loops (offset
    arithmetic correct, no infinite-loop, round-trip data correct).

  This is a confidence-builder outcome rather than a bug-fix one. The
  paths in question landed under the 2026-04-28 storage IO contract
  refactor (`progress-reports/2026-04-28-storage-rw-io-contract.md`)
  and the truncate-op landing
  (`progress-reports/2026-04-28-truncate-op.md`); both rounds had
  inline tests at p=1.0 in isolation, and the BUGGIFY harness now
  validates that mixed-probability fault densities don't break the
  same paths.

- **The new short-return knobs are general-purpose.** They're scoped
  to `read` / `write` (the two contract calls that return a count) and
  they only modulate the success path. Future BUGGIFY harnesses that
  need to stress storage-side resubmit logic — particularly the daemon
  hot path's `peer_policy.zig` writes — can opt in without further
  SimIO work.

## Surfaced bugs

**One self-inflicted regression caught during integration**, no
production bugs in the storage paths the harness targets. The first
version of the SimIO `read` / `write` short-return path consumed an
`r.float(f32)` draw unconditionally (i.e. even when
`short_*_probability == 0`), shifting the deterministic random stream
that downstream BUGGIFY harnesses (`recheck_test`,
`recheck_live_buggify_test`, smart-ban) rely on. Caught because the
first stability check (5 consecutive `zig build test` runs) saw
intermittent `recheck_test` assertion failures before the fix. Fix:
gate the RNG draw on `short_*_probability > 0.0`, so the default-zero
path preserves the original random stream byte-for-byte. After the
gate, 10 consecutive runs are green. See `src/io/sim_io.zig:850-861,
877-892` for the gated form.

Storage paths the harness was designed to catch (errdefer cleanup,
sync's pending counter, per-span resubmit, short-loop arithmetic) are
all behaving as specified — confidence-builder outcome on top of the
2026-04-28 storage IO contract refactor and the truncate-op landing.

## Remaining issues / follow-up

- **Submission-time error during preallocateAll.** If
  `try io.fallocate(...)` returns an error at submission time (e.g.
  `error.PendingQueueFull` from a fully-stressed sim, or
  `error.AlreadyInFlight` from a misuse), the submission loop bails and
  the defers free `completions` / `slots` / `lengths`. The previously-
  submitted heap entries still point at the now-freed completions. In
  practice this is gated by "submission-time failures", which don't
  fire under any reasonable BUGGIFY profile (the SimIO heap has
  4096-capacity default and PieceStore submits ≤ 5 fallocates).
  Real-IO has its own submission-time error surface (`io_uring_submit`
  EAGAIN under SQ pressure), and the same shape applies there. This
  is latent and not exercised by the current harness; filing as a
  separate follow-up to consider.

- **Per-tick `injectRandomFault` is currently a regression-guard call
  rather than a coverage tool.** If a future refactor exposes a
  `runOneTick` hook on PieceStore (or splits the drain into a
  step-able state machine), the harness can grow proper per-tick
  injection between submissions and drain steps. Not blocking — the
  current FaultConfig surface covers the same code paths.

## Verification

- `zig fmt .` clean.
- `zig build` clean.
- `zig build test` clean across 5 consecutive runs.
- `zig build test-storage-writer-buggify`: 4/4 tests pass.
- Sentinel-injection smoke check: `try testing.expect(false)` in the
  partial-init test caught by the runner with the correct test name;
  reverted.
- BUGGIFY summary lines reported on stdout for diagnostic visibility:
  ```
  STORAGE BUGGIFY summary (partial-init): 26/32 seeds hit fault, 6/32 seeds happy-path
  STORAGE BUGGIFY summary (fsync storm): 32/32 seeds hit fault, 0/32 clean drain
  STORAGE BUGGIFY summary (3-span r/w): 26/32 seeds hit fault, 6/32 clean, total 40 hits across write+read phases
  STORAGE BUGGIFY summary (short loops): 32/32 seeds completed round-trip under short-return injection
  ```

## Key code references

- `tests/storage_writer_buggify_test.zig` — full harness (~390 LOC).
- `src/io/sim_io.zig:113-127` — new `short_read_probability` /
  `short_write_probability` fields on `FaultConfig`.
- `src/io/sim_io.zig:845-849` — `read` honours `short_read_probability`
  on the registered-content path.
- `src/io/sim_io.zig:877-881` — `write` honours
  `short_write_probability` on the success path.
- `build.zig:1021-1042` — `test-storage-writer-buggify` step + `test`
  dependency.
- `src/storage/writer.zig:289-401` — `writePiece` / `readPiece` per-span
  loops (the resubmit-on-short and the multi-completion drain that
  Tests C and D exercise).
- `src/storage/writer.zig:411-443` — `sync` multi-fsync drain (Test B).
- `src/storage/writer.zig:554-630` — `preallocateAll` errdefer +
  multi-fallocate drain (Test A).

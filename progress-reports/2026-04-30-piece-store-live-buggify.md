# 2026-04-30 — Live-pipeline BUGGIFY harness for `PieceStoreOf(SimIO)`

## What changed

New BUGGIFY harness wrapping the foundation `PieceStoreOf(SimIO)`
integration tests with the canonical 32-seed shape.

- **`tests/storage_writer_live_buggify_test.zig`** (new). Four
  scenarios, each over 32 deterministic seeds:
  1. **init+sync** — multifile torrent so two fallocate completions
     drain (errdefer cleanup surface), then two fsync completions.
  2. **fallocate→truncate fallback** — 3-byte single-file torrent
     with 10 % `fallocate_unsupported_probability` driving the
     truncate fallback path; 5 % `truncate_error_probability`
     composes with it.
  3. **2-span writePiece+readPiece round-trip** — multifile torrent;
     piece 0 spans alpha[0..3] + beta/gamma[0..1].
  4. **3-span writePiece+readPiece round-trip** — 3-file torrent;
     single 9-byte piece spans alpha + beta + gamma.

- **`src/io/sim_io.zig`** — new `pre_tick_hook` field on `SimIO`
  (callback + ctx pair). Fires at the top of every `tick` call
  after the re-entrancy guard. Lets BUGGIFY harnesses inject
  `injectRandomFault` rolls into the same drain loops the
  system-under-test runs internally — `PieceStore.{init, sync,
  writePiece, readPiece}` all own their own `while (pending > 0)
  try io.tick(1)` loops, so the only way to mutate an in-flight
  op's result mid-method is from inside `tick` itself.

- **`build.zig`** — new `test-storage-writer-live-buggify` step
  wired into the default `test` step.

## Why this shape

The foundation tests (`tests/storage_writer_test.zig`) exercise
each error path with a single-knob `FaultConfig` at p=1.0 —
confirming the path *can* fire but not that it composes safely
under random multi-knob pressure. BUGGIFY adds:

- `errdefer` cleanup of partially-opened files when one of N
  fallocates fails (init opens all files synchronously, then
  submits N fallocates; failure on completion #2 of N must close
  all N fds via the `errdefer for (files) |maybe_file| ...` chain).
- `sync`'s pending-counter under fsync error storms — 5 % per-op
  with 2-3 fsyncs per scenario produces a healthy mix of
  "all succeed", "one fails", "several fail in interleaved order".
  The pending counter must reach zero in every case.
- Per-span resubmit racing with cancellation under read/write
  fault injection — `injectRandomFault` mutates an in-flight op's
  result while the heap is otherwise quiescent; the
  write/readSpanCallback short-write loops must NOT silently
  re-submit on a faulted completion.
- `fallocate→truncate` fallback edge cases — when fallocate forces
  the truncate fallback AND truncate also faults, both error paths
  must compose without losing the first error or leaking fds.

## Run results

```
PieceStore LIVE BUGGIFY summary (init+sync):    20/32 seeds succeeded, 3/32 fault hits across 3 seeds with hits
PieceStore LIVE BUGGIFY summary (fallback):     27/32 seeds succeeded, 3/32 fault hits across 3 seeds with hits
PieceStore LIVE BUGGIFY summary (2-span):       21/32 seeds succeeded, 2/32 fault hits across 2 seeds with hits
PieceStore LIVE BUGGIFY summary (3-span):       20/32 seeds succeeded, 3/32 fault hits across 3 seeds with hits
```

All 32 seeds terminate gracefully across all 4 scenarios — no
panic, no UAF, no leak (testing.allocator is the byte-level
ground truth). The non-success seeds return kernel-shaped errors
(`NoSpaceLeft`, `InputOutput`, `OperationNotSupported`) from the
relevant fault path.

The vacuous-pass guard requires `seeds_with_hits >= 1` per
scenario; passes comfortably (2-3 hits per scenario from the
per-tick hook). Combined with per-op fault rolls, every scenario
exercises both the per-tick-injection path and the per-op-fault
path.

## What I learned

- **PieceStore owns its drain loops.** Unlike `AsyncRecheck` /
  `AsyncMetadataFetch`, which the EventLoop's outer tick drives,
  `PieceStore.{init, sync, writePiece, readPiece}` are blocking
  call-shaped: they submit ops then block on
  `while (pending > 0) try io.tick(1)`. There's no place in test
  code to inject between drain iterations. The only options are
  (a) per-op `FaultConfig` (which fires at submission time, before
  the heap is populated), or (b) a hook inside `tick` itself.
  Option (b) — `pre_tick_hook` — is the surgical addition.

- **Hit counts are heap-depth-bounded.** PieceStore typically has
  1-3 ops in flight at a time (one per file or per span), so even
  at p=0.05 per-tick the per-seed hit rate is ~10 %. The
  vacuous-pass guard is calibrated against this — `seeds_with_hits
  >= 1` is genuinely tight, not pro-forma. If a future refactor
  reduces heap depth further, the guard would start failing and
  flag the regression.

- **Per-tick + per-op compose.** Even when `injectRandomFault`
  doesn't fire (either because the heap is empty or the probe
  hits a sentinel), the per-op `FaultConfig` rolls at submission.
  For init+sync the 5 % per-op rate dominates (fewer in-flight
  ops); for the round-trip variants the per-tick hook adds extra
  pressure during the drain.

## Surprises

- **None.** No bugs surfaced — all 4 scenarios pass cleanly under
  the canonical fault-rate × 32 seeds. The error-cleanup paths
  in `PieceStore.{init, sync, writePiece, readPiece}` already
  composed correctly under the foundation tests' single-knob
  probes. The BUGGIFY harness is now in place for future
  regressions.

## Remaining issues / follow-up

- **Pre-existing failure on `sim_smart_ban_phase12_eventloop_test`**
  (`disconnect-rejoin one-corrupt-block` / `steady-state
  honest-co-located-peer`) is unrelated to this work and reproduces
  on the parent commit (`6e5ef33`).

- **Heap-depth visibility.** `injectRandomFault` returns `null`
  when the heap is empty or only contains parked sentinels. The
  hit counter only counts successful injections — silent
  "skipped because heap was empty" cases are invisible. If the
  per-op fault path ever regresses, the per-tick path may quietly
  fail to compensate. Adding a `tries / hits` ratio to the
  summary would surface this; deferred as cosmetic.

## Key code references

- `tests/storage_writer_live_buggify_test.zig:1-58` — header doc
  with safety invariants and pattern reference.
- `tests/storage_writer_live_buggify_test.zig:155-167` —
  `preTickInject` hook installed on SimIO.
- `tests/storage_writer_live_buggify_test.zig:399-428` —
  `aggregateAndAssert` with vacuous-pass guard.
- `src/io/sim_io.zig:319-332` — `pre_tick_hook` + `pre_tick_ctx`
  fields on SimIO.
- `src/io/sim_io.zig:474-490` — hook call site at top of `tick`.
- `build.zig:1119-1142` — `test-storage-writer-live-buggify` step.

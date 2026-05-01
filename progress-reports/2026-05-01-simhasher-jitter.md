# 2026-05-01 SimHasher Verify-Result Jitter

## What changed and why

- Added deterministic verification-result delay knobs to `SimHasher.FaultConfig`: `verify_result_delay_ticks_min` and `verify_result_delay_ticks_max`.
- Added a delayed result queue that promotes completed hashes only when `drainResultsInto` advances enough logical drain ticks.
- Kept the default at zero delay, preserving the existing immediate-drain simulation model unless a test opts in.
- Added a regression test that forces a two-drain delay and verifies both `hasPendingWork` and result ownership across the delay.

This closes the SimHasher interleaving-realism follow-up from `STATUS.md`: tests can now model hash completions arriving after other simulated I/O or peer-state transitions.

## What was learned

- The main test target does compile and run `src/io/hasher.zig` inline tests; the initial RED run failed exactly on the missing fault-config fields.
- The full suite remains green with the default immediate behavior, which is the key compatibility check for existing simulation tests.

## Remaining issues or follow-up

- `SimIO` still has strict close/CQE ordering. The next interleaving gap is delayed close-driven CQEs and bounded CQE reordering in `src/io/sim_io.zig`.
- Once `SimIO` can force late CQEs, use both knobs together to harden peer-slot and async-operation lifetime paths.

## Key code references

- `src/io/hasher.zig:553` - delayed verification-result queue record.
- `src/io/hasher.zig:588` - new `SimHasher.FaultConfig` delay knobs.
- `src/io/hasher.zig:663` - verify submission now queues immediate or delayed results.
- `src/io/hasher.zig:820` - deterministic delay sampling and delayed-result promotion.
- `src/io/hasher.zig:1382` - regression coverage for delayed verify results.

## Verification

- `zig build test`

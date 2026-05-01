# 2026-05-01 SimIO Late CQEs

## What changed and why

- Added `SimIO.FaultConfig` tick-delay knobs for close-triggered reset CQEs and global CQE reordering.
- Added `Pending.ready_tick` and a logical `delivery_tick` so tests can defer CQE delivery by event-loop ticks without advancing simulated nanoseconds.
- Changed `tick` to find due-and-ready completions instead of only popping the heap root, so a delayed early CQE does not block later ready CQEs.
- Routed `closeSocket` parked-recv resets through the close-delay scheduler.
- Added unit coverage for delayed close reset delivery and deferring an otherwise-ready timeout CQE.

This closes the strict-SimIO interleaving gap where parked recv resets always arrived immediately on close. Higher-level tests can now reproduce "old CQE lands later" timing deterministically.

## What was learned

- The new ready-tick scheduler is compatible with the existing suite under default-zero knobs.
- The smart-ban BUGGIFY telemetry shifted on one run from the usual `96/96` honest-piece verification to `95/96`, but the test's assertions still held and the full suite exited successfully. That confirms the scheduler changes real interleavings even without opting into the new knobs.

## Remaining issues or follow-up

- Wire the new SimIO delay knobs together with SimHasher verify-result jitter into higher-level lifetime/regression tests.
- Use those tests to harden any peer-slot or async-operation lifetime paths they expose.

## Key code references

- `src/io/sim_io.zig:137` - delayed close and CQE reorder fault knobs.
- `src/io/sim_io.zig:188` - pending completion now carries `ready_tick`.
- `src/io/sim_io.zig:430` - logical delivery tick state.
- `src/io/sim_io.zig:677` - `tick` delivery loop now selects due-and-ready completions.
- `src/io/sim_io.zig:854` - close-reset scheduling combines close delay and reorder delay.
- `src/io/sim_io.zig:1801` - regression coverage for delayed close-reset CQEs.

## Verification

- `zig build test`

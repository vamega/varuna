# Recheck cancel late read drain

## What changed and why

- `AsyncRecheck` now tracks destroy state and defers freeing the parent object while read completions or read-cancel completions are still live (`src/io/recheck.zig:66`, `src/io/recheck.zig:340`, `src/io/recheck.zig:384`).
- Each `ReadOp` now owns both the read completion and a cancel completion, plus explicit in-flight flags. The op remains attached to its slot until both CQEs have drained, which avoids freeing the parent before a late cancel callback arrives (`src/io/recheck.zig:172`, `src/io/recheck.zig:406`, `src/io/recheck.zig:412`).
- Reading slots keep their plans and buffers until every submitted read op is finished or canceled. Hashing slots can still be cleared on cancel because the hasher owns the buffer after successful submission (`src/io/recheck.zig:425`, `src/io/recheck.zig:433`, `src/io/recheck.zig:582`).
- Added a SimIO regression that starts a recheck, cancels it with a read still queued, then ticks the simulator to deliver the late completion (`tests/recheck_test.zig:275`).

## What was learned

- The first drain implementation had an ordering bug: target cancellation could arrive before the cancel CQE. Detaching the `ReadOp` on the target CQE made the slot look drained and allowed the parent to self-free while the cancel CQE still pointed at the op.
- Keeping the `ReadOp` attached until both target and cancel sides are done gives the slot a simple quiescence condition: `read_ops.items.len == 0`.

## Remaining issues or follow-up

- UDP tracker request ownership is still pending. Its current single-completion send/recv shape can still race or hit `AlreadyInFlight`.
- Full-suite verification still needs to be rerun after the UDP tracker work.

## Verification

- `zig build test-recheck --summary failures` passed.
- `zig build test-recheck-live-buggify --summary failures` passed.
- `zig build test-recheck-buggify --summary failures` passed.
- `git diff --check` passed.

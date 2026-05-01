# Metadata fetch late CQE drain

## What changed and why

- `AsyncMetadataFetch` now tracks live slot operations and cancel completions before freeing slot buffers or embedded completions (`src/io/metadata_handler.zig:121`, `src/io/metadata_handler.zig:916`).
- Destroy is now deferred when metadata fetch I/O is still in flight. It marks the fetch closing, cancels live slot completions, closes sockets, suppresses user completion callbacks, and frees the fetch only after all target/cancel CQEs have drained (`src/io/metadata_handler.zig:345`, `src/io/metadata_handler.zig:1036`, `src/io/metadata_handler.zig:1045`).
- Slot release no longer resets a slot that still owns a kernel/simulator-visible completion or buffer; `completeSlotRelease` waits until both the target operation and cancel operation are done (`src/io/metadata_handler.zig:944`).
- Added simulator regressions for canceling a fetch parked in recv and for a successful peer completing while slower peers are still parked, with the user callback destroying the fetch before late close CQEs drain (`tests/metadata_fetch_test.zig:216`, `tests/metadata_fetch_test.zig:431`).

## What was learned

- The cancellation regression reliably hung the focused metadata suite before the fix: `cancelMetadataFetch` freed the fetch while SimIO still had a delayed close CQE for the parked recv.
- The success path has the same ownership shape. `verifyAndComplete` can close slower peer sockets while their recv completions still point into the fetch object, then the user's completion callback may call `destroy`.

## Remaining issues or follow-up

- Async recheck cancellation has the same embedded-completion lifetime pattern and remains the next lifecycle risk.
- UDP tracker requests still need separate completion ownership or strictly serialized send/recv submission.

## Verification

- `zig build test-metadata-fetch --summary failures` passed.
- `zig build test-metadata-fetch-live-buggify --summary failures` passed.
- `zig build test-metadata-fetch-shared --summary failures` passed.
- `git diff --check` passed.

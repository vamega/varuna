# AsyncRecheck test fixture skip

## What changed
- Fixed the `AsyncRecheck skips all known-complete pieces` fixture so its v1 `pieces` byte string contains four 20-byte hashes and closes both bencode dictionaries.
- Replaced the broad `Session.load(...) catch return error.SkipZigTest` with `try`, so malformed test fixtures fail instead of silently becoming environment skips.

## What was learned
- The previous fixture declared `pieces80:` but only supplied 42 bytes, including the trailing `ee` bytes that were meant to close dictionaries.
- The skipped test was not platform- or io_uring-related; it was masked fixture corruption.

## Verification
- Confirmed the red state: filtered root test failed with `UnexpectedEndOfStream` after removing the skip catch.
- `nix run nixpkgs#zig_0_15 -- test ... --test-filter recheck ...`: all 15 filtered tests passed.
- `env LIBRARY_PATH=/nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2/lib nix run nixpkgs#zig_0_15 -- build test-recheck`: passed.
- Full suite later passed after the remaining simulator regressions were fixed.

## Remaining issues
- None for this fixture change.

## Key references
- `src/io/recheck.zig:493`

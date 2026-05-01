# 2026-05-01 Peer policy DownloadingPiece alias fix

## What changed and why

- Added a focused `zig build test-peer-policy` target for peer policy ownership regressions.
- Added a regression test for a completing peer whose `next_downloading_piece` aliases the same `DownloadingPiece` as `downloading_piece`.
- Fixed `detachAllPeersExcept` so it still clears `next_downloading_piece` aliases on the completing slot while leaving that slot's current piece for the caller to finish cleaning up.

## What was learned

- The full-suite double-free came from stale `next_downloading_piece` ownership after `completePieceDownload` destroyed the current `DownloadingPiece`.
- The simulation can expose this indirectly, but allocator timing and event ordering make the full smart-ban path an unreliable reproducer.
- A deterministic ownership test is better: it models the exact alias state and fails before any allocator reuse or event-loop scheduling noise matters.

## Remaining issues or follow-up

- The existing `std.testing.allocator`/GPA already catches double-free errors well. A custom poison allocator could help with use-after-free diagnostics, but ownership-invariant tests around `DownloadingPiece` references should catch this class earlier and more reliably.
- Broader `zig build test` still has unrelated peer/protocol/simulation failures from the prior baseline.

## Key references

- `build.zig:267`
- `src/io/peer_policy.zig:1055`
- `src/io/peer_policy.zig:1995`

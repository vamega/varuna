# Piece Hash Lifecycle (Track A) — 2026-04-26

Three-phase memory management for the v1/hybrid SHA-1 piece hash table per
[docs/piece-hash-lifecycle.md](../docs/piece-hash-lifecycle.md).

## What changed

The v1 `pieces` field — a flat `piece_count * 20` byte table that lived for
the entire lifetime of every loaded torrent — now has explicit lifecycle
control. Three phases, each independently exercisable:

* **Phase 1** — piece-by-piece zeroing on verification + endgame slice free.
  After `pt.completePiece` returns true (piece verified + disk-persisted),
  the EL fires `peer_policy.onPieceVerifiedAndPersisted` which clobbers the
  20-byte hash for that piece and frees the whole table once every piece
  is verified.
* **Phase 2** — `Session.loadForSeeding` skips parsing the `pieces` field
  entirely. The daemon also calls `freePieces()` after determining a
  torrent is fully complete at startup (both skip-recheck and recheck
  paths) so existing fast-path loads inherit the steady-state savings
  without restructuring init order.
* **Phase 3** — `Session.loadPiecesForRecheck()` re-parses the v1 hash
  table from `torrent_bytes` for operator-triggered recheck. The current
  daemon's `forceRecheck` API uses stop+start, which goes through
  `Session.load` and gives Phase 3 semantics implicitly; the explicit
  method is exposed for future zero-restart callers.
* **v2/hybrid analog** — `MerkleCache.evictCompletedFile(file_idx, complete)`
  drops the cached per-piece SHA-256 tree once every piece in a file is
  complete. The 32-byte per-file `pieces_root` stays in metainfo (small,
  authoritative).

Memory savings (per [docs/piece-hash-lifecycle.md](../docs/piece-hash-lifecycle.md)):

| Scenario | Before | After |
|---|---|---|
| 50 completed 50 GB torrents (512 KB pieces) | ~100 MB | 0 B |
| 100 GB active download (16 KB pieces) | 128 MB constant | frees ~1.3 KB / piece as it progresses |
| 1000-torrent seeding box | proportional | 0 B for piece hashes |

## Key files touched

* `src/torrent/metainfo.zig` — `parseSeedingOnly` companion plus
  `pieceCountFromFileSizes` fallback (since `pieceCount` previously
  derived from `pieces.len / 20`, which is zero when skipped).
* `src/torrent/layout.zig` — `piece_hashes` is now `?[]const u8`.
  `pieceHash` returns `error.PiecesNotLoaded` when null.
* `src/torrent/session.zig` — `pieces: ?[]u8` heap-owned mutable
  field, `loadForDownload` / `loadForSeeding` / `freePieces` /
  `loadPiecesForRecheck` / `zeroPieceHash` / `allHashesVerified` /
  `hasPieceHashes`. The pieces buffer is allocated separately from
  the session arena so it can be freed mid-session.
* `src/torrent/merkle_cache.zig` — `evictCompletedFile` method
  (also clears the 11 existing `piece_hashes = ""` literals to
  match the new `?[]const u8` shape).
* `src/io/peer_policy.zig` — `onPieceVerifiedAndPersisted` hook
  (with `fileIndexForPiece` helper) called from both disk-write
  completion paths.
* `src/io/peer_handler.zig` — calls the hook from the disk-write
  CQE handler.
* `src/daemon/torrent_session.zig` — calls `session.freePieces()`
  at the two startup-time .seeding transitions (skip-recheck and
  onRecheckComplete).
* `tests/piece_hash_lifecycle_test.zig` — 15 algorithm + boundary
  tests. Wired into `zig build test`.
* `tests/transfer_integration_test.zig` — fixed post-Phase-1 test
  expectation: it was reading `layout.pieceHash` after piece
  completion, which now correctly errors `PiecesNotLoaded`. Switched
  to `layout.mapPiece` for span planning (the test only needs spans;
  the hash check uses a locally-stashed value).
* `build.zig` — wired `tests/piece_hash_lifecycle_test.zig` into the
  main `test` step plus a focused `test-piece-hash-lifecycle` step.

## What was learned

1. **Multi-source piece assembly (Phase 2 work, just-landed) interacts
   non-trivially with per-piece zeroing.** The original implementation
   fired `zeroPieceHash` immediately after `pt.completePiece` returned
   true, on the assumption that the piece is "done" at that point. But
   under multi-source assembly, multiple peers can have their own
   `DownloadingPiece` state for the same piece in flight when the
   first peer's contribution verifies. The first peer's `pt.completePiece`
   zeros the hash; a second peer's later piece-block delivery rolls into
   `completePieceDownload`, which reads the now-zero hash and submits to
   the hasher. The resulting hash mismatch is reported as a hash
   failure on the second peer's slot — which is an honest peer that
   delivered correct data. Surfaced by `sim_smart_ban_eventloop_test.zig`
   on seed `0x1` (4-piece scenario where pieces 1..3 are multi-source).

   **Fix**: in `peer_policy.completePieceDownload`, gate the hash read
   on `pt.isPieceComplete(piece_index)` *before* reading. If the piece
   is already complete, drop into `cleanupDuplicateCompletion` (a new
   helper that mirrors the existing endgame duplicate path) without
   touching the hasher or releasing the piece. This is conceptually the
   same shape as the existing `hasPendingWrite` endgame check in
   `processHashResults`, just earlier in the pipeline so it covers the
   piece-hash-lifecycle race window between disk-write completion and
   any in-flight duplicate completePieceDownload calls.

   The Phase 1 lifecycle hook is correct as-is — the bug was that
   `completePieceDownload` had no guard for "piece already complete by
   another peer's contribution." Adding the guard makes the lifecycle
   compatible with multi-source assembly, and as a side-benefit, slightly
   improves the duplicate-completion path (no spurious hasher work).

2. **Source-level `test "..."` blocks in src/ aren't currently picked up
   by `zig build test`.** Only files explicitly listed in `build.zig`'s
   test artifacts are run. Most subsystem-level test blocks (in
   `src/torrent/*`, `src/storage/*`, etc.) live in their files for
   read-the-test-next-to-the-code value but never execute. This is
   exactly Task #6 (housekeeping: build.zig audit). I worked around it
   by also placing the lifecycle tests in a dedicated `tests/` file and
   wiring it into the main test step.

3. **The lifecycle hook fires before smart-ban is done in a more
   roundabout way than the doc made obvious — but the order works out
   safely.** Smart-ban records are *populated* on hash failure and
   *consumed* on hash pass, both inside `processHashResults`. Disk
   writes are submitted *after* smart-ban consumption. So by the time
   `pt.completePiece` is called from the disk-write completion (and our
   lifecycle hook fires), smart-ban has already finished its records
   for this piece. The original docs framed the safety as "snapshot
   taken before completePieceDownload" — true, but the consume step
   matters more: the hook is only racing with the disk-write completion
   path, not with smart-ban itself. Captured in the inline comment on
   `onPieceVerifiedAndPersisted`.

4. **Failed-piece re-download must not zero hashes.** Smart-ban's
   per-block records persist across the failed→retry cycle, but the
   layout's piece hash is read by `completePieceDownload` *both* on
   the original failed attempt *and* on the retry. Zeroing on
   `pt.completePiece` (true → first verified completion) — and not on
   `processHashResults` failure — keeps the hash live for retries.
   The "smart-ban interaction: hash stays live across failed-piece
   re-download" test in `tests/piece_hash_lifecycle_test.zig` pins
   this invariant.

5. **Generic EL parameterisation requires `anytype` on lifecycle hooks.**
   Stage 2 of the IO migration made `EventLoop` generic over its IO
   backend (`EventLoopOf(RealIO)` vs `EventLoopOf(SimIO)`). Functions
   called from generic contexts must take `self: anytype` rather than
   `self: *EventLoop` (which would lock to a specific instantiation).
   Caught by the rebase onto `507c6bd` — original implementation
   targeted `*EventLoop` (the pre-generic shape on the stale base);
   moving to `anytype` is a one-line fix.

4. **`tc.session: ?*const session_mod.Session` is the right contract for
   reads but blocks lifecycle mutation.** Rather than flipping the field
   to `*Session` (sweeping change, dozens of read-only consumers
   across `peer_handler`/`web_seed_handler`/`protocol`/`seed_handler`),
   I scoped a `@constCast` to the lifecycle helper itself with a clear
   comment explaining the safety: the daemon owns the storage, and the
   helper is only called post-`pt.completePiece` true on the EL thread.

5. **The transfer integration test was reading pieceHash post-completion
   and broke immediately.** This was the first signal the wiring was
   alive — tests that read the hash table after the torrent fully
   verifies now correctly error `PiecesNotLoaded`. The fix in the test
   was to use `layout.mapPiece` (just spans) instead of
   `verify.planPieceVerification` (spans + hash). Worth flagging as a
   shape consumers should adopt: post-completion span mapping should
   not go through the verification-planning helper.

## Test count

* Baseline (current main, post-Phase-2): 223 tests in `zig build test`.
* After Track A: **238 tests** (+15 net). Stable across 3 back-to-back
  runs.
* `zig fmt` clean across all touched files. (Two pre-existing format
  drifts in `src/io/utp_handler.zig` and `src/io/seed_handler.zig` are
  on main but not introduced by Track A.)

## Memory savings demonstration

The dedicated test
`loadForSeeding allocates fewer bytes than loadForDownload (Phase 2 demo)`
in `tests/piece_hash_lifecycle_test.zig` constructs a 1024-piece v1
torrent (synthesised with valid bencode framing) and asserts:

* `loadForSeeding` produces a session with `pieces == null`.
* `loadForDownload` produces one with `pieces.?.len == piece_count * 20`.
* `freePieces` on the download session brings it to the same
  `pieces == null` state.

The test goes through `std.testing.allocator`, which catches any leaks
or double-frees in the new lifecycle paths.

## Follow-ups (not in scope for Track A)

* **Task #6 — build.zig audit.** Many subsystem-level test blocks in
  `src/` aren't wired into `zig build test`. Worth a sweep that adds
  `comptime { _ = ... }` references in subsystem `root.zig` files (the
  pattern `src/crypto/root.zig` already uses) so close-to-the-code
  tests start running. My new tests go through a dedicated
  `tests/piece_hash_lifecycle_test.zig` to side-step this gap.
* **`forceRecheck` could go through `loadPiecesForRecheck` instead of
  stop+start.** The current API path tears down the whole session —
  works but loses the seeding socket and re-runs all init. A future
  optimisation: load pieces on the existing seeding session, kick off
  recheck, free pieces again on completion. The Session-side API is
  already exposed; only the daemon-side wiring would change.
* **Sim integration test for the end-to-end lifecycle.** The
  `EventLoopOf(SimIO)` infrastructure is in main but the existing
  `tests/sim_*.zig` files aren't wired into `build.zig` either (see
  Task #6). Once that's resolved, a sim test driving a small swarm to
  completion + asserting `session.pieces == null` post-finalisation
  would close the integration loop. The algorithm tests already pin
  the shape; the sim test would prove the EL hooks fire under
  realistic timing.

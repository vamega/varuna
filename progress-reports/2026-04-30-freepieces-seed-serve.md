# freePieces() seed-serve fix

## What changed and why

Commit `a4579e9` (Apr 26, "torrent: piece hash lifecycle — three-phase
memory management") added `session.freePieces()` calls in
`src/daemon/torrent_session.zig` at lines 599 (skip-recheck seed-setup),
782 (post-recheck seed-setup), and 907 (post live-recheck). After
`freePieces`, `layout.piece_hashes = null`. When a leecher sent a BT
REQUEST, the seeder's `servePieceRequest` (`src/io/seed_handler.zig:269`)
called `planPieceVerificationWithScratch` (`src/storage/verify.zig:55`),
which unconditionally read `session.layout.pieceHash(piece_index)` and
returned `error.PiecesNotLoaded`. The error was swallowed by
`catch return;` so every REQUEST silently no-op'd → leecher waited
forever → `scripts/demo_swarm.sh` timed out at 60s.

The bug went undetected because:
1. `tests/transfer_integration_test.zig` constructs sessions via
   `EventLoop.addTorrent` + `Session.load` directly, never going through
   `TorrentSession`'s recheck-completion path that calls `freePieces()`.
2. `scripts/demo_swarm.sh` was not run between Apr 26 and Apr 30
   (surfaced during backend-validation Round 2).

## Defenses shipped

Three layered defenses landed as separate bisectable commits.

### Defense 1: factor `planPieceSpans` helper

`src/storage/verify.zig` now exposes `PieceSpans` + `planPieceSpans` /
`planPieceSpansWithScratch` that return ONLY span layout — never touching
`pieceHash`. Span-only callers switched to it:

- `src/io/seed_handler.zig:269` (the bug site)
- `src/io/peer_policy.zig:746` (inline-verify writeback)
- `src/io/peer_policy.zig:966` (v2 leaf-store writeback)
- `src/io/peer_policy.zig:1147` (hasher-result writeback)
- `src/io/web_seed_handler.zig:514` (web-seed writeback)

`planPieceVerificationWithScratch` now delegates to `planPieceSpans` for
the span computation and layers the hash read on top, so verification
callers (recheck, planPieceVerification self-tests) keep their existing
contract.

Two inline tests cover the regression:
- `planPieceSpans returns span layout without reading hashes`
- `planPieceSpans works after freePieces (regression: seed-mode REQUEST)`

Commit: `33ce6c9`.

### Defense 2: surface seed-handler errors

`src/io/seed_handler.zig` swapped `catch return;` for diagnostic logs
plus targeted peer-drop when the error is a programming/state-corruption
signal:

- `planPieceSpans` failure or zero-spans → log + `removePeer(slot)`
  (a leecher waiting for a PIECE that never comes is worse than a clean
  disconnect — the disconnect makes the failure observable to monitoring
  and gives the leecher a fast peer-rotation signal).
- `createPieceBuffer` / `pending_reads.append` OOM → log warn but stay
  connected (transient pool exhaustion is recoverable; peer re-REQUESTs).
- Benign protocol-level rejections (throttled upload, unknown torrent,
  piece-not-complete, oversized block, invalid block range) remain
  unlogged early returns — those are normal protocol behavior.

Commit: `c469b7b`.

### Defense 3: regression integration test

`tests/seed_serve_after_free_pieces_test.zig` drives a real EventLoop
into seed mode after explicit `session.freePieces()`, then connects a
manual TCP peer that performs a plaintext BT handshake, sends INTERESTED,
sends REQUEST for piece 0, and asserts a matching PIECE message arrives.

Verified the test FAILS at parent commit `39eb017` (PIECE not received,
peer sees PeerClosed) and PASSES after the planPieceSpans fix in
`33ce6c9`. This is the "test that would have caught the bug" proof.

The test deliberately uses ONE Session shared between the local EL's
seeder role and the manual TCP peer's downloader role — production-
realistic shape after TorrentSession's seed transition. The local EL's
downloader-side completion path is not exercised; the manual TCP peer
reads PIECE off the wire and validates bytes itself.

Wired through `zig build test-seed-serve-after-free` and into `zig build test`.

Commit: `52d49ad`.

## Defense 4 deferred — Loaded/Seeded type-encoded invariant

The prompt specified a fourth defense: refactor `Session` into a tagged
union (`LoadedSession` / `SeededSession`) so `freePieces()` becomes a
type-safe transition and the compiler refuses calls to `pieceHash` from
seeder paths. The prompt explicitly allowed deferring this: "If the
refactor turns out to be much bigger than expected (e.g. thousands of
lines touched, deep ownership questions about who allocates what during
the transition), STOP and report."

Scope estimate before deferring:
- 17 source files reference `Session` directly (across `src/` and `tests/`).
- `*const Session` flows through `TorrentContext.session: ?*Session`,
  every event-loop tick, every peer-handler entrypoint, every storage
  call, the recheck pipeline, the web-seed pipeline, the smart-ban
  attribution path. Splitting the type forces every caller to either
  switch on the union or accept a wider/narrower view.
- `freePieces()`'s mutation in place means `TorrentSession` would have
  to rewrite the union variant under the same `*Session` pointer, which
  changes the storage shape (variant tag is a different memory layout).
  Either every consumer reloads the pointer through a session manager
  call, or the union holds a stable header + variant payload split.
- `loadPiecesForRecheck` is the reverse transition (Phase 3 endgame
  recovery): seeder → loaded. The union refactor needs both directions
  to be type-safe, doubling the design surface.

Defenses 1–3 already make the bug structurally impossible to reproduce
at the runtime level: every former span-only caller of
`planPieceVerificationWithScratch` is now using `planPieceSpans`, and
`planPieceSpans` is defined to never touch `pieceHash`. A future
`Session` consumer reintroducing the bug would have to actively call
the verification helper for span-only purposes — which is now both
semantically wrong and clearly named.

Defense 4 remains a worthwhile invariant to encode in the type system,
but it's a refactor that deserves its own design pass and review
window. Filing as follow-up.

## Validation

- `nix develop --command zig build` — clean.
- `nix develop --command zig build test` — all pass (no new failures
  vs. parent commit; the new `seed_serve_after_free_pieces` test runs
  in the default `test` step).
- `nix develop --command zig fmt --check .` — clean.
- `IO_BACKEND=io_uring scripts/demo_swarm.sh` (under `nix shell
  nixpkgs#opentracker --command nix develop --command ...`) →
  `swarm demo succeeded` with `progress=1.0000` within 60s. This is
  empirical proof the freePieces bug is end-to-end fixed with io_uring.

## Lines touched

- `src/storage/verify.zig`: +132 / -19 (helper + tests)
- `src/io/seed_handler.zig`: +35 / -4 (helper switch + Defense 2 logs)
- `src/io/peer_policy.zig`: +12 / -6 (helper switch at 3 sites)
- `src/io/web_seed_handler.zig`: +5 / -2 (helper switch)
- `tests/seed_serve_after_free_pieces_test.zig`: +382 (new file)
- `build.zig`: +20 (test-seed-serve-after-free target)

Total: ~6 files, ~580 net additions across 3 commits.

## Key code references

- The bug: `src/daemon/torrent_session.zig:599`, `:782`, `:907`
  (three `session.freePieces()` call sites) → `src/io/seed_handler.zig:269`
  (formerly `planPieceVerificationWithScratch` → `error.PiecesNotLoaded`
  swallowed by `catch return;`).
- Fix: `src/storage/verify.zig:48-92` (`PieceSpans` +
  `planPieceSpans` / `planPieceSpansWithScratch`).
- Test: `tests/seed_serve_after_free_pieces_test.zig`.

## Remaining issues / follow-up

- **Defense 4** (Session union refactor) — open. Should be tackled
  with a clear mandate to rewrite TorrentContext.session pointer
  semantics and accept the cross-cutting churn.
- The downloader-side `peer_policy.zig:696` still calls
  `sess.layout.pieceHash` — that path runs only on a session that
  hasn't called `freePieces` (i.e. a downloader session), but the
  type system doesn't enforce it. Fixed by Defense 4 if/when that lands.
- The web-seed handler's two remaining `pieceHash` calls
  (`web_seed_handler.zig:412`, `:495`) are similarly downloader-only;
  same caveat.

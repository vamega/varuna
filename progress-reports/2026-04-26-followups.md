# Followups Round (cleanup-engineer) — 2026-04-26

Two contained follow-ups deferred from the prior post-Phase-2 session:
**Task A** (app/config source-side test discovery) and **Task B**
(live force-recheck via `loadPiecesForRecheck`). Both shipped as
single coherent commits per pattern #8.

Test count: **531 → 599 (+68)**. Stable across 3 back-to-back runs.
`zig build`: clean. `zig fmt`: clean.

## Task A — app/config source-side test discovery

The prior session (`78e1efc`) re-enabled source-side test discovery for
most subsystems via the `test { _ = X; }` pattern in `src/root.zig`,
but left `_ = app; _ = config;` gated. Their note attributed the gating
to a "comptime-eval error in `src/io/io_interface.zig:392`" that they
couldn't resolve in the time available.

### What the gating actually surfaced

Adding `_ = app;` and `_ = config;` to the test-context block exposes
five **latent test bugs** in code that had never been reached as
test-context. Each is independent of the others; none is a
"comptime-eval ordering" issue. The Zig 0.15.2 rule "a file's test
blocks compile only when it's reached as test-context" means these
bugs lay dormant until the import chain from `app.zig` (which reaches
`storage.writer`/`storage.verify` via `@import("storage/root.zig")`,
which transitively reaches `io.io_interface`/`io.ring`) became
test-reachable.

The five fixes:

1. **`src/io/io_interface.zig:288` — `comptime assert(@alignOf(State) <= backend_state_align)`**.
   The test "Completion.backendStateAs round-trips through opaque
   storage" used a `packed struct { u32, u64, bool }` for State. A
   packed struct of 97 bits has a u104/u128 backing integer with 16-byte
   alignment, exceeding `backend_state_align = @alignOf(*usize) = 8`.
   Fix: dropped `packed`; same round-trip semantics, alignment-correct.

2. **`src/io/io_interface.zig:392` — `for (op_tags) |o|` runtime-known**.
   `std.meta.fields(...)` returns `[]const builtin.Type.EnumField`,
   whose `value: comptime_int` field forces comptime iteration. Fix:
   switched both nested loops to `inline for`.

3. **`src/io/ring.zig:27` — missing `try` on `posix.mmap`**. The iovec
   base ptr was being `@ptrCast` from an error union. `registerBuffers`
   is called only from a `ring.zig` test, never from production, so
   the bug stayed dormant. Fix: added the missing `try`.

4. **`src/storage/{writer,verify}.zig` — broken bencode literal in 5 tests**.
   The shared multi-file metainfo string ended in `eee` instead of `ee`
   — one trailing `e` past the close of the outer dict, which the
   bencode parser correctly rejects as `error.TrailingData`. Fix:
   replaced all 5 occurrences.

5. **`src/config.zig:367` — `load` leaks toml parser's `error_info`**.
   3 error-path tests (`load rejects invalid transport preset`,
   `load rejects invalid transport flag in array`, `loadDefault stops
   on malformed config in current directory`) leaked the parser's
   `error_info` allocation. The toml parser duplicates
   `mapping_ctx.field_path.items` into its own allocator on
   `error_info` set; that allocation is freed only by `parser.deinit()`.
   Fix: added `defer parser.deinit()` in `load`.

### Lesson

The team-lead's hypothesis (comptime-eval ordering / circular imports /
comptime-only branches) was a reasonable framing of the symptom — three
separate compile errors firing only when `_ = app;` was added, all
pointing into `io_interface.zig`. But the actual diagnosis was simpler:
**Zig 0.15.2's lazy compilation rule means that a test in module X,
relying on something to lazily-compile-correctly, only catches its
breakage when X becomes test-context-reachable**. Each of the three
io_interface / ring errors had been written incorrectly from the start
but never had the chance to fail.

This generalises: **whenever you add `_ = X;` to the test-context list,
expect to find latent bugs in tests that have never run before**. A
clean baseline isn't evidence the tests are correct — only that they
didn't compile in test-context.

The 4 newly-failing storage tests + 3 leak-bug config tests are the
same shape: tests that lived in their files for code-co-located reading
value but had been silently skipped. Zig 0.15.2's gotcha is one of the
nastier kinds — silent skip rather than build error.

## Task B — live force-recheck via `loadPiecesForRecheck`

The prior `SessionManager.forceRecheck` did `session.stop(); session.start();`,
which tears down the entire session (peer drops, tracker stop+restart,
queue reset) and re-runs full init in a background thread. The Track A
piece-hash-lifecycle work added `Session.loadPiecesForRecheck()` as a
prerequisite for a zero-restart recheck path; this task wires it up.

### Design

`forceRecheck` now prefers a **live** path on the `TorrentSession` and
falls back to stop+start for any state that precludes it (paused,
stopped, error, checking, metadata_fetching).

The live path (`TorrentSession.forceRecheckLive`):

1. Validates state is downloading or seeding with `torrent_id_in_shared`,
   `session`, `shared_fds`, and `piece_tracker` all populated.
2. Calls `Session.loadPiecesForRecheck()` if `Session.hasPieceHashes()`
   is false (Phase 2 already dropped the SHA-1 table for steady-state
   seeding).
3. Sets state to `.checking`.
4. Submits `AsyncRecheck` via `EventLoop.startRecheck` against the
   existing `torrent_id_in_shared` slot, with `onLiveRecheckComplete`
   as the completion callback.

`onLiveRecheckComplete` (fires on the EL thread after AsyncRecheck
finishes):

1. Persists results to the resume DB via the existing `markCompleteBatch`
   semantics (matches the stop+start path's upsert behaviour; pruning
   stale entries is a pre-existing concern not introduced here).
2. Calls the new `PieceTracker.applyRecheckResult` to overwrite the
   existing `complete` Bitfield's bits **in place** — no reallocation
   means the EL's `*const Bitfield` pointer (set via
   `setTorrentCompletePieces`) stays valid across the rebuild.
3. Cancels the AsyncRecheck (frees the heap-allocated state machine).
4. Transitions state to `.seeding` (and calls `freePieces` per Phase 2
   lifecycle) if the recheck found every piece complete; else
   `.downloading`.

### Why in-place vs replace

The natural shape — `pt.deinit(); pt = new_pt;` — runs into a subtle
race: the EL holds a `*const Bitfield` pointer into the old
`complete.bits` slice. Even though replacing the optional value at the
same address keeps the outer `*const Bitfield` valid, the inner `bits`
slice points to NEW memory after replacement, and the OLD memory gets
freed. If the EL is mid-iterating `bits` on a different thread (it's
not, today; the EL is single-threaded and we run on it during the
callback — but the invariant is fragile and worth not relying on),
that's a UAF.

`PieceTracker.applyRecheckResult` reuses the existing `bits` storage
(`@memcpy` overwrites), takes the tracker's own mutex internally, and
preserves availability counts (peer Have/bitfield announces remain
valid across a recheck — recheck only changes what *we* have, not what
peers have). In-progress claims are dropped, since they were tracking
pre-recheck state.

### Tests added

Per STYLE.md's layered testing strategy:

- **3 algorithm tests** in `tests/piece_hash_lifecycle_test.zig` for
  `applyRecheckResult`:
  - storage stability (`pt.complete.bits.ptr` doesn't move),
  - in_progress reset (claims dropped),
  - availability preservation (peer-side counts survive).
- **1 integration test** in `tests/recheck_test.zig`
  ("live force-recheck rebuilds PieceTracker bitfield in place"):
  drives the full EL → AsyncRecheck → applyRecheckResult round-trip
  against a real session with disk content, asserts (a) bitfield
  storage doesn't move, (b) bitfield reflects on-disk reality, (c)
  availability survives across the rebuild.

A safety-under-faults test for the live recheck flow (BUGGIFY +
fault injection during recheck) was deferred — the existing recheck
flow has BUGGIFY coverage indirectly via the smart-ban EL test, and
the live path's only delta is the in-place bitfield update, which
the algorithm tests already pin.

## Worktree-base lessons

The team-lead's CRITICAL FIRST STEP saved time: my worktree's base was
`6b6688d`, not `3f52d43`. Pre-rebase, `flake.nix` didn't exist (it was
added in a later commit), and the `nix develop` shell couldn't run. A
single `git rebase 3f52d43` brought the worktree current and unblocked
everything.

**Pattern: rebase as canary** (already in STYLE.md from the
storage-engineer + runtime-engineer note) held — the rebase brought in
post-`6b6688d` work that my fixes had to be aware of (specifically: the
`78e1efc` test-context block in `src/root.zig` is what I was modifying,
and pre-rebase it didn't exist).

## Files touched

Task A (commit `8694235`):
- `src/root.zig` — added `_ = app;` and `_ = config;` to the test-context block; trimmed the now-stale gating comment.
- `src/io/io_interface.zig` — fixed two latent test bugs (line 288 alignment, line 392 inline-for).
- `src/io/ring.zig` — added missing `try` before `posix.mmap` in `FixedBufferPool.registerBuffers`.
- `src/storage/writer.zig` — fixed 4 broken bencode literals.
- `src/storage/verify.zig` — fixed 1 broken bencode literal.
- `src/config.zig` — added `defer parser.deinit()` in `load`.

Task B (commit `3f42e83`):
- `src/torrent/piece_tracker.zig` — added `PieceTracker.applyRecheckResult` (in-place bitfield rebuild).
- `src/daemon/torrent_session.zig` — added `forceRecheckLive` and `onLiveRecheckComplete`.
- `src/daemon/session_manager.zig` — `forceRecheck` prefers live path; falls back to stop+start.
- `tests/piece_hash_lifecycle_test.zig` — 3 algorithm tests for `applyRecheckResult`.
- `tests/recheck_test.zig` — 1 integration test for the live recheck flow.

## Follow-ups (not in scope for this round)

- **Resume DB stale-entry pruning on recheck**. Both the existing
  stop+start path and the new live path use additive
  `markCompleteBatch` after recheck. Pieces that were complete pre-
  recheck but found incomplete post-recheck remain marked complete
  in the resume DB. On daemon restart with skip-recheck, those stale
  marks would cause incorrect resume state. The fix is small (clear
  pieces table for the info_hash before re-inserting) but is an
  independent improvement to both paths.
- **Safety-under-faults test for live force-recheck**. The algorithm
  tests pin the in-place update invariants; the integration test
  exercises the EL round-trip on a healthy session. A BUGGIFY harness
  injecting faults during the recheck (read errors, hasher failures,
  disconnect during rebuild) would close the third layer.
- **Live recheck during in-progress download**. The current shape
  drops `in_progress` claims wholesale on recheck completion. A more
  surgical version could preserve claims for pieces that the recheck
  also found incomplete. Optimisation, not a correctness gap.

# Recheck Followups Round — 2026-04-26

Three contained recheck-adjacent follow-ups deferred from the prior
post-Phase-2 + cleanup-engineer sessions: **A1** (resume DB
stale-entry pruning), **A2** (surgical `in_progress` preservation
across recheck), **A3** (BUGGIFY-style safety harness). All three
shipped as separate commits per pattern #8 (tests pass at every commit).

Test count: **599 → 608 (+9)**. Stable across full-suite runs.
`zig build`: clean. `zig fmt`: clean.

## Task A1 — Resume DB stale-entry pruning on recheck (commit `05ab9b6`)

### What changed

The post-recheck callback (`onRecheckComplete` for stop+start;
`onLiveRecheckComplete` for the live force-recheck Task B from the
previous round) used the additive `markCompleteBatch` to record
verified pieces in the `pieces` table. Pieces marked complete
pre-recheck that the recheck found incomplete were left as stale rows
that would corrupt fast-resume on the next daemon start (resume DB
says "complete", disk disagrees → trust the resume DB → seed garbage).

Added `ResumeDb.replaceCompletePieces(info_hash, indices)` — an atomic
delete-then-insert in a single `BEGIN IMMEDIATE` / `COMMIT` transaction
that wipes the prior pieces-table set for the info_hash and lays down
the new one. A concurrent reader never observes a partial state.
Auxiliary per-torrent tables (rate_limits, share_limits, transfer_stats,
…) are untouched — recheck only affects piece completion. To wipe all
torrent state, callers continue to use `clearTorrent`.

Both `onRecheckComplete` and `onLiveRecheckComplete` now call
`replaceCompletePieces` (passing the recheck's full bitfield, including
the empty case so all pre-recheck rows for that hash are cleared).

### Tests added

4 inline tests in `state_db.zig`:
- stale entries dropped (5,6,7 pre → 1,3 post; 5,6,7 verifiably gone)
- empty replacement clears all pieces for the info_hash
- multi-info_hash isolation (replace on hash A leaves hash B alone)
- idempotent on no-change (round-trip preserves entries)

### Why a new method instead of `clearTorrent + markCompleteBatch`

`clearTorrent` deletes 8 tables of per-torrent state (transfer_stats,
torrent_categories, torrent_tags, rate_limits, info_hash_v2,
tracker_overrides, share_limits, queue_positions) — a full reset. After
recheck we only want to replace the `pieces` table. A new method with
the precise scope is cleaner than calling `clearTorrent` and re-inserting
all the auxiliary state.

## Task A2 — Surgical in_progress preservation across recheck (commit `f86842e`)

### What changed

`PieceTracker.applyRecheckResult` previously dropped ALL `in_progress`
claims on recheck — heavy-but-correct cleanup that wasted in-flight
download state. The surgical version applies a per-piece truth table:

| `(was_in_progress, now_complete)` | Action                                  |
|-----------------------------------|-----------------------------------------|
| `(true,  true)`                   | drop claim, bitfield=1 (rare race)      |
| `(true,  false)`                  | **keep claim** (the surgical optimization) |
| `(false, true)`                   | no change (bitfield reflects recheck)   |
| `(false, false)`                  | no change (bitfield reflects recheck)   |

Equivalent: `new_in_progress[i] = old_in_progress[i] AND NOT
new_complete[i]`.

The "keep claim" branch is the optimization. When peer A is
mid-downloading piece N with blocks 0..7 in `dp.buf`, and the recheck
correctly finds piece N incomplete-on-disk (some blocks haven't
flushed), the prior heavy clear forced the picker to re-claim piece N
fresh — discarding the existing DownloadingPiece and `dp.buf` state and
having peer A re-request the buffered blocks. The surgical update
keeps the `in_progress` bit so the picker treats N as still claimed,
the existing DP keeps serving deliveries, and peer A continues from
where it left off.

The rare row-1 case (`in_progress` AND `now_complete`) drops
in_progress because the verified bytes on disk win over the in-flight
download. The orphaned DP for that piece is left alone; when in-flight
blocks finish arriving, `completePieceDownload`'s normal flow hashes
them and `completePiece` returns false as a duplicate of the
already-set complete bit — no leak, no lifecycle complication.
PieceTracker can't observe the DP map directly so it can't proactively
destroy DPs.

### Tests added (replacing the old "clears in_progress" test)

In `tests/piece_hash_lifecycle_test.zig`:
- row 1 — drop in_progress when recheck found complete (rare race)
- row 2 — preserve in_progress when recheck found incomplete (the
          surgical optimization being added here)
- rows 3, 4, 5 — not-in-progress pieces follow recheck cleanly
- mixed truth table — preserve some, drop others, follow recheck on
                       the rest in a single call

The previous "applyRecheckResult clears in_progress (claimed pieces are
released)" test is replaced — the heavy-clear semantics it asserted
are no longer the contract. Storage-stability and availability-
preservation tests are unchanged: those properties hold under both
the heavy and surgical behaviours.

## Task A3 — Safety harness for the recheck surfaces (commit `5ed7e24`)

### What I shipped

`tests/recheck_buggify_test.zig` — a 32-seed randomized cross-product
safety harness for the two surfaces the post-recheck callback fires
(A1 + A2). For each deterministic seed, randomize:

- pre-recheck `complete` bitfield (random subset)
- pre-recheck `in_progress` bitfield (random, disjoint with complete)
- recheck-result bitfield (random, independent)
- `piece_count` ∈ [4, 256]
- info_hash (random per seed)

Drive the surfaces in production order (`applyRecheckResult` →
`replaceCompletePieces`); assert the safety invariants:

1. `pt.complete.bits.ptr` stable across the rebuild (storage invariant
   for the EL's `*const Bitfield` pointer).
2. `pt.complete` bits match recheck result exactly.
3. `pt.in_progress` matches the surgical truth table bit-by-bit.
4. `bytes_complete` reflects recheck.
5. Resume DB `pieces` table = recheck result exactly (no stale rows).
6. No allocation leak (testing.allocator catches).
7. No panic / crash.

Plus a `piece_count=1` boundary cell that walks all 6 valid `(pre_c,
pre_ip, recheck)` combinations directly. Vacuous-pass guards pin
coverage at ≥28/32 seeds per branch; empirically all three surfaces
(A2 preserve, A2 race-drop, A1 prune) saturate at 32/32 with the
canonical seed list.

First run telemetry:

```
RECHECK BUGGIFY summary: 32 seeds, piece_count [13, 255],
A2 preserved in 32/32, A2 race-dropped in 32/32, A1 pruned in 32/32;
total 516 preserved blocks, 1076 stale rows pruned
```

### Why algorithm-level instead of EL+SimIO BUGGIFY

The canonical BUGGIFY harness shape (`tests/sim_smart_ban_eventloop_test.zig`)
drives `EventLoopOf(SimIO)` with per-tick `injectRandomFault` plus per-op
`FaultConfig` over 32 seeds. That's the right target for the recheck
pipeline — it would catch live-wiring recovery bugs (e.g. AsyncRecheck
slot cleanup under read-error injection, hasher submission failures
under fault, partial completion races, etc.) that an algorithm-level
harness can't reach.

But it's blocked on `AsyncRecheck` being hard-coded to `*RealIO`
(`src/io/recheck.zig:34`). Making the recheck state machine IO-generic
is a multi-file refactor:

- `src/io/recheck.zig` — `AsyncRecheck` would become `AsyncRecheckOf(IO)`
  or use `anytype` for the io pointer; `Slot` and `ReadOp` would need
  `IO`-parameterisation at allocation sites.
- `src/io/event_loop.zig` — `startRecheck` / `cancelRecheckForTorrent`
  call sites would need to thread the IO type through.
- The `rechecks` list type changes; per-IO instantiation changes.
- Test ergonomics: a SimIO-driven `AsyncRecheck` needs SimIO disk reads
  to actually return piece data (not just `usize=0`), or the recheck
  produces a tautologically empty bitfield. SimIO would need a
  `setFileBytes(fd, content)` extension.

Per **pattern #14 — investigation discipline** ("if your investigation
surfaces work bigger than the task scope, STOP and file the scoped
follow-up rather than ship a partial fix"): I shipped the algorithm-
level cross-product harness now and filed the EL+SimIO recheck BUGGIFY
as a separate follow-up. The two surfaces I changed are pure
algorithmic/data-structure — the algorithm-level test captures their
full safety contract per the layered-testing-strategy "safety
properties are fault-invariant" rule.

The follow-up note is in STATUS.md → "Next" → recheck-IO-generic
refactor.

## Methodology notes

### Worktree base management

Verified via the team-lead's "CRITICAL FIRST STEP" check that the
worktree's HEAD is `4c10d73` (current main). After `git submodule
update --init vendor/boringssl vendor/c-ares` (which the
`EnterWorktree` setup didn't do for me), the build environment was
ready and the baseline test ran clean.

### Cwd discipline gotcha

Once during the session I edited files via the `Edit` tool with
`/home/madiath/Projects/varuna/...` paths instead of the worktree's
`/home/madiath/Projects/varuna/.claude/worktrees/recheck-engineer/...`
paths — the edits landed in the main repo, not the worktree. Recovered
by saving the diff (`git diff > patch`), reverting main, and applying
the patch in the worktree. Cost: ~5 minutes of confusion + a clean
recovery procedure. Lesson: when the harness puts you in a worktree
session, always pass either relative paths or worktree-absolute paths
to `Edit`/`Write`. The Read tool surfaces files via the cwd-aware
search, but Edit/Write take a literal absolute path.

### Pattern #8 + Pattern #14 in tension

Pattern #8 says "tests pass at every commit"; pattern #14 says "if
investigation surfaces work bigger than scope, STOP and file the
follow-up." A3's investigation surfaced the AsyncRecheck-hard-coded-
to-RealIO issue mid-task. The right call was to:

1. Ship the algorithm-level harness as a complete artefact (passes #8).
2. File the IO-generic refactor as a future follow-up (respects #14).

Neither pattern was sacrificed; the partial scope of "BUGGIFY harness
for live recheck" → "algorithm-level harness against the changed
surfaces" was honest about what the algorithm test does and doesn't
cover. The progress report and STATUS.md "Next" note explicitly call
out the gap so future sessions don't think the live-pipeline BUGGIFY
is closed.

## Files touched

A1 (commit `05ab9b6`):
- `src/storage/state_db.zig` — added `replaceCompletePieces` method + 4 inline tests.
- `src/daemon/torrent_session.zig` — `onRecheckComplete` and `onLiveRecheckComplete` use the new method.

A2 (commit `f86842e`):
- `src/torrent/piece_tracker.zig` — `applyRecheckResult` applies the surgical truth table.
- `tests/piece_hash_lifecycle_test.zig` — replaced the heavy-clear test with 4 truth-table tests + a mixed cross-product.

A3 (commit `5ed7e24`):
- `tests/recheck_buggify_test.zig` (new) — 32-seed cross-product safety harness + piece_count=1 boundary case.
- `build.zig` — wired `test-recheck-buggify` step.

## Follow-ups (not in scope for this round)

- **EL+SimIO BUGGIFY harness for the live recheck pipeline.** Requires
  refactoring `AsyncRecheck` to be generic over its IO backend (currently
  `io: *RealIO`). Touches `src/io/recheck.zig`, `src/io/event_loop.zig`
  (startRecheck, cancelRecheckForTorrent), plus a `SimIO.setFileBytes`
  extension so SimIO reads can return real content (today returns 0
  bytes, which would make every recheck result tautologically empty).
  Estimated 1-2 days. Once landed, the canonical BUGGIFY shape (per-tick
  `injectRandomFault` + per-op `FaultConfig` × 32 seeds) wraps the
  live-recheck integration test.

- **DownloadingPiece cleanup for A2 row-1 (`was_in_progress` AND
  `now_complete`).** Today the orphaned DP is left in the
  `downloading_pieces` map after applyRecheckResult drops the
  `in_progress` bit; it's eventually destroyed when in-flight blocks
  complete (`completePieceDownload`'s `completePiece` returns false as
  duplicate). This is correct behaviour but technically has a small
  window where the DP holds memory unnecessarily. A surgical cleanup
  pass after the recheck callback could iterate `downloading_pieces` and
  destroy DPs whose `piece_index` is now `complete[i]=true AND
  in_progress[i]=false`. Optimization, not a correctness gap.

- **`pruneStaleAfterRecheck` API generalisation.** The current
  `replaceCompletePieces` signature is specific to the pieces table.
  If smart-ban records ever start persisting to the resume DB (today
  they're in-memory only — `std.AutoHashMap`), or if the v2 info-hash
  table ever needs per-piece records, this API would need to grow to
  cover them. Not currently a gap (smart-ban is in-memory, info_hash_v2
  is per-info_hash not per-piece) — but the API name was deliberately
  kept narrow to leave room for that growth.

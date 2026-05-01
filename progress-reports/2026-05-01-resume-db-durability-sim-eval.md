# 2026-05-01 — Resume-DB durability vs. fsync barrier: sim repro feasibility

## Summary

Investigation of the bug flagged in
[`progress-reports/2026-05-01-codebase-review-gpt-5.5.md`](2026-05-01-codebase-review-gpt-5.5.md):
*resume DB rows can be committed to SQLite while the underlying piece bytes
are still un-fsynced, so a crash between "write CQE" and "fsync CQE" can
leave the DB asserting completion for stale or missing bytes after restart.*

The review's claim is **confirmed**. The two cadences (5 s resume flush
vs. 30 s fsync sweep) live in completely independent paths and never
synchronise. A repro is feasible under simulation, but it requires a
small, well-bounded extension to `SimIO` (~150–200 lines) to model
"what bytes survive a crash". The repro is **not** doable today with
zero sim changes — `SimIO` does not distinguish between "write CQE
completed" and "data is on stable storage". I stopped at the gap
analysis per the briefing's "few hundred lines = stop and report" rule.

A draft test scaffold is **not** added in this round — the test is
meaningless without the SimIO durability model, and the model needs
its own design pass before code lands. Section 4 sketches the test
shape so a follow-up can pick it up cleanly.

## 1. Current order of events

Resolved line numbers against the worktree (commit `1f1e32f`):

1. **Peer delivers a piece.**
   `PIECE` message → block accumulates → hash submitted to the
   `Hasher` thread pool.

2. **Hash result drains.** `peer_policy.processHashResults` polls
   the hasher; on a verified piece it submits per-span writes through
   the IO contract:
   - `src/io/peer_handler.zig:927-975` — `diskWriteCompleteFor` callback
     handles short writes and fault paths.
   - `src/io/peer_handler.zig:978-1030` — `handleDiskWriteResult` runs
     when the **last** span CQE lands. On success it calls
     `pt.completePiece(piece_index, piece_length)` at line 1003 and
     bumps `tc.dirty_writes_since_sync +|= 1` at line 1014 *only on
     first completion*.

3. **Resume-row record (lock-free in-memory queue).**
   `TorrentSession.persistNewCompletions` at
   `src/daemon/torrent_session.zig:2403-2417` walks
   `piece_tracker.isPieceComplete(i)` and calls `rw.recordPiece(i)` —
   which just appends to a `std.ArrayList(u32)` under a mutex
   (`src/storage/state_db.zig:127-131`). **No fsync interaction.**

4. **Resume-row flush to SQLite.** `TorrentSession.flushResume` at
   `src/daemon/torrent_session.zig:2423-2438` calls
   `ResumeWriter.flush()` at `src/storage/state_db.zig:134-155`, which
   immediately performs `db.markCompleteBatch(...)` against
   `SqliteBackend` (or `SimResumeBackend`). **No fsync interaction.**

5. **The two callers that drive 3+4** are on the *event-loop thread*
   in the daemon main loop:
   - `src/main.zig:342-360` — periodic 5-second tick:
     `persistNewCompletions(); flushResume();`
   - `src/main.zig:252-268` — drain-onset:
     `persistNewCompletions(); flushResume();`
   - `src/main.zig:384-396` — final-exit:
     `persistNewCompletions(); flushResume();`
   Plus `pause()` at `torrent_session.zig:418-431` and three more
   sites at `torrent_session.zig:1421, 1512, 428`.

6. **Periodic fsync sweep (independent path).**
   `EventLoop.startPeriodicSync()` arms a self-rescheduling timer
   (default `sync_timer_interval_ms = 30 s`) at `src/io/event_loop.zig:2148-2181`.
   Each fire walks every torrent and submits `submitTorrentSync(idx, false)`
   for those with `tc.dirty_writes_since_sync > 0`
   (`src/io/event_loop.zig:2033-2097`). Per-fsync CQE callback
   (`torrentSyncCallback`, line 2099) decrements
   `dirty_writes_since_sync` saturating-style on the last completion.

   `submitShutdownSync` at `src/io/event_loop.zig:2188-2199` is invoked
   on drain — but the daemon's drain handler in `src/main.zig:252-268`
   calls `persistNewCompletions(); flushResume();` first, then keeps
   ticking the loop. **There is no `submitShutdownSync` call on the
   drain path before `flushResume`.** Searching `src/main.zig` for
   `submitTorrentSync\|submitShutdownSync` returns nothing — the
   shutdown drain depends on whatever fsyncs the periodic sweep
   happened to land before drain started.

7. **`TorrentSession` has no knowledge of `dirty_writes_since_sync`
   or `sync_in_flight`.** Both fields live on
   `EventLoop.TorrentContext` (`src/io/types.zig:235-249`); neither is
   read by any code in `src/daemon/torrent_session.zig`. The two
   subsystems are completely decoupled.

**Verdict:** the review's claim is exact. Resume rows for piece N can
be committed to SQLite at any 5-second tick following piece N's write
CQE, regardless of whether piece N's bytes have ever been fsynced.
After a crash:
- The piece-data file's pagecache for piece N is gone.
- The on-disk file may or may not contain piece N (kernel-controlled
  writeback may have flushed it; may not).
- The SQLite resume DB asserts piece N is complete.
- On restart the daemon trusts the DB, skips recheck for piece N, and
  starts seeding stale or zero-filled bytes.

## 2. Sim gap analysis

### What we have today

| Component | Surface | Bug-relevance |
| --- | --- | --- |
| `SimIO.write` (sim_io.zig:941-954) | Schedules a `.write = op.buf.len` completion or `error.NoSpaceLeft` | Models acceptance, not durability |
| `SimIO.fsync` (sim_io.zig:956-963) | Schedules `.fsync = {}` or `error.InputOutput` | Pure no-op on success |
| `SimIO.read` + `setFileBytes` (sim_io.zig:911-939, 392-400) | Reads return a registered byte slice | Caller-owned static slice — never updated by `write` |
| `SimIO.file_content` (sim_io.zig:302-314) | `AutoHashMap(fd, []const u8)` | One read-only slice per fd; no dirty/durable distinction |
| `SimResumeBackend` (sim_resume_backend.zig:24-) | Per-table hashmaps under a mutex | Writes commit **immediately** to in-memory state — no "snapshot of what would survive" |
| `SimResumeBackend.FaultConfig` (sim_resume_backend.zig:37-64) | `commit_failure_probability`, `read_failure_probability`, `read_corruption_probability`, `silent_drop_probability` | Models commit-time errors, not power-loss-after-commit-before-flush |
| `pre_tick_hook` (sim_io.zig:326-338) | Test hook invoked at top of every `tick` | Generic — gives the test access to the heap mid-drain |
| `injectRandomFault` | Mutates an in-flight op's result inside the heap | Generic — doesn't add new ops |

### What's missing

A faithful repro needs SimIO to model the *kernel pagecache barrier* —
the exact behaviour `fsync` exists to bridge. Concrete additions:

1. **Per-fd dirty buffer.** Replace the read-only `file_content` slice
   with a struct like:
   ```zig
   const SimFile = struct {
       durable: std.ArrayListUnmanaged(u8),  // bytes that have been fsynced
       pending: std.ArrayListUnmanaged(u8),  // bytes accepted by write but not yet fsynced
       // (or store as sparse-extent maps if memory cost matters — pieces are 16 KiB - 16 MiB)
   };
   ```
   `SimIO.write` extends `pending` (sized to cover offset+len, zero-fills
   any gap). `read` returns bytes from the union of `durable` overlaid
   with `pending` (most-recent-wins per byte) — this matches what a
   real read would see post-write, pre-fsync (pagecache hit).

2. **`fsync` commits the dirty buffer.** On the success path, copy
   `pending[range]` into `durable[range]` and clear the corresponding
   region of `pending`. (Datasync vs full sync doesn't matter for the
   repro — both flush data.) On the fault path, leave `pending`
   untouched and deliver `error.InputOutput` (already implemented).

3. **`crash()` operation.** A new test-only method:
   ```zig
   pub fn crash(self: *SimIO) void { /* drop pending; preserve durable */ }
   ```
   Drops every fd's `pending` buffer. Subsequent reads see only
   `durable` content. Models a power-loss / kernel-panic between
   write CQE and fsync CQE.

4. **`SimResumeBackend.snapshot()` / `crashSimulate()`.** The resume
   DB is a separate device: SQLite on a different filesystem layer,
   logically. For the bug as stated, the DB's WAL is presumed durable
   on commit (the bug is *not* SQLite losing data). So
   `SimResumeBackend` does not need crash semantics — its writes can
   stay synchronous-to-shared-state. The crash only affects
   SimIO-managed file content.

5. **Re-init path that observes the crash.** The test needs to spin
   down `EventLoopOf(SimIO)` after the crash, construct a new
   `Session` + `PieceStore` + `EventLoop` against the *same* SimIO
   file content (post-crash) and the *same* `SimResumeBackend` state,
   and exercise the "trust the DB" path
   (`Session.maskCompletePieces` / `loadCompletePieces`). The
   `AsyncRecheckOf(SimIO)` foundation in `tests/recheck_test.zig`
   already shows how to read SimIO content through `setFileBytes`;
   the new shape is "after crash, reads see only the durable layer".

### Effort estimate

- (1)+(2)+(3) on SimIO: ~120 lines core + ~50 lines test exercising
  the new ops directly. The trickiest part is keeping the dirty/durable
  storage zero-alloc on the fast path; a sparse-extent representation
  is right but adds code.
- (4) is unnecessary — leave `SimResumeBackend` as is.
- (5) is the test wiring: ~80 lines to do init → write piece → crash →
  re-init → assert.

Total: ~250 lines of production sim code + ~150 lines of test = under
the "few hundred lines" cap, but past "trivial extension". A solo
afternoon to land the SimIO model + a single deterministic seed.

## 3. Repro feasibility

**Conditional yes.** The bug is real and reachable in deterministic
single-seed simulation, *but* the SimIO durability model needs the
extension above first. With it, the repro is straightforward:

```
seed -> EventLoopOf(SimIO) + SimResumeBackend
  1. open small synthetic torrent, register zero-filled SimIO content for the data fd
  2. simulate a peer delivering piece 0:
     - inject the bytes into SimIO via the existing scripted-peer path
     - drive ticks until write CQEs land for piece 0 spans
     - drive ticks until completePiece + dirty_writes_since_sync++ fires
  3. drive enough ticks to trigger the 5-second resume flush
     (or call persistNewCompletions + flushResume directly)
     — assert SimResumeBackend.pieces contains piece 0
  4. CALL sim_io.crash() — drops piece 0's bytes from SimIO state
  5. tear down EventLoop; build a fresh one against the same fd state
     and the same SimResumeBackend
  6. load completion bitfield from SimResumeBackend — observe piece 0 present
  7. assert: either the daemon ran a recheck before trusting the DB
     (it did NOT — that's the bug), OR the loaded completion is
     consistent with what's actually on the durable layer
  8. test FAILS today: daemon trusts the DB, advertises piece 0 to peers,
     but a read returns the durable layer (zero-filled).
```

The assertion that *fails today* is step 7/8: the bug is "the daemon
trusts a stale completion row". A passing test would be one that
reproduces the failure (i.e., asserts that the daemon currently
makes the unsafe decision, then a follow-up PR flips the assertion
once the fix lands).

## 4. PoC: not landed this round

I did not land a draft test under `tests/`, and did not add a
`zig build` step. Reasons:

- The SimIO durability extension is the load-bearing piece. A test
  written without it would be vacuous (every "crash" leaves data
  unchanged because SimIO doesn't track dirty bytes).
- The extension is the right thing to land first as its own
  self-contained change with its own algorithm-level tests
  (`tests/sim_io_durability_test.zig`), so the durability model is
  reviewed on its own merits before any bug-repro test depends on it.
- Per the briefing's "stop at scoping when sim extension > few lines",
  the size of (1)+(2)+(3) above (~120 lines + tests) is at the line
  where I should stop and write up rather than implement.

The follow-up PR sequence would be:

1. **`sim: add per-fd dirty/durable file model + crash op`** — the
   ~250-line SimIO extension with its own algorithm-level test file
   asserting the model behaves correctly under various
   write→read→fsync→read→crash→read sequences.
2. **`tests: resume-DB durability vs. fsync barrier repro`** — the
   single-seed bug-reproducing test. Wired through a new
   `test-resume-durability-bug` step in `build.zig` so it can be
   excluded from the default `test` step (it asserts a current bug;
   would block CI).
3. **`daemon: gate flushResume on fsync barrier`** — the actual fix
   (out of scope for this evaluation).

## What was learned

- **The `dirty_writes_since_sync` counter exists but the resume-flush
  path is unaware of it.** It would be one assertion to fix:
  `flushResume` could refuse to commit completion rows whose pieces
  haven't been observed in a `dirty_writes_since_sync` decrement
  (i.e., whose bytes haven't been fsynced). Or the simpler
  shape-fix: have `submitShutdownSync` and the periodic sync sweep
  *also* drive the resume DB flush, so the two cadences become one.

- **`SimResumeBackend` is correctly shaped for the bug.** Synchronous
  in-memory commit is exactly what production gets out of a SQLite
  WAL commit — the bug isn't that SQLite is unreliable, it's that
  the daemon doesn't gate the SQLite commit on fsync.

- **`SimIO`'s read path was already extended once (the
  `setFileBytes` map at `sim_io.zig:302-314`)** for recheck tests.
  The proposed durability extension generalises that — same fd
  → bytes map, but two-tier (durable + pending) with crash semantics.
  Same access shape; production daemon code never observes the new
  internal split.

- **`pre_tick_hook` (`sim_io.zig:326-338`) is reusable for crash
  injection too.** A BUGGIFY harness can roll a crash probability
  per tick, just like it currently rolls fault probabilities. Once
  the durability model is in, "32 seeds × random crash points"
  is one extra knob.

## Remaining issues / follow-up

- **Decide whether the production fix is "extend `dirty` accounting
  per-piece" or "merge sync + flush cadences".** The cheaper fix is
  the latter — invoke `submitShutdownSync` from the drain handler
  and require the periodic resume flush to wait on
  `dirty_writes_since_sync == 0`. The more correct fix is per-piece
  generation tracking. The review hints at both.

- **Coordinate with the
  [`progress-reports/2026-04-09-storage-integrity-and-resume.md`](2026-04-09-storage-integrity-and-resume.md)
  baseline** before making the fix. There are likely related
  invariants there.

- **The `mmap` durability audit** referenced in `main.zig:215` (`docs/mmap-durability-audit.md`)
  is the prior context — re-read R6 before designing the fix.

## Key code references

- **Bug surface (resume row commits ahead of fsync)**:
  - `src/daemon/torrent_session.zig:2403-2417` — `persistNewCompletions`
  - `src/daemon/torrent_session.zig:2423-2438` — `flushResume`
  - `src/storage/state_db.zig:127-155` — `ResumeWriter.recordPiece` + `flush`
- **Producer of completions**:
  - `src/io/peer_handler.zig:978-1030` — `handleDiskWriteResult`
    (calls `pt.completePiece` + bumps `dirty_writes_since_sync`)
- **Independent fsync sweep**:
  - `src/io/event_loop.zig:2033-2097` — `submitTorrentSync`
  - `src/io/event_loop.zig:2148-2181` — `startPeriodicSync` / `armPeriodicSync` / `periodicSyncFire`
  - `src/io/event_loop.zig:2188-2199` — `submitShutdownSync`
- **Decoupling site**:
  - `src/main.zig:252-268`, `342-360`, `384-396` — three resume-flush
    callsites; none of them call `submitShutdownSync` first
- **Sim infrastructure that exists**:
  - `src/io/sim_io.zig:300-338` — `file_content` map, `pre_tick_hook`
  - `src/io/sim_io.zig:911-963` — `read` / `write` / `fsync` (no
    durable/dirty distinction)
  - `src/storage/sim_resume_backend.zig:37-64` — fault knobs (no
    crash op)
- **Useful test scaffolding to mirror**:
  - `tests/recheck_test.zig:531-720` — `AsyncRecheckOf(SimIO)` +
    `setFileBytes` end-to-end shape
  - `tests/storage_writer_live_buggify_test.zig` — 32-seed
    `PieceStoreOf(SimIO)` BUGGIFY harness (mirror its top-of-file
    invariant doc and seed-summary aggregator)
  - `tests/recheck_buggify_test.zig:60-66, 382-485` — `SimResumeBackend`
    backend swap

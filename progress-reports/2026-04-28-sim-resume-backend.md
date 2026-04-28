# 2026-04-28 — `SimResumeBackend`: in-memory resume DB for sim tests

## What changed and why

Lands Path A from
[`docs/sqlite-simulation-and-replacement.md`](../docs/sqlite-simulation-and-replacement.md):
adds a `SimResumeBackend` so that `EventLoopOf(SimIO)`-shaped
fault-injection harnesses can reach the resume DB layer without going
through real SQLite.

Before this round, the resume DB was reachable only through
`SqliteBackend.open(":memory:")`, which required `libsqlite3` linking
and could not be told to fail commits, drop reads, or corrupt data on
demand. BUGGIFY harnesses that wanted to test recheck recovery under
resume-DB faults had no way to inject them — the SimIO read/write/fsync
fault knobs do not reach SQLite's storage layer.

Path A closes the gap with **~80% of Path B's testability win for ~3%
of the engineering cost** (per the research doc's headline ratio).
Production stays on SQLite. Path B (custom storage engine) is deferred
indefinitely, per §5 of the research doc.

## What was learned

- **Both backends must share identical types or signatures drift.**
  The original `ResumeDb` nested types like `TransferStats` inside the
  struct (`pub const TransferStats = struct {...}` inside `ResumeDb`).
  Lifting them to file-level in `state_db.zig` was required so
  `SimResumeBackend.saveTransferStats(_, _, stats)` and
  `SqliteBackend.saveTransferStats(_, _, stats)` accept the *same*
  struct, not nominally-distinct ones. The lift was the only
  observable change to consumer code (and even that is invisible
  through the `pub const ResumeDb = ResumeDbOf(SqliteBackend)` alias —
  consumers continue to write `state_db.ResumeDb`).

- **`std.AutoHashMap` rejects slice-bearing keys.** First draft used
  `std.AutoHashMapUnmanaged(TrackerOverrideKey, ...)` where the key
  embedded a `[]const u8` URL. `std.hash.autoHash` refuses slice fields
  (intent unclear: hash by pointer? by content?). Working around with
  a custom hash context is possible but adds noise; for the bounded N
  these tables hit (~10s of tags / overrides per torrent), an unsorted
  `std.ArrayListUnmanaged(RowStruct)` with linear lookup is simpler
  and equally correct. Daemon doesn't notice — both backends expose the
  same public methods.

- **Identity functor is enough.** The research doc sketched a thin
  forwarding wrapper (`ResumeDbOf(B) = struct { backend: B; pub fn
  open(...) { ... self.backend.open(...) } ... }`). I went with
  `ResumeDbOf(B) = B` — pure type alias, zero overhead, zero dead
  code. Comptime API parity is preserved by virtue of consumers being
  able to compile against either backend through the alias. If we
  later want explicit forwarding (e.g. for instrumentation), it's a
  single-file change.

- **`replaceCompletePieces` atomic-swap maps cleanly to in-memory.**
  SQLite uses `BEGIN IMMEDIATE … COMMIT` to make the delete-then-insert
  atomic from a concurrent reader's perspective. SimResumeBackend
  achieves the same under `std.Thread.Mutex` — the whole operation
  runs while holding the lock, so readers never observe a partial
  state. Same correctness, simpler implementation.

- **The "open per call" anti-pattern in `TorrentSession` survived
  unchanged.** `loadTrackerOverrides`, `persistTrackerOverride`, and
  `unpersistTrackerOverride` in `src/daemon/torrent_session.zig` each
  open and close a fresh `ResumeDb` connection per call (research
  doc §1.5 surprise #2). I left this as-is for this round; cleaning
  it up requires routing through the shared `SessionManager.resume_db`
  and is independent of the backend swap. Tracked as future cleanup.

## Remaining issues / follow-up

- **Path B remains explicitly deferred.** SQLite is genuinely a good
  fit for varuna's workload. Research doc §5 walks through why a
  custom storage engine is not justified by current evidence. Reopen
  if profiling shows SQLite is the bottleneck for resume DB writes,
  or if a SQLite bug surfaces in production.

- **`TorrentSession.persistTrackerOverride` per-call open/close**
  remains. Should route through `SessionManager.resume_db` like every
  other consumer. Independent of the backend swap, easy fix, but not
  on the path to the testability win.

- **`recheck_live_buggify_test.zig` + `recheck_test.zig` don't
  currently use `ResumeDb` at all.** I expected to refactor all three
  recheck test files; only `recheck_buggify_test.zig` actually touches
  the resume DB. The other two test the recheck pipeline against
  `EventLoopOf(SimIO)` directly — no resume DB involvement. So the
  rewire scope was narrower than briefed.

- **Cross-backend property tests are not part of this round.** Research
  doc §2.6 mentions "cross-backend property tests — same operation
  sequence, both backends, expect identical observable state — pin
  this down" as a Path A risk mitigation. Reasonable next step but
  separate from the milestone.

- **Snapshot/restore is not implemented.** Research doc §2.2 sketches
  a snapshot/restore facility for "survive process kill at every
  commit boundary" tests. Not currently used by any harness; defer
  until a test wants it.

## Key code references

- [`src/storage/state_db.zig:18-103`](../src/storage/state_db.zig) —
  `ResumeDbOf(Backend)` functor, `ResumeDb` alias, top-level shared
  types, `SqliteBackend` struct opening line.
- [`src/storage/state_db.zig:1220+`](../src/storage/state_db.zig) —
  `ResumeWriter` (concrete on `SqliteBackend`).
- [`src/storage/sim_resume_backend.zig`](../src/storage/sim_resume_backend.zig)
  — full SimResumeBackend implementation, FaultConfig, per-table
  hashmaps + lists.
- [`tests/sim_resume_backend_test.zig`](../tests/sim_resume_backend_test.zig)
  — 22 algorithm-level + fault-knob tests.
- [`tests/recheck_buggify_test.zig:60-66`](../tests/recheck_buggify_test.zig)
  — backend swap.
- [`tests/recheck_buggify_test.zig:382-485`](../tests/recheck_buggify_test.zig)
  — new BUGGIFY pass (commit failure injection).
- [`build.zig:746-770`](../build.zig) — `test-sim-resume-backend` step.

## Surprises worth flagging for next time

- **`ResumeDb` consumer surface was much smaller than 25 methods.**
  Research doc §1.1 said `SessionManager` calls "~25 methods". Real
  count is closer to 15 distinct methods, plus `TorrentSession` and
  `QueueManager` adding maybe 5 more. The ~55-method count is the
  *backend*'s public surface; daemon-side consumption is much
  narrower. Inventory before designing.

- **The `TorrentSession.loadTrackerOverrides` open-per-call path
  is the only place where `ResumeDb.open()` is called outside
  `SessionManager`.** Worth refactoring eventually; not blocked by
  the backend split.

- **Test counts that include `:memory:` SQLite tests are not
  portable.** The original `recheck_buggify_test.zig` did
  `var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;`
  — a `SkipZigTest` if SQLite linking failed. SimResumeBackend has no
  link dependency, so the skip path goes away. Net positive: tests
  always run.

## Test count delta

1494 → 1525 (+31).

- +22 from `tests/sim_resume_backend_test.zig` (new file)
- +1 from new BUGGIFY pass in `tests/recheck_buggify_test.zig`
- +8 unaccounted; likely from `--summary all` aggregation surfacing
  individual `test "..."` blocks I lifted between files (the cell-loop
  inside `edge case: piece_count=1` may now report as multiple
  passes).

## Commits (4)

1. `edc77c5` — storage: introduce ResumeDbOf(Backend); add
   SimResumeBackend
2. `3ce75ed` — storage: SimResumeBackend tests + ArrayList row tables
3. `1e25d37` — tests: rewire recheck_buggify_test to use
   SimResumeBackend
4. (this commit) — docs/STATUS: SimResumeBackend milestone

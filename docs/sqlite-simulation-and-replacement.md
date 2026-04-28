# SQLite simulation and replacement: design study

**Status:** research-only design doc, 2026-04-27. Recommends an
implementation path; no code lands from this round.

This document evaluates two related but distinct paths for the resume
state subsystem (`src/storage/state_db.zig` + `src/dht/persistence.zig`):

- **Path A — Simulate the SQLite interface.** Add a backend-shaped
  abstraction over `ResumeDb` so tests can inject an in-memory
  `SimResumeDb` with deterministic faults. Production keeps SQLite.
- **Path B — Replace SQLite with a custom storage engine.** Build a
  small Zig storage backend that runs on the event loop thread through
  the IO contract.

The two paths differ in scope by roughly two orders of magnitude. Section
5 picks one and justifies why.

The goal of the work in either path is the same: the daemon's resume DB
should be reachable from `EventLoopOf(SimIO)` BUGGIFY harnesses, so that
randomized fault tests can fail commits, corrupt reads, drop writes, and
verify the post-recovery state.

---

## Section 1 — current SQLite usage in varuna

### 1.1 Touchpoints

- `src/storage/sqlite3.zig` (76 LOC) — minimal `extern "sqlite3"`
  binding shim (open, close, prepare, step, bind, column, free).
- `src/storage/state_db.zig` (2026 LOC) — `ResumeDb` (the DAO) +
  `ResumeWriter` (the per-torrent batch buffer). 55 public methods.
  This is the entire resume DB surface for the daemon.
- `src/dht/persistence.zig` (263 LOC) — `DhtPersistence`. Uses the same
  `sqlite3.zig` shim, but a *different* SQLite database file (`dht.db`)
  with `PRAGMA synchronous = OFF` and `PRAGMA journal_mode = MEMORY`.
  DHT routing-table state is treated as ephemeral.
- `src/main.zig:477,484` — opens the DHT DB and sets the relaxed
  pragmas; opens the resume DB indirectly via `SessionManager`.
- `src/daemon/session_manager.zig` — owns a single `ResumeDb` value,
  calls ~25 methods (load* on startup, save*/clear* from RPC handlers).
- `src/daemon/torrent_session.zig` — owns a per-session `ResumeWriter`,
  calls `recordPiece` / `flushResume` from worker threads, and (a
  surprise — see §1.5) opens a *fresh* `ResumeDb` per call for tracker
  override read/write paths.
- `src/daemon/queue_manager.zig` — `saveToDb` / `loadFromDb` against
  `queue_positions`.
- `src/rpc/handlers.zig:1303,1357` — direct `saveCategory` calls from
  the WebAPI category endpoints.

Total SQLite-touching daemon code: roughly **2,300 LOC** (state_db.zig
+ sqlite3.zig + persistence.zig + ~150 LOC scattered in callers).

### 1.2 Schema inventory

Resume DB (`varuna.db`, WAL mode, `synchronous=NORMAL` default, full
mutex):

| Table | Primary key | Rows scaling | Frequency of writes |
| ---   | ---         | ---          | ---                 |
| `pieces` | `(info_hash, piece_index)` | O(piece_count × #torrents) | hot — every ~5 s during download (batched) |
| `transfer_stats` | `info_hash` | O(#torrents) | every `flushResume()` |
| `categories` | `name` | small (user-defined) | RPC-driven |
| `torrent_categories` | `info_hash` | O(#torrents) | RPC-driven |
| `torrent_tags` | `(info_hash, tag)` | O(#torrents × tags) | RPC-driven |
| `global_tags` | `name` | small | RPC-driven |
| `rate_limits` | `info_hash` | O(#torrents) | RPC-driven |
| `share_limits` | `info_hash` | O(#torrents) | RPC-driven |
| `info_hash_v2` | `info_hash` | only hybrid/v2 torrents | metadata-load time |
| `tracker_overrides` | `(info_hash, url)` | O(#torrents × edits) | RPC-driven |
| `banned_ips` | `address` | O(#bans) | RPC-driven |
| `banned_ranges` | `id` (autoinc) | O(#ranges) | RPC-driven |
| `ipfilter_config` | singleton (id=1) | 1 row | rare |
| `queue_positions` | `info_hash_hex` | O(#torrents) | each queue mutation (clear-and-rewrite) |

DHT DB (`dht.db`, MEMORY journal, `synchronous=OFF`):

| Table | Primary key | Notes |
| ---   | ---         | ---   |
| `dht_config` | `key` | `node_id` blob singleton |
| `dht_nodes`  | `node_id` | ≤ 300 rows (`SELECT … LIMIT 300`) |

There are **no JOINs**, **no foreign keys** declared, **no aggregations**,
and **no subqueries** in the codebase. The single non-trivial operation
is the `BEGIN IMMEDIATE` … `replaceCompletePieces` transaction
(`state_db.zig:410-439`), which atomically swaps the set of complete
pieces for a torrent during recheck. `clearTorrent` does a similar
multi-table delete-in-transaction at `state_db.zig:457-495`.

All other queries are point lookups by primary key, full-table scans
(`SELECT * FROM categories`), or per-info_hash range scans
(`SELECT piece_index FROM pieces WHERE info_hash = ?1`).

Indexes: only the implicit ones SQLite creates for primary keys. No
explicit `CREATE INDEX` anywhere.

### 1.3 Query inventory

About **45 distinct SQL strings** across `state_db.zig` and
`persistence.zig`:

- 16 `CREATE TABLE` (schema setup, fired once at open).
- 5 prepared statements held for the lifetime of the DB
  (`insert_stmt`, `query_stmt`, `delete_stmt`, `save_stats_stmt`,
  `load_stats_stmt`) — these cover the hot piece-completion path.
- ~25 `execOneShot` strings — prepare/step/finalize per call. These are
  cold paths (categories, tags, bans, tracker overrides, queue
  positions, share limits, IP filter config, v2 hash mapping).
- 2 transactional sequences: `replaceCompletePieces`, `clearTorrent`.

### 1.4 Threading model

AGENTS.md says: *"SQLite operations — must run on a dedicated background
thread, never on the event-loop thread."* The implementation is more
relaxed than the policy. `SQLITE_OPEN_FULLMUTEX` (`state_db.zig:31`,
`main.zig:477`) opens the connection in serialized mode, so any thread
can call any method on the same connection and SQLite's own mutex
serializes access. In practice:

- Per-torrent piece persistence (`ResumeWriter.flush`) runs on each
  torrent's `startWorker` thread (`torrent_session.zig:409`).
- RPC-driven mutations (`setTorrentCategory`, `addTorrentTags`,
  rate-limit setters, ban list rewrites) run on the RPC handler's
  thread, which is *also not* the EL thread (the WebAPI handler is
  invoked from the EL but routes work synchronously — and the
  `*ResumeDb` value held in `SessionManager` is shared across all
  callers).
- DHT writes run on whatever thread the DHT engine fires from.

So the policy reduces to: **"never on the event loop thread"**, which is
guaranteed today because every consumer is reached via a background
thread, and `SQLITE_OPEN_FULLMUTEX` makes the resulting concurrency
safe. Path A and Path B both need to preserve this invariant — neither
the simulator backend nor a new engine should suddenly demand EL-only
access.

### 1.5 Consistency requirements

- **Crash safety**: WAL mode + default `synchronous=NORMAL` survives
  process kill but not power loss for the most recent commit. The
  recheck-pruning + `clearTorrent` paths use `BEGIN IMMEDIATE` … `COMMIT`
  to make the multi-row update atomic — partial state is never observed.
- **Atomicity-critical writes**: `replaceCompletePieces`,
  `clearTorrent`, `persistBanList` (clear-then-rewrite), and
  `persistQueuePositions` (clear-then-rewrite). Loss of any of these
  mid-flight on power failure is acceptable; **partial application
  visible to readers is not**.
- **The piece-completion fast path tolerates loss**: a SIGKILL between
  two `flush()` calls discards up to 5 s of completions, recoverable by
  recheck. This is the design contract today — see STATUS.md
  "Storage & Resume". Not a strong durability requirement.

### 1.6 Surprises worth flagging

- **`SQLITE_OPEN_FULLMUTEX` + multi-thread access is the actual model**,
  not "background-thread-only". The single shared connection in
  `SessionManager.resume_db` is touched from many threads, relying on
  SQLite's own mutex. Path A's `SimResumeDb` will inherit this — and
  needs its own lock to remain a drop-in.
- **`TorrentSession.persistTrackerOverride` opens and closes a fresh
  `ResumeDb` connection per call** (`torrent_session.zig:2326-2331`).
  Same for `loadTrackerOverrides` and `unpersistTrackerOverride`. Three
  open/close cycles per RPC-driven tracker edit — works, not great. Any
  refactor for Path A should fix this by routing through the shared
  `SessionManager.resume_db` like every other consumer.
- **No FOREIGN KEY enforcement** anywhere. Cross-table consistency is a
  caller invariant (e.g. `clearTorrent` lists every torrent-keyed table
  and deletes from each manually). Adding a new torrent-scoped table
  without updating `clearTorrent` is silently broken.
- **DHT DB uses `synchronous=OFF`**: routing nodes are best-effort, but
  the same `sqlite3.zig` shim handles both DBs. A custom engine would
  need to support both durability profiles or accept that DHT goes back
  to "rebuild from bootstrap on every restart."
- **All SQL is parameterized** (`?1`, `?2` placeholders + `bind_blob` /
  `bind_text`). No string concatenation. Good for replacing the engine
  later — none of the queries have SQL-string-only behaviour.

---

## Section 2 — Path A: simulate the SQLite interface

The minimal change to give simulator tests visibility into the resume
DB layer.

### 2.1 Shape of the interface

Mirror the IO-contract pattern: `ResumeDb` becomes
`ResumeDbOf(Backend: type)`, parameterised at comptime.

```zig
// src/storage/state_db.zig
pub fn ResumeDbOf(comptime Backend: type) type {
    return struct {
        backend: Backend,

        pub fn markComplete(self: *@This(), info_hash: [20]u8, idx: u32) !void {
            return self.backend.markComplete(info_hash, idx);
        }
        pub fn markCompleteBatch(self: *@This(), info_hash: [20]u8, indices: []const u32) !void {
            return self.backend.markCompleteBatch(info_hash, indices);
        }
        // … 50 more thin wrappers …
    };
}

pub const ResumeDb = ResumeDbOf(SqliteBackend);   // production
```

Two backends:

- `SqliteBackend` — the existing 2 000-LOC implementation, lifted out
  of `ResumeDb` into a struct that exposes the same method names.
- `SimResumeBackend` — in-memory, deterministic, fault-injectable.

The 55 method signatures stay byte-for-byte identical so consumers
don't change. Only the type they hold changes
(`*ResumeDb` → `*ResumeDbOf(B)` if the consumer is generic, or stay
`*ResumeDb` for production-only consumers).

### 2.2 SimResumeBackend

Per-table in-memory state plus fault knobs:

```zig
pub const SimResumeBackend = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    faults: ResumeFaults = .{},

    // pieces table: info_hash → set of piece_index
    pieces: std.AutoHashMap([20]u8, std.AutoHashMap(u32, void)),
    // transfer_stats: info_hash → TransferStats
    transfer_stats: std.AutoHashMap([20]u8, TransferStats),
    // … one field per table …
};

pub const ResumeFaults = struct {
    /// Probability that a write call returns error.SqliteCommitFailed.
    commit_failure_probability: f32 = 0.0,
    /// Probability that a load call returns no rows even though rows exist.
    read_disappear_probability: f32 = 0.0,
    /// Probability that a load returns the data corrupted (e.g. bitfield
    /// with random extra/missing bits) — exercises recheck recovery.
    read_corruption_probability: f32 = 0.0,
    /// Probability that a transaction is reported committed but the
    /// effect is not actually applied (lost write, mid-fsync crash).
    silent_drop_probability: f32 = 0.0,
};
```

The point is parity-of-shape with `SimIO.FaultConfig` so existing
BUGGIFY harnesses can pass the same seed through both. Tests construct
the simulator backend directly, drive their own torrent through
`EventLoopOf(SimIO)` *and* `ResumeDbOf(SimResumeBackend)`, and assert
the post-fault state.

`SimResumeBackend` must also support snapshot/restore for the
"survive process kill at every commit boundary" test pattern: dump the
state, simulate a kill at point T, restart, replay, verify. ~50 LOC of
deep-copy code per table covers this.

### 2.3 How invasive is the consumer change?

Consumer code (`session_manager.zig`, `torrent_session.zig`,
`queue_manager.zig`, `rpc/handlers.zig`) currently holds
`?ResumeDb` directly. Two options:

- **Comptime-generic consumers.** Make `SessionManager` and
  `TorrentSession` parameterised on `Backend` too. Aligns with the
  EventLoop pattern. Cost: viral generic-ness. `SessionManager(Backend)`
  pulls a `Backend` parameter into every place that touches it
  (which is most of the daemon).
- **Vtable boundary at the top of the resume-DB module.** Keep the
  consumers concrete — they hold a `*ResumeDbVtable` that dispatches at
  runtime to either backend. Cost: indirect calls on the piece-write
  hot path; benefit: zero changes outside `state_db.zig`.
- **Two production builds.** Comptime-pick the backend at the top of
  `state_db.zig` based on a build flag. Production builds get
  `SqliteBackend`; sim-test builds get `SimResumeBackend`. The
  daemon code holds `ResumeDb`, which resolves to one or the other.
  This is the cleanest fit for varuna's existing test harness model
  but means sim tests can't compose multiple resume DBs of different
  backends in the same binary — a constraint that is unlikely to bite.

Recommendation: **two production builds with comptime backend
selection**, the same pattern AGENTS.md uses for the IO contract. The
resume DB sees roughly the same access pattern as the EventLoop —
single instance, accessed everywhere. Comptime-pinning the backend
matches the rest of the codebase and keeps the hot path direct-call.

### 2.4 Test-side wins

Tests that already exist and would gain BUGGIFY coverage:

| Test | What it tests today | Path A unlock |
| ---  | ---                 | ---           |
| `tests/recheck_buggify_test.zig` | `replaceCompletePieces` + `applyRecheckResult` over 32 seeds | adds commit-failure / silent-drop knobs to verify the recheck callback's *recovery* under fault, not just correctness on success |
| `tests/recheck_live_buggify_test.zig` | `AsyncRecheckOf(SimIO)` with read EIO + per-tick BUGGIFY | adds resume-DB faults so a successful recheck followed by a failed `replaceCompletePieces` is exercised — currently invisible |
| `tests/recheck_test.zig` | foundation `EventLoopOf(SimIO)` recheck pipeline | inherit `SimResumeBackend`; gain commit-failure paths |
| Future `tests/queue_persistence_buggify_test.zig` | (does not exist) | becomes feasible — fail `clearQueuePositions` mid-rewrite, verify queue manager rebuilds |
| Future `tests/banlist_persistence_buggify_test.zig` | (does not exist) | persist-ban-list-mid-flush fault → assert in-memory state is consistent with DB on next load |

The piece-write fast path (`ResumeWriter.flush` → `markCompleteBatch`)
is the most valuable target. Today it has *no* simulator coverage —
flush is called from a real OS thread, blocks on a real SQLite call,
and tests skip the path entirely. With `SimResumeBackend`, the
deterministic test simply intercepts the call.

### 2.5 Effort estimate (Path A)

- **Refactor `ResumeDb` into `ResumeDbOf(SqliteBackend)`**: lift
  `db`/statements into a `SqliteBackend` struct, move all 55 methods
  there, leave `state_db.zig` exporting a thin generic wrapper. ~1 day,
  pure shuffling — `zig build test` validates it.
- **Implement `SimResumeBackend`**: one in-memory map per table, all
  55 methods, fault knobs, snapshot/restore. ~2 days, mostly mechanical.
  Most work is in the `loadX` helpers that allocate-and-return slices
  (matching the existing API contract for `loadCategories`,
  `loadTrackerOverrides`, `loadBannedIps`, etc).
- **Wire backend selection through the daemon**: comptime build option
  + `pub const ResumeDb = ResumeDbOf(active_backend);` in `state_db.zig`,
  no changes to consumers. ~0.5 days.
- **Audit + reuse SimResumeBackend in 5 existing tests**: replace the
  `:memory:` SQLite handles with `SimResumeBackend.init(seed)` and add
  fault probes to existing BUGGIFY harnesses. ~1.5 days.

**Total: ~4-5 days for an experienced engineer**, end-to-end. Path A
alone delivers the simulation goal. No production behaviour changes.

### 2.6 Risks (Path A)

- **Drift**: every new method on `SqliteBackend` must also be
  implemented on `SimResumeBackend`. A `comptime` parity check at the
  top of `state_db.zig` (`std.meta.declarations` symmetry) catches
  forgets at build time.
- **Semantic drift**: `SimResumeBackend` could implement a subtly
  different consistency model (e.g. miss the `BEGIN IMMEDIATE` ordering
  that `replaceCompletePieces` relies on). Cross-backend property
  tests — same operation sequence, both backends, expect identical
  observable state — pin this down. ~50 LOC extra per harness.
- **`SQLITE_OPEN_FULLMUTEX` is silent today**; `SimResumeBackend` needs
  its own `std.Thread.Mutex` for parity with multi-thread callers.
  Trivial but easy to forget.
- **Allocations**: many `loadX` helpers `dupe` strings out of SQLite
  rows. The sim backend should `dupe` too — making sure the
  caller-frees contract still holds. Otherwise tests leak in
  `testing.allocator` and fail loudly, which is fine but noisy.

---

## Section 3 — Path B: replace SQLite with a custom engine

A larger swing: no SQLite, no FFI dependency, no `libsqlite3-dev`
package requirement, and the engine integrates directly with varuna's
IO contract — every read/write/fsync goes through the same
`EventLoopOf(IO)` plumbing the rest of the daemon uses.

### 3.1 What it would buy

- **Uniform IO model**: `ResumeDb` joins every other I/O subsystem on
  the EL thread. The "SQLite background thread" exception in AGENTS.md
  goes away. BUGGIFY tests cover the resume DB *for free* via SimIO's
  existing read/write/fsync fault knobs — no separate
  `ResumeFaults` configuration.
- **One less external dependency**: no `libsqlite3-dev` in the build
  environment, no `-Dsqlite=bundled|system` build flag, no
  `vendor/sqlite` blob if we ever vendor it.
- **Tighter operational model**: the engine knows it is the only writer
  (single-process daemon), so it can skip features SQLite carries for
  multi-writer concurrency.
- **Determinism**: every byte the engine writes is observable to a
  SimIO test. Crash points are at every `write` SQE and every `fsync`
  SQE; nothing happens behind the FFI boundary.

### 3.2 Three candidate shapes

#### 3.2.a Append-only log + in-memory snapshot

The simplest shape, well-suited to varuna's workload:

- All writes append a tagged record to a single `varuna.log` file.
- All reads hit an in-memory hashmap rebuilt at startup by replaying
  the log.
- A periodic snapshot writes the entire in-memory state to
  `varuna.snapshot.{N}` and truncates the log.
- WAL-style crash safety: each commit is `write(record)` + `fsync`;
  partial writes detected via per-record CRC + length prefix and
  truncated on replay.

References:
- nanos/etcd's WAL design (read 200-300 LOC of any small
  append-only-log impl on GitHub).
- Bitcask (Riak's engine) — pure append-log + hint files.

Workload fit: **excellent**. varuna's writes are roughly
"piece N of torrent T is complete" + a handful of RPC-driven mutations
per minute. The whole resume state for a daemon with 1 000 torrents fits
comfortably in memory (rough back-of-envelope: 1 000 torrents × 4 KiB
of metadata + 100 MB of piece bitmaps even for huge torrents = ~100 MB).
The in-memory map *is* the live state; the log just makes it durable.

LOC estimate: **2 000 - 3 000 LOC of Zig** for the engine itself,
including:
- log writer + per-record CRC + length framing (~400 LOC)
- log reader + replay state machine (~400 LOC)
- snapshot writer/reader (~300 LOC)
- in-memory schema (one struct per table) (~600 LOC)
- public API matching the existing 55 methods (~700 LOC)
- crash-recovery tests (~400 LOC)

Plus the existing migration tool (Path B requires it; see §3.4). LOC for
that ~500-1 000 in `varuna-tools`.

Drawback: replay time grows with log size between snapshots. Mitigation
is straightforward — snapshot on shutdown, snapshot every N writes,
amortize. Not a real problem for varuna's write rate.

#### 3.2.b LSM tree

RocksDB-shape: memtable + sorted SSTables + compaction.

Reference: `reference-codebases/tigerbeetle/src/lsm/` — production-grade
Zig LSM. Total LSM directory: **~24 000 LOC**, plus ~1 700 LOC of grid
+ storage glue, plus ~34 000 LOC of VSR (consensus + recovery) which
varuna doesn't need. The "just the LSM" subset is still
~10 000 - 15 000 LOC.

Workload fit: **poor**. LSM optimizes for high write volume (millions
per second) at the cost of read amplification and compaction CPU.
varuna writes a few rows per second. Using an LSM here is a six-month
engineering project to solve a problem we don't have.

LOC estimate (writing it from scratch, not copying TigerBeetle's): a
production-quality LSM is **3-6 person-months** of work. Don't.

#### 3.2.c B-tree (LMDB shape)

LMDB's `mdb.c` is famously around 8 000 - 10 000 lines of C. Append-only
B-tree with copy-on-write — every write creates a new root, old roots
become free on the next checkpoint.

Workload fit: **moderate**. The on-disk B-tree handles range scans
nicely (varuna does `SELECT piece_index FROM pieces WHERE info_hash = ?`,
which is a range scan), but copy-on-write B-tree write amplification is
real, and getting the page allocator right is fiddly.

LOC estimate: **5 000 - 10 000 LOC** for a production-ready
implementation. Not crazy, but a significant chunk of a senior engineer's
time (1-2 months). LMDB is *fast* and *correct* but the implementation
sweats every detail.

### 3.3 Crash safety (whichever shape)

Standard answer: **WAL with per-record CRC + length framing**.

- Every commit is one `write(record)` + one `fsync`.
- Records carry a CRC32C of payload, length, and a monotonic sequence.
- On recovery, scan from the last known-good record; truncate at the
  first CRC mismatch.
- Periodic checkpoint flushes the WAL into the main file (snapshot for
  the append-log shape, page-merge for the B-tree shape).

Verifiable via SimIO BUGGIFY: kill the engine at every write boundary
(every `write` SQE submission), restart, verify post-recovery state is
*one of* the consistent committed states. The deterministic-IO contract
makes this brutally repeatable in a way SQLite tests cannot match
without rewriting SQLite's VFS.

### 3.4 Migration

Existing users have `varuna.db` SQLite files with months of resume state
(piece bitfields, lifetime transfer stats, RPC-defined preferences).
Path B *must* ship a one-shot migration tool:

1. `varuna-tools migrate-resume --in varuna.db --out varuna.log` reads
   the SQLite DB via the old shim and writes the same state into the
   new format.
2. Daemon checks for `varuna.db` at startup; if present and
   `varuna.log` is missing, run migration in-process and rename
   `varuna.db → varuna.db.bak` on success.

The migration tool is `varuna-tools` (not `varuna`), so it's allowed to
use blocking `std.fs` per AGENTS.md. ~500 LOC of boring shuffling.

This adds a release-management cost: the migration path needs its own
test matrix (DB at every schema version we've shipped → new format).

### 3.5 Risk inventory (Path B)

- **Trusted-input persistence is still trusted-input**: the engine
  parses files we wrote ourselves, not adversarial torrents/peers, so
  the recent untrusted-input parser hardening doesn't directly apply.
  But "we wrote this file last week, then a partial write happened,
  then we crashed, then we restarted" is the *real* adversarial input.
  Get this wrong and user resume state is silently corrupted on next
  start. Recovery is "torrent must be fully rechecked" — annoying but
  not data loss. Get it *very* wrong (mis-parse a length field, walk
  off the end of the buffer) and we crash on startup, which a power
  user will notice within a week.
- **WAL recovery edge cases**: torn writes inside a single record;
  partial commits across power loss; sector boundaries; XFS allocation
  hints; tmpfs's lack of fsync semantics. SQLite has spent 20 years on
  these and has a test suite that runs SQLite under fault injection
  for thousands of CPU-hours. We don't.
- **Operational surprises**: the resume DB grows beyond expected size
  (a user with 50 000 torrents); rare crashes that aren't covered by
  tests; filesystem-specific oddities (CIFS, encrypted ZFS, btrfs
  subvol snapshots mid-write). Each one is a multi-day investigation
  the first time it happens.
- **Migration cost**: every existing user runs through a one-shot
  conversion. If the converter has a bug, *all* affected users get
  corrupted state. The only safe play is: convert into a new file,
  keep the SQLite file as backup until the user voluntarily
  decommissions it.
- **Maintenance cost forever**: every BEP we add that needs persisted
  state requires updating the engine's schema migration path, the
  migration tool, the in-memory representation, and the WAL replay
  code. SQLite handles all of that with `CREATE TABLE IF NOT EXISTS`
  and a one-line `ALTER`.

### 3.6 Effort estimate (Path B)

| Sub-task | Estimate |
| --- | --- |
| Append-only log engine, MVP | 3-4 weeks |
| WAL + recovery + snapshot | 2-3 weeks |
| Public API parity (55 methods) | 2 weeks |
| Migration tool + test matrix | 2 weeks |
| Cross-backend property tests (SQLite vs new) | 1 week |
| Production hardening + first 6 months of bug reports | open-ended, weeks-to-months |

**Total for the append-log shape: 2-3 calendar months for an experienced
engineer**, before counting the long tail of operational issues.

LSM or B-tree shapes: **6-12 months** before parity-with-SQLite-WAL
durability. Not a serious option for the resume DB.

---

## Section 4 — hybrid paths

A few shapes worth naming so they're not silently overlooked.

### 4.1 Path A only, then re-evaluate

Land Path A. Defer Path B. Use the BUGGIFY coverage from Path A to
*find* the resume-DB consistency bugs that today's tests can't see; if
they all turn out to be in our calling code (e.g. forgetting to
transactionally couple ban-list rewrites), no engine work is justified.
If real SQLite bugs surface (extremely unlikely given SQLite's track
record), re-evaluate.

### 4.2 Hot-path / cold-path split

Custom append-log for the *hot* writes (`pieces` and `transfer_stats`
— ~95% of write volume by row count) plus SQLite for the cold,
RPC-driven configuration tables (categories, tags, bans, tracker
overrides, share limits, IP filter config, queue positions). Two
backends, two consistency models, two failure modes. **Not
recommended** — you pay the maintenance cost of both engines and gain
nothing for varuna's write volume. Skipping.

### 4.3 SQLite-on-SimIO via a custom VFS

SQLite supports custom VFS implementations. A varuna VFS that routes
SQLite's `xRead`/`xWrite`/`xSync` through varuna's IO contract would
give us the fault-injection win *without* replacing the engine.

Cost estimate: SQLite's VFS interface is fundamentally synchronous —
`xRead` blocks until bytes return. Mapping this to an async IO contract
requires either (a) running SQLite on a dedicated worker thread that
*calls back into the EL via a queue* (which is what we do today, just
through libsqlite3 internals instead of a varuna VFS), or (b) using
SQLite's WAL "wal-blocking" hooks to defer commits — neither of which
gets us BUGGIFY-style "fail this `pwrite` with EIO" without significant
plumbing. **Not worth pursuing** unless we find ourselves needing
SQLite-grade durability with SimIO-grade testability, which is not a
problem we have today. Skipping.

### 4.4 Path A first, then Path B if it earns its place

Same as 4.1, but explicit about the asymmetry:
`SimResumeBackend` from Path A becomes the *test substrate* for any
future Path B work. If Path B ever lands, the property tests built on
top of `SimResumeBackend` are exactly what validates the new engine
against the old one. Path A is therefore an investment that pays
forward into Path B, not a dead-end.

This is the recommended trajectory.

---

## Section 5 — recommendation

**Land Path A. Defer Path B indefinitely, contingent on profiling
evidence or operational surprises.**

The argument:

1. **Path A solves the testability problem in 4-5 days.** The reason
   this work is on the table is "tests using `EventLoopOf(SimIO)` can't
   reach the resume DB layer." Path A delivers exactly that, with no
   production risk and no migration work.
2. **SQLite is genuinely a good fit for varuna's workload.** It is
   battle-hardened, ships in every Linux distro, has a fault-injection
   test suite that is bigger than varuna's entire codebase, and the
   parts varuna actually uses (point lookups, range scans on a single
   table, a couple of multi-row transactions) are SQLite's
   easy case. There is no profiling evidence that it is a bottleneck.
   Replacing it would be solving a problem we do not have.
3. **Path A is reusable as a Path B substrate.**
   `SimResumeBackend`'s deterministic in-memory implementation is
   exactly the cross-backend test oracle a future Path B engine would
   need. Path A is therefore not wasted work even in a world where we
   eventually replace SQLite.
4. **Path B's costs are real and the wins are abstract.** The "uniform
   IO contract" win is genuine but small — there is one exception in
   AGENTS.md and it doesn't bite anyone day-to-day. The "no FFI
   dependency" win matters only if we ship a static binary to a
   platform that lacks `libsqlite3.so`, which is not a stated goal.
   Against that: 2-3 person-months of senior engineering, a migration
   path that affects every existing user, and a long tail of
   operational surprises in trusted-input persistence code that would
   be on us to debug for years.
5. **The DNS comparison in the brief is misleading.** DNS replacement
   was tractable because (a) DNS is an untrusted-input protocol and
   `getaddrinfo`'s threading model collided with our io_uring design,
   so we had a strong functional pull *toward* a custom replacement,
   and (b) c-ares is small and DNS resolution is read-only at the
   protocol level. Resume DB replacement has no equivalent forcing
   function — SQLite's threading model collides with our preferred IO
   model only via the AGENTS.md exception, not via correctness. The
   workload is also write-heavy with crash-safety requirements, which
   is *much* harder than DNS.

The decision is not wishy-washy: **A only, until evidence forces a
revisit.** If, six months from now, the BUGGIFY coverage Path A gives us
surfaces persistent SQLite-attributable bugs (effectively zero
probability) or profiling shows SQLite is the bottleneck for resume DB
write throughput (also low probability — the daemon writes a few KB/s
to the resume DB), reopen the question.

---

## Section 6 — estimated effort summary

| Path | Effort | Risk | Testability win |
| --- | --- | --- | --- |
| **Path A** (simulate only) | **4-5 days** | low — pure refactor + new in-memory backend, comptime parity check guards drift | **~80%** of the BUGGIFY coverage Path B would deliver |
| Path A + retrofit 5 existing tests | +1.5 days | low | unlock fault-injection paths in `recheck_buggify`, `recheck_live_buggify`, `recheck_test`, plus net-new harnesses for queue + ban list persistence |
| Path B (append-log MVP) | 2-3 months | medium-high — first 6 months of operational surprises | **+15-20%** over Path A: covers SQLite VFS-layer faults that Path A's `SimResumeBackend` skips |
| Path B (LSM) | 6-12 months | high — wrong shape for workload | same +15-20% as the append-log shape |
| Path B (LMDB-shape B-tree) | 4-8 months | high — fiddly page allocator | same +15-20% |
| Path B with full SQLite WAL parity (any shape) | 12+ months | high — SQLite's edge cases over 20 years of bug fixes | marginal additional gain over the MVP |

**Headline ratio**: Path A captures roughly 80% of the testability win
for ~3% of the engineering cost (5 days vs. 3-12 months). The remaining
20% (faults inside the storage engine itself) is a long-tail concern
SQLite already handles better than anything we could realistically
write in a quarter.

The right call is Path A now, document Path B as a deferred option in
`docs/future-features.md`, and revisit only with operational evidence.

---

## Appendix — pointers for the next round

If/when Path A is greenlit:

- The lift-and-shift refactor (`ResumeDb` → `ResumeDbOf(SqliteBackend)`)
  is at `src/storage/state_db.zig:16-1188`. 55 public methods, all in
  one struct.
- Backend selection lives in `src/storage/state_db.zig:1` plus a
  build-flag pickup in `build.zig` (mirror the existing
  `-Dsqlite=bundled|system` flag).
- Consumer update points (no source changes needed if comptime selection
  is used, only the type alias):
  - `src/daemon/session_manager.zig:59,88,110,171,211,...`
  - `src/daemon/torrent_session.zig:216,1280,2286,2328,2336,...`
  - `src/daemon/queue_manager.zig:264,272`
  - `src/rpc/handlers.zig:1303,1357`
- Test reuse targets:
  - `tests/recheck_buggify_test.zig` (32-seed cross-product)
  - `tests/recheck_live_buggify_test.zig` (live `EventLoopOf(SimIO)`
    pipeline)
  - `tests/recheck_test.zig` (foundation integration tests)
- Existing fault model to mirror: `src/io/sim_io.zig:88-130`
  (`FaultConfig` shape) and `src/io/sim_io.zig:946`
  (`injectRandomFault`). `ResumeFaults` should follow the same
  per-op-probability + per-tick-injection pattern so the seed flow is
  uniform across IO and resume-DB faults.
- Don't forget: `SQLITE_OPEN_FULLMUTEX` makes the production code
  thread-safe by accident. `SimResumeBackend` needs an explicit
  `std.Thread.Mutex` to preserve this.

If/when Path B is reopened:

- Read `reference-codebases/tigerbeetle/src/lsm/` for what a
  production Zig storage engine looks like — but use it as a *cost
  signal*, not a template. TigerBeetle's LSM is the right shape for
  TigerBeetle's workload, not varuna's.
- The append-log shape (§3.2.a) is the only Path B variant worth
  serious thought for varuna's workload.
- The migration story (§3.4) is mandatory and is half the engineering
  cost.

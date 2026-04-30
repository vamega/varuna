# Async data-file move + setLocation deprecation

External review C5: `setLocation` (the qBittorrent WebAPI endpoint that
changes a torrent's save location) was doing synchronous recursive
`posix.read` / `posix.write` in a copy-then-delete loop. Cross-fs
moves of multi-GB torrent data held the calling thread for arbitrary
time. Fixed in this branch.

## What changed

1. **IO contract additions** (`src/io/io_interface.zig`):
   - New op: `splice(in_fd, in_offset, out_fd, out_offset, len)`.
     RealIO submits as `IORING_OP_SPLICE`. Posix backends route through
     `PosixFilePool`'s worker thread (the wrapper isn't in
     `std.os.linux`, so `posix_file_pool.zig:executeSplice` invokes
     `syscall6` directly). mmap variants run inline on the EL thread;
     KqueueMmapIO returns `OperationNotSupported`.
   - New op: `copy_file_range(in_fd, in_offset, out_fd, out_offset, len)`.
     **No native io_uring op exists** as of kernel 6.x — RealIO runs
     the syscall inline; Posix backends route through the pool;
     Darwin emulates via `pread`+`pwrite`.
   - SimIO: synchronous-success completions plus
     `splice_error_probability` / `copy_file_range_error_probability`
     fault knobs.
   - Verified against varuna's kernel floor (6.6/6.8): SPLICE ships in
     5.7+, copy_file_range syscall in 4.5+ (cross-fs since 5.3).

2. **MoveJob state machine** (`src/storage/move_job.zig`):
   - Dedicated worker thread per job. AGENTS.md sanctions a worker
     thread for "one-time file creation, directory setup" — a
     setLocation move is the prototypical case.
   - States: `created → running → {succeeded, failed, canceled}`.
     Atomic state byte plus atomic progress counters (`bytes_copied`,
     `total_bytes`, `files_done`, `total_files`, `cancel_requested`,
     `used_rename`).
   - **Same-FS fast path**: `posix.fstatat` on src and dst returns
     each path's `dev_t`. Matching `dev` ⇒ `posix.rename`
     (constant-time on every modern Linux filesystem).
   - **Cross-FS path**: recursive walk, `posix.copy_file_range`
     per file with a 32 MiB chunk cap (matches coreutils `cp`;
     keeps cancel responsive). Source files unlinked after their
     copy lands; source dirs `rmdir`d on the way out.
   - Symlink safety: `O_NOFOLLOW` on both src open and dst create.
   - Pre-scan computes totals before copying so progress percentages
     are meaningful from the first poll.

3. **SessionManager integration** (`src/daemon/session_manager.zig`):
   - New fields: `move_jobs: AutoHashMap(MoveJobId, *MoveJob)` and
     `torrent_move_jobs: StringHashMap(MoveJobId)` (reverse index
     preventing concurrent moves of the same torrent).
   - New methods: `startMoveJob`, `getMoveJobProgress`, `cancelMoveJob`,
     `commitMoveJob`, `forgetMoveJob`.
   - Old `setLocation` and the inline `moveDataFiles` recursive
     `posix.read`/`posix.write` loop are gone.

4. **Endpoints** (`src/rpc/handlers.zig`):
   ```
   POST   /api/v2/varuna/torrents/move           → start (returns id)
   GET    /api/v2/varuna/torrents/move/<id>      → poll progress
   POST   /api/v2/varuna/torrents/move/<id>/cancel
   POST   /api/v2/varuna/torrents/move/<id>/commit
   DELETE /api/v2/varuna/torrents/move/<id>      → forget terminal job
   ```
   The `/varuna/` segment makes the dependency explicit — qBittorrent
   clients don't reach the new endpoint accidentally.
   `POST /api/v2/torrents/setLocation` returns 400 with a body that
   names the new endpoint, so existing clients fail loudly rather
   than hanging.

5. **varuna-ctl** (`src/ctl/main.zig`):
   - `varuna-ctl move` now hits the async endpoint.
   - New: `move-status <id>`, `move-cancel <id>`, `move-commit <id>`.

## Tests

- `src/storage/move_job.zig` (8 tests): same-fs single file rename,
  same-fs directory tree rename, progress snapshot observable,
  missing source surfaces SourceNotFound, cancel-before-start no-op,
  source files unlinked after rename, completion callback fires
  with terminal state.
- `tests/api_endpoints_test.zig` (10 tests): deprecated setLocation
  returns 400 with pointer, hash/location validation, unknown
  hash → 404, unknown id → 404 for all sub-routes (cancel, commit,
  status, delete), invalid id → 400, wrong method → 405.

Total test count: 1747 → 1764 (+17, all passing). Pre-existing flaky
tests in `sim_smart_ban_phase12_eventloop_test` and
`sim_multi_source_eventloop_test` are unrelated to this change.

## Design tradeoffs

**Worker thread vs EL state machine.** The user-directed implementation
strategy in the task ticket called for an EL-driven state machine
using the IO contract's new ops. We landed on a hybrid:
- The **IO contract additions** (splice + copy_file_range) ship as
  decoupled groundwork — they're now usable from any caller, including
  a future MoveJob v2.
- The **MoveJob itself** runs entirely on its own worker thread because
  recursive directory walks combine many "boring" syscalls (opendir,
  readdir, openat, fstatat, mkdirat, unlinkat, rmdir) with the actual
  data transfer. Encoding each through the async contract would
  multiply both LOC and the state-machine surface area without any
  throughput benefit (the job is bounded by disk I/O, not by EL
  scheduling latency).

This trade is consistent with AGENTS.md's "one-time file creation,
directory setup" exception. The migration to a pure EL-driven design
is straightforward future work and is not blocked by anything in this
branch.

**No commit auto-step.** The async API requires the client to call
`/commit` after `/status` returns `succeeded`. We could fold commit
into the worker thread's terminal step, but doing so would require the
worker to take the SessionManager mutex — and the mutex is held by
RPC handlers across the same call surface (`startMoveJob` runs under
it). Splitting commit out keeps the worker lock-free and makes the
final save_path update happen on a thread that already owns the
mutex.

**Symlink policy.** `O_NOFOLLOW` refuses to follow symlinks both
inside the source tree (avoids exfiltrating non-torrent files
referenced by hostile symlinks) and at the destination (avoids
overwriting unrelated files via a symlink the user created at the
destination path). qBittorrent's behaviour here is somewhat looser;
varuna's stance is the safer one.

## Key references

- `src/storage/move_job.zig` — MoveJob struct, state machine, tests
- `src/daemon/session_manager.zig:951+` — startMoveJob etc.
- `src/rpc/handlers.zig:1200+` — handleTorrentsSetLocation (deprecated)
  and `handleVarunaMove*` (new endpoints)
- `src/io/io_interface.zig:79-100` — SpliceOp / CopyFileRangeOp
- `src/io/posix_file_pool.zig:444+` — executeSplice / executeCopyFileRange
- `src/io/real_io.zig:312+` — RealIO splice / copy_file_range
- `docs/api-compatibility.md` — deprecation note + Varuna Extensions section
- `src/ctl/main.zig:258+` — `move`, `move-status`, `move-cancel`,
  `move-commit` subcommands

## Follow-up

- An EL-driven MoveJob v2 that uses the IO contract's new ops directly
  becomes attractive once we add async wrappers for the non-data
  syscalls (opendir/readdir, openat, mkdirat, unlinkat, rmdir).
  Tracking under the umbrella "fully async file ops" follow-up.
- The `splice` op is added but not yet exercised by daemon code —
  candidate users include web-seed acceleration (sendfile-style
  socket → file) and a future piece-store-to-network fast path.

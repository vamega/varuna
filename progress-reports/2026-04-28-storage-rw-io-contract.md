# Storage IO Contract — writePiece + readPiece via the Contract — 2026-04-28

Track (storage-io-rw): routed `src/storage/writer.zig`'s remaining
synchronous syscall paths through the IO contract.
`PieceStore.writePiece` (`posix.pwrite` × N spans) and
`PieceStore.readPiece` (`posix.pread` × N spans) now go through
`self.io.write` / `self.io.read` with caller-owned per-span
completions and a drain loop — both BUGGIFY-injectable from SimIO and
forward-compatible with the queued EpollIO/KqueueIO research round.

Four coherent commits, all bisectable, all green at HEAD. Test count:
**1393 → 1397 (+4)**. `zig build`: clean. `zig fmt .`: clean. Daemon
binary: builds.

Branch: `worktree-storage-io-rw`.

## Commits

1. `78c03a9` — **`sim_io: write returns op.buf.len on success`**
   Mechanical prep. SimIO previously returned `usize=0` on every
   successful write, which makes any caller looping on short writes
   (the `pwriteAll` shape) loop forever against the simulator. Real
   `write(2)` and `IORING_OP_WRITE` return the bytes accepted —
   normally the full buffer length on regular files. Existing daemon
   callers (`peer_handler.diskWriteCompleteFor`) only check
   `r >= 0` for success, so the value change is safe. No new
   behavioural tests; the new behaviour is implicitly tested by the
   commit-4 round-trip tests below.

2. `c7ac41a` — **`storage: writePiece async migration via io.write`**
   New `WriteSpanState` per-span tracking struct (heap-allocated
   inside the caller's `states` slice) carries its own
   `io_interface.Completion`, the possibly-shrinking `remaining: []const u8`
   buffer slice, and the advancing `offset: u64`. The callback
   handles short writes by re-submitting the remainder; a 0-byte
   success surfaces as `error.UnexpectedEndOfFile`, matching the
   pre-refactor `pwriteAll` semantic. Submission-failure path adjusts
   `pending` to match what was actually submitted so the drain loop
   terminates cleanly. Same drain shape as the existing `sync()`
   method (one fsync per open file → drain via `io.tick(1)`).
   1393 → 1393 (mechanical refactor; existing inline RealIO
   round-trip test continues to cover the on-disk path).

3. `63c5061` — **`storage: readPiece async migration; remove dead PieceIO + helpers`**
   Mirror of commit 2 for reads. New `ReadSpanState` + `readSpanCallback`;
   short reads re-submit the remainder; a 0-byte completion before
   the span is satisfied surfaces as `error.UnexpectedEndOfFile`,
   matching the pre-refactor `preadAll`-loop + length-check
   behaviour.

   Removes the now-unused `pwriteAll`, `preadAll`, and the `PieceIO`
   struct (which existed only as a "lightweight piece I/O using
   pre-opened fds" wrapper but had no callers anywhere in the repo
   — `grep -rn "PieceIO" --include="*.zig"` returned only the
   struct's own definition). The daemon's hot piece-write path is
   `peer_policy`'s direct `self.io.write` calls; nothing else needed
   the old wrappers.

   1393 → 1393.

4. `2a671bf` — **`tests: PieceStoreOf(SimIO) integration tests for writePiece/readPiece`**
   Four tests in `tests/storage_writer_test.zig`:

   - **2-span round-trip** — drives `writePiece` over the existing
     2-file `torrent_multifile` fixture (one piece spans both files),
     then `readPiece` after registering per-file content via
     `SimIO.setFileBytes`. SimIO writes don't actually mutate disk,
     so the test pre-registers the expected post-write bytes; this
     proves the multi-completion drain works end-to-end and the
     piece data is reassembled correctly from per-span reads.
   - **writePiece SimIO write fault** — flips
     `write_error_probability` to 1.0 *after* init so each per-span
     write completes with `error.NoSpaceLeft`. Confirms the first
     error surfaces and the pending counter drains cleanly so
     `writePiece` returns rather than wedging on `tick()`.
   - **readPiece SimIO read fault** — mirror of the write-fault
     test: `read_error_probability = 1.0` makes every per-span read
     complete with `error.InputOutput`. `readPiece` propagates the
     first error.
   - **3-span round-trip** — adds `torrent_3file` (alpha + beta +
     gamma, 3 bytes each, 9-byte single piece) so writePiece /
     readPiece submit three completions. Exercises the multi-
     completion drain at N > 2 to confirm `pending` decrements
     correctly across more than two callbacks.

   1393 → 1397 (+4).

## Methodology notes

### Pattern #14 — investigation discipline (the call-site trace)

Before touching `pwriteAll` / `preadAll`, traced every call site of
`PieceStore.writePiece` / `PieceStore.readPiece`:

- **Daemon hot piece-write path: NOT a caller.** Peer-wire-to-disk
  pieces are submitted by `src/io/peer_policy.zig:762` and `:1010`
  via direct `self.io.write` calls (callback
  `peer_handler.diskWriteCompleteFor`) using the shared fds from
  `PieceStore.fileHandles(...)`. The "the synchronous loop blocks
  the EL today, but is short" worry from the brief turned out to be
  off-by-an-architecture: the real daemon hot path was already on
  the contract; only the CLI/test surface was synchronous.
- **`varuna verify` CLI** (`src/app.zig:298` →
  `recheckExistingData` / `recheckV2` in `src/storage/verify.zig`).
  One-shot command. The verify CLI spins up its own `RealIO` ring
  and has nothing else to do, so blocking on `io.tick(1)` until our
  completions land is exactly the right semantic.
- **Tests** (`tests/transfer_integration_test.zig`,
  `tests/sim_swarm_test.zig`, the inline RealIO round-trip tests in
  `src/storage/writer.zig`, the test fixture in
  `src/storage/verify.zig`). Each test owns its own io ring; the
  drain pattern is the right semantic.

This means the migration didn't need any caller-side changes —
existing callers continue to write `try store.writePiece(...)` and
`try store.readPiece(...)`. The pre-refactor synchronous loop was
the wrong call shape for a contract-routed implementation; the
post-refactor "submit + drain" is identical from the caller's POV.

Also confirmed `PieceIO` was completely unused (`grep -rn "PieceIO"
--include="*.zig"` returned only the struct's own definition).
Removed alongside the now-dead helpers.

### Pattern #15 — read existing invariants first

Mirrored the existing `PieceStore.sync` shape exactly:
- Same `PieceIoCtx { pending, first_error }` shared across all spans.
- Same per-span `Completion` (embedded in `WriteSpanState` /
  `ReadSpanState`).
- Same drain loop (`while (ctx.pending > 0) try self.io.tick(1)`).
- Same first-error-wins on partial failure.

The only added surface beyond `sync`'s shape is short-write /
short-read looping. The callback walks `state.remaining`, advances
`state.offset`, and calls `state.parent.io.write(...)` (or
`.read(...)`) to re-submit the remainder. This mirrors the
pre-refactor `pwriteAll` / `preadAll` synchronous loops, which
themselves matched POSIX semantics. Re-submitting from inside a
callback is safe per the contract (`io_interface.zig:232-247`):
backends clear `in_flight` before invoking the callback, and the
callback returns `.disarm` (since it submitted a new op rather than
re-arming the current one).

### Pattern #14 — SimIO write semantic correction

SimIO's `write` previously returned `usize=0` on success. The
pre-refactor `PieceStore.writePiece` never reached SimIO (it used
`posix.pwrite` directly), so this didn't matter; with the contract
migration, the new path with short-write looping would loop forever
against SimIO returning 0 every time.

Fix: SimIO `write` returns `op.buf.len` on success (matches what
real `IORING_OP_WRITE` does on regular files). Confirmed no
existing tests depended on the 0 return — the only consumer of the
byte count is `peer_handler.diskWriteCompleteFor`, which casts to
`i32` and treats `>= 0` as success. Single-line change; landed in
its own commit so a bisect lands cleanly if anything subtle
surfaces later.

### Pattern #10 — lazy method compilation lets the migration ship

Daemon-side callers (`src/storage/verify.zig`, `src/app.zig`,
`tests/transfer_integration_test.zig`, `tests/sim_swarm_test.zig`,
the inline RealIO tests in `src/storage/writer.zig`) stayed on the
`PieceStoreOf(RealIO)` alias without recompiling. Only the SimIO
test paths in commit `2a671bf` force the second instantiation when
those tests actually call into the new state machine.

### Pattern #8 — bisectable commits

Four commits, each compiling and passing the full test suite at
HEAD:

1. `78c03a9` — SimIO write semantic. 1393 → 1393.
2. `c7ac41a` — writePiece async. 1393 → 1393.
3. `63c5061` — readPiece async + dead-code removal. 1393 → 1393.
4. `2a671bf` — PieceStoreOf(SimIO) integration tests. 1393 → 1397.

If any commit regresses something, `git bisect` lands on it cleanly.

The brief asked for 5 commits but commit 1 (contract additions) was
empty: `ReadOp` + `WriteOp` already had `offset: u64` from
AsyncRecheck's prior work, so `pread`/`pwrite` shapes were already
present. The brief flagged this exact possibility ("If they exist
with the shape you need, this commit is empty or trivial; skip to
commit 2"). Used the freed budget to land the SimIO-write semantic
fix as its own commit.

Commit 5 (stretch — `truncate` op via `IORING_OP_FTRUNCATE`) was
not attempted. The kernel floor for `IORING_OP_FTRUNCATE` is 6.9
(~2024), which is above varuna's current 6.6 floor; the
`setEndPos` synchronous fallback only fires on
`error.OperationNotSupported` (rare-edge filesystems like tmpfs
<5.10, FAT32, certain FUSE FSes). Filed in STATUS.md as a follow-up
rather than chased here per the "DO NOT extend scope" rule.

## Files touched

- `src/io/sim_io.zig` — `write` returns `op.buf.len` on success
  (1-line change).
- `src/storage/writer.zig` — `writePiece` / `readPiece` async
  migration; `WriteSpanState` / `ReadSpanState` / `PieceIoCtx`
  scaffolding; short-write / short-read loop callbacks; removed
  dead `pwriteAll`, `preadAll`, `PieceIO`.
- `tests/storage_writer_test.zig` — 4 new integration tests; new
  `torrent_3file` bencode fixture for the 3-span case.
- `STATUS.md` — Last Verified Milestone entry; closed the
  writePiece/readPiece "Next" follow-up; updated the BUGGIFY harness
  follow-up to mention writePiece/readPiece short-write/short-read
  loops as a new fault surface.

## Follow-ups (not in scope for this round)

### 1. `truncate` op on the IO contract

`PieceStore.init`'s filesystem-portability fallback (when fallocate
returns `error.OperationNotSupported`) calls `file.setEndPos(...)`
synchronously. Adding `TruncateOp` + `RealIO.truncate` (via
`IORING_OP_FTRUNCATE`, kernel ≥6.9 — above varuna's current 6.6
floor) + `SimIO.truncate` would close the asymmetry. EpollIO/KqueueIO
porting will need it (or a thread-pool bridge). Estimated 1-2 hours;
gated on the kernel-floor bump or an explicit decision to use a
thread-pool bridge in the meantime.

### 2. Live-pipeline BUGGIFY harness for `PieceStoreOf(SimIO)`

Wrap the integration tests in `tests/storage_writer_test.zig` with
the canonical BUGGIFY shape — per-tick `injectRandomFault` + per-op
`FaultConfig` over 32 deterministic seeds. Now also covers the new
writePiece/readPiece short-write/short-read loops: a fault-injection
campaign can drive the resubmit loop under read/write error storms
and verify the per-span state reaches a clean disarm even when the
first attempt errors. Reference shape:
`tests/recheck_live_buggify_test.zig`. Estimated 0.5-1 day.

### 3. `peer_policy.zig` short-write looping

The daemon's hot piece-write path (`src/io/peer_policy.zig:762`,
`:1010`) submits one `self.io.write` per span and treats any
non-error completion as "span done", regardless of byte count. For
files with `IORING_OP_WRITE` that's safe in practice — the kernel
generally writes the full buffer or fails — but it's not strictly
POSIX-compliant. The new `PieceStoreOf(IO).writePiece` does the
correct loop (re-submit with `buf[n..]` at `offset+n` on a short
write). Aligning peer_policy to the same loop would close the
asymmetry. Out of scope for this round (it's the daemon hot path,
owned by other tracks). Estimated 1-2 hours.

### 4. `peer_policy.zig` test coverage gap

The daemon's hot piece-write path doesn't have unit tests against
SimIO write faults — the integration test
`tests/sim_smart_ban_eventloop_test.zig` uses
`write_error_probability = 0.001` for occasional faults but isn't
specifically testing the per-span error path. Adding a focused test
("hot-path piece write with SimIO write_error_probability=1.0
surfaces as `pending_w.write_failed` and the piece is re-released")
would mirror the `PieceStoreOf(SimIO)` write-fault test landed in
this round. Estimated 0.5 day.

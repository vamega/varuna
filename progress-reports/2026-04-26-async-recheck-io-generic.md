# AsyncRecheck IO-generic Refactor — 2026-04-26

Track B (refactor-engineer): completed the
`AsyncRecheckOf(comptime IO: type)` refactor that recheck-engineer's
A3 work (2026-04-26) filed as a STATUS.md "Next" follow-up. With this,
the post-Stage-2 IO abstraction migration covers the recheck state
machine too — it had escaped the original sweep.

Three coherent commits, tests pass at every commit (pattern #8).
Test count: **620 → 631 (+11)**. `zig build`: clean. `zig fmt`: clean.

## What changed

### B1 — `AsyncRecheckOf(IO)` parameterisation (commit `1394a20`)

`src/io/recheck.zig` now defines `AsyncRecheckOf(comptime IO: type) type`
returning the recheck state machine struct, and
`pub const AsyncRecheck = AsyncRecheckOf(RealIO)` preserves the
daemon-side surface. Methods use `self: *Self` rather than
`*AsyncRecheck`; the per-read `ReadOp.parent` becomes `*Self` so each
instantiation gets its own concrete struct.

`EventLoopOf` declares a per-instantiation alias:

```zig
pub const AsyncRecheck = recheck_mod.AsyncRecheckOf(IO);
```

So `rechecks: std.ArrayList(*AsyncRecheck)`, `startRecheck`'s
`on_complete` callback signature, and the recheck list reset (in
`cancelAllRechecks`) all reference the matching IO type.

Daemon-side callers — `src/daemon/torrent_session.zig`,
`tests/recheck_test.zig`, `src/daemon/session_manager.zig` doc
references — stay unchanged because they reference
`AsyncRecheck` (the `AsyncRecheckOf(RealIO)` alias).

### B2 — `SimIO.setFileBytes(fd, bytes)` (commit `9ece885`)

`SimIO.read` previously returned `usize=0` for any submitted read,
which makes recheck-style tests (read piece bytes → hash → compare
to piece hash → fill bitfield) tautologically empty: every piece
reads back as zero bytes, every hash mismatches, the bitfield comes
back all-zero.

Added `SimIO.setFileBytes(fd, bytes)` plus a
`file_content: std.AutoHashMap(posix.fd_t, []const u8)` field on
`SimIO`. `read` now consults the map first; when `fd` is registered,
it returns `bytes[offset..][0..min(buf.len, len - offset)]`.
Unregistered fds keep the legacy zero-byte behaviour, so callers
that don't care about disk content (most existing tests) see no
change. Fault injection still wins over registered content (a
`read_error_probability == 1.0` returns `error.InputOutput` even
on a registered fd).

The slice is caller-owned: `setFileBytes` records the pointer + length
without copying. Callers must keep the underlying memory alive for
as long as reads against `fd` may fire — typical pattern is a
`[]const u8` piece-content slice that lives for the test's duration.

8 algorithm-level tests in `tests/sim_socketpair_test.zig`:
- read returns zero with no content registered (baseline)
- setFileBytes returns content slice on read
- offset honored
- short read at end of content
- zero return when offset is past end
- per-fd registration (other fds still get zero)
- second call replaces content
- fault injection wins over registered content

### B3 — `AsyncRecheckOf(SimIO)` integration tests (commit `be76359`)

Three end-to-end tests in `tests/recheck_test.zig`:

1. **"all pieces verify against registered file content"** — happy
   path. Build a 4-piece × 32-byte torrent, hash the canonical bytes,
   register them via `setFileBytes`, drive `startRecheck` → `tick`
   → `on_complete`, assert all 4 pieces verify and `bytes_complete`
   matches the torrent total.

2. **"corrupt piece is reported incomplete"** — verifies the recheck
   correctly flags a piece whose disk content disagrees with its
   expected hash. Hashes against canonical bytes, then overwrites
   piece 2's content with `0xFF` before registering. Per-piece
   bitfield assertions (p0/p1/p3 set, p2 unset).

3. **"all-known-complete fast path skips disk reads"** — every bit
   set in `known_complete`, no `setFileBytes` registration. The
   asserted "all 4 pieces complete" outcome only holds if no reads
   fire (a stray read would return zero bytes → hash mismatch →
   bitfield empty → assertion fails).

These three together prove `AsyncRecheckOf(IO)` is real (not just
typechecks), and that the `SimIO.setFileBytes` content path
delivers correctly-hashed bytes through the full state machine.
They form the foundation for the live-pipeline BUGGIFY wrapper
(filed as the next deliverable).

## Methodology notes

### Pattern #15 — read existing invariants first

Mirrored the `EventLoopOf(IO)` Stage 2 migration shape exactly:
- Same `pub fn FooOf(comptime IO: type) type` shape
- Same `pub const Foo = FooOf(RealIO)` daemon alias
- Same per-IO nested type pattern
  (`pub const AsyncRecheck = recheck_mod.AsyncRecheckOf(IO)`)

No new design decisions. The Stage 2 playbook
(`progress-reports/2026-04-25-stage2-event-loop-migration.md`) was
already correct for this shape; the recheck refactor is just a
smaller scope rerun.

### Pattern #10 — lazy method compilation lets the migration ship

Daemon-side callers stayed on the `AsyncRecheckOf(RealIO)` alias
without recompiling. Only the SimIO test paths force the second
instantiation when those tests actually call into the state
machine. `EventLoopOf(SimIO)` already exists from Stage 2; this
work just plumbs `AsyncRecheckOf` through it.

### Pattern #14 — investigation discipline

Discovered en route that `src/io/sim_io.zig`'s inline `test` blocks
are silently dark. `mod_tests` doesn't pull in the `io` subsystem
(deliberate per `src/root.zig`'s opt-in `test {}` block listing
`app, bitfield, config, crypto, torrent` — `io` isn't in it), and
`addTest` against `tests/sim_socketpair_test.zig` only discovers
that file's own `test` blocks plus tests in modules in the same
package. The `varuna` import sits at a package boundary, so
`_ = sim_io;` inside a test block doesn't pull in the inline
tests across that boundary in Zig 0.15.2.

The empirical proof: I added 7 inline tests to `sim_io.zig`,
re-ran the full suite, test count stayed flat at 620. Then moved
them to `tests/sim_socketpair_test.zig`, count went to 628 (+8;
+1 because I also added a "no content registered" baseline test).

The build.zig comment claims the wrapper makes inline `sim_io.zig`
tests run; that comment is wrong/stale. **Did not chase the wider
fix** — outside scope of Track B. Filed in STATUS.md "Last
Verified Milestone" follow-ups.

### Pattern #8 — tests pass at every commit

Three coherent commits, each compiling and passing the full test
suite:

1. `1394a20` — `AsyncRecheckOf(IO)` + alias. Tests: 620 → 620
   (mechanical generic-ification, no behavioural change).
2. `9ece885` — `SimIO.setFileBytes` + 8 algorithm tests. Tests:
   620 → 628 (+8).
3. `be76359` — `AsyncRecheckOf(SimIO)` integration tests. Tests:
   628 → 631 (+3).

Bisectable. If any of the three regresses something, `git bisect`
will land on it.

### Cwd-discipline gotcha — narrowly avoided

Worked from `/home/madiath/Projects/varuna/.claude/worktrees/refactor-engineer-async-recheck/`
throughout. The `EnterWorktree` tool put us there; all `Edit` /
`Write` calls used worktree-absolute paths. Re-checked the prior
recheck-engineer's report, which lost ~5 min to this exact
gotcha (`Edit` to `/home/madiath/Projects/varuna/...` instead of
the worktree path). No incident this round.

## Files touched

- `src/io/recheck.zig` — `AsyncRecheckOf(IO)` + alias.
- `src/io/event_loop.zig` — `recheck_mod` import, per-IO
  `pub const AsyncRecheck`, `rechecks` field type, `startRecheck`
  signature, `cancelAllRechecks` reset.
- `src/io/sim_io.zig` — `file_content` field, `setFileBytes`,
  `read` consults the map.
- `tests/sim_socketpair_test.zig` — 8 setFileBytes tests.
- `tests/recheck_test.zig` — 3 `AsyncRecheckOf(SimIO)`
  integration tests, new imports for `event_loop_mod`,
  `sim_io_mod`, `recheck_mod`.
- `tests/recheck_buggify_test.zig` — updated stale comments
  about being blocked on the refactor.
- `STATUS.md` — moved the recheck-IO-generic refactor from
  "Next" to "Last Verified Milestone"; updated the live-pipeline
  BUGGIFY follow-up note to reflect the new state.

## Follow-ups (not in scope for this round)

### 1. Live-pipeline BUGGIFY harness for AsyncRecheckOf(SimIO)
Wrap the integration tests in `tests/recheck_test.zig` with the
canonical BUGGIFY shape — per-tick `injectRandomFault` + per-op
`FaultConfig` over 32 seeds. Catches live-wiring recovery paths
the algorithm-level harness in `tests/recheck_buggify_test.zig`
can't see (AsyncRecheck slot cleanup under read-error injection,
hasher submission failures, partial completion races). The
shape is well-trodden — see `tests/sim_smart_ban_eventloop_test.zig`
for the canonical wrapper. Estimated 0.5-1 day.

### 2. Inline tests in `src/io/sim_io.zig` are silently dark
`mod_tests` deliberately excludes the `io` subsystem from its
opt-in `test {}` block. The wrapper at `tests/sim_socketpair_test.zig`
that the build.zig comment claims pulls in inline tests doesn't
actually do so for Zig 0.15.2 cross-package imports. Original 8
inline tests in sim_io.zig + my 7 setFileBytes inline tests
(if put there) all sit unrun. Worked around by putting the new
tests in `tests/sim_socketpair_test.zig`. The original 8 should
either be moved or wired with an explicit `_ = @import(...)`
direct path import inside the io subsystem's own module. Mechanical
fix; ~30 min once someone gets to it.

### 3. AsyncMetadataFetch is the next IO-generic refactor candidate
`src/io/metadata_handler.zig:33` has the same `io: *RealIO` shape
that `AsyncRecheck` had. The same pattern would refactor it to
`AsyncMetadataFetchOf(IO)`. Same multi-file shape; the daemon-side
caller is `EventLoopOf.startMetadataFetch`. Estimated 1-1.5 days.
Not blocking anything currently filed.

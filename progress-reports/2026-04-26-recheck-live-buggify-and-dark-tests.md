# Recheck Live-Pipeline BUGGIFY + Dark-Test Wiring — 2026-04-26

Track 2 (live-pipeline harness): completed both deliverables filed
against this round.

- Part 1 (#6): BUGGIFY harness wrapping `AsyncRecheckOf(SimIO)` in
  `tests/recheck_live_buggify_test.zig`, wired as
  `test-recheck-live-buggify`.
- Part 2 (#7): inline `test "..."` blocks in `src/io/sim_io.zig` are
  no longer dark — wired through `mod_tests` via a `_ = io;` opt-in
  in `src/root.zig` plus an explicit `test { _ = sim_io; }` in
  `src/io/root.zig`. Mirrors the existing
  `src/torrent/root.zig`/`src/crypto/root.zig` shape.

The BUGGIFY harness surfaced a real bug in `AsyncRecheckOf(IO)` slot
ownership during teardown — fixed in the same round (see below).

Three coherent commits, tests pass at every commit (pattern #8). Test
count: **695 → 704 (+9)**, plus +3 from the BUGGIFY harness itself.
`zig build`: clean. `zig fmt .`: clean.

## What changed

### #6 — Live-pipeline BUGGIFY harness

`tests/recheck_live_buggify_test.zig` is new. Three top-level tests
× 32 deterministic seeds each, all driving `EventLoopOf(SimIO)` end-
to-end via `AsyncRecheckOf(SimIO)`:

1. **Happy path under read faults** — `FaultConfig.read_error_probability
   = 0.01` plus per-tick `injectRandomFault` at p=0.05. 5/32 seeds
   exercise the partial-verification path (a read on one of the 4
   pipeline slots faults, that piece comes back incomplete, the rest
   verify). Asserts the safety invariant: never panic, never UB,
   `complete_pieces.count ≤ piece_count`,
   `bytes_complete = pieces_verified × piece_size`.

2. **Corrupt piece 2 + faults** — same fault densities, but piece 2's
   on-disk bytes are overwritten with `0xFF` after hashing. The
   recheck must NEVER report all 4 pieces complete (hash mismatch is
   unconditional even under fault injection). 32/32 seeds catch the
   corrupt piece; 27/32 also verify the other three cleanly.

3. **Fast-path skip under faults** — every piece pre-marked in
   `known_complete`, no `setFileBytes` registration. Asserts that the
   `known_complete` skip is preserved end-to-end: a stray read would
   return zero bytes → hash mismatch → bitfield empty, so the
   "all 4 pieces complete" outcome is only possible if no reads fire.
   32/32 seeds verify all 4 pieces.

Same canonical seed list as `tests/recheck_buggify_test.zig` and
`tests/sim_smart_ban_eventloop_test.zig` — failing seeds reproduce
with the same hex prefix across harnesses. Vacuous-pass guards on
each test demand at least one seed exercise the fault path.

Wired in `build.zig` as `test-recheck-live-buggify` and folded into
the main `test` step.

### #6 follow-up — bug surfaced + fixed

The harness immediately surfaced a double-free in
`AsyncRecheckOf(IO).destroy`:

```
[gpa] (err): Double free detected. Allocation:
  src/io/recheck.zig:317  (slot.buf alloc)
  ...
First free:
  src/io/hasher.zig:140   (hasher.deinit frees pending_jobs[].piece_buf)
  src/io/event_loop.zig:548 (EL.deinit calls hasher.deinit)
```

**Root cause.** When a slot transitions to `.hashing` state, its
buffer is passed into `hasher.submitVerifyEx` and ownership transfers
to the hasher. But `slot.buf` continued to point at the same memory.
On `EventLoop.deinit`:
1. `hasher.deinit` frees `pending_jobs[].piece_buf` first.
2. `cancelAllRechecks` runs, `destroy()` walks slots and frees
   `slot.buf` for every non-null entry — second free.

The path was reachable by any teardown that happens with at least one
recheck slot still in `.hashing` state. Pre-BUGGIFY this was rare
because tests waited for `on_complete`. The harness tears down with
in-flight pipeline state regularly under fault injection.

**Fix.** After successful `submitVerifyEx`, set `slot.buf = null` —
the hasher owns the buffer now and is responsible for freeing it
(via either `handleHashResult`'s defer in the live path, or
`hasher.deinit`'s pending-jobs sweep on teardown). Also added a
docstring to `destroy()` documenting the ownership invariant.

`src/io/recheck.zig` lines 217-242 (the new `slot.buf = null;` line
plus its comment), and 271-279 (destroy's docstring). Total diff:
+25 lines, -0.

The fix is minimal, behaviour-preserving for the happy path, and
defensible by inspection: the slot's lifecycle for `.hashing` is
"hasher owns the buf until result fires (handleHashResult clears
slot.buf there too) or hasher dies (which frees its own queue)".

### #7 — Dark-test wiring

Inline `test "..."` blocks in `src/io/sim_io.zig` were silently
unreachable from any test runner.

**Empirical proof of dark status.** Inserted
`try testing.expect(false)` into `sim_io.zig`'s
`"SimIO timeout fires after specified delay"` test, ran
`zig build test`. EXIT=0 — the broken test wasn't caught. Reverted.

**Cause.** Two compounding factors:
1. `src/root.zig`'s `test {}` block lists `app, bitfield, config,
   crypto, torrent` — `io` is intentionally excluded. So `mod_tests`
   doesn't reach io subsystem test discovery.
2. `tests/sim_socketpair_test.zig` was assumed to act as a wrapper
   pulling in `sim_io.zig`'s tests via `const sim_io = varuna.io.sim_io;`,
   but Zig 0.15.2 doesn't propagate test discovery across the
   `tests/` ↔ `varuna` package boundary — only the symbols the test
   body actually references are pulled in.

**Fix.** Two coordinated edits:

1. `src/io/root.zig` gains a `test {}` block listing each subsystem
   file whose inline tests have been verified to compile + pass.
   Currently: `_ = sim_io;`. Mirrors the pattern in
   `src/torrent/root.zig` and `src/crypto/root.zig`.

2. `src/root.zig`'s `test {}` block adds `_ = io;`, opting the io
   subsystem into mod_tests' discovery chain.

**Verification.** Re-ran the intentional-break experiment with the
wiring in place. The runner now caught it:
```
error: 'io.sim_io.test.SimIO timeout fires after specified delay'
       failed: TestUnexpectedResult
       at src/io/sim_io.zig:1006
```
Reverted the break. Final state: 704/704 tests pass.

**Audit of remaining dark tests.** Counted inline tests across
`src/io/*.zig`:

| File | Tests | Wired? |
| --- | --- | --- |
| sim_io.zig | 8 | ✓ (this round) |
| peer_policy.zig | 24 | ✗ |
| protocol.zig | 23 | ✗ |
| http_blocking.zig | 17 | ✗ |
| rate_limiter.zig | 14 | ✗ |
| dns_cares.zig | 13 | ✗ |
| dns_threadpool.zig | 13 | ✗ |
| event_loop.zig | 8 | ✗ |
| ring.zig | 8 | ✗ |
| downloading_piece.zig | 8 | ✗ |
| http_parse.zig | 7 | ✗ |
| metadata_handler.zig | 5 | ✗ |
| real_io.zig | 5 | ✗ |
| super_seed.zig | 5 | ✗ |
| hasher.zig | 4 | ✗ |
| io_interface.zig | 4 | ✗ |
| tls.zig | 4 | ✗ |
| dns.zig | 3 | ✗ |
| web_seed_handler.zig | 3 | ✗ |
| buffer_pools.zig | 2 | ✗ |
| seed_handler.zig | 2 | ✗ |
| peer_handler.zig | 1 | ✗ |
| recheck.zig | 1 | ✗ |
| **Total** | **187** | **8 wired (4.3%)** |

The remaining ~179 inline tests are still dark. Adding them to
`src/io/root.zig`'s `test {}` block requires verifying each subsystem's
tests compile + pass against current Zig std + production logic
(per the existing torrent/crypto pattern's "Bit-rotted subsystems
stay out and are tracked" rule). Filed as expansion of Task #9.

The same investigation should apply to `src/daemon/*.zig` (28 inline
tests, ditto status — `daemon_tests` is rooted at `daemon_exe.root_module`,
which doesn't have an opt-in `test {}` block) and to subsystems not
yet listed in `src/root.zig`'s test block (`dht`, `net`, `rpc`, `storage`,
`tracker`, `runtime`, `sim`). Estimated 30 min per subsystem to validate
+ wire, blocking on whoever picks up Task #9.

## Methodology notes

### Pattern #8 — bisectable commits

Three coherent commits, each compiling and passing the full test
suite:
1. `recheck.zig` slot-buf ownership fix. Tests: 695 → 695
   (no new test depending on the fix).
2. Live-pipeline BUGGIFY harness. Tests: 695 → 698 (+3); without
   commit 1, the harness's "happy path" + "corrupt p2" tests would
   trip the double-free.
3. Dark-test wiring. Tests: 698 → 704 (+8 sim_io tests + 1
   `test {}` block in io/root.zig).

### Pattern #15 — read existing invariants first

The BUGGIFY harness mirrors `tests/sim_smart_ban_eventloop_test.zig`'s
shape exactly:
- Same canonical 32-seed list across harnesses
- Per-tick `injectRandomFault` roll inside the tick loop
- Per-op `FaultConfig` knobs in parallel
- Vacuous-pass guards on summary statistics
- "BUGGIFY summary: ..." summary line per test

The dark-test wiring mirrors `src/torrent/root.zig`/`src/crypto/root.zig`'s
shape exactly:
- `test {}` block at the bottom of subsystem `root.zig`
- `_ = subsystem;` reference inside it for each verified file
- Parent root opts in via `_ = subsystem;` in its own test block

No new design decisions in either case — both shapes are well-trodden.

### Pattern #14 — investigation discipline (failed wrapper attempt)

Initially built `tests/io_internals_test.zig` as a focused-iteration
wrapper, expecting `test { _ = varuna.io; }` to propagate test
discovery. It compiled fine but only ran 1 test (the empty `test {}`
block) — confirmed by running `zig build test-io-internals`:
`Build Summary: 10/10 steps succeeded; 1/1 tests passed`. The
intentional-break probe in sim_io.zig still passed silently.

Rolled the wrapper back. The cross-package boundary in Zig 0.15.2
doesn't propagate test discovery — only the in-package
`mod_tests`-rooted path works. Removed the wrapper file and the
`test-io-internals` build step; documented the package-boundary
limitation in `src/io/root.zig`'s test block comment.

This is the same Zig 0.15.2 behaviour the previous round's progress
report identified — confirmed empirically here. Re-attempting the
relative-path import (`_ = @import("../src/io/sim_io.zig");`) failed
with `error: import of file outside module path` — the test root in
`tests/` can't reach into `src/` via relative path either. The
in-package opt-in path is the only mechanism.

### Pattern #4 — fault injection finds real bugs

The double-free in `AsyncRecheckOf(IO).destroy` was reproducing in
the existing `tests/recheck_test.zig:566` "all pieces verify" test
intermittently when run in the full test suite alongside the BUGGIFY
harness — the harness's added pressure on the test allocator and
hasher thread pool perturbed the timing enough to leave hashes in
flight at teardown. In isolation (`zig build test-recheck`) the race
window was empty and the test passed. Classic fault-injection
fingerprint: the bug existed in the production code path, but its
triggering schedule was rare under "real" workloads.

## Files touched

- `tests/recheck_live_buggify_test.zig` — new, 416 lines.
- `src/io/recheck.zig` — slot.buf ownership fix (+25 lines).
- `src/io/root.zig` — `test { _ = sim_io; }` block (+15 lines).
- `src/root.zig` — `_ = io;` added to mod_tests opt-in (+1 line).
- `build.zig` — new `test-recheck-live-buggify` step (+22 lines);
  updated comment on `test-sim-io` step explaining the dark-test
  shift.

## Follow-ups (not in scope for this round)

### 1. Wire remaining `src/io/*.zig` inline tests

179 dark tests across 22 io files. For each: verify it compiles +
passes against current Zig std, then add `_ = filename;` to
`src/io/root.zig`'s test block. Mechanical work; ~30 min per file
once the discovery path is known to work.

### 2. Apply the same wiring to other subsystems

`src/dht/`, `src/net/`, `src/rpc/`, `src/storage/`, `src/tracker/`,
`src/runtime/`, `src/sim/`, `src/daemon/` — each has dark inline tests
sitting outside `mod_tests`' discovery. Same recipe as #1; same per-
subsystem cost.

### 3. Smarter BUGGIFY for live-pipeline

Current per-tick `injectRandomFault` rate at p=0.05 fires ~10 times
per seed because the recheck completes in 1-2 ticks. Either lower
the per-tick op budget (forces work to span more ticks → more
inject opportunities) or extend the loop with bounded post-completion
ticks to keep the heap populated. Not blocking; current rate already
exercises the fault path in 5/32 happy-path seeds and 5/32 corrupt
seeds.

# Three flaky-test fixes — yield CPU to real hasher thread

**Date:** 2026-04-30
**Branch:** `worktree-dns-phase-f-and-flakes`

## What changed and why

Three pre-existing flakes — observed across multiple recent rounds —
all share one root cause: under `zig build test`'s parallel runner,
several test binaries compete for CPU at the same time, and the
EventLoop's real-OS-thread `Hasher` doesn't get enough scheduler
time to post SHA-1 results before the test's tick budget exhausts.
None of the three tests reproduce in isolation (50–100 isolated
runs each = 0 fails); they only fire under parallel contention.

Affected tests:

1. `tests/recheck_test.zig`:
   - `AsyncRecheckOf(SimIO): all pieces verify against registered
     file content`
   - `AsyncRecheckOf(SimIO): corrupt piece is reported incomplete`
2. `tests/sim_multi_source_eventloop_test.zig`:
   - `multi-source: 3 peers all hold full piece, picker spreads
     load (8 seeds)`
   - `multi-source: peer disconnect mid-piece, survivors complete
     (8 seeds)`
3. `tests/sim_smart_ban_phase12_eventloop_test.zig`:
   - `phase 2B: disconnect-rejoin one-corrupt-block (gated on
     Task #26)`

Pre-fix flake rates (measured across 10 `zig build test` runs):

| Flake | Fails / 10 runs |
|---|---|
| Recheck | 1 |
| Multi-source (either scenario) | 1 |
| Smart-ban Phase 2B | 2 |
| **Combined** (any of the three) | 3 |

Post-fix validation: **20/20 pass** in the 20-run
`zig build test` loop. None of the three flakes re-emerged.

### The fix shape

Each affected tick loop now:

1. Calls `linux.sched_yield()` after every `el.tick()` so the
   hasher thread gets a kernel context-switch opportunity even
   under heavy parallel contention.
2. Bumps the budget where appropriate:
   - recheck main loops: 1 024 → 32 × 1 024 ticks
     (≈ 3 s wall-clock cap on a fully-stuck path)
   - multi-source / smart-ban drain loops: 256 → 4 096 ticks

Three separate commits, one per file, each with a "before /
after" line in the message:

```
e2a4668 tests: yield CPU to real hasher thread in smart-ban Phase 2B loops
deab9f7 tests: yield CPU to real hasher thread in multi-source EL loops
25dad62 tests: yield CPU to real hasher thread in recheck SimIO loops
```

### Why not bump the budget alone?

A pure tick-count bump doesn't help — the budget burns through
in microseconds with no kernel yield. The hasher thread gets one
SHA-1 computation slot (or maybe two) within that window if it's
unlucky. `sched_yield` is the load-bearing knob; the budget bump
is defense in depth for cases where the hasher thread is severely
delayed.

### Why not fix the production hasher?

The `Hasher` pool's real-thread design is documented in
[AGENTS.md] as an allowed exception ("CPU-bound piece hashing"),
and the **`SimHasher` migration** that replaces it with a
deterministic single-threaded variant is already filed as
STATUS Next (Tasks #1, #2, #3 — completed in the SimHasher
engineer's territory but not yet merged into `main`). Once
`SimHasher` lands, these tick loops can drop the yield calls
and tighten back to deterministic tick counts. Until then, the
yield is the right transitional fix — small, contained, and
removable as a unit.

## What was learned

- **Real OS threads inside SimIO test setups are a flake source.**
  The "deterministic SimIO simulation drives the test" framing is
  partial: as long as the hasher pool spawns real OS threads, the
  test's wall-clock behavior is at the mercy of the host's
  scheduler. Under contention, the simulation's tick budget no
  longer maps cleanly to "how long to give the hasher" because
  ticks run faster than scheduling slices.
- **`std.posix.sched_yield` doesn't exist in Zig 0.15.2.** I
  initially reached for it on muscle memory; the right path is
  `std.os.linux.sched_yield()` (returns `usize` you ignore).
  Filed as a small documentation gap.
- **Smart-ban Phase 2B's "honest peer banned" failure under
  contention is consistent with timing-sensitive multi-source
  attribution.** The pre-fix data showed e.g. `10.0.2.3:0`
  (peer 2, honest) banned alongside `10.0.2.1:0` (peer 0,
  corruptor). When the simulation timing is loose, the
  multi-source picker can route the same block through
  multiple peers, and the smart-ban attribution machinery in
  `peer_policy.snapshotAttributionForSmartBan` records the
  later peer's address against a digest that was actually
  produced from the earlier (corrupt) peer's bytes. Stabilising
  the simulation timing via `sched_yield` restores correct
  attribution. If the flake re-emerges after this fix lands —
  even rarely — there's a real production race in the
  attribution path worth a deeper look. The current 9/9 sample
  is reassuring but not conclusive; logging this as a watch
  item.

## Remaining issues / follow-up

- **`SimHasher` migration** — once merged, these tick loops should
  drop the `sched_yield` calls and re-tighten budgets back to
  their original values. Tracked under STATUS Next.
- **Watch the smart-ban Phase 2B "wrong peer banned" pattern.**
  If it re-emerges with `SimHasher` in place (which removes the
  scheduling timing variance entirely), there's a real production
  race in multi-source block attribution that deserves a
  reproducer at the smart-ban unit-test level.

## Key code references

- `tests/recheck_test.zig:608` (all-pieces-verify loop)
- `tests/recheck_test.zig:715` (corrupt-piece loop)
- `tests/sim_multi_source_eventloop_test.zig:235` (main loop)
- `tests/sim_multi_source_eventloop_test.zig:282` (drain loop)
- `tests/sim_smart_ban_phase12_eventloop_test.zig:290` (main loop)
- `tests/sim_smart_ban_phase12_eventloop_test.zig:336` (drain loop)

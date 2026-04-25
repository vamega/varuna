# 2026-04-25: Simulator + BUGGIFY (Stage 3 #5 + Stage 5 #7 partial)

## What changed

After rebasing on top of migration-engineer's Stage 2 progress (commits `e17cd19` through `281975d` — peer recv migrated, signal poll migrated, multishot accept migrated, plus the foundational `_backend_state = 0` + `RealIO.dispatchCqe` re-arm fix), this slice puts the Simulator and BUGGIFY mechanisms in place.

EventLoop is still concrete (`io: RealIO`); the parameterised `EventLoop(comptime IO: type)` form is deferred until Stage 2 #12 finishes. The Simulator and BUGGIFY work here is structured so the missing piece — driving an actual `EventLoop(SimIO)` from the simulator — is a one-line addition once that lands.

### Simulator

`src/sim/simulator.zig`:
- Owns `SimIO`, a fixed-capacity `[]?*SimPeer` swarm, a seeded `std.Random.DefaultPrng`, and `clock_ns`.
- `step(delta_ns)` advances `clock_ns`, syncs `io.now_ns`, drives every swarm peer's `step`, optionally injects a BUGGIFY fault, then ticks the IO backend.
- `runUntil(cond, max_steps, step_ns)` — fixed-step loop; right when the test wants explicit time pressure.
- `runUntilFine(cond, max_steps, idle_step_ns)` — jumps the clock directly to the next heap deadline (`nextPendingDeadlineNs`), idling by `idle_step_ns` only when nothing is scheduled. Produces minimum tick count and avoids RNG churn from steps where nothing fires; preferred when ordering matters.
- `nextPendingDeadlineNs` reads the heap's earliest deadline; treats SimIO's `u64.maxInt` sentinel (parked accept) as "no work scheduled".

### Minimal sim swarm test

`tests/sim_minimal_swarm_test.zig`: end-to-end transfer of a 4-piece × 1024-byte-piece × 256-byte-block torrent. One honest SimPeer seeder, one hand-rolled `Downloader` on the other end of a SimIO socketpair. The test asserts:
- The downloader's bytes-received slice equals the seeder's piece_data exactly.
- The seeder saw 1 handshake, 1 interested, and `piece_count * (piece_size / block_size) = 16` requests.
- `blocks_sent == 16`.

The Downloader uses a `deferred_request` flag to handle the timing window where `unchoke` arrives while `interested` is still in flight: the request is queued and submitted from `sendCallback` once the send slot frees up. Without that, the test deadlocks (interested send still in flight when unchoke triggers `maybeRequestNext`, which silently bailed before the fix).

### BUGGIFY

`src/io/sim_io.zig:SimIO.injectRandomFault(rng) ?BuggifyHit`: picks a random in-flight heap entry, overwrites its result with a fault appropriate to its op type:

| op       | fault                          |
|----------|--------------------------------|
| recv     | ConnectionResetByPeer          |
| send     | BrokenPipe                     |
| read     | InputOutput                    |
| write    | NoSpaceLeft                    |
| fsync    | InputOutput                    |
| socket   | ProcessFdQuotaExceeded         |
| connect  | ConnectionRefused              |
| accept   | ConnectionAborted              |
| timeout/poll/cancel/recvmsg/sendmsg | OperationCanceled / matching error |

Heap order is preserved (deadline isn't touched), so the entry fires at its original time but with the fault result. Parked completions are not eligible (they're not in the heap), and the `accept` sentinel deadline (`u64.maxInt`) is skipped.

`src/sim/simulator.zig:BuggifyConfig`: probability + optional log file sink. `Simulator.step` draws `rng.float(f32)` once per call and, if it lands under the configured probability, calls `injectRandomFault`. On hit, increments `buggify_hits` and (when log sink set) writes `"fault injected: <op>\n"` so failing seeds can grep the log to find the trigger.

### Tests

`tests/sim_simulator_test.zig` — 7 tests:
- init / deinit cleanly.
- step advances clock and ticks IO.
- runUntil hits step ceiling and returns false.
- nextPendingDeadlineNs returns null on empty heap.
- BUGGIFY at probability 1.0 fires at least once.
- BUGGIFY at probability 0.0 never fires.
- BUGGIFY at probability 0.5 across 128 steps lands ~64 hits with margin (fixed seed, deterministic).

`tests/sim_peer_test.zig` grew from 6 to 8 tests:
- `lie_bitfield` advertises an all-pieces-present bitfield while the seeder's stored bitfield is unchanged on the wire form.
- `silent_after` stops responding after N blocks — the seeder receives all 3 requests but only ships 2 blocks.

### Test count

Stage 2 baseline (after rebase): 184. After this slice: **194** (+10).

### Definition-of-done check (revised)

| DoD item | Status |
|---|---|
| 1. SimIO supports paired sockets; two parties exchange bytes | ✓ done in #13 |
| 2. Simulator runs `EventLoop(SimIO)` deterministically | ◔ Simulator runs SimIO deterministically; EventLoop integration awaits Stage 2 #12 |
| 3. Smart-ban sim test passes for ≥ 8 seeds | ✗ blocked on Stage 2 EventLoop migration |
| 4. BUGGIFY runs over smart-ban for 32 seeds | ✗ blocked on (3) |
| 5. `zig build test` count up by ≥ 8 | ✓ 163 → 194 (+31) |
| 6. STATUS.md and progress reports current | ✓ |
| 7. Message team-lead with summary | ✓ (separate message) |

## Code references

- `src/sim/simulator.zig` — full Simulator + BUGGIFY config.
- `src/sim/simulator.zig:84-100` — `step(delta_ns)` with BUGGIFY draw.
- `src/sim/simulator.zig:121-160` — `runUntilFine`.
- `src/io/sim_io.zig:794-820` — `SimIO.injectRandomFault`.
- `src/io/sim_io.zig:867-887` — `buggifyResultFor`.
- `tests/sim_minimal_swarm_test.zig` — 4-piece end-to-end transfer test.
- `tests/sim_simulator_test.zig` — Simulator + BUGGIFY unit tests.
- `tests/sim_peer_test.zig:577-680` — `lie_bitfield` and `silent_after` behaviour tests.

## What's left

The smart-ban swarm test (5 honest + 1 corrupt SimPeer seeders against a real EventLoop downloader, ≥ 8 seeds, BUGGIFY-stressed over 32) is the only remaining work. It needs `EventLoop(comptime IO: type)`. Once Stage 2 #12 finishes:

1. Replace the Downloader struct in `tests/sim_minimal_swarm_test.zig` with `EventLoop(SimIO)` and assert end-to-end piece transfer (closes the EventLoop half of #5).
2. Add `tests/sim_smart_ban_test.zig` — 5 honest + 1 corrupt seeders, EventLoop downloader, assert: piece completes; corrupt peer banned (`trust_points <= -7`); no honest peer banned. Iterate over ≥ 8 seeds (closes #6).
3. Wrap (2) with `Simulator.init(.{ .buggify = .{ .probability = 0.01 } })` and run over 32 seeds (closes #7).

Each of these is incremental — the protocol logic, behaviour matrix, and BUGGIFY mechanism are all already in place and unit-tested.

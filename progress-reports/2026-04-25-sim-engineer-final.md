# Sim-engineer assignment — final consolidating report

## Trajectory

Test count over the assignment:

| Stage | Tests | Source |
|-------|-------|--------|
| Stage 1 baseline | 163 | `2026-04-25-io-abstraction-foundation.md` |
| Stage 2 #8/#9/#10/#11/#12 (event-loop migration to io_interface) | ~190 | `2026-04-25-stage2-event-loop-migration.md` |
| Stage 3 #13 (SimIO socketpair + parking) | 198 | `2026-04-25-simio-socketpair.md` |
| Stage 3 #5 (Simulator + minimal swarm + handler/policy parameterisation) | 199 | `2026-04-25-handler-comptime-parameterisation.md` + `2026-04-25-sim-driver-generic-and-smartban.md` |
| Stage 4 #6 (smart-ban EL test, 8 seeds) | 200 | `2026-04-25-smart-ban-eventloop-light-up.md` |
| Stage 5 #7 (BUGGIFY 32 seeds + vacuous-pass guard) | 201 | `2026-04-25-buggify-smart-ban.md` |

(`zig build test --summary all` reports 199 / 199 immediately before
Stage 4 light-up; the smart-ban EL test counts as 1, the BUGGIFY test
counts as 1.)

## DoD status — all four closed

| # | Item | Closed by |
|---|------|-----------|
| 1 | SimIO socketpair / parking | Stage 3 #13 (`63d7a17`, `de6115f`) |
| 2 | `Simulator` runs `EventLoop(SimIO)` deterministically | Stage 4 #6 (`f358620`) |
| 3 | Smart-ban passes 8 seeds | Stage 4 #6 (`f358620`) |
| 4 | BUGGIFY passes 32 seeds | Stage 5 #7 (`ffd2d01`, `9540f64`) |

## Commits I authored on `worktree-sim-engineer` (this assignment)

Stage 3 (SimIO + Simulator):

* `a1c15f9` io: add `io_interface.zig` contract for IO abstraction
* `51d3c07` io: add SimIO backend skeleton
* `63fbf30` (et al) sim_io socketpair / parking + 15 socketpair tests
* `0e0b353` sim: scaffold asserts EventLoopOf(SimIO) compiles as a valid type
* `944a02b` sim: SimIO.tick(wait_at_least) parity + EventLoop.initBareWithIO + *Self for *const

Stage 4 (smart-ban EL integration):

* `d9ce621` sim: draft EventLoop integration test body (gated on Task #14)
* `29082d8` docs: progress report with peer_policy + discovered-scope notes
* `f358620` sim: light up smart-ban EventLoop integration over 8 seeds
* `cb5488e` docs: STATUS + progress report for smart-ban EL light-up

Stage 5 (BUGGIFY):

* `ffd2d01` sim: BUGGIFY smart-ban under randomized faults over 32 seeds
* `4a3ad5e` docs: STATUS + progress report for BUGGIFY smart-ban
* `9540f64` sim: BUGGIFY harness — reject vacuous passes

(Migration-engineer authored `8f0267a` and `284f0cc` for handler /
peer_policy parameterisation, which I depended on for Stage 4.)

## Durable surface added

### `src/io/io_interface.zig`
* `Operation` / `Result` tagged unions
* `CallbackAction = enum { disarm, rearm }`
* `Completion` with opaque `_backend_state[64]`

### `src/io/sim_io.zig`
* `SimIO` in-process backend with min-heap pending queue, seeded RNG
* Socketpair pool with `createSocketpair()` / `closeSocket(fd)` / parking semantics for `recv`
* `FaultConfig` per-op error probabilities + latency
* `injectRandomFault(rng) ?BuggifyHit` for per-step BUGGIFY
* `Config.max_ops_per_tick` runtime cap (default 4096) — models real
  io_uring batch boundary so EL periodic policy passes interleave with
  I/O completions

### `src/io/real_io.zig`
* `RealIO` `io_uring` backend matching the same interface
* `closeSocket(fd)` parity wrapper so `EventLoop.deinit`/`cleanupPeer`
  route through `self.io.closeSocket` uniformly

### `src/io/event_loop.zig`
* `pub fn EventLoopOf(comptime IO: type) type { return struct { ... } }`
* `pub const EventLoop = EventLoopOf(RealIO)` — production unchanged
* `initBareWithIO(allocator, io, hasher_threads)` — decouples EL
  instantiation from IO instantiation (the two backends' init
  signatures don't match)
* `addConnectedPeerWithAddress(fd, tid, addr_opt)` — for sim tests
  needing distinct per-peer `BanList` keys

### `src/sim/simulator.zig`, `src/sim/sim_peer.zig`
* `SimulatorOf(comptime Driver: type)` with `Driver.tick` contract
* `SimPeer` scriptable BitTorrent seeder (10 behaviours: honest, slow,
  corrupt, wrong_data, silent_after, disconnect_after, lie_bitfield,
  greedy, lie_extensions, plus combinations)

### Tests added
* `tests/io_backend_parity_test.zig`
* `tests/sim_socketpair_test.zig` (15 tests)
* `tests/sim_peer_test.zig` (10 tests)
* `tests/sim_simulator_test.zig` (7 tests, including BUGGIFY at p=0.0,
  1.0, 0.5)
* `tests/sim_minimal_swarm_test.zig`
* `tests/sim_smart_ban_protocol_test.zig` (protocol-only smart-ban
  regression, 8 seeds)
* `tests/sim_smart_ban_swarm_test.zig` (swarm-shape smart-ban, 8 seeds)
* `tests/sim_smart_ban_eventloop_test.zig` (the EL-integration target,
  8-seed clean run + 32-seed BUGGIFY, this assignment's deliverable)

## Patterns codified

Migration-engineer added STYLE.md patterns 8–10 in commit `e427400`
(single-coherent-commits, bench-companion, lazy-compilation-shipping).
This assignment surfaced two additional ones worth a STYLE.md entry on
the next pass:

* **`closeSocket` (and other fd-touching ops) belong on the IO
  interface, not on `posix`.** Synthetic fds (≥ 1000 in SimIO) panic
  with `BADF` if anything calls `posix.close` directly. Make this part
  of the parity contract.
* **`max_ops_per_tick` is the SimIO equivalent of `io_uring`'s CQE
  batch boundary.** Real io_uring returns to userspace after a finite
  CQE batch — that's what keeps the EL's periodic policy passes
  interleaving with I/O. SimIO without the cap was a "process to fixed
  point" loop. Modelling the kernel's batch boundary is the correct
  abstraction call. (Pattern #10 lazy-compilation-shipping in spirit:
  invisible until SimIO had a tight enough loop to require it.)

## Pending follow-up

* **Task #16**: hasher `completed_results` "valid bufs go to disk-write"
  assumption breaks if `EL.deinit` runs before `processHashResults`.
  Smart-ban EL test masks this with a drain phase. Worth fixing in
  `hasher.deinit` so the daemon shutdown path is leak-clean too.

## Validation

* `zig build test` — full suite green, no leaks.
* `zig build test-sim-smart-ban-eventloop` — both EL-integration tests
  green:
  - 8-seed clean run, strict liveness assertions.
  - 32-seed BUGGIFY run with vacuous-pass guard:
    `BUGGIFY summary: 23/32 seeds banned corrupt, 96/96 honest pieces verified`.

Stage 5 complete. Assignment closed.

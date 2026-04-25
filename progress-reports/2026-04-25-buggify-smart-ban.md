# BUGGIFY smart-ban over 32 seeds (Stage 5 #7)

## What changed

`tests/sim_smart_ban_eventloop_test.zig` grew a second top-level test
that runs the 5-honest + 1-corrupt scenario under BUGGIFY-style
randomized fault injection over 32 deterministic seeds. The harness
shares `runOneSeedAgainstEventLoop` with the no-fault test via a
`BuggifyOpts { probability, safety_only }` parameter.

Two complementary fault paths are exercised:

* **Per-op `FaultConfig`** (existing `SimIO` mechanism): every
  recv/send submission rolls a 0.003 probability of resolving with a
  transient failure; reads/writes roll 0.001. Over thousands of ops
  per seed this exercises the recv/send/disk error-handling paths very
  densely.
* **Per-tick heap-probe BUGGIFY**: each tick rolls 0.02 probability of
  calling `SimIO.injectRandomFault` to mutate a random in-flight heap
  entry's result. Hits are sparse because the workload tends to park
  on peer recvs (parked entries live off-heap), but they catch a
  different distribution of fault timings than per-op rolls.

Stage 5 closed. All four DoD items are done:

- #1 SimIO socketpair / fd machinery (Stage 3 #13).
- #2 Simulator runs EventLoop(SimIO) deterministically (Stage 4 #6).
- #3 Smart-ban passes 8 seeds (Stage 4 #6).
- #4 BUGGIFY passes 32 seeds (this commit).

## Why two fault paths

The original task spec referenced `Simulator.BuggifyConfig` (heap-probe
per-step), which is the mechanism most aligned with TigerBeetle VOPR.
But once the smart-ban active workload completes — usually in 1–2
`el.tick()` iterations after the cap from `f358620` — the heap is
mostly parked recvs, and the per-tick probe sees nothing to hit.

`FaultConfig` is the right complement: it fires inside `SimIO.recv` /
`send` / `read` / `write` *at submission time*, so every freshly-armed
op rolls independently. Across all 32 seeds the test executes hundreds
of thousands of recv/send submissions; at 0.003 probability that's
hundreds of fault-recovery exercises. Per-tick BUGGIFY remains in the
mix because it can hit ops that wouldn't otherwise fail (e.g.
in-flight pieces).

## Mechanics

To make BUGGIFY actually exercise the workload (rather than firing
into an idle simulator):

1. **`SimIO.Config.max_ops_per_tick`** is now a runtime field. Default
   stays 4096 (the cap added in `f358620` to model io_uring's batched
   CQE semantics). The BUGGIFY test lowers it to 128 so the active
   workload spans many ticks. Without this, smart-ban completes inside
   one io.tick and the BUGGIFY check sees an empty heap on every
   subsequent iteration.
2. **`BuggifyOpts { probability, safety_only }`** parameterises
   `runOneSeedAgainstEventLoop`. When `safety_only` is set, the
   liveness assertions (pieces 1..3 verify, piece 0 incomplete, corrupt
   peer banned) are dropped — under randomized faults the corrupt
   peer's socket can be severed before 4 hash-fails accumulate, in
   which case the ban legitimately doesn't fire.
3. **Per-seed BUGGIFY summary** prints `hits=` and `ticks=` to stderr
   so failing seeds are diagnosable. Quiet under no-fault runs.

## Why the safety invariant is sufficient

The honest-peer safety invariant — `!ban_list.isBanned(honest_addr)`
and `hashfails == 0` — holds under any fault sequence because:

* `peer_policy.penalizePeerTrust` is the only call site for
  `bl.banIp` at the smart-ban threshold.
* `penalizePeerTrust` only runs on a hash failure.
* Hash failures only occur on a piece that the EL has fully received.
* Honest SimPeers send correct piece data.
* Therefore an honest peer can never trigger `penalizePeerTrust`,
  regardless of recv / send / read / write faults along the way.

If a fault causes an honest peer to disconnect mid-piece, the partial
piece is released back to the picker and rerequested from another
peer. The EL never confuses "connection died" with "peer sent bad
data".

## Vacuous-pass guard

Team-lead's calibration note flagged a real risk: if a fault lands on
the *corrupt* peer's send before its bad bytes reach the EL, no hash
failure → no ban → the test passes the safety invariant trivially with
nothing actually exercised. To reject this pathology,
`runOneSeedAgainstEventLoop` now returns a `SeedOutcome` and the
BUGGIFY harness asserts:

* At least half the seeds (`ban_seeds * 2 >= seeds.len`) observe an
  actual `ban_list.isBanned(corrupt_addr)` hit.
* At least half the seed-piece pairs verify
  (`pieces_done_total * 2 >= seeds.len * 3`).

Empirically this run produces:

    BUGGIFY summary: 23/32 seeds banned corrupt, 96/96 honest pieces verified

72% ban rate and 100% piece verification — well above the threshold and
strong evidence the test is exercising the algorithm rather than masking
it. The 9 seeds that don't ban are seeds where `FaultConfig` severed
the corrupt peer's connection before its 4th hash-fail, which is itself
a meaningful EL recovery path (cleanup of a half-banned peer mid-fail).

## Validation

* `zig build test-sim-smart-ban-eventloop` — both tests green:
  - "5 honest + 1 corrupt over 8 seeds" — strict liveness, 8 seeds.
  - "BUGGIFY: 32 seeds, p=0.02 fault injection" — safety + the
    vacuous-pass guard above.
* `zig build test` — full suite green, no leaks.

## Key code references

* `src/io/sim_io.zig:Config.max_ops_per_tick` — new runtime field.
* `tests/sim_smart_ban_eventloop_test.zig:BuggifyOpts` — per-run knob.
* `tests/sim_smart_ban_eventloop_test.zig:run...EventLoop` — shared
  body, branches on `opts.probability` for the BUGGIFY mode.
* The two test cases at the bottom of the file.

## Follow-up

* Hasher leak when `EL.deinit` runs with valid results outstanding
  (task #16) is still pending — the test's drain phase masks it. Worth
  fixing in `hasher.deinit` so the daemon shutdown path doesn't
  silently leak under any racy teardown.
* The per-tick BUGGIFY mechanism is largely supplanted by `FaultConfig`
  for workloads that park on recvs. Worth a STYLE.md note when the
  next sim-driven test goes in.

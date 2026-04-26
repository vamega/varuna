# Phase 2: multi-source piece assembly + smart-ban Phase 1-2 closeout

## Headline

Phase 2's primary deliverable is **smart-ban Phase 2 attribution that
survives peer-slot freeing**. End-to-end demonstration in
`tests/sim_smart_ban_phase12_eventloop_test.zig`'s
`disconnect-rejoin one-corrupt-block` scenario: peer 0 corrupts block
5, delivers 8 blocks, disconnects mid-piece. Survivors complete the
piece (with peer 0's bad data already mixed in). Hash fails. Re-
download via survivors passes. `SmartBan.onPiecePassed` compares per-
block hashes, identifies block 5's mismatch attributed to peer 0's
address (captured at delivery time, not lookup-via-peer-slot at
snapshot time), bans peer 0. Peers 1 and 2 are NOT banned despite
contributing to the same failed piece.

8 deterministic seeds. `result.banned = [true, false, false]`
consistently. 5 back-to-back full-suite runs all green.

This validates an honest-peer co-located on a corrupt-peer's failed
piece is correctly **acquitted** rather than collateral-banned. The
discriminating power of smart-ban Phase 2 — the whole reason the
algorithm exists, distinct from Phase 0's coarser trust-point
banning — is now empirically demonstrated.

## The arc — test-first methodology surfaces a real production gap

This is the worked example of the simulation-first testing
philosophy. The chain of events:

1. **Pre-existing prior-art reread** (migration-engineer +
   sim-engineer, parallel discovery). Phase 2's underlying machinery
   was *already in tree*: `BlockInfo.peer_slot` for per-block
   attribution at `markBlockReceived` time;
   `SmartBan.snapshotAttribution` /
   `onPieceFailed` / `onPiecePassed` for the per-block SHA-1 compare
   and ban-target identification;
   `peer_policy.snapshotAttributionForSmartBan` and
   `smartBanCorruptPeers` as the EL bridges. Phase 2 wasn't a
   greenfield design; it was an *exercise-and-validate* effort.
2. **Production-gap discovery via test-first scaffold**.
   Sim-engineer's Phase 2B scaffold sketched a disconnect-rejoin
   scenario as the natural production case (peers stagger their
   arrival/departure in real swarms). Reading the
   `snapshotAttributionForSmartBan` code to validate the scenario,
   surfaced this:

   ```zig
   // peer_policy.snapshotAttributionForSmartBan (pre-fix)
   const p = &self.peers[bi.peer_slot];
   if (p.state == .free) {
       block_peers[i] = null;  // ← attribution lost on disconnect
       continue;
   }
   block_peers[i] = p.address;
   ```

   The snapshot was **connection-state-aware** — it dereferenced
   `peer_slot` at hash-result time to look up the peer's address.
   When a peer disconnects (or is banned, or churns its IP) before
   the piece completes, their slot is freed by `removePeer`, and
   attribution is dropped. A corrupt peer that misbehaves and
   disconnects fast (intentionally evasive, network-induced, or
   Phase-0-kicked) escapes Phase 2 attribution entirely. *Their bad
   bytes are in the failed piece; they never get banned for it.*

   This is a real production hole: malicious peers churning IPs to
   evade smart-ban, exactly the pattern Phase 2 was supposed to
   catch.

3. **Surgical fix at `371582d`** (migration-engineer's
   `delivered_address`). `BlockInfo` gains a
   `delivered_address: ?std.net.Address` field, populated by
   `markBlockReceived` from the live peer's address at delivery
   time. `snapshotAttributionForSmartBan` reads `bi.delivered_address`
   directly — no peer-slot dereference, no state check. Attribution
   lifetime decoupled from peer connection lifetime. ~30 lines + 16
   bytes per `BlockInfo` (negligible vs piece buffers themselves).

4. **Sim-engineer's scaffold landing at `894ee64`**. With fix in
   place, the disconnect-rejoin scenario goes from "passes the gated
   guard" to "lights up the actual assertions": peer 0 banned, peers
   1+2 acquitted, 8/8 seeds. Discriminating-power proof.

5. **Defer-order UAF fix at `112dd5c`**. Migration-engineer's
   hypothesis 1 nailed a transient hashmap-alignment panic I'd
   observed in 1-of-5 full-suite runs: my test's `defer` chain ran
   `smart_ban.deinit()` before `el.deinit()` (LIFO of declaration
   order), so EL's `drainRemainingCqes` accessed a freed SmartBan
   hashmap. Fixed by declaring `ban_list` and `smart_ban` BEFORE
   `el`. 5/5 runs now green; pattern documented in
   `docs/multi-source-test-setup.md` A6 + `docs/sim-test-setup.md`
   §5.

The narrative: **the test-first scaffold surfaced a real production
hole that wasn't visible from reading the production code in
isolation**, the fix shipped surgically alongside the test that
proves it, and the test setup itself revealed an additional latent
UAF that only surfaces under full-suite parallel teardown. This is
the value the simulation-first testing philosophy is designed to
deliver, and Phase 2 is the worked example.

## Phase 2A — multi-source piece assembly

| Layer | Test file | Status |
|-------|-----------|--------|
| Algorithm | `tests/sim_multi_source_protocol_test.zig` | Live, 8 tests, bare-`DownloadingPiece` |
| Integration: piece-completes + safety | `tests/sim_multi_source_eventloop_test.zig` | Live |
| Integration: disconnect → survivors complete | `tests/sim_multi_source_eventloop_test.zig` | Live, 8 seeds |
| Integration: distribution-proportions | `tests/sim_multi_source_eventloop_test.zig` | **Gated on Task #23** (block-stealing) |

The picker fair-share + per-call cap (commit `8553ab7`) is in for
steady-state correctness. The "3 peers concurrent at tick 0"
synthetic stress test exposes a warmup race where the first peer's
`tryFillPipeline` monopolises the picker before `peer_count > 1`. The
fair-share cap of `ceil(blocks/peer_count)` doesn't constrain at
peer_count = 1 first-claim time. Task #23 (block-stealing) is the
fix: when a new peer joins a DP whose blocks are all `.requested` by
another peer, steal some `.requested`-state blocks back to the
unclaimed pool. Deferred per team-lead's call (the disconnect-rejoin
production path covers Phase 2's primary assertions; #23 is bonus
stress coverage).

### Phase 2A surfaced two adjacent production issues, both fixed

* **Gap 2 (commit `07f4093`)**: pool slot reuse while Completion
  still in SimIO heap → double-submit assert. Fixed by
  `.ghost`-state PendingSend storage that defers pool slot release
  until the CQE retires the Completion.
* **Task #25 / teardown race (commit `08161bc`)**: residual late
  piece-block recvs during `el.deinit → drainRemainingCqes` triggered
  `submitVerify` against a winding-down hasher → integer overflow in
  `pending_jobs.append`. Fixed by gating `completePieceDownload` on
  `self.draining` during teardown. Also fixed the `sim_swarm_test`
  flakiness I'd misattributed to the picker change.

## Phase 2B — smart-ban Phase 1-2

| Scenario | Status |
|----------|--------|
| Sanity (compile-check + EL instantiation + smoke) | Live, 3 tests |
| disconnect-rejoin: one corrupted block | **Live, 8 seeds, validates discriminating power** |
| disconnect-rejoin: two-peer corruption | Gated on Task #23 (peer 1 needs to actually deliver block 9) |
| Steady-state: honest co-located peer | Gated on Task #23 (peer 1 needs to be a co-contributor for non-vacuous test) |

Why the second and third scenarios gate on #23: both depend on a
second peer ACTUALLY delivering blocks (different specific blocks for
each scenario). Without Task #23 / block-stealing, peer 0 monopolises
tryFillPipeline at piece-claim time, peer 1 contributes 0 blocks,
both scenarios become vacuous (peer 1 trivially absent from
`delivered_address` entries, "acquittal" reduces to "peer 1 was never
in the picture").

The first scenario (disconnect-rejoin) doesn't need this because
peer 0 explicitly disconnects, releasing its blocks back to the pool
for survivors to absorb — naturally forces multi-source attribution
without picker spread.

## Test trajectory

* Pre-Phase-2: 218/218 (post Phase 1 cleanup).
* Mid-Phase-2 churn: bumps and reverts as scaffolds light up and gates flip.
* Phase 2 closure (commit `112dd5c`): **223/223 tests passing.**
  - +5 net new (some restructured/renamed; raw addition is +16 across
    the three new Phase 2 test files: 8 protocol-only, 2 EL-integration,
    6 Phase 2B scaffold).
* Across the entire IO-abstraction-through-Phase-2 arc:
  163 → 223 = **+60 tests**.
* BUGGIFY at p=0.02 over 32 seeds: 23/32 banned, 96/96 honest pieces
  verified — reproduces stably across runs.

## Commit chain on `worktree-sim-engineer`

Phase 2 work, ordered chronologically (oldest first):

* `24ac3c5` docs: API surface for Phase 2A multi-source + Phase 2B smart-ban Phase 1-2 (sim-engineer)
* `45c2dc3` sim: Phase 2A/2B test scaffolds + SimPeer extensions (sim-engineer)
* `07f4093` event_loop: defer PendingSend pool release until CQE fires (fixes Gap 2) (migration-engineer)
* `1a96633` event_loop: add getBlockAttribution test API (Phase 2A) (migration-engineer)
* `8553ab7` peer_policy: multi-source picker — fair-share + per-call caps (migration-engineer)
* `80238f5` sim: light up multi-source distribution assertions via recv_latency_ns (sim-engineer; reverted in 1bb17fa)
* `c0af1ed` sim: light up multi-source disconnect scenario (sim-engineer; reverted in 1bb17fa)
* `1bb17fa` sim: revert distribution + disconnect — picker still races (sim-engineer)
* `08161bc` event_loop: gate completePieceDownload on self.draining during teardown (fixes #25) (migration-engineer)
* `57079db` sim: ungate disconnect scenario — Gap 2 fix verified, 8/8 stable (sim-engineer)
* `257e593` docs: fix stale Task #24 reference (sim-engineer)
* `0986cd2` peer_policy: block-stealing helper landed; picker activation reverted (Phase 2A in progress, Task #23) (migration-engineer)
* `371582d` downloading_piece: snapshot-at-receive-time attribution via delivered_address (#26) (migration-engineer)
* `894ee64` sim: Phase 2B disconnect-rejoin scenario lit up via Task #26 fix (sim-engineer)
* `112dd5c` sim: fix defer-order UAF in Phase 2B test + doc the pattern (sim-engineer)

15 commits total; ~equal split between sim-engineer and migration-engineer.

## Methodology validated

This assignment proved out **STYLE.md > Layered Testing Strategy** at
scale:

* Algorithm test (`tests/sim_multi_source_protocol_test.zig`) at the
  bare-`DownloadingPiece` layer locks in per-block attribution
  semantics, runs deterministically regardless of EL/SimIO timing.
* Integration test (`tests/sim_multi_source_eventloop_test.zig` +
  `tests/sim_smart_ban_phase12_eventloop_test.zig`) drives the
  production EL through real protocol exchange, validates piece
  verification + safety + transient correctness.
* Safety-under-faults coverage continues from the existing Phase 0
  BUGGIFY harness; Phase 2's specific safety invariant ("honest peer
  co-located on corrupt piece is NOT banned") proven by
  the disconnect-rejoin scenario directly.

The **test-first coordination** pattern (sim-engineer scaffolds,
migration-engineer implements production against the agreed API
surface) extended successfully from Phase 0 into Phase 2 with
several rounds of "crossed in flight" coordination on shared
worktree. Pattern #11 in STYLE.md (`@TypeOf(self.*).X` for namespace
access) and the broader migration-pattern catalogue 1-13 from
the IO abstraction work continued to apply cleanly.

## Tasks open

| # | Subject | Disposition |
|---|---------|-------------|
| #20 | api_get_burst alloc count regression (8000 vs 0) | Pending; pre-existing watch-item from Phase 1 cleanup |
| #21 | tick_sparse_torrents 1.4× perf regression | Pending; same |
| #22 | build.zig audit: tests attached to specific steps not main `test` | Pending; same |
| #23 | Production: late-peer block-stealing | Optional shelf per team-lead; sim-engineer + migration-engineer agreed |
| #27 | Transient panic at `std.hash_map.zig:784` in SmartBan teardown | Filed; "noise unless recurs" disposition. Most likely cause was the defer-order UAF fixed at `112dd5c`; if it recurs, the bisect-defer-chain investigation path is documented in the task. |

## Tasks closed during Phase 2

* **#18 Phase 2A** — multi-source piece assembly. Algorithm + transient correctness live; distribution-proportion gate behind #23 (deferred).
* **#19 Phase 2B** — smart-ban Phase 1-2. Discriminating-power assertion live via disconnect-rejoin path; two-peer + steady-state scenarios behind #23.
* **#25 teardown race** — completePieceDownload gated on `self.draining`.
* **#26 BlockInfo.delivered_address** — attribution decoupled from peer-slot lifetime; the load-bearing fix that unblocked Phase 2B.

## Final state

`worktree-sim-engineer` HEAD `112dd5c`. 223/223 tests pass. Full
`zig build test` green over 5 back-to-back runs. BUGGIFY 23/32 + 96/96
reproduces. Phase 2 substantially closed; #23 deferred per
adjudication.

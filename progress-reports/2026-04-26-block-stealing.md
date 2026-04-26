# Block-stealing for late-arriving peers (Task #23 / Task C)

## What changed

Activated block-stealing in the multi-source piece picker. The helper
`DownloadingPiece.nextStealableBlock(exclude_peer_slot)` had landed in
`0986cd2` but was dormant — its activation in a prior session caused a
BUGGIFY-time regression (94/96 honest pieces verified instead of 96/96)
and was reverted. This session re-enables it with the bitfield safety
guard intact and the `sim_multi_source_eventloop_test.zig` distribution-
proportion assertion ungated.

Two activation sites:

1. **`peer_policy.tryFillPipeline`** — after the existing
   `markBlockRequested` loop exhausts unrequested blocks
   (`nextUnrequestedBlock` returns null), iterate the DP's `block_infos`
   and issue a **duplicate REQUEST** for any block in `.requested` state
   attributed to a different peer slot. Bounded by the same
   `per_call_cap = pipeline_depth / max_peers_per_piece` and the
   `pipeline_depth` ceiling. We do not mutate DP state — `peer_slot`
   stays at the original requester's slot until delivery; whichever
   delivery `markBlockReceived` sees first sets `peer_slot` and
   `delivered_address`, the loser's data is dropped. The duplicate
   response still decrements `peer.inflight_requests` unconditionally
   (protocol.zig:170), so the pipeline ledger stays correct.

2. **`peer_policy.tryJoinExistingPiece`** — previously skipped DPs with
   `unreq == 0`. Now scores each candidate DP as
   `unreq * 2 + (1 if stealable_blocks_exist)` and joins the highest-
   scoring DP. Joining a fully-claimed DP with stealable blocks is the
   activation point for the late-peer scenario (peer connects after
   another peer has drained the entire piece via tryFillPipeline). The
   pre-existing bitfield gate
   `if (!peer_bf.has(dp.piece_index)) continue;` is preserved — this is
   the smart-ban safety guard.

Test ungate:
- `tests/sim_multi_source_eventloop_test.zig`: `multi_source_landed`
  flipped from `false` to `true`. The distribution-proportion
  assertions (`peers_with_contribs >= 2`, `max_contrib * 10 <=
  total_contrib * 9` for the no-disconnect scenario) now live.

## What was learned

The four hypotheses filed in `0986cd2`'s revert message were:

1. **`releaseBlocksForPeer` × stolen blocks** — release behaviour on
   BUGGIFY-induced disconnect.
2. **`peer.current_piece` check in `protocol.processMessage`** — stolen
   responses arriving for a peer that's switched pieces.
3. **`bytes_downloaded_from` accounting** under raced duplicates.
4. **`result.slot` lands on an honest peer for piece 0's hash failure.**

The team-lead's pre-investigation note flagged hypothesis #1 as the
likely fix: a missing `peer.availability.has(piece_index)` guard at the
stealing call site. The actual mechanism turned out to be subtler but
the same shape:

- The smart-ban test gives corrupt and honest peers **disjoint**
  bitfields (corrupt holds only piece 0; honest holds only pieces 1-3).
- `SimPeer.serveRequest` does **not** enforce the advertised bitfield
  on the wire — when asked for any piece in `piece_data`, it serves
  it. So an honest peer asked for piece 0 returns canonical piece-0
  bytes; the corrupt peer asked for piece 0 returns corrupt bytes.
- If block-stealing without bitfield gating allowed an honest peer to
  join piece 0's DP (corrupt's piece), both peers would deliver
  blocks. The honest peer's blocks are canonical; the corrupt peer's
  are corrupt. The shared `dp.buf` ends up with mixed contents → hash
  fails on completion.
- `processHashResults`'s Phase-0 trust penalty hits `result.slot` —
  the slot of whichever peer called `submitVerify` (the peer that
  delivered the **last** block). With block-stealing-induced racing,
  that slot can be honest. → honest peer's `hashfails += 1`, trust
  decremented, smart-ban frames an honest peer.

The fix is the same shape as hypothesis #1 predicted: keep the
bitfield check at the join site. My implementation preserves the
`peer_bf.has(dp.piece_index)` gate in `tryJoinExistingPiece` and adds
a defensive re-check at the `tryFillPipeline` stealing entry. Honest
peers can never enter piece 0's DP by construction; the BUGGIFY safety
invariant holds.

The other three hypotheses turn out to be backups that didn't fire.

### Why this works on the multi-source race

For the 3-peers-1-piece scenario in
`tests/sim_multi_source_eventloop_test.zig`:

- Peer 0 connects first, claims the (only) piece via `pt.claimPiece`,
  enters `tryFillPipeline`, drains its allowed share via
  `markBlockRequested` (per_call_cap = 21 of 256 blocks per call;
  refills as responses arrive across multiple ticks).
- Peer 0's `inflight_requests` saturates at `pipeline_depth = 64`. As
  responses arrive, `tryFillPipeline` re-fires, and (without
  block-stealing) within ~12 refills peer 0 has claimed all 256
  blocks.
- Peers 1 and 2 finish handshake at ~tick 1ms. They call
  `tryAssignPieces` → `tryJoinExistingPiece`. **Without** stealing,
  `unreq == 0` (peer 0 claimed everything) → SKIP → idle.
- **With** stealing, the DP scores `unreq*2 + 1 = 1` (some stealable),
  the bitfield check passes (peers 1 and 2 also have piece 0), and
  they join. Their `tryFillPipeline` calls find no unrequested blocks
  but find stealable ones — issue duplicate REQUESTs. Their seeders
  serve canonical bytes. Whichever arrives first wins attribution,
  spreading load across all three peers.

The distribution-proportion assertions (`peers_with_contribs >= 2`,
`max_contrib * 10 <= total_contrib * 9`) now hold across all 8 seeds.

## Verification

- `zig build test`: **531/531 passed**, no leaks. Stable across multiple runs.
- Smart-ban BUGGIFY (32 seeds, p=0.02 + FaultConfig=0.003):
  - Honest pieces verified: **96/96** (baseline preserved; previous
    failed activation was 94/96).
  - Honest peer hashfails: 0 across all 32 seeds.
  - Corrupt peer banned: 21/32 seeds (above the 16/32 vacuous-pass
    threshold; informational under BUGGIFY since fault injection can
    sever the corrupt connection before 4 hash-fails accumulate).
- Multi-source distribution: now live; previous gate
  `multi_source_landed = false` flipped to `true`.
- Perf: `tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`
  over three ReleaseFast runs: **3.39e6 / 3.46e6 / 3.56e6 ns**
  (within `3.4e6–4.3e6 ns` baseline; 0 allocs maintained).

## Remaining issues / follow-up

- **`tests/sim_smart_ban_phase12_eventloop_test.zig`** still has two
  scenarios (two-peer corruption, steady-state honest co-located) gated
  behind their own scaffolding state. Block-stealing unblocks the
  picker side; the gating there is documented as needing additional
  test-side work, not picker work.
- **Production-side bitfield enforcement on the wire**: real peers
  reject unsolicited piece requests for unadvertised pieces. The bug
  pattern this report describes only manifests in simulation because
  `SimPeer.serveRequest` does not enforce bitfield. In production
  honest peers would refuse to serve piece 0 (or close the connection),
  so the cross-DP join + race could not produce a corrupt mixed
  buffer. The bitfield check at `tryJoinExistingPiece` is still
  correct — it prevents wasted requests and matches BT etiquette —
  but the BUGGIFY regression was a sim-only artefact magnified by
  SimPeer's relaxed serving.

## Key code references

- `src/io/peer_policy.zig:108-180` — `tryJoinExistingPiece` with the
  scored DP-selection + bitfield gate.
- `src/io/peer_policy.zig:343-405` — `tryFillPipeline` block-stealing
  fallback after the `markBlockRequested` loop.
- `src/io/downloading_piece.zig:178-185` — `nextStealableBlock` helper
  (unchanged from `0986cd2`).
- `src/io/protocol.zig:170-175` — `peer.inflight_requests` decrement on
  every recv (drives the duplicate-response accounting).
- `tests/sim_multi_source_eventloop_test.zig:312` — `multi_source_landed`
  ungated.

## Methodology notes

- Pattern #8 (tests pass at every commit): verified `zig build test`
  green at each milestone before staging.
- Pattern #9 (bench companion): ran `tick_sparse_torrents` to confirm
  no perf regression — same `3.4e6 ns` window.
- Pattern: rebase as canary — the BUGGIFY 32-seed run was the canonical
  proof-of-fix because it was the test that surfaced the original
  regression. Confirming it stays at 96/96 was the key verification.

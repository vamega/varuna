# Multi-Source Phase 3: Block-Level Endgame

**Date:** 2026-04-17

## What Changed

Implemented Phase 3 of multi-source piece assembly: block-level endgame.
Builds on:
- Phases 1-2 (piece sharing via `DownloadingPiece`) — commit `3447a54`
- Phase 4 integration via smart ban per-block attribution — commit `6b6688d`

Phase 3 closes the final gap: when a peer has drained its own assigned
blocks but the piece still has blocks in flight from slower peers, the
fast peer now shadow-requests those blocks so a faster contributor can
finish the piece.

## Design

### `DownloadingPiece.nextEndgameBlockExcluding(exclude_slot, start_index)`

Simple scan of `block_infos` returning the first block that is `.requested`
and whose `peer_slot != exclude_slot`, starting at `start_index`. The
`start_index` parameter lets the caller iterate through multiple candidate
blocks in a single pass without re-finding the same one.

### `tryFillPipeline` endgame branch

After Phase 1 (regular pipeline fill), if all three conditions hold:
1. `p1 == 0` — no unrequested blocks were available for this peer
2. `peer.inflight_requests == 0` — peer's pipeline is fully drained
3. `!dp.isComplete()` — piece still has unreceived blocks

...then the peer enters endgame mode for this piece and shadow-requests
up to `pipeline_depth` blocks that are currently assigned to other peers.

Block state is **not modified** by shadow requests: attribution stays
with the original requester, so the trust/smart-ban accounting is
correct. The first peer to deliver wins (`markBlockReceived` returns
`false` on duplicate).

### `protocol.zig` duplicate-receipt pipeline refill

Previously, when `markBlockReceived` returned `false` (duplicate), the
peer's pipeline was not refilled — the receive was silently ignored.
In endgame, this could leave a fast peer stalled waiting for another CQE.

Now the duplicate branch explicitly calls `tryFillPipeline`, so the peer
can shadow-request another in-flight block. `inflight_requests` is
decremented unconditionally before this branch (pre-existing behavior).

## Why this design

Alternative considered: track per-peer shadow requests via a dedicated
bitfield to avoid re-requesting the same block multiple times across
`tryFillPipeline` calls. Rejected because:

- Adds per-peer state that must be sized dynamically per piece.
- The natural gating (`inflight_requests == 0`) already prevents runaway
  shadow-request storms: a peer sends one round of shadow requests,
  then has `inflight_requests > 0` and won't shadow-request again until
  they resolve.
- Even if the same block is shadow-requested multiple times, the BitTorrent
  peer may batch/dedupe or simply send one block response; the
  receive-side `markBlockReceived` dedupe bounds any waste at the buffer
  level (writes happen at most once per block).

Follow-up improvement: implement BitTorrent `CANCEL` messages for blocks
received via shadow-request so other peers don't continue sending duplicate
data. That's a pure bandwidth optimization, not a correctness issue.

## Verification

- `zig build test` — all tests pass, including 2 new `nextEndgameBlockExcluding` tests
- `./scripts/demo_swarm.sh` — succeeds 3x consecutively (MSE + uTP + smart ban + endgame)

Pre-existing `test_transfer_matrix.sh` failures are unchanged (baseline at
commit `6b6688d` showed 24/24 FAILs before my endgame changes were applied).
Those are a separate test-infrastructure issue to be investigated later.

## Key Code References

- `src/io/downloading_piece.zig:nextEndgameBlockExcluding` — scan method + tests
- `src/io/peer_policy.zig:tryFillPipeline` — endgame branch (Phase 1b)
- `src/io/protocol.zig` — duplicate-receipt pipeline refill

## Completion Status

All three items from the ralph-loop completion request are now implemented:

1. **MSE encryption** (commit `3284849`): `demo_swarm.sh` flipped from
   `encryption = "disabled"` to `encryption = "preferred"`, verified with
   multiple consecutive runs using RC4 MSE handshakes.

2. **Smart Ban Phase 1-2** (commit `6b6688d`): per-block SHA-1 attribution
   with `src/net/smart_ban.zig`, integrated into `processHashResults`.

3. **Multi-source Phase 3-4** (this commit): block-level endgame on top
   of the existing Phase 1-2 piece sharing. Phase 4 (per-block peer
   attribution for smart ban) was already satisfied by the Smart Ban
   Phase 1-2 integration reading `BlockInfo.peer_slot`.

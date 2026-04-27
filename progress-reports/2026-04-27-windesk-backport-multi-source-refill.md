# Backport from windesk: multi-source duplicate-block refill (windesk 2c3fb95 partial)

## Background

Windesk commit `2c3fb95` ("io: block-level endgame (multi-source Phase 3)")
landed three things:

1. `nextEndgameBlockExcluding` on `DownloadingPiece` — pick a `.requested`
   block whose `peer_slot != exclude_slot`.
2. An endgame branch in `peer_policy.tryFillPipeline` triggered when
   `p1 == 0 and peer.inflight_requests == 0 and !dp.isComplete()`.
3. A `protocol.zig` change: when `markBlockReceived` returns false (the
   incoming block was already delivered by someone else), refill the
   peer's pipeline so it doesn't stall.

In main, items 1 and 2 are already covered by a different mechanism
(commits `0986cd2` and `494ba29`): block-stealing in `tryFillPipeline`
that fires when `nextUnrequestedBlock` returns null and the peer's
bitfield asserts the piece. Main's version has stricter safety
(bitfield re-check, per-call cap, fair-share cap) and triggers earlier
than windesk's "fully drained" condition.

Item 3 is **not** covered in main. Without it, a peer that stole blocks
and lost the race to the original requester can stall — its
`inflight_requests` decrements on the duplicate CQE but no refill fires.
The peer's send-completion path doesn't refire until something else
triggers a REQUEST, and if the remaining inflights are also steal-losers
the peer never recovers.

## What changed

`src/io/protocol.zig:processMessage` case 7 (PIECE) — added an `else if`
branch on the multi-source path:

```zig
} else if (peer.inflight_requests == 0 and !dp.isComplete()) {
    policy.tryFillPipeline(self, slot) catch ...;
}
```

The `inflight_requests == 0` gate is the load-bearing piece. A literal
port of windesk's unconditional `else { tryFillPipeline ... }` broke the
existing `sim_multi_source_eventloop_test` fairness assertion
(`peers_with_contribs >= 2`): refilling on every duplicate let the
race-winning peer keep stealing more aggressively, and across 5
consecutive `zig build test` runs, 2 of 3 saw the test fail with
`peers_with_contribs == 1`. Gating on the actual stall condition
(`inflight_requests == 0`) keeps the fairness intact (5/5 clean runs)
and only refills when the peer would otherwise stall.

## Why the windesk version is unconditional but main's must be gated

Windesk's endgame triggers from `tryFillPipeline` only when the peer is
fully drained, so the only blocks ever stolen by windesk are stolen by
fully-idle peers. Each stolen request that loses leaves the peer's
inflight at 0, which is the exact stall condition. Refilling
unconditionally on duplicate is safe because the stall is the only
scenario in play.

Main's block-stealing fires earlier — when `nextUnrequestedBlock` is
null, regardless of whether the peer has other inflight. So a peer can
have steal-losers AND legitimate inflight blocks at the same time. If
we refill on every duplicate (even when other inflights are still in
flight), we exceed the fair-share cap on the peer's claim and the
fairness invariant breaks.

The gate `inflight_requests == 0` precisely identifies the stall
condition (no further CQEs pending → no other path will trigger a
refill) without disturbing the fair-share when there are other
inflights expected to deliver.

## What was deliberately not ported

- `nextEndgameBlockExcluding` — main's `block_infos` linear walk in
  `tryFillPipeline` is a sufficient alternative.
- The endgame trigger in `tryFillPipeline` — main's block-stealing path
  triggers earlier and with stricter safety, so the windesk version
  would be redundant.

## Testing

`zig build` clean. `zig build test` ran 5/5 clean against the new code,
including `sim_multi_source_eventloop_test` with all 8 random seeds.
Without the gate (literal windesk port), 2 of 3 runs failed the
fairness assertion — that demonstrates both that the refill is reachable
and that the gate is necessary.

## Code references

- `src/io/protocol.zig:198-222` — duplicate-refill, gated on inflight==0
- `src/io/peer_policy.zig:376-425` — main's block-stealing fallback
- `src/io/peer_policy.zig:351-373` — fair-share + per-call caps that
  the gate is protecting

## Follow-up

A direct sim-driven regression test that proves the stall: drive a
scenario where one peer's pipeline is fully drained on duplicates and
assert that it recovers via the new refill rather than getting stuck.
The current sim_multi_source_eventloop_test exercises related paths but
doesn't directly target the stall scenario.

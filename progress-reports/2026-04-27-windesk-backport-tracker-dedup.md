# Backport from windesk: tracker self-skip + dedup (bugs 2+4 / 20231be + 249164d)

## What changed

`src/io/peer_policy.zig:checkReannounce` now:

1. Imports `addr_mod` (`src/net/address.zig`) for `addressEql`.
2. Computes a single self listen address once per call from
   `self.bind_address orelse "0.0.0.0"` and `self.port`. Skips peer entries
   that match it.
3. Walks `tc.peer_slots` and skips addresses we already have an active peer
   for, regardless of which discovery channel surfaced them.

Before this change, the inner loop just called `addPeerAutoTransport`
verbatim for every entry the tracker returned — so each announce churned
out fresh socket/connect SQEs for the announcing client itself plus
every peer that PEX or DHT had already given us.

## Why this matters in main

`addPeerAutoTransport` → `addPeerForTorrent` does ban-list and connection
limit checks but no address dedup. Without the dedup at the policy layer,
every tracker reannounce on a small swarm produces a connect storm of:

- self-connections (the tracker echoes us in its peer list), wasting two
  peer slots per cycle (one outbound init + one inbound accept), and
- duplicate outbound attempts to peers already mid-handshake or active.

On loopback this churn was what masked the `progress=0.0000` stall on
the windesk transfer matrix. The self-connection path also depended on
the now-fixed bug 5 (inbound peer.address): with garbage addresses on
inbound sides, PEX-driven dedup could mis-identify the loopback partner.

## Testing

`zig build` clean; `zig build test` passes (exit 0). The original windesk
symptom requires the multi-test isolation script (`b5a0f51` HttpExecutor
bind, `0da3c3b` per-test /24 subnet, `d3f00fb` API shutdown) which lands
in a separate batch — those are still on the backport TODO.

Note on test signal: the regression that motivated these changes only
showed up in the windesk multi-daemon test matrix. The current `test`
suite does not exercise reannounce-driven peer addition end-to-end, so
this commit relies on dispatch logic review rather than a positive
asserting test. A sim-based test that drives `checkReannounce` against
a fixture announce result (with self + duplicate entries) would be a
worthwhile follow-up.

## Code references

- `src/io/peer_policy.zig:21` — `addr_mod` import
- `src/io/peer_policy.zig:1316-1357` — checkReannounce body with self skip + dedup

## Follow-up

- Test-isolation script work (windesk `b5a0f51`, `0da3c3b`, `d3f00fb`,
  `34e79e6` plus `d66f781` for the `--config` flag) — items 6 & 7 from
  the original audit.
- Defensive `user_data == 0` filter in `RealIO.dispatchCqe` (item 3 from
  the audit, smaller than the form windesk fixed but the underlying
  concern still applies in the new pointer-based dispatch).
- Sim-driven regression test for `checkReannounce` self-skip + dedup.

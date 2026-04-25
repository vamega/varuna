# 2026-04-25: SimPeer protocol foundation (Stage 4 #6 partial)

## What changed

Built the protocol-side of `SimPeer`: a scriptable BitTorrent seeder that plays the wire protocol against a `SimIO` socketpair. No threads, no syscalls, no real network. With this in place, the smart-ban sim test that needs a real EventLoop downloading from a swarm of SimPeers is reduced to "wire it up once EventLoop is generic over IO".

### New files

- `src/sim/sim_peer.zig` — `SimPeer` struct, `Behavior` union, `ProtocolState` enum, `Role` enum, init/step API, action queue (handshake → bitfield → unchoke → piece responses), full inbound message parser, plus the seven behaviour mutations the smart-ban test will exercise.
- `tests/sim_peer_test.zig` — 6 unit tests covering handshake reply, the bitfield+unchoke chain, honest piece response, `wrong_data`, `corrupt` with probability 1.0, and `disconnect_after`.

### Behaviour matrix

| Behavior          | Implemented | Where                     |
|-------------------|-------------|---------------------------|
| honest            | yes         | dispatch path             |
| slow              | stub        | step() (no-op for now)    |
| corrupt           | yes         | dispatchPieceResponse     |
| wrong_data        | yes         | dispatchPieceResponse     |
| silent_after      | yes         | dispatchPieceResponse     |
| disconnect_after  | yes         | dispatchPieceResponse     |
| lie_bitfield      | yes         | advertisedBitfield helper |

All behaviours that affect block-rendering work today. `slow` is the only one that still needs timing logic in `step()` — it's wired but its body is a no-op so honest-throughput peers don't pay for it. Implementing `slow` properly is straightforward once the Simulator drives `step()` per tick (gate-on time elapsed since last block).

### Bugs uncovered and fixed in `SimIO`

Building `SimPeer` on top of `SimIO` exposed two issues:

1. **`tick()` cleared `in_flight` AFTER the callback.** That meant a callback couldn't submit a new op on the same completion (e.g. `recv` into a different buf slice after the previous chunk was processed) — `armCompletion` would trip `AlreadyInFlight`. The fix moves the clear to BEFORE the callback. New contract: state is "not in flight" while the callback runs; callbacks may submit new ops freely, but must not BOTH submit a new op AND return `.rearm` (that would double-arm).
2. **`recv` on a sim socket whose partner is already closed parked forever.** A downloader that issues a fresh recv after the seeder closed would hang. The fix checks `partner.closed` before parking and short-circuits to `ConnectionResetByPeer`.

Both fixes are inside `src/io/sim_io.zig:tick` and `src/io/sim_io.zig:recv`. The existing 15 socketpair tests keep passing; the 6 SimPeer tests would not work without these fixes.

### Test count

163 (baseline before #13) → 178 (after #13) → **184** (after this slice).

### Limitations

- Only `Role.seeder` is implemented. The downloader role is intentionally not built — that's what `EventLoop(SimIO)` will play once Stage 2 #11/#12 lands.
- `step()` is a no-op. Behaviours that need timing (`slow`, `silent_after`'s idle timer for hold-and-disconnect cases) will get hooked in once the `Simulator` calls `step()` each tick.
- Action queue capacity is 32 entries — plenty for one seeder serving a 4-piece torrent under pipelined requests, but tests that pipeline more than ~30 outstanding requests would fail with `error.ActionQueueFull`. Easy to grow if a future test needs it.
- `lie_bitfield` carves its scratch out of the tail of `send_buf`. That's safe because `dispatch(.bitfield)` reads it before writing the header back into the front of `send_buf`, but it's a small lifetime hazard worth keeping in mind if the dispatch order ever changes.

## Code references

- `src/sim/sim_peer.zig:42-62` — `Behavior` union (matches the team-lead's spec).
- `src/sim/sim_peer.zig:75-90` — `ProtocolState`, `Role`.
- `src/sim/sim_peer.zig:120-200` — `SimPeer` struct + `init`.
- `src/sim/sim_peer.zig:209-256` — action queue and `pumpActions`.
- `src/sim/sim_peer.zig:258-330` — per-action dispatch (handshake / bitfield / unchoke / piece).
- `src/sim/sim_peer.zig:295-321` — `dispatchPieceResponse` with all behaviour gates.
- `src/sim/sim_peer.zig:362-419` — recv callback + handleIncoming + processHandshake / processMessage parser.
- `src/io/sim_io.zig:316-348` — fixed `tick` contract.
- `src/io/sim_io.zig:626-647` — partner-closed short-circuit in `recv`.

## Verification

```
nix develop --command zig build test-sim-peer    # 6/6 pass
nix develop --command zig build test-sim-io      # 15/15 pass
nix develop --command zig build test             # 184/184 pass
```

## What's next

This commit closes the part of #6 that doesn't depend on EventLoop being generic. The remaining work (smart-ban test against a real EventLoop downloading from 5 honest + 1 corrupt SimPeer over 8 seeds; BUGGIFY-stressed runs over 32 seeds) is gated on Stage 2 #11/#12 finishing. Once that lands, the work is:

1. Stand up `Simulator` (#5 / Task #8): owns `SimIO`, `EventLoop(SimIO)`, the SimSwarm, a seeded RNG, and a clock. `step(delta_ns)` drives the swarm peers, ticks SimIO, ticks the EventLoop. Variable step granularity (jump to next pending deadline) for determinism.
2. `tests/sim_minimal_swarm_test.zig` (#5 deliverable): one honest SimPeer, one EventLoop downloader, end-to-end piece transfer.
3. `tests/sim_smart_ban_test.zig` (#6 final): 5 honest + 1 corrupt against the EventLoop, ≥ 8 seeds, assert corrupt peer banned and no honest peer banned.
4. BUGGIFY (#7): per-tick fault from `FaultConfig`, log "fault injected" lines, run smart-ban over 32 seeds.

# 2026-04-05: Download Pipeline 5x Speedup

## What Was Done

Identified and fixed a severe download throughput bottleneck by overhauling
the BitTorrent block request pipeline.

### Before / After

| Scenario | Speed |
|----------|-------|
| Before (pipeline_depth=5) | ~2.7 MB/s (Debian ISO, 40 peers) |
| After (pipeline_depth=64 + multi-piece) | ~14–19 MB/s |
| qbittorrent-nox baseline (same swarm) | ~12–20 MB/s |

## What Was Learned

### Root cause: 4 round-trips per 256 KB piece

With `pipeline_depth=5`, each 256 KB piece (16 × 16 KB blocks) required:
- Round 1: send 5 requests → receive 5 blocks
- Round 2: send 5 more → receive 5 more  
- Round 3: send 5 more → receive 5 more  
- Round 4: send 1 → receive 1

At 100 ms RTT: 4 × 100 ms = 400 ms/piece overhead, dominating transfer time.

### Fix 1: pipeline_depth = 64 → 1 round-trip per piece

With pipeline_depth ≥ 16 (blocks per piece), all 16 block requests for a
256 KB piece are sent in one batch.  The peer receives all requests and
sends all blocks back continuously.  Round-trips drop from 4 to 1 per piece.

(`src/io/peer_policy.zig:18`)

### Fix 2: Multi-piece pipelining eliminates inter-piece gaps

Even with depth=64, after piece A completes there is a brief event-loop
gap before requests for piece B are sent.  During this gap the peer's
upload slot is idle.

Solution: `tryFillPipeline` now pre-claims a `next_piece` as soon as the
current piece's blocks are all requested (but before they all arrive).
The remote peer receives piece B's requests while still sending piece A's
blocks.  On piece A completion, `promoteNextPieceOrMarkIdle` atomically
makes next_piece the new current_piece and claims another next_piece.

New Peer fields: `next_piece`, `next_piece_buf`, `next_blocks_expected`,
`next_blocks_received`, `next_pipeline_sent`.

### Ubuntu tracker limitation confirmed

Benchmarked qbittorrent-nox with DHT/PEX **disabled** against the Ubuntu
25.10 torrent.  Result: 1 peer, ~11 KB/s — identical to varuna.
The ubuntu tracker (`torrent.ubuntu.com`) consistently returns only 1 peer
regardless of client, numwant parameter, or announce frequency.
This is a tracker-side policy, not a varuna bug.

## Remaining Issues / Follow-Up

- The `send_pending` guard in `tryFillPipeline` still serializes request
  sends when the kernel send CQE is delayed.  A per-peer request queue
  would allow buffering requests without waiting for the CQE.
- End-game mode (request last pieces from multiple peers) is not
  implemented.  qbittorrent completes torrents faster at the tail end.
- Two-piece overlap is the current limit.  Deeper queues (4–8 pieces)
  may give marginal additional gains for very high-latency peers.

## Code References

- `src/io/peer_policy.zig:18` — `pipeline_depth = 64`
- `src/io/peer_policy.zig:97` — `tryFillPipeline` with two-phase fill
- `src/io/peer_policy.zig:212` — `promoteNextPieceOrMarkIdle`
- `src/io/event_loop.zig:150` — `next_piece*` fields in Peer struct
- `src/io/protocol.zig:114` — PIECE handler for next_piece blocks

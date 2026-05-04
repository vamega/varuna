# Peer Candidate List

## What changed
- Added an in-memory per-torrent peer candidate list. Tracker, DHT, PEX, and manual peer additions now enqueue candidates instead of dropping discovery results when connection capacity is temporarily full.
- The event loop drains candidates each tick after tracker/DHT/PEX processing and starts outbound connections while global, per-torrent, and half-open limits allow.
- Private torrents reject DHT and PEX candidates at enqueue time; tracker and manual peers remain allowed.
- DHT peer results still preserve the lookup hash used for outbound handshakes, so BEP 52 v2 lookups connect to the v2 swarm hash.

## What was learned
- The earlier adaptive DHT-priority idea is less useful without a durable in-memory candidate pool, because discovery results could still be discarded when half-open capacity was full.
- Keeping candidates in memory only is enough for the current goal: it survives transient connection pressure within a daemon run without adding resume DB or config surface.
- Direct unit tests that called `dhtTick` or `checkReannounce` had to explicitly drain candidates because immediate discovery-to-connect behavior is no longer the contract.

## Remaining issues
- Candidate counts are not yet exposed through daemon diagnostics/RPC, so live torrent debugging still has to infer queue pressure indirectly.
- Failed candidates are retained with bounded retry backoff; if this creates too much churn on large public swarms, the next refinement should add richer eviction/aging metrics rather than disk persistence.

## Code references
- `src/io/peer_candidates.zig:1`
- `src/io/types.zig:243`
- `src/io/event_loop.zig:1159`
- `src/io/event_loop.zig:1980`
- `src/io/dht_handler.zig:57`
- `src/io/peer_policy.zig:1507`
- `src/io/protocol.zig:603`
- `src/daemon/torrent_session.zig:679`
- `src/daemon/session_manager.zig:1863`
- `tests/event_loop_health_test.zig:351`

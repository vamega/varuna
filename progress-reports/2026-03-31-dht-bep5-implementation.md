# DHT (BEP 5) Implementation — Phases 1-3

## What was done

Implemented the Distributed Hash Table (BEP 5) for trackerless peer discovery, covering the first three phases from the `docs/dht-bep52-plan.md` plan.

### New files created under `src/dht/`

- `node_id.zig` — 160-bit NodeId type, XOR distance computation, bucket index calculation, compact node info encode/decode (26-byte BEP 5 format), random ID generation within a bucket range for refresh.
- `routing_table.zig` — 160 k-buckets with K=8, node classification (good/questionable/bad per BEP 5 section 2), bad-node eviction, `findClosest` returning K nodes sorted by XOR distance, bucket staleness detection for 15-minute refresh.
- `krpc.zig` — Zero-allocation KRPC protocol layer. Manual bencode parsing without heap allocation for incoming UDP datagrams. Encode/decode for all four query types (ping, find_node, get_peers, announce_peer), responses, and errors.
- `token.zig` — SipHash-2-4 based token management. Tokens bound to querier IP address. 5-minute secret rotation with overlap window so tokens from the previous period remain valid.
- `lookup.zig` — Iterative lookup state machine. Tracks up to 64 candidates sorted by XOR distance. Queries alpha=3 at a time. Collects peers from get_peers responses. Saves tokens for announce_peer follow-up.
- `bootstrap.zig` — Hard-coded bootstrap node list (router.bittorrent.com, dht.transmissionbt.com, router.utorrent.com, dht.libtorrent.org). DNS resolution helper for startup.
- `persistence.zig` — SQLite tables (dht_config, dht_nodes) for persisting the node ID and up to 300 routing table nodes across restarts.
- `dht.zig` — Main DHT engine coordinating all components. Responds to incoming queries, drives iterative lookups, sends announce_peer after get_peers completes, manages bootstrap, handles timeouts, and produces outbound packets.
- `root.zig` — Module exports.

### Event loop integration

- `src/io/dht_handler.zig` — New handler module (follows `utp_handler.zig` pattern). Demuxes DHT vs uTP by first byte of UDP datagram ('d' = KRPC dict, else uTP). Runs DHT tick. Drains outbound packets via the shared UDP socket. Feeds discovered peers into the existing `addPeerForTorrent` pipeline.
- `src/io/utp_handler.zig` — Modified `handleUtpRecv` to check first byte and route to DHT handler before uTP processing.
- `src/io/event_loop.zig` — Added `dht_engine` field, `dht_handler` import, `dhtTick` call in the tick function.

### Test coverage

44 total DHT tests across all modules:
- 7 node_id tests (XOR properties, bucket index, compact roundtrips, random bucket ID)
- 8 routing_table tests (add, update, bucket full, bad replacement, findClosest sort, refresh, classification)
- 8 krpc tests (ping/find_node/get_peers/response/error roundtrips, invalid input rejection)
- 8 token tests (determinism, differentiation, validation, rotation, double rotation)
- 7 lookup tests (seed, nextToQuery, completion, response handling, peer/candidate dedup)
- 5 dht_engine tests (init, ping query, find_node query, disabled mode, get_peers lookup)
- 1 persistence test (address formatting)

## What was learned

- Zig 0.15 `std.net.Address` is an extern union where IPv4 is accessed via `addr.in.sa.addr` (not `addr.in.addr`). Use `Address.initIp4()` for construction and `addr.getPort()` for port access.
- Zig 0.15 `ArrayList.append` takes `(self, allocator, item)` — the allocator is a separate parameter, not stored in the struct.
- Zero-allocation bencode parsing is practical for KRPC since messages fit in a single UDP datagram (< 1500 bytes). The manual parser avoids allocating a full bencode tree just to extract a few known keys.
- The uTP/DHT demux approach (first byte check) is simple and reliable because bencode dicts always start with 'd' (0x64) while uTP packets have version/type nibbles in the first byte.

## Remaining work

- **DHT Phase 4 (hardening)**: Rate limiting outbound queries to avoid being flagged as abusive. IPv6 support (BEP 32). Fuzz tests for incoming KRPC messages.
- **TorrentSession integration**: Wire `DhtEngine` initialization into the daemon startup path (`src/daemon/torrent_session.zig`). Call `getPeers` for non-private torrents when starting. Call `announcePeer` after download completion.
- **Private torrent guard**: The engine has an `enabled` flag but `TorrentSession` needs to check `metainfo.isPrivate()` before calling any DHT operations.
- **Persist on shutdown**: Call `saveNodes` during graceful SIGINT/SIGTERM shutdown and periodically every 30 minutes.

## Key code references

- `src/dht/dht.zig:108` — `handleIncoming`: entry point for incoming KRPC datagrams
- `src/dht/dht.zig:120` — `tick`: periodic maintenance (timeouts, lookups, bootstrap, refresh)
- `src/io/utp_handler.zig:129` — demux point: first byte check routes to DHT or uTP
- `src/io/dht_handler.zig:14` — `handleDhtRecv`: event loop to DHT engine bridge
- `src/io/event_loop.zig:291` — `dht_engine` field on EventLoop

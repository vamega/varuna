# DHT IPv4/IPv6 Integration (BEP 5 + BEP 32)

## What was done

Wired up the DHT engine (already implemented in `src/dht/`) into the daemon lifecycle so that it actually runs and discovers peers. Also added IPv6 support throughout (BEP 32 dual-stack DHT).

### Core wiring (main.zig)
- Create `DhtEngine` at startup with a randomly generated node ID
- Set `shared_el.port = cfg.network.port_min` so the UDP socket binds on the right port
- Call `startUtpListener()` early (before the event loop) so DHT bootstrap pings can be submitted
- Resolve bootstrap hostnames (blocking DNS, one-time at startup) and call `addBootstrapNodes()`
- Set `shared_el.dht_engine = &dht_engine_storage` to wire it in
- Update event loop tick condition to include `udp_fd >= 0` so DHT gets ticks even with no TCP peers

### DHT peer requests from torrent sessions (torrent_session.zig)
- In `integrateIntoEventLoop()`: call `engine.requestPeers(self.info_hash)` for non-private torrents
- In `integrateSeedIntoEventLoop()`: call `engine.announcePeer(self.info_hash, self.port)` for non-private torrents

### IPv6 dual-stack UDP socket (event_loop.zig, utp_handler.zig)
- `startUtpListener()` now creates an `AF.INET6` socket with `IPV6_V6ONLY = 0` (dual-stack)
- Applies `SO_BINDTODEVICE` if `bind_device` is configured
- `utp_recv_addr` and `utp_send_addr` changed from `posix.sockaddr` to `std.net.Address` to accommodate IPv6
- `normalizeMappedAddr()`: incoming IPv4 packets on dual-stack socket arrive as `::ffff:x.x.x.x`; normalized to `AF.INET` before passing to DHT/uTP
- `toSendAddr()`: IPv4 destination addresses converted to IPv4-mapped IPv6 for sending on the `AF.INET6` socket
- `addressEql()` in dht_handler now handles both IPv4 and IPv6

### IPv6 KRPC support (BEP 32, krpc.zig, node_id.zig, dht.zig)
- `Response` now has `nodes6` and `values6_raw` fields
- `parseResponse()` parses `nodes6` (38-byte IPv6 compact node info) and `values6` (18-byte IPv6 compact peer info)
- `encodeCompactNode6()` / `decodeCompactNode6()` in `node_id.zig` for 38-byte IPv6 node encoding
- `handleResponse()` in `dht.zig` parses both `nodes` (IPv4) and `nodes6` (IPv6) into the routing table
- `handleResponse()` parses both `values` (6-byte IPv4 peers) and `values6` (18-byte IPv6 peers)
- `respondFindNode()` and `respondGetPeers()` filter to only encode IPv4 nodes (avoiding incorrect IPv6→26-byte encoding)
- `addressToBytes()` handles IPv6 for token generation

### Bootstrap (bootstrap.zig)
- Now resolves both IPv4 and IPv6 addresses per bootstrap host

### Disable-trackers mode (config.zig, session_manager.zig, torrent_session.zig)
- Added `disable_trackers: bool = false` to config `[network]` section
- When true and torrent is not private: skip tracker announces entirely, rely on DHT/PEX
- If tracker announce fails: log warning and proceed with empty peer list; DHT fills in asynchronously
- Private torrents always use the tracker regardless of `disable_trackers`

## What was learned

- On a dual-stack `AF.INET6` socket with `IPV6_V6ONLY = 0`, incoming IPv4 packets arrive as IPv4-mapped IPv6 (`::ffff:x.x.x.x`). Must normalize on recv AND convert on send.
- The DHT engine was fully implemented in `src/dht/` but had zero callsites wiring it into the daemon loop. A few dozen lines of glue code in main.zig and torrent_session.zig were enough to activate it.
- The event loop tick condition `peer_count > 0 or listen_fd >= 0` would skip ticking when there are no torrents yet, preventing DHT bootstrap from ever happening. Adding `or udp_fd >= 0` fixes this.
- `encodeCompactNode` asserts `AF.INET` family to catch any future attempts to encode IPv6 nodes via the IPv4 path.

## Remaining issues

- DHT IPv6 responses (`nodes6`, `values6`) are parsed but DHT responses we send don't include `nodes6` -- this limits our visibility as a DHT participant for IPv6-only nodes.
- Node ID is not persisted to SQLite; it's regenerated on each restart (causes routing table churn). `src/dht/persistence.zig` has the schema but is not wired up.
- Routing table is not persisted to SQLite either.
- The `startBootstrap()` find_node lookup needs nodes in the routing table to query, so the initial find_node_for_own_id lookup silently fails. Bootstrap nodes get added via pings, then the first get_peers lookup drives the table. Works but slower than ideal.

## Code references
- `src/main.zig:86-115` — DHT engine initialization and bootstrap
- `src/io/event_loop.zig:1394-1440` — `startUtpListener()` dual-stack changes
- `src/io/utp_handler.zig:660-700` — `normalizeMappedAddr()` and `toSendAddr()`
- `src/daemon/torrent_session.zig:468-475` — DHT requestPeers hook
- `src/daemon/torrent_session.zig:1038-1044` — DHT announcePeer hook
- `src/dht/dht.zig:380-436` — IPv6 peer parsing in handleResponse
- `src/dht/node_id.zig:120-145` — encodeCompactNode6/decodeCompactNode6
- `src/dht/krpc.zig:60-80` — nodes6/values6_raw in Response

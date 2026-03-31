# BEP 52 Phases 4-5: Integration and Hash Exchange Wire Protocol

## What was done

Implemented the remaining BEP 52 (BitTorrent v2 / Hybrid torrent) integration work:

### Phase 4 -- Protocol Integration

1. **Dual info-hash handshake matching** (`src/io/peer_handler.zig`, `src/io/utp_handler.zig`):
   - Both inbound and outbound handshake validation now accept either the v1 (SHA-1) or truncated v2 (first 20 bytes of SHA-256) info-hash.
   - For hybrid torrents, v2-capable peers may use the SHA-256 info-hash in the BitTorrent handshake; the daemon now matches on both.
   - The same change applies to both TCP and uTP handshake paths.

2. **TorrentContext v2 info-hash** (`src/io/event_loop.zig`):
   - Added `info_hash_v2: ?[20]u8` to `TorrentContext` -- the truncated v2 hash for handshake matching.
   - `addTorrentWithKey` automatically derives the truncated v2 hash from `session.metainfo.info_hash_v2`.

3. **Tracker announce v2 hash** (`src/tracker/announce.zig`):
   - Added `info_hash_v2: ?[32]u8` to `Request`. When set, the truncated v2 hash is appended as a second `info_hash=` parameter in the announce URL.
   - This allows v2-aware trackers to place the client in both the v1 and v2 peer swarms for hybrid torrents.

4. **Resume DB v2 hash** (`src/storage/resume.zig`):
   - New `info_hash_v2` table maps v1 info-hash (20 bytes) to full v2 info-hash (32 bytes).
   - `saveInfoHashV2` and `loadInfoHashV2` methods for persistence.

5. **TorrentSession v2 propagation** (`src/daemon/torrent_session.zig`):
   - Added `info_hash_v2: ?[32]u8` field, populated from metainfo on creation.
   - Persisted to resume DB on startup, loaded from DB if not available from metainfo.
   - Passed through to all four announce call sites.

### Phase 5 -- Hash Exchange Wire Protocol

1. **Hash exchange module** (`src/net/hash_exchange.zig`):
   - Message types: `hash request` (21), `hashes` (22), `hash reject` (23).
   - Full encode/decode for all three message types with proper big-endian wire format.
   - `buildHashesFromTree`: builds a hashes response from a Merkle tree for a given request, extracting hashes from the specified layer and computing uncle/proof hashes.

2. **Protocol handler integration** (`src/io/protocol.zig`):
   - Added switch cases for messages 21, 22, 23 in `processMessage`.
   - `handleHashRequest`: validates the request and sends a hash reject (runtime Merkle tree caching is not yet implemented).
   - `handleHashesResponse`: decodes and logs received hashes, verifies file index is in range.
   - `handleHashReject`: logs the rejection for debugging.
   - `sendHashReject`: sends a hash reject echoing back the request parameters.

## What was learned

- The BEP 52 handshake uses the same 20-byte info-hash field but with a truncated SHA-256 hash. This means existing 68-byte handshake format works unchanged -- only the matching logic needs to accept both hash values.
- For tracker announces, the BEP 52 spec suggests using the v1 info-hash for maximum compatibility with existing trackers. The v2 hash is added as an additional parameter for v2-aware trackers.
- The hash exchange messages (21/22/23) use fixed-width binary encoding, not bencode. Each field is a big-endian u32 followed by raw 32-byte SHA-256 hashes.

## Remaining work

- **Runtime Merkle tree caching**: To actually serve hash requests (instead of rejecting them), per-file Merkle trees need to be built from piece data and cached in `TorrentContext`. This is a performance optimization -- the tree construction infrastructure already exists in `src/torrent/merkle.zig`.
- **Piece-layer streaming**: Requesting and integrating Merkle hash layers from peers during download for incremental piece verification.
- **Integration testing**: End-to-end test with a v2/hybrid torrent against another BEP 52-capable client.

## Key file references

- `src/io/event_loop.zig:163-170` -- TorrentContext.info_hash_v2 field
- `src/io/peer_handler.zig:281-307` -- dual info-hash inbound matching
- `src/io/utp_handler.zig:377-381` -- dual info-hash outbound validation (uTP)
- `src/net/hash_exchange.zig` -- full hash exchange module (encode/decode/build)
- `src/io/protocol.zig:556-650` -- hash exchange message handlers
- `src/tracker/announce.zig:16-19` -- Request.info_hash_v2 field
- `src/storage/resume.zig:149-165` -- info_hash_v2 table schema
- `src/storage/resume.zig:557-588` -- saveInfoHashV2/loadInfoHashV2
- `src/daemon/torrent_session.zig:82` -- TorrentSession.info_hash_v2 field

# Magnet Link Support (BEP 9)

## What was done

Implemented full magnet link support per BEP 9 (Extension for Peers to Send Metadata Files):

### New files
- `src/torrent/magnet.zig` -- Magnet URI parser supporting hex (40-char) and base32 (32-char) info-hashes, percent-decoded display names and tracker URLs
- `src/net/ut_metadata.zig` -- BEP 9 protocol: request/data/reject message encode/decode, MetadataAssembler for collecting pieces and verifying against info-hash

### Modified files
- `src/net/extensions.zig` -- Added `encodeExtensionHandshakeWithMetadata()` that includes `metadata_size` in the BEP 10 handshake
- `src/io/protocol.zig` -- Event loop now handles incoming ut_metadata request messages (serves metadata pieces to peers), uses tracked sends for io_uring buffer safety. Extension handshake now includes metadata_size.
- `src/daemon/torrent_session.zig` -- Added `createFromMagnet()`, `fetchMetadata()`, `fetchMetadataFromPeer()`, `buildTorrentBytes()`. New `metadata_fetching` state. Magnet metadata fetch runs on background thread before normal download.
- `src/daemon/session_manager.zig` -- Added `addMagnet()` method
- `src/rpc/handlers.zig` -- `torrents/add` endpoint now accepts `urls=` parameter for magnet links (qBittorrent API compatible)
- `src/ctl/main.zig` -- `varuna-ctl add` now accepts `--magnet <uri>` or a bare `magnet:` URI
- Module roots updated to export new files

## Key design decisions

1. **Background thread metadata fetch**: Metadata download runs on a dedicated background thread using blocking Ring I/O, not through the async event loop. This avoids adding metadata assembly state to every peer slot and keeps the one-time metadata fetch simple.

2. **Synthetic .torrent file**: After metadata verification, we build a minimal `.torrent` file (`d8:announce...4:info<raw dict>e`) so the rest of the codebase (Session.load, PieceStore, tracker) works unchanged.

3. **Tracked sends in event loop**: When serving metadata pieces to peers via the event loop, we use `nextTrackedSendUserData` and `pending_sends` to ensure the send buffer persists until the io_uring CQE arrives. This prevents UAF bugs.

4. **10 MiB metadata cap**: Protects against malicious peers advertising absurdly large metadata.

## What was learned

- BEP 9 data messages have a bencoded dictionary followed by raw piece data in the same payload. Finding the dictionary boundary requires a lightweight bencode scanner (`findDictEnd`) that doesn't allocate.
- The peer sends ut_metadata responses to our locally-assigned extension ID (not theirs), so we listen for `ext.local_ut_metadata_id` when receiving, but send to the peer's advertised ID.
- Base32 info-hash encoding (32 chars) is less common than hex (40 chars) but some older magnet links use it. 32 base32 chars = 160 bits = exactly 20 bytes.

## Tests added

- 12 magnet URI tests: hex/base32/uppercase parsing, multiple trackers, no trackers, empty params, invalid prefix/hash/length, percent decoding edge cases
- 12 ut_metadata tests: request/reject/data encode-decode roundtrips, metadata assembler single/multi-piece, hash mismatch, duplicate piece, oversized metadata, reset-and-retry, invalid message types, findDictEnd

## Remaining work

- Parallel metadata piece requests from multiple peers
- Retry from different peers on hash mismatch
- Trackerless magnet support (needs DHT, BEP 5)
- Timeout handling for metadata fetch connections

## Code references

- Magnet parser: `src/torrent/magnet.zig`
- ut_metadata protocol: `src/net/ut_metadata.zig`
- Metadata fetch flow: `src/daemon/torrent_session.zig:fetchMetadata()` (~line 1000)
- Event loop metadata serving: `src/io/protocol.zig:handleUtMetadata()` (~line 167)
- API magnet handling: `src/rpc/handlers.zig:handleTorrentsAdd()` (~line 260)

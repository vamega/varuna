# BEP 21: Partial Seeds (upload_only extension)

## What was done

Implemented BEP 21 -- the extension for partial seeds. A partial seed is a peer
that has completed its selective download (all wanted files) but does not have
all pieces in the torrent. It signals `upload_only: 1` in the BEP 10 extension
handshake to tell other peers it will upload but not download.

### Changes

1. **Extension handshake parsing/encoding** (`src/net/extensions.zig`):
   - Added `upload_only: bool` to `ExtensionHandshake` struct.
   - Decode `upload_only` from incoming BEP 10 handshakes (any non-zero integer = true).
   - New `encodeExtensionHandshakeFull()` that accepts `upload_only` parameter.
   - When `upload_only` is false, the key is omitted from the bencoded dict entirely
     (following libtorrent's convention of only sending it when true).

2. **Peer state** (`src/io/event_loop.zig`):
   - Added `upload_only: bool` to `Peer` struct.
   - Added `upload_only: bool` to `TorrentContext` struct (tracks our own state).

3. **Protocol handling** (`src/io/protocol.zig`):
   - Store `upload_only` from decoded extension handshake into `Peer.upload_only`.
   - `submitExtensionHandshake` reads `TorrentContext.upload_only` and passes it
     to the encoder.

4. **Partial seed detection** (`src/torrent/piece_tracker.zig`):
   - New `isPartialSeed()` method: returns true when there is a wanted mask, all
     wanted pieces are complete, but `complete.count < piece_count`.

5. **Peer policy** (`src/io/peer_policy.zig`):
   - `tryAssignPieces`: skip piece assignment when `TorrentContext.upload_only` is true.
   - `checkPartialSeed`: new periodic check that detects partial seed state transitions,
     updates `TorrentContext.upload_only`, and re-sends extension handshakes to all
     connected peers when the state changes.
   - PEX flags: upload_only peers get the `seed` flag in PEX messages.

6. **API** (`src/rpc/handlers.zig`, `src/daemon/session_manager.zig`):
   - `PeerInfo.upload_only` exposed in `torrentPeers` endpoint.
   - `PropertiesInfo.partial_seed` exposed in `torrents/properties` endpoint.
   - `partial_seed` included in `sync/maindata` and `torrents/info` responses.

7. **Torrent session** (`src/daemon/torrent_session.zig`):
   - `Stats.partial_seed` field populated from `PieceTracker.isPartialSeed()`.
   - Auto-transition from `downloading` to `seeding` when partial seed detected.

### Tests (10 new)
- 6 extension handshake tests: encode/decode upload_only, roundtrip, omission when false,
  combined with metadata_size.
- 4 piece_tracker tests: isPartialSeed without wanted mask, with full mask, with partial
  mask (the core case), and transition when all pieces complete.

## What was learned

- BEP 21 is a simple extension that piggybacks on BEP 10. The `upload_only` key
  is just an integer in the extension handshake dictionary. libtorrent sends it as
  `upload_only: 1` and only when true (omitted otherwise).
- The partial seed concept maps directly to selective download: when a user marks
  some files as `do_not_download` and all remaining files' pieces are verified,
  the client becomes a partial seed.
- Re-sending the extension handshake on state change is important -- peers need to
  know when we transition to/from upload_only so they can adjust their interest and
  request strategies.

## Key files
- `src/net/extensions.zig` -- upload_only encode/decode
- `src/io/protocol.zig:157-163` -- store upload_only from peer handshake
- `src/io/peer_policy.zig:751-797` -- checkPartialSeed periodic detection
- `src/torrent/piece_tracker.zig:352-363` -- isPartialSeed method
- `src/daemon/torrent_session.zig:541-547` -- auto-transition to seeding

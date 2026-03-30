# Private Flag Enforcement (BEP 27)

## What was done

Implemented private torrent enforcement per BEP 27. When a torrent has `private=1` in its info dictionary, the client now restricts peer discovery to tracker-only.

### Changes

1. **TorrentContext** (`src/io/event_loop.zig:159`): Added `is_private: bool` field. Updated `addTorrentWithKey` to accept and store the flag.

2. **Extension handshake** (`src/net/extensions.zig:79`): `encodeExtensionHandshake` now takes `is_private` parameter. When true, `ut_pex` is omitted from the "m" dictionary so peers know we won't participate in peer exchange.

3. **PEX message rejection** (`src/io/protocol.zig:137-145`): When processing extension messages, if the sub-id maps to `ut_pex` and the torrent is private, the message is silently dropped.

4. **isPeerDiscoveryAllowed** (`src/io/event_loop.zig:467-472`): New helper that returns false for private torrents. Future DHT/LSD code should call this before announcing or responding.

5. **TorrentSession** (`src/daemon/torrent_session.zig:100,153`): Stores `is_private` from metainfo at creation time. Passes it through to `addTorrentWithKey` at both integration points.

6. **API responses** (`src/rpc/handlers.zig`, `src/rpc/sync.zig`): Added `is_private` field to torrents/properties, torrent info list, and sync/maindata responses.

7. **uTP path** (`src/io/utp_handler.zig:413-415`): Extension handshake over uTP also checks private flag.

## What was learned

- BEP 27 is simple in principle but touches many layers: metainfo parsing (already done), extension negotiation, message processing, and the public API.
- The extension handshake is the right place to prevent PEX from being set up, but we also need the message-level guard because a misbehaving peer might send PEX messages regardless.
- The `is_private` flag is immutable for the lifetime of a torrent (it's part of the info dict which is covered by the info hash), so storing it once at creation time is correct.

## Remaining work

- DHT and LSD are not yet implemented, but when they are, they must call `isPeerDiscoveryAllowed` before announcing.
- No integration test yet for the full private torrent flow (would need a private tracker setup).

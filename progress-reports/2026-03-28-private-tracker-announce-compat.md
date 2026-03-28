# Private Tracker Announce Compatibility Fixes

## What was done

Audited and fixed HTTP/UDP announce request parameters for private tracker compatibility.

### Issues found and fixed

1. **`numwant` not always sent**: `Request.numwant` was `?u32 = null`, meaning most announces omitted it entirely. Private trackers expect this parameter. Changed to `u32 = 50` so it is always included.

2. **`key` parameter never sent**: No call site populated `Request.key`. Private trackers use this per-session random value for authentication/IP migration. Added `Request.generateKey()` to produce an 8-char hex key, stored per-session in `TorrentSession.tracker_key`, and passed through all announce calls (HTTP and UDP).

3. **Announce-list fallback missing in daemon**: `TorrentSession.startWorker()` only used `session.metainfo.announce`, ignoring `announce_list`. If the primary announce URL failed, the daemon would error instead of trying alternatives. Added `buildTrackerUrls()` helper and fallback loop (matching what `client.zig` already had).

4. **UDP `key` field ignored session key**: `udp.zig` line 68 generated a random per-request key instead of using `request.key`. Fixed to use the session key when available.

### Key changes

- `src/tracker/announce.zig`: `Request.numwant` is now always-present `u32 = 50`. `Request.key` changed from `?[]const u8` to `?[8]u8`. Added `generateKey()`. Added tests for key inclusion, numwant presence, and key generation format.
- `src/tracker/udp.zig`: Uses `request.key` for the UDP announce key field; respects `request.numwant`.
- `src/daemon/torrent_session.zig`: Added `tracker_key` field, `buildTrackerUrls()` for announce-list fallback, `.key` on all announce calls, uses `addTorrentWithKey()`.
- `src/torrent/client.zig`: Generates session key in `seed()` and `download()`, passes through `sendTrackerEvent()`.
- `src/io/event_loop.zig`: `TorrentContext` gains `tracker_key` field; re-announce includes it. Added `addTorrentWithKey()`.
- `src/torrent/metainfo.zig`: Added tests for `private=1` parsing.

### Not changed (already correct)

- `compact=1` was already always sent.
- `uploaded` and `downloaded` fields exist on `Request` and default to 0 -- callers that track upload/download bytes pass them correctly.
- `event` parameter is correctly sent for started/completed/stopped and omitted for regular re-announces.
- Peer ID follows `-VR0001-` Azureus-style convention (`src/torrent/peer_id.zig`).
- Private flag is already parsed from metainfo (`private=1` in info dict).
- `info_hash` and `peer_id` are correctly percent-encoded (RFC 3986 unreserved set).

## Remaining work

- Track actual `uploaded` bytes in the event loop and pass to re-announce/stopped events (currently always 0 for re-announces).
- DHT/PEX suppression when `metainfo.isPrivate()` is true (no DHT/PEX implemented yet, so not currently a problem).

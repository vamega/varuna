# API Stub Population for Flood/qui WebUI Compatibility

## What was done

Populated all remaining stub/placeholder fields in the qBittorrent-compatible API so that Flood and qui WebUIs receive real data instead of empty strings and zeros.

### Changes by field

1. **`tracker` field in torrent info** (`src/daemon/torrent_session.zig:Stats`): Added `tracker` field populated from `session.metainfo.announce` (the primary announce URL). Previously hardcoded as `""`.

2. **`trackers_count`** (`Stats`): Added field, computed by counting unique tracker URLs (primary announce + announce_list, deduplicating the primary URL). Previously hardcoded as `0`.

3. **`piece_range` in file info** (`src/daemon/session_manager.zig:FileInfo`): Added `first_piece` and `last_piece` fields populated from `layout.files[i].first_piece` and `end_piece_exclusive - 1`. Previously hardcoded as `[0,0]`.

4. **`content_path`**: Built as `save_path + "/" + torrent_name` via `compat.buildContentPath()`. For single-file torrents this is the full file path; for multi-file torrents it's the directory. Previously just echoed `save_path`.

5. **`magnet_uri`**: Generated via `compat.buildMagnetUri()` using info-hash hex, display name (percent-encoded), and primary tracker URL. Follows the `magnet:?xt=urn:btih:<hash>&dn=<name>&tr=<tracker>` format. Previously hardcoded as `""`.

6. **`torrentPeers` endpoint** (`handleSyncTorrentPeers`): Now returns real peer data from the event loop -- iterates over `EventLoop.peers[]`, filters by torrent ID, and returns IP address, port, connection flags (D/U/d/u/E/X/P), progress from bitfield, bytes downloaded/uploaded. Previously returned `{"peers":{}}`.

7. **Properties endpoint fields**: Populated `hash`, `infohash_v1`, `name`, `created_by`, `creation_date` from metainfo. Previously all empty strings.

8. **`super_seeding` in torrent info**: Now uses `stat.super_seeding` instead of hardcoded `false`.

### Files changed

- `src/daemon/torrent_session.zig`: Added `tracker`, `trackers_count`, `content_path`, `num_files` fields to `Stats`; populated in `getStats()`.
- `src/daemon/session_manager.zig`: Added `first_piece`/`last_piece` to `FileInfo`; added `PeerInfo` type and `getTorrentPeers()` method; extended `PropertiesInfo` with hash, name, created_by, creation_date, trackers_count.
- `src/rpc/handlers.zig`: Updated `serializeTorrentInfo()` and `handleTorrentsFiles()` to use real data; replaced torrentPeers stub with real implementation; updated properties handler.
- `src/rpc/sync.zig`: Updated `serializeTorrentObject()` to use real tracker, trackers_count, content_path, magnet_uri, super_seeding.
- `src/rpc/compat.zig`: Added `buildContentPath()`, `buildMagnetUri()`, `percentEncode()` shared utility functions with 6 tests.

### Key decisions

- Shared utility functions (`buildContentPath`, `buildMagnetUri`, `percentEncode`) placed in `compat.zig` since both `handlers.zig` and `sync.zig` need them.
- Peer progress calculated from `Bitfield.count / Bitfield.piece_count` instead of iterating all bits (O(1) vs O(n)).
- Per-peer speed not tracked yet (returns 0) since the event loop tracks aggregate speed per torrent, not per peer.
- `creation_date` kept as -1 since the metainfo parser doesn't extract the `creation date` field from the torrent file.

### Remaining items

- Per-peer download/upload speed: would need per-peer speed tracking in the event loop (rolling window per peer slot).
- Peer client identification: the peer ID bytes are received during handshake but not stored in `Peer` struct; would need a field to decode Azureus/Shadow-style client names.
- `creation_date` parsing from metainfo bencode.

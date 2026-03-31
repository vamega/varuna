# API Placeholder Cleanup and Compatibility Documentation

**Date**: 2026-03-31

## What was done

Replaced hardcoded placeholder values in the qBittorrent-compatible WebAPI with real data from the running daemon, and documented the full API compatibility surface.

### Real DHT node count
- Added `EventLoop.getDhtNodeCount()` method (`src/io/event_loop.zig`) that reads from `dht_engine.table.nodeCount()`.
- Wired into `transfer/info` (`src/rpc/handlers.zig:175`) and `sync/maindata` server_state (`src/rpc/sync.zig:164`).
- Previously hardcoded to 0.

### Real BEP 52 v2 info-hash
- Added `info_hash_v2: ?[32]u8` to the `Stats` struct (`src/daemon/torrent_session.zig:80`) and populated it from `TorrentSession.info_hash_v2` in `getStats()`.
- Added `info_hash_v2` to `PropertiesInfo` (`src/daemon/session_manager.zig:997`).
- Added `formatInfoHashV2()` helper in `src/rpc/compat.zig` to convert 32-byte hash to 64-char lowercase hex.
- Updated 3 serialization sites to emit real v2 hash instead of empty string:
  - `serializeTorrentInfo` in handlers.zig (torrent info endpoint)
  - `handleTorrentsProperties` in handlers.zig (properties endpoint)
  - `serializeTorrentObject` in sync.zig (sync/maindata torrent objects)
- Pure v1 torrents still emit `""` for infohash_v2.

### Scrape data in properties
- Added `scrape_complete`/`scrape_incomplete` to `PropertiesInfo`.
- Properties endpoint now returns real tracker scrape data for `peers_total` (leechers), `seeds` (seeders from scrape), and `seeds_total` (seeders from scrape) instead of 0.

### Creation date from .torrent files
- Added `creation_date: i64` field to `Metainfo` struct (`src/torrent/metainfo.zig:26`).
- Parsed from the standard `creation date` bencode key in .torrent files.
- Propagated through `PropertiesInfo` to the properties API endpoint (was hardcoded to -1).

### API compatibility documentation
- Created `docs/api-compatibility.md` with full endpoint matrix.
- Documents: implemented endpoints, remaining placeholder fields (total_wasted, avg speeds, availability), explicitly unsupported endpoints (tracker editing, RSS, search plugins), and deferred endpoints (rename, pieceStates, export, queue management).
- Unknown API paths already return HTTP 404 (`src/rpc/handlers.zig:124`).

## Tests added
- 2 tests for `formatInfoHashV2` in `src/rpc/compat.zig`: non-null hash produces correct 64-char hex, null hash produces zeros.
- All existing tests pass (`zig build test -Dtls=none`).

## Key files changed
- `src/daemon/torrent_session.zig` -- Stats.info_hash_v2 field
- `src/daemon/session_manager.zig` -- PropertiesInfo v2 hash, scrape data, creation_date
- `src/torrent/metainfo.zig` -- creation_date parsing
- `src/io/event_loop.zig` -- getDhtNodeCount()
- `src/rpc/handlers.zig` -- real DHT nodes, v2 hash, scrape data, completion_date in transfer/info and properties
- `src/rpc/sync.zig` -- real DHT nodes and v2 hash in maindata
- `src/rpc/compat.zig` -- formatInfoHashV2 helper + tests
- `docs/api-compatibility.md` -- new compatibility matrix
- `STATUS.md`, `AGENTS.md`, `docs/future-features.md` -- documentation updates

## Remaining placeholder fields
These are documented in `docs/api-compatibility.md`:
- `total_wasted` -- needs hash-fail byte tracking (not yet instrumented)
- `dl_speed_avg` / `up_speed_avg` -- needs cumulative average tracking
- `free_space_on_disk` -- needs statfs call
- `total_peer_connections` -- could sum per-torrent counts
- `availability` -- needs distributed copies calculation from peer bitfields

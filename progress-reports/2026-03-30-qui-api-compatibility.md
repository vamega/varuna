# qui / Flood WebUI API Compatibility Audit

## What was done

Audited the Varuna API implementation against what qui (autobrr/qui) actually
expects from a qBittorrent v2 API, identified all gaps, and fixed them.

### Audit methodology

Read the qui source code in `reference-codebases/qui/`:
- `web/src/types/index.ts` -- TypeScript interfaces for all API response types
- `web/src/lib/torrent-state-utils.ts` -- qBittorrent state string mapping
- `internal/proxy/handler.go` -- Go proxy routing (which endpoints qui intercepts)
- `web/src/lib/api.ts` -- Frontend API client

### Gaps found and fixed

**1. Torrent state strings (CRITICAL)**
- Before: emitted Varuna internal names (`downloading`, `seeding`, `paused`, `stopped`)
- After: maps to qBittorrent strings (`downloading`, `uploading`, `pausedDL`, `pausedUP`, `stoppedDL`, `stoppedUP`, `checkingDL`, `checkingUP`, `error`)
- New file: `src/rpc/compat.zig` with `torrentStateString()` and tests
- qui uses these strings to determine torrent status labels and icons

**2. Missing torrent info fields (~25 fields)**
- Added: `infohash_v1`, `infohash_v2`, `total_size`, `content_path`, `download_path`, `amount_left`, `completed`, `downloaded`, `downloaded_session`, `uploaded`, `uploaded_session`, `time_active`, `seeding_time`, `last_activity`, `completion_on`, `num_complete`, `num_incomplete`, `tracker`, `trackers_count`, `f_l_piece_prio`, `force_start`, `super_seeding`, `auto_tmm`, `priority`, `availability`, `max_ratio`, `max_seeding_time`, `ratio_limit`, `seeding_time_limit`, `popularity`, `magnet_uri`, `reannounce`, `seen_complete`
- Fixed: `private` (was `is_private`), `seq_dl` and `private` now emit JSON booleans (`true`/`false`) instead of integers (`0`/`1`)
- Applied to both `serializeTorrentInfo` (torrents/info) and `serializeTorrentObject` (sync/maindata)

**3. CORS headers**
- Added `Access-Control-Allow-Origin: *` and related CORS headers to all responses
- Added `OPTIONS` preflight handler
- Ensures browser-direct access works without a proxy

**4. Transfer info**
- Added `connection_status` and `dht_nodes` fields (qui's `TransferInfo` interface requires them)
- Removed non-standard `active_torrents` field

**5. Server state (sync/maindata)**
- Added `connection_status`, `dht_nodes`, `queueing`, `use_alt_speed_limits`, `refresh_interval`, `free_space_on_disk`, `total_peer_connections`

**6. Preferences (expanded)**
- Was: only `dl_limit` and `up_limit`
- Now: 40+ fields covering network settings, connection limits, seeding limits, paths, BitTorrent protocol flags, queue management -- all fields qui's `AppPreferences` interface reads
- Added JSON body parsing for `setPreferences` (qui may send JSON instead of form data)

**7. File info**
- Added `index`, `availability`, `is_seed`, `piece_range` fields

**8. Tracker info**
- Added `msg` field (empty string, qui expects it)

**9. Properties**
- Added 15+ missing fields: `download_path`, `created_by`, `dl_speed_avg`, `up_speed_avg`, `hash`, `infohash_v1`, `infohash_v2`, `name`, `share_ratio`, `time_elapsed`, `nb_connections_limit`, `peers_total`, `seeds`, `seeds_total`, `last_seen`, `reannounce`, `completion_date`, `total_downloaded_session`, `total_uploaded_session`, `total_wasted`
- Fixed: `is_private` and `seq_dl` now emit JSON booleans

**10. New endpoints**
- `GET /api/v2/app/version` -- returns "v5.0.0"
- `GET /api/v2/app/buildInfo` -- returns build metadata
- `GET /api/v2/sync/torrentPeers` -- stub returning empty peers (prevents UI errors)
- `GET /api/v2/app/webapiVersion` now returns `text/plain` content type

## Key learnings

- qui's Go backend acts as a proxy to qBittorrent and caches/enriches responses; the frontend never hits qBittorrent directly. For direct browser access, CORS is needed.
- Zig `std.fmt` has a 32-argument limit per format call, so large JSON objects must be split across multiple `print()` calls.
- qBittorrent state strings encode both the operation AND the completion status (e.g. `pausedDL` vs `pausedUP`), which requires knowing both state and progress.
- Many qui UI features (dashboard stats, torrent details, file browser) silently break if expected JSON fields are missing -- they don't error, they just show blank/zero values.

## Files changed

- `src/rpc/compat.zig` (new) -- qBittorrent state string mapping
- `src/rpc/root.zig` -- registered compat module
- `src/rpc/handlers.zig` -- CORS, expanded responses, new endpoints, JSON int parsing
- `src/rpc/sync.zig` -- expanded torrent and server_state serialization

## Remaining work

- Populate `tracker` field with actual primary tracker URL in torrent info
- Populate `trackers_count` with actual count
- Populate `piece_range` in file info with actual piece indices
- Add real peer data to `sync/torrentPeers` endpoint
- `content_path` should include the torrent name subdirectory for multi-file torrents
- Some stub fields (magnet_uri, popularity, availability) could be populated with real data

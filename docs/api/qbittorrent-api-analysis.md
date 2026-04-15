# qBittorrent WebAPI Analysis for Varuna

This document provides a comprehensive analysis of the qBittorrent WebAPI v2 surface
compared to Varuna's implementation, based on:
- The [qBittorrent WebUI API wiki (v5.0)](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0))
- The [OpenAPI spec PR #21817](https://github.com/qbittorrent/qBittorrent/pull/21817) (partial, covers auth + transfer)
- Varuna source: `src/rpc/handlers.zig`, `src/rpc/compat.zig`, `src/rpc/sync.zig`

## A. Implemented Endpoints

### Auth

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/auth/login` | POST | Full | Form-encoded `username` + `password`. Returns `Ok.` / `Fails.` with `SID` cookie. Matches qBittorrent exactly. |
| `/api/v2/auth/logout` | GET | Full | Clears session. Returns `Ok.` |

**Example -- login:**
```
POST /api/v2/auth/login
Content-Type: application/x-www-form-urlencoded

username=admin&password=adminadmin

Response: "Ok."
Set-Cookie: SID=<session-id>; HttpOnly; SameSite=Lax; path=/
```

### Application

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/app/webapiVersion` | GET | Full | Returns `"2.9.3"` (text/plain). |
| `/api/v2/app/version` | GET | Full | Returns `v5.0.0` (text/plain). |
| `/api/v2/app/buildInfo` | GET | Full | Returns `{"qt":"N/A","libtorrent":"N/A","boost":"N/A","openssl":"N/A","bitness":64}`. All lib versions are N/A since Varuna is not built on Qt/libtorrent. |
| `/api/v2/app/preferences` | GET | Full | Returns 40+ fields. See preferences diff in section F. |
| `/api/v2/app/setPreferences` | POST | Full | Accepts both form-encoded and JSON body. Supports: `dl_limit`, `up_limit`, `max_ratio*`, `max_seeding_time*`, `queueing_enabled`, `max_active_downloads`, `max_active_uploads`, `max_active_torrents`, `dht`, `pex`, `enable_utp`, `banned_IPs`. |

**Example -- preferences (abbreviated):**
```json
{
  "dl_limit": 0,
  "up_limit": 0,
  "save_path": "/downloads",
  "queueing_enabled": false,
  "max_active_downloads": -1,
  "dht": true,
  "pex": true,
  "encryption": 0,
  "enable_utp": true,
  "piece_cache_enabled": 0,
  "banned_IPs": ""
}
```

**Differences from qBittorrent:**
- `piece_cache_enabled` is a Varuna extension (not in qBittorrent).
- Many qBittorrent preferences fields are returned with hardcoded defaults (e.g. `listen_port: 6881`, `max_connec: 500`) because Varuna does not yet expose them as configurable.

### Transfer

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/transfer/info` | GET | Full | Returns `connection_status`, `dht_nodes`, `dl_info_speed`, `up_info_speed`, `dl_info_data`, `up_info_data`, `dl_rate_limit`, `up_rate_limit`. |
| `/api/v2/transfer/speedLimitsMode` | GET | Full | Always returns `0` (no alternative speed mode). |
| `/api/v2/transfer/banPeers` | POST | Full | Pipe-separated `peers=ip:port|ip:port`. |
| `/api/v2/transfer/unbanPeers` | POST | Full | **Varuna extension.** Pipe-separated `ips=ip|ip`. Returns `{"removed": N}`. |
| `/api/v2/transfer/bannedPeers` | GET | Full | **Varuna extension.** Returns `{"individual":[...],"ranges":[...],"total_rules":N}`. |
| `/api/v2/transfer/importBanList` | POST | Full | **Varuna extension.** Imports ipfilter files (DAT, P2P, CIDR formats). Returns `{"imported":N,"errors":N}`. |

**Example -- transfer/info:**
```json
{
  "connection_status": "connected",
  "dht_nodes": 42,
  "dl_info_speed": 1048576,
  "up_info_speed": 524288,
  "dl_info_data": 10737418240,
  "up_info_data": 5368709120,
  "dl_rate_limit": 0,
  "up_rate_limit": 0
}
```

### Torrents -- Core

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/torrents/info` | GET | Full | Returns array of torrent objects with 40+ fields per torrent. See field analysis in diff report. |
| `/api/v2/torrents/add` | POST | Full | Supports multipart/form-data (torrent file upload), raw body, and magnet URIs via `urls` field. Accepts `savepath`, `category` params. |
| `/api/v2/torrents/delete` | POST | Full | `hashes=<hash>&deleteFiles=true/false`. |
| `/api/v2/torrents/pause` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/resume` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/properties` | GET | Full | Returns detailed torrent properties including scrape data, v2 info-hash, creation_date. |
| `/api/v2/torrents/files` | GET | Full | Returns file list with `index`, `name`, `size`, `progress`, `priority`, `availability`, `is_seed`, `piece_range`. |
| `/api/v2/torrents/trackers` | GET | Full | Returns tracker list with `url`, `status`, `tier`, `num_peers`, `num_seeds`, `num_leeches`, `num_downloaded`, `msg`. |
| `/api/v2/torrents/webSeeds` | GET | Full | Returns `[{"url":"..."}]` for each web seed. |
| `/api/v2/torrents/filePrio` | POST | Full | `hash=<hash>&id=<idx|idx>&priority=<0|1|6|7>`. |
| `/api/v2/torrents/setSequentialDownload` | POST | Full | `hash=<hash>&value=true/false`. |
| `/api/v2/torrents/setDownloadLimit` | POST | Full | `hashes=<hash>&limit=<bytes/sec>`. |
| `/api/v2/torrents/setUploadLimit` | POST | Full | `hashes=<hash>&limit=<bytes/sec>`. |
| `/api/v2/torrents/downloadLimit` | POST | Full | Returns numeric limit value for requested hash. |
| `/api/v2/torrents/uploadLimit` | POST | Full | Returns numeric limit value for requested hash. |
| `/api/v2/torrents/forceReannounce` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/recheck` | POST | Full | `hashes=<hash>`. Triggers async io_uring-based recheck. |
| `/api/v2/torrents/setLocation` | POST | Full | `hashes=<hash>&location=<path>`. |
| `/api/v2/torrents/setSuperSeeding` | POST | Full | `hashes=<hash>&value=true/false`. |
| `/api/v2/torrents/setShareLimits` | POST | Full | `hashes=<hash>&ratioLimit=<float>&seedingTimeLimit=<int>`. |
| `/api/v2/torrents/addTrackers` | POST | Full | `hash=<hash>&urls=<newline-separated URLs>`. |
| `/api/v2/torrents/removeTrackers` | POST | Full | `hash=<hash>&urls=<pipe-separated URLs>`. |
| `/api/v2/torrents/editTracker` | POST | Full | `hash=<hash>&origUrl=<url>&newUrl=<url>`. |

### Torrents -- Queue Management

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/torrents/increasePrio` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/decreasePrio` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/topPrio` | POST | Full | `hashes=<hash>`. |
| `/api/v2/torrents/bottomPrio` | POST | Full | `hashes=<hash>`. |

### Torrents -- Categories

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/torrents/categories` | GET | Full | Returns `{"cat_name":{"name":"...","savePath":"..."}}`. |
| `/api/v2/torrents/createCategory` | POST | Full | `category=<name>&savePath=<path>`. Persisted to SQLite. |
| `/api/v2/torrents/editCategory` | POST | Full | `category=<name>&savePath=<path>`. |
| `/api/v2/torrents/removeCategories` | POST | Full | `categories=<newline-separated>`. Clears category from affected torrents. |
| `/api/v2/torrents/setCategory` | POST | Full | `hashes=<hash>&category=<name>`. |

### Torrents -- Tags

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/torrents/tags` | GET | Full | Returns JSON array of tag strings. |
| `/api/v2/torrents/createTags` | POST | Full | `tags=<comma-separated>`. Persisted to SQLite. |
| `/api/v2/torrents/deleteTags` | POST | Full | `tags=<comma-separated>`. Removes from all torrents. |
| `/api/v2/torrents/addTags` | POST | Full | `hashes=<hash>&tags=<comma-separated>`. |
| `/api/v2/torrents/removeTags` | POST | Full | `hashes=<hash>&tags=<comma-separated>`. |

### Torrents -- Varuna Extensions

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/torrents/connDiagnostics` | GET | Full | Varuna-only. Returns `{"connection_attempts":N,"connection_failures":N,"timeout_failures":N,"refused_failures":N,"peers_connected":N,"peers_half_open":N}`. |

### Sync

| Endpoint | Method | Status | Notes |
|----------|--------|--------|-------|
| `/api/v2/sync/maindata` | GET | Full | Delta protocol with `rid`-based change detection using Wyhash. Returns `torrents`, `torrents_removed`, `categories`, `tags`, `server_state`. |
| `/api/v2/sync/torrentPeers` | GET | Full | Delta protocol with per-torrent peer snapshots. Returns real peer data: IP, client name, speeds, flags, progress. |

**Example -- sync/maindata (abbreviated):**
```json
{
  "rid": 1,
  "full_update": true,
  "torrents": {
    "abcdef0123456789...": {
      "name": "example.torrent",
      "state": "downloading",
      "progress": 0.5000,
      "dlspeed": 1024000,
      "upspeed": 512000
    }
  },
  "torrents_removed": [],
  "categories": {},
  "tags": [],
  "server_state": {
    "connection_status": "connected",
    "dht_nodes": 42,
    "dl_info_speed": 1024000,
    "up_info_speed": 512000,
    "dl_rate_limit": 0,
    "up_rate_limit": 0,
    "alltime_dl": 10737418240,
    "alltime_ul": 5368709120,
    "queueing": false,
    "use_alt_speed_limits": false,
    "refresh_interval": 1500,
    "free_space_on_disk": 0,
    "total_peer_connections": 0
  }
}
```

---

## B. Should Implement (Priority)

These endpoints are needed for full compatibility with WebUI clients (qui, Flood, VueTorrent).

### High Priority

| Endpoint | Method | Why | Complexity |
|----------|--------|-----|------------|
| `/api/v2/torrents/rename` | POST | Flood and qui both call this when users rename a torrent in the UI. Without it, rename actions silently fail. | Low -- update `TorrentSession.name` and persist to resume DB. |
| `/api/v2/app/defaultSavePath` | GET | VueTorrent and some Flood forks call this on startup to pre-fill the add-torrent dialog. Returns a plain-text path. | Trivial -- return `session_manager.default_save_path`. |
| `/api/v2/torrents/toggleSequentialDownload` | POST | qBittorrent uses toggle (not set) for the sequential download button. Some clients send this instead of `setSequentialDownload`. | Low -- read current value, flip it. |
| `/api/v2/transfer/toggleSpeedLimitsMode` | POST | The alt-speed button in all major WebUI clients calls this endpoint. Without it, the button does nothing. | Low -- would need an `alt_speed_active` flag to toggle, or return OK as a no-op. |
| `/api/v2/torrents/setAutoManagement` | POST | qui sends this when auto TMM is toggled. Should accept and ignore (or implement basic TMM). | Trivial -- accept and return OK. |
| `/api/v2/torrents/setForceStart` | POST | qui sends this for force-start. Should accept and optionally bypass queue limits. | Low -- accept and resume torrent, ignoring queue. |

### Medium Priority

| Endpoint | Method | Why | Complexity |
|----------|--------|-----|------------|
| `/api/v2/torrents/pieceStates` | GET | Used by WebUI clients to render the piece progress bar. Returns array of 0/1/2 per piece. | Medium -- need to expose per-piece state from `PieceTracker`. |
| `/api/v2/torrents/pieceHashes` | GET | Used by some clients to display piece hash info. Returns array of hex strings. | Medium -- need to read piece hashes from metainfo. |
| `/api/v2/torrents/renameFile` | POST | Allows renaming individual files inside a torrent from the WebUI. | Medium -- need to update storage path mapping. |
| `/api/v2/torrents/renameFolder` | POST | Allows renaming a folder inside a multi-file torrent. | Medium -- similar to renameFile but for directories. |
| `/api/v2/torrents/export` | GET | Export `.torrent` file for an added torrent. Some clients use this for backup. | Low -- return stored `torrent_bytes` with content-type `application/x-bittorrent`. |
| `/api/v2/transfer/setDownloadLimit` | POST | Global download limit via transfer endpoint (separate from preferences). | Trivial -- call `setGlobalDlLimit`. |
| `/api/v2/transfer/setUploadLimit` | POST | Global upload limit via transfer endpoint. | Trivial -- call `setGlobalUlLimit`. |
| `/api/v2/transfer/downloadLimit` | GET | Global download limit query. | Trivial -- return current limit value. |
| `/api/v2/transfer/uploadLimit` | GET | Global upload limit query. | Trivial -- return current limit value. |
| `/api/v2/torrents/addPeers` | POST | Manually add peers to a torrent. Used by advanced users. | Medium -- need to connect to specified addresses via the ring. |

---

## C. Not Implemented (Low Priority)

These endpoints exist in qBittorrent but are not needed for Varuna's use case.

### Will Not Implement

| Endpoint | Reason |
|----------|--------|
| `/api/v2/app/shutdown` | Varuna is a systemd daemon. Use `systemctl stop varuna`. |
| `/api/v2/app/cookies` / `setCookies` | HTTP download cookies for fetching .torrent files from URLs. Varuna does not fetch .torrent files from HTTP URLs. |
| `/api/v2/rss/*` (12 endpoints) | RSS feed management and auto-downloading rules. Out of scope -- use Sonarr/Radarr/Autobrr instead. |
| `/api/v2/search/*` (8 endpoints) | Search plugin management. Out of scope -- use Jackett/Prowlarr instead. |
| `/api/v2/log/main` | Application log retrieval. Use `journalctl -u varuna` instead. |
| `/api/v2/log/peers` | Peer log retrieval. Use `journalctl -u varuna` or `connDiagnostics`. |
| `/api/v2/transfer/setSpeedLimitsMode` | Alternative speed limits scheduling. Use `cron` + `varuna-ctl setPreferences`. |
| `/api/v2/torrents/toggleFirstLastPiecePrio` | First/last piece priority for streaming. Sequential mode covers the main use case. |

### Could Add Later (Low Demand)

| Endpoint | Notes |
|----------|-------|
| `/api/v2/torrents/setAutoManagement` | Auto TMM (Torrent Management Mode). Accept as no-op initially. |
| `/api/v2/torrents/setForceStart` | Force start bypassing queue. Could map to resume + queue bypass. |

---

## D. Endpoint Count Summary

| Category | qBittorrent | Varuna Implemented | Gap |
|----------|-------------|-------------------|-----|
| Auth | 2 | 2 | 0 |
| Application | 7 | 5 | 2 (`shutdown`, `defaultSavePath`, `cookies`, `setCookies`) |
| Log | 2 | 0 | 2 (will not implement) |
| Sync | 2 | 2 | 0 |
| Transfer | 8 | 4+3 extensions | 4 (`toggleSpeedLimitsMode`, `setSpeedLimitsMode`, `setDownloadLimit`, `setUploadLimit`, `downloadLimit`, `uploadLimit`) |
| Torrents (core) | 22 | 19 | 3 (`rename`, `addPeers`, `stop`/`start` naming) |
| Torrents (files) | 5 | 3 | 2 (`pieceStates`, `pieceHashes`) |
| Torrents (queue) | 4 | 4 | 0 |
| Torrents (categories) | 5 | 5 | 0 |
| Torrents (tags) | 5 | 5 | 0 |
| Torrents (misc) | 5 | 3 | 2 (`toggleSequentialDownload`, `toggleFirstLastPiecePrio`) |
| RSS | 12 | 0 | 12 (will not implement) |
| Search | 8 | 0 | 8 (will not implement) |
| **Total** | **87** | **55 + 4 extensions** | **32** |

Excluding RSS (12) and Search (8) which are out of scope, the gap is **12 endpoints**, most of which are trivial or low complexity.

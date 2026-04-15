# Varuna vs qBittorrent API Diff Report

This document details field-level and behavioral differences between Varuna's API
responses and qBittorrent's documented API format.

Source analysis: `src/rpc/handlers.zig`, `src/rpc/compat.zig`, `src/rpc/sync.zig`

## 1. torrents/info Response Fields

### Fields Varuna Returns (matching qBittorrent)

All of the following fields are present and semantically compatible:

| Field | Varuna Source | Notes |
|-------|--------------|-------|
| `name` | `stat.name` | |
| `hash` | `stat.info_hash_hex` | 40-char lowercase hex |
| `infohash_v1` | `stat.info_hash_hex` | Same as `hash` |
| `infohash_v2` | `stat.info_hash_v2` | 64-char hex or empty string for v1-only |
| `state` | `compat.torrentStateString()` | See state mapping section |
| `size` | `stat.total_size` | |
| `total_size` | `stat.total_size` | |
| `progress` | `stat.progress` | 4 decimal places |
| `dlspeed` | `stat.download_speed` | |
| `upspeed` | `stat.upload_speed` | |
| `num_seeds` | `stat.scrape_complete` | From tracker scrape |
| `num_leechs` | `stat.peers_connected` | Connected peers |
| `num_complete` | `stat.scrape_complete` | |
| `num_incomplete` | `stat.scrape_incomplete` | |
| `added_on` | `stat.added_on` | Unix timestamp |
| `completion_on` | computed | `added_on` if progress >= 1.0, else -1 |
| `save_path` | `stat.save_path` | |
| `content_path` | `compat.buildContentPath()` | `save_path/name` |
| `download_path` | hardcoded `""` | |
| `pieces_have` | `stat.pieces_have` | |
| `pieces_num` | `stat.pieces_total` | |
| `dl_limit` | `stat.dl_limit` | |
| `up_limit` | `stat.ul_limit` | |
| `eta` | `stat.eta` | Seconds, -1 if unknown |
| `ratio` | `stat.ratio` | 4 decimal places |
| `seq_dl` | `stat.sequential_download` | |
| `f_l_piece_prio` | hardcoded `false` | |
| `force_start` | hardcoded `false` | |
| `super_seeding` | `stat.super_seeding` | |
| `auto_tmm` | hardcoded `false` | |
| `category` | `stat.category` | |
| `tags` | `stat.tags` | Comma-separated |
| `tracker` | `stat.tracker` | First announce URL |
| `trackers_count` | `stat.trackers_count` | |
| `amount_left` | `total_size - bytes_downloaded` | |
| `completed` | `stat.bytes_downloaded` | |
| `downloaded` | `stat.bytes_downloaded` | |
| `downloaded_session` | `stat.bytes_downloaded` | Same as `downloaded` (no session tracking) |
| `uploaded` | `stat.bytes_uploaded` | |
| `uploaded_session` | `stat.bytes_uploaded` | Same as `uploaded` (no session tracking) |
| `time_active` | `now - added_on` | |
| `seeding_time` | `stat.seeding_time` | |
| `last_activity` | `now` | Always current time |
| `seen_complete` | hardcoded `-1` | |
| `priority` | `stat.queue_position` | |
| `availability` | hardcoded `-1` | Not implemented |
| `max_ratio` | hardcoded `-1` | |
| `max_seeding_time` | hardcoded `-1` | |
| `ratio_limit` | `stat.ratio_limit` | 4 decimal places |
| `seeding_time_limit` | `stat.seeding_time_limit` | |
| `popularity` | hardcoded `0` | |
| `magnet_uri` | `compat.buildMagnetUri()` | |
| `reannounce` | hardcoded `0` | |
| `partial_seed` | `stat.partial_seed` | Only in `/torrents/info`, not in `/sync/maindata` |

### Fields Varuna Returns That qBittorrent Does Not

| Field | Notes |
|-------|-------|
| `private` | Varuna includes `"private": true/false`. qBittorrent uses `isPrivate` in properties only, not in torrents/info. Most clients ignore unknown fields so this is harmless. |
| `infohash_v2` | Varuna includes this in torrents/info. qBittorrent v5.0 also includes it, so this is compatible. |

### Fields qBittorrent Returns That Varuna Does Not

| Field | Impact | Notes |
|-------|--------|-------|
| `isPrivate` | Low | qBittorrent uses `isPrivate` naming. Varuna uses `private`. Some clients may check for `isPrivate`. |

### Fields With Behavioral Differences

| Field | qBittorrent | Varuna | Impact |
|-------|-------------|--------|--------|
| `downloaded_session` | Bytes downloaded since app restart | Same as `downloaded` (total) | Low -- session tracking not implemented |
| `uploaded_session` | Bytes uploaded since app restart | Same as `uploaded` (total) | Low -- session tracking not implemented |
| `last_activity` | Timestamp of last chunk transfer | Always `now` | Low -- cosmetic |
| `seen_complete` | Timestamp of last time a complete copy was seen | Always `-1` | Low -- cosmetic |
| `availability` | Distributed copies from peer bitfields | Always `-1` | Medium -- some UIs display this |
| `popularity` | Not standard qBittorrent field | Always `0` | None |
| `completion_on` | Timestamp of actual completion | Uses `added_on` as fallback | Low -- close enough for display |
| `f_l_piece_prio` | Whether first/last piece priority is enabled | Always `false` | Low -- not implemented |
| `force_start` | Whether force-start is enabled | Always `false` | Low -- not implemented |
| `reannounce` | Seconds until next tracker announce | Always `0` | Low -- cosmetic |
| `dl_limit` / `up_limit` | Uses `-1` for unlimited | Uses `0` for unlimited | Medium -- some clients may treat `0` and `-1` differently |

---

## 2. torrents/properties Response Fields

### Fields Present and Compatible

`save_path`, `creation_date`, `piece_size`, `comment`, `created_by`, `total_size`,
`pieces_have`, `pieces_num`, `dl_speed`, `up_speed`, `dl_limit`, `up_limit`, `eta`,
`hash`, `infohash_v1`, `infohash_v2`, `name`, `ratio`, `share_ratio`, `time_elapsed`,
`time_active`, `seeding_time`, `nb_connections`, `nb_connections_limit`, `peers`,
`peers_total`, `seeds`, `seeds_total`, `addition_date`, `completion_date`,
`total_downloaded`, `total_downloaded_session`, `total_uploaded`, `total_uploaded_session`,
`is_private`, `seq_dl`, `super_seeding`, `web_seeds_count`, `partial_seed`,
`ratio_limit`, `seeding_time_limit`

### Placeholder/Hardcoded Fields

| Field | Value | qBittorrent | Notes |
|-------|-------|-------------|-------|
| `download_path` | `""` | Actual download path | Separate download path not supported |
| `total_wasted` | `0` | Bytes that failed hash verification | Would require tracking corrupted data |
| `dl_speed_avg` | `0` | Average download speed | Would require cumulative tracking |
| `up_speed_avg` | `0` | Average upload speed | Would require cumulative tracking |
| `last_seen` | `-1` | Last seen complete timestamp | Not tracked |
| `reannounce` | `0` | Seconds to next announce | Not exposed |

### Fields Varuna Includes That qBittorrent Does Not

| Field | Notes |
|-------|-------|
| `infohash_v2` | Varuna includes v2 hash in properties. qBittorrent v5.0+ also includes this. |

---

## 3. sync/maindata Response Structure

### Structure Differences

| Field | qBittorrent | Varuna | Notes |
|-------|-------------|--------|-------|
| `categories_removed` | Present in delta updates | Not included | Varuna always sends full categories object |
| `tags_removed` | Present in delta updates | Not included | Varuna always sends full tags array |

### server_state Field Differences

| Field | qBittorrent | Varuna | Notes |
|-------|-------------|--------|-------|
| `connection_status` | Dynamic (`connected`/`firewalled`/`disconnected`) | Always `"connected"` | Varuna does not detect firewall status |
| `queueing` | Reflects actual queueing state | Always `false` | Should reflect `queue_manager.config.enabled` |
| `use_alt_speed_limits` | Alternative speed mode state | Always `false` | No alternative speed mode |
| `refresh_interval` | User-configurable | Always `1500` | Not configurable |
| `free_space_on_disk` | Actual free space from `statfs` | Always `0` | Could be implemented with `statfs` |
| `total_peer_connections` | Sum of all peer connections | Always `0` | Could sum per-torrent peer counts |
| `alltime_dl` | All-time download total | Session total (same as `dl_info_data`) | No persistent tracking across restarts |
| `alltime_ul` | All-time upload total | Session total (same as `up_info_data`) | No persistent tracking across restarts |

---

## 4. torrents/files Response Fields

### Compatible Fields

`index`, `name`, `size`, `progress`, `priority`, `is_seed`, `piece_range`, `availability`

### Differences

| Field | qBittorrent | Varuna | Notes |
|-------|-------------|--------|-------|
| `availability` | Computed from peer bitfields | Same as `progress` | Approximated |
| `is_seed` | Whether file is complete | Always `false` | Should check progress == 1.0 |

---

## 5. torrents/trackers Response Fields

### Compatible Fields

`url`, `status`, `tier`, `num_peers`, `num_seeds`, `num_leeches`, `num_downloaded`, `msg`

### Differences

| Field | qBittorrent | Varuna | Notes |
|-------|-------------|--------|-------|
| `msg` | Tracker response message | Always `""` | Tracker messages not stored |

---

## 6. sync/torrentPeers Response Fields

### Compatible Fields

`client`, `dl_speed`, `downloaded`, `flags`, `ip`, `port`, `progress`, `up_speed`, `uploaded`

### Placeholder/Empty Fields

| Field | qBittorrent | Varuna | Notes |
|-------|-------------|--------|-------|
| `connection` | Connection type (BT/uTP/etc) | `""` | Not tracked |
| `country` | Country name from GeoIP | `""` | No GeoIP database |
| `country_code` | ISO country code | `""` | No GeoIP database |
| `files` | Files being transferred | `""` | Not tracked |
| `flags_desc` | Human-readable flag descriptions | `""` | Not implemented |
| `relevance` | Peer relevance score | Always `1` | Not computed |

### Varuna Extensions

| Field | Notes |
|-------|-------|
| `upload_only` | Boolean indicating whether peer is upload-only (BEP 21). Not in qBittorrent's response. |

---

## 7. State Mapping

Varuna maps internal states to qBittorrent state strings:

| Varuna State | Progress < 1.0 | Progress >= 1.0 |
|-------------|----------------|-----------------|
| `downloading` | `downloading` | `uploading` |
| `seeding` | `uploading` | `uploading` |
| `paused` | `pausedDL` | `pausedUP` |
| `stopped` | `stoppedDL` | `stoppedUP` |
| `queued` | `queuedDL` | `queuedUP` |
| `checking` | `checkingDL` | `checkingUP` |
| `metadata_fetching` | `metaDL` | `metaDL` |
| `error` | `error` | `error` |

### States qBittorrent Has That Varuna Does Not Map To

| State | Description | Notes |
|-------|-------------|-------|
| `stalledDL` | Downloading but no peers transferring data | Varuna reports `downloading` instead |
| `stalledUP` | Seeding but no peers downloading from us | Varuna reports `uploading` instead |
| `forcedDL` | Force-started download (bypasses queue) | Not supported |
| `forcedUP` | Force-started upload (bypasses queue) | Not supported |
| `allocating` | Allocating disk space | Varuna allocates synchronously during init |
| `missingFiles` | Torrent data files are missing | Varuna reports `error` instead |
| `checkingResumeData` | Checking resume data on startup | Not applicable |
| `moving` | Torrent data is being moved | Varuna moves synchronously |
| `unknown` | Unknown state | Not used |

---

## 8. Authentication Differences

| Aspect | qBittorrent | Varuna | Notes |
|--------|-------------|--------|-------|
| Cookie name | Configurable (`SID` default) | Fixed `SID` | |
| IP ban on failed logins | Yes (configurable) | No | Could be added |
| HTTPS | Configurable | Not built-in | Use reverse proxy |
| Custom cookie name | Yes | No | |
| Auth header support | Bearer token alternate | Cookie only | |

---

## 9. Error Response Format

| Aspect | qBittorrent | Varuna | Notes |
|--------|-------------|--------|-------|
| Unknown endpoint | 404 with no body | 404 with `{"error":"not found"}` | Different body format |
| Unauthorized | 403 `Forbidden` text | 403 `Forbidden` text | Compatible |
| Invalid hash | 404 with no body | 404 with `{"error":"TorrentNotFound"}` | Different body format |
| Missing param | 400 (varies) | 400 with `{"error":"missing <param>"}` | More descriptive |

---

## 10. Summary of Impact

### High Impact (may break client functionality)
- `dl_limit`/`up_limit` using `0` instead of `-1` for unlimited
- Missing `stalledDL`/`stalledUP` states (torrent appears active when stalled)
- `queueing` in server_state always `false` even when queue is enabled

### Medium Impact (cosmetic or minor feature gaps)
- `availability` always -1 in torrents/info
- `free_space_on_disk` always 0 in server_state
- `total_peer_connections` always 0 in server_state
- `downloaded_session`/`uploaded_session` not separate from totals
- `is_seed` always false in files response

### Low Impact (rarely noticed)
- `last_activity` always current time
- `seen_complete` always -1
- `connection`/`country`/`country_code` empty in peer data
- `total_wasted`/`dl_speed_avg`/`up_speed_avg` always 0 in properties
- `msg` always empty in trackers

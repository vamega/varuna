# qBittorrent WebAPI Compatibility

Varuna implements a subset of the [qBittorrent WebAPI v2](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-4.1)) for compatibility with WebUI clients such as [qui](https://github.com/autobrr/qui) and Flood.

This document tracks which endpoints are implemented, which return placeholder data, and which are explicitly unsupported.

## Implemented Endpoints

### Auth
| Endpoint | Status |
|---|---|
| `POST /api/v2/auth/login` | Full |
| `GET /api/v2/auth/logout` | Full |

### App
| Endpoint | Status |
|---|---|
| `GET /api/v2/app/webapiVersion` | Full (returns "2.9.3") |
| `GET /api/v2/app/version` | Full (returns "v5.0.0") |
| `GET /api/v2/app/buildInfo` | Full |
| `GET /api/v2/app/preferences` | Full (40+ fields) |
| `POST /api/v2/app/setPreferences` | Full (form + JSON) |

### Transfer
| Endpoint | Status |
|---|---|
| `GET /api/v2/transfer/info` | Full (real DHT node count, speeds, limits) |
| `GET /api/v2/transfer/speedLimitsMode` | Full |
| `POST /api/v2/transfer/banPeers` | Full |
| `POST /api/v2/transfer/unbanPeers` | Full |
| `GET /api/v2/transfer/bannedPeers` | Full |
| `POST /api/v2/transfer/importBanList` | Full |

### Torrents
| Endpoint | Status |
|---|---|
| `GET /api/v2/torrents/info` | Full (40+ fields, v2 info-hash, scrape data) |
| `POST /api/v2/torrents/add` | Full (multipart + raw, magnet URIs) |
| `POST /api/v2/torrents/delete` | Full (with --delete-files) |
| `POST /api/v2/torrents/pause` | Full |
| `POST /api/v2/torrents/resume` | Full |
| `GET /api/v2/torrents/properties` | Full (scrape-based peers/seeds totals, v2 info-hash, creation_date) |
| `GET /api/v2/torrents/files` | Full (index, availability, piece_range) |
| `GET /api/v2/torrents/trackers` | Full (with msg field) |
| `POST /api/v2/torrents/filePrio` | Full |
| `POST /api/v2/torrents/setSequentialDownload` | Full |
| `POST /api/v2/torrents/setDownloadLimit` | Full |
| `POST /api/v2/torrents/setUploadLimit` | Full |
| `GET /api/v2/torrents/downloadLimit` | Full |
| `GET /api/v2/torrents/uploadLimit` | Full |
| `POST /api/v2/torrents/forceReannounce` | Full |
| `POST /api/v2/torrents/recheck` | Full |
| `POST /api/v2/torrents/setLocation` | Full |
| `POST /api/v2/torrents/setSuperSeeding` | Full |
| `GET /api/v2/torrents/connDiagnostics` | Full (Varuna extension) |

### Categories & Tags
| Endpoint | Status |
|---|---|
| `GET /api/v2/torrents/categories` | Full |
| `POST /api/v2/torrents/createCategory` | Full |
| `POST /api/v2/torrents/editCategory` | Full |
| `POST /api/v2/torrents/removeCategories` | Full |
| `POST /api/v2/torrents/setCategory` | Full |
| `GET /api/v2/torrents/tags` | Full |
| `POST /api/v2/torrents/createTags` | Full |
| `POST /api/v2/torrents/deleteTags` | Full |
| `POST /api/v2/torrents/addTags` | Full |
| `POST /api/v2/torrents/removeTags` | Full |

### Sync
| Endpoint | Status |
|---|---|
| `GET /api/v2/sync/maindata` | Full (delta protocol, rid-based, Wyhash change detection) |
| `GET /api/v2/sync/torrentPeers` | Full (real peer data, speeds, client names) |

## Remaining Placeholder Values

| Field | Location | Status |
|---|---|---|
| `total_wasted` | properties | Always 0. Requires tracking bytes that fail hash verification. |
| `dl_speed_avg` / `up_speed_avg` | properties | Always 0. Requires tracking cumulative speed averages. |
| `free_space_on_disk` | sync/maindata server_state | Always 0. Could use `statfs` but not critical. |
| `total_peer_connections` | sync/maindata server_state | Always 0. Could sum per-torrent peer counts. |
| `availability` | torrent info/sync | Always -1. Requires computing distributed copies from peer bitfields. |
| `popularity` | torrent info/sync | Always 0. Not a standard qBittorrent field. |

## Unsupported -- Will Not Implement

These endpoints are explicitly out of scope for Varuna.

| Endpoint | Reason |
|---|---|
| `POST /api/v2/torrents/addTrackers` | Modifying tracker lists post-add conflicts with private tracker semantics. Use the torrent file's announce list. |
| `POST /api/v2/torrents/removeTrackers` | Same as above. |
| `POST /api/v2/torrents/editTracker` | Same as above. |
| Time-based alt-speed scheduling | Use `cron` + `varuna-ctl` instead. See `docs/future-features.md`. |

## Unsupported -- Could Be Added Later

These endpoints are not implemented but could be added if there is demand.

| Endpoint | Notes |
|---|---|
| `POST /api/v2/torrents/rename` | Rename torrent display name. |
| `POST /api/v2/torrents/renameFile` | Rename individual file within torrent. |
| `POST /api/v2/torrents/renameFolder` | Rename folder within torrent. |
| `GET /api/v2/torrents/pieceStates` | Per-piece download state (not downloaded / downloading / downloaded). |
| `GET /api/v2/torrents/pieceHashes` | Per-piece SHA-1 hash list. |
| `GET /api/v2/torrents/export` | Export .torrent file for an added torrent. |
| `POST /api/v2/torrents/toggleFirstLastPiecePrio` | First/last piece priority for streaming. Sequential mode covers the main use case. |
| `POST /api/v2/torrents/setShareLimits` | Per-torrent share ratio and seeding time limits. |
| Queue management (`topPrio`, `bottomPrio`, `increasePrio`, `decreasePrio`) | Torrent queue ordering. Varuna currently processes all active torrents equally. |
| `/api/v2/rss/*` | RSS feed management and auto-downloading rules. |
| `/api/v2/search/*` | Search plugin management (search engines, results). |
| `/api/v2/transfer/setDownloadLimit` | Global rate limits are set via `setPreferences`. |
| `/api/v2/transfer/setUploadLimit` | Same as above. |
| `/api/v2/log/*` | Log retrieval endpoints. |

## Error Handling for Unknown Paths

Varuna returns HTTP 404 with `{"error":"not found"}` for any API path that does not match a known endpoint. This applies to all unsupported endpoints listed above. Unauthenticated requests to any endpoint (except login) receive HTTP 403.

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
| `GET /api/v2/app/defaultSavePath` | Full |
| `POST /api/v2/app/shutdown` | Full (optional `timeout` param) |

### Transfer
| Endpoint | Status |
|---|---|
| `GET /api/v2/transfer/info` | Full (real DHT node count, speeds, limits) |
| `GET /api/v2/transfer/speedLimitsMode` | Full |
| `POST /api/v2/transfer/toggleSpeedLimitsMode` | 501 — alt-speed requires a second set of rate limits, toggle flag, and optional scheduling. Use `setDownloadLimit`/`setUploadLimit` directly or automate via `cron` + `varuna-ctl`. |
| `GET /api/v2/transfer/downloadLimit` | Full |
| `GET /api/v2/transfer/uploadLimit` | Full |
| `POST /api/v2/transfer/setDownloadLimit` | Full |
| `POST /api/v2/transfer/setUploadLimit` | Full |
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
| `POST /api/v2/torrents/setLocation` | **Deprecated, returns 400.** qBittorrent's contract returns synchronously after the move completes — that holds the RPC handler thread for arbitrary time on cross-filesystem moves of multi-GB torrent data, and the original implementation issued userspace `posix.read` / `posix.write` in a copy loop. Varuna refuses to honour the sync contract; clients should use `POST /api/v2/varuna/torrents/move` (see [Varuna Extensions](#varuna-extensions) below). |
| `POST /api/v2/torrents/setSuperSeeding` | Full |
| `POST /api/v2/torrents/addTrackers` | Full |
| `POST /api/v2/torrents/removeTrackers` | Full |
| `POST /api/v2/torrents/editTracker` | Full |
| `GET /api/v2/torrents/connDiagnostics` | Full (Varuna extension) |
| `POST /api/v2/torrents/rename` | Full |
| `POST /api/v2/torrents/toggleSequentialDownload` | Full |
| `POST /api/v2/torrents/setAutoManagement` | 501 — auto-management requires per-category save paths, post-completion move hooks (io_uring), and PieceStore mapping updates. Use `POST /api/v2/varuna/torrents/move` manually or automate via `varuna-ctl move`. |
| `POST /api/v2/torrents/setForceStart` | Full (bypasses queue limits) |
| `GET /api/v2/torrents/pieceStates` | Full |
| `GET /api/v2/torrents/pieceHashes` | Full (v1 only) |
| `POST /api/v2/torrents/renameFile` | 501 — requires io_uring filesystem rename, PieceStore mapping updates, SQLite persistence, and coordination with active downloads. |
| `POST /api/v2/torrents/renameFolder` | 501 — same as renameFile plus recursive directory handling across multiple file mappings. |
| `GET /api/v2/torrents/export` | Full |
| `POST /api/v2/torrents/addPeers` | Full |

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

## Varuna Extensions

These endpoints are varuna-native and have no qBittorrent equivalent.
Clients reaching them have explicitly opted into varuna's design (the
`/varuna/` path segment makes the dependency explicit). See
[`progress-reports/2026-04-30-async-move-job.md`](../progress-reports/2026-04-30-async-move-job.md)
for the design rationale.

### Async file-move

The async file-move endpoint replaces the qBittorrent-compatible
`POST /api/v2/torrents/setLocation` path, which has been deprecated
because its synchronous semantics are incompatible with the daemon's
performance guarantees. Cross-filesystem moves of multi-GB torrent data
can hold the calling thread for arbitrary time; the new endpoint
returns immediately with a job id, copies on a worker thread, and
exposes progress via polling.

| Endpoint | Status |
|---|---|
| `POST /api/v2/varuna/torrents/move` | Start a move. Body: `hashes=<info-hash>&location=<absolute-path>`. Returns `202 Accepted` with `{"id": <u64>}`. |
| `GET /api/v2/varuna/torrents/move/<id>` | Snapshot progress. Returns `{"id":...,"state":"created\|running\|succeeded\|failed\|canceled","bytes_copied":...,"total_bytes":...,"files_done":...,"total_files":...,"used_rename":bool,"error":"..."}`. |
| `POST /api/v2/varuna/torrents/move/<id>/cancel` | Request cancellation. Idempotent. Worker observes between files. |
| `POST /api/v2/varuna/torrents/move/<id>/commit` | Apply the destination path to the torrent's `save_path` and unpause. Required after `succeeded` so that the daemon doesn't write to the new location while the move is still in flight. |
| `DELETE /api/v2/varuna/torrents/move/<id>` | Forget a terminal job's bookkeeping. |

State machine: `created → running → {succeeded, failed, canceled}`.
Every job is in exactly one state at a time; once a terminal state is
reached the bookkeeping persists until the operator calls `DELETE`.

Same-fs detection uses `fstatat(2)` on src and dst to compare device
ids (`dev_t`); when they match the worker thread issues a single
`rename(2)` for constant-time relocation. Cross-fs falls through to a
recursive walk that copies each file via `copy_file_range(2)` (in-kernel
on Linux ≥5.3 ⇒ always available on varuna's 6.6 floor; emulated via
`pread`/`pwrite` on platforms without the syscall) with a 32 MiB chunk
cap to keep cancellation responsive.

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
| Time-based alt-speed scheduling | Use `cron` + `varuna-ctl` instead. See `docs/future-features.md`. |

## Unsupported -- Could Be Added Later

These endpoints are not implemented but could be added if there is demand.

| Endpoint | Notes |
|---|---|
| `POST /api/v2/torrents/toggleFirstLastPiecePrio` | First/last piece priority for streaming. Sequential mode covers the main use case. |
| `/api/v2/rss/*` | RSS feed management and auto-downloading rules. |
| `/api/v2/search/*` | Search plugin management (search engines, results). |
| `/api/v2/log/*` | Log retrieval endpoints. |

## Error Handling for Unknown Paths

Varuna returns HTTP 404 with `{"error":"not found"}` for any API path that does not match a known endpoint. This applies to all unsupported endpoints listed above. Unauthenticated requests to any endpoint (except login) receive HTTP 403.

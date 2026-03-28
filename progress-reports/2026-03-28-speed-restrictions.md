# Speed Restrictions (Rate Limiting)

## What was done

Implemented download and upload speed restrictions for the varuna BitTorrent daemon, supporting both per-torrent and global (daemon-wide) rate limits.

### Token bucket rate limiter (`src/io/rate_limiter.zig`)
- New `TokenBucket` struct: fills at configured bytes/sec, tracks tokens via monotonic clock
- `RateLimiter` pairs download + upload buckets
- Comptime-safe initialization (`initComptime`) for struct field defaults
- Rate of 0 means unlimited (all operations pass through)
- 15 unit tests covering consume, refill, partial consume, setRate, delay calculation

### Event loop integration (`src/io/event_loop.zig`)
- Global `RateLimiter` on `EventLoop` struct
- Per-torrent `RateLimiter` on `TorrentContext` struct
- `consumeDownloadTokens` / `consumeUploadTokens` check per-torrent then global limits
- `isDownloadThrottled` / `isUploadThrottled` for fast throttle checks
- Download throttling: `tryAssignPieces` and `tryFillPipeline` skip work when throttled
- Upload throttling: `servePieceRequest` drops requests when throttled, `flushQueuedResponses` and `sendPieceBlock` consume upload tokens
- Piece data receipt (message id 7) consumes download tokens

### Config (`src/config.zig`)
- `network.dl_limit` and `network.ul_limit` fields (bytes/sec, 0 = unlimited)
- Applied to shared event loop at daemon startup

### Per-torrent state (`src/daemon/torrent_session.zig`)
- `dl_limit` and `ul_limit` fields on `TorrentSession`
- Propagated to event loop on `integrateIntoEventLoop` and `integrateSeedIntoEventLoop`
- Included in `Stats` struct for API reporting

### API endpoints (`src/rpc/handlers.zig`)
- `GET /api/v2/app/preferences` -- returns `{dl_limit, up_limit}`
- `POST /api/v2/app/setPreferences` -- set global limits (`dl_limit=N&up_limit=N`)
- `GET /api/v2/transfer/info` -- now includes `dl_rate_limit` and `up_rate_limit`
- `GET /api/v2/transfer/speedLimitsMode` -- returns 0 (normal mode)
- `POST /api/v2/torrents/setDownloadLimit` -- per-torrent download limit
- `POST /api/v2/torrents/setUploadLimit` -- per-torrent upload limit
- `POST /api/v2/torrents/downloadLimit` -- query per-torrent download limit
- `POST /api/v2/torrents/uploadLimit` -- query per-torrent upload limit
- `GET /api/v2/torrents/info` -- now includes `dl_limit` and `up_limit` per torrent

### CLI (`src/ctl/main.zig`)
- `varuna-ctl set-dl-limit <hash|global> <N>` -- set download limit
- `varuna-ctl set-ul-limit <hash|global> <N>` -- set upload limit
- `varuna-ctl get-dl-limit <hash|global>` -- query download limit
- `varuna-ctl get-ul-limit <hash|global>` -- query upload limit

### Session manager (`src/daemon/session_manager.zig`)
- `setTorrentDlLimit` / `setTorrentUlLimit` -- update both session and event loop
- `setGlobalDlLimit` / `setGlobalUlLimit` -- update shared event loop

## Design decisions

- **Token bucket algorithm**: Standard approach for BitTorrent rate limiting. 1-second burst capacity (capacity = rate). Refill based on monotonic clock elapsed time.
- **Throttle by skipping work, not blocking**: When rate limited, the event loop skips piece assignment and pipeline filling rather than sleeping. This keeps the event loop non-blocking per io_uring policy.
- **Upload throttling drops requests**: When upload is throttled, piece requests from peers are silently dropped. The peer will re-request. This avoids buffering and complexity.
- **Per-torrent + global layering**: `consumeDownloadTokens` checks per-torrent bucket first, then global. Both must have tokens for I/O to proceed. Whichever is lower effectively applies.
- **qBittorrent API compatibility**: Endpoints follow qBittorrent conventions for preferences, speed limits, and per-torrent limits.

## What was learned

- Zig struct field defaults must be comptime-known. `std.time.nanoTimestamp()` is a runtime call, so token buckets in struct defaults need a comptime-safe constructor that defers the first timestamp to runtime.
- Rate limiting at the event loop level (not kernel level) is the right approach for BitTorrent -- it lets us make intelligent decisions about which pieces and peers to prioritize.

## Key files changed
- `src/io/rate_limiter.zig` (new) -- token bucket implementation
- `src/io/event_loop.zig` -- rate limit integration into I/O dispatch
- `src/config.zig` -- global speed limit config fields
- `src/daemon/torrent_session.zig` -- per-torrent speed limit state
- `src/daemon/session_manager.zig` -- speed limit management methods
- `src/rpc/handlers.zig` -- API endpoints for speed limits
- `src/ctl/main.zig` -- CLI commands for speed limits
- `src/io/root.zig` -- module export for rate_limiter
- `src/main.zig` -- apply config speed limits at startup

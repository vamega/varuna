# API Endpoints, ETA Calculation, and Share Ratio Tracking

## What was done

Added 7 new qBittorrent v2 compatible API endpoints, ETA calculation, and share ratio tracking to the daemon's HTTP API.

### New Stats fields
- `eta: i64` -- seconds remaining (-1 if not downloading or speed is 0). Formula: `bytes_remaining / download_speed`.
- `ratio: f64` -- share ratio (`bytes_uploaded / bytes_downloaded`, 0.0 if no downloads).
- `sequential_download: bool` -- whether sequential mode is enabled (stored value, actual piece picking depends on workstream B).

All three are returned in `torrents/info` and `torrents/properties` responses.

### New API endpoints

1. **torrents/files** (GET) -- lists files with name, size, per-file progress, priority. Progress computed by checking piece completion across each file's piece range using the layout's `first_piece`/`end_piece_exclusive`.

2. **torrents/trackers** (GET) -- lists tracker URLs with status, tier, peer count from metainfo announce + announce_list.

3. **torrents/properties** (GET) -- detailed properties: save_path, piece_size, comment, speeds, limits, ETA, ratio, time_active, seeding_time, connections, download/upload totals.

4. **torrents/filePrio** (POST) -- sets per-file priority (0=skip, 1=normal, 6=high, 7=max). Values stored in `TorrentSession.file_priorities`, lazily allocated. Actual selective download depends on workstream B.

5. **torrents/setSequentialDownload** (POST) -- toggles sequential mode flag on TorrentSession.

6. **torrents/forceReannounce** (POST) -- spawns background thread to do tracker announce.

7. **torrents/recheck** (POST) -- stops torrent, restarts it (which triggers full recheck from disk).

### Infrastructure changes

- `SessionManager.getSession()` -- exposes direct session access for metadata queries.
- `SessionManager.setSequentialDownload()`, `setFilePriority()`, `forceReannounce()`, `forceRecheck()` -- new session management methods.
- `TorrentSession.announceCompletedWorker` made `pub` for reuse by `forceReannounce`.
- Query string parsing in `handleTorrents` -- GET endpoints can now receive parameters via URL query string (e.g., `?hash=...`).

## Key files changed
- `src/rpc/handlers.zig` -- all new endpoint handlers
- `src/daemon/torrent_session.zig` -- Stats fields (eta, ratio, sequential_download), file_priorities, sequential_download
- `src/daemon/session_manager.zig` -- getSession, setSequentialDownload, setFilePriority, forceReannounce, forceRecheck

## Design decisions
- Per-file progress is computed from piece-level completion, not byte-level. This means a file spanning 3 pieces shows 33%/67%/100%, not exact byte progress. This matches qBittorrent behavior.
- `file_priorities` array is lazily allocated only when filePrio is first called, avoiding memory overhead for torrents that never use it.
- `forceRecheck` reuses the existing stop/start cycle which naturally triggers a full recheck.
- ETA uses instantaneous download speed rather than a rolling average (the event loop's speed stats are already smoothed).

## Remaining work
- Share ratio persistence across sessions (currently only tracks within a session's lifetime, not persisted to resume DB).
- Rolling average speed for more stable ETA (currently uses event loop's speed window).
- Actual selective download based on file priorities (workstream B).
- Actual sequential piece picking (workstream B).

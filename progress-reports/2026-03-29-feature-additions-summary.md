# Feature Additions Summary

**Date:** 2026-03-29

## Overview

A large batch of features was implemented to close gaps identified in a comprehensive feature analysis against qBittorrent, Transmission, and Deluge.

## Features Implemented

### Bind Interface and Port Ranges
- **SO_BINDTODEVICE**: `network.bind_device = "wg0"` restricts all sockets to a specific NIC/VPN interface. Applied to peer listen socket, outbound peer connections, and API server.
- **Bind address**: `network.bind_address = "10.0.0.1"` binds all sockets to a specific local IP.
- **Port ranges**: `network.port_min = 6881`, `network.port_max = 6889`. Daemon tries each port until one succeeds and reports the actual bound port.
- **Implementation**: New `src/net/socket.zig` module with `applyBindDevice`, `applyBindAddress`, `applyBindConfig` helpers. IFNAMSIZ validation, EPERM/ENODEV error handling.

### Selective File Download
- **File priorities**: Each file can be `normal`, `high`, or `do_not_download`.
- **Piece masking**: `buildPieceMask()` in `src/torrent/file_priority.zig` maps file priorities to a bitfield of wanted pieces. Boundary pieces (spanning wanted + skipped files) are correctly marked as wanted.
- **Lazy file creation**: Skipped files are NOT pre-allocated. If a boundary piece later needs to write to a skipped file, it's created on demand (`ensureFileOpen()` in writer.zig).
- **PieceTracker integration**: `claimPiece()` respects the wanted mask. `isComplete()` returns true when all wanted pieces are done.
- **12 new tests**: file_priority (5), piece_tracker wanted mask (5), PieceStore skip/lazy (2).

### Sequential Download Mode
- **Per-torrent toggle**: `sequential_download: bool` on TorrentSession.
- **Piece selection**: When sequential, `claimPiece()` returns the lowest unclaimed piece the peer has (ignoring availability). Useful for video streaming.
- **API**: `POST /api/v2/torrents/setSequentialDownload` with `hash=<hash>&value=true|false`.

### API Endpoints (7 new)
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `torrents/files` | GET | File list with name, size, progress, priority |
| `torrents/trackers` | GET | Tracker URLs with status, tier, peer count |
| `torrents/properties` | GET | Detailed stats (ETA, ratio, piece_size, time_active) |
| `torrents/filePrio` | POST | Set per-file priority (0=skip, 1=normal, 6=high) |
| `torrents/setSequentialDownload` | POST | Toggle sequential mode |
| `torrents/forceReannounce` | POST | Trigger immediate tracker announce |
| `torrents/recheck` | POST | Stop, recheck all pieces from disk, resume |

### ETA and Share Ratio
- **ETA**: `bytes_remaining / download_speed`, returns -1 when not downloading or speed unknown.
- **Ratio**: `bytes_uploaded / bytes_downloaded`, returns 0.0 when no downloads.
- Both included in `torrents/info` and `torrents/properties` responses.

### Connection Limits and Announce Staggering
- **Global connection limit**: `network.max_connections = 500`. Enforced in `addPeerForTorrent()` and `handleAccept()`.
- **Per-torrent limit**: `network.max_peers_per_torrent = 100`. Uses `peerCountForTorrent()`.
- **Half-open limit**: `network.max_half_open = 50`. Tracks peers in `.connecting` state.
- **Announce jitter**: ±10% random jitter on re-announce interval prevents thundering herd on tracker.
- **Initial stagger**: Deterministic 0-5 second delay before first announce, derived from info_hash.
- **90% capacity warning**: Logs when approaching connection limits.

### Speed Restrictions (from separate branch, merged)
- **Token bucket rate limiter**: `src/io/rate_limiter.zig` with 15 unit tests.
- **Per-torrent + global limits**: both checked, lower value applies.
- **Non-blocking**: throttling skips piece assignment and pipeline filling rather than sleeping.
- **Config**: `network.dl_limit`, `network.ul_limit` (bytes/sec, 0 = unlimited).
- **API**: 8 endpoints matching qBittorrent conventions.
- **CLI**: `set-dl-limit`, `set-ul-limit`, `get-dl-limit`, `get-ul-limit`.

## Design Decisions

### Boundary Pieces in Selective Download
Documented in `design-decisions/boundary-pieces-in-selective-download.md`. Decision: download full boundary pieces including data for skipped files. Matches libtorrent, rakshasa, and qBittorrent. Rationale: piece integrity (SHA-1 verification), seeding capability, protocol constraints.

## Key Lessons

### 1. Feature analysis against mature clients reveals gaps fast
Comparing varuna's config, API, and protocol support against qBittorrent identified ~50 gaps in 30 minutes. Prioritizing by "essential for private tracker use" focused effort on high-impact features.

### 2. Selective download is a data-model change, not just UI
File priorities affect piece selection, storage allocation, completion detection, and seeding. Getting the piece mask right (boundary pieces) is the critical design decision. Everything else follows from it.

### 3. Connection limits prevent real-world failures
Without limits, a daemon with 50 torrents could attempt 50 × 100 = 5000 simultaneous connections, exhausting file descriptors. Per-torrent, global, and half-open limits are table stakes.

### 4. Announce staggering is trivial but essential
Adding ±10% jitter to tracker intervals and a per-torrent initial delay (derived from info_hash) prevents all torrents from hitting the tracker simultaneously. Simple to implement, prevents real-world tracker bans.

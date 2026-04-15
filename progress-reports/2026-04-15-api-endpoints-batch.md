# Add 16 qBittorrent-compatible API endpoints

## What changed

Added 16 missing qBittorrent WebAPI endpoints to the RPC handler layer.

### High Priority (6 endpoints)
1. `POST /api/v2/torrents/rename` -- rename torrent display name, updates `TorrentSession.name` field
2. `GET /api/v2/app/defaultSavePath` -- returns `session_manager.default_save_path` as plain text
3. `POST /api/v2/torrents/toggleSequentialDownload` -- flips `sequential_download` on the session and propagates to piece tracker
4. `POST /api/v2/transfer/toggleSpeedLimitsMode` -- no-op stub (alt-speed not implemented)
5. `POST /api/v2/torrents/setAutoManagement` -- no-op stub (accepts and returns OK)
6. `POST /api/v2/torrents/setForceStart` -- resumes torrent bypassing queue limits

### Medium Priority (10 endpoints)
7. `GET /api/v2/torrents/pieceStates` -- returns JSON array of piece states (0/1/2) from PieceTracker bitfields
8. `GET /api/v2/torrents/pieceHashes` -- returns JSON array of hex-encoded SHA-1 piece hashes from metainfo
9. `POST /api/v2/torrents/renameFile` -- stub (returns OK)
10. `POST /api/v2/torrents/renameFolder` -- stub (returns OK)
11. `GET /api/v2/torrents/export` -- returns raw `.torrent` bytes with `application/x-bittorrent` content type
12. `POST /api/v2/transfer/setDownloadLimit` -- sets global download limit via event loop
13. `POST /api/v2/transfer/setUploadLimit` -- sets global upload limit via event loop
14. `GET /api/v2/transfer/downloadLimit` -- returns current global download limit
15. `GET /api/v2/transfer/uploadLimit` -- returns current global upload limit
16. `POST /api/v2/torrents/addPeers` -- parses comma-separated IP:port list and adds peers via `EventLoop.addPeerAutoTransport`

## Key code references
- `src/rpc/handlers.zig`: all handler functions and route registration
- `src/daemon/session_manager.zig`: new methods -- `renameTorrent`, `toggleSequentialDownload`, `forceStartTorrent`, `getPieceStates`, `getPieceHashes`, `addManualPeers`, `parseIpPort`
- `tests/api_endpoints_test.zig`: 24 tests covering route dispatch, param validation, stubs, auth
- `build.zig`: `test-api` build step

## What was learned
- Zig 0.15 uses `std.fmt.bytesToHex` for hex encoding (not `fmtSliceHexLower`)
- The `SyncState` and `PeerSyncState` structs require an allocator field for initialization
- Piece state data is available through `PieceTracker.complete` and `PieceTracker.in_progress` bitfields
- The `torrent_bytes` field on `TorrentSession` holds the raw `.torrent` file (empty for magnet links)

## Remaining issues
- `renameFile` and `renameFolder` are stubs (actual file rename requires filesystem operations)
- `setAutoManagement` is a no-op (auto torrent management not implemented)
- `toggleSpeedLimitsMode` is a no-op (alternative speed limits not implemented)
- `pieceHashes` only works for v1 torrents (v2 uses per-file Merkle trees)
- `rename` does not persist the new name to SQLite (survives runtime but not restart)

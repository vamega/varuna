# Per-peer speed tracking and client name identification

## What was done

Added two features to close minor API gaps in the `torrentPeers` endpoint:

### 1. Per-peer speed tracking
- Added per-peer rolling speed counters (`current_dl_speed`, `current_ul_speed`) to the `Peer` struct alongside the existing byte counters (`bytes_downloaded_from`, `bytes_uploaded_to`).
- Extended `updateSpeedCounters()` in `peer_policy.zig` to compute per-peer speeds using the same 2-second rolling window used for torrent-level speeds.
- The `torrentPeers` API endpoint (`/api/v2/sync/torrentPeers`) now returns real `dl_speed` and `up_speed` values instead of hardcoded zeros.

### 2. Client name identification from peer ID
- Added `remote_peer_id` and `has_peer_id` fields to the `Peer` struct.
- Store the remote peer's 20-byte peer ID from the handshake buffer (`handshake_buf[48..68]`) immediately after handshake validation, in all four handshake paths: TCP outbound, TCP inbound, uTP outbound, uTP inbound.
- Created `src/net/peer_id.zig` with `peerIdToClientName()` that parses three peer ID encoding conventions:
  - **Azureus-style** (`-XX1234-`): covers qBittorrent, Transmission, Deluge, libtorrent, Vuze, Varuna, and 40+ other clients.
  - **Shadow-style** (`X12345-`): covers BitTornado, ABC, etc.
  - **Mainline** (`M1-2-3--`): covers official BitTorrent mainline client.
  - Falls back to `Unknown (<hex>)` for unrecognized formats.
- Version formatting trims trailing `.0` components (e.g., `-qB4610-` becomes "qBittorrent 4.6.1", not "4.6.1.0").
- Wired into `SessionManager.getTorrentPeers()` to resolve client names at query time.

## Key code locations
- `src/io/event_loop.zig:101-145` -- Peer struct with new fields
- `src/io/peer_policy.zig:608-670` -- updateSpeedCounters (per-peer + per-torrent)
- `src/net/peer_id.zig` -- client name parser (full module)
- `src/io/peer_handler.zig:370-371,448-449` -- TCP handshake peer ID extraction
- `src/io/utp_handler.zig:394-395,450-451` -- uTP handshake peer ID extraction
- `src/daemon/session_manager.zig:1058-1063` -- API integration

## What was learned
- The BitTorrent peer ID is at bytes 48-67 of the 68-byte handshake. It must be extracted *after* MSE decryption (the handshake buffer is already decrypted in-place by the time the handshake_recv handler runs).
- The Azureus-style format is by far the most common in modern clients. Shadow-style is mostly historical. Mainline-style is rare but still exists.
- Per-peer speed tracking reuses the same rolling window approach as torrent-level tracking -- cheap to add since it piggybacks on the existing 2-second tick.

## Tests
- 10 new tests in `src/net/peer_id.zig` covering Azureus-style (qBittorrent, Transmission, Deluge, libtorrent, Varuna, Vuze, all-zeros version), Shadow-style, Mainline, unknown, and all-zero peer IDs.
- All existing tests continue to pass.

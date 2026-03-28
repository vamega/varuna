# Connection Limits & Announce Staggering

## What was done

Added connection limiting and announce staggering to prevent thundering herd
problems when the daemon manages many torrents simultaneously.

### Connection limits (3 tiers)

1. **Global connection limit** (`max_connections: u32 = 500`): caps total peers
   across all torrents. Enforced in both `addPeerForTorrent()` (outbound) and
   `handleAccept()` (inbound). Matches qBittorrent's default of 500.

2. **Per-torrent connection limit** (`max_peers_per_torrent: u32 = 100`):
   prevents one torrent from monopolizing all connections. Uses the existing
   `peerCountForTorrent()` method. Matches qBittorrent default of 100.

3. **Half-open connection limit** (`max_half_open: u32 = 50`): prevents SYN
   queue exhaustion. Tracks peers in `.connecting` state via a counter
   incremented in `addPeerForTorrent` and decremented in `handleConnect`
   (success or failure) and `removePeer` (if still connecting).

### Socket exhaustion protection

- `addPeerForTorrent` checks `peer_count < max_connections` before creating a
  socket.
- Logs a warning when >90% of global limit is reached.
- Main daemon loop skips `integrateIntoEventLoop` when at connection limit.
- `handleAccept` closes inbound sockets immediately when at limit.

### Announce staggering / jitter

- `checkReannounce` applies ±10% random jitter to the announce interval,
  regenerated each cycle via a simple LCG PRNG seeded from timestamp.
- `TorrentSession.doStart()` adds an initial random delay (0 to 5 seconds,
  deterministic from info_hash) before the first announce, so torrents added
  in a batch don't all hit the tracker simultaneously.

## Design notes

- qBittorrent uses global (500) + per-torrent (100) limits.
  Transmission uses global + per-torrent (60). We chose qBittorrent-aligned
  defaults since the API is qBittorrent-compatible.
- Half-open limit of 50 is conservative; most Linux systems default to
  `net.ipv4.tcp_max_syn_backlog = 128` so 50 is safe.
- The announce jitter uses a timestamp-based LCG rather than a proper PRNG
  since it only needs to be "different enough" between ticks, not
  cryptographically random.
- Initial announce delay is deterministic from info_hash bytes so it's
  reproducible across restarts while still spreading load.

## Key files changed

- `src/config.zig:20-30` -- new Network config fields
- `src/io/event_loop.zig:497-560` -- addPeerForTorrent with limit checks
- `src/io/event_loop.zig:756-810` -- handleAccept with global limit check
- `src/io/event_loop.zig:1185-1260` -- checkReannounce with jitter
- `src/io/event_loop.zig:546-558` -- removePeer half-open tracking
- `src/daemon/torrent_session.zig:406-425` -- initial announce delay
- `src/main.zig:69-74` -- pass connection limits to event loop

## Remaining work

- Expose connection limits via the qBittorrent-compatible API
  (`/api/v2/app/preferences` and `/api/v2/app/setPreferences`).
- Per-torrent announce jitter in the shared event loop (currently only
  torrent 0 uses checkReannounce; daemon mode re-announces from sessions).
- Connection limit stats in the API (current/max connections).

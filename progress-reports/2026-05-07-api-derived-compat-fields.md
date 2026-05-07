# API Derived Compatibility Fields

## What Changed

- Implemented qBittorrent-style derived API fields for torrent properties and
  sync output: `total_wasted`, `dl_speed_avg`, `up_speed_avg`,
  `total_peer_connections`, `availability`, and `popularity`.
- Persisted `total_wasted` alongside lifetime upload/download counters so hash
  failures survive daemon restart.
- Left `free_space_on_disk` as a temporary 100 GiB compatibility placeholder and
  documented the future qBittorrent-inspired cached refresh design.
- Marked alternate speed-limit mode, RSS endpoints, search endpoints, and
  torrent file/folder renames as intentionally unsupported.

## What Was Learned

- qBittorrent's `availability` maps closely to libtorrent's distributed copies:
  the integer part is the minimum peer availability for any piece and the
  fractional part is the share of pieces above that minimum.
- qBittorrent's free-space path is not a constantly running timer. The useful
  design to copy later is a cached value with expiry, refreshed by a background
  operation only when WebAPI access observes stale data.
- `total_peer_connections` can be exposed cheaply from the shared event loop's
  tracked peer count.

## Remaining Issues

- `free_space_on_disk` is still not a real filesystem query. A real
  implementation should follow qBittorrent PR #8217, submit the blocking statfs
  work through Varuna's blocking-operation pool, and debounce concurrent WebAPI
  requests so only one stale-value refresh is in flight.
- Average speeds and popularity currently use Varuna's available lifetime/active
  time counters. They are qBittorrent-compatible in shape but may not exactly
  match qBittorrent's paused-time accounting until Varuna tracks active time
  more precisely.

## References

- `src/io/peer_policy.zig:1452` - counts failed hash buffers as wasted bytes.
- `src/torrent/piece_tracker.zig:515` - distributed availability calculation.
- `src/daemon/torrent_session.zig:1225` - lifetime transfer and popularity stats.
- `src/daemon/session_manager.zig:709` - total peer connections from event loop.
- `src/rpc/handlers.zig:1057` - average speed fields in properties response.
- `src/rpc/handlers.zig:2077` - unsupported alternate speed-limit mode response.
- `src/rpc/sync.zig:6` - free-space placeholder comment referencing PR #8217.
- `src/rpc/sync.zig:172` - server-state free-space and peer-count fields.
- `src/storage/state_db.zig:41` - persisted transfer stats include wasted bytes.
- `docs/api-compatibility.md:149` - placeholder and unsupported API policy.

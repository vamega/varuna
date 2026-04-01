# 2026-04-01: Cache Live `/sync` Hot Stats In The Event Loop

What was done:
- Added a live synthetic benchmark, `sync_stats_live`, that models the daemon case: a `SessionManager` backed by a shared `EventLoop`, `10,000` torrents, and sparse active peers.
- Cached cumulative download and upload byte totals in `TorrentContext`, then made `getSpeedStats()` and `updateSpeedCounters()` read those cached totals instead of summing every attached peer on demand.
- Wired the counters through the actual payload paths so the cache stays coherent when blocks are received or served.

What was learned:
- The remaining hot part of `/sync` after the sparse-registry pass was not category/tag JSON or queue-position lookup. It was repeated byte aggregation in `getSpeedStats()` and `updateSpeedCounters()`.
- A narrow cache is enough to get a large win here. This did not require a full new hot-summary registry layer.
- The cached totals also improve semantics: torrent totals now remain cumulative across peer disconnects instead of being derived only from the currently attached peer set.

Measured effect:
- `sync_stats_live --iterations=1 --torrents=10000 --peers=1000 --scale=20`
- Before: `19,509,532 ns`
- After: `4,886,050 ns`
- Repeat after: `4,046,868 ns`
- `sync_delta --iterations=200 --torrents=10000`
- Before: `32,633,001,590 ns`
- After: `31,930,370,231 ns`

Remaining issues:
- `/sync/maindata` still allocates and hashes heavily. This pass removed the hottest live stats scan, but a denser hot-summary registry is still the next step if polling dominates at `10k+` torrents.
- Seed plaintext scatter/gather and uTP outbound queueing are still separate experiments. They now have benchmark surfaces but no landed production changes in this pass.

Code references:
- `src/io/event_loop.zig:212`
- `src/io/event_loop.zig:830`
- `src/io/peer_policy.zig:730`
- `src/io/protocol.zig:112`
- `src/io/seed_handler.zig:263`
- `src/perf/workloads.zig:1366`

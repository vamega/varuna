# Startup Performance Considerations

## Why Torrent Clients Start Slowly
Torrent clients often start slowly because they need to rebuild large amounts of runtime state from disk. The common causes are:

- Loading and parsing session state for many torrents.
- Rebuilding views, indexes, filters, and scheduler queues.
- Rechecking files when resume state is missing, stale, or not trusted.
- Performing per-torrent startup work that should have been batched.
- Blocking on non-critical initialization before the daemon becomes usable.

For a client targeting `100k` torrents, bad asymptotic behavior at startup matters more than small constant-factor wins.

## rTorrent Evidence
rTorrent has had recent work specifically targeting slow startup for large session loads. A July 19, 2025 draft PR, `Optimize load_session_torrents code path`, reported startup improvements from about `24.1s` to `1.57s` at `10,000` torrents and from about `301.6s` to `4.79s` at `30,000` torrents.

The changes discussed there focused on removing avoidable startup overhead:

- Defer hashing-view initialization to avoid `O(n²)` work during bulk session loading.
- Bypass scheduler queueing for session torrents during startup.
- Disable view sorting in daemon mode.
- Skip sorted insertion and repeated filter scans when bulk-loading torrents.
- Skip unnecessary verification for trusted session torrents.

Related rTorrent release work also moved session saving to a separate thread with parallel batch processing, reinforcing that session persistence and reconstruction are major performance concerns.

## Design Implications For Varuna
- Treat startup as a dedicated bulk-load path, not as repeated normal add-torrent logic.
- Keep resume state trustworthy enough to avoid full file verification after clean shutdown.
- Build indexes lazily or in batches when possible.
- Avoid server-side sorting unless the API explicitly requires it.
- Make the daemon available before every secondary structure is fully warmed.
- Measure startup using realistic torrent counts and persist the benchmark results.

## Sources
- rTorrent PR `#1546`: <https://github.com/rakshasa/rtorrent/pull/1546>
- rTorrent releases: <https://github.com/rakshasa/rtorrent/releases>
- libtorrent resume data reference: <https://www.libtorrent.org/manual-ref.html>
- libtorrent single-page reference: <https://www.libtorrent.org/single-page-ref.html>

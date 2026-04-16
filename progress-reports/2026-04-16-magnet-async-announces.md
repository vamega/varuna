# Migrate collectMagnetPeers to Ring-Based Executors

**Date:** 2026-04-16

## What Changed

Removed the last blocking I/O code path in the daemon: `collectMagnetPeers`.

Previously, magnet link tracker announces ran on the `startWorker` background
thread using the blocking `HttpClient` and `tracker/udp.zig` functions. This
violated the io_uring policy and could block the thread for up to 4 minutes
(UDP timeout retries × multiple trackers).

Now magnet link announces go through the same ring-based `TrackerExecutor` and
`UdpTrackerExecutor` used by non-magnet torrents. Zero blocking network I/O.

## Design

1. `doStartBackground` for magnets: just sets state + signals done (no I/O)
2. `integrateIntoEventLoop` sees `metadata_fetching` with no `pending_peers`:
   submits async tracker jobs via `submitMagnetAnnounces`
3. New callbacks (`magnetHttpAnnounceComplete`, `magnetUdpAnnounceComplete`)
   accumulate peers from each tracker response
4. When all jobs complete (`finishMagnetAnnounceJob`), signals `background_init_done`
5. Next tick: `integrateIntoEventLoop` sees `metadata_fetching` with `pending_peers`,
   starts `AsyncMetadataFetch`

## Key Code References

- `src/daemon/torrent_session.zig:submitMagnetAnnounces` — job submission
- `src/daemon/torrent_session.zig:magnetHttpAnnounceComplete` — HTTP callback
- `src/daemon/torrent_session.zig:magnetUdpAnnounceComplete` — UDP callback
- `src/daemon/torrent_session.zig:accumulateMagnetPeers` — thread-safe peer accumulation
- `src/daemon/torrent_session.zig:finishMagnetAnnounceJob` — triggers metadata fetch

## What Was Removed

- `collectMagnetPeers` — the blocking function that did `fetchAuto` in a loop
- No longer imports or calls `tracker.announce.fetchAuto` from daemon code
- The old blocking `HttpClient` (`io/http.zig`) and `tracker/udp.zig:fetchViaUdp`
  are no longer called from any daemon path (only by `varuna-ctl` and tests)

## Impact

Every daemon I/O path now goes through io_uring or an allowed exception
(SQLite, hasher thread pool, DNS threadpool, eventfd notifications).

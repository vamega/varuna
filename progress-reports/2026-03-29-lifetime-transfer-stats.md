# Persist lifetime transfer stats to SQLite resume DB

## What was done

Added persistence for `total_uploaded` and `total_downloaded` byte counters so that share ratio survives daemon restarts.

Previously, `Stats.bytes_downloaded` and `Stats.bytes_uploaded` were computed purely from per-peer counters in the event loop. When the daemon restarted, these reset to zero, losing all historical transfer data.

## Design

- New `transfer_stats` table in the SQLite resume DB keyed by `info_hash`, with `total_uploaded` and `total_downloaded` INTEGER columns.
- On startup (`doStart`), the persisted totals are loaded into `baseline_uploaded` / `baseline_downloaded` fields on `TorrentSession`.
- On every resume flush (~5s periodic, plus pause/stop/completion transitions), `flushResume` writes `baseline + current_session_totals` to the DB via `INSERT ... ON CONFLICT DO UPDATE`.
- `getStats()` reports lifetime totals (`baseline + session`) for `bytes_downloaded`, `bytes_uploaded`, and uses those for share ratio computation.

This approach avoids double-counting: the baseline captures all previous sessions, and the current session's peer counters capture the running session. On next restart, the DB value becomes the new baseline.

## Key changes

- `src/storage/resume.zig`: `TransferStats` struct, `transfer_stats` table creation, `saveTransferStats`/`loadTransferStats` on `ResumeDb`, and corresponding thread-safe wrappers on `ResumeWriter`. Three new tests.
- `src/daemon/torrent_session.zig`: `baseline_uploaded`/`baseline_downloaded` fields, load in `doStart`, save in `flushResume`, add to `getStats` totals and ratio.

## Testing

- Three new unit tests for the resume DB: save/load round-trip, upsert behavior, per-torrent isolation.
- `zig build` and `zig build test` pass cleanly.

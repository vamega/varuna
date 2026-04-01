# Torrent Queueing Implementation

**Date:** 2026-03-31

## What was done

Implemented torrent queueing -- controlling how many torrents are actively downloading/uploading simultaneously with automatic queue management.

### New files
- `src/daemon/queue_manager.zig` -- queue ordering, enforcement logic, persistence adapter

### Modified files
- `src/config.zig` -- added `queueing_enabled`, `max_active_downloads`, `max_active_uploads`, `max_active_torrents` to `[daemon]` config section
- `src/daemon/torrent_session.zig` -- added `queued` state to `State` enum, `queue_position` to `Stats` struct
- `src/daemon/session_manager.zig` -- integrated `QueueManager`, queue enforcement on add/remove/pause, priority endpoints
- `src/daemon/root.zig` -- exported `queue_manager` module
- `src/rpc/handlers.zig` -- `increasePrio`, `decreasePrio`, `topPrio`, `bottomPrio` API endpoints; wired preferences to real queue config; `extractJsonBool` helper
- `src/rpc/compat.zig` -- `queued` state maps to `queuedDL`/`queuedUP` (qBittorrent-compatible)
- `src/rpc/sync.zig` -- real `priority` field from queue position
- `src/storage/resume.zig` -- `queue_positions` table, `saveQueuePosition`/`loadQueuePositions`/`clearQueuePositions`/`removeQueuePosition` methods
- `src/main.zig` -- apply queue config from TOML, periodic queue enforcement every ~5s
- `src/ctl/main.zig` -- `queue-top`, `queue-bottom`, `queue-up`, `queue-down` commands

### Features
1. **Configurable limits:** `max_active_downloads` (default 5), `max_active_uploads` (default 5), `max_active_torrents` (default -1 = unlimited). Disabled by default (`queueing_enabled = false`).
2. **Queue states:** `queued` state alongside existing `downloading`/`seeding`/`paused` etc. Paused torrents remain paused (don't auto-resume).
3. **Queue ordering:** 1-based positions, new torrents added to bottom. Priority reordering via API and CLI.
4. **Auto-management:** When active torrents complete/pause/are removed, next queued torrent starts. Periodic enforcement every ~5s catches download->seed transitions.
5. **Preferences API:** `queueing_enabled`, `max_active_downloads`, `max_active_uploads`, `max_active_torrents` readable and writable via `/api/v2/app/preferences` and `/api/v2/app/setPreferences`.
6. **Persistence:** Queue positions saved to SQLite `queue_positions` table. Restored on daemon restart.

## Design decisions

- **QueueManager is a separate module** from SessionManager. SessionManager holds the QueueManager and calls into it while holding its mutex. QueueManager has no locks of its own.
- **EnforcementResult** uses a fixed-size array (32 entries) to avoid heap allocation in the enforcement path. 32 torrents starting at once is a generous upper bound.
- **isDownloading() uses state** rather than piece counts because the PieceTracker.completedCount() method requires a mutable pointer, and queue enforcement works with const session references. The state accurately reflects download vs seed status.
- **Disabled by default** (`queueing_enabled = false`) so existing users are unaffected. When disabled, all torrents start immediately as before.
- **Queue enforcement runs periodically** (every ~5s in the main loop tick) rather than only on state-change events, to catch async transitions like download-to-seed that happen inside the event loop.

## Tests

10 queue manager unit tests covering all ordering operations and boundary conditions. 1 compat test for `queued` state string mapping. All existing tests continue to pass.

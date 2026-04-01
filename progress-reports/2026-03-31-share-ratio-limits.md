# Share Ratio Limits

## What was done

Implemented automatic pause/remove of torrents when they reach a target upload/download ratio or seeding time limit, matching qBittorrent's share ratio limit behavior.

### Features

1. **Global limits** (TOML config under `[daemon]`):
   - `max_ratio_enabled` / `max_ratio` -- target ratio (e.g. 2.0 means upload 2x download)
   - `max_seeding_time_enabled` / `max_seeding_time` -- max minutes to seed after completion
   - `max_ratio_act` -- action when reached: 0 = pause, 1 = remove (qBittorrent convention)

2. **Per-torrent overrides** (`setShareLimits` API endpoint):
   - `ratioLimit`: -2 = use global, -1 = no limit, >=0 = specific ratio
   - `seedingTimeLimit`: -2 = use global, -1 = no limit, >=0 = minutes
   - Per-torrent limits persisted to SQLite `share_limits` table

3. **Enforcement** (main loop, every ~30 seconds):
   - Only applies to torrents in seeding state
   - Per-torrent override takes priority over global setting
   - Pause or remove based on `max_ratio_act`
   - Logged via `std.log.info` when action taken

4. **Completion timestamp tracking**:
   - `completion_on` field on TorrentSession, set when transitioning to seeding
   - Persisted to SQLite, loaded on restart
   - Used for accurate seeding time calculation

5. **API integration** (qBittorrent-compatible):
   - Preferences GET: `max_ratio_enabled`, `max_ratio`, `max_ratio_act`, `max_seeding_time_enabled`, `max_seeding_time` now return real values
   - Preferences SET: all five fields settable via form or JSON body
   - Torrent info: `ratio_limit`, `seeding_time_limit`, `seeding_time` return real values
   - Torrent properties: includes `ratio_limit`, `seeding_time_limit`, accurate `seeding_time`, `completion_date`
   - Sync maindata: same real values
   - `setShareLimits` endpoint: pipe-separated hashes, per-torrent overrides

### Key design decisions

- Enforcement runs outside the mutex lock (collect hashes under lock, then act) to avoid deadlock with pauseTorrent/removeTorrent which also take the mutex.
- Max 64 torrents can be acted upon per check cycle (static buffer avoids allocation).
- `completion_on` is set at every seeding transition point (getStats auto-transition, checkSeedTransition, background recheck completion) to ensure it's always captured.
- Per-torrent `ratio_limit = -2` means "use global" (not -1, which means "no limit").

## Code references

- `src/config.zig:11-21` -- Daemon config fields
- `src/daemon/torrent_session.zig:155-165` -- Per-torrent share limit fields and completion_on
- `src/daemon/torrent_session.zig:29-36` -- Stats struct additions (ratio_limit, seeding_time_limit, completion_on, seeding_time)
- `src/daemon/session_manager.zig:773-870` -- setShareLimits, checkShareLimits, checkTorrentShareLimit, persistCompletionOn
- `src/storage/resume.zig:623-670` -- share_limits table, save/load/clear methods
- `src/storage/sqlite3.zig:54-55,59` -- sqlite3_bind_double, sqlite3_column_double bindings
- `src/rpc/handlers.zig:508-509` -- Real preferences values
- `src/rpc/handlers.zig:969-991` -- setShareLimits endpoint handler
- `src/main.zig:97-101` -- Config wiring
- `src/main.zig:250-252` -- Periodic enforcement check

## Tests

- 4 share limit enforcement tests (ratio, seeding time, per-torrent override, disabled default)
- 1 resume DB share limits persistence test
- 1 config defaults test
- 2 JSON helper tests (extractJsonBool, extractJsonFloat)

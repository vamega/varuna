# 2026-04-09: Daemon Queue And Relocation Cleanup

## What was done and why

Finished the operational cleanup wave around queue enforcement, runtime DHT toggles, and `setLocation()`.

- `src/daemon/session_manager.zig:112` now toggles `engine.enabled` on the existing DHT engine instead of nulling out the event-loop pointer. This makes disable/enable symmetric for engines that were created at startup.
- `src/daemon/session_manager.zig:764` now enforces queue limits in both directions: over-limit active torrents are paused and moved to `.queued`, while queued torrents that fit within the computed limits are resumed in priority order.
- `src/daemon/session_manager.zig:892` adds a relocation guard so `setLocation()` can release the global mutex before the filesystem move without racing a concurrent remove.
- `src/daemon/session_manager.zig:905` moves the actual file relocation outside the mutex, then reacquires the lock only to update `save_path` and resume the session.

## What was learned

- Queueing correctness is two-sided. Promotion-only enforcement works until preferences tighten at runtime; after that, the daemon needs an explicit demotion path or it drifts out of policy and never converges back.
- Releasing the mutex around long filesystem work is only safe once there is an explicit "this torrent is busy relocating" guard that destructive paths honor.

## Remaining issues / follow-up

- The relocation guard currently blocks concurrent removal; if later work needs finer-grained coordination, it should probably become an explicit per-session state instead of a side map.
- Re-enabling DHT still depends on an engine and UDP socket having been created at startup. If startup disabled DHT entirely, runtime enable remains a no-op by design.

## Code references

- `src/daemon/session_manager.zig:112`
- `src/daemon/session_manager.zig:231`
- `src/daemon/session_manager.zig:764`
- `src/daemon/session_manager.zig:892`

# Real Torrent Parity Shutdown

## What changed and why

Ran the real-torrent parity harness after the backend blocking-syscall cleanup. The first three-torrent run confirmed Varuna could still download real torrents, but exposed a shutdown hang after the Varuna `utp_only` leg. The process had stopped the event loop and then waited for background tracker jobs that could no longer complete.

Stopped announces now use fire-and-forget callbacks that do not touch normal announce accounting, so a shutdown announce cannot corrupt `announcing` or `announce_jobs_in_flight` while a regular announce is in flight. During process shutdown only, `SessionManager.deinit` abandons sessions that still have tracker jobs in flight and leaks tracker executors so late callback contexts are not freed during teardown.

## What was learned

The full three-torrent parity run hit public-swarm variability and then disk pressure, but the clean follow-up Proxmox-only matrix completed both clients and both transports:

- Varuna `tcp_and_utp`: complete in 23.341s, 60.472 MiB/s
- qBittorrent `tcp_and_utp`: complete in 37.441s, 37.952 MiB/s
- Varuna `utp_only`: complete in 153.699s, 9.183 MiB/s
- qBittorrent `utp_only`: complete in 165.846s, 8.547 MiB/s

This keeps the architecture unchanged: the daemon still relies on the IO backend for networking/file IO, with unsupported blocking syscalls handled by the backend blocking-op pool work from the prior change.

## Remaining issues

`zig build test-event-loop` passes. `zig build test-torrent-session` still fails in `tests/torrent_session_test.zig` on `addPeersToEventLoop honors uTP-only transport for tracker peers` with `NoTrackers`; that looks separate from the shutdown hang and should be fixed independently.

The full three-torrent matrix needs enough scratch space for all client outputs. Generated parity outputs were cleaned except the final Proxmox result under `perf/output/real-torrent-parity-1778123243`.

## Key references

- `src/daemon/torrent_session.zig:464` - shutdown-only background network job check
- `src/daemon/torrent_session.zig:1617` - stopped announce path separated from normal announce accounting
- `src/daemon/torrent_session.zig:1755` - no-op stopped announce callback
- `src/daemon/session_manager.zig:180` - process-shutdown abandonment of sessions with in-flight tracker jobs
- `src/daemon/session_manager.zig:236` - shutdown-only tracker executor leak to preserve callback contexts

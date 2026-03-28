# Daemon: seed after download completes

## What was done

Implemented daemon seed mode so that when a torrent finishes downloading (or rechecks as 100% complete), the daemon:

1. **Announces to the tracker as a seeder** (`event=completed`, `left=0`) on a background thread so the blocking HTTP call doesn't stall the io_uring event loop.

2. **Creates a shared listen socket** bound to `0.0.0.0:port` for accepting inbound peer connections. The listen socket is created once (on the main thread) and shared across all seeding torrents.

3. **Registers complete_pieces on the per-torrent context** so inbound peers receive the correct bitfield and piece requests are validated against the right torrent.

4. **Routes inbound peers to the correct torrent** by matching the info_hash from the peer's handshake against all registered torrent contexts (previously hardcoded to torrent_id=0).

## Key changes

- `src/daemon/torrent_session.zig`: Added `pending_seed_setup` flag, `announce_thread` for background completed announce, `integrateSeedIntoEventLoop()` for main-thread seed setup, and `checkSeedTransition()` for detecting download completion.

- `src/io/event_loop.zig`: Added `findTorrentByInfoHash()`, `setTorrentCompletePieces()`, and `ensureAccepting()`. Modified `inbound_handshake_recv` to match info_hash against all torrents. Modified `inbound_handshake_send` and `servePieceRequest` to use per-torrent `complete_pieces` (with fallback to global for backward compatibility).

- `src/main.zig`: Added main-loop logic to detect `pending_seed_setup` on sessions, create the listen socket once, and call `ensureAccepting()`. Also ticks the event loop when accepting (even with zero peers) so accept CQEs are processed.

## Design decisions

- **Thread safety**: The listen socket is created on the main thread (not the background worker) because `EventLoop` is not thread-safe. The background worker sets `pending_seed_setup = true` and the main loop picks it up.

- **Background announce**: The `event=completed` tracker announce uses a separate background thread with its own `Ring` instance since the HTTP client needs a ring for io_uring HTTP and the announce is blocking.

- **Shared listen socket**: Only one listen socket is created regardless of how many torrents complete. Inbound peers are routed to the correct torrent via info_hash matching in the handshake.

- **Two entry paths**: Seed mode is triggered both when recheck shows 100% complete (startup with existing data) and when download finishes (transition from downloading state).

## Follow-up work

- The `getStats()` auto-transition from downloading to seeding (line ~208) is now complemented by `checkSeedTransition()` which also triggers the announce and listen setup. The `getStats()` path still works for UI display but doesn't trigger the full seed setup.
- Per-torrent piece caching in seed mode (currently the cache is shared across all torrents).

# Shared Event Loop Lifetime And Seed Read Fixes -- 2026-03-30

## What was done

Fixed the main correctness issues from the latest review pass:

- Detached torrents from the shared `EventLoop` before freeing `session`,
  `piece_tracker`, and shared file descriptors, so pause/remove/recheck no
  longer leave the daemon I/O loop holding freed pointers.
- Preserved shared-loop integration on resume by restarting paused torrents via
  `startWithEventLoop(self.shared_event_loop)` instead of standalone `start()`.
- Made session teardown wait for both announce and scrape workers, and
  serialized announce/scrape access to the shared announce ring with a mutex.
- Reworked the seed read path so concurrent same-piece requests are keyed by a
  unique `read_id`, and queued seed responses now own exact block copies
  instead of depending on the global piece cache at flush time.
- Fixed RPC `files`, `trackers`, and `properties` handlers to use copied
  `SessionManager` accessors instead of raw `*TorrentSession` pointers.
- Fixed API server send handling so short sends resume from `send_offset`
  instead of truncating the HTTP response.
- Changed disk write accounting so only successfully submitted reads/writes are
  counted as pending; failed submissions now mark the write as failed or drop
  the request immediately instead of wedging forever.

## What was learned

- In daemon mode the shared event loop is effectively another owner of torrent
  runtime state. Stopping a torrent is not just “join background threads and
  free memory”; the event-loop context must be detached first or later CQEs and
  stats paths will read freed pointers.
- The seed batching bug was not just a cache problem. Once batching happens
  after CQE dispatch, any queue entry that does not own its own block bytes is
  vulnerable to later cache replacement.
- For `io_uring` multi-span work, `spans_remaining = plan.spans.len` is only
  correct if every SQE submission succeeds. In practice the counter has to be
  derived from actual successful submissions, and the completion path needs a
  way to distinguish “all writes finished” from “some writes never got
  submitted”.

## Remaining issues / follow-up

- The review’s performance and data-oriented-design follow-ups are still open:
  hot-path peer layout, send-buffer bookkeeping, hasher queue structure, and
  tracker DNS/thread-per-lookup behavior were not changed in this pass.

## Code references

- Shared-loop lifecycle and background worker teardown:
  `src/daemon/torrent_session.zig:171`, `src/daemon/torrent_session.zig:208`,
  `src/daemon/torrent_session.zig:227`, `src/daemon/torrent_session.zig:236`,
  `src/daemon/torrent_session.zig:856`, `src/daemon/torrent_session.zig:903`,
  `src/daemon/torrent_session.zig:989`
- Safe copied RPC accessors and handler migration:
  `src/daemon/session_manager.zig:388`, `src/daemon/session_manager.zig:464`,
  `src/daemon/session_manager.zig:527`, `src/rpc/handlers.zig:448`,
  `src/rpc/handlers.zig:480`, `src/rpc/handlers.zig:514`
- API partial-send handling:
  `src/rpc/server.zig:240`, `src/rpc/server.zig:276`, `src/rpc/server.zig:284`,
  `src/rpc/server.zig:441`
- Seed read IDs, queued block ownership, and request accounting:
  `src/io/event_loop.zig:204`, `src/io/event_loop.zig:217`,
  `src/io/event_loop.zig:283`, `src/io/seed_handler.zig:11`,
  `src/io/seed_handler.zig:40`, `src/io/seed_handler.zig:66`,
  `src/io/seed_handler.zig:142`, `src/io/seed_handler.zig:186`
- Write-submission accounting and completion handling:
  `src/io/peer_policy.zig:202`, `src/io/peer_policy.zig:309`,
  `src/io/peer_handler.zig:388`

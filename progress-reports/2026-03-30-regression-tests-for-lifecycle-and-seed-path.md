# Regression Tests For Lifecycle And Seed Path -- 2026-03-30

## What was done

Added deterministic regression tests for the bugfixes that can be expressed as
stable invariants rather than race timing:

- `TorrentSession.stop()` now has a regression test proving it detaches the
  torrent from the shared `EventLoop` and clears `torrent_id_in_shared`.
- `TorrentSession.resume_session()` now has a regression test proving daemon
  mode keeps the existing shared event loop instead of silently switching to
  standalone mode.
- `handleDiskWrite()` now has a regression test proving a write batch marked
  `write_failed` releases the piece back to the picker rather than leaving it
  stuck in-progress.

These complement the tests already added in the previous fix pass for:

- API partial-send progress in `src/rpc/server.zig`
- unique seed read IDs and exact block-copy batching in `src/io/seed_handler.zig`

## What was learned

- The lifecycle bugs are testable without forcing a real race if the test
  asserts ownership state directly: shared-loop slot cleared, torrent detached,
  and shared-loop pointer preserved across resume.
- The write-accounting bug is also testable without touching real disk I/O by
  constructing a pending write entry and driving `handleDiskWrite()` with a
  synthetic CQE.
- The concurrency bugs that remain hard to test are the ones that require
  interleaving detached background threads with teardown. Those are better
  covered by structural hardening plus integration/stress testing.

## Remaining issues / follow-up

- The announce/scrape teardown races are structurally fixed, but there is still
  no deterministic unit test for them because they depend on detached worker
  timing.
- The tracker DNS/thread-per-request behavior and the larger performance/DOD
  findings still need separate work.

## Code references

- Shared-loop lifecycle regression tests:
  `src/daemon/torrent_session.zig:1017`,
  `src/daemon/torrent_session.zig:1051`
- Failed-write release regression test:
  `src/io/peer_handler.zig:408`
- Existing deterministic bugfix tests reinforced by this pass:
  `src/rpc/server.zig:574`,
  `src/io/seed_handler.zig:326`,
  `src/io/seed_handler.zig:335`

## What Was Done

- Replaced the event loop's single global announce mailbox with a per-torrent announce-result queue so tracker callbacks can no longer attach discovered peers to torrent `0` by accident. The queue now stores `{ torrent_id, peers }` entries and `checkReannounce()` drains them onto the matching torrent context. Key changes are in `src/io/event_loop.zig` and `src/io/peer_policy.zig`.
- Changed background completed-announce, reannounce, and scrape scheduling to fan out over the full effective tracker set returned by `buildTrackerUrls()` instead of only using the metainfo primary tracker. This brings background behavior back in line with tracker overrides and announce-list semantics in `src/daemon/torrent_session.zig`.
- Added per-operation in-flight counters for background announce and scrape work so multi-tracker fan-out does not clear the `announcing` / `scraping` flags on the first callback.
- Added a coarse `TorrentSession` mutex and used it around `getStats()`, worker-thread startup, and tracker callback state updates to reduce the startup/read race that previously let RPC readers observe mutable fields while the worker thread was still reshaping session state.
- Added focused regression tests for the per-torrent announce queue and effective tracker URL construction.

## What Was Learned

- The wrong-torrent peer-attachment bug was split across two innocent-looking pieces: the daemon callbacks lost torrent identity, and the event loop intake path hardcoded torrent `0`. Fixing only one side would have left a latent trap.
- Tracker override support was already implemented in `buildTrackerUrls()`, but the background reannounce/scrape path had drifted away from it. Reusing the existing helper was safer than inventing another tracker selection path.
- Multi-tracker background work needs explicit in-flight accounting. A single boolean is enough for one request, but it is the wrong primitive once one user action fans out into N callbacks.
- A coarse session mutex is not the long-term ownership model for `TorrentSession`, but it is a pragmatic way to stop unsynchronized worker-thread mutations from racing with stats reads without redesigning the subsystem mid-wave.

## Remaining Issues / Follow-Up

- The `TorrentSession` mutex is intentionally coarse. It removes the immediate stats/startup race, but a cleaner ownership split between worker-thread state, main-thread state, and callback-updated state is still worth doing in a later wave.
- Background scrape now fans out across effective tracker URLs, but the current aggregation policy is still "latest successful scrape wins". If clients need tier-aware scrape merging, that should be specified explicitly.
- Full verification is still blocked by the local Zig toolchain/cache failure (`manifest_create Unexpected`), so this change still needs a clean test run once the environment is healthy.

## Verification

- Added regression tests in `src/io/event_loop.zig` and `src/daemon/torrent_session.zig`.
- Ran `zig fmt src/io/event_loop.zig src/io/peer_policy.zig src/daemon/torrent_session.zig`
- Ran `zig build test` successfully. The suite emitted existing UDP tracker warning lines during test execution, but exited with code `0`.

## Key References

- `src/io/event_loop.zig`
- `src/io/peer_policy.zig`
- `src/daemon/torrent_session.zig`
- `STATUS.md`

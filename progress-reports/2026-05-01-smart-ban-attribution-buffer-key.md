# 2026-05-01 Smart-Ban Attribution Buffer Key

## What changed

- Fixed smart-ban attribution for overlapping hash jobs of the same torrent piece. `SmartBan.pending_attributions` is now keyed by `(torrent_id, piece_index, piece_buf.ptr)`, so a later re-download cannot overwrite the attribution snapshot for an older piece buffer that is still waiting on hasher results.
- Updated the event-loop completion path to pass the exact piece buffer into `snapshotAttribution`.
- Added a unit regression that queues failed and passing attribution snapshots for the same piece at the same time and verifies the failed buffer still bans the original corrupt peer.
- Fixed the multi-source sim assertion to snapshot per-peer contribution counters before teardown disconnects reset peer slots.

## What was learned

- The smart-ban Phase 2B failure was not stale socket data. The corrupt block was received from peer 0, but the failed hash result consumed a newer attribution snapshot from a later re-download because snapshots were keyed only by `(torrent_id, piece_index)`.
- The multi-source failure was test-observation timing: the evidence was valid during the run, then lost when `removePeer` reset the slots during drain.

## Remaining issues

- Smart-ban records are still keyed by `(torrent_id, piece_index, block_index)`, which is correct for comparing the most recent failed attempt against a later passing attempt. If future work allows multiple unresolved failed attempts for the same piece, that should be revisited with an explicit attempt id.
- Some full-suite tests remain intentionally verbose and skipped, but the full suite passed after this change.

## Code references

- `src/net/smart_ban.zig:71` - pending attribution map is now keyed by the piece buffer submitted to the hasher.
- `src/net/smart_ban.zig:100` - `snapshotAttribution` accepts the piece buffer and stores ownership against that exact attempt.
- `src/io/peer_policy.zig:709` - piece completion passes the buffer used for the hash job into smart-ban attribution.
- `src/net/smart_ban.zig:437` - regression test for overlapping same-piece hash jobs.
- `tests/sim_multi_source_eventloop_test.zig:275` - contribution counters are captured before teardown resets peer slots.

## Verification

- `zig build test-sim-smart-ban-phase12`
- `zig build test-sim-multi-source-eventloop`
- `zig build test`

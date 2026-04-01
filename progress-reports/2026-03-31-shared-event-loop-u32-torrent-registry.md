## What Was Done

- Removed the shared `EventLoop` hard cap of 64 active torrents by replacing the fixed `[64]?TorrentContext` table with a dynamic slot array, a free-list, and stable `u32` torrent IDs.
- Added hashed info-hash lookup for inbound TCP handshake routing, inbound uTP handshake routing, DHT peer-result routing, and MSE responder completion.
- Reworked disk-write CQE correlation to use dedicated write IDs instead of packing `torrent_id` into the 40-bit `user_data.context`.
- Updated shared-loop torrent IDs in `TorrentSession`, `SessionManager`, the hasher job/result types, and peer state to use `u32`.
- Added a regression test that inserts `20,000` torrent contexts, validates hashed lookup, removes one slot, and confirms slot reuse.
- Reduced idle-seeding overhead by avoiding eager per-torrent PEX-state allocation and skipping speed-counter work when there are no connected peers.

## What Was Learned

- The 64-torrent limit was not isolated to one constant. It was reinforced by four separate assumptions:
  - fixed torrent storage in `EventLoop`
  - `u8` torrent IDs threaded through peer/uTP/hasher/session state
  - linear info-hash scans on inbound connection paths
  - CQE context packing that implicitly depended on narrow torrent IDs
- The CQE packing issue is the real reason a simple `u8 -> u32` type change was unsafe. Moving to write IDs made the rest of the widening straightforward.
- Inbound MSE responder setup had an unadvertised second cap: it copied known info-hashes into a fixed `[64][20]u8` stack buffer. That needed to become dynamic as well.
- For the target workload of many idle seeding torrents, the registry size is only part of the problem. Background per-torrent work like eager PEX allocation matters because it scales with loaded torrents even when peer count is zero.

## Remaining Issues / Follow-Up

- Partial-seed detection still scans active torrents periodically. That path is now functionally correct at high torrent counts, but it may still need a slower cadence or an event-driven summary if deployments keep tens of thousands of torrents loaded continuously.
- `/sync` and other management paths still pull torrent state from `TorrentSession` objects rather than a denser hot summary registry. That is the next likely scale bottleneck after the EventLoop cap removal.
- I did not convert the peer table or torrent summaries to SoA in this pass; this change is about removing the active-torrent ceiling and fixing the routing/correlation paths around it.

## Key References

- `/home/vmadiath/projects/varuna-scale/src/io/event_loop.zig:31`
- `/home/vmadiath/projects/varuna-scale/src/io/event_loop.zig:352`
- `/home/vmadiath/projects/varuna-scale/src/io/event_loop.zig:697`
- `/home/vmadiath/projects/varuna-scale/src/io/event_loop.zig:1571`
- `/home/vmadiath/projects/varuna-scale/src/io/peer_handler.zig:430`
- `/home/vmadiath/projects/varuna-scale/src/io/peer_handler.zig:555`
- `/home/vmadiath/projects/varuna-scale/src/io/utp_handler.zig:424`
- `/home/vmadiath/projects/varuna-scale/src/io/dht_handler.zig:51`
- `/home/vmadiath/projects/varuna-scale/src/daemon/torrent_session.zig:185`

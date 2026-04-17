# Smart Ban Phase 1-2: Per-Block SHA-1 Attribution

**Date:** 2026-04-17

## What Changed

Implemented Phases 1-2 of the smart ban algorithm described in
`docs/future-features.md`. This builds on Phase 0 (trust points) committed
earlier in this session and unlocks fair peer banning in multi-source
downloads.

### New module: `src/net/smart_ban.zig`

- `SmartBan` struct with two hash maps:
  - `records: HashMap((torrent_id, piece_index, block_index) -> {peer_addr, digest})`
  - `pending_attributions: HashMap((torrent_id, piece_index) -> []?std.net.Address)`
- `snapshotAttribution(torrent_id, piece_index, block_peers)` — called at piece
  completion to remember which peer sent each block
- `onPieceFailed(tid, piece, buf, block_size)` — computes per-block SHA-1 for
  the failed buffer, stores records keyed by (tid, piece, block_index)
- `onPiecePassed(tid, piece, buf, block_size)` — compares per-block digests of
  the verified buffer against stored records; returns addresses of peers whose
  block hashes changed (they sent corrupt data in the failed download)
- `clearTorrent(tid)` — removes all records + attribution on torrent removal
- 5 unit tests covering: failed+passed round-trip, empty records, multi-torrent
  isolation, null-peer (web seed) skipping, snapshot replacement

### Integration: `src/io/peer_policy.zig`

- `completePieceDownload`: before destroying the `DownloadingPiece`, call
  `snapshotAttributionForSmartBan` to translate per-block `peer_slot` into
  `?std.net.Address` (web seed sentinels → null). The snapshot is stored in
  the smart ban map until the hash result arrives.
- `processHashResults` (valid path): call `sb.onPiecePassed` before writing
  to disk. If any peer's block hashes changed between the failed and passing
  downloads, ban them via `ban_list` and disconnect matching peer slots.
- `processHashResults` (invalid path): call `sb.onPieceFailed` before freeing
  the buffer to record per-block SHA-1 digests.
- `removeTorrent`: call `sb.clearTorrent(torrent_id)` to prevent record leaks.

### Ownership

- `SmartBan` is owned by `SessionManager` (heap-allocated), mirroring `BanList`.
- `EventLoop` holds a borrowed pointer (`smart_ban: ?*SmartBan`).
- `SessionManager.deinit` frees it after nulling the event loop reference.

### Why this works

libtorrent's smart ban requires reading blocks back from disk because the
piece cache may evict them before the callback fires. Varuna's situation is
simpler: the piece buffer is still in memory at `processHashResults` time
(the hasher owns it until the write CQE returns). We compute the per-block
SHA-1 directly from the in-memory buffer — no async disk reads needed.

For multi-source downloads, the per-block peer attribution is exactly what
the algorithm needs. A peer that sent a correct block in the failed download
(but another peer's corrupt block made the piece hash fail) will have
matching block hashes in the passing download and is **not** banned —
avoiding the false positives that simple trust-point banning would produce.

## Verification

- `zig build test` — all tests pass, including 5 new smart ban tests
- `./scripts/demo_swarm.sh` — passes with no regressions (MSE + uTP + smart ban)

## Key Code References

- `src/net/smart_ban.zig` — full implementation (~340 lines including tests)
- `src/io/peer_policy.zig:snapshotAttributionForSmartBan` — slot → address translation
- `src/io/peer_policy.zig:smartBanCorruptPeers` — ban list wiring
- `src/io/peer_policy.zig:processHashResults` — integration points
- `src/io/event_loop.zig:removeTorrent` — cleanup on torrent removal
- `src/daemon/session_manager.zig:initSmartBan` — ownership and lifecycle

## What's Still Pending

Phase 4 of multi-source piece assembly: the `BlockInfo.peer_slot` attribution
already exists in `downloading_piece.zig`, but during the transition from a
piece having been verified (passed) and re-downloaded the smart ban can only
distinguish peers that sent different data. If the same peer is consistently
sending bad blocks, the Phase 0 trust-point system (existing) still catches
them based on piece-level hashfails. The combined system provides both fair
per-block blame AND fast catching of consistently-bad peers.

Block-level endgame (Phase 3 of multi-source) and deeper smart ban integration
for edge cases remain as follow-up work.

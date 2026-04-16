# BEP 19 web seed piece downloads via HttpExecutor

## What changed

Implemented the web seed download orchestrator that connects the existing
`WebSeedManager` (URL management, piece-to-file range mapping, backoff)
to the generic `HttpExecutor` (async HTTP over io_uring), enabling
piece downloads from BEP 19 GetRight-style HTTP seeds.

### New file

- `src/io/web_seed_handler.zig` — Web seed download orchestrator. Manages
  up to 16 concurrent web seed download slots. Each tick, scans torrents
  for available web seeds and unclaimed pieces, submits HTTP Range requests
  through the HttpExecutor, and routes completed pieces through the
  standard hasher verification and disk write pipeline.

### Modified files

- `src/io/types.zig` — Added `web_seed_manager: ?*WebSeedManager` field
  to `TorrentContext` so each torrent can carry its web seed state.

- `src/io/event_loop.zig` — Added `web_seed_slots` array (16 slots) to
  `EventLoop`. Calls `tryAssignWebSeedPieces()` each tick after peer
  piece assignment. Cleans up web seed slot buffers and managers on deinit.

- `src/daemon/torrent_session.zig` — In `addPeersToEventLoop()`, creates
  a `WebSeedManager` when the torrent's metainfo has a non-empty `url_list`.
  Attaches it to the TorrentContext. Added `initWebSeedManager()` helper.

- `src/io/root.zig` — Exported the new `web_seed_handler` module.

## Design

The web seed handler reuses the existing piece lifecycle:

1. **Claim** — `PieceTracker.claimPiece(null)` (no bitfield filter since
   web seeds have all pieces)
2. **Assign** — `WebSeedManager.assignPiece()` picks an idle seed
3. **Download** — `computePieceRanges()` maps the piece to file byte ranges;
   for each range, `buildFileUrl()` + HTTP Range header are submitted as
   `HttpExecutor.Job` entries with `target_buf` pointing into the piece buffer
4. **Verify** — On range completion, submits to the background `Hasher`
   thread pool (or inline SHA-1 fallback)
5. **Write** — `processHashResults()` handles the disk write via io_uring,
   same as for peer-downloaded pieces

Key design decisions:
- One piece per torrent per tick to avoid starving peer downloads
- Multi-file pieces spanning files get one HTTP request per file range
- 404 responses permanently disable the seed; other errors use
  WebSeedManager's exponential backoff
- Heap-allocated `RangeContext` links HttpExecutor callbacks back to slots
- Sentinel peer slot values (`0xFFFF - slot_idx`) distinguish web seed
  hash results without needing a separate hash result path

## What was learned

- The HttpExecutor's `target_buf`/`target_offset` mechanism allows
  zero-copy body writes directly into the piece buffer, avoiding a
  memcpy after HTTP response completion.
- The hasher's `slot` field is only used for the `PendingWrite` tracking
  on the inline (no-hasher) path; the async hasher path uses `torrent_id`
  from the result to look up the torrent context, so any slot value works.

## Remaining issues / follow-up

- **Integration testing**: The handler needs end-to-end testing with a real
  HTTP server serving torrent data. Consider extending `demo_swarm.sh` to
  include a web seed (e.g., nginx or python HTTP server).
- **200 vs 206 handling**: A server may return 200 (full file) instead of
  206 (partial content) if the Range header is ignored. Currently both are
  accepted but the target_buf write assumes the server honored the range.
  This should be validated against `target_bytes_written`.
- **Concurrent pieces per seed**: Currently limited to one piece per seed
  at a time by the `assignPiece` mechanism. Could be extended for pipelining.
- **BEP 17 (Hoffman-style)**: Only BEP 19 (GetRight-style) is implemented.
  BEP 17 uses a different URL scheme with piece index parameters.

## Key code references

- `src/io/web_seed_handler.zig:50` — `tryAssignWebSeedPieces()`
- `src/io/web_seed_handler.zig:137` — `submitRangeRequest()`
- `src/io/web_seed_handler.zig:212` — `webSeedRangeComplete()` callback
- `src/io/web_seed_handler.zig:249` — `submitToHasher()`
- `src/daemon/torrent_session.zig:808` — `initWebSeedManager()`
- `src/io/types.zig:242` — `TorrentContext.web_seed_manager` field

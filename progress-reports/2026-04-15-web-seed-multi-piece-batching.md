# Web Seed Multi-Piece HTTP Range Batching

**Date:** 2026-04-15

## What Changed

Refactored the BEP 19 (GetRight-style) web seed handler to request multiple
contiguous pieces in a single HTTP Range request, instead of one piece per
request. For a 4 MB file with 256 KB pieces, this reduces the number of HTTP
round trips from 16 to as few as 1.

### Core changes

1. **`src/io/web_seed_handler.zig`** — Complete rewrite of the handler:
   - `WebSeedSlot` now tracks `first_piece`, `piece_count`, `total_bytes`,
     and a single `buf` covering the entire contiguous run.
   - `tryAssignWebSeedPieces` claims a contiguous run of pieces (up to
     `web_seed_max_request_bytes`) using `claimPiece` for the first piece
     and `claimSpecificPiece` for subsequent adjacent pieces.
   - One HTTP Range request per file that the run spans (single-file torrents
     always get exactly one request per batch).
   - On HTTP completion, the buffer is split at piece boundaries and each
     piece is submitted to the hasher individually with its own buffer copy.
   - `failSlot` releases all pieces in the run on failure.

2. **`src/torrent/piece_tracker.zig`** — Added `claimSpecificPiece(piece_index)`
   method that atomically claims a specific piece index if it is eligible,
   not complete, and not already in-progress. Used to build contiguous runs
   starting from the piece returned by `claimPiece`.

3. **`src/net/web_seed.zig`** — Added `MultiPieceRange` type and
   `computeMultiPieceRanges` method to `WebSeedManager`. Computes byte ranges
   for a contiguous run of pieces, producing one range per file that the run
   spans (single-file torrents always produce one range).

4. **`src/config.zig`** — Added `web_seed_max_request_bytes: u32 = 4 * 1024 * 1024`
   to `Network` struct. Parsed from TOML `[network]` section.

5. **`src/io/event_loop.zig`** — Added `web_seed_max_request_bytes` field.
   Updated `deinit` to free `buf` (renamed from `piece_buf`).

6. **`src/main.zig`** — Wires config value to event loop at startup.

7. **`src/rpc/handlers.zig`** — Exposed `web_seed_max_request_bytes` in both
   preferences GET and SET (JSON and form-encoded paths). Added field to
   `PreferencesUpdate` struct.

8. **`scripts/web_seed_server.py`** — Added `/_stats` and `/_reset` endpoints
   for request counting. Tests can verify how many HTTP Range requests were
   made for a given download.

9. **`scripts/test_web_seed.sh`** — Rewritten with three scenarios:
   - Scenario 1: Entire 1 MB torrent in one request (max_bytes >= file size)
   - Scenario 2: 4 MB file with 1 MB max (batched into ~4 requests)
   - Scenario 3: 8 MB file with 512 KB max (many small batches, tests queuing)

## Design Decisions

- **Per-piece buffer copies at hash submission time**: After the HTTP response
  completes, we copy each piece out of the large run buffer into individual
  per-piece buffers for the hasher. This avoids keeping the large buffer alive
  during hashing and lets the hasher own/free each buffer independently (which
  is the existing contract). The copy cost is negligible compared to HTTP
  round-trip savings.

- **claimSpecificPiece instead of claimContiguousRun**: Adding a targeted claim
  method is simpler and more composable than a batch method. The handler builds
  the run iteratively, stopping when it hits a non-claimable piece or the byte
  limit.

- **Multi-file torrents**: Each file in the run gets its own HTTP request
  (different URL per BEP 19), but the run covers as many contiguous pieces
  within each file as possible. The `computeMultiPieceRanges` function handles
  the mapping.

## Key Code References

- `src/io/web_seed_handler.zig:67` — `tryAssignWebSeedPieces` (contiguous run logic)
- `src/io/web_seed_handler.zig:267` — `submitPiecesToHasher` (buffer splitting)
- `src/torrent/piece_tracker.zig:283` — `claimSpecificPiece`
- `src/net/web_seed.zig:248` — `computeMultiPieceRanges`
- `src/config.zig:203` — `web_seed_max_request_bytes` field

## What Was Learned

- The existing `processHashResults` in `peer_policy.zig` handles web seed
  hash results transparently via the sentinel slot value (0xFFFF - slot_idx).
  No changes were needed there since each piece gets its own hasher submission
  with its own buffer, which is the same contract as before.

- The `target_buf` + `target_offset` mechanism in `HttpExecutor.Job` works
  well for multi-piece batching — the run buffer is written to directly at
  the correct offset for each file range.

## Remaining Issues

- The e2e test script has not been run (requires opentracker and full daemon
  infrastructure). The unit tests pass and the build is clean.
- Future optimization: instead of copying per-piece buffers at hash time,
  the hasher could accept a slice view into the run buffer with a shared
  reference count. This would eliminate the copy but adds complexity.

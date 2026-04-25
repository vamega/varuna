# Piece Hash Lifecycle Plan

This document describes a planned change to how varuna holds piece hashes in memory.
It is a design plan, not a description of the current implementation.

Links: [STATUS.md](../STATUS.md) | [zero-alloc-plan.md](zero-alloc-plan.md) | [future-features.md](future-features.md)

---

## Problem

Every loaded torrent currently keeps its full piece hash table alive for the entire lifetime
of the session. The table lives in the session's arena allocator as a flat byte slice
(`session.metainfo.pieces`, mirrored in `session.layout.piece_hashes`).

For a v1 torrent at a 256 KB piece size the table is `piece_count × 20` bytes:

| Torrent size | Piece size | Hash table |
|---|---|---|
| 1 GB | 256 KB | ~80 KB |
| 50 GB | 512 KB | ~2 MB |
| 100 GB | 16 KB | ~128 MB |
| 100 GB | 256 KB | ~8 MB |

A box seeding fifty 50 GB torrents keeps ~100 MB of SHA-1 hashes in RAM purely to support
the unlikely event that the operator issues a manual recheck. That memory buys nothing for
the primary workload (uploading blocks to peers).

---

## When are piece hashes actually used?

`session.layout.pieceHash(index)` is called in exactly three places today:

1. **`peer_policy.zig`** — `completePieceDownload`: verify a piece that just finished
   downloading from a peer.
2. **`web_seed_handler.zig`** — same verification path for web-seed downloads.
3. **`storage/verify.zig`** — `verifyPiece`: recheck, called during a full re-verification
   pass triggered by the operator or on startup after an unclean shutdown.

Seeding (uploading blocks to remote peers) **never** consults piece hashes. The downloading
peer verifies with their own copy.

---

## Proposed lifecycle

### Phase 1 — free hashes piece-by-piece as download completes

After `completePieceDownload` marks piece `i` as verified, the 20-byte hash at
`pieces[i*20 .. i*20+20]` is no longer needed for normal operation. We can zero it
immediately and track a `verified_pieces: Bitfield` alongside `complete_pieces`.

When all pieces are verified the entire `pieces` slice can be freed (or the arena page
reclaimed if we move to an arena-per-session). For large torrents at 16 KB pieces this can
free tens of MB as the download progresses rather than holding everything until session end.

**Smart-ban interaction**: the per-block peer attribution snapshot is taken *before*
`completePieceDownload` so the hash is still live when needed. A piece's hash is safe to
discard only after it transitions to `verified`. Failed pieces that trigger smart-ban block
re-requests need the hash until the reassembled piece passes — discard only on pass.

### Phase 2 — keep no hashes for seeding-only torrents

When a session is loaded for a torrent that is already 100% complete (state_db reports full
bitfield), skip loading `pieces` from the `.torrent` file entirely. The session arena still
holds everything else (file list, layout, tracker URLs, info_hash). Piece hashes are not
materialised at all.

This is the high-value case: a seeding box with dozens of large completed torrents holds
zero hash memory without any phase-1 work.

### Phase 3 — on-demand load for recheck

When the operator triggers a recheck, load the raw `.torrent` bytes from disk (already
persisted in the state database), extract the `pieces` field, run the verification pass,
then free the bytes. The recheck path in `storage/verify.zig` already takes a `session`
pointer, so threading the on-demand bytes through is straightforward.

For v2/hybrid torrents the `MerkleCache` already reconstructs piece-level SHA-256 hashes
from the per-file Merkle roots on demand. Phase 3 for v2 is largely already implemented.

---

## V2 / hybrid torrents

V2 torrents store 32-byte Blake3/SHA-256 roots per file (tiny — one per file, not one per
piece). Piece-level hashes are derived from these roots via the Merkle tree. The existing
`MerkleCache` in `src/io/event_loop.zig` already caches reconstructed trees lazily per
file and could be extended to evict completed files' trees. The per-file roots are small
enough to keep permanently.

---

## Memory savings summary

| Scenario | Today | After phase 2 |
|---|---|---|
| 50 completed 50 GB torrents (512 KB pieces) | ~100 MB | 0 B |
| Active 100 GB download (16 KB pieces) | 128 MB constant | Frees ~1.3 KB/piece as it progresses |
| Seeding box, 1000 completed torrents | proportional | 0 B for piece hashes |

---

## Implementation sketch

```
Session:
  pieces: ?[]const u8  // null once fully verified or for seeding-only load

Layout:
  pieceHash(index) -> error if pieces is null (callers handle: only called during download)

PieceTracker:
  onPieceVerified(index):
    // existing: mark complete
    // new: if session.pieces != null, zero bytes [index*20..index*20+20]
    //      if all pieces complete, session.freePieces()

Session:
  loadForSeeding():   // skip parsing "pieces" field entirely
  loadForDownload():  // parse "pieces" as today
  freePieces():       // null out slice; arena pages reclaimed at session deinit
  loadPiecesForRecheck(): // re-read .torrent bytes, extract "pieces", return slice
```

---

## Key files to change

- `src/torrent/metainfo.zig` — make `pieces` parsing optional (skip when seeding-only)
- `src/torrent/session.zig` — `loadForSeeding` vs `loadForDownload`, `freePieces`
- `src/torrent/layout.zig` — `pieceHash` returns error on null pieces
- `src/io/peer_policy.zig` — `completePieceDownload`: call `freePieces` when last piece
  verifies
- `src/storage/verify.zig` — `recheckAll`: call `session.loadPiecesForRecheck()` and free
  after

---

## What this does not change

- The info_hash (20 bytes), file list, layout, tracker URLs, and announce data remain in
  the session arena for the full lifetime of the session. These are needed for seeding,
  tracker announces, DHT, and PEX.
- The `complete_pieces` bitfield in `PieceTracker` remains in memory — it is needed to
  answer HAVE messages and build the BITFIELD sent to connecting peers.

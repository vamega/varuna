# Multi-Source Piece Assembly (Phases 1-2)

**Date:** 2026-04-15

## What changed

Implemented block-level tracking so multiple peers can contribute blocks to the
same piece simultaneously.  Previously each piece was downloaded entirely from a
single peer.

### Phase 1: DownloadingPiece abstraction (single-peer equivalence)

- Created `src/io/downloading_piece.zig` with `DownloadingPiece`, `BlockInfo`,
  `BlockState`, plus `DownloadingPieceKey`/`DownloadingPieceMap` for the
  registry.
- Added `downloading_pieces` HashMap to `EventLoop` (keyed by
  `(torrent_id, piece_index)`).
- Added `downloading_piece` and `next_downloading_piece` pointers to the `Peer`
  struct.
- Rewrote `startPieceDownload` to create/lookup a DownloadingPiece and point the
  peer at it.
- Rewrote `tryFillPipeline` to use `dp.nextUnrequestedBlock()` for block-level
  request selection.
- Rewrote PIECE handler in `protocol.zig` to write through
  `dp.markBlockReceived()` and check `dp.isComplete()`.
- Rewrote CHOKE handler to call `dp.releaseBlocksForPeer()` so choked blocks
  become available to other peers.
- Rewrote `completePieceDownload` to detach all peers from the completed DP,
  hand the buffer to the hasher, and free DP metadata.
- Rewrote `removePeer` in `event_loop.zig` to call
  `detachPeerFromDownloadingPiece` which releases requested blocks and manages
  DP lifecycle (keeps partially-received DPs in the registry for future peers).
- Updated `cleanupPeer` and `deinit` to avoid double-freeing buffers owned by
  DownloadingPieces.
- Legacy paths preserved: when `peer.downloading_piece == null`, the old
  `piece_buf`-based logic still works (used by existing tests and web seeds).

### Phase 2: Multi-source joining

- Added `tryJoinExistingPiece()` in `peer_policy.zig`: scans the
  `downloading_pieces` registry for pieces the peer can help with (same torrent,
  has the piece in its bitfield, unrequested blocks available, fewer than 3
  peers).
- Integrated into both `tryAssignPieces` (tick-based) and `markIdle`
  (immediate assignment on unchoke/have) -- join-existing is tried before
  claiming a new piece.
- `joinPieceDownload()` attaches a peer to an existing DownloadingPiece,
  incrementing `peer_count`.
- Partial abandonment: when all peers disconnect but blocks were received, the
  DownloadingPiece stays in the registry.  The next idle peer that has this
  piece will join it and continue from where the previous peers left off.
- `detachAllPeersExcept()` handles piece completion: the completing peer
  submits to the hasher while other peers on the same piece are detached and
  re-queued as idle.

## Key code references

- `src/io/downloading_piece.zig` -- new file, ~250 lines with unit tests
- `src/io/peer_policy.zig:108` -- `tryJoinExistingPiece`
- `src/io/peer_policy.zig:145` -- `startPieceDownload` (rewritten)
- `src/io/peer_policy.zig:185` -- `joinPieceDownload`
- `src/io/peer_policy.zig:209` -- `detachPeerFromDownloadingPiece`
- `src/io/peer_policy.zig:462` -- `completePieceDownload` (rewritten)
- `src/io/protocol.zig:157` -- PIECE handler (multi-source path)
- `src/io/protocol.zig:37` -- CHOKE handler (block release)
- `src/io/event_loop.zig:1207` -- `removePeer` (DP-aware cleanup)
- `src/io/types.zig:160-161` -- new Peer fields

## Design decisions

- **No mutexes**: all DownloadingPiece access is single-threaded (event loop).
- **Buffer ownership**: the hasher takes ownership of `dp.buf`; DP metadata
  (`block_infos`) is freed immediately after hasher submission.
- **Legacy compatibility**: old per-peer `piece_buf` path preserved for code
  paths that don't yet use DownloadingPiece (web seeds, existing tests).
- **Max 3 peers per piece** (`max_peers_per_piece`): prevents too many peers
  from competing for the same piece's blocks.
- **Best-fit join**: idle peers join the DownloadingPiece with the most
  unrequested blocks, maximizing parallelism benefit.

## What was learned

- The Zig `Bitfield` uses `.has()` not `.isSet()` -- discovered during build.
- DownloadingPiece must handle "unsolicited" blocks (received without prior
  request) by counting them as both requested and received.
- The `cleanupPeer` / `deinit` free-order matters: downloading_pieces registry
  must be freed before the per-peer buffer cleanup loop, and peers with
  downloading_piece pointers must skip freeing `piece_buf`.

## Remaining / follow-up

- **Phase 3 (block-level endgame)**: In endgame, duplicate individual blocks
  instead of entire pieces.  `nextEndgameBlock` would pick blocks in `.requested`
  state from the slowest peer.
- **Phase 4 (smart ban integration)**: Snapshot `block_infos` peer attribution
  on piece completion for per-block hash comparison on failure.
- **Remove legacy fields**: once all tests are migrated to DownloadingPiece,
  remove `piece_buf`, `blocks_received`, `blocks_expected` from Peer struct.
- **demo_swarm validation**: needs opentracker infrastructure to run end-to-end.

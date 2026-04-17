# Multi-Source Piece Assembly Design

**Status:** Planned (design complete, not yet implemented)
**Date:** 2026-04-16
**Prerequisite for:** Smart Ban Phase 1+ (per-block peer attribution)

## Overview

Currently each piece is downloaded entirely from a single peer. Multi-source piece assembly enables requesting different blocks (16KB sub-pieces) of the same piece from multiple peers simultaneously. This improves download speed and enables per-block blame for the smart ban algorithm.

## Key Data Structure: DownloadingPiece

Shared per-piece state that multiple peers reference:

```
DownloadingPiece:
    piece_index: u32
    torrent_id: TorrentId
    buf: []u8                    -- shared piece buffer
    block_infos: []BlockInfo     -- per-block state + peer attribution
    blocks_total: u16
    blocks_received: u16
    blocks_requested: u16
    peer_count: u8

BlockInfo:
    state: enum { none, requested, received }
    peer_slot: u16               -- who owns/sent this block
```

Registry on EventLoop: `downloading_pieces: HashMap((torrent_id, piece_index) -> *DownloadingPiece)`

## Implementation Phases

### Phase 1: Data structures + single-peer equivalence (~300 lines)
Introduce DownloadingPiece but keep single-peer behavior. Every piece still goes to one peer but uses the new abstraction. Validate equivalence with existing tests and demo_swarm.

### Phase 2: Multi-source joining (~150 lines)
Enable multiple peers to work on the same piece. tryAssignPieces gains a "join existing download" path before claiming new pieces. Partial abandonment preserves received blocks.

### Phase 3: Block-level endgame (~100 lines)
In endgame, duplicate individual blocks instead of entire pieces. nextEndgameBlock picks blocks in .requested state from the slowest peer.

### Phase 4: Smart ban integration (~50 lines)
Snapshot block_infos peer attribution on piece completion. Pass to smart ban system for per-block hash comparison on failure/success.

## Key Changes by File

| File | Change |
|------|--------|
| `src/io/downloading_piece.zig` | New: DownloadingPiece, BlockInfo, BlockState (~120 lines) |
| `src/io/types.zig` | Peer: remove piece_buf/blocks_*, add downloading_piece pointer |
| `src/io/peer_policy.zig` | startPieceDownload (join-or-create), tryFillPipeline (block-level), completePieceDownload (multi-peer), tryAssignPieces (join-existing phase) |
| `src/io/protocol.zig` | PIECE handler: write to shared buffer. CHOKE handler: release blocks |
| `src/io/event_loop.zig` | downloading_pieces registry, removePeer partial release |

## Total estimate: ~685 lines touched (490 new, 195 modified)

## Design source
Based on analysis of libtorrent's `piece_picker.cpp` (`downloading_piece` struct, `block_info`) and varuna's current single-peer model. Full design details in progress report.

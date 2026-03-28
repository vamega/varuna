# Boundary Pieces in Selective File Download

**Date:** 2026-03-28
**Status:** Decided

## Problem

When downloading only some files in a multi-file torrent, pieces at file boundaries span both wanted and unwanted files. What should happen to the data from the unwanted file?

Example: Piece N spans file A (wanted) and file B (skipped). We must download piece N to get file A's data. But piece N also contains bytes for file B.

## Decision

**Download and write the full boundary piece, including data for skipped files.**

This matches the behavior of all major BitTorrent clients:
- **libtorrent (arvidn)**: Uses `max(priority)` across all files touching a piece. Boundary pieces always get the priority of the highest-priority file in the span. (`src/torrent.cpp:154-189`)
- **libtorrent-rakshasa**: Inserts full file ranges into priority sets; boundary chunks are included if any spanning file is wanted. (`src/download/download_wrapper.cc:300-335`)
- **qBittorrent**: Inherits libtorrent's behavior.

## Rationale

1. **Piece integrity**: Pieces are cryptographic units verified by SHA-1 hash. You either have the complete piece (and can verify it) or you don't. There's no sub-piece verification.

2. **Seeding**: Once a piece is complete, we can seed it to other peers. Partial pieces can't be seeded because peers request whole pieces and verify them by hash.

3. **Protocol constraint**: The BitTorrent wire protocol has no sub-piece granularity for verification. Block requests are sub-piece, but hash verification is per-piece.

4. **Simplicity**: "If ANY file in the piece is wanted, download the whole piece" is a single bitwise OR over file priorities → piece mask. No complex partial-write tracking needed.

## Implementation in Varuna

- `src/torrent/file_priority.zig:buildPieceMask()` marks a piece as wanted if ANY spanning file is not `do_not_download`
- `src/storage/writer.zig` lazily creates previously-skipped files on demand when a boundary piece write needs them (`ensureFileOpen()`)
- Skipped files are NOT pre-allocated at init time (saves disk space)
- If a skipped file later becomes wanted, it's created on first write

## Disk space impact

Boundary pieces cause a small amount of "extra" data to be written for skipped files — at most `piece_length - 1` bytes per file boundary. For a 256KB piece length and a torrent with 10 files, this is at most ~2.5MB of extra data. For typical use cases this is negligible.

## Alternatives considered

- **Don't write skipped-file data**: Saves disk space but prevents seeding boundary pieces and complicates piece verification. No major client does this.
- **Store boundary data in memory only**: Possible but creates complexity (piece cache eviction, restart loses data, can't seed after restart). No major client does this.
- **Pad skipped-file regions with zeros**: Would cause hash verification failures since the piece hash includes the real file data.

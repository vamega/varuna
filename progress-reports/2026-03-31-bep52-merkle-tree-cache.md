# BEP 52 Runtime Merkle Tree Cache for Hash Serving

**Date**: 2026-03-31

## What was done

Implemented runtime per-file Merkle tree caching so that BEP 52 hash request messages (msg_type 21) are served with real hashes instead of always being rejected.

### New module: `src/torrent/merkle_cache.zig`

- `MerkleCache` struct: per-torrent cache of per-file Merkle trees.
- LRU eviction when the cache exceeds `max_cached_trees` (default 32).
- `buildAndCache()`: builds a `MerkleTree` from piece hashes, validates the root against the expected `pieces_root` from torrent metadata, and stores it.
- `getTree()`: cache lookup with LRU access tracking.
- `isFileComplete()`: checks if all pieces for a file are complete using the `Bitfield`.
- `filePieceRange()`: returns (first_piece, count) for a file from the layout.
- `invalidate()`: removes a cached tree (e.g., on piece corruption).
- 8 tests covering init/deinit, build/retrieve, root mismatch rejection, LRU eviction, invalidation, file completeness checking, piece range queries, and end-to-end hash serving via `buildHashesFromTree`.

### Changes to `src/io/event_loop.zig`

- Added `MerkleCache` import and `merkle_cache` field to `TorrentContext`.
- Added `initMerkleCache()` method: lazily creates the cache for v2/hybrid torrents.
- Added cleanup of `merkle_cache` in `removeTorrent()`.

### Changes to `src/io/protocol.zig`

- Rewrote `handleHashRequest()` to serve real hashes:
  1. Validates request parameters and v2 metadata.
  2. Lazily initializes `MerkleCache` if not yet created.
  3. On cache hit, builds and sends a hashes response via `buildHashesFromTree`.
  4. On cache miss, checks file completeness, reads piece data from disk via `pread`, computes SHA-256 hashes, builds and caches the tree, then serves the response.
  5. Falls back to hash reject if the file is incomplete or too large for inline hashing (>4096 pieces).
- Added `buildPieceHashesFromDisk()`: reads piece data from shared file descriptors using `pread` and computes SHA-256 hashes. Uses the v2 file-aligned layout for correct piece-to-file mapping.
- Added `sendHashesFromTree()`: helper to build and send a hashes response message.

### Bug fix: `src/torrent/merkle.zig`

- Fixed `zero_hash` comptime initialization to use the 3-argument `Sha256.hash` API required by Zig 0.15.2 (was using the old 2-argument form that returned a value).

## What was learned

- In Zig 0.15.2, `Sha256.hash` takes `(data, *out, options)` and writes to an output pointer rather than returning a digest. The comptime `zero_hash` was using the old API, which only manifested as a build error when the code was pulled into the main binary (the test binary had different code paths).
- BEP 52 hash serving requires the full Merkle tree, not just the root. The tree must be built from SHA-256 hashes of piece data, which means reading piece data from disk. This is acceptable as a one-time cost per file since trees are cached.
- The `pread` syscall used in `buildPieceHashesFromDisk` is an acceptable exception to the io_uring policy because tree building is a one-time operation per file (not a hot path), similar to `PieceStore.init`.
- For files with >4096 pieces, inline hashing would block the event loop too long. These should be pre-built on download completion or built in a background thread. The current implementation rejects such requests and logs a debug message.

## Remaining issues / follow-up

- **Large file tree building**: files with >4096 pieces are rejected for inline hashing. A background thread approach (similar to the hasher thread pool) would be needed for these. This is uncommon in practice since 4096 pieces at 256KiB piece_length covers files up to 1 GiB.
- **Eager cache population**: currently trees are built only on demand. An optimization would be to pre-build trees for all complete files when transitioning to seed mode (e.g., after download completes or on daemon startup for complete torrents).
- **Cache persistence**: Merkle trees could be persisted to SQLite to avoid re-reading piece data on daemon restart. This would be especially useful for large files.

## Key code references

- `src/torrent/merkle_cache.zig`: entire new module
- `src/io/protocol.zig:560-770`: rewritten `handleHashRequest`, new `buildPieceHashesFromDisk` and `sendHashesFromTree`
- `src/io/event_loop.zig:172-205`: `TorrentContext.merkle_cache` field
- `src/io/event_loop.zig:643-665`: `initMerkleCache` method
- `src/torrent/merkle.zig:130-135`: `zero_hash` comptime fix

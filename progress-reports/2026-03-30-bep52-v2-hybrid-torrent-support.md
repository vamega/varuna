# BEP 52: BitTorrent v2 / Hybrid Torrent Support (Phase 1-3)

## What was done

Implemented BEP 52 (BitTorrent v2 / hybrid torrent) support covering phases 1-3 of the plan in `docs/dht-bep52-plan.md`:

1. **Version detection and v2 file tree parsing** (Phase 1)
2. **Merkle tree piece verification** (Phase 2)
3. **File-aligned piece layout** (Phase 3)

### New files
- `src/torrent/merkle.zig` -- SHA-256 Merkle tree: construction from piece hashes, root computation, per-piece verification, Merkle proof generation/verification, power-of-2 padding with zero-hashes. 11 tests.
- `src/torrent/file_tree.zig` -- v2 file tree parser: recursive walk of nested bencode dictionaries, empty-string leaf markers for file entries, `length` and `pieces root` extraction, zero-length file handling. 8 tests.

### Modified files
- `src/torrent/metainfo.zig` -- Added `TorrentVersion` enum (v1/v2/hybrid), `V2File` struct, `detectVersion()` function. Extended `Metainfo` with `version`, `info_hash_v2`, `file_tree_v2` fields. Parse function now branches on version: v1 (unchanged), v2 (file tree + SHA-256 info-hash), hybrid (both). Pure v2 populates v1 `files` array from file tree for backward compatibility. 7 new tests.
- `src/torrent/info_hash.zig` -- Added `computeV2()` using `std.crypto.hash.sha2.Sha256` (has hardware SHA-NI acceleration). 1 new test.
- `src/torrent/layout.zig` -- Added `version` and `v2_files` fields to `Layout`. v2 pieces are file-aligned: `mapPieceV2` always returns single-file spans, `pieceSizeV2` respects file boundaries. `build` dispatches to `buildV2` for pure v2. 4 new tests.
- `src/storage/verify.zig` -- Added `HashType` enum (sha1/sha256), extended `PiecePlan` with `expected_hash_v2` and `hash_type`. `verifyPieceBuffer` dispatches to SHA-1 or SHA-256. `planPieceVerification` selects hash type based on layout version.
- `src/io/hasher.zig` -- Extended `Job` with `expected_hash_v2` and `hash_type`. Worker function dispatches to SHA-1 or SHA-256 based on job type.
- `src/torrent/root.zig` -- Exported new `file_tree` and `merkle` modules.

## What was learned

- **v2 piece alignment**: The key architectural difference from v1 is that v2 pieces never cross file boundaries. Each file has its own independent sequence of pieces, and the last piece of each file may be shorter than `piece_length`. This simplifies I/O (always single-file spans) but changes how piece indices map to files.
- **Merkle tree padding**: BEP 52 requires the Merkle tree to be a balanced binary tree, so the leaf count must be padded to the next power of 2 with zero-hashes (SHA-256 of empty data).
- **Zig 0.15 ArrayList API**: `ArrayList` in Zig 0.15 uses `.empty` instead of `.init(allocator)`, and methods like `append`, `deinit`, `toOwnedSlice` all take an explicit allocator parameter.
- **Default field values**: Adding default values to `Metainfo` struct fields (`version: .v1`, `info_hash_v2: null`, etc.) ensures all existing code that constructs `Metainfo` literals continues to compile without modification.

## Remaining work

- **Phase 4**: Peer wire handshake dual info-hash matching (accept connections using either v1 or v2 hash for hybrid torrents), tracker announce with v2 info-hash, resume DB schema extension for v2 info-hash column.
- **Phase 5 (deferred)**: BEP 52 section 5 hash request/hashes/hash reject message exchange, Merkle proof exchange with peers, piece-layer streaming.
- **Test fixtures**: Create actual v2 and hybrid `.torrent` test files (requires a v2-capable torrent creator like libtorrent Python bindings).
- **Fuzz tests**: Add fuzz test for v2 file tree parsing (untrusted input).

## Key code references

- `src/torrent/merkle.zig:12` -- `MerkleTree` struct
- `src/torrent/file_tree.zig:19` -- `parseFileTree` function
- `src/torrent/metainfo.zig:6` -- `TorrentVersion` enum
- `src/torrent/metainfo.zig:112` -- `detectVersion` function
- `src/torrent/layout.zig:89` -- `mapPieceV2` (file-aligned piece mapping)
- `src/torrent/layout.zig:249` -- `buildV2` (v2 layout construction)
- `src/torrent/info_hash.zig:14` -- `computeV2` (SHA-256 info-hash)
- `src/storage/verify.zig:27` -- `HashType` enum
- `src/io/hasher.zig:201` -- SHA-256 dispatch in hasher worker

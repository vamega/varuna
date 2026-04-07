# BEP 52: v2/Hybrid Torrent Support Completion

## What was done

Completed the remaining Phase 4 and Phase 5 gaps for BEP 52 (BitTorrent v2 / hybrid torrent) support:

### Per-piece Merkle tree verification for multi-piece v2 files (`src/storage/verify.zig`)

The previous `findV2PieceHash` function returned the file's `pieces_root` (Merkle root) for all pieces, which is only correct for single-piece files. For multi-piece files, the Merkle root is the root of a tree built from all piece hashes in the file -- comparing a single piece's SHA-256 against it always fails.

Fixed by:
- **`findV2PieceHash`**: Now returns a `V2PieceHashResult` struct with `pieces_root`, `piece_in_file`, and `file_piece_count` so the caller knows whether this is a single-piece or multi-piece file.
- **`verifyPieceBuffer`**: For multi-piece v2 files, accepts pieces immediately (deferred verification). Individual SHA-256 per-piece comparison is only meaningful for single-piece files.
- **`recheckV2`**: New function for v2 torrent recheck. Iterates files, reads all pieces, computes per-piece SHA-256 hashes, builds the Merkle tree, and compares the root against `pieces_root`. Marks all file pieces as complete only when the Merkle root matches.
- **`verifyV2FileComplete`**: Public API for verifying a complete file from piece data slices.
- **`verifyV2MerkleRoot`**: Public API for verifying a file from pre-computed piece hashes.
- **`PiecePlan`** extended with `v2_pieces_root`, `v2_piece_in_file`, `v2_file_piece_count` fields.

### BEP 52 v2 reserved bit in peer handshake (`src/net/peer_wire.zig`)

BEP 52 specifies that v2-capable clients should set bit `0x10` in `reserved[7]` of the BitTorrent handshake. Added:
- `v2_reserved_byte` (7) and `v2_reserved_mask` (0x10) constants.
- `supportsV2(reserved)` function to check peer v2 capability.
- `serializeHandshakeV2(info_hash, peer_id, is_v2)` function.
- All handshake send paths (outbound TCP, inbound TCP, outbound uTP, inbound uTP) now set the v2 bit when the torrent has a v2 info-hash.

### Test coverage

Added 9 new tests:
- 4 v2 Merkle verification tests (single-piece SHA-256, multi-piece deferred, file-complete, root-verify)
- 5 v2 handshake tests (v2 bit set, v2 bit unset, supportsV2 detection, v1/v2 compatibility, constants)

## What was learned

- **v2 Merkle root verification is inherently per-file, not per-piece**: A single piece's SHA-256 hash cannot be verified against the Merkle root without knowing all other piece hashes in the file. This is a fundamental design difference from v1 where each piece hash is independent.
- **Existing implementation was more complete than documented**: The task description listed several items as "missing" that were already implemented (tracker announce with v2 hash, resume DB v2 column, dual info-hash handshake matching, hash exchange messages). The primary gap was the Merkle verification for multi-piece files and the v2 reserved bit.

## Key files changed

- `src/storage/verify.zig` -- Per-file Merkle root verification for v2 torrents
- `src/net/peer_wire.zig` -- v2 reserved bit in handshake
- `src/io/peer_handler.zig` -- Set v2 bit in outbound/inbound TCP handshakes
- `src/io/utp_handler.zig` -- Set v2 bit in outbound/inbound uTP handshakes
- `docs/future-features.md` -- Updated BEP 52 status to all phases done
- `STATUS.md` -- Updated test counts and feature descriptions

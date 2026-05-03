# BEP 52 Async Recheck

## What Changed

- Fixed async recheck for pure-v2 multi-piece files. The recheck state now keeps per-file SHA-256 leaf hashes and only marks the file's pieces complete after the computed Merkle root matches the torrent's `pieces root`.
- Extended hasher results to carry the actual SHA-256 leaf hash for v2 verification jobs. The normal `valid` boolean remains for v1 and single-piece v2 checks.
- Tightened the resume fast path for v2 multi-piece files: a known-complete bit is trusted only when every piece in that v2 file is known complete. Partial resume state now rehashes the whole file so the root can be verified.
- Added SimIO regressions for pure-v2 multi-piece async recheck and partial known-complete v2 files.

## What Was Learned

- The old async path failed closed for multi-piece v2 files because `planPieceVerification` intentionally uses an all-zero `expected_hash_v2` sentinel. The hasher compared each leaf hash against that sentinel, so correct files completed with zero verified pieces.
- Synchronous recheck already had the right model in `verifyV2MerkleRoot`; async only needed the actual leaf hashes returned from the hasher and a per-file aggregation point.
- Partial resume state matters for v2. Trusting one piece of a multi-piece file prevents constructing the complete file root and can leave valid data unverified.

## Validation

- `zig build test-recheck --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `zig build test-recheck-buggify --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `zig build test-recheck-live-buggify --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `zig build test --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`

## Follow-Up

- Add a multi-file pure-v2 async recheck regression, including one corrupted file beside one valid file, so file-scoped completion cannot leak across v2 file boundaries.
- Consider removing the all-zero sentinel from the long-term `PiecePlan` API and making multi-piece v2 verification an explicit plan variant.

## Key References

- `src/io/hasher.zig:62` - hasher results now include `actual_hash_v2`.
- `src/io/hasher.zig:254` - SHA-256 jobs return both direct validity and the computed leaf hash.
- `src/io/recheck.zig:89` - per-v2-file recheck state for leaf aggregation.
- `src/io/recheck.zig:313` - async hash results route multi-piece v2 pieces into Merkle aggregation.
- `src/io/recheck.zig:666` - partial v2 resume state no longer skips individual pieces.
- `src/io/recheck.zig:729` - v2 file completion verifies the Merkle root before marking pieces complete.
- `tests/recheck_test.zig:962` - pure-v2 multi-piece async recheck regression.
- `tests/recheck_test.zig:999` - partial known-complete v2 regression.

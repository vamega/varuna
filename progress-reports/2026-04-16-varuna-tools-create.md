# varuna-tools create Command

**Date:** 2026-04-16

## What Changed

Implemented a native Zig torrent creator in `varuna-tools`, eliminating the
Node.js dependency for test tooling.

### Features (mktorrent parity)
- `-a`/`--announce` — tracker URL (required)
- `-o`/`--output` — output .torrent path
- `-l`/`--piece-length` — bytes or power-of-2 exponent (e.g., 18 = 256KB)
- `-n`/`--name` — torrent name
- `-p`/`--private` — private torrent flag
- `-w`/`--web-seed` — BEP 19 url-list
- `-c`/`--comment` — comment field
- `-s`/`--source` — source field (private tracker ID)
- `--hybrid` — BEP 52 hybrid v1+v2 torrent creation
- `-t`/`--threads` — parallel hashing thread count (default: CPU count)
- Auto piece length selection (targets ~1500 pieces, 16KB–16MB)
- Single file and directory (multi-file) support

### Parallel hashing
Thread pool with atomic piece counter. Each thread does `preadAll` (thread-safe)
+ `Sha1.hash()` (build-time backend: varuna HW-accelerated, stdlib, or boringssl).

Benchmarks (100MB file, 256KB pieces = 800 pieces):
| Threads | Time  | Speed     | Speedup |
|---------|-------|-----------|---------|
| 1       | 333ms | 300 MB/s  | 1x      |
| 4       | 90ms  | 1,109 MB/s| 3.7x   |
| 16 auto | 30ms  | 3,298 MB/s| 11.1x  |

### Hybrid v2 creation (BEP 52)
- SHA-256 per-file Merkle tree construction
- `file tree` nested dict, `pieces root`, `meta version: 2`
- `piece layers` for per-file SHA-256 piece hashes
- 7 unit tests including Merkle root verification and v1 regression

### Validation
- Info hashes byte-identical to mktorrent for same inputs
- All test scripts updated to use `varuna-tools create`
- Node.js no longer required for any test or build tooling

## Key Code References
- `src/torrent/create.zig` — torrent creation + parallel hashing
- `src/app.zig:runCreate` — CLI argument parsing
- `src/torrent/merkle.zig` — Merkle tree for BEP 52

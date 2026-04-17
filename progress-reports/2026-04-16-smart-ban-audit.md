# Smart Ban Audit — libtorrent Reference vs Varuna

**Date:** 2026-04-16

## Findings

Varuna has **zero hash-failure-based peer penalization**. A peer sending corrupt
data causes infinite piece re-download with no consequence. No trust points,
no hashfails counter, no smart ban, no parole mode.

### libtorrent's implementation
- `src/smart_ban.cpp` (329 lines) — torrent_plugin extension
- On piece failure: reads each block from disk, computes per-block SHA-1,
  stores in `map<(piece, block), {peer, digest}>`
- On piece pass: re-reads blocks, compares against stored hashes. Peers whose
  blocks differ between failed and passed downloads are banned
- Also has trust-point system: -2 per failure, ban at -7

### What varuna lacks
1. No per-block peer tracking (single peer per piece today)
2. No post-failure block-level hashing
3. No peer reputation tracking (trust_points, hashfails)
4. No piece-pass callback for cross-referencing prior failures

### Implementation plan
Documented in `docs/future-features.md` as a 3-phase plan:
- Phase 0: Basic trust-point banning (~30 lines)
- Phase 1: Smart ban data structures in `src/net/smart_ban.zig` (~200 lines)
- Phase 2: Event loop integration in `processHashResults` (~50 lines)
- Future: Multi-source piece assembly for full smart ban value

### Varuna simplifications vs libtorrent
- No async disk reads (piece buffer still in memory at hash-result time)
- Single peer per piece (no get_downloaders() needed)
- No force_copy race (no disk cache eviction)

# Multi-tracker simultaneous announce, super-seeding, huge page cache

## What was done

Three protocol/performance features implemented:

### 1. Multi-tracker simultaneous announce (BEP 12)

Previously, tracker announces iterated through the announce-list sequentially: try tier 1, fall back to tier 2, etc. Now all tracker URLs are announced to in parallel using one thread per URL (capped at 8). The first successful response with peers wins; the rest are discarded.

- New module: `src/tracker/multi_announce.zig`
- Integrated into both `src/daemon/torrent_session.zig` (daemon path) and `src/torrent/client.zig` (standalone path)
- Single-URL case is optimized to avoid threading overhead
- Each announce thread creates its own short-lived io_uring ring (16 entries), consistent with the existing announce_ring pattern

### 2. Super-seeding (BEP 16)

Initial seed optimization. When enabled, the seeder sends individual HAVE messages instead of a full bitfield, and tracks which pieces each peer has seen. This maximizes piece diversity during initial seeding.

- New module: `src/io/super_seed.zig` -- `SuperSeedState` tracks per-peer advertised pieces and per-piece distribution counts
- Integrated into `src/io/protocol.zig` -- `sendInboundBitfieldOrUnchoke()` now checks for super-seed mode and sends a single HAVE instead of bitfield
- On receiving HAVE from a peer in super-seed mode, sends back the next piece to advertise (rarest-first)
- Peer cleanup in `removePeer()` and `removeTorrent()` handles super-seed state
- API toggle: `POST /api/v2/torrents/setSuperSeeding` with `hash` and `value=true/false`
- Exposed in torrent properties JSON as `super_seeding` field
- `TorrentSession.setSuperSeeding()` propagates to the event loop's `enableSuperSeed()`/`disableSuperSeed()`

### 3. Huge page piece cache

Optional mmap-backed buffer pool for seed piece read buffers that uses huge pages (2MB TLB entries) to reduce TLB pressure.

- New module: `src/storage/huge_page_cache.zig` -- `HugePageCache` with 3-tier fallback:
  1. `MAP_HUGETLB` (explicit huge pages, requires `/proc/sys/vm/nr_hugepages`)
  2. `madvise(MADV_HUGEPAGE)` (transparent huge pages)
  3. Regular `mmap` (always succeeds)
- Integrated into `src/io/event_loop.zig` -- `huge_page_cache` field, `initHugePageCache()` method
- Seed read buffers in `src/io/seed_handler.zig` try the pool first, fall back to allocator
- `PendingPieceRead.from_pool` flag tracks ownership for correct cleanup
- Config: `performance.use_huge_pages` (bool), `performance.piece_cache_size` (bytes, default 64MB)
- Exposed in preferences API: `piece_cache_enabled`, `piece_cache_allocated`, `piece_cache_huge_pages`

## Key files

- `src/tracker/multi_announce.zig` -- parallel announce logic
- `src/io/super_seed.zig` -- BEP 16 state tracker
- `src/storage/huge_page_cache.zig` -- huge page buffer pool
- `src/io/event_loop.zig:170` -- TorrentContext.super_seed field
- `src/io/event_loop.zig:296` -- huge_page_cache field
- `src/io/protocol.zig:250` -- super-seed bitfield bypass
- `src/io/seed_handler.zig:99` -- huge page pool allocation for read buffers
- `src/config.zig:48-51` -- use_huge_pages and piece_cache_size config
- `src/daemon/torrent_session.zig:120` -- super_seeding field
- `src/rpc/handlers.zig:193` -- setSuperSeeding API endpoint

## What was learned

- Zig 0.15.2's `posix.madvise()` takes 3 arguments (ptr, len, advice as u32), not an enum. The `linux.MADV.HUGEPAGE` constant is 14.
- Zig 0.15.2's `posix.mmap()` takes `prot` as `u32` (not a struct), so `linux.PROT.READ | linux.PROT.WRITE` is the correct form.
- `MAP_HUGETLB` requires the system to have huge pages pre-allocated (`echo N > /proc/sys/vm/nr_hugepages`). Without this, the mmap returns ENOMEM. The 3-tier fallback handles this gracefully.
- BEP 16 super-seeding needs careful integration with the inbound peer handshake flow: the bitfield send state is reused for the HAVE message, which flows naturally into unchoke.

## Tests

- `multi_announce.zig`: 2 tests (empty URLs error, single-URL optimization path)
- `super_seed.zig`: 5 tests (least-distributed piece selection, peer avoidance, distribution tracking, cleanup, preference for rare pieces)
- `huge_page_cache.zig`: 5 tests (zero capacity, fallback, alloc/reset, exhaustion, huge page flag)
- All existing tests continue to pass.

## Remaining work

- Super-seed could benefit from automatic disable once `isFullyDistributed()` returns true
- The huge page cache currently uses a simple bump allocator -- once exhausted, it falls back to the general allocator. A more sophisticated approach could reset the pool periodically.
- Multi-tracker announce could be extended to the re-announce path in `peer_policy.zig` (currently single-URL only)

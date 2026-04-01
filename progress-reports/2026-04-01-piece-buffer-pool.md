# 2026-04-01: piece buffer pool

## What was done and why

- Added a bounded `PieceBufferPool` inside the shared `EventLoop`.
- Reused `PieceBuffer` wrapper objects through an intrusive free list.
- Retained heap-backed piece buffers by common backing sizes instead of allocating and freeing them every create/release cycle.
- Added `piece_buffer_cycle` to `varuna-perf` so the production `createPieceBuffer()` / `releasePieceBuffer()` path can be measured directly.

This was the next obvious step after fixing the huge-page cache lifetime bug. The huge-page cache now reuses mapped slices correctly, but wrapper allocation and non-huge-page backing allocation were still churning on the same common piece sizes.

## What was learned

- Piece-buffer churn was far larger than the remaining warm path needed. A tiny bounded pool is enough to remove almost all of it after warmup.
- Wrapper reuse matters as much as backing reuse for this path. Reusing only the backing slices would still leave one object allocation/destruction per piece-buffer cycle.
- Common size classes are a better first cut than exact-size retention. They catch the normal torrent piece-size set without needing a large number of buckets.

## Measured result

- `zig build -Doptimize=ReleaseFast perf-workload -- piece_buffer_cycle --iterations=5000`
  before: `356068992 ns`, `50000` allocs, `50000` frees, `27935320000` bytes allocated
  after: `239873 ns`, repeat `206658 ns`, `11` allocs, `0` frees, `5587408` live/peak retained bytes

## Remaining issues / follow-up

- The plaintext seed path still allocates one packed vectored-send-state block per batch. That is the next allocator target if seed-path traces still matter after the buffer pool.
- The size-class table is conservative. If real torrents cluster around other piece sizes, extend it based on measurement.

## Code references

- `src/io/event_loop.zig:260`
- `src/io/event_loop.zig:277`
- `src/io/event_loop.zig:1656`
- `src/perf/workloads.zig:426`

# 2026-04-01: huge-page cache reuse

## What was done and why

- Reworked `HugePageCache` from a bump-only allocator into a reusable free-range allocator.
- Wired `EventLoop.releasePieceBuffer()` to return pooled piece slices back to the huge-page cache instead of only skipping `free()` for them.
- Added unit coverage for both simple reuse and adjacent-range merging.

The old behavior was not acceptable for a long-running daemon: once the mapped cache had been carved through once, later pooled piece-buffer releases did not make any of that space available again, so the daemon would eventually fall back to the general allocator permanently.

## What was learned

- The original huge-page cache helped TLB behavior only while the bump region still had headroom. It was not a true reusable pool.
- A simple sorted free-range list is enough to recover the mapped region correctly for the current seed-read workload. This fixes the lifetime problem without changing the existing `MAP_HUGETLB -> MADV_HUGEPAGE -> regular mmap` fallback chain.
- Returning pooled slices on release is the critical missing step. Without that, even a more sophisticated cache object would still leak effective capacity.

## Remaining issues / follow-up

- This fixes reuse of the mapped piece backing memory, but it does not yet pool `PieceBuffer` wrapper objects.
- If free-range bookkeeping becomes hot under real swarm traffic, switch to size-class free lists tuned to common piece sizes.

## Code references

- `src/storage/huge_page_cache.zig:12`
- `src/storage/huge_page_cache.zig:102`
- `src/storage/huge_page_cache.zig:116`
- `src/io/event_loop.zig:1392`
- `src/io/event_loop.zig:1573`

# Remove Explicit MAP_HUGETLB From The Piece Cache

## What Was Done And Why

Removed the explicit `mmap(MAP_HUGETLB)` path from the reusable piece cache and kept the mmap-backed cache plus optional `madvise(MADV_HUGEPAGE)` hint. The goal was to preserve the useful part of the feature, stable reusable piece-buffer storage, without asking users to pre-provision huge pages at the system level.

The cache still maps a reusable backing region and can still be treated as a transparent-huge-page candidate, but it no longer distinguishes between “explicit huge pages” and “regular pages” in the allocator itself.

## What Was Learned

- The operational cost of `MAP_HUGETLB` was not justified by the codebase’s measured wins so far. The big observed improvements came from reuse and pooling, not from proving explicit huge-page mappings were necessary.
- `MADV_HUGEPAGE` is the lower-friction fit for this path because the piece cache is long-lived, reused, and large enough to be a plausible transparent-huge-page candidate.
- The mapped cache region and the per-piece buffers are different things:
  - the mapped cache region is the whole reusable arena, defaulting to `64 MiB` when `initHugePageCache()` is called with `capacity = 0`
  - each piece buffer handed out from that cache is one whole-piece backing slice sized to the torrent piece length, rounded up to the nearest retained class (`16 KiB`, `64 KiB`, `256 KiB`, `512 KiB`, `1 MiB`, `2 MiB`, `4 MiB`, `8 MiB`) or left exact above `8 MiB`

## Remaining Issues Or Follow-Up Work

- The public config name `performance.use_huge_pages` is now really a transparent-huge-page hint toggle. That is compatible, but still slightly misleading. A later cleanup can rename it if config compatibility policy allows.
- The API field `piece_cache_huge_pages` now effectively means “huge-page hint requested/applied,” not “explicit huge pages were provisioned.”

## Code References

- [src/storage/huge_page_cache.zig](/home/vmadiath/projects/varuna/src/storage/huge_page_cache.zig)
- [src/io/event_loop.zig](/home/vmadiath/projects/varuna/src/io/event_loop.zig)
- [src/config.zig](/home/vmadiath/projects/varuna/src/config.zig)
- [src/main.zig](/home/vmadiath/projects/varuna/src/main.zig)
- [src/rpc/handlers.zig](/home/vmadiath/projects/varuna/src/rpc/handlers.zig)

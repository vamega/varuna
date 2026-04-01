# 2026-03-31: Memory Baseline And First Allocation Reduction Pass

## What was done and why

- Added `varuna-perf`, a synthetic workload binary for repeatable allocation and cache measurements without requiring a real swarm or WebUI workload.
- Added a counting allocator so each workload reports allocation count, transient bytes, and peak live bytes directly.
- Reduced short-lived allocations in the highest-churn paths first:
  - request batches now stay on stack / small-send storage,
  - seed batching no longer heap-copies each queued block,
  - `/sync/maindata` now uses fixed-size snapshot keys and a request arena,
  - BEP 10 and ut_metadata decoders now parse fixed-shape dictionaries without allocating bencode trees,
  - scan-heavy peer-policy loops now iterate a dense active-slot list instead of walking every peer slot.

## What was learned

- WSL2 on this host still blocks `perf stat` / `perf record` until the matching `linux-tools-6.6.87.2-microsoft-standard-WSL2` package is installed. `cachegrind` is the practical fallback for cache-miss comparisons here.
- The biggest low-risk wins were all from avoiding temporary heap ownership:
  - request batching was dominated by one tiny heap allocation per refill,
  - extension and ut_metadata decode were dominated by parse-tree allocation,
  - seed batching paid for both per-block copies and the final packed buffer.
- `/sync/maindata` still allocates a meaningful amount even after the arena pass. The remaining cost is now mostly the final response body plus the stats/category/tag materialization itself, not snapshot-key duplication.

## Remaining issues / follow-up

- `Peer` is still a wide AoS struct. The active-slot list removes wasted empty-slot scans, but it is not a full hot/cold split or SoA conversion yet.
- The API server still concatenates headers and body into one owned response buffer. A vectored send path is still available if API polling shows up in end-to-end profiling.
- More RPC endpoints can use the same request-arena pattern as `/sync/maindata`.

## Key measurements

- `request_batch`: `100000` allocs -> `0`; `8.63e8 ns` -> `1.20e6 ns`.
- `seed_batch`: `45001` allocs -> `5001`; `1.31 GB` transient bytes -> `656 MB`; `5.10e8 ns` -> `2.27e8 ns`.
- `extension_decode`: `200003` allocs -> `3` setup allocs; `1.16e9 ns` -> `1.99e6 ns`.
- `ut_metadata_decode`: `50004` allocs -> `4` setup allocs; `4.18e8 ns` -> `1.51e6 ns`.
- `sync_delta`: `46946` allocs -> `32491`; cachegrind `D1` misses `127,624` -> `80,271`; `LLd` misses `73,839` -> `41,528`.

## Code references

- Harness and allocator instrumentation: `build.zig:198`, `src/perf/main.zig:7`, `src/perf/counting_allocator.zig:28`, `src/perf/workloads.zig:83`
- Scratch-span piece planning: `src/storage/verify.zig:42`, `src/storage/verify.zig:109`, `src/io/peer_policy.zig:192`, `src/io/seed_handler.zig:96`
- Small tracked-send storage and request batching: `src/io/event_loop.zig:259`, `src/io/event_loop.zig:1485`, `src/io/peer_policy.zig:97`, `src/io/protocol.zig:355`
- No-copy seed batching: `src/io/seed_handler.zig:26`, `src/io/seed_handler.zig:192`, `src/io/seed_handler.zig:271`, `src/io/event_loop.zig:1507`
- `/sync/maindata` arena and fixed snapshot keys: `src/rpc/sync.zig:23`, `src/rpc/sync.zig:206`, `src/rpc/handlers.zig:1186`, `src/rpc/handlers.zig:1196`
- Allocation-free BEP 10 / ut_metadata decode: `src/net/extensions.zig:140`, `src/net/ut_metadata.zig:102`
- Dense active peer slot scans: `src/io/event_loop.zig:466`, `src/io/event_loop.zig:1382`, `src/io/event_loop.zig:1391`, `src/io/peer_handler.zig:76`, `src/io/utp_handler.zig:257`, `src/io/protocol.zig:444`

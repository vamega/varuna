# 2026-04-01: API steady-state header and upload-buffer reuse

## What changed

- Added inline response-header storage to each `ApiClient`, plus shared `responseHeaderLength()` / `writeResponseHeader()` helpers so standard responses no longer allocate a transient header slice before `sendmsg`.
- Retained grown per-slot API receive buffers across disconnects up to `256 KiB`, so repeated upload-sized requests reuse the same body buffer instead of reallocating it every connection.
- Updated the API burst harness to send `Connection: close` explicitly. Once the production server correctly honored HTTP/1.1 keep-alive by default, the old burst client would otherwise block waiting for EOF and stop measuring the intended short-lived-connection path.

## What was learned

- HTTP/1.1 keep-alive changes benchmark semantics unless the client is explicit. The original burst harness relied on implicit connection close, which stopped being true once the server became standards-compliant by default.
- The remaining API allocator churn was narrower than it first looked. Standard GETs were bottlenecked by one small response-header allocation; uploads were bottlenecked by request-buffer growth being thrown away on every disconnect.
- A bounded retention policy is enough here. Reusing up to `256 KiB` per API slot captures the measured upload workload without letting one oversized request pin a multi-megabyte buffer indefinitely.

## Measured result

- `zig build -Doptimize=ReleaseFast perf-workload -- http_response --iterations=5000`
  before: `5,001` allocs, `648 KB` transient bytes, `4.63e7 ns`
  after: `1` alloc, `8 KB` transient bytes, `1.80e6 ns`, repeat `1.77e6 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_burst --iterations=4000 --clients=8`
  before: `4,000` allocs, `512 KB` transient bytes, `~2.20e8 ns`
  after: `0` allocs, `0` transient bytes, `230834588 ns`, repeat `212902689 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_seq --iterations=4000 --clients=8`
  previous keep-alive result: `95649970 ns`, `87088833 ns`
  after: `73276685 ns`, repeat `79175258 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`
  before: `2,000` allocs, `65.78 MB` transient bytes, `~1.26e8 ns`
  after: `8` allocs, `525 KB` retained bytes, `123901066 ns`

## Remaining work

- Uploads above the retained cap still allocate on demand. That is fine for now; only revisit it if real API traces show sustained large uploads.
- Oversized response headers still fall back to heap allocation. If real handlers start producing that shape frequently, raise the inline cap based on measurement instead of guessing.

## Code references

- [src/rpc/server.zig:10](/home/vmadiath/projects/varuna/src/rpc/server.zig#L10)
- [src/rpc/server.zig:279](/home/vmadiath/projects/varuna/src/rpc/server.zig#L279)
- [src/rpc/server.zig:351](/home/vmadiath/projects/varuna/src/rpc/server.zig#L351)
- [src/rpc/server.zig:563](/home/vmadiath/projects/varuna/src/rpc/server.zig#L563)
- [src/perf/workloads.zig:717](/home/vmadiath/projects/varuna/src/perf/workloads.zig#L717)
- [src/perf/workloads.zig:965](/home/vmadiath/projects/varuna/src/perf/workloads.zig#L965)

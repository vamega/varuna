# Remove Synchronous HTTP Client

## What changed and why

- Deleted the old synchronous HTTP network client and removed the root export so new code cannot import it through `varuna.io`.
- Reduced `tracker/announce.zig` to shared tracker request/response helpers: URL construction, response parsing, and response cleanup. Production HTTP announces already run through `TrackerExecutor` and `HttpExecutor`.
- Removed the perf scenarios that depended on the deleted client. Kept `tracker_http_reuse_potential` as a manual keep-alive socket benchmark and `tracker_announce_executor` as the production async announce benchmark.
- Moved the DNS connect-failure invalidation regression onto the async executor by testing the executor completion path directly.
- Updated active status / design docs so current documentation points at `HttpExecutor` for HTTP tracker and web-seed I/O.

## What was learned

- The production split is now cleaner: tracker announce owns BEP request/response shape, while the daemon owns network execution through async executors.
- `zig build` caught one benchmark cleanup issue after the fresh synchronous-client scenario was removed: the retained reuse-potential benchmark no longer needed an allocator parameter.
- The old DNS regression could be preserved without a real blocking socket by directly driving `httpConnectComplete` with `error.ConnectionRefused`.

## Verification

- `nix shell nixpkgs#zig_0_15 --command zig fmt src/io/root.zig src/io/http_parse.zig src/tracker/announce.zig src/perf/workloads.zig src/io/http_executor.zig src/io/dns_threadpool.zig`
- `nix shell nixpkgs#zig_0_15 --command zig build --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build test --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`

## Remaining issues or follow-up

- Historical progress reports were scrubbed of the exact deleted-client symbols while preserving past-state context.
- UDP tracker synchronous helpers remain separate work; they are not part of this HTTP-client deletion.

## Key code references

- `src/io/root.zig:26` exports `http_parse` / `http_executor` without the deleted synchronous HTTP module.
- `src/io/root.zig:44` guards against re-exporting the legacy synchronous HTTP module.
- `src/tracker/announce.zig:13` keeps tracker announce URL building.
- `src/tracker/announce.zig:44` keeps tracker response parsing.
- `src/io/http_executor.zig:1089` covers DNS cache invalidation on async connect failure.
- `src/perf/workloads.zig:62` keeps only the async and manual reuse-potential tracker HTTP benchmarks.

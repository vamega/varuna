# 2026-05-03 Simplification Cleanup

## What changed

- Removed the legacy blocking BEP 9 metadata fetch module. The daemon now imports only the API progress DTOs from `src/net/metadata_progress.zig`; live metadata download remains owned by `AsyncMetadataFetch`.
- Removed the blocking UDP tracker client (`fetchViaUdp`, global connection cache, blocking DNS/socket send/recv helpers). `src/tracker/udp.zig` now contains BEP 15 codecs, URL parsing, transaction IDs, compact peer parsing, and `ConnectionCache`; live network I/O stays in `UdpTrackerExecutor`.
- Folded the standalone wanted-completed-count cache tests into `src/torrent/piece_tracker.zig` and deleted the extra `tests/piece_tracker_cache_test.zig` target. The randomized cache BUGGIFY test remains separate.
- Removed two Phase 2B smoke tests that only proved type/enum instantiation, and updated the remaining deferred Phase 2B scenarios to describe the actual harness limitation: deterministic same-piece co-contribution.
- Shared the DNS cache implementation across threadpool, c-ares, and custom resolver backends by reusing `dns_custom/cache.zig` from all three.
- Updated live docs/status so they no longer describe removed blocking clients or obsolete scaffold gates as current architecture.

## What was learned

- `src/net/metadata_fetch.zig` had become dead except for the progress type consumed by `TorrentSession`; extracting `FetchProgress` let the old blocking client disappear cleanly.
- The UDP blocking client was only exercised by `tests/udp_tracker_test.zig`; production already used `UdpTrackerExecutor`, and the remaining packet/cache tests preserve the useful non-I/O coverage.
- The threadpool and c-ares DNS caches had the same ownership and eviction policy as the custom resolver cache, so sharing the data structure removed duplicated allocator/key-management code without changing resolver behavior.
- Validation on this aarch64 host needs an explicit sqlite search prefix because the checked-in `lib/libsqlite3.so` symlink points to `/usr/lib/x86_64-linux-gnu/libsqlite3.so.0`.

## Remaining issues

- The checked-in `lib/libsqlite3.so` symlink is host-specific and wrong for aarch64. Tests passed by using `--search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2`; fixing the repository-level sqlite discovery is separate from this cleanup.
- `tests/sim_smart_ban_phase12_eventloop_test.zig` still has two intentionally deferred scenarios. They need a harness control that can force same-piece co-contribution by multiple peers in those shapes.
- Dated progress reports and old planning docs still mention the removed blocking modules as history; those were left intact.

## Key references

- `src/net/metadata_progress.zig:3` - progress DTO extracted from the deleted blocking metadata module.
- `src/tracker/udp.zig:416` - UDP tracker source now transitions from URL parsing directly to packet/cache tests; the blocking client section is gone.
- `src/io/dns_custom/cache.zig:25` - shared DNS cache type used by custom, threadpool, and c-ares resolvers.
- `src/io/dns_custom/cache.zig:99` - absolute-expiry insertion helper for resolver compatibility tests and fixed-TTL backends.
- `src/torrent/piece_tracker.zig:903` - wanted-completed-count cache invariants now live inline with the implementation.
- `tests/sim_smart_ban_phase12_eventloop_test.zig:86` - remaining Phase 2B gate names the harness limitation rather than old task numbers.

## Verification

- `nix run nixpkgs#zig_0_15 -- fmt build.zig src/daemon/torrent_session.zig src/io/dns.zig src/io/dns_cares.zig src/io/dns_custom/cache.zig src/io/dns_threadpool.zig src/net/metadata_progress.zig src/net/root.zig src/net/ut_metadata.zig src/torrent/piece_tracker.zig src/tracker/udp.zig tests/sim_multi_source_eventloop_test.zig tests/sim_smart_ban_phase12_eventloop_test.zig tests/udp_tracker_test.zig`
- `nix shell nixpkgs#zig_0_15 --command zig build --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2 test-dns-custom test-metadata-fetch-shared test-metadata-fetch test-sim-multi-source-eventloop test-sim-smart-ban-phase12 test-piece-tracker-cache-buggify`
- `nix shell nixpkgs#zig_0_15 --command zig build --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2 test`

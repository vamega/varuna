# Async DNS Resolver with TTL Cache

**Date**: 2026-03-30

## What was done

Added a thread-safe DNS resolver (`src/io/dns.zig`) with TTL-based caching to eliminate blocking DNS lookups from the daemon's tracker paths.

### Problem

`getaddrinfo()` has no io_uring equivalent and was being called during tracker announce and scrape operations. While these calls already ran on background threads (not the event loop thread), two issues remained:

1. **HTTP path** (`src/io/http.zig`): spawned a new OS thread per DNS lookup -- wasteful when the same tracker hostname is resolved every 30-60 minutes.
2. **UDP path** (`src/tracker/udp.zig`): called `getaddrinfo()` inline with no timeout, risking indefinite blocking if DNS was slow.
3. **No caching**: every tracker request re-resolved DNS, even though tracker hostnames rarely change.

### Solution

Created `DnsResolver` (a small, mutex-protected cache) with:
- Numeric IP short-circuit (no syscall, no cache)
- 5-minute TTL, 64-entry capacity, oldest-entry eviction
- Background thread + 5-second timeout on cache miss
- Port override on cache hit (same host, different port returns correct address)

Integrated into the daemon:
- `TorrentSession` owns a `DnsResolver` shared across all announce/scrape calls for that torrent
- `fetchAutoWithDns` / `scrapeAutoWithDns` accept an optional resolver
- Original `fetchAuto` / `scrapeAuto` remain as convenience wrappers (no resolver, one-shot resolution)
- Event loop re-announce (peer_policy.zig) uses uncached `fetchAuto` since it runs infrequently

### Key files changed

- `src/io/dns.zig` (new) -- `DnsResolver` and `resolveOnce()`, 13 tests
- `src/io/http.zig` -- removed inline DNS code, uses `dns.zig` via optional `DnsResolver`
- `src/tracker/announce.zig` -- added `fetchAutoWithDns` accepting optional resolver
- `src/tracker/scrape.zig` -- added `scrapeAutoWithDns` and `scrapeHttpWithDns`
- `src/tracker/udp.zig` -- `resolveAddress` now delegates to `dns.resolveOnce()`
- `src/daemon/torrent_session.zig` -- owns `DnsResolver`, passes to all tracker calls
- `src/io/root.zig` -- exports `dns` module
- `docs/io-uring-syscalls.md` -- updated DNS notes, marked HTTP stack resolved

## What was learned

- `getaddrinfo()` can block for 30+ seconds on DNS failure (no default timeout in glibc). The 5-second timeout via `ResetEvent.timedWait` prevents this from stalling background threads.
- The cache must store addresses with port 0 or the original port and override on retrieval, because the same hostname may be used with different ports (e.g., scrape vs announce on different ports is unlikely but possible).
- Thread spawn per DNS request is surprisingly cheap on Linux (~50us), but the real cost is the glibc resolver holding locks and potentially doing nscd/systemd-resolved IPC. Caching avoids this entirely after the first lookup.

## Remaining work

- The event loop's background announce thread (peer_policy.zig) does not use the cached resolver because it has no reference to TorrentSession. This could be improved by threading a DnsResolver pointer through EventLoop, but the re-announce interval (30+ minutes) makes this low priority.
- UDP tracker paths do not use caching (they use `resolveOnce`). Could be improved if UDP trackers become more common.
- c-ares integration is documented as a future option for high-throughput DHT scenarios.

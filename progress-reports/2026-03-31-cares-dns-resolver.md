# c-ares DNS Resolver Backend

**Date**: 2026-03-31

## What was done

Added an alternative c-ares-based async DNS resolver, configurable at build time alongside the existing threadpool-based resolver.

### Build configuration

- New build option: `-Ddns=threadpool` (default) or `-Ddns=c-ares`
- When c-ares is selected, the build links against `libcares` (system library)
- Build options are passed to the code via a `build_options` module (first use of this pattern in the codebase)

### Architecture

```
src/io/dns.zig            -- public dispatch interface (reads build_options)
src/io/dns_threadpool.zig -- existing threadpool backend (extracted from dns.zig)
src/io/dns_cares.zig      -- new c-ares backend
```

Both backends expose identical public APIs:
- `DnsResolver.init(allocator) !DnsResolver`
- `DnsResolver.deinit(allocator)`
- `DnsResolver.resolve(allocator, host, port) !Address`
- `DnsResolver.invalidate(allocator, host)`
- `DnsResolver.clearAll(allocator)`
- `resolveOnce(allocator, host, port) !Address`

Both share the same cache behavior: 5-minute TTL, 64-entry max, LRU eviction.

### c-ares integration approach

The c-ares backend uses `epoll_wait()` on c-ares's internal DNS sockets rather than blocking a threadpool thread. Flow:

1. Call `ares_gethostbyname()` to start async DNS query
2. Call `ares_getsock()` to get fds c-ares wants monitored
3. Register those fds with an epoll instance
4. `epoll_wait()` with remaining timeout
5. On fd readiness, call `ares_process_fd()` to let c-ares process the response
6. c-ares invokes our callback with the resolved address

This avoids thread-per-lookup overhead -- useful for DHT scenarios with many concurrent lookups.

### Interface changes

- `DnsResolver.init()` now takes an `allocator` parameter and returns `!DnsResolver` (error union) to support c-ares initialization
- `TorrentSession.dns_resolver` changed from `DnsResolver` (default-initialized) to `?DnsResolver = null` (lazily initialized via `getDnsResolver()`)
- All call sites updated to use lazy initialization

## What was learned

- Zig's `@cImport` for c-ares headers should work straightforwardly; the c-ares API is fairly simple (init channel, gethostbyname, getsock, process_fd, destroy)
- The `ares_getsock()` function returns a bitmask where bit N indicates read interest on fd N, and bit N+MAXNUM indicates write interest -- slightly unusual API
- The system library name for linking is `cares` (not `libcares` or `c-ares`), producing `-lcares` which finds `libcares.so`
- Zig's `b.addOptions()` / `build_options` module is the standard way to pass build-time configuration to code

## Key files changed

- `build.zig:7-13` -- DnsBackend enum and `-Ddns` option
- `build.zig:18-19` -- build_options module creation
- `build.zig:27` -- build_options import added to varuna_mod
- `build.zig:50-52` -- conditional c-ares linking
- `src/io/dns.zig` -- rewritten as dispatch interface
- `src/io/dns_threadpool.zig` -- extracted threadpool backend (was dns.zig)
- `src/io/dns_cares.zig` -- new c-ares backend
- `src/daemon/torrent_session.zig:104,239,264-269` -- lazy DnsResolver init

## Remaining work

- **Testing with c-ares installed**: The c-ares backend compiles and links correctly when `libc-ares-dev` is installed, but needs integration testing on a system with the dev package
- **io_uring POLL_ADD integration**: The current c-ares backend uses epoll for fd monitoring. A future enhancement could use `IORING_OP_POLL_ADD` directly on c-ares fds for tighter event loop integration (requires the resolver to be aware of the Ring)
- **Timeout refinement**: c-ares has its own timeout mechanism (`ares_timeout()`); currently we use a simple deadline-based epoll timeout instead

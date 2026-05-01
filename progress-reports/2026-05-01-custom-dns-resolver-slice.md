# Custom DNS resolver slice

## What changed and why

Moved the custom DNS library from packet/query scaffolding toward a usable
resolver path.

- `QueryOf(IO)` now applies `bind_device` through the IO contract:
  `socket` completion -> `setsockopt(SO_BINDTODEVICE)` -> UDP `connect` ->
  DNS `send`. The interface-name option bytes live in the query state until
  the setsockopt completion fires.
- `QueryOf(IO)` now closes sockets through `io.closeSocket`, removing the
  direct `posix.close` dependency from the custom DNS state machine.
- `DnsResolverOf(IO).resolveAsync()` now owns `QueryOf(IO)` jobs for simple
  hostname lookup: numeric-IP fast path, cache lookup, A query first, AAAA
  fallback when A fails, CNAME follow-up, NXDOMAIN negative caching, and
  positive TTL caching.
- Added custom-DNS integration tests for bind-device ordering and
  resolver-level A lookup/cache behavior.

The daemon-facing `-Ddns=custom` dispatch remains transitional: HTTP and UDP
tracker executors still use the threadpool-compatible public `DnsResolver`
shape until the executor refactor moves them to the custom callback API.

## What was learned

`QueryResult.answers` carries a slice into `Query.answers_storage`, so the
resolver must consume/copy it before freeing the query. Also, completed
queries cannot be destroyed immediately inside their callback because
`deliver()` submits cancel completions for timers/in-flight ops that still
reference query-owned `Completion` fields. `ResolveJob` now retains completed
queries in a small fixed retired list and frees them when the caller destroys
the job after the event-loop drain.

## Remaining issues / follow-up

- Wire `HttpExecutorOf(IO)` and `UdpTrackerExecutorOf(IO)` to
  `DnsResolverOf(IO).resolveAsync()` when `-Ddns=custom`, replacing the
  eventfd/DnsJob pathway.
- Add a true SimIO resolver integration test now that `QueryOf(IO)` uses
  `io.closeSocket`.
- Implement DNS-over-TCP fallback for truncated UDP responses (`TC=1`).
- Tighten `ResolveJob` cancellation/destroy semantics before executor
  integration so abandoned jobs can be safely retired by slots.

## Verification

- `zig build test-dns-custom --summary failures`
- `zig build test-dns-custom -Ddns=custom --summary failures`
- `zig build --summary failures`
- `zig build test --summary failures`

All were run through `nix shell nixpkgs#zig_0_15 --command ... --search-prefix
/nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2` and passed.

## Key code references

- `src/io/dns_custom/query.zig:247` - bind-device `setsockopt` submission.
- `src/io/dns_custom/query.zig:297` - socket completion now sequences
  bind-device before DNS connect.
- `src/io/dns_custom/query.zig:637` - DNS socket cleanup routes through
  `io.closeSocket`.
- `src/io/dns_custom/resolver.zig:108` - resolver async result/job surface.
- `src/io/dns_custom/resolver.zig:147` - resolver starts a `QueryOf(IO)`.
- `src/io/dns_custom/resolver.zig:174` - query completion handling for
  A/AAAA fallback, CNAME, NXDOMAIN, and cache.
- `tests/dns_custom_integration_test.zig:499` - bind-device ordering test.
- `tests/dns_custom_integration_test.zig:572` - resolver-level lookup/cache
  test.

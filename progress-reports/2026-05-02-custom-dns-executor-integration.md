# Custom DNS executor integration

## What changed and why

Wired the HTTP and UDP tracker executors to the IO-contract-native custom DNS
resolver when built with `-Ddns=custom`.

- `HttpExecutorOf(IO)` and `UdpTrackerExecutorOf(IO)` now select
  `DnsResolverOf(IO)` at comptime for custom-DNS builds.
- Custom-DNS executor paths call `resolveAsync(host, port, ctx, callback)`
  directly and do not create or poll the eventfd/threadpool DNS job path.
- Threadpool and c-ares builds still use the existing public `DnsResolver`
  facade and eventfd-compatible `DnsJob` flow.
- Custom DNS completion uses a small slot-generation context so late callbacks
  do not resume a recycled slot.
- Completed custom DNS jobs are retired and destroyed on the next executor
  tick/destroy. If an executor is destroyed while a DNS query is still in
  flight, final executor destruction is now deferred until the custom resolver
  callback fires and the scripted timer/cancel completions have a chance to
  drain. This keeps the resolver storage alive for `ResolveJob.onQueryComplete`
  instead of leaving the job with a dangling `resolver` pointer.
- Added deterministic executor-level tests that prove HTTP and UDP tracker
  executors consume the custom resolver callback path with scripted DNS instead
  of relying on the threadpool/eventfd path.
- Added destroy-while-DNS-pending regression coverage for both HTTP and UDP
  tracker executors.

## What was learned

The public `dns.DnsResolver` facade intentionally remains threadpool-shaped in
`-Ddns=custom` for non-executor callers, so the clean integration point is a
small comptime split inside the executors. That keeps default and c-ares builds
on their existing public facade while allowing daemon tracker/web-seed paths to
use `DnsResolverOf(IO)` directly.

`ResolveJob.destroy()` is still safest after the event loop has had a chance to
drain cancel completions submitted by completed `QueryOf(IO)` jobs. The executor
therefore retires completed custom DNS jobs instead of destroying them inline in
the callback. For executor teardown, the executor itself must also remain alive
until the DNS callback because the job stores a pointer to the resolver.

## Remaining issues / follow-up

- Implement true custom DNS query cancellation for abandoned executor slots so
  teardown can actively cancel in-flight resolver IO instead of waiting for the
  pending DNS job to complete before final executor destruction.
- The legacy public `dns.DnsResolver` alias still uses the threadpool facade in
  `-Ddns=custom`; current daemon HTTP/UDP tracker executors bypass it, but other
  future daemon DNS users should either use `DnsResolverOf(IO)` or get an
  adapter.
- c-ares verification is blocked in this worktree by existing build plumbing:
  bundled mode cannot find generated `ares_build.h`, and system mode with a Nix
  c-ares package did not add the c-ares include path for `ares.h`.

## Verification

All successful commands were run through `nix shell nixpkgs#zig_0_15 --command`
with SQLite search prefix
`/nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`.

- `zig build test-dns-custom -Ddns=custom --summary failures` passed.
- `zig build test-dns-custom --summary failures` passed.
- `zig build --summary failures` passed.
- `zig build -Ddns=custom --summary failures` passed.
- `zig build test -Ddns=custom --summary failures` passed.
- `zig fmt .` ran after edits.

c-ares probes attempted:

- `zig build -Ddns=c_ares --summary failures` failed before executor compile
  coverage because `vendor/c-ares/include/ares.h` could not include
  `ares_build.h`.
- `zig build -Ddns=c_ares -Dcares=system --summary failures` with a Nix c-ares
  search prefix failed because `ares.h` was not found by the Zig C import.

## Key code references

- `src/io/http_executor.zig:37` - HTTP executor custom-vs-facade DNS type
  selection.
- `src/io/http_executor.zig:340` - HTTP custom resolver initialization.
- `src/io/http_executor.zig:528` - HTTP custom DNS `resolveAsync()` adapter.
- `src/io/http_executor.zig:573` - HTTP custom DNS callback and slot-generation
  guard.
- `src/io/http_executor.zig:351` - HTTP deferred custom-DNS destroy path.
- `src/tracker/udp_executor.zig:35` - UDP tracker custom-vs-facade DNS type
  selection.
- `src/tracker/udp_executor.zig:237` - UDP custom resolver initialization.
- `src/tracker/udp_executor.zig:471` - UDP custom DNS `resolveAsync()` adapter.
- `src/tracker/udp_executor.zig:516` - UDP custom DNS callback and
  slot-generation guard.
- `src/tracker/udp_executor.zig:248` - UDP deferred custom-DNS destroy path.
- `tests/dns_custom_integration_test.zig:650` - HTTP executor custom DNS
  regression test.
- `tests/dns_custom_integration_test.zig:704` - UDP tracker executor custom DNS
  regression test.
- `tests/dns_custom_integration_test.zig:757` - HTTP destroy-while-DNS-pending
  regression test.
- `tests/dns_custom_integration_test.zig:804` - UDP destroy-while-DNS-pending
  regression test.

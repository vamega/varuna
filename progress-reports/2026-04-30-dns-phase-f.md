# Custom DNS library — Phase F: build flag + dispatch + integration test

**Date:** 2026-04-30
**Branch:** `worktree-dns-phase-f-and-flakes`

## What changed and why

Lands the deferred Phase F of the custom DNS library
(`progress-reports/2026-04-29-custom-dns-library.md`): the
`-Ddns=custom` build-flag selector and a SimIO-style end-to-end
integration test driving `QueryOf(IO)` through scripted DNS server
responses.

The Phase A–E commit (`86d8fc3`) deliberately stopped at the library
foundation because a clean cut-over to the new resolver inside the
daemon's executors (`HttpExecutor` / `UdpTrackerExecutor`) requires
unwiring the threadpool's `eventfd-poll` async DNS path — a
substantially larger refactor that the engineer's report flagged as
"recommend the executor refactor as a separate round." This Phase F
ships the **build-flag and library-test** parts only, with a
transitional dispatch in `src/io/dns.zig`.

### Three commits

1. **`build: add -Ddns=custom backend selector`** — extends the
   `DnsBackend` enum with `custom` and updates the `-Ddns=` choice
   list. Build-flag mechanical change only.
2. **`dns: dispatch -Ddns=custom and re-export dns_custom library`**
   — `src/io/dns.zig` re-exports the custom library types as
   `pub const dns_custom = struct { ... }` so callers can drive
   `DnsResolverOf(IO)` directly with their own IO instance. The
   `DnsResolver` shape itself continues to alias the threadpool
   implementation under `.custom` until the executor refactor lands.
   The module docstring documents the gap; selecting the flag does
   not yet close the `bind_device` DNS leak.
3. **`tests: add Phase F integration test for custom DNS library`**
   — `tests/dns_custom_integration_test.zig` drives `QueryOf(IO)`
   end-to-end through a scripted in-process DNS server.

### Why the dispatch is transitional, not a full cut-over

The custom library's public surface is `DnsResolverOf(IO)` — generic
over the IO contract — while threadpool/c-ares export a concrete
`DnsResolver` parameter-free over IO. The async API also differs
fundamentally:

- threadpool: `resolveAsync(host, port, notify_fd: posix.fd_t)
  !AsyncResult { resolved | pending *DnsJob }`. Worker thread writes
  to `notify_fd` (an eventfd) when done; `HttpExecutor` /
  `UdpTrackerExecutor` register `dns_event_fd` with `IORING_OP_POLL_ADD`
  and process completions on the eventfd-poll callback.
- custom: `QueryOf(IO).start(params, ctx, callback)` — pure
  IO-contract callback shape, no eventfd / no thread pool.

Migrating the executors from one model to the other is the executor
refactor — not "extend the dispatch switch" sized work. Until that
lands, `-Ddns=custom` reuses threadpool semantics for the daemon's
async DNS path; the custom library is reachable through
`dns.dns_custom.*` for callers and tests that opt in.

### Why the integration test is `ScriptedIo`, not `SimIO`

The progress report's Phase F point #3 envisioned driving
`DnsResolverOf(SimIO)` end-to-end. SimIO can almost do this — it has
`enqueueSocketResult(fd)` and `pushSocketRecvBytes(fd, bytes)` for
exactly this scripted-peer pattern — but `query.zig`'s `closeSocket()`
calls `std.posix.close(self.socket_fd)` directly on the deliver path,
and `std.posix.close()` `unreachable`s on `EBADF`. SimIO's slot fds
are synthetic integers (1000+) that are not real OS fds, so a SimIO
fd reaching `posix.close()` would crash the test process.

The fix that would let SimIO drive the test cleanly is to add a
`close` op to the IO contract and switch `query.zig`'s direct
`posix.close` call. That's a separate change touching the contract
itself; out of scope for Phase F per the file-ownership boundaries
on this round.

The integration test's `ScriptedIo` test wrapper sidesteps the issue
by allocating a real `AF_UNIX` `SOCK_DGRAM` fd on every `socket()`
op — `posix.close()` succeeds at deliver time without ever touching
the network — while the recv path is fully scripted. Two FIFOs
(non-timer + timer) so pre-armed total-budget timeouts don't outrace
the real recv result that fires after socket → connect → send → recv.

Three test scenarios:

- **happy path** — A query resolves to `192.0.2.42` with TTL=600.
- **NXDOMAIN** — server responds with rcode=nx_domain; the parser
  surfaces `.nx_domain` to the caller's callback.
- **off-path-attacker txid mismatch** — wrong-txid response is
  silently dropped, recv is re-armed, query eventually fails with
  `.failed` when no valid response arrives. This is the
  cache-poisoning defense in `query.zig:processResponse`.

## What was learned

- **`std.posix.close()` on `EBADF` is `unreachable`, not an error
  return.** The ergonomics gap with SimIO synthetic fds is a real
  trap for test authors. The cleanest fix is to add a `close` op to
  the IO contract (so `query.zig` and any other test-faced
  resource-cleanup path can route through `self.io.closeSocket(fd)`
  with backend-specific handling). Out of scope for this round.
- **The custom library's public API is fundamentally different from
  threadpool/c-ares.** The team-lead brief's "verify the public
  DnsResolver API is identical to the threadpool / c-ares variants
  (they all conform to a common shape)" framing is wrong. The
  underlying engineer's progress report is the accurate reading:
  the executor refactor is a separate round.
- **Per-server timeout vs total-budget timeout, on separate
  completions.** `query.zig` arms the total-budget timeout *before*
  the first `socket()` submission, and the per-server timeout
  *after* `submitRecv`. The integration test's two-FIFO design is
  the cleanest way to model "timers are armed but don't fire unless
  explicitly advanced" without dragging in SimIO's full clock model.

## Remaining issues / follow-up

- **The executor refactor.** `HttpExecutor` and `UdpTrackerExecutor`
  still use the threadpool's `eventfd-poll` async DNS pathway when
  `-Ddns=custom` is selected. Migrating them to drive
  `DnsResolverOf(RealIO)` via the IO contract callback shape closes
  the `bind_device` DNS leak entirely. Estimated 2-3 days of work
  including the eventfd unwiring, the `DnsResolver` API merger
  (sync `resolve` and async `resolveAsync` semantics on top of the
  callback-based custom library), and the test pass.
- **Add a `close` op to the IO contract.** Lets `query.zig` and
  other paths route resource cleanup through the IO backend so
  full SimIO-driven tests become viable. Estimated 0.5 day.
- **TCP fallback on TC=1.** Still deferred from Phase B; not
  blocking for typical BitTorrent workloads since trackers /
  web-seed URLs almost never exceed 512-byte UDP responses after
  CNAME follow.
- **Happy-eyeballs (RFC 8305).** Race A and AAAA queries; not v1.

## Key code references

- Build flag enum: `build.zig:1308` (`DnsBackend.custom`).
- Dispatch: `src/io/dns.zig:38` (re-export) and `src/io/dns.zig:54`
  (transitional alias for `.custom`).
- ScriptedIo wrapper: `tests/dns_custom_integration_test.zig:55`
  — two-FIFO design (non-timer + timer queues), real-OS-fd socket
  allocation, scripted recv consumption.
- DNS response builders: `tests/dns_custom_integration_test.zig:217`
  (A response) and `tests/dns_custom_integration_test.zig:265`
  (NXDOMAIN response).

## Test count delta

| Suite | Before | After | Delta |
|---|---|---|---|
| Phase F integration tests | 0 | 4 | +4 |

(`DnsResolverOf instantiates against ScriptedIo` compile-check, plus
the three Query-driven scenarios above.)

## Commit graph

```
019de0c tests: add Phase F integration test for custom DNS library
8c574db dns: dispatch -Ddns=custom and re-export dns_custom library
16a6cd7 build: add -Ddns=custom backend selector
```

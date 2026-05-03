# Custom DNS Library — Design + Recommendation

**Status:** research / pre-implementation. Read-only audit of the current
DNS surface plus a sketch of a varuna-native replacement for c-ares.

**Recommendation (TL;DR):** **Build a custom DNS library** that lives
inside the IO contract. ~600–1200 LOC. Fully BUGGIFY-able through SimIO,
identical wiring on all production backends, no per-backend bridge
required. The parser is the cost — but BitTorrent's DNS workload only
needs a small fraction of c-ares' surface, and the parser is the same
shape (length-prefix, defensive bounds, no recursion) as the bencode /
KRPC / ut_metadata code we have already audited four times.

See §6 for the full justification.

---

## §1 — Current State

### Call-site inventory

`grep -n 'getAddrList\|getAddressList\|c_ares\|cares\|DnsResolver\|resolveAsync\|resolveOnce' src/`
turns up three live places where a hostname becomes an `std.net.Address`:

| # | File:line | Caller / code path | Hostname source | Sync vs async | Where it runs | Notes |
|---|-----------|--------------------|-----------------|---------------|---------------|-------|
| 1 | `src/dht/bootstrap.zig:29` | `resolveBootstrapNodes` | 4 hard-coded bootstrap nodes (`router.bittorrent.com`, `dht.transmissionbt.com`, `router.utorrent.com`, `dht.libtorrent.org`) | **blocking `getAddressList`** | startup, main thread, **before** event loop runs (`src/main.zig:152`) | A/AAAA collected; one of each kept (BEP 32 dual-stack). Skipped if persisted DHT table already has ≥ 8 nodes. |
| 2 | `src/io/http_executor.zig:437` | Tracker HTTP / HTTPS announces + web seed range fetches | tracker URL host or BEP 19 web-seed URL host | **`DnsResolver.resolveAsync`** with eventfd notify | event-loop thread (the threadpool runs on background threads, eventfd wakes the ring) | One shared `DnsResolver` per `HttpExecutor`. Cached results re-used by every announce / scrape / web-seed range. |
| 3 | `src/daemon/udp_tracker_executor.zig:327` | UDP tracker (BEP 15) connect + announce + scrape | UDP tracker URL host | **`DnsResolver.resolveAsync`** with eventfd notify | event-loop thread (same shape as HttpExecutor) | One `DnsResolver` per `UdpTrackerExecutor`. |

Plus the threadpool's worker function itself
(`src/io/dns_threadpool.zig:358`) and the one-shot helper
(`src/io/dns_threadpool.zig:458`). These are the only places that touch
glibc's `getaddrinfo`.

The peer-wire path (`src/net/peer_wire.zig`,
the async metadata fetch state machine, `src/net/utp_manager.zig`) takes
`std.net.Address` directly — peer addresses come from trackers,
DHT compact-peer responses, and PEX. **Peers are never looked up by
hostname.** This is the most important fact in the audit: DNS only
happens at the tracker / web-seed / DHT-bootstrap edge, which is a small
finite set of hostnames per torrent.

### Backend dispatch (`src/io/dns.zig`)

`DnsResolver` is a build-time alias:

- `-Ddns=threadpool` (default) → `src/io/dns_threadpool.zig`. Pre-spawned
  pool of 4 worker threads, max 16 pending jobs, blocking `getaddrinfo`.
  Eventfd notification back to the ring.
- `-Ddns=c-ares` → `src/io/dns_cares.zig`. c-ares channel; on cache
  miss, the resolver creates an `epoll_create1` instance, asks c-ares
  which fds it wants polled (`ares_getsock`), waits on them, drives
  c-ares with `ares_process_fd`, retrieves the result via the
  `caresCallback`. **Currently uses `epoll`, not `io_uring`** — a bridge
  that submits `IORING_OP_POLL_ADD` against the c-ares fds is the
  STATUS.md "next" item that started this research round.

Both backends share the same TTL cache (5 min, 64 entries, mutex,
LRU-by-expiry eviction).

### `vendor/c-ares/`

`vendor/c-ares/src/` totals **~44,929 lines** of C across **98 .c/.h
files**, plus **~3,056 lines** of public headers. The `-Dcares=bundled`
build path compiles all of it; `-Dcares=system` links the OS package.
On Linux this is fine. On any non-Linux target it's a substantial
vendoring chore. Note that the `varuna` daemon is Linux-only by
[scope](#) — but the IO contract (and `KqueueIO` MVP) means the code
already works on Darwin for development, and the `-Dio=kqueue` /
`-Dio=epoll` builds skip daemon installation but still build the
library + tests. c-ares is the heaviest single dependency that follows
those builds.

### Quantification — DNS calls per daemon lifecycle

For a daemon that holds, say, 500 torrents on 50 distinct trackers + 10
web-seed hosts:

- **Startup:** 0–4 bootstrap-node lookups (skipped if `nodeCount() >= 8`
  from the persisted table), so roughly **4 cold** in the very-first-run
  case, **0 cold** after that.
- **First announce per tracker:** 50 cold lookups (one per distinct
  tracker host), serialised through the threadpool's 4 workers.
- **Re-announces (every 30–60 minutes):** all cache hits with the
  default 5-min TTL. We re-resolve at TTL expiry. So about **50 lookups
  per 5 minutes** = ~600/hour even though cached. (The cache TTL is
  shorter than the announce interval — we actually do re-resolve before
  every announce in steady state, since 5 min < 30 min).
- **Web seeds:** lookups per distinct web-seed host, same caching.
- **uTP / TCP peer connects:** **0** (peers are addresses, not hostnames).
- **DHT KRPC:** **0** (the DHT routing table holds compact node
  addresses; only bootstrap takes hostnames).

**Steady-state:** on the order of **tens of lookups per hour** with the
existing cache. A 5-minute TTL is conservative; raising it would push the
rate down further. **Bursty:** the 50-tracker first-announce window at
process start; this is the only place the threadpool's queue might
pressure (it has 16 slots and 4 workers).

The DHT case the c-ares backend was sized for ("hundreds of concurrent
DNS lookups") **does not exist in our DHT** because DHT bootstrap is the
only hostname-shaped operation; everything else is compact peer
addresses. The c-ares backend is over-engineered for our actual
workload.

---

## §2 — What does BitTorrent actually need from DNS?

| Feature | Needed? | Why |
|---|---|---|
| **A (IPv4)** | **yes** | Every tracker, web seed, DHT bootstrap node. |
| **AAAA (IPv6)** | **yes** | Same set of names, IPv6 endpoints when present. BEP 32 (dual-stack DHT) calls for both. |
| **CNAME chain following** | **yes** | Many trackers / web seeds resolve through CDNs (CloudFront, Fastly). Standard resolvers (`getaddrinfo`, c-ares) follow CNAMEs transparently. |
| **NXDOMAIN distinction** | **yes** | We need to surface "tracker hostname doesn't exist" vs. "network failure". The current `error.DnsResolutionFailed` collapses these; that's already a (mild) regression vs. real `getaddrinfo`. |
| **Multiple servers from `/etc/resolv.conf`** | **yes** | If the first nameserver doesn't answer, fall back to the second / third. |
| **`search` / `ndots` from resolv.conf** | **no, in practice** | Trackers and DHT bootstrap nodes ship as FQDNs (the trailing-dot or three-or-more-dots case). We can implement `ndots:1` semantics safely (treat any name with a dot as absolute) and skip search lists entirely for the BitTorrent workload. |
| **`/etc/hosts`** | **yes-ish** | Cheap, helps tests and odd setups. ~30 LOC. |
| **TXT, SRV, MX, PTR, NAPTR, SOA, …** | **no** | Not used by any BEP that varuna supports. |
| **DNSSEC validation** | **no** | We never validate. Same as c-ares' default (it doesn't validate either unless explicitly configured). Trust boundary: whatever resolv.conf points at. Document this. |
| **EDNS0** | **maybe** | Allows >512-byte UDP responses; without it, the server truncates with TC=1 and we have to fall back to TCP. Most modern DNS responses for tracker A/AAAA fit in 512 bytes; CNAME-heavy CDN responses can exceed it. **Worth implementing** with a 1232-byte UDP buffer (the consensus EDNS payload size). Maybe ~30 extra LOC. |
| **DNS-over-TCP** | **rarely** | Required when the server sets TC=1 (truncated). Implement, but it can be a small fast path. |
| **DNS-over-TLS / DNS-over-HTTPS** | **no** | Out of scope for BitTorrent. If the user wants encrypted DNS, configure the system resolver. |
| **Caching with TTL** | **yes** | Already have this; keep the 5-min/64-entry shape. Use the response's authoritative TTL when available (capped at 5 min). |
| **Concurrent queries** | **yes** | Tracker burst + web seed lookups need to overlap. Already fine: the IO contract handles this naturally with multiple `Completion`s. |
| **Source-port randomization, txid randomization** | **yes** | Cache poisoning defense. Cheap. |
| **Happy-eyeballs (RFC 8305)** | **nice-to-have** | Race A and AAAA, prefer the first that connects. Not critical for trackers (we'd just take the first record returned anyway), but useful. ~50 LOC if added. **Not required for v1.** |
| **`/etc/nsswitch.conf`** | **no** | We commit to a `dns` lookup. We don't need to consult `mdns_minimal` / `winbind` / etc. |

The **must-have set** is small: A + AAAA + CNAME chain + NXDOMAIN + UDP
with retry across resolv.conf servers + EDNS0 + TCP fallback + cache.
That's the entire DNS surface for BitTorrent.

c-ares ships ~45 KLoC of code to support TXT, SRV, MX, PTR, NAPTR, SOA,
DNSSEC trust-anchor handling, channel-level rebinding when network
state changes, AppleSDK / ChannelOptions / ARES_OPT_*, c-ares' own
threading abstraction, ares_dns_record API, …. **Well over 90% of
c-ares is unused** by varuna.

---

## §3 — Sketch of `varuna-native` DNS

### Module location

New `src/dns/` subdirectory:

```
src/dns/
  root.zig                 // module test entry point
  resolver.zig             // DnsResolver — public API; cache; resolv.conf
  message.zig              // DNS wire format encode/decode
  query.zig                // per-query state machine (UDP, retransmit, TCP fallback)
  resolv_conf.zig          // /etc/resolv.conf parser (~50 LOC)
  hosts.zig                // /etc/hosts lookup (~30 LOC, optional)
```

The existing `src/io/dns.zig` is preserved as a *façade* until we delete
the c-ares backend; it forwards to `dns/resolver.zig`.

### Public API — async, IO-contract-shaped

```zig
pub const DnsResolverOf = fn (comptime IO: type) type {
    return struct {
        const Self = @This();

        // ── Configuration ──
        pub const Config = struct {
            // Caps + timeouts. All have safe defaults.
            cache_capacity: u16 = 64,
            cache_min_ttl_s: u32 = 30,
            cache_max_ttl_s: u32 = 300,
            per_query_timeout_ms: u32 = 1500,    // Per-server attempt.
            total_timeout_ms: u32 = 5000,        // Across all servers.
            servers: ?[]const std.net.Address = null,    // Override resolv.conf.
        };

        // ── Lifecycle ──
        pub fn init(allocator: Allocator, io: *IO, config: Config) !Self;
        pub fn deinit(self: *Self) void;

        // ── Async resolve (the only callsite shape) ──
        pub const ResolveOp = struct {
            host: []const u8,
            port: u16,
            // Return preference: .both, .a_only, .aaaa_only, .either.
            family: AddressFamily = .both,
        };

        pub const Result = union(enum) {
            resolved: std.net.Address,            // First A or AAAA.
            both: struct { a: ?Address, aaaa: ?Address },
            err: anyerror,                        // NoSuchHost, Timeout, ServerFailure, …
        };

        pub fn resolve(
            self: *Self,
            op: ResolveOp,
            completion: *DnsCompletion,
            userdata: ?*anyopaque,
            callback: *const fn (?*anyopaque, *DnsCompletion, Result) void,
        ) !void;

        // ── Sync helpers (numeric IP fast path) ──
        pub fn parseNumericIp(host: []const u8, port: u16) ?std.net.Address;

        // ── Cache management ──
        pub fn invalidate(self: *Self, host: []const u8) void;
        pub fn clearAll(self: *Self) void;
    };
};
```

`DnsCompletion` is a small struct that *contains* the IO-contract
`Completion` plus the per-query state machine state. The DNS resolver
owns the underlying UDP socket and the in-flight queries; callers just
embed a `DnsCompletion` and submit.

### Resolution flow (UDP, single host, single record type)

```
resolve()
  → numeric IP? -> immediately fire callback with .resolved.
  → cache lookup (fresh? -> immediately fire callback).
  → choose a transaction id (rng), build A query packet, build AAAA query.
  → io.socket(.{ .domain = AF_INET, .sock_type = DGRAM | NONBLOCK }, ...)
  → io.connect(socket, server[0])  // UDP "connect" -> just sets dest.
  → io.sendmsg(socket, query_a)    // submit both A and AAAA in parallel.
  → io.sendmsg(socket, query_aaaa)
  → io.recvmsg(socket, recv_buf, timeout = per_query_timeout_ms)
  → parse(recv_buf):
      - mismatched txid? drop, re-arm.
      - TC=1 (truncated)? -> close UDP, retry over TCP.
      - NXDOMAIN? cache negative for cache_min_ttl_s, fire callback.
      - SERVFAIL / NOERROR with no answer? try next server.
      - answer? extract A/AAAA, follow CNAME chain (max 8 hops).
  → on per-query timeout: try next server.
  → on total timeout: fire callback with error.DnsTimeout.
  → cache result with min(answer_ttl, cache_max_ttl_s).
  → fire callback with .resolved or .both.
```

Every arrow that says `io.x()` is the IO contract — no direct syscalls,
no special-case code per backend. **The same module works under
`RealIO`, `EpollIO`, `KqueueIO`, and `SimIO` with no changes.**

### Wire format (DNS message)

DNS wire format (RFC 1035, RFC 3596) is small:

- **Header:** 12 bytes — txid, flags, qdcount, ancount, nscount, arcount.
- **Question:** name (length-prefixed labels, terminated by 0x00) + qtype (2 bytes) + qclass (2 bytes).
- **Resource Record:** name + type + class + ttl + rdlength + rdata.
- **Compression pointers:** a label that starts with two high bits set
  (`0xC0`) is a 14-bit pointer back into the message. Compression makes
  CNAME chains compact but is the #1 source of historical DNS parser bugs.

Conservative LOC budget for the parser:

| Component | LOC |
|---|---|
| Header encode/decode | 30 |
| Question encode/decode | 40 |
| RR decode (with compression) | 80 |
| Compression-pointer follower (with cycle / depth cap) | 30 |
| CNAME chain following | 40 |
| Encode A query, AAAA query | 30 |
| Top-level parser entry + length checks | 50 |
| Tests inline (round-trip + adversarial) | 200 |

**~500 LOC** for `message.zig` + tests. Plus ~150 for `query.zig` and
~100 for `resolver.zig` + ~50 for `resolv_conf.zig` + ~30 for `hosts.zig`
= **~830 LOC total** in a generous estimate. With tests, **maybe 1000–1200
LOC**. Compared to c-ares' 45 KLoC, this is a **~40× reduction** in the
code we own / audit / build.

### Caching

Keep the existing `StringHashMapUnmanaged(CacheEntry)` shape from
`dns_threadpool.zig`. Two additions:

1. **Per-record TTL** taken from the response (capped at
   `cache_max_ttl_s`, floored at `cache_min_ttl_s`). Replaces the fixed
   5-minute TTL.
2. **Negative caching** — `NXDOMAIN` and `SERVFAIL` cached for
   `cache_min_ttl_s` so a misconfigured tracker URL doesn't pummel the
   resolver. Same key shape; CacheEntry tagged union.

### Retransmission

Per-server attempt: send query, wait `per_query_timeout_ms`, give up,
move to next server. After all servers fail in one round, the total
timeout closes out. No exponential backoff — DNS responses are typically
< 50 ms; we'd rather try the next server fast than back off.

### resolv.conf parsing

`/etc/resolv.conf` is line-oriented: `nameserver <ip>`, `options ndots:N`,
`search <list>`, `domain <name>`. We need only `nameserver`. Default to
`127.0.0.53` (systemd-resolved) and `8.8.8.8` if the file is missing.
Re-parse periodically? — no. The daemon is long-lived but DNS server
changes are rare enough to warrant a daemon restart.

### Cross-backend portability

Every primitive used (`socket`, `connect`, `sendmsg`, `recvmsg`,
`timeout`, `cancel`) is already in `io_interface.zig` and implemented by
all production backends (`RealIO`, `EpollIO`, `KqueueIO`) and by `SimIO`.
**No per-backend code.** The team-lead brief mentions a future split into
five backends (epoll_posix / epoll_mmap / kqueue_posix / kqueue_mmap +
io_uring); that split is invisible to the DNS module because it operates
above the IO contract.

---

## §4 — Security considerations

This is the cost side of the trade. We just spent four rounds (round 1–4
audits) hardening untrusted-input parsers. **A custom DNS parser is a
fresh attack surface.** The shape is the same — length-prefixed bytes,
explicit recursion, type-tagged dispatch — and so the audit machinery
transfers, but we have to do the audit and we have to do the BUGGIFY
fuzz.

### Threat model

DNS responses are untrusted input. Two adversaries:

1. **Off-path attacker** racing legitimate responses. Defenses:
   randomized 16-bit txid + randomized source port (28 bits of entropy
   combined). c-ares does this; we must match.
2. **On-path attacker** (or an attacker who controls the resolver). They
   can deliver arbitrary bytes. Defenses are entirely parser correctness.

### Specific bugs to design out

| Bug class | Mitigation | Reference |
|---|---|---|
| **Compression-pointer infinite loop** | Track visited offsets in a `bitset[message_size]`; refuse to follow a pointer to an already-visited offset. Alternative: cap pointer-following depth at 8 and require strict-decrease (pointer must point earlier in the message). The strict-decrease form is what BIND ships. | Classic CVE pattern: CVE-2017-15087 (knot), CVE-2019-12519 (musl), countless others. |
| **Length-prefix overflow** | Saturating-subtraction form: `if (label_len > data.len - i) return error.MalformedDnsMessage;`. Same shape that landed in `krpc.parseByteString` (`progress-reports/2026-04-26-krpc-hardening.md` finding #1). Apply at every length-prefixed read: label, RR rdlength, message length over TCP. | Same bug class as KRPC #1, #4. |
| **CNAME chain loops / oversize** | Cap CNAME hops at 8. Refuse zero-hop loop (CNAME points to self). Allocate the hop count *outside* the parsed message memory — do not trust the response's count fields. | Classic. RFC 1034 §5.2.2. |
| **Label length over 63** | RFC 1035 caps label length at 63 octets (the high two bits 0b11 encode a compression pointer; 0b00 is a normal label). Reject `len > 63` at parse time. | Trivial; reject. |
| **Total name length over 255** | RFC 1035 caps the wire-format name length at 255 octets. Track the running length; reject. | Trivial; reject. |
| **rdlength > remaining message** | `if (rdlength > data.len - cursor) return error.MalformedDnsMessage;` — same saturating-subtraction. | Same shape. |
| **answer count beyond what fits** | Refuse to allocate based on `ancount`. Iterate, advancing the cursor; if the cursor would advance past the end, reject. | Saturation. |
| **Adversarial UDP source** | Verify the response source address matches the queried server and the response port matches the query source port. UDP `connect()` enforces this at the kernel level. | Already handled by UDP connect-then-send. |
| **TCP message-length-prefix overflow** | DNS-over-TCP is `u16 length-prefix + DNS message`. Same length-prefix-overflow defense; cap at 65535 (the prefix max). | Saturation. |
| **Cache poisoning via mismatched answer** | The answer's question section MUST equal the query's question. Verify before accepting. c-ares does this. | Standard. |
| **EDNS0 OPT record handling** | If we send EDNS0, we must accept (and ignore unknown options in) OPT in the response. Don't mis-parse OPT as a normal RR. | RFC 6891. |
| **DNSSEC validation absence** | **Documented limitation.** We trust the resolver. Same as c-ares' default mode. Mention prominently in `docs/io-uring-syscalls.md`. | Doc-only. |

### Test contract — mirror the KRPC hardening shape

`tests/dns_buggify_test.zig` (new):

- **Encoder error paths**: every encoder returns `error.NoSpaceLeft` on
  every buffer size below the minimum. Same shape as
  `tests/dht_krpc_buggify_test.zig`.
- **Length-prefix overflow**: labels with claimed length > buffer size,
  with `maxInt(u8)` length, with truncated-at-prefix input. All return
  `error.MalformedDnsMessage`.
- **Compression-pointer cycle**: synthesize a message where pointer at
  offset 12 points to offset 12 (self-loop). Refuse cleanly.
- **Compression-pointer forward**: pointer points past `data.len`.
  Refuse cleanly.
- **Compression-pointer-to-pointer chain**: point at a pointer that
  points at a pointer (depth 9, exceeds cap). Refuse cleanly.
- **CNAME loop**: response with a CNAME chain that loops back. Refuse
  cleanly.
- **Truncated message**: every message length from 0 to a known-good
  length minus 1. All reject without panicking.
- **Mismatched txid**: response with the wrong txid is silently dropped
  (re-arm recv); does *not* clobber state.
- **Mismatched question**: response txid matches but question section
  differs. Reject (cache-poisoning defense).
- **Adversarial fuzz**: 32 × 256 random byte sequences fed to the
  parser. Asserts: no panic, no stuck-loop (uses a step counter cap).

The same `injectRandomFault` BUGGIFY harness used for AsyncRecheck and
KRPC parsing applies directly: every IO submission goes through SimIO,
so we can inject `error.OperationCanceled`, short reads, malformed
bytes, etc., and assert the resolver recovers cleanly. **This is a
direct benefit of being inside the IO contract.**

### Source-port + txid randomization

`std.crypto.random.intRangeAtMost(u16, 0, 0xFFFF)` for the txid. For the
source port, we need an ephemeral port; the kernel assigns one when the
UDP socket binds. To get true source-port randomization (the kernel can
assign sequentially under load), we'd issue `IP_BIND_ADDRESS_NO_PORT`
+ random `bind()` to a port in the ephemeral range. **For v1, accept the
kernel's default port assignment** (still ~16 bits of entropy per RFC
6056) and document this; tighten later if a tracker / web seed becomes a
known attack vector. c-ares doesn't do better in default mode either.

---

## §5 — c-ares io_uring integration alternative

The other path on the table: keep c-ares but bridge it onto io_uring
properly (and into SimIO somehow).

`STATUS.md:279` notes: *"c-ares io_uring integration: proof-of-concept in
`~/projects/c-ares` — native io_uring event engine with SENDMSG/RECVMSG
for DNS queries (zero direct syscalls). Could replace varuna's DNS
threadpool to eliminate background-thread DNS."*

### What that would look like

- Patch / fork c-ares to expose its socket-event hooks more cleanly than
  `ares_getsock`. Or use the existing hooks but feed them via
  `IORING_OP_POLL_ADD` rather than `epoll_wait`. The current
  `dns_cares.zig` implementation uses epoll; replacing the inner
  `epoll_wait` with `io.poll(POLL_IN, ...)` is a few-line patch but
  re-introduces the epoll-vs-io-uring split (epoll_wait is itself a
  blocking syscall outside the daemon's ring policy).
- `SimIO` integration: no good story. c-ares opens its own UDP sockets
  with raw `socket(2)`. To intercept those, we'd need a hook layer that
  redirects c-ares' socket creation to SimIO's pool — that requires
  patching `ares_set_socket_functions()` and writing a thin shim. The
  shim is probably ~150 LOC, but its correctness is opaque (we'd be
  asserting that c-ares' state machine never calls a function we didn't
  shim). **BUGGIFY-style fault injection becomes a separate workstream**
  on top of that — we'd have to mock c-ares' socket layer to inject
  faults at the right granularity, which is exactly what SimIO already
  does for our own code.
- Multi-backend story: the c-ares-on-io_uring patch only covers
  `io_uring`. For `EpollIO` we'd revert to current `dns_cares.zig` (with
  its epoll loop). For `KqueueIO` we'd need a fresh kqueue integration.
  For SimIO we'd need the shim above. **Three separate per-backend
  bridges** (epoll, kqueue, sim) on top of the c-ares dependency itself.

### Trade-off summary

| Property | Custom DNS | c-ares + io_uring bridge |
|---|---|---|
| LOC owned | +1000–1200 | -0 (but +shim per backend) |
| Vendoring complexity | none | ~45 KLoC of C, plus build glue |
| Native io_uring path | yes | yes (with patch) |
| Epoll backend support | trivial | needs separate epoll bridge (current state) |
| Kqueue backend support | trivial | needs new kqueue bridge |
| SimIO BUGGIFY testability | trivial — every op is already inside the contract | requires socket-function-table shim, ~150 LOC, opaque correctness |
| Parser security surface | new — needs 1 round of audit + BUGGIFY harness | none |
| Maintenance burden | small — DNS protocol moves slowly | small — c-ares is mature, releases roughly twice a year |
| Day-1 readiness for `KqueueIO` / future mmap-epoll backends | yes | needs work for each |
| Cross-platform footprint | trivial | non-trivial (c-ares system package availability varies) |

The thing that tilts this is **SimIO testability + cross-backend
portability**, not raw LOC count. We have already paid for an IO
abstraction; pulling DNS into it is the obvious extension. c-ares fights
that abstraction — it has its own event loop, its own socket creation,
its own resource lifecycle. Every line of bridge we write is a line that
has to be re-audited against c-ares' next version.

---

## §6 — Recommendation

**Build the custom DNS library.** Replace c-ares entirely.

### Why

1. **The workload is narrow.** §1 quantification: the daemon does on the
   order of dozens of hostname lookups per hour, and only A / AAAA over
   UDP-with-TCP-fallback. c-ares' surface is at least 10× what we need.
2. **The IO-contract fit is exact.** §3 sketch: every DNS network
   primitive (`socket`, `connect`, `sendmsg`, `recvmsg`, `timeout`,
   `cancel`) is already in `io_interface.zig` and implemented by all
   four backends (`RealIO`, `EpollIO`, `KqueueIO`, `SimIO`). No per-
   backend bridge. No "the c-ares mock for SimIO" workstream.
3. **BUGGIFY testability is automatic.** Once the resolver lives inside
   the IO contract, the existing `SimIO.injectRandomFault` machinery
   (and `tests/recheck_live_buggify_test.zig` shape) tests it for free.
   Compare to c-ares-on-io_uring, where SimIO testability requires a
   custom socket-function-table shim and bespoke fault injection.
4. **The parser is small and matches code we already audit.** §3 LOC
   estimate: ~500 LOC for the wire format. Same shape as
   `bencode_scanner.zig`, `krpc.zig`, `ut_metadata.zig`. The
   round-1-through-round-4 hardening playbook (saturating-subtraction
   length-prefix bounds, explicit-stack recursion, fuzzed adversarial
   tests) maps directly. **One round of audit + a BUGGIFY harness; ~3
   days of work.**
5. **Vendoring goes away.** `vendor/c-ares/` (~45 KLoC of C, build glue
   for system / bundled split, header search-path machinery) deletes.
   Cross-compilation simplifies. The KqueueIO MVP and any future
   non-Linux dev builds stop needing to vendor c-ares.
6. **The threadpool path also goes.** No background thread for DNS, no
   eventfd notification dance, no `dns_threadpool.zig` ring-buffer of
   jobs. The `Allowed daemon exceptions` list in AGENTS.md drops "DNS
   without c-ares" — DNS *is* on io_uring.

### Implementation plan (out of scope for this round)

A subsequent implementation round, if and when this recommendation is
accepted:

1. **Phase A — `message.zig` + tests + audit.** Self-contained module,
   pure functions on byte slices, no I/O. Inline tests (round-trip,
   adversarial, compression-pointer hostility). One round of audit
   against the round-1-through-round-4 patterns. Land first; merge
   independently of the rest.
2. **Phase B — `resolv_conf.zig`, `hosts.zig`.** Tiny modules. Inline
   tests.
3. **Phase C — `query.zig` + `resolver.zig`.** The async state machine
   and the cache. Both are generic over `IO`. Inline tests against
   `SimIO`.
4. **Phase D — wire into `src/io/dns.zig` façade.** Switch the default
   backend from threadpool to custom; threadpool stays as a build option
   for the conservative path until c-ares is removed.
5. **Phase E — BUGGIFY harness.** `tests/dns_buggify_test.zig` —
   `injectRandomFault` + `FaultConfig` × 32 seeds against
   `DnsResolverOf(SimIO)` driven through `EventLoopOf(SimIO)`.
6. **Phase F — delete `dns_cares.zig`, drop `vendor/c-ares/`,
   simplify `build.zig` (remove `-Ddns=c-ares`, `-Dcares=...` options).**
   Probably 6–8 weeks after Phase A lands; keep c-ares as the build
   option for a transitional release in case a private-tracker pathology
   surfaces.

### Estimated effort

- Phase A + B: **2–3 days**.
- Phase C: **2–3 days**.
- Phase D: **1 day**.
- Phase E: **1–2 days**.
- Phase F: **0.5 day** (mechanical).

**Total: ~7–10 days** of focused work. The long pole is the audit +
BUGGIFY (Phases A and E).

### Why **not** the hybrid option

A hybrid (custom for the 95% case, fall back to c-ares for edge cases)
keeps both code paths alive forever. It pays the parser-audit cost
(custom path is still untrusted-input parsing) **and** the c-ares
maintenance cost. The whole point of going custom is to pay one cost
once. Reject the hybrid.

---

## Appendix A — Open questions

1. **How aggressive is cache invalidation on connect failure?** The
   existing `DnsResolver.invalidate()` is exposed but no caller invokes
   it. Should a failed tracker connect invalidate the DNS cache? If a
   tracker IP changes and we cache for 5 minutes, the next 4 minutes 59
   seconds of announces all fail. Cheap fix: have HttpExecutor /
   UdpTrackerExecutor call `invalidate()` after `error.ConnectionRefused`
   / `error.NetworkUnreachable` on the connect.
2. **Should we honor TTL > 5 min?** Right now we cap at 5 min. Trackers'
   own DNS TTLs are typically 5 min – 1 hour. Honoring up to 1 hour
   would slash the steady-state lookup rate, at the cost of taking
   longer to recover from a tracker IP migration. Probably OK; matches
   how a stub resolver with a long-lived process behaves.
3. **IPv6-only deployments.** If `/etc/resolv.conf` lists only IPv6
   nameservers, we need IPv6 UDP send. The `IO.sendmsg` path already
   handles AF_INET6; just confirm.
4. **Multiple addresses per tracker.** Today we keep the first
   `getAddressList` result. The current cache stores **one** address.
   Some trackers return multiple A records for load balancing; we
   should pick one randomly, or rotate on connect failure. Not a
   blocker; future tightening.
5. **Happy-eyeballs (RFC 8305) — really?** v1 ships without happy-
   eyeballs; we just take whichever record comes back first. If a user
   reports tracker connection latency under dual-stack with broken
   IPv6, revisit.
6. **What's the migration story for users on `-Ddns=c-ares` today?** They
   silently move to the custom backend. The build option stays
   (forwarding to threadpool or custom) for one release of grace
   period, then drops.
7. **Does the `hosts` file lookup matter?** Probably not in production —
   private trackers always use FQDNs that resolve through DNS — but
   tests benefit. Implementing it is ~30 LOC; cheap insurance.
8. **uTP / DHT — confirmed no DNS?** Re-checked: peers are addresses
   (compact node info from KRPC, compact peers from announce, PEX),
   never hostnames. uTP `connect` and `recv` go directly to addresses.
   No DNS in the peer-wire path. **Confirmed.**

---

## Appendix B — Reference: DNS audit patterns ported from KRPC

For the implementation engineer. Direct ports of the round-1
hardening patterns to DNS:

```zig
// KRPC pattern (src/dht/krpc.zig)
//   if (i + len > data.len) return error.InvalidKrpc;
// translates to:
//   if (len > data.len - i) return error.InvalidKrpc;
// for DNS we have many length-prefixed fields (label, rdlength, OPT length).

fn readLabel(data: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* >= data.len) return error.MalformedDnsMessage;
    const len = data[cursor.*];
    if (len > 63) return error.MalformedDnsMessage; // RFC 1035 §3.1.
    cursor.* += 1;
    if (len > data.len - cursor.*) return error.MalformedDnsMessage; // saturating.
    const label = data[cursor.* .. cursor.* + len];
    cursor.* += len;
    return label;
}

// KRPC `skipValue` recursion -> explicit-stack rewrite landed 2026-04-27.
// Compression pointer following has the same shape — use an explicit
// `visited: std.bit_set.IntegerBitSet(512)` (or sized to message length)
// and a hop counter capped at, say, 8. Refuse forward pointers (must
// strictly decrease).

fn followCompression(
    data: []const u8,
    start: u16,
    out: *NameWriter,
) !void {
    var visited = std.bit_set.IntegerBitSet(512).initEmpty();
    var pos: u16 = start;
    var hops: u8 = 0;
    while (true) {
        if (pos >= data.len) return error.MalformedDnsMessage;
        if (visited.isSet(pos)) return error.MalformedDnsMessage; // cycle.
        visited.set(pos);
        const b0 = data[pos];
        if (b0 == 0) return; // end of name.
        if (b0 & 0xC0 == 0xC0) {
            if (hops >= 8) return error.MalformedDnsMessage;
            hops += 1;
            if (pos + 1 >= data.len) return error.MalformedDnsMessage;
            const new_pos = ((@as(u16, b0 & 0x3F) << 8) | data[pos + 1]);
            if (new_pos >= pos) return error.MalformedDnsMessage; // strict decrease.
            pos = new_pos;
            continue;
        }
        // Normal label.
        const len = b0;
        if (len > 63) return error.MalformedDnsMessage;
        if (len > data.len - pos - 1) return error.MalformedDnsMessage;
        try out.appendLabel(data[pos + 1 .. pos + 1 + len]);
        pos += 1 + len;
    }
}
```

A future implementation engineer should be able to start coding from
the API in §3, the security checklist in §4, and the patterns in this
appendix. If anything in this doc is unclear after reading top to
bottom, fix the gap.

# Custom DNS library — Phases A–E foundation (Phase F deferred)

**Date:** 2026-04-29
**Branch:** `worktree-custom-dns`

## What changed and why

Lands the foundation of the contract-native DNS library described in
`docs/custom-dns-design.md` (Round 1) and
`docs/custom-dns-design-round2.md` (Round 2). The longer arc is to
replace the threadpool (`-Ddns=threadpool`, default) and c-ares
(`-Ddns=c_ares`) backends with a single Zig-native resolver that
lives inside the IO contract — so DNS becomes BUGGIFY-testable, no
longer requires background threads, honors `bind_device`, and drops
the `vendor/c-ares/` ~45 KLoC C dependency.

This session lands Phases A through E of the six-phase plan.
Phase F (the `-Ddns=custom` build flag dispatch and the SimIO
end-to-end smoke test) is deferred — the team-lead brief
explicitly permits stopping here, and the existing `-Ddns=threadpool`
and `-Ddns=c_ares` backends are untouched.

### Module layout

```
src/io/dns_custom/
  message.zig       Phase A — wire format encode/decode + tests
  cache.zig         Phase C — bounded TTL cache (positive + negative)
  resolv_conf.zig   Phase D — /etc/resolv.conf parser
  query.zig         Phase B — per-lookup state machine, generic over IO
  resolver.zig      Phases B/C/E composed — DnsResolverOf(IO)
```

Wired into `src/io/root.zig`'s `test {}` block under
`dns_custom.{message,cache,resolv_conf,query,resolver}`.

### Phase A — wire format parser (essential)

`src/io/dns_custom/message.zig` (~750 LOC including 35 tests).

Hardening patterns ported directly from the round-1-through-round-4
KRPC / bencode parser audits (Pattern #17 audit-pattern-transfer):

- saturating-subtraction length-prefix bounds (mirrors
  `krpc.parseByteString` at `src/dht/krpc.zig:314`)
- compression-pointer **strict-decrease invariant** (any pointer
  reached from offset `c` must satisfy `p < c` — catches forward
  pointers, self-loops, and multi-hop cycles in one check)
- compression-hop counter capped at 16 (defense-in-depth backstop
  on top of strict-decrease)
- label length cap (RFC 1035 §3.1, 63 octets)
- wire-name total length cap (RFC 1035 §2.3.4, 255 octets)
- `rdlength` bound checked before any RDATA read
- `ancount` is **not** used to pre-allocate (we iterate, advance
  the cursor, bail if it would exceed `data.len`)
- mismatched-question rejection (cache-poisoning defense)
- A `rdlength` must equal 4; AAAA `rdlength` must equal 16
- adversarial fuzz smoke (32 random seeds × 64-byte buffers fed to
  `extractAnswers` — no-panic assertion)

Public surface:
- `Header`, `Flags`, `Opcode`, `Rcode`, `RrType`, `RrClass`
- `encodeName`, `readName`, `skipName`, `NameBuffer`
- `encodeQuery`, `encodeQuestion`, `readQuestion`, `readRr`
- `extractAnswers` — top-level entry: question-match,
  CNAME chain follow capped at `max_cname_hops=8`, A/AAAA
  collection.

### Phase B — UDP query state machine (essential)

`src/io/dns_custom/query.zig` (~470 LOC).

`QueryOf(IO)` is generic over the IO backend (RealIO / EpollIO /
KqueueIO / SimIO). State machine: `socket → applyBindDevice (Linux,
optional) → connect → send → recv` with per-server and total-budget
timeouts, multi-server fallback on timeout / SERVFAIL, txid match,
NXDOMAIN delivery, CNAME chain target surfaced for caller follow-up.

Defenses on top of the parser:
- recv-side txid match (drop-and-rearm on mismatch — off-path
  attacker cannot poison; per-server timeout closes us out if the
  legit response never arrives)
- TC=1 truncation: skip to next server (TCP fallback is a Phase F
  follow-up; design doc treats this as a "small fast path")
- per-server attempt + total-budget timeouts on **separate**
  completions — caught a real correctness issue mid-implementation
  where the cancel op reused the target's completion (would have
  corrupted the backend's bookkeeping)

### Phase C — bounded TTL cache (very useful)

`src/io/dns_custom/cache.zig` (~290 LOC, 12 tests).

Mirrors the threadpool/c-ares cache shape (`StringHashMapUnmanaged`
+ 64-entry default + earliest-expiry eviction) with the design-doc
refinements:

- per-record TTL clamped into `TtlBounds.[floor_s, cap_s]`
  (replaces the threadpool's fixed `cap_s` lifetime — `getaddrinfo`
  doesn't expose TTL)
- negative caching: NXDOMAIN / SERVFAIL / no-answer cached for
  `floor_s` so a misconfigured tracker URL doesn't pummel the
  resolver every announce
- tagged `Entry` union (`.positive | .negative`) so callers can
  distinguish "this host doesn't exist" from "lookup pending"
- `sweepExpired` for periodic-tick cleanup

Reuses `dns.zig`'s `TtlBounds` (no separate config type — the
floor/cap already live there).

### Phase D — resolv.conf parser (very useful)

`src/io/dns_custom/resolv_conf.zig` (~190 LOC, 14 tests).

Line-oriented, pure (operates on a slice). Only the `nameserver`
directive is honored — per the design doc, BitTorrent always uses
FQDNs (trackers, web-seed URLs, DHT bootstrap nodes) so search
domains and `ndots` aren't needed.

Features:
- IPv4 + IPv6 nameserver entries
- IPv6 zone-id stripping (`fe80::1%eth0` → `fe80::1`)
- `#` and `;` comment stripping
- CRLF tolerance
- case-insensitive directive name
- caps at `max_nameservers=8` (glibc `MAXNS=3`, but a few more
  accommodate hosts with multi-tunnel / per-link DNS configs)
- silently skips invalid IP addresses (matches glibc behavior)

Fallback chain when `/etc/resolv.conf` is missing or has no valid
nameservers: `127.0.0.53` (systemd-resolved) then `8.8.8.8`.

### Phase E — bind_device support (half day)

Plumbed through `DnsResolverOf(IO).Config.bind_device` into
`QueryOf(IO).QueryParams.bind_device`. On socket-create CQE, the
state machine calls `socket_util.applyBindDevice(fd, name)`. On
permission-denied, logs a warn and continues (matches peer-handler
behavior).

Closes the latent bind_device DNS leak documented in
`docs/custom-dns-design-round2.md` §1 — once Phase F wires
`-Ddns=custom` as a selectable backend.

### Phase F — deferred

The mechanical pieces (`build.zig` enum extension to add `custom`,
`dns.zig` dispatch, SimIO smoke test with a scripted DNS server)
are filed as a follow-up. The Phase B query state machine is
compile-checked but not yet exercised end-to-end against SimIO; the
resolver constructor is exercised in unit tests against a stub IO
type to verify the type instantiates and the cache helpers work.

## What was learned

- **Strict-decrease alone bounds compression-pointer following.**
  The hop counter cap is defense-in-depth; the strict-decrease
  invariant (every compression pointer must point to a *lower*
  offset than the byte we're reading from) trivially eliminates
  cycles and infinite loops because any chain is bounded by
  `log2(message_size)`. Caught while writing the
  `pointer-to-pointer infinite loop` test — the cycle never
  forms because the second pointer's strict-decrease check fires
  first.
- **Cancel ops need their own completion.** The IO contract's
  `cancel(op, c, ...)` requires `op.target` and `c` to be
  different completions. Initial draft of `query.zig` reused the
  target's completion as the cancel-op self, which would have
  corrupted backend bookkeeping under contention. Fixed by
  adding `cancel_op_self`, `cancel_timeout_self`,
  `cancel_total_self` side-channel completions.
- **The query name in `extractAnswers` must be lowercased on
  entry.** RFC 1035 §2.3.3 makes DNS comparisons case-insensitive,
  but the code path only lowercases the *response* names (via
  `NameBuffer.appendLabel`). The query name is fed in by the
  caller, so it's the resolver's responsibility to lowercase
  before calling — a future Phase F integration item to verify in
  the dispatch layer.
- **`getaddrinfo`-shape APIs cannot be retrofitted with
  bind_device.** This was the round-1+2 motivation but I had to
  re-confirm it while implementing. glibc's `getaddrinfo` owns
  the UDP socket internally; there's no callback or hook. The
  custom resolver controlling its own socket is the only way to
  apply `SO_BINDTODEVICE` to DNS traffic.

## Surprises / edge cases

- **Compression-pointer wire-length budget.** RFC 1035 §2.3.4's
  255-octet name cap has to be tracked in the parser's
  *wire-format* sense (sum of `1 + label_len` for each label,
  plus the terminator), not the text-form sense. With compression,
  a malicious response can synthesize a name whose decoded text
  blows past 255 even though no individual label exceeds the
  cap. Fixed by tracking `wire_used` across compression jumps
  and rejecting on overflow.
- **`Result.recv` after a cancel CQE delivers
  `error.OperationCanceled` as the recv variant.** The state
  machine has to handle that path the same as a "per-server
  failure → advance to next server"; my initial draft relied on
  the per-server timeout's CQE driving the advance, which would
  have left the recv completion stuck. Restructured so
  `onPerServerTimeout` only sets `last_err` and issues the
  cancel; the recv's own CQE (whose result is now
  `error.OperationCanceled`) drives the advance.
- **Pre-existing flaky test: `sim_smart_ban_phase12_eventloop_test`.**
  Failed once during the verification run, passed on the next
  attempt. Not introduced by this work — the failure was visible
  in the baseline `nix develop --command zig build test` before
  any DNS files existed.

## Remaining issues / follow-up

### Phase F integration (blocking the `-Ddns=custom` selector)

1. Extend `DnsBackend` in `build.zig` with `custom`.
2. In `src/io/dns.zig`: when `dns_backend == .custom`, dispatch
   to a thin facade exposing the existing `DnsResolver` shape
   (`init(allocator, config)` — no IO param). The facade has to
   either (a) embed a private RealIO event loop, (b) be instantiated
   with an IO pointer and a different API contract from the
   threadpool/c-ares backends, or (c) gate the existing
   `DnsResolver` API behind a wrapper that internally drives a
   short-lived event loop. Option (b) is the cleanest, but
   requires touching every `DnsResolver.init` call site; option
   (c) is the smallest blast radius. **Recommend the executor
   refactor as a separate round.**
3. Build the SimIO end-to-end smoke test: scripted DNS server
   answering one A query, fed bytes to `SimIO`'s recv-script
   facility, drives `DnsResolverOf(SimIO)` through a single
   query.

### Other deferred items

- **TCP fallback on TC=1.** Currently we treat truncated UDP
  responses as a per-server failure and advance. Real TCP
  fallback (the BIND-style 2-byte-prefix DNS-over-TCP wire
  format) is a follow-up — design doc treats this as
  uncommon-enough-for-v1.
- **Happy-eyeballs (RFC 8305).** Race A and AAAA, prefer the
  first that connects. Not required for v1; would need to
  parallelize two `QueryOf(IO)` instances and pick the
  resolved-first.
- **BUGGIFY harness for `DnsResolverOf(SimIO)`.** Once Phase F
  lands, the existing `injectRandomFault` + `FaultConfig` shape
  (see `tests/recheck_live_buggify_test.zig`) applies directly
  — DNS is just another untrusted-input path on the IO contract.
- **resolv.conf re-read.** Current `loadFromFile` runs once at
  init. The daemon is long-lived; if `/etc/resolv.conf` changes
  (VPN connect, network swap), the resolver doesn't notice
  until restart. Acceptable for v1 per the design doc.

## Key code references

- Parser: `src/io/dns_custom/message.zig:172` (`readName`),
  `src/io/dns_custom/message.zig:387` (`extractAnswers`).
- Compression-pointer strict-decrease check:
  `src/io/dns_custom/message.zig:194`.
- Saturating-subtraction length bound:
  `src/io/dns_custom/message.zig:222` (label payload),
  `src/io/dns_custom/message.zig:317` (rdlength).
- Cache TTL clamping: `src/io/dns_custom/cache.zig:78`.
- Negative-caching path: `src/io/dns_custom/cache.zig:96`.
- Per-query state machine entry:
  `src/io/dns_custom/query.zig:131` (`start`).
- Multi-server fallback:
  `src/io/dns_custom/query.zig:382` (`advanceServerOrFail`).
- bind_device hook: `src/io/dns_custom/query.zig:208`.
- resolv.conf fallback chain:
  `src/io/dns_custom/resolv_conf.zig:81`.

## Test count delta

| Suite | Before | After | Delta |
|---|---|---|---|
| Total | 1 604 | 1 677 | +73 |

Approximate per-module breakdown:
- `message.zig`: 35 tests
- `cache.zig`: 12 tests
- `resolv_conf.zig`: 14 tests
- `query.zig`: 2 tests (compile-checks; full async tests Phase F)
- `resolver.zig`: 9 tests (cache helpers + numeric IP fast-path
  + init validation, all against a stub IO type)

## Commit graph

```
832c649 dns: split cancel ops onto dedicated completions
feefe41 dns: add Phase B+C UDP query state machine + resolver
3f5635a dns: add Phase D resolv.conf parser
16ccc3b dns: add Phase A custom DNS wire-format parser
```

(Phase A bottom; Phase B+C top minus the cancel-completion fix.)

## Expected merge conflicts

- **STATUS.md** — three engineers landing milestones in this
  round; predictable conflict zone.
- No other files; the Phase A–E foundation lives entirely under
  `src/io/dns_custom/` and the `dns_custom = struct { ... }`
  test-discovery wrapper added to `src/io/root.zig`. The
  existing `src/io/dns_threadpool.zig` and `src/io/dns_cares.zig`
  are untouched; `src/io/dns.zig` is untouched.

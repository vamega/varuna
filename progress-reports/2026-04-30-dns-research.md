# DNS Library Research — Custom vs c-ares

**Date:** 2026-04-30
**Branch:** `worktree-dns-research`
**Output:** [docs/custom-dns-design.md](../docs/custom-dns-design.md) (~5000 words)
**Status:** research-only; no source changes; no STATUS milestone

## What was done

Read-only audit of the DNS surface in `src/`. Found exactly five DNS
call-sites:

1. `src/dht/bootstrap.zig:29` — blocking `getAddressList` for 4 hard-coded
   bootstrap nodes at startup.
2. `src/io/http_executor.zig:437` — `DnsResolver.resolveAsync` for HTTP/HTTPS
   tracker announces and BEP 19 web seeds.
3. `src/daemon/udp_tracker_executor.zig:327` — `DnsResolver.resolveAsync` for
   UDP tracker (BEP 15).
4. `src/tracker/udp.zig:419` — blocking `getAddressList` (legacy magnet-peer-collection path).
5. Former synchronous HTTP module — blocking `DnsResolver.resolve`.

Plus the threadpool worker (`src/io/dns_threadpool.zig`) and the c-ares
backend (`src/io/dns_cares.zig`).

Wrote a six-section design doc covering: current state quantification,
BitTorrent's actual DNS feature requirements, a sketch of a varuna-native
async resolver, the security threat model, the c-ares-on-io_uring
alternative, and a clear recommendation.

## Recommendation

**Build a custom DNS library** (~600–1200 LOC, ~7–10 days). Replace c-ares
entirely. The IO contract already exposes everything DNS needs
(`socket`/`connect`/`sendmsg`/`recvmsg`/`timeout`/`cancel`), so the
resolver works on all backends — `RealIO`, `EpollIO`, `KqueueIO`, and
`SimIO` — with no per-backend bridge. BUGGIFY testability is automatic
because every IO submission is already on the contract.

The cost is ~500 LOC of DNS wire-format parser. That parser is the same
shape (length-prefix, no-recursion, type-tagged) as the bencode / KRPC /
ut_metadata code we hardened in audit rounds 1–4. The hardening
playbook (saturating-subtraction length-prefix bounds, explicit-stack
recursion, fuzzed adversarial tests) ports directly. The doc's §4 +
Appendix B include drop-in code shapes for the implementation engineer.

## Key surprises

1. **The DHT does not lookup hostnames.** Only the 4 hard-coded
   bootstrap nodes are hostnames; everything else (compact peers from
   tracker, KRPC node info, PEX) is already an `std.net.Address`. This
   means c-ares' "hundreds of concurrent DNS lookups" sizing is
   over-engineered for our actual workload — we're at tens of lookups
   per hour in steady state.
2. **The DnsResolver `invalidate()` API is exported but never called.**
   A failed tracker connect should arguably invalidate the cached IP,
   but currently doesn't. Filed as Open Question #1.
3. **The 5-minute cache TTL is shorter than the typical tracker
   re-announce interval (30–60 min)**, so we re-resolve before nearly
   every announce in steady state. Trivial tightening: cap at the
   response's TTL rather than 5 min.
4. **`vendor/c-ares/` is ~45,000 LOC of C** for code that does ~95%
   features we don't use. This is the largest single dependency and
   the heaviest vendoring chore for non-Linux dev builds.
5. **The current `dns_cares.zig` uses `epoll`, not io_uring.** The
   STATUS.md "next" item ("c-ares io_uring integration") was the
   trigger for this round; the comparison shows the work to fully
   io_uring-ize c-ares (and cross to the other backends + SimIO) is
   strictly larger than writing the custom resolver.

## Remaining issues / follow-up

None for this round — research only. The design doc enumerates the
implementation phases (A through F) with effort estimates if the
recommendation is accepted.

## Key code references

- `src/io/dns.zig:33` — `DnsResolver` build-time alias dispatch.
- `src/io/dns_threadpool.zig:65` — current sync `resolve` API.
- `src/io/dns_threadpool.zig:110` — async `resolveAsync` with eventfd.
- `src/io/dns_cares.zig:205` — c-ares' inner epoll loop (the integration point).
- `src/dht/bootstrap.zig:7` — the 4 bootstrap hostnames.
- `src/io/io_interface.zig:96` — IO contract operation set (everything DNS needs).
- `progress-reports/2026-04-26-krpc-hardening.md` — audit pattern reference.
- `STATUS.md:279` — c-ares io_uring proof-of-concept note that prompted this round.

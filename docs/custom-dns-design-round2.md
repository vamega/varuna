# Custom DNS Library — Round 2 Addendum

**Status:** research / pre-implementation. Extension of
[`custom-dns-design.md`](custom-dns-design.md) (round 1). Read that
document first; this one assumes its terminology and call-site inventory.

**Scope:** evaluate three new dimensions surfaced after round 1 landed:

1. Does the daemon need **SO_BINDTODEVICE** on DNS sockets?
2. Could **POSIX `getaddrinfo_a` + `gai_cancel`** sidestep the parser
   entirely?
3. What do **zio** and **libxev** actually do for async DNS? (Round 1
   surveyed backend selection, not DNS specifically.)

**Updated recommendation (TL;DR):** still **Option A — build the custom
DNS library** (round 1's recommendation). The round 2 evidence
strengthens it rather than weakening it. The one design change: the
custom resolver MUST honor varuna's existing `bind_device` config, which
the current threadpool/c-ares paths silently ignore. See §6.

---

## §1 — Does varuna need SO_BINDTODEVICE on DNS sockets?

### What `bind_device` is in varuna today

`varuna.toml` already exposes `network.bind_device` (`src/config.zig:187`):

> "Network interface to bind to (e.g. `wg0`). Requires CAP_NET_RAW or root."

The implementation is `socket_util.applyBindDevice` in
`src/net/socket.zig:6` — a `setsockopt(SO_BINDTODEVICE, name, len+1)` on
a socket fd. It is applied today on:

| Site | File:line |
|---|---|
| TCP listen socket | `src/io/event_loop.zig:1460` |
| UDP listener (uTP / DHT) | `src/io/event_loop.zig:1385` |
| Outbound peer connect socket | `src/io/peer_handler.zig:187` |
| RPC API server socket | `src/rpc/server.zig:91` |
| Standalone listen helper | `src/main.zig:635` |

It is **NOT** applied on:

- HTTP tracker connect sockets (`src/io/http_executor.zig:497`)
- UDP tracker sockets (`src/daemon/udp_tracker_executor.zig:383`)
- DNS lookup sockets — the threadpool backend uses
  `std.net.getAddressList` (`src/io/dns_threadpool.zig:358`), which
  internally invokes `getaddrinfo`. `getaddrinfo` allocates its own UDP
  socket inside libc; we cannot apply SO_BINDTODEVICE to it. The c-ares
  backend has the same gap (its socket is opened by c-ares; the
  `ares_set_socket_callback` hook would let us apply it, but
  `dns_cares.zig` does not).

So a user running varuna with `bind_device = "wg0"` today has **DNS
queries leaking out the default route**, even though tracker peer
connections and the listen socket are pinned to `wg0`. This is a latent
bug — small, since DNS reveals only "this user is asking for tracker
hostname X" and not the actual peer-traffic five-tuple, but present.

### Is per-interface DNS a real BitTorrent client requirement?

| Client | Interface binding | DNS-via-interface? |
|---|---|---|
| **qBittorrent** | "Network interface" dropdown in Tools → Options → Advanced. Binds peer/tracker sockets to that interface. | No separate setting. Recommended VPN guides rely on the interface binding plus iptables / firewall rules to route DNS. |
| **Transmission** | `bind-address-ipv4` (settings.json) — IP binding, not interface binding. No GUI option on macOS. | No separate setting. Forum guides recommend system-level firewall / iptables for DNS lockdown. |
| **libtorrent (arvidn)** | `listen_interfaces` (string spec) — binds listen and outbound sockets. | No DNS-interface knob in the public API. |
| **rtorrent** | `network.bind` for outbound and `network.listen.bind` for listen — IP binding. | None. |

The pattern is consistent: BitTorrent clients expose interface-binding
for **peer and tracker sockets** because that is the leak surface (real
torrent traffic identifying the user's ISP IP). DNS leakage is treated
as a system-level concern, addressed by:

- VPN providers' own DNS in `/etc/resolv.conf` plus a kill switch.
- iptables / nftables rules forcing port-53 traffic through the tunnel.
- systemd-resolved per-link DNS configuration (NetworkManager populates
  this for VPN connections automatically).

The qBittorrent issue tracker has had complaints about DNS leakage (e.g.
issue #2714) and the upstream answer is "use the system firewall" —
adding a DNS-via-interface option has not landed.

### VPN and multi-homed scenarios

For a typical VPN setup (WireGuard, OpenVPN, Tailscale), the DNS server
on the tunnel is reachable through the default route once the route
table is updated by the VPN client. SO_BINDTODEVICE on the DNS socket is
**not required for the lookup to succeed** — it is required only if the
user wants the DNS query to traverse the tunnel rather than potentially
the original ISP path. Given that VPN providers ship their own DNS
servers reachable over the tunnel, the typical setup already routes DNS
correctly without SO_BINDTODEVICE.

Multi-homed hosts (LAN + WAN, residential + work) generally use a
single resolver visible on both sides; DNS is interface-independent.
The bind_address selection of an outbound source IP does not require
the DNS lookup to use the same source IP.

### Verdict

SO_BINDTODEVICE on DNS sockets is **NICE-TO-HAVE**, not required. But
because varuna *already* honors `bind_device` for tracker peer sockets
and we'd be writing a fresh DNS resolver from scratch, the **incremental
cost is ~5 LOC** (one `applyBindDevice()` call after the UDP query
socket is created) and the right thing to do is plug the gap. Treat it
as a Phase-A polish item in the custom-DNS implementation plan, not a
separate workstream.

This also fixes a real latent bug: bind_device users today have DNS
leaks. The custom DNS path closes that.

---

## §2 — POSIX `getaddrinfo_a` + `gai_cancel` as an alternative

### What `getaddrinfo_a` actually is

[`getaddrinfo_a(3)`](https://man7.org/linux/man-pages/man3/getaddrinfo_a.3.html)
is glibc's libanl async wrapper around `getaddrinfo`. The completion
mechanism is a `struct sigevent`:

- `SIGEV_SIGNAL`: glibc raises a signal (default `SIGRTMIN`) on
  completion. The handler reads `siginfo_t.si_code == SI_ASYNCNL` and
  pulls the result via `gai_error()`. **Signals do not integrate with
  io_uring.** A CQE-shaped event delivery requires a signalfd to feed
  the ring, plus a thunk to demultiplex the per-request `gaicb`.
- `SIGEV_THREAD`: glibc spawns a fresh pthread for each completion to
  invoke the user callback. **This is strictly worse than the current
  threadpool backend** (which keeps a fixed pool of 4 workers and
  reuses them).
- `SIGEV_NONE`: caller polls `gai_error(&gaicb)`. Defeats the async
  shape.

### Cancellation

`gai_cancel(&gaicb)` is best-effort: glibc returns `EAI_CANCELED`,
`EAI_NOTCANCELED`, or `EAI_ALLDONE`. It does not interrupt a libc
worker thread mid-DNS-query (libanl uses an internal thread pool); a
cancelled lookup still occupies the worker until the underlying DNS
operation returns. From varuna's perspective this is no improvement
over the current threadpool's "drop the result on the floor when the
caller goes away" pattern.

### Portability

| Platform | `getaddrinfo_a` |
|---|---|
| **glibc / Linux** | yes (link `-lanl`) |
| **musl / Linux** | **no** — explicit non-goal per
  [musl's functional-differences page](https://wiki.musl-libc.org/functional-differences-from-glibc.html). Static-linked / Alpine builds break. |
| **macOS / Darwin** | **no** — the platform equivalent is libinfo's
  `getaddrinfo_async_start` (Mach-port-based, completely different
  shape; this is what zio's darwin backend uses). |
| **FreeBSD / OpenBSD** | **no** |
| **uClibc / Bionic** | no |

If we ship `-lanl` only, we drop musl/Alpine support. The KqueueIO MVP
(macOS dev builds) needs a separate path. Behavior gap: `-lanl` is the
only platform that has it.

### Trade-off summary against custom DNS

| Property | `getaddrinfo_a` (glibc) + threadpool fallback | Custom DNS library |
|---|---|---|
| Parser to harden | none | ~500 LOC, audited |
| Lines of code we own | ~200 (signalfd glue) + threadpool | ~1000–1200 |
| TTL honored | **no** (libc returns `addrinfo`, not TTL) | yes |
| SO_BINDTODEVICE | **no** (libc owns the socket) | yes (one setsockopt) |
| Source-port randomization | **no** (libc) | yes |
| Transaction-id randomization | yes (libc randomizes) | yes |
| `/etc/nsswitch.conf` integration | **yes** (mDNS, `.local`, etc.) | no (DNS only) |
| `/etc/hosts` lookup | yes | yes (~30 LOC) |
| musl support | no | yes |
| macOS dev support | no | yes |
| io_uring integration | indirect (signalfd or eventfd from a libanl thread) | direct (sendmsg/recvmsg on the ring) |
| SimIO BUGGIFY | **no** (libc not interceptable) | yes (every op is on the contract) |
| Cache poisoning surface | libc's | ours (smaller) |

The killer is **SimIO BUGGIFY**. The whole reason DNS-on-the-IO-contract
exists is so the same fault-injection harness that drives KRPC,
metadata-fetch, and AsyncRecheck applies to DNS too. `getaddrinfo_a` is
opaque libc — we can't inject malformed responses, we can't simulate
slow servers, we can't test fall-through behavior. We'd have to ship a
fundamentally untested DNS code path.

The TTL-honoring gap is also real. The dns-fixes round acknowledged
that varuna's 5-min static cap is a regression vs. authoritative TTLs;
`getaddrinfo_a` cannot expose response TTLs even if we want them.

### Verdict

`getaddrinfo_a` is not viable. The portability hit (no musl, no macOS),
the BUGGIFY hit, and the TTL/bind-device gaps would push us toward
"custom DNS plus glibc-only fast path," which is the worst-of-all
hybrid (more code, more configs, more maintenance, parser still
required for the fallback).

---

## §3 — What zio and libxev actually do

### zio (`reference-codebases/zio/src/dns/`)

zio implements DNS as **per-OS native async** with a thread-pool
fallback for POSIX (Linux/BSD). Total surface area: **428 LOC across
4 files** (`root.zig`, `posix.zig`, `darwin.zig`, `windows.zig`).
Backend selection at comptime in `root.zig:42-47`:

```zig
pub const impl = if (builtin.os.tag == .windows)
    @import("windows.zig")        // GetAddrInfoExW + OVERLAPPED + completion callback
else if (builtin.os.tag.isDarwin() and backend.backend == .kqueue)
    @import("darwin.zig")         // libinfo + Mach port + kqueue
else
    @import("posix.zig");         // blocking getaddrinfo + zio's thread pool
```

#### POSIX path (`posix.zig`, 83 LOC)

```zig
pub fn lookup(options: dns.LookupOptions) dns.LookupError!Result {
    const head = try blockInPlace(lookupBlocking, .{options});
    return ...;
}

fn lookupBlocking(...) ... {
    // synchronous getaddrinfo on a thread-pool worker
}
```

`blockInPlace` (`src/common.zig:374`) submits the work to zio's
existing `ev.Work` thread pool, parks the calling task on a Waiter,
and resumes when the worker signals. Identical in shape to varuna's
current `dns_threadpool.zig`. **No DNS parser; no resolv.conf; no
TTL.**

#### Darwin path (`darwin.zig`, 131 LOC)

Calls `getaddrinfo_async_start` (Apple's libinfo, equivalent in spirit
to glibc's `getaddrinfo_a` but using Mach ports for completion
delivery). The Mach port is registered with kqueue via
`EVFILT_MACHPORT`; the kqueue wakes on completion, the code calls
`getaddrinfo_async_handle_reply` to drive the libinfo callback, which
populates the `addrinfo` chain. Cancellation via
`getaddrinfo_async_cancel`.

This is the only path on the table that is genuinely native-async DNS
without spawning a thread; it relies on Apple-private libinfo +
kqueue's port-watching ability. Not portable to Linux.

#### Windows path (`windows.zig`, 164 LOC)

`GetAddrInfoExW` with `OVERLAPPED` + completion callback. Cancel via
`GetAddrInfoExCancel`. Same shape as Darwin but with Win32 plumbing.

#### Takeaways for varuna

- zio has **no DNS protocol parser of its own**. It punts to the OS
  resolver everywhere.
- zio has **no SO_BINDTODEVICE / IP_BOUND_IF support**. Their model
  doesn't expose the underlying socket.
- zio's POSIX path is roughly what varuna's `dns_threadpool.zig`
  already is (blocking `getaddrinfo` on a worker thread, with the
  caller's task parked).
- zio's darwin path is interesting but Linux-native varuna can't use
  libinfo / Mach.

This validates "thread-pool around `getaddrinfo`" as a reasonable
*portable* baseline, but does not address varuna's specific needs
(BUGGIFY, TTL, SO_BINDTODEVICE, io_uring-native).

### libxev (`reference-codebases/libxev/`)

`grep -r "getaddrinfo\|gai_\|resolv\|dns" reference-codebases/libxev/src/`
returns **zero hits**. libxev's watcher modules cover TCP, UDP, file,
process, timer, async, stream — not DNS. The library takes
`std.net.Address` directly; DNS is the user's problem.

This is a deliberate scope choice (libxev is an event loop, not a
runtime). For varuna it confirms that DNS-as-a-separate-module is the
right boundary; we're not missing some libxev pattern.

### tigerbeetle (`reference-codebases/tigerbeetle/`)

Zero DNS code. tigerbeetle uses raw IP+port endpoints in cluster
configuration and has no hostname-shaped path. No insights for varuna,
which has tracker / DHT bootstrap hostnames as a hard requirement.

### Cross-runtime takeaways

| | zio | libxev | varuna (proposed) |
|---|---|---|---|
| DNS in scope | yes (4 files, 428 LOC) | no | yes (~1000 LOC) |
| Custom parser | **no** | n/a | **yes** |
| Per-OS native async | yes (Darwin libinfo, Windows GetAddrInfoExW) | n/a | n/a (Linux only) |
| Thread-pool baseline | yes (POSIX) | n/a | yes (current; replaced) |
| io_uring-native UDP DNS | no | n/a | **yes** |
| BUGGIFY testability | no | n/a | **yes** |
| SO_BINDTODEVICE / IP_BOUND_IF | no | n/a | **yes** (round 2 addition) |

Varuna's design is more ambitious than either zio's or libxev's because
of the simulation-first testing requirement and the io_uring policy.
The custom parser is the price of admission for both.

---

## §4 — Web-research notes (citations)

- **`SO_BINDTODEVICE` ≠ portable.** macOS uses `IP_BOUND_IF` (and
  `IPV6_BOUND_IF`), takes an `unsigned int` interface index from
  `if_nametoindex`. FreeBSD does not have a stock equivalent.
  ([djangocas write-up](https://djangocas.dev/blog/linux/linux-SO_BINDTODEVICE-and-mac-IP_BOUND_IF-to-bind-socket-to-a-network-interface/))
- **`getaddrinfo_a` requires `-lanl` and is glibc-only.** musl
  explicitly will not implement it
  ([musl functional differences](https://wiki.musl-libc.org/functional-differences-from-glibc.html)).
  macOS's analog is libinfo's `getaddrinfo_async_start` (different
  API, Mach-port completion).
- **`getaddrinfo_a` completion shape is `sigevent`** — `SIGEV_SIGNAL`
  (signal handler with `si_code = SI_ASYNCNL`) or `SIGEV_THREAD`
  (callback in a fresh thread per completion).
  ([`getaddrinfo_a(3)` man page](https://man7.org/linux/man-pages/man3/getaddrinfo_a.3.html))
- **qBittorrent's interface-binding does not include DNS.** Issue
  threads recommend system firewall / iptables for DNS-leak
  prevention, not a client-side option.
  ([qBittorrent VPN binding wiki](https://github.com/qbittorrent/qBittorrent/wiki/How-to-bind-your-vpn-to-prevent-ip-leaks))
- **Transmission binds via `bind-address-ipv4` (an IP, not an
  interface), DNS not separately addressable.**
  ([Transmission BindAddressIPv4 thread](https://forum.transmissionbt.com/viewtopic.php?t=11452))

---

## §5 — Updated recommendation

**Stay with Option A: build the custom contract-native DNS library.**
The round 2 evidence does not change the round 1 conclusion; it
strengthens it.

| Round-2 signal | Effect on the round-1 recommendation |
|---|---|
| zio confirms thread-pool + per-OS native is the portable status quo, and ships ~430 LOC with zero parser. | Validates that "punt to libc" is achievable, but punting forfeits BUGGIFY, TTL, and SO_BINDTODEVICE — the exact properties round 1 selected for. **Reinforces A.** |
| libxev has zero DNS. | Confirms event-loop scope vs. runtime scope is a real boundary. varuna needs DNS in-tree because tracker/DHT call sites need it. Doesn't change the build-vs-buy axis. |
| `getaddrinfo_a` is glibc-only with sigevent completion. | Option B effectively reduces to "thread-pool everywhere + libanl on glibc" — the libanl path is more code than custom DNS for less value (worse cancel semantics, signalfd glue, no TTL, no bind_device). **Rejects B.** |
| BitTorrent clients don't expose DNS-via-interface; system-level handles it. | SO_BINDTODEVICE on DNS is nice-to-have, not required. **Doesn't reject A; adds one Phase-A polish item.** |
| varuna's existing `bind_device` is silently bypassed by the current DNS path. | This is a latent bug. Custom DNS fixes it. **Reinforces A.** |

### Why not C (hybrid)

The round 1 doc rejected the hybrid (§6, "Why **not** the hybrid
option") because it carries both costs forever. Round 2 doesn't change
that. The only hybrid that round 2 makes superficially attractive is
"custom for steady state, glibc `getaddrinfo_a` for cold lookups," but
that still requires the parser (because we still need TTL, BUGGIFY,
bind_device, source-port randomization on every path the daemon
actually uses) — so the glibc path is dead weight.

Hybrid stays rejected.

### Confidence delta from round 1

Round 1 confidence: high. Round 2 confidence: high → high. The new
inputs were a fair audit, and they came back with one design refinement
(SO_BINDTODEVICE / Phase-A) and one bug discovery (bind_device leak in
DNS today). Neither moves the needle off Option A.

---

## §6 — Design refinements for the custom library

The round 1 design (§3 of `custom-dns-design.md`) holds. Two
adjustments:

### §6.1 — `bind_device` in the `Config`

Add to `DnsResolverOf(IO).Config`:

```zig
pub const Config = struct {
    // ... existing fields ...

    /// Apply SO_BINDTODEVICE to UDP/TCP query sockets so DNS traffic
    /// goes out the same interface the daemon's tracker/peer sockets
    /// use. Plumbed through from `network.bind_device` in
    /// `varuna.toml`. Requires CAP_NET_RAW or root.
    bind_device: ?[]const u8 = null,
};
```

Wire-up:

- `EventLoopOf(IO).init` already accepts `bind_device` and stores it
  on the loop (`src/io/event_loop.zig:204`). When the resolver is
  constructed, copy this string into `Config.bind_device`.
- `query.zig` opens the UDP socket via `io.socket(...)`, then on the
  socket-create CQE submits IO-contract
  `setsockopt(SO_BINDTODEVICE, name)` before the UDP connect/send. The
  option buffer lives in the query state until the setsockopt completion
  fires, so RealIO can use an async kernel op where available.
- TCP fallback (DNS-over-TCP for truncated responses) gets the same
  treatment.
- The same IFNAMSIZ validation is applied before submitting setsockopt.

Implementation note (2026-05-01): the custom library now has this
bind-device sequencing inside `QueryOf(IO)` and a resolver-level
`DnsResolverOf(IO).resolveAsync()` path. The daemon leak is not fully
closed until HTTP/UDP tracker executors are moved from the transitional
threadpool facade to that custom resolver API.

### §6.2 — Don't bother with macOS `IP_BOUND_IF`

The varuna daemon is Linux-only by AGENTS.md scope. The KqueueIO MVP
exists for development on macOS but is not a deployment target. We do
not need to ship an `IP_BOUND_IF` path to match SO_BINDTODEVICE on
Darwin. If the resolver compiles on Darwin (it should, because every
primitive it uses is in `io_interface.zig`), the bind_device option
silently no-ops on non-Linux — that's fine, it parallels how the
existing `applyBindDevice` is Linux-conditional.

### §6.3 — Do not change phasing

The round 1 implementation plan (Phases A–F, ~7–10 days) is
unaffected. The bind_device hook fits inside Phase C
(`query.zig` + `resolver.zig`); call it Phase C.5, not a new phase.
Total estimate unchanged.

### §6.4 — Do not absorb zio's POSIX thread-pool path

zio's POSIX backend is what varuna's `dns_threadpool.zig` already is.
Round 1 already plans to keep the threadpool backend as a build option
(`-Ddns=threadpool`) for one transitional release. No reason to also
inherit zio's `blockInPlace` — varuna has its own thread-pool
abstraction in `dns_threadpool.zig` that already does this. Drop
threadpool entirely in Phase F as planned.

---

## §7 — Open questions left for implementation

1. **Should DNS-via-interface failures be fatal or fallback?** When
   `bind_device` is set and `applyBindDevice` returns
   `error.PermissionDenied` (CAP_NET_RAW missing), should the
   resolver hard-fail or fall back to "DNS leaks but tracker traffic
   doesn't"? Current peer-socket behavior in `peer_handler.zig` is to
   **continue without binding** (logs a warn). DNS should match for
   consistency — log warn, don't fail.
2. **Should we randomize source ports for DNS even when bind_device is
   set?** Yes; both are independent. SO_BINDTODEVICE applies before
   `bind()`, and we still want `IP_BIND_ADDRESS_NO_PORT` + ephemeral
   port for txid+port poisoning entropy. Order: socket → bind_device
   → bind to ephemeral → connect → sendmsg.
3. **systemd-resolved on `127.0.0.53` vs. the bind_device.** If
   `/etc/resolv.conf` points at `127.0.0.53` and `bind_device = wg0`,
   the loopback reach is broken (loopback isn't on `wg0`). Resolution
   policy: when bind_device is set and the resolver server is
   loopback, **emit a warning and use `127.0.0.53` anyway** —
   loopback is reachable from any interface in Linux, the kernel
   shortcircuits. Document this in the config comment.
4. **IPv6 bind_device.** `applyBindDevice` is family-agnostic; the
   same setsockopt works for AF_INET6. No new code.

---

## Appendix — Round 1 sections superseded by round 2

None. Round 1 stands as the source of truth for the architecture, the
parser shape, the threat model, the implementation phases, and the
LOC budget. Round 2 is purely additive:

- Section 1 here adds the bind_device-in-DNS audit (round 1 didn't
  examine this).
- Section 2 here closes the door on `getaddrinfo_a` (round 1 didn't
  consider it).
- Section 3 here surveys zio + libxev (round 1 surveyed call sites
  and BEPs, not other Zig runtimes).
- Section 5 here re-states and restages the round 1 verdict with the
  new inputs.
- Section 6 here adds one design knob (bind_device in `Config`) to
  the round 1 sketch.

Read both documents in order; do not read this one alone.

# 2026-04-29 — runtime Clock + Random abstractions

## What changed

Added two new `src/runtime/` modules that virtualise the daemon's
remaining nondeterminism boundaries against `std.time.*` and
`std.crypto.random`. Both use the same tagged-union dispatch shape as
the existing `src/io/clock.zig`:

- **`src/runtime/clock.zig`** — `Clock = union(enum) { real, sim: u64 }`
  with three accessors (`now` → i64 secs, `nowMs` → i64 ms, `nowNs` →
  u64 ns) and matching `advance*` / `set*` mutators. The sim variant
  stores absolute u64 nanoseconds so all three resolutions agree on
  the same logical timeline. Constructors `simAtSecs` / `simAtMs` /
  `simAtNs`. **u64, not i128**: matches the existing
  `SimIO.now_ns: u64` / `PendingEntry.deadline_ns: u64` invariant the
  rest of the simulator uses, fits in 16-byte `Clock` (regression
  test enforces it), wraps in year ~2554 — far past any reasonable
  daemon lifetime.
- **`src/runtime/random.zig`** — `Random = union(enum) { real,
  sim: std.Random.DefaultPrng }` with `bytes`/`int`/`uintLessThan`. The
  module-level docstring catalogues which `std.crypto.random` callers
  are safe to migrate vs. which must stay on the OS CSPRNG for security
  reasons.

The pre-existing `src/io/clock.zig` is now a thin re-export shim so
`EventLoop.clock`, peer/protocol/uTP/web-seed/dht handlers continue to
compile unchanged. `src/runtime/root.zig` exposes both modules under
`varuna.runtime.{clock,random,Clock,Random}`.

## Why tagged-union, not comptime parameterisation

The team-lead's brief offered two options (vtable/runtime dispatch vs.
comptime cascade like the existing IO contract) and asked me to pick
based on call-site density.

`grep -rn 'nanoTimestamp\|milliTimestamp\|std.time.timestamp\|monotonicNow' src/`
returns ~50 production sites; `grep -rn 'std\.crypto\.random'` returns
~25. Comptime parameterisation `ClockOf(comptime Impl: type)` would
force every caller's generic graph to widen all the way down. The IO
contract justifies that cost because IO type is fundamental to the
call surface (different ops, different completion shapes per backend);
clock and random just return integers / fill buffers with nothing to
monomorphise over. Tagged-union dispatch is one branch-predicted
switch on a 24-byte value per call.

The existing `src/io/clock.zig` had already chosen this exact shape;
this work just promotes it to a runtime module and extends it to the
ms / ns resolutions production code actually needs.

## Migrations landed

| Subsystem | Change |
| --- | --- |
| `src/io/rate_limiter.zig` | `TokenBucket` no longer reads `std.time.nanoTimestamp()` internally. Method names changed: `consume`/`available`/`delayNs`/`refill`/`setRate` → `*At` variants taking `now_ns: u64`. `last_refill_ns` switched from `i128` (with `== 0` sentinel) to `?u64` to eliminate the fragile magic value. |
| `src/io/event_loop.zig` | `consumeDownloadTokens` / `consumeUploadTokens` / `isDownloadThrottled` / `isUploadThrottled` / `set{Global,Torrent}{Dl,Ul}Limit` snapshot `self.clock.nowNs()` once and pass through. New `random: Random = .real` field on `Self` (no production consumer yet). |
| `src/io/peer_policy.zig` | 13 in-source test sites: `std.time.timestamp()` → `el.clock.now()`. Production paths already used `self.clock.now()`. |
| `src/tracker/types.zig` | `Request.generateKey(rng: *Random)` — first Random migration. The tracker `key` parameter is a stable client identifier where predictability isn't a security failure. |
| `src/daemon/torrent_session.zig` | `createFromMagnet` / `create` thread a stack-local `Random.realRandom()` into `generateKey`. |
| `tests/clock_random_determinism_test.zig` (new) | TokenBucket sequence + tracker generateKey sequence both reproduce byte-for-byte across runs under sim sources; combined-sources test asserts deterministic output across `(clock_seed, rng_seed)` pairs. |
| `tests/private_tracker_test.zig` | `generateKey` callers updated; new sim-determinism test added. |
| `tests/sim_*_eventloop_test.zig` (4 files) | `el.clock = .{ .sim = N }` → `Clock.simAtSecs(N)` since the sim variant changed from i64 secs to i128 ns. |

## Documented exemptions

Three sites carry inline comments explaining why they bypass the
abstraction:

- **`src/io/dns_cares.zig:342,392`** — synchronous c-ares resolve runs
  on a worker thread against real `epoll_wait`. Routing the deadline
  read through `Clock` without also virtualising c-ares' epoll layer
  would leave the deadline computation out of sync with the real wait.
  Tracked as future work (a larger DNS-sim project).
- **`src/io/kqueue_posix_io.zig:1013`** and
  **`src/io/kqueue_mmap_io.zig:918`** — `monotonicNs()` IS the kqueue
  backend's own time source. Routing through `Clock` would be
  circular. SimIO has its own logical clock for sim-time tests; this
  code only runs on real macOS/BSD.

The MSE handshake (`src/crypto/mse.zig`), peer ID
(`src/torrent/peer_id.zig`), DHT node ID (`src/dht/node_id.zig`), DHT
announce_peer tokens (`src/dht/token.zig`), and RPC session SID
(`src/rpc/auth.zig`) deliberately **stay on `std.crypto.random`**
because predictability would break their security properties. The
`runtime.Random` module-level doc lists each site explicitly.

## Determinism win

The new `tests/clock_random_determinism_test.zig` is impossible to
write before this work landed: `TokenBucket` previously read
`std.time.nanoTimestamp()` directly, so any "consume across 200 ms"
assertion would drift by however long the test scheduler took between
calls. `Request.generateKey` previously read `std.crypto.random`
directly, so two runs would never produce the same key.

The test now asserts:

- Two `TokenBucket` runs over a 1.35 s sim-clock script produce the
  same `(c1, c2, c3, c4, available)` tuple.
- The same script under the analytical model: drain → 1000 consumed,
  +100 ms → 100 credited (50 consumed, 50 left), +250 ms → +250
  credited (300 total, 300 consumed), +1 s → caps at 1000 (1000
  consumed). Catches off-by-one drift in the refill math.
- Different sim clocks (500 ms vs. 50 ms advance) produce different
  refill credits — sanity that the determinism isn't a vacuous "always
  zero" mode.
- `Request.generateKey` byte-for-byte deterministic across 5 seeds and
  16 keys per seed.
- Combined Clock + Random pipeline reproduces fully across same-seed
  runs; key diverges across different RNG seeds while bucket math
  stays identical.

## What was learned

1. **The `.sim = i128` change in Clock is technically a breaking
   change for tests that wrote `.{ .sim = SECS }` directly.** Four
   test sites (`tests/sim_smart_ban_eventloop_test.zig`,
   `tests/sim_swarm_test.zig`, `tests/sim_multi_source_eventloop_test.zig`,
   `tests/sim_smart_ban_phase12_eventloop_test.zig`) needed the
   constructor swap. `Clock.simAtSecs(SECS)` reads cleaner anyway —
   the old form misled at least one caller into commenting "1 ms past
   zero" when the actual semantics were 1 million seconds.

2. **Rate limiter API surface change is invasive but correct.**
   Considered a less-invasive `bucket.clock = self.clock` injection
   pattern, but routing through method parameters keeps the bucket
   stateless w.r.t. time and matches how `EventLoop.clock` already
   threads through other call paths. EventLoop snapshots
   `self.clock.nowNs()` once per public throttle method to avoid
   sampling jitter mid-call.

3. **Sentinel zero in `last_refill_ns` was fragile; replaced with
   `?u64`.** The original code used `last_refill_ns == 0` as the
   "uninitialised, defer to first refill" sentinel. A sim test
   starting at absolute time 0 ns would trigger re-init on every
   refill (no time ever credited). The narrowing-to-u64 work was a
   natural moment to also switch the field to `?u64`, eliminating the
   magic value. Two new tests guard the corner case:
   `refill clock-going-backward is a no-op` and
   `refill across the t=0 anchor seeds rather than crediting`.

4. **`std.crypto.random` sites are not all the same.** The
   simulator-friendly category turned out to be smaller than the
   team-lead's brief implied — most of the BitTorrent crypto.random
   reads are security-relevant (MSE, DHT tokens, peer ID, RPC SID).
   The clean wins are the 4 sites where the random output is just a
   nonce or collision-avoidance number with no adversarial pressure
   (UDP tracker tx IDs, uTP conn IDs, tracker `key`, and a future
   smart-ban tie-break). Migrated 1 (tracker `key`); others tracked
   as follow-up.

5. **u64 vs i128 for ns timestamps — match the existing invariant,
   not the stdlib.** The first cut returned `i128` from `nowNs()` to
   mirror `std.time.nanoTimestamp()`. Team-lead review pointed out
   that the rest of the simulation timeline (`SimIO.now_ns: u64`,
   `Simulator.clock_ns: u64`, `PendingEntry.deadline_ns: u64`) was
   already u64; mismatching widened the `Clock` struct beyond a
   16-byte cache slice, forced 128-bit conversion at every
   `EventLoop → SimIO` boundary, and gave up the ability to put a ns
   timestamp behind `std.atomic.Value(u64)` later. u64 ns since the
   epoch wraps in year ~2554, well outside any plausible daemon
   lifetime. A `@sizeOf(Clock) <= 16` regression test guards the
   choice.

## Remaining work

1. **UDP tracker transaction IDs** (`src/tracker/udp.zig:generateTransactionId`,
   10 callers). Migration requires plumbing `*Random` through
   `UdpTrackerExecutor`. EventLoop now has `random: Random = .real` to
   plug into.
2. **uTP connection IDs** (`src/net/utp.zig:UtpSocket.connect:321`).
   Same pattern — needs `*Random` on `UtpSocket`.
3. **DNS sim time** (`src/io/dns_cares.zig`). Requires also
   virtualising c-ares' epoll layer.
4. **`Clock` field renaming.** `EventLoop.clock` is now used for ms /
   ns reads too, not just seconds. Field name still works but
   `Clock.now()` returning seconds while the rest of the daemon thinks
   in ns is a small footgun. Consider an audit pass that converts
   per-second timestamp comparisons to `nowMs()` where seconds are
   coarser than needed.

## Key references

- `src/runtime/clock.zig:1-220` — Clock type, accessors, mutators,
  inline tests.
- `src/runtime/random.zig:1-160` — Random type + safe-vs-crypto
  catalogue in module docstring.
- `src/io/event_loop.zig:57-60` — Clock + Random imports.
- `src/io/event_loop.zig:182-200` — `clock` and `random` fields with
  doc comment listing sites that must NOT migrate.
- `src/io/rate_limiter.zig:60-110` — `refillAt` / `consumeAt` /
  `availableAt` / `delayNsAt` deterministic-time API.
- `src/io/event_loop.zig:2316-2375` — rate-limit consume / throttle
  paths snapshot `self.clock.nowNs()` once per call.
- `src/tracker/types.zig:23-36` — `generateKey(rng: *Random)`.
- `tests/clock_random_determinism_test.zig` — determinism assertions.
- `STATUS.md:316-…` — milestone entry.

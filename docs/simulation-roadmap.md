# Simulation Roadmap

Captures the progressive work required to move varuna toward
TigerBeetle / FoundationDB-style full-cluster deterministic simulation.

The current state and three queued phases are documented below. Each
phase unblocks the next; skipping ahead doesn't pay off because earlier
phases close the determinism boundaries that later phases assume.

## Current state (as of 2026-04-28)

What works today, deterministically under SimIO + BUGGIFY:

- `EventLoopOf(SimIO)` — full event-loop tick / completion / timer
  semantics
- `AsyncRecheckOf(SimIO)`, `AsyncMetadataFetchOf(SimIO)`,
  `PieceStoreOf(SimIO)` — IO-generic state machines for the deep
  daemon logic
- `SimSwarm` + `SimPeer` — N scripted peers around 1 daemon-under-test
- `SimulatorOf(Driver)` (`src/sim/simulator.zig`) — owns logical clock,
  seeded PRNG, swarm, fault injection
- 19 sim test files exercising the above — recheck-live BUGGIFY,
  smart-ban, multi-source, etc.

What does NOT yet work deterministically:

- The daemon's startup → run → shutdown lifecycle as a whole (orchestration
  layer is concrete on RealIO, not parameterized)
- SQLite calls (real disk, real threading, outside SimIO)
- DNS lookups (real network, outside SimIO, plus `bind_device` is
  silently bypassed)
- Hasher pool — uses real OS threads via `std.Thread.spawn`
- Security-critical randomness (MSE keys, peer ID, DHT node ID, DHT
  tokens, RPC SID) — deliberately stays on `std.crypto.random` so
  production unpredictability is preserved. Sim tests that touch
  these paths configure around them (`encryption_mode = .disabled`,
  fixed peer IDs) or use behavioural assertions. See
  `src/runtime/random.zig` for the policy.

What now DOES work deterministically (post-Phase-2 SimClock/SimRandom):

- Wall-clock reads via `runtime.Clock` (Real / Sim variants)
- Non-cryptographic randomness via `runtime.Random` (tracker `key`
  migrated; UDP tx IDs / uTP conn IDs / smart-ban tie-breaks
  tracked as follow-up)
- External services — trackers, web seeds, DHT nodes, DNS servers —
  are real or hand-mocked, not sim partners
- Multi-daemon simulation (one daemon per simulator process today)

## Phase 1 — Foundation determinism (in flight)

Goal: every component of a single daemon either runs through the IO
contract or has an explicit non-IO sim equivalent.

In flight on `varuna-2026-04-28-phase1`:

1. **R6 PieceStore.sync wiring** + `bind_device` DNS leak fix +
   AGENTS.md SQLite-threading correction (cheap correctness fixes,
   ~1 day).
2. **Daemon rewire onto `backend.RealIO`** (~1.5 days). The 6-way
   IoBackend selector exists; this turns it from dormant capability
   into something the daemon actually uses. After this, the daemon
   compiles and runs under any of the 5 production backends.
3. **SimResumeBackend (Path A from the storage research)** (~4-5
   days). `ResumeDbOf(Backend)` interface + in-memory simulator with
   FaultConfig knobs. Closes the SQLite-not-in-sim gap; live BUGGIFY
   tests can cover the resume DB path end-to-end.

## Phase 2 — Single-daemon full determinism (queued)

Goal: any single varuna daemon can run inside SimulatorOf with no
remaining nondeterminism boundaries.

1. **Custom DNS library** in the IO contract (~7-10 days, per
   `docs/custom-dns-design.md` and `docs/custom-dns-design-round2.md`).
   Replaces c-ares for the production path while keeping c-ares and
   threadpool as build-flag selectable backends. Closes the DNS
   nondeterminism + the `bind_device` leak; gives BUGGIFY-able DNS
   queries.
2. **SimClock + SimRandom abstractions** (~1-2 days each). DONE
   (`progress-reports/2026-04-29-clock-random.md`). `runtime.Clock`
   (tagged-union over `.real` / `.sim: u64`) and `runtime.Random`
   (tagged-union over `.real` / `.sim: DefaultPrng`) live in
   `src/runtime/`; `EventLoop` carries both as fields. Callers
   migrated for nanos-precision time (`rate_limiter.zig`,
   peer-policy test sites) and one Random consumer
   (`tracker.Request.generateKey`).

   **Crypto-determinism boundary** initially documented as "do not
   cross" — but the team has since committed to closing it. The
   current 5 `std.crypto.random` callers (MSE keys
   `src/crypto/mse.zig`, peer ID `src/torrent/peer_id.zig`, DHT node
   ID `src/dht/node_id.zig`, DHT tokens `src/dht/token.zig`, RPC SID
   `src/rpc/auth.zig`) will migrate to a daemon-seeded CSPRNG.
   Production behavior: at startup, seed a ChaCha20-based CSPRNG once
   from `std.crypto.random.bytes(&seed)`; route all subsequent random
   reads through the seeded instance. Cryptographic strength is
   preserved because a 256-bit seed from a real source plus a modern
   CSPRNG is computationally indistinguishable from a true random
   source for the lifetime of a single daemon process — the standard
   "seed once, generate many" pattern. Sim builds inject a known seed
   via the same surface; same CSPRNG implementation; same code paths;
   just a deterministic seed. This closes the boundary entirely.
   Tracked in STATUS.md "Next" — estimated 3-4 days. Until that lands,
   sim tests touching the 5 callers remain non-byte-deterministic; use
   behavioral assertions instead.
3. **SimHasher** — make the hasher deterministic (~2-3 days). Today
   `src/io/hasher.zig` spawns real OS threads via `std.Thread.spawn`,
   which is the last source of non-determinism the EL can't control.
   Workers should consume scheduled tasks from the simulator's clock
   in test builds, eliminating the thread-spawn boundary entirely. The
   alternative ("accept real threads, EL stays deterministic") is
   rejected — leaving real threads in the picture means hashing-
   related races and re-orderings remain non-reproducible, defeating
   the point of single-daemon-deterministic simulation.

   Two implementation shapes to evaluate:
   - **Tagged-union hasher** (mirrors Clock/Random): `Hasher` is a
     union of `RealHasher` (existing thread pool) and `SimHasher`
     (synchronous compute on the EL thread, scheduled via SimIO's
     completion queue). Daemon callers stay on the alias.
   - **Comptime-parameterized hasher**: `HasherOf(comptime Backend)`
     (mirrors EventLoopOf, AsyncRecheckOf). Heavier cascade since
     `AsyncRecheck` and other consumers hold a hasher pointer.

   The tagged-union shape probably wins given the existing
   Clock/Random precedent and the smaller call-site footprint.

## Phase 3 — Cluster simulation (future)

Goal: instantiate N varuna daemons in one simulator process, with
the simulator brokering all network traffic between them.

This is the FoundationDB / TigerBeetle pattern. It requires sim
equivalents of every external service and a virtual network fabric.

### Phase 3a — External service simulators

External services BitTorrent talks to that need deterministic sim
partners:

1. **SimTracker** (HTTP and UDP). Receives announces, returns peer
   lists with controllable delays, failures, peer-set evolution.
   Highest-value individual sim service for BitTorrent — trackers
   are central to swarm semantics, are the hardest external thing
   to mock in real integration tests, and have well-documented
   protocols (BEP 3 HTTP + BEP 15 UDP). Estimated ~1 week.
2. **SimDht**. KRPC-server simulator. Today varuna can SEND KRPC
   queries via SimIO but there's no DHT-side sim partner that
   answers with realistic node tables, find_node, get_peers, etc.
   ~1 week.
3. **SimWebSeed**. HTTP server simulator. Returns piece bytes via
   Range requests with controllable disconnects, slow streams,
   partial reads. Lower priority than tracker since web seeds are
   optional. ~3-5 days.
4. **SimDnsServer**. Once the custom DNS library exists (Phase 2),
   the simulator can answer UDP DNS queries with controllable
   responses, TTLs, NXDOMAIN, etc. ~3-5 days.

### Phase 3b — Virtual network fabric

The cross-daemon routing layer. When daemon A's `io.send(addr=X, ...)`
writes to a virtual address, daemon B's `io.recv()` (bound to that
address inside the same simulator process) must receive the bytes.

Today's `SimSwarm` is closer to "N scripted peers around 1 daemon"
than "N daemons interconnected." Phase 3b extends SimIO with virtual
addressing + cross-instance routing. Estimated ~500-1000 LOC of new
SimIO machinery. ~1-2 weeks.

### Phase 3c — Multi-daemon simulator container

The actual harness: `SimulatorOf` holds multiple `EventLoopOf(SimIO)`
instances on a shared logical clock. `SimulatorOf.tick(delta_ns)` ticks
each daemon, runs the network fabric, runs the external service sims,
injects faults. Tests exercise scenarios like "5 daemons in a swarm,
one tracker, network partition between daemons 2+3 and the rest" with
seed-deterministic behavior across 32 seeds. ~3-5 days once Phase 3a
+ 3b are in place.

## Sequencing rationale

Phase 1 alone doesn't get cluster simulation — but it removes the
foundational "can the orchestration layer even run under SimIO?"
blocker. Without it, parameterizing TorrentSession over IO produces
a TorrentSession-under-SimIO that still calls real SQLite, real
clock, real RNG.

Phase 2 closes the remaining single-daemon nondeterminism boundaries.
After Phase 2, you can run ONE complete varuna daemon inside
SimulatorOf with full BUGGIFY coverage. That's already enormously
valuable for crash-recovery tests, peer-fault tests, etc.

Phase 3 is the multi-week jump from "one daemon under test" to "N
daemons interacting." It's the highest-payoff step for varuna's
workload (BitTorrent is fundamentally a swarm protocol, and many
correctness scenarios only emerge in multi-node interactions —
choke/unchoke fairness across daemons, smart-ban discrimination
under collusion, etc.). But it's a quarter of work, not a week, and
should not be started until Phase 2 lands and the foundation is
proven.

## Related design docs

- `docs/custom-dns-design.md` + round 2 — Phase 2 DNS work
- `docs/sqlite-simulation-and-replacement.md` — Phase 1 SimResumeBackend
- `docs/mmap-durability-audit.md` — surfaced R6 (Phase 1 cheap fix)
- `docs/epoll-kqueue-design.md` — feeds into Phase 1 daemon rewire
  (multi-backend foundation)
- `progress-reports/2026-04-26-async-recheck-io-generic.md` and
  successors — the IO-generic refactor pattern that Phase 2's
  SimClock/SimRandom should mirror

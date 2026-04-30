# 2026-04-30 — Daemon-seeded CSPRNG closes the crypto-determinism boundary

## What changed and why

Five callers (MSE handshake DH keys, peer ID, DHT node ID, DHT
tokens, RPC SID) were documented in the 2026-04-29 SimRandom round
as a "crypto-determinism boundary" deliberately kept on
`std.crypto.random` for production unpredictability. The boundary
defeated single-daemon byte-determinism for any sim path that
exercised encryption, peer identity, or DHT crypto. This round
closes the boundary by making `runtime.Random` a single CSPRNG with
two seed sources.

## The retrofit

`runtime.Random` (`src/runtime/random.zig`) — both variants now
wrap `std.Random.ChaCha` (ChaCha8 IETF, fast-key-erasure forward
security per Bernstein 2017's "Fast-key-erasure random-number
generators"). Only the seed source differs:

- `Random.realRandom()` reads 32 bytes from
  `std.crypto.random.bytes()` (= Linux `getrandom(2)`) once at
  construction and seeds ChaCha8. After that one call, the
  resulting `Random` value never touches `std.crypto.random`
  again.
- `Random.simRandomFromKey([32]u8)` takes the seed as a parameter.
- `Random.simRandom(u64)` is a back-compat convenience (writes the
  u64 into the first 8 bytes of a 32-byte ChaCha key, leaves the
  rest zero, deterministic).

`Random.seed_length` (= `std.Random.ChaCha.secret_seed_length` =
32) is exposed as a `pub const` on the union for callers that want
to derive a seed from a longer source.

`EventLoop.random` lost its `Random = .real` field default (the old
void variant) and is now initialized explicitly in `EventLoop.initBare`
via `Random.realRandom()`. Tests that overwrite `el.random` with a
sim variant after construction continue to work unchanged.

## Threat model (documented in the file header)

Production rests on three properties:

1. **Seed indistinguishability.** `getrandom(2)` is the same source
   BoringSSL / OpenSSL / Go `crypto/rand` use as their CSPRNG seed.
2. **CSPRNG indistinguishability from random.** ChaCha8 with
   fast-key-erasure is the construction Bernstein recommends and
   the same construction Linux 5.18+'s `getrandom(2)` itself uses
   internally. Distinguishing its output from random implies
   breaking the ChaCha permutation.
3. **Process-local state.** Single-process daemon, no fork, no
   shared memory.

Out of scope: kernel-entropy poverty at boot (mitigated by Linux's
blocking pool on `getrandom`), ASLR / address-space-leak attacks
(any in-process CSPRNG is defeated if the seed leaks), side
channels.

## Plumbing landed (Pattern #14 — all callers, no exceptions)

The `*Random` reference is borrowed from `EventLoop.random` and
threaded through constructors. No module-level globals — same
reasoning as the DNS `bind_device` cleanup round
(`docs/custom-dns-design-round2.md` §1).

Migration map:

- `src/torrent/peer_id.zig:generate(random, masquerade)` —
  `*Random` parameter. Forwarded from
  `src/daemon/torrent_session.zig:create` /
  `createFromMagnet` (constructor signature change), called from
  `src/daemon/session_manager.zig:addTorrent` / `addMagnet` with
  `&el.random`.
- `src/dht/node_id.zig:generateRandom(random)` and
  `randomIdInBucket(random, own_id, bucket)`.
- `src/dht/dht.zig:DhtEngine` — gains a borrowed
  `random: *Random` field; `init` / `create` take it. Internal
  callers (`startBootstrap`'s random target, `refreshBucket`) use
  `self.random`. `src/main.zig` passes `&shared_el.random`.
- `src/dht/token.zig:TokenManager.init(random)`,
  `initWithTime(random, now)`, `maybeRotate(random, now)`. The
  `DhtEngine.tick` rotation site forwards `self.random`.
- `src/crypto/mse.zig:MseInitiatorHandshake` /
  `MseResponderHandshake` — gain a `random: *Random` field;
  `init` / `initWithLookup` take it. Internal padding-length and
  padding-bytes generation switches from `std.crypto.random` to
  `self.random`. The blocking-POSIX `handshakeInitiator` /
  `handshakeResponder` (used only in `varuna-ctl` paths) take an
  explicit `*Random` parameter. `src/io/peer_handler.zig` passes
  `&self.random` at construction (init + initWithLookup).
- `src/rpc/auth.zig:SessionStore.createSession(random)` — the
  production handler in `src/rpc/handlers.zig` retrieves
  `&self.session_manager.shared_event_loop.?.random`.
  `SessionStore.sid_len` was made `pub` so the dedicated test
  file can name the type.

Plus the two non-cryptographic sites the team-lead brief listed
five of but `grep -rn 'std\.crypto\.random' src/` found seven of:

- `src/net/utp.zig:UtpSocket.connect(random, now_us)` (16-bit
  conn-id is collision-avoidance, not security, but routes through
  the same source for sim determinism). `UtpManager.connect` gains
  a `*Random` parameter; `src/io/event_loop.zig` passes
  `&self.random`.
- `src/tracker/udp.zig:generateTransactionId(random)` and
  `fetchViaUdp(allocator, random, request)`. The production
  `UdpTrackerExecutor` (`src/daemon/udp_tracker_executor.zig`)
  gains a borrowed `random: *Random` field populated from
  `&el.random` at create time
  (`src/daemon/session_manager.zig:ensureUdpTrackerExecutor`).

## Verification

```
$ grep -rn 'std\.crypto\.random' src/
src/runtime/random.zig:96:        std.crypto.random.bytes(&seed);    # the seed
src/runtime/random.zig:228:    std.crypto.random.bytes(&seed);       # the determinism test
src/io/dns_custom/query.zig:66:    /// poisoning defense (...)        # docstring only
... + 5 sites in `runtime/random.zig`'s file header documenting
    the migration history.
```

Production code now reads from `std.crypto.random` exactly once
per daemon process, at `EventLoop.initBare` time.

## Tests

`tests/csprng_determinism_test.zig` (new) — 11 byte-equality
tests:

- `simRandomFromKey` is byte-deterministic across instances
- distinct seeds produce distinct streams
- per-caller byte-determinism: peer ID (default + masqueraded),
  DHT node ID, token-manager init, token-rotation, RPC SID, MSE
  initiator DH key, MSE responder DH key
- whole-daemon scenario (peer ID → node ID → token → SID → MSE
  init under one shared `*Random`) reproduces every output across
  two runs with the same seed; differs across distinct seeds
- 32-byte key shape reproduces sensitive outputs

Inline tests in each migrated file gain a "byte-deterministic
under SimRandom" assertion.

Test count delta: ~17 new tests across `random.zig`,
`peer_id.zig`, `node_id.zig`, `token.zig`, `auth.zig`, plus the
dedicated determinism file. `zig build test` shows
1656/1673 → 1679+ tests passing on the same baseline (1 known
flaky `sim_multi_source_eventloop_test` per the open team
investigation; that flake predates this work).

## Surprises

1. **Seven callers, not five.** Team-lead brief cited five
   (MSE / peer-id / node-id / token / SID). `grep` after the
   migration found two more (uTP conn-id, UDP tracker tx-id).
   Both were in the original `runtime.Random` docstring's "Safe to
   swap for Random in tests" list. Migrating them alongside is
   what Pattern #14 demands and means the determinism story is
   complete.

2. **`EventLoop.random` field default.** The old `Random = .real`
   default worked because `.real` was a void variant. With ChaCha
   state in the payload, the default became invalid; explicit
   `Random.realRandom()` initialization in `initBare` replaced
   it. Every test that overwrites `el.random` with a sim variant
   continues to work unchanged.

3. **`fetchViaUdp` is varuna-ctl, not daemon.** The synchronous
   `fetchViaUdp` path is blocking POSIX I/O — the daemon goes
   through `UdpTrackerExecutor` instead. So `fetchViaUdp` takes a
   `*Random` parameter; varuna-ctl callers (`src/tracker/announce.zig`
   when `udp://...`) build a fresh `realRandom()` locally. Sim
   tests in `tests/udp_tracker_test.zig` use a file-scoped
   sim-seeded RNG.

4. **`SessionStore.createSession` doesn't have an EventLoop in
   its scope.** The `ApiHandler` holds a `*SessionManager`, which
   holds an optional `*EventLoop`. In the production path the
   handler grabs `&self.session_manager.shared_event_loop.?.random`.
   The defensive fallback (`var fallback = realRandom()` if no
   shared event loop) is documented as unreachable in production
   but lets standalone tests construct an ApiHandler.

## Remaining issues / follow-up

- Two pre-existing test flakes (recheck SimIO + sim_smart_ban
  Phase 2B) are unrelated to this work and are tracked separately.
- The `src/io/dns_custom/query.zig` reference to
  `std.crypto.random.intRangeAtMost` is in a docstring describing
  cache-poisoning defense for future custom-DNS work; it is not
  production code today.
- `progress-reports/2026-04-29-clock-random.md`'s "crypto-
  determinism boundary, explicitly accepted" section is now
  superseded by this round's closure but kept for historical
  context.

## Key code references

- Threat model + design notes:
  `src/runtime/random.zig:1-89` (file-header docstring).
- ChaCha8 backing implementation: `std.Random.ChaCha` (Zig
  stdlib).
- Determinism tests:
  `tests/csprng_determinism_test.zig:1-220`.
- Plumbing entry point: `src/io/event_loop.zig:182-194` (the
  `random: Random` field + comment).
- Production seeding site:
  `src/io/event_loop.zig:initBare` (sets `random =
  Random.realRandom()`).
- STATUS milestone: `STATUS.md` "Last Verified Milestone
  (2026-04-30 — daemon-seeded CSPRNG closes the
  crypto-determinism boundary)".
- Roadmap update: `docs/simulation-roadmap.md` Phase 2 #2.

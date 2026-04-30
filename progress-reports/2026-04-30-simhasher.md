# 2026-04-30 — SimHasher: deterministic hasher backend for sim tests

## What changed

`src/io/hasher.zig` now exposes a tagged-union `Hasher`:

```zig
pub const Hasher = union(enum) {
    real: *RealHasher,
    sim: *SimHasher,
    // … submitVerify[Ex], submitMerkleJob, drainResultsInto,
    //    drainMerkleResultsInto, hasPendingWork, getEventFd,
    //    threadCount, deinit — all dispatch on the active variant
};
```

Mirrors `runtime.Clock` and `runtime.Random` exactly (Real / Sim
variants under one type; daemon callers stay on the alias; sim tests
construct the deterministic variant from a seed).

- `RealHasher` is the existing thread-pool implementation (`src/io/
  hasher.zig:25`). Renamed in Commit 1; behaviour unchanged.
- `SimHasher` (Commit 2) hashes synchronously on the caller (EL)
  thread and pushes the result onto its internal queue. The next
  `peer_policy.processHashResults` call (which `EventLoop.tick` runs
  every iteration) drains it. No worker thread, no condvar, no
  eventfd.
- The tagged-union dispatcher (Commit 3) wraps both. Production
  callers continue writing `Hasher`; the new constructors are
  `Hasher.realInit(allocator, thread_count)` and
  `Hasher.simInit(allocator, seed)`.

## Why a tagged union and not a `HasherOf(comptime Backend)` cascade

Three reasons:

1. **Precedent.** SimClock and SimRandom both went tagged-union.
   Hashing has a similar call-site footprint (event_loop, peer_policy,
   recheck, web_seed_handler, protocol) and a similar cost model
   (dispatch-on-call, not dispatch-in-tight-loop) — a one-branch switch
   is amortised against the SHA-1/256 work.
2. **No type cascade through `AsyncRecheckOf`.** A comptime-
   parameterised hasher would have to flow through every consumer's
   generic graph. `AsyncRecheckOf(IO)` already holds a `*Hasher`
   pointer; widening it to `HasherOf(Backend)` would force tests
   instantiating it against `SimIO` to also pick a hasher backend
   explicitly. The tagged-union shape lets the existing pointer field
   stay on the union type unchanged.
3. **Pointer-in-variant, not value-in-variant.** RealHasher's worker
   threads hold a pointer to the parent struct. A `union(enum) { real:
   RealHasher, sim: SimHasher }` would put the inner struct inline
   inside the Hasher allocation; relocating the union (an assignment,
   a return-by-value, a defensive copy) would relocate the parent and
   leave the workers with stale pointers. `*RealHasher` / `*SimHasher`
   keep the inner struct's address stable for the lifetime it was
   created at, and the union just discriminates.

## Why "synchronous compute, queued result" not "schedule via SimIO"

The brief floated wiring SimHasher submissions through a SimIO
completion queue (mirroring how SimIO's POSIX file pool defers file
ops). That would have meant SimHasher takes a `*SimIO` reference and
each submit calls `sim_io.schedule(...)` to fire the result on the
next `tick`. Two reasons that ended up unnecessary:

1. **The current public API doesn't carry an SimIO reference into
   the hasher.** Plumbing it through would either widen the
   constructor (every sim test passes its SimIO twice) or require
   pattern-matching the union at every consumer site. Neither buys
   anything because:
2. **Consumers already drain every tick.** `EventLoop.tick` calls
   `peer_policy.processHashResults` and `processMerkleResults`
   first-thing on every iteration. So a result pushed onto SimHasher's
   queue during tick N is consumed by the EL inside tick N's same
   call sequence — same delivery shape as SimIO would produce, just
   without the indirection. A test that wants the result to "fire on
   the next tick instead of this one" doesn't currently exist; if one
   does in the future, adding the `*SimIO` plumbing is a self-
   contained follow-up.

The synchronous-and-queued shape also matches the production hasher's
"fire-and-forget submit, result one tick later" timing model close
enough to keep the EL's behaviour realistic — submit returns fast,
result arrives on the next tick.

## Fault injection

`SimHasher.FaultConfig.merkle_pread_fault_prob: f32` (default 0.0)
gates a roll on the SimHasher's own seeded `std.Random.DefaultPrng`.
When the roll fires, the pread inside `processMerkleJob` is treated as
failed and the job returns `piece_hashes = null` — the same shape
RealHasher's worker produces on a real pread error. Two SimHashers
constructed with the same seed produce the same fault sequence
byte-for-byte, asserted by the inline test "same seed produces same
fault sequence".

Verification (the SHA-1 / SHA-256 path) doesn't need a fault knob: the
"hash mismatch → invalid Result" path is itself the failure surface,
and tests can produce mismatches by submitting the wrong expected
hash.

## What was rewired (stretch)

`tests/recheck_test.zig`:
- `AsyncRecheckOf(SimIO): all pieces verify against registered file
  content`
- `AsyncRecheckOf(SimIO): corrupt piece is reported incomplete`
- `AsyncRecheckOf(SimIO): all-known-complete fast path skips disk
  reads`

All three previously initialised the EventLoop with `hasher_threads =
1` (real thread pool against SimIO completions). The first two were
flaky in ~25 % of CI runs because the recheck pipeline submits each
piece's hash job into the pool, then loops `el.tick()` until the
recheck callback fires; under contention the worker fell behind the
SimIO tick cadence and the 1024-tick budget ran out.

Rewire: pass `hasher_threads = 0` so `initBareWithIO` doesn't allocate
a RealHasher, then `el.hasher = try Hasher.simInit(allocator, seed);`.
SimHasher hashes synchronously on the EL thread; the next tick's
`processHashResults` drains it deterministically. 0/8 failures across
fresh runs.

## Test coverage delta

7 new inline tests in `src/io/hasher.zig`:

- `SimHasher: same input produces same valid/invalid verdict
  (determinism)` — submits one valid + one invalid piece across three
  seeds; asserts submit-order preservation and verdict.
- `SimHasher: spawns no real threads` — `threadCount() == 0`,
  `getEventFd() == -1`.
- `SimHasher: results visible on next drain (queue lifecycle)` —
  drain returns nothing pre-submit, returns one post-submit, queue
  empties after drain.
- `SimHasher: deinit defensively frees outstanding piece bufs` —
  testing.allocator panic-on-leak guards the regression that
  motivated the production hasher's defensive deinit.
- `SimHasher: merkle build hashes file pieces synchronously` —
  same fixture as RealHasher's merkle test, asserts SHA-256 of two
  64-byte pieces matches.
- `SimHasher: merkle pread fault knob fails the job` — pin
  `merkle_pread_fault_prob = 1.0`, assert `piece_hashes == null`.
- `SimHasher: same seed produces same fault sequence` — two
  SimHashers seeded identically produce identical fault rolls over
  1024 trials.

Suite size: 1656 → 1663 (+7).

## What was NOT touched

- `src/io/io_interface.zig`, IO backends — out of scope.
- `runtime.Clock` / `runtime.Random` — read for the pattern-mirroring
  pass; not modified.
- `src/crypto/`, `src/dht/`, `src/torrent/peer_id.zig`, `src/rpc/auth.
  zig` — csprng-engineer's territory.
- The two other flaky tests observed during validation
  (`sim_smart_ban_phase12_eventloop_test`, `sim_multi_source_eventloop_test`)
  — separate failure surfaces tracked by the team, not a SimHasher
  symptom.

## Surprises

1. **Inline-mode `RealHasher.create(allocator, 0)` was dead code.** The
   existing constructor accepted `thread_count == 0` and short-circuited
   to a synchronous-submit path, but the only caller (`EventLoop.
   initBareWithIO`) gates on `hasher_threads > 0` *before* calling
   `create`. So the inline path was unreachable from production. Left
   the code in place inside RealHasher (zero risk of breaking
   anything; it's still a documented path) but SimHasher is what
   replaces its intended use.

2. **`Hasher.create(...)` consumers were exactly two.** event_loop.
   zig:444 and tests/event_loop_health_test.zig:87. Renaming to
   `Hasher.realInit` was a two-line change. Worth the asymmetry with
   `Hasher.simInit` for the explicit-backend-at-construction surface.

3. **`event_loop_health_test.zig:69` "EL.deinit drains hasher.
   completed_results" relies on real workers.** The test sleeps 10 ms
   and waits for `hasPendingWork` to flip — that requires an actual
   worker thread to populate `completed_results`. It still uses
   RealHasher; SimHasher would defeat the regression it guards (the
   "hasher worker produced a Result before EL deinit drained it"
   timing race). Left as-is.

## Key code references

- `src/io/hasher.zig:25` — `RealHasher` (renamed; same code).
- `src/io/hasher.zig:553` — `SimHasher`.
- `src/io/hasher.zig:842` — tagged-union `Hasher` dispatcher.
- `src/io/event_loop.zig:443-446` — `Hasher.realInit` call site.
- `tests/event_loop_health_test.zig:87` — `Hasher.realInit` call site.
- `tests/recheck_test.zig:562-581` — first SimHasher injection
  (happy-path test).
- `tests/recheck_test.zig:675-686` — second SimHasher injection
  (corrupt-piece test).
- `tests/recheck_test.zig:768-782` — third SimHasher injection
  (fast-path test).

## Follow-up

- **`getEventFd` on the union.** SimHasher returns `-1`; RealHasher
  returns its eventfd. No production caller currently invokes
  `getEventFd` (it's a leftover from an earlier eventfd-based
  result-wakeup that the swap-buffer drain replaced). Keep both for
  parity but consider removing if no caller emerges by Phase 3.
- **`SimHasher` integration with the broader simulator.** Phase 3
  (cluster simulation) will instantiate N daemons in one
  process. Each daemon's SimHasher already takes its own seed, so
  cross-daemon determinism falls out of the existing seed plumbing.
- **CSPRNG migration (separate "Next" item).** SimHasher closes the
  thread-spawn boundary. The remaining single-daemon nondeterminism
  boundary is the 5-callers `std.crypto.random` set (MSE keys, peer
  ID, DHT node ID, tokens, RPC SID). That's tracked separately in
  STATUS.md and in `docs/simulation-roadmap.md` Phase 2 #2.

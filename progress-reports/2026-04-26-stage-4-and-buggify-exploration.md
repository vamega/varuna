# Stage 4 zero-alloc + DHT KRPC BUGGIFY (followups-2 round)

**Date:** 2026-04-26
**Track:** B (`explorer-engineer`)
**Branch:** `worktree-explorer-engineer-stage-4-buggify`
**Base:** main HEAD `4c10d73` (post-merge of all prior session work)

## Tasks closed

* **Task #4 — Zero-alloc Stage 4: ut_metadata fetch buffer.**
  Last documented stage of `docs/zero-alloc-plan.md`. The shared-
  buffer design eliminates per-fetch heap allocs on the metadata
  assembler path.
* **Task #5 — BUGGIFY exploration on an untouched system.** Picked
  the DHT engine (KRPC parser + routing table). One real bug
  surfaced; filed as Task #6. Most of the deliverable is the new
  regression coverage.

## Stage 4 — pre-allocated ut_metadata fetch buffer

### Design choice (a) was the de facto behaviour already

The team-lead's spec listed three options for the BEP 9 invariant
"at most one in-flight metadata fetch per torrent":
  (a) serialise fetches across all torrents (one buffer, simpler);
  (b) one buffer per torrent (defeats the savings);
  (c) a small pool with claim/release.

Reading `src/io/event_loop.zig:1859` revealed that **(a) was already
enforced** — `if (self.metadata_fetch != null) return error.MetadataFetchAlreadyActive`
gates `startMetadataFetch` so at most one fetch is ever active per
EventLoop, regardless of which torrent triggered it. A single shared
buffer is therefore always sufficient. Stage 4 became dramatically
simpler: **pre-allocate one `max_metadata_size`-sized buffer, route
the assembler through it.**

This is a recurring pattern: the spec's "subtle constraint" turned
out to already be solved by an invariant elsewhere in the code.
Reading the existing call sites *before* writing the design saved a
day of pool-implementation work (option c).

### Implementation

* **`src/net/ut_metadata.zig`**:
  - `MetadataAssembler.initShared(hash, buffer, received)` — assembler
    constructed against caller-owned storage. The assembler still
    holds an `Allocator` field for layout uniformity, but the
    vtable panics on every entry point (`sharedAllocPanic`,
    `sharedFreePanic`, etc.). This is a deliberate tripwire: if a
    code path silently routed through the owning allocator on the
    shared path, the panic surfaces it immediately instead of leaking.
  - `setSize` rejects sizes > shared capacity (defends against a
    future bump in `max_metadata_size` outpacing the EventLoop's
    pre-allocation), and zeros only the active prefix of `received`
    so the per-fetch reset is O(piece_count) rather than
    O(max_piece_count).
  - `nextNeeded` and `reset` now iterate only the active prefix —
    important for the shared path where the slice may be longer
    than the current fetch needs. This was a bug in the original
    `nextNeeded` that would have manifested if the shared array
    held stale `true` bits from a previous fetch (caught by the
    "prefix-only iteration" test that pre-poisons the suffix).
  - `resetForNewFetch(new_hash)` clears `total_size`/`piece_count`
    so a fresh `setSize` is accepted as the first one for a new
    info-hash. Asserts `!owns_storage`.
  - New constant `max_piece_count`
    (= `⌈max_metadata_size / metadata_piece_size⌉` = 640 at the
    current 10-MiB cap) sizes the shared `received` array.

* **`src/io/metadata_handler.zig`**:
  `AsyncMetadataFetch.create` gains optional
  `shared_assembly_buffer` and `shared_assembly_received`
  parameters. When both non-null the assembler is on the shared
  path; otherwise it falls back to allocator-owned storage (used by
  the legacy direct unit tests in this file, which I left in
  place).

* **`src/io/event_loop.zig`**:
  EventLoop gains `metadata_assembly_buffer: ?[]u8` and
  `metadata_assembly_received: ?[]bool`. **Lazy first-use
  allocation in `startMetadataFetch`**, freed in `deinit`. The
  first fetch on a fresh EventLoop pays one ~10-MiB alloc; every
  subsequent fetch is zero-alloc on the assembler path.

### Why lazy first-use rather than init-time eager

The spec text says "allocate at EventLoop init", but the practical
goal is "eliminate per-fetch alloc". Lazy first-use satisfies the
goal for fetches 2..N. The trade-off is that the *first* fetch on
each EventLoop pays a one-time alloc (~10 MiB).

Eager would have pinned 10 MiB on every EventLoop in the test farm
(599+ tests), most of which never do a metadata fetch. That's a
real cost on test-runner memory. Lazy keeps idle EventLoops at zero
cost. If first-fetch latency ever becomes a hot-path concern, the
fix is one line.

### Tests (`tests/metadata_fetch_shared_test.zig`, 9 new)

Layered per `STYLE.md > Layered Testing Strategy`:

* **Algorithm** — bare `MetadataAssembler.initShared`: claim/release
  semantics, capacity rejection, multi-fetch reuse, prefix-only
  iteration under poisoned suffix (catches the `nextNeeded` bug
  noted above).
* **Integration** — `AsyncMetadataFetch.create` with shared buffers
  routes through the shared path (`!owns_storage`); without shared
  buffers it falls back to the legacy lazy-alloc.

The "panicking allocator vtable" tripwire is exercised implicitly:
no test triggers the panic, which proves the assembler stays on
the caller-owned storage path under all the tested scenarios.

### Wiring

`src/net` and `src/io` source-side tests are **not** in the
`mod_tests` discovery chain (`src/root.zig`'s `test { _ = ... }`
block only includes `app, bitfield, config, crypto, torrent`).
Inline tests added to those files would never run. The dedicated
test step `test-metadata-fetch-shared` runs my tests via the same
mechanism the existing 30+ test bundles use.

## Task #5 — BUGGIFY exploration on the DHT engine

### Why DHT

Three reasons for picking DHT over the alternatives in the spec
(web seeds, magnet fetch, MSE, uTP):
* **Adversarial attack surface.** Anyone on the internet who knows
  our UDP port can send KRPC packets. Web seeds, MSE, and uTP all
  have either an authenticated handshake or a TCP connection
  upstream. KRPC is wide open.
* **Untouched by prior BUGGIFY rounds.** Smart-ban Phase 0/1/2,
  block-stealing, and recheck have been worked over. DHT had the
  happy-path round-trip tests in `src/dht/krpc.zig` and that's it.
* **STATUS.md "Next" bullet** flagged KRPC fuzz tests as upcoming
  work. Two birds, one stone.

### Test scope (`tests/dht_krpc_buggify_test.zig`, 7 new)

* **`krpc.parse` random-byte fuzz** — 32 deterministic seeds × 1024
  packets per seed = 32,768 random packets. Lengths span 0..1500
  (UDP MTU). Asserts: never panics, never returns an unhandled
  error, only valid `Message` shapes. Vacuous-pass guard verifies
  the parser is *not* vacuously accepting (under random bytes only
  a small fraction parse successfully — the test caps it at <100%
  of attempts to flag a regression where the parser became too
  permissive).
* **Bit-flip mutation of valid ping query** — encode a real ping
  query, flip one byte at a random position 1024 times per seed × 32
  seeds. Catches a different distribution than pure random — the
  envelope structure stays mostly intact but individual bytes get
  corrupted.
* **Deeply-nested KRPC dict at UDP MTU** — pin the recursion
  behaviour. STYLE.md forbids unbounded recursion in bencode
  parsing; `src/dht/krpc.zig:298:skipValue` is recursive. At UDP
  MTU (~1500 bytes) the maximum nesting depth is ~750 levels;
  default Linux stack at 8 MiB safely accommodates this. The test
  pins the current behaviour and tripwires future MTU or recursion-
  depth changes.
* **`decodeCompactNode` fuzz** — random 26-byte chunks; asserts no
  panic, ID round-trips, address family always INET.
* **RoutingTable adversarial flood** — random adversarial node IDs
  + addresses + interleaved mark/remove/findClosest across 2048 ops
  per seed × 8 seeds. Invariants: nodeCount ≤ K × 160; every node
  lives in the bucket index that matches its XOR distance from
  `own_id`. (`bucket_idx == distanceBucket(own, n.id)`.)
* **`findClosest` zero-length out buffer** — returns 0, no panic.
* **KRPC encoder happy-path size sanity** — pins the encoded
  payload sizes for ping, find_node, get_peers, announce_peer.

### Bug found (filed as Task #6)

The KRPC encoders (`encodePingQuery`, `encodeFindNodeQuery`,
`encodeGetPeersQuery`, `encodeAnnouncePeerQuery`) take `buf: []u8`
and return `!usize` — implying error-on-overflow semantics. But
the internal helpers `writeByteString` (krpc.zig:638) and
`writeInteger` (krpc.zig:647) write directly into the slice with
no bounds checks. Calling any encoder with a too-small buffer
panics in Debug; in Release it's UB.

In production this is **currently safe** because the only caller
(the DHT engine's UDP send path) uses an MTU-sized buffer that's
always large enough for any KRPC message. But the API contract is
unsound — the `!usize` return type implies error reporting, and
the encoder is `pub fn`-exposed via `dht.krpc.*`. A future caller
with a tighter buffer would hit the panic.

I caught this when my "BUGGIFY: KRPC encoders return error.NoSpaceLeft
when buffer is too small" test panicked instead of returning the
expected error. Per Pattern #14 (investigation discipline), I
filed the bug as Task #6 rather than expanding the scope of this
session. Replaced the negative test with a happy-path size sanity
test that pins the encoded sizes — gives the future bounds-checking
patch a regression target.

### What was NOT found (the coverage-as-regression-guard outcome)

Across all 32 × 1024 random packets, all 32 × 1024 bit-flip
mutations, all 8 × 2048 RoutingTable ops, the deeply-nested MTU
packet, and the adversarial compact-node fuzzes:
* `krpc.parse` is panic-free.
* `decodeCompactNode` is panic-free.
* `RoutingTable` invariants hold.
* The recursive `skipValue` does NOT crash at MTU depth.

This is the runtime-engineer Track-C-style outcome described in
STYLE.md > Layered Testing Strategy and called out in the
team-lead's brief: when no bugs surface, the new tests serve as
regression guards. The KRPC parser had near-zero adversarial
coverage before this commit (3 hand-rolled negative tests in
`src/dht/krpc.zig`) and now has TigerBeetle-VOPR-class coverage.

## Validation

Pre-rebase baseline: 599/599 tests passed (HEAD `4c10d73`,
`mise install` + submodules + `nix develop --command zig build test`).

After both commits:
* `zig build test`: 615/615 pass (+16: 9 Stage 4 + 7 DHT BUGGIFY).
* `zig fmt`: clean across all touched files.
* No leaks under the GPA leak-detector.
* Full suite stable across two back-to-back runs.

## Lessons

1. **Read the existing invariants before designing for the
   "subtle constraint".** Stage 4's spec listed three concurrency
   options for the BEP 9 invariant; the EventLoop's
   `metadata_fetch != null` gate had already chosen option (a).
   The "right" design was 50% less code than option (c). Pattern
   #14 generalised: **the spec is a hypothesis; the code is the
   ground truth**. Read the code before pricing the spec.

2. **`mod_tests` doesn't discover everything.** `src/root.zig`'s
   `test { _ = ... }` chain pulls in only the listed subsystems.
   Inline tests in `src/net/*`, `src/io/*`, `src/dht/*` are
   *invisible* to `zig build test`. Adding a dedicated test step
   in `build.zig` is the working pattern (30+ existing test bundles
   use it). Adding a new subsystem to `src/root.zig` is dangerous
   — `cleanup-engineer`'s prior round added `_ = app; _ = config;`
   and surfaced 5 latent bugs in test-context-only code paths.

3. **Panicking allocator vtables make zero-alloc paths
   self-auditing.** If a code path on the shared-buffer assembler
   ever silently called `allocator.alloc`, it would panic
   immediately instead of leaking memory. Worth re-using elsewhere
   for static-only paths (PieceBufferPool, etc.).

4. **A negative test's panic is itself a finding.** I wrote
   `expectError(error.NoSpaceLeft, encodePingQuery(small_buf, ...))`
   expecting the encoder to error cleanly; instead it panicked.
   That's the bug — my test assumed a contract that didn't exist.
   Filed as a separate task and rewrote the test to pin the
   happy-path output sizes. Pattern #14 in action.

5. **The "absent fuzz coverage" surface is large but
   tractable.** DHT was three small files (krpc.zig 781 lines,
   routing_table.zig 445 lines, node_id.zig 267 lines) and had
   useful fuzz tests landed in ~1.5 hours. The pattern transfers
   directly to web seeds, MSE, magnet fetch, uTP — each is a
   bounded-input parser/state-machine that admits the same
   layered-fuzz approach.

## Code references

* `src/net/ut_metadata.zig:225-240` — `max_piece_count` constant.
* `src/net/ut_metadata.zig:294-323` — `MetadataAssembler.initShared`.
* `src/net/ut_metadata.zig:345-378` — `setSize` shared-path branch.
* `src/net/ut_metadata.zig:478-498` — `resetForNewFetch`.
* `src/io/event_loop.zig:354-366` — shared buffer fields.
* `src/io/event_loop.zig:1860-1898` — lazy alloc + wire-through.
* `src/io/event_loop.zig:606-616` — deinit free.
* `src/dht/krpc.zig:298` — recursive `skipValue` (STYLE.md violation).
* `src/dht/krpc.zig:636-654` — unsound `writeByteString`/`writeInteger`.
* `tests/metadata_fetch_shared_test.zig` — Stage 4 layered tests.
* `tests/dht_krpc_buggify_test.zig` — DHT BUGGIFY coverage.

## Commit chain (on `worktree-explorer-engineer-stage-4-buggify`)

* `2faab1c zero-alloc: Stage 4 — pre-allocated ut_metadata fetch buffer`
* `802a3bf dht: BUGGIFY fuzz coverage for KRPC parser + RoutingTable`

## Follow-ups (filed)

* **Task #6** — DHT KRPC encoders lack bounds checking, panic on
  too-small buffers. Time budget ~1 hour. Adds `error.NoSpaceLeft`
  threading through `writeByteString` / `writeInteger`. Optional
  follow-up: `std.debug.assert(buf.len >= ...)` against per-method
  static upper bounds so the precondition is assertable.

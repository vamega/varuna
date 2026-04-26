# AsyncMetadataFetch IO-generic Refactor — 2026-04-26

Track 3 (refactor-engineer-metadata-fetch): completed the
`AsyncMetadataFetchOf(comptime IO: type)` refactor mirroring the
Track B (AsyncRecheck) blueprint that landed earlier today
(`progress-reports/2026-04-26-async-recheck-io-generic.md`). With
this, the post-Stage-2 IO abstraction migration covers the BEP 9
metadata fetch state machine too.

Two coherent commits, tests pass at every commit (pattern #8).
Test count: **689 → 692 (+3 `AsyncMetadataFetchOf(SimIO)` integration
tests in `tests/metadata_fetch_test.zig`)**. `zig build`: clean.
`zig fmt`: clean.

## What changed

### 3A — `AsyncMetadataFetchOf(IO)` parameterisation (commit `69c9287`)

`src/io/metadata_handler.zig` now defines
`AsyncMetadataFetchOf(comptime IO: type) type` returning the BEP 9
state machine struct, and `pub const AsyncMetadataFetch = AsyncMetadataFetchOf(RealIO)`
preserves the daemon-side surface. Methods use `self: *Self` rather
than `*AsyncMetadataFetch`; the three per-completion callbacks
(`metadataConnectComplete`, `metadataSendComplete`,
`metadataRecvComplete`) likewise dispatch through `*Self` so each
instantiation gets its own concrete type.

`EventLoopOf` declares a per-instantiation alias:

```zig
pub const AsyncMetadataFetch = metadata_handler.AsyncMetadataFetchOf(IO);
```

So `metadata_fetch: ?*AsyncMetadataFetch`, `startMetadataFetch`'s
`on_complete` callback signature, and the `AsyncMetadataFetch.create`
call all reference the matching IO type.

Daemon-side callers — `src/daemon/torrent_session.zig`,
`tests/metadata_fetch_shared_test.zig` — stay unchanged because they
reference `AsyncMetadataFetch` (the `AsyncMetadataFetchOf(RealIO)`
alias). Lazy method compilation (pattern #10) means the SimIO
instantiation only forces method bodies through the type-checker
when a SimIO test actually drives them.

### 3B — `AsyncMetadataFetchOf(SimIO)` foundation integration tests (commit `478fa19`)

Three end-to-end tests in a new `tests/metadata_fetch_test.zig`:

1. **"no peers finishes immediately"** — instantiates with an empty
   peer list. `start()` must call `finish(false)` synchronously; the
   callback fires before any ticks. Asserts
   `el.metadata_fetch.?.done == true`, `result_bytes == null`.

2. **"connect-error fault drains all peers and finishes"** — uses
   `connect_error_probability = 1.0` so every `self.io.connect(...)`
   completion delivers `error.ConnectionRefused`. With five peers
   (more than `max_slots = 3`), the state machine cycles through
   connect → fail → tryNextPeer → refill, exhausts peers, and
   `finish(false)`s. Asserts `peers_attempted == 5`.

3. **"legacy-fd send path causes all peers to fail"** — no fault
   injection. `posix.socket()` returns a real kernel fd well below
   SimIO's `socket_fd_base = 1000`, so SimIO's `slotForFd` returns
   null and `send` falls through the legacy zero-byte-success path.
   `onSendComplete` treats `res = 0` as failure
   (`if (res <= 0) ... releaseSlot; tryNextPeer`); each peer fails
   after handshake-send. Drives the connect → send → fail → next
   transition through three peers.

Together these prove `AsyncMetadataFetchOf(IO)` is real (not just
typechecks) and force compilation of every method that the state
machine traverses for connect / send / recv error handling.

## Methodology notes

### Pattern #15 — read existing invariants first

Mirrored the AsyncRecheck refactor exactly:
- Same `pub fn FooOf(comptime IO: type) type` shape
- Same `pub const Foo = FooOf(RealIO)` daemon alias
- Same per-IO nested type pattern in `EventLoopOf`
  (`pub const AsyncMetadataFetch = metadata_handler.AsyncMetadataFetchOf(IO)`)

No new design decisions on the parameterisation itself. The
recheck progress report
(`progress-reports/2026-04-26-async-recheck-io-generic.md`) was
already correct for this shape; this is a smaller-scope rerun.

### Pattern #14 — investigation discipline (the big asymmetry)

The AsyncRecheck refactor reached a 3-test happy-path integration
suite end-to-end via `SimIO.setFileBytes(fd, bytes)`. AsyncMetadataFetch
**does not** trivially admit the same shape, and I deliberately did
**not** invent a new pattern for it — flagged for follow-up instead.

The asymmetry: AsyncRecheck's I/O is one-way (read piece bytes from
a pre-opened file fd; SimIO returns scripted bytes). AsyncMetadataFetch's
I/O is bidirectional protocol — the state machine sends a BT
handshake, recvs a peer handshake, sends an extension handshake,
recvs an extension handshake reply, sends a ut_metadata request,
recvs a piece response. Each step's send must succeed and each
recv must contain a protocol-correct response keyed to the previous
send. SimIO doesn't currently support scripting this — `setFileBytes`
is for `read()`, and there's no equivalent for the
`socket()` → `connect()` → `send()` ↔ `recv()` chain.

Worse, `connectPeer` calls `posix.socket()` directly (not
`self.io.socket()`), so the resulting fd is a real kernel fd that
SimIO doesn't recognise. With a real fd, SimIO's `slotForFd` returns
null and both `recv` and `send` fall through to the legacy zero-byte
success path. That's enough to drive the **error** paths I tested
(send returns 0 → fail → next peer), but not the happy path.

Two viable design options for the follow-up:

- **(a) Refactor socket creation through the IO interface.** Replace
  `connectPeer`'s `posix.socket()` with `self.io.socket()` so SimIO
  returns a synthetic fd tied to a SimIO socket-pool slot. The state
  machine becomes `socket → connect → send` instead of sync-socket +
  async-connect. SimIO's existing `createSocketpair` mechanism then
  drives the BEP 9 protocol via a fake peer on the partner side. This
  is cleaner architecturally but adds a callback step.

- **(b) Extend SimIO with `setSocketRecvScript(fd, bytes)`.** Mirrors
  `setFileBytes` shape but for recv. Modify SimIO's `recv` to consult
  the script map ahead of `slotForFd` so a real-fd path works.
  Modify `send` to "swallow successfully" (return `op.buf.len`) on
  scripted fds. The test still has to predict / discover what fd
  `posix.socket()` will return, which is fragile but workable in a
  single-threaded test process.

I'm flagging both options in STATUS.md "Next" rather than picking
one in this round. Either approach also unlocks a live-pipeline
BUGGIFY harness for `AsyncMetadataFetchOf(SimIO)` analogous to the
AsyncRecheck follow-up. Per the team-lead brief: "If you finish
early and feel tempted to land a live-pipeline BUGGIFY harness for
the new `AsyncMetadataFetchOf(SimIO)`, stop — that's worth doing
but should be its own follow-up round."

### Pattern #10 — lazy method compilation lets the migration ship

Daemon-side callers stayed on the `AsyncMetadataFetchOf(RealIO)`
alias without recompiling. Only the SimIO test paths in commit `3B`
force the second instantiation when those tests actually call into
the state machine. The `EventLoopOf(SimIO)` plumbing is already in
place from Stage 2; this work just plumbs `AsyncMetadataFetchOf`
through it.

`zig build` (full daemon binary): clean. `zig build test --summary all`:
692/692 passed. Verified the daemon path picks up the
`AsyncMetadataFetchOf(RealIO)` alias unchanged.

### Pattern #8 — tests pass at every commit

Two coherent commits, each compiling and passing the full test
suite:

1. `69c9287` — `AsyncMetadataFetchOf(IO)` + alias. Tests: 689 →
   689 (mechanical generic-ification, no behavioural change). Note:
   the recheck report's "620 → 631" baseline was pre-Track-1 BUGGIFY;
   Track 1's parallel work added the ut_metadata + uTP SACK BUGGIFY
   tests (commit `c026158`) which raised the baseline to 689 by
   the time this commit landed.
2. `478fa19` — `AsyncMetadataFetchOf(SimIO)` foundation integration
   tests. Tests: 689 → 692 (+3).

Bisectable. If either regresses something, `git bisect` lands on it.

## Parallel-track coordination notes

This work landed on `worktree-parser-audit-roundN` alongside Track 1
(`untrusted-input parser audit hunt`) and Track 2 (`Live-pipeline
BUGGIFY harness for AsyncRecheckOf`). Track 1 committed
`199a0b6 ut_metadata: harden BEP 9 parser`, `76a7043 utp: bound
SelectiveAck.decode`, and `c026158 BUGGIFY harness for ut_metadata
+ uTP SACK` while this work was in progress. Track 2 committed
build.zig + recheck.zig changes plus `tests/recheck_live_buggify_test.zig`.
No file conflicts: my changes touch `src/io/metadata_handler.zig`,
`src/io/event_loop.zig` (alias declaration only), and add
`tests/metadata_fetch_test.zig`.

The `build.zig` `test-metadata-fetch` step I added got swept into
Track 1's commit `c026158` (parallel agents auto-staged the file);
the test step works correctly and `zig build test-metadata-fetch`
runs the new tests. Not ideal hygiene but no behavioural impact.

## Files touched (this track)

- `src/io/metadata_handler.zig` — `AsyncMetadataFetchOf(IO)` + alias
  (commit `69c9287`).
- `src/io/event_loop.zig` — per-IO `pub const AsyncMetadataFetch`
  alias, `metadata_fetch` field type, `startMetadataFetch` callback
  signature, `AsyncMetadataFetch.create` call (commit `69c9287`).
- `tests/metadata_fetch_test.zig` — three foundation integration
  tests (commit `478fa19`).
- `STATUS.md` — "Last Verified Milestone" entry; "Next" follow-ups
  for happy-path test + live-pipeline BUGGIFY harness.

## Follow-ups (not in scope for this round)

### 1. Happy-path `AsyncMetadataFetchOf(SimIO)` integration test
Scripted BEP 9 protocol responses (BT handshake reply, extension
handshake with `m: { ut_metadata: N, metadata_size: ... }`,
ut_metadata data message, assembler verify success). Two design
options as discussed above; pick one and ship. Estimated 1 day.

### 2. Live-pipeline BUGGIFY harness for AsyncMetadataFetchOf(SimIO)
Once the happy-path test is in place, wrap it with the canonical
shape — per-tick `injectRandomFault` + per-op `FaultConfig` over
32 deterministic seeds. Catches handshake-recovery races, partial-
send retries, slot cleanup under recv-error injection, and
assembler-reset paths that the algorithm-level
`tests/ut_metadata_buggify_test.zig` and the foundation error-path
tests can't see together. Reference shape:
`tests/sim_smart_ban_eventloop_test.zig`. Estimated 0.5-1 day.

### 3. Inline tests in `src/io/metadata_handler.zig`
The five inline tests in this file route through
`tests/metadata_fetch_shared_test.zig` via the existing
`test-metadata-fetch-shared` step (which directly imports
`varuna.io.metadata_handler`). Worth verifying they're actually
running once Task #7 (src/io/ source-side tests dark in mod_tests)
lands a wider fix.

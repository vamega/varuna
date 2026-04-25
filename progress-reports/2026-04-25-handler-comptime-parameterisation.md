# Handler-File Conversion to Comptime EL Parameterisation (Stage 3 #13)

## What changed and why

Sim-engineer wrapped EventLoop in `EventLoopOf(comptime IO: type)` (commit
`e3a0270`) and asserted that `EventLoopOf(SimIO)` instantiates as a valid
type (commit `0e0b353`). The struct compiled, but its callbacks still
cast user-data to `*EventLoop = *EventLoopOf(RealIO)` — running them
under SimIO would have read stale RealIO bytes off a SimIO-backed
EventLoop. Task #13 was the conversion that closes that gap for the
smart-ban run path.

Shipped in commit `8f0267a` (`io: convert run-path handlers to comptime
EL parameterisation`):

- **peer_handler.zig** — all 7 callbacks moved to factories
  `xCompleteFor(comptime EL: type) Callback`. The factory's inner cast
  `*EL = @ptrCast(userdata)` is the only thing that varies per
  instantiation; everything else is shared body. All 16 helpers
  (`handleAccepted`, `handleRecvResult`, `executeMseAction`, etc.)
  switched to `self: anytype` so the EL is inferred at the callsite.
  Internal callbacks reference each other via
  `xCompleteFor(@TypeOf(self.*))`.
- **`DiskWriteOp`** — refactored to `DiskWriteOpOf(comptime EL: type)`
  generic struct, with `pub const DiskWriteOp = DiskWriteOpOf(EventLoop)`
  preserved as a back-compat alias for code that's still concrete.
  All 3 allocation sites (peer_policy.zig × 2, web_seed_handler.zig × 1)
  now use `DiskWriteOpOf(@TypeOf(self.*))` and
  `diskWriteCompleteFor(@TypeOf(self.*))`, so they stay EL-agnostic
  regardless of how the surrounding function is typed.
- **protocol.zig** — 17 helper signatures (the recv-submit family,
  `processMessage`, `submitMessage`, `submitExtensionHandshake`,
  `sendInterestedAndGoActive`, `sendInboundBitfieldOrUnchoke`,
  `submitPexMessage`, the hash-exchange helpers) became `self: anytype`.
  `submitMessage` now reads `EL.small_send_capacity` off the inferred
  type rather than hard-coding `EventLoop.small_send_capacity`.
- **event_loop.zig** — 5 registration sites pass the factory form:
  `peer_handler.peerSocketCompleteFor(Self)`, `peerAcceptCompleteFor(Self)`,
  `pendingSendCompleteFor(Self)` (×4). The big formatting churn in the
  diff is `zig fmt` re-indenting the struct body now that `EventLoopOf`
  wraps it (the parameterisation commit shipped without a re-format).

## Shape choice (1 vs 2)

There were two viable patterns the team-lead and I had discussed:

- **Shape 1 (factories at module scope)** — what I shipped.
  `pub fn peerRecvCompleteFor(comptime EL: type) Callback {
       return struct { fn cb(...) {...} }.cb;
   }`
  Registered as `peer_handler.peerRecvCompleteFor(Self)`.
- **Shape 2 (Self-method wrappers in `EventLoopOf(IO)`)**.
  Wrappers live next to the struct fields:
  `fn peerRecvCompleteCb(ud, c, r) { return peer_handler.peerRecvImpl(self, c, r); }`.
  Registered as `peerRecvCompleteCb`. Impls take `self: anytype`.

Shape 1 keeps the EL-cast colocated with the body it dispatches on —
when reading peer_handler.zig you don't have to jump to event_loop.zig
for the type-cast layer. Shape 2 makes registration sites read more
naturally and pushes the cast into the type that "owns" Self. Both
work. I went with shape 1; the team-lead's separate brief to
sim-engineer leaned toward shape 2. If the codebase wants the inverse,
swap the seven factories for Self-method wrappers — purely mechanical.

## What this does NOT cover

The brief's "must convert" list was peer_handler.zig + protocol.zig +
DiskWriteOp + registration sites. Those are done. The following are
deliberately untouched:

- **peer_policy.zig** — 30+ functions still typed `self: *EventLoop`.
  `EventLoopOf(SimIO).run()` calls `peer_policy.processHashResults(self)`
  etc. (event_loop.zig:1483-1493), so the moment the smart-ban EL test
  drives a `tick()` loop, peer_policy.zig will need the same
  `anytype self` propagation. Today's type-only assertion in
  `tests/sim_smart_ban_eventloop_test.zig` doesn't compile any methods,
  so it passes — but the next person wiring the test must convert
  peer_policy.zig (especially `processHashResults`,
  `completePieceDownload`, `smartBanCorruptPeers` for the smart-ban
  path; `tryAssignPieces`, `tryFillPipeline` for piece flow).
- **utp_handler.zig / seed_handler.zig / web_seed_handler.zig /
  dht_handler.zig** — sim-engineer's analysis flagged these as
  "compile-only under SimIO; never run". Smart-ban scenarios use TCP
  peers, no DHT, no web seeds, no seeding past piece completion. Left
  typed `*EventLoop` accordingly. If a future SimIO scenario exercises
  uTP or DHT, convert per-method on demand.

## What was learned

- **Lazy method compilation is a strong tool.** `EventLoopOf(SimIO)`
  instantiates without compiling its methods, so partial conversions
  ship without breaking the build. The "tests pass at every commit"
  invariant becomes much easier — convert only what the next test
  actually drives, ship it, repeat.
- **`zig fmt` after a struct wrap.** Sim-engineer's
  `event_loop: parameterise over comptime IO` commit added the
  `EventLoopOf(IO) { return struct { ... } }` wrapper but didn't
  reindent the body, leaving 2380+ lines under-indented by one level.
  My handler-conversion commit happened to run `zig fmt` and absorbed
  the reformat — pure noise in the diff but worth knowing for the
  reviewer (the substantive event_loop.zig change is just 5 registration
  sites).
- **Tests-pass-at-every-commit was the meta-discipline that made the
  whole migration ship without rollback.** Five Stage-2 commits + the
  pool refactor + this conversion all crossed 163/163 → 199/199
  cleanly because no commit was allowed to land yellow. The
  reorganisation that came up as `seed_plaintext_burst` regressed 3×
  was caught by a benchmark, not a test — so the "always green tests"
  rule needs a "always-green-bench" companion for perf-sensitive
  paths. Worth codifying alongside the migration patterns in
  STYLE.md.

## Remaining issues / follow-up

1. **peer_policy.zig conversion** — required before the smart-ban EL
   integration test (`tests/sim_smart_ban_eventloop_test.zig`) can do
   anything beyond type assertion. Sim-engineer's task #9. Probably
   ~1-2h with the patterns in STYLE.md.
2. **Shape 1 vs Shape 2** — if the team-lead wants the inverse layout,
   it's a focused mechanical pass. Don't ship both shapes; pick one
   and stay there.
3. **utp/dht/seed/webseed converters** — only when needed by a
   specific SimIO scenario. Don't pre-convert.

## Key code references

- `src/io/peer_handler.zig:31-56` — `peerAcceptCompleteFor` (representative
  factory shape)
- `src/io/peer_handler.zig:850-887` — `DiskWriteOpOf` generic struct +
  `diskWriteCompleteFor` factory
- `src/io/protocol.zig:425-456` — three submit-recv helpers showing
  `self: anytype` + `peerRecvCompleteFor(@TypeOf(self.*))`
- `src/io/event_loop.zig:73-75` — `EventLoopOf` parameterisation entry
  (from sim-engineer's `e3a0270`)
- `src/io/event_loop.zig:2048` — registration site using `Self` factory
- `src/io/peer_policy.zig:567,784` — DiskWriteOp allocation sites with
  `@TypeOf(self.*)`
- `src/io/web_seed_handler.zig:558` — third DiskWriteOp allocation site
- `tests/sim_smart_ban_eventloop_test.zig:263-296` — placeholder test
  asserting `EventLoopOf(SimIO)` is a valid type

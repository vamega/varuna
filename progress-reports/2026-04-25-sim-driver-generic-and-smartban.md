# 2026-04-25: Simulator generic over Driver + protocol-only smart-ban regression

## What changed

After a coordination round with the team-lead, this slice picks up the
"don't hold for Stage 2 #12" direction: build the Simulator as a generic
type so EventLoop drops in cleanly later, and lock in the smart-ban Phase
0 algorithm against the existing SimPeer fault matrix today via a
protocol-only regression test.

### Callback contract — `io_interface.zig`

Added a new paragraph to the `Callback contract` section spelling out
the in_flight clearing rule that both backends now follow (cleared
*before* invoking the callback so callbacks can submit a new op on the
same completion). The one-line rule: a callback may **either** submit a
new op **or** return `.rearm`, not both. This was an undocumented
invariant both backends independently arrived at via the
re-arm-with-new-buffer pattern; making it explicit prevents future
drift.

### `SimState` packed-struct rationale

Inline NOTE next to the `SimState` declaration in `sim_io.zig`
explaining why it's a regular struct, not packed: adding
`parked_socket_index: u32` pushes packed bit-width to 96, and Zig
0.15.2's packed-struct alignment rule (smallest power-of-two integer
that fits) lifts `@alignOf` to 16, blowing past
`backend_state_align = 8`. The regular-struct form sits at 12 bytes /
4-byte align, comfortably within the 64-byte / 8-byte budget.

### Simulator → `SimulatorOf(comptime Driver: type)`

Refactored the Simulator into a generic type. Driver contract is
minimal:

```zig
pub fn tick(self: *Driver, io: *SimIO) !void
```

Default `pub const Simulator = SimulatorOf(StubDriver)` is the public
type used by all current tests. `StubDriver` is a no-op tick counter —
useful for verifying the simulator's own surface (clock, BUGGIFY,
runUntil) without an EventLoop on the other end.

`Simulator.step` order is now: clock advance → peer.step (per swarm
peer) → BUGGIFY draw → driver.tick → io.tick. Driver gets called with
the simulator's `io` pointer, so once `EventLoop(SimIO)` lands the
plumbing is `SimulatorOf(EventLoop(SimIO))` and `step` calls
`event_loop.tick(&io)` automatically.

New tests in `tests/sim_simulator_test.zig` cover the generic surface:
"custom driver receives io pointer" verifies the Driver contract works
with an arbitrary user type, not just StubDriver.

### Protocol-only smart-ban regression

`tests/sim_smart_ban_protocol_test.zig` runs the extracted smart-ban
Phase 0 algorithm against a SimPeer swarm:

- 6 SimPeer seeders: 5 honest + 1 corrupt (`wrong_data` behavior).
- A hand-rolled `Downloader` that mirrors `peer_policy.zig:penalizePeerTrust`:
  `trust_points -|= 2` on hash failure, ban at `trust_points <= -7`.
- 4 pieces, 32 bytes each, SHA-1-verified after receive.
- Round-robin starting at `corrupt_peer_index` so the corrupt peer
  picks up first attempts.
- `pumpRequests` is gated on `allPeersReady` (every peer has
  `unchoke_received`) so faster honest peers don't race ahead and grab
  every piece before the corrupt peer's unchoke arrives. Without that
  gate the test trivially "passes" without ever exercising smart-ban —
  a real subtle issue worth catching before the EventLoop-integrated
  version lands.

Run over 8 different seeds. Each seed asserts:
- all 4 pieces verify (liveness),
- corrupt peer is banned (`trust_points <= -7`, `hashfails >= 4`),
- no honest peer is banned or has any hashfails.

This is **not** the official smart-ban sim test — that one uses
`EventLoop(SimIO)` as the downloader, which depends on Stage 2 #12
finishing. But it locks in the algorithm against my SimPeer
infrastructure today; when EventLoop becomes generic, the same
scenario ports over.

### Test count

194 → **195**. Builds clean.

## What's left

The two DoD items still gated on Stage 2 #12:

1. Replace the hand-rolled Downloader in
   `sim_minimal_swarm_test.zig` with `EventLoop(SimIO)`. The minimal
   sim swarm test then closes both DoD #2 ("Simulator runs
   `EventLoop(SimIO)` deterministically") and DoD #3's protocol half.
2. Replace the hand-rolled Downloader in
   `sim_smart_ban_protocol_test.zig` with `EventLoop(SimIO)`, run
   under `Simulator.init(.{ .buggify = .{ .probability = 0.01 } })`
   over 32 seeds. Closes DoD #4.

The mechanism for both is in place. The integration is mechanical
once Stage 2 #12 commits a parameterised `EventLoop`.

## Commits since the prior report

```
c921aae sim: callback contract docs + Simulator generic over Driver + smart-ban protocol regression
6f4cde7 sim: more SimPeer behavior tests + STATUS + progress report
b83ba4e sim: BUGGIFY randomized fault injection (Stage 5 #7 partial)
09b7cc6 sim: Simulator + minimal sim swarm test (Stage 3 #5)
59e87cd docs: STATUS + progress report for SimPeer foundation
0565b83 sim: SimPeer protocol logic and behavior tests (Stage 4 #6 partial)
e4c2475 sim: SimIO socketpair / fd machinery (Stage 3 #13)
```

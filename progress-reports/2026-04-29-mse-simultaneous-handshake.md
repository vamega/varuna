# MSE simultaneous-handshake stale-CQE race + generation-counter fix

**Date:** 2026-04-29

## What changed and why

Closed two production bugs that had the same root cause:

1. **`STATUS.md:272` (Done backlog):** "MSE simultaneous handshake
   robustness — timing-dependent crash in `checkPeerTimeouts ->
   removePeer -> cleanupPeer` when both inbound and outbound MSE
   handshakes are in flight. Disappears under GDB."
2. **`STATUS.md:308` (Known Issues):** "MSE handshake failures in
   mixed encryption mode — `vc_not_found` and `req1_not_found` errors
   occur during simultaneous inbound+outbound MSE handshakes."

Both turned out to be the same race, just observed from different
angles: a stale recv CQE from an OLD MSE handshake firing the callback
against a REUSED peer slot, with the OLD CQE's bytes (or error)
landing on the NEW peer's state machine.

## Root cause

The OLD MSE recv was submitted via
`io.recv(.{ .fd = peer.fd, .buf = mse_initiator->peer_public_key[..] },
&peer.recv_completion, …)`. When `removePeer(slot)` ran (most
commonly fired by `checkPeerTimeouts` on a 60-second-stuck outbound
MSE handshake):

1. `cleanupPeer` closes the fd and `allocator.destroy(mse_initiator)`.
   The buffer pointer in the in-flight recv is now dangling.
2. `peer.* = Peer{}` resets the slot — including
   `peer.recv_completion` (callback set to null, `_backend_state`
   zeroed).
3. The slot is reallocated to a fresh peer (e.g. a new outbound
   connection). A new `mse_initiator` is built; its DH-key send +
   recv go onto the same `peer.recv_completion`.
4. The OLD CQE arrives. The kernel/SimIO has its userdata pointer
   stored as `&peer.recv_completion`. The callback (now armed with
   the NEW peer's state) fires with the OLD result.

Pre-fix, the OLD CQE's bytes (often `error.ConnectionResetByPeer`
from the close) tripped the `attemptMseFallback` branch on the NEW
peer. Even when the OLD CQE delivered actual partial bytes, those
were attributed to the NEW state machine — corrupting the VC scan
or the req1 search and producing the `vc_not_found` /
`req1_not_found` errors.

The crash in `cleanupPeer` mentioned in STATUS.md was the secondary
symptom: when the OLD CQE-induced stale fallback eventually
re-entered cleanup paths in inconsistent state (e.g. mse_initiator
already null, but other state mid-tear-down), various invariants
held by `cleanupPeer` could fire. Under GDB, the timing widened
enough that the OLD CQE either fired before the slot reuse or the
heap allocator returned different addresses — masking the race.

## Fix shape

**Per-slot generation counter + heap-allocated MSE op wrapper**:

1. New `EventLoop.peer_generations: []u32` parallel to `peers`.
   Bumped (`+%= 1`) in `removePeer` *before* `peer.* = Peer{}` and
   in `attemptMseFallback` before reconnection. Lives outside the
   `Peer` struct so it survives reset.

2. New `MseHandshakeOpOf(EL)` wrapper struct, heap-allocated per
   MSE recv/send submission:

   ```zig
   pub fn MseHandshakeOpOf(comptime EL: type) type {
       return struct {
           completion: io_interface.Completion = .{},
           el: *EL,
           slot: u16,
           generation: u32,
           is_initiator: bool,
           is_send: bool,
       };
   }
   ```

   Submitted via `submitMseRecv` / `submitMseSend`. The wrapper's
   `&completion` is what enters the SQE; `peer.recv_completion` /
   `peer.send_completion` are NOT used for MSE state-machine ops
   anymore.

3. Callback factories `mseHandshakeRecvCompleteFor(EL)` /
   `mseHandshakeSendCompleteFor(EL)` recover the wrapper from
   `userdata`, free it unconditionally, then check
   `el.peer_generations[op.slot] == op.generation`. On mismatch
   the dispatch is silently dropped; the slot has been reused and
   the OLD result must not be acted on.

4. **Belt-and-suspenders:** `checkPeerTimeouts` now skips slots in
   `.mse_handshake_send` / `.mse_handshake_recv` / `.mse_resp_send`
   / `.mse_resp_recv`. The 60s threshold was sized for stuck active
   piece transfers; MSE handshakes complete in hundreds of
   milliseconds or fail through normal recv-error paths, and
   timing them out was the most common trigger for the slot-reuse
   race. With the generation counter in place this is no longer
   strictly necessary for correctness, but it removes the most
   frequent path that exercised the race in production.

## Hypothesis verdict

The investigation prompt named two hypotheses:

- **Hypothesis 1** ("cleanupPeer frees MSE state while a CQE is in
  flight against it; fix shape: generation counters or in-progress
  guards"): correct in shape but subtler in mechanism. The kernel
  doesn't UAF the freed buffer (closed fd cancels the recv before
  any write). The actual race is the OLD CQE's `userdata` pointer
  surviving slot reset and landing on the NEW callback.
- **Hypothesis 2** ("vc_not_found / req1_not_found from
  four-state-machine confusion on simultaneous-connect; fix shape:
  isPeerAlreadyConnected"): turned out to be a *symptom* of the
  same race, not a separate bug. When the OLD recv CQE replayed
  against the NEW MSE state machine, the dispatched bytes (or
  error) appeared as VC-scan / req1-scan failures.

So the answer is: hypothesis-1 was right in shape, hypothesis-2 was
the same bug seen from the other side. One fix closes both.

## What was learned

- **Caller-owned `Completion`s embedded in long-lived slot structs
  need a stale-CQE story** beyond "callback set to null on slot
  reset". The window between reset and the next reuse is enough for
  the OLD CQE to skip cleanly, but once the slot is reused and a
  NEW armCompletion sets the callback again, the OLD CQE's userdata
  points at the NEW state. Either the wrapper-with-generation
  pattern or unconditional cancel-on-close-and-wait is required.
- **The race is invisible in single-threaded io_uring under GDB**
  because the timing window is narrow. The "disappears under GDB"
  signal in the bug report was correct evidence of a race.
- **`peer.* = Peer{}` zeros `_backend_state` to all-zero**, which
  matches the documented contract (`backend_state_size` of zero
  bytes denotes "not in flight"). That's actually the *cause* of
  the trap door: after reset, the next `armCompletion` succeeds
  cleanly because in_flight reads as 0, but the OLD CQE's queue
  entry still references the same address.
- **The generation pattern is a clean local fix** that doesn't
  require restructuring the IO contract. It composes with the
  existing PendingSend `(slot, send_id)` matching for tracked sends
  — both serve the same invariant for different op classes.

## Verification

1. `zig build` — clean.
2. `zig build test` — clean across 5 consecutive runs.
3. `zig build test-sim-mse-simultaneous` — 3/3 tests pass.
4. 32-seed sweep on the new sim test — all green deterministically.
5. **Regression bite confirmed**: temporarily disabling the
   generation-mismatch check in `mseHandshakeRecvCompleteFor`
   produces 32/32 seed failures (`expected 32, found 0` on the
   intact-count assertion); restoring the check returns 32/32 green.
6. `scripts/demo_swarm.sh` with `encryption = "preferred"` — 5/5
   consecutive runs clean, MSE handshakes complete on both sides.

(Note: STATUS.md previously claimed `demo_swarm.sh` ran with
`encryption = "disabled"` as workaround. The script has actually
been on `"preferred"` since commit `3284849` ("demo_swarm: enable
MSE encryption"). The workaround note in STATUS.md was stale; this
milestone re-validates the swarm end-to-end and updates the entry.)

## Remaining issues / follow-up

- None blocking.
- Optional follow-up: extend the wrapper pattern to the BT-handshake
  recv path (`peer.recv_completion` in `inbound_handshake_recv` /
  `handshake_recv` / `active_recv_header` / `active_recv_body`).
  The crash window is narrower there because the buffer pointers
  are into the Peer struct itself (zeroed but not freed by reset),
  so a stale CQE writes to garbage but doesn't UAF — and the existing
  state guards (`peer.state == .free` / `.connecting`) mostly
  protect against acting on it. Worth filing as a defense-in-depth
  task but not driven by an active bug.

## Code references

- `src/io/event_loop.zig:177` — new `peer_generations: []u32`
  field on the EL.
- `src/io/event_loop.zig:438` / `:444` — allocation in
  `initBareWithIO`, free in deinit.
- `src/io/event_loop.zig:1631` — generation bump in `removePeer`,
  *before* `peer.* = Peer{}`.
- `src/io/peer_handler.zig:992` — `MseHandshakeOpOf(EL)` wrapper
  struct + the design rationale (links to STYLE.md).
- `src/io/peer_handler.zig:1018` — `mseHandshakeRecvCompleteFor`
  callback factory with the generation-mismatch bail.
- `src/io/peer_handler.zig:1062` — `mseHandshakeSendCompleteFor`.
- `src/io/peer_handler.zig:1093` — `submitMseRecv` helper.
- `src/io/peer_handler.zig:1119` — `submitMseSend` helper.
- `src/io/peer_handler.zig:1158` — generation bump in
  `attemptMseFallback`.
- `src/io/peer_policy.zig:1182` — `checkPeerTimeouts` now skips
  MSE handshake states.
- `tests/sim_mse_simultaneous_handshake_test.zig` — new
  SimIO-driven regression: exercises slot-reuse + stale-CQE replay
  across 32 seeds.
- `STYLE.md` migration pattern #17 — "Generation counter pattern"
  documents the invariant.

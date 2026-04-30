# 2026-04-30 — MSE simultaneous-handshake race: reproduction harness + audit

## TL;DR

The long-standing STATUS Known Issue ("MSE handshake failures in mixed
encryption mode" — `vc_not_found` and `req1_not_found` errors during
simultaneous inbound + outbound MSE handshakes) does **not reproduce
under the deterministic stack** (SimIO + SimHasher + SimRandom +
SimClock) across 32 seeds. Across:

- 32 seeds × clean simultaneous inbound + outbound MSE handshake — 32/32
  complete cleanly, no `vc_not_found`, no `req1_not_found`.
- 8 seeds × 5% recv-error fault injection — all observed failures are
  the expected `connection_closed` propagation; **0 cross-handshake
  state-corruption candidates** (the historical symptom).
- 8 seeds × `removePeer` mid-handshake + slot reuse for fresh inbound —
  no crash, slot reuses cleanly, second handshake completes.

The bug as originally described — a real-io_uring timing-dependent
crash that disappears under GDB — is structurally precluded by the
deterministic stack: SimIO's `closeSocket` immediately fails the
parked recv (vs. real io_uring where the CQE may arrive much later);
the `_backend_state` zero-on-`Peer{}` reset and `armCompletion`
re-init keep the next submission clean.

That said, the audit found and fixed **two real defects** in the
production MSE/peer-lifecycle code that an io_uring-policy-aware
review would have flagged independently of the simultaneous-handshake
hypothesis:

1. **`attemptMseFallback` used raw `posix.close`** — both an io_uring
   policy violation *and* a SimIO synthetic-fd panic vector
   (`unreachable, // Always a race condition` on BADF). Switched to
   `self.io.closeSocket(peer.fd)`.
2. **`handleSocketResult` used raw `posix.close`** in two stale-CQE
   branches (`peer.state == .free` and `peer.state != .connecting`).
   Same fix.

With these two close-routing bugs fixed and the harness asserting
clean runs across 32 seeds, the Known Issue is closed. The harness
remains as a regression guard.

## Methodology

The brief was Pattern #14 (reproduce first, diagnose second, fix
third) — and explicitly anticipated this outcome:

> If the race turns out NOT to reproduce under deterministic
> conditions (i.e., it was real-thread-scheduling-dependent and
> SimHasher killed it incidentally), document that finding and close
> the Known Issue accordingly — but verify across many seeds first.

## Reproduction harness — `tests/sim_mse_handshake_test.zig`

Drives **one EventLoop with two MSE handshakes in flight
simultaneously**:

- Slot A (outbound): EL plays the MSE initiator. We call
  `enqueueSocketResult(out_local)` so the EL's next `io.socket()`
  resolves to one half of a SimIO socketpair, then call
  `addPeerForTorrent(addr, tid)`. SimIO synchronously completes the
  socket and connect ops; `handleConnectResult` routes through
  `startMseInitiator` (because `encryption_mode = .preferred` and
  `mse_rejected = false`).
- Slot B (inbound): we call `addInboundPeer(tid, in_local, addr)`.
  This parks the slot in `.inbound_handshake_recv` with a recv
  submitted on `peer.handshake_buf`. The peer-side initiator then
  drives Ya + PadA into the socket; the EL's
  `detectAndHandleInboundMse` sees the non-BT first byte and starts
  the MSE responder.

The peer side of each handshake is driven by a `PeerMseDriver` —
~150-line helper that wraps an `MseInitiatorHandshake` /
`MseResponderHandshake` state machine, owns its own `Random` (so the
EL and peer don't interleave RNG draws), reads bytes off the SimIO
socket, feeds them to the state machine, and pushes responses back.
One `Random` per side ensures byte-determinism per seed — if the bug
were sensitive to a specific DH key / pad-length combination, it
would surface on at least one of the 32 seeds.

`runtime.Random` is the daemon-seeded ChaCha8 CSPRNG that landed
2026-04-30 (`progress-reports/2026-04-30-csprng-migration.md`). All
four sources of nondeterminism in the MSE handshake — DH private
keys, PadA / PadB / PadC / PadD lengths and bytes — flow through
this single `Random` per side and are byte-deterministic per seed.

`Hasher.simInit` (the synchronous variant) replaces the real-thread
hasher pool so hash-result delivery ordering is also deterministic
(landed 2026-04-30,
`progress-reports/2026-04-30-simhasher.md`).

## Test bodies

Four tests:

1. **single seed sanity** — one seed, asserts both sides complete with
   `crypto_method == crypto_rc4`. Smoke test.
2. **`removePeer` during in-flight handshake — does not crash or
   corrupt next slot** — directly exercises the historical
   "checkPeerTimeouts → removePeer → cleanupPeer" scenario. Across
   8 seeds: outbound MSE handshake started, mid-handshake `removePeer`
   fires (simulating the timeout), drive ticks to drain the
   closeSocket-fired recv-error CQE, then re-use the slot for a fresh
   inbound MSE handshake. Asserts the second handshake completes
   cleanly with `crypto_method == crypto_rc4`. The slot reuse is the
   key part — if a stale CQE on the freed `recv_completion` could
   cross-contaminate the new handshake, it would manifest here.
3. **recv-error fault injection — 8 seeds × 0.05** — each recv has a
   5% chance of returning `ConnectionResetByPeer`. The assertion is
   sharp: any reset must propagate as `connection_closed`, never
   masquerade as `vc_not_found` / `req1_not_found`. Across 8 seeds:
   0 state-corruption candidates.
4. **32-seed sweep** — 32 distinct seeds, all clean. The standard
   BUGGIFY-style coverage budget; if the bug were RNG-dependent it
   would surface on at least one of these.

## Production fixes landed

Two raw-`posix.close` callsites in `src/io/peer_handler.zig` were
replaced with `self.io.closeSocket(peer.fd)`:

- **`attemptMseFallback`** (`src/io/peer_handler.zig:1110`). This is
  the production MSE → plaintext fallback path: when the outbound
  MSE handshake fails and `encryption_mode == .preferred`, we close
  the encrypted-leg fd and reconnect plaintext. Pre-fix:
  `posix.close(peer.fd)` panicked with `BADF` on a SimIO synthetic
  fd (the panic was caught by the recv-error injection test). Post-
  fix: routes through the IO contract uniformly. This was *also* an
  io_uring policy violation — `AGENTS.md` "Daemon paths that must use
  `io_uring`" lists peer connect/recv/send and by extension the
  closing path that pairs with them.
- **`handleSocketResult`** (`src/io/peer_handler.zig:165, 173`). Two
  stale-socket-CQE branches close the just-created fd: when the slot
  was freed before the socket completed, and when the slot was
  reused for something else. Same fix — `self.io.closeSocket(...)`
  uniformly. Less load-bearing than the fallback fix in practice
  (the `peer.state != .connecting` branch is unlikely to fire under
  SimIO because the slot's lifetime overlaps the synchronous socket
  completion), but the close-routing should be uniform.

The MSE state heap (`peer.mse_initiator` / `peer.mse_responder`) is
freed *after* the close in `attemptMseFallback`; the `cleanupPeer`
path likewise frees these heap-allocated state machines after
`closeSocket`. Audit: this is safe because (a) on RealIO the kernel
does not write into the recv buffer after the fd is closed; the CQE
delivers `-ECANCELED` with the buffer state frozen as of close. (b)
`peer.* = Peer{}` resets `peer.state` to `.free` so the late CQE's
callback (`handleRecvResult`) early-returns on `peer.state == .free`
without dereferencing `mse_initiator` / `mse_responder`. The race
window I initially worried about — kernel writes into freed buffer
between close and the CQE — does not exist on Linux io_uring.

## Why the historical bug doesn't reproduce here

Three plausible explanations, in declining likelihood:

1. **Fixed by an earlier round, STATUS not updated.** `git log
   --grep "stale"` surfaces commit `eb1daac` (rpc: add
   shutdown), which added the `.connecting`-guard against stale
   connect CQEs corrupting reused slot MSE state. Commit `3284849`
   then landed "demo_swarm: enable MSE encryption (encryption =
   "preferred")" with the message "With the MSE stale-CQE fix and
   multi-source endgame double-free fix, MSE encryption works
   reliably end-to-end. Verified with 5 consecutive demo_swarm
   runs, all peers using RC4 encryption." So the underlying defect
   was already addressed — STATUS.md just hadn't been updated to
   close the Known Issue. (The line about `demo_swarm.sh runs with
   encryption = "disabled"` is stale: `scripts/demo_swarm.sh`
   already uses `"preferred"`.)
2. **SimIO model is stricter than real io_uring.** `closeSocket`
   immediately fails the parked recv with `ConnectionResetByPeer`
   (vs. real io_uring where the CQE arrives whenever the kernel
   gets around to it); `_backend_state` is zeroed on
   `peer.* = Peer{}`, but `armCompletion` re-initialises it on the
   next submission. So a stale CQE for a freed completion is
   structurally impossible.
3. **SimHasher delivers hash results synchronously**, eliminating
   the OS-thread-scheduling jitter that was probably the original
   reproduction trigger.

The three explanations aren't mutually exclusive, but (1) is most
load-bearing — once the production code routes stale CQEs cleanly
on real io_uring, the determinism boundary closes whatever residual
nondeterminism might have made the symptom rare-but-real.

## Defenses already in place

A walk through the current code path turns up the following stale-
CQE / lifecycle guards (some predate this round, some I added):

- `handleConnectResult`: `if (peer.state == .free) return` and
  `if (peer.state != .connecting) return` — kills stale connect CQEs
  that would corrupt reused slot MSE state.
- `handleSocketResult`: same two guards, plus this round's
  `self.io.closeSocket` fix on the close branches.
- `handleRecvResult`: `if (peer.state == .free) return` early-return,
  plus `peer.state == .connecting` reconnect guard, plus the MSE
  fallback paths only fire on `.mse_handshake_recv` /
  `.mse_resp_recv` (not on stale state).
- `handleSendResult`: same pattern.
- `attemptMseFallback`: this round's `self.io.closeSocket` fix.
- `cleanupPeer`: `closeSocket` precedes the heap free — kernel can
  no longer write to the buffer.

## Test count delta

`zig build test`: 1731/1747 → 1735/1751 (+4 new tests, 0
regressions; the unrelated `sim_smart_ban_phase12_eventloop_test`
intermittent flake remains uncorrelated).

## What was NOT touched

- The MSE state machines (`MseInitiatorHandshake` /
  `MseResponderHandshake`) — no defects found.
- Generation counters on Peer slots — not needed; the existing
  `peer.state == .free` early-return is sufficient.
- Explicit handshake-in-progress guards on `removePeer` /
  `cleanupPeer` — not needed; `mse_initiator` /
  `mse_responder` heap free after `closeSocket` is safe per the
  Linux io_uring kernel-doesn't-write-after-close contract.
- `src/io/io_interface.zig`, `src/io/event_loop.zig` outside the
  MSE-related fields/methods — out of scope per the brief.

## Surprises

1. **`attemptMseFallback`'s raw `posix.close` was a real production
   bug**, not a sim-only artifact. On real io_uring it works (no
   BADF — the fd is real) but it's an io_uring policy violation that
   bypasses the IO contract; on SimIO it panics. Found via the
   recv-error fault injection test.
2. **The harness compiled cleanly without changes to the MSE state
   machines** — the existing `Random *Random` plumbing (added in the
   2026-04-30 CSPRNG migration round) was sufficient to drive both
   sides deterministically. Re-using the same async state machines
   the EL uses (rather than re-implementing the protocol on the peer
   side) cuts the harness to ~150 lines.
3. **`peer.state == .free` early-return is the only guard
   `handleRecvResult` needs** — I'd expected to need a generation
   counter or in-flight tracking, but the existing guard plus the
   close-before-free ordering in `cleanupPeer` is sufficient.

## Key code references

- Test harness: `tests/sim_mse_handshake_test.zig`.
- Production fixes: `src/io/peer_handler.zig:1110-1112`
  (`attemptMseFallback`), `src/io/peer_handler.zig:165-176`
  (`handleSocketResult`).
- IO contract (`closeSocket` for both backends):
  `src/io/real_io.zig:109` (`posix.close`),
  `src/io/sim_io.zig:720` (slot-marked-closed).
- Stale-CQE guards (already present): `src/io/peer_handler.zig:233`
  (connect), `:246` (connect non-`.connecting`), `:411`
  (send `.free`), `:619` (recv `.connecting`).
- Heap-free ordering: `src/io/event_loop.zig:2890-2927`
  (`cleanupPeer`).

## Follow-up

- STATUS.md "Known Issues" entry struck through with this round's
  closure. The duplicate STATUS line referencing the same issue
  ("MSE simultaneous handshake robustness", line 276) is also closed
  now — it predates the stale-CQE fix landing in `eb1daac` /
  `d3b4a27` and the close-routing fixes in this round.
- Consider replacing the `posix.close` on the inbound-rejection
  branches in `handleAccepted` (lines 75-115) with
  `self.io.closeSocket` for uniformity. They're production-only
  paths (the multishot accept callback never fires under SimIO
  because tests use `addInboundPeer` directly), so the panic risk
  is zero; the change is purely contract uniformity. Filed as a
  small follow-up.

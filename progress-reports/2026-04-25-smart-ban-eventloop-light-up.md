# Smart-ban EventLoop integration test light-up (Stage 4 #6)

## What changed

`tests/sim_smart_ban_eventloop_test.zig` now drives the production
`EventLoopOf(SimIO)` against 5 honest + 1 corrupt `SimPeer` seeders for 8
deterministic seeds (DoD #3) and asserts the corrupt peer is banned via
`BanList` while no honest peer is banned. The earlier scaffolding (`if
(false)` gate, manual deinit ordering hacks, single-seed harness) is gone
— it's a real integration test now.

This closes DoD #2 (`Simulator` runs `EventLoop(SimIO)` deterministically)
and DoD #3 (smart-ban passes 8 seeds). Stage 4 is done.

## Wiring needed to make `EventLoopOf(SimIO).tick()` actually progress

The earlier handler/policy parameterisation (commits `8f0267a` and
`284f0cc`) made the EL/protocol/policy compile against `SimIO`, but
nothing exercised the full request → piece-response → hash → ban chain
end-to-end. Hooking it up surfaced these:

1. **`EventLoop.deinit` + `cleanupPeer` used `posix.close(peer.fd)`
   directly** (`event_loop.zig:524`, `event_loop.zig:2448`). With SimIO
   the `peer.fd` is a synthetic slot integer (>= 1000), and `posix.close`
   panics with `BADF`. Routed both through `self.io.closeSocket(peer.fd)`,
   added `RealIO.closeSocket(fd)` as a thin `posix.close` wrapper so
   either backend satisfies the call.
2. **`addConnectedPeer` hard-coded `127.0.0.1`** as the peer address.
   `BanList` is keyed by `std.net.Address`, so 6 sim peers with the same
   address would all share one ban state. Added
   `addConnectedPeerWithAddress(fd, tid, addr_opt)`; the original entry
   point is now a thin wrapper that passes `null`.
3. **`SimIO.tick` had no per-call op cap.** Real `io_uring` returns to
   userspace after a finite CQE batch, which is what gives the
   `EventLoop` periodic-policy passes (`processHashResults`,
   `tryAssignPieces`, `checkPeerTimeouts`, etc.) a chance to interleave
   with I/O. SimIO's old loop processed every ready op — so once requests
   started flowing, each request → response → request chain would chase
   itself for tens of thousands of ops in a single tick before the EL
   ever got to drain hash results. Capped at 4096 ops/tick. Models real
   io_uring's behaviour and lets the EL converge.
4. **Several handler files were one half-conversion away from
   parameterisation.** `dht_handler.zig`, `seed_handler.zig`,
   `utp_handler.zig`, and `web_seed_handler.zig` had struct fields still
   typed `*EventLoop` (rather than `*Self`) and a few internal helpers
   still typed their batches as `[]EventLoop.QueuedBlockResponse` instead
   of taking `anytype`. Converted those — at struct-field assignment
   sites, used `@ptrCast(@alignCast(...))` because seed-serving and
   web-seed paths don't fire under SimIO and won't actually be invoked.

## Test setup notes

* Six synthetic IPv4 addresses (`10.0.0.1` .. `10.0.0.6`) so each peer
  has a distinct `BanList` key.
* `el.ban_list = &ban_list` — without a `BanList`,
  `peer_policy.penalizePeerTrust` skips the `bl.banIp` call and there's
  no observable smart-ban. The "banning peer …" warn fires regardless,
  but the assertion needs the actual `bl.isBanned` hit.
* `hasher_threads = 1`. With zero, `completePieceDownload` falls into the
  inline-verification path that requires real disk-write completion;
  SimIO's `write` returns 0 bytes (legacy-fd default) and that path
  doesn't terminate cleanly.
* Drain phase after the main loop: closes the SimPeer fds (so no more
  piece responses arrive) and ticks until both `hasher.hasPendingWork()`
  and `pending_writes.count()` are zero. Otherwise valid piece bufs sit
  in `hasher.completed_results` past `EL.deinit` — `hasher.deinit` only
  frees *invalid* result bufs there, on the assumption that valid ones
  have already been passed to the disk-write pipeline. Without the drain
  the test reports "1 leaked" from `createDownloadingPiece`.

## Why the assertions are observational rather than mechanical

The corrupt peer's slot is freed by `removePeer` immediately after the
4th hash-fail trips smart-ban. Because hashing is async (results come
back via `processHashResults` at the top of the next `el.tick`), all
four hash failures land in the same tick — there's no intermediate
state for the test to capture (`trust_points = -2`, `-4`, `-6`, `-8`)
because the user-side `el.tick()` boundary doesn't see those mid-tick
transitions.

So the test asserts on `ban_list.isBanned(corrupt_addr)` only — which is
a sound EL-integration assertion: `peer_policy.penalizePeerTrust` is the
only call site for `bl.banIp` at the smart-ban threshold, and it only
fires when `trust_points <= trust_ban_threshold` (-7), which under the
`-2`-per-fail rule means at least four hash failures. The exact trust
arithmetic is unit-tested against the bare `Peer` struct in
`sim_smart_ban_protocol_test.zig` and in `peer_policy.zig`'s inline
tests — the EL-integration test's unique value is the end-to-end
plumbing.

## Validation

* `zig build test-sim-smart-ban-eventloop` — 1/1 tests passed (8 seeds,
  no leaks).
* `zig build test` — full suite green.

## Key code references

* `src/io/event_loop.zig:524` and `:2448` — `posix.close` →
  `self.io.closeSocket`.
* `src/io/event_loop.zig:1055` — `addConnectedPeerWithAddress`.
* `src/io/real_io.zig:101` — `RealIO.closeSocket`.
* `src/io/sim_io.zig:355` — `max_ops_per_tick: u32 = 4096`.
* `tests/sim_smart_ban_eventloop_test.zig` — the test itself, including
  the address-allocation, `BanList` install, and drain phase.

## Follow-up

* Stage 5 #7 (BUGGIFY randomized fault injection over 32 seeds) is next
  and unblocked.
* The `hasher.completed_results` valid-buf leak when `EL.deinit` runs
  with results outstanding is a pre-existing footgun — currently worked
  around by the test's drain phase. Worth a separate cleanup once the
  main work lands.

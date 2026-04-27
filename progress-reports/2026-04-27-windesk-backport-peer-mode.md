# Backport from windesk: peer.mode role-confusion (bug 1 / 3af560a + 4e3d72c)

## What changed

`peer.mode` records which side opened the TCP socket, not who serves pieces.
Four sites in main were treating `mode == .inbound` as "the swarm role is
seeder" and so silently broke every transfer where a seeder dialled a
leecher (e.g. when the tracker handed the seeder the leecher's address).

### `src/io/protocol.zig`

- `processMessage` case 2 (INTERESTED): drop the `peer.mode == .inbound`
  gate on the auto-unchoke. Both orientations should auto-unchoke on
  interest; mode is irrelevant.
- `processMessage` case 6 (REQUEST): drop the `peer.mode == .inbound`
  gate on `servePieceRequest`. We serve any peer we've unchoked.
- `processMessage` case 4 (HAVE) and case 5 (BITFIELD): call new
  `maybeSendInterested(self, slot, tc)` after applying the availability
  update. Inbound-mode peers (the leecher side of a seeder-initiated
  connection) need to declare INTERESTED when they learn the remote has
  pieces they want; outbound peers already do this in
  `sendInterestedAndGoActive`.
- New helper `maybeSendInterested`: gated to `active_recv_*` states and a
  no-op if `am_interested` is already true. Computes "has useful piece"
  by walking the peer's availability bitfield against
  `tc.complete_pieces orelse self.complete_pieces`.
- New helper `sendOutboundBitfieldThenInterested`: sends BITFIELD (if we
  have any complete pieces) before INTERESTED for outbound peers, then
  the existing send-completion handler drives `sendInterestedAndGoActive`.

### `src/io/peer_handler.zig`

- `.extension_handshake_send` send-completion now calls
  `sendOutboundBitfieldThenInterested` instead of going straight to
  INTERESTED. Without BITFIELD the remote never learns we have pieces to
  serve, so a seeder-as-initiator stalls the leecher.
- New `.outbound_bitfield_send` send-completion: chains into
  `sendInterestedAndGoActive`.
- `handleHandshakeRecv` (outbound BT handshake): use
  `sendOutboundBitfieldThenInterested` on both the success and the
  extension-handshake-failure paths.

### `src/io/types.zig`

- `PeerState`: added `outbound_bitfield_send` between
  `extension_handshake_send` and `inbound_handshake_recv`.

### `tests/peer_mode_regression_test.zig` + `build.zig`

Ported the windesk regression test verbatim. Drives `processMessage`
directly with a one-byte INTERESTED body against an outbound-mode peer
and asserts that `am_choking` flips. Deterministic; fails against
pre-fix source, passes post-fix.

The other three sub-bugs (BITFIELD/HAVE auto-interest, REQUEST serving)
need richer test fixtures than the current scaffolding provides — the
BITFIELD/HAVE handlers early-return without a session, and
`servePieceRequest` wants a real seed handler. Tracked as follow-up.

## Why this matters in main

Main has the simulation-first redesign and is gradually migrating peer
flows to the comptime-IO event loop, but the protocol-layer bug is
present verbatim — `protocol.zig:83` and `protocol.zig:154` still had
the `peer.mode == .inbound` gates. These do not run through SimIO yet
(swarm-level sim tests gate on the EventLoop's existing send/recv
plumbing), so the protocol bug never showed up in CI.

Original windesk symptom: ~25% flake on large-20m-64k under the
test-transfer-matrix script.

## Testing

`zig build` clean; `zig build test` clean. The new
`peer_mode_regression_test` runs as part of the `test` step. Did not
attempt to reproduce the multi-test-matrix flake — the test isolation
work (`b5a0f51`, `0da3c3b`, `d3f00fb`, `34e79e6`) is the prerequisite
for that and lands in a separate batch.

## Code references

- `src/io/types.zig:42` — new `outbound_bitfield_send` PeerState
- `src/io/protocol.zig:79-93` — INTERESTED case, gate dropped
- `src/io/protocol.zig:116-125` — HAVE case, maybeSendInterested call
- `src/io/protocol.zig:155-167` — REQUEST case, gate dropped
- `src/io/protocol.zig:153-159` — BITFIELD case, maybeSendInterested call
- `src/io/protocol.zig:651-700` — maybeSendInterested helper
- `src/io/protocol.zig:716-740` — sendOutboundBitfieldThenInterested helper
- `src/io/peer_handler.zig:511-525` — extension/outbound bitfield send completions
- `src/io/peer_handler.zig:703-715` — outbound handshake-recv path
- `tests/peer_mode_regression_test.zig` — INTERESTED unchoke regression
- `build.zig:194-208` — test wiring

## Follow-up

The three uncovered sub-bugs (BITFIELD auto-interest, HAVE auto-interest,
REQUEST serving) need either:

1. Pure-function extraction of the gate decisions for direct unit-testing, or
2. A richer test fixture that lets `processMessage` see a real session and
   complete_pieces.

Two more `peer.mode == .inbound` reads remain in main with the same
role-vs-direction confusion smell:

- `src/io/peer_policy.zig:1173` — "don't timeout inbound peers"
- `src/io/peer_policy.zig:1366` — PEX `.seed` flag on inbound peers

Not addressed here; flagged for an audit pass.

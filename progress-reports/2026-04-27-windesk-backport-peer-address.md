# Backport from windesk: inbound peer.address (bug 5 / 57f292d)

## What changed

`src/io/peer_handler.zig:handleAccepted` now calls `getpeername` unconditionally
on every accepted fd, rejects the connection if the syscall fails, and stores
the resolved `std.net.Address` on `peer.address` before transitioning the slot
into `inbound_handshake_recv`.

Prior to this change the field was left at its `undefined` default unless a
`ban_list` was configured, and even then the resolved address was only used
for the immediate `isBanned` check — never persisted.

## Why this matters in main

Several main-branch sites read `peer.address` for inbound peers:

- `src/io/protocol.zig:isPeerAlreadyConnected` (called from PEX) calls
  `addressEql` against every peer's address. A garbage address can silently
  false-match a real peer and cause us to drop a good connection as a
  "duplicate".
- `src/daemon/session_manager.zig:1794` calls `peer.address.getPort()` from
  `/sync/torrentPeers`. The `getPort` helper has an `else => unreachable` for
  unknown families — undefined memory hits that with whatever `sa_family`
  byte happens to be in the storage.
- The reban sweep walks every peer and calls `bl.isBanned(peer.address)`.

The fix matches windesk's `57f292d` line-for-line modulo file location.

## Testing

`zig build` / `zig build test` clean. The original windesk symptom
(`progress=0.0000` stalls on large-20m-64k under the multi-test matrix) was
not directly reproducible from main without also porting the test-isolation
script changes (`b5a0f51`, `0da3c3b`, `d3f00fb`, `34e79e6`) — those land in
a separate batch.

## Code references

- `src/io/peer_handler.zig:61-124` — getpeername on accept, peer.address set
- `src/io/peer_handler.zig:108-114` — Peer struct init now includes `.address`

## Follow-up

Two remaining `peer.mode == .inbound` reads still in main that arguably
have the same role-vs-direction confusion as bug 1:

- `src/io/peer_policy.zig:1173` — "don't timeout inbound peers"
- `src/io/peer_policy.zig:1366` — PEX advertises inbound peer as "seed"

Not part of this backport; flagged for a follow-up audit.

# Inbound TCP Peer Undefined-Address Bug

**Date:** 2026-04-22 (session continuation)

## Summary

Fixed an intermittent stall in multi-peer transfers where the downloader
would sit at `progress=0.0000` despite having connected peers. Root
cause: inbound TCP-accepted peers were constructed with `peer.address`
left at its `std.net.Address = undefined` default. Downstream code that
iterates peers and reads `peer.address` (PEX duplicate detection, ban
sweeps, smart-ban, the `/sync/torrentPeers` API) saw stack garbage.
Occasional accidental matches against valid addresses caused random
disconnects of healthy connections, which looked like a protocol stall.

## Symptom

`scripts/test_transfer_matrix.sh` was flaky on the larger 64 KB-piece
cases — `large-20m-64k` failed ~20% of runs, `med-10m-64k` occasionally.
The failure signature was always the same:

- Seeder and downloader complete MSE + BT + extension handshake.
- `progress=0.0000` indefinitely, `num_leechs=2` on the downloader side,
  `downloaded=0`.
- Same test completes in ~6 s in isolation.
- Only triggered mid-suite, after ~10+ prior tests had run.
- Specifically 64 KB-piece torrents of ≥ 5 MB (160+ pieces); 16 KB and
  256 KB pieces never failed, and 100 MB torrents with 256 KB pieces
  (400 pieces) also always passed, so the threshold wasn't piece count.

## Diagnosis

Instrumented the test to preserve the workdir and snapshot the daemon's
torrent/peers API state on failure. The snapshot crashed:

```
thread 356921 panic: reached unreachable code
std.net.zig:184:21: getPort — else => unreachable
src/daemon/session_manager.zig:1783 in getTorrentPeers —
    const port: u16 = peer.address.getPort();
```

`getPort()` panicked because `peer.address.any.family` was neither
`AF_INET`, `AF_INET6`, nor `AF_UNIX`. Which means the address field was
whatever garbage happened to be on the stack at the time the Peer was
constructed.

Tracing the construction, `peer_handler.zig:handleAccept` built:

```zig
peer.* = Peer{
    .fd = new_fd,
    .state = .inbound_handshake_recv,
    .mode = .inbound,
};
```

No `.address`. The struct's default is `address: std.net.Address = undefined`.

An existing `getpeername` call above was used *only* to test the ban
list — the resolved address was never stored. For inbound peers the
field stayed undefined forever.

## Consequences of Undefined `peer.address`

Every caller that read `peer.address` on an inbound peer got stack
garbage. The specific downstream paths that matter:

- `protocol.zig:isPeerAlreadyConnected` (called from PEX) iterates all
  peers on a torrent and compares addresses via `addressEql`. A garbage
  address happening to match the real seeder address would make PEX
  (or any other duplicate filter) think the seeder was "already
  connected" and skip / tear down the real connection.
- `event_loop.zig:1590` does `bl.isBanned(peer.address)` on every peer
  during periodic ban sweeps. A garbage address that matches a CIDR
  ban causes the peer to be disconnected as if banned.
- `peer_policy.zig:1141` hands `peer.address` to the PEX state on
  detach; the PEX table ends up with garbage.
- `peer_policy.zig:1878` calls `banIp(peer.address, ...)` in the smart-ban
  path. A mis-attributed garbage address could ban a random range.
- `session_manager.zig:getTorrentPeers` / `getPort` panic directly.

Why only 64 KB-piece tests? No specific reason — the underlying bug is
layout-independent. The tests most likely to trip it are the ones with
the most peer activity, the most PEX traffic, the most ban-sweep
iterations, and the most connection churn — which correlates loosely
with piece count times block count, and the 64 KB-piece cases sit in
the sweet spot where the bug fires often enough to be noticeable but
not so often that every test fails.

## Fix

`src/io/peer_handler.zig:handleAccept`: resolve the remote address via
`getpeername` up front, reject the connection if it fails, and include
it in the `Peer` initialisation.

Before:
```zig
peer.* = Peer{
    .fd = new_fd,
    .state = .inbound_handshake_recv,
    .mode = .inbound,
};
```

After:
```zig
peer.* = Peer{
    .fd = new_fd,
    .state = .inbound_handshake_recv,
    .mode = .inbound,
    .address = peer_address,
};
```

The ban check now reuses the resolved `peer_address` instead of making
its own `getpeername` call.

Other peer-construction sites already set `.address` correctly:
- `event_loop.zig:addPeerForTorrent` (outbound TCP) — passes through
  the configured address
- `event_loop.zig:addUtpPeer` (outbound uTP) — same
- `utp_handler.zig:283` (inbound uTP) — pulls from
  `UtpManager.getRemoteAddress`

## Verification

- `zig build` / `zig build test`: pass.
- `./scripts/demo_swarm.sh`: passes.
- Pre-fix reproduction loop: ran the matrix in a tight loop until
  `large-20m-64k` stalled at `progress=0.0000` — got a hit on attempt 1.
- Post-fix: first full matrix run completed with `large-20m-64k PASS`;
  longer soak is running to confirm the flake is gone.

## Key Code References

- `src/io/peer_handler.zig:19-100` — `handleAccept` flow with the fix
- `src/io/peer_handler.zig:41,105` — `peer_address` resolution + use
- `src/io/protocol.zig:573-582` — `isPeerAlreadyConnected`, the
  addressEql consumer that was most likely to silently misbehave
- `src/io/event_loop.zig:1590` — ban sweep using `peer.address`
- `src/daemon/session_manager.zig:1783` — `getPort` call site that
  actually panicked and gave us the crash dump
- `src/io/types.zig:108` — `address: std.net.Address = undefined`
  default (the trap)

## Follow-ups

- Consider removing the `undefined` default from `Peer.address` and
  making it `?std.net.Address = null`. That would convert future
  forgotten-initializations into compile-time-obvious `null` instead
  of stack-garbage reads, at the cost of a wrapper for every access.
  The current fix is load-bearing; this is a "never again" cleanup.
- STATUS.md Known Issues entry for "`large-20m-64k` intermittent stall"
  can come down once the soak confirms stability.

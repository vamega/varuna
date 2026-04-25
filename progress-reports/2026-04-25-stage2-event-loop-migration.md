# 2026-04-25: Stage 2 EventLoop migration — DONE

## What changed

Stage 2 of the IO abstraction is complete. Every async op in the
daemon now runs through the `io_interface` backend (`RealIO` in
production, `SimIO` in tests). The legacy `ring: linux.IoUring`
field, the `(slot|op_type|context)` packed-userdata scheme,
`OpType` / `OpData` / `encodeUserData` / `decodeUserData`, and the
giant CQE dispatch switch in `event_loop.zig` are all deleted.

`posix.fdatasync` and `timerfd_create` / `timerfd_settime` no longer
appear anywhere on the daemon hot path. `varuna` is the first
production user of the new io_interface end-to-end.

## Commits

In chronological order:

| Commit | Slice |
|---|---|
| `e17cd19` | #8 — `io: RealIO` field on EventLoop alongside legacy `ring` |
| `a33143d` | #9 — timerfd → native `io.timeout` |
| `8e3e46c` | #10 — `PieceStore.sync` → async `io.fsync` |
| `c2b903d` | #11 part 1 — peer recv on `Peer.recv_completion` |
| `0767216` | docs: STATUS + intermediate progress report |
| `56ff7e1` | #12 — signal poll on `io.poll` |
| `281975d` | #12 — multishot peer accept on `io.accept(.multishot)` |
| `b15d3ba` | #12 — recheck reads on `io.read` (per-span ReadOp) |
| `f8cf995` | #12 — disk writes on `io.write` (per-span DiskWriteOp) |
| `fa56885` | #12 — seed disk reads on `io.read` (per-span SeedReadOp) |
| `1bd794a` | #12 — HTTP executor (socket / deadline-bounded connect / send / recv) |
| `5d505cd` | #12 — RPC server (multishot accept / per-client gen-stamped ClientOp) |
| `cfc1dd3` | #12 — metadata fetch (connect / send / recv per Slot) |
| `c4e701d` | #12 — uTP recvmsg/sendmsg on EventLoop completions |
| `67fe292` | #12 — UDP tracker executor (socket / sendmsg / recvmsg per Slot) |
| `050c533` | #12 — outbound peer socket/connect on `Peer.connect_completion` |
| `9a2cff2` | #11 part 2 — peer send (untracked + tracked PendingSend); wait swap |
| `cd8435c` | #12 final — delete legacy `ring`, dispatch switch, `OpType`, shims |

## Patterns that worked well

After 18 migrations, two shapes accounted for almost everything:

### 1. Single Completion per long-lived "slot"

Used wherever the underlying state machine is fully serial. The
Completion is embedded directly in the slot struct; `@fieldParentPtr`
recovers the slot pointer from the completion in the callback;
pointer arithmetic on the parent slice yields the slot index.

- `Peer.recv_completion` — handshake → header → body → next header,
  with MSE chunks; only one recv in flight per peer.
- `Peer.connect_completion` — outbound `socket` chains a `connect` on
  the same completion.
- `Peer.send_completion` — *untracked* peer wire sends (handshake,
  MSE, MSE-resubmit). One untracked send in flight per peer at a
  time; gated by `peer.send_pending`.
- `HttpExecutor.RequestSlot.completion` — DNS → connect → TLS or
  send → recv loop, fully serial within a slot.
- `AsyncMetadataFetch.Slot.completion` — connecting → handshake_send
  → handshake_recv → ext_handshake_send → ext_handshake_recv →
  piece_request_send → piece_recv loop, serial.
- `UdpTrackerExecutor.RequestSlot.completion` — socket → sendmsg →
  recvmsg, serial.
- `EventLoop.tick_timeout_completion` — single one-shot timer.
- `EventLoop.signal_completion` — POLL.IN on signalfd; rearm on first
  fire so a second SIGINT during drain forces immediate exit.
- `EventLoop.accept_completion` — multishot accept; F_MORE preserves
  in_flight.
- `EventLoop.utp_recv_completion` / `utp_send_completion` — UDP
  socket recvmsg/sendmsg.
- `EventLoop.wake_timeout_completion` — for `submitTimeout`.
- `HttpExecutor.dns_poll_completion` /
  `UdpTrackerExecutor.dns_poll_completion` — DNS-eventfd poll, .rearm.

### 2. Heap-allocated tracking struct with embedded Completion

Used for fan-out where multiple ops are in flight against the same
logical entity simultaneously. The struct is `allocator.create`d on
submit, freed by the callback. The Completion address is stable for
the kernel's lifetime regardless of any owning ArrayList growth.

- `recheck.AsyncRecheck.ReadOp` — per-span piece read.
- `peer_handler.DiskWriteOp` — per-span piece write.
- `seed_handler.SeedReadOp` — per-span seed disk read for piece
  responses.
- `rpc.server.ApiServer.ClientOp` — per-client recv/send with a
  generation counter so stale CQEs against a reused slot are
  filtered.
- `buffer_pools.PendingSend` itself — already heap-allocated for the
  `pending_sends: ArrayList(*PendingSend)` model so the embedded
  Completion (in-flight tracked-send tracker) has a stable address.

### Smaller patterns

- `io.connect` with `deadline_ns` cleanly replaces the manual
  `IOSQE_IO_LINK + link_timeout` hack on `ud + 1` previously seen
  in HttpExecutor.
- `io.poll(POLL.IN)` with `.rearm` callback replaces the
  `sentinel_dns` / `sentinel_*` userdata convention used by HTTP and
  UDP tracker for DNS-eventfd plumbing.
- `io.cancel(.{ .target = &c })` replaces manual
  `ring.cancel(cancel_ud, accept_ud, 0)` with shared
  `accept_cancel_completion` etc.

## Foundation bugs surfaced and fixed

Both surfaced once real callbacks started re-arming the same
completion. The parity tests didn't trip them because their
callbacks return `.disarm` immediately.

### Bug A — `dispatchCqe` cleared `in_flight` after the callback

`RealIO.dispatchCqe` previously ran:

```
const action = callback(...);
if (!more) realState(c).in_flight = false;
```

A callback that re-armed the same completion in the natural
"recv body, then immediately recv next header" pattern hit
`AlreadyInFlight` against itself. Fix: clear `in_flight` *before*
the callback (multishot still leaves it set, since the kernel will
deliver more CQEs against the same SQE).

### Bug B — `Completion._backend_state` defaulted to `undefined`

In Debug, undefined memory is filled with `0xaa`. `realState(c)`
casts the field to `RealState` whose first field is
`in_flight: bool`; reading `0xaa` byte 0 as bool gave `true`, so
fresh completions could observe stale `in_flight=true`. Fix: default
the byte array to `[_]u8{0} ** 64`.

### The blocking-wait swap

A subtler one. During the migration, `EventLoop.tick()` blocked on
`self.ring.submit_and_wait(1)` and drained `self.io` non-blocking.
That works while the legacy ring still has SQEs queued. Once peer
send and the residual op types moved to `io`, the legacy ring went
empty and `submit_and_wait(1)` blocked indefinitely. Fix
(commit `9a2cff2`): swap to `self.io.tick(1)` as the blocking call
and drain the legacy ring non-blocking; in the final cleanup
(`cd8435c`) the legacy ring is gone.

## Tests

163/163 throughout the migration — no regression. The new tests
the team-lead anticipated would land here didn't materialise: every
sub-task was best validated by the existing integration suite
(test-sim, test-transfer, test-event-loop) plus the parity tests.
The recv path's two foundation fixes were caught by `test-sim`,
which exercises a full handshake → header → body → request → piece
flow against a real socketpair. `test-io-parity` stays at 2/2.

## What's left

Stage 2 is complete. Stages 3+ (Simulator + sim_swarm tests, SimPeer
behaviours, BUGGIFY) are sim-engineer's track. With the legacy ring
gone, parameterising `EventLoop` over `comptime IO: type` is now a
mechanical lift — every reference to `self.io` and `*RealIO` in the
codebase becomes `self.io` and `*IO` with a generic type parameter
threading through. That's the right entry point for whichever
teammate picks up `Simulator + EventLoop(SimIO)`.

## Key code references

- `src/io/event_loop.zig:62-300` — EventLoop struct (no `ring` field).
- `src/io/event_loop.zig:1426-1461` — `tick()` blocking on
  `io.tick(1)`.
- `src/io/event_loop.zig:1505-1525` — `submitTimeout` on
  `wake_timeout_completion`.
- `src/io/peer_handler.zig:21-44` — `peerAcceptComplete` rearm.
- `src/io/peer_handler.zig:131-169` — `peerSocketComplete` chains
  `io.connect`.
- `src/io/peer_handler.zig:330-340` — `peerSendComplete` (untracked).
- `src/io/peer_handler.zig:357-389` — `pendingSendComplete` (tracked).
- `src/io/peer_handler.zig:418-456` — `peerRecvComplete`.
- `src/io/peer_handler.zig:802-844` — `DiskWriteOp` +
  `diskWriteComplete`.
- `src/io/protocol.zig:426-456` — three migrated recv submission
  helpers.
- `src/io/real_io.zig:114-140` — `dispatchCqe` with the in_flight
  fix.
- `src/io/io_interface.zig:251-257` — zero-default
  `_backend_state`.
- `src/io/buffer_pools.zig:312-331` — `PendingSend` with embedded
  Completion.
- `src/io/event_loop.zig:2065-2120` — `submitPendingSend` /
  `handlePartialSend`.
- `src/storage/writer.zig:124-160` — async `sync(io)` API.
- `src/io/recheck.zig:108-160` — `ReadOp` + `recheckReadComplete`.
- `src/io/seed_handler.zig:24-58` — `SeedReadOp` +
  `seedReadComplete`.
- `src/rpc/server.zig:118-135` — `ClientOp` (per-op gen-stamped).
- `src/rpc/server.zig:138-256` — `apiAcceptComplete` /
  `apiRecvComplete` / `apiSendComplete`.
- `src/io/http_executor.zig:269-330` — `httpSocketComplete` /
  `httpConnectComplete` (deadline-bounded).
- `src/io/http_executor.zig:560-700` — `httpSendComplete` /
  `httpRecvComplete`.
- `src/io/metadata_handler.zig:170-225` —
  `metadataConnectComplete` / `metadataSendComplete` /
  `metadataRecvComplete`.
- `src/daemon/udp_tracker_executor.zig:225-310` —
  `udpSocketComplete` / `udpSendComplete` / `udpRecvComplete`.
- `src/io/utp_handler.zig:42-84` — `utpRecvComplete` /
  `utpSendComplete`.

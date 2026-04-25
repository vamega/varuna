# 2026-04-25: Stage 2 EventLoop migration (#8, #9, #10, #11 part 1)

## What changed

Started the Stage 2 lift of `event_loop.zig` from the legacy
`(slot|op_type|context)` packed user_data scheme onto the new
`io_interface`-based `RealIO` backend. Four of the five Stage 2 task
slices landed; peer send (the second half of #11) and the rest of
#12 remain.

## Commits in this batch

| Commit | Slice |
|---|---|
| `e17cd19` | #8 — `io: RealIO` field on EventLoop |
| `a33143d` | #9 — timerfd → native `io.timeout` |
| `8e3e46c` | #10 — `PieceStore.sync` → async `io.fsync` |
| `c2b903d` | #11 part 1 — peer recv on `Peer.recv_completion` |

### #8: parallel `io: RealIO` field

`EventLoop` now embeds a second io_uring instance (`io: RealIO`)
alongside the legacy `ring: linux.IoUring`. They share fds; each call
site flips atomically between them during the migration. `tick()`
drains `io` non-blockingly before the legacy ring's `submit_and_wait`
and again after dispatch. `deinit` flushes `io` alongside `ring` in
the existing Phase 0/Phase 2 drain loops, then deinits `io` in
Phase 4. `RealIO.init` gained the same `COOP_TASKRUN | SINGLE_ISSUER`
fallback path that `ring.zig:initIoUring` uses, so older kernels
still boot.

### #9: timerfd → io.timeout

The old timer mechanism (timerfd_create → timerfd_settime → io_uring
read on the timerfd) is gone. `EventLoop.tick_timeout_completion`
arms a single one-shot `io.timeout` per scheduled callback;
`tickTimeoutComplete` clears `timer_pending` and drains expired
callbacks via `fireExpiredTimers`, which re-arms for the next
soonest deadline. `OpType.timerfd` is deleted; the corresponding
dispatch arm is gone. This was the first real proof the new path
works end-to-end.

### #10: PieceStore.sync → io.fsync

`posix.fdatasync` no longer appears anywhere in the daemon path.
`PieceStore.sync` now takes a `*RealIO`, allocates one
`io_interface.Completion` per open file, submits them all via
`io.fsync(.datasync = true)`, and ticks the ring until every
completion fires. The first fsync error is surfaced after all
completions land. Both call sites (the `writer.zig` test and
`tests/transfer_integration_test.zig`) construct a one-shot RealIO
around the call.

A small helper, `SyncContext { pending, first_error }`, plus the
private `syncCompleteCallback` form the count-down. It's the model
for any future "submit N, wait for all, surface the first error"
pattern.

### #11 part 1: peer recv migration

Recvs are naturally serial per peer (handshake → header → body, with
MSE chunks as needed), so a single `recv_completion` field on `Peer`
is sufficient. All five recv submission helpers migrated:

- `protocol.submitHandshakeRecv`
- `protocol.submitHeaderRecv`
- `protocol.submitBodyRecv`
- `peer_handler.executeMseAction` (.recv arm)
- `peer_handler.startMseResponder` (catch-up read)

The new callback `peer_handler.peerRecvComplete`:

1. Recovers `*Peer` via `@fieldParentPtr("recv_completion", c)`.
2. Computes the slot index from `(@intFromPtr(peer) - peers.ptr) / @sizeOf(Peer)`.
3. Translates `Result.recv` into a synthetic cqe-shaped `i32`
   (negative on error) and calls the existing dispatch body, now
   factored out as `handleRecvResult(self, slot, recv_res)`.
4. Returns `.disarm`.

`OpType.peer_recv` and the corresponding dispatch arm are deleted.
`perf/workloads.runPeerAcceptBurst` stops counting `peer_recv` CQEs
on the legacy ring (they no longer land there) and gains an
`io.tick(0)` drain so io_interface completions still progress.

## Foundation bugs surfaced and fixed

Both bugs were latent; the parity tests didn't trip them because
their callbacks return `.disarm` without re-arming the same
completion. The recv migration is the first real exercise of the
"callback re-arms its own completion" path.

### Bug A — `dispatchCqe` cleared `in_flight` after the callback

`RealIO.dispatchCqe` previously ran:

```
const action = callback(...);
if (!more) realState(c).in_flight = false;
```

So a callback that re-armed the same completion in the natural
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

## Tests

163/163 (no regression). `test-io-parity 2/2`, `test-transfer 1/1`,
`test-event-loop 3/3`, `test-sim 1/1` (the latter exercises the new
recv path end-to-end through a VirtualPeer seeder/EventLoop
downloader transfer).

## What's left

- **#11 part 2 — peer send migration.** Examination of `peer_policy.zig`
  shows the daemon explicitly relies on multiple in-flight tracked
  sends per peer for pipeline refills (see comment at
  `peer_policy.zig:259`). A single `send_completion` per peer would
  regress that. The proper shape: untracked sends (handshake, MSE)
  use `Peer.send_completion`; tracked sends embed a Completion
  inside `PendingSend`. This is a moderate refactor — flagged in a
  team-lead message.

- **#12 — remaining op types.** HTTP (`http_executor.zig`), RPC
  accept/recv/send, peer listener multishot accept, disk read/write
  (PieceStore via peer_handler/web_seed_handler), recheck
  (`recheck.zig`), metadata (`metadata_handler.zig`), uTP
  (`utp_handler.zig`), UDP tracker, signal poll. Once everything is
  migrated, `encodeUserData` / `decodeUserData` / `OpType` and the
  CQE dispatch switch all go away, along with the legacy `ring`
  field on `EventLoop`.

## Key code references

- `src/io/event_loop.zig:146-153` — `io: RealIO` field.
- `src/io/event_loop.zig:354-368` — RealIO init with fallback.
- `src/io/event_loop.zig:415-451` — `tick()` drain order
  (legacy + io interleaved).
- `src/io/event_loop.zig:1480-1525` — `armNextTimer` / `tickTimeoutComplete`.
- `src/io/peer_handler.zig:418-456` — `peerRecvComplete` callback +
  `handleRecvResult` factoring.
- `src/io/protocol.zig:426-450` — three migrated recv submission
  helpers.
- `src/io/real_io.zig:114-140` — `dispatchCqe` with the in_flight
  fix.
- `src/io/io_interface.zig:251-256` — zero-default `_backend_state`.
- `src/storage/writer.zig:124-160` — async `sync(io)` API.
- `src/storage/writer.zig:200-225` — `SyncContext` + callback.

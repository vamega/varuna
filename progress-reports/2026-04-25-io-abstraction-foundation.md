# 2026-04-25: IO abstraction foundation (Stages 1, 2 partial, 3 early)

## What changed

Landed the foundation of the IO abstraction described in `docs/io-abstraction-plan.md`. The daemon's EventLoop is **not** yet generic over its IO backend — but the contract, both backends, and a parity proof are in place so that the migration of `event_loop.zig` is now a mechanical lift across the 86 known io_uring call sites.

### New files

- `src/io/io_interface.zig` — public contract: `Operation` and `Result` tagged unions (one variant per op), `CallbackAction = enum { disarm, rearm }`, single-callback signature, caller-owned `Completion` struct with opaque per-backend state (`backend_state_size = 64`, comptime-asserted by each backend).
- `src/io/sim_io.zig` — in-process simulation backend. Min-heap pending queue keyed by `(deadline_ns, seeded_seq)`, `FaultConfig` with per-op error probabilities + latency injection, seeded `std.Random.DefaultPrng`. Submissions land synchronously; `tick()` drains all completions with `deadline <= now_ns`. Zero-alloc after init.
- `src/io/real_io.zig` — `linux.IoUring` backend. Encodes `Completion*` as the SQE's `user_data`, dispatches CQEs via `Completion.callback`. Multishot accept supported via `op.multishot` (relies on `IORING_CQE_F_MORE`). Connect deadlines submit a paired `link_timeout` SQE with a sentinel `user_data` that gets silently consumed.
- `tests/io_backend_parity_test.zig` — comptime check that both backends expose the required method set + runtime tests that run identical bodies against `RealIO` and `SimIO`.

### Test count

Before this session: ~145 tests (estimate). After: **163 / 163 passing**. 18 new tests across the four files above.

## Key design decisions (locked in)

1. **Comptime duck-typed interface, not vtables.** The eventual `EventLoop(comptime IO: type)` will pick its backend at compile time. Zero runtime dispatch overhead.
2. **Caller-owned completions.** A `Completion` is a struct that the caller embeds in a longer-lived holder (e.g. a peer slot). The backend writes results into it and invokes the callback. The backend never allocates a completion.
3. **Single concrete `Completion` type, opaque backend state.** Avoids propagating `Peer(IO)` generics through hundreds of files. Backends `comptime assert` their state fits in `backend_state_size = 64` bytes.
4. **One callback signature.** `fn(?*anyopaque, *Completion, Result) CallbackAction`. The userdata reaches its IO backend through ownership context, not through a generic on the callback type.
5. **`anyerror` on results.** Each `Result` variant returns `anyerror!T` rather than typed error unions. Keeps the interface flat across backends; callers switch on specific errors when they care.
6. **Migration via parallel `io: RealIO` field.** The plan is to add an `io: RealIO` field alongside the existing `ring: linux.IoUring` and migrate call sites one op type at a time. Old and new APIs coexist until all sites are converted, at which point the old `ring` field is deleted.

## What this proves

- The interface contract is exercisable: 16 unit tests (8 SimIO, 5 RealIO, 3 io_interface) and 2 parity tests demonstrate end-to-end submit → callback flow.
- Both backends are interchangeable: `tests/io_backend_parity_test.zig` runs identical test bodies against each; the comptime check fails to compile if a backend's method signature drifts.
- `RealIO` works against real `io_uring`: `recv` on a socketpair, `send + recv` round-trip, `cancel` aborts in-flight ops, `fsync` on a tempfile, `timeout` fires — all on a 16-entry ring.
- `SimIO` works deterministically: timeouts deliver in deadline order, fault injection at probability 1.0 always errors, cancel removes a target and delivers `OperationCanceled`, `rearm` resubmits.

## What does **not** yet work

- The daemon cannot run in simulation — `event_loop.zig` still calls `self.ring.*` directly (86 call sites across 18 op types). Migrating it is the bulk of Stage 2.
- `SimIO` has no fd / socketpair machinery yet — `recv` and `send` deliver zero bytes by default. To actually exchange data between two `SimPeer`s through `SimIO`, the in-process socketpair (Task #13) needs to land.
- `Simulator` and `SimPeer` (Stages 3-4) are not implemented. The smart-ban sim test (Stage 4) is gated on these.
- `BUGGIFY` (Stage 5) is gated on Stage 4.

## Next steps (decomposed and tracked as tasks)

| Task | Stage | What |
|---|---|---|
| #8  | 2 | Add `io: RealIO` field to EventLoop alongside the existing `ring`. |
| #9  | 2 | Migrate `timerfd_create + timerfd_settime + read(timer_fd)` at `event_loop.zig:345,1464` to native `io.timeout` op. Self-contained slice — drop the `timerfd` OpType. |
| #10 | 2 | Convert `posix.fdatasync` at `storage/writer.zig:127` to async `io.fsync(datasync = true)`. Removes a hot-path block. |
| #11 | 2 | Embed `Completion` fields in `Peer`, migrate peer recv/send dispatch from the `decodeUserData` switch to direct `Completion.callback`. |
| #12 | 2 | Migrate the remaining op types (HTTP, RPC, accept, disk read/write, recheck, metadata, uTP, UDP tracker, signal poll). Delete `encodeUserData/decodeUserData/OpType`. |
| #13 | 3 | SimIO socketpair: `createSocketpair() -> [2]fd`, `send(fd_a, bytes)` queues to `partner.recv_queue`, parked `recv` on `fd_b` delivers from queue. |
| #5  | 3 | `Simulator` + `SimSwarm`: drives `EventLoop(SimIO)` with a tick loop. Requires Stage 2 done. |
| #6  | 4 | `SimPeer` behaviors (honest, slow, corrupt, wrong_data, silent_after, disconnect_after, lie_bitfield) + smart-ban sim test. |
| #7  | 5 | BUGGIFY: per-tick fault injection from a seeded RNG. |

## Code references

- `src/io/io_interface.zig:1-279` — full contract.
- `src/io/io_interface.zig:46` — `backend_state_size = 64`.
- `src/io/sim_io.zig:80-95` — `SimState`.
- `src/io/sim_io.zig:140-165` — `Pending` and heap key.
- `src/io/real_io.zig:39-58` — `RealState`.
- `src/io/real_io.zig:107-141` — `dispatchCqe` (multishot-aware).
- `tests/io_backend_parity_test.zig:29-50` — comptime backend conformance check.
- `docs/io-abstraction-plan.md` — full design.

## How to verify

```
zig build                       # daemon still builds
zig build test                  # 163/163 tests pass
zig build test-io-parity        # parity test in isolation
```

The parity test is the canonical "does the abstraction hold" check. Add a new backend: make this test pass.

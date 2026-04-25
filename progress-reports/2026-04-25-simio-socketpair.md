# 2026-04-25: SimIO socketpair / fd machinery (Stage 3 #13)

## What changed

`SimIO` can now actually deliver bytes between two parties in-process. Before this change, `recv` and `send` either returned zero bytes or a fault-injected error; there was no way to wire a `SimPeer` ↔ `EventLoop` round-trip through the simulator. After this change, two `Completion`s submitted on the two halves of a `createSocketpair()` exchange real bytes through a per-socket ring buffer.

### Public surface added

- `SimIO.createSocketpair() ![2]posix.fd_t` — allocates two slots from the pre-sized socket pool and links them as partners. The returned fake fds live in `[1000, 1000 + socket_capacity)`. Synthetic fds returned by the `socket` op live in `[100_000, ...)` so they never collide with sim-socket fds.
- `SimIO.closeSocket(fd: posix.fd_t) void` — marks the slot closed. Any parked recv on this slot fires with `error.ConnectionResetByPeer`. The partner's parked recv (if any) also fires with reset, modelling the peer-side semantics that the EventLoop cares about. Slots are not returned to the free list — closed sockets stay in the pool until `deinit`.
- New `Config` fields: `socket_capacity: u32 = 64`, `recv_queue_capacity_bytes: u32 = 64 * 1024`. Default 64 slots × 64 KiB recv buffer = 4 MiB allocator-up-front, easily resizable per test.

### Behaviour changes

- `recv` looks up the fd:
  - Sim socket with bytes queued → consume into the caller's buffer, schedule with `recv_latency_ns`.
  - Sim socket with empty queue → **park** the completion on the socket. The completion stays `in_flight` but is not in the heap. `parked_socket_index` in `SimState` records the slot.
  - Sim socket that's closed → schedule with `error.ConnectionResetByPeer`.
  - Non-sim fd → fall through to the legacy zero-byte-default path so existing tests (`fd = 7`, etc.) keep working.
- `send` looks up the fd, finds the partner via `partner_index`, and:
  - Appends bytes into `partner.recv_queue`. If the queue is full, returns the partial count.
  - If the partner has a parked recv, pulls bytes out for it and schedules its completion with `recv_latency_ns`.
  - Schedules the send completion with `result.send = bytes_written` and `send_latency_ns`. Send returns immediately even if the partner has no parked recv (zero-copy semantics — caller owns the buffer).
- `cancel` adds a third branch: parked-on-socket. The completion is removed from `socket.parked_recv`, scheduled with `OperationCanceled`, and the cancel completion fires with success. The earlier in-heap branch is unchanged.

### Implementation notes

- `SimState` grew a `parked_socket_index: u32` field. Switched the struct from `packed` to a regular struct because adding the new field pushed the packed layout's `@alignOf` past `backend_state_align = 8`. The non-packed struct sits at 12 bytes / 4-byte align — well within `backend_state_size = 64` and the `@alignOf <= 8` cap.
- The rearm path in `tick()` now resets `simState(c).* = .{}` before re-submitting through the public path. `popMin` only clears `heap_index`; in_flight stays true, which would otherwise trip `armCompletion`'s "AlreadyInFlight" check on the resubmit. Resubmission goes through the public method (`recv`, `send`, etc.) so the socket-vs-heap routing is recomputed fresh.
- `submitOp` was decomposed into `armCompletion` (sets `c.op`/`userdata`/`callback`/state, refuses double-arm) + `schedule` (pushes onto the heap with a pre-resolved result). Each public method calls `armCompletion` first and then routes either to `schedule` (heap path) or to the parking helper (no schedule, just record the slot).

### Tests

15 new tests in `tests/sim_socketpair_test.zig`:
- `createSocketpair returns two distinct fds`
- `socketpair round-trip: send then recv delivers bytes`
- `recv parks until partner sends`
- `partial recv leaves remaining bytes in queue`
- `multiple sends accumulate in partner queue`
- `closeSocket fails parked recv with ConnectionResetByPeer`
- `closeSocket fails partner's parked recv too`
- `send on closed local fd returns BrokenPipe`
- `send to closed peer returns BrokenPipe`
- `recv on closed local fd returns ConnectionResetByPeer`
- `cancel of parked recv delivers OperationCanceled`
- `mixed: heap-pending timeout coexists with socket-parked recv`
- `socket capacity exhausted returns SocketCapacityExhausted`
- `recv on non-socket fd uses legacy zero-byte path`
- `createSocketpair: many pairs up to capacity`

Test count: 163 → 178.

### Build wiring

The inline `test` blocks in `src/io/sim_io.zig` aren't reachable from `mod_tests`/`daemon_tests` (Zig 0.15 does not auto-discover tests in transitively imported modules in this codebase, and the `test { _ = @import(...) }` pattern in subsystem `root.zig` files reports zero discovered tests too). Cross-module imports are also not allowed from `tests/`, so a one-line `_ = @import("../src/io/sim_io.zig")` wrapper isn't an option.

Workaround: write the tests directly in `tests/sim_socketpair_test.zig` against the public `varuna.io.sim_io.SimIO` surface, and add a dedicated build step `test-sim-io` that the `test` step depends on.

This means the original 8 inline tests in `sim_io.zig` still don't actually run, even though they compile. That's a pre-existing gap; not in scope here. (It applies to the inline tests in `real_io.zig` and `io_interface.zig` too.) A future cleanup could create a wrapper file inside the `varuna` module path that pulls them in via `_ = @import("sim_io.zig");` — that's the only way to bridge the import barrier without restructuring the module.

## Code references

- `src/io/sim_io.zig:43-58` — `SimState` (now non-packed; carries `parked_socket_index`).
- `src/io/sim_io.zig:135-186` — `RecvQueue` ring buffer.
- `src/io/sim_io.zig:188-201` — `SimSocket`.
- `src/io/sim_io.zig:332-365` — `createSocketpair`, `closeSocket`.
- `src/io/sim_io.zig:368-422` — `recv` with park / consume / fault paths.
- `src/io/sim_io.zig:424-487` — `send` with append / unpark / fault paths.
- `src/io/sim_io.zig:583-611` — `cancel` with parked-on-socket branch.
- `tests/sim_socketpair_test.zig` — 15 unit tests.
- `build.zig:269-285` — `test-sim-io` build step.

## Verification

```
nix develop --command zig build                # daemon still builds
nix develop --command zig build test-sim-io    # 15/15 pass
nix develop --command zig build test           # 178/178 pass
```

## Next

The path is now clear for Stage 3 #5 (Simulator + minimal sim_swarm test) — the IO substrate exists and is exercised. That task is gated on Stage 2 EventLoop migration (#11/#12) being far enough along that `EventLoop` is parameterised over its IO backend. Migration-engineer is currently on #11.

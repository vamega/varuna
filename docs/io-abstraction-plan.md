# IO Abstraction Plan

This document captures the design for making the EventLoop generic over its IO backend,
enabling a first-class simulation backend (`SimIO`) alongside the production `RealIO`
(io_uring). It is a living design document — sections marked **[OPEN]** are not yet settled.

Links: [STYLE.md](../STYLE.md) | [zero-alloc-plan.md](zero-alloc-plan.md) | [STATUS.md](../STATUS.md)

---

## Why we own the interface

Three alternatives were evaluated: libxev, ZIO, and Zig 0.16's `std.Io`.

**libxev**: Callback-based proactor, same pattern we'd design ourselves. But it's
cross-platform (complexity we don't need), its Zig 0.16 support required 2,500 lines of
compatibility shims, and its README explicitly states it won't integrate with `std.Io`. No
simulation backend exists or is planned.

**ZIO**: Stackful coroutines with 256 KB–8 MB of stack per fiber. With 500 peers that is
128 MB–4 GB in stacks alone on the data plane, directly contradicting the zero-alloc goal.
Additionally, ZIO is mid-migration to Zig 0.16 (issue #99 open) and has no simulation
backend.

**std.Io (Zig 0.16)**: The right design pattern — IO context passed like an allocator —
but the io_uring backend is explicitly a proof-of-concept and not production ready.

**Conclusion**: None of the three provide simulation. All three would require us to build
SimIO ourselves anyway. We own the interface so that simulation is first-class rather than
bolted on, the interface is exactly as thin as io_uring needs, and we carry no external
dependency risk across Zig version upgrades.

We take design inspiration from:
- **libxev**: caller-owned completion structs, intrusive queue linkage, `CallbackAction`
- **ZIO / std.Io**: IO context passed like an allocator through the call stack
- **TigerBeetle VOPR**: seeded-RNG fault injection, deterministic completion ordering

---

## Design Principles

**The EventLoop is generic over its IO backend.** Production code uses `RealIO` (io_uring).
Test code uses `SimIO`. Both implement the same comptime interface. There are no vtables,
no runtime dispatch, no `if (testing)` branches in production code.

**Completions are caller-owned.** The IO backend never allocates a completion. The caller
declares a `Completion` in a long-lived location (embedded in a `Peer` slot, or on the
stack for one-shot operations) and passes a pointer. The backend writes the result into the
completion and invokes the callback. The backend holds only a pointer — never an allocation.

**The interface is as small as possible.** Only operations that the EventLoop actually
submits are in the interface. No convenience wrappers, no cross-platform abstractions.

**SimIO is zero-allocation after init.** The simulation's pending-completion priority queue
is pre-allocated at init with a fixed capacity. Fault injection uses a seeded PRNG
initialised at sim construction time. No allocation occurs during a simulation tick.

---

## The Interface

**[OPEN]** The exact interface definition is the primary thing to iterate on. The sketch
below captures intent; field names, error sets, and method signatures should be reviewed
before implementation begins.

```zig
/// IO is a comptime duck-typed interface. Any type that provides the following
/// declarations may be used as the IO backend for EventLoop.
///
/// Required declarations:
///   Completion: type
///   CallbackAction: enum { disarm, rearm }
///
/// Required methods (called by EventLoop):
///   fn tick(self: *IO) void
///   fn recv(self: *IO, fd: posix.fd_t, buf: []u8, c: *Completion, cb: Callback) void
///   fn send(self: *IO, fd: posix.fd_t, buf: []const u8, c: *Completion, cb: Callback) void
///   fn read(self: *IO, fd: posix.fd_t, buf: []u8, offset: u64, c: *Completion, cb: Callback) void
///   fn write(self: *IO, fd: posix.fd_t, buf: []const u8, offset: u64, c: *Completion, cb: Callback) void
///   fn fsync(self: *IO, fd: posix.fd_t, c: *Completion, cb: Callback) void
///   fn timeout(self: *IO, ns: u64, c: *Completion, cb: Callback) void
///   fn cancel(self: *IO, c: *Completion) void
///
/// Callback type (per-operation result union):
///   fn (userdata: ?*anyopaque, io: *IO, c: *Completion, result: Result) CallbackAction
```

**[OPEN]** Should the callback be a tagged union of per-operation callbacks, or a single
callback with a `Result` union? libxev uses a single callback with a result union. That
makes completion structs uniform but means callbacks must switch on the result type. A
per-operation callback avoids the switch but requires different completion types per
operation.

**[OPEN]** Where does `userdata` live — in the completion struct or passed separately to
each submit call? libxev puts it in the completion. This means one completion can only
serve one callback at a time, which matches our single-outstanding-operation-per-slot model.

**[OPEN]** `connect` and `accept` are needed for `RealIO` but SimIO can inject peers via
`SimIO.addPeer()` without going through a connect/accept path. Should connect/accept be in
the interface, or handled outside it (i.e., `EventLoop` only uses the interface for
data-transfer operations, and peer injection happens through a separate sim-specific API)?

---

## Completion Struct

The `Completion` is a caller-owned struct embedded in longer-lived structures. It carries
the operation parameters, the callback, and the intrusive queue linkage needed by the
backend. The backend may write additional state into it (e.g., the io_uring SQE index).

```zig
/// Sketch — exact fields TBD.
pub const Completion = struct {
    // Intrusive queue linkage (owned by the backend while submitted).
    next: ?*Completion = null,

    // Operation parameters (set by caller before submitting).
    op: Operation,

    // Callback invoked on completion.
    userdata: ?*anyopaque,
    callback: Callback,

    // Backend-private state (e.g. sqe_index for RealIO, deadline for SimIO).
    // [OPEN] Should this be a union(backend_tag) or opaque bytes?
    _backend: BackendState = .{},
};
```

**[OPEN]** `BackendState` — how to store backend-private fields without making `Completion`
generic over `IO`? Options:
1. Fixed opaque byte array sized to `@max(RealIO.State, SimIO.State)` — no generics, some
   wasted space.
2. Make `Completion` generic: `Completion(IO: type)` — clean but propagates generics
   everywhere.
3. Store backend state outside the completion in parallel arrays indexed by submission order
   — completion stays clean but adds indirection.

---

## File Structure

```
src/io/
  io_interface.zig     ← Completion, CallbackAction, Result types; interface documentation
  real_io.zig          ← RealIO: wraps the existing io_uring ring (extracted from event_loop.zig)
  sim_io.zig           ← SimIO: in-process pending queue, fault injection, seeded PRNG
  event_loop.zig       ← becomes EventLoop(comptime IO: type)
  simulator.zig        ← Simulator: owns SimIO + SimSwarm, drives tick loop
  sim_peer.zig         ← SimPeer: scriptable in-process peer (replaces VirtualPeer for sim tests)
```

`VirtualPeer` (AF_UNIX socketpair) stays for integration tests that want a real socket.
`SimPeer` is the sim-only replacement: no file descriptors, no threads, completions
delivered directly through `SimIO`.

---

## RealIO

`RealIO` wraps the io_uring ring that currently lives inside `EventLoop`. The extraction is
not a rewrite — the SQE submission and CQE processing code moves largely as-is into
`real_io.zig`. `EventLoop` stops calling `self.ring.*` directly and calls `self.io.*`
instead.

The ring is still created at `EventLoop.init`; `RealIO` is initialised with a pointer to
it. The peer state machines, protocol handling, and piece tracking do not change.

**[OPEN]** Does `RealIO` own the ring (`linux.IoUring`) or does `EventLoop` own it and
pass a pointer to `RealIO`? Ownership in `RealIO` is cleaner but makes `EventLoop.init`
slightly more complex. Ownership in `EventLoop` preserves the current structure and makes
the extraction smaller.

---

## SimIO

`SimIO` maintains a priority queue of pending completions sorted by simulated delivery
time. The simulator advances a logical clock and calls `sim_io.tick(now_ns)`, which
delivers all completions with `deadline <= now_ns` by invoking their callbacks in order.

```zig
pub const SimIO = struct {
    pending: PendingQueue,   // min-heap sorted by deadline_ns; pre-allocated at init
    rng: std.rand.DefaultPrng,
    faults: FaultConfig,
    now_ns: u64 = 0,

    pub const FaultConfig = struct {
        recv_error_probability: f32 = 0.0,   // inject ECONNRESET with this probability
        send_error_probability: f32 = 0.0,
        read_error_probability: f32 = 0.0,   // inject EIO with this probability
        write_error_probability: f32 = 0.0,
        recv_latency_ns: u64 = 0,            // added to every recv delivery time
        write_latency_ns: u64 = 0,           // simulates slow disk
        completion_jitter_ns: u64 = 0,       // random jitter on each completion (0 = none)
    };

    /// Called by Simulator.step(). Delivers all completions due at or before now_ns.
    pub fn tick(self: *SimIO, now_ns: u64) void { ... }

    /// Inject a peer connection directly (no connect/accept path).
    pub fn addPeer(self: *SimIO, peer: *SimPeer) void { ... }

    /// Inject a disk write failure for the next write to this fd.
    pub fn injectWriteError(self: *SimIO, fd: posix.fd_t, err: anyerror) void { ... }
};
```

**[OPEN]** Capacity of the pending queue. With 500 peers and up to 4 in-flight operations
per peer (recv, send, read, write), the queue needs ~2,000 slots. Should this be a fixed
compile-time constant or configurable at `SimIO.init`?

**[OPEN]** Completion ordering within the same `now_ns`. When multiple completions are due
at the same simulated time, what order are they delivered in? Options: submission order
(deterministic, matches intuition), random order (stress-tests the EventLoop's ordering
assumptions), or priority by operation type (recvs before writes, etc.). The random order
with a fixed seed is the most useful for finding bugs.

---

## SimPeer

`SimPeer` replaces `VirtualPeer` for simulation tests. It has no file descriptor and runs
no background thread. Instead, it registers with `SimIO` and the simulator drives it
forward each tick.

```zig
pub const SimPeer = struct {
    behavior: Behavior,
    state: ProtocolState,   // tracks where this peer is in the BT handshake
    rng: *std.rand.DefaultPrng,  // shared with the simulator

    pub const Behavior = union(enum) {
        honest: void,
        slow: struct { bytes_per_ns: u64 },
        corrupt: struct { probability: f32 },
        wrong_data: void,
        silent_after: struct { blocks: u32 },
        disconnect_after: struct { blocks: u32 },
        lie_bitfield: void,
    };
};
```

`SimPeer.step()` is called by the simulator each tick. It inspects its behavior and either
delivers the next BT message to the EventLoop via `SimIO` (inserting a completion into the
pending queue with the appropriate deadline) or does nothing (simulating a slow or silent
peer).

**[OPEN]** Should `SimPeer` implement the full BT wire protocol internally, or should it be
driven by a simpler script (a sequence of pre-determined messages)? A full protocol
implementation is more realistic but complex. A script is simpler and sufficient for most
fault scenarios. Possibly: a script for fault scenarios, a full implementation for swarm
tests.

---

## Simulator

`Simulator` owns the `SimIO`, a `SimSwarm` of `SimPeer`s, and the `EventLoop`. It drives
the tick loop with a controlled clock.

```zig
pub const Simulator = struct {
    io: SimIO,
    el: EventLoop(SimIO),
    swarm: SimSwarm,
    rng: std.rand.DefaultPrng,
    clock_ns: u64,

    pub fn init(seed: u64, config: Config) !Simulator { ... }

    /// Advance simulation by delta_ns of logical time.
    /// Drives the swarm peers, then ticks SimIO (delivering due completions),
    /// then ticks the EventLoop (processing delivered completions).
    pub fn step(self: *Simulator, delta_ns: u64) void {
        self.clock_ns += delta_ns;
        self.el.clock.set(@divFloor(self.clock_ns, std.time.ns_per_s));
        for (self.swarm.peers) |*peer| peer.step(self.clock_ns, &self.rng);
        self.io.tick(self.clock_ns);
        self.el.tick();
    }

    pub fn runUntil(
        self: *Simulator,
        comptime condition: fn (*Simulator) bool,
        max_steps: u32,
        step_ns: u64,
    ) bool {
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            if (condition(self)) return true;
            self.step(step_ns);
        }
        return false;
    }
};
```

**[OPEN]** Step granularity. A 1ms step (1,000,000 ns) gives enough resolution to model
peer round-trip times (typically 10ms–200ms on a LAN) while keeping simulation fast. Should
step size be fixed or variable (e.g., jump directly to the next scheduled completion)?
Variable step size gives better determinism but requires the pending queue to expose its
next deadline.

---

## Extraction Plan

The refactor is staged to keep the tree building and tests passing at each step.

**Stage 1**: Define `io_interface.zig` — the `Completion`, `CallbackAction`, `Result`, and
interface documentation. No EventLoop changes yet.

**Stage 2**: Extract `RealIO` from `EventLoop`. Move the ring submission and CQE dispatch
into `real_io.zig`. `EventLoop` becomes `EventLoop(comptime IO: type)` with `IO = RealIO`
hardcoded initially. All existing tests must pass.

**Stage 3**: Write `SimIO` with a static pending queue and the `FaultConfig`. Write a
minimal sim test using `Simulator` with a single honest `SimPeer` — equivalent to the
existing `sim_swarm_test.zig` but without AF_UNIX sockets or background threads.

**Stage 4**: Add `SimPeer` behaviors (slow, corrupt, disconnect). Write the smart-ban sim
test: one corrupt peer in a swarm of honest peers; assert the corrupt peer is banned and
the piece completes.

**Stage 5**: Wire `BUGGIFY` — on each tick, the simulator randomly (seeded) applies a
fault from `FaultConfig` to a randomly chosen in-flight operation. Tests that pass under
BUGGIFY are genuinely robust.

---

## What Does Not Change

- Peer state machines (`active_recv_header`, `active_recv_body`, etc.)
- Protocol handling (`processMessage`, `completePieceDownload`, smart ban)
- Piece tracking, piece verification, PieceStore
- RPC, tracker, DHT — these are control-plane and remain separate from the IO interface
- `VirtualPeer` and the existing `sim_swarm_test.zig` — kept for integration tests

The IO abstraction touches only the boundary between the EventLoop and the kernel.
Everything above that boundary is unchanged.

//! SimIO — in-process IO backend for simulation tests.
//!
//! `SimIO` implements the same interface as `RealIO` but never touches the
//! kernel. Submissions land in an internal min-heap keyed by simulated
//! delivery time. A test driver (the `Simulator`) advances a logical clock
//! and calls `tick`, which delivers all due completions by invoking their
//! callbacks.
//!
//! Properties:
//!   * **Deterministic.** All fault decisions and ordering tiebreakers
//!     derive from a seeded `std.Random.DefaultPrng`.
//!   * **Zero-alloc after init.** The pending heap is sized at `init` with
//!     a fixed capacity. Submissions past that capacity return
//!     `error.PendingQueueFull`; they do not allocate.
//!   * **No threads, no fds, no syscalls.** Submissions run on the test
//!     thread; delivery happens during `tick` on the same thread.
//!
//! See `docs/io-abstraction-plan.md` for the broader design.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const assert = std.debug.assert;

const ifc = @import("io_interface.zig");
const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const Callback = ifc.Callback;
const CallbackAction = ifc.CallbackAction;

// ── Public re-exports for backend duck-typing ─────────────

pub const Op = ifc.Operation;

// ── Backend state ─────────────────────────────────────────
//
// SimIO stores per-completion bookkeeping in `Completion._backend_state`.
// It records the heap index so cancel can find the entry without a linear
// scan, plus an `in_flight` flag.

pub const SimState = packed struct {
    /// Index into `pending` while in the heap; std.math.maxInt(u32) means
    /// "not in the heap" (delivered or never submitted).
    heap_index: u32 = std.math.maxInt(u32),
    in_flight: bool = false,
    _padding: u31 = 0,
};

comptime {
    // The opaque area in the public Completion must accommodate SimState.
    assert(@sizeOf(SimState) <= ifc.backend_state_size);
    assert(@alignOf(SimState) <= ifc.backend_state_align);
}

inline fn simState(c: *Completion) *SimState {
    return c.backendStateAs(SimState);
}

// ── Fault injection configuration ─────────────────────────

pub const FaultConfig = struct {
    /// Probability that a given recv completion is delivered with
    /// `error.ConnectionResetByPeer` instead of bytes.
    recv_error_probability: f32 = 0.0,
    /// Same idea for send.
    send_error_probability: f32 = 0.0,
    /// Probability for read (disk EIO).
    read_error_probability: f32 = 0.0,
    /// Probability for write (disk EIO / ENOSPC).
    write_error_probability: f32 = 0.0,
    /// Probability that a connect completes with `error.ConnectionRefused`.
    connect_error_probability: f32 = 0.0,
    /// Added to every recv delivery time (simulates network latency).
    recv_latency_ns: u64 = 0,
    /// Added to every send delivery time.
    send_latency_ns: u64 = 0,
    /// Added to every disk write delivery time (simulates slow disk).
    write_latency_ns: u64 = 0,
    /// Random jitter added to each completion's deadline. 0 disables.
    completion_jitter_ns: u64 = 0,
};

pub const Config = struct {
    /// Capacity of the pending-completion heap. Submissions past this
    /// capacity fail with `error.PendingQueueFull`.
    pending_capacity: u32 = 4096,
    /// Seed for the deterministic PRNG. Tests should derive this from a
    /// per-test seed and print it on failure.
    seed: u64 = 0,
    faults: FaultConfig = .{},
};

// ── Pending entry ─────────────────────────────────────────
//
// A pending entry is a (deadline, sequence, completion, result) tuple in
// the min-heap. `seq` breaks ties between completions sharing a deadline
// — assigning sequence numbers from a seeded PRNG produces a deterministic
// but order-stressing schedule.
//
// `result` is the result to deliver. Operations like recv/send that
// normally depend on the kernel are pre-resolved at submit time using the
// FaultConfig and a simple "no kernel — assume nothing happens unless
// scripted" model.

const Pending = struct {
    deadline_ns: u64,
    seq: u64,
    completion: *Completion,
    result: Result,
};

fn pendingLess(_: void, a: Pending, b: Pending) std.math.Order {
    if (a.deadline_ns != b.deadline_ns) return std.math.order(a.deadline_ns, b.deadline_ns);
    return std.math.order(a.seq, b.seq);
}

// ── SimIO ─────────────────────────────────────────────────

pub const SimIO = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    config: Config,

    /// Wall-time-in-nanoseconds of the simulated clock. The driver
    /// (`Simulator.step`) advances this; `tick` delivers everything due.
    now_ns: u64 = 0,

    /// Strictly-increasing submission counter. Combined with the PRNG it
    /// becomes the heap tiebreaker.
    submit_seq: u64 = 0,

    /// Min-heap of pending completions keyed by deadline_ns then seq.
    /// Backed by a single allocation made at init.
    pending: []Pending,
    pending_len: u32 = 0,

    /// Re-entrancy guard for `tick`. Callbacks may submit new operations,
    /// but they may not call `tick` recursively.
    in_tick: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) !SimIO {
        const slots = try allocator.alloc(Pending, config.pending_capacity);
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(config.seed),
            .config = config,
            .pending = slots,
        };
    }

    pub fn deinit(self: *SimIO) void {
        self.allocator.free(self.pending);
        self.* = undefined;
    }

    /// Current simulated time.
    pub fn now(self: *const SimIO) u64 {
        return self.now_ns;
    }

    /// Advance the simulated clock and deliver all due completions.
    /// Equivalent to `now_ns += delta_ns; try self.tick()`.
    pub fn advance(self: *SimIO, delta_ns: u64) !void {
        self.now_ns += delta_ns;
        try self.tick();
    }

    /// Deliver every completion with `deadline_ns <= now_ns`. Callbacks
    /// may submit new operations during delivery; if a callback returns
    /// `.rearm`, the operation is re-submitted with the same parameters
    /// at `now_ns + 0` (delivered on the next tick that fires it).
    pub fn tick(self: *SimIO) !void {
        assert(!self.in_tick); // no recursive ticks
        self.in_tick = true;
        defer self.in_tick = false;

        while (self.pending_len > 0 and self.pending[0].deadline_ns <= self.now_ns) {
            const entry = self.popMin();
            const c = entry.completion;
            const callback = c.callback orelse continue; // disarmed mid-flight

            const action = callback(c.userdata, c, entry.result);
            switch (action) {
                .disarm => {
                    simState(c).in_flight = false;
                },
                .rearm => {
                    // Re-submit with the same op parameters and a fresh
                    // result tied to the current time.
                    try self.submitOp(c, c.op, .{ .delay_ns = 0 });
                },
            }
        }
    }

    // ── Heap operations ───────────────────────────────────

    fn popMin(self: *SimIO) Pending {
        assert(self.pending_len > 0);
        const root = self.pending[0];
        simState(root.completion).heap_index = std.math.maxInt(u32);

        self.pending_len -= 1;
        if (self.pending_len > 0) {
            const moved = self.pending[self.pending_len];
            self.pending[0] = moved;
            simState(moved.completion).heap_index = 0;
            self.siftDown(0);
        }
        return root;
    }

    fn pushPending(self: *SimIO, entry: Pending) !void {
        if (self.pending_len == self.pending.len) return error.PendingQueueFull;
        const i = self.pending_len;
        self.pending[i] = entry;
        simState(entry.completion).heap_index = i;
        self.pending_len += 1;
        self.siftUp(i);
    }

    fn siftUp(self: *SimIO, idx: u32) void {
        var i = idx;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (pendingLess({}, self.pending[i], self.pending[parent]) == .lt) {
                self.swap(i, parent);
                i = parent;
            } else break;
        }
    }

    fn siftDown(self: *SimIO, idx: u32) void {
        var i = idx;
        while (true) {
            const l = 2 * i + 1;
            const r = 2 * i + 2;
            var best = i;
            if (l < self.pending_len and pendingLess({}, self.pending[l], self.pending[best]) == .lt) best = l;
            if (r < self.pending_len and pendingLess({}, self.pending[r], self.pending[best]) == .lt) best = r;
            if (best == i) break;
            self.swap(i, best);
            i = best;
        }
    }

    fn swap(self: *SimIO, a: u32, b: u32) void {
        const tmp = self.pending[a];
        self.pending[a] = self.pending[b];
        self.pending[b] = tmp;
        simState(self.pending[a].completion).heap_index = a;
        simState(self.pending[b].completion).heap_index = b;
    }

    // ── Internal submission ───────────────────────────────

    const SubmitOptions = struct {
        delay_ns: u64,
    };

    fn submitOp(
        self: *SimIO,
        c: *Completion,
        op: Operation,
        opts: SubmitOptions,
    ) !void {
        const result = self.resolveResult(op);
        const latency = self.opLatency(op);
        const jitter_ns = self.jitter();
        const deadline = self.now_ns +| opts.delay_ns +| latency +| jitter_ns;

        c.op = op;
        const st = simState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .heap_index = std.math.maxInt(u32), .in_flight = true };

        self.submit_seq +%= 1;
        const seq = self.submit_seq ^ self.rng.random().int(u64);

        try self.pushPending(.{
            .deadline_ns = deadline,
            .seq = seq,
            .completion = c,
            .result = result,
        });
    }

    /// Pre-resolve the result for an operation at submit time. Without
    /// SimPeer / fd machinery, sockets and disk ops succeed with zero
    /// bytes by default, modulo fault injection. Tests that need richer
    /// behaviour will plumb data through SimPeer in a follow-up.
    fn resolveResult(self: *SimIO, op: Operation) Result {
        const r = self.rng.random();
        return switch (op) {
            .none => .{ .timeout = {} }, // never delivered
            .recv => blk: {
                if (r.float(f32) < self.config.faults.recv_error_probability) {
                    break :blk .{ .recv = error.ConnectionResetByPeer };
                }
                break :blk .{ .recv = @as(usize, 0) };
            },
            .send => blk: {
                if (r.float(f32) < self.config.faults.send_error_probability) {
                    break :blk .{ .send = error.BrokenPipe };
                }
                break :blk .{ .send = @as(usize, 0) };
            },
            .recvmsg => blk: {
                if (r.float(f32) < self.config.faults.recv_error_probability) {
                    break :blk .{ .recvmsg = error.ConnectionResetByPeer };
                }
                break :blk .{ .recvmsg = @as(usize, 0) };
            },
            .sendmsg => blk: {
                if (r.float(f32) < self.config.faults.send_error_probability) {
                    break :blk .{ .sendmsg = error.BrokenPipe };
                }
                break :blk .{ .sendmsg = @as(usize, 0) };
            },
            .read => blk: {
                if (r.float(f32) < self.config.faults.read_error_probability) {
                    break :blk .{ .read = error.InputOutput };
                }
                break :blk .{ .read = @as(usize, 0) };
            },
            .write => blk: {
                if (r.float(f32) < self.config.faults.write_error_probability) {
                    break :blk .{ .write = error.NoSpaceLeft };
                }
                break :blk .{ .write = @as(usize, 0) };
            },
            .fsync => .{ .fsync = {} },
            .socket => .{ .socket = self.nextFakeFd() },
            .connect => blk: {
                if (r.float(f32) < self.config.faults.connect_error_probability) {
                    break :blk .{ .connect = error.ConnectionRefused };
                }
                break :blk .{ .connect = {} };
            },
            // Accept never delivers without a SimPeer pushing a connection;
            // until SimPeer lands, accept stays parked indefinitely.
            .accept => .{ .accept = error.WouldBlock },
            .timeout => .{ .timeout = {} },
            .poll => .{ .poll = @as(u32, 0) },
            // Cancel is handled separately via cancelOp; this branch
            // shouldn't be hit during scheduling.
            .cancel => .{ .cancel = error.OperationNotFound },
        };
    }

    fn opLatency(self: *const SimIO, op: Operation) u64 {
        return switch (op) {
            .recv, .recvmsg => self.config.faults.recv_latency_ns,
            .send, .sendmsg => self.config.faults.send_latency_ns,
            .write => self.config.faults.write_latency_ns,
            .timeout => |t| t.ns,
            else => 0,
        };
    }

    fn jitter(self: *SimIO) u64 {
        const max = self.config.faults.completion_jitter_ns;
        if (max == 0) return 0;
        return self.rng.random().uintLessThan(u64, max);
    }

    /// Synthesise a fake file descriptor. Returned values fit in the
    /// `posix.fd_t` range but never collide with real ones because the
    /// daemon never opens the simulator process's stdin/stdout.
    fn nextFakeFd(self: *SimIO) posix.fd_t {
        // Stable but distinct per call; not actually opened.
        const id: i32 = @intCast(@as(u32, @truncate(self.submit_seq +% 1024)));
        return @as(posix.fd_t, id);
    }

    // ── Public submission methods (interface) ─────────────

    pub fn recv(self: *SimIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .recv = op }, .{ .delay_ns = 0 });
    }

    pub fn send(self: *SimIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .send = op }, .{ .delay_ns = 0 });
    }

    pub fn recvmsg(self: *SimIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .recvmsg = op }, .{ .delay_ns = 0 });
    }

    pub fn sendmsg(self: *SimIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .sendmsg = op }, .{ .delay_ns = 0 });
    }

    pub fn read(self: *SimIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .read = op }, .{ .delay_ns = 0 });
    }

    pub fn write(self: *SimIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .write = op }, .{ .delay_ns = 0 });
    }

    pub fn fsync(self: *SimIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .fsync = op }, .{ .delay_ns = 0 });
    }

    pub fn socket(self: *SimIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .socket = op }, .{ .delay_ns = 0 });
    }

    pub fn connect(self: *SimIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .connect = op }, .{ .delay_ns = 0 });
    }

    pub fn accept(self: *SimIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        // Accept stays parked until SimPeer pushes a connection. Submit
        // with a sentinel deadline so it never fires on its own.
        const result: Result = .{ .accept = error.WouldBlock };
        c.op = .{ .accept = op };
        const st = simState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .heap_index = std.math.maxInt(u32), .in_flight = true };

        self.submit_seq +%= 1;
        const seq = self.submit_seq ^ self.rng.random().int(u64);
        try self.pushPending(.{
            .deadline_ns = std.math.maxInt(u64), // parked
            .seq = seq,
            .completion = c,
            .result = result,
        });
    }

    pub fn timeout(self: *SimIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .timeout = op }, .{ .delay_ns = 0 });
    }

    pub fn poll(self: *SimIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
        try self.submitOp(c, .{ .poll = op }, .{ .delay_ns = 0 });
    }

    /// Cancel an in-flight operation by completion pointer. The cancelled
    /// op's callback fires with `error.OperationCanceled` on the same
    /// tick. The cancel completion itself fires with `.cancel = {}` on
    /// success or `.cancel = error.OperationNotFound` if the target was
    /// not in the queue.
    pub fn cancel(self: *SimIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        c.userdata = ud;
        c.callback = cb;
        c.next = null;

        const target = op.target;
        const ts = simState(target);
        if (!ts.in_flight or ts.heap_index == std.math.maxInt(u32)) {
            // Target is not in the heap — deliver "not found" immediately.
            c.op = .{ .cancel = op };
            try self.submitOp(c, .{ .cancel = op }, .{ .delay_ns = 0 });
            // Override the result we just scheduled.
            self.overrideTopResult(c, .{ .cancel = error.OperationNotFound });
            return;
        }

        // Pull the target out of the heap and schedule its cancel result.
        const idx = ts.heap_index;
        const target_entry = self.removeAt(idx);
        target_entry.completion.op = target_entry.completion.op; // unchanged
        // Reschedule the target with a CancelOnSubmit-style result.
        const cancel_result = cancelResultFor(target_entry.completion.op);
        try self.scheduleResolved(target_entry.completion, cancel_result, 0);

        // Schedule the cancel completion's own delivery.
        try self.submitOp(c, .{ .cancel = op }, .{ .delay_ns = 0 });
        self.overrideTopResult(c, .{ .cancel = {} });
    }

    /// Replace the most-recently-pushed entry's result. Used to override
    /// the synthesised default for a few specific paths (cancel, accept).
    fn overrideTopResult(self: *SimIO, c: *Completion, result: Result) void {
        const idx = simState(c).heap_index;
        if (idx == std.math.maxInt(u32)) return;
        self.pending[idx].result = result;
    }

    fn scheduleResolved(self: *SimIO, c: *Completion, result: Result, delay_ns: u64) !void {
        const st = simState(c);
        st.* = .{ .heap_index = std.math.maxInt(u32), .in_flight = true };

        self.submit_seq +%= 1;
        const seq = self.submit_seq ^ self.rng.random().int(u64);
        try self.pushPending(.{
            .deadline_ns = self.now_ns +| delay_ns,
            .seq = seq,
            .completion = c,
            .result = result,
        });
    }

    fn removeAt(self: *SimIO, idx: u32) Pending {
        assert(idx < self.pending_len);
        const removed = self.pending[idx];
        simState(removed.completion).heap_index = std.math.maxInt(u32);

        self.pending_len -= 1;
        if (idx != self.pending_len) {
            const moved = self.pending[self.pending_len];
            self.pending[idx] = moved;
            simState(moved.completion).heap_index = idx;
            // Restore heap order from idx (could need to sift either way).
            self.siftDown(idx);
            self.siftUp(idx);
        }
        return removed;
    }
};

fn cancelResultFor(op: Operation) Result {
    return switch (op) {
        .none => .{ .timeout = error.OperationCanceled },
        .recv => .{ .recv = error.OperationCanceled },
        .send => .{ .send = error.OperationCanceled },
        .recvmsg => .{ .recvmsg = error.OperationCanceled },
        .sendmsg => .{ .sendmsg = error.OperationCanceled },
        .read => .{ .read = error.OperationCanceled },
        .write => .{ .write = error.OperationCanceled },
        .fsync => .{ .fsync = error.OperationCanceled },
        .socket => .{ .socket = error.OperationCanceled },
        .connect => .{ .connect = error.OperationCanceled },
        .accept => .{ .accept = error.OperationCanceled },
        .timeout => .{ .timeout = error.OperationCanceled },
        .poll => .{ .poll = error.OperationCanceled },
        .cancel => .{ .cancel = error.OperationCanceled },
    };
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

fn testCallback(
    userdata: ?*anyopaque,
    _: *Completion,
    result: Result,
) CallbackAction {
    const ctx: *TestCtx = @ptrCast(@alignCast(userdata.?));
    ctx.last_result = result;
    ctx.calls += 1;
    return .disarm;
}

const TestCtx = struct {
    calls: u32 = 0,
    last_result: ?Result = null,
};

test "SimIO timeout fires after specified delay" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, testCallback);

    // No fire yet (now_ns = 0, deadline = 1_000_000).
    try io.tick();
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Halfway — still no fire.
    try io.advance(500_000);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Past the deadline — fires once.
    try io.advance(600_000);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO multiple timeouts deliver in deadline order" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const N: u32 = 8;
    var completions: [N]Completion = .{Completion{}} ** N;

    const OrderLog = struct {
        slots: [N]u32 = .{0} ** N,
        next_index: u32 = 0,
    };
    var log = OrderLog{};

    // Submit timeouts in submission order 0..N-1, but with deadlines that
    // run from N down to 1 — so the *delivery* order should be the reverse
    // of the *submission* order.
    const cb = struct {
        fn cb(ud: ?*anyopaque, c: *Completion, _: Result) CallbackAction {
            const owner: *OrderLog = @ptrCast(@alignCast(ud.?));
            const base_addr = @intFromPtr(c) - @intFromPtr(&completions_for_test[0]);
            const idx: u32 = @intCast(base_addr / @sizeOf(Completion));
            owner.slots[owner.next_index] = idx;
            owner.next_index += 1;
            return .disarm;
        }
    }.cb;
    completions_for_test = &completions;

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        try io.timeout(.{ .ns = (N - i) * 1_000_000 }, &completions[i], &log, cb);
    }

    try io.advance(N * 1_000_000 + 1);
    try testing.expectEqual(N, log.next_index);
    // The deadline schedule was N, N-1, ..., 1 ms — so callback i=N-1
    // fires first (deadline 1 ms), down to i=0 last (deadline N ms).
    var k: u32 = 0;
    while (k < N) : (k += 1) {
        try testing.expectEqual(N - 1 - k, log.slots[k]);
    }
}

// File-scope mutable so the inline test callback can derive a slot index
// from the completion pointer arithmetic.
var completions_for_test: []Completion = &.{};

test "SimIO recv with fault probability 1.0 always errors" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 12345,
        .faults = .{ .recv_error_probability = 1.0 },
    });
    defer io.deinit();

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.recv(.{ .fd = 7, .buf = &buf }, &c, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "SimIO connect with fault probability 0.0 always succeeds" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 1,
        .faults = .{ .connect_error_probability = 0.0 },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6881);
    try io.connect(.{ .fd = 3, .addr = addr }, &c, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .connect => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO PendingQueueFull when capacity exhausted" {
    var io = try SimIO.init(testing.allocator, .{ .pending_capacity = 4 });
    defer io.deinit();

    var completions: [5]Completion = .{Completion{}} ** 5;
    var ctx = TestCtx{};

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try io.timeout(.{ .ns = 1_000_000_000 }, &completions[i], &ctx, testCallback);
    }
    try testing.expectError(
        error.PendingQueueFull,
        io.timeout(.{ .ns = 1_000_000_000 }, &completions[4], &ctx, testCallback),
    );
}

test "SimIO cancel removes target and delivers OperationCanceled" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var target = Completion{};
    var canceller = Completion{};

    const TestState = struct {
        target_calls: u32 = 0,
        target_result: ?Result = null,
        cancel_calls: u32 = 0,
        cancel_result: ?Result = null,
    };
    var state = TestState{};

    const target_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *TestState = @ptrCast(@alignCast(ud.?));
            s.target_calls += 1;
            s.target_result = result;
            return .disarm;
        }
    }.cb;
    const cancel_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *TestState = @ptrCast(@alignCast(ud.?));
            s.cancel_calls += 1;
            s.cancel_result = result;
            return .disarm;
        }
    }.cb;

    var buf: [16]u8 = undefined;
    try io.recv(.{ .fd = 7, .buf = &buf }, &target, &state, target_cb);
    try io.cancel(.{ .target = &target }, &canceller, &state, cancel_cb);

    try io.tick();

    try testing.expectEqual(@as(u32, 1), state.target_calls);
    try testing.expectEqual(@as(u32, 1), state.cancel_calls);
    switch (state.target_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (state.cancel_result.?) {
        .cancel => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO cancel returns OperationNotFound for unsubmitted target" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var unsubmitted = Completion{};
    var canceller = Completion{};
    var ctx = TestCtx{};

    try io.cancel(.{ .target = &unsubmitted }, &canceller, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .cancel => |r| try testing.expectError(error.OperationNotFound, r),
        else => try testing.expect(false),
    }
}

test "SimIO rearm resubmits the same operation" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const Counter = struct { fires: u32 = 0, target: u32 = 3 };
    var counter = Counter{};

    var c = Completion{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            const s: *Counter = @ptrCast(@alignCast(ud.?));
            s.fires += 1;
            return if (s.fires < s.target) .rearm else .disarm;
        }
    }.cb;

    try io.timeout(.{ .ns = 0 }, &c, &counter, cb);
    try io.advance(1);
    try io.advance(1);
    try io.advance(1);
    try testing.expectEqual(@as(u32, 3), counter.fires);
}

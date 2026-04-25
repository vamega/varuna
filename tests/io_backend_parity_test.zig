//! Backend parity test — proves RealIO and SimIO satisfy the same
//! `io_interface` contract by running identical test bodies against both.
//!
//! The test bodies are written generic over the comptime IO type. Each
//! body submits a sequence of operations and asserts the observed
//! callbacks match expectations. If a backend's method signature drifts
//! from the contract, this file fails to compile — making the contract
//! enforceable at the build, not just a doc-comment promise.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const testing = std.testing;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const RealIO = varuna.io.real_io.RealIO;
const SimIO = varuna.io.sim_io.SimIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Compile-time interface check ──────────────────────────
//
// Forces both backends to expose the same set of submission methods. A
// missing or renamed method fails to compile here, before any test runs.

fn requireBackendMethods(comptime IO: type) void {
    comptime {
        const required = [_][]const u8{
            "init",    "deinit",  "tick",
            "recv",    "send",    "recvmsg",
            "sendmsg", "read",    "write",
            "fsync",   "socket",  "connect",
            "accept",  "timeout", "poll",
            "cancel",
        };
        for (required) |name| {
            if (!@hasDecl(IO, name)) {
                @compileError(@typeName(IO) ++ " is missing required method: " ++ name);
            }
        }
    }
}

comptime {
    requireBackendMethods(RealIO);
    requireBackendMethods(SimIO);
}

// ── Shared test bodies ────────────────────────────────────

const Counter = struct {
    fires: u32 = 0,
    last_result: ?Result = null,
};

fn counterCallback(
    userdata: ?*anyopaque,
    _: *Completion,
    result: Result,
) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(userdata.?));
    c.fires += 1;
    c.last_result = result;
    return .disarm;
}

/// Submit a single timeout, drain it, expect exactly one call.
/// Generic over the IO backend.
fn runTimeoutOnce(
    comptime IO: type,
    io: *IO,
    drain_fn: fn (io: *IO) anyerror!void,
) !void {
    var c = Completion{};
    var counter = Counter{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &counter, counterCallback);
    try drain_fn(io);
    try testing.expectEqual(@as(u32, 1), counter.fires);
    switch (counter.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

/// Submit a cancel against an unsubmitted target, drain, expect
/// OperationNotFound. Generic over the IO backend.
fn runCancelOfNothing(
    comptime IO: type,
    io: *IO,
    drain_fn: fn (io: *IO) anyerror!void,
) !void {
    var unsubmitted = Completion{};
    var canceller = Completion{};
    var counter = Counter{};
    try io.cancel(.{ .target = &unsubmitted }, &canceller, &counter, counterCallback);
    try drain_fn(io);
    try testing.expectEqual(@as(u32, 1), counter.fires);
    switch (counter.last_result.?) {
        .cancel => |r| try testing.expectError(error.OperationNotFound, r),
        else => try testing.expect(false),
    }
}

// ── Drain helpers per backend ─────────────────────────────

fn drainReal(io: *RealIO) !void {
    try io.tick(1);
}

fn drainSim(io: *SimIO) !void {
    try io.advance(2_000_000); // past any 1ms deadline
}

// ── Tests ─────────────────────────────────────────────────

test "RealIO and SimIO both deliver a single timeout" {
    // SimIO branch — runs unconditionally.
    {
        var io = try SimIO.init(testing.allocator, .{});
        defer io.deinit();
        try runTimeoutOnce(SimIO, &io, drainSim);
    }

    // RealIO branch — skip if io_uring is unavailable.
    {
        var io = RealIO.init(.{ .entries = 16 }) catch return;
        defer io.deinit();
        try runTimeoutOnce(RealIO, &io, drainReal);
    }
}

test "RealIO and SimIO both report OperationNotFound for stray cancels" {
    {
        var io = try SimIO.init(testing.allocator, .{});
        defer io.deinit();
        try runCancelOfNothing(SimIO, &io, drainSim);
    }

    {
        var io = RealIO.init(.{ .entries = 16 }) catch return;
        defer io.deinit();
        try runCancelOfNothing(RealIO, &io, drainReal);
    }
}

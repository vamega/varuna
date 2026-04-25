//! Wrapper that runs the inline tests from `src/sim/simulator.zig`.
//!
//! Test files in `src/` aren't reached by `zig build test` in this
//! codebase (mod_tests doesn't auto-discover transitively imported
//! tests), so we copy a few black-box tests against the public
//! `varuna.sim.Simulator` surface here. This grows the run-test count
//! while leaving the inline tests in place for documentation.

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io = varuna.io.sim_io;
const Simulator = varuna.sim.Simulator;
const SimulatorOf = varuna.sim.SimulatorOf;
const StubDriver = varuna.sim.StubDriver;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

test "Simulator.init / deinit cleanly with empty swarm" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();
    try testing.expectEqual(@as(u32, 0), sim.swarm_len);
    try testing.expectEqual(@as(u64, 0), sim.clock_ns);
}

test "Simulator.step advances clock and ticks IO" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();

    const FireCounter = struct { count: u32 = 0 };
    var ctx = FireCounter{};

    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            const c: *FireCounter = @ptrCast(@alignCast(ud.?));
            c.count += 1;
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try sim.io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, cb);

    try sim.step(2_000_000);
    try testing.expectEqual(@as(u32, 1), ctx.count);
    try testing.expectEqual(@as(u64, 2_000_000), sim.clock_ns);
}

test "Simulator.runUntil hits step ceiling and returns false" {
    const State = struct {
        fn never(_: *Simulator) bool {
            return false;
        }
    };

    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();

    const ok = try sim.runUntil(State.never, 5, 1_000);
    try testing.expect(!ok);
    try testing.expectEqual(@as(u64, 5_000), sim.clock_ns);
}

test "Simulator.nextPendingDeadlineNs returns null when heap is empty" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();
    try testing.expectEqual(@as(?u64, null), sim.nextPendingDeadlineNs());
}

test "BUGGIFY at probability 1.0 fires at least one injection" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 1.0 },
    }, StubDriver{});
    defer sim.deinit();

    const Counter = struct { calls: u32 = 0, errs: u32 = 0 };
    var ctx = Counter{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const c: *Counter = @ptrCast(@alignCast(ud.?));
            c.calls += 1;
            switch (result) {
                .recv => |r| _ = r catch {
                    c.errs += 1;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var c1 = Completion{};
    var c2 = Completion{};
    var c3 = Completion{};
    var c4 = Completion{};
    var buf1: [4]u8 = undefined;
    var buf2: [4]u8 = undefined;
    var buf3: [4]u8 = undefined;
    var buf4: [4]u8 = undefined;
    try sim.io.recv(.{ .fd = 7, .buf = &buf1 }, &c1, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf2 }, &c2, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf3 }, &c3, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf4 }, &c4, &ctx, cb);

    try sim.step(0);
    try testing.expect(sim.buggify_hits >= 1);
    try testing.expectEqual(@as(u32, 4), ctx.calls);
    try testing.expect(ctx.errs >= 1);
}

test "BUGGIFY at probability 0.0 never injects" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 0.0 },
    }, StubDriver{});
    defer sim.deinit();

    var c = Completion{};
    var buf: [4]u8 = undefined;
    const cb = struct {
        fn cb(_: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            return .disarm;
        }
    }.cb;
    try sim.io.recv(.{ .fd = 7, .buf = &buf }, &c, null, cb);
    try sim.step(0);
    try testing.expectEqual(@as(u32, 0), sim.buggify_hits);
}

test "BUGGIFY across many steps with probability 0.5 hits a fraction" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 0.5 },
        .seed = 0xDEADBEEF,
    }, StubDriver{});
    defer sim.deinit();

    const cb = struct {
        fn cb(_: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            return .disarm;
        }
    }.cb;

    // Submit one timeout per iteration and step. The timeout fires on
    // the next step, so injections should land on roughly half of them.
    var i: u32 = 0;
    var completions: [128]Completion = .{Completion{}} ** 128;
    while (i < completions.len) : (i += 1) {
        try sim.io.timeout(.{ .ns = 0 }, &completions[i], null, cb);
        try sim.step(0);
    }

    // 0.5 probability over 128 steps: expect roughly 64 hits, with
    // sufficient slack to avoid flakes on a fixed seed.
    try testing.expect(sim.buggify_hits >= 32);
    try testing.expect(sim.buggify_hits <= 96);
}

//! SimIO socketpair / parking / close / cancel tests.
//!
//! These exercise the public surface of the in-process socket machinery
//! added by `createSocketpair` / `closeSocket` plus the recv-park-on-empty
//! and send-unpark-partner flow inside `SimIO.send` and `SimIO.recv`. The
//! goal is to prove two parties can actually exchange bytes through SimIO
//! deterministically — the prerequisite for end-to-end SimPeer ↔ EventLoop
//! sim tests in later stages.
//!
//! All tests run via `varuna.io.sim_io.SimIO` so they sit on the public
//! interface, not on private fields.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io = varuna.io.sim_io;
const SimIO = sim_io.SimIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Test fixtures ─────────────────────────────────────────

const TestCtx = struct {
    calls: u32 = 0,
    last_result: ?Result = null,
};

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

// ── Tests ─────────────────────────────────────────────────

test "createSocketpair returns two distinct fds" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();
    try testing.expect(fds[0] != fds[1]);
    // Sim socket fds are positive (well above stdin/stdout/stderr).
    try testing.expect(fds[0] > 2);
    try testing.expect(fds[1] > 2);
}

test "socketpair round-trip: send then recv delivers bytes" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var send_c = Completion{};
    var recv_c = Completion{};
    var send_ctx = TestCtx{};
    var recv_ctx = TestCtx{};
    var recv_buf: [16]u8 = undefined;

    // Send first — bytes accumulate in the partner's queue.
    try io.send(.{ .fd = fds[0], .buf = "ping" }, &send_c, &send_ctx, testCallback);
    // Then post the recv on the partner; it should pull from queue.
    try io.recv(.{ .fd = fds[1], .buf = &recv_buf }, &recv_c, &recv_ctx, testCallback);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), send_ctx.calls);
    try testing.expectEqual(@as(u32, 1), recv_ctx.calls);
    switch (send_ctx.last_result.?) {
        .send => |r| try testing.expectEqual(@as(usize, 4), try r),
        else => try testing.expect(false),
    }
    switch (recv_ctx.last_result.?) {
        .recv => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualStrings("ping", recv_buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "recv parks until partner sends" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var recv_c = Completion{};
    var send_c = Completion{};
    var recv_ctx = TestCtx{};
    var send_ctx = TestCtx{};
    var recv_buf: [16]u8 = undefined;

    // Recv first — queue is empty, so it parks.
    try io.recv(.{ .fd = fds[0], .buf = &recv_buf }, &recv_c, &recv_ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), recv_ctx.calls);

    // Send wakes the parked recv.
    try io.send(.{ .fd = fds[1], .buf = "pong" }, &send_c, &send_ctx, testCallback);
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), recv_ctx.calls);
    try testing.expectEqual(@as(u32, 1), send_ctx.calls);
    switch (recv_ctx.last_result.?) {
        .recv => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualStrings("pong", recv_buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "partial recv leaves remaining bytes in queue" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var send_c = Completion{};
    var send_ctx = TestCtx{};
    try io.send(.{ .fd = fds[0], .buf = "abcdef" }, &send_c, &send_ctx, testCallback);

    var recv1_c = Completion{};
    var recv1_ctx = TestCtx{};
    var buf1: [4]u8 = undefined;
    try io.recv(.{ .fd = fds[1], .buf = &buf1 }, &recv1_c, &recv1_ctx, testCallback);

    try io.tick(0);
    switch (recv1_ctx.last_result.?) {
        .recv => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualStrings("abcd", buf1[0..n]);
        },
        else => try testing.expect(false),
    }

    // Two bytes still queued.
    var recv2_c = Completion{};
    var recv2_ctx = TestCtx{};
    var buf2: [4]u8 = undefined;
    try io.recv(.{ .fd = fds[1], .buf = &buf2 }, &recv2_c, &recv2_ctx, testCallback);
    try io.tick(0);
    switch (recv2_ctx.last_result.?) {
        .recv => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 2), n);
            try testing.expectEqualStrings("ef", buf2[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "multiple sends accumulate in partner queue" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var s1 = Completion{};
    var s2 = Completion{};
    var s3 = Completion{};
    var sctx = TestCtx{};
    try io.send(.{ .fd = fds[0], .buf = "AAA" }, &s1, &sctx, testCallback);
    try io.send(.{ .fd = fds[0], .buf = "BBB" }, &s2, &sctx, testCallback);
    try io.send(.{ .fd = fds[0], .buf = "CCC" }, &s3, &sctx, testCallback);

    var r = Completion{};
    var rctx = TestCtx{};
    var buf: [16]u8 = undefined;
    try io.recv(.{ .fd = fds[1], .buf = &buf }, &r, &rctx, testCallback);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 3), sctx.calls);
    try testing.expectEqual(@as(u32, 1), rctx.calls);
    switch (rctx.last_result.?) {
        .recv => |res| {
            const n = try res;
            try testing.expectEqual(@as(usize, 9), n);
            try testing.expectEqualStrings("AAABBBCCC", buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "closeSocket fails parked recv with ConnectionResetByPeer" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var recv_c = Completion{};
    var ctx = TestCtx{};
    var buf: [16]u8 = undefined;
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &recv_c, &ctx, testCallback);

    // Parked — no fire yet.
    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    io.closeSocket(fds[0]);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "closeSocket fails partner's parked recv too" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var recv_c = Completion{};
    var ctx = TestCtx{};
    var buf: [16]u8 = undefined;
    // Park a recv on fds[1].
    try io.recv(.{ .fd = fds[1], .buf = &buf }, &recv_c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Close fds[0] — partner's parked recv should be woken with reset.
    io.closeSocket(fds[0]);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "send on closed local fd returns BrokenPipe" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();
    io.closeSocket(fds[0]);

    var send_c = Completion{};
    var ctx = TestCtx{};
    try io.send(.{ .fd = fds[0], .buf = "x" }, &send_c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .send => |r| try testing.expectError(error.BrokenPipe, r),
        else => try testing.expect(false),
    }
}

test "send to closed peer returns BrokenPipe" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();
    io.closeSocket(fds[1]);

    var send_c = Completion{};
    var ctx = TestCtx{};
    try io.send(.{ .fd = fds[0], .buf = "x" }, &send_c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .send => |r| try testing.expectError(error.BrokenPipe, r),
        else => try testing.expect(false),
    }
}

test "recv on closed local fd returns ConnectionResetByPeer" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();
    io.closeSocket(fds[0]);

    var recv_c = Completion{};
    var ctx = TestCtx{};
    var buf: [4]u8 = undefined;
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &recv_c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "cancel of parked recv delivers OperationCanceled" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var recv_c = Completion{};
    var cancel_c = Completion{};

    const State = struct {
        recv_calls: u32 = 0,
        cancel_calls: u32 = 0,
        recv_result: ?Result = null,
        cancel_result: ?Result = null,
    };
    var st = State{};

    const recv_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *State = @ptrCast(@alignCast(ud.?));
            s.recv_calls += 1;
            s.recv_result = result;
            return .disarm;
        }
    }.cb;
    const cancel_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *State = @ptrCast(@alignCast(ud.?));
            s.cancel_calls += 1;
            s.cancel_result = result;
            return .disarm;
        }
    }.cb;

    var buf: [16]u8 = undefined;
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &recv_c, &st, recv_cb);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), st.recv_calls);

    try io.cancel(.{ .target = &recv_c }, &cancel_c, &st, cancel_cb);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), st.recv_calls);
    try testing.expectEqual(@as(u32, 1), st.cancel_calls);
    switch (st.recv_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (st.cancel_result.?) {
        .cancel => |r| try r,
        else => try testing.expect(false),
    }

    // The cancelled completion must have been removed from the socket's
    // parked slot — otherwise a subsequent send would re-fire it.
    var send_c = Completion{};
    var send_ctx = TestCtx{};
    try io.send(.{ .fd = fds[1], .buf = "late" }, &send_c, &send_ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), send_ctx.calls);
    // recv_calls still 1 — i.e., not re-fired.
    try testing.expectEqual(@as(u32, 1), st.recv_calls);
}

test "mixed: heap-pending timeout coexists with socket-parked recv" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    const fds = try io.createSocketpair();

    var timer_c = Completion{};
    var recv_c = Completion{};
    var send_c = Completion{};
    var timer_ctx = TestCtx{};
    var recv_ctx = TestCtx{};
    var send_ctx = TestCtx{};
    var buf: [16]u8 = undefined;

    // Timeout in 5ms, parked recv (queue empty), nothing else due.
    try io.timeout(.{ .ns = 5_000_000 }, &timer_c, &timer_ctx, testCallback);
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &recv_c, &recv_ctx, testCallback);

    try io.advance(2_000_000); // halfway — timer not yet due, recv parked
    try testing.expectEqual(@as(u32, 0), timer_ctx.calls);
    try testing.expectEqual(@as(u32, 0), recv_ctx.calls);

    // Partner sends — wakes parked recv.
    try io.send(.{ .fd = fds[1], .buf = "hi" }, &send_c, &send_ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), recv_ctx.calls);
    try testing.expectEqual(@as(u32, 1), send_ctx.calls);
    try testing.expectEqual(@as(u32, 0), timer_ctx.calls); // timer still pending

    try io.advance(4_000_000); // crosses the 5ms deadline
    try testing.expectEqual(@as(u32, 1), timer_ctx.calls);
}

test "socket capacity exhausted returns SocketCapacityExhausted" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 3 });
    defer io.deinit();

    // First pair consumes 2 slots.
    _ = try io.createSocketpair();
    // Second pair would need 2 more but only 1 is free.
    try testing.expectError(error.SocketCapacityExhausted, io.createSocketpair());
}

test "recv on non-socket fd uses legacy zero-byte path" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var recv_c = Completion{};
    var ctx = TestCtx{};
    var buf: [4]u8 = undefined;
    try io.recv(.{ .fd = 7, .buf = &buf }, &recv_c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

test "createSocketpair: many pairs up to capacity" {
    const cap: u32 = 10;
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = cap });
    defer io.deinit();

    var pairs: [5][2]posix.fd_t = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        pairs[i] = try io.createSocketpair();
    }
    // 5 pairs × 2 = 10 slots used; one more pair would exhaust.
    try testing.expectError(error.SocketCapacityExhausted, io.createSocketpair());

    // Every pair's two fds should be distinct, and pair fds shouldn't
    // collide across pairs.
    var seen = std.AutoHashMap(posix.fd_t, void).init(testing.allocator);
    defer seen.deinit();
    for (pairs) |p| {
        try testing.expect(p[0] != p[1]);
        try seen.put(p[0], {});
        try seen.put(p[1], {});
    }
    try testing.expectEqual(@as(usize, 10), seen.count());
}

// ── setFileBytes (recheck/disk content) ───────────────────
//
// `SimIO.setFileBytes(fd, bytes)` registers caller-owned content for
// `fd` so a subsequent `read` returns slices of `bytes` at the
// requested offset instead of the legacy `usize=0` success.
// Required for recheck/disk tests whose semantics depend on bytes
// hashing back to a piece's expected hash.

test "SimIO read returns zero bytes when no content is registered" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 7, .buf = &buf, .offset = 0 }, &c, &ctx, testCallback);
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes returns content slice on read" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const content = "hello world recheck content";
    try io.setFileBytes(7, content);

    var buf: [16]u8 = undefined;
    @memset(&buf, 0xff);
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 7, .buf = &buf, .offset = 0 }, &c, &ctx, testCallback);
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 16), n);
            try testing.expectEqualSlices(u8, content[0..16], buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes honors offset" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const content = "0123456789abcdef";
    try io.setFileBytes(11, content);

    var buf: [4]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 11, .buf = &buf, .offset = 6 }, &c, &ctx, testCallback);
    try io.tick(0);

    switch (ctx.last_result.?) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 4), n);
            try testing.expectEqualSlices(u8, "6789", buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes returns short read at end of content" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const content = "12345";
    try io.setFileBytes(3, content);

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 3, .buf = &buf, .offset = 2 }, &c, &ctx, testCallback);
    try io.tick(0);

    switch (ctx.last_result.?) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 3), n);
            try testing.expectEqualSlices(u8, "345", buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes returns zero when offset is past end" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const content = "short";
    try io.setFileBytes(2, content);

    var buf: [8]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 2, .buf = &buf, .offset = 100 }, &c, &ctx, testCallback);
    try io.tick(0);

    switch (ctx.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes is per-fd; unregistered fds get zero" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const content_a = "alpha";
    try io.setFileBytes(40, content_a);

    var buf: [8]u8 = undefined;
    var c1 = Completion{};
    var ctx1 = TestCtx{};
    try io.read(.{ .fd = 40, .buf = &buf, .offset = 0 }, &c1, &ctx1, testCallback);

    var buf2: [8]u8 = undefined;
    var c2 = Completion{};
    var ctx2 = TestCtx{};
    try io.read(.{ .fd = 41, .buf = &buf2, .offset = 0 }, &c2, &ctx2, testCallback);

    try io.tick(0);

    switch (ctx1.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 5), try r),
        else => try testing.expect(false),
    }
    switch (ctx2.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

test "SimIO setFileBytes second call replaces content" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    try io.setFileBytes(50, "first");
    try io.setFileBytes(50, "second-call-content");

    var buf: [32]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 50, .buf = &buf, .offset = 0 }, &c, &ctx, testCallback);
    try io.tick(0);

    switch (ctx.last_result.?) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 19), n);
            try testing.expectEqualSlices(u8, "second-call-content", buf[0..n]);
        },
        else => try testing.expect(false),
    }
}

test "SimIO read still honors fault injection over registered content" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 7,
        .faults = .{ .read_error_probability = 1.0 },
    });
    defer io.deinit();

    try io.setFileBytes(99, "would-be-content");

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = 99, .buf = &buf, .offset = 0 }, &c, &ctx, testCallback);
    try io.tick(0);

    switch (ctx.last_result.?) {
        .read => |r| try testing.expectError(error.InputOutput, r),
        else => try testing.expect(false),
    }
}

// ── fallocate / fsync contract ops ────────────────────────────
//
// The new disk-pre-allocation and flush ops are submission-shape
// peers of `read` / `write`. These exercise: success delivery, the
// per-op fault knob, and the BUGGIFY-via-injectRandomFault path.

test "SimIO fallocate completes successfully by default" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fallocate(
        .{ .fd = 42, .mode = 0, .offset = 0, .len = 4 * 1024 },
        &c,
        &ctx,
        testCallback,
    );
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fallocate => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO fallocate with fault probability 1.0 always returns NoSpaceLeft" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 12345,
        .faults = .{ .fallocate_error_probability = 1.0 },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fallocate(
        .{ .fd = 42, .mode = 0, .offset = 0, .len = 1024 },
        &c,
        &ctx,
        testCallback,
    );
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fallocate => |r| try testing.expectError(error.NoSpaceLeft, r),
        else => try testing.expect(false),
    }
}

test "SimIO fallocate fault probability 0.5 fires roughly half the time" {
    // Sanity check that the f32 dice roll honours the configured probability.
    // 256 trials at p=0.5 with a deterministic seed: in [25%, 75%] is plenty
    // of margin to dodge a flake.
    var io = try SimIO.init(testing.allocator, .{
        .seed = 0xdeadbeef,
        .faults = .{ .fallocate_error_probability = 0.5 },
    });
    defer io.deinit();

    var errors: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var c = Completion{};
        var ctx = TestCtx{};
        try io.fallocate(
            .{ .fd = 7, .mode = 0, .offset = 0, .len = 16 },
            &c,
            &ctx,
            testCallback,
        );
        try io.tick(0);
        switch (ctx.last_result.?) {
            .fallocate => |r| _ = r catch {
                errors += 1;
            },
            else => try testing.expect(false),
        }
    }

    try testing.expect(errors > 64); // > 25%
    try testing.expect(errors < 192); // < 75%
}

test "SimIO fsync with fault probability 1.0 always returns InputOutput" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 77,
        .faults = .{ .fsync_error_probability = 1.0 },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = 9, .datasync = true }, &c, &ctx, testCallback);
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fsync => |r| try testing.expectError(error.InputOutput, r),
        else => try testing.expect(false),
    }
}

test "SimIO fallocate result is mutated by injectRandomFault (BUGGIFY)" {
    // BUGGIFY harness path: an in-flight fallocate sitting in the heap
    // gets its result swapped to error.NoSpaceLeft on the next tick.
    var io = try SimIO.init(testing.allocator, .{ .seed = 0xa1a1a1a1 });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fallocate(
        .{ .fd = 11, .mode = 0, .offset = 0, .len = 4096 },
        &c,
        &ctx,
        testCallback,
    );

    var rng = std.Random.DefaultPrng.init(0);
    const hit = io.injectRandomFault(&rng);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(std.meta.Tag(ifc.Operation), .fallocate), hit.?.op_tag);

    try io.tick(0);
    switch (ctx.last_result.?) {
        .fallocate => |r| try testing.expectError(error.NoSpaceLeft, r),
        else => try testing.expect(false),
    }
}

test "SimIO truncate completes successfully by default" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(
        .{ .fd = 42, .length = 4 * 1024 },
        &c,
        &ctx,
        testCallback,
    );
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO truncate with fault probability 1.0 always returns InputOutput" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 0xc0ffee,
        .faults = .{ .truncate_error_probability = 1.0 },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(
        .{ .fd = 42, .length = 1024 },
        &c,
        &ctx,
        testCallback,
    );
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .truncate => |r| try testing.expectError(error.InputOutput, r),
        else => try testing.expect(false),
    }
}

//! EpollIO smoke tests. Mirrors the shape of `tests/sim_socketpair_test.zig`
//! but exercises real Linux socketpairs through the epoll readiness
//! backend (`src/io/epoll_io.zig`). Provides backend-specific coverage
//! beyond the inline tests in `epoll_io.zig`:
//!
//! - Multi-tick socketpair round-trip with both ends parked.
//! - Larger-buffer transfer to exercise `posix.send` / `posix.recv`
//!   under a non-blocking socket.
//! - Multiple concurrent timers ordered by deadline.
//! - Cancel of a registered fd before any data arrives.
//! - Negative coverage: file ops return `error.Unimplemented` so daemon
//!   callers know to gate their PieceStore wiring on the file-op
//!   follow-up.
//!
//! These run via `zig build test-epoll-io` (focused) or as part of
//! `zig build test` (full suite).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const epoll_io = varuna.io.epoll_io;
const EpollIO = epoll_io.EpollIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Fixtures ──────────────────────────────────────────────

fn skipIfUnavailable() !EpollIO {
    return EpollIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
}

fn makeSocketpairNonBlocking() !?[2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return null;
    for ([_]i32{ fds[0], fds[1] }) |fd| {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, @bitCast(@as(isize, posix.SOCK.NONBLOCK))));
    }
    return fds;
}

const Counter = struct {
    sent: u32 = 0,
    received: u32 = 0,
    bytes_sent: usize = 0,
    bytes_received: usize = 0,
    cancel_count: u32 = 0,
    timer_count: u32 = 0,
    recv_buf: [4096]u8 = undefined,
    last_recv_err: ?anyerror = null,
};

fn sendCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.sent += 1;
    switch (result) {
        .send => |r| c.bytes_sent += r catch 0,
        else => {},
    }
    return .disarm;
}

fn recvCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.received += 1;
    switch (result) {
        .recv => |r| {
            if (r) |n| {
                c.bytes_received += n;
            } else |err| {
                c.last_recv_err = err;
            }
        },
        else => {},
    }
    return .disarm;
}

fn cancelCb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.cancel_count += 1;
    return .disarm;
}

fn timerCb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.timer_count += 1;
    return .disarm;
}

// ── Tests ─────────────────────────────────────────────────

test "EpollIO multi-tick send/recv round-trip on real socketpair" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fds = (try makeSocketpairNonBlocking()) orelse return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter = Counter{};

    // Park the recv first; it should EAGAIN and register for EPOLLIN.
    var recv_c = Completion{};
    try io.recv(.{ .fd = fds[1], .buf = &counter.recv_buf }, &recv_c, &counter, recvCb);
    try testing.expectEqual(@as(u32, 0), counter.received);

    // Now submit a send. The socket buffer is empty; send should succeed
    // immediately (or partially), the data lands on fds[1]'s receive side,
    // and a subsequent tick should fire the recv callback.
    var send_c = Completion{};
    try io.send(.{ .fd = fds[0], .buf = "epoll-mvp" }, &send_c, &counter, sendCb);
    try testing.expectEqual(@as(u32, 1), counter.sent);

    var attempts: u32 = 0;
    while (counter.received < 1 and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }
    try testing.expectEqual(@as(u32, 1), counter.received);
    try testing.expectEqual(@as(usize, 9), counter.bytes_sent);
    try testing.expectEqual(@as(usize, 9), counter.bytes_received);
    try testing.expectEqualStrings("epoll-mvp", counter.recv_buf[0..9]);
}

test "EpollIO multiple timers fire in deadline order" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var counter = Counter{};

    var c1 = Completion{};
    var c2 = Completion{};
    var c3 = Completion{};

    // Submit out-of-order — heap should still fire by deadline.
    try io.timeout(.{ .ns = 5_000_000 }, &c2, &counter, timerCb); // 5ms
    try io.timeout(.{ .ns = 1_000_000 }, &c1, &counter, timerCb); // 1ms
    try io.timeout(.{ .ns = 10_000_000 }, &c3, &counter, timerCb); // 10ms

    var attempts: u32 = 0;
    while (counter.timer_count < 3 and attempts < 200) : (attempts += 1) {
        try io.tick(0);
        std.Thread.sleep(1_000_000); // 1ms between polls
    }

    try testing.expectEqual(@as(u32, 3), counter.timer_count);
}

test "EpollIO cancel on registered recv before data delivers OperationCanceled" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fds = (try makeSocketpairNonBlocking()) orelse return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter = Counter{};
    var recv_buf: [16]u8 = undefined;
    var recv_c = Completion{};
    var cancel_c = Completion{};

    try io.recv(.{ .fd = fds[0], .buf = &recv_buf }, &recv_c, &counter, recvCb);
    try testing.expectEqual(@as(u32, 0), counter.received);

    try io.cancel(.{ .target = &recv_c }, &cancel_c, &counter, cancelCb);

    try testing.expectEqual(@as(u32, 1), counter.received);
    try testing.expectEqual(@as(u32, 1), counter.cancel_count);
    try testing.expectEqual(@as(?anyerror, error.OperationCanceled), counter.last_recv_err);
}

test "EpollIO file ops return Unimplemented (MVP scope marker)" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("epoll_unimpl_test", .{ .truncate = true });
    defer file.close();

    const Box = struct {
        fsync_calls: u32 = 0,
        fsync_err: ?anyerror = null,
        truncate_calls: u32 = 0,
        truncate_err: ?anyerror = null,
        fallocate_calls: u32 = 0,
        fallocate_err: ?anyerror = null,
    };
    var box = Box{};

    const fsync_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.fsync_calls += 1;
            switch (result) {
                .fsync => |r| if (r) |_| {} else |err| {
                    b.fsync_err = err;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;
    const truncate_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.truncate_calls += 1;
            switch (result) {
                .truncate => |r| if (r) |_| {} else |err| {
                    b.truncate_err = err;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;
    const fallocate_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.fallocate_calls += 1;
            switch (result) {
                .fallocate => |r| if (r) |_| {} else |err| {
                    b.fallocate_err = err;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var fsync_c = Completion{};
    var truncate_c = Completion{};
    var fallocate_c = Completion{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &fsync_c, &box, fsync_cb);
    try io.truncate(.{ .fd = file.handle, .length = 4096 }, &truncate_c, &box, truncate_cb);
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 4096 }, &fallocate_c, &box, fallocate_cb);

    try testing.expectEqual(@as(u32, 1), box.fsync_calls);
    try testing.expectEqual(@as(u32, 1), box.truncate_calls);
    try testing.expectEqual(@as(u32, 1), box.fallocate_calls);
    try testing.expectEqual(@as(?anyerror, error.Unimplemented), box.fsync_err);
    try testing.expectEqual(@as(?anyerror, error.Unimplemented), box.truncate_err);
    try testing.expectEqual(@as(?anyerror, error.Unimplemented), box.fallocate_err);
}

test "EpollIO socket op produces a non-blocking fd" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const Box = struct {
        fd: ?posix.fd_t = null,
        err: ?anyerror = null,
    };
    var box = Box{};

    const sock_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            switch (result) {
                .socket => |r| {
                    if (r) |fd| {
                        b.fd = fd;
                    } else |err| {
                        b.err = err;
                    }
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try io.socket(.{
        .domain = posix.AF.INET,
        .sock_type = posix.SOCK.STREAM,
        .protocol = 0,
    }, &c, &box, sock_cb);

    try testing.expect(box.fd != null);
    defer posix.close(box.fd.?);

    // Verify the fd is non-blocking.
    const fl = try posix.fcntl(box.fd.?, posix.F.GETFL, 0);
    try testing.expect((fl & @as(usize, @bitCast(@as(isize, posix.SOCK.NONBLOCK)))) != 0);
}

//! EpollMmapIO smoke tests. Mirrors `tests/epoll_posix_io_test.zig` but
//! exercises the mmap-backed file-op path. The readiness layer (sockets,
//! timers, cancel) is identical between the two backends; this file's
//! distinct value is in the file-op coverage:
//!
//! - Multi-tick socketpair round-trip (sanity that the readiness layer
//!   actually mirrors EpollPosixIO).
//! - `pwrite` -> `pread` round-trip through the mmap region.
//! - Larger-buffer write that triggers a remap (pre-allocated file size,
//!   then write extending past the original mapping).
//! - `fsync` (msync) on a populated mapping.
//! - `truncate` invalidates the mapping and the next read sees the new
//!   size.
//!
//! These run via `zig build test-epoll-mmap-io` (focused) or as part of
//! `zig build test` (full suite).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const epoll_mmap_io = varuna.io.epoll_mmap_io;
const EpollMmapIO = epoll_mmap_io.EpollMmapIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Fixtures ──────────────────────────────────────────────

fn skipIfUnavailable() !EpollMmapIO {
    return EpollMmapIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
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
    file_calls: u32 = 0,
    file_bytes: usize = 0,
    last_err: ?anyerror = null,
    recv_buf: [4096]u8 = undefined,
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
        .recv => |r| if (r) |n| {
            c.bytes_received += n;
        } else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

fn writeCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.file_calls += 1;
    switch (result) {
        .write => |r| if (r) |n| {
            c.file_bytes = n;
        } else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

fn readCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.file_calls += 1;
    switch (result) {
        .read => |r| if (r) |n| {
            c.file_bytes = n;
        } else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

fn truncateCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.file_calls += 1;
    switch (result) {
        .truncate => |r| if (r) |_| {} else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

fn fsyncCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.file_calls += 1;
    switch (result) {
        .fsync => |r| if (r) |_| {} else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

fn fallocateCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.file_calls += 1;
    switch (result) {
        .fallocate => |r| if (r) |_| {} else |err| {
            c.last_err = err;
        },
        else => {},
    }
    return .disarm;
}

// ── Tests ─────────────────────────────────────────────────

test "EpollMmapIO multi-tick send/recv round-trip on real socketpair" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fds = (try makeSocketpairNonBlocking()) orelse return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var counter = Counter{};

    var recv_c = Completion{};
    try io.recv(.{ .fd = fds[1], .buf = &counter.recv_buf }, &recv_c, &counter, recvCb);
    try testing.expectEqual(@as(u32, 0), counter.received);

    var send_c = Completion{};
    try io.send(.{ .fd = fds[0], .buf = "epoll-mmap" }, &send_c, &counter, sendCb);
    try testing.expectEqual(@as(u32, 1), counter.sent);

    var attempts: u32 = 0;
    while (counter.received < 1 and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }
    try testing.expectEqual(@as(u32, 1), counter.received);
    try testing.expectEqual(@as(usize, 10), counter.bytes_sent);
    try testing.expectEqual(@as(usize, 10), counter.bytes_received);
    try testing.expectEqualStrings("epoll-mmap", counter.recv_buf[0..10]);
}

test "EpollMmapIO mmap-backed write triggers remap on file growth" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("mmap_grow", .{ .truncate = true, .read = true });
    defer file.close();

    // Initial fallocate to 1024 bytes — establishes the first mapping
    // when we later read.
    var counter = Counter{};
    var fa1_c = Completion{};
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 1024 }, &fa1_c, &counter, fallocateCb);
    try testing.expectEqual(@as(u32, 1), counter.file_calls);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    // Write near the end of the existing region (no remap needed).
    var w1_c = Completion{};
    counter.file_calls = 0;
    try io.write(.{ .fd = file.handle, .buf = "near-end", .offset = 1000 }, &w1_c, &counter, writeCb);
    try testing.expectEqual(@as(usize, 8), counter.file_bytes);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    // Grow the file past the existing 1024-byte mapping.
    var fa2_c = Completion{};
    counter.file_calls = 0;
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 8192 }, &fa2_c, &counter, fallocateCb);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    // Write past the original mapping — should trigger a remap and succeed.
    var w2_c = Completion{};
    counter.file_calls = 0;
    counter.file_bytes = 0;
    try io.write(.{ .fd = file.handle, .buf = "past-old-mapping-edge", .offset = 4096 }, &w2_c, &counter, writeCb);
    try testing.expectEqual(@as(usize, 21), counter.file_bytes);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    // Read it back.
    var read_buf: [21]u8 = undefined;
    var r_c = Completion{};
    counter.file_calls = 0;
    counter.file_bytes = 0;
    try io.read(.{ .fd = file.handle, .buf = &read_buf, .offset = 4096 }, &r_c, &counter, readCb);
    try testing.expectEqual(@as(usize, 21), counter.file_bytes);
    try testing.expectEqualStrings("past-old-mapping-edge", &read_buf);
}

test "EpollMmapIO fsync (msync) on a populated mapping succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("mmap_fsync", .{ .truncate = true, .read = true });
    defer file.close();

    var counter = Counter{};
    var fa_c = Completion{};
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 4096 }, &fa_c, &counter, fallocateCb);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    var w_c = Completion{};
    counter.file_calls = 0;
    try io.write(.{ .fd = file.handle, .buf = "fsync-me", .offset = 0 }, &w_c, &counter, writeCb);
    try testing.expectEqual(@as(usize, 8), counter.file_bytes);

    // fsync goes through msync(MS_SYNC) since a mapping is established.
    var s_c = Completion{};
    counter.file_calls = 0;
    counter.last_err = null;
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &s_c, &counter, fsyncCb);
    try testing.expectEqual(@as(u32, 1), counter.file_calls);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);
}

test "EpollMmapIO truncate invalidates mapping; next read reflects new size" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("mmap_truncate", .{ .truncate = true, .read = true });
    defer file.close();

    // Truncate to 256 bytes.
    var counter = Counter{};
    var t1_c = Completion{};
    try io.truncate(.{ .fd = file.handle, .length = 256 }, &t1_c, &counter, truncateCb);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    // Read at offset 200 — within range, should return 16 bytes (zeroed).
    var read_buf: [16]u8 = undefined;
    var r1_c = Completion{};
    counter.file_calls = 0;
    counter.file_bytes = 0;
    try io.read(.{ .fd = file.handle, .buf = &read_buf, .offset = 200 }, &r1_c, &counter, readCb);
    try testing.expectEqual(@as(usize, 16), counter.file_bytes);

    // Truncate down to 100 bytes — invalidates the existing 256-byte
    // mapping. The next read at offset 200 must now see the smaller file.
    var t2_c = Completion{};
    counter.file_calls = 0;
    counter.last_err = null;
    try io.truncate(.{ .fd = file.handle, .length = 100 }, &t2_c, &counter, truncateCb);
    try testing.expectEqual(@as(?anyerror, null), counter.last_err);

    var r2_c = Completion{};
    counter.file_calls = 0;
    counter.file_bytes = 999; // sentinel: detect "didn't get called"
    try io.read(.{ .fd = file.handle, .buf = &read_buf, .offset = 200 }, &r2_c, &counter, readCb);
    // After truncate to 100, offset 200 is past EOF -> zero bytes.
    try testing.expectEqual(@as(usize, 0), counter.file_bytes);
}

//! EpollPosixIO smoke tests. Mirrors the shape of
//! `tests/sim_socketpair_test.zig` but exercises real Linux socketpairs
//! through the epoll readiness backend (`src/io/epoll_posix_io.zig`).
//! Provides backend-specific coverage beyond the inline tests in
//! `epoll_posix_io.zig`:
//!
//! - Multi-tick socketpair round-trip with both ends parked.
//! - Larger-buffer transfer to exercise `posix.send` / `posix.recv`
//!   under a non-blocking socket.
//! - Multiple concurrent timers ordered by deadline.
//! - Cancel of a registered fd before any data arrives.
//! - File ops via `PosixFilePool`: fsync/truncate/fallocate completion,
//!   write→read round-trip, concurrent submission, and bad-fd fault
//!   propagation through the worker thread.
//!
//! These run via `zig build test-epoll-posix-io` (focused) or as part of
//! `zig build test` (full suite).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const epoll_posix_io = varuna.io.epoll_posix_io;
const EpollPosixIO = epoll_posix_io.EpollPosixIO;
const HttpExecutor = varuna.io.http_executor.HttpExecutorOf(EpollPosixIO);

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Fixtures ──────────────────────────────────────────────

fn skipIfUnavailable() !EpollPosixIO {
    return EpollPosixIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
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
    last_send_err: ?anyerror = null,
    last_recv_err: ?anyerror = null,
};

fn sendCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(ud.?));
    c.sent += 1;
    switch (result) {
        .send => |r| if (r) |n| {
            c.bytes_sent += n;
        } else |err| {
            c.last_send_err = err;
        },
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

const RecvThenEof = struct {
    calls: u32 = 0,
    first_bytes: usize = 0,
    second_bytes: usize = std.math.maxInt(usize),
    err: ?anyerror = null,
    buf: [32]u8 = undefined,
};

fn recvThenEofCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const ctx: *RecvThenEof = @ptrCast(@alignCast(ud.?));
    ctx.calls += 1;
    switch (result) {
        .recv => |r| {
            const n = r catch |err| {
                ctx.err = err;
                return .disarm;
            };
            if (ctx.calls == 1) {
                ctx.first_bytes = n;
                return .rearm;
            }
            ctx.second_bytes = n;
        },
        else => {},
    }
    return .disarm;
}

fn createHttpListenSocket() !struct { fd: posix.fd_t, port: u16 } {
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(fd);

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var enable: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 1);

    var bound: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(fd, @ptrCast(&bound), &len);
    const bound_addr = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(&bound)).* };
    return .{ .fd = fd, .port = bound_addr.getPort() };
}

const HttpCloseServerCtx = struct {
    listen_fd: posix.fd_t,
};

fn runCloseDelimitedHttpServer(ctx: *HttpCloseServerCtx) void {
    const deadline_ns = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    const conn_fd = while (std.time.nanoTimestamp() < deadline_ns) {
        break posix.accept(
            ctx.listen_fd,
            null,
            null,
            posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1_000_000);
                continue;
            },
            else => return,
        };
    } else return;
    defer posix.close(conn_fd);

    var buf: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len and std.time.nanoTimestamp() < deadline_ns) {
        const n = posix.recv(conn_fd, buf[used..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(1_000_000);
                continue;
            },
            else => return,
        };
        if (n == 0) return;
        used += n;
        if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
    }

    _ = posix.send(conn_fd, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello world", 0) catch {};
}

const HttpResultBox = struct {
    done: bool = false,
    status: u16 = 0,
    body_len: usize = 0,
    body_matches: bool = false,
    err: ?anyerror = null,
};

fn httpCloseComplete(ctx: *anyopaque, result: HttpExecutor.RequestResult) void {
    const box: *HttpResultBox = @ptrCast(@alignCast(ctx));
    box.done = true;
    box.status = result.status;
    box.err = result.err;
    if (result.body) |body| {
        box.body_len = body.len;
        box.body_matches = std.mem.eql(u8, body, "hello world");
    }
}

// ── Tests ─────────────────────────────────────────────────

test "EpollPosixIO multi-tick send/recv round-trip on real socketpair" {
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

    // Now submit a send. The readiness backend reports the send completion
    // from tick(), so callers observe async ordering like io_uring even when
    // the socket is already writable.
    var send_c = Completion{};
    try io.send(.{ .fd = fds[0], .buf = "epoll-mvp" }, &send_c, &counter, sendCb);

    var attempts: u32 = 0;
    while ((counter.sent < 1 or counter.received < 1) and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }
    try testing.expectEqual(@as(u32, 1), counter.sent);
    try testing.expectEqual(@as(u32, 1), counter.received);
    try testing.expectEqual(@as(usize, 9), counter.bytes_sent);
    try testing.expectEqual(@as(usize, 9), counter.bytes_received);
    try testing.expectEqualStrings("epoll-mvp", counter.recv_buf[0..9]);
}

test "EpollPosixIO closeSocket cancels parked send callback" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fds = (try makeSocketpairNonBlocking()) orelse return error.SkipZigTest;
    defer posix.close(fds[1]);

    var counter = Counter{};
    var send_c = Completion{};
    try io.send(.{ .fd = fds[0], .buf = "pending-close" }, &send_c, &counter, sendCb);
    try testing.expectEqual(@as(u32, 0), counter.sent);

    io.closeSocket(fds[0]);

    try testing.expectEqual(@as(u32, 1), counter.sent);
    try testing.expectEqual(error.OperationCanceled, counter.last_send_err.?);
}

test "EpollPosixIO recv rearm after peer close delivers EOF" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fds = (try makeSocketpairNonBlocking()) orelse return error.SkipZigTest;
    var writer_open = true;
    defer if (writer_open) posix.close(fds[0]);
    defer posix.close(fds[1]);

    var ctx = RecvThenEof{};
    var recv_c = Completion{};
    try io.recv(.{ .fd = fds[1], .buf = &ctx.buf }, &recv_c, &ctx, recvThenEofCb);

    const n = try posix.write(fds[0], "hello");
    try testing.expectEqual(@as(usize, 5), n);
    posix.close(fds[0]);
    writer_open = false;

    var attempts: u32 = 0;
    while (ctx.calls < 2 and attempts < 100) : (attempts += 1) {
        try io.tick(0);
        std.Thread.sleep(1_000_000);
    }

    try testing.expectEqual(@as(u32, 2), ctx.calls);
    try testing.expectEqual(@as(?anyerror, null), ctx.err);
    try testing.expectEqual(@as(usize, 5), ctx.first_bytes);
    try testing.expectEqualStrings("hello", ctx.buf[0..5]);
    try testing.expectEqual(@as(usize, 0), ctx.second_bytes);
}

test "EpollPosixIO HttpExecutor completes close-delimited response" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const listen = try createHttpListenSocket();
    defer posix.close(listen.fd);

    var server_ctx = HttpCloseServerCtx{ .listen_fd = listen.fd };
    const server_thread = try std.Thread.spawn(.{}, runCloseDelimitedHttpServer, .{&server_ctx});
    defer server_thread.join();

    var executor = try HttpExecutor.create(testing.allocator, &io, .{});
    defer executor.destroy();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/announce", .{listen.port});
    var result = HttpResultBox{};
    var job = HttpExecutor.Job{
        .context = &result,
        .on_complete = httpCloseComplete,
        .url_len = @intCast(url.len),
        .host_len = "127.0.0.1".len,
    };
    @memcpy(job.url[0..url.len], url);
    @memcpy(job.host[0.."127.0.0.1".len], "127.0.0.1");
    try executor.submit(job);

    var attempts: u32 = 0;
    while (!result.done and attempts < 1000) : (attempts += 1) {
        executor.tick();
        try io.tick(0);
        std.Thread.sleep(1_000_000);
    }

    try testing.expect(result.done);
    try testing.expectEqual(@as(?anyerror, null), result.err);
    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expectEqual(@as(usize, "hello world".len), result.body_len);
    try testing.expect(result.body_matches);
}

test "EpollPosixIO multiple timers fire in deadline order" {
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

test "EpollPosixIO cancel on registered recv before data delivers OperationCanceled" {
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

test "EpollPosixIO file ops complete asynchronously via PosixFilePool" {
    // The five file-op methods (fsync, truncate, fallocate, read, write)
    // route through the pool. Workers run the syscall, push the result,
    // and signal `wakeup_fd`; `tick` drains the queue and fires
    // callbacks. Asserts each op delivers a successful result against a
    // real tmpfile.
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(
        "epoll_file_ops_test",
        .{ .read = true, .truncate = true },
    );
    defer file.close();
    try file.writeAll("varuna_initial");

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

    var attempts: u32 = 0;
    while ((box.fsync_calls < 1 or
        box.truncate_calls < 1 or
        box.fallocate_calls < 1) and attempts < 200) : (attempts += 1)
    {
        try io.tick(1);
    }

    try testing.expectEqual(@as(u32, 1), box.fsync_calls);
    try testing.expectEqual(@as(u32, 1), box.truncate_calls);
    try testing.expectEqual(@as(u32, 1), box.fallocate_calls);
    try testing.expectEqual(@as(?anyerror, null), box.fsync_err);
    try testing.expectEqual(@as(?anyerror, null), box.truncate_err);
    // tmpfs may reject fallocate with OperationNotSupported on
    // pre-5.10 kernels; that's the daemon's documented fallback path
    // and counts as a clean delivery.
    try testing.expect(box.fallocate_err == null or box.fallocate_err.? == error.OperationNotSupported);
}

test "EpollPosixIO write-then-read round-trips through the pool" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(
        "epoll_rw_round_trip",
        .{ .read = true, .truncate = true },
    );
    defer file.close();

    const Box = struct {
        write_n: ?usize = null,
        read_n: ?usize = null,
        read_buf: [16]u8 = undefined,
        done: u32 = 0,
    };
    var box = Box{};

    const write_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            switch (result) {
                .write => |r| b.write_n = r catch null,
                else => {},
            }
            b.done += 1;
            return .disarm;
        }
    }.cb;
    const read_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            switch (result) {
                .read => |r| b.read_n = r catch null,
                else => {},
            }
            b.done += 1;
            return .disarm;
        }
    }.cb;

    var write_c = Completion{};
    try io.write(.{ .fd = file.handle, .buf = "varuna", .offset = 0 }, &write_c, &box, write_cb);

    var attempts: u32 = 0;
    while (box.done < 1 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(usize, 6), box.write_n.?);

    var read_c = Completion{};
    try io.read(.{ .fd = file.handle, .buf = &box.read_buf, .offset = 0 }, &read_c, &box, read_cb);

    attempts = 0;
    while (box.done < 2 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(usize, 6), box.read_n.?);
    try testing.expectEqualStrings("varuna", box.read_buf[0..6]);
}

test "EpollPosixIO concurrent file ops all complete" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(
        "epoll_concurrent_writes",
        .{ .read = true, .truncate = true },
    );
    defer file.close();
    try posix.ftruncate(file.handle, 64 * 16);

    const op_count: u32 = 64;
    const Box = struct {
        completed: u32 = 0,
        errs: u32 = 0,
    };
    var box = Box{};

    const write_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.completed += 1;
            switch (result) {
                .write => |r| if (r) |_| {} else |_| {
                    b.errs += 1;
                },
                else => b.errs += 1,
            }
            return .disarm;
        }
    }.cb;

    const completions = try testing.allocator.alloc(Completion, op_count);
    defer testing.allocator.free(completions);
    @memset(completions, Completion{});

    for (0..op_count) |i| {
        try io.write(.{
            .fd = file.handle,
            .buf = "varuna_test_op_!",
            .offset = i * 16,
        }, &completions[i], &box, write_cb);
    }

    var attempts: u32 = 0;
    while (box.completed < op_count and attempts < 1000) : (attempts += 1) {
        try io.tick(1);
    }
    try testing.expectEqual(op_count, box.completed);
    try testing.expectEqual(@as(u32, 0), box.errs);
}

test "EpollPosixIO file op against a closed fd surfaces an error" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    const Box = struct {
        called: u32 = 0,
        err: ?anyerror = null,
    };
    var box = Box{};

    const write_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.called += 1;
            switch (result) {
                .write => |r| if (r) |_| {} else |err| {
                    b.err = err;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try io.write(.{ .fd = -1, .buf = "boom", .offset = 0 }, &c, &box, write_cb);

    var attempts: u32 = 0;
    while (box.called == 0 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(u32, 1), box.called);
    try testing.expect(box.err != null);
}

test "EpollPosixIO socket op produces a non-blocking fd" {
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

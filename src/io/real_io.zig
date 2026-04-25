//! RealIO — io_uring backend implementing the public `io_interface`.
//!
//! `RealIO` owns a `linux.IoUring` and dispatches submissions through the
//! caller-owned `Completion` struct. The completion's address is the SQE's
//! `user_data`; on CQE arrival we cast the user_data back to a pointer and
//! invoke the callback.
//!
//! This module is the production backend. It is intentionally a thin
//! wrapper — it does not own the peer table, the piece store, or any other
//! daemon state. `EventLoop` keeps that ownership; `RealIO` only translates
//! between the public interface and `linux.IoUring`.
//!
//! See `docs/io-abstraction-plan.md`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;

const ifc = @import("io_interface.zig");
const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const Callback = ifc.Callback;
const CallbackAction = ifc.CallbackAction;

// ── Backend state ─────────────────────────────────────────
//
// RealIO needs to keep a few pieces of state alive inside the Completion
// while the SQE is in flight:
//
//   * `in_flight`              — guards against double submission.
//   * `multishot`              — distinguishes multishot accept from
//                                single-shot (multishot CQEs do not consume
//                                the completion until F_MORE clears).
//   * `has_link_timeout`       — connect with a deadline submits two SQEs;
//                                the link_timeout CQE is consumed silently
//                                (its user_data is `link_timeout_sentinel`).
//   * `deadline_ts`            — backing storage for the kernel timespec
//                                referenced by the SQE. Must outlive submit.
//
// All combined fits well under `ifc.backend_state_size` (64 bytes).

pub const RealState = struct {
    in_flight: bool = false,
    multishot: bool = false,
    has_link_timeout: bool = false,
    /// Kernel timespec used by `timeout` and the link_timeout for
    /// `connect`. Reading the SQE keeps this address; we store it in the
    /// completion so it survives until the CQE arrives.
    deadline_ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
};

comptime {
    assert(@sizeOf(RealState) <= ifc.backend_state_size);
    assert(@alignOf(RealState) <= ifc.backend_state_align);
}

inline fn realState(c: *Completion) *RealState {
    return c.backendStateAs(RealState);
}

/// Sentinel user_data for the link_timeout SQE that pairs with a
/// deadline-bounded connect. The CQE for the timeout is silently consumed.
/// (`@intFromPtr(null)` is 0 which would also collide with anything else.)
const link_timeout_sentinel: u64 = std.math.maxInt(u64);

// ── Configuration ─────────────────────────────────────────

pub const Config = struct {
    /// Number of SQEs / CQEs in the ring. Must be a power of two.
    entries: u16 = 1024,
    /// Optional ring init flags (e.g. IORING_SETUP_COOP_TASKRUN).
    flags: u32 = 0,
};

// ── RealIO ────────────────────────────────────────────────

pub const RealIO = struct {
    ring: linux.IoUring,

    pub fn init(config: Config) !RealIO {
        // Fall back to plain init if the kernel doesn't accept the requested
        // flags (e.g. COOP_TASKRUN / SINGLE_ISSUER on older kernels). Mirrors
        // the policy in `ring.zig:initIoUring`.
        const ring = linux.IoUring.init(config.entries, config.flags) catch
            try linux.IoUring.init(config.entries, 0);
        return .{ .ring = ring };
    }

    pub fn deinit(self: *RealIO) void {
        self.ring.deinit();
        self.* = undefined;
    }

    /// Synchronously close a file descriptor. The signature matches
    /// `SimIO.closeSocket` so EventLoop.deinit can use `self.io.closeSocket(fd)`
    /// uniformly across both backends. RealIO calls `posix.close`; SimIO
    /// marks its slot closed and fails any parked recv on it.
    pub fn closeSocket(_: *RealIO, fd: posix.fd_t) void {
        posix.close(fd);
    }

    /// Submit any pending SQEs and dispatch all available CQEs by
    /// invoking the corresponding `Completion.callback`. Returns once the
    /// CQ is empty.
    ///
    /// `wait_at_least` blocks for at least that many completions before
    /// returning (use 0 for non-blocking, 1 for "advance the loop").
    pub fn tick(self: *RealIO, wait_at_least: u32) !void {
        _ = try self.ring.submit_and_wait(wait_at_least);

        var cqes: [32]linux.io_uring_cqe = undefined;
        while (true) {
            const count = try self.ring.copy_cqes(&cqes, 0);
            if (count == 0) break;
            for (cqes[0..count]) |cqe| {
                try self.dispatchCqe(cqe);
            }
            if (count < cqes.len) break;
        }
    }

    fn dispatchCqe(self: *RealIO, cqe: linux.io_uring_cqe) !void {
        // Silently swallow link_timeout CQEs paired with connect.
        if (cqe.user_data == link_timeout_sentinel) return;

        const c: *Completion = @ptrFromInt(cqe.user_data);
        const callback = c.callback orelse return;

        // For multishot operations, the CQE may carry IORING_CQE_F_MORE,
        // meaning the kernel will deliver more CQEs against the same SQE.
        // Only flip in_flight off for the final CQE (F_MORE clear).
        const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;

        const result = buildResult(c.op, cqe);

        // Clear in_flight BEFORE invoking the callback so that callbacks
        // which immediately submit a follow-on op on the same completion
        // (e.g., a peer reading the next protocol header after the body
        // completes) don't trip the AlreadyInFlight guard against
        // themselves. For multishot CQEs the kernel will deliver more
        // completions against the same SQE — leave in_flight set.
        if (!more) {
            realState(c).in_flight = false;
        }

        const action = callback(c.userdata, c, result);

        switch (action) {
            .disarm => {},
            .rearm => {
                if (more) return; // multishot: next CQE comes from the kernel
                try self.resubmit(c);
            },
        }
    }

    fn resubmit(self: *RealIO, c: *Completion) !void {
        const userdata = c.userdata;
        const callback = c.callback orelse return;
        switch (c.op) {
            .none => {},
            .recv => |op| try self.recv(op, c, userdata, callback),
            .send => |op| try self.send(op, c, userdata, callback),
            .recvmsg => |op| try self.recvmsg(op, c, userdata, callback),
            .sendmsg => |op| try self.sendmsg(op, c, userdata, callback),
            .read => |op| try self.read(op, c, userdata, callback),
            .write => |op| try self.write(op, c, userdata, callback),
            .fsync => |op| try self.fsync(op, c, userdata, callback),
            .socket => |op| try self.socket(op, c, userdata, callback),
            .connect => |op| try self.connect(op, c, userdata, callback),
            .accept => |op| try self.accept(op, c, userdata, callback),
            .timeout => |op| try self.timeout(op, c, userdata, callback),
            .poll => |op| try self.poll(op, c, userdata, callback),
            .cancel => |op| try self.cancel(op, c, userdata, callback),
        }
    }

    // ── Submission methods ────────────────────────────────

    pub fn recv(self: *RealIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op }, ud, cb);
        const sqe = try self.ring.recv(@intFromPtr(c), op.fd, .{ .buffer = op.buf }, op.flags);
        _ = sqe;
    }

    pub fn send(self: *RealIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op }, ud, cb);
        const sqe = try self.ring.send(@intFromPtr(c), op.fd, op.buf, op.flags);
        _ = sqe;
    }

    pub fn recvmsg(self: *RealIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op }, ud, cb);
        const sqe = try self.ring.recvmsg(@intFromPtr(c), op.fd, op.msg, op.flags);
        _ = sqe;
    }

    pub fn sendmsg(self: *RealIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op }, ud, cb);
        const sqe = try self.ring.sendmsg(@intFromPtr(c), op.fd, op.msg, op.flags);
        _ = sqe;
    }

    pub fn read(self: *RealIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        const sqe = try self.ring.read(@intFromPtr(c), op.fd, .{ .buffer = op.buf }, op.offset);
        _ = sqe;
    }

    pub fn write(self: *RealIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const sqe = try self.ring.write(@intFromPtr(c), op.fd, op.buf, op.offset);
        _ = sqe;
    }

    pub fn fsync(self: *RealIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        const flags: u32 = if (op.datasync) linux.IORING_FSYNC_DATASYNC else 0;
        const sqe = try self.ring.fsync(@intFromPtr(c), op.fd, flags);
        _ = sqe;
    }

    pub fn socket(self: *RealIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .socket = op }, ud, cb);
        const sqe = try self.ring.socket(@intFromPtr(c), op.domain, op.sock_type, op.protocol, 0);
        _ = sqe;
    }

    pub fn connect(self: *RealIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);
        const addrlen = op.addr.getOsSockLen();
        const sqe = try self.ring.connect(@intFromPtr(c), op.fd, &op.addr.any, addrlen);

        if (op.deadline_ns) |ns| {
            // Chain a link_timeout. The connect SQE must carry IO_LINK and
            // be immediately followed by the link_timeout SQE. The
            // link_timeout user_data is a sentinel — we silently swallow
            // its CQE in dispatchCqe.
            sqe.flags |= linux.IOSQE_IO_LINK;
            const st = realState(c);
            st.deadline_ts = .{
                .sec = @intCast(ns / std.time.ns_per_s),
                .nsec = @intCast(ns % std.time.ns_per_s),
            };
            st.has_link_timeout = true;
            const lt_sqe = try self.ring.link_timeout(link_timeout_sentinel, &st.deadline_ts, 0);
            _ = lt_sqe;
        }
    }

    pub fn accept(self: *RealIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        realState(c).multishot = op.multishot;
        // We do not request the kernel to fill peer addr — multishot can't
        // share it across CQEs anyway. Callers who need it call
        // `getpeername(2)` on the accepted fd.
        const flags: u32 = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
        const sqe = if (op.multishot)
            try self.ring.accept_multishot(@intFromPtr(c), op.fd, null, null, flags)
        else
            try self.ring.accept(@intFromPtr(c), op.fd, null, null, flags);
        _ = sqe;
    }

    pub fn timeout(self: *RealIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        const st = realState(c);
        st.deadline_ts = .{
            .sec = @intCast(op.ns / std.time.ns_per_s),
            .nsec = @intCast(op.ns % std.time.ns_per_s),
        };
        const sqe = try self.ring.timeout(@intFromPtr(c), &st.deadline_ts, 0, 0);
        _ = sqe;
    }

    pub fn poll(self: *RealIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        const sqe = try self.ring.poll_add(@intFromPtr(c), op.fd, op.events);
        _ = sqe;
    }

    /// Cancel an in-flight operation by completion pointer. The cancel
    /// completion `c` itself receives a `.cancel` result; the cancelled
    /// op's callback fires with `error.OperationCanceled` on the next
    /// tick that drains its CQE.
    pub fn cancel(self: *RealIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);
        const sqe = try self.ring.cancel(@intFromPtr(c), @intFromPtr(op.target), 0);
        _ = sqe;
    }

    fn armCompletion(self: *RealIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        const st = realState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .in_flight = true };
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }
};

// ── CQE → Result ──────────────────────────────────────────

fn buildResult(op: Operation, cqe: linux.io_uring_cqe) Result {
    return switch (op) {
        .none => .{ .timeout = error.UnknownOperation },
        .recv => .{ .recv = countOrError(cqe) },
        .send => .{ .send = countOrError(cqe) },
        .recvmsg => .{ .recvmsg = countOrError(cqe) },
        .sendmsg => .{ .sendmsg = countOrError(cqe) },
        .read => .{ .read = countOrError(cqe) },
        .write => .{ .write = countOrError(cqe) },
        .fsync => .{ .fsync = voidOrError(cqe) },
        .socket => .{ .socket = fdOrError(cqe) },
        .connect => .{ .connect = voidOrError(cqe) },
        .accept => .{ .accept = acceptResult(cqe) },
        .timeout => .{ .timeout = timeoutResult(cqe) },
        .poll => .{ .poll = pollResult(cqe) },
        .cancel => .{ .cancel = cancelResult(cqe) },
    };
}

fn countOrError(cqe: linux.io_uring_cqe) anyerror!usize {
    if (cqe.res < 0) return errnoToError(cqe.err());
    return @intCast(cqe.res);
}

fn voidOrError(cqe: linux.io_uring_cqe) anyerror!void {
    if (cqe.res < 0) return errnoToError(cqe.err());
}

fn fdOrError(cqe: linux.io_uring_cqe) anyerror!posix.fd_t {
    if (cqe.res < 0) return errnoToError(cqe.err());
    return @intCast(cqe.res);
}

fn acceptResult(cqe: linux.io_uring_cqe) anyerror!ifc.Accepted {
    if (cqe.res < 0) return errnoToError(cqe.err());
    return .{
        .fd = @intCast(cqe.res),
        // Kernel didn't fill addr (we passed null). Caller uses getpeername.
        .addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0),
    };
}

fn timeoutResult(cqe: linux.io_uring_cqe) anyerror!void {
    // Timeouts complete with -ETIME on success (timer expired) and 0 on
    // count completion. Both are normal completions; only -ECANCELED is
    // an error worth surfacing.
    return switch (cqe.err()) {
        .SUCCESS, .TIME => {},
        .CANCELED => error.OperationCanceled,
        else => |e| posix.unexpectedErrno(e),
    };
}

fn pollResult(cqe: linux.io_uring_cqe) anyerror!u32 {
    if (cqe.res < 0) return errnoToError(cqe.err());
    return @intCast(cqe.res);
}

fn cancelResult(cqe: linux.io_uring_cqe) anyerror!void {
    return switch (cqe.err()) {
        .SUCCESS => {},
        .NOENT => error.OperationNotFound,
        .ALREADY => error.AlreadyCompleted,
        else => |e| posix.unexpectedErrno(e),
    };
}

fn errnoToError(e: linux.E) anyerror {
    return switch (e) {
        .SUCCESS => unreachable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .PIPE => error.BrokenPipe,
        .CONNABORTED => error.ConnectionAborted,
        .CANCELED => error.OperationCanceled,
        .NOENT => error.OperationNotFound,
        .ALREADY => error.AlreadyCompleted,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .ISDIR => error.IsDir,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => posix.unexpectedErrno(e),
    };
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

fn skipIfUnavailable() !RealIO {
    return RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
}

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
    ctx.calls += 1;
    ctx.last_result = result;
    return .disarm;
}

test "RealIO timeout fires on real ring" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, testCallback); // 1ms

    try io.tick(1); // block for at least 1 completion
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

test "RealIO recv on socketpair delivers bytes" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    // Create a connected AF_UNIX socketpair.
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Submit recv on fds[0]; we expect "hello".
    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &c, &ctx, testCallback);

    // Write "hello" on fds[1] (synchronous write — outside the ring is fine
    // because this is test setup).
    const n = try posix.write(fds[1], "hello");
    try testing.expectEqual(@as(usize, 5), n);

    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| {
            const got = try r;
            try testing.expectEqual(@as(usize, 5), got);
            try testing.expectEqualStrings("hello", buf[0..5]);
        },
        else => try testing.expect(false),
    }
}

test "RealIO send + recv round-trip on socketpair" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Both = struct {
        sent: u32 = 0,
        received: u32 = 0,
        bytes_sent: usize = 0,
        bytes_received: usize = 0,
        recv_buf: [32]u8 = undefined,
    };
    var both = Both{};

    const send_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *Both = @ptrCast(@alignCast(ud.?));
            s.sent += 1;
            switch (result) {
                .send => |r| s.bytes_sent = r catch 0,
                else => {},
            }
            return .disarm;
        }
    }.cb;
    const recv_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *Both = @ptrCast(@alignCast(ud.?));
            s.received += 1;
            switch (result) {
                .recv => |r| s.bytes_received = r catch 0,
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var send_c = Completion{};
    var recv_c = Completion{};
    try io.recv(.{ .fd = fds[1], .buf = &both.recv_buf }, &recv_c, &both, recv_cb);
    try io.send(.{ .fd = fds[0], .buf = "varuna" }, &send_c, &both, send_cb);

    // Drain both completions.
    while (both.sent < 1 or both.received < 1) try io.tick(1);

    try testing.expectEqual(@as(usize, 6), both.bytes_sent);
    try testing.expectEqual(@as(usize, 6), both.bytes_received);
    try testing.expectEqualStrings("varuna", both.recv_buf[0..6]);
}

test "RealIO cancel aborts an in-flight recv" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const Both = struct {
        recv_calls: u32 = 0,
        cancel_calls: u32 = 0,
        recv_result: ?Result = null,
        cancel_result: ?Result = null,
    };
    var st = Both{};

    const recv_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *Both = @ptrCast(@alignCast(ud.?));
            s.recv_calls += 1;
            s.recv_result = result;
            return .disarm;
        }
    }.cb;
    const cancel_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *Both = @ptrCast(@alignCast(ud.?));
            s.cancel_calls += 1;
            s.cancel_result = result;
            return .disarm;
        }
    }.cb;

    var recv_buf: [16]u8 = undefined;
    var recv_c = Completion{};
    var cancel_c = Completion{};

    try io.recv(.{ .fd = fds[0], .buf = &recv_buf }, &recv_c, &st, recv_cb);
    // Submit but don't tick yet — keep the recv in flight.
    _ = try io.ring.submit();

    try io.cancel(.{ .target = &recv_c }, &cancel_c, &st, cancel_cb);

    while (st.recv_calls < 1 or st.cancel_calls < 1) try io.tick(1);

    switch (st.recv_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    // Cancel may complete either successfully (.cancel = {}) or with
    // AlreadyCompleted if the recv completed first; both are acceptable.
    switch (st.cancel_result.?) {
        .cancel => {},
        else => try testing.expect(false),
    }
}

test "RealIO fsync on tempfile succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    // Create a temp file we can fsync.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("fsync_test", .{ .truncate = true });
    defer file.close();
    _ = try posix.write(file.handle, "data");

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &c, &ctx, testCallback);
    try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fsync => |r| try r,
        else => try testing.expect(false),
    }
}

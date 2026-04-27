//! EpollMmapIO — Linux epoll readiness backend with mmap-based file I/O.
//!
//! Companion to `epoll_posix_io.zig`. The readiness layer (epoll) is
//! identical — sockets, timers, and cancel are mechanically the same. The
//! axis that differs is file I/O:
//!
//!   * `epoll_posix_io.zig`: `pread`/`pwrite`/`fsync`/`fallocate` syscalls
//!     offloaded to a thread pool.
//!   * `epoll_mmap_io.zig` (this file): file is mmap'd at first access;
//!     reads/writes are `memcpy`s; `fsync` is `msync(MS_SYNC)`. Zero-copy,
//!     OS pagecache implicit. Page faults block the calling thread today
//!     (mitigation: `madvise(WILLNEED)`); promote to a thread-pool memcpy
//!     if profiling shows it matters.
//!
//! ## Status: scaffold (commit 1 of the bifurcation)
//!
//! This commit establishes the type so the 6-way `IoBackend` enum compiles
//! end-to-end. Commit 2 mirrors the socket / timer / cancel machinery from
//! `epoll_posix_io.zig` and wires up the mmap-based file ops.
//!
//! Until commit 2 lands, **all** submission methods deliver
//! `error.Unimplemented` synchronously. `init` / `deinit` / `tick` /
//! `closeSocket` are real so callers can construct, drain (no-op), and tear
//! down an instance — useful so `-Dio=epoll_mmap` builds and instantiation
//! tests pass even before the real implementation lands.

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
// Same layout as EpollPosixIO. Will be reused once the socket / timer
// machinery is mirrored in commit 2.

const sentinel_index: u32 = std.math.maxInt(u32);

pub const EpollState = struct {
    in_flight: bool = false,
    epoll_registered: bool = false,
    accept_multishot: bool = false,
    registered_fd: posix.fd_t = -1,
    deadline_ns: u64 = 0,
    timer_heap_index: u32 = sentinel_index,
};

comptime {
    assert(@sizeOf(EpollState) <= ifc.backend_state_size);
    assert(@alignOf(EpollState) <= ifc.backend_state_align);
}

inline fn epollState(c: *Completion) *EpollState {
    return c.backendStateAs(EpollState);
}

// ── Configuration ─────────────────────────────────────────

pub const Config = struct {
    /// Initial capacity for the timer heap (used in commit 2).
    max_completions: u32 = 1024,
};

// ── EpollMmapIO ───────────────────────────────────────────

pub const EpollMmapIO = struct {
    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,
    wakeup_fd: posix.fd_t,
    active: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !EpollMmapIO {
        _ = config;
        const epoll_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        switch (linux.E.init(epoll_rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .INVAL => return error.InvalidArgument,
            else => |e| return posix.unexpectedErrno(e),
        }
        const epoll_fd: posix.fd_t = @intCast(epoll_rc);
        errdefer posix.close(epoll_fd);

        const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        switch (linux.E.init(efd_rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |e| return posix.unexpectedErrno(e),
        }
        const wakeup_fd: posix.fd_t = @intCast(efd_rc);
        errdefer posix.close(wakeup_fd);

        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .wakeup_fd = wakeup_fd,
        };
    }

    pub fn deinit(self: *EpollMmapIO) void {
        posix.close(self.wakeup_fd);
        posix.close(self.epoll_fd);
        self.* = undefined;
    }

    pub fn closeSocket(self: *EpollMmapIO, fd: posix.fd_t) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        posix.close(fd);
    }

    pub fn tick(self: *EpollMmapIO, wait_at_least: u32) !void {
        _ = self;
        _ = wait_at_least;
        // Stub: no in-flight work today; full readiness loop arrives in
        // commit 2 alongside the socket / timer mirror from EpollPosixIO.
    }

    // ── Submission methods (UNIMPLEMENTED in scaffold) ────
    //
    // Commit 2 mirrors the socket / timer / cancel paths from
    // `epoll_posix_io.zig` and replaces the file-op stubs with mmap-backed
    // memcpy + msync. Today every submission method delivers
    // `error.Unimplemented` synchronously.

    pub fn socket(self: *EpollMmapIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .socket = op }, ud, cb);
        _ = deliverInline(c, .{ .socket = error.Unimplemented });
    }

    pub fn connect(self: *EpollMmapIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .connect = op }, ud, cb);
        _ = deliverInline(c, .{ .connect = error.Unimplemented });
    }

    pub fn accept(self: *EpollMmapIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .accept = op }, ud, cb);
        _ = deliverInline(c, .{ .accept = error.Unimplemented });
    }

    pub fn recv(self: *EpollMmapIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .recv = op }, ud, cb);
        _ = deliverInline(c, .{ .recv = error.Unimplemented });
    }

    pub fn send(self: *EpollMmapIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .send = op }, ud, cb);
        _ = deliverInline(c, .{ .send = error.Unimplemented });
    }

    pub fn recvmsg(self: *EpollMmapIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .recvmsg = op }, ud, cb);
        _ = deliverInline(c, .{ .recvmsg = error.Unimplemented });
    }

    pub fn sendmsg(self: *EpollMmapIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .sendmsg = op }, ud, cb);
        _ = deliverInline(c, .{ .sendmsg = error.Unimplemented });
    }

    pub fn timeout(self: *EpollMmapIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .timeout = op }, ud, cb);
        _ = deliverInline(c, .{ .timeout = error.Unimplemented });
    }

    pub fn poll(self: *EpollMmapIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .poll = op }, ud, cb);
        _ = deliverInline(c, .{ .poll = error.Unimplemented });
    }

    pub fn cancel(self: *EpollMmapIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .cancel = op }, ud, cb);
        _ = deliverInline(c, .{ .cancel = error.Unimplemented });
    }

    pub fn read(self: *EpollMmapIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .read = op }, ud, cb);
        _ = deliverInline(c, .{ .read = error.Unimplemented });
    }

    pub fn write(self: *EpollMmapIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .write = op }, ud, cb);
        _ = deliverInline(c, .{ .write = error.Unimplemented });
    }

    pub fn fsync(self: *EpollMmapIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .fsync = op }, ud, cb);
        _ = deliverInline(c, .{ .fsync = error.Unimplemented });
    }

    pub fn fallocate(self: *EpollMmapIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .fallocate = op }, ud, cb);
        _ = deliverInline(c, .{ .fallocate = error.Unimplemented });
    }

    pub fn truncate(self: *EpollMmapIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        try armCompletion(c, .{ .truncate = op }, ud, cb);
        _ = deliverInline(c, .{ .truncate = error.Unimplemented });
    }
};

// ── Internal helpers ──────────────────────────────────────

fn armCompletion(c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
    const st = epollState(c);
    if (st.in_flight) return error.AlreadyInFlight;
    st.* = .{ .in_flight = true };
    c.op = op;
    c.userdata = ud;
    c.callback = cb;
    c.next = null;
}

fn deliverInline(c: *Completion, result: Result) CallbackAction {
    const st = epollState(c);
    st.in_flight = false;
    const cb = c.callback orelse return .disarm;
    return cb(c.userdata, c, result);
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

fn skipIfUnavailable() !EpollMmapIO {
    return EpollMmapIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
}

test "EpollMmapIO init / deinit succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    try testing.expect(io.epoll_fd >= 0);
    try testing.expect(io.wakeup_fd >= 0);
}

test "EpollMmapIO scaffold: socket op returns Unimplemented" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const Box = struct { calls: u32 = 0, err: ?anyerror = null };
    var box = Box{};

    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.calls += 1;
            switch (result) {
                .socket => |r| if (r) |_| {} else |err| {
                    b.err = err;
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
    }, &c, &box, cb);

    try testing.expectEqual(@as(u32, 1), box.calls);
    try testing.expectEqual(@as(?anyerror, error.Unimplemented), box.err);
}

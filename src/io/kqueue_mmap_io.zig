//! KqueueMmapIO — STUB for the 6-way IoBackend selector.
//!
//! STUB — kqueue-bifurcation-engineer replaces this file when their
//! sibling worktree merges. The real `KqueueMmapIO` mirrors `KqueuePosixIO`
//! at the readiness layer (kqueue) and uses mmap-based file I/O instead of
//! `pread`/`pwrite` — the macOS analogue of `EpollMmapIO`.
//!
//! This stub exists so `src/io/backend.zig` can dispatch to a kqueue_mmap
//! type at comptime under `-Dio=kqueue_mmap`. Every method delivers
//! `error.Unimplemented` synchronously.

const std = @import("std");
const posix = std.posix;

const ifc = @import("io_interface.zig");
const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const Callback = ifc.Callback;
const CallbackAction = ifc.CallbackAction;

pub const Config = struct {
    max_completions: u32 = 1024,
};

pub const KqueueMmapIO = struct {
    pub fn init(allocator: std.mem.Allocator, config: Config) !KqueueMmapIO {
        _ = allocator;
        _ = config;
        return error.Unimplemented;
    }

    pub fn deinit(self: *KqueueMmapIO) void {
        self.* = undefined;
    }

    pub fn closeSocket(self: *KqueueMmapIO, fd: posix.fd_t) void {
        _ = self;
        posix.close(fd);
    }

    pub fn tick(self: *KqueueMmapIO, wait_at_least: u32) !void {
        _ = self;
        _ = wait_at_least;
    }

    pub fn socket(_: *KqueueMmapIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .socket = op }, .{ .socket = error.Unimplemented });
    }
    pub fn connect(_: *KqueueMmapIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .connect = op }, .{ .connect = error.Unimplemented });
    }
    pub fn accept(_: *KqueueMmapIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .accept = op }, .{ .accept = error.Unimplemented });
    }
    pub fn recv(_: *KqueueMmapIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .recv = op }, .{ .recv = error.Unimplemented });
    }
    pub fn send(_: *KqueueMmapIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .send = op }, .{ .send = error.Unimplemented });
    }
    pub fn recvmsg(_: *KqueueMmapIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .recvmsg = op }, .{ .recvmsg = error.Unimplemented });
    }
    pub fn sendmsg(_: *KqueueMmapIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .sendmsg = op }, .{ .sendmsg = error.Unimplemented });
    }
    pub fn timeout(_: *KqueueMmapIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .timeout = op }, .{ .timeout = error.Unimplemented });
    }
    pub fn poll(_: *KqueueMmapIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .poll = op }, .{ .poll = error.Unimplemented });
    }
    pub fn cancel(_: *KqueueMmapIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .cancel = op }, .{ .cancel = error.Unimplemented });
    }
    pub fn read(_: *KqueueMmapIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .read = op }, .{ .read = error.Unimplemented });
    }
    pub fn write(_: *KqueueMmapIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .write = op }, .{ .write = error.Unimplemented });
    }
    pub fn fsync(_: *KqueueMmapIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .fsync = op }, .{ .fsync = error.Unimplemented });
    }
    pub fn fallocate(_: *KqueueMmapIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .fallocate = op }, .{ .fallocate = error.Unimplemented });
    }
    pub fn truncate(_: *KqueueMmapIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        return stubDeliver(c, ud, cb, .{ .truncate = op }, .{ .truncate = error.Unimplemented });
    }
};

fn stubDeliver(c: *Completion, ud: ?*anyopaque, cb: Callback, op: Operation, result: Result) !void {
    c.op = op;
    c.userdata = ud;
    c.callback = cb;
    c.next = null;
    _ = cb(ud, c, result);
}

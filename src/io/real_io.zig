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
const ring_mod = @import("ring.zig");

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
    /// Per-op feature flags determined once via `IORING_REGISTER_PROBE`
    /// at init. Branch points consult this instead of doing version
    /// arithmetic on `uname(2)` so we pick up backports / custom
    /// kernels that compiled in newer ops without bumping their
    /// reported version.
    feature_support: ring_mod.FeatureSupport,

    pub fn init(config: Config) !RealIO {
        // Fall back to plain init if the kernel doesn't accept the requested
        // flags (e.g. COOP_TASKRUN / SINGLE_ISSUER on older kernels). Mirrors
        // the policy in `ring.zig:initIoUring`.
        var ring = linux.IoUring.init(config.entries, config.flags) catch
            try linux.IoUring.init(config.entries, 0);
        const features = ring_mod.probeFeatures(&ring);
        return .{ .ring = ring, .feature_support = features };
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
            .close => |op| try self.close(op, c, userdata, callback),
            .fallocate => |op| try self.fallocate(op, c, userdata, callback),
            .truncate => |op| try self.truncate(op, c, userdata, callback),
            .openat => |op| try self.openat(op, c, userdata, callback),
            .mkdirat => |op| try self.mkdirat(op, c, userdata, callback),
            .renameat => |op| try self.renameat(op, c, userdata, callback),
            .unlinkat => |op| try self.unlinkat(op, c, userdata, callback),
            .statx => |op| try self.statx(op, c, userdata, callback),
            .getdents => |op| try self.getdents(op, c, userdata, callback),
            .splice => |op| try self.splice(op, c, userdata, callback),
            .copy_file_range => |op| try self.copy_file_range(op, c, userdata, callback),
            .socket => |op| try self.socket(op, c, userdata, callback),
            .connect => |op| try self.connect(op, c, userdata, callback),
            .accept => |op| try self.accept(op, c, userdata, callback),
            .bind => |op| try self.bind(op, c, userdata, callback),
            .listen => |op| try self.listen(op, c, userdata, callback),
            .setsockopt => |op| try self.setsockopt(op, c, userdata, callback),
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

    pub fn close(self: *RealIO, op_in: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_close) {
            try self.armCompletion(c, .{ .close = op_in }, ud, cb);
            const sqe = try self.ring.close(@intFromPtr(c), op_in.fd);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .close = op }, ud, cb);
            const result: Result = .{ .close = closeFdResult(op.fd) };
            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .close => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    /// `IORING_OP_FALLOCATE` (kernel ≥5.6). The CQE delivers `0` on
    /// success or a negative errno on failure (NOSPC, IO, OPNOTSUPP, …).
    /// Some filesystems (tmpfs <5.10, FAT32, certain FUSE FSes) reject
    /// fallocate entirely with `EOPNOTSUPP`; callers that need a portable
    /// pre-allocation primitive must catch that and fall back.
    pub fn fallocate(self: *RealIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        const sqe = try self.ring.fallocate(@intFromPtr(c), op.fd, op.mode, op.offset, op.len);
        _ = sqe;
    }

    /// `truncate` dispatches based on the kernel's `IORING_OP_FTRUNCATE`
    /// support, probed once at `init` via `IORING_REGISTER_PROBE`:
    ///
    ///   * **Async path** (kernel ≥6.9, `feature_support.supports_ftruncate
    ///     == true`): submit `IORING_OP_FTRUNCATE` like any other ring op.
    ///     The CQE flows through `dispatchCqe` and `buildResult` returns
    ///     `voidOrError(cqe)` for `.truncate`. Matches the existing
    ///     `IORING_OP_FALLOCATE` shape exactly.
    ///
    ///   * **Sync path** (kernel <6.9, or any kernel where the probe
    ///     register itself is unsupported): fall back to a direct
    ///     `posix.ftruncate(2)` and fire the completion's callback
    ///     inline. In_flight is cleared before invoking the callback so
    ///     a callback that re-submits a new op on the same completion
    ///     doesn't trip `error.AlreadyInFlight` against itself
    ///     (mirrors `dispatchCqe`). `.rearm` is iterated via an inner
    ///     loop rather than recursing through `resubmit` to dodge the
    ///     inferred-error-set cycle that truncate→resubmit→truncate
    ///     would create.
    ///
    /// The only daemon caller is `PieceStore.init`'s filesystem-
    /// portability fallback (when fallocate returns
    /// `error.OperationNotSupported` on tmpfs <5.10, FAT32, certain FUSE
    /// FSes). That path already runs on a background thread (see
    /// `doStartBackground` in `src/daemon/torrent_session.zig`), so the
    /// sync fallback has zero event-loop-thread impact when it fires.
    pub fn truncate(self: *RealIO, op_in: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_ftruncate) {
            try self.armCompletion(c, .{ .truncate = op_in }, ud, cb);
            const sqe = try self.ring.get_sqe();
            // `IORING_OP_FTRUNCATE` (kernel 6.9+) takes the new file
            // length in `sqe->off`; addr/len/rw_flags/buf_index/
            // splice_fd_in must all be zero or the kernel returns
            // EINVAL. `prep_rw(.FTRUNCATE, fd, addr=0, len=0,
            // offset=length)` produces exactly that shape.
            sqe.prep_rw(.FTRUNCATE, op_in.fd, 0, 0, op_in.length);
            sqe.user_data = @intFromPtr(c);
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .truncate = op }, ud, cb);

            const result: Result = if (posix.ftruncate(op.fd, op.length)) |_|
                .{ .truncate = {} }
            else |err|
                .{ .truncate = err };

            // Clear in_flight before invoking the callback (mirrors
            // dispatchCqe — see the Operation doc-comment in
            // io_interface.zig).
            realState(c).in_flight = false;

            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .truncate => |new_op| op = new_op,
                    else => return, // callback overwrote c.op with a different op (illegal under the contract)
                },
            }
        }
    }

    /// `openat` dispatches through `IORING_OP_OPENAT` when the runtime
    /// probe reports support (kernel ≥5.6), otherwise it falls back to
    /// `posix.openat(2)` and fires the callback inline. The async path
    /// requires a sentinel-terminated path owned by the caller until CQE.
    pub fn openat(self: *RealIO, op_in: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_openat) {
            try self.armCompletion(c, .{ .openat = op_in }, ud, cb);
            const stored = &c.op.openat;
            const sqe = try self.ring.openat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.flags, stored.mode);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .openat = op }, ud, cb);
            const result: Result = if (posix.openat(op.dir_fd, op.path, op.flags, op.mode)) |fd|
                .{ .openat = fd }
            else |err|
                .{ .openat = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .openat => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    pub fn mkdirat(self: *RealIO, op_in: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_mkdirat) {
            try self.armCompletion(c, .{ .mkdirat = op_in }, ud, cb);
            const stored = &c.op.mkdirat;
            const sqe = try self.ring.mkdirat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.mode);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .mkdirat = op }, ud, cb);
            const result: Result = if (posix.mkdirat(op.dir_fd, op.path, op.mode)) |_|
                .{ .mkdirat = {} }
            else |err|
                .{ .mkdirat = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .mkdirat => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    pub fn renameat(self: *RealIO, op_in: ifc.RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_renameat) {
            try self.armCompletion(c, .{ .renameat = op_in }, ud, cb);
            const stored = &c.op.renameat;
            const sqe = try self.ring.renameat(
                @intFromPtr(c),
                stored.old_dir_fd,
                stored.old_path.ptr,
                stored.new_dir_fd,
                stored.new_path.ptr,
                stored.flags,
            );
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .renameat = op }, ud, cb);
            const result: Result = if (op.flags != 0)
                .{ .renameat = error.OperationNotSupported }
            else if (posix.renameat(op.old_dir_fd, op.old_path, op.new_dir_fd, op.new_path)) |_|
                .{ .renameat = {} }
            else |err|
                .{ .renameat = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .renameat => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    pub fn unlinkat(self: *RealIO, op_in: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_unlinkat) {
            try self.armCompletion(c, .{ .unlinkat = op_in }, ud, cb);
            const stored = &c.op.unlinkat;
            const sqe = try self.ring.unlinkat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.flags);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .unlinkat = op }, ud, cb);
            const result: Result = if (posix.unlinkat(op.dir_fd, op.path, op.flags)) |_|
                .{ .unlinkat = {} }
            else |err|
                .{ .unlinkat = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .unlinkat => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    pub fn statx(self: *RealIO, op_in: ifc.StatxOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_statx) {
            try self.armCompletion(c, .{ .statx = op_in }, ud, cb);
            const stored = &c.op.statx;
            const sqe = try self.ring.statx(
                @intFromPtr(c),
                stored.dir_fd,
                stored.path,
                stored.flags,
                stored.mask,
                stored.buf,
            );
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .statx = op }, ud, cb);
            const rc = linux.statx(op.dir_fd, op.path, op.flags, op.mask, op.buf);
            const result: Result = switch (linux.E.init(rc)) {
                .SUCCESS => .{ .statx = {} },
                else => |err| .{ .statx = errnoToError(err) },
            };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .statx => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    pub fn getdents(self: *RealIO, op_in: ifc.GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .getdents = op }, ud, cb);
            const rc = linux.getdents64(op.fd, op.buf.ptr, op.buf.len);
            const result: Result = switch (linux.E.init(rc)) {
                .SUCCESS => .{ .getdents = rc },
                else => |err| .{ .getdents = errnoToError(err) },
            };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .getdents => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    /// `IORING_OP_SPLICE` — kernel ≥5.7. Varuna's floor is 6.6 ⇒ always
    /// available on supported kernels. The kernel signals the special
    /// "fd is a pipe; ignore offset" sentinel via `std.math.maxInt(u64)`
    /// in the offset field; that contract is what the io_uring helper
    /// already expects so we pass through unchanged.
    pub fn splice(self: *RealIO, op: ifc.SpliceOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .splice = op }, ud, cb);
        const sqe = try self.ring.splice(@intFromPtr(c), op.in_fd, op.in_offset, op.out_fd, op.out_offset, op.len);
        if (op.flags != 0) sqe.rw_flags = @bitCast(op.flags);
    }

    /// `copy_file_range(2)` — no native io_uring op exists as of kernel
    /// 6.x. Submitting a thread-pool offload from the EL is overkill
    /// for the only daemon caller (the async MoveJob), which already
    /// runs the syscall on its own worker thread. The contract op is
    /// implemented for completeness with a synchronous-inline fallback;
    /// callers that submit it from the EL thread accept the resulting
    /// stall.
    pub fn copy_file_range(self: *RealIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_range = op }, ud, cb);
        const result: Result = blk: {
            var off_in: i64 = @bitCast(op.in_offset);
            var off_out: i64 = @bitCast(op.out_offset);
            const rc = linux.copy_file_range(op.in_fd, &off_in, op.out_fd, &off_out, op.len, op.flags);
            switch (linux.E.init(rc)) {
                .SUCCESS => break :blk .{ .copy_file_range = @as(usize, @intCast(rc)) },
                .BADF => break :blk .{ .copy_file_range = error.BadFileDescriptor },
                .INVAL => break :blk .{ .copy_file_range = error.InvalidArgument },
                .XDEV, .NOSYS, .OPNOTSUPP => break :blk .{ .copy_file_range = error.OperationNotSupported },
                .IO => break :blk .{ .copy_file_range = error.InputOutput },
                .NOSPC => break :blk .{ .copy_file_range = error.NoSpaceLeft },
                .ISDIR => break :blk .{ .copy_file_range = error.IsDir },
                .OVERFLOW => break :blk .{ .copy_file_range = error.FileTooBig },
                else => |e| break :blk .{ .copy_file_range = posix.unexpectedErrno(e) },
            }
        };
        // Mirror the truncate sync-fallback shape — clear in_flight
        // before invoking the callback so a callback that re-submits a
        // new op on the same completion doesn't trip AlreadyInFlight.
        realState(c).in_flight = false;
        const action = cb(ud, c, result);
        switch (action) {
            .disarm => return,
            // Honor .rearm only for the same op kind (mirrors truncate).
            .rearm => switch (c.op) {
                .copy_file_range => |new_op| try self.copy_file_range(new_op, c, ud, cb),
                else => return,
            },
        }
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

    /// `bind` dispatches based on the kernel's `IORING_OP_BIND` support,
    /// probed at init via `IORING_REGISTER_PROBE`:
    ///
    ///   * **Async path** (kernel ≥6.11, `feature_support.supports_bind
    ///     == true`): submit `IORING_OP_BIND`. The CQE flows through
    ///     `dispatchCqe` and `buildResult` returns `voidOrError(cqe)`
    ///     for `.bind`. The `BindOp.addr` value lives inside
    ///     `Completion.op` (a tagged-union variant), so its address is
    ///     stable while the SQE is in flight — the kernel reads
    ///     `addr.any` asynchronously.
    ///
    ///   * **Sync path** (kernel <6.11): fall back to `posix.bind(2)`
    ///     and fire the callback inline. Mirrors the `truncate`
    ///     fallback shape — clears `in_flight` before invoking the
    ///     callback so a callback that re-submits a new op on the same
    ///     completion doesn't trip `error.AlreadyInFlight` against
    ///     itself, and uses an inner loop rather than recursing through
    ///     `resubmit` to dodge the inferred-error-set cycle.
    ///
    /// Daemon callers today are listen-socket bring-up paths
    /// (`event_loop.zig` peer / uTP listeners, `rpc/server.zig` API
    /// listener). Those run once at startup; the operational gain from
    /// async dispatch is small (bind is a fast in-kernel op with no I/O
    /// wait) but routing through the contract method gives uniform
    /// FeatureSupport-gated behaviour and primes the path for any
    /// future runtime rebind.
    pub fn bind(self: *RealIO, op_in: ifc.BindOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_bind) {
            try self.armCompletion(c, .{ .bind = op_in }, ud, cb);
            // The op is now stored inside `c.op.bind`; read the addr
            // from there so the pointer the kernel sees outlives this
            // function. (Reading from `op_in` would be wrong: that's a
            // by-value parameter on the stack.)
            const stored = &c.op.bind;
            const addrlen = stored.addr.getOsSockLen();
            const sqe = try self.ring.bind(@intFromPtr(c), stored.fd, &stored.addr.any, addrlen, 0);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .bind = op }, ud, cb);

            const result: Result = if (posix.bind(op.fd, &op.addr.any, op.addr.getOsSockLen())) |_|
                .{ .bind = {} }
            else |err|
                .{ .bind = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .bind => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    /// `listen` mirrors `bind`: branches on
    /// `feature_support.supports_listen` (kernel ≥6.11 →
    /// `IORING_OP_LISTEN`, else `posix.listen(2)` inline).
    pub fn listen(self: *RealIO, op_in: ifc.ListenOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_listen) {
            try self.armCompletion(c, .{ .listen = op_in }, ud, cb);
            const sqe = try self.ring.listen(@intFromPtr(c), op_in.fd, op_in.backlog, 0);
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .listen = op }, ud, cb);

            const result: Result = if (posix.listen(op.fd, op.backlog)) |_|
                .{ .listen = {} }
            else |err|
                .{ .listen = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .listen => |new_op| op = new_op,
                    else => return,
                },
            }
        }
    }

    /// `setsockopt` dispatches based on `feature_support.supports_setsockopt`,
    /// which corresponds to `IORING_OP_URING_CMD` support (the carrier
    /// op for the `SOCKET_URING_OP_SETSOCKOPT` subcmd, kernel ≥6.7):
    ///
    ///   * **Async path** (URING_CMD supported): submit a `URING_CMD`
    ///     SQE with the `SETSOCKOPT` subcmd via `IoUring.setsockopt`.
    ///     The kernel reads the `optval` buffer asynchronously, so the
    ///     caller MUST keep the slice alive until the callback fires.
    ///     Storing it in `c.op.setsockopt.optval` (the tagged-union
    ///     variant inside the completion) gives the right lifetime.
    ///     Note: `supports_setsockopt = true` is a *necessary* condition
    ///     for the SETSOCKOPT subcmd but not sufficient — the kernel may
    ///     still return `ENOTSUP`/`EINVAL` for the subcmd itself if it
    ///     pre-dates 6.7. Callers must handle that at completion time.
    ///
    ///   * **Sync path** (URING_CMD unsupported): fall back to
    ///     `posix.setsockopt(2)` inline. Same loop+rearm shape as
    ///     `bind`/`listen`/`truncate`.
    pub fn setsockopt(self: *RealIO, op_in: ifc.SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_setsockopt) {
            try self.armCompletion(c, .{ .setsockopt = op_in }, ud, cb);
            const stored = &c.op.setsockopt;
            const sqe = try self.ring.setsockopt(
                @intFromPtr(c),
                stored.fd,
                stored.level,
                stored.optname,
                stored.optval,
            );
            _ = sqe;
            return;
        }

        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .setsockopt = op }, ud, cb);

            const result: Result = if (posix.setsockopt(op.fd, @intCast(op.level), op.optname, op.optval)) |_|
                .{ .setsockopt = {} }
            else |err|
                .{ .setsockopt = err };

            realState(c).in_flight = false;
            const action = cb(ud, c, result);
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .setsockopt => |new_op| op = new_op,
                    else => return,
                },
            }
        }
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
        .close => .{ .close = voidOrError(cqe) },
        .fallocate => .{ .fallocate = voidOrError(cqe) },
        // On kernels with `IORING_OP_FTRUNCATE` support
        // (`feature_support.supports_ftruncate == true`), truncate flows
        // through the ring exactly like fallocate/fsync — the CQE
        // carries either 0 (success) or a negative errno. On older
        // kernels truncate completes synchronously inside
        // `RealIO.truncate` and never reaches `dispatchCqe`, so this
        // branch is unreachable in that case.
        .truncate => .{ .truncate = voidOrError(cqe) },
        .openat => .{ .openat = fdOrError(cqe) },
        .mkdirat => .{ .mkdirat = voidOrError(cqe) },
        .renameat => .{ .renameat = voidOrError(cqe) },
        .unlinkat => .{ .unlinkat = voidOrError(cqe) },
        .statx => .{ .statx = voidOrError(cqe) },
        // getdents completes synchronously inside `RealIO.getdents` because
        // Zig 0.15.2 exposes no io_uring getdents helper/op.
        .getdents => .{ .getdents = countOrError(cqe) },
        .splice => .{ .splice = countOrError(cqe) },
        // copy_file_range completes synchronously inside `RealIO.copy_file_range`
        // and never reaches `dispatchCqe`; keep a shaped variant for
        // exhaustiveness so the union switch stays total.
        .copy_file_range => .{ .copy_file_range = countOrError(cqe) },
        .socket => .{ .socket = fdOrError(cqe) },
        .connect => .{ .connect = voidOrError(cqe) },
        .accept => .{ .accept = acceptResult(cqe) },
        // Bind / listen / setsockopt either come back from the async
        // ring (kernel ≥6.11 for bind/listen, ≥6.7 for setsockopt) or
        // never reach `dispatchCqe` because the sync fallback fired the
        // callback inline. Either way, when the CQE *does* land we
        // translate it the same way as fallocate / fsync — `0` on
        // success, negative errno on failure.
        .bind => .{ .bind = voidOrError(cqe) },
        .listen => .{ .listen = voidOrError(cqe) },
        .setsockopt => .{ .setsockopt = voidOrError(cqe) },
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

fn closeFdResult(fd: posix.fd_t) anyerror!void {
    const rc = linux.close(fd);
    return switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => |e| errnoToError(e),
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
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .NOTDIR => error.NotDir,
        .ALREADY => error.AlreadyCompleted,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .NOSYS => error.OperationNotSupported,
        .XDEV => error.RenameAcrossMountPoints,
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

test "RealIO truncate extends a tempfile via the runtime-detected path" {
    // Truncate dispatches at runtime based on
    // `feature_support.supports_ftruncate` (probed at init via
    // IORING_REGISTER_PROBE). On kernel ≥6.9 it submits
    // `IORING_OP_FTRUNCATE` and the CQE flows through dispatchCqe
    // (test must `tick(1)`). On older kernels it falls back to a
    // synchronous `posix.ftruncate(2)` and fires the callback inline
    // (no tick needed). This test handles both paths and confirms the
    // fd's size matches the requested length either way.
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("truncate_test", .{ .truncate = true });
    defer file.close();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(.{ .fd = file.handle, .length = 4096 }, &c, &ctx, testCallback);

    if (ctx.calls == 0) {
        // Async path: callback fires from the CQE, drive one tick.
        try io.tick(1);
    }

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }

    // Verify the file actually grew to 4 KiB.
    const stat = try posix.fstat(file.handle);
    try testing.expectEqual(@as(@TypeOf(stat.size), 4096), stat.size);
}

test "RealIO truncate via async path (kernel ≥6.9 only)" {
    // Skip when the running kernel doesn't support IORING_OP_FTRUNCATE.
    // Otherwise force-confirm the SQE-submission path: the callback
    // must NOT have fired before `tick(1)` because the async path
    // delegates completion to the kernel.
    var io = try skipIfUnavailable();
    defer io.deinit();

    if (!io.feature_support.supports_ftruncate) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("truncate_async_test", .{ .truncate = true });
    defer file.close();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(.{ .fd = file.handle, .length = 8192 }, &c, &ctx, testCallback);

    // Async submission must NOT have completed yet.
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }

    const stat = try posix.fstat(file.handle);
    try testing.expectEqual(@as(@TypeOf(stat.size), 8192), stat.size);
}

test "RealIO truncate shrinks file via async path" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    if (!io.feature_support.supports_ftruncate) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("truncate_shrink", .{ .truncate = true });
    defer file.close();
    _ = try posix.write(file.handle, "0123456789"); // 10 bytes

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(.{ .fd = file.handle, .length = 4 }, &c, &ctx, testCallback);
    try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }
    const stat = try posix.fstat(file.handle);
    try testing.expectEqual(@as(@TypeOf(stat.size), 4), stat.size);
}

test "RealIO bind on a fresh socket via the runtime-detected path" {
    // Mirror of the truncate test: the bind path branches on
    // `feature_support.supports_bind`. On 6.11+ kernels we submit
    // IORING_OP_BIND; the CQE flows through dispatchCqe and the test
    // must `tick(1)`. On older kernels the synchronous fallback fires
    // the callback inline and no tick is needed. Either way the bind
    // must succeed against an ephemeral 127.0.0.1:0 address.
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);

    var c = Completion{};
    var ctx = TestCtx{};
    try io.bind(.{ .fd = fd, .addr = addr }, &c, &ctx, testCallback);
    if (ctx.calls == 0) try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .bind => |r| try r,
        else => try testing.expect(false),
    }
}

test "RealIO bind delivers EADDRINUSE for double-bind via async path" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    if (!io.feature_support.supports_bind) return error.SkipZigTest;

    // Take an ephemeral port via a synchronous bind so we have a
    // concrete `:port` address that's guaranteed in use, then try to
    // bind a second socket to it via the async ring path.
    const taker = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(taker);
    const ephemeral = try std.net.Address.parseIp4("127.0.0.1", 0);
    try posix.bind(taker, &ephemeral.any, ephemeral.getOsSockLen());

    var taken_addr: posix.sockaddr = undefined;
    var taken_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(taker, &taken_addr, &taken_len);
    const concrete = std.net.Address{ .any = taken_addr };

    const second = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(second);
    var c = Completion{};
    var ctx = TestCtx{};
    try io.bind(.{ .fd = second, .addr = concrete }, &c, &ctx, testCallback);
    try testing.expectEqual(@as(u32, 0), ctx.calls); // async: no inline fire
    try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .bind => |r| try testing.expectError(error.AddressInUse, r),
        else => try testing.expect(false),
    }
}

test "RealIO listen on a bound socket via the runtime-detected path" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());

    var c = Completion{};
    var ctx = TestCtx{};
    try io.listen(.{ .fd = fd, .backlog = 16 }, &c, &ctx, testCallback);
    if (ctx.calls == 0) try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .listen => |r| try r,
        else => try testing.expect(false),
    }
}

test "RealIO setsockopt SO_REUSEADDR via the runtime-detected path" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const enable = std.mem.toBytes(@as(c_int, 1));
    var c = Completion{};
    var ctx = TestCtx{};
    try io.setsockopt(.{
        .fd = fd,
        .level = posix.SOL.SOCKET,
        .optname = posix.SO.REUSEADDR,
        .optval = &enable,
    }, &c, &ctx, testCallback);
    if (ctx.calls == 0) try io.tick(1);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        // URING_CMD setsockopt may surface ENOTSUP / EINVAL when the
        // kernel supports URING_CMD but not the SETSOCKOPT subcmd
        // (probe gives a necessary but not sufficient signal — see
        // FeatureSupport.supports_setsockopt). Accept either success
        // or those two specific errors.
        .setsockopt => |r| r catch |e| switch (e) {
            error.OperationNotSupported, error.InvalidArgument => {},
            else => return e,
        },
        else => try testing.expect(false),
    }
}

test "bindBlocking helper round-trips on RealIO" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);

    try ifc.bindBlocking(&io, .{ .fd = fd, .addr = addr });
    try ifc.listenBlocking(&io, .{ .fd = fd, .backlog = 8 });

    // Confirm the socket is in LISTEN by trying to connect from a
    // sibling client socket.
    var taken_addr: posix.sockaddr = undefined;
    var taken_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(fd, &taken_addr, &taken_len);
    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &taken_addr, taken_len);
}

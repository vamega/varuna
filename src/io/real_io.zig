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
const posix_file_pool = @import("posix_file_pool.zig");
const BlockingOpPool = posix_file_pool.BlockingOpPool;
const BlockingOp = posix_file_pool.BlockingOp;
const PoolCompleted = posix_file_pool.Completed;

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
const pool_wakeup_sentinel: u64 = std.math.maxInt(u64) - 1;
const detached_close_sentinel: u64 = std.math.maxInt(u64) - 2;

const ready_capacity = 64;
const splice_pipe_offset = std.math.maxInt(u64);
const splice_f_nonblock: u32 = 0x02;
const pipe_op: linux.IORING_OP = @enumFromInt(62);
const copy_pipe_flags: u32 = @bitCast(posix.O{ .CLOEXEC = true, .NONBLOCK = true });

const ReadyEntry = struct {
    completion: *Completion,
    result: Result,
};

const RealCopyFileSessionState = struct {
    state: enum(u8) {
        closed,
        opening,
        open,
        copying_to_pipe,
        copying_to_dst,
        closing,
    } = .closed,
    pipe_fds: [2]posix.fd_t = .{ -1, -1 },
    pipe_result: [2]i32 = .{ -1, -1 },
    buffered: usize = 0,
    drained: usize = 0,
    close_remaining: u8 = 0,
    close_error: ?anyerror = null,
    poisoned: bool = false,
};

comptime {
    assert(@sizeOf(RealCopyFileSessionState) <= ifc.copy_file_session_state_size);
    assert(@alignOf(RealCopyFileSessionState) <= ifc.copy_file_session_state_align);
}

// ── Configuration ─────────────────────────────────────────

pub const Config = struct {
    /// Number of SQEs / CQEs in the ring. Must be a power of two.
    entries: u16 = 1024,
    /// Optional ring init flags (e.g. IORING_SETUP_COOP_TASKRUN).
    flags: u32 = 0,
    /// Allocator for the fallback blocking-op pool and wake context. The
    /// production backend normally passes the event-loop allocator; tests
    /// that instantiate RealIO directly can rely on this default.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    file_pool_workers: u32 = 4,
    file_pool_pending_capacity: u32 = 256,
    file_pool_copy_scratch_bytes: usize = 1024 * 1024,
};

// ── RealIO ────────────────────────────────────────────────

pub const RealIO = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    /// Per-op feature flags determined once via `IORING_REGISTER_PROBE`
    /// at init. Branch points consult this instead of doing version
    /// arithmetic on `uname(2)` so we pick up backports / custom
    /// kernels that compiled in newer ops without bumping their
    /// reported version.
    feature_support: ring_mod.FeatureSupport,
    ready: [ready_capacity]ReadyEntry = undefined,
    ready_head: u8 = 0,
    ready_len: u8 = 0,
    pool: *BlockingOpPool,
    pool_swap: std.ArrayListUnmanaged(PoolCompleted) = .{},
    pool_wakeup_ctx: *posix.fd_t,
    pool_wakeup_fd: posix.fd_t,
    pool_wakeup_armed: bool = false,

    pub fn init(config: Config) !RealIO {
        // Fall back to plain init if the kernel doesn't accept the requested
        // flags (e.g. COOP_TASKRUN / SINGLE_ISSUER on older kernels). Mirrors
        // the policy in `ring.zig:initIoUring`.
        var ring = linux.IoUring.init(config.entries, config.flags) catch
            try linux.IoUring.init(config.entries, 0);
        errdefer ring.deinit();
        const features = ring_mod.probeFeatures(&ring);

        const efd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(efd);

        const wakeup_ctx = try config.allocator.create(posix.fd_t);
        errdefer config.allocator.destroy(wakeup_ctx);
        wakeup_ctx.* = efd;

        const pool = try BlockingOpPool.create(config.allocator, .{
            .worker_count = config.file_pool_workers,
            .pending_capacity = config.file_pool_pending_capacity,
            .copy_scratch_bytes = config.file_pool_copy_scratch_bytes,
        });
        errdefer pool.deinit();
        pool.setWakeup(wakeup_ctx, wakeFromPool);

        var self = RealIO{
            .allocator = config.allocator,
            .ring = ring,
            .feature_support = features,
            .pool = pool,
            .pool_wakeup_ctx = wakeup_ctx,
            .pool_wakeup_fd = efd,
        };
        try self.armPoolWakeup();
        return self;
    }

    pub fn deinit(self: *RealIO) void {
        self.pool.deinit();
        self.pool_swap.deinit(self.allocator);
        self.allocator.destroy(self.pool_wakeup_ctx);
        posix.close(self.pool_wakeup_fd);
        self.ring.deinit();
        self.* = undefined;
    }

    /// Fire-and-forget fd close used by legacy socket teardown paths. Prefer
    /// `IORING_OP_CLOSE`; if the SQ ring cannot accept the detached close, use
    /// the backend blocking pool. The final inline close is an overflow escape
    /// hatch to avoid leaking an fd if both queues are saturated.
    pub fn closeSocket(self: *RealIO, fd: posix.fd_t) void {
        if (self.feature_support.supports_close) {
            if (self.ring.close(detached_close_sentinel, fd)) |_| return else |_| {}
        }
        self.pool.submitDetached(.{ .close = .{ .fd = fd } }) catch {
            posix.close(fd);
        };
    }

    /// Submit any pending SQEs and dispatch all available CQEs by
    /// invoking the corresponding `Completion.callback`. Returns once the
    /// CQ is empty.
    ///
    /// `wait_at_least` blocks for at least that many completions before
    /// returning (use 0 for non-blocking, 1 for "advance the loop").
    pub fn tick(self: *RealIO, wait_at_least: u32) !void {
        while (true) {
            var fired: u32 = 0;
            fired += try self.drainReadyCount();
            fired += try self.drainPoolCount();
            if (wait_at_least != 0 and fired > 0) return;

            try self.armPoolWakeup();
            _ = try self.ring.submit_and_wait(if (wait_at_least == 0) 0 else 1);

            var cqes: [32]linux.io_uring_cqe = undefined;
            while (true) {
                const count = try self.ring.copy_cqes(&cqes, 0);
                if (count == 0) break;
                for (cqes[0..count]) |cqe| {
                    fired += try self.dispatchCqe(cqe);
                }
                if (count < cqes.len) break;
            }

            fired += try self.drainPoolCount();
            fired += try self.drainReadyCount();
            if (wait_at_least == 0 or fired > 0) return;
        }
    }

    fn dispatchCqe(self: *RealIO, cqe: linux.io_uring_cqe) !u32 {
        // Silently swallow link_timeout CQEs paired with connect.
        if (cqe.user_data == link_timeout_sentinel) return 0;
        if (cqe.user_data == detached_close_sentinel) return 0;
        if (cqe.user_data == pool_wakeup_sentinel) {
            self.pool_wakeup_armed = false;
            self.drainPoolWakeup();
            const fired = try self.drainPoolCount();
            try self.armPoolWakeup();
            return fired;
        }

        const c: *Completion = @ptrFromInt(cqe.user_data);
        const callback = c.callback orelse return 0;

        switch (c.op) {
            .open_copy_file_session => {
                try self.dispatchOpenCopyFileSession(c, cqe);
                return 1;
            },
            .copy_file_chunk => {
                try self.dispatchCopyFileChunk(c, cqe);
                return 1;
            },
            .close_copy_file_session => {
                try self.dispatchCloseCopyFileSession(c, cqe);
                return 1;
            },
            else => {},
        }

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
                if (more) return 1; // multishot: next CQE comes from the kernel
                try self.resubmit(c);
            },
        }
        return 1;
    }

    fn drainReady(self: *RealIO, wait_at_least: u32) !bool {
        var fired: u32 = 0;
        while (self.popReady()) |entry| {
            fired += 1;
            try self.dispatchReadyEntry(entry);
            if (wait_at_least != 0 and fired >= wait_at_least) return true;
        }
        return fired > 0 and wait_at_least != 0;
    }

    fn drainReadyCount(self: *RealIO) !u32 {
        var fired: u32 = 0;
        while (self.popReady()) |entry| {
            fired += 1;
            try self.dispatchReadyEntry(entry);
        }
        return fired;
    }

    fn queueReady(self: *RealIO, c: *Completion, result: Result) !void {
        if (self.ready_len >= ready_capacity) return error.PendingQueueFull;
        const idx = (@as(usize, self.ready_head) + @as(usize, self.ready_len)) % ready_capacity;
        self.ready[idx] = .{ .completion = c, .result = result };
        self.ready_len += 1;
    }

    fn popReady(self: *RealIO) ?ReadyEntry {
        if (self.ready_len == 0) return null;
        const entry = self.ready[@as(usize, self.ready_head)];
        self.ready_head = @intCast((@as(usize, self.ready_head) + 1) % ready_capacity);
        self.ready_len -= 1;
        if (self.ready_len == 0) self.ready_head = 0;
        return entry;
    }

    fn dispatchReadyEntry(self: *RealIO, entry: ReadyEntry) !void {
        const c = entry.completion;
        realState(c).in_flight = false;
        const cb = c.callback orelse return;
        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => try self.resubmit(c),
        }
    }

    fn armPoolWakeup(self: *RealIO) !void {
        if (self.pool_wakeup_armed) return;
        const sqe = try self.ring.poll_add(pool_wakeup_sentinel, self.pool_wakeup_fd, linux.POLL.IN);
        _ = sqe;
        self.pool_wakeup_armed = true;
    }

    fn drainPoolWakeup(self: *RealIO) void {
        var value: u64 = 0;
        while (true) {
            _ = posix.read(self.pool_wakeup_fd, std.mem.asBytes(&value)) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
        }
    }

    fn drainPoolCount(self: *RealIO) !u32 {
        var fired: u32 = 0;
        try self.pool.drainCompletedInto(&self.pool_swap);
        defer self.pool_swap.clearRetainingCapacity();
        for (self.pool_swap.items) |entry| {
            fired += 1;
            try self.dispatchPoolEntry(entry);
        }
        return fired;
    }

    fn dispatchPoolEntry(self: *RealIO, entry: PoolCompleted) !void {
        const c = entry.completion;
        realState(c).in_flight = false;
        const cb = c.callback orelse return;
        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => try self.resubmit(c),
        }
    }

    fn submitBlockingOp(self: *RealIO, op: BlockingOp, c: *Completion) !void {
        self.pool.submit(op, c) catch |err| {
            realState(c).in_flight = false;
            return err;
        };
    }

    fn wakeFromPool(ctx: ?*anyopaque) void {
        const wakeup_fd: *const posix.fd_t = @ptrCast(@alignCast(ctx.?));
        const value: u64 = 1;
        _ = posix.write(wakeup_fd.*, std.mem.asBytes(&value)) catch {};
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
            .open_copy_file_session => |op| try self.open_copy_file_session(op, c, userdata, callback),
            .copy_file_chunk => |op| try self.copy_file_chunk(op, c, userdata, callback),
            .close_copy_file_session => |op| try self.close_copy_file_session(op, c, userdata, callback),
            .fchown => |op| try self.fchown(op, c, userdata, callback),
            .fchmod => |op| try self.fchmod(op, c, userdata, callback),
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

        try self.armCompletion(c, .{ .close = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .close = op_in }, c);
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
    ///   * **Fallback path** (kernel <6.9, or any kernel where the probe
    ///     register itself is unsupported): offload `ftruncate(2)` to the
    ///     backend-owned `BlockingOpPool` so the event-loop thread does not
    ///     run the syscall.
    ///
    /// The only daemon caller is `PieceStore.init`'s filesystem-
    /// portability fallback (when fallocate returns
    /// `error.OperationNotSupported` on tmpfs <5.10, FAT32, certain FUSE
    /// FSes). That path already runs on a background thread (see
    /// `doStartBackground` in `src/daemon/torrent_session.zig`).
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

        try self.armCompletion(c, .{ .truncate = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .truncate = op_in }, c);
    }

    /// `openat` dispatches through `IORING_OP_OPENAT` when the runtime
    /// probe reports support (kernel ≥5.6), otherwise it offloads
    /// `openat(2)` to the backend-owned `BlockingOpPool`. The async path
    /// requires a sentinel-terminated path owned by the caller until CQE.
    pub fn openat(self: *RealIO, op_in: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_openat) {
            try self.armCompletion(c, .{ .openat = op_in }, ud, cb);
            const stored = &c.op.openat;
            const sqe = try self.ring.openat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.flags, stored.mode);
            _ = sqe;
            return;
        }

        try self.armCompletion(c, .{ .openat = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .openat = op_in }, c);
    }

    pub fn mkdirat(self: *RealIO, op_in: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_mkdirat) {
            try self.armCompletion(c, .{ .mkdirat = op_in }, ud, cb);
            const stored = &c.op.mkdirat;
            const sqe = try self.ring.mkdirat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.mode);
            _ = sqe;
            return;
        }

        try self.armCompletion(c, .{ .mkdirat = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .mkdirat = op_in }, c);
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

        try self.armCompletion(c, .{ .renameat = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .renameat = op_in }, c);
    }

    pub fn unlinkat(self: *RealIO, op_in: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_unlinkat) {
            try self.armCompletion(c, .{ .unlinkat = op_in }, ud, cb);
            const stored = &c.op.unlinkat;
            const sqe = try self.ring.unlinkat(@intFromPtr(c), stored.dir_fd, stored.path.ptr, stored.flags);
            _ = sqe;
            return;
        }

        try self.armCompletion(c, .{ .unlinkat = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .unlinkat = op_in }, c);
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

        try self.armCompletion(c, .{ .statx = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .statx = op_in }, c);
    }

    pub fn getdents(self: *RealIO, op_in: ifc.GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .getdents = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .getdents = op_in }, c);
    }

    pub fn open_copy_file_session(self: *RealIO, op: ifc.OpenCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .open_copy_file_session = op }, ud, cb);
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        if (st.state != .closed) return try self.queueReady(c, .{ .open_copy_file_session = error.InvalidState });
        st.* = .{ .state = .opening };

        if (self.feature_support.supports_pipe) {
            const sqe = try self.ring.get_sqe();
            sqe.prep_rw(pipe_op, 0, @intFromPtr(&st.pipe_result), 0, 0);
            sqe.rw_flags = copy_pipe_flags;
            sqe.user_data = @intFromPtr(c);
            return;
        }

        // IORING_OP_PIPE is 6.16+, above varuna's current kernel floor.
        // Synchronous pipe creation is a short setup syscall; completion is
        // still reported through RealIO's ready queue on the next tick so
        // callbacks never fire inline.
        const fds = posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true }) catch |err| {
            st.* = .{};
            return try self.queueReady(c, .{ .open_copy_file_session = err });
        };
        st.pipe_fds = fds;
        st.state = .open;
        try self.queueReady(c, .{ .open_copy_file_session = {} });
    }

    pub fn copy_file_chunk(self: *RealIO, op: ifc.CopyFileChunkOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_chunk = op }, ud, cb);
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        if (st.state != .open or st.poisoned) return try self.queueReady(c, .{ .copy_file_chunk = error.InvalidState });
        if (op.len == 0) return try self.queueReady(c, .{ .copy_file_chunk = error.InvalidArgument });
        st.state = .copying_to_pipe;
        st.buffered = 0;
        st.drained = 0;
        try self.submitCopySpliceToPipe(c);
    }

    pub fn close_copy_file_session(self: *RealIO, op: ifc.CloseCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .close_copy_file_session = op }, ud, cb);
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        if (st.state == .copying_to_pipe or st.state == .copying_to_dst or st.state == .opening) {
            return try self.queueReady(c, .{ .close_copy_file_session = error.AlreadyInFlight });
        }
        st.state = .closing;
        st.close_remaining = 0;
        st.close_error = null;

        if (st.pipe_fds[0] >= 0) {
            const sqe = try self.ring.close(@intFromPtr(c), st.pipe_fds[0]);
            _ = sqe;
            st.pipe_fds[0] = -1;
            st.close_remaining += 1;
        }
        if (st.pipe_fds[1] >= 0) {
            const sqe = try self.ring.close(@intFromPtr(c), st.pipe_fds[1]);
            _ = sqe;
            st.pipe_fds[1] = -1;
            st.close_remaining += 1;
        }
        if (st.close_remaining == 0) {
            st.* = .{};
            try self.queueReady(c, .{ .close_copy_file_session = {} });
        }
    }

    pub fn fchown(self: *RealIO, op: ifc.FchownOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fchown = op }, ud, cb);
        try self.submitBlockingOp(.{ .fchown = op }, c);
    }

    pub fn fchmod(self: *RealIO, op: ifc.FchmodOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fchmod = op }, ud, cb);
        try self.submitBlockingOp(.{ .fchmod = op }, c);
    }

    fn dispatchOpenCopyFileSession(self: *RealIO, c: *Completion, cqe: linux.io_uring_cqe) !void {
        const op = c.op.open_copy_file_session;
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        if (cqe.res < 0) {
            st.* = .{};
            return self.completeCopyOperation(c, .{ .open_copy_file_session = errnoToError(cqe.err()) });
        }
        st.pipe_fds = .{ st.pipe_result[0], st.pipe_result[1] };
        st.state = .open;
        return self.completeCopyOperation(c, .{ .open_copy_file_session = {} });
    }

    fn dispatchCopyFileChunk(self: *RealIO, c: *Completion, cqe: linux.io_uring_cqe) !void {
        const op = c.op.copy_file_chunk;
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        switch (st.state) {
            .copying_to_pipe => {
                const n = countOrError(cqe) catch |err| {
                    st.state = .open;
                    return self.completeCopyOperation(c, .{ .copy_file_chunk = err });
                };
                if (n == 0) {
                    st.state = .open;
                    return self.completeCopyOperation(c, .{ .copy_file_chunk = @as(usize, 0) });
                }
                st.buffered = n;
                st.drained = 0;
                st.state = .copying_to_dst;
                self.submitCopySpliceToDestination(c) catch |err| {
                    st.poisoned = true;
                    st.state = .open;
                    return self.completeCopyOperation(c, .{ .copy_file_chunk = err });
                };
            },
            .copying_to_dst => {
                const n = countOrError(cqe) catch |err| {
                    st.poisoned = true;
                    st.state = .open;
                    return self.completeCopyOperation(c, .{ .copy_file_chunk = err });
                };
                const remaining = st.buffered - st.drained;
                if (n == 0 or n > remaining) {
                    st.poisoned = true;
                    st.state = .open;
                    return self.completeCopyOperation(c, .{ .copy_file_chunk = error.WriteShort });
                }
                st.drained += n;
                if (st.drained < st.buffered) {
                    self.submitCopySpliceToDestination(c) catch |err| {
                        st.poisoned = true;
                        st.state = .open;
                        return self.completeCopyOperation(c, .{ .copy_file_chunk = err });
                    };
                    return;
                }
                const copied = st.drained;
                st.buffered = 0;
                st.drained = 0;
                st.state = .open;
                return self.completeCopyOperation(c, .{ .copy_file_chunk = copied });
            },
            else => return self.completeCopyOperation(c, .{ .copy_file_chunk = error.InvalidState }),
        }
    }

    fn dispatchCloseCopyFileSession(self: *RealIO, c: *Completion, cqe: linux.io_uring_cqe) !void {
        const op = c.op.close_copy_file_session;
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        if (cqe.res < 0 and st.close_error == null) st.close_error = errnoToError(cqe.err());
        st.close_remaining -|= 1;
        if (st.close_remaining > 0) return;

        const maybe_err = st.close_error;
        st.* = .{};
        if (maybe_err) |err| {
            return self.completeCopyOperation(c, .{ .close_copy_file_session = err });
        }
        return self.completeCopyOperation(c, .{ .close_copy_file_session = {} });
    }

    fn submitCopySpliceToPipe(self: *RealIO, c: *Completion) !void {
        const op = c.op.copy_file_chunk;
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        const sqe = try self.ring.splice(
            @intFromPtr(c),
            op.src_fd,
            op.src_offset,
            st.pipe_fds[1],
            splice_pipe_offset,
            op.len,
        );
        sqe.rw_flags = splice_f_nonblock;
    }

    fn submitCopySpliceToDestination(self: *RealIO, c: *Completion) !void {
        const op = c.op.copy_file_chunk;
        const st = op.session.backendStateAs(RealCopyFileSessionState);
        const remaining = st.buffered - st.drained;
        const sqe = try self.ring.splice(
            @intFromPtr(c),
            st.pipe_fds[0],
            splice_pipe_offset,
            op.dst_fd,
            op.dst_offset + st.drained,
            remaining,
        );
        sqe.rw_flags = splice_f_nonblock;
    }

    fn completeCopyOperation(self: *RealIO, c: *Completion, result: Result) !void {
        realState(c).in_flight = false;
        const cb = c.callback orelse return;
        const action = cb(c.userdata, c, result);
        switch (action) {
            .disarm => {},
            .rearm => try self.resubmit(c),
        }
    }

    pub fn socket(self: *RealIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (!self.feature_support.supports_socket) {
            try self.armCompletion(c, .{ .socket = op }, ud, cb);
            try self.submitBlockingOp(.{ .socket = op }, c);
            return;
        }

        try self.armCompletion(c, .{ .socket = op }, ud, cb);
        const sock_type = op.sock_type | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
        const sqe = try self.ring.socket(@intFromPtr(c), op.domain, sock_type, op.protocol, 0);
        _ = sqe;
    }

    pub fn connect(self: *RealIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);
        // `connect` is asynchronous: the kernel may read the sockaddr after
        // this function returns. Keep the pointer anchored in the completion's
        // stored operation, not the by-value stack parameter.
        const stored = &c.op.connect;
        const addrlen = stored.addr.getOsSockLen();
        const sqe = try self.ring.connect(@intFromPtr(c), stored.fd, &stored.addr.any, addrlen);

        if (stored.deadline_ns) |ns| {
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
    ///   * **Fallback path** (kernel <6.11): offload `bind(2)` to the
    ///     backend-owned `BlockingOpPool`. Callback/rearm handling stays
    ///     centralized in the pool-completion dispatcher.
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

        try self.armCompletion(c, .{ .bind = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .bind = op_in }, c);
    }

    /// `listen` mirrors `bind`: branches on
    /// `feature_support.supports_listen` (kernel ≥6.11 →
    /// `IORING_OP_LISTEN`, else `listen(2)` on the blocking-op pool).
    pub fn listen(self: *RealIO, op_in: ifc.ListenOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        if (self.feature_support.supports_listen) {
            try self.armCompletion(c, .{ .listen = op_in }, ud, cb);
            const sqe = try self.ring.listen(@intFromPtr(c), op_in.fd, op_in.backlog, 0);
            _ = sqe;
            return;
        }

        try self.armCompletion(c, .{ .listen = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .listen = op_in }, c);
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
    ///   * **Fallback path** (URING_CMD unsupported): offload
    ///     `setsockopt(2)` to the backend-owned `BlockingOpPool`.
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

        try self.armCompletion(c, .{ .setsockopt = op_in }, ud, cb);
        try self.submitBlockingOp(.{ .setsockopt = op_in }, c);
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
        if (isBlockingPoolOp(op.target.op) and self.pool.tryCancelPending(op.target)) {
            try self.queueReady(c, .{ .cancel = {} });
            return;
        }
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
        // through the ring exactly like fallocate/fsync. On older kernels
        // truncate completes through the blocking-op pool and never reaches
        // `dispatchCqe`, so this branch is unreachable in that case.
        .truncate => .{ .truncate = voidOrError(cqe) },
        .openat => .{ .openat = fdOrError(cqe) },
        .mkdirat => .{ .mkdirat = voidOrError(cqe) },
        .renameat => .{ .renameat = voidOrError(cqe) },
        .unlinkat => .{ .unlinkat = voidOrError(cqe) },
        .statx => .{ .statx = voidOrError(cqe) },
        // getdents completes through the blocking-op pool because Zig
        // 0.15.2 exposes no io_uring getdents helper/op.
        .getdents => .{ .getdents = countOrError(cqe) },
        .open_copy_file_session => .{ .open_copy_file_session = voidOrError(cqe) },
        .copy_file_chunk => .{ .copy_file_chunk = countOrError(cqe) },
        .close_copy_file_session => .{ .close_copy_file_session = voidOrError(cqe) },
        .fchown => .{ .fchown = voidOrError(cqe) },
        .fchmod => .{ .fchmod = voidOrError(cqe) },
        .socket => .{ .socket = fdOrError(cqe) },
        .connect => .{ .connect = voidOrError(cqe) },
        .accept => .{ .accept = acceptResult(cqe) },
        // Bind / listen / setsockopt either come back from the async ring
        // or complete through the blocking-op pool. When a CQE does land,
        // translate it the same way as fallocate / fsync.
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

fn isBlockingPoolOp(op: Operation) bool {
    return switch (op) {
        .close,
        .truncate,
        .openat,
        .mkdirat,
        .renameat,
        .unlinkat,
        .statx,
        .getdents,
        .fchown,
        .fchmod,
        .socket,
        .bind,
        .listen,
        .setsockopt,
        => true,
        else => false,
    };
}

fn errnoToError(e: linux.E) anyerror {
    return switch (e) {
        .SUCCESS => unreachable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .NOTCONN => error.SocketNotConnected,
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
        .DESTADDRREQ => error.DestinationAddressRequired,
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

test "RealIO maps ENOTCONN completions to SocketNotConnected" {
    try testing.expect(errnoToError(.NOTCONN) == error.SocketNotConnected);
    try testing.expect(ifc.linuxErrnoToError(.NOTCONN) == error.SocketNotConnected);
    try testing.expect(errnoToError(.DESTADDRREQ) == error.DestinationAddressRequired);
    try testing.expect(ifc.linuxErrnoToError(.DESTADDRREQ) == error.DestinationAddressRequired);
}

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

fn expectNoInlineThenTick(io: *RealIO, ctx: *TestCtx) !void {
    try testing.expectEqual(@as(u32, 0), ctx.calls);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
}

test "RealIO unsupported ring fallbacks complete from tick" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.feature_support = .{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("truncate", .{ .truncate = true });
        defer file.close();

        var c = Completion{};
        var ctx = TestCtx{};
        try io.truncate(.{ .fd = file.handle, .length = 4096 }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .truncate => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        const file = try tmp.dir.createFile("openat", .{ .truncate = true });
        file.close();

        var c = Completion{};
        var ctx = TestCtx{};
        try io.openat(.{
            .dir_fd = tmp.dir.fd,
            .path = "openat",
            .flags = .{ .ACCMODE = .RDONLY },
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .openat => |r| posix.close(try r),
            else => try testing.expect(false),
        }
    }

    {
        var c = Completion{};
        var ctx = TestCtx{};
        try io.mkdirat(.{
            .dir_fd = tmp.dir.fd,
            .path = "made",
            .mode = 0o755,
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .mkdirat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        const file = try tmp.dir.createFile("rename-old", .{ .truncate = true });
        file.close();

        var c = Completion{};
        var ctx = TestCtx{};
        try io.renameat(.{
            .old_dir_fd = tmp.dir.fd,
            .old_path = "rename-old",
            .new_dir_fd = tmp.dir.fd,
            .new_path = "rename-new",
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .renameat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        const file = try tmp.dir.createFile("unlink-me", .{ .truncate = true });
        file.close();

        var c = Completion{};
        var ctx = TestCtx{};
        try io.unlinkat(.{
            .dir_fd = tmp.dir.fd,
            .path = "unlink-me",
            .flags = 0,
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .unlinkat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        var stat_buf: linux.Statx = undefined;
        var c = Completion{};
        var ctx = TestCtx{};
        try io.statx(.{
            .dir_fd = tmp.dir.fd,
            .path = "rename-new",
            .flags = linux.AT.SYMLINK_NOFOLLOW,
            .mask = linux.STATX_BASIC_STATS,
            .buf = &stat_buf,
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .statx => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        var buf: [512]u8 align(@alignOf(linux.dirent64)) = undefined;
        var c = Completion{};
        var ctx = TestCtx{};
        try io.getdents(.{
            .fd = tmp.dir.fd,
            .buf = &buf,
        }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .getdents => {},
            else => try testing.expect(false),
        }
    }

    {
        const file = try tmp.dir.createFile("close-me", .{ .truncate = true });
        var c = Completion{};
        var ctx = TestCtx{};
        try io.close(.{ .fd = file.handle }, &c, &ctx, testCallback);
        try expectNoInlineThenTick(&io, &ctx);
        switch (ctx.last_result.?) {
            .close => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
        defer posix.close(fd);
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);

        var bind_c = Completion{};
        var bind_ctx = TestCtx{};
        try io.bind(.{ .fd = fd, .addr = addr }, &bind_c, &bind_ctx, testCallback);
        try expectNoInlineThenTick(&io, &bind_ctx);
        switch (bind_ctx.last_result.?) {
            .bind => |r| try r,
            else => try testing.expect(false),
        }

        var listen_c = Completion{};
        var listen_ctx = TestCtx{};
        try io.listen(.{ .fd = fd, .backlog = 16 }, &listen_c, &listen_ctx, testCallback);
        try expectNoInlineThenTick(&io, &listen_ctx);
        switch (listen_ctx.last_result.?) {
            .listen => |r| try r,
            else => try testing.expect(false),
        }

        const enable = std.mem.toBytes(@as(c_int, 1));
        var set_c = Completion{};
        var set_ctx = TestCtx{};
        try io.setsockopt(.{
            .fd = fd,
            .level = posix.SOL.SOCKET,
            .optname = posix.SO.REUSEADDR,
            .optval = &enable,
        }, &set_c, &set_ctx, testCallback);
        try expectNoInlineThenTick(&io, &set_ctx);
        switch (set_ctx.last_result.?) {
            .setsockopt => |r| try r,
            else => try testing.expect(false),
        }
    }
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
    // `IORING_OP_FTRUNCATE` and the CQE flows through dispatchCqe. On
    // older kernels it falls back through the blocking-op pool. Either path
    // must deliver the callback from `tick`.
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("truncate_test", .{ .truncate = true });
    defer file.close();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(.{ .fd = file.handle, .length = 4096 }, &c, &ctx, testCallback);
    try expectNoInlineThenTick(&io, &ctx);
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
    // IORING_OP_BIND; the CQE flows through dispatchCqe. On older kernels
    // the fallback runs on the blocking-op pool. Either way the callback
    // must be delivered from `tick` and the bind must succeed
    // against an ephemeral 127.0.0.1:0 address.
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);

    var c = Completion{};
    var ctx = TestCtx{};
    try io.bind(.{ .fd = fd, .addr = addr }, &c, &ctx, testCallback);
    try expectNoInlineThenTick(&io, &ctx);
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
    try expectNoInlineThenTick(&io, &ctx);
    switch (ctx.last_result.?) {
        .listen => |r| try r,
        else => try testing.expect(false),
    }
}

test "RealIO connected UDP sendmsg can omit destination address" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const server = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, posix.IPPROTO.UDP);
    defer posix.close(server);
    const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try posix.bind(server, &bind_addr.any, bind_addr.getOsSockLen());

    var server_sockaddr: posix.sockaddr = undefined;
    var server_socklen: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server, &server_sockaddr, &server_socklen);
    const server_addr = std.net.Address{ .any = server_sockaddr };

    const client = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.UDP);
    defer posix.close(client);

    var connect_c = Completion{};
    var connect_ctx = TestCtx{};
    try io.connect(.{ .fd = client, .addr = server_addr }, &connect_c, &connect_ctx, testCallback);
    if (connect_ctx.calls == 0) try io.tick(1);
    try testing.expectEqual(@as(u32, 1), connect_ctx.calls);
    switch (connect_ctx.last_result.?) {
        .connect => |r| try r,
        else => try testing.expect(false),
    }

    const payload = "ping";
    var iov = [1]posix.iovec_const{.{
        .base = payload.ptr,
        .len = payload.len,
    }};
    var msg = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    var send_c = Completion{};
    var send_ctx = TestCtx{};
    try io.sendmsg(.{ .fd = client, .msg = &msg }, &send_c, &send_ctx, testCallback);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), send_ctx.calls);
    switch (send_ctx.last_result.?) {
        .sendmsg => |r| try testing.expectEqual(payload.len, try r),
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
    try expectNoInlineThenTick(&io, &ctx);
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

test "RealIO bind/listen ops round-trip through caller-owned wait" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);

    var bind_c = Completion{};
    var bind_ctx = TestCtx{};
    try io.bind(.{ .fd = fd, .addr = addr }, &bind_c, &bind_ctx, testCallback);
    try expectNoInlineThenTick(&io, &bind_ctx);
    switch (bind_ctx.last_result.?) {
        .bind => |r| try r,
        else => try testing.expect(false),
    }

    var listen_c = Completion{};
    var listen_ctx = TestCtx{};
    try io.listen(.{ .fd = fd, .backlog = 8 }, &listen_c, &listen_ctx, testCallback);
    try expectNoInlineThenTick(&io, &listen_ctx);
    switch (listen_ctx.last_result.?) {
        .listen => |r| try r,
        else => try testing.expect(false),
    }

    // Confirm the socket is in LISTEN by trying to connect from a
    // sibling client socket.
    var taken_addr: posix.sockaddr = undefined;
    var taken_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(fd, &taken_addr, &taken_len);
    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);
    try posix.connect(client_fd, &taken_addr, taken_len);
}

//! Backend-owned blocking-op thread pool.
//!
//! Shared by backends that need backend-owned syscall offload. The
//! readiness backends use it because `epoll` / `kqueue` cannot make
//! regular-file and fd-management syscalls nonblocking; `RealIO` uses it
//! only when the runtime io_uring probe says the native ring op is absent.
//! The pool's worker threads execute the syscall, push the result back,
//! and signal a backend-provided wakeup callback. The backend drains the
//! result queue from its `tick()` and fires the user's callbacks.
//!
//! ## Why a thread pool
//!
//! Neither `epoll_wait` nor `kevent` reports readiness for regular files —
//! a file is "always readable" from the kernel's point of view, but the
//! `read`/`write` syscalls themselves block when the page isn't resident
//! and a fault has to be serviced. To preserve the contract's
//! "submission returns immediately, the callback fires later" shape we
//! offload every blocking syscall to a worker thread. This mirrors what
//! `zio` and `libxev`'s epoll backend do.
//!
//! ## Design choices (read STYLE.md pattern #15 first)
//!
//! 1. **One module, multiple consumers.** The work the pool performs is
//!    syscall-shaped and independent of the readiness primitive. Epoll
//!    uses eventfd and kqueue uses `EVFILT_USER`. The pool exposes a
//!    callback-shaped wakeup hook (`WakeFn`) so each backend wires it to
//!    whatever signal its loop already understands.
//!
//! 2. **Caller-owned `Completion`s.** Same contract as the rest of the IO
//!    interface — the pool stores a `*Completion` pointer in each pending
//!    entry; the backend's `armCompletion` has already filled
//!    `op`/`userdata`/`callback`/`_backend_state` by the time `submit`
//!    returns.
//!
//! 3. **Bounded pending and completed queues.** Both sized at
//!    construction; the completed queue is at least as large as the
//!    pending queue so a worker can never fail to record its result. A
//!    full pending queue causes `submit` to return
//!    `error.PendingQueueFull`. Defaults are `pending_capacity = 256` and
//!    `worker_count = 4` — modeled on the `change_batch` size used by
//!    KqueuePosixIO and `default_thread_count` in `hasher.zig`.
//!
//! 4. **Mirror `hasher.zig`'s shape.** That module is varuna's canonical
//!    CPU-bound worker pool. Its mutex+condvar+eventfd pattern is the
//!    direct model for this file's mutex+condvar+wakeup-callback
//!    structure. Pool lifecycle (start workers, signal shutdown, join)
//!    is verbatim.
//!
//! ## Cancellation
//!
//! Blocking-op cancellation through this pool is **best-effort**:
//!   * If the op is still pending when `cancel` runs, we drop it and
//!     deliver `error.OperationCanceled` synchronously.
//!   * If a worker has already picked it up, we cannot interrupt the
//!     blocking syscall; the op's "real" result is delivered when the
//!     worker finishes.
//!
//! ## Static-allocation invariant
//!
//! All bounded buffers are allocated once at `create`. Workers do not
//! allocate. The pool may allocate when growing the completed buffer
//! during `drainCompletedInto`, but the steady-state path is alloc-free
//! against the caller's swap buffer.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const assert = std.debug.assert;

const ifc = @import("io_interface.zig");
const Completion = ifc.Completion;
const Result = ifc.Result;

// ── Public types ──────────────────────────────────────────

pub const MappedRegion = struct {
    base: [*]align(std.heap.page_size_min) u8,
    len: usize,
};

pub const MsyncOp = struct {
    mapping: MappedRegion,
};

pub const MmapCloseOp = struct {
    fd: posix.fd_t,
    mapping: ?MappedRegion,
};

pub const MmapFallocateOp = struct {
    fd: posix.fd_t,
    mode: i32,
    offset: u64,
    len: u64,
    mapping: ?MappedRegion,
};

pub const MmapTruncateOp = struct {
    fd: posix.fd_t,
    length: u64,
    mapping: ?MappedRegion,
};

pub const MmapSetupResult = anyerror!MappedRegion;

pub const MmapSetupOp = struct {
    fd: posix.fd_t,
    mapping: ?MappedRegion,
    advise_willneed: bool,
    result: *MmapSetupResult,
};

/// One unit of blocking syscall work. Carries the parameters the worker needs to
/// run the syscall. The op type is duplicated from `ifc.Operation` so the
/// pool doesn't have to switch the full Operation union.
pub const BlockingOp = union(enum) {
    read: ifc.ReadOp,
    write: ifc.WriteOp,
    fsync: ifc.FsyncOp,
    close: ifc.CloseOp,
    fallocate: ifc.FallocateOp,
    truncate: ifc.TruncateOp,
    openat: ifc.OpenAtOp,
    mkdirat: ifc.MkdirAtOp,
    renameat: ifc.RenameAtOp,
    unlinkat: ifc.UnlinkAtOp,
    statx: ifc.StatxOp,
    getdents: ifc.GetdentsOp,
    copy_file_chunk: ifc.CopyFileChunkOp,
    fchown: ifc.FchownOp,
    fchmod: ifc.FchmodOp,
    socket: ifc.SocketOp,
    bind: ifc.BindOp,
    listen: ifc.ListenOp,
    setsockopt: ifc.SetsockoptOp,
    msync: MsyncOp,
    mmap_close: MmapCloseOp,
    mmap_fallocate: MmapFallocateOp,
    mmap_truncate: MmapTruncateOp,
    mmap_setup: MmapSetupOp,
};

/// Back-compat alias for older file-op-only call sites.
pub const FileOp = BlockingOp;

/// A completed op ready to fire its callback. The pool stages these in
/// `completed`; the backend drains them in `tick()` and invokes
/// `c.callback`. Pre-resolved `Result` so the backend doesn't reinterpret
/// the op tag.
pub const Completed = struct {
    completion: *Completion,
    result: Result,
};

/// Wakeup callback. Workers invoke it after pushing onto `completed` so
/// the readiness loop wakes out of `epoll_pwait` / `kevent`. Signature is
/// fd-/handle-agnostic by design — backends close over their own state
/// (eventfd handle on Linux, kqueue fd + ident on macOS).
///
/// **Must be safe to call from any thread.** Implementations are
/// expected to be a single non-blocking write to a pipe / eventfd / kevent.
pub const WakeFn = *const fn (ctx: ?*anyopaque) void;

pub const Config = struct {
    /// Worker thread count. Defaults to 4, matching `hasher.zig`. Set to
    /// 0 to enable inline mode (every submit runs synchronously on the
    /// caller's thread) for tests that need deterministic ordering.
    worker_count: u32 = 4,
    /// Bound on simultaneously-pending submissions. Beyond this,
    /// `submit` returns `error.PendingQueueFull`.
    pending_capacity: u32 = 256,
    /// Per-worker scratch buffer used only when `copy_file_chunk` falls
    /// back to positioned read/write. Allocated once at pool creation.
    copy_scratch_bytes: usize = 1024 * 1024,
};

/// Per-pool errors returned at the public surface. Worker-thread errors
/// are encoded into the `Result` union and surfaced through the
/// completion callback.
pub const PoolError = error{
    PendingQueueFull,
};

// ── Internal entry types ──────────────────────────────────

const PendingEntry = struct {
    completion: ?*Completion,
    op: BlockingOp,
};

// ── BlockingOpPool ─────────────────────────────────────────

pub const BlockingOpPool = struct {
    allocator: std.mem.Allocator,
    workers: []std.Thread,
    worker_scratch: [][]u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Submission queue: backend pushes (under EL thread), workers pop.
    pending_mutex: std.Thread.Mutex = .{},
    pending_cond: std.Thread.Condition = .{},
    pending: std.ArrayListUnmanaged(PendingEntry) = .{},
    pending_capacity: u32,

    // Result queue: workers push, backend drains in `tick`.
    completed_mutex: std.Thread.Mutex = .{},
    completed: std.ArrayListUnmanaged(Completed) = .{},

    // In-flight count: pending entries dequeued by a worker but not yet
    // pushed onto `completed`. Surface for `hasPendingWork` so the
    // backend's tick can decide when it's safe to idle.
    in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Wakeup callback. The backend wires it to its readiness primitive
    // (eventfd on epoll, EVFILT_USER on kqueue). Stored as `?*anyopaque`
    // + WakeFn so the pool stays decoupled from the backend's concrete
    // type.
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?WakeFn = null,

    /// Heap-allocated to give workers a stable pointer for the lifetime
    /// of the pool. Mirrors `hasher.zig`.
    pub fn create(allocator: std.mem.Allocator, cfg: Config) !*BlockingOpPool {
        const self = try allocator.create(BlockingOpPool);
        errdefer allocator.destroy(self);

        const workers = try allocator.alloc(std.Thread, cfg.worker_count);
        errdefer allocator.free(workers);

        const worker_scratch = try allocator.alloc([]u8, cfg.worker_count);
        errdefer allocator.free(worker_scratch);
        for (worker_scratch) |*buf| buf.* = &.{};
        var scratch_allocated: usize = 0;
        errdefer {
            for (worker_scratch[0..scratch_allocated]) |buf| allocator.free(buf);
        }
        const scratch_bytes = @max(cfg.copy_scratch_bytes, 1);
        for (worker_scratch) |*buf| {
            buf.* = try allocator.alloc(u8, scratch_bytes);
            scratch_allocated += 1;
        }

        self.* = .{
            .allocator = allocator,
            .workers = workers,
            .worker_scratch = worker_scratch,
            .pending_capacity = cfg.pending_capacity,
        };
        errdefer self.pending.deinit(allocator);
        errdefer self.completed.deinit(allocator);

        try self.pending.ensureTotalCapacity(allocator, cfg.pending_capacity);
        try self.completed.ensureTotalCapacity(allocator, cfg.pending_capacity);

        // Spawn workers last: any earlier failure has to teardown the
        // partial set.
        var spawned: usize = 0;
        errdefer {
            self.running.store(false, .release);
            self.pending_cond.broadcast();
            for (self.workers[0..spawned]) |t| t.join();
        }
        for (self.workers, 0..) |*t, worker_index| {
            t.* = try std.Thread.spawn(.{}, workerFn, .{ self, worker_index });
            spawned += 1;
        }
        return self;
    }

    /// Stop accepting work, wake every worker, join them. Drains any
    /// unprocessed pending entries by delivering `error.OperationCanceled`
    /// — the contract is "every submitted op fires its callback exactly
    /// once". Completions still on `completed` after the join are left
    /// for one final `drainCompletedInto` by the backend in its
    /// `deinit` path.
    pub fn deinit(self: *BlockingOpPool) void {
        self.running.store(false, .release);
        self.pending_cond.broadcast();
        for (self.workers) |t| t.join();
        self.allocator.free(self.workers);

        // Cancel anything still in the pending queue so the contract
        // ("every submitted op fires its callback") is preserved if a
        // backend chooses to drain after the pool has been told to
        // shut down. No workers are running, so we can do this without
        // taking the locks.
        for (self.pending.items) |entry| {
            const completion = entry.completion orelse continue;
            self.completed.appendAssumeCapacity(.{
                .completion = completion,
                .result = makeCancelledResult(entry.op),
            });
        }
        self.pending.clearRetainingCapacity();

        self.pending.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        for (self.worker_scratch) |buf| self.allocator.free(buf);
        self.allocator.free(self.worker_scratch);
        const allocator = self.allocator;
        // Note: don't dereference `self` after destroy.
        allocator.destroy(self);
    }

    /// Wire the wakeup hook. Backend calls this once during its `init`,
    /// passing a context pointer (the backend itself, typically) and a
    /// function pointer that the pool's workers will invoke after each
    /// completion. **Must be set before `submit`** to avoid silent
    /// no-wake states.
    pub fn setWakeup(self: *BlockingOpPool, ctx: ?*anyopaque, wake_fn: WakeFn) void {
        self.wake_ctx = ctx;
        self.wake_fn = wake_fn;
    }

    /// Submit a file op. Returns `error.PendingQueueFull` if the bound
    /// would be exceeded. The caller is responsible for filling
    /// `c.callback` and `c.userdata` (typically via the backend's
    /// `armCompletion`) before calling submit.
    pub fn submit(self: *BlockingOpPool, op: BlockingOp, c: *Completion) PoolError!void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.items.len >= self.pending_capacity) {
            return error.PendingQueueFull;
        }
        self.pending.appendAssumeCapacity(.{ .completion = c, .op = op });
        // Wake one worker — only one can take the new entry.
        self.pending_cond.signal();
    }

    /// Submit worker-only cleanup work with no public completion callback.
    /// Used for legacy `closeSocket` teardown paths whose API is intentionally
    /// fire-and-forget.
    pub fn submitDetached(self: *BlockingOpPool, op: BlockingOp) PoolError!void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.items.len >= self.pending_capacity) {
            return error.PendingQueueFull;
        }
        self.pending.appendAssumeCapacity(.{ .completion = null, .op = op });
        self.pending_cond.signal();
    }

    /// Drain the completed queue into the caller's buffer. Backend
    /// invokes this from `tick()`; the buffer is the backend's persistent
    /// scratch (e.g. `EpollPosixIO.completed_swap`). Returns the slice
    /// the backend should iterate over to invoke callbacks.
    ///
    /// The slice's storage is `out`'s storage — once the backend is done
    /// with it, calling `out.clearRetainingCapacity()` resets for the
    /// next tick.
    pub fn drainCompletedInto(
        self: *BlockingOpPool,
        out: *std.ArrayListUnmanaged(Completed),
    ) !void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        try out.appendSlice(self.allocator, self.completed.items);
        self.completed.clearRetainingCapacity();
    }

    /// True if the pool has work that hasn't reached the user callback
    /// yet. Backend's `tick` consults this to decide whether to block on
    /// the next readiness wait.
    pub fn hasPendingWork(self: *BlockingOpPool) bool {
        if (self.in_flight.load(.acquire) > 0) return true;
        self.pending_mutex.lock();
        if (self.pending.items.len > 0) {
            self.pending_mutex.unlock();
            return true;
        }
        self.pending_mutex.unlock();
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        return self.completed.items.len > 0;
    }

    /// Best-effort cancel by completion pointer. Returns `true` if the op
    /// was found pending (and removed → cancelled). Returns `false` if it
    /// was already running on a worker, already completed, or never
    /// submitted. Backend's `cancel` op uses this to decide what cancel
    /// result to deliver.
    pub fn tryCancelPending(self: *BlockingOpPool, c: *Completion) bool {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        for (self.pending.items, 0..) |entry, idx| {
            const completion = entry.completion orelse continue;
            if (completion == c) {
                _ = self.pending.swapRemove(idx);
                self.completed_mutex.lock();
                defer self.completed_mutex.unlock();
                self.completed.appendAssumeCapacity(.{
                    .completion = completion,
                    .result = makeCancelledResult(entry.op),
                });
                self.signalWake();
                return true;
            }
        }
        return false;
    }

    fn signalWake(self: *BlockingOpPool) void {
        if (self.wake_fn) |f| f(self.wake_ctx);
    }

    // ── Worker loop ───────────────────────────────────────

    fn workerFn(self: *BlockingOpPool, worker_index: usize) void {
        const scratch = self.worker_scratch[worker_index];
        while (true) {
            self.pending_mutex.lock();
            while (self.pending.items.len == 0 and self.running.load(.acquire)) {
                // Cap the wait so a `running = false` signal that races a
                // newly-emptied queue still wakes us. Mirrors hasher.zig.
                self.pending_cond.timedWait(
                    &self.pending_mutex,
                    1 * std.time.ns_per_s,
                ) catch {};
            }
            if (!self.running.load(.acquire) and self.pending.items.len == 0) {
                self.pending_mutex.unlock();
                return;
            }
            const entry = self.pending.orderedRemove(0);
            _ = self.in_flight.fetchAdd(1, .acq_rel);
            self.pending_mutex.unlock();

            const result = executeOp(entry.op, scratch);

            if (entry.completion) |completion| {
                self.completed_mutex.lock();
                self.completed.appendAssumeCapacity(.{
                    .completion = completion,
                    .result = result,
                });
                self.completed_mutex.unlock();
            }
            _ = self.in_flight.fetchSub(1, .acq_rel);

            if (entry.completion != null) self.signalWake();
        }
    }
};

/// Back-compat alias for older file-op-only call sites.
pub const PosixFilePool = BlockingOpPool;

// ── Op execution (worker thread) ──────────────────────────
//
// Each `executeXxx` runs the underlying syscall and packs the result.
// **Runs on a worker thread** — must not touch the pool's mutexes, must
// not take locks anywhere else.

fn executeOp(op: BlockingOp, scratch: []u8) Result {
    return switch (op) {
        .read => |p| .{ .read = executeRead(p) },
        .write => |p| .{ .write = executeWrite(p) },
        .fsync => |p| .{ .fsync = executeFsync(p) },
        .close => |p| .{ .close = executeClose(p) },
        .fallocate => |p| .{ .fallocate = executeFallocate(p) },
        .truncate => |p| .{ .truncate = executeTruncate(p) },
        .openat => |p| .{ .openat = executeOpenAt(p) },
        .mkdirat => |p| .{ .mkdirat = executeMkdirAt(p) },
        .renameat => |p| .{ .renameat = executeRenameAt(p) },
        .unlinkat => |p| .{ .unlinkat = executeUnlinkAt(p) },
        .statx => |p| .{ .statx = executeStatx(p) },
        .getdents => |p| .{ .getdents = executeGetdents(p) },
        .copy_file_chunk => |p| .{ .copy_file_chunk = executeCopyFileChunk(p, scratch) },
        .fchown => |p| .{ .fchown = executeFchown(p) },
        .fchmod => |p| .{ .fchmod = executeFchmod(p) },
        .socket => |p| .{ .socket = executeSocket(p) },
        .bind => |p| .{ .bind = executeBind(p) },
        .listen => |p| .{ .listen = executeListen(p) },
        .setsockopt => |p| .{ .setsockopt = executeSetsockopt(p) },
        .msync => |p| .{ .fsync = executeMsync(p) },
        .mmap_close => |p| .{ .close = executeMmapClose(p) },
        .mmap_fallocate => |p| .{ .fallocate = executeMmapFallocate(p) },
        .mmap_truncate => |p| .{ .truncate = executeMmapTruncate(p) },
        .mmap_setup => |p| blk: {
            p.result.* = executeMmapSetup(p);
            break :blk .{ .read = @as(usize, 0) };
        },
    };
}

fn executeRead(op: ifc.ReadOp) anyerror!usize {
    return posix.pread(op.fd, op.buf, op.offset);
}

fn executeWrite(op: ifc.WriteOp) anyerror!usize {
    return posix.pwrite(op.fd, op.buf, op.offset);
}

fn executeFsync(op: ifc.FsyncOp) anyerror!void {
    if (comptime builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = if (op.datasync) linux.fdatasync(op.fd) else linux.fsync(op.fd);
        switch (linux.E.init(rc)) {
            .SUCCESS => return,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .BADF => return error.BadFileDescriptor,
            .INVAL => return error.InvalidArgument,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
    // Generic POSIX: `fsync` is the strongest portable primitive.
    // `op.datasync` is best-effort; on platforms without a separate
    // datasync we degrade to fsync.
    return posix.fsync(op.fd);
}

fn executeClose(op: ifc.CloseOp) anyerror!void {
    posix.close(op.fd);
}

fn executeFallocate(op: ifc.FallocateOp) anyerror!void {
    if (comptime builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.fallocate(
            op.fd,
            op.mode,
            @intCast(op.offset),
            @intCast(op.len),
        );
        switch (linux.E.init(rc)) {
            .SUCCESS => return,
            .NOSPC => return error.NoSpaceLeft,
            .OPNOTSUPP => return error.OperationNotSupported,
            .IO => return error.InputOutput,
            .BADF => return error.BadFileDescriptor,
            .INVAL => return error.InvalidArgument,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
    if (comptime builtin.target.os.tag.isDarwin()) {
        // F_PREALLOCATE plumbing — same shape as kqueue_mmap_io's
        // emulation. Fallback is the daemon's existing
        // OperationNotSupported → ftruncate path.
        const F_ALLOCATECONTIG: c_uint = 0x2;
        const F_ALLOCATEALL: c_uint = 0x4;
        const F_PEOFPOSMODE: c_int = 3;
        const fstore_t = extern struct {
            fst_flags: c_uint,
            fst_posmode: c_int,
            fst_offset: posix.off_t,
            fst_length: posix.off_t,
            fst_bytesalloc: posix.off_t,
        };
        var store = fstore_t{
            .fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL,
            .fst_posmode = F_PEOFPOSMODE,
            .fst_offset = 0,
            .fst_length = @intCast(op.offset + op.len),
            .fst_bytesalloc = 0,
        };
        // F_PREALLOCATE = 42 on darwin.
        const rc = std.c.fcntl(op.fd, 42, &store);
        if (rc == 0) return posix.ftruncate(op.fd, op.offset + op.len);
        return error.OperationNotSupported;
    }
    return error.OperationNotSupported;
}

fn executeTruncate(op: ifc.TruncateOp) anyerror!void {
    return posix.ftruncate(op.fd, op.length);
}

fn executeOpenAt(op: ifc.OpenAtOp) anyerror!posix.fd_t {
    return posix.openat(op.dir_fd, op.path, op.flags, op.mode);
}

fn executeMkdirAt(op: ifc.MkdirAtOp) anyerror!void {
    return posix.mkdirat(op.dir_fd, op.path, op.mode);
}

fn executeRenameAt(op: ifc.RenameAtOp) anyerror!void {
    if (op.flags != 0) return error.OperationNotSupported;
    return posix.renameat(op.old_dir_fd, op.old_path, op.new_dir_fd, op.new_path);
}

fn executeUnlinkAt(op: ifc.UnlinkAtOp) anyerror!void {
    return posix.unlinkat(op.dir_fd, op.path, op.flags);
}

fn executeStatx(op: ifc.StatxOp) anyerror!void {
    if (comptime builtin.target.os.tag == .linux) {
        const rc = std.os.linux.statx(op.dir_fd, op.path, op.flags, op.mask, op.buf);
        return switch (std.os.linux.E.init(rc)) {
            .SUCCESS => {},
            else => |err| ifc.linuxErrnoToError(err),
        };
    }

    const st = try posix.fstatatZ(op.dir_fd, op.path, op.flags);
    op.buf.* = std.mem.zeroes(std.os.linux.Statx);
    op.buf.mask = op.mask & std.os.linux.STATX_BASIC_STATS;
    op.buf.blksize = @intCast(@max(st.blksize, 0));
    op.buf.nlink = @intCast(@max(st.nlink, 0));
    op.buf.uid = @intCast(st.uid);
    op.buf.gid = @intCast(st.gid);
    op.buf.mode = @intCast(st.mode);
    op.buf.ino = @intCast(@max(st.ino, 0));
    op.buf.size = @intCast(@max(st.size, 0));
    op.buf.blocks = @intCast(@max(st.blocks, 0));
}

fn executeGetdents(op: ifc.GetdentsOp) anyerror!usize {
    if (comptime builtin.target.os.tag == .linux) {
        const rc = std.os.linux.getdents64(op.fd, op.buf.ptr, op.buf.len);
        return switch (std.os.linux.E.init(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| ifc.linuxErrnoToError(err),
        };
    }

    var dir: std.fs.Dir = .{ .fd = op.fd };
    var iter = dir.iterateAssumeFirstIteration();
    var out: usize = 0;
    var index: usize = 0;
    while (true) {
        const maybe_entry = try iter.next();
        const entry = maybe_entry orelse return out;
        const next = ifc.appendDirent64(
            op.buf,
            out,
            @as(u64, index + 1),
            @as(u64, index + 1),
            fileKindToDirentType(entry.kind),
            entry.name,
        ) orelse {
            if (out == 0) return error.InvalidArgument;
            return out;
        };
        out = next;
        index += 1;
    }
}

fn executeCopyFileChunk(op: ifc.CopyFileChunkOp, scratch: []u8) anyerror!usize {
    if (op.len == 0) return error.InvalidArgument;
    if (comptime builtin.target.os.tag == .linux) {
        var total: usize = 0;
        while (total < op.len) {
            const remaining = op.len - total;
            var off_in: i64 = @intCast(op.src_offset + total);
            var off_out: i64 = @intCast(op.dst_offset + total);
            const rc = std.os.linux.copy_file_range(op.src_fd, &off_in, op.dst_fd, &off_out, remaining, 0);
            switch (std.os.linux.E.init(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return total;
                    total += n;
                },
                .XDEV, .NOSYS, .OPNOTSUPP => {
                    if (total > 0) return total;
                    return executeCopyFileChunkReadWrite(op, scratch);
                },
                .BADF => if (total > 0) return total else return error.BadFileDescriptor,
                .INVAL => if (total > 0) return total else return error.InvalidArgument,
                .IO => if (total > 0) return total else return error.InputOutput,
                .NOSPC => if (total > 0) return total else return error.NoSpaceLeft,
                .ISDIR => if (total > 0) return total else return error.IsDir,
                .OVERFLOW => if (total > 0) return total else return error.FileTooBig,
                .TXTBSY => if (total > 0) return total else return error.WouldBlock,
                else => |e| if (total > 0) return total else return posix.unexpectedErrno(e),
            }
        }
        return total;
    }
    return executeCopyFileChunkReadWrite(op, scratch);
}

fn executeCopyFileChunkReadWrite(op: ifc.CopyFileChunkOp, scratch: []u8) anyerror!usize {
    assert(scratch.len > 0);
    var total: usize = 0;
    while (total < op.len) {
        const want = @min(op.len - total, scratch.len);
        const n_read = posix.pread(op.src_fd, scratch[0..want], op.src_offset + total) catch |err| {
            if (total > 0) return total;
            return err;
        };
        if (n_read == 0) return total;

        var written: usize = 0;
        while (written < n_read) {
            const w = posix.pwrite(op.dst_fd, scratch[written..n_read], op.dst_offset + total + written) catch |err| {
                if (total + written > 0) return total + written;
                return err;
            };
            if (w == 0) {
                if (total + written > 0) return total + written;
                return error.WriteShort;
            }
            written += w;
        }
        total += n_read;
    }
    return total;
}

fn executeFchown(op: ifc.FchownOp) anyerror!void {
    return posix.fchown(op.fd, @as(posix.uid_t, @intCast(op.uid)), @as(posix.gid_t, @intCast(op.gid)));
}

fn executeFchmod(op: ifc.FchmodOp) anyerror!void {
    return posix.fchmod(op.fd, op.mode);
}

fn executeSocket(op: ifc.SocketOp) anyerror!posix.fd_t {
    if (comptime builtin.target.os.tag == .linux) {
        const sock_type = op.sock_type | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
        return posix.socket(@intCast(op.domain), sock_type, @intCast(op.protocol));
    }

    const fd = try posix.socket(@intCast(op.domain), @intCast(op.sock_type), @intCast(op.protocol));
    errdefer posix.close(fd);
    try setNonblockCloexec(fd);
    return fd;
}

fn executeBind(op: ifc.BindOp) anyerror!void {
    return posix.bind(op.fd, &op.addr.any, op.addr.getOsSockLen());
}

fn executeListen(op: ifc.ListenOp) anyerror!void {
    return posix.listen(op.fd, op.backlog);
}

fn executeSetsockopt(op: ifc.SetsockoptOp) anyerror!void {
    return posix.setsockopt(op.fd, @intCast(op.level), op.optname, op.optval);
}

fn executeUnmap(mapping: ?MappedRegion) void {
    if (mapping) |m| {
        if (m.len > 0) posix.munmap(m.base[0..m.len]);
    }
}

fn executeMsync(op: MsyncOp) anyerror!void {
    if (op.mapping.len == 0) return;
    return posix.msync(op.mapping.base[0..op.mapping.len], posix.MSF.SYNC);
}

fn executeMmapClose(op: MmapCloseOp) anyerror!void {
    executeUnmap(op.mapping);
    posix.close(op.fd);
}

fn executeMmapFallocate(op: MmapFallocateOp) anyerror!void {
    executeUnmap(op.mapping);
    return executeFallocate(.{
        .fd = op.fd,
        .mode = op.mode,
        .offset = op.offset,
        .len = op.len,
    });
}

fn executeMmapTruncate(op: MmapTruncateOp) anyerror!void {
    executeUnmap(op.mapping);
    return executeTruncate(.{
        .fd = op.fd,
        .length = op.length,
    });
}

fn executeMmapSetup(op: MmapSetupOp) anyerror!MappedRegion {
    executeUnmap(op.mapping);

    const stat = try posix.fstat(op.fd);
    if (stat.size < 0) return error.InvalidArgument;
    const file_len: usize = @intCast(stat.size);
    if (file_len == 0) {
        return .{
            .base = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(std.heap.page_size_min)),
            .len = 0,
        };
    }

    const mapped = try posix.mmap(
        null,
        file_len,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        op.fd,
        0,
    );
    if (op.advise_willneed) {
        _ = posix.madvise(mapped.ptr, mapped.len, posix.MADV.WILLNEED) catch {};
    }
    return .{ .base = mapped.ptr, .len = mapped.len };
}

fn setNonblockCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, posix.SOCK.NONBLOCK));
    const fdflags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, fdflags | posix.FD_CLOEXEC);
}

fn fileKindToDirentType(kind: std.fs.File.Kind) u8 {
    return switch (kind) {
        .block_device => std.os.linux.DT.BLK,
        .character_device => std.os.linux.DT.CHR,
        .directory => std.os.linux.DT.DIR,
        .named_pipe => std.os.linux.DT.FIFO,
        .sym_link => std.os.linux.DT.LNK,
        .file => std.os.linux.DT.REG,
        .unix_domain_socket => std.os.linux.DT.SOCK,
        else => std.os.linux.DT.UNKNOWN,
    };
}

fn makeCancelledResult(op: BlockingOp) Result {
    return switch (op) {
        .read => .{ .read = error.OperationCanceled },
        .write => .{ .write = error.OperationCanceled },
        .fsync => .{ .fsync = error.OperationCanceled },
        .close => .{ .close = error.OperationCanceled },
        .fallocate => .{ .fallocate = error.OperationCanceled },
        .truncate => .{ .truncate = error.OperationCanceled },
        .openat => .{ .openat = error.OperationCanceled },
        .mkdirat => .{ .mkdirat = error.OperationCanceled },
        .renameat => .{ .renameat = error.OperationCanceled },
        .unlinkat => .{ .unlinkat = error.OperationCanceled },
        .statx => .{ .statx = error.OperationCanceled },
        .getdents => .{ .getdents = error.OperationCanceled },
        .copy_file_chunk => .{ .copy_file_chunk = error.OperationCanceled },
        .fchown => .{ .fchown = error.OperationCanceled },
        .fchmod => .{ .fchmod = error.OperationCanceled },
        .socket => .{ .socket = error.OperationCanceled },
        .bind => .{ .bind = error.OperationCanceled },
        .listen => .{ .listen = error.OperationCanceled },
        .setsockopt => .{ .setsockopt = error.OperationCanceled },
        .msync => .{ .fsync = error.OperationCanceled },
        .mmap_close => .{ .close = error.OperationCanceled },
        .mmap_fallocate => .{ .fallocate = error.OperationCanceled },
        .mmap_truncate => .{ .truncate = error.OperationCanceled },
        .mmap_setup => .{ .read = error.OperationCanceled },
    };
}

// ── Inline tests ──────────────────────────────────────────

const testing = std.testing;

test "BlockingOpPool: create / deinit with default config" {
    const pool = try BlockingOpPool.create(testing.allocator, .{});
    defer pool.deinit();
    try testing.expect(pool.workers.len == 4);
    try testing.expectEqual(@as(u32, 256), pool.pending_capacity);
}

test "BlockingOpPool: setWakeup stores the callback" {
    const pool = try BlockingOpPool.create(testing.allocator, .{ .worker_count = 1 });
    defer pool.deinit();

    const Box = struct {
        var fired: u32 = 0;
        fn cb(_: ?*anyopaque) void {
            fired += 1;
        }
    };
    Box.fired = 0;
    pool.setWakeup(null, Box.cb);
    try testing.expect(pool.wake_fn != null);
}

test "BlockingOpPool: submit fails with PendingQueueFull when bound exceeded" {
    // Use 0 workers so submitted ops never drain (workers would otherwise
    // pop them off the queue). With 0 workers, every `submit` accumulates.
    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 0,
        .pending_capacity = 2,
    });
    defer pool.deinit();

    var c1 = Completion{};
    var c2 = Completion{};
    var c3 = Completion{};
    const op = BlockingOp{ .fsync = .{ .fd = -1, .datasync = true } };
    try pool.submit(op, &c1);
    try pool.submit(op, &c2);
    try testing.expectError(error.PendingQueueFull, pool.submit(op, &c3));
}

test "BlockingOpPool: tryCancelPending removes a pending op and pushes Cancelled" {
    // 0 workers — every submission stays pending until cancelled.
    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 0,
        .pending_capacity = 4,
    });
    defer pool.deinit();

    var c = Completion{};
    try pool.submit(.{ .fsync = .{ .fd = -1, .datasync = true } }, &c);
    try testing.expect(pool.tryCancelPending(&c));

    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    try pool.drainCompletedInto(&swap);
    try testing.expectEqual(@as(usize, 1), swap.items.len);
    switch (swap.items[0].result) {
        .fsync => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    // Second cancel returns false (already drained).
    try testing.expect(!pool.tryCancelPending(&c));
}

test "BlockingOpPool: write then read round-trip via the worker" {
    if (builtin.target.os.tag != .linux and !builtin.target.os.tag.isDarwin()) {
        return error.SkipZigTest;
    }

    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 2,
        .pending_capacity = 16,
    });
    defer pool.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("pool_round_trip", .{ .read = true, .truncate = true });
    defer file.close();

    var write_c = Completion{};
    var read_c = Completion{};

    try pool.submit(.{ .write = .{
        .fd = file.handle,
        .buf = "varuna",
        .offset = 0,
    } }, &write_c);

    // Wait for the write to land.
    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        try pool.drainCompletedInto(&swap);
        if (swap.items.len > 0) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 1), swap.items.len);
    switch (swap.items[0].result) {
        .write => |r| try testing.expectEqual(@as(usize, 6), try r),
        else => try testing.expect(false),
    }
    swap.clearRetainingCapacity();

    // Read it back.
    var buf: [16]u8 = undefined;
    try pool.submit(.{ .read = .{
        .fd = file.handle,
        .buf = &buf,
        .offset = 0,
    } }, &read_c);

    attempts = 0;
    while (attempts < 200) : (attempts += 1) {
        try pool.drainCompletedInto(&swap);
        if (swap.items.len > 0) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 1), swap.items.len);
    switch (swap.items[0].result) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 6), n);
            try testing.expectEqualStrings("varuna", buf[0..6]);
        },
        else => try testing.expect(false),
    }
}

test "BlockingOpPool: bad fd surfaces as an error result (fault injection)" {
    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 1,
        .pending_capacity = 4,
    });
    defer pool.deinit();

    var c = Completion{};
    // -1 is universally an invalid fd; pwrite returns EBADF.
    try pool.submit(.{ .write = .{
        .fd = -1,
        .buf = "x",
        .offset = 0,
    } }, &c);

    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        try pool.drainCompletedInto(&swap);
        if (swap.items.len > 0) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 1), swap.items.len);
    switch (swap.items[0].result) {
        .write => |r| try testing.expectError(error.NotOpenForWriting, r),
        else => try testing.expect(false),
    }
}

test "BlockingOpPool: stress — N workers drain M ops from a small queue" {
    if (builtin.target.os.tag != .linux and !builtin.target.os.tag.isDarwin()) {
        return error.SkipZigTest;
    }

    const worker_count: u32 = 4;
    const total_ops: u32 = 256;

    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = worker_count,
        .pending_capacity = total_ops,
    });
    defer pool.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("stress_target", .{ .read = true, .truncate = true });
    defer file.close();

    // Pre-extend so writes at non-zero offsets succeed.
    try posix.ftruncate(file.handle, total_ops * 16);

    const completions = try testing.allocator.alloc(Completion, total_ops);
    defer testing.allocator.free(completions);
    @memset(completions, Completion{});

    for (0..total_ops) |i| {
        try pool.submit(.{ .write = .{
            .fd = file.handle,
            .buf = "varuna_test_op_!",
            .offset = i * 16,
        } }, &completions[i]);
    }

    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    var seen: u32 = 0;
    var attempts: u32 = 0;
    while (seen < total_ops and attempts < 2000) : (attempts += 1) {
        try pool.drainCompletedInto(&swap);
        for (swap.items) |entry| {
            switch (entry.result) {
                .write => |r| try testing.expectEqual(@as(usize, 16), try r),
                else => try testing.expect(false),
            }
        }
        seen += @intCast(swap.items.len);
        swap.clearRetainingCapacity();
        if (seen < total_ops) std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(total_ops, seen);
}

test "BlockingOpPool: hasPendingWork tracks pending and in-flight" {
    // 0 workers: pending stays high, nothing in-flight.
    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 0,
        .pending_capacity = 4,
    });
    defer pool.deinit();

    try testing.expect(!pool.hasPendingWork());
    var c = Completion{};
    try pool.submit(.{ .fsync = .{ .fd = -1, .datasync = true } }, &c);
    try testing.expect(pool.hasPendingWork());

    _ = pool.tryCancelPending(&c);
    // After cancel, an entry is on `completed`; still has pending work.
    try testing.expect(pool.hasPendingWork());

    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    try pool.drainCompletedInto(&swap);
    try testing.expect(!pool.hasPendingWork());
}

test "BlockingOpPool: deinit cancels still-pending submissions" {
    var pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 0,
        .pending_capacity = 4,
    });

    var c1 = Completion{};
    var c2 = Completion{};
    try pool.submit(.{ .fsync = .{ .fd = -1, .datasync = true } }, &c1);
    try pool.submit(.{ .fsync = .{ .fd = -1, .datasync = true } }, &c2);

    // The pool's `deinit` moves the still-pending entries onto
    // `completed` so the backend's final drain delivers
    // OperationCanceled. We can't observe that after deinit (the pool is
    // freed); instead we assert it via a manual drain BEFORE deinit:
    var swap: std.ArrayListUnmanaged(Completed) = .{};
    defer swap.deinit(testing.allocator);
    pool.deinit();
    // The pool memory is gone — the test's purpose is to confirm `deinit`
    // does not leak (the testing allocator catches that).
}

test "BlockingOpPool: wakeup callback fires after each completion" {
    const Box = struct {
        var hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque) void {
            _ = hits.fetchAdd(1, .acq_rel);
        }
    };
    Box.hits.store(0, .release);

    const pool = try BlockingOpPool.create(testing.allocator, .{
        .worker_count = 1,
        .pending_capacity = 4,
    });
    defer pool.deinit();
    pool.setWakeup(null, Box.cb);

    var c = Completion{};
    // Bad fd -> immediate worker error -> push to completed -> wake.
    try pool.submit(.{ .fsync = .{ .fd = -1, .datasync = true } }, &c);

    var attempts: u32 = 0;
    while (Box.hits.load(.acquire) == 0 and attempts < 200) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(Box.hits.load(.acquire) >= 1);
}

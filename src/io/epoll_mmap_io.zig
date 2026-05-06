//! EpollMmapIO — Linux epoll readiness backend with mmap-based file I/O.
//!
//! Companion to `epoll_posix_io.zig`. The readiness layer (epoll) is
//! identical — sockets, timers, and cancel are mechanically the same. The
//! axis that differs is file I/O:
//!
//!   * `epoll_posix_io.zig`: `pread`/`pwrite`/`fsync`/`fallocate` syscalls
//!     offloaded to a thread pool.
//!   * `epoll_mmap_io.zig` (this file): file is `mmap`'d at first access;
//!     reads/writes are `memcpy`s; `fsync` is `msync(MS_SYNC)`. Zero-copy,
//!     OS pagecache implicit. Page faults block the calling thread today
//!     (mitigation: `madvise(MADV_WILLNEED)` ahead of time when feasible);
//!     promote to a thread-pool memcpy if profiling shows it matters.
//!
//! ## Mapping lifecycle
//!
//!   1. First file op against `fd` runs `fstat(fd)` to get the file size,
//!      then `mmap(fd, 0..size, PROT_READ | PROT_WRITE, MAP_SHARED)` and
//!      records `(ptr, size)` in `file_mappings`.
//!   2. Subsequent reads/writes do `@memcpy` against the recorded mapping.
//!      If a write would extend past `size` we tear down the mapping and
//!      remap (the file should already have been `fallocate`d / `ftruncate`d
//!      to the necessary size; otherwise the write returns
//!      `error.AccessDenied` for SIGBUS-equivalent semantics).
//!   3. `fsync` runs `msync(ptr, size, MS_SYNC)` — stronger than
//!      `fdatasync` since `msync` flushes both data and any metadata
//!      changes accumulated against the mapping.
//!   4. `fallocate` calls `posix.fallocate` synchronously; if the file's
//!      mapping is now stale (size grew) the next access remaps.
//!   5. `truncate` calls `posix.ftruncate` synchronously; the existing
//!      mapping is unmapped so the next access remaps.
//!   6. `closeSocket` (used for files too — naming is historical) tears
//!      down any mapping for `fd` before `posix.close`.
//!
//! ## Page-fault discussion (deliberate MVP limitation)
//!
//! In the MVP, page faults block the EL thread. For varuna's workload
//! (large piece reads/writes from a small set of files) this is rarely a
//! problem if `madvise(MADV_WILLNEED)` is used proactively to warm the
//! pagecache before the read fires. None of varuna's reference codebases
//! (libxev, tigerbeetle, ZIO) use mmap for data-path file I/O — that's a
//! signal worth respecting. If profiling shows page-fault stalls matter,
//! the mitigation is to run the `memcpy` itself on a thread pool so the
//! EL keeps making progress while a fault resolves. Tracked under
//! "EpollMmapIO file-op page-fault mitigation" in
//! `progress-reports/2026-04-30-epoll-bifurcation.md`.
//!
//! See `reference-codebases/libxev/src/backend/epoll.zig` for the canonical
//! readiness-loop reference; the file-op story is novel to varuna.

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
const posix_file_pool = @import("posix_file_pool.zig");
const PosixFilePool = posix_file_pool.PosixFilePool;
const FileOp = posix_file_pool.FileOp;
const PoolCompleted = posix_file_pool.Completed;

// ── Backend state ─────────────────────────────────────────
//
// Shared layout with EpollPosixIO. Fits in `ifc.backend_state_size = 64`
// bytes.

const sentinel_index: u32 = std.math.maxInt(u32);

const FdInterest = enum(u8) {
    none,
    read,
    write,
    poll,
};

const PosixCopyFileSessionState = struct {
    open: bool = false,
    copy_in_flight: bool = false,
    poisoned: bool = false,
};

pub const EpollState = struct {
    in_flight: bool = false,
    epoll_registered: bool = false,
    accept_multishot: bool = false,
    interest: FdInterest = .none,
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
    /// Initial capacity for the timer heap. Mirrors EpollPosixIO.Config.
    max_completions: u32 = 1024,
    /// Worker pool used by semantic file-copy and metadata ops. The mmap
    /// strategy keeps normal read/write on mappings, but copy sessions and
    /// fchown/fchmod must not run blocking syscalls on the event-loop thread.
    file_pool_workers: u32 = 4,
    file_pool_pending_capacity: u32 = 256,
};

// ── Mmap bookkeeping ──────────────────────────────────────

const MmapEntry = struct {
    /// Base pointer of the mapping. Points into the virtual address space.
    ptr: [*]u8,
    /// Size of the mapping in bytes.
    size: usize,
};

const FdRegistration = struct {
    read: ?*Completion = null,
    write_head: ?*Completion = null,
    write_tail: ?*Completion = null,
    poll: ?*Completion = null,

    fn isEmpty(self: FdRegistration) bool {
        return self.read == null and self.write_head == null and self.poll == null;
    }
};

fn writeQueueAppend(reg: *FdRegistration, c: *Completion) void {
    c.next = null;
    if (reg.write_tail) |tail| {
        tail.next = c;
    } else {
        reg.write_head = c;
    }
    reg.write_tail = c;
}

fn writeQueuePrepend(reg: *FdRegistration, c: *Completion) void {
    c.next = reg.write_head;
    reg.write_head = c;
    if (reg.write_tail == null) reg.write_tail = c;
}

fn writeQueuePop(reg: *FdRegistration) ?*Completion {
    const head = reg.write_head orelse return null;
    reg.write_head = head.next;
    if (reg.write_head == null) reg.write_tail = null;
    head.next = null;
    return head;
}

fn writeQueueRemove(reg: *FdRegistration, c: *Completion) bool {
    var prev: ?*Completion = null;
    var cur = reg.write_head;
    while (cur) |entry| {
        if (entry == c) {
            const next = entry.next;
            if (prev) |p| {
                p.next = next;
            } else {
                reg.write_head = next;
            }
            if (reg.write_tail == entry) reg.write_tail = prev;
            entry.next = null;
            return true;
        }
        prev = entry;
        cur = entry.next;
    }
    return false;
}

const MmapCompleted = struct {
    completion: *Completion,
    result: Result,
};

// ── Timer heap ────────────────────────────────────────────
//
// Same shape as EpollPosixIO. O(n) peek-min is fine for varuna's
// timer counts.

const TimerHeap = struct {
    entries: std.array_list.Managed(*Completion),

    fn init(allocator: std.mem.Allocator, capacity: u32) !TimerHeap {
        var entries = std.array_list.Managed(*Completion).init(allocator);
        try entries.ensureTotalCapacity(capacity);
        return .{ .entries = entries };
    }

    fn deinit(self: *TimerHeap) void {
        self.entries.deinit();
    }

    fn push(self: *TimerHeap, c: *Completion) !void {
        try self.entries.append(c);
        epollState(c).timer_heap_index = @intCast(self.entries.items.len - 1);
    }

    fn peekMin(self: *TimerHeap) ?*Completion {
        if (self.entries.items.len == 0) return null;
        var min_idx: usize = 0;
        var min_deadline = epollState(self.entries.items[0]).deadline_ns;
        for (self.entries.items[1..], 1..) |c, i| {
            const d = epollState(c).deadline_ns;
            if (d < min_deadline) {
                min_deadline = d;
                min_idx = i;
            }
        }
        return self.entries.items[min_idx];
    }

    fn remove(self: *TimerHeap, c: *Completion) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (entry == c) {
                _ = self.entries.swapRemove(i);
                epollState(c).timer_heap_index = sentinel_index;
                if (i < self.entries.items.len) {
                    epollState(self.entries.items[i]).timer_heap_index = @intCast(i);
                }
                return true;
            }
        }
        return false;
    }
};

// ── EpollMmapIO ───────────────────────────────────────────

pub const EpollMmapIO = struct {
    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,
    wakeup_ctx: *posix.fd_t,
    /// Cross-thread wakeup primitive (mirrors EpollPosixIO).
    wakeup_fd: posix.fd_t,
    /// Active in-flight count (for `tick(wait_at_least)` semantics).
    active: u32 = 0,
    timers: TimerHeap,
    cached_now_ns: u64 = 0,
    /// Per-fd mmap state. Populated lazily on first file op against `fd`.
    file_mappings: std.AutoHashMap(posix.fd_t, MmapEntry),
    mmap_completed: std.ArrayListUnmanaged(MmapCompleted) = .{},
    mmap_completed_swap: std.ArrayListUnmanaged(MmapCompleted) = .{},
    pool: *PosixFilePool,
    pool_swap: std.ArrayListUnmanaged(PoolCompleted) = .{},
    fd_registrations: std.AutoHashMap(posix.fd_t, FdRegistration),
    /// Completion currently being dispatched on the write lane. If its
    /// callback submits the same completion again (partial send), queue it
    /// at the front so later same-fd sends cannot interleave into the TCP
    /// byte stream.
    requeue_write_front: ?*Completion = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !EpollMmapIO {
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

        const wakeup_ctx = try allocator.create(posix.fd_t);
        errdefer allocator.destroy(wakeup_ctx);
        wakeup_ctx.* = wakeup_fd;

        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = wakeup_fd },
        };
        const ctl_rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wakeup_fd, &ev);
        switch (linux.E.init(ctl_rc)) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }

        const pool = try PosixFilePool.create(allocator, .{
            .worker_count = config.file_pool_workers,
            .pending_capacity = config.file_pool_pending_capacity,
        });
        errdefer pool.deinit();
        pool.setWakeup(wakeup_ctx, wakeFromPool);

        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .wakeup_ctx = wakeup_ctx,
            .wakeup_fd = wakeup_fd,
            .timers = try TimerHeap.init(allocator, config.max_completions),
            .file_mappings = std.AutoHashMap(posix.fd_t, MmapEntry).init(allocator),
            .pool = pool,
            .fd_registrations = std.AutoHashMap(posix.fd_t, FdRegistration).init(allocator),
        };
    }

    pub fn deinit(self: *EpollMmapIO) void {
        self.pool.deinit();
        self.pool_swap.deinit(self.allocator);
        // Tear down any remaining mappings before freeing the map itself.
        var it = self.file_mappings.valueIterator();
        while (it.next()) |entry| {
            posix.munmap(@alignCast(entry.ptr[0..entry.size]));
        }
        self.file_mappings.deinit();
        self.mmap_completed.deinit(self.allocator);
        self.mmap_completed_swap.deinit(self.allocator);
        self.fd_registrations.deinit();
        self.timers.deinit();
        self.allocator.destroy(self.wakeup_ctx);
        posix.close(self.wakeup_fd);
        posix.close(self.epoll_fd);
        self.* = undefined;
    }

    fn wakeFromPool(ctx: ?*anyopaque) void {
        const wakeup_fd: *const posix.fd_t = @ptrCast(@alignCast(ctx.?));
        const val: u64 = 1;
        _ = posix.write(wakeup_fd.*, std.mem.asBytes(&val)) catch {};
    }

    /// Synchronously close a file descriptor. Used for both sockets and
    /// regular files (the contract method is named `closeSocket` for
    /// historical reasons). Tears down any mmap mapping for `fd` first.
    pub fn closeSocket(self: *EpollMmapIO, fd: posix.fd_t) void {
        self.unmapFile(fd);
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        if (self.fd_registrations.fetchRemove(fd)) |entry| {
            self.cancelRegisteredCompletion(entry.value.read);
            self.cancelWriteQueue(entry.value.write_head);
            self.cancelRegisteredCompletion(entry.value.poll);
        }
        posix.close(fd);
    }

    // ── Main loop ─────────────────────────────────────────

    pub fn tick(self: *EpollMmapIO, wait_at_least: u32) !void {
        self.updateNow();

        var fired: u32 = 0;
        try self.fireExpiredTimers(&fired);
        try self.drainMmapCompletions(&fired);
        try self.drainPool(&fired);

        if (self.active == 0) return;
        if (wait_at_least != 0 and fired >= wait_at_least) return;

        const timeout_ms: i32 = self.computeEpollTimeout(wait_at_least, fired);

        var events: [128]linux.epoll_event = undefined;
        const n_rc = linux.epoll_pwait(self.epoll_fd, &events, events.len, timeout_ms, null);
        const n: usize = switch (linux.E.init(n_rc)) {
            .SUCCESS => @intCast(n_rc),
            .INTR => 0,
            else => |e| return posix.unexpectedErrno(e),
        };

        self.updateNow();

        for (events[0..n]) |ev| {
            if (ev.data.fd == self.wakeup_fd) {
                var buf: u64 = 0;
                _ = posix.read(self.wakeup_fd, std.mem.asBytes(&buf)) catch {};
                continue;
            }
            try self.dispatchFdReady(ev.data.fd, ev.events);
        }

        try self.fireExpiredTimers(&fired);
        try self.drainMmapCompletions(&fired);
        try self.drainPool(&fired);
    }

    fn drainPool(self: *EpollMmapIO, fired: *u32) !void {
        try self.pool.drainCompletedInto(&self.pool_swap);
        defer self.pool_swap.clearRetainingCapacity();
        for (self.pool_swap.items) |entry| {
            try self.dispatchPoolEntry(entry, fired);
        }
    }

    fn dispatchPoolEntry(self: *EpollMmapIO, entry: PoolCompleted, fired: *u32) !void {
        const c = entry.completion;
        const st = epollState(c);
        st.in_flight = false;
        self.active -|= 1;
        fired.* += 1;
        switch (c.op) {
            .copy_file_chunk => |op| op.session.backendStateAs(PosixCopyFileSessionState).copy_in_flight = false,
            else => {},
        }

        const cb = c.callback orelse return;
        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => switch (c.op) {
                .copy_file_chunk => |op| try self.copy_file_chunk(op, c, c.userdata, cb),
                .fchown => |op| try self.fchown(op, c, c.userdata, cb),
                .fchmod => |op| try self.fchmod(op, c, c.userdata, cb),
                else => {},
            },
        }
    }

    fn drainMmapCompletions(self: *EpollMmapIO, fired: *u32) !void {
        if (self.mmap_completed.items.len == 0) return;

        std.mem.swap(
            std.ArrayListUnmanaged(MmapCompleted),
            &self.mmap_completed,
            &self.mmap_completed_swap,
        );
        defer self.mmap_completed_swap.clearRetainingCapacity();

        for (self.mmap_completed_swap.items) |entry| {
            try self.dispatchMmapEntry(entry, fired);
        }
    }

    fn dispatchMmapEntry(self: *EpollMmapIO, entry: MmapCompleted, fired: *u32) !void {
        const c = entry.completion;
        const st = epollState(c);
        st.in_flight = false;
        self.active -|= 1;
        fired.* += 1;

        const cb = c.callback orelse return;
        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => switch (c.op) {
                .read => |op| try self.read(op, c, c.userdata, cb),
                .write => |op| try self.write(op, c, c.userdata, cb),
                .fsync => |op| try self.fsync(op, c, c.userdata, cb),
                .fallocate => |op| try self.fallocate(op, c, c.userdata, cb),
                .truncate => |op| try self.truncate(op, c, c.userdata, cb),
                .open_copy_file_session => |op| try self.open_copy_file_session(op, c, c.userdata, cb),
                .copy_file_chunk => |op| try self.copy_file_chunk(op, c, c.userdata, cb),
                .close_copy_file_session => |op| try self.close_copy_file_session(op, c, c.userdata, cb),
                .fchown => |op| try self.fchown(op, c, c.userdata, cb),
                .fchmod => |op| try self.fchmod(op, c, c.userdata, cb),
                else => {},
            },
        }
    }

    fn computeEpollTimeout(self: *EpollMmapIO, wait_at_least: u32, fired: u32) i32 {
        // Non-blocking tick: caller wants epoll_pwait to return immediately
        // regardless of how far away the next timer is. Without this guard,
        // a future timer's deadline_ns would be returned even for tick(0),
        // so the kernel would block for that duration (e.g. up to the 30 s
        // periodic-sync interval) — turning what callers expect to be a
        // non-blocking sweep into a multi-second hang. Mirrors RealIO's
        // `submit_and_wait(0)` semantics.
        if (wait_at_least == 0) return 0;
        if (fired >= wait_at_least) return 0;
        const next_deadline = if (self.timers.peekMin()) |t|
            epollState(t).deadline_ns
        else
            return -1;

        if (next_deadline <= self.cached_now_ns) return 0;
        const ns_remaining = next_deadline - self.cached_now_ns;
        const ms_remaining = (ns_remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        return @intCast(@min(ms_remaining, @as(u64, std.math.maxInt(i32))));
    }

    fn updateNow(self: *EpollMmapIO) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        if (linux.E.init(rc) == .SUCCESS) {
            const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch
                std.math.maxInt(u64);
            self.cached_now_ns = std.math.add(u64, sec_ns, @intCast(ts.nsec)) catch
                std.math.maxInt(u64);
        }
    }

    fn fireExpiredTimers(self: *EpollMmapIO, fired: *u32) !void {
        while (self.timers.peekMin()) |c| {
            const st = epollState(c);
            if (st.deadline_ns > self.cached_now_ns) break;

            _ = self.timers.remove(c);
            st.in_flight = false;
            self.active -|= 1;
            fired.* += 1;

            const cb = c.callback orelse continue;
            const action = cb(c.userdata, c, .{ .timeout = {} });
            switch (action) {
                .disarm => {},
                .rearm => switch (c.op) {
                    .timeout => |t_op| try self.timeout(t_op, c, c.userdata, cb),
                    else => {},
                },
            }
        }
    }

    fn dispatchFdReady(self: *EpollMmapIO, fd: posix.fd_t, events: u32) !void {
        const reg = self.fd_registrations.getPtr(fd) orelse return;

        var write_c: ?*Completion = null;
        var read_c: ?*Completion = null;
        var poll_c: ?*Completion = null;

        if (reg.write_head != null) {
            if ((events & (linux.EPOLL.OUT | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0) {
                write_c = writeQueuePop(reg);
                if (write_c) |c| self.clearRegisteredCompletion(c);
            }
        }
        if (reg.read) |c| {
            if ((events & (linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0) {
                read_c = c;
                reg.read = null;
                self.clearRegisteredCompletion(c);
            }
        }
        if (reg.poll) |c| {
            const poll_events = switch (c.op) {
                .poll => |op| op.events,
                else => 0,
            };
            if ((events & (poll_events | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0) {
                poll_c = c;
                reg.poll = null;
                self.clearRegisteredCompletion(c);
            }
        }

        try self.updateFdRegistration(fd);

        if (write_c) |c| try self.dispatchReadyCompletion(c, events);
        if (read_c) |c| try self.dispatchReadyCompletion(c, events);
        if (poll_c) |c| try self.dispatchReadyCompletion(c, events);
    }

    fn dispatchReadyCompletion(self: *EpollMmapIO, c: *Completion, events: u32) !void {
        const st = epollState(c);
        const cb = c.callback orelse return;
        std.debug.assert(!st.epoll_registered);
        std.debug.assert(!st.in_flight);

        const prioritize_requeue = fdInterestForCompletion(c) == .write;
        if (prioritize_requeue) self.requeue_write_front = c;
        defer if (prioritize_requeue and self.requeue_write_front == c) {
            self.requeue_write_front = null;
        };

        const result = performInline(c, events);
        const action = cb(c.userdata, c, result);
        switch (action) {
            .disarm => {},
            .rearm => try self.resubmit(c),
        }
    }

    fn resubmit(self: *EpollMmapIO, c: *Completion) !void {
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

    // ── Submission methods (sockets, mirrored from EpollPosixIO) ──

    pub fn socket(self: *EpollMmapIO, op_in: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .socket = op }, ud, cb);
            const sock_type = op.sock_type | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
            const result: Result = if (posix.socket(@intCast(op.domain), sock_type, op.protocol)) |fd|
                .{ .socket = fd }
            else |err|
                .{ .socket = err };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .socket => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn connect(self: *EpollMmapIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);
        const addrlen = op.addr.getOsSockLen();
        if (posix.connect(op.fd, &op.addr.any, addrlen)) {
            const action = try self.deliverInline(c, .{ .connect = {} });
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .connect => |new_op| try self.connect(new_op, c, ud, cb),
                    else => return,
                },
            }
            return;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => {
                const action = try self.deliverInline(c, .{ .connect = err });
                switch (action) {
                    .disarm => return,
                    .rearm => switch (c.op) {
                        .connect => |new_op| try self.connect(new_op, c, ud, cb),
                        else => return,
                    },
                }
                return;
            },
        }
        try self.registerFd(c, op.fd, linux.EPOLL.OUT);
        _ = op.deadline_ns;
    }

    pub fn accept(self: *EpollMmapIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        epollState(c).accept_multishot = op.multishot;
        try self.registerFd(c, op.fd, linux.EPOLL.IN);
    }

    pub fn recv(self: *EpollMmapIO, op_in: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.IN);
    }

    pub fn send(self: *EpollMmapIO, op_in: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.OUT);
    }

    pub fn recvmsg(self: *EpollMmapIO, op_in: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.IN);
    }

    pub fn sendmsg(self: *EpollMmapIO, op_in: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.OUT);
    }

    /// Synchronous fallback. Same shape as `EpollPosixIO.bind`.
    pub fn bind(self: *EpollMmapIO, op_in: ifc.BindOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .bind = op }, ud, cb);

            const result: Result = if (posix.bind(op.fd, &op.addr.any, op.addr.getOsSockLen())) |_|
                .{ .bind = {} }
            else |err|
                .{ .bind = err };

            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .bind => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn listen(self: *EpollMmapIO, op_in: ifc.ListenOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .listen = op }, ud, cb);

            const result: Result = if (posix.listen(op.fd, op.backlog)) |_|
                .{ .listen = {} }
            else |err|
                .{ .listen = err };

            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .listen => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn setsockopt(self: *EpollMmapIO, op_in: ifc.SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .setsockopt = op }, ud, cb);

            const result: Result = if (posix.setsockopt(op.fd, @intCast(op.level), op.optname, op.optval)) |_|
                .{ .setsockopt = {} }
            else |err|
                .{ .setsockopt = err };

            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .setsockopt => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn openat(self: *EpollMmapIO, op_in: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .openat = op }, ud, cb);
            const result: Result = if (posix.openat(op.dir_fd, op.path, op.flags, op.mode)) |fd|
                .{ .openat = fd }
            else |err|
                .{ .openat = err };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .openat => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn mkdirat(self: *EpollMmapIO, op_in: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .mkdirat = op }, ud, cb);
            const result: Result = if (posix.mkdirat(op.dir_fd, op.path, op.mode)) |_|
                .{ .mkdirat = {} }
            else |err|
                .{ .mkdirat = err };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .mkdirat => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn renameat(self: *EpollMmapIO, op_in: ifc.RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .renameat = op }, ud, cb);
            const result: Result = if (op.flags != 0)
                .{ .renameat = error.OperationNotSupported }
            else if (posix.renameat(op.old_dir_fd, op.old_path, op.new_dir_fd, op.new_path)) |_|
                .{ .renameat = {} }
            else |err|
                .{ .renameat = err };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .renameat => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn unlinkat(self: *EpollMmapIO, op_in: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .unlinkat = op }, ud, cb);
            const result: Result = if (posix.unlinkat(op.dir_fd, op.path, op.flags)) |_|
                .{ .unlinkat = {} }
            else |err|
                .{ .unlinkat = err };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .unlinkat => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn statx(self: *EpollMmapIO, op_in: ifc.StatxOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .statx = op }, ud, cb);
            const rc = linux.statx(op.dir_fd, op.path, op.flags, op.mask, op.buf);
            const result: Result = switch (linux.E.init(rc)) {
                .SUCCESS => .{ .statx = {} },
                else => |err| .{ .statx = ifc.linuxErrnoToError(err) },
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .statx => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn getdents(self: *EpollMmapIO, op_in: ifc.GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .getdents = op }, ud, cb);
            const rc = linux.getdents64(op.fd, op.buf.ptr, op.buf.len);
            const result: Result = switch (linux.E.init(rc)) {
                .SUCCESS => .{ .getdents = rc },
                else => |err| .{ .getdents = ifc.linuxErrnoToError(err) },
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .getdents => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn timeout(self: *EpollMmapIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        self.updateNow();
        const deadline = std.math.add(u64, self.cached_now_ns, op.ns) catch
            std.math.maxInt(u64);
        epollState(c).deadline_ns = deadline;
        try self.timers.push(c);
        self.active += 1;
    }

    pub fn poll(self: *EpollMmapIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        try self.registerFd(c, op.fd, op.events);
    }

    pub fn cancel(self: *EpollMmapIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);

        const target = op.target;
        const tst = epollState(target);
        var found = false;

        if (tst.timer_heap_index != sentinel_index) {
            if (self.timers.remove(target)) {
                found = true;
                tst.in_flight = false;
                self.active -|= 1;
                if (target.callback) |target_cb| {
                    _ = target_cb(target.userdata, target, .{ .timeout = error.OperationCanceled });
                }
            }
        }

        if (!found and tst.epoll_registered) {
            _ = try self.unregisterCompletion(target);
            found = true;

            if (target.callback) |target_cb| {
                _ = target_cb(target.userdata, target, makeCancelledResult(target.op));
            }
        }

        if (!found) {
            const target_is_file = switch (target.op) {
                .copy_file_chunk, .fchown, .fchmod => true,
                else => false,
            };
            if (target_is_file and self.pool.tryCancelPending(target)) {
                found = true;
            }
        }

        const result: Result = if (found) .{ .cancel = {} } else .{ .cancel = error.OperationNotFound };
        const action = try self.deliverInline(c, result);
        switch (action) {
            .disarm => return,
            .rearm => switch (c.op) {
                .cancel => |new_op| try self.cancel(new_op, c, ud, cb),
                else => return,
            },
        }
    }

    // ── File ops (mmap-backed) ────────────────────────────
    //
    // Read / write are synchronous from the EL's POV — they `memcpy`
    // against the per-fd mapping. Page faults block this thread; see the
    // file header for the mitigation discussion.
    //
    // The mapping is established lazily on first access (`fstat` to size
    // the mapping; `mmap` PROT_READ | PROT_WRITE). A subsequent `pwrite`
    // that needs to extend past the current mapping triggers a remap if
    // the file has already been resized via `fallocate` / `truncate`.

    pub fn read(self: *EpollMmapIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        const result: Result = blk: {
            const entry = self.ensureMapping(op.fd) catch |err| break :blk .{ .read = err };
            const offset_us: usize = @intCast(op.offset);
            if (offset_us >= entry.size) break :blk .{ .read = @as(usize, 0) };
            const available = entry.size - offset_us;
            const n = @min(op.buf.len, available);
            @memcpy(op.buf[0..n], entry.ptr[offset_us..][0..n]);
            break :blk .{ .read = n };
        };
        try self.enqueueMmapCompletion(c, result);
    }

    pub fn write(self: *EpollMmapIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const result: Result = blk: {
            const offset_us: usize = @intCast(op.offset);
            const required = offset_us + op.buf.len;

            // Refresh mapping; if the file has grown beyond the current
            // mapping we remap to pick up the new size.
            var entry = self.ensureMapping(op.fd) catch |err| break :blk .{ .write = err };
            if (required > entry.size) {
                self.unmapFile(op.fd);
                entry = self.ensureMapping(op.fd) catch |err| break :blk .{ .write = err };
            }
            if (required > entry.size) {
                // File still too small; caller must `fallocate` /
                // `truncate` first. Surface ENOSPC-equivalent so callers'
                // existing fallocate-fallback paths can react.
                break :blk .{ .write = error.NoSpaceLeft };
            }
            @memcpy(entry.ptr[offset_us..][0..op.buf.len], op.buf);
            break :blk .{ .write = op.buf.len };
        };
        try self.enqueueMmapCompletion(c, result);
    }

    pub fn fsync(self: *EpollMmapIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        const result: Result = blk: {
            // If we have a mapping, msync flushes both data and metadata
            // changes accumulated against the mapping (stronger than
            // fdatasync — `op.datasync` is honoured semantically by virtue
            // of the call still flushing dirty pages).
            if (self.file_mappings.get(op.fd)) |entry| {
                const slice: []align(std.heap.page_size_min) u8 = @alignCast(entry.ptr[0..entry.size]);
                posix.msync(slice, posix.MSF.SYNC) catch |err| break :blk .{ .fsync = err };
                break :blk .{ .fsync = {} };
            }
            // Fall back to plain fsync/fdatasync if no mapping established
            // yet (e.g. a freshly-truncated file with no reads/writes
            // pending).
            const rc = if (op.datasync) linux.fdatasync(op.fd) else linux.fsync(op.fd);
            switch (linux.E.init(rc)) {
                .SUCCESS => break :blk .{ .fsync = {} },
                .IO => break :blk .{ .fsync = error.InputOutput },
                .NOSPC => break :blk .{ .fsync = error.NoSpaceLeft },
                else => |e| break :blk .{ .fsync = posix.unexpectedErrno(e) },
            }
        };
        try self.enqueueMmapCompletion(c, result);
    }

    pub fn close(self: *EpollMmapIO, op: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .close = op }, ud, cb);
        self.unmapFile(op.fd);
        posix.close(op.fd);
        try self.enqueueMmapCompletion(c, .{ .close = {} });
    }

    pub fn fallocate(self: *EpollMmapIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        const result: Result = blk: {
            // Drop any stale mapping; the next access remaps to the new
            // size.
            self.unmapFile(op.fd);
            const rc = linux.fallocate(
                op.fd,
                op.mode,
                @intCast(op.offset),
                @intCast(op.len),
            );
            switch (linux.E.init(rc)) {
                .SUCCESS => break :blk .{ .fallocate = {} },
                .NOSPC => break :blk .{ .fallocate = error.NoSpaceLeft },
                .OPNOTSUPP => break :blk .{ .fallocate = error.OperationNotSupported },
                .IO => break :blk .{ .fallocate = error.InputOutput },
                else => |e| break :blk .{ .fallocate = posix.unexpectedErrno(e) },
            }
        };
        try self.enqueueMmapCompletion(c, result);
    }

    pub fn truncate(self: *EpollMmapIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        const result: Result = blk: {
            self.unmapFile(op.fd);
            posix.ftruncate(op.fd, op.length) catch |err| break :blk .{ .truncate = err };
            break :blk .{ .truncate = {} };
        };
        try self.enqueueMmapCompletion(c, result);
    }

    pub fn open_copy_file_session(self: *EpollMmapIO, op: ifc.OpenCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .open_copy_file_session = op }, ud, cb);
        const st = op.session.backendStateAs(PosixCopyFileSessionState);
        if (st.copy_in_flight) return try self.enqueueMmapCompletion(c, .{ .open_copy_file_session = error.AlreadyInFlight });
        if (st.open) return try self.enqueueMmapCompletion(c, .{ .open_copy_file_session = error.InvalidState });
        st.* = .{ .open = true };
        try self.enqueueMmapCompletion(c, .{ .open_copy_file_session = {} });
    }

    pub fn copy_file_chunk(self: *EpollMmapIO, op: ifc.CopyFileChunkOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_chunk = op }, ud, cb);
        const st = op.session.backendStateAs(PosixCopyFileSessionState);
        if (!st.open or st.poisoned) return try self.enqueueMmapCompletion(c, .{ .copy_file_chunk = error.InvalidState });
        if (st.copy_in_flight) return try self.enqueueMmapCompletion(c, .{ .copy_file_chunk = error.AlreadyInFlight });
        if (op.len == 0) return try self.enqueueMmapCompletion(c, .{ .copy_file_chunk = error.InvalidArgument });
        st.copy_in_flight = true;
        try self.submitFileOp(.{ .copy_file_chunk = op }, c);
    }

    pub fn close_copy_file_session(self: *EpollMmapIO, op: ifc.CloseCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .close_copy_file_session = op }, ud, cb);
        const st = op.session.backendStateAs(PosixCopyFileSessionState);
        if (st.copy_in_flight) return try self.enqueueMmapCompletion(c, .{ .close_copy_file_session = error.AlreadyInFlight });
        st.* = .{};
        try self.enqueueMmapCompletion(c, .{ .close_copy_file_session = {} });
    }

    pub fn fchown(self: *EpollMmapIO, op: ifc.FchownOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fchown = op }, ud, cb);
        try self.submitFileOp(.{ .fchown = op }, c);
    }

    pub fn fchmod(self: *EpollMmapIO, op: ifc.FchmodOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fchmod = op }, ud, cb);
        try self.submitFileOp(.{ .fchmod = op }, c);
    }

    fn submitFileOp(self: *EpollMmapIO, op: FileOp, c: *Completion) !void {
        self.active += 1;
        self.pool.submit(op, c) catch |err| {
            self.active -|= 1;
            epollState(c).in_flight = false;
            switch (op) {
                .copy_file_chunk => |p| p.session.backendStateAs(PosixCopyFileSessionState).copy_in_flight = false,
                else => {},
            }
            return err;
        };
    }

    // ── Mmap helpers ──────────────────────────────────────

    fn ensureMapping(self: *EpollMmapIO, fd: posix.fd_t) !MmapEntry {
        if (self.file_mappings.get(fd)) |entry| return entry;

        // `fstat` to size the mapping. A zero-byte file produces a
        // zero-byte mapping; mmap rejects that, so we treat it as a
        // valid empty mapping (no allocation; reads/writes against the
        // zero region naturally return zero / NoSpaceLeft).
        var st: linux.Stat = undefined;
        const rc = linux.fstat(fd, &st);
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .BADF => return error.BadFileDescriptor,
            else => |e| return posix.unexpectedErrno(e),
        }
        const size: usize = @intCast(st.size);
        if (size == 0) {
            const entry: MmapEntry = .{ .ptr = @ptrFromInt(@alignOf(usize)), .size = 0 };
            try self.file_mappings.put(fd, entry);
            return entry;
        }

        const slice = try posix.mmap(
            null,
            size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        // `madvise(MADV_WILLNEED)` warms the pagecache so the first
        // memcpy doesn't stall on a synchronous page fault. Best-effort
        // — failure is fine.
        _ = posix.madvise(slice.ptr, slice.len, posix.MADV.WILLNEED) catch {};

        const entry: MmapEntry = .{ .ptr = slice.ptr, .size = slice.len };
        try self.file_mappings.put(fd, entry);
        return entry;
    }

    fn unmapFile(self: *EpollMmapIO, fd: posix.fd_t) void {
        if (self.file_mappings.fetchRemove(fd)) |kv| {
            if (kv.value.size > 0) {
                const slice: []align(std.heap.page_size_min) u8 = @alignCast(kv.value.ptr[0..kv.value.size]);
                posix.munmap(slice);
            }
        }
    }

    // ── Internal helpers (mirrored from EpollPosixIO) ─────

    fn armCompletion(self: *EpollMmapIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        const st = epollState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .in_flight = true };
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }

    fn registerFd(self: *EpollMmapIO, c: *Completion, fd: posix.fd_t, events: u32) !void {
        _ = events;
        const interest = fdInterestForCompletion(c);
        const gop = try self.fd_registrations.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const reg = gop.value_ptr;

        switch (interest) {
            .read, .poll => {
                const lane: *?*Completion = switch (interest) {
                    .read => &reg.read,
                    .poll => &reg.poll,
                    else => unreachable,
                };
                if (lane.* != null and lane.* != c) {
                    epollState(c).in_flight = false;
                    return error.AlreadyInFlight;
                }
                lane.* = c;
            },
            .write => {
                if (self.requeue_write_front == c) {
                    writeQueuePrepend(reg, c);
                } else {
                    writeQueueAppend(reg, c);
                }
            },
            .none => {
                epollState(c).in_flight = false;
                return error.UnsupportedOperation;
            },
        }

        self.updateFdRegistration(fd) catch |err| {
            switch (interest) {
                .read => {
                    if (reg.read == c) reg.read = null;
                },
                .write => _ = writeQueueRemove(reg, c),
                .poll => {
                    if (reg.poll == c) reg.poll = null;
                },
                .none => {},
            }
            if (reg.isEmpty()) _ = self.fd_registrations.remove(fd);
            const st = epollState(c);
            st.in_flight = false;
            st.epoll_registered = false;
            st.registered_fd = -1;
            st.interest = .none;
            return err;
        };

        const st = epollState(c);
        st.epoll_registered = true;
        st.registered_fd = fd;
        st.interest = interest;
        self.active += 1;
    }

    fn updateFdRegistration(self: *EpollMmapIO, fd: posix.fd_t) !void {
        const reg = self.fd_registrations.get(fd) orelse return;
        if (reg.isEmpty()) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            _ = self.fd_registrations.remove(fd);
            return;
        }

        var ev: linux.epoll_event = .{
            .events = fdRegistrationEvents(reg),
            .data = .{ .fd = fd },
        };
        const mod_rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
        switch (linux.E.init(mod_rc)) {
            .SUCCESS => return,
            .NOENT => {},
            .BADF => return error.FileDescriptorInvalid,
            .PERM => return error.FileDescriptorIncompatibleWithEpoll,
            else => |e| return posix.unexpectedErrno(e),
        }

        const add_rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
        switch (linux.E.init(add_rc)) {
            .SUCCESS => {},
            .EXIST => {
                const retry_rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
                switch (linux.E.init(retry_rc)) {
                    .SUCCESS => {},
                    else => |e| return posix.unexpectedErrno(e),
                }
            },
            .NOMEM, .NOSPC => return error.SystemResources,
            .PERM => return error.FileDescriptorIncompatibleWithEpoll,
            .BADF => return error.FileDescriptorInvalid,
            else => |e| return posix.unexpectedErrno(e),
        }
    }

    fn unregisterCompletion(self: *EpollMmapIO, c: *Completion) !bool {
        const st = epollState(c);
        if (!st.epoll_registered) return false;
        const fd = st.registered_fd;
        if (self.fd_registrations.getPtr(fd)) |reg| {
            switch (st.interest) {
                .read => {
                    if (reg.read == c) reg.read = null;
                },
                .write => {
                    _ = writeQueueRemove(reg, c);
                },
                .poll => {
                    if (reg.poll == c) reg.poll = null;
                },
                .none => {},
            }
        }
        self.clearRegisteredCompletion(c);
        try self.updateFdRegistration(fd);
        return true;
    }

    fn cancelRegisteredCompletion(self: *EpollMmapIO, c: ?*Completion) void {
        const completion = c orelse return;
        self.clearRegisteredCompletion(completion);
        completion.next = null;
        if (completion.callback) |cb| {
            _ = cb(completion.userdata, completion, makeCancelledResult(completion.op));
        }
    }

    fn cancelWriteQueue(self: *EpollMmapIO, head: ?*Completion) void {
        var cur = head;
        while (cur) |completion| {
            const next = completion.next;
            self.cancelRegisteredCompletion(completion);
            cur = next;
        }
    }

    fn clearRegisteredCompletion(self: *EpollMmapIO, c: *Completion) void {
        const st = epollState(c);
        st.in_flight = false;
        st.epoll_registered = false;
        st.registered_fd = -1;
        st.interest = .none;
        self.active -|= 1;
    }

    fn fdInterestForCompletion(c: *const Completion) FdInterest {
        return switch (c.op) {
            .recv, .recvmsg, .accept => .read,
            .send, .sendmsg, .connect => .write,
            .poll => .poll,
            else => .none,
        };
    }

    fn fdRegistrationEvents(reg: FdRegistration) u32 {
        var events: u32 = linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP;
        if (reg.read != null) events |= linux.EPOLL.IN;
        if (reg.write_head != null) events |= linux.EPOLL.OUT;
        if (reg.poll) |c| {
            events |= switch (c.op) {
                .poll => |op| op.events,
                else => 0,
            };
        }
        return events;
    }

    fn enqueueMmapCompletion(self: *EpollMmapIO, c: *Completion, result: Result) !void {
        self.active += 1;
        self.mmap_completed.append(self.allocator, .{
            .completion = c,
            .result = result,
        }) catch |err| {
            self.active -|= 1;
            epollState(c).in_flight = false;
            return err;
        };
    }

    fn deliverInline(self: *EpollMmapIO, c: *Completion, result: Result) !CallbackAction {
        _ = self;
        const st = epollState(c);
        st.in_flight = false;
        const cb = c.callback orelse return .disarm;
        return cb(c.userdata, c, result);
    }
};

// ── Per-op syscall helpers ────────────────────────────────

fn makeCancelledResult(op: Operation) Result {
    return switch (op) {
        .none => .{ .timeout = error.OperationCanceled },
        .recv => .{ .recv = error.OperationCanceled },
        .send => .{ .send = error.OperationCanceled },
        .recvmsg => .{ .recvmsg = error.OperationCanceled },
        .sendmsg => .{ .sendmsg = error.OperationCanceled },
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
        .open_copy_file_session => .{ .open_copy_file_session = error.OperationCanceled },
        .copy_file_chunk => .{ .copy_file_chunk = error.OperationCanceled },
        .close_copy_file_session => .{ .close_copy_file_session = error.OperationCanceled },
        .fchown => .{ .fchown = error.OperationCanceled },
        .fchmod => .{ .fchmod = error.OperationCanceled },
        .socket => .{ .socket = error.OperationCanceled },
        .connect => .{ .connect = error.OperationCanceled },
        .accept => .{ .accept = error.OperationCanceled },
        .bind => .{ .bind = error.OperationCanceled },
        .listen => .{ .listen = error.OperationCanceled },
        .setsockopt => .{ .setsockopt = error.OperationCanceled },
        .timeout => .{ .timeout = error.OperationCanceled },
        .poll => .{ .poll = error.OperationCanceled },
        .cancel => .{ .cancel = error.OperationCanceled },
    };
}

fn doRecvmsg(op: ifc.RecvmsgOp) anyerror!usize {
    const rc = linux.recvmsg(op.fd, op.msg, op.flags);
    switch (linux.E.init(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.FileDescriptorInvalid,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        .NOTCONN => return error.SocketNotConnected,
        .DESTADDRREQ => return error.DestinationAddressRequired,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |e| return posix.unexpectedErrno(e),
    }
}

fn doSendmsg(op: ifc.SendmsgOp) anyerror!usize {
    const rc = linux.sendmsg(op.fd, @ptrCast(op.msg), op.flags);
    switch (linux.E.init(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.FileDescriptorInvalid,
        .PIPE => return error.BrokenPipe,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        .NOTCONN => return error.SocketNotConnected,
        .DESTADDRREQ => return error.DestinationAddressRequired,
        else => |e| return posix.unexpectedErrno(e),
    }
}

fn doRecv(op: ifc.RecvOp) anyerror!usize {
    const rc = posix.system.recvfrom(op.fd, op.buf.ptr, op.buf.len, op.flags, null, null);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.FileDescriptorInvalid,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        .NOTCONN => return error.SocketNotConnected,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |e| return posix.unexpectedErrno(e),
    }
}

fn doSend(op: ifc.SendOp) anyerror!usize {
    const rc = posix.system.sendto(op.fd, op.buf.ptr, op.buf.len, op.flags, null, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.FileDescriptorInvalid,
        .PIPE => return error.BrokenPipe,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        .NOTCONN => return error.SocketNotConnected,
        else => |e| return posix.unexpectedErrno(e),
    }
}

fn doConnectComplete(fd: posix.fd_t) anyerror!void {
    var err_val: u32 = 0;
    var err_len: posix.socklen_t = @sizeOf(u32);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err_val).ptr, &err_len);
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
    }
    if (err_val == 0) return;
    const e: linux.E = @enumFromInt(err_val);
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        else => posix.unexpectedErrno(e),
    };
}

fn doAccept(listen_fd: posix.fd_t) anyerror!ifc.Accepted {
    var addr_storage: posix.sockaddr.storage = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const flags: u32 = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = try posix.accept(listen_fd, @ptrCast(&addr_storage), &addr_len, flags);
    const addr = std.net.Address.initPosix(@ptrCast(@alignCast(&addr_storage)));
    return .{ .fd = fd, .addr = addr };
}

fn performInline(c: *Completion, events: u32) Result {
    return switch (c.op) {
        .recv => |op| .{ .recv = doRecv(op) },
        .send => |op| .{ .send = doSend(op) },
        .recvmsg => |op| .{ .recvmsg = doRecvmsg(op) },
        .sendmsg => |op| .{ .sendmsg = doSendmsg(op) },
        .connect => |op| .{ .connect = doConnectComplete(op.fd) },
        .accept => |op| .{ .accept = doAccept(op.fd) },
        .poll => .{ .poll = events },
        else => .{ .timeout = error.UnknownOperation },
    };
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

fn skipIfUnavailable() !EpollMmapIO {
    return EpollMmapIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
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

test "EpollMmapIO init / deinit succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    try testing.expect(io.epoll_fd >= 0);
    try testing.expect(io.wakeup_fd >= 0);
}

test "EpollMmapIO timeout fires after deadline" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, testCallback);

    var attempts: u32 = 0;
    while (ctx.calls == 0 and attempts < 200) : (attempts += 1) {
        try io.tick(0);
        std.Thread.sleep(1_000_000);
    }

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollMmapIO socket creates non-blocking fd" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.socket(.{
        .domain = posix.AF.INET,
        .sock_type = posix.SOCK.STREAM,
        .protocol = 0,
    }, &c, &ctx, testCallback);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .socket => |r| {
            const fd = try r;
            defer posix.close(fd);
            try testing.expect(fd >= 0);
        },
        else => try testing.expect(false),
    }
}

fn makeNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(usize, @bitCast(@as(isize, posix.SOCK.NONBLOCK))));
}

test "EpollMmapIO recv on socketpair returns bytes after send" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try makeNonBlocking(fds[0]);

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.recv(.{ .fd = fds[0], .buf = &buf }, &c, &ctx, testCallback);

    try testing.expectEqual(@as(u32, 0), ctx.calls);

    const n = try posix.write(fds[1], "mmap-hello");
    try testing.expectEqual(@as(usize, 10), n);

    var attempts: u32 = 0;
    while (ctx.calls == 0 and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| {
            const got = try r;
            try testing.expectEqual(@as(usize, 10), got);
            try testing.expectEqualStrings("mmap-hello", buf[0..10]);
        },
        else => try testing.expect(false),
    }
}

test "EpollMmapIO cancel on parked recv delivers OperationCanceled" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try makeNonBlocking(fds[0]);

    const Box = struct {
        recv_calls: u32 = 0,
        cancel_calls: u32 = 0,
        recv_result: ?Result = null,
        cancel_result: ?Result = null,
    };
    var box = Box{};

    const recv_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.recv_calls += 1;
            b.recv_result = result;
            return .disarm;
        }
    }.cb;
    const cancel_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.cancel_calls += 1;
            b.cancel_result = result;
            return .disarm;
        }
    }.cb;

    var recv_buf: [16]u8 = undefined;
    var recv_c = Completion{};
    var cancel_c = Completion{};

    try io.recv(.{ .fd = fds[0], .buf = &recv_buf }, &recv_c, &box, recv_cb);
    try testing.expectEqual(@as(u32, 0), box.recv_calls);

    try io.cancel(.{ .target = &recv_c }, &cancel_c, &box, cancel_cb);

    try testing.expectEqual(@as(u32, 1), box.recv_calls);
    try testing.expectEqual(@as(u32, 1), box.cancel_calls);
    switch (box.recv_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (box.cancel_result.?) {
        .cancel => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollMmapIO mmap-backed pwrite + pread round-trip" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // O_RDWR — `mmap PROT_READ | PROT_WRITE` against a `MAP_SHARED`
    // mapping requires the underlying fd to allow both. `createFile`
    // defaults to O_WRONLY which would surface as `error.AccessDenied`.
    const file = try tmp.dir.createFile("mmap_rw", .{ .truncate = true, .read = true });
    defer file.close();

    // Pre-size the file via fallocate so the mmap region is non-empty.
    var fa_c = Completion{};
    var fa_ctx = TestCtx{};
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 4096 }, &fa_c, &fa_ctx, testCallback);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), fa_ctx.calls);
    switch (fa_ctx.last_result.?) {
        .fallocate => |r| try r,
        else => try testing.expect(false),
    }

    // Write some bytes at offset 100.
    var w_c = Completion{};
    var w_ctx = TestCtx{};
    try io.write(.{ .fd = file.handle, .buf = "varuna-mmap", .offset = 100 }, &w_c, &w_ctx, testCallback);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), w_ctx.calls);
    switch (w_ctx.last_result.?) {
        .write => |r| try testing.expectEqual(@as(usize, 11), try r),
        else => try testing.expect(false),
    }

    // Read them back.
    var read_buf: [11]u8 = undefined;
    var r_c = Completion{};
    var r_ctx = TestCtx{};
    try io.read(.{ .fd = file.handle, .buf = &read_buf, .offset = 100 }, &r_c, &r_ctx, testCallback);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), r_ctx.calls);
    switch (r_ctx.last_result.?) {
        .read => |r| {
            const n = try r;
            try testing.expectEqual(@as(usize, 11), n);
            try testing.expectEqualStrings("varuna-mmap", read_buf[0..n]);
        },
        else => try testing.expect(false),
    }

    // fsync should succeed (msync(MS_SYNC) on the mapping).
    var s_c = Completion{};
    var s_ctx = TestCtx{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &s_c, &s_ctx, testCallback);
    try io.tick(1);
    try testing.expectEqual(@as(u32, 1), s_ctx.calls);
    switch (s_ctx.last_result.?) {
        .fsync => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollMmapIO read past EOF returns zero bytes" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // O_RDWR — required by mmap on the post-truncate read path.
    const file = try tmp.dir.createFile("mmap_eof", .{ .truncate = true, .read = true });
    defer file.close();

    // Truncate to 64 bytes via the contract.
    var t_c = Completion{};
    var t_ctx = TestCtx{};
    try io.truncate(.{ .fd = file.handle, .length = 64 }, &t_c, &t_ctx, testCallback);
    try io.tick(1);
    switch (t_ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }

    // Read at offset 1000 — past EOF — should return zero bytes.
    var buf: [16]u8 = undefined;
    var r_c = Completion{};
    var r_ctx = TestCtx{};
    try io.read(.{ .fd = file.handle, .buf = &buf, .offset = 1000 }, &r_c, &r_ctx, testCallback);
    try io.tick(1);
    switch (r_ctx.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

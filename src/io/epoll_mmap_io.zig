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

// ── Backend state ─────────────────────────────────────────
//
// Shared layout with EpollPosixIO. Fits in `ifc.backend_state_size = 64`
// bytes.

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
    /// Initial capacity for the timer heap. Mirrors EpollPosixIO.Config.
    max_completions: u32 = 1024,
};

// ── Mmap bookkeeping ──────────────────────────────────────

const MmapEntry = struct {
    /// Base pointer of the mapping. Points into the virtual address space.
    ptr: [*]u8,
    /// Size of the mapping in bytes.
    size: usize,
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
    /// Cross-thread wakeup primitive (mirrors EpollPosixIO).
    wakeup_fd: posix.fd_t,
    /// Active in-flight count (for `tick(wait_at_least)` semantics).
    active: u32 = 0,
    timers: TimerHeap,
    cached_now_ns: u64 = 0,
    /// Per-fd mmap state. Populated lazily on first file op against `fd`.
    file_mappings: std.AutoHashMap(posix.fd_t, MmapEntry),

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

        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = wakeup_fd },
        };
        const ctl_rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, wakeup_fd, &ev);
        switch (linux.E.init(ctl_rc)) {
            .SUCCESS => {},
            else => |e| return posix.unexpectedErrno(e),
        }

        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
            .wakeup_fd = wakeup_fd,
            .timers = try TimerHeap.init(allocator, config.max_completions),
            .file_mappings = std.AutoHashMap(posix.fd_t, MmapEntry).init(allocator),
        };
    }

    pub fn deinit(self: *EpollMmapIO) void {
        // Tear down any remaining mappings before freeing the map itself.
        var it = self.file_mappings.valueIterator();
        while (it.next()) |entry| {
            posix.munmap(@alignCast(entry.ptr[0..entry.size]));
        }
        self.file_mappings.deinit();
        self.timers.deinit();
        posix.close(self.wakeup_fd);
        posix.close(self.epoll_fd);
        self.* = undefined;
    }

    /// Synchronously close a file descriptor. Used for both sockets and
    /// regular files (the contract method is named `closeSocket` for
    /// historical reasons). Tears down any mmap mapping for `fd` first.
    pub fn closeSocket(self: *EpollMmapIO, fd: posix.fd_t) void {
        self.unmapFile(fd);
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        posix.close(fd);
    }

    // ── Main loop ─────────────────────────────────────────

    pub fn tick(self: *EpollMmapIO, wait_at_least: u32) !void {
        self.updateNow();

        var fired: u32 = 0;
        try self.fireExpiredTimers(&fired);

        if (self.active == 0 and (wait_at_least == 0 or fired >= wait_at_least)) return;

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
            const c: *Completion = @ptrFromInt(@as(usize, @intCast(ev.data.ptr)));
            try self.dispatchReady(c, ev.events);
        }

        try self.fireExpiredTimers(&fired);
    }

    fn computeEpollTimeout(self: *EpollMmapIO, wait_at_least: u32, fired: u32) i32 {
        if (fired >= wait_at_least and wait_at_least > 0) return 0;
        const next_deadline = if (self.timers.peekMin()) |t|
            epollState(t).deadline_ns
        else
            return if (wait_at_least == 0) 0 else -1;

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

    fn dispatchReady(self: *EpollMmapIO, c: *Completion, events: u32) !void {
        const st = epollState(c);
        const cb = c.callback orelse return;

        if (st.epoll_registered) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, st.registered_fd, null);
            st.epoll_registered = false;
        }
        st.in_flight = false;
        self.active -|= 1;

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
            .fallocate => |op| try self.fallocate(op, c, userdata, callback),
            .truncate => |op| try self.truncate(op, c, userdata, callback),
            .socket => |op| try self.socket(op, c, userdata, callback),
            .connect => |op| try self.connect(op, c, userdata, callback),
            .accept => |op| try self.accept(op, c, userdata, callback),
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
        if (doAccept(op.fd)) |accepted| {
            const action = try self.deliverInline(c, .{ .accept = accepted });
            switch (action) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .accept => |new_op| try self.accept(new_op, c, ud, cb),
                    else => return,
                },
            }
            return;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => {
                const action = try self.deliverInline(c, .{ .accept = err });
                switch (action) {
                    .disarm => return,
                    .rearm => switch (c.op) {
                        .accept => |new_op| try self.accept(new_op, c, ud, cb),
                        else => return,
                    },
                }
                return;
            },
        }
        try self.registerFd(c, op.fd, linux.EPOLL.IN);
    }

    pub fn recv(self: *EpollMmapIO, op_in: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .recv = op }, ud, cb);
            const result: Result = res: {
                if (posix.recv(op.fd, op.buf, op.flags)) |n| {
                    break :res .{ .recv = n };
                } else |err| {
                    if (err == error.WouldBlock) {
                        try self.registerFd(c, op.fd, linux.EPOLL.IN);
                        return;
                    }
                    break :res .{ .recv = err };
                }
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .recv => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn send(self: *EpollMmapIO, op_in: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .send = op }, ud, cb);
            const result: Result = res: {
                if (posix.send(op.fd, op.buf, op.flags)) |n| {
                    break :res .{ .send = n };
                } else |err| {
                    if (err == error.WouldBlock) {
                        try self.registerFd(c, op.fd, linux.EPOLL.OUT);
                        return;
                    }
                    break :res .{ .send = err };
                }
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .send => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn recvmsg(self: *EpollMmapIO, op_in: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .recvmsg = op }, ud, cb);
            const result: Result = res: {
                const n = doRecvmsg(op);
                if (n) |bytes| {
                    break :res .{ .recvmsg = bytes };
                } else |err| {
                    if (err == error.WouldBlock) {
                        try self.registerFd(c, op.fd, linux.EPOLL.IN);
                        return;
                    }
                    break :res .{ .recvmsg = err };
                }
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .recvmsg => |new_op| {
                        op = new_op;
                        continue;
                    },
                    else => return,
                },
            }
        }
    }

    pub fn sendmsg(self: *EpollMmapIO, op_in: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .sendmsg = op }, ud, cb);
            const result: Result = res: {
                const n = doSendmsg(op);
                if (n) |bytes| {
                    break :res .{ .sendmsg = bytes };
                } else |err| {
                    if (err == error.WouldBlock) {
                        try self.registerFd(c, op.fd, linux.EPOLL.OUT);
                        return;
                    }
                    break :res .{ .sendmsg = err };
                }
            };
            switch (try self.deliverInline(c, result)) {
                .disarm => return,
                .rearm => switch (c.op) {
                    .sendmsg => |new_op| {
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
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, tst.registered_fd, null);
            tst.epoll_registered = false;
            tst.registered_fd = -1;
            tst.in_flight = false;
            self.active -|= 1;
            found = true;

            if (target.callback) |target_cb| {
                const cancel_result: Result = switch (target.op) {
                    .recv => .{ .recv = error.OperationCanceled },
                    .send => .{ .send = error.OperationCanceled },
                    .recvmsg => .{ .recvmsg = error.OperationCanceled },
                    .sendmsg => .{ .sendmsg = error.OperationCanceled },
                    .connect => .{ .connect = error.OperationCanceled },
                    .accept => .{ .accept = error.OperationCanceled },
                    .poll => .{ .poll = error.OperationCanceled },
                    else => .{ .timeout = error.OperationCanceled },
                };
                _ = target_cb(target.userdata, target, cancel_result);
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
        _ = try self.deliverInline(c, result);
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
        _ = try self.deliverInline(c, result);
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
        _ = try self.deliverInline(c, result);
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
        _ = try self.deliverInline(c, result);
    }

    pub fn truncate(self: *EpollMmapIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        const result: Result = blk: {
            self.unmapFile(op.fd);
            posix.ftruncate(op.fd, op.length) catch |err| break :blk .{ .truncate = err };
            break :blk .{ .truncate = {} };
        };
        _ = try self.deliverInline(c, result);
    }

    pub fn splice(self: *EpollMmapIO, op: ifc.SpliceOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .splice = op }, ud, cb);
        // The mmap backends don't host a thread pool — splice runs on
        // the EL thread. The only daemon caller is the async file-move
        // job, which is one-shot per torrent relocation; the resulting
        // EL stall is bounded and observably acceptable.
        const result: Result = blk: {
            var off_in: i64 = @bitCast(op.in_offset);
            var off_out: i64 = @bitCast(op.out_offset);
            const off_in_ptr: ?*i64 = if (op.in_offset == std.math.maxInt(u64)) null else &off_in;
            const off_out_ptr: ?*i64 = if (op.out_offset == std.math.maxInt(u64)) null else &off_out;
            const rc = linux.syscall6(
                .splice,
                @as(usize, @bitCast(@as(isize, op.in_fd))),
                @intFromPtr(off_in_ptr),
                @as(usize, @bitCast(@as(isize, op.out_fd))),
                @intFromPtr(off_out_ptr),
                op.len,
                op.flags,
            );
            switch (linux.E.init(rc)) {
                .SUCCESS => break :blk .{ .splice = @as(usize, @intCast(rc)) },
                .BADF => break :blk .{ .splice = error.BadFileDescriptor },
                .INVAL => break :blk .{ .splice = error.InvalidArgument },
                .NOMEM => break :blk .{ .splice = error.SystemResources },
                .SPIPE => break :blk .{ .splice = error.InvalidArgument },
                .IO => break :blk .{ .splice = error.InputOutput },
                .NOSPC => break :blk .{ .splice = error.NoSpaceLeft },
                .PIPE => break :blk .{ .splice = error.BrokenPipe },
                .AGAIN => break :blk .{ .splice = error.WouldBlock },
                else => |e| break :blk .{ .splice = posix.unexpectedErrno(e) },
            }
        };
        _ = try self.deliverInline(c, result);
    }

    pub fn copy_file_range(self: *EpollMmapIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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
        _ = try self.deliverInline(c, result);
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
        var ev: linux.epoll_event = .{
            .events = events | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
            .data = .{ .ptr = @intFromPtr(c) },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .EXIST => {
                const mod_rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
                switch (linux.E.init(mod_rc)) {
                    .SUCCESS => {},
                    else => |e| return posix.unexpectedErrno(e),
                }
            },
            .NOMEM, .NOSPC => return error.SystemResources,
            .PERM => return error.FileDescriptorIncompatibleWithEpoll,
            else => |e| return posix.unexpectedErrno(e),
        }
        const st = epollState(c);
        st.epoll_registered = true;
        st.registered_fd = fd;
        self.active += 1;
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

fn doRecvmsg(op: ifc.RecvmsgOp) anyerror!usize {
    const rc = linux.recvmsg(op.fd, op.msg, op.flags);
    switch (linux.E.init(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        else => |e| return posix.unexpectedErrno(e),
    }
}

fn doSendmsg(op: ifc.SendmsgOp) anyerror!usize {
    const rc = linux.sendmsg(op.fd, @ptrCast(op.msg), op.flags);
    switch (linux.E.init(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .PIPE => return error.BrokenPipe,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
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
        .recv => |op| .{ .recv = posix.recv(op.fd, op.buf, op.flags) },
        .send => |op| .{ .send = posix.send(op.fd, op.buf, op.flags) },
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
    try testing.expectEqual(@as(u32, 1), fa_ctx.calls);
    switch (fa_ctx.last_result.?) {
        .fallocate => |r| try r,
        else => try testing.expect(false),
    }

    // Write some bytes at offset 100.
    var w_c = Completion{};
    var w_ctx = TestCtx{};
    try io.write(.{ .fd = file.handle, .buf = "varuna-mmap", .offset = 100 }, &w_c, &w_ctx, testCallback);
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
    switch (t_ctx.last_result.?) {
        .truncate => |r| try r,
        else => try testing.expect(false),
    }

    // Read at offset 1000 — past EOF — should return zero bytes.
    var buf: [16]u8 = undefined;
    var r_c = Completion{};
    var r_ctx = TestCtx{};
    try io.read(.{ .fd = file.handle, .buf = &buf, .offset = 1000 }, &r_c, &r_ctx, testCallback);
    switch (r_ctx.last_result.?) {
        .read => |r| try testing.expectEqual(@as(usize, 0), try r),
        else => try testing.expect(false),
    }
}

//! EpollIO — Linux epoll readiness backend implementing the public
//! `io_interface`.
//!
//! `EpollIO` is the fallback for environments where `io_uring` is forbidden
//! (seccomp policies that block `io_uring_setup`, ancient kernels, hostile
//! sandboxes). The contract is identical to `RealIO`: each method submits
//! an asynchronous operation and a CQE-equivalent fires the
//! `Completion.callback` from `tick`.
//!
//! Design follows `docs/epoll-kqueue-design.md`:
//!
//!   * Sockets use the standard non-blocking + EAGAIN → register → retry
//!     pattern. We register interest with `epoll_ctl(EPOLL_CTL_ADD)` using
//!     `EPOLLONESHOT` (level-triggered, one-shot), retry the syscall when
//!     `epoll_wait` reports readiness, and deliver the result.
//!   * Timers use a flat array of pending timers (peek-min via linear
//!     scan; libxev pattern). Number of concurrent timers in varuna's hot
//!     path is small (~hundreds), so O(n) peek is fine. The next deadline
//!     drives the `epoll_wait` timeout argument.
//!   * File ops (`read`, `write`, `pread`, `pwrite`, `fallocate`, `fsync`,
//!     `truncate`) MUST be offloaded to a thread pool because epoll cannot
//!     deliver readiness for regular files. **MVP STATUS: file ops are not
//!     implemented yet — they return `error.Unimplemented`.** Track:
//!     `progress-reports/2026-04-29-epoll-io-mvp.md`.
//!   * Cancel is best-effort: for socket ops we `epoll_ctl(EPOLL_CTL_DEL)`
//!     the fd and complete the cancelled op with `error.OperationCanceled`.
//!     For timers we remove from the heap and deliver cancellation. Already
//!     dispatched ops cannot be cancelled.
//!   * `accept` with `multishot=true` honours the contract semantically;
//!     native multishot doesn't exist on epoll, so the caller's `.rearm`
//!     return drives re-submission.
//!
//! ## Architecture choices
//!
//! Each submission method is **self-contained** — it loops internally for
//! the synchronous-completion rearm path, and it never calls back into the
//! re-dispatch helper. The async path runs through `tick → dispatchReady
//! → resubmit → submission method`, where `resubmit` is the only place
//! that re-invokes a submission method by tag. This keeps Zig 0.15.2's
//! inferred error sets acyclic (mutual recursion through callbacks would
//! otherwise be unresolvable).
//!
//! See `reference-codebases/libxev/src/backend/epoll.zig` for the canonical
//! reference implementation; libxev's epoll backend is structurally
//! similar but its author flagged it as "in much poorer quality" than the
//! kqueue one. Pattern adapted from there + ZIO + tigerbeetle survey in
//! the design doc.

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
// EpollIO stores per-completion bookkeeping in `Completion._backend_state`.
// State must fit in `ifc.backend_state_size` (64 bytes). Required slots:
//
//   * `in_flight`         — guards against double-submission.
//   * `epoll_registered`  — whether the fd is currently in our epoll set.
//   * `registered_fd`     — fd to remove from epoll on disarm/cancel; we
//                           store it explicitly because the op union may be
//                           rewritten by a callback before we read it.
//   * `accept_multishot`  — sticky flag for multishot-accept drain-loop.
//   * `deadline_ns`       — absolute monotonic nanoseconds for timers.
//   * `timer_heap_index`  — sentinel-tagged index into the timer heap.

const sentinel_index: u32 = std.math.maxInt(u32);

pub const EpollState = struct {
    in_flight: bool = false,
    epoll_registered: bool = false,
    accept_multishot: bool = false,
    /// fd we registered in the epoll set, if any. Stored separately from
    /// `c.op` because the callback may rearm with a different op; we still
    /// need to know which fd to `EPOLL_CTL_DEL` on disarm.
    registered_fd: posix.fd_t = -1,
    /// Absolute monotonic deadline for `timeout` ops, in nanoseconds since
    /// the monotonic clock epoch.
    deadline_ns: u64 = 0,
    /// Position in the timer heap; `sentinel_index` means "not in heap".
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
    /// Initial capacity for the timer heap. Grows on demand if needed.
    /// Mirrors RealIO's `entries` knob in spirit.
    max_completions: u32 = 1024,
};

// ── Timer heap ────────────────────────────────────────────
//
// MVP uses a flat array. `peekMin` does a linear scan but for varuna's
// timer counts (low-hundreds in the hot path) this is fine. Replace with
// a true binary heap when profiling shows it's a bottleneck.

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

    fn count(self: *const TimerHeap) usize {
        return self.entries.items.len;
    }
};

// ── EpollIO ───────────────────────────────────────────────

pub const EpollIO = struct {
    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,
    /// Cross-thread wakeup primitive. Background workers (file-op thread
    /// pool, when implemented) write to this fd; we read it inside `tick`
    /// to drain spurious wakes.
    wakeup_fd: posix.fd_t,
    /// Active in-flight count (for `tick(wait_at_least)` semantics).
    active: u32 = 0,
    timers: TimerHeap,
    /// Cached monotonic-clock reading, refreshed in `tick`.
    cached_now_ns: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !EpollIO {
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
        };
    }

    pub fn deinit(self: *EpollIO) void {
        self.timers.deinit();
        posix.close(self.wakeup_fd);
        posix.close(self.epoll_fd);
        self.* = undefined;
    }

    /// Synchronously close a file descriptor. Mirrors `RealIO.closeSocket`.
    /// Best-effort removes the fd from epoll first to avoid the
    /// "closed-fd-still-in-epoll-set" footgun called out in
    /// `docs/epoll-kqueue-design.md`. ENOENT is fine — fd was never
    /// registered.
    pub fn closeSocket(self: *EpollIO, fd: posix.fd_t) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        posix.close(fd);
    }

    // ── Main loop ─────────────────────────────────────────

    /// Drain expired timers, `epoll_wait` for the next event, dispatch
    /// ready fds, drain any timers that became due during the wait.
    /// Mirrors the contract's `tick` semantics.
    pub fn tick(self: *EpollIO, wait_at_least: u32) !void {
        self.updateNow();

        var fired: u32 = 0;
        try self.fireExpiredTimers(&fired);

        if (self.active == 0 and (wait_at_least == 0 or fired >= wait_at_least)) return;

        const timeout_ms: i32 = self.computeEpollTimeout(wait_at_least, fired);

        var events: [128]linux.epoll_event = undefined;
        const n_rc = linux.epoll_pwait(self.epoll_fd, &events, events.len, timeout_ms, null);
        const n: usize = switch (linux.E.init(n_rc)) {
            .SUCCESS => @intCast(n_rc),
            .INTR => 0, // signal interrupt — caller can re-tick
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

    fn computeEpollTimeout(self: *EpollIO, wait_at_least: u32, fired: u32) i32 {
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

    fn updateNow(self: *EpollIO) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        if (linux.E.init(rc) == .SUCCESS) {
            const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch
                std.math.maxInt(u64);
            self.cached_now_ns = std.math.add(u64, sec_ns, @intCast(ts.nsec)) catch
                std.math.maxInt(u64);
        }
    }

    fn fireExpiredTimers(self: *EpollIO, fired: *u32) !void {
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
                    else => {}, // illegal under the contract — ignore
                },
            }
        }
    }

    /// Dispatch a ready fd from the epoll wait loop. Clears the
    /// completion's epoll registration (EPOLLONESHOT is already
    /// auto-disabled by the kernel; we just clean up state) and re-runs
    /// the operation through the resubmit path. The submission method
    /// retries the syscall and either delivers the result inline or
    /// re-registers if EAGAIN comes back.
    fn dispatchReady(self: *EpollIO, c: *Completion, events: u32) !void {
        const st = epollState(c);
        const cb = c.callback orelse return;

        // Clean up the epoll registration. EPOLLONESHOT means the kernel
        // has already disabled this fd's interest — but we still need to
        // EPOLL_CTL_DEL to tear down state for re-add later.
        if (st.epoll_registered) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, st.registered_fd, null);
            st.epoll_registered = false;
        }
        st.in_flight = false;
        self.active -|= 1;

        // Build the result by retrying the operation. If retry returns
        // EAGAIN (rare under EPOLLONESHOT), we'll re-register via the
        // submission method's own path — but for our common case the retry
        // succeeds.
        const result = performInline(c, events);
        const action = cb(c.userdata, c, result);
        switch (action) {
            .disarm => {},
            .rearm => try self.resubmit(c),
        }
    }

    fn resubmit(self: *EpollIO, c: *Completion) !void {
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

    // ── Submission methods ────────────────────────────────
    //
    // Each method is self-contained: it runs the syscall once, and if it
    // succeeded synchronously, fires the callback in a loop that handles
    // .rearm. If the syscall returns EAGAIN, the method registers fd
    // interest with epoll and returns; the async path picks up via
    // `tick → dispatchReady → resubmit → submission method`.
    //
    // **Intentionally no calls to `resubmit` from inside a submission
    // method.** That would create an inferred-error-set cycle in Zig 0.15.2
    // (recv → resubmit → recv).

    pub fn socket(self: *EpollIO, op_in: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        var op = op_in;
        while (true) {
            try self.armCompletion(c, .{ .socket = op }, ud, cb);

            // Always-non-blocking + cloexec. Daemon callers expect fds
            // that don't block in non-uring code paths and the EAGAIN
            // pattern requires it.
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

    pub fn connect(self: *EpollIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);

        const addrlen = op.addr.getOsSockLen();
        if (posix.connect(op.fd, &op.addr.any, addrlen)) {
            // Connect completed synchronously (e.g. AF_UNIX).
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
        // MVP: deadline_ns is honoured only via explicit `cancel` from a
        // separate timeout completion. Native deadline-bounded connect
        // belongs to a follow-up.
        _ = op.deadline_ns;
    }

    pub fn accept(self: *EpollIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        epollState(c).accept_multishot = op.multishot;

        // Try once before parking — there may already be a pending
        // connection. If accept returns EAGAIN we register and wait.
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

    pub fn recv(self: *EpollIO, op_in: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn send(self: *EpollIO, op_in: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn recvmsg(self: *EpollIO, op_in: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn sendmsg(self: *EpollIO, op_in: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn timeout(self: *EpollIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);

        self.updateNow();
        const deadline = std.math.add(u64, self.cached_now_ns, op.ns) catch
            std.math.maxInt(u64);
        epollState(c).deadline_ns = deadline;

        try self.timers.push(c);
        self.active += 1;
    }

    pub fn poll(self: *EpollIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);

        // Translate POLL_IN/POLL_OUT/etc. to EPOLLIN/EPOLLOUT/etc. The
        // bitmask values match between `linux.POLL.*` and `linux.EPOLL.*`
        // for the common cases (IN=1, OUT=4, ERR=8, HUP=16), so a direct
        // copy is sufficient.
        try self.registerFd(c, op.fd, op.events);
    }

    pub fn cancel(self: *EpollIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);

        const target = op.target;
        const tst = epollState(target);
        var found = false;

        // Timer in heap?
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

        // Registered with epoll?
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

    // ── File ops (UNIMPLEMENTED in MVP) ───────────────────
    //
    // The MVP scope intentionally excludes file ops. They MUST run on a
    // worker thread pool because epoll cannot deliver readiness for regular
    // files (they always poll ready). Daemon paths that depend on these
    // ops will not work under `-Dio=epoll` until the follow-up lands.

    pub fn read(self: *EpollIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        const action = try self.deliverInline(c, .{ .read = error.Unimplemented });
        // Unimplemented op rearm is a no-op; the caller can't make progress.
        _ = action;
    }

    pub fn write(self: *EpollIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const action = try self.deliverInline(c, .{ .write = error.Unimplemented });
        _ = action;
    }

    pub fn fsync(self: *EpollIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        const action = try self.deliverInline(c, .{ .fsync = error.Unimplemented });
        _ = action;
    }

    pub fn fallocate(self: *EpollIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        const action = try self.deliverInline(c, .{ .fallocate = error.Unimplemented });
        _ = action;
    }

    pub fn truncate(self: *EpollIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        const action = try self.deliverInline(c, .{ .truncate = error.Unimplemented });
        _ = action;
    }

    // ── Internal helpers ──────────────────────────────────

    fn armCompletion(self: *EpollIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        const st = epollState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .in_flight = true };
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }

    fn registerFd(self: *EpollIO, c: *Completion, fd: posix.fd_t, events: u32) !void {
        var ev: linux.epoll_event = .{
            .events = events | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
            .data = .{ .ptr = @intFromPtr(c) },
        };
        const rc = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .EXIST => {
                // Already registered (e.g. previous EPOLLONESHOT armed but
                // not yet fired) — modify instead.
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

    /// Deliver a synchronous-completion result by clearing in_flight and
    /// invoking the callback. Returns the callback's action so the caller
    /// can handle .rearm in its own loop. **Does not call `resubmit`** —
    /// that would create an inferred-error-set cycle.
    fn deliverInline(self: *EpollIO, c: *Completion, result: Result) !CallbackAction {
        _ = self;
        const st = epollState(c);
        st.in_flight = false;
        const cb = c.callback orelse return .disarm;
        return cb(c.userdata, c, result);
    }
};

// ── Per-op syscall helpers ────────────────────────────────

/// `linux.recvmsg` returns a usize rc; convert to anyerror!usize.
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

/// Retry the operation associated with `c` on its ready fd. Called from
/// `dispatchReady` after `epoll_wait` reports readiness; the syscall
/// should generally succeed at this point (unless multiple readers
/// raced).
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

fn skipIfUnavailable() !EpollIO {
    return EpollIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
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

test "EpollIO init / deinit succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    try testing.expect(io.epoll_fd >= 0);
    try testing.expect(io.wakeup_fd >= 0);
}

test "EpollIO timeout fires after deadline" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, testCallback); // 1ms

    var attempts: u32 = 0;
    while (ctx.calls == 0 and attempts < 200) : (attempts += 1) {
        try io.tick(0);
        std.Thread.sleep(1_000_000); // 1ms
    }

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollIO socket creates non-blocking fd" {
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

test "EpollIO recv on socketpair returns bytes after send" {
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

    // Recv should have parked (no data available).
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Now write — recv should fire on the next tick.
    const n = try posix.write(fds[1], "hello");
    try testing.expectEqual(@as(usize, 5), n);

    var attempts: u32 = 0;
    while (ctx.calls == 0 and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }

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

test "EpollIO send + recv round-trip on socketpair" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try makeNonBlocking(fds[0]);
    try makeNonBlocking(fds[1]);

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

    var attempts: u32 = 0;
    while ((both.sent < 1 or both.received < 1) and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }

    try testing.expectEqual(@as(usize, 6), both.bytes_sent);
    try testing.expectEqual(@as(usize, 6), both.bytes_received);
    try testing.expectEqualStrings("varuna", both.recv_buf[0..6]);
}

test "EpollIO cancel on parked recv delivers OperationCanceled" {
    var io = try skipIfUnavailable();
    defer io.deinit();

    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try makeNonBlocking(fds[0]);

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
    try testing.expectEqual(@as(u32, 0), st.recv_calls);

    try io.cancel(.{ .target = &recv_c }, &cancel_c, &st, cancel_cb);

    try testing.expectEqual(@as(u32, 1), st.recv_calls);
    try testing.expectEqual(@as(u32, 1), st.cancel_calls);
    switch (st.recv_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (st.cancel_result.?) {
        .cancel => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollIO file ops return Unimplemented (MVP scope marker)" {
    // The MVP intentionally does not implement file ops. They require a
    // worker thread pool because epoll cannot signal regular-file readiness.
    // This test asserts the explicit UNIMPLEMENTED contract so the gap is
    // discoverable. When the file-op follow-up lands, this test should be
    // replaced with proper read/write/fallocate/fsync/truncate coverage.
    var io = try skipIfUnavailable();
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("epoll_unimpl", .{ .truncate = true });
    defer file.close();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &c, &ctx, testCallback);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fsync => |r| try testing.expectError(error.Unimplemented, r),
        else => try testing.expect(false),
    }
}

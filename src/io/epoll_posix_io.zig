//! EpollPosixIO — Linux epoll readiness backend with POSIX file-op strategy.
//!
//! `EpollPosixIO` is the fallback for environments where `io_uring` is forbidden
//! (seccomp policies that block `io_uring_setup`, ancient kernels, hostile
//! sandboxes). The contract is identical to `RealIO`: each method submits
//! an asynchronous operation and a CQE-equivalent fires the
//! `Completion.callback` from `tick`.
//!
//! ## Bifurcation rationale
//!
//! The readiness layer (epoll) is one axis. The file-I/O strategy is a
//! separate axis. There are two valid choices for a readiness-based backend:
//!
//!   * **POSIX (this file)**: `pread`/`pwrite`/`fsync`/`fallocate` syscalls
//!     offloaded to a thread pool to keep the EL non-blocking. Predictable,
//!     matches io_uring semantics, copies through syscall buffers.
//!   * **mmap (`epoll_mmap_io.zig`)**: file is mapped at open; reads/writes
//!     are `memcpy`s; durability via `msync`. Zero-copy, OS pagecache
//!     implicit, but page faults can stall the calling thread.
//!
//! These deserve separate backends because they make different tradeoffs.
//! The socket / timer / cancel machinery is shared in design — both files
//! mirror the same readiness layer; only the file-op submission methods
//! differ.
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
//!   * File ops (`read`, `write`, `fsync`, `fallocate`, `truncate`) run on
//!     a `PosixFilePool` worker thread. Workers execute the syscall and
//!     push the result onto the pool's completed queue; the worker then
//!     writes a byte to `wakeup_fd` to break `epoll_pwait`. The next
//!     `tick` drains the pool via `drainPool` and fires the user's
//!     callback. See `src/io/posix_file_pool.zig`. KqueuePosixIO uses the
//!     same pool with EVFILT_USER as the wake primitive.
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
const posix_file_pool = @import("posix_file_pool.zig");
const PosixFilePool = posix_file_pool.PosixFilePool;
const FileOp = posix_file_pool.FileOp;
const PoolCompleted = posix_file_pool.Completed;

// ── Backend state ─────────────────────────────────────────
//
// EpollPosixIO stores per-completion bookkeeping in `Completion._backend_state`.
// State must fit in `ifc.backend_state_size` (64 bytes). Required slots:
//
//   * `in_flight`         — guards against double-submission.
//   * `epoll_registered`  — whether the fd is currently in our epoll set.
//   * `registered_fd`     — fd to remove from epoll on disarm/cancel; we
//                           store it explicitly because the op union may be
//                           rewritten by a callback before we read it.
//   * `interest`          — which per-fd readiness lane owns this completion.
//   * `accept_multishot`  — sticky flag for multishot-accept drain-loop.
//   * `deadline_ns`       — absolute monotonic nanoseconds for timers.
//   * `timer_heap_index`  — sentinel-tagged index into the timer heap.

const sentinel_index: u32 = std.math.maxInt(u32);

const FdInterest = enum(u8) {
    none,
    read,
    write,
    poll,
};

pub const EpollState = struct {
    in_flight: bool = false,
    epoll_registered: bool = false,
    accept_multishot: bool = false,
    interest: FdInterest = .none,
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

// ── Configuration ─────────────────────────────────────────

pub const Config = struct {
    /// Initial capacity for the timer heap. Grows on demand if needed.
    /// Mirrors RealIO's `entries` knob in spirit.
    max_completions: u32 = 1024,

    /// Number of worker threads in the file-op pool. epoll cannot deliver
    /// readiness for regular files; every `read`/`write`/`fsync`/
    /// `fallocate`/`truncate` runs on this pool. Default 4 mirrors
    /// `hasher.zig`. Set to 0 only in tests that want inline-mode op
    /// execution (file ops will then never complete asynchronously —
    /// most tests should leave it at the default).
    file_pool_workers: u32 = 4,

    /// Bound on outstanding file ops awaiting worker pickup. `submit`
    /// returns `error.PendingQueueFull` past this. 256 matches kqueue's
    /// kevent change-batch sizing.
    file_pool_pending_capacity: u32 = 256,
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

// ── EpollPosixIO ───────────────────────────────────────────────

pub const EpollPosixIO = struct {
    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,
    wakeup_ctx: *posix.fd_t,
    /// Cross-thread wakeup primitive. The file-op thread pool writes a
    /// `u64` to this fd whenever a worker pushes a result; we read it
    /// inside `tick` to drain accumulated wake counts (eventfd semantics
    /// collapse multiple writes into one read).
    wakeup_fd: posix.fd_t,
    /// Active in-flight count (for `tick(wait_at_least)` semantics).
    /// Counts both registered fds (sockets, timers) AND outstanding pool
    /// submissions, so `tick` knows to block on `epoll_pwait` while a
    /// worker has work in flight.
    active: u32 = 0,
    timers: TimerHeap,
    /// Cached monotonic-clock reading, refreshed in `tick`.
    cached_now_ns: u64 = 0,
    /// File-op worker thread pool. Read/write/fsync/fallocate/truncate
    /// all run here because epoll cannot deliver readiness for regular
    /// files. Workers signal completion via `wakeup_fd` (see
    /// `wakeFromPool`).
    pool: *PosixFilePool,
    /// Scratch buffer for `pool.drainCompletedInto`. Reused across
    /// ticks; sized lazily as the pool grows. Owned by EpollPosixIO so
    /// no allocation churn on hot ticks.
    pool_swap: std.ArrayListUnmanaged(PoolCompleted) = .{},
    fd_registrations: std.AutoHashMap(posix.fd_t, FdRegistration),
    /// Completion currently being dispatched on the write lane. If its
    /// callback submits the same completion again (partial send), queue it
    /// at the front so later same-fd sends cannot interleave into the TCP
    /// byte stream.
    requeue_write_front: ?*Completion = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) !EpollPosixIO {
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

        var timers = try TimerHeap.init(allocator, config.max_completions);
        errdefer timers.deinit();

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
            .timers = timers,
            .pool = pool,
            .fd_registrations = std.AutoHashMap(posix.fd_t, FdRegistration).init(allocator),
        };
    }

    /// Compatibility no-op for older direct tests that called this
    /// after `init`. The wake context is now bound during `init` using a
    /// heap-stable fd pointer, so by-value backend construction through
    /// `backend.initOneshot` and `backend.initEventLoop` is safe.
    pub fn bindWakeup(self: *EpollPosixIO) void {
        self.pool.setWakeup(self.wakeup_ctx, wakeFromPool);
    }

    pub fn deinit(self: *EpollPosixIO) void {
        // Pool deinit joins workers BEFORE we touch wakeup_fd, so a
        // worker pushing a final result + signalling wake is fine — the
        // eventfd stays open until we close it below.
        self.pool.deinit();
        self.pool_swap.deinit(self.allocator);
        self.fd_registrations.deinit();
        self.timers.deinit();
        self.allocator.destroy(self.wakeup_ctx);
        posix.close(self.wakeup_fd);
        posix.close(self.epoll_fd);
        self.* = undefined;
    }

    /// Wakeup hook handed to the file-op pool. Workers invoke this
    /// after pushing a result; the eventfd write makes
    /// `epoll_pwait` return so `tick` drains the pool's completed
    /// queue. Best-effort — a write failure (eventfd full at u64::max,
    /// effectively impossible) means the next tick will pick the
    /// result up via `pool.drainCompletedInto` regardless.
    fn wakeFromPool(ctx: ?*anyopaque) void {
        const wakeup_fd: *const posix.fd_t = @ptrCast(@alignCast(ctx.?));
        const val: u64 = 1;
        _ = posix.write(wakeup_fd.*, std.mem.asBytes(&val)) catch {};
    }

    /// Synchronously close a file descriptor. Mirrors `RealIO.closeSocket`.
    /// Best-effort removes the fd from epoll first to avoid the
    /// "closed-fd-still-in-epoll-set" footgun called out in
    /// `docs/epoll-kqueue-design.md`. ENOENT is fine — fd was never
    /// registered.
    pub fn closeSocket(self: *EpollPosixIO, fd: posix.fd_t) void {
        _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        if (self.fd_registrations.fetchRemove(fd)) |entry| {
            self.cancelRegisteredCompletion(entry.value.read);
            self.cancelWriteQueue(entry.value.write_head);
            self.cancelRegisteredCompletion(entry.value.poll);
        }
        posix.close(fd);
    }

    // ── Main loop ─────────────────────────────────────────

    /// Drain expired timers, `epoll_wait` for the next event, dispatch
    /// ready fds, drain any timers that became due during the wait.
    /// Mirrors the contract's `tick` semantics.
    pub fn tick(self: *EpollPosixIO, wait_at_least: u32) !void {
        self.updateNow();

        var fired: u32 = 0;
        try self.fireExpiredTimers(&fired);
        try self.drainPool(&fired);

        if (self.active == 0) return;
        if (wait_at_least != 0 and fired >= wait_at_least) return;

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
            try self.dispatchFdReady(ev.data.fd, ev.events);
        }

        try self.fireExpiredTimers(&fired);
        try self.drainPool(&fired);
    }

    /// Drain the file-op pool's completed queue and dispatch each
    /// callback. Called from `tick` before and after `epoll_pwait` so
    /// callbacks land on the same EL pass as the wake fd's read.
    fn drainPool(self: *EpollPosixIO, fired: *u32) !void {
        try self.pool.drainCompletedInto(&self.pool_swap);
        defer self.pool_swap.clearRetainingCapacity();
        for (self.pool_swap.items) |entry| {
            try self.dispatchPoolEntry(entry, fired);
        }
    }

    /// Fire the user callback for one pool completion. Mirrors
    /// `dispatchCqe` in RealIO: clear in_flight before invoking the
    /// callback so a callback that resubmits a follow-on op on the same
    /// completion doesn't trip `AlreadyInFlight` against itself.
    fn dispatchPoolEntry(self: *EpollPosixIO, entry: PoolCompleted, fired: *u32) !void {
        const c = entry.completion;
        const cb = c.callback orelse return;
        const st = epollState(c);
        st.in_flight = false;
        self.active -|= 1;
        fired.* += 1;

        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => switch (c.op) {
                .read => |op| try self.read(op, c, c.userdata, cb),
                .write => |op| try self.write(op, c, c.userdata, cb),
                .fsync => |op| try self.fsync(op, c, c.userdata, cb),
                .fallocate => |op| try self.fallocate(op, c, c.userdata, cb),
                .truncate => |op| try self.truncate(op, c, c.userdata, cb),
                else => {}, // callback overwrote c.op with a non-file op; that path is its own armCompletion
            },
        }
    }

    fn computeEpollTimeout(self: *EpollPosixIO, wait_at_least: u32, fired: u32) i32 {
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

    fn updateNow(self: *EpollPosixIO) void {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        if (linux.E.init(rc) == .SUCCESS) {
            const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch
                std.math.maxInt(u64);
            self.cached_now_ns = std.math.add(u64, sec_ns, @intCast(ts.nsec)) catch
                std.math.maxInt(u64);
        }
    }

    fn fireExpiredTimers(self: *EpollPosixIO, fired: *u32) !void {
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

    /// Dispatch all completions interested in the ready event for `fd`.
    /// epoll only stores one user-data value per fd, but io_uring callers
    /// routinely keep an independent recv and send in flight on the same
    /// socket. We therefore demultiplex the fd readiness into read/write
    /// lanes and deliver the matching caller-owned completions.
    fn dispatchFdReady(self: *EpollPosixIO, fd: posix.fd_t, events: u32) !void {
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

        // Deliver write-side completions first. Tracked sends can be
        // heap-backed; a recv callback may disconnect the peer and free
        // those buffers, while the embedded recv completion remains stable
        // if a send callback disconnects first.
        if (write_c) |c| try self.dispatchReadyCompletion(c, events);
        if (read_c) |c| try self.dispatchReadyCompletion(c, events);
        if (poll_c) |c| try self.dispatchReadyCompletion(c, events);
    }

    /// Dispatch one ready completion. The fd registration has already been
    /// removed from the per-fd table before this is called.
    fn dispatchReadyCompletion(self: *EpollPosixIO, c: *Completion, events: u32) !void {
        const st = epollState(c);
        const cb = c.callback orelse return;
        std.debug.assert(!st.epoll_registered);
        std.debug.assert(!st.in_flight);

        // Build the result by retrying the operation. If retry returns
        // EAGAIN (rare under EPOLLONESHOT), we'll re-register via the
        // submission method's own path — but for our common case the retry
        // succeeds.
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

    fn resubmit(self: *EpollPosixIO, c: *Completion) !void {
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

    pub fn socket(self: *EpollPosixIO, op_in: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn connect(self: *EpollPosixIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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
        // MVP: deadline_ns is honoured only via explicit `cancel` from a
        // separate timeout completion. Native deadline-bounded connect
        // belongs to a follow-up.
        _ = op.deadline_ns;
    }

    pub fn accept(self: *EpollPosixIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        epollState(c).accept_multishot = op.multishot;
        try self.registerFd(c, op.fd, linux.EPOLL.IN);
    }

    pub fn recv(self: *EpollPosixIO, op_in: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.IN);
    }

    pub fn send(self: *EpollPosixIO, op_in: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.OUT);
    }

    pub fn recvmsg(self: *EpollPosixIO, op_in: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.IN);
    }

    pub fn sendmsg(self: *EpollPosixIO, op_in: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op_in }, ud, cb);
        try self.registerFd(c, op_in.fd, linux.EPOLL.OUT);
    }

    /// Synchronous fallback. Epoll has no equivalent of
    /// `IORING_OP_BIND`; bind is a fast in-kernel call with no I/O wait
    /// so it runs inline and the callback fires from this submission
    /// path, mirroring the truncate pattern.
    pub fn bind(self: *EpollPosixIO, op_in: ifc.BindOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    /// Synchronous fallback. See `bind`.
    pub fn listen(self: *EpollPosixIO, op_in: ifc.ListenOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    /// Synchronous fallback. See `bind`.
    pub fn setsockopt(self: *EpollPosixIO, op_in: ifc.SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn openat(self: *EpollPosixIO, op_in: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn mkdirat(self: *EpollPosixIO, op_in: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn renameat(self: *EpollPosixIO, op_in: ifc.RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn unlinkat(self: *EpollPosixIO, op_in: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn statx(self: *EpollPosixIO, op_in: ifc.StatxOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn getdents(self: *EpollPosixIO, op_in: ifc.GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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

    pub fn timeout(self: *EpollPosixIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);

        self.updateNow();
        const deadline = std.math.add(u64, self.cached_now_ns, op.ns) catch
            std.math.maxInt(u64);
        epollState(c).deadline_ns = deadline;

        try self.timers.push(c);
        self.active += 1;
    }

    pub fn poll(self: *EpollPosixIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);

        // Translate POLL_IN/POLL_OUT/etc. to EPOLLIN/EPOLLOUT/etc. The
        // bitmask values match between `linux.POLL.*` and `linux.EPOLL.*`
        // for the common cases (IN=1, OUT=4, ERR=8, HUP=16), so a direct
        // copy is sufficient.
        try self.registerFd(c, op.fd, op.events);
    }

    pub fn cancel(self: *EpollPosixIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
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
            _ = try self.unregisterCompletion(target);
            found = true;

            if (target.callback) |target_cb| {
                _ = target_cb(target.userdata, target, makeCancelledResult(target.op));
            }
        }

        // Pool-pending file op? Best-effort: if a worker has already
        // picked it up, we cannot interrupt the syscall, and the op
        // delivers normally.
        if (!found) {
            const target_is_file = switch (target.op) {
                .read, .write, .fsync, .fallocate, .truncate => true,
                else => false,
            };
            if (target_is_file and self.pool.tryCancelPending(target)) {
                found = true;
                // Pool pushed an OperationCanceled result onto its
                // completed queue; the next `drainPool` (in tick()) will
                // fire the target's callback. We don't decrement `active`
                // here — `dispatchPoolEntry` does that when it fires.
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

    // ── File ops ──────────────────────────────────────────
    //
    // epoll cannot deliver readiness for regular files (the kernel
    // reports them as always-ready and the actual syscall blocks on a
    // page fault). Every file op runs on the `PosixFilePool` worker
    // thread; the worker pushes the result onto the pool's completed
    // queue and signals `wakeup_fd`. The next `tick` drains the queue
    // and fires the user's callback.

    pub fn read(self: *EpollPosixIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        try self.submitFileOp(.{ .read = op }, c);
    }

    pub fn write(self: *EpollPosixIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        try self.submitFileOp(.{ .write = op }, c);
    }

    pub fn fsync(self: *EpollPosixIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        try self.submitFileOp(.{ .fsync = op }, c);
    }

    pub fn close(self: *EpollPosixIO, op: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .close = op }, ud, cb);
        try self.submitFileOp(.{ .close = op }, c);
    }

    pub fn fallocate(self: *EpollPosixIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        try self.submitFileOp(.{ .fallocate = op }, c);
    }

    pub fn truncate(self: *EpollPosixIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        try self.submitFileOp(.{ .truncate = op }, c);
    }

    pub fn splice(self: *EpollPosixIO, op: ifc.SpliceOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .splice = op }, ud, cb);
        try self.submitFileOp(.{ .splice = op }, c);
    }

    pub fn copy_file_range(self: *EpollPosixIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_range = op }, ud, cb);
        try self.submitFileOp(.{ .copy_file_range = op }, c);
    }

    fn submitFileOp(self: *EpollPosixIO, op: FileOp, c: *Completion) !void {
        // Bump active so `tick`'s early-return guard knows we have
        // outstanding work; matches the timer / registered-fd path.
        // Decremented when `dispatchPoolEntry` fires the callback.
        self.active += 1;
        self.pool.submit(op, c) catch |err| {
            // Roll back the bookkeeping we just touched.
            self.active -|= 1;
            epollState(c).in_flight = false;
            return err;
        };
    }

    // ── Internal helpers ──────────────────────────────────

    fn armCompletion(self: *EpollPosixIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        const st = epollState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .in_flight = true };
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }

    fn registerFd(self: *EpollPosixIO, c: *Completion, fd: posix.fd_t, events: u32) !void {
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

    fn updateFdRegistration(self: *EpollPosixIO, fd: posix.fd_t) !void {
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

    fn unregisterCompletion(self: *EpollPosixIO, c: *Completion) !bool {
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

    fn cancelRegisteredCompletion(self: *EpollPosixIO, c: ?*Completion) void {
        const completion = c orelse return;
        self.clearRegisteredCompletion(completion);
        completion.next = null;
        if (completion.callback) |cb| {
            _ = cb(completion.userdata, completion, makeCancelledResult(completion.op));
        }
    }

    fn cancelWriteQueue(self: *EpollPosixIO, head: ?*Completion) void {
        var cur = head;
        while (cur) |completion| {
            const next = completion.next;
            self.cancelRegisteredCompletion(completion);
            cur = next;
        }
    }

    fn clearRegisteredCompletion(self: *EpollPosixIO, c: *Completion) void {
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

    /// Deliver a synchronous-completion result by clearing in_flight and
    /// invoking the callback. Returns the callback's action so the caller
    /// can handle .rearm in its own loop. **Does not call `resubmit`** —
    /// that would create an inferred-error-set cycle.
    fn deliverInline(self: *EpollPosixIO, c: *Completion, result: Result) !CallbackAction {
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
        .splice => .{ .splice = error.OperationCanceled },
        .copy_file_range => .{ .copy_file_range = error.OperationCanceled },
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

/// `linux.recvmsg` returns a usize rc; convert to anyerror!usize.
fn doRecvmsg(op: ifc.RecvmsgOp) anyerror!usize {
    const rc = linux.recvmsg(op.fd, op.msg, op.flags);
    switch (linux.E.init(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .INTR => return error.Interrupted,
        .NOTCONN => return error.SocketNotConnected,
        .DESTADDRREQ => return error.DestinationAddressRequired,
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

/// Retry the operation associated with `c` on its ready fd. Called from
/// `dispatchReady` after `epoll_wait` reports readiness; the syscall
/// should generally succeed at this point (unless multiple readers
/// raced).
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

fn skipIfUnavailable() !EpollPosixIO {
    return EpollPosixIO.init(testing.allocator, .{}) catch return error.SkipZigTest;
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

test "EpollPosixIO init / deinit succeeds" {
    var io = try skipIfUnavailable();
    defer io.deinit();
    try testing.expect(io.epoll_fd >= 0);
    try testing.expect(io.wakeup_fd >= 0);
}

test "EpollPosixIO timeout fires after deadline" {
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

test "EpollPosixIO socket creates non-blocking fd" {
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

test "EpollPosixIO recv on socketpair returns bytes after send" {
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

test "EpollPosixIO send + recv round-trip on socketpair" {
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

test "EpollPosixIO sendmsg + recv round-trip on socketpair" {
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
        iov: [2]posix.iovec_const = undefined,
        msg: posix.msghdr_const = undefined,
    };
    var both = Both{};
    both.iov[0] = .{ .base = "var".ptr, .len = 3 };
    both.iov[1] = .{ .base = "una".ptr, .len = 3 };
    both.msg = .{
        .name = null,
        .namelen = 0,
        .iov = &both.iov,
        .iovlen = both.iov.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    const send_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *Both = @ptrCast(@alignCast(ud.?));
            s.sent += 1;
            switch (result) {
                .sendmsg => |r| s.bytes_sent = r catch 0,
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
    try io.sendmsg(.{ .fd = fds[0], .msg = &both.msg }, &send_c, &both, send_cb);

    var attempts: u32 = 0;
    while ((both.sent < 1 or both.received < 1) and attempts < 100) : (attempts += 1) {
        try io.tick(1);
    }

    try testing.expectEqual(@as(usize, 6), both.bytes_sent);
    try testing.expectEqual(@as(usize, 6), both.bytes_received);
    try testing.expectEqualStrings("varuna", both.recv_buf[0..6]);
}

test "EpollPosixIO cancel on parked recv delivers OperationCanceled" {
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

test "EpollPosixIO bind/listen/setsockopt fire inline (synchronous fallback)" {
    // The contract methods on epoll backends are synchronous fallbacks:
    // the syscall runs inline and the callback fires before the
    // submission method returns. No `tick` should be needed.
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const enable = std.mem.toBytes(@as(c_int, 1));
    var sso_c = Completion{};
    var sso_ctx = TestCtx{};
    try io.setsockopt(.{
        .fd = fd,
        .level = posix.SOL.SOCKET,
        .optname = posix.SO.REUSEADDR,
        .optval = &enable,
    }, &sso_c, &sso_ctx, testCallback);
    try testing.expectEqual(@as(u32, 1), sso_ctx.calls);
    switch (sso_ctx.last_result.?) {
        .setsockopt => |r| try r,
        else => try testing.expect(false),
    }

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var bind_c = Completion{};
    var bind_ctx = TestCtx{};
    try io.bind(.{ .fd = fd, .addr = addr }, &bind_c, &bind_ctx, testCallback);
    try testing.expectEqual(@as(u32, 1), bind_ctx.calls);
    switch (bind_ctx.last_result.?) {
        .bind => |r| try r,
        else => try testing.expect(false),
    }

    var listen_c = Completion{};
    var listen_ctx = TestCtx{};
    try io.listen(.{ .fd = fd, .backlog = 4 }, &listen_c, &listen_ctx, testCallback);
    try testing.expectEqual(@as(u32, 1), listen_ctx.calls);
    switch (listen_ctx.last_result.?) {
        .listen => |r| try r,
        else => try testing.expect(false),
    }
}

test "EpollPosixIO fsync round-trips through the file-op pool" {
    // File ops route through `PosixFilePool`. Worker calls `fdatasync`,
    // pushes the result, signals the eventfd; the next `tick` drains
    // the pool's completed queue and fires this callback.
    var io = try skipIfUnavailable();
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("epoll_fsync", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("ok");

    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &c, &ctx, testCallback);

    var attempts: u32 = 0;
    while (ctx.calls == 0 and attempts < 200) : (attempts += 1) {
        try io.tick(1);
    }
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fsync => |r| try r,
        else => try testing.expect(false),
    }
}

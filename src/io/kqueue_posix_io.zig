//! KqueuePosixIO — kqueue(2)-based backend with POSIX file-op strategy.
//!
//! KqueuePosixIO targets macOS (and, by extension, the BSDs). It exists so that
//! varuna can be developed on a macOS laptop; production stays on Linux /
//! io_uring. See `docs/epoll-kqueue-design.md` for the full survey and
//! per-op mapping; `progress-reports/2026-04-29-kqueue-io-mvp.md` for what
//! the original `KqueueIO` MVP shipped, and
//! `progress-reports/2026-04-30-kqueue-bifurcation.md` for the rename and
//! split into `KqueuePosixIO` (this file) + `KqueueMmapIO` (sibling).
//!
//! ## File-op strategy axis
//!
//! kqueue is a readiness API for *fds*; for regular files it always reports
//! readiness immediately, and the actual `read`/`write` syscall blocks the
//! caller. There are two valid file-op strategies on top of this:
//!
//!   * **POSIX (this file)** — `pread`/`pwrite`/`fsync`/`fcntl(F_PREALLOCATE)`
//!     syscalls offloaded to a thread pool. Predictable, matches io_uring's
//!     completion semantics, no implicit pagecache assumptions.
//!   * **mmap (`kqueue_mmap_io.zig`)** — file mapped into the address space
//!     at first access; reads/writes become `memcpy` against the mapping;
//!     durability via `msync(MS_SYNC)`. Zero-copy at the cost of page-fault
//!     latency on the EL thread.
//!
//! The readiness layer (sockets, timers, cancel) is identical between the
//! two; only the file-op submission methods diverge.
//!
//! ## Architecture
//!
//! kqueue is a *readiness* API (reactor): it tells you when an fd can be
//! read or written; the caller still performs the syscall itself. io_uring
//! is *completion* (proactor): the kernel performs the syscall and reports
//! a result. The contract was shaped for the proactor model. Mapping it
//! onto kqueue is mechanical:
//!
//!   1. Submit method tries the syscall non-blocking.
//!   2. On success or hard error, push a `(completion, result)` entry onto
//!      `completed`. The next `tick()` invokes the callback.
//!   3. On `EAGAIN`, register a one-shot `EVFILT_READ` / `EVFILT_WRITE`
//!      kevent against the fd, store the completion pointer in `udata`,
//!      and wait. When the kevent fires, retry the syscall and deliver.
//!
//! `tick()` calls `kevent()` with the staged change-list, fills an event
//! list with ready fds, retries each ready completion's syscall, drains the
//! `completed` queue by invoking callbacks, and returns. Timers are NOT
//! `EVFILT_TIMER` — they use a heap of deadlines, with the next deadline
//! passed as the `kevent()` `timeout` argument. (Per libxev's rationale:
//! many timers + EVFILT_TIMER = many syscalls.)
//!
//! ## Comptime gating
//!
//! kqueue is macOS-and-BSD-only. The Zig stdlib's `posix.kqueue` /
//! `posix.kevent` symbols are declared on every platform but their bodies
//! reference `system.kqueue` / `system.kevent`, which only exist when
//! targeting one of those OSes. We exploit Zig's lazy semantic analysis:
//! function bodies that touch those symbols are only analyzed if
//! reachable. As long as nothing on Linux instantiates KqueuePosixIO's
//! lifecycle methods (init/tick/etc.), the file compiles cleanly there.
//! Tests that invoke real kqueue syscalls comptime-skip on non-darwin.
//!
//! ## Scope of this MVP
//!
//! Implemented today:
//!   - Lifecycle: init / deinit / tick / closeSocket / bindWakeup
//!   - Timers: heap-of-deadlines + `timeout` op
//!   - Cancellation: best-effort `cancel` op (timer / kevent / pool)
//!   - Socket lifecycle: `socket` (sync), `connect` (with deadline),
//!     `accept` (single-shot + multishot emulation)
//!   - Stream IO: `recv`, `send`
//!   - Datagram IO: `recvmsg`, `sendmsg`
//!   - Readiness: `poll`
//!   - File ops: `read`, `write`, `fsync`, `fallocate`, `truncate`
//!     routed through `PosixFilePool`. Workers signal back via
//!     `EVFILT_USER` + `NOTE_TRIGGER` so `kevent()` returns. See
//!     `src/io/posix_file_pool.zig` for the pool itself; `EpollPosixIO`
//!     uses the same pool with eventfd as the wake primitive.
//!
//! ## Per-completion state
//!
//! Each `Completion._backend_state` carries a `KqueueState` with:
//!   * `in_flight`        — guards against double submission
//!   * `parked_filter`    — which kevent filter is parked (read/write)
//!   * `multishot`        — accept multishot emulation flag
//!   * `cancelled`        — best-effort cancel signal
//!   * `timer_index`      — index in timer heap (sentinel = not in heap)
//!   * `deadline_ns`      — absolute monotonic deadline (for timeouts /
//!                          connect-with-deadline)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
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

// EVFILT_USER + NOTE_TRIGGER constants used to wake `kevent()` from
// background pool workers. `std.c.EVFILT.USER` is normally correct but
// libxev / zio note that NetBSD's binding is wrong upstream; we mirror
// zio's switch for safety. NOTE_TRIGGER is platform-uniform per macOS /
// BSD docs.
const evfilt_user: i16 = switch (builtin.target.os.tag) {
    .netbsd => 8,
    else => if (@hasDecl(std.c, "EVFILT")) std.c.EVFILT.USER else 0,
};
const note_trigger: u32 = 0x01000000;

/// Stable identifier for our cross-thread user event. Chosen so it
/// doesn't collide with any fd we'd register on EVFILT_READ /
/// EVFILT_WRITE (those use the fd number as `ident`; EVFILT_USER lives
/// in a disjoint ident namespace per kqueue, but using a non-fd value
/// keeps debugging easier).
const waker_ident: usize = 0xFADEFADE;

/// True when the current target supports kqueue. Used to gate hot syscall
/// bodies; helpers and types are platform-agnostic so the file itself
/// compiles cleanly on Linux too.
const is_kqueue_platform = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

// ── Backend state ─────────────────────────────────────────

/// Per-completion bookkeeping stored in `Completion._backend_state`.
///
/// Layout (regular struct, not packed): bool + i16 + bool + bool + u32 +
/// u64 = 24 bytes with 8-byte alignment. Well inside the 64-byte contract
/// budget. Don't pack — see the SimIO note about packed-struct alignment.
pub const KqueueState = struct {
    in_flight: bool = false,
    multishot: bool = false,
    cancelled: bool = false,
    /// EVFILT_READ (=-1), EVFILT_WRITE (=-2), or 0 if not parked.
    parked_filter: i16 = 0,
    /// Index in the timer heap, `sentinel_index` if not in the heap.
    timer_index: u32 = sentinel_index,
    /// Absolute deadline in monotonic nanoseconds (timeouts and
    /// connect-with-deadline both use this field).
    deadline_ns: u64 = 0,
    /// Sequence number used to break heap ties deterministically.
    seq: u32 = 0,
};

comptime {
    assert(@sizeOf(KqueueState) <= ifc.backend_state_size);
    assert(@alignOf(KqueueState) <= ifc.backend_state_align);
}

inline fn kqueueState(c: *Completion) *KqueueState {
    return c.backendStateAs(KqueueState);
}

const sentinel_index: u32 = std.math.maxInt(u32);

// ── Configuration ─────────────────────────────────────────

pub const Config = struct {
    /// Maximum number of timers in flight. Submissions past this fail
    /// with `error.PendingQueueFull`.
    timer_capacity: u32 = 256,
    /// Maximum number of socket completions parked on kqueue at once.
    /// This is a soft sizing hint; the change-list is fed in batches of
    /// `change_batch`.
    pending_capacity: u32 = 4096,
    /// kevent change-list batch size — how many submissions we hand to
    /// `kevent()` in a single call. Mirrors tigerbeetle's 256.
    change_batch: u32 = 256,

    /// Number of worker threads in the file-op pool. Default 4 mirrors
    /// `hasher.zig`. Set to 0 only in tests that want inline-mode op
    /// execution.
    file_pool_workers: u32 = 4,
    /// Bound on outstanding file ops awaiting worker pickup. `submit`
    /// returns `error.PendingQueueFull` past this.
    file_pool_pending_capacity: u32 = 256,
};

// ── Pending change / completed entries ────────────────────

/// A staged kevent submission that hasn't been handed to the kernel yet.
const PendingChange = struct {
    completion: *Completion,
    /// EVFILT_READ or EVFILT_WRITE.
    filter: i16,
    /// Identifier — almost always the fd.
    ident: usize,
};

/// A completion ready to fire its callback. The result is precomputed and
/// stored verbatim so the callback receives the same shape regardless of
/// whether the op succeeded inline or came back through kevent.
const CompletedEntry = struct {
    completion: *Completion,
    result: Result,
};

/// Min-heap entry for timers.
const TimerEntry = struct {
    deadline_ns: u64,
    seq: u32,
    completion: *Completion,
};

fn timerLess(a: TimerEntry, b: TimerEntry) bool {
    if (a.deadline_ns != b.deadline_ns) return a.deadline_ns < b.deadline_ns;
    return a.seq < b.seq;
}

// ── KqueuePosixIO ──────────────────────────────────────────────

pub const KqueuePosixIO = struct {
    kq: posix.fd_t,

    /// Monotonically increasing sequence counter, used as a tiebreaker
    /// for heap ordering. Wraps at u32 max (we do not expect anywhere
    /// near 4G timers per process).
    seq_counter: u32 = 0,

    /// Staged kevent submissions awaiting flush in the next tick.
    /// Bounded by `cfg.pending_capacity`; allocated in `init`.
    pending_changes: std.ArrayListUnmanaged(PendingChange) = .{},

    /// Completions ready to fire their callbacks. Drained at the end of
    /// each tick.
    completed: std.ArrayListUnmanaged(CompletedEntry) = .{},

    /// Min-heap of pending timers, keyed by absolute monotonic deadline.
    /// Bounded by `cfg.timer_capacity`. Heap operations bump the
    /// `timer_index` field on each entry's KqueueState so that `cancel`
    /// can locate it in O(1).
    timers: std.ArrayListUnmanaged(TimerEntry) = .{},

    cfg: Config,
    allocator: std.mem.Allocator,

    /// File-op worker thread pool. read/write/fsync/fallocate/truncate
    /// route here; workers signal via NOTE_TRIGGER on the registered
    /// EVFILT_USER kevent.
    pool: *PosixFilePool,
    /// Scratch buffer reused across ticks for `pool.drainCompletedInto`.
    pool_swap: std.ArrayListUnmanaged(PoolCompleted) = .{},
    /// Counts file ops in flight on the pool. Used by the kevent
    /// timeout calc so we wait for the EVFILT_USER wake when the
    /// readiness side has nothing else to do.
    pool_in_flight: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !KqueuePosixIO {
        if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;

        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        const pool = try PosixFilePool.create(allocator, .{
            .worker_count = cfg.file_pool_workers,
            .pending_capacity = cfg.file_pool_pending_capacity,
        });
        errdefer pool.deinit();

        // Register the cross-thread user event. EV_CLEAR makes it
        // edge-triggered: each NOTE_TRIGGER fires exactly one wake; the
        // kernel resets the trigger bit when the event is delivered.
        var change: [1]posix.Kevent = .{.{
            .ident = waker_ident,
            .filter = evfilt_user,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = try posix.kevent(kq, &change, &.{}, null);

        var self = KqueuePosixIO{
            .kq = kq,
            .cfg = cfg,
            .allocator = allocator,
            .pool = pool,
        };

        try self.pending_changes.ensureTotalCapacity(allocator, cfg.pending_capacity);
        errdefer self.pending_changes.deinit(allocator);
        try self.completed.ensureTotalCapacity(allocator, cfg.pending_capacity);
        errdefer self.completed.deinit(allocator);
        try self.timers.ensureTotalCapacity(allocator, cfg.timer_capacity);

        return self;
    }

    /// Bind the file-op pool's wakeup callback to this kqueue. Must be
    /// called after `init` (which returns by value, so we need a stable
    /// `*KqueuePosixIO` for the wake closure to address).
    pub fn bindWakeup(self: *KqueuePosixIO) void {
        self.pool.setWakeup(self, wakeFromPool);
    }

    /// Wakeup hook handed to the file-op pool. Workers invoke this
    /// after pushing a result; a NOTE_TRIGGER on the registered
    /// EVFILT_USER ident makes `kevent()` return so `tick` drains the
    /// pool's completed queue.
    fn wakeFromPool(ctx: ?*anyopaque) void {
        if (comptime !is_kqueue_platform) return;
        const self: *KqueuePosixIO = @ptrCast(@alignCast(ctx.?));
        var change: [1]posix.Kevent = .{.{
            .ident = waker_ident,
            .filter = evfilt_user,
            .flags = 0,
            .fflags = note_trigger,
            .data = 0,
            .udata = 0,
        }};
        // kevent(2) is thread-safe against concurrent EL `kevent()`
        // calls on the same kq; the trigger is delivered atomically.
        _ = posix.kevent(self.kq, &change, &.{}, null) catch {};
    }

    pub fn deinit(self: *KqueuePosixIO) void {
        // Pool deinit joins workers BEFORE we close kq, so a
        // worker-issued NOTE_TRIGGER racing with shutdown is safe.
        self.pool.deinit();
        self.pool_swap.deinit(self.allocator);
        if (comptime is_kqueue_platform) {
            if (self.kq >= 0) posix.close(self.kq);
        }
        self.pending_changes.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Synchronous fd close. Symmetric with `RealIO.closeSocket` so
    /// `EventLoop.deinit` can call it uniformly.
    pub fn closeSocket(_: *KqueuePosixIO, fd: posix.fd_t) void {
        posix.close(fd);
    }

    /// Drive the loop forward by one batch:
    ///   1. Pop expired timers, deliver them.
    ///   2. Drain `completed` (synchronous-result completions).
    ///   3. Hand staged kevents to the kernel and harvest ready events.
    ///   4. Re-drain `completed` (kevent retries that succeeded inline).
    ///
    /// `wait_at_least` is a hint: when 0, kevent() polls with a zero
    /// timespec; otherwise we wait until either a kevent fires or the
    /// next timer deadline passes. Mirrors RealIO's submit_and_wait
    /// semantics.
    pub fn tick(self: *KqueuePosixIO, wait_at_least: u32) !void {
        if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;

        const now = monotonicNs();
        // Expire any timers whose deadline has passed.
        try self.expireTimers(now);

        // Drain the file-op pool first so any callbacks they fire land
        // alongside synchronous completions in a single tick. Pool
        // completions go through `dispatchPoolEntry` (separate from
        // `drainCompleted` because pool entries already carry a
        // pre-resolved Result and are tracked in `pool_in_flight`, not
        // `pending_changes`).
        try self.drainPool();

        // First drain pass — synchronous successes/failures.
        self.drainCompleted();

        // Build the kevent change-list from staged submissions.
        var change_buf: [256]posix.Kevent = undefined;
        const change_cap = @min(change_buf.len, self.cfg.change_batch);
        const changes_to_submit = @min(self.pending_changes.items.len, change_cap);
        for (self.pending_changes.items[0..changes_to_submit], 0..) |pc, i| {
            change_buf[i] = makeKevent(pc.ident, pc.filter, @intFromPtr(pc.completion));
        }

        // Decide on the kevent timeout.
        var ts_storage: posix.timespec = undefined;
        const timeout_ptr: ?*const posix.timespec = blk: {
            if (wait_at_least == 0) {
                ts_storage = .{ .sec = 0, .nsec = 0 };
                break :blk &ts_storage;
            }
            // Wait until the soonest of: nothing (block) / next timer.
            if (self.peekNextDeadline()) |deadline_ns| {
                const wait_ns = if (deadline_ns > monotonicNs()) deadline_ns - monotonicNs() else 0;
                ts_storage = .{
                    .sec = @intCast(wait_ns / std.time.ns_per_s),
                    .nsec = @intCast(wait_ns % std.time.ns_per_s),
                };
                break :blk &ts_storage;
            }
            // No timers — block until any kevent fires.
            break :blk null;
        };

        var event_buf: [256]posix.Kevent = undefined;
        const got = try posix.kevent(
            self.kq,
            change_buf[0..changes_to_submit],
            &event_buf,
            timeout_ptr,
        );

        // Successful submissions consumed; drop them from pending.
        if (changes_to_submit > 0) {
            // Slide the tail down in-place.
            const remaining = self.pending_changes.items.len - changes_to_submit;
            for (0..remaining) |i| {
                self.pending_changes.items[i] = self.pending_changes.items[i + changes_to_submit];
            }
            self.pending_changes.shrinkRetainingCapacity(remaining);
        }

        // Re-expire timers (kevent may have blocked through a deadline).
        try self.expireTimers(monotonicNs());

        // Process ready events.
        for (event_buf[0..got]) |ev| {
            // Cross-thread wake from the file-op pool. The pool's
            // workers have pushed results onto `pool.completed`; the
            // post-loop `drainPool` call below picks them up.
            if (ev.filter == evfilt_user and ev.ident == waker_ident) continue;
            const c: *Completion = @ptrFromInt(ev.udata);
            const st = kqueueState(c);
            st.parked_filter = 0;
            // Cancellation requested?
            if (st.cancelled) {
                self.pushCompleted(c, makeCancelledResult(c.op));
                continue;
            }
            try self.retrySyscall(c, ev);
        }

        // Drain the pool again — workers may have pushed between the
        // pre-tick drain and now.
        try self.drainPool();

        // Final drain of any newly-completed callbacks.
        self.drainCompleted();
    }

    fn drainPool(self: *KqueuePosixIO) !void {
        try self.pool.drainCompletedInto(&self.pool_swap);
        defer self.pool_swap.clearRetainingCapacity();
        for (self.pool_swap.items) |entry| {
            self.dispatchPoolEntry(entry);
        }
    }

    /// Fire the user callback for one pool completion. Mirrors
    /// `dispatch` (the readiness-side equivalent) — clears in_flight
    /// before invoking the callback so a callback that resubmits a
    /// follow-on op on the same completion doesn't trip
    /// `AlreadyInFlight` against itself.
    fn dispatchPoolEntry(self: *KqueuePosixIO, entry: PoolCompleted) void {
        const c = entry.completion;
        const cb = c.callback orelse return;
        kqueueState(c).in_flight = false;
        self.pool_in_flight -|= 1;
        const action = cb(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => switch (c.op) {
                .read => |op| self.read(op, c, c.userdata, cb) catch {},
                .write => |op| self.write(op, c, c.userdata, cb) catch {},
                .fsync => |op| self.fsync(op, c, c.userdata, cb) catch {},
                .fallocate => |op| self.fallocate(op, c, c.userdata, cb) catch {},
                .truncate => |op| self.truncate(op, c, c.userdata, cb) catch {},
                else => {}, // callback overwrote c.op with a non-file op
            },
        }
    }

    // ── Internal: completed queue + dispatch ───────────────

    fn drainCompleted(self: *KqueuePosixIO) void {
        // Walk the queue. Callbacks may submit follow-on ops that push
        // *more* entries onto `completed`; we capture the current length
        // first, dispatch those, then loop. This avoids an unbounded
        // recursion-style drain inside one tick while still letting a
        // synchronous callback land its rearm before we return.
        while (self.completed.items.len > 0) {
            const entry = self.completed.orderedRemove(0);
            self.dispatch(entry);
        }
    }

    fn pushCompleted(self: *KqueuePosixIO, c: *Completion, result: Result) void {
        // Cap-bound; we ensured capacity in init.
        self.completed.appendAssumeCapacity(.{ .completion = c, .result = result });
    }

    fn dispatch(self: *KqueuePosixIO, entry: CompletedEntry) void {
        const c = entry.completion;
        const callback = c.callback orelse return;
        // Clear in_flight before invoking — see `io_interface.zig` for
        // the rationale (callbacks may submit follow-on ops on the same
        // completion).
        kqueueState(c).in_flight = false;
        const action = callback(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => {
                // For the MVP, .rearm only re-runs the same op via the
                // generic resubmit path.
                self.resubmit(c) catch {
                    // Best-effort — surface the error through the same
                    // result variant. This path is rare enough to avoid
                    // adding an error channel just for it.
                };
            },
        }
    }

    fn resubmit(self: *KqueuePosixIO, c: *Completion) !void {
        const ud = c.userdata;
        const cb = c.callback orelse return;
        switch (c.op) {
            .none => {},
            .recv => |op| try self.recv(op, c, ud, cb),
            .send => |op| try self.send(op, c, ud, cb),
            .recvmsg => |op| try self.recvmsg(op, c, ud, cb),
            .sendmsg => |op| try self.sendmsg(op, c, ud, cb),
            .read => |op| try self.read(op, c, ud, cb),
            .write => |op| try self.write(op, c, ud, cb),
            .fsync => |op| try self.fsync(op, c, ud, cb),
            .fallocate => |op| try self.fallocate(op, c, ud, cb),
            .truncate => |op| try self.truncate(op, c, ud, cb),
            .socket => |op| try self.socket(op, c, ud, cb),
            .connect => |op| try self.connect(op, c, ud, cb),
            .accept => |op| try self.accept(op, c, ud, cb),
            .timeout => |op| try self.timeout(op, c, ud, cb),
            .poll => |op| try self.poll(op, c, ud, cb),
            .cancel => |op| try self.cancel(op, c, ud, cb),
        }
    }

    fn armCompletion(self: *KqueuePosixIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        _ = self;
        const st = kqueueState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{ .in_flight = true };
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }

    // ── Internal: kevent helpers ──────────────────────────

    fn parkOnFilter(self: *KqueuePosixIO, c: *Completion, fd: posix.fd_t, filter: i16) !void {
        if (self.pending_changes.items.len >= self.cfg.pending_capacity) {
            return error.PendingQueueFull;
        }
        kqueueState(c).parked_filter = filter;
        self.pending_changes.appendAssumeCapacity(.{
            .completion = c,
            .filter = filter,
            .ident = @intCast(fd),
        });
    }

    fn retrySyscall(self: *KqueuePosixIO, c: *Completion, ev: posix.Kevent) !void {
        // The op tag tells us how to retry. EOF / error info comes via
        // ev.flags / ev.fflags.
        const got_eof = if (comptime is_kqueue_platform)
            (ev.flags & std.c.EV.EOF) != 0
        else
            false;
        const errno_payload: u32 = if (comptime is_kqueue_platform)
            if ((ev.flags & std.c.EV.ERROR) != 0) @intCast(ev.fflags) else 0
        else
            0;

        switch (c.op) {
            .recv => |op| {
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .recv = errnoFromCInt(errno_payload) });
                    return;
                }
                self.tryRecv(op, c) catch {
                    // Retry on transient EAGAIN: keep parked.
                };
            },
            .send => |op| {
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .send = errnoFromCInt(errno_payload) });
                    return;
                }
                self.trySend(op, c) catch {};
            },
            .recvmsg => |op| {
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .recvmsg = errnoFromCInt(errno_payload) });
                    return;
                }
                self.tryRecvmsg(op, c) catch {};
            },
            .sendmsg => |op| {
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .sendmsg = errnoFromCInt(errno_payload) });
                    return;
                }
                self.trySendmsg(op, c) catch {};
            },
            .accept => |op| {
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .accept = errnoFromCInt(errno_payload) });
                    return;
                }
                self.tryAccept(op, c) catch {};
            },
            .connect => |op| {
                // EOF on the write filter without errno typically means the
                // peer closed during the connect handshake. Surface it as
                // a connect refusal so callers see a clean error path.
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .connect = errnoFromCInt(errno_payload) });
                    return;
                }
                if (got_eof) {
                    self.pushCompleted(c, .{ .connect = error.ConnectionRefused });
                    return;
                }
                // Probe SO_ERROR to capture the actual connect outcome.
                const so_err = posix.getsockoptError(op.fd) catch |err| {
                    self.pushCompleted(c, .{ .connect = err });
                    return;
                };
                _ = so_err; // void-on-success
                self.pushCompleted(c, .{ .connect = {} });
            },
            .poll => |op| {
                // Translate the kevent filter back to POLL_* bits.
                var revents: u32 = 0;
                if (opFilterIsRead(op)) revents |= posix.POLL.IN;
                if (opFilterIsWrite(op)) revents |= posix.POLL.OUT;
                if (got_eof) revents |= posix.POLL.HUP;
                if (errno_payload != 0) revents |= posix.POLL.ERR;
                self.pushCompleted(c, .{ .poll = revents });
            },
            else => {
                // Other ops shouldn't be parked on kevent today.
                self.pushCompleted(c, makeCancelledResult(c.op));
            },
        }
    }

    // ── Timer heap ────────────────────────────────────────

    fn peekNextDeadline(self: *KqueuePosixIO) ?u64 {
        if (self.timers.items.len == 0) return null;
        return self.timers.items[0].deadline_ns;
    }

    fn expireTimers(self: *KqueuePosixIO, now_ns: u64) !void {
        while (self.timers.items.len > 0 and self.timers.items[0].deadline_ns <= now_ns) {
            const entry = self.popMinTimer();
            const c = entry.completion;
            kqueueState(c).timer_index = sentinel_index;
            // Distinguish timeouts from connect-with-deadline by op tag.
            switch (c.op) {
                .timeout => self.pushCompleted(c, .{ .timeout = {} }),
                .connect => {
                    // Deadline expired before the kevent fired; cancel the
                    // socket parking and deliver a timeout.
                    kqueueState(c).cancelled = true;
                    self.pushCompleted(c, .{ .connect = error.ConnectionTimedOut });
                },
                else => {
                    // Unexpected op in the heap. Defensive fallthrough.
                    self.pushCompleted(c, makeCancelledResult(c.op));
                },
            }
        }
    }

    fn pushTimer(self: *KqueuePosixIO, deadline_ns: u64, c: *Completion) !void {
        if (self.timers.items.len >= self.cfg.timer_capacity) {
            return error.PendingQueueFull;
        }
        const seq = self.seq_counter;
        self.seq_counter +%= 1;
        const entry = TimerEntry{ .deadline_ns = deadline_ns, .seq = seq, .completion = c };
        var idx: u32 = @intCast(self.timers.items.len);
        self.timers.appendAssumeCapacity(entry);
        kqueueState(c).timer_index = idx;
        kqueueState(c).deadline_ns = deadline_ns;
        kqueueState(c).seq = seq;
        // Sift up.
        while (idx > 0) {
            const parent = (idx - 1) / 2;
            if (timerLess(self.timers.items[idx], self.timers.items[parent])) {
                self.swapTimers(idx, parent);
                idx = parent;
            } else break;
        }
    }

    fn popMinTimer(self: *KqueuePosixIO) TimerEntry {
        const entry = self.timers.items[0];
        const last = self.timers.pop().?;
        if (self.timers.items.len > 0) {
            self.timers.items[0] = last;
            kqueueState(last.completion).timer_index = 0;
            self.siftDown(0);
        }
        return entry;
    }

    fn removeTimerAt(self: *KqueuePosixIO, idx: u32) void {
        const last = self.timers.pop().?;
        if (idx == self.timers.items.len) return; // popped tail
        self.timers.items[idx] = last;
        kqueueState(last.completion).timer_index = idx;
        // Could move up or down; try both.
        self.siftDown(idx);
        var i: u32 = idx;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (timerLess(self.timers.items[i], self.timers.items[parent])) {
                self.swapTimers(i, parent);
                i = parent;
            } else break;
        }
    }

    fn siftDown(self: *KqueuePosixIO, start_idx: u32) void {
        var idx: u32 = start_idx;
        const n: u32 = @intCast(self.timers.items.len);
        while (true) {
            const left = idx * 2 + 1;
            const right = idx * 2 + 2;
            var smallest = idx;
            if (left < n and timerLess(self.timers.items[left], self.timers.items[smallest])) {
                smallest = left;
            }
            if (right < n and timerLess(self.timers.items[right], self.timers.items[smallest])) {
                smallest = right;
            }
            if (smallest == idx) break;
            self.swapTimers(idx, smallest);
            idx = smallest;
        }
    }

    fn swapTimers(self: *KqueuePosixIO, a: u32, b: u32) void {
        const tmp = self.timers.items[a];
        self.timers.items[a] = self.timers.items[b];
        self.timers.items[b] = tmp;
        kqueueState(self.timers.items[a].completion).timer_index = a;
        kqueueState(self.timers.items[b].completion).timer_index = b;
    }

    // ── Submission methods ────────────────────────────────

    pub fn timeout(self: *KqueuePosixIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        const deadline = monotonicNs() +| op.ns;
        try self.pushTimer(deadline, c);
    }

    pub fn socket(self: *KqueuePosixIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .socket = op }, ud, cb);
        // macOS lacks SOCK_NONBLOCK / SOCK_CLOEXEC flags. Open the socket
        // first, then fcntl.
        const result: Result = blk: {
            const fd = posix.socket(@intCast(op.domain), @intCast(op.sock_type), @intCast(op.protocol)) catch |err| {
                break :blk .{ .socket = err };
            };
            setNonblockCloexec(fd) catch |err| {
                posix.close(fd);
                break :blk .{ .socket = err };
            };
            break :blk .{ .socket = fd };
        };
        self.pushCompleted(c, result);
    }

    pub fn connect(self: *KqueuePosixIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);

        const addrlen = op.addr.getOsSockLen();
        const rc = posix.connect(op.fd, &op.addr.any, addrlen);
        if (rc) |_| {
            // Connected immediately (rare but legal — local connections).
            self.pushCompleted(c, .{ .connect = {} });
            return;
        } else |err| switch (err) {
            error.WouldBlock => {
                // Park on EVFILT_WRITE; on readiness we probe SO_ERROR.
                try self.parkOnFilter(c, op.fd, std.c.EVFILT.WRITE);
                if (op.deadline_ns) |ns| {
                    const deadline = monotonicNs() +| ns;
                    try self.pushTimer(deadline, c);
                }
            },
            else => self.pushCompleted(c, .{ .connect = err }),
        }
    }

    pub fn accept(self: *KqueuePosixIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        kqueueState(c).multishot = op.multishot;
        try self.tryAccept(op, c);
    }

    fn tryAccept(self: *KqueuePosixIO, op: ifc.AcceptOp, c: *Completion) !void {
        var addr: posix.sockaddr.storage = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const accepted = posix.accept(op.fd, @ptrCast(&addr), &addrlen, 0);
        if (accepted) |fd| {
            setNonblockCloexec(fd) catch |err| {
                posix.close(fd);
                self.pushCompleted(c, .{ .accept = err });
                return;
            };
            // No SOCK_NONBLOCK on macOS, so accept() doesn't honour the
            // flag at the syscall level — we set it via fcntl above.
            const accepted_addr = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(@alignCast(&addr))).* };
            self.pushCompleted(c, .{ .accept = .{ .fd = fd, .addr = accepted_addr } });
            // Multishot emulation: re-park on EVFILT_READ for the next.
            if (op.multishot) try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ);
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ),
            else => self.pushCompleted(c, .{ .accept = err }),
        }
    }

    pub fn recv(self: *KqueuePosixIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op }, ud, cb);
        try self.tryRecv(op, c);
    }

    fn tryRecv(self: *KqueuePosixIO, op: ifc.RecvOp, c: *Completion) !void {
        const r = posix.recv(op.fd, op.buf, op.flags);
        if (r) |n| {
            self.pushCompleted(c, .{ .recv = n });
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ),
            else => self.pushCompleted(c, .{ .recv = err }),
        }
    }

    pub fn send(self: *KqueuePosixIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op }, ud, cb);
        try self.trySend(op, c);
    }

    fn trySend(self: *KqueuePosixIO, op: ifc.SendOp, c: *Completion) !void {
        const r = posix.send(op.fd, op.buf, op.flags);
        if (r) |n| {
            self.pushCompleted(c, .{ .send = n });
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.WRITE),
            else => self.pushCompleted(c, .{ .send = err }),
        }
    }

    pub fn recvmsg(self: *KqueuePosixIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op }, ud, cb);
        try self.tryRecvmsg(op, c);
    }

    fn tryRecvmsg(self: *KqueuePosixIO, op: ifc.RecvmsgOp, c: *Completion) !void {
        const rc = if (comptime is_kqueue_platform)
            std.c.recvmsg(op.fd, op.msg, @intCast(op.flags))
        else
            -1;
        const errno = posix.errno(rc);
        if (rc >= 0) {
            self.pushCompleted(c, .{ .recvmsg = @intCast(rc) });
            return;
        }
        switch (errno) {
            .AGAIN => try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ),
            else => |e| self.pushCompleted(c, .{ .recvmsg = posix.unexpectedErrno(e) }),
        }
    }

    pub fn sendmsg(self: *KqueuePosixIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op }, ud, cb);
        try self.trySendmsg(op, c);
    }

    fn trySendmsg(self: *KqueuePosixIO, op: ifc.SendmsgOp, c: *Completion) !void {
        const rc = if (comptime is_kqueue_platform)
            std.c.sendmsg(op.fd, op.msg, @intCast(op.flags))
        else
            -1;
        const errno = posix.errno(rc);
        if (rc >= 0) {
            self.pushCompleted(c, .{ .sendmsg = @intCast(rc) });
            return;
        }
        switch (errno) {
            .AGAIN => try self.parkOnFilter(c, op.fd, std.c.EVFILT.WRITE),
            else => |e| self.pushCompleted(c, .{ .sendmsg = posix.unexpectedErrno(e) }),
        }
    }

    pub fn poll(self: *KqueuePosixIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        // Map POLL_IN→EVFILT_READ, POLL_OUT→EVFILT_WRITE. If both are set
        // we currently only register the first; full multi-filter support
        // is a nice-to-have follow-up.
        const wants_in = (op.events & posix.POLL.IN) != 0;
        const wants_out = (op.events & posix.POLL.OUT) != 0;
        if (!wants_in and !wants_out) {
            self.pushCompleted(c, .{ .poll = error.InvalidArgument });
            return;
        }
        const filter: i16 = if (wants_in) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
        try self.parkOnFilter(c, op.fd, filter);
    }

    pub fn cancel(self: *KqueuePosixIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);
        const target = op.target;
        const tst = kqueueState(target);

        // Best-effort. Four parking states to handle:
        //   * In timer heap → remove, deliver OperationCanceled.
        //   * Parked on kevent → mark cancelled; tick will deliver
        //     OperationCanceled when the filter fires (or never, if it
        //     doesn't — this is the "best-effort" gap from the design doc).
        //   * Pending on the file-op pool → tryCancelPending pulls it
        //     off the queue and pushes Cancelled. Workers that have
        //     already picked up the op cannot be interrupted.
        //   * Already completed / not in flight → OperationNotFound.
        var found = false;
        if (tst.timer_index != sentinel_index) {
            self.removeTimerAt(tst.timer_index);
            tst.timer_index = sentinel_index;
            self.pushCompleted(target, makeCancelledResult(target.op));
            found = true;
        } else if (tst.parked_filter != 0) {
            tst.cancelled = true;
            // Deliver immediately rather than waiting for the filter —
            // matches the contract's "cancel callback fires next tick"
            // shape used by RealIO.
            self.pushCompleted(target, makeCancelledResult(target.op));
            found = true;
        } else {
            const target_is_file = switch (target.op) {
                .read, .write, .fsync, .fallocate, .truncate => true,
                else => false,
            };
            if (target_is_file and self.pool.tryCancelPending(target)) {
                // Pool pushed Cancelled onto its completed queue;
                // `dispatchPoolEntry` will fire the target's callback on
                // the next `drainPool` (and decrement `pool_in_flight`
                // there).
                found = true;
            }
        }

        const result: anyerror!void = if (found) {} else error.OperationNotFound;
        self.pushCompleted(c, .{ .cancel = result });
    }

    // ── File ops (PosixFilePool-routed) ───────────────────
    //
    // kevent reports regular files as always-ready; the actual
    // `pread`/`pwrite`/`fsync`/etc. syscall blocks on page faults. We
    // offload to a worker thread; the worker pushes the result onto
    // `pool.completed` and signals `EVFILT_USER` so `kevent()` returns.
    // The next `tick` drains via `drainPool`. Same shape as
    // `EpollPosixIO`'s file-op path, with the wake primitive swapped.

    pub fn read(self: *KqueuePosixIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        try self.submitFileOp(.{ .read = op }, c);
    }

    pub fn write(self: *KqueuePosixIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        try self.submitFileOp(.{ .write = op }, c);
    }

    pub fn fsync(self: *KqueuePosixIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        try self.submitFileOp(.{ .fsync = op }, c);
    }

    pub fn fallocate(self: *KqueuePosixIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        try self.submitFileOp(.{ .fallocate = op }, c);
    }

    pub fn truncate(self: *KqueuePosixIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        try self.submitFileOp(.{ .truncate = op }, c);
    }

    fn submitFileOp(self: *KqueuePosixIO, op: FileOp, c: *Completion) !void {
        self.pool_in_flight += 1;
        self.pool.submit(op, c) catch |err| {
            self.pool_in_flight -|= 1;
            kqueueState(c).in_flight = false;
            return err;
        };
    }
};

// ── Helpers ───────────────────────────────────────────────

/// Monotonic ns reader for the kqueue backend's own scheduling.
///
/// Clock injection note: the runtime `Clock` abstraction explicitly
/// excludes IO-backend internal timekeeping. The kqueue backend IS the
/// time source for its own deadline heap; routing through `Clock` would
/// be circular. SimIO has its own logical clock; this code only runs on
/// real macOS/BSD kqueue.
inline fn monotonicNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn makeKevent(ident: usize, filter: i16, udata: usize) posix.Kevent {
    if (comptime is_kqueue_platform) {
        return .{
            .ident = ident,
            .filter = filter,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
    } else {
        // Compile-time unreachable on Linux; we never call this body.
        @compileError("kqueue helpers should only be invoked on a kqueue platform");
    }
}

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
        .fallocate => .{ .fallocate = error.OperationCanceled },
        .truncate => .{ .truncate = error.OperationCanceled },
        .socket => .{ .socket = error.OperationCanceled },
        .connect => .{ .connect = error.OperationCanceled },
        .accept => .{ .accept = error.OperationCanceled },
        .timeout => .{ .timeout = error.OperationCanceled },
        .poll => .{ .poll = error.OperationCanceled },
        .cancel => .{ .cancel = error.OperationCanceled },
    };
}

fn errnoFromCInt(errno_value: u32) anyerror {
    // Map common errno values to varuna's error names. Mirrors RealIO's
    // errnoToError (see real_io.zig:443+) but indexed via the numeric
    // errno that kqueue's EV_ERROR delivers in fflags rather than the
    // Linux enum.
    return switch (errno_value) {
        @intFromEnum(posix.E.CONNREFUSED) => error.ConnectionRefused,
        @intFromEnum(posix.E.CONNRESET) => error.ConnectionResetByPeer,
        @intFromEnum(posix.E.NETUNREACH) => error.NetworkUnreachable,
        @intFromEnum(posix.E.HOSTUNREACH) => error.HostUnreachable,
        @intFromEnum(posix.E.TIMEDOUT) => error.ConnectionTimedOut,
        @intFromEnum(posix.E.PIPE) => error.BrokenPipe,
        @intFromEnum(posix.E.CONNABORTED) => error.ConnectionAborted,
        @intFromEnum(posix.E.AGAIN) => error.WouldBlock,
        @intFromEnum(posix.E.BADF) => error.BadFileDescriptor,
        @intFromEnum(posix.E.INTR) => error.Interrupted,
        @intFromEnum(posix.E.INVAL) => error.InvalidArgument,
        @intFromEnum(posix.E.IO) => error.InputOutput,
        @intFromEnum(posix.E.NOSPC) => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

fn setNonblockCloexec(fd: posix.fd_t) !void {
    if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, posix.SOCK.NONBLOCK));
    const fdflags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, fdflags | posix.FD_CLOEXEC);
}

// PollOp helpers — small extensions used by the retry path. Defined out
// of line so the contract type stays free of backend-specific helpers.
fn opFilterIsRead(op: ifc.PollOp) bool {
    return (op.events & std.posix.POLL.IN) != 0;
}
fn opFilterIsWrite(op: ifc.PollOp) bool {
    return (op.events & std.posix.POLL.OUT) != 0;
}

// ── Tests (mock-based; comptime-skip platform-specific ones) ─

const testing = std.testing;

test "KqueuePosixIO: state size and alignment fit the contract budget" {
    try testing.expect(@sizeOf(KqueueState) <= ifc.backend_state_size);
    try testing.expect(@alignOf(KqueueState) <= ifc.backend_state_align);
}

test "KqueuePosixIO: timer heap orders by deadline then sequence" {
    var entries = [_]TimerEntry{
        .{ .deadline_ns = 30, .seq = 1, .completion = undefined },
        .{ .deadline_ns = 10, .seq = 0, .completion = undefined },
        .{ .deadline_ns = 20, .seq = 0, .completion = undefined },
        .{ .deadline_ns = 20, .seq = 1, .completion = undefined },
        .{ .deadline_ns = 5, .seq = 99, .completion = undefined },
    };
    std.sort.heap(TimerEntry, &entries, {}, struct {
        fn lt(_: void, a: TimerEntry, b: TimerEntry) bool {
            return timerLess(a, b);
        }
    }.lt);
    try testing.expectEqual(@as(u64, 5), entries[0].deadline_ns);
    try testing.expectEqual(@as(u64, 10), entries[1].deadline_ns);
    try testing.expectEqual(@as(u64, 20), entries[2].deadline_ns);
    try testing.expectEqual(@as(u32, 0), entries[2].seq);
    try testing.expectEqual(@as(u64, 20), entries[3].deadline_ns);
    try testing.expectEqual(@as(u32, 1), entries[3].seq);
    try testing.expectEqual(@as(u64, 30), entries[4].deadline_ns);
}

test "KqueuePosixIO: makeCancelledResult preserves op tag" {
    const tags = .{
        .{ Operation{ .recv = .{ .fd = 0, .buf = &[_]u8{} } }, "recv" },
        .{ Operation{ .send = .{ .fd = 0, .buf = &[_]u8{} } }, "send" },
        .{ Operation{ .timeout = .{ .ns = 0 } }, "timeout" },
    };
    inline for (tags) |t| {
        const r = makeCancelledResult(t[0]);
        const got_tag: Result = r;
        switch (got_tag) {
            inline else => |_, tag| try testing.expect(std.mem.eql(u8, @tagName(tag), t[1])),
        }
    }
}

test "KqueuePosixIO: errnoFromCInt maps common errnos" {
    try testing.expectEqual(error.ConnectionRefused, errnoFromCInt(@intFromEnum(posix.E.CONNREFUSED)));
    try testing.expectEqual(error.WouldBlock, errnoFromCInt(@intFromEnum(posix.E.AGAIN)));
    try testing.expectEqual(error.Unexpected, errnoFromCInt(99999));
}

test "KqueuePosixIO: init succeeds and deinit closes kq (skipped on non-kqueue platforms)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueuePosixIO.init(testing.allocator, .{});
    defer io.deinit();
    try testing.expect(io.kq >= 0);
}

test "KqueuePosixIO: timeout fires after the deadline (real syscall path; skipped on non-kqueue)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueuePosixIO.init(testing.allocator, .{});
    defer io.deinit();

    const Ctx = struct {
        fired: bool = false,
        last: ?Result = null,
    };
    var ctx = Ctx{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const c: *Ctx = @ptrCast(@alignCast(ud.?));
            c.fired = true;
            c.last = result;
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, cb);
    while (!ctx.fired) try io.tick(1);

    switch (ctx.last.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

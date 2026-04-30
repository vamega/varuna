//! KqueueMmapIO — kqueue(2) backend with mmap-based file-op strategy.
//!
//! Sibling of `kqueue_posix_io.zig`. The readiness layer (sockets, timers,
//! cancel) is identical to KqueuePosixIO — kqueue is a readiness API and
//! the mapping from io_interface → kqueue events does not depend on how
//! files are accessed. The two files diverge only in the file-op
//! submission methods.
//!
//! ## File-op strategy
//!
//! Every file fd that the daemon reads/writes is `mmap`'d into the process
//! address space at first access:
//!
//!   * `read` / `write` (positional) → bounds-checked `memcpy` against the
//!     mapping. No syscall on the hot path; the OS pagecache services
//!     misses via page faults.
//!   * `fsync` → `msync(memory, MS_SYNC)` over the mapping. Darwin's
//!     `msync` does not distinguish data-only from data+metadata; we issue
//!     `MSF.SYNC` for both `datasync=true` and `datasync=false`. (Apple's
//!     `F_FULLFSYNC` would give true durability — out of scope for a dev
//!     backend.)
//!   * `fallocate` → `fcntl(F_PREALLOCATE)` + `ftruncate`. Darwin lacks
//!     Linux-style `fallocate`; this is the documented dev-backend
//!     emulation (matches `tigerbeetle/src/io/darwin.zig:fs_allocate`).
//!     `error.OperationNotSupported` is delivered if the underlying
//!     filesystem rejects F_PREALLOCATE (the daemon's fallback path then
//!     trips through `truncate`, identical to Linux's tmpfs<5.10 path).
//!   * `truncate` → unmap-if-mapped + `ftruncate`. macOS lacks `mremap`,
//!     so resizing a mapped file requires `munmap` followed by a fresh
//!     `mmap` on the next access.
//!
//! ## Why mmap for a dev backend
//!
//! The daemon's piece-store hot path is positional reads/writes against
//! large files. On Linux, io_uring delivers true asynchrony plus
//! IORING_OP_READ_FIXED's zero-copy. On macOS without io_uring, the two
//! options are:
//!
//!   1. **POSIX (the sibling)** — pread/pwrite on a worker thread. One
//!      thread-pool round-trip per request. Predictable cost; matches
//!      io_uring's submit-then-wait shape; works on every filesystem.
//!   2. **mmap (this file)** — memcpy on the EL thread. Zero syscalls in
//!      steady state, but the page-fault cost lands on the EL thread
//!      when the working set exceeds RAM. Acceptable for development
//!      where torrents are small relative to RAM.
//!
//! Production stays on Linux/io_uring regardless. The two macOS variants
//! exist to let developers compare strategies under a real workload —
//! and to keep the macOS dev path compiling cleanly through any future
//! file-op refactor.
//!
//! ## Per-completion state
//!
//! Same `KqueueState` as KqueuePosixIO (file ops are synchronous — no
//! parked-filter or timer-heap entries needed for them).

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

/// True when the current target supports kqueue. Same gate as KqueuePosixIO
/// — keeps the file compilable on Linux while letting Zig's lazy semantic
/// analysis skip macOS-only syscall bodies.
const is_kqueue_platform = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

// ── Backend state ─────────────────────────────────────────

/// Per-completion bookkeeping. Identical layout to KqueuePosixIO so the
/// shared readiness logic copy-pastes cleanly. Kept as a sibling type
/// (rather than an `@import` from kqueue_posix_io.zig) to avoid coupling
/// the two backends through a shared header.
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
    /// Maximum number of timers in flight.
    timer_capacity: u32 = 256,
    /// Maximum number of socket completions parked on kqueue at once.
    pending_capacity: u32 = 4096,
    /// kevent change-list batch size.
    change_batch: u32 = 256,
    /// Maximum number of concurrent file mappings. The MVP allocates a
    /// fixed-size table; growth is a follow-up.
    file_mapping_capacity: u32 = 256,
    /// Whether to issue `madvise(WILLNEED)` after mmap. Darwin lacks
    /// `MAP_POPULATE`; this is the closest equivalent.
    advise_willneed: bool = true,
};

// ── Pending change / completed entries ────────────────────

const PendingChange = struct {
    completion: *Completion,
    filter: i16,
    ident: usize,
};

const CompletedEntry = struct {
    completion: *Completion,
    result: Result,
};

const TimerEntry = struct {
    deadline_ns: u64,
    seq: u32,
    completion: *Completion,
};

fn timerLess(a: TimerEntry, b: TimerEntry) bool {
    if (a.deadline_ns != b.deadline_ns) return a.deadline_ns < b.deadline_ns;
    return a.seq < b.seq;
}

// ── File-mapping table ────────────────────────────────────

/// One entry per mmap'd file. The mapping covers the file [0, len) at
/// the moment we mapped it; if the file grows past `len` we must remap.
const FileMapping = struct {
    /// Page-aligned base pointer returned by mmap.
    base: [*]align(std.heap.page_size_min) u8,
    /// Length we passed to mmap. Bounds-checks against this.
    len: usize,
};

const FileMappingTable = std.AutoHashMapUnmanaged(posix.fd_t, FileMapping);

// ── Darwin F_PREALLOCATE plumbing ─────────────────────────
//
// macOS has no `fallocate(2)`; the closest call is `fcntl(F_PREALLOCATE)`
// with an `fstore_t` argument. Layout copied verbatim from
// `reference-codebases/tigerbeetle/src/io/darwin.zig:fs_allocate`.

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

// ── KqueueMmapIO ──────────────────────────────────────────

pub const KqueueMmapIO = struct {
    kq: posix.fd_t,

    seq_counter: u32 = 0,
    pending_changes: std.ArrayListUnmanaged(PendingChange) = .{},
    completed: std.ArrayListUnmanaged(CompletedEntry) = .{},
    timers: std.ArrayListUnmanaged(TimerEntry) = .{},
    file_mappings: FileMappingTable = .{},

    cfg: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !KqueueMmapIO {
        if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;

        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        var self = KqueueMmapIO{
            .kq = kq,
            .cfg = cfg,
            .allocator = allocator,
        };

        try self.pending_changes.ensureTotalCapacity(allocator, cfg.pending_capacity);
        errdefer self.pending_changes.deinit(allocator);
        try self.completed.ensureTotalCapacity(allocator, cfg.pending_capacity);
        errdefer self.completed.deinit(allocator);
        try self.timers.ensureTotalCapacity(allocator, cfg.timer_capacity);
        errdefer self.timers.deinit(allocator);
        try self.file_mappings.ensureTotalCapacity(allocator, cfg.file_mapping_capacity);

        return self;
    }

    pub fn deinit(self: *KqueueMmapIO) void {
        // Unmap before closing the kqueue fd. Callers are responsible
        // for closing the underlying file fds (the contract has no
        // close-file hook); our mappings outlive the fds in the worst
        // case, but munmap on a now-closed fd is still well-defined.
        if (comptime is_kqueue_platform) {
            var it = self.file_mappings.valueIterator();
            while (it.next()) |m| {
                posix.munmap(m.base[0..m.len]);
            }
        }
        self.file_mappings.deinit(self.allocator);

        if (comptime is_kqueue_platform) {
            if (self.kq >= 0) posix.close(self.kq);
        }
        self.pending_changes.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn closeSocket(_: *KqueueMmapIO, fd: posix.fd_t) void {
        posix.close(fd);
    }

    pub fn tick(self: *KqueueMmapIO, wait_at_least: u32) !void {
        if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;

        const now = monotonicNs();
        try self.expireTimers(now);
        self.drainCompleted();

        var change_buf: [256]posix.Kevent = undefined;
        const change_cap = @min(change_buf.len, self.cfg.change_batch);
        const changes_to_submit = @min(self.pending_changes.items.len, change_cap);
        for (self.pending_changes.items[0..changes_to_submit], 0..) |pc, i| {
            change_buf[i] = makeKevent(pc.ident, pc.filter, @intFromPtr(pc.completion));
        }

        var ts_storage: posix.timespec = undefined;
        const timeout_ptr: ?*const posix.timespec = blk: {
            if (wait_at_least == 0) {
                ts_storage = .{ .sec = 0, .nsec = 0 };
                break :blk &ts_storage;
            }
            if (self.peekNextDeadline()) |deadline_ns| {
                const wait_ns = if (deadline_ns > monotonicNs()) deadline_ns - monotonicNs() else 0;
                ts_storage = .{
                    .sec = @intCast(wait_ns / std.time.ns_per_s),
                    .nsec = @intCast(wait_ns % std.time.ns_per_s),
                };
                break :blk &ts_storage;
            }
            break :blk null;
        };

        var event_buf: [256]posix.Kevent = undefined;
        const got = try posix.kevent(
            self.kq,
            change_buf[0..changes_to_submit],
            &event_buf,
            timeout_ptr,
        );

        if (changes_to_submit > 0) {
            const remaining = self.pending_changes.items.len - changes_to_submit;
            for (0..remaining) |i| {
                self.pending_changes.items[i] = self.pending_changes.items[i + changes_to_submit];
            }
            self.pending_changes.shrinkRetainingCapacity(remaining);
        }

        try self.expireTimers(monotonicNs());

        for (event_buf[0..got]) |ev| {
            const c: *Completion = @ptrFromInt(ev.udata);
            const st = kqueueState(c);
            st.parked_filter = 0;
            if (st.cancelled) {
                self.pushCompleted(c, makeCancelledResult(c.op));
                continue;
            }
            try self.retrySyscall(c, ev);
        }

        self.drainCompleted();
    }

    // ── Internal: completed queue + dispatch ───────────────

    fn drainCompleted(self: *KqueueMmapIO) void {
        while (self.completed.items.len > 0) {
            const entry = self.completed.orderedRemove(0);
            self.dispatch(entry);
        }
    }

    fn pushCompleted(self: *KqueueMmapIO, c: *Completion, result: Result) void {
        self.completed.appendAssumeCapacity(.{ .completion = c, .result = result });
    }

    fn dispatch(self: *KqueueMmapIO, entry: CompletedEntry) void {
        const c = entry.completion;
        const callback = c.callback orelse return;
        kqueueState(c).in_flight = false;
        const action = callback(c.userdata, c, entry.result);
        switch (action) {
            .disarm => {},
            .rearm => {
                self.resubmit(c) catch {};
            },
        }
    }

    fn resubmit(self: *KqueueMmapIO, c: *Completion) !void {
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

    fn armCompletion(self: *KqueueMmapIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
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

    fn parkOnFilter(self: *KqueueMmapIO, c: *Completion, fd: posix.fd_t, filter: i16) !void {
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

    fn retrySyscall(self: *KqueueMmapIO, c: *Completion, ev: posix.Kevent) !void {
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
                self.tryRecv(op, c) catch {};
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
                if (errno_payload != 0) {
                    self.pushCompleted(c, .{ .connect = errnoFromCInt(errno_payload) });
                    return;
                }
                if (got_eof) {
                    self.pushCompleted(c, .{ .connect = error.ConnectionRefused });
                    return;
                }
                const so_err = posix.getsockoptError(op.fd) catch |err| {
                    self.pushCompleted(c, .{ .connect = err });
                    return;
                };
                _ = so_err;
                self.pushCompleted(c, .{ .connect = {} });
            },
            .poll => |op| {
                var revents: u32 = 0;
                if (opFilterIsRead(op)) revents |= posix.POLL.IN;
                if (opFilterIsWrite(op)) revents |= posix.POLL.OUT;
                if (got_eof) revents |= posix.POLL.HUP;
                if (errno_payload != 0) revents |= posix.POLL.ERR;
                self.pushCompleted(c, .{ .poll = revents });
            },
            else => {
                self.pushCompleted(c, makeCancelledResult(c.op));
            },
        }
    }

    // ── Timer heap ────────────────────────────────────────

    fn peekNextDeadline(self: *KqueueMmapIO) ?u64 {
        if (self.timers.items.len == 0) return null;
        return self.timers.items[0].deadline_ns;
    }

    fn expireTimers(self: *KqueueMmapIO, now_ns: u64) !void {
        while (self.timers.items.len > 0 and self.timers.items[0].deadline_ns <= now_ns) {
            const entry = self.popMinTimer();
            const c = entry.completion;
            kqueueState(c).timer_index = sentinel_index;
            switch (c.op) {
                .timeout => self.pushCompleted(c, .{ .timeout = {} }),
                .connect => {
                    kqueueState(c).cancelled = true;
                    self.pushCompleted(c, .{ .connect = error.ConnectionTimedOut });
                },
                else => {
                    self.pushCompleted(c, makeCancelledResult(c.op));
                },
            }
        }
    }

    fn pushTimer(self: *KqueueMmapIO, deadline_ns: u64, c: *Completion) !void {
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
        while (idx > 0) {
            const parent = (idx - 1) / 2;
            if (timerLess(self.timers.items[idx], self.timers.items[parent])) {
                self.swapTimers(idx, parent);
                idx = parent;
            } else break;
        }
    }

    fn popMinTimer(self: *KqueueMmapIO) TimerEntry {
        const entry = self.timers.items[0];
        const last = self.timers.pop().?;
        if (self.timers.items.len > 0) {
            self.timers.items[0] = last;
            kqueueState(last.completion).timer_index = 0;
            self.siftDown(0);
        }
        return entry;
    }

    fn removeTimerAt(self: *KqueueMmapIO, idx: u32) void {
        const last = self.timers.pop().?;
        if (idx == self.timers.items.len) return;
        self.timers.items[idx] = last;
        kqueueState(last.completion).timer_index = idx;
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

    fn siftDown(self: *KqueueMmapIO, start_idx: u32) void {
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

    fn swapTimers(self: *KqueueMmapIO, a: u32, b: u32) void {
        const tmp = self.timers.items[a];
        self.timers.items[a] = self.timers.items[b];
        self.timers.items[b] = tmp;
        kqueueState(self.timers.items[a].completion).timer_index = a;
        kqueueState(self.timers.items[b].completion).timer_index = b;
    }

    // ── File-mapping helpers ──────────────────────────────

    /// Look up an existing mapping; if absent, fstat the fd and `mmap`
    /// the entire file. Returns the live mapping. Callers bounds-check
    /// against `len` themselves.
    ///
    /// Errors propagate through the caller's `Result.read|write|fsync`
    /// variant. We do not park on kqueue for files — readiness is
    /// undefined for regular files on darwin (always reports ready;
    /// the syscall blocks), so the synchronous path is the right one.
    fn getOrMap(self: *KqueueMmapIO, fd: posix.fd_t) !FileMapping {
        if (comptime !is_kqueue_platform) return error.UnsupportedPlatform;
        if (self.file_mappings.get(fd)) |existing| return existing;

        const stat = try posix.fstat(fd);
        const file_len: usize = @intCast(stat.size);
        // mmap rejects length=0; deliver an empty mapping that
        // bounds-checks correctly for read(off=0, len=0) but
        // short-reads anything else.
        if (file_len == 0) {
            const empty = FileMapping{
                .base = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(std.heap.page_size_min)),
                .len = 0,
            };
            // Don't insert empty mappings into the table — they'll be
            // remapped at non-zero size by the next access after a
            // truncate or fallocate.
            return empty;
        }

        const mapped = try posix.mmap(
            null,
            file_len,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (self.cfg.advise_willneed) {
            // Best-effort hint — Darwin honors WILLNEED as a readahead
            // pump; failure is non-fatal.
            posix.madvise(mapped.ptr, mapped.len, posix.MADV.WILLNEED) catch {};
        }

        const entry = FileMapping{ .base = mapped.ptr, .len = mapped.len };
        // Pre-allocated capacity in init; this should never fail.
        try self.file_mappings.put(self.allocator, fd, entry);
        return entry;
    }

    /// Drop a mapping for `fd`, if any. Used before truncate so the
    /// next access remaps at the new size. Callers responsible for
    /// triggering this themselves — the contract has no "fd resized
    /// outside the contract" hook.
    fn unmapFile(self: *KqueueMmapIO, fd: posix.fd_t) void {
        if (comptime !is_kqueue_platform) return;
        const entry = self.file_mappings.fetchRemove(fd) orelse return;
        if (entry.value.len > 0) posix.munmap(entry.value.base[0..entry.value.len]);
    }

    // ── Submission methods: socket / timer / cancel (mirrors POSIX) ───

    pub fn timeout(self: *KqueueMmapIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        const deadline = monotonicNs() +| op.ns;
        try self.pushTimer(deadline, c);
    }

    pub fn socket(self: *KqueueMmapIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .socket = op }, ud, cb);
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

    pub fn connect(self: *KqueueMmapIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);

        const addrlen = op.addr.getOsSockLen();
        const rc = posix.connect(op.fd, &op.addr.any, addrlen);
        if (rc) |_| {
            self.pushCompleted(c, .{ .connect = {} });
            return;
        } else |err| switch (err) {
            error.WouldBlock => {
                try self.parkOnFilter(c, op.fd, std.c.EVFILT.WRITE);
                if (op.deadline_ns) |ns| {
                    const deadline = monotonicNs() +| ns;
                    try self.pushTimer(deadline, c);
                }
            },
            else => self.pushCompleted(c, .{ .connect = err }),
        }
    }

    pub fn accept(self: *KqueueMmapIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        kqueueState(c).multishot = op.multishot;
        try self.tryAccept(op, c);
    }

    fn tryAccept(self: *KqueueMmapIO, op: ifc.AcceptOp, c: *Completion) !void {
        var addr: posix.sockaddr.storage = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const accepted = posix.accept(op.fd, @ptrCast(&addr), &addrlen, 0);
        if (accepted) |fd| {
            setNonblockCloexec(fd) catch |err| {
                posix.close(fd);
                self.pushCompleted(c, .{ .accept = err });
                return;
            };
            const accepted_addr = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(@alignCast(&addr))).* };
            self.pushCompleted(c, .{ .accept = .{ .fd = fd, .addr = accepted_addr } });
            if (op.multishot) try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ);
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ),
            else => self.pushCompleted(c, .{ .accept = err }),
        }
    }

    pub fn recv(self: *KqueueMmapIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op }, ud, cb);
        try self.tryRecv(op, c);
    }

    fn tryRecv(self: *KqueueMmapIO, op: ifc.RecvOp, c: *Completion) !void {
        const r = posix.recv(op.fd, op.buf, op.flags);
        if (r) |n| {
            self.pushCompleted(c, .{ .recv = n });
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.READ),
            else => self.pushCompleted(c, .{ .recv = err }),
        }
    }

    pub fn send(self: *KqueueMmapIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op }, ud, cb);
        try self.trySend(op, c);
    }

    fn trySend(self: *KqueueMmapIO, op: ifc.SendOp, c: *Completion) !void {
        const r = posix.send(op.fd, op.buf, op.flags);
        if (r) |n| {
            self.pushCompleted(c, .{ .send = n });
        } else |err| switch (err) {
            error.WouldBlock => try self.parkOnFilter(c, op.fd, std.c.EVFILT.WRITE),
            else => self.pushCompleted(c, .{ .send = err }),
        }
    }

    pub fn recvmsg(self: *KqueueMmapIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op }, ud, cb);
        try self.tryRecvmsg(op, c);
    }

    fn tryRecvmsg(self: *KqueueMmapIO, op: ifc.RecvmsgOp, c: *Completion) !void {
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

    pub fn sendmsg(self: *KqueueMmapIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op }, ud, cb);
        try self.trySendmsg(op, c);
    }

    fn trySendmsg(self: *KqueueMmapIO, op: ifc.SendmsgOp, c: *Completion) !void {
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

    pub fn poll(self: *KqueueMmapIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        const wants_in = (op.events & posix.POLL.IN) != 0;
        const wants_out = (op.events & posix.POLL.OUT) != 0;
        if (!wants_in and !wants_out) {
            self.pushCompleted(c, .{ .poll = error.InvalidArgument });
            return;
        }
        const filter: i16 = if (wants_in) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
        try self.parkOnFilter(c, op.fd, filter);
    }

    pub fn cancel(self: *KqueueMmapIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);
        const target = op.target;
        const tst = kqueueState(target);

        var found = false;
        if (tst.timer_index != sentinel_index) {
            self.removeTimerAt(tst.timer_index);
            tst.timer_index = sentinel_index;
            self.pushCompleted(target, makeCancelledResult(target.op));
            found = true;
        } else if (tst.parked_filter != 0) {
            tst.cancelled = true;
            self.pushCompleted(target, makeCancelledResult(target.op));
            found = true;
        }

        const result: anyerror!void = if (found) {} else error.OperationNotFound;
        self.pushCompleted(c, .{ .cancel = result });
    }

    // ── File ops (mmap-based) ─────────────────────────────

    pub fn read(self: *KqueueMmapIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        const r: Result = blk: {
            if (comptime !is_kqueue_platform) break :blk .{ .read = error.UnsupportedPlatform };
            const mapping = self.getOrMap(op.fd) catch |err| break :blk .{ .read = err };
            // Bounds-check against the mapped length. Reads past EOF
            // short-read; reads entirely past EOF return 0 bytes (matches
            // pread semantics).
            const off: usize = @intCast(op.offset);
            if (off >= mapping.len) break :blk .{ .read = @as(usize, 0) };
            const available = mapping.len - off;
            const n = @min(op.buf.len, available);
            @memcpy(op.buf[0..n], mapping.base[off .. off + n]);
            break :blk .{ .read = n };
        };
        self.pushCompleted(c, r);
    }

    pub fn write(self: *KqueueMmapIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const r: Result = blk: {
            if (comptime !is_kqueue_platform) break :blk .{ .write = error.UnsupportedPlatform };
            const mapping = self.getOrMap(op.fd) catch |err| break :blk .{ .write = err };
            const off: usize = @intCast(op.offset);
            // Writes past mapped EOF are not supported in this MVP.
            // Callers should size the file via fallocate / truncate
            // first (PieceStore.init does this).
            if (off >= mapping.len) break :blk .{ .write = error.NoSpaceLeft };
            const available = mapping.len - off;
            const n = @min(op.buf.len, available);
            @memcpy(mapping.base[off .. off + n], op.buf[0..n]);
            break :blk .{ .write = n };
        };
        self.pushCompleted(c, r);
    }

    pub fn fsync(self: *KqueueMmapIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        const r: Result = blk: {
            if (comptime !is_kqueue_platform) break :blk .{ .fsync = error.UnsupportedPlatform };
            // Darwin's msync flushes the dirty pages in the mapping to
            // disk. There is no datasync vs full-sync distinction at
            // the msync layer — both `op.datasync = true` and `false`
            // map to MSF.SYNC. For true durability the call would be
            // `fcntl(F_FULLFSYNC)`; out of scope for the dev backend.
            const entry = self.file_mappings.get(op.fd) orelse {
                // No mapping → nothing buffered through us → no-op success.
                // (PieceStore.init may fsync before any read/write —
                // that's a legitimate "ensure metadata is on disk" call.
                // Issue a plain `fsync(2)` for that case via std.c.)
                const rc = std.c.fsync(op.fd);
                if (rc == 0) break :blk .{ .fsync = {} };
                break :blk .{ .fsync = posix.unexpectedErrno(posix.errno(rc)) };
            };
            if (entry.len == 0) break :blk .{ .fsync = {} };
            posix.msync(entry.base[0..entry.len], posix.MSF.SYNC) catch |err| {
                break :blk .{ .fsync = err };
            };
            break :blk .{ .fsync = {} };
        };
        self.pushCompleted(c, r);
    }

    pub fn fallocate(self: *KqueueMmapIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        const r: Result = blk: {
            if (comptime !is_kqueue_platform) break :blk .{ .fallocate = error.UnsupportedPlatform };
            // Darwin has no Linux-style fallocate. Emulate with
            // F_PREALLOCATE + ftruncate. Pattern from
            // tigerbeetle/src/io/darwin.zig:fs_allocate.
            //
            // The contract's `op.offset + op.len` is the desired file
            // size; we attempt contiguous allocation first, fall back
            // to non-contiguous, then ftruncate to set the actual size.
            const target_size: posix.off_t = @intCast(op.offset + op.len);
            var store = fstore_t{
                .fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL,
                .fst_posmode = F_PEOFPOSMODE,
                .fst_offset = 0,
                .fst_length = target_size,
                .fst_bytesalloc = 0,
            };
            var rc = posix.system.fcntl(op.fd, posix.F.PREALLOCATE, @intFromPtr(&store));
            if (posix.errno(rc) != .SUCCESS) {
                // Retry without contiguous constraint.
                store.fst_flags = F_ALLOCATEALL;
                rc = posix.system.fcntl(op.fd, posix.F.PREALLOCATE, @intFromPtr(&store));
            }
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                // Darwin spells the "not supported" errno EOPNOTSUPP;
                // there's no separate ENOTSUP on this platform.
                .OPNOTSUPP => break :blk .{ .fallocate = error.OperationNotSupported },
                .BADF => break :blk .{ .fallocate = error.BadFileDescriptor },
                .INVAL => break :blk .{ .fallocate = error.InvalidArgument },
                .OVERFLOW => break :blk .{ .fallocate = error.FileTooBig },
                else => |e| break :blk .{ .fallocate = posix.unexpectedErrno(e) },
            }
            // Drop any mapping; the next access remaps at the new size.
            self.unmapFile(op.fd);
            posix.ftruncate(op.fd, op.offset + op.len) catch |err| {
                break :blk .{ .fallocate = err };
            };
            break :blk .{ .fallocate = {} };
        };
        self.pushCompleted(c, r);
    }

    pub fn truncate(self: *KqueueMmapIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        // Darwin lacks `mremap`; the only safe path is to drop the
        // mapping before the file is resized and let the next access
        // remap at the new size.
        self.unmapFile(op.fd);
        const r: Result = if (posix.ftruncate(op.fd, op.length)) |_|
            .{ .truncate = {} }
        else |err|
            .{ .truncate = err };
        self.pushCompleted(c, r);
    }

    /// `splice(2)` is Linux-only. Always returns `error.OperationNotSupported`
    /// on macOS/BSD; callers fall back to `copy_file_range` (which we
    /// emulate with read+write below) or to a plain read/write loop.
    pub fn splice(self: *KqueueMmapIO, op: ifc.SpliceOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = op;
        try self.armCompletion(c, .{ .splice = .{ .in_fd = -1, .in_offset = 0, .out_fd = -1, .out_offset = 0, .len = 0 } }, ud, cb);
        self.pushCompleted(c, .{ .splice = error.OperationNotSupported });
    }

    /// Emulate `copy_file_range` on Darwin via a positioned read+write
    /// pair (the daemon's MoveJob caller chunks larger transfers, so a
    /// single bounded transfer is sufficient).
    pub fn copy_file_range(self: *KqueueMmapIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_range = op }, ud, cb);
        const result: Result = blk: {
            var stack_buf: [128 * 1024]u8 = undefined;
            const want = @min(op.len, stack_buf.len);
            const n_read = posix.pread(op.in_fd, stack_buf[0..want], op.in_offset) catch |err| break :blk .{ .copy_file_range = err };
            if (n_read == 0) break :blk .{ .copy_file_range = @as(usize, 0) };
            var written: usize = 0;
            while (written < n_read) {
                const w = posix.pwrite(op.out_fd, stack_buf[written..n_read], op.out_offset + written) catch |err| break :blk .{ .copy_file_range = err };
                if (w == 0) break :blk .{ .copy_file_range = error.WriteShort };
                written += w;
            }
            break :blk .{ .copy_file_range = n_read };
        };
        self.pushCompleted(c, result);
    }
};

// ── Helpers ───────────────────────────────────────────────

/// Monotonic ns reader for the kqueue+mmap backend's own scheduling.
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

fn opFilterIsRead(op: ifc.PollOp) bool {
    return (op.events & std.posix.POLL.IN) != 0;
}
fn opFilterIsWrite(op: ifc.PollOp) bool {
    return (op.events & std.posix.POLL.OUT) != 0;
}

// ── Tests (mock-based; comptime-skip platform-specific ones) ─

const testing = std.testing;

test "KqueueMmapIO: state size and alignment fit the contract budget" {
    try testing.expect(@sizeOf(KqueueState) <= ifc.backend_state_size);
    try testing.expect(@alignOf(KqueueState) <= ifc.backend_state_align);
}

test "KqueueMmapIO: timer heap orders by deadline then sequence" {
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

test "KqueueMmapIO: makeCancelledResult preserves op tag" {
    const tags = .{
        .{ Operation{ .recv = .{ .fd = 0, .buf = &[_]u8{} } }, "recv" },
        .{ Operation{ .send = .{ .fd = 0, .buf = &[_]u8{} } }, "send" },
        .{ Operation{ .timeout = .{ .ns = 0 } }, "timeout" },
        .{ Operation{ .read = .{ .fd = 0, .buf = &[_]u8{}, .offset = 0 } }, "read" },
        .{ Operation{ .write = .{ .fd = 0, .buf = &[_]u8{}, .offset = 0 } }, "write" },
        .{ Operation{ .fsync = .{ .fd = 0 } }, "fsync" },
    };
    inline for (tags) |t| {
        const r = makeCancelledResult(t[0]);
        const got_tag: Result = r;
        switch (got_tag) {
            inline else => |_, tag| try testing.expect(std.mem.eql(u8, @tagName(tag), t[1])),
        }
    }
}

test "KqueueMmapIO: errnoFromCInt maps common errnos" {
    try testing.expectEqual(error.ConnectionRefused, errnoFromCInt(@intFromEnum(posix.E.CONNREFUSED)));
    try testing.expectEqual(error.WouldBlock, errnoFromCInt(@intFromEnum(posix.E.AGAIN)));
    try testing.expectEqual(error.Unexpected, errnoFromCInt(99999));
}

test "KqueueMmapIO: fstore_t layout matches Darwin's struct" {
    // Tigerbeetle's reference declaration uses these exact field types
    // and order. A drift here would silently mis-encode the F_PREALLOCATE
    // request and produce inscrutable EINVALs on macOS.
    //
    // Darwin's struct is 32 bytes total: 4-byte fst_flags, 4-byte
    // fst_posmode, then three 8-byte off_t fields. The struct align is
    // 8 (the off_t alignment dominates).
    try testing.expectEqual(@as(usize, 4 + 4 + 8 + 8 + 8), @sizeOf(fstore_t));
    try testing.expectEqual(@as(usize, @alignOf(posix.off_t)), @alignOf(fstore_t));
}

test "KqueueMmapIO: init succeeds and deinit closes kq (skipped on non-kqueue platforms)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueueMmapIO.init(testing.allocator, .{});
    defer io.deinit();
    try testing.expect(io.kq >= 0);
}

test "KqueueMmapIO: timeout fires after the deadline (real syscall path; skipped on non-kqueue)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueueMmapIO.init(testing.allocator, .{});
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

test "KqueueMmapIO: mmap-backed read/write round-trip (real fs; skipped on non-kqueue)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;

    // Create a temp file, size it via fallocate, write a pattern,
    // fsync, read it back. Exercises every file-op method.
    const tmp_dir = testing.tmpDir(.{});
    var tmp = tmp_dir;
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("kqueue_mmap_io.bin", .{ .read = true });
    defer file.close();

    var io = try KqueueMmapIO.init(testing.allocator, .{});
    defer io.deinit();

    const Ctx = struct {
        last: ?Result = null,
        fired: bool = false,
    };
    const cb_factory = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const c: *Ctx = @ptrCast(@alignCast(ud.?));
            c.last = result;
            c.fired = true;
            return .disarm;
        }
    };

    // 1. fallocate to 4096 bytes.
    var ctx_alloc = Ctx{};
    var c_alloc = Completion{};
    try io.fallocate(.{ .fd = file.handle, .offset = 0, .len = 4096 }, &c_alloc, &ctx_alloc, cb_factory.cb);
    while (!ctx_alloc.fired) try io.tick(1);
    switch (ctx_alloc.last.?) {
        .fallocate => |r| try r,
        else => try testing.expect(false),
    }

    // 2. write a pattern at offset 100.
    const pattern = "hello mmap world";
    var ctx_w = Ctx{};
    var c_w = Completion{};
    try io.write(.{ .fd = file.handle, .buf = pattern, .offset = 100 }, &c_w, &ctx_w, cb_factory.cb);
    while (!ctx_w.fired) try io.tick(1);
    switch (ctx_w.last.?) {
        .write => |r| try testing.expectEqual(@as(usize, pattern.len), try r),
        else => try testing.expect(false),
    }

    // 3. fsync.
    var ctx_f = Ctx{};
    var c_f = Completion{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &c_f, &ctx_f, cb_factory.cb);
    while (!ctx_f.fired) try io.tick(1);
    switch (ctx_f.last.?) {
        .fsync => |r| try r,
        else => try testing.expect(false),
    }

    // 4. read it back.
    var read_buf: [pattern.len]u8 = undefined;
    var ctx_r = Ctx{};
    var c_r = Completion{};
    try io.read(.{ .fd = file.handle, .buf = &read_buf, .offset = 100 }, &c_r, &ctx_r, cb_factory.cb);
    while (!ctx_r.fired) try io.tick(1);
    switch (ctx_r.last.?) {
        .read => |r| try testing.expectEqual(@as(usize, pattern.len), try r),
        else => try testing.expect(false),
    }
    try testing.expectEqualStrings(pattern, &read_buf);
}

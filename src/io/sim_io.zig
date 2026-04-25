//! SimIO — in-process IO backend for simulation tests.
//!
//! `SimIO` implements the same interface as `RealIO` but never touches the
//! kernel. Submissions land in an internal min-heap keyed by simulated
//! delivery time. A test driver (the `Simulator`) advances a logical clock
//! and calls `tick`, which delivers all due completions by invoking their
//! callbacks.
//!
//! In addition to the heap, `SimIO` owns a fixed pool of `SimSocket` slots.
//! `createSocketpair` allocates two slots and links them as partners; bytes
//! written to one side land in the partner's recv ring buffer. A `recv`
//! against an empty buffer is **parked** on the socket — it leaves the heap
//! and is moved back when the partner sends. This is enough machinery to
//! drive a real BitTorrent peer state machine end-to-end inside one
//! single-threaded simulation.
//!
//! Properties:
//!   * **Deterministic.** All fault decisions and ordering tiebreakers
//!     derive from a seeded `std.Random.DefaultPrng`.
//!   * **Zero-alloc on the data path.** The heap, socket pool, and per-
//!     socket recv buffers are sized at `init` with fixed capacities.
//!     Submissions past `pending_capacity` fail with
//!     `error.PendingQueueFull`; sockets past `socket_capacity` fail with
//!     `error.SocketCapacityExhausted`.
//!   * **No threads, no fds, no syscalls.** Submissions run on the test
//!     thread; delivery happens during `tick` on the same thread.
//!
//! See `docs/io-abstraction-plan.md` for the broader design.

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

// ── Public re-exports for backend duck-typing ─────────────

pub const Op = ifc.Operation;

// ── Backend state ─────────────────────────────────────────
//
// SimIO stores per-completion bookkeeping in `Completion._backend_state`.
// It records the heap index so cancel can find the entry without a linear
// scan, the socket slot the completion is parked on (if any), and an
// `in_flight` flag.

pub const SimState = struct {
    /// Index into `pending` while in the heap; `sentinel_index` means
    /// "not in the heap" (delivered, never submitted, or parked on a
    /// socket — see `parked_socket_index`).
    heap_index: u32 = sentinel_index,
    /// Slot index into `sockets` while parked on a socket waiting for
    /// data; `sentinel_index` means "not parked".
    parked_socket_index: u32 = sentinel_index,
    in_flight: bool = false,
};

comptime {
    // The opaque area in the public Completion must accommodate SimState.
    assert(@sizeOf(SimState) <= ifc.backend_state_size);
    assert(@alignOf(SimState) <= ifc.backend_state_align);
}

inline fn simState(c: *Completion) *SimState {
    return c.backendStateAs(SimState);
}

/// Sentinel for `heap_index` and `parked_socket_index` ("not present").
const sentinel_index: u32 = std.math.maxInt(u32);

// ── Fault injection configuration ─────────────────────────

pub const FaultConfig = struct {
    /// Probability that a given recv completion is delivered with
    /// `error.ConnectionResetByPeer` instead of bytes.
    recv_error_probability: f32 = 0.0,
    /// Same idea for send.
    send_error_probability: f32 = 0.0,
    /// Probability for read (disk EIO).
    read_error_probability: f32 = 0.0,
    /// Probability for write (disk EIO / ENOSPC).
    write_error_probability: f32 = 0.0,
    /// Probability that a connect completes with `error.ConnectionRefused`.
    connect_error_probability: f32 = 0.0,
    /// Added to every recv delivery time (simulates network latency).
    recv_latency_ns: u64 = 0,
    /// Added to every send delivery time.
    send_latency_ns: u64 = 0,
    /// Added to every disk write delivery time (simulates slow disk).
    write_latency_ns: u64 = 0,
    /// Random jitter added to each completion's deadline. 0 disables.
    completion_jitter_ns: u64 = 0,
};

pub const Config = struct {
    /// Capacity of the pending-completion heap. Submissions past this
    /// capacity fail with `error.PendingQueueFull`.
    pending_capacity: u32 = 4096,
    /// Number of socket slots in the pool. Each `createSocketpair` consumes
    /// two slots. Submissions past this capacity fail with
    /// `error.SocketCapacityExhausted`.
    socket_capacity: u32 = 64,
    /// Per-socket recv-queue ring buffer size in bytes. A `send` writes
    /// into the partner's queue; the partner's `recv` consumes from it.
    /// Sized to comfortably hold a couple of BitTorrent block-sized
    /// payloads (16 KiB blocks) without queueing pressure.
    recv_queue_capacity_bytes: u32 = 64 * 1024,
    /// Seed for the deterministic PRNG. Tests should derive this from a
    /// per-test seed and print it on failure.
    seed: u64 = 0,
    faults: FaultConfig = .{},
};

// ── Pending entry ─────────────────────────────────────────
//
// A pending entry is a (deadline, sequence, completion, result) tuple in
// the min-heap. `seq` breaks ties between completions sharing a deadline
// — assigning sequence numbers from a seeded PRNG produces a deterministic
// but order-stressing schedule.
//
// `result` is the result to deliver when the entry pops.

const Pending = struct {
    deadline_ns: u64,
    seq: u64,
    completion: *Completion,
    result: Result,
};

fn pendingLess(_: void, a: Pending, b: Pending) std.math.Order {
    if (a.deadline_ns != b.deadline_ns) return std.math.order(a.deadline_ns, b.deadline_ns);
    return std.math.order(a.seq, b.seq);
}

// ── Recv ring buffer ──────────────────────────────────────

const RecvQueue = struct {
    buf: []u8 = &.{},
    head: u32 = 0,
    tail: u32 = 0,
    count: u32 = 0,

    fn append(self: *RecvQueue, data: []const u8) usize {
        const cap: usize = self.buf.len;
        assert(self.count <= cap);
        const space: usize = cap - self.count;
        const n: usize = @min(space, data.len);
        var copied: usize = 0;
        while (copied < n) {
            const remaining = n - copied;
            const tail_to_end = cap - self.tail;
            const chunk = @min(remaining, tail_to_end);
            assert(chunk > 0);
            @memcpy(self.buf[self.tail..][0..chunk], data[copied..][0..chunk]);
            copied += chunk;
            self.tail = @intCast((@as(usize, self.tail) + chunk) % cap);
        }
        self.count += @intCast(n);
        assert(self.count <= cap);
        return n;
    }

    fn consume(self: *RecvQueue, dst: []u8) usize {
        const cap: usize = self.buf.len;
        assert(self.count <= cap);
        const n: usize = @min(self.count, dst.len);
        var copied: usize = 0;
        while (copied < n) {
            const remaining = n - copied;
            const head_to_end = cap - self.head;
            const chunk = @min(remaining, head_to_end);
            assert(chunk > 0);
            @memcpy(dst[copied..][0..chunk], self.buf[self.head..][0..chunk]);
            copied += chunk;
            self.head = @intCast((@as(usize, self.head) + chunk) % cap);
        }
        self.count -= @intCast(n);
        return n;
    }

    fn reset(self: *RecvQueue) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }
};

// ── Sim socket slot ───────────────────────────────────────

pub const SimSocket = struct {
    in_use: bool = false,
    closed: bool = false,
    /// Slot index of the partner; `sentinel_index` when not paired.
    partner_index: u32 = sentinel_index,
    /// Free-list link when the slot is in the free pool. `sentinel_index`
    /// while the slot is in use.
    next_free: u32 = sentinel_index,
    /// At most one parked recv per socket. The parked completion is
    /// `in_flight` but is not in the heap.
    parked_recv: ?*Completion = null,
    recv_queue: RecvQueue = .{},
};

// ── Constants ─────────────────────────────────────────────

/// Base value for fake socket fds. Chosen large enough that it never
/// collides with stdin/stdout/stderr or typical kernel-issued fds the
/// test process might hold open at the same time.
const socket_fd_base: i32 = 1000;

/// Base value for synthetic fds returned by the `socket` op (when the
/// caller wants an fd-like value but doesn't care about routing data
/// through it). Far above the `[socket_fd_base, socket_fd_base + cap)`
/// range so legacy callers never collide with sim-socket fds.
const synthetic_fd_base: i32 = 100_000;

// ── SimIO ─────────────────────────────────────────────────

pub const SimIO = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    config: Config,

    /// Wall-time-in-nanoseconds of the simulated clock. The driver
    /// (`Simulator.step`) advances this; `tick` delivers everything due.
    now_ns: u64 = 0,

    /// Strictly-increasing submission counter. Combined with the PRNG it
    /// becomes the heap tiebreaker.
    submit_seq: u64 = 0,

    /// Min-heap of pending completions keyed by deadline_ns then seq.
    /// Backed by a single allocation made at init.
    pending: []Pending,
    pending_len: u32 = 0,

    /// Re-entrancy guard for `tick`. Callbacks may submit new operations,
    /// but they may not call `tick` recursively.
    in_tick: bool = false,

    /// Pool of socket slots. Allocated at init; never reclaimed mid-life.
    sockets: []SimSocket,
    /// Backing memory for all per-socket recv ring buffers; freed in
    /// deinit. Sized as `socket_capacity * recv_queue_capacity_bytes`.
    recv_queue_pool: []u8,
    /// Head of the free-list of unallocated socket slots.
    free_socket_head: u32 = sentinel_index,

    pub fn init(allocator: std.mem.Allocator, config: Config) !SimIO {
        const slots = try allocator.alloc(Pending, config.pending_capacity);
        errdefer allocator.free(slots);

        const sockets = try allocator.alloc(SimSocket, config.socket_capacity);
        errdefer allocator.free(sockets);

        const queue_total: usize = @as(usize, config.socket_capacity) * config.recv_queue_capacity_bytes;
        const queue_buf = try allocator.alloc(u8, queue_total);
        errdefer allocator.free(queue_buf);

        // Build the free list by linking slot i → slot i-1 → ...; the
        // head is the highest index so allocations come out in descending
        // order. The order doesn't matter for correctness.
        var i: u32 = 0;
        var head: u32 = sentinel_index;
        while (i < config.socket_capacity) : (i += 1) {
            const offset: usize = @as(usize, i) * config.recv_queue_capacity_bytes;
            sockets[i] = .{
                .in_use = false,
                .closed = false,
                .partner_index = sentinel_index,
                .next_free = head,
                .parked_recv = null,
                .recv_queue = .{
                    .buf = queue_buf[offset..][0..config.recv_queue_capacity_bytes],
                },
            };
            head = i;
        }

        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(config.seed),
            .config = config,
            .pending = slots,
            .sockets = sockets,
            .recv_queue_pool = queue_buf,
            .free_socket_head = head,
        };
    }

    pub fn deinit(self: *SimIO) void {
        self.allocator.free(self.pending);
        self.allocator.free(self.recv_queue_pool);
        self.allocator.free(self.sockets);
        self.* = undefined;
    }

    /// Current simulated time.
    pub fn now(self: *const SimIO) u64 {
        return self.now_ns;
    }

    /// Advance the simulated clock and deliver all due completions.
    /// Equivalent to `now_ns += delta_ns; try self.tick()`.
    pub fn advance(self: *SimIO, delta_ns: u64) !void {
        self.now_ns += delta_ns;
        try self.tick();
    }

    /// Deliver every completion with `deadline_ns <= now_ns`. Callbacks
    /// may submit new operations during delivery — including a fresh op
    /// on the same completion. If a callback returns `.rearm`, the
    /// operation is re-submitted via the public path (so socket / heap
    /// routing is recomputed each time).
    ///
    /// Contract: state is cleared to "not in flight" before the callback
    /// runs, so a callback that submits a new op on the same completion
    /// (e.g. recv into a different buffer slice after the previous chunk
    /// was processed) sees a clean `in_flight=false`. Callbacks must not
    /// both submit a new op AND return `.rearm` — that would double-arm.
    pub fn tick(self: *SimIO) !void {
        assert(!self.in_tick); // no recursive ticks
        self.in_tick = true;
        defer self.in_tick = false;

        while (self.pending_len > 0 and self.pending[0].deadline_ns <= self.now_ns) {
            const entry = self.popMin();
            const c = entry.completion;
            const callback = c.callback orelse continue; // disarmed mid-flight

            // Mark the completion no-longer-in-flight before the callback
            // runs. popMin already cleared heap_index; a parked completion
            // would never reach the heap. So clearing in_flight here means
            // the callback can submit a new op on the same completion via
            // the public API without armCompletion tripping AlreadyInFlight.
            simState(c).in_flight = false;

            const action = callback(c.userdata, c, entry.result);
            switch (action) {
                .disarm => {},
                .rearm => {
                    // Reset state fully (callback may have left fields
                    // dirty from an earlier op) and resubmit through the
                    // public path.
                    simState(c).* = .{};
                    try self.resubmit(c);
                },
            }
        }
    }

    /// Resubmit a completion through the appropriate public method.
    /// Used by the rearm path; callers shouldn't invoke directly.
    fn resubmit(self: *SimIO, c: *Completion) !void {
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
            .socket => |op| try self.socket(op, c, ud, cb),
            .connect => |op| try self.connect(op, c, ud, cb),
            .accept => |op| try self.accept(op, c, ud, cb),
            .timeout => |op| try self.timeout(op, c, ud, cb),
            .poll => |op| try self.poll(op, c, ud, cb),
            .cancel => |op| try self.cancel(op, c, ud, cb),
        }
    }

    // ── Heap operations ───────────────────────────────────

    fn popMin(self: *SimIO) Pending {
        assert(self.pending_len > 0);
        const root = self.pending[0];
        simState(root.completion).heap_index = sentinel_index;

        self.pending_len -= 1;
        if (self.pending_len > 0) {
            const moved = self.pending[self.pending_len];
            self.pending[0] = moved;
            simState(moved.completion).heap_index = 0;
            self.siftDown(0);
        }
        return root;
    }

    fn pushPending(self: *SimIO, entry: Pending) !void {
        if (self.pending_len == self.pending.len) return error.PendingQueueFull;
        const i = self.pending_len;
        self.pending[i] = entry;
        simState(entry.completion).heap_index = i;
        self.pending_len += 1;
        self.siftUp(i);
    }

    fn siftUp(self: *SimIO, idx: u32) void {
        var i = idx;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (pendingLess({}, self.pending[i], self.pending[parent]) == .lt) {
                self.swap(i, parent);
                i = parent;
            } else break;
        }
    }

    fn siftDown(self: *SimIO, idx: u32) void {
        var i = idx;
        while (true) {
            const l = 2 * i + 1;
            const r = 2 * i + 2;
            var best = i;
            if (l < self.pending_len and pendingLess({}, self.pending[l], self.pending[best]) == .lt) best = l;
            if (r < self.pending_len and pendingLess({}, self.pending[r], self.pending[best]) == .lt) best = r;
            if (best == i) break;
            self.swap(i, best);
            i = best;
        }
    }

    fn swap(self: *SimIO, a: u32, b: u32) void {
        const tmp = self.pending[a];
        self.pending[a] = self.pending[b];
        self.pending[b] = tmp;
        simState(self.pending[a].completion).heap_index = a;
        simState(self.pending[b].completion).heap_index = b;
    }

    fn removeAt(self: *SimIO, idx: u32) Pending {
        assert(idx < self.pending_len);
        const removed = self.pending[idx];
        simState(removed.completion).heap_index = sentinel_index;

        self.pending_len -= 1;
        if (idx != self.pending_len) {
            const moved = self.pending[self.pending_len];
            self.pending[idx] = moved;
            simState(moved.completion).heap_index = idx;
            // Restore heap order from idx (could need to sift either way).
            self.siftDown(idx);
            self.siftUp(idx);
        }
        return removed;
    }

    // ── Submission helpers ────────────────────────────────

    /// Initialise a completion for a new submission. Refuses to re-arm a
    /// completion that's still in flight.
    fn armCompletion(_: *SimIO, c: *Completion, op: Operation, ud: ?*anyopaque, cb: Callback) !void {
        const st = simState(c);
        if (st.in_flight) return error.AlreadyInFlight;
        st.* = .{};
        st.in_flight = true;
        c.op = op;
        c.userdata = ud;
        c.callback = cb;
        c.next = null;
    }

    /// Push a completion into the heap with a pre-resolved result. The
    /// caller is responsible for arming the completion (in_flight=true)
    /// before calling.
    fn schedule(self: *SimIO, c: *Completion, result: Result, delay_ns: u64) !void {
        const st = simState(c);
        assert(st.in_flight);
        // Either fresh (heap_index=sentinel) or being moved off a socket
        // park (parked_socket_index already cleared by caller).
        assert(st.heap_index == sentinel_index);

        const jitter_ns = self.jitter();
        const deadline = self.now_ns +| delay_ns +| jitter_ns;
        self.submit_seq +%= 1;
        const seq = self.submit_seq ^ self.rng.random().int(u64);
        try self.pushPending(.{
            .deadline_ns = deadline,
            .seq = seq,
            .completion = c,
            .result = result,
        });
    }

    fn jitter(self: *SimIO) u64 {
        const max = self.config.faults.completion_jitter_ns;
        if (max == 0) return 0;
        return self.rng.random().uintLessThan(u64, max);
    }

    /// Synthesise a fake file descriptor for the `socket` op. The returned
    /// values fit in the `posix.fd_t` range and never collide with the
    /// sim-socket fd range issued by `createSocketpair`.
    fn nextSyntheticFd(self: *SimIO) posix.fd_t {
        self.submit_seq +%= 1;
        const offset: i32 = @intCast(@as(u32, @truncate(self.submit_seq)) & 0xffff);
        return @as(posix.fd_t, synthetic_fd_base + offset);
    }

    // ── Socket pool helpers ───────────────────────────────

    fn allocSocketSlot(self: *SimIO) !u32 {
        if (self.free_socket_head == sentinel_index) return error.SocketCapacityExhausted;
        const slot = self.free_socket_head;
        assert(slot < self.sockets.len);
        const sock = &self.sockets[slot];
        assert(!sock.in_use);
        self.free_socket_head = sock.next_free;
        sock.in_use = true;
        sock.closed = false;
        sock.partner_index = sentinel_index;
        sock.next_free = sentinel_index;
        sock.parked_recv = null;
        sock.recv_queue.reset();
        return slot;
    }

    fn releaseSocketSlot(self: *SimIO, slot: u32) void {
        assert(slot < self.sockets.len);
        const sock = &self.sockets[slot];
        sock.in_use = false;
        sock.closed = false;
        sock.partner_index = sentinel_index;
        sock.parked_recv = null;
        sock.recv_queue.reset();
        sock.next_free = self.free_socket_head;
        self.free_socket_head = slot;
    }

    fn fdForSlot(_: *const SimIO, slot: u32) posix.fd_t {
        return @as(posix.fd_t, socket_fd_base + @as(i32, @intCast(slot)));
    }

    fn slotForFd(self: *const SimIO, fd: posix.fd_t) ?u32 {
        if (fd < socket_fd_base) return null;
        const offset: i64 = @as(i64, fd) - @as(i64, socket_fd_base);
        if (offset < 0) return null;
        if (@as(u64, @intCast(offset)) >= self.sockets.len) return null;
        const slot: u32 = @intCast(offset);
        if (!self.sockets[slot].in_use) return null;
        return slot;
    }

    /// Allocate two paired socket slots and return their fake fds. The
    /// fds are linked so a `send` on one delivers to the other's recv
    /// queue. Use `closeSocket` to release a side; slots are not
    /// reclaimed until `deinit`.
    pub fn createSocketpair(self: *SimIO) ![2]posix.fd_t {
        const a = try self.allocSocketSlot();
        const b = self.allocSocketSlot() catch |err| {
            self.releaseSocketSlot(a);
            return err;
        };
        assert(a != b);
        self.sockets[a].partner_index = b;
        self.sockets[b].partner_index = a;
        assert(self.sockets[a].partner_index == b);
        assert(self.sockets[b].partner_index == a);
        return .{ self.fdForSlot(a), self.fdForSlot(b) };
    }

    /// Mark a socket as closed. Any parked recv on that slot is failed
    /// with `error.ConnectionResetByPeer`. The partner's parked recv (if
    /// any) is also failed — modelling the peer-reset semantics that the
    /// EventLoop cares about. Slots are not returned to the free pool.
    pub fn closeSocket(self: *SimIO, fd: posix.fd_t) void {
        const slot = self.slotForFd(fd) orelse return;
        const sock = &self.sockets[slot];
        if (sock.closed) return;
        sock.closed = true;

        // Fail this side's parked recv first.
        if (sock.parked_recv) |waiter| {
            sock.parked_recv = null;
            const wst = simState(waiter);
            assert(wst.parked_socket_index == slot);
            wst.parked_socket_index = sentinel_index;
            // Pre-condition for schedule: in_flight stays true. heap_index
            // is already sentinel because waiter was parked, not queued.
            self.schedule(waiter, .{ .recv = error.ConnectionResetByPeer }, 0) catch unreachable;
        }

        // Fail partner's parked recv.
        if (sock.partner_index != sentinel_index) {
            const partner_idx = sock.partner_index;
            assert(partner_idx < self.sockets.len);
            const partner = &self.sockets[partner_idx];
            if (partner.in_use and !partner.closed) {
                if (partner.parked_recv) |waiter| {
                    partner.parked_recv = null;
                    const wst = simState(waiter);
                    assert(wst.parked_socket_index == partner_idx);
                    wst.parked_socket_index = sentinel_index;
                    self.schedule(waiter, .{ .recv = error.ConnectionResetByPeer }, 0) catch unreachable;
                }
            }
        }
    }

    // ── Public submission methods (interface) ─────────────

    pub fn recv(self: *SimIO, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recv = op }, ud, cb);

        // Fault injection — applies to socket and legacy fds alike, so
        // tests can stress every recv site uniformly.
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.recv_error_probability) {
            return self.schedule(c, .{ .recv = error.ConnectionResetByPeer }, self.config.faults.recv_latency_ns);
        }

        if (self.slotForFd(op.fd)) |slot| {
            const sock = &self.sockets[slot];
            if (sock.closed) {
                return self.schedule(c, .{ .recv = error.ConnectionResetByPeer }, 0);
            }
            if (sock.recv_queue.count > 0) {
                const want = @min(op.buf.len, sock.recv_queue.count);
                const got = sock.recv_queue.consume(op.buf[0..want]);
                assert(got == want);
                return self.schedule(c, .{ .recv = got }, self.config.faults.recv_latency_ns);
            }
            // If the partner has already closed, no more bytes will ever
            // arrive — fail the recv now instead of parking forever.
            if (sock.partner_index != sentinel_index) {
                const partner = &self.sockets[sock.partner_index];
                if (partner.closed) {
                    return self.schedule(c, .{ .recv = error.ConnectionResetByPeer }, 0);
                }
            }
            // Park: stay in-flight, leave the heap, point at this slot.
            assert(sock.parked_recv == null);
            sock.parked_recv = c;
            const st = simState(c);
            assert(st.heap_index == sentinel_index);
            assert(st.parked_socket_index == sentinel_index);
            st.parked_socket_index = slot;
            return;
        }

        // Legacy fd: zero-byte success (matches the pre-socket
        // behaviour for any caller that didn't go through createSocketpair).
        return self.schedule(c, .{ .recv = @as(usize, 0) }, self.config.faults.recv_latency_ns);
    }

    pub fn send(self: *SimIO, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .send = op }, ud, cb);

        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.send_error_probability) {
            return self.schedule(c, .{ .send = error.BrokenPipe }, self.config.faults.send_latency_ns);
        }

        if (self.slotForFd(op.fd)) |slot| {
            const sock = &self.sockets[slot];
            if (sock.closed) {
                return self.schedule(c, .{ .send = error.BrokenPipe }, 0);
            }
            if (sock.partner_index == sentinel_index) {
                return self.schedule(c, .{ .send = error.BrokenPipe }, 0);
            }
            const partner = &self.sockets[sock.partner_index];
            if (partner.closed) {
                return self.schedule(c, .{ .send = error.BrokenPipe }, 0);
            }

            // Append into partner queue. May write less than op.buf.len if
            // capacity is reached; we surface the byte count in the result
            // so the caller can detect partial writes.
            const written = partner.recv_queue.append(op.buf);
            assert(written <= op.buf.len);

            // Wake a parked recv on the partner side, if any.
            if (partner.parked_recv) |waiter| {
                partner.parked_recv = null;
                const wst = simState(waiter);
                assert(wst.in_flight);
                assert(wst.parked_socket_index == sock.partner_index);
                wst.parked_socket_index = sentinel_index;
                switch (waiter.op) {
                    .recv => |recv_op| {
                        const want = @min(recv_op.buf.len, partner.recv_queue.count);
                        // The partner just received bytes; if want is 0
                        // the queue must be empty and the parked recv
                        // would not have been parked. Defensive assert.
                        assert(want > 0 or partner.recv_queue.count == 0);
                        const got = if (want > 0)
                            partner.recv_queue.consume(recv_op.buf[0..want])
                        else
                            @as(usize, 0);
                        try self.schedule(waiter, .{ .recv = got }, self.config.faults.recv_latency_ns);
                    },
                    else => unreachable, // only recv ops park on a socket
                }
            }

            return self.schedule(c, .{ .send = written }, self.config.faults.send_latency_ns);
        }

        // Legacy fd: zero-byte success (matches pre-socket behaviour).
        return self.schedule(c, .{ .send = @as(usize, 0) }, self.config.faults.send_latency_ns);
    }

    pub fn recvmsg(self: *SimIO, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .recvmsg = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.recv_error_probability) {
            return self.schedule(c, .{ .recvmsg = error.ConnectionResetByPeer }, self.config.faults.recv_latency_ns);
        }
        // Datagram fds aren't routed through the socket pool yet.
        return self.schedule(c, .{ .recvmsg = @as(usize, 0) }, self.config.faults.recv_latency_ns);
    }

    pub fn sendmsg(self: *SimIO, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .sendmsg = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.send_error_probability) {
            return self.schedule(c, .{ .sendmsg = error.BrokenPipe }, self.config.faults.send_latency_ns);
        }
        return self.schedule(c, .{ .sendmsg = @as(usize, 0) }, self.config.faults.send_latency_ns);
    }

    pub fn read(self: *SimIO, op: ifc.ReadOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .read = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.read_error_probability) {
            return self.schedule(c, .{ .read = error.InputOutput }, 0);
        }
        return self.schedule(c, .{ .read = @as(usize, 0) }, 0);
    }

    pub fn write(self: *SimIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.write_error_probability) {
            return self.schedule(c, .{ .write = error.NoSpaceLeft }, self.config.faults.write_latency_ns);
        }
        return self.schedule(c, .{ .write = @as(usize, 0) }, self.config.faults.write_latency_ns);
    }

    pub fn fsync(self: *SimIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        return self.schedule(c, .{ .fsync = {} }, 0);
    }

    pub fn socket(self: *SimIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .socket = op }, ud, cb);
        return self.schedule(c, .{ .socket = self.nextSyntheticFd() }, 0);
    }

    pub fn connect(self: *SimIO, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .connect = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.connect_error_probability) {
            return self.schedule(c, .{ .connect = error.ConnectionRefused }, 0);
        }
        return self.schedule(c, .{ .connect = {} }, 0);
    }

    pub fn accept(self: *SimIO, op: ifc.AcceptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .accept = op }, ud, cb);
        // Without a SimPeer pushing a connection there's no way to fire
        // accept, so park it on a sentinel deadline. Cancel will pull it
        // out via the heap path.
        self.submit_seq +%= 1;
        const seq = self.submit_seq ^ self.rng.random().int(u64);
        try self.pushPending(.{
            .deadline_ns = std.math.maxInt(u64),
            .seq = seq,
            .completion = c,
            .result = .{ .accept = error.WouldBlock },
        });
    }

    pub fn timeout(self: *SimIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        return self.schedule(c, .{ .timeout = {} }, op.ns);
    }

    pub fn poll(self: *SimIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        return self.schedule(c, .{ .poll = @as(u32, 0) }, 0);
    }

    /// Cancel an in-flight operation by completion pointer. The cancelled
    /// op's callback fires with `error.OperationCanceled` on the same
    /// tick; the cancel completion itself fires with `.cancel = {}` on
    /// success or `.cancel = error.OperationNotFound` if the target was
    /// not in flight.
    pub fn cancel(self: *SimIO, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .cancel = op }, ud, cb);

        const target = op.target;
        const ts = simState(target);

        // Branch 1: target was never in flight (or already delivered).
        if (!ts.in_flight) {
            return self.schedule(c, .{ .cancel = error.OperationNotFound }, 0);
        }

        // Branch 2: target is parked on a socket waiting for data.
        if (ts.parked_socket_index != sentinel_index) {
            const slot = ts.parked_socket_index;
            assert(slot < self.sockets.len);
            const sock = &self.sockets[slot];
            assert(sock.parked_recv == target);
            sock.parked_recv = null;
            ts.parked_socket_index = sentinel_index;
            try self.schedule(target, cancelResultFor(target.op), 0);
            return self.schedule(c, .{ .cancel = {} }, 0);
        }

        // Branch 3: target is in the heap.
        assert(ts.heap_index != sentinel_index);
        const idx = ts.heap_index;
        _ = self.removeAt(idx);
        try self.schedule(target, cancelResultFor(target.op), 0);
        return self.schedule(c, .{ .cancel = {} }, 0);
    }
};

fn cancelResultFor(op: Operation) Result {
    return switch (op) {
        .none => .{ .timeout = error.OperationCanceled },
        .recv => .{ .recv = error.OperationCanceled },
        .send => .{ .send = error.OperationCanceled },
        .recvmsg => .{ .recvmsg = error.OperationCanceled },
        .sendmsg => .{ .sendmsg = error.OperationCanceled },
        .read => .{ .read = error.OperationCanceled },
        .write => .{ .write = error.OperationCanceled },
        .fsync => .{ .fsync = error.OperationCanceled },
        .socket => .{ .socket = error.OperationCanceled },
        .connect => .{ .connect = error.OperationCanceled },
        .accept => .{ .accept = error.OperationCanceled },
        .timeout => .{ .timeout = error.OperationCanceled },
        .poll => .{ .poll = error.OperationCanceled },
        .cancel => .{ .cancel = error.OperationCanceled },
    };
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

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
    ctx.last_result = result;
    ctx.calls += 1;
    return .disarm;
}

test "SimIO timeout fires after specified delay" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, testCallback);

    // No fire yet (now_ns = 0, deadline = 1_000_000).
    try io.tick();
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Halfway — still no fire.
    try io.advance(500_000);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    // Past the deadline — fires once.
    try io.advance(600_000);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO multiple timeouts deliver in deadline order" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const N: u32 = 8;
    var completions: [N]Completion = .{Completion{}} ** N;

    const OrderLog = struct {
        slots: [N]u32 = .{0} ** N,
        next_index: u32 = 0,
    };
    var log = OrderLog{};

    // Submit timeouts in submission order 0..N-1, but with deadlines that
    // run from N down to 1 — so the *delivery* order should be the reverse
    // of the *submission* order.
    const cb = struct {
        fn cb(ud: ?*anyopaque, c: *Completion, _: Result) CallbackAction {
            const owner: *OrderLog = @ptrCast(@alignCast(ud.?));
            const base_addr = @intFromPtr(c) - @intFromPtr(&completions_for_test[0]);
            const idx: u32 = @intCast(base_addr / @sizeOf(Completion));
            owner.slots[owner.next_index] = idx;
            owner.next_index += 1;
            return .disarm;
        }
    }.cb;
    completions_for_test = &completions;

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        try io.timeout(.{ .ns = (N - i) * 1_000_000 }, &completions[i], &log, cb);
    }

    try io.advance(N * 1_000_000 + 1);
    try testing.expectEqual(N, log.next_index);
    // The deadline schedule was N, N-1, ..., 1 ms — so callback i=N-1
    // fires first (deadline 1 ms), down to i=0 last (deadline N ms).
    var k: u32 = 0;
    while (k < N) : (k += 1) {
        try testing.expectEqual(N - 1 - k, log.slots[k]);
    }
}

// File-scope mutable so the inline test callback can derive a slot index
// from the completion pointer arithmetic.
var completions_for_test: []Completion = &.{};

test "SimIO recv with fault probability 1.0 always errors" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 12345,
        .faults = .{ .recv_error_probability = 1.0 },
    });
    defer io.deinit();

    var buf: [16]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};
    try io.recv(.{ .fd = 7, .buf = &buf }, &c, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "SimIO connect with fault probability 0.0 always succeeds" {
    var io = try SimIO.init(testing.allocator, .{
        .seed = 1,
        .faults = .{ .connect_error_probability = 0.0 },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6881);
    try io.connect(.{ .fd = 3, .addr = addr }, &c, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .connect => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO PendingQueueFull when capacity exhausted" {
    var io = try SimIO.init(testing.allocator, .{ .pending_capacity = 4 });
    defer io.deinit();

    var completions: [5]Completion = .{Completion{}} ** 5;
    var ctx = TestCtx{};

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try io.timeout(.{ .ns = 1_000_000_000 }, &completions[i], &ctx, testCallback);
    }
    try testing.expectError(
        error.PendingQueueFull,
        io.timeout(.{ .ns = 1_000_000_000 }, &completions[4], &ctx, testCallback),
    );
}

test "SimIO cancel removes target and delivers OperationCanceled" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var target = Completion{};
    var canceller = Completion{};

    const TestState = struct {
        target_calls: u32 = 0,
        target_result: ?Result = null,
        cancel_calls: u32 = 0,
        cancel_result: ?Result = null,
    };
    var state = TestState{};

    const target_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *TestState = @ptrCast(@alignCast(ud.?));
            s.target_calls += 1;
            s.target_result = result;
            return .disarm;
        }
    }.cb;
    const cancel_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const s: *TestState = @ptrCast(@alignCast(ud.?));
            s.cancel_calls += 1;
            s.cancel_result = result;
            return .disarm;
        }
    }.cb;

    var buf: [16]u8 = undefined;
    try io.recv(.{ .fd = 7, .buf = &buf }, &target, &state, target_cb);
    try io.cancel(.{ .target = &target }, &canceller, &state, cancel_cb);

    try io.tick();

    try testing.expectEqual(@as(u32, 1), state.target_calls);
    try testing.expectEqual(@as(u32, 1), state.cancel_calls);
    switch (state.target_result.?) {
        .recv => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (state.cancel_result.?) {
        .cancel => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO cancel returns OperationNotFound for unsubmitted target" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    var unsubmitted = Completion{};
    var canceller = Completion{};
    var ctx = TestCtx{};

    try io.cancel(.{ .target = &unsubmitted }, &canceller, &ctx, testCallback);
    try io.tick();

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .cancel => |r| try testing.expectError(error.OperationNotFound, r),
        else => try testing.expect(false),
    }
}

test "SimIO rearm resubmits the same operation" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const Counter = struct { fires: u32 = 0, target: u32 = 3 };
    var counter = Counter{};

    var c = Completion{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            const s: *Counter = @ptrCast(@alignCast(ud.?));
            s.fires += 1;
            return if (s.fires < s.target) .rearm else .disarm;
        }
    }.cb;

    try io.timeout(.{ .ns = 0 }, &c, &counter, cb);
    try io.advance(1);
    try io.advance(1);
    try io.advance(1);
    try testing.expectEqual(@as(u32, 3), counter.fires);
}

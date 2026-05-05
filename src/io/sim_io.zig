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
const linux = std.os.linux;
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
//
// NOTE on layout: this is a regular struct, not a packed struct. We tried
// a packed-struct form earlier (heap_index: u32 + in_flight: bool +
// _padding: u31, total 64 bits / 8 bytes / 8-byte align). Adding
// `parked_socket_index: u32` pushes the packed bit-width to 96 bits, and
// Zig 0.15.2 rounds packed-struct alignment up to the smallest
// power-of-two integer that fits — that's `@alignOf(u128) == 16`, which
// blows past `backend_state_align = 8` and trips the comptime assert
// below. The regular-struct form sits at 12 bytes / 4-byte align, well
// inside the 64-byte / 8-byte budget. Don't try to "fix" this back to
// packed without verifying alignment against `backend_state_align`.

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
    /// Probability that a fallocate completes with `error.NoSpaceLeft`
    /// (matches what the kernel surfaces when a torrent file's
    /// pre-allocation hits a full disk).
    fallocate_error_probability: f32 = 0.0,
    /// Probability that a fallocate completes with
    /// `error.OperationNotSupported`, simulating a filesystem that
    /// rejects fallocate entirely (tmpfs <5.10, FAT32, certain FUSE
    /// FSes). PieceStore.init reacts by falling back to `io.truncate`,
    /// so this knob is what tests use to drive the fallback path.
    /// Independent of `fallocate_error_probability`; checked first.
    fallocate_unsupported_probability: f32 = 0.0,
    /// Probability that a truncate completes with `error.InputOutput`
    /// (disk failure during ftruncate). Exercised by the
    /// `PieceStore.init` fallback path that fires on filesystems
    /// rejecting fallocate (tmpfs <5.10, FAT32, certain FUSE FSes).
    truncate_error_probability: f32 = 0.0,
    /// Probability that a splice completes with `error.InputOutput`.
    /// Used by MoveJob fault tests to exercise the cross-fs copy
    /// path's error handling.
    splice_error_probability: f32 = 0.0,
    /// Probability that a copy_file_range completes with
    /// `error.InputOutput`. Used by MoveJob fault tests.
    copy_file_range_error_probability: f32 = 0.0,
    /// Directory-op fault knobs used by future MoveJob/PieceStore.init
    /// state-machine tests. Each successful op still mutates the virtual
    /// filesystem deterministically; a fault returns `error.InputOutput`
    /// and leaves state unchanged.
    openat_error_probability: f32 = 0.0,
    mkdirat_error_probability: f32 = 0.0,
    renameat_error_probability: f32 = 0.0,
    renameat_exdev_probability: f32 = 0.0,
    unlinkat_error_probability: f32 = 0.0,
    statx_error_probability: f32 = 0.0,
    getdents_error_probability: f32 = 0.0,
    close_error_probability: f32 = 0.0,
    /// Probability that an fsync completes with `error.InputOutput`
    /// (disk failure mid-flush). Distinct from
    /// `write_error_probability` so BUGGIFY can target sync-only paths.
    fsync_error_probability: f32 = 0.0,
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
    /// Inclusive min/max logical-tick delay for reset CQEs generated by
    /// `closeSocket` when it wakes parked recv operations. Defaults to
    /// zero, preserving the strict model.
    delayed_close_cqe_min_ticks: u32 = 0,
    delayed_close_cqe_max_ticks: u32 = 0,
    /// Inclusive min/max logical-tick delay for every scheduled CQE.
    /// Tests use this to make same-time completions arrive on later
    /// ticks without advancing simulated nanoseconds.
    cqe_reorder_window_ticks_min: u32 = 0,
    cqe_reorder_window_ticks_max: u32 = 0,
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
    /// Cap on ops processed per `tick(...)` call. Models real io_uring's
    /// batched CQE behaviour (the kernel returns to userspace after a
    /// finite batch even if more CQEs are ready). Lets the EventLoop's
    /// periodic policy passes (processHashResults, tryAssignPieces,
    /// checkPeerTimeouts, etc.) interleave with I/O completions instead
    /// of starving inside a tight callback chain. BUGGIFY tests lower
    /// this so the work spans more ticks and faults can land on
    /// in-flight ops.
    max_ops_per_tick: u32 = 4096,
};

// ── Pending entry ─────────────────────────────────────────
//
// A pending entry is a (deadline, ready tick, sequence, completion,
// result) tuple in the min-heap. `ready_tick` lets fault-injection hold a
// CQE after its simulated time deadline has arrived. `seq` breaks ties
// between completions sharing a deadline and ready tick — assigning
// sequence numbers from a seeded PRNG produces a deterministic but
// order-stressing schedule.
//
// `result` is the result to deliver when the entry pops.

const Pending = struct {
    deadline_ns: u64,
    ready_tick: u64,
    seq: u64,
    completion: *Completion,
    result: Result,
};

fn pendingLess(_: void, a: Pending, b: Pending) std.math.Order {
    if (a.deadline_ns != b.deadline_ns) return std.math.order(a.deadline_ns, b.deadline_ns);
    if (a.ready_tick != b.ready_tick) return std.math.order(a.ready_tick, b.ready_tick);
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

// ── Sim file state (durability model) ─────────────────────
//
// Two byte-level layers per fd:
//
//   - `durable`: bytes that have been fsynced. Survives `crash()`.
//   - `pending`: bytes accepted by `write` but not yet fsynced. Dropped
//     by `crash()`.
//   - `pending_len`: file length metadata accepted by `write`,
//     `truncate`, or `fallocate` but not yet fsynced. Dropped by
//     `crash()`.
//   - `pending_dirty`: bit-per-byte mask. Bit `i` set means `pending[i]`
//     is an overlay (returned by reads in preference to `durable[i]`);
//     clear means `durable[i]` wins.
//
// `read` returns `durable[i]` when `pending_dirty[i] == 0` and
// `pending[i]` when `pending_dirty[i] == 1`. `fsync` copies each set bit
// from `pending` into `durable` (resizing `durable` to `pending_len` when
// file length metadata is dirty) then clears those bits. `crash()` clears
// all bits and resets `pending_len`.
//
// All three buffers grow as needed when a `write` extends past their
// current length; bytes added by growth are zeroed and marked
// non-dirty (pending bits clear).
pub const SimFile = struct {
    durable: std.ArrayListUnmanaged(u8) = .{},
    pending: std.ArrayListUnmanaged(u8) = .{},
    pending_len: ?usize = null,
    pending_dirty: std.DynamicBitSetUnmanaged = .{},

    fn deinit(self: *SimFile, allocator: std.mem.Allocator) void {
        self.durable.deinit(allocator);
        self.pending.deinit(allocator);
        self.pending_dirty.deinit(allocator);
    }

    /// Length the durable layer claims (post-fsync content size).
    fn durableLen(self: *const SimFile) usize {
        return self.durable.items.len;
    }

    /// Length the union (durable + pending overlay) claims. Equals
    /// pending metadata length when present, otherwise durable length.
    fn visibleLen(self: *const SimFile) usize {
        return self.pending_len orelse self.durable.items.len;
    }

    /// Grow `pending` and `pending_dirty` so they cover at least `n`
    /// bytes. Newly-grown bytes are zeroed and marked clean.
    fn ensurePending(
        self: *SimFile,
        allocator: std.mem.Allocator,
        n: usize,
    ) !void {
        if (self.pending.items.len < n) {
            const old_len = self.pending.items.len;
            try self.pending.resize(allocator, n);
            @memset(self.pending.items[old_len..], 0);
        }
        if (self.pending_dirty.bit_length < n) {
            try self.pending_dirty.resize(allocator, n, false);
        }
    }

    fn markPendingLen(self: *SimFile, len: usize) void {
        self.pending_len = len;
    }

    fn extendPendingLen(self: *SimFile, len: usize) void {
        self.pending_len = @max(self.pending_len orelse self.durable.items.len, len);
    }

    fn markDirtyRange(self: *SimFile, start: usize, end: usize) void {
        var i: usize = start;
        while (i < end) : (i += 1) self.pending_dirty.set(i);
    }

    fn writePendingBytes(
        self: *SimFile,
        allocator: std.mem.Allocator,
        off: usize,
        bytes: []const u8,
    ) !void {
        const end = off + bytes.len;
        try self.ensurePending(allocator, end);
        self.extendPendingLen(end);
        @memcpy(self.pending.items[off..end], bytes);
        self.markDirtyRange(off, end);
    }

    fn fillPendingBytes(
        self: *SimFile,
        allocator: std.mem.Allocator,
        off: usize,
        len: usize,
        byte: u8,
        keep_size: bool,
    ) !void {
        const visible_before = self.visibleLen();
        const end = off + len;
        if (!keep_size) self.extendPendingLen(end);

        const dirty_end = if (keep_size) @min(end, visible_before) else end;
        if (off >= dirty_end) return;

        try self.ensurePending(allocator, dirty_end);
        @memset(self.pending.items[off..dirty_end], byte);
        self.markDirtyRange(off, dirty_end);
    }

    /// Read the union of durable+pending into `dst`, starting at file
    /// offset `off`. Returns the number of bytes written into `dst`.
    /// Bytes past the visible length read as zero, mirroring real
    /// pread behaviour against a sparse file (we treat unwritten
    /// regions as zero-filled, matching what mmap or a fresh
    /// fallocate'd file would expose).
    fn readUnion(self: *const SimFile, off: usize, dst: []u8) usize {
        const visible = self.visibleLen();
        if (off >= visible) return 0;
        const available: usize = visible - off;
        const n: usize = @min(dst.len, available);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const file_idx = off + i;
            const dirty = file_idx < self.pending_dirty.bit_length and
                self.pending_dirty.isSet(file_idx);
            if (dirty) {
                dst[i] = self.pending.items[file_idx];
            } else if (file_idx < self.durable.items.len) {
                dst[i] = self.durable.items[file_idx];
            } else {
                dst[i] = 0;
            }
        }
        return n;
    }

    /// Promote pending length metadata and every dirty byte into
    /// `durable`, then clear the dirty mask. After the call, `pending`
    /// retains its buffer (so the next write doesn't have to grow from
    /// zero) but no bit in `pending_dirty` is set.
    fn promotePending(
        self: *SimFile,
        allocator: std.mem.Allocator,
    ) !void {
        const target_len = self.pending_len orelse self.durable.items.len;
        var need = target_len;

        // Grow durable to cover the highest dirty bit, if any.
        if (self.pending_dirty.bit_length > 0) {
            var it = self.pending_dirty.iterator(.{});
            while (it.next()) |idx| {
                if (idx + 1 > need) need = idx + 1;
            }
        }

        if (self.durable.items.len != need) {
            const old_len = self.durable.items.len;
            try self.durable.resize(allocator, need);
            if (need > old_len) @memset(self.durable.items[old_len..], 0);
        }

        var it2 = self.pending_dirty.iterator(.{});
        while (it2.next()) |idx| {
            if (idx < self.durable.items.len) {
                self.durable.items[idx] = self.pending.items[idx];
            }
        }
        // Clear the dirty mask in one shot. We keep the bit-set
        // capacity around; the next write will set bits again.
        self.pending_dirty.unsetAll();
        self.pending_len = null;
    }

    /// Drop every dirty bit (i.e. forget all pending writes). The
    /// pending buffer is shrunk-in-place but its capacity is retained
    /// — a subsequent write reuses the allocation. Mirrors a
    /// power-loss between write CQE and fsync CQE.
    fn dropPending(self: *SimFile) void {
        self.pending_len = null;
        self.pending_dirty.unsetAll();
        self.pending.clearRetainingCapacity();
    }
};

const SimFsKind = enum {
    file,
    dir,
};

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

    /// Logical CQE drain tick. Incremented once per `tick` call, so
    /// tests can defer completions by event-loop iterations without
    /// advancing simulated nanoseconds.
    delivery_tick: u64 = 0,

    /// Min-heap of pending completions keyed by deadline_ns, ready_tick,
    /// then seq.
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

    /// Optional per-fd file state, populated by `setFileBytes` (seed)
    /// and by subsequent `write` / `fsync` ops (durability model). When
    /// a `read` op targets a registered fd, SimIO returns the union of
    /// `durable` overlaid with `pending` (most-recent byte wins) instead
    /// of the default zero-byte success.
    ///
    /// Used by recheck/disk tests *and* by durability-aware tests that
    /// model the kernel's pagecache barrier:
    ///   * `write(buf, offset)` extends `pending` (sized to cover
    ///     offset+len) and marks the affected bytes dirty.
    ///   * `fsync` (success path) promotes the dirty pending region
    ///     into `durable` and clears the dirty mask.
    ///   * `crash()` drops every fd's pending bytes, leaving only
    ///     durable. Models a power-loss between write CQE and fsync
    ///     CQE.
    ///
    /// The map is empty by default; production data-path reads against
    /// fds that were never seeded or written still hit the legacy
    /// zero-byte path.
    ///
    /// Tradeoff: flat `ArrayListUnmanaged(u8)` per layer plus a
    /// `pending_dirty` bit-per-byte mask. Simpler than a sparse-extent
    /// representation and good enough for the test piece sizes (KB to a
    /// few MB). If a future test wants to model a multi-GB sparse file
    /// the storage shape can switch to extents without changing the
    /// public API. Bytes are owned by SimIO (`setFileBytes` copies); the
    /// caller may free its source slice immediately after the call.
    file_state: std.AutoHashMap(posix.fd_t, SimFile),

    /// Minimal virtual namespace for fd-relative directory ops. Keys are
    /// normalized path strings owned by SimIO; fd handles opened through
    /// `openat` store an owned copy in `fd_paths`.
    fs_nodes: std.StringHashMapUnmanaged(SimFsKind) = .{},
    path_file_state: std.StringHashMapUnmanaged(SimFile) = .{},
    fd_paths: std.AutoHashMap(posix.fd_t, []u8),
    fd_dir_offsets: std.AutoHashMap(posix.fd_t, usize),
    closed_fds: std.AutoHashMap(posix.fd_t, void),

    /// FIFO of pre-prepared fds returned by future `socket()` calls.
    /// Each `socket` submission consumes one entry; if the queue is
    /// empty the op falls back to `nextSyntheticFd()`.
    ///
    /// Lets tests script "next call to `io.socket()` returns this
    /// specific fd" — used by AsyncMetadataFetchOf(SimIO) happy-path
    /// tests to wire the fetcher to a `createSocketpair` half whose
    /// recv queue has been pre-loaded with scripted protocol responses.
    prepared_socket_fds: std.ArrayList(posix.fd_t) = .empty,

    /// Optional pre-tick hook invoked at the top of every `tick` call
    /// (after the re-entrancy guard, before any completions are
    /// delivered). Lets BUGGIFY harnesses inject `injectRandomFault`
    /// rolls into the same drain loops that the system-under-test
    /// runs internally — `PieceStore.writePiece`, `sync`, `init` all
    /// own their own `while (pending > 0) try io.tick(1)` loops, so
    /// the only way to mutate an in-flight op's result mid-method is
    /// from inside `tick` itself.
    ///
    /// The hook may call `injectRandomFault`, log, or examine
    /// `self.pending_len`, but MUST NOT call `tick` recursively.
    pre_tick_hook: ?*const fn (sim: *SimIO, ctx: ?*anyopaque) void = null,
    pre_tick_ctx: ?*anyopaque = null,

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

        var self = SimIO{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(config.seed),
            .config = config,
            .pending = slots,
            .sockets = sockets,
            .recv_queue_pool = queue_buf,
            .free_socket_head = head,
            .file_state = std.AutoHashMap(posix.fd_t, SimFile).init(allocator),
            .fd_paths = std.AutoHashMap(posix.fd_t, []u8).init(allocator),
            .fd_dir_offsets = std.AutoHashMap(posix.fd_t, usize).init(allocator),
            .closed_fds = std.AutoHashMap(posix.fd_t, void).init(allocator),
        };
        errdefer self.deinit();

        try self.putFsNode(".", .dir);
        try self.putFsNode("/", .dir);
        return self;
    }

    pub fn deinit(self: *SimIO) void {
        var it = self.file_state.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.file_state.deinit();
        var path_file_it = self.path_file_state.iterator();
        while (path_file_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.path_file_state.deinit(self.allocator);
        var node_it = self.fs_nodes.iterator();
        while (node_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.fs_nodes.deinit(self.allocator);
        var fd_it = self.fd_paths.iterator();
        while (fd_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.fd_paths.deinit();
        self.fd_dir_offsets.deinit();
        self.closed_fds.deinit();
        self.prepared_socket_fds.deinit(self.allocator);
        self.allocator.free(self.pending);
        self.allocator.free(self.recv_queue_pool);
        self.allocator.free(self.sockets);
        self.* = undefined;
    }

    /// Seed durable byte content for `fd`. Subsequent `read` submissions
    /// on `fd` see these bytes overlaid with any pending (un-fsynced)
    /// writes. Used by recheck/disk tests that need the read result to
    /// reflect "what's on disk" rather than always returning zero.
    ///
    /// SimIO copies `bytes` into an owned buffer, so the caller may free
    /// or reuse its slice immediately. (This differs from the original
    /// no-copy contract; the new durability model needs to own + grow
    /// the byte storage, so the slice can no longer be aliased.)
    ///
    /// Calling twice with the same fd replaces the durable layer and
    /// drops any pending bytes.
    pub fn setFileBytes(self: *SimIO, fd: posix.fd_t, bytes: []const u8) !void {
        const sf = try self.getOrPutFileStateForFd(fd);
        try self.resetFileBytes(sf, bytes);
    }

    /// Drop every fd's pending (un-fsynced) bytes; durable bytes stay.
    /// Models a power-loss / kernel-panic between a write CQE and the
    /// matching fsync CQE. Subsequent reads see only durable content.
    /// Test-only — the public daemon code never calls this.
    pub fn crash(self: *SimIO) void {
        var it = self.file_state.iterator();
        while (it.next()) |entry| entry.value_ptr.dropPending();
        var path_it = self.path_file_state.iterator();
        while (path_it.next()) |entry| entry.value_ptr.dropPending();
    }

    /// Enqueue `fd` so the next `socket()` submission returns it
    /// instead of a fresh synthetic fd. FIFO across multiple calls.
    ///
    /// Pair with `createSocketpair` to script "the metadata fetch's
    /// next socket() resolves to side-A of this pair" — caller pushes
    /// scripted bytes onto the partner side via
    /// `pushSocketRecvBytes` and the fetch state machine drives
    /// against it as if it were a live peer.
    pub fn enqueueSocketResult(self: *SimIO, fd: posix.fd_t) !void {
        try self.prepared_socket_fds.append(self.allocator, fd);
    }

    /// Append `bytes` directly to the recv queue for `fd`, the
    /// scripted-peer mirror of `setFileBytes`. The fetcher consumes
    /// these bytes through normal `recv` ops as if a live partner had
    /// `send`-ed them.
    ///
    /// Returns `error.InvalidFd` if `fd` is not in the socket pool
    /// (i.e. not allocated by `createSocketpair`), `error.SocketClosed`
    /// if the slot has been closed, or `error.RecvQueueFull` if the
    /// queue lacks the capacity for the full slice. Pre-load all
    /// scripted bytes upfront so a parked recv never has to wait —
    /// the queue's ring-buffer write is atomic per call.
    ///
    /// If a recv is currently parked on `fd`, this wakes it (mirrors
    /// the wake-up path in `send`).
    pub fn pushSocketRecvBytes(self: *SimIO, fd: posix.fd_t, bytes: []const u8) !void {
        const slot = self.slotForFd(fd) orelse return error.InvalidFd;
        const sock = &self.sockets[slot];
        if (sock.closed) return error.SocketClosed;

        const written = sock.recv_queue.append(bytes);
        if (written != bytes.len) return error.RecvQueueFull;

        if (sock.parked_recv) |waiter| {
            sock.parked_recv = null;
            const wst = simState(waiter);
            assert(wst.in_flight);
            assert(wst.parked_socket_index == slot);
            wst.parked_socket_index = sentinel_index;
            switch (waiter.op) {
                .recv => |recv_op| {
                    const want = @min(recv_op.buf.len, sock.recv_queue.count);
                    const got = if (want > 0)
                        sock.recv_queue.consume(recv_op.buf[0..want])
                    else
                        @as(usize, 0);
                    try self.schedule(waiter, .{ .recv = got }, self.config.faults.recv_latency_ns);
                },
                else => unreachable, // only recv ops park on a socket
            }
        }
    }

    /// Current simulated time.
    pub fn now(self: *const SimIO) u64 {
        return self.now_ns;
    }

    /// Advance the simulated clock and deliver all due completions.
    /// Equivalent to `now_ns += delta_ns; try self.tick()`.
    pub fn advance(self: *SimIO, delta_ns: u64) !void {
        self.now_ns += delta_ns;
        try self.tick(0);
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
    ///
    /// `wait_at_least` is accepted for signature parity with
    /// `RealIO.tick(wait_at_least)` — production code generic over the
    /// IO type uniformly calls `io.tick(1)`. SimIO is synchronous and
    /// never blocks; the parameter is ignored.
    pub fn tick(self: *SimIO, wait_at_least: u32) !void {
        _ = wait_at_least;
        assert(!self.in_tick); // no recursive ticks
        self.delivery_tick +%= 1;

        // Pre-tick hook (BUGGIFY harness entry-point). Fires before the
        // `in_tick` flag is set so the hook may invoke any non-tick
        // public method — `injectRandomFault` is the canonical use, but
        // the hook is generic. Recursive `tick` is still rejected by the
        // assertion above on re-entry.
        if (self.pre_tick_hook) |hook| hook(self, self.pre_tick_ctx);

        self.in_tick = true;
        defer self.in_tick = false;

        // Cap ops processed per tick (Config.max_ops_per_tick). See
        // Config docstring for rationale.
        var ops: u32 = 0;
        while (ops < self.config.max_ops_per_tick) : (ops += 1) {
            const ready_idx = self.findReadyPendingIndex() orelse break;
            const entry = self.removeAt(ready_idx);
            const c = entry.completion;
            const callback = c.callback orelse continue; // disarmed mid-flight

            // Mark the completion no-longer-in-flight before the callback
            // runs. removeAt already cleared heap_index; a parked completion
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
            .close => |op| try self.close(op, c, ud, cb),
            .fallocate => |op| try self.fallocate(op, c, ud, cb),
            .truncate => |op| try self.truncate(op, c, ud, cb),
            .openat => |op| try self.openat(op, c, ud, cb),
            .mkdirat => |op| try self.mkdirat(op, c, ud, cb),
            .renameat => |op| try self.renameat(op, c, ud, cb),
            .unlinkat => |op| try self.unlinkat(op, c, ud, cb),
            .statx => |op| try self.statx(op, c, ud, cb),
            .getdents => |op| try self.getdents(op, c, ud, cb),
            .splice => |op| try self.splice(op, c, ud, cb),
            .copy_file_range => |op| try self.copy_file_range(op, c, ud, cb),
            .socket => |op| try self.socket(op, c, ud, cb),
            .connect => |op| try self.connect(op, c, ud, cb),
            .accept => |op| try self.accept(op, c, ud, cb),
            .bind => |op| try self.bind(op, c, ud, cb),
            .listen => |op| try self.listen(op, c, ud, cb),
            .setsockopt => |op| try self.setsockopt(op, c, ud, cb),
            .timeout => |op| try self.timeout(op, c, ud, cb),
            .poll => |op| try self.poll(op, c, ud, cb),
            .cancel => |op| try self.cancel(op, c, ud, cb),
        }
    }

    // ── Heap operations ───────────────────────────────────

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

    fn findReadyPendingIndex(self: *const SimIO) ?u32 {
        var best: ?u32 = null;
        var i: u32 = 0;
        while (i < self.pending_len) : (i += 1) {
            const entry = self.pending[i];
            if (entry.deadline_ns > self.now_ns) continue;
            if (entry.ready_tick > self.delivery_tick) continue;

            if (best) |best_idx| {
                if (pendingLess({}, entry, self.pending[best_idx]) == .lt) {
                    best = i;
                }
            } else {
                best = i;
            }
        }
        return best;
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
        return self.scheduleWithTickDelay(c, result, delay_ns, self.cqeReorderDelayTicks());
    }

    fn scheduleCloseReset(self: *SimIO, c: *Completion, result: Result) !void {
        const close_delay = self.closeCqeDelayTicks();
        const reorder_delay = self.cqeReorderDelayTicks();
        return self.scheduleWithTickDelay(c, result, 0, close_delay +| reorder_delay);
    }

    fn scheduleWithTickDelay(
        self: *SimIO,
        c: *Completion,
        result: Result,
        delay_ns: u64,
        delay_ticks: u32,
    ) !void {
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
            .ready_tick = self.readyTick(delay_ticks),
            .seq = seq,
            .completion = c,
            .result = result,
        });
    }

    fn readyTick(self: *const SimIO, delay_ticks: u32) u64 {
        if (delay_ticks == 0) return self.delivery_tick;
        return self.delivery_tick +| @as(u64, delay_ticks) +| 1;
    }

    fn jitter(self: *SimIO) u64 {
        const max = self.config.faults.completion_jitter_ns;
        if (max == 0) return 0;
        return self.rng.random().uintLessThan(u64, max);
    }

    fn closeCqeDelayTicks(self: *SimIO) u32 {
        return self.sampleTickDelay(
            self.config.faults.delayed_close_cqe_min_ticks,
            self.config.faults.delayed_close_cqe_max_ticks,
        );
    }

    fn cqeReorderDelayTicks(self: *SimIO) u32 {
        return self.sampleTickDelay(
            self.config.faults.cqe_reorder_window_ticks_min,
            self.config.faults.cqe_reorder_window_ticks_max,
        );
    }

    fn sampleTickDelay(self: *SimIO, min: u32, max: u32) u32 {
        if (max <= min) return min;
        const span = max - min;
        return min + self.rng.random().uintLessThan(u32, span + 1);
    }

    /// Synthesise a fake file descriptor for the `socket` op. The returned
    /// values fit in the `posix.fd_t` range and never collide with the
    /// sim-socket fd range issued by `createSocketpair`.
    fn nextSyntheticFd(self: *SimIO) posix.fd_t {
        self.submit_seq +%= 1;
        const offset: i32 = @intCast(@as(u32, @truncate(self.submit_seq)) & 0xffff);
        return @as(posix.fd_t, synthetic_fd_base + offset);
    }

    fn putFsNode(self: *SimIO, path: []const u8, kind: SimFsKind) !void {
        if (self.fs_nodes.getPtr(path)) |existing| {
            existing.* = kind;
            return;
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.fs_nodes.put(self.allocator, owned, kind);
    }

    fn removeFsNode(self: *SimIO, path: []const u8) void {
        if (self.fs_nodes.fetchRemove(path)) |kv| self.allocator.free(kv.key);
    }

    fn getOrPutPathFileState(self: *SimIO, path: []const u8) !*SimFile {
        if (self.path_file_state.getPtr(path)) |sf| return sf;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.path_file_state.put(self.allocator, owned, .{});
        return self.path_file_state.getPtr(path).?;
    }

    fn getOrPutRawFileState(self: *SimIO, fd: posix.fd_t) !*SimFile {
        const gop = try self.file_state.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn getOrPutFileStateForFd(self: *SimIO, fd: posix.fd_t) !*SimFile {
        if (self.closed_fds.contains(fd)) return error.BadFileDescriptor;
        if (self.fd_paths.get(fd)) |path| return self.getOrPutPathFileState(path);
        return self.getOrPutRawFileState(fd);
    }

    fn fileStatePtrForFd(self: *SimIO, fd: posix.fd_t) !?*SimFile {
        if (self.closed_fds.contains(fd)) return error.BadFileDescriptor;
        if (self.fd_paths.get(fd)) |path| return self.path_file_state.getPtr(path);
        return self.file_state.getPtr(fd);
    }

    fn resetFileBytes(self: *SimIO, sf: *SimFile, bytes: []const u8) !void {
        sf.deinit(self.allocator);
        sf.* = .{};
        var owned = std.ArrayListUnmanaged(u8){};
        errdefer owned.deinit(self.allocator);
        try owned.appendSlice(self.allocator, bytes);
        sf.durable = owned;
    }

    fn removePathFileState(self: *SimIO, path: []const u8) void {
        if (self.path_file_state.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            var value = kv.value;
            value.deinit(self.allocator);
        }
    }

    fn movePathFileState(self: *SimIO, old_path: []const u8, new_path: []const u8) !void {
        const kv = self.path_file_state.fetchRemove(old_path) orelse return;
        var value = kv.value;
        errdefer value.deinit(self.allocator);
        self.allocator.free(kv.key);

        self.removePathFileState(new_path);
        const owned_new = try self.allocator.dupe(u8, new_path);
        errdefer self.allocator.free(owned_new);
        try self.path_file_state.put(self.allocator, owned_new, value);
    }

    fn resolveAt(self: *SimIO, dir_fd: posix.fd_t, path: [:0]const u8) ![]u8 {
        if (path.len == 0) return error.FileNotFound;
        if (path[0] == '/') return try self.allocator.dupe(u8, path);

        const base = if (dir_fd == posix.AT.FDCWD)
            "."
        else
            self.fd_paths.get(dir_fd) orelse return error.BadFileDescriptor;

        if (std.mem.eql(u8, base, ".")) return try self.allocator.dupe(u8, path);
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, path });
    }

    fn parentPath(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            if (idx == 0) return "/";
            return path[0..idx];
        }
        return ".";
    }

    fn hasDir(self: *SimIO, path: []const u8) bool {
        return if (self.fs_nodes.get(path)) |kind| kind == .dir else false;
    }

    fn hasChild(self: *SimIO, dir_path: []const u8) bool {
        var iter = self.fs_nodes.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            if (path.len <= dir_path.len) continue;
            if (!std.mem.startsWith(u8, path, dir_path)) continue;
            if (std.mem.eql(u8, dir_path, ".") or path[dir_path.len] == '/') return true;
        }
        return false;
    }

    fn directChildName(dir_path: []const u8, child_path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, child_path, dir_path)) return null;

        if (std.mem.eql(u8, dir_path, ".")) {
            if (std.mem.indexOfScalar(u8, child_path, '/') != null) return null;
            return child_path;
        }

        if (std.mem.eql(u8, dir_path, "/")) {
            if (child_path.len <= 1 or child_path[0] != '/') return null;
            const rest = child_path[1..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
            return rest;
        }

        if (child_path.len <= dir_path.len + 1) return null;
        if (!std.mem.startsWith(u8, child_path, dir_path)) return null;
        if (child_path[dir_path.len] != '/') return null;
        const rest = child_path[dir_path.len + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
        return rest;
    }

    fn direntType(kind: SimFsKind) u8 {
        return switch (kind) {
            .file => linux.DT.REG,
            .dir => linux.DT.DIR,
        };
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
        if (self.fd_paths.fetchRemove(fd)) |kv| {
            self.allocator.free(kv.value);
            _ = self.fd_dir_offsets.remove(fd);
            self.closed_fds.put(fd, {}) catch {};
            return;
        }

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
            self.scheduleCloseReset(waiter, .{ .recv = error.ConnectionResetByPeer }) catch unreachable;
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
                    self.scheduleCloseReset(waiter, .{ .recv = error.ConnectionResetByPeer }) catch unreachable;
                }
            }
        }
    }

    // ── Public submission methods (interface) ─────────────

    pub fn close(self: *SimIO, op: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .close = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.close_error_probability) {
            return self.schedule(c, .{ .close = error.InputOutput }, 0);
        }

        if (self.fd_paths.fetchRemove(op.fd)) |kv| {
            self.allocator.free(kv.value);
            _ = self.fd_dir_offsets.remove(op.fd);
            try self.closed_fds.put(op.fd, {});
            return self.schedule(c, .{ .close = {} }, 0);
        }

        if (self.slotForFd(op.fd)) |_| {
            self.closeSocket(op.fd);
            try self.closed_fds.put(op.fd, {});
            return self.schedule(c, .{ .close = {} }, 0);
        }

        if (self.file_state.contains(op.fd)) {
            try self.closed_fds.put(op.fd, {});
            return self.schedule(c, .{ .close = {} }, 0);
        }

        return self.schedule(c, .{ .close = error.BadFileDescriptor }, 0);
    }

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
        // Fault injection is the higher-priority signal: when both a
        // registered content map and a fault probability fire, the fault
        // wins. BUGGIFY tests that inject `read_error_probability == 1.0`
        // against a fd with `setFileBytes` need to see `error.InputOutput`,
        // not the registered bytes.
        if (r.float(f32) < self.config.faults.read_error_probability) {
            return self.schedule(c, .{ .read = error.InputOutput }, 0);
        }

        // If content was registered via setFileBytes (or grown by prior
        // writes), return the union of durable+pending at the requested
        // offset. Otherwise fall through to the legacy zero-byte
        // success for callers that don't care about disk content.
        const maybe_sf = self.fileStatePtrForFd(op.fd) catch |err| {
            return self.schedule(c, .{ .read = err }, 0);
        };
        if (maybe_sf) |sf| {
            const off: usize = @intCast(op.offset);
            const n = sf.readUnion(off, op.buf);
            return self.schedule(c, .{ .read = n }, 0);
        }

        return self.schedule(c, .{ .read = @as(usize, 0) }, 0);
    }

    pub fn write(self: *SimIO, op: ifc.WriteOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .write = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.write_error_probability) {
            return self.schedule(c, .{ .write = error.NoSpaceLeft }, self.config.faults.write_latency_ns);
        }

        // Apply the write into the per-fd pending layer (auto-creating
        // the SimFile entry if missing). This models pagecache acceptance
        // — bytes are visible to subsequent reads but are NOT durable
        // until an fsync CQE lands. `crash()` will drop them.
        //
        // We populate the SimFile even when the caller has not previously
        // called `setFileBytes` so that a fully-write-driven test still
        // exercises the durability model end-to-end.
        const off: usize = @intCast(op.offset);
        const end: usize = off + op.buf.len;
        const sf = self.getOrPutFileStateForFd(op.fd) catch |err| {
            // Out of memory while creating the entry — surface as EIO
            // through the normal completion path so the caller's error
            // handling fires.
            const result_err = if (err == error.BadFileDescriptor) err else error.NoSpaceLeft;
            return self.schedule(c, .{ .write = result_err }, self.config.faults.write_latency_ns);
        };
        sf.ensurePending(self.allocator, end) catch {
            return self.schedule(c, .{ .write = error.NoSpaceLeft }, self.config.faults.write_latency_ns);
        };
        sf.extendPendingLen(end);
        @memcpy(sf.pending.items[off..end], op.buf);
        sf.markDirtyRange(off, end);

        // Real `write(2)` / `IORING_OP_WRITE` returns the number of bytes
        // accepted, normally the full buffer length on regular files.
        // Returning the full length lets `PieceStoreOf(SimIO).writePiece`
        // (which loops on short writes the same way `pwriteAll` did) treat
        // a successful write as "span done" instead of looping forever on
        // a 0-byte response.
        return self.schedule(c, .{ .write = op.buf.len }, self.config.faults.write_latency_ns);
    }

    pub fn fsync(self: *SimIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fsync = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.fsync_error_probability) {
            // Fault path: pending is left untouched, modelling a real
            // fsync that surfaced EIO before the journal flushed. The
            // bytes are still in pagecache but not durable; a subsequent
            // crash drops them.
            return self.schedule(c, .{ .fsync = error.InputOutput }, 0);
        }
        // Success: promote dirty pending bytes into durable. This is
        // the kernel-pagecache barrier the daemon is supposed to wait
        // for before recording resume-DB completions.
        const maybe_sf = self.fileStatePtrForFd(op.fd) catch |err| {
            return self.schedule(c, .{ .fsync = err }, 0);
        };
        if (maybe_sf) |sf| {
            sf.promotePending(self.allocator) catch {
                // Allocation failure during promotePending — surface as
                // EIO so the caller's error path runs.
                return self.schedule(c, .{ .fsync = error.InputOutput }, 0);
            };
        }
        return self.schedule(c, .{ .fsync = {} }, 0);
    }

    pub fn fallocate(self: *SimIO, op: ifc.FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .fallocate = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.fallocate_unsupported_probability) {
            return self.schedule(c, .{ .fallocate = error.OperationNotSupported }, 0);
        }
        if (r.float(f32) < self.config.faults.fallocate_error_probability) {
            return self.schedule(c, .{ .fallocate = error.NoSpaceLeft }, 0);
        }

        const keep_size = (op.mode & linux.FALLOC.FL_KEEP_SIZE) != 0;
        const zero_range = (op.mode & linux.FALLOC.FL_ZERO_RANGE) != 0;
        const modeled_bits: i32 =
            linux.FALLOC.FL_KEEP_SIZE |
            linux.FALLOC.FL_ZERO_RANGE;

        if ((op.mode & ~modeled_bits) != 0) {
            return self.schedule(c, .{ .fallocate = error.OperationNotSupported }, 0);
        }

        const off: usize = @intCast(op.offset);
        const len: usize = @intCast(op.len);

        // Supported visible behaviours:
        //   * mode 0 extends pending length with zero-filled bytes.
        //   * KEEP_SIZE allocates without changing visible bytes/length.
        //   * ZERO_RANGE zeros the byte range and extends length unless
        //     paired with KEEP_SIZE.
        //
        // Intentionally unsupported: PUNCH_HOLE, COLLAPSE_RANGE,
        // INSERT_RANGE, UNSHARE_RANGE, NO_HIDE_STALE, unknown bits, and
        // mixed range-edit modes whose sparse extent, shifting, or
        // shared-block semantics do not fit this byte-layer model.
        if (zero_range) {
            const sf = self.getOrPutFileStateForFd(op.fd) catch |err| {
                const result_err = if (err == error.BadFileDescriptor) err else error.NoSpaceLeft;
                return self.schedule(c, .{ .fallocate = result_err }, 0);
            };
            sf.fillPendingBytes(self.allocator, off, len, 0, keep_size) catch {
                return self.schedule(c, .{ .fallocate = error.NoSpaceLeft }, 0);
            };
        } else if (!keep_size) {
            const end = off + len;
            const sf = self.getOrPutFileStateForFd(op.fd) catch |err| {
                const result_err = if (err == error.BadFileDescriptor) err else error.NoSpaceLeft;
                return self.schedule(c, .{ .fallocate = result_err }, 0);
            };
            sf.extendPendingLen(end);
        }
        return self.schedule(c, .{ .fallocate = {} }, 0);
    }

    /// Truncate updates the simulated visible file length, but the
    /// metadata is pending until `fsync` promotes it. A later `crash()`
    /// reverts the length to the durable layer.
    pub fn truncate(self: *SimIO, op: ifc.TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .truncate = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.truncate_error_probability) {
            return self.schedule(c, .{ .truncate = error.InputOutput }, 0);
        }
        const sf = self.getOrPutFileStateForFd(op.fd) catch |err| {
            const result_err = if (err == error.BadFileDescriptor) err else error.InputOutput;
            return self.schedule(c, .{ .truncate = result_err }, 0);
        };
        sf.markPendingLen(@intCast(op.length));
        return self.schedule(c, .{ .truncate = {} }, 0);
    }

    /// Sim splice models a successful "all bytes transferred" completion
    /// (`op.len`). The fault knob delivers `error.InputOutput`. SimIO
    /// doesn't model on-disk file content, so the actual data movement
    /// is observably opaque — only the byte count and the error path
    /// matter for state-machine tests.
    pub fn splice(self: *SimIO, op: ifc.SpliceOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .splice = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.splice_error_probability) {
            return self.schedule(c, .{ .splice = error.InputOutput }, 0);
        }
        return self.schedule(c, .{ .splice = op.len }, 0);
    }

    /// Sim copy_file_range copies visible source bytes into the
    /// destination's pending layer when the source fd is content-aware.
    /// The copied bytes are readable immediately but need `fsync` to
    /// become durable; `crash()` drops them like write-accepted bytes.
    /// If the source fd has no SimFile state, preserve the legacy opaque
    /// full-count success used by state-machine tests that do not inspect
    /// file content.
    pub fn copy_file_range(self: *SimIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .copy_file_range = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.copy_file_range_error_probability) {
            return self.schedule(c, .{ .copy_file_range = error.InputOutput }, 0);
        }

        const src = (self.fileStatePtrForFd(op.in_fd) catch |err| {
            return self.schedule(c, .{ .copy_file_range = err }, 0);
        }) orelse {
            return self.schedule(c, .{ .copy_file_range = op.len }, 0);
        };

        const in_off: usize = @intCast(op.in_offset);
        const visible = src.visibleLen();
        if (in_off >= visible or op.len == 0) {
            return self.schedule(c, .{ .copy_file_range = @as(usize, 0) }, 0);
        }

        const copied_len = @min(op.len, visible - in_off);
        const scratch = self.allocator.alloc(u8, copied_len) catch {
            return self.schedule(c, .{ .copy_file_range = error.NoSpaceLeft }, 0);
        };
        defer self.allocator.free(scratch);

        const read_n = src.readUnion(in_off, scratch);
        assert(read_n == copied_len);

        const out_off: usize = @intCast(op.out_offset);
        const dst = self.getOrPutFileStateForFd(op.out_fd) catch |err| {
            const result_err = if (err == error.BadFileDescriptor) err else error.NoSpaceLeft;
            return self.schedule(c, .{ .copy_file_range = result_err }, 0);
        };
        dst.writePendingBytes(self.allocator, out_off, scratch) catch {
            return self.schedule(c, .{ .copy_file_range = error.NoSpaceLeft }, 0);
        };

        return self.schedule(c, .{ .copy_file_range = copied_len }, 0);
    }

    pub fn openat(self: *SimIO, op: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .openat = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.openat_error_probability) {
            return self.schedule(c, .{ .openat = error.InputOutput }, 0);
        }

        const path = self.resolveAt(op.dir_fd, op.path) catch |err| {
            return self.schedule(c, .{ .openat = err }, 0);
        };
        defer self.allocator.free(path);

        const kind = self.fs_nodes.get(path);
        if (kind == null) {
            if (!op.flags.CREAT) return self.schedule(c, .{ .openat = error.FileNotFound }, 0);
            if (!self.hasDir(parentPath(path))) return self.schedule(c, .{ .openat = error.FileNotFound }, 0);
            self.putFsNode(path, .file) catch {
                return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
            };
            _ = self.getOrPutPathFileState(path) catch {
                return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
            };
        } else if (op.flags.CREAT and op.flags.EXCL) {
            return self.schedule(c, .{ .openat = error.PathAlreadyExists }, 0);
        } else if (op.flags.DIRECTORY and kind.? != .dir) {
            return self.schedule(c, .{ .openat = error.NotDir }, 0);
        } else if (kind.? == .file and op.flags.TRUNC) {
            const sf = self.getOrPutPathFileState(path) catch {
                return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
            };
            self.resetFileBytes(sf, "") catch {
                return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
            };
        }

        const fd = self.nextSyntheticFd();
        _ = self.closed_fds.remove(fd);
        const owned = self.allocator.dupe(u8, path) catch {
            return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
        };
        self.fd_paths.put(fd, owned) catch {
            self.allocator.free(owned);
            return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
        };
        if (self.fs_nodes.get(path)) |opened_kind| {
            if (opened_kind == .dir) {
                self.fd_dir_offsets.put(fd, 0) catch {
                    _ = self.fd_paths.remove(fd);
                    self.allocator.free(owned);
                    return self.schedule(c, .{ .openat = error.NoSpaceLeft }, 0);
                };
            }
        }
        return self.schedule(c, .{ .openat = fd }, 0);
    }

    pub fn mkdirat(self: *SimIO, op: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .mkdirat = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.mkdirat_error_probability) {
            return self.schedule(c, .{ .mkdirat = error.InputOutput }, 0);
        }

        const path = self.resolveAt(op.dir_fd, op.path) catch |err| {
            return self.schedule(c, .{ .mkdirat = err }, 0);
        };
        defer self.allocator.free(path);
        if (self.fs_nodes.contains(path)) return self.schedule(c, .{ .mkdirat = error.PathAlreadyExists }, 0);
        if (!self.hasDir(parentPath(path))) return self.schedule(c, .{ .mkdirat = error.FileNotFound }, 0);
        self.putFsNode(path, .dir) catch {
            return self.schedule(c, .{ .mkdirat = error.NoSpaceLeft }, 0);
        };
        return self.schedule(c, .{ .mkdirat = {} }, 0);
    }

    pub fn renameat(self: *SimIO, op: ifc.RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .renameat = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.renameat_error_probability) {
            return self.schedule(c, .{ .renameat = error.InputOutput }, 0);
        }
        if (self.rng.random().float(f32) < self.config.faults.renameat_exdev_probability) {
            return self.schedule(c, .{ .renameat = error.RenameAcrossMountPoints }, 0);
        }
        if (op.flags != 0) return self.schedule(c, .{ .renameat = error.OperationNotSupported }, 0);

        const old_path = self.resolveAt(op.old_dir_fd, op.old_path) catch |err| {
            return self.schedule(c, .{ .renameat = err }, 0);
        };
        defer self.allocator.free(old_path);
        const new_path = self.resolveAt(op.new_dir_fd, op.new_path) catch |err| {
            return self.schedule(c, .{ .renameat = err }, 0);
        };
        defer self.allocator.free(new_path);

        const kind = self.fs_nodes.get(old_path) orelse {
            return self.schedule(c, .{ .renameat = error.FileNotFound }, 0);
        };
        if (!self.hasDir(parentPath(new_path))) return self.schedule(c, .{ .renameat = error.FileNotFound }, 0);

        self.removeFsNode(old_path);
        self.putFsNode(new_path, kind) catch {
            return self.schedule(c, .{ .renameat = error.NoSpaceLeft }, 0);
        };
        self.movePathFileState(old_path, new_path) catch {
            return self.schedule(c, .{ .renameat = error.NoSpaceLeft }, 0);
        };
        return self.schedule(c, .{ .renameat = {} }, 0);
    }

    pub fn unlinkat(self: *SimIO, op: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .unlinkat = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.unlinkat_error_probability) {
            return self.schedule(c, .{ .unlinkat = error.InputOutput }, 0);
        }

        const path = self.resolveAt(op.dir_fd, op.path) catch |err| {
            return self.schedule(c, .{ .unlinkat = err }, 0);
        };
        defer self.allocator.free(path);
        const kind = self.fs_nodes.get(path) orelse {
            return self.schedule(c, .{ .unlinkat = error.FileNotFound }, 0);
        };
        const remove_dir = (op.flags & posix.AT.REMOVEDIR) != 0;
        if (remove_dir and kind != .dir) return self.schedule(c, .{ .unlinkat = error.NotDir }, 0);
        if (!remove_dir and kind == .dir) return self.schedule(c, .{ .unlinkat = error.IsDir }, 0);
        if (remove_dir and self.hasChild(path)) return self.schedule(c, .{ .unlinkat = error.DirNotEmpty }, 0);

        self.removeFsNode(path);
        if (kind == .file) self.removePathFileState(path);
        return self.schedule(c, .{ .unlinkat = {} }, 0);
    }

    pub fn statx(self: *SimIO, op: ifc.StatxOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .statx = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.statx_error_probability) {
            return self.schedule(c, .{ .statx = error.InputOutput }, 0);
        }

        const path = self.resolveAt(op.dir_fd, op.path) catch |err| {
            return self.schedule(c, .{ .statx = err }, 0);
        };
        defer self.allocator.free(path);

        const kind = self.fs_nodes.get(path) orelse {
            return self.schedule(c, .{ .statx = error.FileNotFound }, 0);
        };

        op.buf.* = std.mem.zeroes(linux.Statx);
        op.buf.mask = op.mask & linux.STATX_BASIC_STATS;
        op.buf.blksize = 4096;
        op.buf.nlink = 1;
        op.buf.mode = switch (kind) {
            .file => linux.S.IFREG | 0o644,
            .dir => linux.S.IFDIR | 0o755,
        };
        op.buf.size = if (kind == .file)
            @intCast(if (self.path_file_state.getPtr(path)) |sf| sf.visibleLen() else 0)
        else
            0;
        return self.schedule(c, .{ .statx = {} }, 0);
    }

    pub fn getdents(self: *SimIO, op: ifc.GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .getdents = op }, ud, cb);
        const r = self.rng.random();
        if (r.float(f32) < self.config.faults.getdents_error_probability) {
            return self.schedule(c, .{ .getdents = error.InputOutput }, 0);
        }

        const dir_path = self.fd_paths.get(op.fd) orelse {
            return self.schedule(c, .{ .getdents = error.BadFileDescriptor }, 0);
        };
        if (!self.hasDir(dir_path)) {
            return self.schedule(c, .{ .getdents = error.NotDir }, 0);
        }

        const start_index = self.fd_dir_offsets.get(op.fd) orelse 0;
        var seen: usize = 0;
        var emitted: usize = 0;
        var out: usize = 0;
        var iter = self.fs_nodes.iterator();
        while (iter.next()) |entry| {
            const child_path = entry.key_ptr.*;
            const name = directChildName(dir_path, child_path) orelse continue;
            if (seen < start_index) {
                seen += 1;
                continue;
            }

            const next = ifc.appendDirent64(
                op.buf,
                out,
                @as(u64, 1 + seen),
                @as(u64, seen + 1),
                direntType(entry.value_ptr.*),
                name,
            ) orelse {
                if (out == 0) {
                    return self.schedule(c, .{ .getdents = error.InvalidArgument }, 0);
                }
                break;
            };
            out = next;
            seen += 1;
            emitted += 1;
        }

        self.fd_dir_offsets.put(op.fd, start_index + emitted) catch {
            return self.schedule(c, .{ .getdents = error.NoSpaceLeft }, 0);
        };
        return self.schedule(c, .{ .getdents = out }, 0);
    }

    pub fn socket(self: *SimIO, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .socket = op }, ud, cb);
        // Consume a pre-prepared fd if any, so tests can script which
        // fd the caller's next `socket()` resolves to. Falls back to a
        // fresh synthetic fd (the legacy behaviour) when the queue is
        // empty.
        const fd = if (self.prepared_socket_fds.items.len > 0)
            self.prepared_socket_fds.orderedRemove(0)
        else
            self.nextSyntheticFd();
        return self.schedule(c, .{ .socket = fd }, 0);
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
            .ready_tick = 0,
            .seq = seq,
            .completion = c,
            .result = .{ .accept = error.WouldBlock },
        });
    }

    /// SimIO doesn't model real socket binding, so bind succeeds
    /// inline. No fault knob today — listener bring-up paths exercise
    /// this once at startup; the simulator's interesting failures
    /// happen on the wire (recv/send/connect), not on local-only ops
    /// like bind/listen/setsockopt.
    pub fn bind(self: *SimIO, op: ifc.BindOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .bind = op }, ud, cb);
        return self.schedule(c, .{ .bind = {} }, 0);
    }

    /// Synchronous-success completion. See `bind`.
    pub fn listen(self: *SimIO, op: ifc.ListenOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .listen = op }, ud, cb);
        return self.schedule(c, .{ .listen = {} }, 0);
    }

    /// Synchronous-success completion. See `bind`.
    pub fn setsockopt(self: *SimIO, op: ifc.SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .setsockopt = op }, ud, cb);
        return self.schedule(c, .{ .setsockopt = {} }, 0);
    }

    pub fn timeout(self: *SimIO, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .timeout = op }, ud, cb);
        return self.schedule(c, .{ .timeout = {} }, op.ns);
    }

    pub fn poll(self: *SimIO, op: ifc.PollOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.armCompletion(c, .{ .poll = op }, ud, cb);
        return self.schedule(c, .{ .poll = @as(u32, 0) }, 0);
    }

    /// Result of a BUGGIFY fault injection — describes the op kind that
    /// got its result mutated, for telemetry/logging on the simulator side.
    pub const BuggifyHit = struct {
        op_tag: std.meta.Tag(Operation),
    };

    /// Replace the result of a randomly-chosen in-flight heap entry with
    /// a fault appropriate to its op type. Returns the op kind whose
    /// result was overridden so the simulator can log "fault injected:
    /// <op>", or `null` if no schedulable entry was available.
    ///
    /// Heap order is unchanged (deadline isn't touched), so the entry
    /// fires at its original time but with the fault result. Parked
    /// completions are not eligible (they're not in the heap), and the
    /// `accept` sentinel deadline (`u64.maxInt`) is skipped.
    pub fn injectRandomFault(self: *SimIO, rng: *std.Random.DefaultPrng) ?BuggifyHit {
        if (self.pending_len == 0) return null;
        // Probe a few entries — the heap may contain non-schedulable
        // sentinel entries (parked accept), so skip those.
        var probes: u32 = 0;
        while (probes < 8) : (probes += 1) {
            const idx = rng.random().uintLessThan(u32, self.pending_len);
            const entry = &self.pending[idx];
            if (entry.deadline_ns == std.math.maxInt(u64)) {
                probes += 1;
                continue;
            }
            const op_tag = std.meta.activeTag(entry.completion.op);
            entry.result = buggifyResultFor(entry.completion.op);
            return .{ .op_tag = op_tag };
        }
        return null;
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

/// Per-op fault chosen by BUGGIFY. The errors are picked to match what
/// the kernel would surface for the corresponding syscall under stress
/// (transient network failure, EIO on disk, ENOSPC on write, etc.).
fn buggifyResultFor(op: Operation) Result {
    return switch (op) {
        .none => .{ .timeout = error.UnknownOperation },
        .recv => .{ .recv = error.ConnectionResetByPeer },
        .send => .{ .send = error.BrokenPipe },
        .recvmsg => .{ .recvmsg = error.ConnectionResetByPeer },
        .sendmsg => .{ .sendmsg = error.BrokenPipe },
        .read => .{ .read = error.InputOutput },
        .write => .{ .write = error.NoSpaceLeft },
        .fsync => .{ .fsync = error.InputOutput },
        .close => .{ .close = error.InputOutput },
        .fallocate => .{ .fallocate = error.NoSpaceLeft },
        .truncate => .{ .truncate = error.InputOutput },
        .openat => .{ .openat = error.InputOutput },
        .mkdirat => .{ .mkdirat = error.InputOutput },
        .renameat => .{ .renameat = error.InputOutput },
        .unlinkat => .{ .unlinkat = error.InputOutput },
        .statx => .{ .statx = error.InputOutput },
        .getdents => .{ .getdents = error.InputOutput },
        .splice => .{ .splice = error.InputOutput },
        .copy_file_range => .{ .copy_file_range = error.InputOutput },
        .socket => .{ .socket = error.ProcessFdQuotaExceeded },
        .connect => .{ .connect = error.ConnectionRefused },
        .accept => .{ .accept = error.ConnectionAborted },
        // bind/listen/setsockopt aren't naturally fault-prone in the
        // simulator (no I/O wait, no flaky-network surface). Pick
        // plausible local-failure errnos so callers' switch arms
        // exercise the error branch when BUGGIFY hits.
        .bind => .{ .bind = error.AddressInUse },
        .listen => .{ .listen = error.AddressInUse },
        .setsockopt => .{ .setsockopt = error.InvalidArgument },
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
    try io.tick(0);
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
    var completions: [N]Completion = @splat(Completion{});

    const OrderLog = struct {
        slots: [N]u32 = @splat(0),
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
    try io.tick(0);

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
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .connect => |r| try r,
        else => try testing.expect(false),
    }
}

test "SimIO PendingQueueFull when capacity exhausted" {
    var io = try SimIO.init(testing.allocator, .{ .pending_capacity = 4 });
    defer io.deinit();

    var completions: [5]Completion = @splat(Completion{});
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

    try io.tick(0);

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
    try io.tick(0);

    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .cancel => |r| try testing.expectError(error.OperationNotFound, r),
        else => try testing.expect(false),
    }
}

test "SimIO bind/listen/setsockopt deliver synchronous-success" {
    // SimIO doesn't model real socket binding — bind/listen/setsockopt
    // succeed inline through `schedule(.., 0)` and the result fires on
    // the next `advance(1)`. This mirrors the truncate path: useful as a
    // no-fault stub so listener bring-up code under test exercises the
    // happy path without needing a real ring.
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var bind_c = Completion{};
    var listen_c = Completion{};
    var sso_c = Completion{};
    var bind_ctx = TestCtx{};
    var listen_ctx = TestCtx{};
    var sso_ctx = TestCtx{};

    try io.bind(.{ .fd = 7, .addr = addr }, &bind_c, &bind_ctx, testCallback);
    try io.listen(.{ .fd = 7, .backlog = 8 }, &listen_c, &listen_ctx, testCallback);
    const enable = std.mem.toBytes(@as(c_int, 1));
    try io.setsockopt(.{
        .fd = 7,
        .level = 1, // SOL_SOCKET (Linux)
        .optname = 2, // SO_REUSEADDR (Linux)
        .optval = &enable,
    }, &sso_c, &sso_ctx, testCallback);

    try io.advance(1);
    try testing.expect(bind_ctx.last_result != null);
    try testing.expect(listen_ctx.last_result != null);
    try testing.expect(sso_ctx.last_result != null);
    switch (bind_ctx.last_result.?) {
        .bind => |r| try r,
        else => try testing.expect(false),
    }
    switch (listen_ctx.last_result.?) {
        .listen => |r| try r,
        else => try testing.expect(false),
    }
    switch (sso_ctx.last_result.?) {
        .setsockopt => |r| r catch |e| return e,
        else => try testing.expect(false),
    }
}

test "SimIO bind cancellation delivers OperationCanceled" {
    // Submit `bind` (deadline 0) and cancel it before `advance` runs.
    // The cancel pulls the entry out of the heap and delivers
    // OperationCanceled on the target completion via cancelResultFor —
    // exercises the bind arm of that switch.
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var target_c = Completion{};
    var cancel_c = Completion{};
    var target_ctx = TestCtx{};
    var cancel_ctx = TestCtx{};

    try io.bind(.{ .fd = 9, .addr = addr }, &target_c, &target_ctx, testCallback);
    try io.cancel(.{ .target = &target_c }, &cancel_c, &cancel_ctx, testCallback);
    try io.advance(1);

    switch (target_ctx.last_result.?) {
        .bind => |r| try testing.expectError(error.OperationCanceled, r),
        else => try testing.expect(false),
    }
    switch (cancel_ctx.last_result.?) {
        .cancel => |r| try r,
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

test "SimIO closeSocket can delay parked recv reset by ticks" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{
            .delayed_close_cqe_min_ticks = 1,
            .delayed_close_cqe_max_ticks = 1,
        },
    });
    defer io.deinit();

    const fds = try io.createSocketpair();
    var buf: [1]u8 = undefined;
    var c = Completion{};
    var ctx = TestCtx{};

    try io.recv(.{ .fd = fds[1], .buf = &buf }, &c, &ctx, testCallback);
    io.closeSocket(fds[0]);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .recv => |r| try testing.expectError(error.ConnectionResetByPeer, r),
        else => try testing.expect(false),
    }
}

test "SimIO CQE reorder window defers otherwise ready completions by ticks" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{
            .cqe_reorder_window_ticks_min = 1,
            .cqe_reorder_window_ticks_max = 1,
        },
    });
    defer io.deinit();

    var c = Completion{};
    var ctx = TestCtx{};
    try io.timeout(.{ .ns = 0 }, &c, &ctx, testCallback);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 0), ctx.calls);

    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

const std = @import("std");
const posix = std.posix;
const HugePageCache = @import("../storage/huge_page_cache.zig").HugePageCache;

pub const PieceBuffer = struct {
    buf: []u8,
    storage: []u8 = &.{},
    from_pool: bool = false,
    ref_count: u32 = 1,
    next_free: ?*PieceBuffer = null,
};

pub const PieceBufferPool = struct {
    const retained_heap_limit: usize = 64 * 1024 * 1024;
    const max_buffers_per_class: u16 = 8;
    const class_sizes = [_]usize{
        16 * 1024,
        64 * 1024,
        256 * 1024,
        512 * 1024,
        1024 * 1024,
        2 * 1024 * 1024,
        4 * 1024 * 1024,
        8 * 1024 * 1024,
    };

    const RetainedClass = struct {
        head: ?*PieceBuffer = null,
        count: u16 = 0,
    };

    retained_heap_bytes: usize = 0,
    retained_heap: std.AutoHashMapUnmanaged(usize, RetainedClass) = .empty,
    free_wrappers: ?*PieceBuffer = null,

    pub fn acquire(
        self: *PieceBufferPool,
        allocator: std.mem.Allocator,
        huge_page_cache: ?*HugePageCache,
        size: usize,
    ) !*PieceBuffer {
        const storage_size = preferredStorageSize(size);
        if (huge_page_cache) |hpc| {
            if (hpc.alloc(storage_size)) |storage| {
                const piece_buffer = try self.acquireWrapper(allocator);
                piece_buffer.* = .{
                    .buf = storage[0..size],
                    .storage = storage,
                    .from_pool = true,
                };
                return piece_buffer;
            }
        }

        if (self.acquireRetained(storage_size)) |piece_buffer| {
            piece_buffer.* = .{
                .buf = piece_buffer.storage[0..size],
                .storage = piece_buffer.storage,
                .from_pool = false,
            };
            return piece_buffer;
        }

        const storage = try allocator.alloc(u8, storage_size);
        errdefer allocator.free(storage);

        const piece_buffer = try self.acquireWrapper(allocator);
        piece_buffer.* = .{
            .buf = storage[0..size],
            .storage = storage,
            .from_pool = false,
        };
        return piece_buffer;
    }

    pub fn release(
        self: *PieceBufferPool,
        allocator: std.mem.Allocator,
        huge_page_cache: ?*HugePageCache,
        piece_buffer: *PieceBuffer,
    ) void {
        if (piece_buffer.from_pool) {
            if (huge_page_cache) |hpc| hpc.free(piece_buffer.storage);
            self.recycleWrapper(piece_buffer);
            return;
        }

        if (self.retainHeapBuffer(allocator, piece_buffer)) return;

        allocator.free(piece_buffer.storage);
        self.recycleWrapper(piece_buffer);
    }

    pub fn deinit(self: *PieceBufferPool, allocator: std.mem.Allocator) void {
        var retained_it = self.retained_heap.iterator();
        while (retained_it.next()) |entry| {
            var head = entry.value_ptr.head;
            while (head) |piece_buffer| {
                const next = piece_buffer.next_free;
                allocator.free(piece_buffer.storage);
                allocator.destroy(piece_buffer);
                head = next;
            }
        }
        self.retained_heap.deinit(allocator);

        var wrappers = self.free_wrappers;
        while (wrappers) |piece_buffer| {
            wrappers = piece_buffer.next_free;
            allocator.destroy(piece_buffer);
        }
        self.* = .{};
    }

    fn acquireWrapper(self: *PieceBufferPool, allocator: std.mem.Allocator) !*PieceBuffer {
        if (self.free_wrappers) |piece_buffer| {
            self.free_wrappers = piece_buffer.next_free;
            piece_buffer.next_free = null;
            return piece_buffer;
        }
        return allocator.create(PieceBuffer);
    }

    fn recycleWrapper(self: *PieceBufferPool, piece_buffer: *PieceBuffer) void {
        piece_buffer.next_free = self.free_wrappers;
        self.free_wrappers = piece_buffer;
    }

    fn acquireRetained(self: *PieceBufferPool, storage_size: usize) ?*PieceBuffer {
        const retained = self.retained_heap.getPtr(storage_size) orelse return null;
        const piece_buffer = retained.head orelse return null;
        retained.head = piece_buffer.next_free;
        piece_buffer.next_free = null;
        retained.count -= 1;
        self.retained_heap_bytes -= piece_buffer.storage.len;
        return piece_buffer;
    }

    fn retainHeapBuffer(self: *PieceBufferPool, allocator: std.mem.Allocator, piece_buffer: *PieceBuffer) bool {
        const storage = piece_buffer.storage;
        if (self.retained_heap_bytes + storage.len > retained_heap_limit) return false;

        const gop = self.retained_heap.getOrPut(allocator, storage.len) catch return false;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        if (gop.value_ptr.count >= max_buffers_per_class) return false;

        piece_buffer.buf = storage;
        piece_buffer.next_free = gop.value_ptr.head;
        gop.value_ptr.head = piece_buffer;
        gop.value_ptr.count += 1;
        self.retained_heap_bytes += storage.len;
        return true;
    }

    pub fn preferredStorageSize(size: usize) usize {
        for (class_sizes) |class_size| {
            if (size <= class_size) return class_size;
        }
        return size;
    }
};

pub const VectoredSendState = struct {
    backing: []align(@alignOf(posix.iovec_const)) u8,
    backing_capacity: usize = 0,
    pool_class: u8 = std.math.maxInt(u8),
    next_free: ?*VectoredSendState = null,
    headers: [][13]u8,
    iovecs: []posix.iovec_const,
    msg: posix.msghdr_const,
    piece_buffers: []*PieceBuffer,
    iov_index: usize = 0,

    pub fn advance(self: *VectoredSendState, bytes_sent: usize) bool {
        var remaining = bytes_sent;
        while (remaining > 0 and self.iov_index < self.iovecs.len) {
            const iov = &self.iovecs[self.iov_index];
            if (remaining < iov.len) {
                iov.base += remaining;
                iov.len -= remaining;
                remaining = 0;
                break;
            }
            remaining -= iov.len;
            self.iov_index += 1;
        }

        self.msg.iov = self.iovecs.ptr + self.iov_index;
        self.msg.iovlen = self.iovecs.len - self.iov_index;
        return self.iov_index < self.iovecs.len;
    }
};

pub const vectored_send_backing_align = @max(
    @alignOf(VectoredSendState),
    @max(@alignOf([13]u8), @max(@alignOf(posix.iovec_const), @alignOf(*PieceBuffer))),
);

pub const VectoredSendLayout = struct {
    total_bytes: usize,
    headers_offset: usize,
    iovecs_offset: usize,
    refs_offset: usize,
};

pub const VectoredSendPool = struct {
    const retained_limit: usize = 256 * 1024;
    const max_blocks_per_class: u16 = 16;
    const invalid_class: u8 = std.math.maxInt(u8);
    const class_capacities = [_]usize{ 1, 2, 4, 8, 16, 32, 64 };

    const RetainedClass = struct {
        head: ?*VectoredSendState = null,
        count: u16 = 0,
    };

    retained_bytes: usize = 0,
    classes: [class_capacities.len]RetainedClass = [_]RetainedClass{.{}} ** class_capacities.len,

    pub fn acquire(self: *VectoredSendPool, allocator: std.mem.Allocator, batch_len: usize) !*VectoredSendState {
        const selection = selectClass(batch_len);
        const layout = vectoredSendLayout(selection.capacity);

        if (selection.class_index) |class_index| {
            const retained = &self.classes[class_index];
            if (retained.head) |state| {
                retained.head = state.next_free;
                retained.count -= 1;
                self.retained_bytes -= state.backing.len;
                state.backing_capacity = selection.capacity;
                state.pool_class = @intCast(class_index);
                state.next_free = null;
                return state;
            }
        }

        const backing = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(vectored_send_backing_align), layout.total_bytes);
        const state: *VectoredSendState = @ptrCast(@alignCast(backing.ptr));
        state.backing = backing;
        state.backing_capacity = selection.capacity;
        state.pool_class = if (selection.class_index) |class_index| @intCast(class_index) else invalid_class;
        state.next_free = null;
        return state;
    }

    pub fn release(self: *VectoredSendPool, allocator: std.mem.Allocator, state: *VectoredSendState) void {
        if (state.pool_class == invalid_class) {
            allocator.free(state.backing);
            return;
        }

        const class_index: usize = state.pool_class;
        const retained = &self.classes[class_index];
        if (retained.count >= max_blocks_per_class or self.retained_bytes + state.backing.len > retained_limit) {
            allocator.free(state.backing);
            return;
        }

        state.next_free = retained.head;
        retained.head = state;
        retained.count += 1;
        self.retained_bytes += state.backing.len;
    }

    pub fn deinit(self: *VectoredSendPool, allocator: std.mem.Allocator) void {
        for (&self.classes) |*retained| {
            var head = retained.head;
            while (head) |state| {
                const next = state.next_free;
                allocator.free(state.backing);
                head = next;
            }
            retained.* = .{};
        }
        self.* = .{};
    }

    fn selectClass(batch_len: usize) struct { capacity: usize, class_index: ?usize } {
        for (class_capacities, 0..) |capacity, idx| {
            if (batch_len <= capacity) return .{ .capacity = capacity, .class_index = idx };
        }
        return .{ .capacity = batch_len, .class_index = null };
    }
};

pub fn vectoredSendLayout(block_capacity: usize) VectoredSendLayout {
    const state_bytes = @sizeOf(VectoredSendState);
    const headers_bytes = @sizeOf([13]u8) * block_capacity;
    const iovecs_bytes = @sizeOf(posix.iovec_const) * block_capacity * 2;
    const refs_bytes = @sizeOf(*PieceBuffer) * block_capacity;

    var total_bytes: usize = 0;
    const state_offset = std.mem.alignForward(usize, total_bytes, @alignOf(VectoredSendState));
    total_bytes = state_offset + state_bytes;
    const headers_offset = std.mem.alignForward(usize, total_bytes, @alignOf([13]u8));
    total_bytes = headers_offset + headers_bytes;
    const iovecs_offset = std.mem.alignForward(usize, total_bytes, @alignOf(posix.iovec_const));
    total_bytes = iovecs_offset + iovecs_bytes;
    const refs_offset = std.mem.alignForward(usize, total_bytes, @alignOf(*PieceBuffer));
    total_bytes = refs_offset + refs_bytes;

    return .{
        .total_bytes = total_bytes,
        .headers_offset = headers_offset,
        .iovecs_offset = iovecs_offset,
        .refs_offset = refs_offset,
    };
}

pub const PendingSend = struct {
    sent: usize = 0,
    slot: u16 = 0,
    /// Unique ID for matching CQEs to the correct PendingSend when
    /// multiple sends are in-flight for the same slot. Also used to
    /// disambiguate after slot reuse — a stale CQE for an old PendingSend
    /// whose slot has been re-allocated will not find a matching
    /// (slot, send_id) pair in the active list.
    /// `send_id == 0` is a sentinel meaning "this pool slot is free".
    send_id: u32 = 0,
    storage: union(enum) {
        /// Pool-free sentinel. Active PendingSends have either `owned`
        /// or `vectored`; `free` is only set by `PendingSendPool.release`.
        /// The `next_free` u32 forms the free-list (`PendingSendPool.free_head`
        /// chases this through inactive slots).
        free: u32,
        owned: struct {
            buf: []u8,
            small_slot: ?u16 = null,
        },
        vectored: *VectoredSendState,
    } = .{ .free = 0 },
    /// Caller-owned completion driving the in-flight send for this
    /// PendingSend. The PendingSend's address is the kernel's user_data,
    /// so it must be stable for the lifetime of the send. Achieved via
    /// `PendingSendPool` allocating a fixed-size backing array at init
    /// — pool slot addresses never move.
    completion: @import("io_interface.zig").Completion = .{},
};

/// Fixed-size pool of `PendingSend` slots with a free-list head.
/// Pre-allocated once at EventLoop init; per-send claim/release is
/// O(1) and zero-alloc on the hot path. The kernel sees stable
/// `Completion*` addresses because pool slots never move.
///
/// Sized to `max_connections * max_in_flight_per_peer` at init —
/// generous enough to absorb the worst-case pipeline-refill +
/// keepalive + piece-response burst across all peers without
/// exhausting the pool. If the pool *does* exhaust, callers fall
/// back to `error.OutOfMemory` and the daemon drops the send (peer
/// will be retried on the next refill cycle).
pub const PendingSendPool = struct {
    storage: []PendingSend,
    free_head: ?u32, // index into storage; null if exhausted
    in_use: u32 = 0,

    /// Sentinel for "no next free" (used at the tail of the free list).
    const free_tail: u32 = std.math.maxInt(u32);

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !PendingSendPool {
        const slots = try allocator.alloc(PendingSend, capacity);
        // Build the initial free list: slot 0 -> 1 -> 2 -> ... -> N-1 -> tail.
        for (slots, 0..) |*s, i| {
            const next: u32 = if (i + 1 < capacity) @intCast(i + 1) else free_tail;
            s.* = .{ .storage = .{ .free = next } };
        }
        return .{
            .storage = slots,
            .free_head = if (capacity > 0) 0 else null,
        };
    }

    pub fn deinit(self: *PendingSendPool, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn claim(self: *PendingSendPool) ?*PendingSend {
        const head = self.free_head orelse return null;
        const slot = &self.storage[head];
        const next = switch (slot.storage) {
            .free => |n| n,
            else => unreachable, // slot in free-list head must be free
        };
        self.free_head = if (next == free_tail) null else next;
        self.in_use += 1;
        // Caller will overwrite `storage` to its active variant and reset
        // `sent` / `slot` / `send_id` / `completion`.
        return slot;
    }

    pub fn release(self: *PendingSendPool, ps: *PendingSend) void {
        const base = @intFromPtr(self.storage.ptr);
        const offset = @intFromPtr(ps) - base;
        const idx: u32 = @intCast(offset / @sizeOf(PendingSend));
        std.debug.assert(idx < self.storage.len);
        const next: u32 = if (self.free_head) |h| h else free_tail;
        ps.* = .{ .storage = .{ .free = next } };
        self.free_head = idx;
        std.debug.assert(self.in_use > 0);
        self.in_use -= 1;
    }
};

test "PendingSendPool claims and releases slots in LIFO order" {
    var pool = try PendingSendPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), pool.in_use);
    const a = pool.claim() orelse return error.PoolExhausted;
    const b = pool.claim() orelse return error.PoolExhausted;
    const c = pool.claim() orelse return error.PoolExhausted;
    try std.testing.expectEqual(@as(u32, 3), pool.in_use);

    // LIFO: release c then claim should return c again.
    pool.release(c);
    try std.testing.expectEqual(@as(u32, 2), pool.in_use);
    const c2 = pool.claim() orelse return error.PoolExhausted;
    try std.testing.expectEqual(c, c2);

    pool.release(a);
    pool.release(b);
    pool.release(c2);
    try std.testing.expectEqual(@as(u32, 0), pool.in_use);
}

test "PendingSendPool returns null when exhausted" {
    var pool = try PendingSendPool.init(std.testing.allocator, 2);
    defer pool.deinit(std.testing.allocator);

    const a = pool.claim() orelse return error.PoolExhausted;
    const b = pool.claim() orelse return error.PoolExhausted;
    try std.testing.expectEqual(@as(?*PendingSend, null), pool.claim());
    pool.release(a);
    pool.release(b);
}

pub const SmallSendPool = struct {
    storage: []u8,
    free: []bool,

    pub fn init(allocator: std.mem.Allocator, slot_count: usize, slot_capacity: usize) !SmallSendPool {
        const total = try allocator.alloc(u8, slot_count * slot_capacity);
        errdefer allocator.free(total);

        const free = try allocator.alloc(bool, slot_count);
        @memset(free, true);

        return .{
            .storage = total,
            .free = free,
        };
    }

    pub fn deinit(self: *SmallSendPool, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.free(self.free);
        self.* = undefined;
    }

    pub fn alloc(self: *SmallSendPool, bytes: []const u8, slot_capacity: usize) ?struct { slot: u16, buf: []u8 } {
        if (bytes.len > slot_capacity) return null;

        for (self.free, 0..) |is_free, idx| {
            if (!is_free) continue;
            self.free[idx] = false;

            const start = idx * slot_capacity;
            const slot_buf = self.storage[start .. start + bytes.len];
            @memcpy(slot_buf, bytes);

            return .{
                .slot = @intCast(idx),
                .buf = slot_buf,
            };
        }

        return null;
    }

    pub fn release(self: *SmallSendPool, slot: u16) void {
        self.free[slot] = true;
    }
};

const std = @import("std");

pub const PoolConfig = struct {
    initial_bytes: u64,
    max_bytes: u64,
    mtu_slot_bytes: usize = 1400,
    growth_chunk_bytes: u64 = 8 * 1024 * 1024,
};

pub const PoolStats = struct {
    capacity_bytes: u64 = 0,
    used_bytes: u64 = 0,
    free_bytes: u64 = 0,
    small_capacity_bytes: u64 = 0,
    small_used_bytes: u64 = 0,
    mtu_capacity_bytes: u64 = 0,
    mtu_used_bytes: u64 = 0,
    growth_count: u64 = 0,
    growth_failures: u64 = 0,
    allocation_failures: u64 = 0,
};

pub const UtpPacketHandle = struct {
    slot_index: usize,
    capacity: usize,
    len: usize,
    buf: []u8,

    pub fn bytes(self: UtpPacketHandle) []u8 {
        return self.buf[0..self.len];
    }
};

pub const UtpPacketPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    slots: std.ArrayList(Slot) = .empty,
    free_heads: [class_count]?usize = @as([class_count]?usize, @splat(null)),
    capacity_bytes: u64 = 0,
    used_bytes: u64 = 0,
    growth_count: u64 = 0,
    growth_failures: u64 = 0,
    allocation_failures: u64 = 0,

    const class_count = 5;
    const mtu_class = 4;
    const small_bins = [_]usize{ 64, 128, 256, 512 };

    const Slot = struct {
        buf: []u8,
        capacity: usize,
        class: usize,
        in_use: bool = false,
        next_free: ?usize = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !UtpPacketPool {
        var pool = initEmpty(allocator, config);
        errdefer pool.deinit();
        try pool.preallocate(config.initial_bytes);
        return pool;
    }

    pub fn initEmpty(allocator: std.mem.Allocator, config: PoolConfig) UtpPacketPool {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *UtpPacketPool) void {
        for (self.slots.items) |slot| {
            self.allocator.free(slot.buf);
        }
        self.slots.deinit(self.allocator);
        self.* = initEmpty(self.allocator, self.config);
    }

    pub fn preallocate(self: *UtpPacketPool, budget: u64) !void {
        const capped_budget = @min(budget, self.config.max_bytes);
        if (capped_budget <= self.capacity_bytes) return;
        try self.growMixed(capped_budget - self.capacity_bytes);
    }

    pub fn alloc(self: *UtpPacketPool, len: usize) !UtpPacketHandle {
        const class = self.classForLen(len) orelse return error.DatagramTooLarge;
        if (self.free_heads[class] == null) {
            self.growForClass(class) catch |err| {
                self.allocation_failures += 1;
                return err;
            };
        }
        const slot_index = self.free_heads[class] orelse {
            self.allocation_failures += 1;
            return error.PacketPoolExhausted;
        };
        var slot = &self.slots.items[slot_index];
        self.free_heads[class] = slot.next_free;
        slot.next_free = null;
        slot.in_use = true;
        self.used_bytes += slot.capacity;
        return .{
            .slot_index = slot_index,
            .capacity = slot.capacity,
            .len = len,
            .buf = slot.buf,
        };
    }

    pub fn free(self: *UtpPacketPool, handle: UtpPacketHandle) void {
        if (handle.slot_index >= self.slots.items.len) return;
        var slot = &self.slots.items[handle.slot_index];
        if (!slot.in_use) return;
        slot.in_use = false;
        slot.next_free = self.free_heads[slot.class];
        self.free_heads[slot.class] = handle.slot_index;
        self.used_bytes -= slot.capacity;
    }

    pub fn stats(self: *const UtpPacketPool) PoolStats {
        var result = PoolStats{
            .capacity_bytes = self.capacity_bytes,
            .used_bytes = self.used_bytes,
            .free_bytes = self.capacity_bytes - self.used_bytes,
            .growth_count = self.growth_count,
            .growth_failures = self.growth_failures,
            .allocation_failures = self.allocation_failures,
        };
        for (self.slots.items) |slot| {
            if (slot.class == mtu_class) {
                result.mtu_capacity_bytes += slot.capacity;
                if (slot.in_use) result.mtu_used_bytes += slot.capacity;
            } else {
                result.small_capacity_bytes += slot.capacity;
                if (slot.in_use) result.small_used_bytes += slot.capacity;
            }
        }
        return result;
    }

    fn growForClass(self: *UtpPacketPool, class: usize) !void {
        const required = self.classCapacity(class);
        if (self.capacity_bytes + required > self.config.max_bytes) {
            self.growth_failures += 1;
            return error.PacketPoolExhausted;
        }
        const remaining_budget = self.config.max_bytes - self.capacity_bytes;
        const desired = @max(@as(u64, @intCast(required)), self.config.growth_chunk_bytes);
        const growth_budget = @min(desired, remaining_budget);
        try self.addSlot(class);
        if (growth_budget > required) {
            try self.growMixed(growth_budget - required);
        }
        self.growth_count += 1;
    }

    fn growMixed(self: *UtpPacketPool, budget: u64) !void {
        var remaining = @min(budget, self.config.max_bytes - self.capacity_bytes);
        if (remaining == 0) return;

        if (remaining >= self.config.mtu_slot_bytes * 8) {
            const small_budget = remaining / 4;
            try self.addSmallSlots(&remaining, small_budget);
        }

        while (remaining >= self.config.mtu_slot_bytes) {
            try self.addSlot(mtu_class);
            remaining -= self.config.mtu_slot_bytes;
        }

        try self.addSmallSlots(&remaining, remaining);
    }

    fn addSmallSlots(self: *UtpPacketPool, remaining: *u64, budget: u64) !void {
        var spent: u64 = 0;
        var class: usize = 0;
        while (class < small_bins.len and remaining.* >= small_bins[0] and spent < budget) {
            const cap = small_bins[class];
            if (remaining.* >= cap and spent + cap <= budget) {
                try self.addSlot(class);
                remaining.* -= cap;
                spent += cap;
            }
            class = (class + 1) % small_bins.len;
            if (budget - spent < small_bins[0]) break;
        }
    }

    fn addSlot(self: *UtpPacketPool, class: usize) !void {
        const cap = self.classCapacity(class);
        if (self.capacity_bytes + cap > self.config.max_bytes) return error.PacketPoolExhausted;
        const buf = try self.allocator.alloc(u8, cap);
        errdefer self.allocator.free(buf);
        const slot_index = self.slots.items.len;
        try self.slots.append(self.allocator, .{
            .buf = buf,
            .capacity = cap,
            .class = class,
            .next_free = self.free_heads[class],
        });
        self.free_heads[class] = slot_index;
        self.capacity_bytes += cap;
    }

    fn classForLen(self: *const UtpPacketPool, len: usize) ?usize {
        if (len == 0) return 0;
        for (small_bins, 0..) |cap, i| {
            if (len <= cap) return i;
        }
        if (len <= self.config.mtu_slot_bytes) return mtu_class;
        return null;
    }

    fn classCapacity(self: *const UtpPacketPool, class: usize) usize {
        return if (class == mtu_class) self.config.mtu_slot_bytes else small_bins[class];
    }
};

test "packet pool allocates small packets from the smallest fitting bin" {
    var pool = try UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = 1024,
        .max_bytes = 1024,
    });
    defer pool.deinit();

    const handle = try pool.alloc(65);
    defer pool.free(handle);

    try std.testing.expectEqual(@as(usize, 128), handle.capacity);
    try std.testing.expectEqual(@as(usize, 65), handle.bytes().len);
}

test "packet pool allocates MTU slots for large datagrams" {
    const mtu_slot_bytes = 1400;
    var pool = try UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = mtu_slot_bytes,
        .max_bytes = mtu_slot_bytes,
        .mtu_slot_bytes = mtu_slot_bytes,
    });
    defer pool.deinit();

    const handle = try pool.alloc(mtu_slot_bytes);
    defer pool.free(handle);

    try std.testing.expectEqual(@as(usize, mtu_slot_bytes), handle.capacity);
    try std.testing.expectEqual(@as(usize, mtu_slot_bytes), handle.bytes().len);
}

test "packet pool reuses freed slots" {
    var pool = try UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = 512,
        .max_bytes = 512,
    });
    defer pool.deinit();

    const first = try pool.alloc(20);
    const first_ptr = first.bytes().ptr;
    pool.free(first);

    const second = try pool.alloc(20);
    defer pool.free(second);

    try std.testing.expectEqual(first_ptr, second.bytes().ptr);
}

test "packet pool grows in coarse chunks up to the max budget" {
    var pool = try UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = 64,
        .max_bytes = 512,
        .growth_chunk_bytes = 128,
    });
    defer pool.deinit();

    const first = try pool.alloc(64);
    defer pool.free(first);
    const second = try pool.alloc(64);
    defer pool.free(second);
    const stats = pool.stats();

    try std.testing.expect(stats.growth_count >= 1);
    try std.testing.expect(stats.capacity_bytes <= 512);
}

test "packet pool reports exhaustion when max budget is consumed" {
    var pool = try UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = 64,
        .max_bytes = 64,
    });
    defer pool.deinit();

    const handle = try pool.alloc(64);
    defer pool.free(handle);

    try std.testing.expectError(error.PacketPoolExhausted, pool.alloc(64));
}

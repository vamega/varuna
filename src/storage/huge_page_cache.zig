const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// A piece cache buffer pool backed by anonymous mmap. When requested, the
/// mapping is hinted with MADV_HUGEPAGE so the kernel can promote it to
/// transparent huge pages without requiring explicit MAP_HUGETLB setup.
pub const HugePageCache = struct {
    const Range = struct {
        offset: usize,
        len: usize,
    };

    const MmapAllocation = struct {
        buffer: []align(std.heap.page_size_min) u8,
        huge_page_hint_enabled: bool,
    };

    allocator: std.mem.Allocator,
    buffer: []align(std.heap.page_size_min) u8,
    capacity: usize,
    used: usize = 0,
    huge_page_hint_enabled: bool,
    free_ranges: std.ArrayListUnmanaged(Range) = .empty,

    /// Initialize a piece cache buffer pool.
    ///
    /// `capacity` is the desired size in bytes. When `use_huge_page_hint` is
    /// true, the allocator applies MADV_HUGEPAGE to the mmap-backed region.
    ///
    /// If capacity is 0, no allocation is performed and the cache is a no-op.
    pub fn init(allocator: std.mem.Allocator, capacity: usize, use_huge_page_hint: bool) HugePageCache {
        if (capacity == 0) {
            return .{
                .allocator = allocator,
                .buffer = &.{},
                .capacity = 0,
                .huge_page_hint_enabled = false,
            };
        }

        const alloc_size = std.mem.alignForward(usize, capacity, std.heap.page_size_min);

        if (use_huge_page_hint) {
            if (mmapWithHugePageHint(alloc_size)) |mapping| {
                return .{
                    .allocator = allocator,
                    .buffer = mapping.buffer,
                    .capacity = alloc_size,
                    .huge_page_hint_enabled = mapping.huge_page_hint_enabled,
                };
            }
        }

        if (mmapRegular(alloc_size)) |buf| {
            return .{
                .allocator = allocator,
                .buffer = buf,
                .capacity = alloc_size,
                .huge_page_hint_enabled = false,
            };
        }

        return .{
            .allocator = allocator,
            .buffer = &.{},
            .capacity = 0,
            .huge_page_hint_enabled = false,
        };
    }

    pub fn deinit(self: *HugePageCache) void {
        self.free_ranges.deinit(self.allocator);
        if (self.buffer.len > 0) {
            posix.munmap(self.buffer);
        }
        self.* = undefined;
    }

    /// Allocate a slice from the cache for a piece buffer.
    /// Returns null if the cache is exhausted.
    pub fn alloc(self: *HugePageCache, size: usize) ?[]u8 {
        if (size == 0) return self.buffer[0..0];

        if (self.allocFromFreeRange(size)) |offset| {
            return self.buffer[offset..][0..size];
        }

        if (self.used + size > self.capacity) return null;
        const start = self.used;
        self.used += size;
        return self.buffer[start..][0..size];
    }

    /// Return a previously allocated slice to the cache.
    pub fn free(self: *HugePageCache, buf: []u8) void {
        if (buf.len == 0 or self.capacity == 0) return;

        const base = @intFromPtr(self.buffer.ptr);
        const start = @intFromPtr(buf.ptr);
        const end = start + buf.len;
        std.debug.assert(start >= base);
        std.debug.assert(end <= base + self.capacity);

        const offset = start - base;
        const range_end = offset + buf.len;

        if (range_end == self.used) {
            self.used = offset;
            self.collapseTail();
            return;
        }

        var insert_index: usize = 0;
        while (insert_index < self.free_ranges.items.len and self.free_ranges.items[insert_index].offset < offset) {
            insert_index += 1;
        }

        const merge_prev = insert_index > 0 and self.free_ranges.items[insert_index - 1].offset + self.free_ranges.items[insert_index - 1].len == offset;
        const merge_next = insert_index < self.free_ranges.items.len and range_end == self.free_ranges.items[insert_index].offset;

        if (merge_prev and merge_next) {
            self.free_ranges.items[insert_index - 1].len += buf.len + self.free_ranges.items[insert_index].len;
            _ = self.free_ranges.orderedRemove(insert_index);
        } else if (merge_prev) {
            self.free_ranges.items[insert_index - 1].len += buf.len;
        } else if (merge_next) {
            self.free_ranges.items[insert_index].offset = offset;
            self.free_ranges.items[insert_index].len += buf.len;
        } else {
            self.free_ranges.insert(self.allocator, insert_index, .{
                .offset = offset,
                .len = buf.len,
            }) catch return;
        }

        self.collapseTail();
    }

    /// Reset the cache, allowing all space to be reused.
    /// Does not actually free memory -- just resets the bump pointer.
    pub fn reset(self: *HugePageCache) void {
        self.used = 0;
        self.free_ranges.clearRetainingCapacity();
    }

    /// Return the amount of free space remaining.
    pub fn available(self: *const HugePageCache) usize {
        return self.capacity - self.used;
    }

    /// Check if the cache was successfully allocated.
    pub fn isAllocated(self: *const HugePageCache) bool {
        return self.capacity > 0;
    }

    // ── Internal ─────────────────────────────────────────────

    fn allocFromFreeRange(self: *HugePageCache, size: usize) ?usize {
        for (self.free_ranges.items, 0..) |*range, idx| {
            if (range.len < size) continue;

            const offset = range.offset;
            if (range.len == size) {
                _ = self.free_ranges.orderedRemove(idx);
            } else {
                range.offset += size;
                range.len -= size;
            }
            return offset;
        }
        return null;
    }

    fn collapseTail(self: *HugePageCache) void {
        while (self.free_ranges.items.len > 0) {
            const last_index = self.free_ranges.items.len - 1;
            const last = self.free_ranges.items[last_index];
            if (last.offset + last.len != self.used) break;
            self.used = last.offset;
            self.free_ranges.items.len = last_index;
        }
    }

    fn mmapWithHugePageHint(size: usize) ?MmapAllocation {
        const buf = mmapRegular(size) orelse return null;
        const hint_enabled = if (posix.madvise(buf.ptr, buf.len, linux.MADV.HUGEPAGE)) |_| true else |_| false;
        return .{
            .buffer = buf,
            .huge_page_hint_enabled = hint_enabled,
        };
    }

    fn mmapRegular(size: usize) ?[]align(std.heap.page_size_min) u8 {
        const flags: linux.MAP = .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        };
        return doMmap(size, flags);
    }

    fn doMmap(size: usize, flags: linux.MAP) ?[]align(std.heap.page_size_min) u8 {
        const result = posix.mmap(
            null,
            size,
            linux.PROT.READ | linux.PROT.WRITE,
            flags,
            -1,
            0,
        );
        if (result) |buf| {
            return buf;
        } else |_| {
            return null;
        }
    }
};

// ── Tests ────────────────────────────────────────────────

test "huge page cache init with zero capacity is no-op" {
    var cache = HugePageCache.init(std.testing.allocator, 0, true);
    try std.testing.expect(!cache.isAllocated());
    try std.testing.expectEqual(@as(usize, 0), cache.capacity);
    // deinit on zero-capacity is safe
    cache.deinit();
}

test "huge page cache fallback to regular mmap" {
    var cache = HugePageCache.init(std.testing.allocator, 64 * 1024, false);
    if (!cache.isAllocated()) return; // mmap failed (shouldn't happen)
    defer cache.deinit();

    try std.testing.expect(cache.capacity >= 64 * 1024);
    try std.testing.expect(!cache.huge_page_hint_enabled);
}

test "huge page cache alloc and reset" {
    var cache = HugePageCache.init(std.testing.allocator, 4096, false);
    if (!cache.isAllocated()) return;
    defer cache.deinit();

    const buf1 = cache.alloc(1024);
    try std.testing.expect(buf1 != null);
    try std.testing.expectEqual(@as(usize, 1024), buf1.?.len);

    const buf2 = cache.alloc(1024);
    try std.testing.expect(buf2 != null);

    // Verify disjoint
    try std.testing.expect(buf1.?.ptr != buf2.?.ptr);

    cache.reset();
    try std.testing.expectEqual(cache.capacity, cache.available());
}

test "huge page cache exhaustion returns null" {
    var cache = HugePageCache.init(std.testing.allocator, 4096, false);
    if (!cache.isAllocated()) return;
    defer cache.deinit();

    _ = cache.alloc(cache.capacity);
    const buf = cache.alloc(1);
    try std.testing.expect(buf == null);
}

test "huge page cache with huge page hint flag" {
    var cache = HugePageCache.init(std.testing.allocator, 4 * 1024 * 1024, true);
    if (!cache.isAllocated()) return;
    defer cache.deinit();

    try std.testing.expect(cache.capacity >= 4 * 1024 * 1024);

    const buf = cache.alloc(16384);
    try std.testing.expect(buf != null);
}

test "huge page cache reuses freed ranges" {
    var cache = HugePageCache.init(std.testing.allocator, 4096, false);
    if (!cache.isAllocated()) return;
    defer cache.deinit();

    const first = cache.alloc(1024).?;
    const second = cache.alloc(1024).?;
    cache.free(first);
    const reused = cache.alloc(1024).?;

    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    try std.testing.expectEqual(@as(usize, 2048), cache.used);

    cache.free(second);
    cache.free(reused);
    try std.testing.expectEqual(@as(usize, 0), cache.used);
}

test "huge page cache merges adjacent freed ranges" {
    var cache = HugePageCache.init(std.testing.allocator, 4096, false);
    if (!cache.isAllocated()) return;
    defer cache.deinit();

    const first = cache.alloc(1024).?;
    const second = cache.alloc(1024).?;
    const third = cache.alloc(1024).?;

    cache.free(second);
    cache.free(first);

    const merged = cache.alloc(2048).?;
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(merged.ptr));

    cache.free(third);
    cache.free(merged);
    try std.testing.expectEqual(@as(usize, 0), cache.used);
}

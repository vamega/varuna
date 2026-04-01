const std = @import("std");

pub const Stats = struct {
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    failed_allocs: usize = 0,
    failed_resizes: usize = 0,
    failed_remaps: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn noteGrow(self: *Stats, bytes: usize) void {
        self.bytes_allocated += bytes;
        self.live_bytes += bytes;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }

    fn noteShrink(self: *Stats, bytes: usize) void {
        self.bytes_freed += bytes;
        self.live_bytes -|= bytes;
    }
};

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    stats: Stats = .{},

    const Self = @This();

    pub fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stats.alloc_calls += 1;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
            self.stats.failed_allocs += 1;
            return null;
        };
        self.stats.noteGrow(len);
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stats.resize_calls += 1;
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (!ok) {
            self.stats.failed_resizes += 1;
            return false;
        }
        if (new_len > memory.len) {
            self.stats.noteGrow(new_len - memory.len);
        } else if (memory.len > new_len) {
            self.stats.noteShrink(memory.len - new_len);
        }
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stats.remap_calls += 1;
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse {
            self.stats.failed_remaps += 1;
            return null;
        };
        if (new_len > memory.len) {
            self.stats.noteGrow(new_len - memory.len);
        } else if (memory.len > new_len) {
            self.stats.noteShrink(memory.len - new_len);
        }
        return ptr;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.stats.free_calls += 1;
        self.stats.noteShrink(memory.len);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

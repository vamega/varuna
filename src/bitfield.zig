const std = @import("std");

pub const Bitfield = struct {
    bits: []u8,
    piece_count: u32,
    count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, piece_count: u32) !Bitfield {
        const bits = try allocator.alloc(u8, byteCount(piece_count));
        @memset(bits, 0);
        return .{
            .bits = bits,
            .piece_count = piece_count,
        };
    }

    pub fn deinit(self: *Bitfield, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
        self.* = undefined;
    }

    pub fn has(self: Bitfield, piece_index: u32) bool {
        if (piece_index >= self.piece_count) return false;

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        return (self.bits[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    pub fn set(self: *Bitfield, piece_index: u32) !void {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }
        if (self.has(piece_index)) {
            return;
        }

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        self.bits[byte_index] |= @as(u8, 1) << bit_index;
        self.count += 1;
    }

    pub fn importBitfield(self: *Bitfield, bitfield: []const u8) void {
        @memset(self.bits, 0);
        const copy_length = @min(self.bits.len, bitfield.len);
        @memcpy(self.bits[0..copy_length], bitfield[0..copy_length]);
        self.count = countSetBits(self.bits, self.piece_count);
    }

    pub fn byteCount(piece_count: u32) usize {
        return @intCast((piece_count + 7) / 8);
    }

    fn countSetBits(bits: []const u8, piece_count: u32) u32 {
        const full_bytes: usize = @intCast(piece_count / 8);
        var total: u32 = 0;
        for (bits[0..full_bytes]) |byte| {
            total += @popCount(byte);
        }
        const remaining_bits: u4 = @intCast(piece_count % 8);
        if (remaining_bits > 0) {
            // Mask out trailing bits beyond piece_count (keep only the top remaining_bits)
            const shift: u3 = @intCast(8 - remaining_bits);
            const mask: u8 = @as(u8, 0xFF) << shift;
            total += @popCount(bits[full_bytes] & mask);
        }
        return total;
    }
};

test "set and query individual bits" {
    var bf = try Bitfield.init(std.testing.allocator, 16);
    defer bf.deinit(std.testing.allocator);

    try std.testing.expect(!bf.has(0));
    try std.testing.expect(!bf.has(7));
    try std.testing.expectEqual(@as(u32, 0), bf.count);

    try bf.set(0);
    try bf.set(7);
    try bf.set(15);

    try std.testing.expect(bf.has(0));
    try std.testing.expect(bf.has(7));
    try std.testing.expect(bf.has(15));
    try std.testing.expect(!bf.has(1));
    try std.testing.expectEqual(@as(u32, 3), bf.count);
}

test "import external bitfield" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    bf.importBitfield(&.{0b1010_0000});
    try std.testing.expect(bf.has(0));
    try std.testing.expect(!bf.has(1));
    try std.testing.expect(bf.has(2));
    try std.testing.expectEqual(@as(u32, 2), bf.count);
}

test "count tracks set operations" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    try bf.set(0);
    try std.testing.expectEqual(@as(u32, 1), bf.count);
    try bf.set(0);
    try std.testing.expectEqual(@as(u32, 1), bf.count);
    try bf.set(1);
    try std.testing.expectEqual(@as(u32, 2), bf.count);
}

test "out of range index returns false for has" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    try std.testing.expect(!bf.has(4));
    try std.testing.expect(!bf.has(100));
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(4));
}

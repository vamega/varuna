const std = @import("std");
const layout = @import("layout.zig");

pub const default_block_size: u32 = 16 * 1024;

pub const Geometry = struct {
    layout: *const layout.Layout,
    block_size: u32 = default_block_size,

    pub const Request = struct {
        piece_index: u32,
        piece_offset: u32,
        length: u32,
    };

    pub fn blockCount(self: Geometry, piece_index: u32) !u32 {
        const piece_size = try self.layout.pieceSize(piece_index);
        return @intCast((piece_size + self.block_size - 1) / self.block_size);
    }

    pub fn blockSize(self: Geometry, piece_index: u32, block_index: u32) !u32 {
        const block_count = try self.blockCount(piece_index);
        if (block_index >= block_count) {
            return error.InvalidBlockIndex;
        }

        if (block_index + 1 < block_count) {
            return self.block_size;
        }

        const piece_size = try self.layout.pieceSize(piece_index);
        const consumed = block_index * self.block_size;
        return piece_size - consumed;
    }

    pub fn requestForBlock(self: Geometry, piece_index: u32, block_index: u32) !Request {
        const length = try self.blockSize(piece_index, block_index);
        return .{
            .piece_index = piece_index,
            .piece_offset = block_index * self.block_size,
            .length = length,
        };
    }
};

test "derive block geometry from layout" {
    const path = [_][]const u8{"test.bin"};
    const files = [_]@import("metainfo.zig").Metainfo.File{
        .{ .length = 40_000, .path = path[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = @import("metainfo.zig").Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .comment = null,
        .name = "test.bin",
        .piece_length = 16_384,
        .pieces = hashes,
        .files = files[0..],
    };

    const built = try layout.build(std.testing.allocator, &source);
    defer layout.freeLayout(std.testing.allocator, built);

    const geometry = Geometry{ .layout = &built };

    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(0));
    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(1));
    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(2));

    const last = try geometry.requestForBlock(2, 0);
    try std.testing.expectEqual(@as(u32, 7_232), last.length);
    try std.testing.expectEqual(@as(u32, 0), last.piece_offset);
}

test "split large pieces into multiple blocks" {
    const path = [_][]const u8{"test.bin"};
    const files = [_]@import("metainfo.zig").Metainfo.File{
        .{ .length = 70_000, .path = path[0..] },
    };
    // 70_000 bytes / 32_768 piece_length = 3 pieces → 60 bytes of hash.
    const hashes =
        "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = @import("metainfo.zig").Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .comment = null,
        .name = "test.bin",
        .piece_length = 32_768,
        .pieces = hashes,
        .files = files[0..],
    };

    const built = try layout.build(std.testing.allocator, &source);
    defer layout.freeLayout(std.testing.allocator, built);

    const geometry = Geometry{ .layout = &built };

    try std.testing.expectEqual(@as(u32, 2), try geometry.blockCount(0));
    try std.testing.expectEqual(@as(u32, 16_384), try geometry.blockSize(0, 0));
    try std.testing.expectEqual(@as(u32, 16_384), try geometry.blockSize(0, 1));

    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(2));
    try std.testing.expectEqual(@as(u32, 4_464), try geometry.blockSize(2, 0));
    try std.testing.expectError(error.InvalidBlockIndex, geometry.blockSize(2, 1));
}

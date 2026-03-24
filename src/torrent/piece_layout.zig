const std = @import("std");
const metainfo = @import("metainfo.zig");

pub const Layout = struct {
    total_size: u64,
    piece_length: u32,
    piece_count: u32,
    last_piece_length: u32,
    files: []File,

    pub const File = struct {
        length: u64,
        offset: u64,
        path: []const []const u8,
    };

    pub const FileSpan = struct {
        file_index: u32,
        file_offset: u64,
        length: u32,
    };

    pub fn pieceSize(self: Layout, piece_index: u32) !u32 {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }

        if (piece_index + 1 == self.piece_count) {
            return self.last_piece_length;
        }

        return self.piece_length;
    }

    pub fn pieceOffset(self: Layout, piece_index: u32) !u64 {
        _ = try self.pieceSize(piece_index);
        return @as(u64, piece_index) * self.piece_length;
    }

    pub fn describePiece(self: Layout, allocator: std.mem.Allocator, piece_index: u32) ![]FileSpan {
        const piece_offset = try self.pieceOffset(piece_index);
        const piece_size = try self.pieceSize(piece_index);
        const piece_end = piece_offset + piece_size;

        var spans: std.ArrayListUnmanaged(FileSpan) = .empty;
        defer spans.deinit(allocator);

        for (self.files, 0..) |file, file_index| {
            const file_end = file.offset + file.length;
            if (file_end <= piece_offset) continue;
            if (file.offset >= piece_end) break;

            const overlap_start = @max(file.offset, piece_offset);
            const overlap_end = @min(file_end, piece_end);
            if (overlap_end <= overlap_start) continue;

            try spans.append(allocator, .{
                .file_index = std.math.cast(u32, file_index) orelse return error.TooManyFiles,
                .file_offset = overlap_start - file.offset,
                .length = std.math.cast(u32, overlap_end - overlap_start) orelse return error.IntegerOverflow,
            });
        }

        return spans.toOwnedSlice(allocator);
    }

    pub fn renderRelativePath(
        self: Layout,
        allocator: std.mem.Allocator,
        root_name: []const u8,
        file_index: u32,
    ) ![]u8 {
        if (file_index >= self.files.len) {
            return error.InvalidFileIndex;
        }

        const file = self.files[file_index];
        var path = std.ArrayList(u8).empty;
        defer path.deinit(allocator);

        try path.appendSlice(allocator, root_name);
        for (file.path) |component| {
            try path.append(allocator, std.fs.path.sep);
            try path.appendSlice(allocator, component);
        }

        return path.toOwnedSlice(allocator);
    }
};

pub fn build(allocator: std.mem.Allocator, info: metainfo.Metainfo) !Layout {
    const total_size = info.totalSize();

    const piece_count = info.pieceCount();
    if (piece_count == 0) {
        return error.EmptyTorrent;
    }

    const expected_piece_count = expectedPieceCount(total_size, info.piece_length);
    if (piece_count != expected_piece_count) {
        return error.PieceCountMismatch;
    }

    const files = try allocator.alloc(Layout.File, info.files.len);
    errdefer allocator.free(files);

    var running_offset: u64 = 0;
    for (info.files, files) |source, *target| {
        target.* = .{
            .length = source.length,
            .offset = running_offset,
            .path = source.path,
        };
        running_offset = try std.math.add(u64, running_offset, source.length);
    }

    return .{
        .total_size = total_size,
        .piece_length = info.piece_length,
        .piece_count = piece_count,
        .last_piece_length = lastPieceLength(total_size, info.piece_length),
        .files = files,
    };
}

pub fn freeLayout(allocator: std.mem.Allocator, layout: Layout) void {
    allocator.free(layout.files);
}

fn expectedPieceCount(total_size: u64, piece_length: u32) u32 {
    const divisor = @as(u64, piece_length);
    const rounded = std.math.divCeil(u64, total_size, divisor) catch unreachable;
    return std.math.cast(u32, rounded) orelse @panic("piece count overflow");
}

fn lastPieceLength(total_size: u64, piece_length: u32) u32 {
    const remainder = @mod(total_size, @as(u64, piece_length));
    if (remainder == 0) {
        return piece_length;
    }

    return std.math.cast(u32, remainder) orelse @panic("last piece length overflow");
}

test "build layout for single file torrent" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try build(std.testing.allocator, info);
    defer freeLayout(std.testing.allocator, layout);

    try std.testing.expectEqual(@as(u64, 10), layout.total_size);
    try std.testing.expectEqual(@as(u32, 4), layout.piece_length);
    try std.testing.expectEqual(@as(u32, 3), layout.piece_count);
    try std.testing.expectEqual(@as(u32, 2), layout.last_piece_length);
    try std.testing.expectEqual(@as(u64, 0), layout.files[0].offset);
}

test "describe piece spanning multiple files" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi5e4:pathl4:betaee" ++ "d6:lengthi2e4:pathl5:gammaee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try build(std.testing.allocator, info);
    defer freeLayout(std.testing.allocator, layout);

    const piece_zero = try layout.describePiece(std.testing.allocator, 0);
    defer std.testing.allocator.free(piece_zero);

    try std.testing.expectEqual(@as(usize, 2), piece_zero.len);
    try std.testing.expectEqual(@as(u32, 0), piece_zero[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), piece_zero[0].file_offset);
    try std.testing.expectEqual(@as(u32, 3), piece_zero[0].length);
    try std.testing.expectEqual(@as(u32, 1), piece_zero[1].file_index);
    try std.testing.expectEqual(@as(u64, 0), piece_zero[1].file_offset);
    try std.testing.expectEqual(@as(u32, 1), piece_zero[1].length);

    const piece_one = try layout.describePiece(std.testing.allocator, 1);
    defer std.testing.allocator.free(piece_one);

    try std.testing.expectEqual(@as(usize, 1), piece_one.len);
    try std.testing.expectEqual(@as(u32, 1), piece_one[0].file_index);
    try std.testing.expectEqual(@as(u64, 1), piece_one[0].file_offset);
    try std.testing.expectEqual(@as(u32, 4), piece_one[0].length);

    const piece_two = try layout.describePiece(std.testing.allocator, 2);
    defer std.testing.allocator.free(piece_two);

    try std.testing.expectEqual(@as(usize, 1), piece_two.len);
    try std.testing.expectEqual(@as(u32, 2), piece_two[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), piece_two[0].file_offset);
    try std.testing.expectEqual(@as(u32, 2), piece_two[0].length);
}

test "reject mismatched piece count" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    try std.testing.expectError(error.PieceCountMismatch, build(std.testing.allocator, info));
}

test "render relative path for multi file torrent" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try build(std.testing.allocator, info);
    defer freeLayout(std.testing.allocator, layout);

    const first = try layout.renderRelativePath(std.testing.allocator, info.name, 0);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("root/alpha", first);

    const second = try layout.renderRelativePath(std.testing.allocator, info.name, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("root/beta/gamma", second);
}

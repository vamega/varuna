const std = @import("std");
const metainfo = @import("metainfo.zig");

pub const Layout = struct {
    piece_length: u32,
    piece_count: u32,
    total_size: u64,
    files: []File,
    piece_hashes: []const u8,

    pub const File = struct {
        length: u64,
        torrent_offset: u64,
        first_piece: u32,
        end_piece_exclusive: u32,
        path: []const []const u8,
    };

    pub const Span = struct {
        file_index: u32,
        file_offset: u64,
        piece_offset: u32,
        torrent_offset: u64,
        length: u32,
    };

    pub fn pieceSize(self: Layout, piece_index: u32) !u32 {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }

        if (piece_index + 1 < self.piece_count) {
            return self.piece_length;
        }

        const consumed = @as(u64, piece_index) * self.piece_length;
        return @intCast(self.total_size - consumed);
    }

    pub fn pieceOffset(self: Layout, piece_index: u32) !u64 {
        _ = try self.pieceSize(piece_index);
        return @as(u64, piece_index) * self.piece_length;
    }

    pub fn pieceHash(self: Layout, piece_index: u32) ![]const u8 {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }

        const start = @as(usize, piece_index) * 20;
        return self.piece_hashes[start .. start + 20];
    }

    pub fn pieceSpanCount(self: Layout, piece_index: u32) !usize {
        _ = try self.pieceSize(piece_index);

        var count: usize = 0;
        for (self.files) |file| {
            if (file.length == 0) continue;
            if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;
            count += 1;
        }

        return count;
    }

    pub fn mapPiece(self: Layout, piece_index: u32, buffer: []Span) ![]Span {
        const piece_size = try self.pieceSize(piece_index);
        const required = try self.pieceSpanCount(piece_index);
        if (buffer.len < required) {
            return error.SpanBufferTooSmall;
        }

        const piece_start = @as(u64, piece_index) * self.piece_length;
        const piece_end = piece_start + piece_size;

        var next: usize = 0;
        for (self.files, 0..) |file, file_index| {
            if (file.length == 0) continue;
            if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;

            const file_start = file.torrent_offset;
            const file_end = file_start + file.length;
            const overlap_start = @max(piece_start, file_start);
            const overlap_end = @min(piece_end, file_end);

            if (overlap_start >= overlap_end) continue;

            buffer[next] = .{
                .file_index = @intCast(file_index),
                .file_offset = overlap_start - file_start,
                .piece_offset = @intCast(overlap_start - piece_start),
                .torrent_offset = overlap_start,
                .length = @intCast(overlap_end - overlap_start),
            };
            next += 1;
        }

        return buffer[0..next];
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

pub fn build(allocator: std.mem.Allocator, source: *const metainfo.Metainfo) !Layout {
    const total_size = source.totalSize();
    const piece_count = try source.pieceCount();
    if (piece_count == 0) {
        return error.EmptyTorrentData;
    }

    const expected_piece_count = try computePieceCount(total_size, source.piece_length);
    if (piece_count != expected_piece_count) {
        return error.PieceHashCountMismatch;
    }

    const files = try allocator.alloc(Layout.File, source.files.len);
    errdefer allocator.free(files);

    var running_offset: u64 = 0;
    for (source.files, 0..) |file, index| {
        const file_start = running_offset;
        const file_end = file_start + file.length;

        files[index] = .{
            .length = file.length,
            .torrent_offset = file_start,
            .first_piece = @intCast(file_start / source.piece_length),
            .end_piece_exclusive = if (file.length == 0)
                @intCast(file_start / source.piece_length)
            else
                @intCast((file_end + source.piece_length - 1) / source.piece_length),
            .path = file.path,
        };

        running_offset = file_end;
    }

    return .{
        .piece_length = source.piece_length,
        .piece_count = piece_count,
        .total_size = total_size,
        .files = files,
        .piece_hashes = source.pieces,
    };
}

pub fn freeLayout(allocator: std.mem.Allocator, value: Layout) void {
    allocator.free(value.files);
}

fn computePieceCount(total_size: u64, piece_length: u32) !u32 {
    if (piece_length == 0) return error.InvalidPieceLength;
    if (total_size == 0) return error.EmptyTorrentData;

    const piece_count = (total_size + piece_length - 1) / piece_length;
    return std.math.cast(u32, piece_count) orelse error.TooManyPieces;
}

test "build layout for single file torrent" {
    const path = [_][]const u8{"test.bin"};
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 10, .path = path[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "test.bin",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    try std.testing.expectEqual(@as(u64, 10), built.total_size);
    try std.testing.expectEqual(@as(u32, 3), built.piece_count);
    try std.testing.expectEqual(@as(u32, 4), try built.pieceSize(0));
    try std.testing.expectEqual(@as(u32, 2), try built.pieceSize(2));
    try std.testing.expectEqual(@as(u64, 8), try built.pieceOffset(2));
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaa", try built.pieceHash(0));
}

test "map piece across multiple files" {
    const path0 = [_][]const u8{"alpha"};
    const path1 = [_][]const u8{"beta"};
    const path2 = [_][]const u8{"gamma"};
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 3, .path = path0[0..] },
        .{ .length = 5, .path = path1[0..] },
        .{ .length = 2, .path = path2[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    var spans: [3]Layout.Span = undefined;
    const piece0 = try built.mapPiece(0, spans[0..]);
    try std.testing.expectEqual(@as(usize, 2), piece0.len);
    try std.testing.expectEqual(@as(u32, 0), piece0[0].file_index);
    try std.testing.expectEqual(@as(u32, 3), piece0[0].length);
    try std.testing.expectEqual(@as(u32, 1), piece0[1].length);
    try std.testing.expectEqual(@as(u64, 0), piece0[1].file_offset);

    const piece1 = try built.mapPiece(1, spans[0..]);
    try std.testing.expectEqual(@as(usize, 1), piece1.len);
    try std.testing.expectEqual(@as(u32, 1), piece1[0].file_index);
    try std.testing.expectEqual(@as(u64, 1), piece1[0].file_offset);
    try std.testing.expectEqual(@as(u32, 4), piece1[0].length);

    const piece2 = try built.mapPiece(2, spans[0..]);
    try std.testing.expectEqual(@as(usize, 2), piece2.len);
    try std.testing.expectEqual(@as(u32, 1), piece2[0].file_index);
    try std.testing.expectEqual(@as(u32, 1), piece2[0].length);
    try std.testing.expectEqual(@as(u32, 2), piece2[1].file_index);
    try std.testing.expectEqual(@as(u32, 1), piece2[1].piece_offset);
    try std.testing.expectEqual(@as(u32, 1), piece2[1].length);
}

test "reject mismatched piece hash count" {
    const path = [_][]const u8{"test.bin"};
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 10, .path = path[0..] },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "test.bin",
        .piece_length = 4,
        .pieces = "aaaaaaaaaaaaaaaaaaaa",
        .files = files[0..],
    };

    try std.testing.expectError(error.PieceHashCountMismatch, build(std.testing.allocator, &source));
}

test "render relative path for multi file torrent" {
    const path0 = [_][]const u8{"alpha"};
    const path1 = [_][]const u8{ "beta", "gamma" };
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 3, .path = path0[0..] },
        .{ .length = 7, .path = path1[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    const first = try built.renderRelativePath(std.testing.allocator, source.name, 0);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("root/alpha", first);

    const second = try built.renderRelativePath(std.testing.allocator, source.name, 1);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("root/beta/gamma", second);
}

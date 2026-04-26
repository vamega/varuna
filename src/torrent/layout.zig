const std = @import("std");
const metainfo = @import("metainfo.zig");

pub const Layout = struct {
    piece_length: u32,
    piece_count: u32,
    total_size: u64,
    files: []File,
    /// Flat SHA-1 piece hash table for v1/hybrid torrents.
    ///
    /// Lifecycle (see `docs/piece-hash-lifecycle.md`):
    ///   - non-null after `Session.loadForDownload` for v1/hybrid;
    ///   - null after `Session.loadForSeeding` (Phase 2) — never materialised;
    ///   - null after `Session.freePieces` (Phase 1 endgame) — discarded once
    ///     all pieces are verified;
    ///   - null for pure v2 torrents (which use Merkle roots, not flat hashes).
    ///
    /// Callers must handle `error.PiecesNotLoaded` from `pieceHash`. The Session
    /// owns the backing storage; the layout stores a non-owning view.
    piece_hashes: ?[]const u8 = null,
    /// Torrent version for piece mapping strategy.
    version: metainfo.TorrentVersion = .v1,
    /// v2 per-file piece metadata (null for pure v1).
    v2_files: ?[]const metainfo.V2File = null,

    pub const File = struct {
        length: u64,
        torrent_offset: u64,
        first_piece: u32,
        end_piece_exclusive: u32,
        path: []const []const u8,
        /// For v2 file-aligned layout: the global piece index where this file starts.
        v2_piece_offset: u32 = 0,
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

        if (self.version == .v2) {
            return self.pieceSizeV2(piece_index);
        }

        if (piece_index + 1 < self.piece_count) {
            return self.piece_length;
        }

        const consumed = @as(u64, piece_index) * self.piece_length;
        return @intCast(self.total_size - consumed);
    }

    /// v2 piece size: pieces are file-aligned, so the last piece of each file
    /// may be smaller than piece_length.
    fn pieceSizeV2(self: Layout, piece_index: u32) !u32 {
        for (self.files) |file| {
            if (file.length == 0) continue;
            if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;

            // This piece belongs to this file
            const piece_in_file = piece_index - file.first_piece;
            const file_pieces = (file.length + self.piece_length - 1) / self.piece_length;

            if (piece_in_file + 1 < file_pieces) {
                return self.piece_length;
            }
            // Last piece of this file
            const consumed = @as(u64, piece_in_file) * self.piece_length;
            return @intCast(file.length - consumed);
        }
        return error.InvalidPieceIndex;
    }

    pub fn pieceOffset(self: Layout, piece_index: u32) !u64 {
        _ = try self.pieceSize(piece_index);
        if (self.version == .v2) {
            // For v2, piece offset is within the file, not global
            // Return the global torrent offset for compatibility
            for (self.files) |file| {
                if (file.length == 0) continue;
                if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;
                const piece_in_file = piece_index - file.first_piece;
                return file.torrent_offset + @as(u64, piece_in_file) * self.piece_length;
            }
            return error.InvalidPieceIndex;
        }
        return @as(u64, piece_index) * self.piece_length;
    }

    pub fn pieceHash(self: Layout, piece_index: u32) ![]const u8 {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }
        if (self.version == .v2) {
            return error.UnsupportedForV2;
        }
        // Phase 1/2 of the piece-hash lifecycle: hashes may be freed for
        // verified pieces (piece-by-piece + endgame slice free) or never
        // materialised at all (seeding-only load).
        const hashes = self.piece_hashes orelse return error.PiecesNotLoaded;
        const start = @as(usize, piece_index) * 20;
        return hashes[start .. start + 20];
    }

    pub fn pieceSpanCount(self: Layout, piece_index: u32) !usize {
        _ = try self.pieceSize(piece_index);

        if (self.version == .v2) {
            // v2 pieces are file-aligned: always exactly 1 span
            return 1;
        }

        var count: usize = 0;
        for (self.files) |file| {
            if (file.length == 0) continue;
            if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;
            count += 1;
        }

        return count;
    }

    pub fn mapPiece(self: Layout, piece_index: u32, buffer: []Span) ![]Span {
        if (self.version == .v2) {
            return self.mapPieceV2(piece_index, buffer);
        }
        return self.mapPieceV1(piece_index, buffer);
    }

    /// v1 piece mapping: pieces may span multiple files.
    fn mapPieceV1(self: Layout, piece_index: u32, buffer: []Span) ![]Span {
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

    /// v2 piece mapping: pieces are file-aligned, always maps to exactly one file.
    fn mapPieceV2(self: Layout, piece_index: u32, buffer: []Span) ![]Span {
        const piece_size = try self.pieceSizeV2(piece_index);
        if (buffer.len < 1) return error.SpanBufferTooSmall;

        for (self.files, 0..) |file, file_index| {
            if (file.length == 0) continue;
            if (piece_index < file.first_piece or piece_index >= file.end_piece_exclusive) continue;

            const piece_in_file = piece_index - file.first_piece;
            const file_offset = @as(u64, piece_in_file) * self.piece_length;

            buffer[0] = .{
                .file_index = @intCast(file_index),
                .file_offset = file_offset,
                .piece_offset = 0,
                .torrent_offset = file.torrent_offset + file_offset,
                .length = piece_size,
            };
            return buffer[0..1];
        }

        return error.InvalidPieceIndex;
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

    if (source.version == .v2) {
        return buildV2(allocator, source, total_size);
    }

    // v1 or hybrid: derive piece count. When `pieces` is empty (seeding-only
    // load skipped the field), fall back to the file-size-derived count.
    const piece_count = try source.pieceCount();
    if (piece_count == 0) {
        return error.EmptyTorrentData;
    }

    // Cross-validate against the file-size-derived count when both sources
    // are available. Skip validation when `pieces` is unavailable — Phase 2
    // already trusts the file table for already-verified torrents.
    if (source.pieces.len > 0) {
        const expected_piece_count = try computePieceCount(total_size, source.piece_length);
        if (piece_count != expected_piece_count) {
            return error.PieceHashCountMismatch;
        }
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
        // null when seeding-only load skipped pieces parsing (Phase 2).
        .piece_hashes = if (source.pieces.len > 0) source.pieces else null,
        .version = source.version,
        .v2_files = source.file_tree_v2,
    };
}

/// Build a v2 file-aligned layout. Pieces do not cross file boundaries.
fn buildV2(allocator: std.mem.Allocator, source: *const metainfo.Metainfo, total_size: u64) !Layout {
    const piece_count = try source.pieceCountFromFiles();
    if (piece_count == 0) {
        return error.EmptyTorrentData;
    }

    const files = try allocator.alloc(Layout.File, source.files.len);
    errdefer allocator.free(files);

    var running_offset: u64 = 0;
    var running_piece: u32 = 0;
    for (source.files, 0..) |file, index| {
        const file_start = running_offset;
        const file_pieces: u32 = if (file.length == 0)
            0
        else
            @intCast((file.length + source.piece_length - 1) / source.piece_length);

        files[index] = .{
            .length = file.length,
            .torrent_offset = file_start,
            .first_piece = running_piece,
            .end_piece_exclusive = running_piece + file_pieces,
            .path = file.path,
            .v2_piece_offset = running_piece,
        };

        running_offset += file.length;
        running_piece += file_pieces;
    }

    return .{
        .piece_length = source.piece_length,
        .piece_count = piece_count,
        .total_size = total_size,
        .files = files,
        .piece_hashes = null, // v2 uses Merkle roots, not flat hashes
        .version = .v2,
        .v2_files = source.file_tree_v2,
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

// ── v2 layout tests ────────────────────────────────────────

test "build v2 file-aligned layout" {
    const path0 = [_][]const u8{"alpha.bin"};
    const path1 = [_][]const u8{"beta.bin"};
    const v1_files = [_]metainfo.Metainfo.File{
        .{ .length = 5, .path = path0[0..] },
        .{ .length = 10, .path = path1[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 5, .pieces_root = [_]u8{0xAA} ** 32 },
        .{ .path = path1[0..], .length = 10, .pieces_root = [_]u8{0xBB} ** 32 },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .files = @constCast(v1_files[0..]),
        .version = .v2,
        .file_tree_v2 = @constCast(v2_files[0..]),
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    // alpha.bin: 5 bytes / 4 = 2 pieces (0, 1)
    // beta.bin: 10 bytes / 4 = 3 pieces (2, 3, 4)
    try std.testing.expectEqual(@as(u32, 5), built.piece_count);
    try std.testing.expectEqual(@as(u64, 15), built.total_size);
    try std.testing.expectEqual(metainfo.TorrentVersion.v2, built.version);

    // File piece ranges
    try std.testing.expectEqual(@as(u32, 0), built.files[0].first_piece);
    try std.testing.expectEqual(@as(u32, 2), built.files[0].end_piece_exclusive);
    try std.testing.expectEqual(@as(u32, 2), built.files[1].first_piece);
    try std.testing.expectEqual(@as(u32, 5), built.files[1].end_piece_exclusive);
}

test "v2 piece size respects file boundaries" {
    const path0 = [_][]const u8{"a.bin"};
    const path1 = [_][]const u8{"b.bin"};
    const v1_files = [_]metainfo.Metainfo.File{
        .{ .length = 5, .path = path0[0..] },
        .{ .length = 3, .path = path1[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 5, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = path1[0..], .length = 3, .pieces_root = [_]u8{0} ** 32 },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .files = @constCast(v1_files[0..]),
        .version = .v2,
        .file_tree_v2 = @constCast(v2_files[0..]),
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    // a.bin: piece 0 (4 bytes), piece 1 (1 byte -- last piece of file)
    // b.bin: piece 2 (3 bytes -- only piece of file)
    try std.testing.expectEqual(@as(u32, 3), built.piece_count);
    try std.testing.expectEqual(@as(u32, 4), try built.pieceSize(0));
    try std.testing.expectEqual(@as(u32, 1), try built.pieceSize(1)); // last piece of a.bin
    try std.testing.expectEqual(@as(u32, 3), try built.pieceSize(2)); // only piece of b.bin
}

test "v2 mapPiece returns single-file spans" {
    const path0 = [_][]const u8{"a.bin"};
    const path1 = [_][]const u8{"b.bin"};
    const v1_files = [_]metainfo.Metainfo.File{
        .{ .length = 5, .path = path0[0..] },
        .{ .length = 3, .path = path1[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 5, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = path1[0..], .length = 3, .pieces_root = [_]u8{0} ** 32 },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .files = @constCast(v1_files[0..]),
        .version = .v2,
        .file_tree_v2 = @constCast(v2_files[0..]),
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    var spans: [3]Layout.Span = undefined;

    // Piece 0: first 4 bytes of a.bin
    const p0 = try built.mapPiece(0, spans[0..]);
    try std.testing.expectEqual(@as(usize, 1), p0.len);
    try std.testing.expectEqual(@as(u32, 0), p0[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), p0[0].file_offset);
    try std.testing.expectEqual(@as(u32, 4), p0[0].length);

    // Piece 1: last 1 byte of a.bin
    const p1 = try built.mapPiece(1, spans[0..]);
    try std.testing.expectEqual(@as(usize, 1), p1.len);
    try std.testing.expectEqual(@as(u32, 0), p1[0].file_index);
    try std.testing.expectEqual(@as(u64, 4), p1[0].file_offset);
    try std.testing.expectEqual(@as(u32, 1), p1[0].length);

    // Piece 2: all of b.bin (3 bytes)
    const p2 = try built.mapPiece(2, spans[0..]);
    try std.testing.expectEqual(@as(usize, 1), p2.len);
    try std.testing.expectEqual(@as(u32, 1), p2[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), p2[0].file_offset);
    try std.testing.expectEqual(@as(u32, 3), p2[0].length);
}

test "v2 pieceSpanCount is always 1" {
    const path0 = [_][]const u8{"a.bin"};
    const v1_files = [_]metainfo.Metainfo.File{
        .{ .length = 10, .path = path0[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 10, .pieces_root = [_]u8{0} ** 32 },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .files = @constCast(v1_files[0..]),
        .version = .v2,
        .file_tree_v2 = @constCast(v2_files[0..]),
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    // All v2 pieces should have exactly 1 span
    for (0..built.piece_count) |i| {
        try std.testing.expectEqual(@as(usize, 1), try built.pieceSpanCount(@intCast(i)));
    }
}

test "pure v2 layout rejects v1 piece hashes" {
    const path0 = [_][]const u8{"a.bin"};
    const v1_files = [_]metainfo.Metainfo.File{
        .{ .length = 4, .path = path0[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 4, .pieces_root = [_]u8{0} ** 32 },
    };
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .files = @constCast(v1_files[0..]),
        .version = .v2,
        .file_tree_v2 = @constCast(v2_files[0..]),
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    try std.testing.expectError(error.UnsupportedForV2, built.pieceHash(0));
}

test "hybrid layout keeps v1 piece mapping semantics" {
    const path0 = [_][]const u8{"alpha"};
    const path1 = [_][]const u8{"beta"};
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 3, .path = path0[0..] },
        .{ .length = 5, .path = path1[0..] },
    };
    const v2_files = [_]metainfo.V2File{
        .{ .path = path0[0..], .length = 3, .pieces_root = [_]u8{0xAA} ** 32 },
        .{ .path = path1[0..], .length = 5, .pieces_root = [_]u8{0xBB} ** 32 },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbb";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
        .version = .hybrid,
        .file_tree_v2 = @constCast(v2_files[0..]),
        .info_hash_v2 = [_]u8{0x11} ** 32,
    };

    const built = try build(std.testing.allocator, &source);
    defer freeLayout(std.testing.allocator, built);

    var spans: [2]Layout.Span = undefined;
    const piece0 = try built.mapPiece(0, spans[0..]);
    try std.testing.expectEqual(@as(usize, 2), piece0.len);
    try std.testing.expectEqual(@as(u32, 3), piece0[0].length);
    try std.testing.expectEqual(@as(u32, 1), piece0[1].length);
    try std.testing.expectEqual(@as(usize, 2), try built.pieceSpanCount(0));
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaa", try built.pieceHash(0));
}

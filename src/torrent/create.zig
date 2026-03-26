const std = @import("std");
const Ring = @import("../io/ring.zig").Ring;

pub const CreateOptions = struct {
    announce_url: []const u8,
    piece_length: u32 = 256 * 1024,
    name: ?[]const u8 = null,
};

/// Create a .torrent file for a single file.
/// Returns the raw bencode bytes of the torrent metainfo.
pub fn createSingleFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    options: CreateOptions,
) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    // Derive name from filename if not provided
    const name = options.name orelse std.fs.path.basename(file_path);

    // Hash all pieces
    const piece_count = computePieceCount(file_size, options.piece_length);
    const piece_hashes = try allocator.alloc(u8, piece_count * 20);
    defer allocator.free(piece_hashes);

    const read_buffer = try allocator.alloc(u8, options.piece_length);
    defer allocator.free(read_buffer);

    var piece_index: usize = 0;
    while (piece_index < piece_count) : (piece_index += 1) {
        const offset = piece_index * @as(usize, options.piece_length);
        const remaining = file_size - offset;
        const to_read: usize = @intCast(@min(remaining, options.piece_length));

        const n = try file.preadAll(read_buffer[0..to_read], offset);
        if (n != to_read) return error.UnexpectedEndOfFile;

        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(read_buffer[0..to_read], &digest, .{});
        @memcpy(piece_hashes[piece_index * 20 ..][0..20], &digest);
    }

    // Build bencode
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "d");

    // announce
    try output.print(allocator, "8:announce{}:", .{options.announce_url.len});
    try output.appendSlice(allocator, options.announce_url);

    // info dict
    try output.appendSlice(allocator, "4:infod");

    // length
    try output.print(allocator, "6:lengthi{}e", .{file_size});

    // name
    try output.print(allocator, "4:name{}:", .{name.len});
    try output.appendSlice(allocator, name);

    // piece length
    try output.print(allocator, "12:piece lengthi{}e", .{options.piece_length});

    // pieces
    try output.print(allocator, "6:pieces{}:", .{piece_hashes.len});
    try output.appendSlice(allocator, piece_hashes);

    try output.appendSlice(allocator, "ee"); // close info dict and root dict

    return output.toOwnedSlice(allocator);
}

const FileEntry = struct {
    relative_path: []const u8,
    full_path: []const u8,
    size: u64,
};

/// Create a .torrent file for a directory (multi-file torrent).
pub fn createDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: CreateOptions,
) ![]u8 {
    const name = options.name orelse std.fs.path.basename(dir_path);

    // Collect all files
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| {
            allocator.free(entry.relative_path);
            allocator.free(entry.full_path);
        }
        files.deinit(allocator);
    }

    try collectFiles(allocator, dir_path, "", &files);

    // Sort by relative path for deterministic output
    std.mem.sort(FileEntry, files.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
        }
    }.lessThan);

    // Compute total size
    var total_size: u64 = 0;
    for (files.items) |entry| {
        total_size += entry.size;
    }
    if (total_size == 0) return error.EmptyDirectory;

    // Hash all pieces across concatenated files
    const piece_count = computePieceCount(total_size, options.piece_length);
    const piece_hashes = try allocator.alloc(u8, piece_count * 20);
    defer allocator.free(piece_hashes);

    try hashMultiFilePieces(allocator, files.items, options.piece_length, piece_hashes);

    // Build bencode
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "d");
    try output.print(allocator, "8:announce{}:", .{options.announce_url.len});
    try output.appendSlice(allocator, options.announce_url);

    try output.appendSlice(allocator, "4:infod");

    // files list
    try output.appendSlice(allocator, "5:filesl");
    for (files.items) |entry| {
        try output.print(allocator, "d6:lengthi{}e4:pathl", .{entry.size});
        // Split relative path into components
        var iter = std.mem.splitScalar(u8, entry.relative_path, std.fs.path.sep);
        while (iter.next()) |component| {
            try output.print(allocator, "{}:", .{component.len});
            try output.appendSlice(allocator, component);
        }
        try output.appendSlice(allocator, "ee");
    }
    try output.append(allocator, 'e');

    // name
    try output.print(allocator, "4:name{}:", .{name.len});
    try output.appendSlice(allocator, name);

    // piece length
    try output.print(allocator, "12:piece lengthi{}e", .{options.piece_length});

    // pieces
    try output.print(allocator, "6:pieces{}:", .{piece_hashes.len});
    try output.appendSlice(allocator, piece_hashes);

    try output.appendSlice(allocator, "ee");
    return output.toOwnedSlice(allocator);
}

fn collectFiles(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    prefix: []const u8,
    files: *std.ArrayList(FileEntry),
) !void {
    var dir = try std.fs.cwd().openDir(base_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fs.path.join(allocator, &.{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(rel);

        const full = try std.fs.path.join(allocator, &.{ base_path, entry.name });
        errdefer allocator.free(full);

        switch (entry.kind) {
            .file => {
                const stat = try std.fs.cwd().statFile(full);
                try files.append(allocator, .{
                    .relative_path = rel,
                    .full_path = full,
                    .size = stat.size,
                });
            },
            .directory => {
                defer allocator.free(full);
                try collectFiles(allocator, full, rel, files);
                allocator.free(rel);
            },
            else => {
                allocator.free(rel);
                allocator.free(full);
            },
        }
    }
}

fn hashMultiFilePieces(
    allocator: std.mem.Allocator,
    files: []const FileEntry,
    piece_length: u32,
    piece_hashes: []u8,
) !void {
    const read_buffer = try allocator.alloc(u8, piece_length);
    defer allocator.free(read_buffer);

    var hasher = std.crypto.hash.Sha1.init(.{});
    var piece_index: usize = 0;
    var bytes_in_piece: usize = 0;

    for (files) |entry| {
        const file = try std.fs.cwd().openFile(entry.full_path, .{});
        defer file.close();

        var file_offset: u64 = 0;
        while (file_offset < entry.size) {
            const remaining_in_piece = @as(usize, piece_length) - bytes_in_piece;
            const remaining_in_file: usize = @intCast(entry.size - file_offset);
            const to_read = @min(remaining_in_piece, remaining_in_file);

            const n = try file.preadAll(read_buffer[0..to_read], file_offset);
            if (n != to_read) return error.UnexpectedEndOfFile;

            hasher.update(read_buffer[0..to_read]);
            bytes_in_piece += to_read;
            file_offset += to_read;

            if (bytes_in_piece == piece_length) {
                hasher.final(piece_hashes[piece_index * 20 ..][0..20]);
                hasher = std.crypto.hash.Sha1.init(.{});
                piece_index += 1;
                bytes_in_piece = 0;
            }
        }
    }

    // Final partial piece
    if (bytes_in_piece > 0) {
        hasher.final(piece_hashes[piece_index * 20 ..][0..20]);
    }
}

fn computePieceCount(file_size: u64, piece_length: u32) usize {
    return @intCast((file_size + @as(u64, piece_length) - 1) / @as(u64, piece_length));
}

test "create single file torrent and parse it back" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test file
    {
        const file = try tmp.dir.createFile("test.bin", .{});
        defer file.close();
        try file.writeAll("hello world test data for torrent creation");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 16,
    });
    defer allocator.free(torrent_bytes);

    // Parse it back
    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expectEqualStrings("test.bin", info.name);
    try std.testing.expectEqualStrings("http://tracker.example/announce", info.announce.?);
    try std.testing.expectEqual(@as(u32, 16), info.piece_length);
    try std.testing.expectEqual(@as(u64, 43), info.totalSize());
    try std.testing.expectEqual(@as(u32, 3), try info.pieceCount());
}

test "create multi-file torrent from directory" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test directory with files
    try tmp.dir.makePath("mydir/subdir");
    {
        const f = try tmp.dir.createFile("mydir/file_a.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }
    {
        const f = try tmp.dir.createFile("mydir/subdir/file_b.txt", .{});
        defer f.close();
        try f.writeAll("world!!");
    }

    const dir_path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "mydir",
    });
    defer allocator.free(dir_path);

    const torrent_bytes = try createDirectory(allocator, dir_path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 8,
    });
    defer allocator.free(torrent_bytes);

    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expectEqualStrings("mydir", info.name);
    try std.testing.expect(info.isMultiFile());
    try std.testing.expectEqual(@as(usize, 2), info.files.len);
    try std.testing.expectEqual(@as(u64, 12), info.totalSize());
    try std.testing.expectEqual(@as(u32, 2), try info.pieceCount());
}

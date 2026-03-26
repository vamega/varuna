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

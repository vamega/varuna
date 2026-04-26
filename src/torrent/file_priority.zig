const std = @import("std");
const layout = @import("layout.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;

pub const FilePriority = enum(u2) {
    normal = 0,
    high = 1,
    do_not_download = 2,
};

/// Build a bitfield marking which pieces are "wanted" based on per-file priorities.
///
/// A piece is wanted if ANY file that overlaps it has a priority other than
/// `do_not_download`. This ensures boundary pieces (spanning a wanted and a
/// skipped file) are still downloaded -- they contain data for the wanted file.
pub fn buildPieceMask(
    allocator: std.mem.Allocator,
    lay: *const layout.Layout,
    file_priorities: []const FilePriority,
) !Bitfield {
    std.debug.assert(file_priorities.len == lay.files.len);

    var wanted = try Bitfield.init(allocator, lay.piece_count);
    errdefer wanted.deinit(allocator);

    for (lay.files, 0..) |file, file_index| {
        if (file.length == 0) continue;
        if (file_priorities[file_index] == .do_not_download) continue;

        // Mark every piece this file touches as wanted.
        var piece: u32 = file.first_piece;
        while (piece < file.end_piece_exclusive) : (piece += 1) {
            wanted.set(piece) catch {};
        }
    }

    return wanted;
}

/// Return true when all files have `normal` or `high` priority (no filtering needed).
pub fn allWanted(file_priorities: []const FilePriority) bool {
    for (file_priorities) |p| {
        if (p == .do_not_download) return false;
    }
    return true;
}

/// Count pieces that are wanted.
pub fn wantedCount(wanted: *const Bitfield) u32 {
    return wanted.count;
}

// ── Tests ─────────────────────────────────────────────────

test "all files wanted produces full mask" {
    const path0 = [_][]const u8{"a"};
    const path1 = [_][]const u8{"b"};
    const metainfo = @import("metainfo.zig");
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 4, .path = path0[0..] },
        .{ .length = 4, .path = path1[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbb";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .comment = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const lay = try layout.build(std.testing.allocator, &source);
    defer layout.freeLayout(std.testing.allocator, lay);

    const priorities = [_]FilePriority{ .normal, .normal };
    var mask = try buildPieceMask(std.testing.allocator, &lay, priorities[0..]);
    defer mask.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), mask.count);
    try std.testing.expect(mask.has(0));
    try std.testing.expect(mask.has(1));
}

test "skip second file still downloads boundary piece" {
    // File layout: file0 = 3 bytes, file1 = 7 bytes, piece_length = 4
    // Pieces: [0: file0(3)+file1(1)] [1: file1(4)] [2: file1(2)]
    // If file1 is skipped, piece 0 is still wanted (it has file0 data).
    // Pieces 1 and 2 are not wanted (only file1 data).
    const path0 = [_][]const u8{"alpha"};
    const path1 = [_][]const u8{"beta"};
    const metainfo = @import("metainfo.zig");
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 3, .path = path0[0..] },
        .{ .length = 7, .path = path1[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .comment = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const lay = try layout.build(std.testing.allocator, &source);
    defer layout.freeLayout(std.testing.allocator, lay);

    const priorities = [_]FilePriority{ .normal, .do_not_download };
    var mask = try buildPieceMask(std.testing.allocator, &lay, priorities[0..]);
    defer mask.deinit(std.testing.allocator);

    try std.testing.expect(mask.has(0)); // boundary piece -- wanted
    try std.testing.expect(!mask.has(1)); // pure file1
    try std.testing.expect(!mask.has(2)); // pure file1
    try std.testing.expectEqual(@as(u32, 1), mask.count);
}

test "skip first file, want second file downloads boundary" {
    const path0 = [_][]const u8{"alpha"};
    const path1 = [_][]const u8{"beta"};
    const metainfo = @import("metainfo.zig");
    const files = [_]metainfo.Metainfo.File{
        .{ .length = 3, .path = path0[0..] },
        .{ .length = 7, .path = path1[0..] },
    };
    const hashes = "aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbcccccccccccccccccccc";
    const source = metainfo.Metainfo{
        .info_hash = [_]u8{0} ** 20,
        .announce = null,
        .created_by = null,
        .comment = null,
        .name = "root",
        .piece_length = 4,
        .pieces = hashes,
        .files = files[0..],
    };

    const lay = try layout.build(std.testing.allocator, &source);
    defer layout.freeLayout(std.testing.allocator, lay);

    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var mask = try buildPieceMask(std.testing.allocator, &lay, priorities[0..]);
    defer mask.deinit(std.testing.allocator);

    // Piece 0 spans both files -> wanted (file1 data in it)
    try std.testing.expect(mask.has(0));
    try std.testing.expect(mask.has(1));
    try std.testing.expect(mask.has(2));
    try std.testing.expectEqual(@as(u32, 3), mask.count);
}

test "allWanted returns false when file is skipped" {
    const priorities = [_]FilePriority{ .normal, .do_not_download, .high };
    try std.testing.expect(!allWanted(priorities[0..]));
}

test "allWanted returns true when all normal or high" {
    const priorities = [_]FilePriority{ .normal, .high, .normal };
    try std.testing.expect(allWanted(priorities[0..]));
}

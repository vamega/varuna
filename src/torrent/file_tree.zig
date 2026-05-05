const std = @import("std");
const bencode = @import("bencode.zig");
const metainfo = @import("metainfo.zig");

/// Parse a BEP 52 v2 `file tree` dictionary into a flat list of V2File entries.
///
/// The v2 file tree is a nested dictionary where:
/// - Directory names are keys with dict values (containing more entries)
/// - File entries have an empty-string key "" whose value is a dict with
///   `length` (integer) and `pieces root` (32-byte string)
///
/// Example:
///   file tree:
///     dir1:
///       file1.txt:
///         "": {length: 1234, pieces root: <32 bytes>}
pub fn parseFileTree(
    allocator: std.mem.Allocator,
    file_tree_dict: []const bencode.Value.Entry,
) ![]metainfo.V2File {
    var files = std.ArrayList(metainfo.V2File).empty;
    defer files.deinit(allocator);
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
        }
    }

    var path_stack = std.ArrayList([]const u8).empty;
    defer path_stack.deinit(allocator);

    try walkFileTree(allocator, file_tree_dict, &path_stack, &files);

    return files.toOwnedSlice(allocator);
}

pub fn freeV2Files(allocator: std.mem.Allocator, v2_files: []const metainfo.V2File) void {
    for (v2_files) |file| {
        allocator.free(file.path);
    }
    allocator.free(v2_files);
}

fn walkFileTree(
    allocator: std.mem.Allocator,
    entries: []const bencode.Value.Entry,
    path_stack: *std.ArrayList([]const u8),
    files: *std.ArrayList(metainfo.V2File),
) !void {
    for (entries) |entry| {
        if (entry.key.len == 0) {
            // Empty-string key: this is a file leaf marker.
            // The value is a dict containing "length" and optionally "pieces root".
            const file_dict = switch (entry.value) {
                .dict => |d| d,
                else => return error.InvalidFileTreeEntry,
            };

            const length = blk: {
                const v = bencode.dictGet(file_dict, "length") orelse return error.MissingFileLength;
                break :blk switch (v) {
                    .integer => |i| {
                        if (i < 0) return error.NegativeFileLength;
                        break :blk @as(u64, @intCast(i));
                    },
                    else => return error.InvalidFileLength,
                };
            };

            // pieces root is required for files with length > 0.
            // For zero-length files, pieces root may be absent.
            var pieces_root: [32]u8 = @as([32]u8, @splat(0));
            if (bencode.dictGet(file_dict, "pieces root")) |pr_val| {
                const pr_bytes = switch (pr_val) {
                    .bytes => |b| b,
                    else => return error.InvalidPiecesRoot,
                };
                if (pr_bytes.len != 32) return error.InvalidPiecesRootLength;
                @memcpy(&pieces_root, pr_bytes);
            } else if (length > 0) {
                return error.MissingPiecesRoot;
            }

            // Build the path from the stack (excluding the empty-string key)
            const path = try allocator.alloc([]const u8, path_stack.items.len);
            @memcpy(path, path_stack.items);

            try files.append(allocator, .{
                .path = path,
                .length = length,
                .pieces_root = pieces_root,
            });
        } else {
            // Non-empty key: this is a directory or file name component.
            // The value must be a dict containing either more entries or a "" leaf.
            const sub_dict = switch (entry.value) {
                .dict => |d| d,
                else => return error.InvalidFileTreeEntry,
            };

            try path_stack.append(allocator, entry.key);
            try walkFileTree(allocator, sub_dict, path_stack, files);
            _ = path_stack.pop();
        }
    }
}

// ── Tests ──────────────────────────────────────────────────

fn buildSimpleFileTree(allocator: std.mem.Allocator, input: []const u8) ![]metainfo.V2File {
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const dict = switch (root) {
        .dict => |d| d,
        else => return error.UnexpectedBencodeType,
    };

    return parseFileTree(allocator, dict);
}

test "parse single file tree" {
    // file tree: { "test.txt": { "": { "length": 1234, "pieces root": <32 zeros> } } }
    const pieces_root = @as([32]u8, @splat(0xAA));
    const input = "d8:test.txtd0:d6:lengthi1234e11:pieces root32:" ++ pieces_root ++ "eee";

    const files = try buildSimpleFileTree(std.testing.allocator, input);
    defer freeV2Files(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(u64, 1234), files[0].length);
    try std.testing.expectEqual(@as(usize, 1), files[0].path.len);
    try std.testing.expectEqualStrings("test.txt", files[0].path[0]);
    try std.testing.expectEqual(pieces_root, files[0].pieces_root);
}

test "parse nested directory file tree" {
    // file tree: { "dir": { "sub": { "file.bin": { "": { "length": 42, "pieces root": <32 bytes> } } } } }
    const pr = @as([32]u8, @splat(0xBB));
    const input = "d3:dird3:subd8:file.bind0:d6:lengthi42e11:pieces root32:" ++ pr ++ "eeeee";

    const files = try buildSimpleFileTree(std.testing.allocator, input);
    defer freeV2Files(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(u64, 42), files[0].length);
    try std.testing.expectEqual(@as(usize, 3), files[0].path.len);
    try std.testing.expectEqualStrings("dir", files[0].path[0]);
    try std.testing.expectEqualStrings("sub", files[0].path[1]);
    try std.testing.expectEqualStrings("file.bin", files[0].path[2]);
}

test "parse multiple files in file tree" {
    // Two files: dir/a.txt and dir/b.txt
    const pr1 = @as([32]u8, @splat(0x11));
    const pr2 = @as([32]u8, @splat(0x22));
    const input = "d3:dird5:a.txtd0:d6:lengthi100e11:pieces root32:" ++ pr1 ++ "ee5:b.txtd0:d6:lengthi200e11:pieces root32:" ++ pr2 ++ "eeee";

    const files = try buildSimpleFileTree(std.testing.allocator, input);
    defer freeV2Files(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqual(@as(u64, 100), files[0].length);
    try std.testing.expectEqualStrings("a.txt", files[0].path[1]);
    try std.testing.expectEqual(@as(u64, 200), files[1].length);
    try std.testing.expectEqualStrings("b.txt", files[1].path[1]);
}

test "parse zero-length file without pieces root" {
    // Zero-length files don't require pieces root
    const input = "d9:empty.txtd0:d6:lengthi0eeee";

    const files = try buildSimpleFileTree(std.testing.allocator, input);
    defer freeV2Files(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(u64, 0), files[0].length);
    try std.testing.expectEqual(@as([32]u8, @splat(0)), files[0].pieces_root);
}

test "reject non-zero file without pieces root" {
    const input = "d8:test.txtd0:d6:lengthi100eeee";

    try std.testing.expectError(
        error.MissingPiecesRoot,
        buildSimpleFileTree(std.testing.allocator, input),
    );
}

test "reject invalid pieces root length" {
    // pieces root with wrong length (16 instead of 32)
    const input = "d8:test.txtd0:d6:lengthi100e11:pieces root16:0123456789abcdefeee";

    try std.testing.expectError(
        error.InvalidPiecesRootLength,
        buildSimpleFileTree(std.testing.allocator, input),
    );
}

test "reject negative file length" {
    const pr = @as([32]u8, @splat(0));
    const input = "d8:test.txtd0:d6:lengthi-5e11:pieces root32:" ++ pr ++ "eee";

    try std.testing.expectError(
        error.NegativeFileLength,
        buildSimpleFileTree(std.testing.allocator, input),
    );
}

test "parse empty file tree" {
    const input = "de";

    const files = try buildSimpleFileTree(std.testing.allocator, input);
    defer freeV2Files(std.testing.allocator, files);

    try std.testing.expectEqual(@as(usize, 0), files.len);
}

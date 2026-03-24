const std = @import("std");
const bencode = @import("bencode.zig");
const info_hash = @import("info_hash.zig");

pub const Metainfo = struct {
    info_hash: [20]u8,
    announce: ?[]const u8,
    created_by: ?[]const u8,
    name: []const u8,
    piece_length: u32,
    pieces: []const u8,
    files: []File,

    pub const File = struct {
        length: u64,
        path: []const []const u8,
    };
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Metainfo {
    const digest = try info_hash.compute(input);
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const root_dict = expectDict(root);
    const info = expectDict(try getRequired(root_dict, "info"));

    const name = expectBytes(try getRequired(info, "name"));
    const pieces = expectBytes(try getRequired(info, "pieces"));
    if (pieces.len == 0 or pieces.len % 20 != 0) {
        return error.InvalidPiecesField;
    }

    const piece_length = expectPositiveU32(try getRequired(info, "piece length"));
    const files = if (bencode.dictGet(info, "files")) |value|
        try parseMultiFileList(allocator, expectList(value))
    else
        try parseSingleFileList(allocator, expectPositiveU64(try getRequired(info, "length")), name);

    return .{
        .info_hash = digest,
        .announce = if (bencode.dictGet(root_dict, "announce")) |value| expectBytes(value) else null,
        .created_by = if (bencode.dictGet(root_dict, "created by")) |value| expectBytes(value) else null,
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .files = files,
    };
}

pub fn freeMetainfo(allocator: std.mem.Allocator, metainfo: Metainfo) void {
    for (metainfo.files) |file| {
        allocator.free(file.path);
    }
    allocator.free(metainfo.files);
}

fn parseSingleFileList(
    allocator: std.mem.Allocator,
    length: u64,
    name: []const u8,
) ![]Metainfo.File {
    const path = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(path);
    path[0] = name;

    const files = try allocator.alloc(Metainfo.File, 1);
    files[0] = .{
        .length = length,
        .path = path,
    };
    return files;
}

fn parseMultiFileList(
    allocator: std.mem.Allocator,
    values: []const bencode.Value,
) ![]Metainfo.File {
    var files = try allocator.alloc(Metainfo.File, values.len);
    errdefer {
        for (files[0..values.len]) |file| {
            if (file.path.len != 0) allocator.free(file.path);
        }
        allocator.free(files);
    }

    for (values, 0..) |value, index| {
        const entry = expectDict(value);
        const length = expectPositiveU64(try getRequired(entry, "length"));
        const path = try parsePath(allocator, expectList(try getRequired(entry, "path")));
        files[index] = .{
            .length = length,
            .path = path,
        };
    }

    return files;
}

fn parsePath(
    allocator: std.mem.Allocator,
    components: []const bencode.Value,
) ![]const []const u8 {
    if (components.len == 0) {
        return error.InvalidFilePath;
    }

    const path = try allocator.alloc([]const u8, components.len);
    errdefer allocator.free(path);

    for (components, 0..) |component, index| {
        path[index] = expectBytes(component);
    }

    return path;
}

fn getRequired(dict: []const bencode.Value.Entry, key: []const u8) !bencode.Value {
    return bencode.dictGet(dict, key) orelse error.MissingRequiredField;
}

fn expectDict(value: bencode.Value) []const bencode.Value.Entry {
    return switch (value) {
        .dict => |dict| dict,
        else => @panic("expected bencode dictionary"),
    };
}

fn expectList(value: bencode.Value) []const bencode.Value {
    return switch (value) {
        .list => |list| list,
        else => @panic("expected bencode list"),
    };
}

fn expectBytes(value: bencode.Value) []const u8 {
    return switch (value) {
        .bytes => |bytes| bytes,
        else => @panic("expected bencode bytes"),
    };
}

fn expectPositiveU32(value: bencode.Value) u32 {
    const integer = expectPositiveU64(value);
    return std.math.cast(u32, integer) orelse @panic("integer overflow");
}

fn expectPositiveU64(value: bencode.Value) u64 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) @panic("expected non-negative integer");
            return @intCast(integer);
        },
        else => @panic("expected bencode integer"),
    };
}

test "parse single file torrent metainfo" {
    const input =
        "d8:announce14:http://tracker" ++ "10:created by6:varuna" ++ "4:infod6:lengthi5e" ++ "4:name8:test.bin" ++ "12:piece lengthi16384e" ++ "6:pieces20:abcdefghijklmnopqrstee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expectEqual(try info_hash.compute(input), metainfo.info_hash);
    try std.testing.expectEqualStrings("http://tracker", metainfo.announce.?);
    try std.testing.expectEqualStrings("varuna", metainfo.created_by.?);
    try std.testing.expectEqualStrings("test.bin", metainfo.name);
    try std.testing.expectEqual(@as(u32, 16384), metainfo.piece_length);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", metainfo.pieces);
    try std.testing.expectEqual(@as(usize, 1), metainfo.files.len);
    try std.testing.expectEqual(@as(u64, 5), metainfo.files[0].length);
    try std.testing.expectEqual(@as(usize, 1), metainfo.files[0].path.len);
    try std.testing.expectEqualStrings("test.bin", metainfo.files[0].path[0]);
}

test "parse multi file torrent metainfo" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi16384e" ++ "6:pieces20:abcdefghijklmnopqrsteee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expectEqual(try info_hash.compute(input), metainfo.info_hash);
    try std.testing.expectEqualStrings("root", metainfo.name);
    try std.testing.expectEqual(@as(usize, 2), metainfo.files.len);
    try std.testing.expectEqual(@as(u64, 3), metainfo.files[0].length);
    try std.testing.expectEqualStrings("alpha", metainfo.files[0].path[0]);
    try std.testing.expectEqual(@as(u64, 7), metainfo.files[1].length);
    try std.testing.expectEqualStrings("beta", metainfo.files[1].path[0]);
    try std.testing.expectEqualStrings("gamma", metainfo.files[1].path[1]);
}

test "reject invalid pieces length" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces3:abcee";

    try std.testing.expectError(error.InvalidPiecesField, parse(std.testing.allocator, input));
}

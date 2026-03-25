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

    pub fn pieceCount(self: Metainfo) !u32 {
        return std.math.cast(u32, self.pieces.len / 20) orelse error.PieceCountOverflow;
    }

    pub fn pieceHash(self: Metainfo, piece_index: u32) ![]const u8 {
        if (piece_index >= try self.pieceCount()) {
            return error.InvalidPieceIndex;
        }

        const start = @as(usize, piece_index) * 20;
        return self.pieces[start .. start + 20];
    }

    pub fn totalSize(self: Metainfo) u64 {
        var total: u64 = 0;
        for (self.files) |file| {
            total +%= file.length;
        }
        return total;
    }

    pub fn isMultiFile(self: Metainfo) bool {
        return self.files.len > 1;
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Metainfo {
    const digest = try info_hash.compute(input);
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const root_dict = try expectDict(root);
    const info = try expectDict(try getRequired(root_dict, "info"));

    const name = try expectBytes(try getRequired(info, "name"));
    const pieces = try expectBytes(try getRequired(info, "pieces"));
    if (pieces.len == 0 or pieces.len % 20 != 0) {
        return error.InvalidPiecesField;
    }

    const piece_length = try expectPositiveU32(try getRequired(info, "piece length"));
    const files = if (bencode.dictGet(info, "files")) |value|
        try parseMultiFileList(allocator, try expectList(value))
    else
        try parseSingleFileList(allocator, try expectPositiveU64(try getRequired(info, "length")), name);

    return .{
        .info_hash = digest,
        .announce = if (bencode.dictGet(root_dict, "announce")) |value| try expectBytes(value) else null,
        .created_by = if (bencode.dictGet(root_dict, "created by")) |value| try expectBytes(value) else null,
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
        const entry = try expectDict(value);
        const length = try expectPositiveU64(try getRequired(entry, "length"));
        const path = try parsePath(allocator, try expectList(try getRequired(entry, "path")));
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
        path[index] = try expectBytes(component);
    }

    return path;
}

fn getRequired(dict: []const bencode.Value.Entry, key: []const u8) !bencode.Value {
    return bencode.dictGet(dict, key) orelse error.MissingRequiredField;
}

const BencodeTypeError = error{
    UnexpectedBencodeType,
    NegativeInteger,
    IntegerOverflow,
};

fn expectDict(value: bencode.Value) BencodeTypeError![]const bencode.Value.Entry {
    return switch (value) {
        .dict => |dict| dict,
        else => error.UnexpectedBencodeType,
    };
}

fn expectList(value: bencode.Value) BencodeTypeError![]const bencode.Value {
    return switch (value) {
        .list => |list| list,
        else => error.UnexpectedBencodeType,
    };
}

fn expectBytes(value: bencode.Value) BencodeTypeError![]const u8 {
    return switch (value) {
        .bytes => |bytes| bytes,
        else => error.UnexpectedBencodeType,
    };
}

fn expectPositiveU32(value: bencode.Value) BencodeTypeError!u32 {
    const integer = try expectPositiveU64(value);
    return std.math.cast(u32, integer) orelse error.IntegerOverflow;
}

fn expectPositiveU64(value: bencode.Value) BencodeTypeError!u64 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.NegativeInteger;
            return @intCast(integer);
        },
        else => error.UnexpectedBencodeType,
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

test "piece hash accessors expose torrent piece metadata" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const info = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, info);

    try std.testing.expectEqual(@as(u32, 3), try info.pieceCount());
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try info.pieceHash(0));
    try std.testing.expectEqualStrings("UVWXYZ12345678", (try info.pieceHash(2))[6..]);
    try std.testing.expectEqual(@as(u64, 10), info.totalSize());
    try std.testing.expect(!info.isMultiFile());
    try std.testing.expectError(error.InvalidPieceIndex, info.pieceHash(3));
}

test "reject non-dictionary torrent root" {
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parse(std.testing.allocator, "li1ei2ee"),
    );
}

test "reject non-integer piece length" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece length3:foo6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parse(std.testing.allocator, input),
    );
}

test "reject negative file length" {
    const input =
        "d4:infod6:lengthi-1e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.NegativeInteger,
        parse(std.testing.allocator, input),
    );
}

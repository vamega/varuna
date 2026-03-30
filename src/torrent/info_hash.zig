const std = @import("std");
const Sha1 = @import("../crypto/sha1.zig");

pub fn compute(torrent_bytes: []const u8) ![20]u8 {
    const info_bytes = try findInfoBytes(torrent_bytes);

    var digest: [20]u8 = undefined;
    Sha1.hash(info_bytes, &digest, .{});
    return digest;
}

pub fn findInfoBytes(torrent_bytes: []const u8) ![]const u8 {
    var index: usize = 0;
    try expectByte(torrent_bytes, &index, 'd');

    while (true) {
        const next = peek(torrent_bytes, index) orelse return error.UnexpectedEndOfStream;
        if (next == 'e') {
            return error.MissingInfoDictionary;
        }

        const key = try parseByteString(torrent_bytes, &index);
        const value_start = index;
        try skipValue(torrent_bytes, &index);

        if (std.mem.eql(u8, key, "info")) {
            return torrent_bytes[value_start..index];
        }
    }
}

fn skipValue(input: []const u8, index: *usize) !void {
    const next = peek(input, index.*) orelse return error.UnexpectedEndOfStream;
    switch (next) {
        'i' => {
            index.* += 1;
            while (peek(input, index.*)) |byte| {
                index.* += 1;
                if (byte == 'e') return;
            }
            return error.UnexpectedEndOfStream;
        },
        'l' => {
            index.* += 1;
            while (true) {
                const inner = peek(input, index.*) orelse return error.UnexpectedEndOfStream;
                if (inner == 'e') {
                    index.* += 1;
                    return;
                }
                try skipValue(input, index);
            }
        },
        'd' => {
            index.* += 1;
            while (true) {
                const inner = peek(input, index.*) orelse return error.UnexpectedEndOfStream;
                if (inner == 'e') {
                    index.* += 1;
                    return;
                }
                _ = try parseByteString(input, index);
                try skipValue(input, index);
            }
        },
        '0'...'9' => {
            _ = try parseByteString(input, index);
        },
        else => return error.InvalidBencodeValue,
    }
}

fn parseByteString(input: []const u8, index: *usize) ![]const u8 {
    const length_start = index.*;
    while (peek(input, index.*)) |byte| {
        if (byte == ':') break;
        if (!std.ascii.isDigit(byte)) return error.InvalidByteStringLength;
        index.* += 1;
    }

    if (peek(input, index.*) == null) {
        return error.UnexpectedEndOfStream;
    }

    const length_bytes = input[length_start..index.*];
    if (length_bytes.len == 0) {
        return error.InvalidByteStringLength;
    }

    index.* += 1;
    const length = try std.fmt.parseUnsigned(usize, length_bytes, 10);
    const start = index.*;
    const end = start + length;
    if (end > input.len) {
        return error.UnexpectedEndOfStream;
    }

    index.* = end;
    return input[start..end];
}

fn expectByte(input: []const u8, index: *usize, expected: u8) !void {
    if (peek(input, index.*) != expected) {
        return error.UnexpectedByte;
    }
    index.* += 1;
}

fn peek(input: []const u8, index: usize) ?u8 {
    if (index >= input.len) return null;
    return input[index];
}

test "find raw info dictionary bytes" {
    const input =
        "d8:announce14:http://tracker" ++ "4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const info = try findInfoBytes(input);
    try std.testing.expectEqualStrings(
        "d6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrste",
        info,
    );
}

test "compute info hash matches direct sha1 of raw info bytes" {
    const input =
        "d8:announce14:http://tracker" ++ "4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const expected_info = "d6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrste";
    var expected: [20]u8 = undefined;
    Sha1.hash(expected_info, &expected, .{});

    try std.testing.expectEqual(expected, try compute(input));
}

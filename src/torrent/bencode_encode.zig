const std = @import("std");
const bencode = @import("bencode.zig");

/// Encode a bencode Value into a byte buffer.
pub fn encode(allocator: std.mem.Allocator, value: bencode.Value) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try encodeValue(allocator, &output, value);
    return output.toOwnedSlice(allocator);
}

fn encodeValue(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: bencode.Value) !void {
    switch (value) {
        .integer => |integer| {
            try output.append(allocator, 'i');
            try output.print(allocator, "{}", .{integer});
            try output.append(allocator, 'e');
        },
        .bytes => |bytes| {
            try output.print(allocator, "{}:", .{bytes.len});
            try output.appendSlice(allocator, bytes);
        },
        .list => |items| {
            try output.append(allocator, 'l');
            for (items) |item| {
                try encodeValue(allocator, output, item);
            }
            try output.append(allocator, 'e');
        },
        .dict => |entries| {
            try output.append(allocator, 'd');
            for (entries) |entry| {
                try output.print(allocator, "{}:", .{entry.key.len});
                try output.appendSlice(allocator, entry.key);
                try encodeValue(allocator, output, entry.value);
            }
            try output.append(allocator, 'e');
        },
    }
}

test "encode integer" {
    const result = try encode(std.testing.allocator, .{ .integer = 42 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("i42e", result);
}

test "encode bytes" {
    const result = try encode(std.testing.allocator, .{ .bytes = "spam" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("4:spam", result);
}

test "encode roundtrip" {
    const input = "d3:cow3:moo4:spamli1ei2eee";
    const parsed = try bencode.parse(std.testing.allocator, input);
    defer bencode.freeValue(std.testing.allocator, parsed);

    const encoded = try encode(std.testing.allocator, parsed);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(input, encoded);
}

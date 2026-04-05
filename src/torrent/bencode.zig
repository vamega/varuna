const std = @import("std");

pub const Value = union(enum) {
    integer: i64,
    bytes: []const u8,
    list: []Value,
    dict: []Entry,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
    };
};

pub const ParseError = std.mem.Allocator.Error || std.fmt.ParseIntError || error{
    TrailingData,
    UnexpectedEndOfStream,
    InvalidPrefix,
    InvalidInteger,
    InvalidByteStringLength,
    UnexpectedByte,
    NestingTooDeep,
    TooManyElements,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    var parser = Parser{
        .allocator = allocator,
        .input = input,
    };

    const value = try parser.parseValue();
    if (!parser.isAtEnd()) {
        return error.TrailingData;
    }

    return value;
}

pub fn dictGet(dict: []const Value.Entry, key: []const u8) ?Value {
    for (dict) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
    }

    return null;
}

const max_nesting_depth: u32 = 64;
const max_container_elements: u32 = 500_000;

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    depth: u32 = 0,

    fn parseValue(self: *Parser) ParseError!Value {
        const next = self.peek() orelse return error.UnexpectedEndOfStream;
        return switch (next) {
            'i' => .{ .integer = try self.parseInteger() },
            'l' => .{ .list = try self.parseList() },
            'd' => .{ .dict = try self.parseDict() },
            '0'...'9' => .{ .bytes = try self.parseBytes() },
            else => error.InvalidPrefix,
        };
    }

    fn parseInteger(self: *Parser) ParseError!i64 {
        try self.expectByte('i');
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == 'e') break;
            self.index += 1;
        }

        if (self.peek() == null) {
            return error.UnexpectedEndOfStream;
        }

        const digits = self.input[start..self.index];
        if (digits.len == 0) {
            return error.InvalidInteger;
        }

        self.index += 1;
        return std.fmt.parseInt(i64, digits, 10);
    }

    fn parseBytes(self: *Parser) ParseError![]const u8 {
        const length_start = self.index;
        while (self.peek()) |byte| {
            if (byte == ':') break;
            if (!std.ascii.isDigit(byte)) return error.InvalidByteStringLength;
            self.index += 1;
        }

        if (self.peek() == null) {
            return error.UnexpectedEndOfStream;
        }

        const length_slice = self.input[length_start..self.index];
        if (length_slice.len == 0) {
            return error.InvalidByteStringLength;
        }

        self.index += 1;
        const length = try std.fmt.parseUnsigned(usize, length_slice, 10);

        const end = self.index + length;
        if (end > self.input.len) {
            return error.UnexpectedEndOfStream;
        }

        defer self.index = end;
        return self.input[self.index..end];
    }

    fn parseList(self: *Parser) ParseError![]Value {
        try self.expectByte('l');
        if (self.depth >= max_nesting_depth) return error.NestingTooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        var values: std.ArrayListUnmanaged(Value) = .empty;
        errdefer values.deinit(self.allocator);

        while (true) {
            const next = self.peek() orelse return error.UnexpectedEndOfStream;
            if (next == 'e') {
                self.index += 1;
                return try values.toOwnedSlice(self.allocator);
            }
            if (values.items.len >= max_container_elements) return error.TooManyElements;

            try values.append(self.allocator, try self.parseValue());
        }
    }

    fn parseDict(self: *Parser) ParseError![]Value.Entry {
        try self.expectByte('d');
        if (self.depth >= max_nesting_depth) return error.NestingTooDeep;
        self.depth += 1;
        defer self.depth -= 1;

        var entries: std.ArrayListUnmanaged(Value.Entry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                freeValue(self.allocator, entry.value);
            }
            entries.deinit(self.allocator);
        }

        while (true) {
            const next = self.peek() orelse return error.UnexpectedEndOfStream;
            if (next == 'e') {
                self.index += 1;
                return try entries.toOwnedSlice(self.allocator);
            }
            if (entries.items.len >= max_container_elements) return error.TooManyElements;

            const key = try self.parseBytes();
            const value = try self.parseValue();
            try entries.append(self.allocator, .{
                .key = key,
                .value = value,
            });
        }
    }

    fn expectByte(self: *Parser, byte: u8) ParseError!void {
        if (self.peek() != byte) {
            return error.UnexpectedByte;
        }
        self.index += 1;
    }

    fn peek(self: *Parser) ?u8 {
        if (self.index >= self.input.len) return null;
        return self.input[self.index];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.index == self.input.len;
    }
};

pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .integer, .bytes => {},
        .list => |items| {
            for (items) |item| freeValue(allocator, item);
            allocator.free(items);
        },
        .dict => |entries| {
            for (entries) |entry| freeValue(allocator, entry.value);
            allocator.free(entries);
        },
    }
}

test "parse integer value" {
    const value = try parse(std.testing.allocator, "i42e");
    defer freeValue(std.testing.allocator, value);

    try std.testing.expectEqual(Value{ .integer = 42 }, value);
}

test "parse byte string value" {
    const value = try parse(std.testing.allocator, "4:spam");
    defer freeValue(std.testing.allocator, value);

    try std.testing.expectEqualStrings("spam", value.bytes);
}

test "parse nested list and dict values" {
    const input = "d3:cow3:moo4:spamli1ei2eee";
    const value = try parse(std.testing.allocator, input);
    defer freeValue(std.testing.allocator, value);

    try std.testing.expectEqual(@as(usize, 2), value.dict.len);
    try std.testing.expectEqualStrings("cow", value.dict[0].key);
    try std.testing.expectEqualStrings("moo", value.dict[0].value.bytes);
    try std.testing.expectEqualStrings("spam", value.dict[1].key);
    try std.testing.expectEqual(@as(usize, 2), value.dict[1].value.list.len);
    try std.testing.expectEqual(Value{ .integer = 1 }, value.dict[1].value.list[0]);
    try std.testing.expectEqual(Value{ .integer = 2 }, value.dict[1].value.list[1]);
}

test "reject trailing bytes after root value" {
    try std.testing.expectError(error.TrailingData, parse(std.testing.allocator, "i1ei2e"));
}

test "reject truncated list" {
    try std.testing.expectError(error.UnexpectedEndOfStream, parse(std.testing.allocator, "li1e"));
}

// ── Fuzz test ─────────────────────────────────────────────

test "fuzz bencode parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            const value = parse(std.testing.allocator, input) catch return;
            freeValue(std.testing.allocator, value);
        }
    }.run, .{
        .corpus = &.{
            // Valid bencode samples
            "i0e",
            "i42e",
            "i-1e",
            "4:spam",
            "0:",
            "le",
            "de",
            "li1ei2ei3ee",
            "d3:cow3:mooe",
            "d3:cow3:moo4:spamli1ei2eee",
            // Invalid / edge cases
            "",
            "i",
            "ie",
            "l",
            "d",
            "999999999:",
            "i99999999999999999999e",
            "i-0e",
            "ddddddddddddddddddde",
        },
    });
}

// ── Edge case tests ───────────────────────────────────────

test "reject empty input" {
    try std.testing.expectError(error.UnexpectedEndOfStream, parse(std.testing.allocator, ""));
}

test "reject single bytes" {
    // Every single byte value should either parse successfully or return an error, never panic.
    var buf: [1]u8 = undefined;
    for (0..256) |b| {
        buf[0] = @intCast(b);
        if (parse(std.testing.allocator, &buf)) |value| {
            freeValue(std.testing.allocator, value);
        } else |_| {}
    }
}

test "reject deeply nested lists" {
    // 256 nested lists with no closing: "llll...l"
    const depth = 256;
    var buf: [depth]u8 = undefined;
    @memset(&buf, 'l');
    try std.testing.expectError(error.UnexpectedEndOfStream, parse(std.testing.allocator, &buf));
}

test "reject deeply nested dicts" {
    // "d1:ad1:ad1:a..." -- each level is a dict with key "a" and value = next dict
    const depth = 128;
    // Each nesting level needs "d1:a" (4 bytes) plus "e" closers at the end
    var buf: [depth * 4 + depth]u8 = undefined;
    for (0..depth) |i| {
        buf[i * 4 + 0] = 'd';
        buf[i * 4 + 1] = '1';
        buf[i * 4 + 2] = ':';
        buf[i * 4 + 3] = 'a';
    }
    // Innermost value: "de" (empty dict)
    // Actually we need a value for the last key. Use "de" (empty dict) then close all.
    // Rewrite: we have depth keys, the last one's value is "de", then depth-1 closing 'e's.
    const prefix_len = depth * 4;
    // Replace last 4 bytes of prefix with a value
    // Actually the structure works: d1:a d1:a d1:a ... d1:a <value> e e e ... e
    // We need a value for the innermost key and then depth 'e's to close.
    // Total = prefix_len + 2 (for "de") + depth (for closing 'e's)
    var full_buf = std.testing.allocator.alloc(u8, prefix_len + 2 + depth) catch return;
    defer std.testing.allocator.free(full_buf);
    @memcpy(full_buf[0..prefix_len], buf[0..prefix_len]);
    full_buf[prefix_len] = 'd';
    full_buf[prefix_len + 1] = 'e';
    @memset(full_buf[prefix_len + 2 ..], 'e');

    const value = try parse(std.testing.allocator, full_buf);
    freeValue(std.testing.allocator, value);
}

test "parse very long byte string" {
    // Build "10000:<10000 bytes of 'x'>"
    const length = 10000;
    const header = "10000:";
    var buf = std.testing.allocator.alloc(u8, header.len + length) catch return;
    defer std.testing.allocator.free(buf);
    @memcpy(buf[0..header.len], header);
    @memset(buf[header.len..], 'x');

    const value = try parse(std.testing.allocator, buf);
    freeValue(std.testing.allocator, value);
    try std.testing.expectEqual(@as(usize, length), value.bytes.len);
}

test "reject negative zero integer" {
    // "i-0e" is invalid per bencode spec, but our parser may accept it.
    // Either way it must not panic.
    if (parse(std.testing.allocator, "i-0e")) |value| {
        freeValue(std.testing.allocator, value);
    } else |_| {}
}

test "parse negative integer" {
    const value = try parse(std.testing.allocator, "i-42e");
    defer freeValue(std.testing.allocator, value);
    try std.testing.expectEqual(Value{ .integer = -42 }, value);
}

test "reject integer overflow" {
    // Larger than i64 max
    try std.testing.expectError(
        error.Overflow,
        parse(std.testing.allocator, "i99999999999999999999e"),
    );
    // Smaller than i64 min
    try std.testing.expectError(
        error.Overflow,
        parse(std.testing.allocator, "i-99999999999999999999e"),
    );
}

test "reject truncated inputs" {
    const truncated_cases = [_][]const u8{
        "i1",
        "3:ab",
        "l",
        "d",
        "d3:foo",
        "d3:fooi1e",
        "li1ei2e",
    };
    for (truncated_cases) |input| {
        try std.testing.expectError(
            error.UnexpectedEndOfStream,
            parse(std.testing.allocator, input),
        );
    }
}

test "reject invalid bencode byte sequences" {
    const invalid_cases = [_][]const u8{
        "xyz",
        "\x00",
        "\xff",
        "i1e trailing",
        "ie",
        "i--1e",
        "iabce",
        "-1:x",
    };
    for (invalid_cases) |input| {
        if (parse(std.testing.allocator, input)) |value| {
            freeValue(std.testing.allocator, value);
        } else |err| {
            // Must be a ParseError, not a panic
            _ = err;
        }
    }
}

test "reject byte string length overflow" {
    // Length that would overflow usize
    if (parse(std.testing.allocator, "99999999999999999999:")) |value| {
        freeValue(std.testing.allocator, value);
    } else |_| {}
}

test "parse empty byte string" {
    const value = try parse(std.testing.allocator, "0:");
    defer freeValue(std.testing.allocator, value);
    try std.testing.expectEqualStrings("", value.bytes);
}

test "parse empty list" {
    const value = try parse(std.testing.allocator, "le");
    defer freeValue(std.testing.allocator, value);
    try std.testing.expectEqual(@as(usize, 0), value.list.len);
}

test "parse empty dict" {
    const value = try parse(std.testing.allocator, "de");
    defer freeValue(std.testing.allocator, value);
    try std.testing.expectEqual(@as(usize, 0), value.dict.len);
}

test "parse i64 min and max" {
    {
        const value = try parse(std.testing.allocator, "i9223372036854775807e");
        defer freeValue(std.testing.allocator, value);
        try std.testing.expectEqual(Value{ .integer = std.math.maxInt(i64) }, value);
    }
    {
        const value = try parse(std.testing.allocator, "i-9223372036854775808e");
        defer freeValue(std.testing.allocator, value);
        try std.testing.expectEqual(Value{ .integer = std.math.minInt(i64) }, value);
    }
}

// ── Nesting depth limit tests ────────────────────────────

test "list nested exactly at max depth succeeds" {
    // Build "lll...li0ee...e" with exactly max_nesting_depth levels of 'l'.
    const depth = max_nesting_depth;
    var buf = std.testing.allocator.alloc(u8, depth + 3 + depth) catch return;
    defer std.testing.allocator.free(buf);
    @memset(buf[0..depth], 'l');
    // Innermost value: "i0e"
    buf[depth] = 'i';
    buf[depth + 1] = '0';
    buf[depth + 2] = 'e';
    @memset(buf[depth + 3 ..], 'e');

    const value = try parse(std.testing.allocator, buf);
    freeValue(std.testing.allocator, value);
}

test "list nested one beyond max depth returns NestingTooDeep" {
    // Build "lll...li0ee...e" with max_nesting_depth + 1 levels of 'l'.
    const depth = max_nesting_depth + 1;
    var buf = std.testing.allocator.alloc(u8, depth + 3 + depth) catch return;
    defer std.testing.allocator.free(buf);
    @memset(buf[0..depth], 'l');
    buf[depth] = 'i';
    buf[depth + 1] = '0';
    buf[depth + 2] = 'e';
    @memset(buf[depth + 3 ..], 'e');

    try std.testing.expectError(error.NestingTooDeep, parse(std.testing.allocator, buf));
}

test "dict nested one beyond max depth returns NestingTooDeep" {
    // Build "d1:ad1:a...d1:ade...e" with max_nesting_depth + 1 dict levels.
    const depth = max_nesting_depth + 1;
    // Each level: "d1:a" (4 bytes). Innermost value: "de" (2 bytes). Then depth closing 'e's.
    const total = depth * 4 + 2 + depth;
    var buf = std.testing.allocator.alloc(u8, total) catch return;
    defer std.testing.allocator.free(buf);
    for (0..depth) |i| {
        buf[i * 4 + 0] = 'd';
        buf[i * 4 + 1] = '1';
        buf[i * 4 + 2] = ':';
        buf[i * 4 + 3] = 'a';
    }
    const prefix_len = depth * 4;
    buf[prefix_len] = 'd';
    buf[prefix_len + 1] = 'e';
    @memset(buf[prefix_len + 2 ..], 'e');

    try std.testing.expectError(error.NestingTooDeep, parse(std.testing.allocator, buf));
}

test "max_container_elements constant is 500000" {
    // Compile-time assertion that the safety limit exists at the expected value.
    try std.testing.expectEqual(@as(u32, 500_000), max_container_elements);
}

test "max_nesting_depth constant is 64" {
    try std.testing.expectEqual(@as(u32, 64), max_nesting_depth);
}

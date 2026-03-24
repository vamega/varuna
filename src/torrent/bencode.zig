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

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Value {
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

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn parseValue(self: *Parser) !Value {
        const next = self.peek() orelse return error.UnexpectedEndOfStream;
        return switch (next) {
            'i' => .{ .integer = try self.parseInteger() },
            'l' => .{ .list = try self.parseList() },
            'd' => .{ .dict = try self.parseDict() },
            '0'...'9' => .{ .bytes = try self.parseBytes() },
            else => error.InvalidPrefix,
        };
    }

    fn parseInteger(self: *Parser) !i64 {
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

    fn parseBytes(self: *Parser) ![]const u8 {
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

    fn parseList(self: *Parser) ![]Value {
        try self.expectByte('l');

        var values: std.ArrayListUnmanaged(Value) = .empty;
        errdefer values.deinit(self.allocator);

        while (true) {
            const next = self.peek() orelse return error.UnexpectedEndOfStream;
            if (next == 'e') {
                self.index += 1;
                return try values.toOwnedSlice(self.allocator);
            }

            try values.append(self.allocator, try self.parseValue());
        }
    }

    fn parseDict(self: *Parser) ![]Value.Entry {
        try self.expectByte('d');

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

            const key = try self.parseBytes();
            const value = try self.parseValue();
            try entries.append(self.allocator, .{
                .key = key,
                .value = value,
            });
        }
    }

    fn expectByte(self: *Parser, byte: u8) !void {
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

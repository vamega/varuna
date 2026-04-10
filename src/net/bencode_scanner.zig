const std = @import("std");

/// A zero-allocation bencode scanner parameterized by error type.
///
/// Both the BEP 10 extension handshake decoder (`extensions.zig`) and
/// the BEP 9 ut_metadata decoder (`ut_metadata.zig`) need a lightweight
/// bencode pull-parser that works on a borrowed `[]const u8` slice.
/// This generic extracts that shared logic so both callers can use their
/// own error names.
///
/// `ErrorSet` must be a Zig error set type (e.g. `error{InvalidMessage}`).
/// All parse failures are reported as the first error in that set.
pub fn BencodeScanner(comptime ErrorSet: type) type {
    // Extract the single sentinel error value from the set so every
    // method can `return sentinel` instead of hard-coding an error name.
    const set_info = @typeInfo(ErrorSet).error_set.?;
    const sentinel: ErrorSet = @field(anyerror, set_info[0].name);

    return struct {
        data: []const u8,
        pos: usize = 0,

        const Self = @This();

        pub fn init(data: []const u8) Self {
            return .{ .data = data };
        }

        pub fn peek(self: *const Self) ?u8 {
            if (self.pos >= self.data.len) return null;
            return self.data[self.pos];
        }

        pub fn isAtEnd(self: *const Self) bool {
            return self.pos == self.data.len;
        }

        pub fn expectByte(self: *Self, expected: u8) ErrorSet!void {
            if (self.peek() != expected) return sentinel;
            self.pos += 1;
        }

        pub fn parseBytes(self: *Self) ErrorSet![]const u8 {
            const start = self.pos;
            while (self.peek()) |byte| {
                if (byte == ':') break;
                if (!std.ascii.isDigit(byte)) return sentinel;
                self.pos += 1;
            }
            if (self.peek() != ':') return sentinel;

            const len_slice = self.data[start..self.pos];
            if (len_slice.len == 0) return sentinel;

            self.pos += 1;
            const len = std.fmt.parseUnsigned(usize, len_slice, 10) catch return sentinel;
            const end = self.pos + len;
            if (end > self.data.len) return sentinel;

            defer self.pos = end;
            return self.data[self.pos..end];
        }

        pub fn parseInteger(self: *Self) ErrorSet!i64 {
            try self.expectByte('i');
            const start = self.pos;
            while (self.peek()) |byte| {
                if (byte == 'e') break;
                self.pos += 1;
            }
            if (self.peek() != 'e') return sentinel;

            const digits = self.data[start..self.pos];
            if (digits.len == 0) return sentinel;

            self.pos += 1;
            return std.fmt.parseInt(i64, digits, 10) catch sentinel;
        }

        pub fn skipValue(self: *Self) ErrorSet!void {
            const next = self.peek() orelse return sentinel;
            switch (next) {
                'i' => _ = try self.parseInteger(),
                'l' => {
                    self.pos += 1;
                    while (true) {
                        const item = self.peek() orelse return sentinel;
                        if (item == 'e') {
                            self.pos += 1;
                            return;
                        }
                        try self.skipValue();
                    }
                },
                'd' => {
                    self.pos += 1;
                    while (true) {
                        const item = self.peek() orelse return sentinel;
                        if (item == 'e') {
                            self.pos += 1;
                            return;
                        }
                        _ = try self.parseBytes();
                        try self.skipValue();
                    }
                },
                '0'...'9' => _ = try self.parseBytes(),
                else => return sentinel,
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────

const testing = std.testing;
const TestScanner = BencodeScanner(error{TestError});

test "parseBytes decodes bencoded string" {
    var s = TestScanner.init("5:hello");
    const result = try s.parseBytes();
    try testing.expectEqualStrings("hello", result);
    try testing.expect(s.isAtEnd());
}

test "parseInteger decodes bencoded integer" {
    var s = TestScanner.init("i42e");
    const result = try s.parseInteger();
    try testing.expectEqual(@as(i64, 42), result);
    try testing.expect(s.isAtEnd());
}

test "parseInteger decodes negative integer" {
    var s = TestScanner.init("i-7e");
    const result = try s.parseInteger();
    try testing.expectEqual(@as(i64, -7), result);
}

test "skipValue skips integer" {
    var s = TestScanner.init("i99e3:abc");
    try s.skipValue();
    const rest = try s.parseBytes();
    try testing.expectEqualStrings("abc", rest);
}

test "skipValue skips list" {
    var s = TestScanner.init("li1ei2ee3:end");
    try s.skipValue();
    const rest = try s.parseBytes();
    try testing.expectEqualStrings("end", rest);
}

test "skipValue skips dict" {
    var s = TestScanner.init("d3:keyi1ee4:next");
    try s.skipValue();
    const rest = try s.parseBytes();
    try testing.expectEqualStrings("next", rest);
}

test "expectByte rejects wrong byte" {
    var s = TestScanner.init("x");
    try testing.expectError(error.TestError, s.expectByte('d'));
}

test "peek returns null at end" {
    var s = TestScanner.init("");
    try testing.expect(s.peek() == null);
    try testing.expect(s.isAtEnd());
}

test "parseBytes rejects truncated input" {
    var s = TestScanner.init("5:hi");
    try testing.expectError(error.TestError, s.parseBytes());
}

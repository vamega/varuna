const std = @import("std");

const Writer = std.Io.Writer;

/// Escape a string for safe inclusion in a JSON string value.
/// Returns a formatter that can be used with `{s}` or `{f}` in format strings.
/// The output escapes `"`, `\`, and control characters per RFC 8259.
pub fn jsonSafe(s: []const u8) std.fmt.Alt([]const u8, formatJsonSafe) {
    return .{ .data = s };
}

fn formatJsonSafe(s: []const u8, writer: *Writer) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    // Other control characters: \u00XX
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Tests ─────────────────────────────────────────────────

test "escapes double quotes" {
    try std.testing.expectFmt("hello\\\"world", "{f}", .{jsonSafe("hello\"world")});
}

test "escapes backslash" {
    try std.testing.expectFmt("path\\\\to\\\\file", "{f}", .{jsonSafe("path\\to\\file")});
}

test "escapes control characters" {
    try std.testing.expectFmt("line1\\nline2\\ttab", "{f}", .{jsonSafe("line1\nline2\ttab")});
}

test "passes through normal text" {
    try std.testing.expectFmt("normal text 123", "{f}", .{jsonSafe("normal text 123")});
}

test "escapes low control characters as unicode" {
    try std.testing.expectFmt("\\u0001\\u0002", "{f}", .{jsonSafe("\x01\x02")});
}

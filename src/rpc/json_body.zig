const std = @import("std");
const server = @import("server.zig");

pub const StatusBody = struct {
    status: []const u8,
};

pub const ErrorBody = struct {
    @"error": []const u8,
};

pub const Fixed4 = struct {
    value: f64,

    pub fn jsonStringify(self: Fixed4, writer: anytype) !void {
        try writer.print("{d:.4}", .{self.value});
    }
};

pub fn append(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const body = try alloc(allocator, value);
    defer allocator.free(body);
    try out.appendSlice(allocator, body);
}

pub fn alloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.write(value);
    return out.toOwnedSlice();
}

pub fn response(allocator: std.mem.Allocator, status: u16, value: anytype) server.Response {
    const body = alloc(allocator, value) catch
        return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
    return .{ .status = status, .body = body, .owned_body = body };
}

pub fn ok(allocator: std.mem.Allocator) server.Response {
    return response(allocator, 200, StatusBody{ .status = "ok" });
}

pub fn errorMessage(allocator: std.mem.Allocator, status: u16, message: []const u8) server.Response {
    return response(allocator, status, ErrorBody{ .@"error" = message });
}

test "alloc serializes structures and escapes string fields" {
    const body = try alloc(std.testing.allocator, .{
        .status = "ok",
        .message = "file \"ready\"",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"message\":\"file \\\"ready\\\"\"}", body);
}

test "Fixed4 preserves qBittorrent decimal formatting" {
    const body = try alloc(std.testing.allocator, .{ .ratio = Fixed4{ .value = 1.5 } });
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("{\"ratio\":1.5000}", body);
}

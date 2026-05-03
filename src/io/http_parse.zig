const std = @import("std");

/// Parsed components of an HTTP/HTTPS URL.
pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_https: bool,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8 = "GET",
    host: []const u8,
    path: []const u8,
    body: []const u8 = "",
    content_type: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    extra_headers: []const Header = &.{},
    connection: []const u8 = "keep-alive",
    user_agent: []const u8 = "varuna/0.1",
};

pub const ParsedResponse = struct {
    status: u16,
    headers: []const u8,
    body: []const u8,

    pub fn headerValue(self: ParsedResponse, name: []const u8) ?[]const u8 {
        return findHeaderValue(self.headers, name);
    }
};

pub fn appendRequest(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), request: Request) !void {
    try buf.print(allocator, "{s} {s} HTTP/1.1\r\n", .{ request.method, request.path });
    try buf.print(allocator, "Host: {s}\r\n", .{request.host});
    try buf.print(allocator, "Connection: {s}\r\n", .{request.connection});
    try buf.print(allocator, "User-Agent: {s}\r\n", .{request.user_agent});
    if (request.content_type) |content_type| {
        try buf.print(allocator, "Content-Type: {s}\r\n", .{content_type});
    }
    if (request.cookie) |cookie| {
        try buf.print(allocator, "Cookie: {s}\r\n", .{cookie});
    }
    for (request.extra_headers) |header| {
        if (header.name.len == 0) continue;
        try buf.print(allocator, "{s}: {s}\r\n", .{ header.name, header.value });
    }
    if (request.body.len > 0 or !std.mem.eql(u8, request.method, "GET")) {
        try buf.print(allocator, "Content-Length: {}\r\n", .{request.body.len});
    }
    try buf.appendSlice(allocator, "\r\n");
    try buf.appendSlice(allocator, request.body);
}

/// Parse an HTTP or HTTPS URL into its components.
/// The returned slices point into the input `url` — no allocation.
pub fn parseUrl(url: []const u8) !ParsedUrl {
    var is_https = false;
    var default_port: u16 = 80;

    const after_scheme = if (std.mem.startsWith(u8, url, "https://")) blk: {
        is_https = true;
        default_port = 443;
        break :blk url[8..];
    } else if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else
        url;

    // Split host:port from path
    const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const host_port = after_scheme[0..path_start];
    const path = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";

    // Split host and port
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        const port_str = host_port[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        return .{
            .host = host_port[0..colon],
            .port = port,
            .path = path,
            .is_https = is_https,
        };
    }

    return .{
        .host = host_port,
        .port = default_port,
        .path = path,
        .is_https = is_https,
    };
}

test "parseUrl http with port" {
    const p = try parseUrl("http://tracker.example.com:8080/announce");
    try std.testing.expectEqualStrings("tracker.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 8080), p.port);
    try std.testing.expectEqualStrings("/announce", p.path);
    try std.testing.expect(!p.is_https);
}

test "parseUrl https default port" {
    const p = try parseUrl("https://tracker.example.com/announce");
    try std.testing.expectEqualStrings("tracker.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 443), p.port);
    try std.testing.expect(p.is_https);
}

test "parseUrl http default port" {
    const p = try parseUrl("http://example.com/path");
    try std.testing.expectEqual(@as(u16, 80), p.port);
}

// ── HTTP response parsing ─────────────────────────────────
//
// Pure functions for parsing HTTP/1.1 response headers and status lines.
// Used by HttpExecutor plus parser-focused tests and benchmarks.

/// Find the start of the HTTP response body (after the \r\n\r\n separator).
pub fn findBodyStart(data: []const u8) ?usize {
    const sep = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, sep)) |pos| {
        return pos + sep.len;
    }
    return null;
}

/// Parse the Content-Length header value from raw HTTP headers.
pub fn parseContentLength(headers: []const u8) ?usize {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (iter.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

/// Check if the Connection header is set to "close".
pub fn parseConnectionClose(headers: []const u8) bool {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (iter.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "connection:")) {
            const value = std.mem.trim(u8, line["connection:".len..], " ");
            return std.ascii.eqlIgnoreCase(value, "close");
        }
    }
    return false;
}

/// Parse the HTTP status code from the response status line.
pub fn parseStatusCode(data: []const u8) ?u16 {
    if (data.len < 12) return null;
    if (!std.mem.startsWith(u8, data, "HTTP/")) return null;
    const space1 = std.mem.indexOfScalar(u8, data, ' ') orelse return null;
    if (space1 + 4 > data.len) return null;
    return std.fmt.parseInt(u16, data[space1 + 1 .. space1 + 4], 10) catch null;
}

pub fn findHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

pub fn parseResponse(data: []const u8) !ParsedResponse {
    const body_start = findBodyStart(data) orelse return error.IncompleteResponse;
    const status = parseStatusCode(data) orelse return error.InvalidStatusLine;
    return .{
        .status = status,
        .headers = data[0..body_start],
        .body = data[body_start..],
    };
}

test "parseStatusCode" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("garbage"));
}

test "findBodyStart" {
    try std.testing.expectEqual(@as(?usize, 19), findBodyStart("HTTP/1.1 200 OK\r\n\r\nbody"));
    try std.testing.expectEqual(@as(?usize, null), findBodyStart("no separator"));
}

test "parseContentLength" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 42\r\nConnection: close\r\n";
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength(headers));
}

test "parseConnectionClose" {
    try std.testing.expect(parseConnectionClose("HTTP/1.1 200 OK\r\nConnection: close\r\n"));
    try std.testing.expect(!parseConnectionClose("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n"));
}

test "appendRequest includes method body content type cookie and custom headers" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try appendRequest(allocator, &buf, .{
        .method = "POST",
        .host = "127.0.0.1",
        .path = "/api/v2/app/setPreferences",
        .body = "dht=false",
        .content_type = "application/x-www-form-urlencoded",
        .cookie = "SID=abc123",
        .extra_headers = &.{
            .{ .name = "X-Test", .value = "yes" },
        },
        .connection = "close",
        .user_agent = "varuna-ctl/test",
    });

    try std.testing.expectEqualStrings(
        "POST /api/v2/app/setPreferences HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Connection: close\r\n" ++
            "User-Agent: varuna-ctl/test\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\n" ++
            "Cookie: SID=abc123\r\n" ++
            "X-Test: yes\r\n" ++
            "Content-Length: 9\r\n" ++
            "\r\n" ++
            "dht=false",
        buf.items,
    );
}

test "parseResponse returns status headers and complete body" {
    const raw = "HTTP/1.1 403 Forbidden\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "Forbidden";

    const parsed = try parseResponse(raw);
    try std.testing.expectEqual(@as(u16, 403), parsed.status);
    try std.testing.expectEqualStrings("Forbidden", parsed.body);
    try std.testing.expectEqualStrings("text/plain", parsed.headerValue("content-type").?);
}

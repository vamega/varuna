const std = @import("std");

/// Parsed components of an HTTP/HTTPS URL.
pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_https: bool,
};

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
// Used by both HttpExecutor (daemon, io_uring) and HttpClient (CLI, blocking).

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

test "parseStatusCode" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("garbage"));
}

test "findBodyStart" {
    try std.testing.expectEqual(@as(?usize, 20), findBodyStart("HTTP/1.1 200 OK\r\n\r\nbody"));
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

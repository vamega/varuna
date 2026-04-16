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

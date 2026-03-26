const std = @import("std");
const posix = std.posix;
const Ring = @import("ring.zig").Ring;

/// Minimal HTTP/1.1 GET client over io_uring.
/// Designed for tracker announces: simple GET requests with small responses.
pub const HttpClient = struct {
    ring: *Ring,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ring: *Ring) HttpClient {
        return .{
            .ring = ring,
            .allocator = allocator,
        };
    }

    /// Perform an HTTP GET request and return the response body.
    /// DNS resolution runs on a background thread to avoid blocking the ring.
    pub fn get(self: *HttpClient, url: []const u8) !HttpResponse {
        const parsed = try parseUrl(url);

        // Resolve DNS on a background thread
        const address = try resolveDns(self.allocator, parsed.host, parsed.port);

        // Connect via io_uring
        const fd = try self.ring.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);

        self.ring.connect_timeout(fd, &address.any, address.getOsSockLen(), 10) catch |err| {
            if (err == error.ConnectionTimedOut) return error.ConnectionTimedOut;
            return err;
        };

        // Build and send HTTP request
        var request_buf = std.ArrayList(u8).empty;
        defer request_buf.deinit(self.allocator);

        try request_buf.print(self.allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{
            parsed.path,
            parsed.host,
        });

        try self.ring.send_all(fd, request_buf.items);

        // Receive response
        var response_buf = std.ArrayList(u8).empty;
        errdefer response_buf.deinit(self.allocator);

        var recv_buf: [8192]u8 = undefined;
        while (true) {
            const n = self.ring.recv(fd, &recv_buf) catch |err| {
                if (response_buf.items.len > 0) break; // treat as end of response
                return err;
            };
            if (n == 0) break;
            try response_buf.appendSlice(self.allocator, recv_buf[0..n]);

            // Check if we have the full response
            if (findBodyStart(response_buf.items)) |body_start| {
                const content_length = parseContentLength(response_buf.items[0..body_start]);
                if (content_length) |cl| {
                    const total_expected = body_start + cl;
                    if (response_buf.items.len >= total_expected) break;
                }
                // If no Content-Length, keep reading until connection closes
            }
        }

        posix.close(fd);

        // Parse response
        const body_start = findBodyStart(response_buf.items) orelse return error.InvalidHttpResponse;
        const status = parseStatusCode(response_buf.items) orelse return error.InvalidHttpResponse;

        return .{
            .status = status,
            .body = response_buf.items[body_start..],
            .raw = response_buf,
            .allocator = self.allocator,
        };
    }
};

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    raw: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.raw.deinit(self.allocator);
    }
};

// ── URL parsing ───────────────────────────────────────────

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) !ParsedUrl {
    // Strip "http://" prefix
    const after_scheme = if (std.mem.startsWith(u8, url, "http://"))
        url[7..]
    else if (std.mem.startsWith(u8, url, "https://"))
        return error.HttpsNotSupported
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
        };
    }

    return .{
        .host = host_port,
        .port = 80,
        .path = path,
    };
}

// ── DNS resolution (threadpool) ───────────────────────────

const DnsResult = struct {
    address: ?std.net.Address = null,
    err: ?anyerror = null,
    done: std.Thread.ResetEvent = .{},
};

fn resolveDns(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    // For numeric IPs, parse directly without DNS
    if (std.net.Address.parseIp4(host, port)) |addr| {
        return addr;
    } else |_| {}
    if (std.net.Address.parseIp6(host, port)) |addr| {
        return addr;
    } else |_| {}

    // DNS resolution on a background thread
    var result = DnsResult{};

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);

    const thread = try std.Thread.spawn(.{}, dnsWorker, .{ host_z, port, &result });
    defer thread.join();

    // Wait for DNS result with timeout
    result.done.timedWait(5 * std.time.ns_per_s) catch return error.DnsTimeout;

    if (result.err) |err| return err;
    return result.address orelse error.DnsResolutionFailed;
}

fn dnsWorker(host: [:0]const u8, port: u16, result: *DnsResult) void {
    const list = std.net.getAddressList(std.heap.page_allocator, host, port) catch |err| {
        result.err = err;
        result.done.set();
        return;
    };
    defer list.deinit();

    if (list.addrs.len > 0) {
        result.address = list.addrs[0];
    } else {
        result.err = error.DnsResolutionFailed;
    }
    result.done.set();
}

// ── HTTP response parsing ─────────────────────────────────

fn findBodyStart(data: []const u8) ?usize {
    const sep = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, sep)) |pos| {
        return pos + sep.len;
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (iter.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

fn parseStatusCode(data: []const u8) ?u16 {
    // "HTTP/1.1 200 OK\r\n"
    if (data.len < 12) return null;
    if (!std.mem.startsWith(u8, data, "HTTP/")) return null;
    const space1 = std.mem.indexOfScalar(u8, data, ' ') orelse return null;
    if (space1 + 4 > data.len) return null;
    return std.fmt.parseInt(u16, data[space1 + 1 .. space1 + 4], 10) catch null;
}

// ── Tests ─────────────────────────────────────────────────

test "parse url with port" {
    const parsed = try parseUrl("http://tracker.example.com:8080/announce?info_hash=abc");
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expectEqualStrings("/announce?info_hash=abc", parsed.path);
}

test "parse url default port" {
    const parsed = try parseUrl("http://tracker.example.com/announce");
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
    try std.testing.expectEqualStrings("/announce", parsed.path);
}

test "parse url no path" {
    const parsed = try parseUrl("http://example.com:6969");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
    try std.testing.expectEqualStrings("/", parsed.path);
}

test "parse status code" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("garbage"));
}

test "find body start" {
    try std.testing.expectEqual(@as(?usize, 20), findBodyStart("HTTP/1.1 200 OK\r\n\r\nbody"));
    try std.testing.expectEqual(@as(?usize, null), findBodyStart("no separator"));
}

test "parse content length" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 42\r\nConnection: close\r\n";
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength(headers));
}

test "http get against local fake server" {
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    // Start a fake HTTP server
    var server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.net.Server) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();

            var buf: [4096]u8 = undefined;
            var used: usize = 0;
            while (used < buf.len) {
                const n = conn.stream.read(buf[used..]) catch return;
                if (n == 0) return;
                used += n;
                if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
            }

            const response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world";
            conn.stream.writeAll(response) catch {};
        }
    }.run, .{&server});
    defer server_thread.join();

    var client = HttpClient.init(std.testing.allocator, &ring);

    var url_buf = std.ArrayList(u8).empty;
    defer url_buf.deinit(std.testing.allocator);
    try url_buf.print(std.testing.allocator, "http://127.0.0.1:{}/test", .{port});

    var response = try client.get(url_buf.items);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("hello world", response.body);
}

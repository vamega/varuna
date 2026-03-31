const std = @import("std");
const posix = std.posix;
const Ring = @import("ring.zig").Ring;
const DnsResolver = @import("dns.zig").DnsResolver;
const build_options = @import("build_options");
const TlsStream = @import("tls.zig").TlsStream;

/// Minimal HTTP/1.1 GET client over io_uring.
/// Designed for tracker announces: simple GET requests with small responses.
/// Supports both HTTP and HTTPS (when built with -Dtls=boringssl).
pub const HttpClient = struct {
    ring: *Ring,
    allocator: std.mem.Allocator,
    dns_resolver: ?*DnsResolver = null,

    pub fn init(allocator: std.mem.Allocator, ring: *Ring) HttpClient {
        return .{
            .ring = ring,
            .allocator = allocator,
        };
    }

    /// Create an HttpClient with a shared DNS cache.
    pub fn initWithDns(allocator: std.mem.Allocator, ring: *Ring, dns_resolver: *DnsResolver) HttpClient {
        return .{
            .ring = ring,
            .allocator = allocator,
            .dns_resolver = dns_resolver,
        };
    }

    /// Perform an HTTP GET request and return the response body.
    /// DNS resolution runs on a background thread to avoid blocking the ring.
    /// When a DnsResolver is attached, results are cached across requests.
    /// Supports both http:// and https:// URLs.
    pub fn get(self: *HttpClient, url: []const u8) !HttpResponse {
        return self.getWithHeaders(url, &.{});
    }

    /// Perform an HTTP GET with additional headers (e.g. Range for BEP 19 web seeds).
    /// `extra_headers` is a slice of pre-formatted header lines (without trailing \r\n).
    pub fn getWithHeaders(self: *HttpClient, url: []const u8, extra_headers: []const []const u8) !HttpResponse {
        const parsed = try parseUrl(url);

        if (parsed.is_https) {
            return self.getHttpsWithHeaders(parsed, extra_headers);
        }

        return self.getHttpWithHeaders(parsed, extra_headers);
    }

    /// Convenience: HTTP GET with a byte Range header (BEP 19 web seeding).
    /// Returns the response; caller should check status == 206 for partial content.
    pub fn getRange(self: *HttpClient, url: []const u8, range_start: u64, range_end: u64) !HttpResponse {
        var range_hdr_buf: [128]u8 = undefined;
        const range_hdr = std.fmt.bufPrint(&range_hdr_buf, "Range: bytes={}-{}", .{ range_start, range_end }) catch return error.RangeHeaderTooLong;
        const headers = [_][]const u8{range_hdr};
        return self.getWithHeaders(url, &headers);
    }

    /// Plain HTTP GET over io_uring.
    fn getHttp(self: *HttpClient, parsed: ParsedUrl) !HttpResponse {
        return self.getHttpWithHeaders(parsed, &.{});
    }

    /// Plain HTTP GET over io_uring with additional headers.
    fn getHttpWithHeaders(self: *HttpClient, parsed: ParsedUrl, extra_headers: []const []const u8) !HttpResponse {
        // Resolve DNS -- use shared cache if available, otherwise one-shot
        const address = if (self.dns_resolver) |r|
            try r.resolve(self.allocator, parsed.host, parsed.port)
        else
            try @import("dns.zig").resolveOnce(self.allocator, parsed.host, parsed.port);

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

        try request_buf.print(self.allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\n", .{
            parsed.path,
            parsed.host,
        });
        for (extra_headers) |hdr| {
            try request_buf.appendSlice(self.allocator, hdr);
            try request_buf.appendSlice(self.allocator, "\r\n");
        }
        try request_buf.appendSlice(self.allocator, "Connection: close\r\n\r\n");

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

    /// HTTPS GET: TLS handshake + HTTP tunneled through BoringSSL BIO pair,
    /// with all network I/O on io_uring.
    fn getHttps(self: *HttpClient, parsed: ParsedUrl) !HttpResponse {
        return self.getHttpsWithHeaders(parsed, &.{});
    }

    /// HTTPS GET with additional headers.
    fn getHttpsWithHeaders(self: *HttpClient, parsed: ParsedUrl, extra_headers: []const []const u8) !HttpResponse {
        if (build_options.tls_backend != .boringssl) {
            return error.HttpsNotSupported;
        }

        // Resolve DNS
        const address = if (self.dns_resolver) |r|
            try r.resolve(self.allocator, parsed.host, parsed.port)
        else
            try @import("dns.zig").resolveOnce(self.allocator, parsed.host, parsed.port);

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

        // Initialize TLS
        var tls_stream = try TlsStream.init(self.allocator, parsed.host);
        defer tls_stream.deinit();

        // Perform TLS handshake
        try self.tlsHandshake(fd, &tls_stream);

        // Build HTTP request
        var request_buf = std.ArrayList(u8).empty;
        defer request_buf.deinit(self.allocator);

        try request_buf.print(self.allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\n", .{
            parsed.path,
            parsed.host,
        });
        for (extra_headers) |hdr| {
            try request_buf.appendSlice(self.allocator, hdr);
            try request_buf.appendSlice(self.allocator, "\r\n");
        }
        try request_buf.appendSlice(self.allocator, "Connection: close\r\n\r\n");

        // Send HTTP request through TLS
        try self.tlsSendAll(fd, &tls_stream, request_buf.items);

        // Receive response through TLS
        var response_buf = std.ArrayList(u8).empty;
        errdefer response_buf.deinit(self.allocator);

        try self.tlsRecvResponse(fd, &tls_stream, &response_buf);

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

    /// Drive the TLS handshake to completion using io_uring for all network I/O.
    fn tlsHandshake(self: *HttpClient, fd: posix.fd_t, tls_stream: *TlsStream) !void {
        var send_buf: [16384]u8 = undefined;
        var recv_buf: [16384]u8 = undefined;

        var iterations: u32 = 0;
        const max_iterations: u32 = 100; // prevent infinite loops

        while (iterations < max_iterations) : (iterations += 1) {
            const result = tls_stream.doHandshake() catch return error.TlsHandshakeFailed;

            switch (result) {
                .complete => return,
                .want_write, .want_read => {
                    // Always flush any pending outbound ciphertext first
                    try self.tlsFlushPending(fd, tls_stream, &send_buf);

                    if (result == .want_read) {
                        // Need more data from the server
                        const n = self.ring.recv(fd, &recv_buf) catch |err| {
                            if (err == error.ConnectionClosed) return error.TlsHandshakeFailed;
                            return err;
                        };
                        if (n == 0) return error.TlsHandshakeFailed;
                        tls_stream.feedRecv(recv_buf[0..n]) catch return error.TlsHandshakeFailed;
                    }
                },
            }
        }

        return error.TlsHandshakeFailed;
    }

    /// Flush all pending outbound ciphertext from the TLS stream via io_uring send.
    fn tlsFlushPending(self: *HttpClient, fd: posix.fd_t, tls_stream: *TlsStream, send_buf: []u8) !void {
        while (true) {
            const n = tls_stream.pendingSend(send_buf) catch return;
            if (n == 0) break;
            try self.ring.send_all(fd, send_buf[0..n]);
        }
    }

    /// Send all plaintext data through the TLS stream, flushing ciphertext via io_uring.
    fn tlsSendAll(self: *HttpClient, fd: posix.fd_t, tls_stream: *TlsStream, data: []const u8) !void {
        var send_buf: [16384]u8 = undefined;
        var total: usize = 0;

        while (total < data.len) {
            const n = tls_stream.writePlaintext(data[total..]) catch return error.TlsWriteFailed;
            if (n == 0) {
                // BoringSSL wants to flush -- send pending ciphertext
                try self.tlsFlushPending(fd, tls_stream, &send_buf);
                continue;
            }
            total += n;
            try self.tlsFlushPending(fd, tls_stream, &send_buf);
        }
    }

    /// Receive an HTTP response through the TLS stream.
    fn tlsRecvResponse(self: *HttpClient, fd: posix.fd_t, tls_stream: *TlsStream, response_buf: *std.ArrayList(u8)) !void {
        var recv_buf: [16384]u8 = undefined;
        var plaintext_buf: [16384]u8 = undefined;
        var send_buf: [16384]u8 = undefined;

        var iterations: u32 = 0;
        const max_iterations: u32 = 10000;

        while (iterations < max_iterations) : (iterations += 1) {
            // Try to read any already-decrypted plaintext
            const plain_n = tls_stream.readPlaintext(&plaintext_buf) catch return error.TlsReadFailed;
            if (plain_n > 0) {
                try response_buf.appendSlice(self.allocator, plaintext_buf[0..plain_n]);

                // Check if we have the full HTTP response
                if (self.isResponseComplete(response_buf.items)) break;
                continue;
            }

            // No plaintext available -- need more ciphertext from the network
            const n = self.ring.recv(fd, &recv_buf) catch |err| {
                if (response_buf.items.len > 0) break;
                return err;
            };
            if (n == 0) break; // connection closed

            tls_stream.feedRecv(recv_buf[0..n]) catch return error.TlsReadFailed;

            // Flush any renegotiation/alert data BoringSSL wants to send
            self.tlsFlushPending(fd, tls_stream, &send_buf) catch {};
        }
    }

    fn isResponseComplete(self: *HttpClient, data: []const u8) bool {
        _ = self;
        if (findBodyStart(data)) |body_start| {
            const content_length = parseContentLength(data[0..body_start]);
            if (content_length) |cl| {
                return data.len >= body_start + cl;
            }
            // No Content-Length -- need to read until connection closes
            return false;
        }
        return false;
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

pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_https: bool,
};

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

// ── HTTP response parsing ─────────────────────────────────

pub fn findBodyStart(data: []const u8) ?usize {
    const sep = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, sep)) |pos| {
        return pos + sep.len;
    }
    return null;
}

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

pub fn parseStatusCode(data: []const u8) ?u16 {
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
    try std.testing.expect(!parsed.is_https);
}

test "parse url default port" {
    const parsed = try parseUrl("http://tracker.example.com/announce");
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
    try std.testing.expectEqualStrings("/announce", parsed.path);
    try std.testing.expect(!parsed.is_https);
}

test "parse url no path" {
    const parsed = try parseUrl("http://example.com:6969");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
    try std.testing.expectEqualStrings("/", parsed.path);
    try std.testing.expect(!parsed.is_https);
}

test "parse https url" {
    const parsed = try parseUrl("https://tracker.example.com/announce");
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("/announce", parsed.path);
    try std.testing.expect(parsed.is_https);
}

test "parse https url with port" {
    const parsed = try parseUrl("https://tracker.example.com:8443/announce?info_hash=abc");
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 8443), parsed.port);
    try std.testing.expectEqualStrings("/announce?info_hash=abc", parsed.path);
    try std.testing.expect(parsed.is_https);
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

// ── Fuzz and edge case tests for HTTP response parsing ────

test "fuzz HTTP response parsers" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // All three parsers must not panic on any input
            _ = findBodyStart(input);
            _ = parseContentLength(input);
            _ = parseStatusCode(input);
        }
    }.run, .{
        .corpus = &.{
            "",
            "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world",
            "HTTP/1.1 404 Not Found\r\n\r\n",
            "HTTP/1.0 500 Internal Server Error\r\n\r\n",
            "garbage",
            "\r\n\r\n",
            "HTTP/",
            "HTTP/1.1 ",
            "HTTP/1.1 999 X\r\n\r\n",
            "Content-Length: 99999999999999999999\r\n\r\n",
        },
    });
}

test "fuzz URL parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            _ = parseUrl(input) catch return;
        }
    }.run, .{
        .corpus = &.{
            "",
            "http://example.com",
            "http://example.com:8080/path",
            "https://example.com",
            "https://example.com:8443/path",
            "example.com:80/path",
            "http://[::1]:8080/path",
            "http://:8080",
            "http://host:99999/path",
        },
    });
}

test "parseStatusCode edge cases" {
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode(""));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("HTTP/1.1"));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("HTTP/1.1 "));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("HTTP/1.1 XX"));
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("GET / HTTP"));
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.0 200 OK\r\n"));
    try std.testing.expectEqual(@as(?u16, 100), parseStatusCode("HTTP/1.1 100 Continue\r\n"));
}

test "parseContentLength edge cases" {
    try std.testing.expectEqual(@as(?usize, null), parseContentLength(""));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("No-Such-Header: 42\r\n"));
    try std.testing.expectEqual(@as(?usize, 0), parseContentLength("Content-Length: 0\r\n"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: abc\r\n"));
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("content-length: 42\r\n"));
}

test "findBodyStart edge cases" {
    try std.testing.expectEqual(@as(?usize, null), findBodyStart(""));
    try std.testing.expectEqual(@as(?usize, null), findBodyStart("\r\n"));
    try std.testing.expectEqual(@as(?usize, null), findBodyStart("\r\n\r"));
    try std.testing.expectEqual(@as(?usize, 4), findBodyStart("\r\n\r\n"));
    try std.testing.expectEqual(@as(?usize, 4), findBodyStart("\r\n\r\nbody here"));
}

test "parseUrl https is recognized" {
    const parsed = try parseUrl("https://example.com");
    try std.testing.expect(parsed.is_https);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
}

test "parseUrl invalid port" {
    try std.testing.expectError(error.InvalidPort, parseUrl("http://example.com:notaport/path"));
    try std.testing.expectError(error.InvalidPort, parseUrl("http://example.com:99999/path"));
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

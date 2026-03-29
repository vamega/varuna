const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("../io/ring.zig").Ring;
const socket_util = @import("../net/socket.zig");
const auth = @import("auth.zig");

const max_api_clients = 64;
const recv_buf_size = 8192;
const max_request_size = 4 * 1024 * 1024; // 4 MiB max for torrent uploads

/// HTTP API server running entirely on io_uring.
/// Accept, recv, parse, route, send -- all via SQEs, no blocking I/O.
pub const ApiServer = struct {
    ring: Ring,
    allocator: std.mem.Allocator,
    listen_fd: posix.fd_t = -1,
    clients: [max_api_clients]ApiClient = [_]ApiClient{.{}} ** max_api_clients,
    handler: *const fn (std.mem.Allocator, Request) Response = defaultHandler,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, bind_addr: []const u8, port: u16) !ApiServer {
        return initWithDevice(allocator, bind_addr, port, null);
    }

    pub fn initWithDevice(allocator: std.mem.Allocator, bind_addr: []const u8, port: u16, bind_device: ?[]const u8) !ApiServer {
        const ring = try Ring.init(64);
        errdefer {
            var r = ring;
            r.deinit();
        }

        // Create and bind listen socket
        const addr = try std.net.Address.parseIp4(bind_addr, port);
        const fd = try posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);

        // SO_REUSEADDR
        const enable: u32 = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

        // SO_BINDTODEVICE if configured
        if (bind_device) |device| {
            try socket_util.applyBindDevice(fd, device);
        }

        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 128);

        return .{
            .ring = ring,
            .allocator = allocator,
            .listen_fd = fd,
        };
    }

    pub fn deinit(self: *ApiServer) void {
        for (&self.clients) |*client| {
            if (client.fd >= 0) {
                posix.close(client.fd);
                client.fd = -1;
            }
            if (client.recv_buf) |buf| {
                self.allocator.free(buf);
                client.recv_buf = null;
            }
        }
        if (self.listen_fd >= 0) posix.close(self.listen_fd);
        self.ring.deinit();
    }

    pub fn setHandler(self: *ApiServer, handler: *const fn (std.mem.Allocator, Request) Response) void {
        self.handler = handler;
    }

    /// Run the API server event loop. Blocks until stopped.
    pub fn run(self: *ApiServer) !void {
        // Submit initial accept
        try self.submitAccept();

        while (self.running) {
            _ = try self.ring.inner.submit_and_wait(1);

            var cqes: [32]linux.io_uring_cqe = undefined;
            const count = try self.ring.inner.copy_cqes(&cqes, 0);

            for (cqes[0..count]) |cqe| {
                self.dispatch(cqe);
            }
        }
    }

    /// Process one batch of CQEs. Non-blocking if no CQEs ready.
    /// Returns true if any CQEs were processed.
    pub fn poll(self: *ApiServer) !bool {
        _ = try self.ring.inner.submit();

        var cqes: [32]linux.io_uring_cqe = undefined;
        const count = try self.ring.inner.copy_cqes(&cqes, 0);

        for (cqes[0..count]) |cqe| {
            self.dispatch(cqe);
        }
        return count > 0;
    }

    pub fn stop(self: *ApiServer) void {
        self.running = false;
    }

    // ── CQE dispatch ──────────────────────────────────────

    // user_data encoding: bits[63:8] = slot, bits[7:0] = op
    const OP_ACCEPT: u8 = 1;
    const OP_RECV: u8 = 2;
    const OP_SEND: u8 = 3;

    fn encodeUd(slot: u8, op: u8) u64 {
        return (@as(u64, slot) << 8) | op;
    }

    fn dispatch(self: *ApiServer, cqe: linux.io_uring_cqe) void {
        const op: u8 = @intCast(cqe.user_data & 0xFF);
        const slot: u8 = @intCast((cqe.user_data >> 8) & 0xFF);

        switch (op) {
            OP_ACCEPT => self.handleAccept(cqe),
            OP_RECV => self.handleRecv(slot, cqe),
            OP_SEND => self.handleSend(slot, cqe),
            else => {},
        }
    }

    fn handleAccept(self: *ApiServer, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            self.submitAccept() catch {};
            return;
        }
        const new_fd: posix.fd_t = @intCast(cqe.res);

        const slot = self.allocClientSlot() orelse {
            _ = self.ring.inner.close(0, new_fd) catch {};
            self.submitAccept() catch {};
            return;
        };

        var client = &self.clients[slot];
        client.fd = new_fd;
        client.recv_buf = self.allocator.alloc(u8, recv_buf_size) catch {
            _ = self.ring.inner.close(0, new_fd) catch {};
            client.fd = -1;
            self.submitAccept() catch {};
            return;
        };
        client.recv_offset = 0;

        // Submit recv for request
        self.submitRecv(slot) catch {
            self.closeClient(slot);
        };

        // Re-submit accept
        self.submitAccept() catch {};
    }

    fn handleRecv(self: *ApiServer, slot: u8, cqe: linux.io_uring_cqe) void {
        if (cqe.res <= 0) {
            self.closeClient(slot);
            return;
        }
        var client = &self.clients[slot];
        const n: usize = @intCast(cqe.res);
        client.recv_offset += n;

        const data = client.recv_buf.?[0..client.recv_offset];

        // First, we need the headers (terminated by \r\n\r\n)
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            // Haven't received complete headers yet
            if (client.recv_offset >= data.len) {
                self.sendErrorResponse(slot, 413, "Request Too Large");
            } else {
                self.submitRecv(slot) catch {
                    self.closeClient(slot);
                };
            }
            return;
        };

        // Headers are complete. Check if we need to wait for the body.
        const body_start = header_end + 4;
        const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            self.sendErrorResponse(slot, 400, "Bad Request");
            return;
        };
        const headers = data[first_line_end + 2 .. header_end];
        const content_length = parseContentLength(headers);

        if (content_length) |expected_body_len| {
            const body_received = client.recv_offset - body_start;

            if (body_received < expected_body_len) {
                // Need more body data. Grow buffer if needed.
                const total_needed = body_start + expected_body_len;
                if (total_needed > max_request_size) {
                    self.sendErrorResponse(slot, 413, "Request Too Large");
                    return;
                }

                if (total_needed > client.recv_buf.?.len) {
                    // Grow the buffer
                    const new_buf = self.allocator.realloc(client.recv_buf.?, total_needed) catch {
                        self.sendErrorResponse(slot, 500, "Internal Server Error");
                        return;
                    };
                    client.recv_buf = new_buf;
                }

                self.submitRecv(slot) catch {
                    self.closeClient(slot);
                };
                return;
            }
        }

        // We have enough data. Parse and handle.
        const request = parseRequest(data) orelse {
            self.sendErrorResponse(slot, 400, "Bad Request");
            return;
        };

        const response = self.handler(self.allocator, request);
        self.sendResponse(slot, response);
    }

    fn handleSend(self: *ApiServer, slot: u8, cqe: linux.io_uring_cqe) void {
        _ = cqe;
        // Response sent, close connection
        self.closeClient(slot);
    }

    // ── SQE helpers ───────────────────────────────────────

    pub fn submitAccept(self: *ApiServer) !void {
        const ud = encodeUd(0, OP_ACCEPT);
        _ = try self.ring.inner.accept(ud, self.listen_fd, null, null, posix.SOCK.CLOEXEC);
    }

    fn submitRecv(self: *ApiServer, slot: u8) !void {
        const client = &self.clients[slot];
        const buf = client.recv_buf orelse return;
        const ud = encodeUd(slot, OP_RECV);
        _ = try self.ring.inner.recv(ud, client.fd, .{ .buffer = buf[client.recv_offset..] }, 0);
    }

    fn sendResponse(self: *ApiServer, slot: u8, response: Response) void {
        const client = &self.clients[slot];

        // Build HTTP response into the recv buffer (reuse it)
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        buf.print(self.allocator, "HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: close\r\n", .{
            response.status,
            statusText(response.status),
            response.content_type,
            response.body.len,
        }) catch return;
        if (response.extra_headers) |hdrs| {
            buf.appendSlice(self.allocator, hdrs) catch return;
        }
        buf.appendSlice(self.allocator, "\r\n") catch return;
        buf.appendSlice(self.allocator, response.body) catch return;

        if (response.owned_body) |owned| {
            self.allocator.free(owned);
        }
        if (response.owned_extra_headers) |owned| {
            self.allocator.free(owned);
        }

        // Store response in a buffer the client owns
        if (client.recv_buf) |old_buf| {
            self.allocator.free(old_buf);
        }
        client.recv_buf = buf.toOwnedSlice(self.allocator) catch return;
        client.recv_offset = 0;

        const ud = encodeUd(slot, OP_SEND);
        _ = self.ring.inner.send(ud, client.fd, client.recv_buf.?, 0) catch {
            self.closeClient(slot);
            return;
        };
    }

    fn sendErrorResponse(self: *ApiServer, slot: u8, status: u16, message: []const u8) void {
        self.sendResponse(slot, .{
            .status = status,
            .content_type = "text/plain",
            .body = message,
        });
    }

    fn closeClient(self: *ApiServer, slot: u8) void {
        const client = &self.clients[slot];
        if (client.fd >= 0) {
            _ = self.ring.inner.close(0, client.fd) catch {};
            client.fd = -1;
        }
        if (client.recv_buf) |buf| self.allocator.free(buf);
        client.* = .{};
    }

    fn allocClientSlot(self: *ApiServer) ?u8 {
        for (&self.clients, 0..) |*client, i| {
            if (client.fd < 0) return @intCast(i);
        }
        return null;
    }
};

// ── HTTP types ────────────────────────────────────────────

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
    cookie_sid: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: []const u8 = "",
    owned_body: ?[]u8 = null, // if set, freed after send
    extra_headers: ?[]const u8 = null, // optional extra headers (e.g. Set-Cookie)
    owned_extra_headers: ?[]u8 = null, // if set, freed after send
};

pub const ApiClient = struct {
    fd: posix.fd_t = -1,
    recv_buf: ?[]u8 = null,
    recv_offset: usize = 0,
};

fn parseRequest(data: []const u8) ?Request {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return null;
    const first_line = data[0..first_line_end];

    // "GET /path HTTP/1.1"
    const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const method = first_line[0..method_end];

    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, first_line, path_start, ' ') orelse return null;
    const path = first_line[path_start..path_end];

    const body = data[header_end + 4 ..];

    // Extract headers
    const headers = data[first_line_end + 2 .. header_end];
    const cookie_sid = auth.extractSidFromHeaders(headers);
    const content_type = extractHeader(headers, "content-type");

    return .{
        .method = method,
        .path = path,
        .body = body,
        .cookie_sid = cookie_sid,
        .content_type = content_type,
    };
}

/// Extract Content-Length from raw header block. Returns null if not present or invalid.
fn parseContentLength(headers: []const u8) ?usize {
    const value = extractHeader(headers, "content-length") orelse return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// Case-insensitive header extraction from the raw header block.
fn extractHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse headers.len;
        const line = headers[pos..line_end];
        pos = if (line_end + 2 <= headers.len) line_end + 2 else headers.len;

        // Find colon
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = line[0..colon];

        // Case-insensitive comparison
        if (header_name.len != name.len) continue;
        var match = true;
        for (header_name, name) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                match = false;
                break;
            }
        }
        if (!match) continue;

        return std.mem.trimLeft(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn defaultHandler(_: std.mem.Allocator, request: Request) Response {
    _ = request;
    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Request Too Large",
        500 => "Internal Server Error",
        else => "Unknown",
    };
}

// ── Tests ─────────────────────────────────────────────────

test "parse HTTP request" {
    const data = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/api/v2/app/webapiVersion", req.path);
}

test "parse POST request with body" {
    const data = "POST /api/v2/torrents/add HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const req = parseRequest(data).?;
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/api/v2/torrents/add", req.path);
    try std.testing.expectEqualStrings("hello", req.body);
}

test "parse request extracts content-type" {
    const data = "POST /api/v2/torrents/add HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: 0\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expectEqualStrings("multipart/form-data; boundary=abc", req.content_type.?);
}

test "parse request without content-type" {
    const data = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expect(req.content_type == null);
}

test "extractHeader case insensitive" {
    const headers = "Host: localhost\r\ncontent-type: text/plain\r\nContent-Length: 42\r\n";
    try std.testing.expectEqualStrings("text/plain", extractHeader(headers, "content-type").?);
    try std.testing.expectEqualStrings("text/plain", extractHeader(headers, "Content-Type").?);
    try std.testing.expectEqualStrings("42", extractHeader(headers, "content-length").?);
    try std.testing.expect(extractHeader(headers, "x-missing") == null);
}

test "parseContentLength extracts length" {
    const headers = "Content-Type: text/plain\r\nContent-Length: 1234\r\n";
    try std.testing.expectEqual(@as(?usize, 1234), parseContentLength(headers));
}

test "parseContentLength returns null when missing" {
    const headers = "Content-Type: text/plain\r\n";
    try std.testing.expect(parseContentLength(headers) == null);
}

test "api server init and deinit" {
    var server = ApiServer.init(std.testing.allocator, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
}

test "api server handles request via io_uring" {
    var server = ApiServer.init(std.testing.allocator, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();

    // Get the actual port
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server.listen_fd, &addr, &addr_len);
    const listen_addr = std.net.Address{ .any = addr };
    const port = listen_addr.getPort();

    server.setHandler(struct {
        fn handle(_: std.mem.Allocator, request: Request) Response {
            if (std.mem.eql(u8, request.path, "/api/v2/app/webapiVersion")) {
                return .{ .body = "\"2.9.3\"" };
            }
            return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
        }
    }.handle);

    // Submit accept
    server.submitAccept() catch return;

    // Connect a test client (using std.net since this is the test side)
    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);

    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    // Send HTTP request
    const request_bytes = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = try posix.write(client_fd, request_bytes);

    // Poll the server to process accept + recv + send
    var iterations: u32 = 0;
    while (iterations < 100) : (iterations += 1) {
        _ = server.poll() catch break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Read response
    var response_buf: [4096]u8 = undefined;
    const n = try posix.read(client_fd, &response_buf);
    const response = response_buf[0..n];

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, response, "\"2.9.3\"") != null);
}

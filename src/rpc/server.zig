const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ring_mod = @import("../io/ring.zig");
const socket_util = @import("../net/socket.zig");
const auth = @import("auth.zig");
const io_interface = @import("../io/io_interface.zig");
const real_io_mod = @import("../io/real_io.zig");
const RealIO = real_io_mod.RealIO;
const scratch = @import("scratch.zig");

const max_api_clients = 64;
const recv_buf_size = 8192;
const header_buf_size = 512;
const retained_recv_buf_limit = 256 * 1024;
const max_request_size = 4 * 1024 * 1024; // 4 MiB max for torrent uploads
pub const response_header_inline_size = header_buf_size;

/// Per-slot bump-arena slab size (Stage 2 zero-alloc plan, see
/// `docs/zero-alloc-plan.md`). The slab is the **fast-path** size:
/// handler allocations served from the slab cost zero parent-allocator
/// calls. Pre-allocated at server init for all 64 slots
/// (`64 × 256 KiB = 16 MiB`), so steady-state requests that fit in the
/// slab make zero allocator calls.
///
/// Allocations that exceed the slab transparently spill to the parent
/// allocator via `scratch.TieredArena`, up to `request_arena_capacity`.
/// Spilled allocations are freed in a single sweep on `arena.reset()`
/// (called between requests).
pub const request_arena_slab = 256 * 1024;

/// Per-slot bump-arena hard cap (slab + spill). The plan calls for an
/// 8 MiB upper bound; `/sync/maindata` for 10K torrents has a transient
/// peak of ~21 MiB (HashMaps, stats arrays, JSON growth on top of the
/// response itself). 64 MiB gives ~3× margin for that case while
/// remaining bounded; oversize allocations surface `error.OutOfMemory`
/// and the handler returns 500.
///
/// Active-slot worst-case = `max_api_clients × request_arena_capacity`
/// = 64 × 64 MiB = 4 GiB at full saturation; in practice qBittorrent
/// UIs hold 1–3 connections, so the typical working set is 64–192 MiB.
pub const request_arena_capacity = 64 * 1024 * 1024;

const event_loop_mod = @import("../io/event_loop.zig");

/// HTTP API server running on the shared io_interface backend.
/// Accept, recv, parse, route, send -- all via `io.*` ops with caller-
/// owned Completions. Each in-flight per-client op carries a generation
/// counter via a heap-allocated ClientOp tracker so stale CQEs after
/// slot reuse are filtered cheaply.
pub const ApiServer = struct {
    io: *RealIO,
    allocator: std.mem.Allocator,
    listen_fd: posix.fd_t = -1,
    clients: [max_api_clients]ApiClient = [_]ApiClient{.{}} ** max_api_clients,
    client_generations: [max_api_clients]u32 = [_]u32{0} ** max_api_clients,
    handler: *const fn (std.mem.Allocator, Request) Response = defaultHandler,
    running: bool = true,
    accept_completion: io_interface.Completion = .{},

    pub fn init(allocator: std.mem.Allocator, io: *RealIO, bind_addr: []const u8, port: u16) !ApiServer {
        return initWithDevice(allocator, io, bind_addr, port, null);
    }

    /// Create an API server using a pre-existing listen socket (e.g. from
    /// systemd socket activation). The caller retains ownership of the fd.
    pub fn initWithFd(allocator: std.mem.Allocator, io: *RealIO, listen_fd: posix.fd_t) !ApiServer {
        var server: ApiServer = .{
            .io = io,
            .allocator = allocator,
            .listen_fd = listen_fd,
        };
        preallocateRequestArenas(&server);
        return server;
    }

    pub fn initWithDevice(allocator: std.mem.Allocator, io: *RealIO, bind_addr: []const u8, port: u16, bind_device: ?[]const u8) !ApiServer {
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

        var server: ApiServer = .{
            .io = io,
            .allocator = allocator,
            .listen_fd = fd,
        };
        preallocateRequestArenas(&server);
        return server;
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
            releaseClientResponse(self, client);
            if (client.request_arena) |*arena| {
                arena.deinit();
                client.request_arena = null;
            }
        }
        if (self.listen_fd >= 0) posix.close(self.listen_fd);
        // io is shared, not owned — don't deinit it
    }

    pub fn setHandler(self: *ApiServer, handler: *const fn (std.mem.Allocator, Request) Response) void {
        self.handler = handler;
    }

    /// Per-op tracking struct. Now **embedded in `ApiClient`** (one
    /// `recv_op` + one `send_op` per slot), so submit/complete cycles
    /// don't allocate. Each slot has at most one in-flight recv + one
    /// in-flight send at a time, which is a Pattern #1 ("Single
    /// Completion per long-lived slot for serial state machines")
    /// configuration in `STYLE.md`. Stale completion filtering uses the
    /// `gen` snapshot taken at submission time vs `client_generations`
    /// at completion.
    const ClientOp = struct {
        completion: io_interface.Completion = .{},
        server: *ApiServer = undefined,
        slot: u8 = 0,
        gen: u32 = 0,
    };

    pub fn stop(self: *ApiServer) void {
        self.running = false;
    }

    // ── Run helpers (tests / benchmarks) ──────────────────

    /// Run a standalone event loop. For tests and benchmarks only.
    pub fn run(self: *ApiServer) !void {
        try self.submitAccept();
        while (self.running) {
            try self.io.tick(1);
        }
    }

    /// Process one batch of completions. Non-blocking. For tests and
    /// benchmarks only.
    pub fn poll(self: *ApiServer) !bool {
        try self.io.tick(0);
        return true;
    }

    // ── Accept ────────────────────────────────────────────

    pub fn submitAccept(self: *ApiServer) !void {
        try self.io.accept(
            .{ .fd = self.listen_fd, .multishot = true },
            &self.accept_completion,
            self,
            apiAcceptComplete,
        );
    }

    fn apiAcceptComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *ApiServer = @ptrCast(@alignCast(userdata.?));
        const new_fd = switch (result) {
            .accept => |r| r catch return .rearm,
            else => return .rearm,
        };
        const accepted_fd = new_fd.fd;

        const slot = self.allocClientSlot() orelse {
            posix.close(accepted_fd);
            return .rearm;
        };

        const client = &self.clients[slot];
        client.fd = accepted_fd;
        client.recv_offset = 0;

        self.submitRecv(slot) catch {
            self.closeClient(slot);
        };
        return .rearm;
    }

    // ── Recv ──────────────────────────────────────────────

    fn submitRecv(self: *ApiServer, slot: u8) !void {
        const client = &self.clients[slot];
        if (client.fd < 0) return error.InvalidClientSlot;
        const op = &client.recv_op;
        op.* = .{
            .completion = .{},
            .server = self,
            .slot = slot,
            .gen = self.client_generations[slot],
        };
        const storage = recvStorage(client);
        try self.io.recv(
            .{ .fd = client.fd, .buf = storage[client.recv_offset..] },
            &op.completion,
            op,
            apiRecvComplete,
        );
    }

    fn apiRecvComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const op: *ClientOp = @ptrCast(@alignCast(userdata.?));
        const self = op.server;
        const slot = op.slot;
        const gen = op.gen;

        if (!self.isLiveClient(slot, gen)) return .disarm;

        const n = switch (result) {
            .recv => |r| r catch {
                self.closeClient(slot);
                return .disarm;
            },
            else => return .disarm,
        };
        if (n == 0) {
            self.closeClient(slot);
            return .disarm;
        }
        const client = &self.clients[slot];
        client.recv_offset += n;
        self.processBufferedRequest(slot);
        return .disarm;
    }

    // ── Send ──────────────────────────────────────────────

    fn submitSend(self: *ApiServer, slot: u8) !void {
        const client = &self.clients[slot];
        const header = client.header_buf orelse return error.NoSendBuffer;
        var iov_len: usize = 0;
        if (client.header_offset < header.len) {
            const remaining = header[client.header_offset..];
            client.send_iov[iov_len] = .{
                .base = remaining.ptr,
                .len = remaining.len,
            };
            iov_len += 1;
        }
        if (client.body_offset < client.body.len) {
            const remaining = client.body[client.body_offset..];
            client.send_iov[iov_len] = .{
                .base = remaining.ptr,
                .len = remaining.len,
            };
            iov_len += 1;
        }
        if (iov_len == 0) return error.NoSendBuffer;
        client.send_msg = .{
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&client.send_iov),
            .iovlen = iov_len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const op = &client.send_op;
        op.* = .{
            .completion = .{},
            .server = self,
            .slot = slot,
            .gen = self.client_generations[slot],
        };
        try self.io.sendmsg(
            .{ .fd = client.fd, .msg = &client.send_msg },
            &op.completion,
            op,
            apiSendComplete,
        );
    }

    fn apiSendComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const op: *ClientOp = @ptrCast(@alignCast(userdata.?));
        const self = op.server;
        const slot = op.slot;
        const gen = op.gen;

        if (!self.isLiveClient(slot, gen)) return .disarm;
        const sent = switch (result) {
            .sendmsg => |r| r catch {
                self.closeClient(slot);
                return .disarm;
            },
            else => return .disarm,
        };
        if (sent == 0) {
            self.closeClient(slot);
            return .disarm;
        }

        const client = &self.clients[slot];
        const complete = advanceSendProgress(client, sent) catch {
            self.closeClient(slot);
            return .disarm;
        };
        if (complete) {
            if (!client.keep_alive) {
                self.closeClient(slot);
                return .disarm;
            }
            releaseClientResponse(self, client);
            if (client.recv_offset > 0) {
                self.processBufferedRequest(slot);
            } else {
                self.submitRecv(slot) catch {
                    self.closeClient(slot);
                };
            }
            return .disarm;
        }
        self.submitSend(slot) catch {
            self.closeClient(slot);
        };
        return .disarm;
    }

    fn sendResponse(self: *ApiServer, slot: u8, response: Response) void {
        const client = &self.clients[slot];
        var owned_body = response.owned_body;
        errdefer if (owned_body) |owned| {
            if (!ownedBodyManagedByArena(client, owned)) self.allocator.free(owned);
        };
        defer if (response.owned_extra_headers) |owned| {
            if (!ownedBodyManagedByArena(client, owned)) self.allocator.free(owned);
        };

        releaseClientResponse(self, client);

        const header_len = responseHeaderLength(response, client.keep_alive);
        if (header_len <= client.header_inline.len) {
            client.header_buf = writeResponseHeader(client.header_inline[0..header_len], response, client.keep_alive) catch return;
            client.header_is_heap = false;
        } else {
            const header_buf = self.allocator.alloc(u8, header_len) catch return;
            errdefer self.allocator.free(header_buf);
            const written = writeResponseHeader(header_buf, response, client.keep_alive) catch return;
            client.header_buf = written;
            client.header_is_heap = true;
        }

        client.header_offset = 0;
        client.body = response.body;
        client.body_offset = 0;
        client.owned_body = owned_body;
        owned_body = null;

        self.submitSend(slot) catch {
            self.closeClient(slot);
            return;
        };
    }

    fn processBufferedRequest(self: *ApiServer, slot: u8) void {
        const client = &self.clients[slot];
        const data = recvData(client);

        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            if (client.recv_offset >= max_request_size) {
                self.sendErrorResponse(slot, 413, "Request Too Large");
            } else {
                if (client.recv_offset == recvStorage(client).len) {
                    const next_capacity = @min(max_request_size, recvStorage(client).len * 2);
                    ensureRecvCapacity(self, client, next_capacity) catch {
                        self.sendErrorResponse(slot, 500, "Internal Server Error");
                        return;
                    };
                }
                self.submitRecv(slot) catch {
                    self.closeClient(slot);
                };
            }
            return;
        };

        const body_start = header_end + 4;
        const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse {
            self.sendErrorResponse(slot, 400, "Bad Request");
            return;
        };
        const headers = data[first_line_end + 2 .. header_end];
        const content_length = parseContentLength(headers) orelse 0;
        const total_needed = body_start + content_length;
        if (total_needed > max_request_size) {
            self.sendErrorResponse(slot, 413, "Request Too Large");
            return;
        }
        if (data.len < total_needed) {
            ensureRecvCapacity(self, client, total_needed) catch |err| {
                switch (err) {
                    error.RequestTooLarge => self.sendErrorResponse(slot, 413, "Request Too Large"),
                    else => self.sendErrorResponse(slot, 500, "Internal Server Error"),
                }
                return;
            };

            self.submitRecv(slot) catch {
                self.closeClient(slot);
            };
            return;
        }

        const parsed = parseRequest(data[0..total_needed]) orelse {
            self.sendErrorResponse(slot, 400, "Bad Request");
            return;
        };

        client.keep_alive = parsed.request.keep_alive;

        const remaining = client.recv_offset - parsed.consumed_len;
        if (remaining > 0) {
            const storage = recvStorage(client);
            std.mem.copyForwards(u8, storage[0..remaining], storage[parsed.consumed_len .. parsed.consumed_len + remaining]);
        }
        client.recv_offset = remaining;

        // Stage 2 zero-alloc: route handler allocations through the per-slot
        // bump arena. Reset before each call — guaranteed safe at this entry
        // point because `handleSend` calls `releaseClientResponse` on
        // send-complete *before* we re-enter `processBufferedRequest`. If
        // the slot's arena failed to pre-allocate (rare), fall back to the
        // parent allocator so we still respond rather than 500.
        const handler_allocator = ensureRequestArena(self, client) catch self.allocator;

        const response = self.handler(handler_allocator, parsed.request);
        self.sendResponse(slot, response);
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
        var retained_recv_buf: ?[]u8 = null;
        var retained_arena: ?scratch.TieredArena = null;
        if (client.fd >= 0) {
            posix.close(client.fd);
            client.fd = -1;
        }
        if (client.recv_buf) |buf| {
            if (buf.len <= retained_recv_buf_limit) {
                retained_recv_buf = buf;
            } else {
                self.allocator.free(buf);
            }
        }
        // Retain arena across slot reuse, same as `recv_buf`. The slab is
        // reset (lazily — by `ensureRequestArena` on the next request),
        // not freed. Only `deinit` truly frees the slab.
        if (client.request_arena) |arena| {
            retained_arena = arena;
        }
        releaseClientResponse(self, client);
        client.* = .{};
        client.recv_buf = retained_recv_buf;
        client.request_arena = retained_arena;
    }

    fn allocClientSlot(self: *ApiServer) ?u8 {
        for (&self.clients, 0..) |*client, i| {
            if (client.fd < 0) {
                self.client_generations[i] +%= 1;
                if (self.client_generations[i] == 0) self.client_generations[i] = 1;
                return @intCast(i);
            }
        }
        return null;
    }

    fn isLiveClient(self: *const ApiServer, slot: u8, generation: u32) bool {
        return self.client_generations[slot] == generation and self.clients[slot].fd >= 0;
    }
};

// ── HTTP types ────────────────────────────────────────────

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
    cookie_sid: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    keep_alive: bool = false,
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
    recv_inline: [recv_buf_size]u8 = undefined,
    recv_offset: usize = 0,
    header_buf: ?[]u8 = null,
    header_inline: [header_buf_size]u8 = undefined,
    header_is_heap: bool = false,
    header_offset: usize = 0,
    body: []const u8 = "",
    owned_body: ?[]u8 = null,
    body_offset: usize = 0,
    keep_alive: bool = false,
    send_iov: [2]posix.iovec_const = undefined,
    send_msg: posix.msghdr_const = std.mem.zeroes(posix.msghdr_const),
    /// Per-slot tiered bump arena for response building (Stage 2 zero-alloc
    /// plan). The 256 KiB slab is pre-allocated at server init via
    /// `preallocateRequestArenas`; allocations beyond the slab spill to
    /// the parent allocator up to `request_arena_capacity`. Reset between
    /// requests; retained across slot reuse like `recv_buf`. See
    /// `STYLE.md` Memory section + `src/rpc/scratch.zig`.
    request_arena: ?scratch.TieredArena = null,
    /// Embedded per-slot recv/send tracker structs (Pattern #1 in
    /// `STYLE.md`: single Completion per long-lived slot for serial
    /// state machines). Replaces the prior `allocator.create(ClientOp)`
    /// per recv/send — this slot has at most one in-flight recv and at
    /// most one in-flight send at any time, so static storage suffices.
    recv_op: ApiServer.ClientOp = .{},
    send_op: ApiServer.ClientOp = .{},
};

const ParsedRequest = struct {
    request: Request,
    consumed_len: usize,
};

fn recvStorage(client: *ApiClient) []u8 {
    return if (client.recv_buf) |buf| buf else client.recv_inline[0..];
}

fn recvData(client: *ApiClient) []u8 {
    return recvStorage(client)[0..client.recv_offset];
}

fn ensureRecvCapacity(self: *ApiServer, client: *ApiClient, min_capacity: usize) !void {
    if (min_capacity > max_request_size) return error.RequestTooLarge;
    if (min_capacity <= recvStorage(client).len) return;

    if (client.recv_buf) |buf| {
        client.recv_buf = try self.allocator.realloc(buf, min_capacity);
        return;
    }

    const new_capacity = @max(min_capacity, recv_buf_size * 2);
    const new_buf = try self.allocator.alloc(u8, new_capacity);
    @memcpy(new_buf[0..client.recv_offset], client.recv_inline[0..client.recv_offset]);
    client.recv_buf = new_buf;
}

fn parseRequest(data: []const u8) ?ParsedRequest {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return null;
    const first_line = data[0..first_line_end];

    // "GET /path HTTP/1.1"
    const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const method = first_line[0..method_end];

    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, first_line, path_start, ' ') orelse return null;
    const path = first_line[path_start..path_end];
    const version = first_line[path_end + 1 ..];

    // Extract headers
    const headers = data[first_line_end + 2 .. header_end];
    const content_length = parseContentLength(headers) orelse 0;
    const consumed_len = header_end + 4 + content_length;
    if (consumed_len > data.len) return null;
    const body = data[header_end + 4 .. consumed_len];
    const cookie_sid = auth.extractSidFromHeaders(headers);
    const content_type = extractHeader(headers, "content-type");
    const keep_alive = requestKeepAlive(version, extractHeader(headers, "connection"));

    return .{
        .request = .{
            .method = method,
            .path = path,
            .body = body,
            .cookie_sid = cookie_sid,
            .content_type = content_type,
            .keep_alive = keep_alive,
        },
        .consumed_len = consumed_len,
    };
}

fn requestKeepAlive(version: []const u8, connection: ?[]const u8) bool {
    if (connection) |value| {
        const trimmed = std.mem.trim(u8, value, " ");
        if (std.ascii.eqlIgnoreCase(trimmed, "close")) return false;
        if (std.ascii.eqlIgnoreCase(trimmed, "keep-alive")) return true;
    }
    return std.mem.eql(u8, version, "HTTP/1.1");
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

pub fn responseHeaderLength(response: Response, keep_alive: bool) usize {
    return std.fmt.count("HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: {s}\r\n", .{
        response.status,
        statusText(response.status),
        response.content_type,
        response.body.len,
        if (keep_alive) "keep-alive" else "close",
    }) + (response.extra_headers orelse "").len + 2;
}

pub fn writeResponseHeader(dest: []u8, response: Response, keep_alive: bool) ![]u8 {
    var stream = std.io.fixedBufferStream(dest);
    const writer = stream.writer();
    try writer.print("HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: {s}\r\n", .{
        response.status,
        statusText(response.status),
        response.content_type,
        response.body.len,
        if (keep_alive) "keep-alive" else "close",
    });
    if (response.extra_headers) |hdrs| {
        try writer.writeAll(hdrs);
    }
    try writer.writeAll("\r\n");
    return dest[0..stream.pos];
}

/// Pre-allocate per-slot request arenas (Stage 2 zero-alloc plan).  Called
/// once during `init`/`initWithFd`/`initWithDevice`.  Slots whose
/// pre-allocation fails (rare; only on parent-allocator OOM at startup)
/// are left null; `ensureRequestArena` lazy-inits them on first request.
fn preallocateRequestArenas(server: *ApiServer) void {
    for (&server.clients) |*client| {
        client.request_arena = scratch.TieredArena.init(
            server.allocator,
            request_arena_slab,
            request_arena_capacity,
        ) catch null;
    }
}

/// Lazy-initialize the per-client request arena (idempotent across slot
/// reuse — server init pre-allocates the slab when possible, so this
/// path runs only when a slot's slab failed to pre-alloc). Reset on each
/// call; the caller must ensure the previous response's send has fully
/// drained — which is guaranteed at the `processBufferedRequest` entry
/// point because `handleSend` calls `releaseClientResponse` on
/// send-complete *before* re-entering `processBufferedRequest`.
fn ensureRequestArena(self: *ApiServer, client: *ApiClient) !std.mem.Allocator {
    if (client.request_arena) |*arena| {
        arena.reset();
        return arena.allocator();
    }
    client.request_arena = try scratch.TieredArena.init(
        self.allocator,
        request_arena_slab,
        request_arena_capacity,
    );
    return client.request_arena.?.allocator();
}

/// True if `slice` is owned by the slot arena (slab or spill chain).
/// Used to keep `releaseOwnedResponseBody` from double-freeing arena
/// memory through the parent allocator. Conservative: when the
/// `request_arena` is present we treat any owned response body as
/// arena-managed, since handlers in this codebase always allocate from
/// the allocator the server passes in (the arena's). The arena's reset
/// reclaims slab and spill in a single sweep; the parent allocator
/// must never see arena-region pointers.
fn ownedBodyManagedByArena(client: *const ApiClient, slice: []const u8) bool {
    _ = slice;
    return client.request_arena != null;
}

fn releaseOwnedResponseBody(allocator: std.mem.Allocator, client: *ApiClient) void {
    if (client.owned_body) |owned| {
        // Arena-backed bodies (slab or spill) are released by the next
        // arena.reset() — never free them through the parent allocator.
        if (!ownedBodyManagedByArena(client, owned)) allocator.free(owned);
    }
    client.owned_body = null;
}

fn advanceSendProgress(client: *ApiClient, sent: usize) !bool {
    if (sent == 0) return error.InvalidSendLength;
    const header = client.header_buf orelse return error.NoSendBuffer;
    if (client.header_offset > header.len or client.body_offset > client.body.len) {
        return error.InvalidSendLength;
    }

    const header_remaining = header.len - client.header_offset;
    if (sent < header_remaining) {
        client.header_offset += sent;
        return false;
    }

    client.header_offset = header.len;
    const body_sent = sent - header_remaining;
    const body_remaining = client.body.len - client.body_offset;
    if (body_sent > body_remaining) return error.InvalidSendLength;
    client.body_offset += body_sent;
    return client.header_offset == header.len and client.body_offset == client.body.len;
}

fn releaseClientResponse(self: *ApiServer, client: *ApiClient) void {
    if (client.header_is_heap) {
        if (client.header_buf) |buf| self.allocator.free(buf);
    }
    client.header_buf = null;
    client.header_is_heap = false;
    client.header_offset = 0;
    client.body = "";
    client.body_offset = 0;
    releaseOwnedResponseBody(self.allocator, client);
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
    try std.testing.expectEqualStrings("GET", req.request.method);
    try std.testing.expectEqualStrings("/api/v2/app/webapiVersion", req.request.path);
    try std.testing.expect(req.request.keep_alive);
}

test "parse POST request with body" {
    const data = "POST /api/v2/torrents/add HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const req = parseRequest(data).?;
    try std.testing.expectEqualStrings("POST", req.request.method);
    try std.testing.expectEqualStrings("/api/v2/torrents/add", req.request.path);
    try std.testing.expectEqualStrings("hello", req.request.body);
}

test "parse request extracts content-type" {
    const data = "POST /api/v2/torrents/add HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: 0\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expectEqualStrings("multipart/form-data; boundary=abc", req.request.content_type.?);
}

test "parse request without content-type" {
    const data = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expect(req.request.content_type == null);
}

test "parse request honors connection close" {
    const data = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const req = parseRequest(data).?;
    try std.testing.expect(!req.request.keep_alive);
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
    var test_io = RealIO.init(.{ .entries = 64 }) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
}

test "api server handles request via io_uring" {
    var test_io = RealIO.init(.{ .entries = 64 }) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
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

test "api server keeps HTTP/1.1 connection alive for sequential requests" {
    var test_io = RealIO.init(.{ .entries = 64 }) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();

    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server.listen_fd, &addr, &addr_len);
    const listen_addr = std.net.Address{ .any = addr };
    const port = listen_addr.getPort();

    server.setHandler(struct {
        fn handle(_: std.mem.Allocator, request: Request) Response {
            _ = request;
            return .{ .body = "\"2.9.3\"" };
        }
    }.handle);

    server.submitAccept() catch return;

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);

    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    const request_bytes = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = try posix.write(client_fd, request_bytes);

    var iterations: u32 = 0;
    while (iterations < 100) : (iterations += 1) {
        _ = server.poll() catch break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    var response_buf: [4096]u8 = undefined;
    const n1 = try posix.read(client_fd, &response_buf);
    const response1 = response_buf[0..n1];
    try std.testing.expect(std.mem.indexOf(u8, response1, "Connection: keep-alive") != null);

    _ = try posix.write(client_fd, request_bytes);
    iterations = 0;
    while (iterations < 100) : (iterations += 1) {
        _ = server.poll() catch break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    const n2 = try posix.read(client_fd, &response_buf);
    const response2 = response_buf[0..n2];
    try std.testing.expect(std.mem.startsWith(u8, response2, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, response2, "\"2.9.3\"") != null);
}

test "advanceSendProgress tracks partial sends" {
    var client = ApiClient{
        .header_buf = "he"[0..],
        .body = "llo"[0..],
    };

    try std.testing.expect(!(try advanceSendProgress(&client, 2)));
    try std.testing.expectEqual(@as(usize, 2), client.header_offset);
    try std.testing.expectEqual(@as(usize, 0), client.body_offset);
    try std.testing.expect(try advanceSendProgress(&client, 3));
    try std.testing.expectEqual(@as(usize, 2), client.header_offset);
    try std.testing.expectEqual(@as(usize, 3), client.body_offset);
}

test "advanceSendProgress rejects invalid completions" {
    var client = ApiClient{
        .header_buf = "ab"[0..],
        .body = "c"[0..],
    };

    try std.testing.expectError(error.InvalidSendLength, advanceSendProgress(&client, 0));
    try std.testing.expectError(error.InvalidSendLength, advanceSendProgress(&client, 4));
    client.header_buf = null;
    try std.testing.expectError(error.NoSendBuffer, advanceSendProgress(&client, 1));
}

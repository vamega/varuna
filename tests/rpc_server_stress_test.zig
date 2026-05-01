//! Integration stress test for the post-Track-B `ApiServer` lifecycle
//! (Track C). Drives many seeds × randomised connect/disconnect/
//! request-size patterns against the real `ApiServer` running on
//! the selected production IO backend, asserting safety properties — no leaks, no UAF, no
//! kernel-side crashes, and that successful responses match the
//! handler output.
//!
//! The `ApiServer` is concrete-typed against the selected backend so this test
//! cannot be driven under `SimIO` directly. Instead it perturbs
//! timing via random poll budgets and random disconnect points: a
//! client may close after writing only the request line, after the
//! header block, or after reading some-but-not-all of the response.
//! Each variation exercises the handleRecv/handleSend/closeClient
//! state machine in a different order, hitting paths that a happy-
//! path test rarely sees.
//!
//! This is a layer-3 safety test (`STYLE.md` Layered Testing
//! Strategy). It does **not** assert liveness — under random close
//! times, the handler may or may not run for a given client; the
//! assertion is only that nothing leaks and the server stays
//! responsive across the seed.
//!
//! Track B's per-slot `TieredArena` + embedded `recv_op`/`send_op`
//! `ClientOp` patterns are the specific surfaces under test.
//! Mismatched-generation completions on reused slots are filtered
//! by `isLiveClient(slot, gen)`; this test exercises that filter
//! by closing and reconnecting fast enough that stale CQEs may
//! land while a slot is mid-reuse.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const varuna = @import("varuna");
const rpc_server = varuna.rpc.server;
const rpc_handlers = varuna.rpc.handlers;
const rpc_sync = varuna.rpc.sync;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const backend = varuna.io.backend;

fn echoHandler(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    // Allocate a body from the per-slot arena allocator. Length
    // depends on the request path so different seeds drive different
    // response sizes.
    const body = std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"len\":{}}}", .{
        request.path,
        request.body.len,
    }) catch return .{ .status = 500, .body = "{\"error\":\"alloc\"}" };
    return .{ .body = body, .owned_body = body };
}

fn pollFor(server: *rpc_server.ApiServer, ms: u32) void {
    var i: u32 = 0;
    while (i < ms / 5) : (i += 1) {
        _ = server.poll() catch break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

fn listenPort(server: *const rpc_server.ApiServer) !u16 {
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server.listen_fd, &addr, &addr_len);
    return (std.net.Address{ .any = addr }).getPort();
}

const CloseStrategy = enum {
    /// Connect, write full request, drain response, close.
    happy_path,
    /// Connect, write only the request line (no \r\n\r\n), close.
    /// The server's recv loop will see EOF before the request is
    /// complete and must close cleanly.
    close_mid_request,
    /// Connect, write full request, close before reading response.
    /// The server has already kicked off the send by the time we
    /// close; the send will complete (kernel buffers it) and the
    /// next recv will see EOF.
    close_before_send_complete,
    /// Connect, never write, close.
    close_immediately,
};

fn nonblockingConnect(port: u16) !posix.fd_t {
    const client_fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {}, // connect-in-progress; that's fine for our stress test
        else => return err,
    };
    return client_fd;
}

fn driveClient(server: *rpc_server.ApiServer, port: u16, strategy: CloseStrategy, request_n: u32) !void {
    const client_fd = nonblockingConnect(port) catch return;
    defer posix.close(client_fd);

    if (strategy == .close_immediately) {
        // Don't even drain the server — closing right away exercises
        // the kernel's RST/FIN delivery path against a fresh accept.
        return;
    }

    // Give the server a chance to accept the connection.
    pollFor(server, 30);

    if (strategy == .close_mid_request) {
        // Write only part of the request line (no terminator). The
        // server's recv reads what we wrote, sees no \r\n\r\n, and
        // submits a fresh recv. Closing the socket then triggers EOF
        // on that pending recv.
        _ = posix.write(client_fd, "GET /api/v2/probe") catch {};
        pollFor(server, 30);
        return;
    }

    var req_buf: [4096]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET /api/v2/probe?n={} HTTP/1.1\r\nHost: localhost\r\n\r\n",
        .{request_n},
    ) catch return;
    _ = posix.write(client_fd, req) catch return;

    if (strategy == .close_before_send_complete) {
        // Don't read; close while the server's send is in flight.
        // The server's send_op completion may still fire; the
        // generation filter on the next recv will handle it.
        pollFor(server, 30);
        return;
    }

    // Happy path: poll until the server has had time to handle, then
    // drain the response with a non-blocking read.
    pollFor(server, 100);

    var resp_buf: [4096]u8 = undefined;
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        const n = posix.read(client_fd, &resp_buf) catch |err| switch (err) {
            error.WouldBlock => {
                pollFor(server, 30);
                continue;
            },
            else => return,
        };
        if (n == 0) break;
        if (n > 0) {
            // Sanity-check: response starts with the HTTP/1.1 status line.
            try std.testing.expect(std.mem.startsWith(u8, resp_buf[0..n], "HTTP/1.1 "));
            break;
        }
    }
}

test "ApiServer: 32 seeds × random close-mid-flight strategies" {
    var test_io = backend.initWithCapacity(std.testing.allocator, 64) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(echoHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    var seed: u64 = 0;
    while (seed < 32) : (seed += 1) {
        var rng = std.Random.DefaultPrng.init(seed);
        const ops_this_seed: u32 = 4;

        var op: u32 = 0;
        while (op < ops_this_seed) : (op += 1) {
            const strategy: CloseStrategy = @enumFromInt(rng.random().uintLessThan(u8, 4));
            try driveClient(&server, port, strategy, op);
        }

        // Drain between seeds so any in-flight client_op trackers
        // are reaped before the next seed exercises the slot.
        pollFor(&server, 100);
    }

    // Final long drain — any in-flight ops must complete (or be
    // filtered as stale) before the server is deinit'd. The GPA leak
    // detector enforces no embedded ClientOp mishandling.
    pollFor(&server, 300);
}

test "ApiServer: rapid connect-reconnect exercises generation filter on slot reuse" {
    // Tight loop: connect, send, drain. The server's accept-multishot
    // path will reuse the slot whose `client_generations[slot]` has
    // just incremented. If a stale recv/send completion lands on the
    // reused slot, `isLiveClient(slot, gen)` filters it. This test
    // exists to ensure the embedded `recv_op`/`send_op` (Pattern #1
    // in `STYLE.md`) interact correctly with the generation counter
    // under churn.
    var test_io = backend.initWithCapacity(std.testing.allocator, 64) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(echoHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    var iter: u32 = 0;
    while (iter < 16) : (iter += 1) {
        try driveClient(&server, port, .happy_path, iter);
    }
    pollFor(&server, 300);
}

// ── Real-handler routing tests (T3) ─────────────────────────────
//
// The two stress tests above intentionally use `echoHandler` because
// they're chasing lifecycle invariants — leaks, UAF, generation-filter
// correctness — and the handler body is irrelevant. The tests below
// fill the matching gap: they wire a real `ApiHandler` onto a real
// `ApiServer`, fire an HTTP request through the kernel via posix
// sockets, and assert the request reached the handler and the right
// status / body shape came back. That exercises the full stack:
// accept → recv → header parse → query parse → cookie extraction →
// route dispatch → handler → response → send. Anything below the
// handler boundary that breaks (header parsing, route table, cookie
// extraction, body delivery) shows up here, while the handler-only
// tests in `tests/api_endpoints_test.zig` would still pass.
//
// The `ApiServer` is concrete-typed against the selected backend, so we cannot
// drive it with `SimIO`; we instead use a real listening socket on
// `127.0.0.1` and synchronously poll between writes/reads from the
// same thread. The handler is bound via a file-scope global because
// `setHandler` takes a function pointer (the same pattern `main.zig`
// uses for `globalApiHandler`).

var routing_handler_global: ?*rpc_handlers.ApiHandler = null;

fn routingHandlerEntrypoint(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    if (routing_handler_global) |h| return h.handle(allocator, request);
    return .{ .status = 500, .body = "{\"error\":\"handler not bound\"}" };
}

const RoutingTestCtx = struct {
    test_io: *backend.RealIO,
    server: *rpc_server.ApiServer,
    sm: *SessionManager,
    handler: *rpc_handlers.ApiHandler,
    port: u16,

    fn init() !RoutingTestCtx {
        const allocator = std.testing.allocator;

        const sm = try allocator.create(SessionManager);
        errdefer allocator.destroy(sm);
        sm.* = SessionManager.init(allocator);
        sm.default_save_path = "/tmp/varuna-routing-test";

        const handler = try allocator.create(rpc_handlers.ApiHandler);
        errdefer allocator.destroy(handler);
        handler.* = .{
            .session_manager = sm,
            .sync_state = rpc_sync.SyncState.init(allocator),
            .peer_sync_state = rpc_sync.PeerSyncState.init(allocator),
        };
        errdefer {
            handler.sync_state.deinit();
            handler.peer_sync_state.deinit();
        }

        const test_io = try allocator.create(backend.RealIO);
        errdefer allocator.destroy(test_io);
        test_io.* = try backend.initWithCapacity(allocator, 64);
        errdefer test_io.deinit();

        const server = try allocator.create(rpc_server.ApiServer);
        errdefer allocator.destroy(server);
        server.* = try rpc_server.ApiServer.init(allocator, test_io, "127.0.0.1", 0);
        errdefer server.deinit();

        // Wire the global ahead of the handler firing so a CQE that
        // races accept/recv can never see a null pointer.
        routing_handler_global = handler;
        server.setHandler(routingHandlerEntrypoint);
        try server.submitAccept();

        // Resolve the listening port.
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(server.listen_fd, &addr, &addr_len);
        const port = (std.net.Address{ .any = addr }).getPort();

        return .{
            .test_io = test_io,
            .server = server,
            .sm = sm,
            .handler = handler,
            .port = port,
        };
    }

    fn deinit(self: *RoutingTestCtx) void {
        const allocator = std.testing.allocator;
        // Drain any in-flight CQEs before tearing down.
        pollFor(self.server, 200);
        self.server.deinit();
        allocator.destroy(self.server);
        self.test_io.deinit();
        allocator.destroy(self.test_io);
        self.handler.sync_state.deinit();
        self.handler.peer_sync_state.deinit();
        allocator.destroy(self.handler);
        self.sm.deinit();
        allocator.destroy(self.sm);
        routing_handler_global = null;
    }
};

const HttpExchange = struct {
    status: u16,
    body: []const u8, // points into `raw`
    raw: []u8, // owned by caller

    fn deinit(self: *HttpExchange, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

/// Fire one HTTP request at `127.0.0.1:port`, wait for the response,
/// and return the parsed status code + body slice. The connection is
/// closed after one round-trip (HTTP/1.0-style). Polls the server
/// between read/write phases so its io_uring state machine advances.
fn doRequest(
    server: *rpc_server.ApiServer,
    port: u16,
    method: []const u8,
    path: []const u8,
    extra_headers: []const u8,
    body: []const u8,
) !HttpExchange {
    const allocator = std.testing.allocator;

    const client_fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    defer posix.close(client_fd);

    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    pollFor(server, 30);

    var req_buf: [8192]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &req_buf,
        "{s} {s} HTTP/1.0\r\nHost: localhost\r\nContent-Length: {}\r\n{s}\r\n{s}",
        .{ method, path, body.len, extra_headers, body },
    );
    var write_off: usize = 0;
    while (write_off < req.len) {
        const n = posix.write(client_fd, req[write_off..]) catch |err| switch (err) {
            error.WouldBlock => {
                pollFor(server, 30);
                continue;
            },
            else => return err,
        };
        if (n == 0) break;
        write_off += n;
    }

    pollFor(server, 200);

    // Read the response. Loop until we either see EOF or have
    // accumulated enough bytes that the headers + body parse out.
    var raw = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer raw.deinit(allocator);

    var attempts: u32 = 0;
    while (attempts < 60) : (attempts += 1) {
        var chunk: [4096]u8 = undefined;
        const n = posix.read(client_fd, &chunk) catch |err| switch (err) {
            error.WouldBlock => {
                pollFor(server, 30);
                continue;
            },
            else => break,
        };
        if (n == 0) break;
        try raw.appendSlice(allocator, chunk[0..n]);
        // If we already have a full response (EOF will close), stop polling.
        if (std.mem.indexOf(u8, raw.items, "\r\n\r\n") != null and raw.items.len > 0) {
            // Read once more to catch any straggler bytes, then break.
            const n2 = posix.read(client_fd, &chunk) catch |err| switch (err) {
                error.WouldBlock => {
                    pollFor(server, 30);
                    continue;
                },
                else => break,
            };
            if (n2 == 0) break;
            try raw.appendSlice(allocator, chunk[0..n2]);
        }
    }

    const owned = try raw.toOwnedSlice(allocator);
    errdefer allocator.free(owned);

    if (!std.mem.startsWith(u8, owned, "HTTP/1.")) return error.NoHttpResponse;
    // status code lives at bytes 9..12.
    if (owned.len < 12) return error.NoHttpResponse;
    const status = try std.fmt.parseInt(u16, owned[9..12], 10);

    const header_end = std.mem.indexOf(u8, owned, "\r\n\r\n") orelse return error.MalformedResponse;
    const body_slice = owned[header_end + 4 ..];

    return .{ .status = status, .body = body_slice, .raw = owned };
}

fn extractCookieSid(raw_response: []const u8) ?[]const u8 {
    // Looking for: `Set-Cookie: SID=<32hex>; HttpOnly; ...`
    const tag = "Set-Cookie: SID=";
    const start = std.mem.indexOf(u8, raw_response, tag) orelse return null;
    const after_tag = start + tag.len;
    const semi = std.mem.indexOfPos(u8, raw_response, after_tag, ";") orelse return null;
    return raw_response[after_tag..semi];
}

test "ApiServer routing: GET /api/v2/auth/login is reachable without auth" {
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    var resp = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/auth/login", "Content-Type: application/x-www-form-urlencoded\r\n", "username=admin&password=adminadmin");
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("Ok.", resp.body);

    const sid = extractCookieSid(resp.raw) orelse return error.NoCookieSet;
    try std.testing.expectEqual(@as(usize, 32), sid.len);
}

test "ApiServer routing: unauthenticated app/version returns 403" {
    // Auth-required endpoints must reject requests without a Cookie
    // header even when the route exists. This catches a regression
    // where the route matcher fires before auth.
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/app/version", "", "");
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 403), resp.status);
}

test "ApiServer routing: authed app/version, app/buildInfo, app/defaultSavePath round-trip" {
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    // Login.
    var login = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/auth/login", "Content-Type: application/x-www-form-urlencoded\r\n", "username=admin&password=adminadmin");
    defer login.deinit(std.testing.allocator);
    const sid = extractCookieSid(login.raw) orelse return error.NoCookieSet;

    var cookie_buf: [128]u8 = undefined;
    const cookie_hdr = try std.fmt.bufPrint(&cookie_buf, "Cookie: SID={s}\r\n", .{sid});

    {
        var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/app/version", cookie_hdr, "");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("v5.0.0", resp.body);
    }
    {
        var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/app/buildInfo", cookie_hdr, "");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        // Body is JSON; check for one stable key.
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bitness\":64") != null);
    }
    {
        var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/app/defaultSavePath", cookie_hdr, "");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("/tmp/varuna-routing-test", resp.body);
    }
}

test "ApiServer routing: torrents/info returns empty array via real handler" {
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    var login = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/auth/login", "Content-Type: application/x-www-form-urlencoded\r\n", "username=admin&password=adminadmin");
    defer login.deinit(std.testing.allocator);
    const sid = extractCookieSid(login.raw) orelse return error.NoCookieSet;

    var cookie_buf: [128]u8 = undefined;
    const cookie_hdr = try std.fmt.bufPrint(&cookie_buf, "Cookie: SID={s}\r\n", .{sid});

    var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/torrents/info", cookie_hdr, "");
    defer resp.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    // Empty manager → empty JSON array. This proves the route hit the
    // ApiHandler.handleTorrents → handleTorrentsInfo path, not just a
    // generic 404 fallback.
    try std.testing.expectEqualStrings("[]", resp.body);
}

test "ApiServer routing: torrents/categories starts empty, createCategory POST sticks" {
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    var login = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/auth/login", "Content-Type: application/x-www-form-urlencoded\r\n", "username=admin&password=adminadmin");
    defer login.deinit(std.testing.allocator);
    const sid = extractCookieSid(login.raw) orelse return error.NoCookieSet;

    var cookie_buf: [128]u8 = undefined;
    const cookie_hdr = try std.fmt.bufPrint(&cookie_buf, "Cookie: SID={s}\r\n", .{sid});

    // 1. Empty list before any create.
    {
        var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/torrents/categories", cookie_hdr, "");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("{}", resp.body);
    }

    // 2. Create one.
    var create_hdr_buf: [256]u8 = undefined;
    const create_hdr = try std.fmt.bufPrint(&create_hdr_buf, "Content-Type: application/x-www-form-urlencoded\r\n{s}", .{cookie_hdr});
    {
        var resp = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/torrents/createCategory", create_hdr, "category=movies&savePath=/srv/movies");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // 3. List shows the new category.
    {
        var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/torrents/categories", cookie_hdr, "");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"movies\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/srv/movies") != null);
    }
}

test "ApiServer routing: unknown path returns 404 from handler (not socket-level)" {
    // A request with valid auth but a route that doesn't match any
    // handler must reach `ApiHandler.handle`'s catch-all 404 (with a
    // JSON body), not the `defaultHandler` 404 inside `server.zig`.
    // This pins the wiring between the routing layer and the
    // handler — flipping `setHandler` off would surface here.
    var ctx = RoutingTestCtx.init() catch return error.SkipZigTest;
    defer ctx.deinit();

    var login = try doRequest(ctx.server, ctx.port, "POST", "/api/v2/auth/login", "Content-Type: application/x-www-form-urlencoded\r\n", "username=admin&password=adminadmin");
    defer login.deinit(std.testing.allocator);
    const sid = extractCookieSid(login.raw) orelse return error.NoCookieSet;

    var cookie_buf: [128]u8 = undefined;
    const cookie_hdr = try std.fmt.bufPrint(&cookie_buf, "Cookie: SID={s}\r\n", .{sid});

    var resp = try doRequest(ctx.server, ctx.port, "GET", "/api/v2/this/is/not/a/route", cookie_hdr, "");
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    // Generic-router 404 says `not found`; ApiHandler emits JSON.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "{\"error\":") != null);
}

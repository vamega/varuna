//! Integration tests for the Stage 2 RPC bump arena.
//!
//! Layered per `STYLE.md` Layered Testing Strategy:
//! 1. Algorithm tests — `RequestArena` invariants under controlled inputs.
//! 2. Integration tests — full request through `ApiServer`, asserting that
//!    handler allocations land in the per-slot arena, that arena memory
//!    is reused across requests on the same connection, and that an
//!    oversize response surfaces 500 cleanly.
//! 3. Safety-under-fault — arena is robust against allocation failure
//!    inside an ArrayList growth chain (no leak, no overrun, no panic).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const varuna = @import("varuna");
const rpc_server = varuna.rpc.server;
const rpc_handlers = varuna.rpc.handlers;
const rpc_sync = varuna.rpc.sync;
const scratch = varuna.rpc.scratch;
const backend = varuna.io.backend;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;
const Random = varuna.runtime.Random;

// ── 1. Algorithm tests ────────────────────────────────────

test "RequestArena alloc/reset cycle returns memory" {
    var arena = try scratch.RequestArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    const a = arena.allocator();
    const buf1 = try a.alloc(u8, 128);
    @memset(buf1, 0xAB);
    try std.testing.expect(arena.used() >= 128);

    const buf2 = try a.alloc(u8, 256);
    @memset(buf2, 0xCD);
    try std.testing.expect(arena.used() >= 128 + 256);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expect(arena.highWater() >= 128 + 256);

    const buf3 = try a.alloc(u8, 64);
    @memset(buf3, 0xEF);
    try std.testing.expect(arena.used() >= 64);
}

test "RequestArena returns OOM at hard cap" {
    var arena = try scratch.RequestArena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 512);
    _ = try a.alloc(u8, 256);

    // 768 used; a 512 alloc must fail (would exceed 1024).
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 512));

    // Arena still usable for smaller allocations.
    const small = try a.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), small.len);
}

test "RequestArena oversize allocation is atomic — no leak on OOM" {
    var arena = try scratch.RequestArena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    try std.testing.expectError(error.OutOfMemory, arena.allocator().alloc(u8, 2048));
    try std.testing.expectEqual(@as(usize, 0), arena.used());

    const buf = try arena.allocator().alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), buf.len);
}

test "RequestArena retains high_water across reset cycles" {
    var arena = try scratch.RequestArena.init(std.testing.allocator, 4096);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 1000);
    arena.reset();
    try std.testing.expect(arena.highWater() >= 1000);

    _ = try a.alloc(u8, 100);
    arena.reset();
    try std.testing.expect(arena.highWater() >= 1000);
}

test "ArrayList in arena hits OOM cleanly without crashing" {
    var arena = try scratch.RequestArena.init(std.testing.allocator, 2048);
    defer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var oom_hit = false;
    while (i < 8192) : (i += 1) {
        list.append(a, @truncate(i)) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            oom_hit = true;
            break;
        };
    }
    try std.testing.expect(oom_hit);
    try std.testing.expect(list.items.len > 0);
    try std.testing.expect(list.items.len <= 2048);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}

// ── 2. Integration tests through ApiServer ────────────────
//
// These follow the pattern in `src/rpc/server.zig`'s "api server handles
// request via io_uring" test: bind a server on 127.0.0.1:0, connect a
// client, send a request, poll the server for ~500 ms (100 × 5 ms), then
// read the response. The poll budget gives io_uring time to drain
// accept → recv → send completions.

const HandlerProbe = struct {
    var last_body_ptr: usize = 0;
    var last_body_len: usize = 0;
    var calls: u32 = 0;

    fn reset() void {
        last_body_ptr = 0;
        last_body_len = 0;
        calls = 0;
    }
};

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    active_allocations: usize = 0,
    active_bytes: usize = 0,
    total_allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = vtableAlloc,
                .resize = vtableResize,
                .remap = vtableRemap,
                .free = vtableFree,
            },
        };
    }

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.active_allocations += 1;
        self.active_bytes += len;
        self.total_allocations += 1;
        return ptr;
    }

    fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.parent.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len > buf.len) {
                self.active_bytes += new_len - buf.len;
            } else {
                self.active_bytes -= buf.len - new_len;
            }
        }
        return ok;
    }

    fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        if (new_len > buf.len) {
            self.active_bytes += new_len - buf.len;
        } else {
            self.active_bytes -= buf.len - new_len;
        }
        return ptr;
    }

    fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.active_allocations -= 1;
        self.active_bytes -= buf.len;
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

const ParentOwnedProbe = struct {
    var allocator: std.mem.Allocator = undefined;
};

fn arenaProbeHandler(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    HandlerProbe.calls += 1;
    const body = std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"call\":{}}}", .{
        request.path,
        HandlerProbe.calls,
    }) catch return .{ .status = 500, .body = "{\"error\":\"alloc\"}" };
    HandlerProbe.last_body_ptr = @intFromPtr(body.ptr);
    HandlerProbe.last_body_len = body.len;
    return .{ .body = body, .owned_body = body };
}

fn parentOwnedResponseHandler(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    _ = allocator;
    _ = request;

    const parent = ParentOwnedProbe.allocator;
    const body = parent.dupe(u8, "{\"source\":\"parent\"}") catch
        return .{ .status = 500, .body = "{\"error\":\"body_alloc\"}" };
    const headers = parent.dupe(u8, "X-Varuna-Test: parent-owned\r\n") catch {
        parent.free(body);
        return .{ .status = 500, .body = "{\"error\":\"header_alloc\"}" };
    };
    return .{
        .body = body,
        .owned_body = body,
        .extra_headers = headers,
        .owned_extra_headers = headers,
    };
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

test "ApiServer routes handler allocations through per-slot arena" {
    HandlerProbe.reset();

    var test_io = backend.initWithCapacity(std.testing.allocator, 64) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(arenaProbeHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    var client_closed = false;
    defer if (!client_closed) posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    const req = "GET /api/v2/probe HTTP/1.1\r\nHost: localhost\r\n\r\n";

    // First request.
    _ = try posix.write(client_fd, req);
    pollFor(&server, 500);
    try std.testing.expect(HandlerProbe.calls >= 1);
    const first_ptr = HandlerProbe.last_body_ptr;

    // The handler-returned body must lie inside one of the server's per-slot
    // arenas — that is what proves the arena routing landed correctly.
    var found_slot: ?usize = null;
    for (server.clients, 0..) |client, idx| {
        if (client.request_arena) |arena| {
            const buf = arena.backing;
            const buf_start = @intFromPtr(buf.ptr);
            if (first_ptr >= buf_start and first_ptr < buf_start + buf.len) {
                found_slot = idx;
                break;
            }
        }
    }
    try std.testing.expect(found_slot != null);

    var resp_buf: [2048]u8 = undefined;
    const n1 = try posix.read(client_fd, &resp_buf);
    try std.testing.expect(std.mem.startsWith(u8, resp_buf[0..n1], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n1], "\"call\":1") != null);

    // Second request on the same keep-alive connection — same slot, same
    // arena, reset between calls. The bump-pointer offset for the response
    // body should be identical (no leftover state in the arena).
    _ = try posix.write(client_fd, req);
    pollFor(&server, 500);
    try std.testing.expect(HandlerProbe.calls >= 2);
    try std.testing.expectEqual(first_ptr, HandlerProbe.last_body_ptr);

    const n2 = try posix.read(client_fd, &resp_buf);
    try std.testing.expect(std.mem.startsWith(u8, resp_buf[0..n2], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n2], "\"call\":2") != null);

    // Drain the pending embedded recv op by closing the socket and polling
    // once more so the recv completion observes EOF before deinit.
    posix.close(client_fd);
    client_closed = true;
    pollFor(&server, 200);
}

test "ApiServer frees parent-owned response allocations while arena exists" {
    var test_io = backend.initWithCapacity(std.testing.allocator, 64) catch return error.SkipZigTest;
    defer test_io.deinit();
    var counting_parent: CountingAllocator = .{ .parent = std.testing.allocator };
    ParentOwnedProbe.allocator = counting_parent.allocator();

    var server = rpc_server.ApiServer.init(ParentOwnedProbe.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(parentOwnedResponseHandler);
    server.submitAccept() catch return;

    var preallocated_arenas: usize = 0;
    for (server.clients) |client| {
        if (client.request_arena != null) preallocated_arenas += 1;
    }
    try std.testing.expect(preallocated_arenas > 0);
    const baseline_allocations = counting_parent.active_allocations;
    const baseline_bytes = counting_parent.active_bytes;

    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    var client_closed = false;
    defer if (!client_closed) posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    _ = try posix.write(client_fd, "GET /parent-owned HTTP/1.1\r\nHost: localhost\r\n\r\n");
    pollFor(&server, 500);

    var resp_buf: [2048]u8 = undefined;
    const n = try posix.read(client_fd, &resp_buf);
    const resp = resp_buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Varuna-Test: parent-owned") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "{\"source\":\"parent\"}") != null);

    posix.close(client_fd);
    client_closed = true;
    pollFor(&server, 200);

    try std.testing.expectEqual(baseline_allocations, counting_parent.active_allocations);
    try std.testing.expectEqual(baseline_bytes, counting_parent.active_bytes);
}

test "ApiHandler category and tag list responses stay in request arena when cache is dirty" {
    var counting_parent: CountingAllocator = .{ .parent = std.testing.allocator };
    const parent = counting_parent.allocator();

    var sm = SessionManager.init(parent);
    defer sm.deinit();
    try sm.category_store.create("movies", "/srv/movies");
    try sm.tag_store.create("linux");

    var handler = rpc_handlers.ApiHandler{
        .session_manager = &sm,
        .sync_state = rpc_sync.SyncState.init(parent),
        .peer_sync_state = rpc_sync.PeerSyncState.init(parent),
    };
    defer handler.sync_state.deinit();
    defer handler.peer_sync_state.deinit();

    var rng = Random.simRandom(0x5176);
    const sid = handler.session_store.createSession(&rng);

    var arena = try scratch.TieredArena.init(parent, rpc_server.request_arena_slab, rpc_server.request_arena_capacity);
    defer arena.deinit();

    const baseline_allocations = counting_parent.active_allocations;
    const baseline_bytes = counting_parent.active_bytes;

    {
        arena.reset();
        const resp = handler.handle(arena.allocator(), .{
            .method = "GET",
            .path = "/api/v2/torrents/categories",
            .cookie_sid = &sid,
        });
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"movies\"") != null);
        try std.testing.expect(resp.owned_body != null);
        try std.testing.expect(arena.ownsSlice(resp.owned_body.?));
        arena.reset();
        try std.testing.expectEqual(baseline_allocations, counting_parent.active_allocations);
        try std.testing.expectEqual(baseline_bytes, counting_parent.active_bytes);
    }

    {
        arena.reset();
        const resp = handler.handle(arena.allocator(), .{
            .method = "GET",
            .path = "/api/v2/torrents/tags",
            .cookie_sid = &sid,
        });
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"linux\"") != null);
        try std.testing.expect(resp.owned_body != null);
        try std.testing.expect(arena.ownsSlice(resp.owned_body.?));
        arena.reset();
        try std.testing.expectEqual(baseline_allocations, counting_parent.active_allocations);
        try std.testing.expectEqual(baseline_bytes, counting_parent.active_bytes);
    }
}

fn buildMetainfo(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d4:infod");
    try buf.appendSlice(allocator, "6:lengthi1024e");
    try buf.writer(allocator).print("4:name{d}:{s}", .{ name.len, name });
    try buf.appendSlice(allocator, "12:piece lengthi1024e");
    try buf.appendSlice(allocator, "6:pieces20:abcdefghijklmnopqrst");
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

fn insertArenaProbeTorrent(
    allocator: std.mem.Allocator,
    sm: *SessionManager,
    rng: *Random,
    name: []const u8,
) !struct {
    hash: [40]u8,
    metainfo: []u8,
} {
    const meta = try buildMetainfo(allocator, name);
    defer allocator.free(meta);
    const meta_copy = try allocator.dupe(u8, meta);
    errdefer allocator.free(meta_copy);

    const session = try allocator.create(TorrentSession);
    errdefer allocator.destroy(session);
    session.* = try TorrentSession.create(allocator, rng, meta, "/tmp/varuna-rpc-arena-test", null);
    errdefer session.deinit();

    const hash = session.info_hash_hex;
    try sm.sessions.put(&session.info_hash_hex, session);
    return .{ .hash = hash, .metainfo = meta_copy };
}

test "ApiHandler dynamic endpoint responses stay in request arena" {
    var counting_parent: CountingAllocator = .{ .parent = std.testing.allocator };
    const parent = counting_parent.allocator();

    var sm = SessionManager.init(parent);
    defer sm.deinit();

    var rng = Random.simRandom(0xA4E6A);
    const inserted = try insertArenaProbeTorrent(parent, &sm, &rng, "export.bin");
    defer parent.free(inserted.metainfo);

    var handler = rpc_handlers.ApiHandler{
        .session_manager = &sm,
        .sync_state = rpc_sync.SyncState.init(parent),
        .peer_sync_state = rpc_sync.PeerSyncState.init(parent),
    };
    defer handler.sync_state.deinit();
    defer handler.peer_sync_state.deinit();

    const sid = handler.session_store.createSession(&rng);

    var arena = try scratch.TieredArena.init(parent, rpc_server.request_arena_slab, rpc_server.request_arena_capacity);
    defer arena.deinit();

    const baseline_allocations = counting_parent.active_allocations;
    const baseline_bytes = counting_parent.active_bytes;

    const DynamicProbe = struct {
        fn expectBodyInArena(
            h: *rpc_handlers.ApiHandler,
            a: *scratch.TieredArena,
            method: []const u8,
            path: []const u8,
            body: []const u8,
            cookie_sid: ?[]const u8,
            expected_status: u16,
            needle: []const u8,
        ) !void {
            a.reset();
            const resp = h.handle(a.allocator(), .{
                .method = method,
                .path = path,
                .body = body,
                .cookie_sid = cookie_sid,
            });
            try std.testing.expectEqual(expected_status, resp.status);
            try std.testing.expect(std.mem.indexOf(u8, resp.body, needle) != null);
            try std.testing.expect(resp.owned_body != null);
            try std.testing.expect(a.ownsSlice(resp.owned_body.?));
        }

        fn expectHeadersInArena(
            h: *rpc_handlers.ApiHandler,
            a: *scratch.TieredArena,
            method: []const u8,
            path: []const u8,
            body: []const u8,
            needle: []const u8,
        ) !void {
            a.reset();
            const resp = h.handle(a.allocator(), .{
                .method = method,
                .path = path,
                .body = body,
            });
            try std.testing.expectEqual(@as(u16, 200), resp.status);
            try std.testing.expect(resp.owned_extra_headers != null);
            try std.testing.expect(a.ownsSlice(resp.owned_extra_headers.?));
            try std.testing.expect(resp.extra_headers != null);
            try std.testing.expect(std.mem.indexOf(u8, resp.extra_headers.?, needle) != null);
        }
    };

    try DynamicProbe.expectHeadersInArena(
        &handler,
        &arena,
        "POST",
        "/api/v2/auth/login",
        "username=admin&password=adminadmin",
        "Set-Cookie: SID=",
    );

    try DynamicProbe.expectBodyInArena(
        &handler,
        &arena,
        "GET",
        "/api/v2/app/preferences",
        "",
        &sid,
        200,
        "\"save_path\"",
    );

    try DynamicProbe.expectBodyInArena(
        &handler,
        &arena,
        "GET",
        "/api/v2/transfer/info",
        "",
        &sid,
        200,
        "\"connection_status\"",
    );

    {
        arena.reset();
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/api/v2/torrents/export?hash={s}", .{inserted.hash});
        const resp = handler.handle(arena.allocator(), .{
            .method = "GET",
            .path = path,
            .cookie_sid = &sid,
        });
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("application/x-bittorrent", resp.content_type);
        try std.testing.expectEqualStrings(inserted.metainfo, resp.body);
        try std.testing.expect(resp.owned_body != null);
        try std.testing.expect(arena.ownsSlice(resp.owned_body.?));
    }

    arena.reset();
    try std.testing.expectEqual(baseline_allocations, counting_parent.active_allocations);
    try std.testing.expectEqual(baseline_bytes, counting_parent.active_bytes);
}

// ── 3. Safety-under-fault: oversize response ──────────────

fn oversizeHandler(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    _ = request;
    // Try to allocate well past the arena cap. Must fail with OOM; the
    // handler returns 500 and the server still answers cleanly.
    const huge = allocator.alloc(u8, rpc_server.request_arena_capacity + 1) catch
        return .{ .status = 500, .body = "{\"error\":\"too_big\"}" };
    return .{ .body = huge, .owned_body = huge };
}

test "ApiServer surfaces 500 on arena cap exceeded — no leak" {
    var test_io = backend.initWithCapacity(std.testing.allocator, 64) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(oversizeHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    var client_closed = false;
    defer if (!client_closed) posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    _ = try posix.write(client_fd, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
    pollFor(&server, 500);

    var resp_buf: [4096]u8 = undefined;
    const n = try posix.read(client_fd, &resp_buf);
    const resp = resp_buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "too_big") != null);

    // Drain the pending embedded recv op before deinit.
    posix.close(client_fd);
    client_closed = true;
    pollFor(&server, 200);
}

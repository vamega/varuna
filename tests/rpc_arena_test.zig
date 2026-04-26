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
const scratch = varuna.rpc.scratch;

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

    var test_ring = linux.IoUring.init(64, 0) catch return error.SkipZigTest;
    defer test_ring.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_ring, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(arenaProbeHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);
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
    var test_ring = linux.IoUring.init(64, 0) catch return error.SkipZigTest;
    defer test_ring.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_ring, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(oversizeHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    _ = try posix.write(client_fd, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
    pollFor(&server, 500);

    var resp_buf: [4096]u8 = undefined;
    const n = try posix.read(client_fd, &resp_buf);
    const resp = resp_buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, resp, "HTTP/1.1 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "too_big") != null);
}

const std = @import("std");
const varuna = @import("varuna");
const handlers_mod = varuna.rpc.handlers;
const server_mod = varuna.rpc.server;
const SessionManager = varuna.daemon.session_manager.SessionManager;

// ── API endpoint tests ─────────────────────────────────────────
//
// These tests verify the new API handler routing and response structure
// by constructing an ApiHandler with a minimal SessionManager (no event
// loop) and exercising each endpoint through the handle() dispatch path.

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,

    fn init() TestCtx {
        const sm = std.testing.allocator.create(SessionManager) catch @panic("alloc");
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/test-downloads";
        var handler = handlers_mod.ApiHandler{
            .session_manager = sm,
            .sync_state = .{ .allocator = std.testing.allocator },
            .peer_sync_state = .{ .allocator = std.testing.allocator },
        };
        const sid = handler.session_store.createSession();
        return .{ .handler = handler, .sm = sm, .sid = sid };
    }

    fn deinit(self: *TestCtx) void {
        self.sm.deinit();
        std.testing.allocator.destroy(self.sm);
    }

    fn handle(self: *TestCtx, method: []const u8, path: []const u8, body: []const u8) server_mod.Response {
        return self.handler.handle(std.testing.allocator, .{
            .method = method,
            .path = path,
            .body = body,
            .cookie_sid = &self.sid,
        });
    }
};

// ── Route existence tests ──────────────────────────────────────

test "defaultSavePath returns plain text" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/app/defaultSavePath", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("text/plain", resp.content_type);
    try std.testing.expectEqualStrings("/tmp/test-downloads", resp.body);
}

test "toggleSpeedLimitsMode returns 501 Not Implemented" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/transfer/toggleSpeedLimitsMode", "");
    try std.testing.expectEqual(@as(u16, 501), resp.status);
}

test "transfer/downloadLimit returns 0 without event loop" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/transfer/downloadLimit", "");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("text/plain", resp.content_type);
    try std.testing.expectEqualStrings("0", resp.body);
}

test "transfer/uploadLimit returns 0 without event loop" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/transfer/uploadLimit", "");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("0", resp.body);
}

test "transfer/setDownloadLimit requires limit param" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/transfer/setDownloadLimit", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "transfer/setUploadLimit requires limit param" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/transfer/setUploadLimit", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/rename requires hash and name" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/rename", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/rename with unknown hash returns 404" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/rename", "hash=0000000000000000000000000000000000000000&name=newname");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "torrents/toggleSequentialDownload requires hashes" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/toggleSequentialDownload", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/setAutoManagement returns 501 Not Implemented" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/setAutoManagement", "hashes=abc&enable=true");
    try std.testing.expectEqual(@as(u16, 501), resp.status);
}

test "torrents/setForceStart requires hashes" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/setForceStart", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/pieceStates requires hash" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/torrents/pieceStates", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/pieceStates with unknown hash returns 404" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/torrents/pieceStates?hash=0000000000000000000000000000000000000000", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "torrents/pieceHashes requires hash" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/torrents/pieceHashes", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/pieceHashes with unknown hash returns 404" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/torrents/pieceHashes?hash=0000000000000000000000000000000000000000", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "torrents/renameFile returns 501 Not Implemented" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/renameFile", "hash=abc&oldPath=a&newPath=b");
    try std.testing.expectEqual(@as(u16, 501), resp.status);
}

test "torrents/renameFolder returns 501 Not Implemented" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/renameFolder", "hash=abc&oldPath=a&newPath=b");
    try std.testing.expectEqual(@as(u16, 501), resp.status);
}

test "torrents/export with unknown hash returns 404" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("GET", "/api/v2/torrents/export?hash=0000000000000000000000000000000000000000", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "torrents/addPeers requires hashes and peers" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/addPeers", "");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "torrents/addPeers requires peers param" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const resp = ctx.handle("POST", "/api/v2/torrents/addPeers", "hashes=abc");
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

// ── SessionManager unit tests ──────────────────────────────────

test "parseIpPort parses valid IPv4:port" {
    const addr = SessionManager.parseIpPort("192.168.1.1:6881");
    try std.testing.expect(addr != null);
    try std.testing.expectEqual(@as(u16, 6881), addr.?.getPort());
}

test "parseIpPort returns null for garbage" {
    try std.testing.expect(SessionManager.parseIpPort("not-an-address") == null);
    try std.testing.expect(SessionManager.parseIpPort("") == null);
    try std.testing.expect(SessionManager.parseIpPort(":1234") == null);
}

// ── Unauthorized request tests ──────────────────────────────────

test "new endpoints require authentication" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // No cookie_sid -> should get 403 Forbidden
    const resp = ctx.handler.handle(std.testing.allocator, .{
        .method = "GET",
        .path = "/api/v2/app/defaultSavePath",
        .body = "",
        .cookie_sid = null,
    });
    try std.testing.expectEqual(@as(u16, 403), resp.status);
}

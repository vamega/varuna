//! Happy-path API tests: share limits + properties round-trip (T4).
//!
//! `setShareLimits` accepts the qBittorrent-shaped `ratioLimit` /
//! `seedingTimeLimit` query parameters and stores them on the
//! TorrentSession. `torrents/properties` then surfaces them back as
//! the JSON keys `ratio_limit` / `seeding_time_limit`. The round-trip
//! through both endpoints is what users actually see — these tests
//! pin that contract.
//!
//! `tests/api_endpoints_test.zig` covers only error cases for these
//! endpoints; this fills the happy-path side.

const std = @import("std");
const varuna = @import("varuna");
const handlers_mod = varuna.rpc.handlers;
const server_mod = varuna.rpc.server;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,

    fn init() TestCtx {
        const sm = std.testing.allocator.create(SessionManager) catch @panic("alloc");
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/varuna-share-limits-test";
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

    fn insertTorrent(self: *TestCtx, name: []const u8) ![40]u8 {
        const allocator = std.testing.allocator;
        const meta = try buildMetainfo(allocator, name);
        defer allocator.free(meta);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        session.* = try TorrentSession.create(allocator, meta, "/tmp/varuna-share-limits-test", null);

        const hex = session.info_hash_hex;
        try self.sm.sessions.put(&session.info_hash_hex, session);
        return hex;
    }
};

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

fn freeBody(resp: server_mod.Response) void {
    if (resp.owned_body) |b| std.testing.allocator.free(b);
}

// ── Round-trip: setShareLimits → torrents/properties ───────────

test "setShareLimits stores ratio + seeding time, properties surfaces them" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-share.bin");

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&ratioLimit=2.5&seedingTimeLimit=4320", .{hash});

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/setShareLimits", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Verify in-memory state.
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(f64, 2.5), session.ratio_limit);
        try std.testing.expectEqual(@as(i64, 4320), session.seeding_time_limit);
    }

    // Verify the user-visible API surface (properties) reflects them.
    var prop_buf: [128]u8 = undefined;
    const prop_path = try std.fmt.bufPrint(&prop_buf, "/api/v2/torrents/properties?hash={s}", .{hash});
    {
        const resp = ctx.handle("GET", prop_path, "");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"ratio_limit\":2.5000") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"seeding_time_limit\":4320") != null);
    }
}

test "setShareLimits with -1 stores 'no limit' sentinel" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-nolimit.bin");

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&ratioLimit=-1&seedingTimeLimit=-1", .{hash});

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/setShareLimits", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(f64, -1.0), session.ratio_limit);
    try std.testing.expectEqual(@as(i64, -1), session.seeding_time_limit);
}

test "setShareLimits with omitted params keeps -2 'use global' default" {
    // The handler interprets a missing `ratioLimit` / `seedingTimeLimit`
    // as -2 (use global). Verify that's not a bug — the parse path
    // shouldn't treat the bare hashes-only body as an error.
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-default.bin");
    // Defaults on a fresh TorrentSession.
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(f64, -2.0), session.ratio_limit);
        try std.testing.expectEqual(@as(i64, -2), session.seeding_time_limit);
    }

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hashes={s}", .{hash});

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/setShareLimits", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(f64, -2.0), session.ratio_limit);
    try std.testing.expectEqual(@as(i64, -2), session.seeding_time_limit);
}

test "setShareLimits with multiple pipe-separated hashes applies to all" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const a = try ctx.insertTorrent("torrent-a.bin");
    const b = try ctx.insertTorrent("torrent-b.bin");

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hashes={s}|{s}&ratioLimit=3.0&seedingTimeLimit=600", .{ a, b });

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/setShareLimits", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    inline for (.{ a, b }) |hash| {
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(f64, 3.0), session.ratio_limit);
        try std.testing.expectEqual(@as(i64, 600), session.seeding_time_limit);
    }
}

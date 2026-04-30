//! Happy-path API tests: categories + tags (T4).
//!
//! These tests round-trip a real change through `ApiHandler.handle`
//! and verify the new state is observable through subsequent reads.
//! `tests/api_endpoints_test.zig` already covers the negative paths
//! (missing params, unknown hashes); this file fills the matching
//! positive-path gap so a regression that breaks the actual mutation
//! is caught.
//!
//! We don't stand up a full event loop, so torrents are inserted
//! directly into `SessionManager.sessions` via the `insertTorrent`
//! helper. That sidesteps the `shared_event_loop`-required path of
//! `addTorrent` while still exercising the same handler→SM→
//! TorrentSession surface.

const std = @import("std");
const varuna = @import("varuna");
const handlers_mod = varuna.rpc.handlers;
const server_mod = varuna.rpc.server;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;

// ── Shared fixture ─────────────────────────────────────────────

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,

    fn init() TestCtx {
        const sm = std.testing.allocator.create(SessionManager) catch @panic("alloc");
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/varuna-categories-test";
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

    /// Insert a torrent session directly into `sessions` so handlers
    /// that look up by hash work without a shared event loop.
    /// Returns the 40-char hex info-hash.
    fn insertTorrent(self: *TestCtx, name: []const u8) ![40]u8 {
        const allocator = std.testing.allocator;
        const meta = try buildMetainfo(allocator, name, 0);
        defer allocator.free(meta);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        session.* = try TorrentSession.create(allocator, meta, "/tmp/varuna-categories-test/" ++ "x", null);

        const hex = session.info_hash_hex;
        try self.sm.sessions.put(&session.info_hash_hex, session);
        return hex;
    }
};

fn buildMetainfo(allocator: std.mem.Allocator, name: []const u8, private_flag: u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d4:infod");
    try buf.appendSlice(allocator, "6:lengthi1024e");
    try buf.writer(allocator).print("4:name{d}:{s}", .{ name.len, name });
    try buf.appendSlice(allocator, "12:piece lengthi1024e");
    try buf.appendSlice(allocator, "6:pieces20:abcdefghijklmnopqrst");
    try buf.writer(allocator).print("7:privatei{d}e", .{private_flag});
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

fn freeBody(resp: server_mod.Response) void {
    if (resp.owned_body) |b| std.testing.allocator.free(b);
}

// ── Categories: create → list → assign → list ──────────────────

test "categories happy-path: createCategory, list, setCategory, list" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent1.bin");

    // Empty list.
    {
        const resp = ctx.handle("GET", "/api/v2/torrents/categories", "");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("{}", resp.body);
    }

    // Create.
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=movies&savePath=/srv/movies");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // List shows it.
    {
        const resp = ctx.handle("GET", "/api/v2/torrents/categories", "");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"movies\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/srv/movies") != null);
    }

    // Assign to torrent.
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&category=movies", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Verify the SessionManager observed the change.
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expect(session.category != null);
        try std.testing.expectEqualStrings("movies", session.category.?);
    }
}

test "editCategory updates savePath in store" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=tv&savePath=/srv/tv");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/editCategory", "category=tv&savePath=/mnt/tv-new");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    {
        const resp = ctx.handle("GET", "/api/v2/torrents/categories", "");
        defer freeBody(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/mnt/tv-new") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "/srv/tv") == null);
    }
}

test "removeCategories drops the assigned torrent's category back to null" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent2.bin");

    // Setup: create + assign.
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=archive&savePath=/srv/archive");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&category=archive", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Remove the category.
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/removeCategories", "categories=archive");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Torrent's category should be cleared (production explicitly
    // walks the sessions map and frees `session.category` when the
    // category is removed).
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expect(session.category == null);
    }
}

test "setCategory clears category when given empty value" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent3.bin");

    // Create + assign.
    _ = blk: {
        const r = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=keep&savePath=/srv/keep");
        defer freeBody(r);
        break :blk r;
    };
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&category=keep", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Now clear by passing empty `category`.
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&category=", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expect(session.category == null);
    }
}

// ── Tags: create → add to torrent → list → remove → delete ─────

test "tags happy-path: createTags, addTags, list, removeTags, deleteTags" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-tags.bin");

    // Create globally.
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createTags", "tags=hd,trusted");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Tag list reflects creation.
    {
        const resp = ctx.handle("GET", "/api/v2/torrents/tags", "");
        defer freeBody(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"hd\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"trusted\"") != null);
    }

    // Apply both tags to the torrent.
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&tags=hd,trusted", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/addTags", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(usize, 2), session.tags.items.len);
    }

    // Remove one from the torrent.
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&tags=hd", .{hash});
        const resp = ctx.handle("POST", "/api/v2/torrents/removeTags", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(usize, 1), session.tags.items.len);
        try std.testing.expectEqualStrings("trusted", session.tags.items[0]);
    }

    // Delete the remaining tag from the global store. Torrent should
    // also lose it (production walks all sessions and prunes matching
    // tags on deletion).
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/deleteTags", "tags=trusted");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expectEqual(@as(usize, 0), session.tags.items.len);
    }
}

test "addTags is idempotent (re-adding an existing tag is a no-op)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-idempotent.bin");

    var body_buf: [256]u8 = undefined;
    const add_body = try std.fmt.bufPrint(&body_buf, "hashes={s}&tags=alpha", .{hash});
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTags", add_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTags", add_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session.tags.items.len);
    try std.testing.expectEqualStrings("alpha", session.tags.items[0]);
}

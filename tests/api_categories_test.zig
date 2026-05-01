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
const Random = varuna.runtime.random.Random;

// ── Shared fixture ─────────────────────────────────────────────

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,
    random: Random,

    fn init() TestCtx {
        const sm = std.testing.allocator.create(SessionManager) catch @panic("alloc");
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/varuna-categories-test";
        var handler = handlers_mod.ApiHandler{
            .session_manager = sm,
            .sync_state = .{ .allocator = std.testing.allocator },
            .peer_sync_state = .{ .allocator = std.testing.allocator },
        };
        var random = Random.simRandom(0xDEADBEEF);
        const sid = handler.session_store.createSession(&random);
        return .{ .handler = handler, .sm = sm, .sid = sid, .random = random };
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
        session.* = try TorrentSession.create(allocator, &self.random, meta, "/tmp/varuna-categories-test/" ++ "x", null);

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

test "setCategory with hashes=all applies to every torrent" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const a = try ctx.insertTorrent("all-category-a.bin");
    const b = try ctx.insertTorrent("all-category-b.bin");

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=batch&savePath=/srv/batch");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", "hashes=all&category=batch");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    inline for (.{ a, b }) |hash| {
        const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
        try std.testing.expect(session.category != null);
        try std.testing.expectEqualStrings("batch", session.category.?);
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

test "addTags with pipe-separated hashes applies to each selected torrent" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const a = try ctx.insertTorrent("pipe-tags-a.bin");
    const b = try ctx.insertTorrent("pipe-tags-b.bin");
    const c = try ctx.insertTorrent("pipe-tags-c.bin");

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hashes={s}|{s}&tags=selected", .{ a, b });
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTags", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session_a = ctx.sm.sessions.get(&a) orelse return error.SessionMissing;
    const session_b = ctx.sm.sessions.get(&b) orelse return error.SessionMissing;
    const session_c = ctx.sm.sessions.get(&c) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session_a.tags.items.len);
    try std.testing.expectEqual(@as(usize, 1), session_b.tags.items.len);
    try std.testing.expectEqual(@as(usize, 0), session_c.tags.items.len);
    try std.testing.expectEqualStrings("selected", session_a.tags.items[0]);
    try std.testing.expectEqualStrings("selected", session_b.tags.items[0]);
}

test "torrents info filters by hashes category tag and state" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const linux = try ctx.insertTorrent("linux.iso");
    const movie = try ctx.insertTorrent("movie.mkv");
    const book = try ctx.insertTorrent("book.epub");

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/createCategory", "category=media&savePath=/srv/media");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&category=media", .{movie});
        const resp = ctx.handle("POST", "/api/v2/torrents/setCategory", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&tags=favorite", .{movie});
        const resp = ctx.handle("POST", "/api/v2/torrents/addTags", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const session = ctx.sm.sessions.get(&movie) orelse return error.SessionMissing;
        session.state = .paused;
    }

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "/api/v2/torrents/info?hashes={s}|{s}&category=media&tag=favorite&filter=paused",
        .{ linux, movie },
    );
    const resp = ctx.handle("GET", path, "");
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &movie) != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &linux) == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &book) == null);
}

test "torrents info sorts then applies offset and limit" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const zed = try ctx.insertTorrent("zed.bin");
    const alpha = try ctx.insertTorrent("alpha.bin");
    const middle = try ctx.insertTorrent("middle.bin");

    const resp = ctx.handle("GET", "/api/v2/torrents/info?sort=name&offset=1&limit=1", "");
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &middle) != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &alpha) == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &zed) == null);
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

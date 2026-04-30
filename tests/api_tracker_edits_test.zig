//! Happy-path API tests: tracker overrides (T4).
//!
//! `addTrackers`, `editTracker`, and `removeTrackers` all manipulate
//! the `TorrentSession.tracker_overrides` overlay on top of the
//! metainfo-supplied announce list. Existing tests cover the
//! validation cases (missing params, unknown hash); this file
//! verifies the overlay actually mutates as expected when the inputs
//! are valid.
//!
//! We don't need a started session for these tests because the
//! mutators only touch the in-memory `TrackerOverrides` struct — the
//! re-announce that production also fires on success is a best-effort
//! call and harmless to skip.

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
        sm.default_save_path = "/tmp/varuna-tracker-edit-test";
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

    /// Insert a torrent whose metainfo carries an announce URL we can
    /// edit/remove against.
    fn insertTorrent(self: *TestCtx, name: []const u8) ![40]u8 {
        const allocator = std.testing.allocator;
        const meta = try buildMetainfo(allocator, name);
        defer allocator.free(meta);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        session.* = try TorrentSession.create(allocator, meta, "/tmp/varuna-tracker-edit-test", null);

        const hex = session.info_hash_hex;
        try self.sm.sessions.put(&session.info_hash_hex, session);
        return hex;
    }
};

fn buildMetainfo(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // bencode dict ordering: announce → info (lex order). Length
    // prefix must match the byte count exactly — the URL below is 18
    // bytes so the prefix is `18:`. Mis-matching this is a silent
    // bencode-parse failure.
    try buf.appendSlice(allocator, "d8:announce18:http://t.test/anno");
    try buf.appendSlice(allocator, "4:infod");
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

// ── addTrackers happy path ────────────────────────────────────

test "addTrackers appends a user-added URL to tracker_overrides.added" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-add.bin");

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hash={s}&urls=http://added.test/announce", .{hash});

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTrackers", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session.tracker_overrides.added.items.len);
    try std.testing.expectEqualStrings(
        "http://added.test/announce",
        session.tracker_overrides.added.items[0].url,
    );
}

test "addTrackers handles %0A-separated multi-URL bodies" {
    // qBittorrent sends multiple URLs separated by `%0A` (URL-encoded
    // newline). Verify the parse path handles that.
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-multi.bin");

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "hash={s}&urls=http://a.example/announce%0Ahttp://b.example/announce",
        .{hash},
    );

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTrackers", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 2), session.tracker_overrides.added.items.len);
}

// ── editTracker happy path ────────────────────────────────────

test "editTracker on a metainfo URL records an 'edit' override" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-edit.bin");

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "hash={s}&origUrl=http://t.test/anno&newUrl=http://replaced.example/announce",
        .{hash},
    );

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/editTracker", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session.tracker_overrides.edits.items.len);
    const edit = session.tracker_overrides.edits.items[0];
    try std.testing.expectEqualStrings("http://t.test/anno", edit.orig_url);
    try std.testing.expectEqualStrings("http://replaced.example/announce", edit.new_url);
}

test "editTracker on a previously-added URL replaces it in-place" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-edit-added.bin");

    var add_buf: [256]u8 = undefined;
    const add_body = try std.fmt.bufPrint(&add_buf, "hash={s}&urls=http://added-a.example/announce", .{hash});
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTrackers", add_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    var edit_buf: [512]u8 = undefined;
    const edit_body = try std.fmt.bufPrint(
        &edit_buf,
        "hash={s}&origUrl=http://added-a.example/announce&newUrl=http://added-b.example/announce",
        .{hash},
    );
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/editTracker", edit_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    // No 'edit' override; the added entry was replaced in place.
    try std.testing.expectEqual(@as(usize, 0), session.tracker_overrides.edits.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.tracker_overrides.added.items.len);
    try std.testing.expectEqualStrings(
        "http://added-b.example/announce",
        session.tracker_overrides.added.items[0].url,
    );
}

// ── removeTrackers happy path ─────────────────────────────────

test "removeTrackers on a user-added URL drops it from added list" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-remove.bin");

    var add_buf: [256]u8 = undefined;
    const add_body = try std.fmt.bufPrint(&add_buf, "hash={s}&urls=http://x.example/announce", .{hash});
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/addTrackers", add_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    var rm_buf: [256]u8 = undefined;
    const rm_body = try std.fmt.bufPrint(&rm_buf, "hash={s}&urls=http://x.example/announce", .{hash});
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/removeTrackers", rm_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 0), session.tracker_overrides.added.items.len);
    // Removing a user-added URL doesn't promote it into the 'removed'
    // list — that list is only for hiding metainfo URLs.
    try std.testing.expectEqual(@as(usize, 0), session.tracker_overrides.removed.items.len);
}

test "removeTrackers on a metainfo URL records a 'remove' override" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-remove-meta.bin");

    var rm_buf: [256]u8 = undefined;
    const rm_body = try std.fmt.bufPrint(
        &rm_buf,
        "hash={s}&urls=http://t.test/anno",
        .{hash},
    );
    {
        const resp = ctx.handle("POST", "/api/v2/torrents/removeTrackers", rm_body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session.tracker_overrides.removed.items.len);
    try std.testing.expectEqualStrings(
        "http://t.test/anno",
        session.tracker_overrides.removed.items[0],
    );
}

test "addTrackers de-duplicates against existing added URLs" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const hash = try ctx.insertTorrent("torrent-dup.bin");

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hash={s}&urls=http://once.example/announce", .{hash});

    // Add twice.
    {
        const r1 = ctx.handle("POST", "/api/v2/torrents/addTrackers", body);
        defer freeBody(r1);
        try std.testing.expectEqual(@as(u16, 200), r1.status);
    }
    {
        const r2 = ctx.handle("POST", "/api/v2/torrents/addTrackers", body);
        defer freeBody(r2);
        try std.testing.expectEqual(@as(u16, 200), r2.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&hash) orelse return error.SessionMissing;
    try std.testing.expectEqual(@as(usize, 1), session.tracker_overrides.added.items.len);
}

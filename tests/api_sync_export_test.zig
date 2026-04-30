//! Happy-path API tests: sync deltas, export, addPeers, rename (T4).
//!
//! Each test round-trips a real change through the API and verifies
//! the new state is observable through the appropriate read path.
//!
//! Notes on what's testable without a full event loop:
//! - `rename` is purely in-memory on `TorrentSession.name`. Direct
//!   inspection works.
//! - `export` returns `torrent_bytes` straight from the in-memory
//!   session; we can byte-compare against the input metainfo.
//! - `addPeers` actually queues into the event loop. Without one, the
//!   SessionManager call is a no-op past the parse step; we test that
//!   the request reaches the handler, parses, and returns 200.
//! - `sync/maindata` builds its delta from `getAllStats` which works
//!   regardless of started state, so we can fully test the rid
//!   round-trip and delta semantics.

const std = @import("std");
const varuna = @import("varuna");
const handlers_mod = varuna.rpc.handlers;
const server_mod = varuna.rpc.server;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;
const Random = varuna.runtime.random.Random;

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,
    random: Random,

    fn init() TestCtx {
        const sm = std.testing.allocator.create(SessionManager) catch @panic("alloc");
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/varuna-sync-export-test";
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
        self.handler.sync_state.deinit();
        self.handler.peer_sync_state.deinit();
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

    /// Insert a torrent and return both its info-hash (hex) and a
    /// duplicate of the metainfo bytes (so the test can byte-compare
    /// against the export output without poking at internals).
    fn insertTorrent(self: *TestCtx, name: []const u8) !struct {
        hash: [40]u8,
        meta_copy: []u8,
    } {
        const allocator = std.testing.allocator;
        const meta = try buildMetainfo(allocator, name);
        const meta_copy = try allocator.dupe(u8, meta);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        // `TorrentSession.create` dupes `torrent_bytes` internally, so
        // freeing `meta` here is safe.
        session.* = try TorrentSession.create(allocator, &self.random, meta, "/tmp/varuna-sync-export-test", null);
        allocator.free(meta);

        const hex = session.info_hash_hex;
        try self.sm.sessions.put(&session.info_hash_hex, session);
        return .{ .hash = hex, .meta_copy = meta_copy };
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

// ── rename happy path ─────────────────────────────────────────

test "rename updates session.name in place" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("original-name.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hash={s}&name=renamed-display", .{inserted.hash});

    {
        const resp = ctx.handle("POST", "/api/v2/torrents/rename", body);
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    ctx.sm.mutex.lock();
    defer ctx.sm.mutex.unlock();
    const session = ctx.sm.sessions.get(&inserted.hash) orelse return error.SessionMissing;
    try std.testing.expectEqualStrings("renamed-display", session.name);
}

test "rename rejects empty name with 400" {
    // Negative companion to the happy-path test above. Both `hash` and
    // `name` are required and non-empty.
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("orig.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "hash={s}&name=", .{inserted.hash});
    const resp = ctx.handle("POST", "/api/v2/torrents/rename", body);
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

// ── export happy path ─────────────────────────────────────────

test "export returns the exact torrent bytes the session was created from" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("export-me.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/v2/torrents/export?hash={s}", .{inserted.hash});

    const resp = ctx.handle("GET", path, "");
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("application/x-bittorrent", resp.content_type);
    try std.testing.expectEqualSlices(u8, inserted.meta_copy, resp.body);
}

// ── addPeers reach-the-handler smoke ──────────────────────────

test "addPeers parses IP:port list and returns 200 when hash is known" {
    // `addManualPeers` walks the event loop's peer queue when one is
    // configured. Without a shared event loop the call is a no-op past
    // the parse step, but the handler must still reach
    // `session_manager.addManualPeers` and return success — that's the
    // contract this test pins. See `tests/api_endpoints_test.zig` for
    // the negative paths (missing peers / unknown hash).
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("peers.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "hashes={s}&peers=1.2.3.4:6881,5.6.7.8:51413",
        .{inserted.hash},
    );

    const resp = ctx.handle("POST", "/api/v2/torrents/addPeers", body);
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

// ── sync/maindata delta semantics ─────────────────────────────

test "sync/maindata first call (rid=0) returns full_update=true with rid=1" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("sync.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    const resp = ctx.handle("GET", "/api/v2/sync/maindata?rid=0", "");
    defer freeBody(resp);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"full_update\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"rid\":1") != null);
    // Torrent must appear in the snapshot.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, &inserted.hash) != null);
}

test "sync/maindata second call returns full_update=false and prunes unchanged torrents" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("delta.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    // Round 1: rid=0 → rid=1.
    {
        const resp = ctx.handle("GET", "/api/v2/sync/maindata?rid=0", "");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);
    }

    // Round 2: rid=1 → rid=2. Torrent unchanged → should NOT appear.
    {
        const resp = ctx.handle("GET", "/api/v2/sync/maindata?rid=1", "");
        defer freeBody(resp);
        try std.testing.expectEqual(@as(u16, 200), resp.status);

        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"full_update\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"rid\":2") != null);
        // The unchanged torrent must NOT be present in the delta.
        try std.testing.expect(std.mem.indexOf(u8, resp.body, &inserted.hash) == null);
    }
}

test "sync/maindata surfaces a torrent again after its tags change" {
    // Apply a tag, then ask for the next delta. The torrent's stats
    // hash now differs from the previous snapshot, so it must show up.
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("delta-mut.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    // rid=0 → rid=1: full snapshot taken.
    {
        const r = ctx.handle("GET", "/api/v2/sync/maindata?rid=0", "");
        defer freeBody(r);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }

    // Apply a tag to mutate stats hash.
    {
        var body_buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "hashes={s}&tags=mutated", .{inserted.hash});
        const r = ctx.handle("POST", "/api/v2/torrents/addTags", body);
        defer freeBody(r);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }

    // rid=1 → rid=2: torrent must appear in the delta.
    {
        const r = ctx.handle("GET", "/api/v2/sync/maindata?rid=1", "");
        defer freeBody(r);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, &inserted.hash) != null);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"full_update\":false") != null);
    }
}

test "sync/maindata reports torrents_removed when a session disappears" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const inserted = try ctx.insertTorrent("doomed.bin");
    defer std.testing.allocator.free(inserted.meta_copy);

    // Establish baseline snapshot (rid=0 → rid=1).
    {
        const r = ctx.handle("GET", "/api/v2/sync/maindata?rid=0", "");
        defer freeBody(r);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }

    // Remove the torrent directly (full SM lifecycle is wired but
    // requires an event loop; pull it out by hand to keep the test
    // event-loop-free).
    {
        ctx.sm.mutex.lock();
        defer ctx.sm.mutex.unlock();
        const sess_ptr = ctx.sm.sessions.get(&inserted.hash) orelse return error.SessionMissing;
        _ = ctx.sm.sessions.remove(&inserted.hash);
        sess_ptr.deinit();
        std.testing.allocator.destroy(sess_ptr);
    }

    // rid=1 → rid=2: hash must show up in `torrents_removed`.
    {
        const r = ctx.handle("GET", "/api/v2/sync/maindata?rid=1", "");
        defer freeBody(r);
        try std.testing.expectEqual(@as(u16, 200), r.status);

        // Locate `torrents_removed` array and confirm our hash is in it.
        const idx = std.mem.indexOf(u8, r.body, "\"torrents_removed\":[") orelse return error.MalformedSnapshot;
        const tail = r.body[idx..];
        const close = std.mem.indexOfScalar(u8, tail, ']') orelse return error.MalformedSnapshot;
        const removed_section = tail[0 .. close + 1];
        try std.testing.expect(std.mem.indexOf(u8, removed_section, &inserted.hash) != null);
    }
}

//! Private-torrent DHT gating tests (BEP 27).
//!
//! Private torrents must never reach out to the DHT for peer discovery
//! or announce — that would defeat the privacy guarantee a private
//! tracker provides. The gate lives in three production call sites
//! (initial DHT register, post-integration force-requery, seed-mode
//! announce) and is centralised through the `TorrentSession.dht*`
//! helpers; these tests pin the contract so a future regression that
//! drops the gate is caught immediately.
//!
//! Strategy: stand up a real `DhtEngine` and a real `TorrentSession`
//! parsed from a metainfo blob with `private: 1` (and again with
//! `private: 0`), then drive the production helpers and assert
//! engine-side state. We don't need a full event loop — the helpers
//! talk directly to the engine — so this stays a layer-1 unit test
//! per `STYLE.md`'s Layered Testing Strategy.

const std = @import("std");
const varuna = @import("varuna");

const TorrentSession = varuna.daemon.torrent_session.TorrentSession;
const DhtEngine = varuna.dht.DhtEngine;
const NodeId = varuna.dht.NodeId;
const Random = varuna.runtime.random.Random;

/// One Random instance shared across all the test sessions; deterministic
/// seed so traces are reproducible.
var test_random = Random.simRandom(0xCAFEBABE);

// ── Fixture helpers ────────────────────────────────────────────

/// Build a minimal single-file v1 metainfo blob. `private_flag` is
/// the BEP 27 `private` integer (0 or 1). Caller owns the returned
/// slice.
fn buildMetainfo(allocator: std.mem.Allocator, name: []const u8, private_flag: u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // info dict ordering: bencode requires keys in lexicographic order.
    // Keys we need: length, name, piece length, pieces, private.
    try buf.appendSlice(allocator, "d4:infod");
    try buf.appendSlice(allocator, "6:lengthi1024e");
    try buf.writer(allocator).print("4:name{d}:{s}", .{ name.len, name });
    try buf.appendSlice(allocator, "12:piece lengthi1024e");
    try buf.appendSlice(allocator, "6:pieces20:abcdefghijklmnopqrst");
    try buf.writer(allocator).print("7:privatei{d}e", .{private_flag});
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Heap-allocate a TorrentSession parsed from the given metainfo blob.
/// Heap-allocation mirrors the production path in
/// `SessionManager.addTorrent` and sidesteps Zig 0.15's
/// "var never mutated" check that fires when a stack-allocated
/// session is only touched via `defer .deinit()`.
fn createSession(
    allocator: std.mem.Allocator,
    metainfo_bytes: []const u8,
    save_path: []const u8,
) !*TorrentSession {
    const session = try allocator.create(TorrentSession);
    errdefer allocator.destroy(session);
    session.* = try TorrentSession.create(allocator, &test_random, metainfo_bytes, save_path, null);
    return session;
}

fn destroySession(allocator: std.mem.Allocator, session: *TorrentSession) void {
    session.deinit();
    allocator.destroy(session);
}

/// Spin up a heap-allocated `DhtEngine` with a deterministic node ID
/// so test seed snapshots are stable. Caller frees with `destroyEngine`.
fn createEngine(allocator: std.mem.Allocator) !*DhtEngine {
    const node_id: NodeId = [_]u8{0xAB} ** 20;
    return try DhtEngine.create(allocator, &test_random, node_id);
}

fn destroyEngine(allocator: std.mem.Allocator, engine: *DhtEngine) void {
    engine.deinit();
    allocator.destroy(engine);
}

// ── Sanity: metainfo carries the private flag we built ─────────

test "private metainfo round-trips through TorrentSession.is_private" {
    const allocator = std.testing.allocator;

    const private_bytes = try buildMetainfo(allocator, "priv.bin", 1);
    defer allocator.free(private_bytes);
    const public_bytes = try buildMetainfo(allocator, "pub.bin", 0);
    defer allocator.free(public_bytes);

    const priv_sess = try createSession(allocator, private_bytes, "/tmp/priv");
    defer destroySession(allocator, priv_sess);
    const pub_sess = try createSession(allocator, public_bytes, "/tmp/pub");
    defer destroySession(allocator, pub_sess);

    try std.testing.expect(priv_sess.is_private);
    try std.testing.expect(!pub_sess.is_private);
}

// ── T2.1: requestPeers gating ──────────────────────────────────

test "private torrent does not register DHT requestPeers" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "priv.bin", 1);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/priv");
    defer destroySession(allocator, sess);

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);
    try std.testing.expectEqual(@as(u8, 0), engine.pending_search_count);

    const did_register = sess.dhtRegisterPeers(engine);

    try std.testing.expect(!did_register);
    try std.testing.expectEqual(@as(u8, 0), engine.pending_search_count);
}

test "public torrent does register DHT requestPeers" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "pub.bin", 0);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/pub");
    defer destroySession(allocator, sess);

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);
    try std.testing.expectEqual(@as(u8, 0), engine.pending_search_count);

    const did_register = sess.dhtRegisterPeers(engine);

    try std.testing.expect(did_register);
    try std.testing.expectEqual(@as(u8, 1), engine.pending_search_count);
    try std.testing.expectEqualSlices(
        u8,
        &sess.info_hash,
        &engine.pending_searches[0],
    );
}

// ── T2.2: forceRequery gating ──────────────────────────────────

test "private torrent does not forceRequery the DHT" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "priv.bin", 1);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/priv");
    defer destroySession(allocator, sess);

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    const did_requery = sess.dhtForceRequery(engine);

    try std.testing.expect(!did_requery);
    try std.testing.expectEqual(@as(u8, 0), engine.pending_search_count);
}

test "public torrent does forceRequery the DHT" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "pub.bin", 0);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/pub");
    defer destroySession(allocator, sess);

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    const did_requery = sess.dhtForceRequery(engine);

    try std.testing.expect(did_requery);
    // forceRequery on an unknown hash registers it fresh.
    try std.testing.expectEqual(@as(u8, 1), engine.pending_search_count);
    try std.testing.expect(!engine.pending_search_done[0]);
}

// ── T2.3: announcePeer gating ──────────────────────────────────

test "private torrent does not announcePeer to the DHT" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "priv.bin", 1);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/priv");
    defer destroySession(allocator, sess);
    sess.port = 6881;

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    const did_announce = sess.dhtAnnouncePeer(engine);

    try std.testing.expect(!did_announce);
    // announcePeer would have started a get_peers lookup as its
    // first phase. Verify the engine has no active lookups whose
    // target matches our private info-hash.
    for (&engine.active_lookups) |maybe_lk| {
        if (maybe_lk) |lk| {
            try std.testing.expect(!std.mem.eql(u8, &lk.target, &sess.info_hash));
        }
    }
}

test "public torrent does attempt DHT announcePeer" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "pub.bin", 0);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/pub");
    defer destroySession(allocator, sess);
    sess.port = 6881;

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    const did_announce = sess.dhtAnnouncePeer(engine);

    try std.testing.expect(did_announce);
    // The engine's `listen_port` records the port we asked it to
    // announce on; that's the cleanest signal that announcePeer was
    // actually entered (the `get_peers` lookup may or may not start
    // depending on routing-table state, which is empty in this test).
    try std.testing.expectEqual(@as(u16, 6881), engine.listen_port);
}

// ── T2.4: hybrid v1+v2 torrents respect the gate too ──────────

test "private hybrid (v2) torrent's truncated v2 hash also gated" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "priv.bin", 1);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/priv");
    defer destroySession(allocator, sess);

    // Force a fake v2 info-hash so we cover the v2-truncation path.
    sess.info_hash_v2 = [_]u8{0x55} ** 32;

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    _ = sess.dhtRegisterPeers(engine);
    _ = sess.dhtForceRequery(engine);
    _ = sess.dhtAnnouncePeer(engine);

    try std.testing.expectEqual(@as(u8, 0), engine.pending_search_count);
}

test "public hybrid (v2) torrent registers BOTH v1 and v2 hashes" {
    const allocator = std.testing.allocator;

    const bytes = try buildMetainfo(allocator, "pub.bin", 0);
    defer allocator.free(bytes);

    const sess = try createSession(allocator, bytes, "/tmp/pub");
    defer destroySession(allocator, sess);

    // Inject a deterministic v2 hash so we can verify the truncation
    // travels into the engine. Pure v1 returns a single registration;
    // hybrid registers two.
    sess.info_hash_v2 = [_]u8{0x77} ** 32;

    const engine = try createEngine(allocator);
    defer destroyEngine(allocator, engine);

    try std.testing.expect(sess.dhtRegisterPeers(engine));
    try std.testing.expectEqual(@as(u8, 2), engine.pending_search_count);

    var truncated_v2: [20]u8 = undefined;
    @memcpy(&truncated_v2, sess.info_hash_v2.?[0..20]);

    try std.testing.expectEqualSlices(u8, &sess.info_hash, &engine.pending_searches[0]);
    try std.testing.expectEqualSlices(u8, &truncated_v2, &engine.pending_searches[1]);
}

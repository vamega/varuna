const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const verify_mod = varuna.storage.verify;
const Sha1 = varuna.crypto.Sha1;
const Layout = varuna.torrent.layout.Layout;
const VirtualPeer = varuna.sim.VirtualPeer;

// ── Virtual-peer swarm tests ────────────────────────────────────
//
// These tests replace the real TCP listen socket from transfer_integration_test
// with an AF_UNIX socketpair controlled by a VirtualPeer.  A background thread
// runs the seeder-side BitTorrent protocol (handshake → bitfield → unchoke →
// piece response); the EventLoop runs in the test thread via el.tick().
//
// This exercises the full piece-download path — protocol parsing, disk writes,
// SHA-1 verification — without a real network stack or a second daemon instance.

const piece_data_len = 1024;
const max_ticks = 2000;

fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hash: [20]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name12:test_sim.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces20:");
    try buf.appendSlice(allocator, &piece_hash);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

// ── Seeder thread context ─────────────────────────────────────

const SeederCtx = struct {
    vp: VirtualPeer,
    info_hash: [20]u8,
    piece_data: *const [piece_data_len]u8,
    err: ?anyerror = null,

    fn run(ctx: *SeederCtx) void {
        ctx.runInner() catch |e| {
            ctx.err = e;
        };
    }

    fn runInner(ctx: *SeederCtx) !void {
        defer ctx.vp.deinit(); // close test-side fd when done

        // 1. Receive the EventLoop's BitTorrent handshake
        _ = try ctx.vp.recvHandshake();

        // 2. Send our handshake (no BEP 10 extension bit → EventLoop skips
        //    extension handshake, goes directly to INTERESTED)
        const seeder_peer_id = "-TSTVS000-simseeder0001"[0..20].*;
        try ctx.vp.sendHandshake(ctx.info_hash, seeder_peer_id);

        // 3. Advertise that we have all pieces
        try ctx.vp.sendBitfield(1, true);

        // 4. Unchoke the downloader so it can send REQUESTs
        try ctx.vp.sendUnchoke();

        // 5. Wait for a REQUEST and serve the block
        const req = try ctx.vp.waitForRequest();
        const block_end = req.begin + req.length;
        try ctx.vp.sendPiece(req.index, req.begin, ctx.piece_data[req.begin..block_end]);
    }
};

test "VirtualPeer seeder transfers a piece to EventLoop downloader" {
    const allocator = std.testing.allocator;

    // ── 1. Build piece data and compute its SHA-1 hash ─────────
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i ^ 0xA5);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    // ── 2. Build and parse the torrent metainfo ─────────────────
    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash);
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "data",
    });
    defer allocator.free(data_root);

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    // ── 3. Create the PieceStore (downloader starts with no data) ─
    var store = try PieceStore.init(allocator, &session);
    defer store.deinit();

    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    // ── 4. Create PieceTracker (downloader role) ────────────────
    var empty_bf = try varuna.bitfield.Bitfield.init(allocator, 1);
    defer empty_bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, 1, piece_data_len, piece_data_len, &empty_bf, 0);
    defer tracker.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), tracker.completedCount());

    // ── 5. Create EventLoop ──────────────────────────────────────
    var el = EventLoop.initBare(allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.encryption_mode = .disabled;
    // Advance the sim clock so time-based gates (unchoke interval, etc.) open.
    el.clock = .{ .sim = 10_000 };

    // ── 6. Register the torrent ──────────────────────────────────
    const peer_id = "-VR0001-simdl0000001".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, peer_id);

    // ── 7. Create socketpair and inject the EventLoop's fd ──────
    var pair = VirtualPeer.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer pair.vp.deinit();

    _ = try el.addConnectedPeer(pair.el_fd, tid);

    // ── 8. Spawn the seeder thread ───────────────────────────────
    var ctx = SeederCtx{
        .vp = pair.vp,
        .info_hash = session.metainfo.info_hash,
        .piece_data = &piece_data,
    };
    // Transfer fd ownership: the seeder thread owns ctx.vp.fd from here.
    pair.vp.fd = -1; // prevent double-close in defer above

    const seeder_thread = try std.Thread.spawn(.{}, SeederCtx.run, .{&ctx});

    // ── 9. Tick until piece is downloaded ───────────────────────
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        el.tick() catch |err| {
            std.debug.print("tick {d} error: {s}\n", .{ ticks, @errorName(err) });
            break;
        };
        if (tracker.completedCount() >= 1) break;
        el.submitTimeout(10_000_000) catch {}; // 10 ms fallback
    }

    seeder_thread.join();

    // ── 10. Report seeder-side errors ───────────────────────────
    if (ctx.err) |e| {
        std.debug.print("seeder thread error: {s}\n", .{@errorName(e)});
        return error.SeederFailed;
    }

    // ── 11. Verify piece was transferred ────────────────────────
    if (tracker.completedCount() < 1) {
        std.debug.print("FAIL: piece not received after {d} ticks\n", .{ticks});
        return error.TestUnexpectedResult;
    }

    // ── 12. Verify data integrity ────────────────────────────────
    var read_buf: [piece_data_len]u8 = undefined;
    var span_scratch: [8]Layout.Span = undefined;
    const plan = try verify_mod.planPieceVerificationWithScratch(allocator, &session, 0, &span_scratch);
    defer plan.deinit(allocator);
    try store.readPiece(plan.spans, &read_buf);

    var actual_hash: [20]u8 = undefined;
    Sha1.hash(&read_buf, &actual_hash, .{});
    try std.testing.expectEqualSlices(u8, &piece_hash, &actual_hash);
    try std.testing.expectEqualSlices(u8, &piece_data, &read_buf);
}

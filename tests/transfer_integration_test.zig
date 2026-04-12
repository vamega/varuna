const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;
const TorrentContext = varuna.io.types.TorrentContext;
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const verify_mod = varuna.storage.verify;
const Sha1 = varuna.crypto.Sha1;
const Layout = varuna.torrent.layout.Layout;

// ── Single-process piece transfer integration test ──────────────
//
// One EventLoop, one TorrentContext, self-connected via TCP loopback.
//
// The torrent context has:
//   - complete_pieces with piece 0 set (seeder role for inbound peers)
//   - piece_tracker with 0 complete (downloader role for outbound peers)
//   - shared_fds pointing to files with the actual piece data
//
// The test connects an outbound peer to the same daemon's listen socket.
// The inbound peer serves the piece; the outbound peer downloads it.
// After the transfer, the piece_tracker records the piece as complete.

/// Size of test piece data: small enough for a single block (< 16 KB).
const piece_data_len = 1024;

/// Maximum event loop ticks before declaring failure.
const max_ticks = 2000;

/// Build a minimal single-file v1 torrent (bencoded).
fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hash: [20]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name13:test_xfer.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces20:");
    try buf.appendSlice(allocator, &piece_hash);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Create a non-blocking TCP listen socket on 127.0.0.1 with ephemeral port.
fn createListenSocket() !struct { fd: posix.fd_t, port: u16 } {
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(fd);

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 1);

    // Read back the kernel-assigned port
    var bound: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(fd, @ptrCast(&bound), &len);
    const bound_addr = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(&bound)).* };
    return .{ .fd = fd, .port = bound_addr.getPort() };
}

test "single-piece transfer between seeder and downloader on shared event loop" {
    const allocator = std.testing.allocator;

    // ── 1. Prepare piece data and compute SHA-1 hash ─────────
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| {
        b.* = @truncate(i ^ 0xA5);
    }
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    // ── 2. Build torrent file ────────────────────────────────
    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash);
    defer allocator.free(torrent_bytes);

    // ── 3. Temp directory for data files ─────────────────────
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "data",
    });
    defer allocator.free(data_root);

    // ── 4. Load session and create PieceStore ────────────────
    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    var store = try PieceStore.init(allocator, &session);
    defer store.deinit();

    // Write the seeder's piece data to disk
    var span_scratch: [8]Layout.Span = undefined;
    const plan = try verify_mod.planPieceVerificationWithScratch(
        allocator,
        &session,
        0,
        &span_scratch,
    );
    defer plan.deinit(allocator);
    try store.writePiece(plan.spans, &piece_data);
    try store.sync();

    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    // ── 5. Bitfield (seeder role) and PieceTracker (downloader role) ─
    var complete_pieces = try Bitfield.init(allocator, 1);
    defer complete_pieces.deinit(allocator);
    try complete_pieces.set(0); // we "have" piece 0 for seeding

    // PieceTracker starts empty -- the downloader wants piece 0
    var empty_bf = try Bitfield.init(allocator, 1);
    defer empty_bf.deinit(allocator);

    var tracker = try PieceTracker.init(
        allocator,
        1,
        piece_data_len,
        piece_data_len,
        &empty_bf,
        0,
    );
    defer tracker.deinit(allocator);

    // Sanity check: downloader starts with 0 complete pieces
    try std.testing.expectEqual(@as(u32, 0), tracker.completedCount());

    // ── 6. Create EventLoop ──────────────────────────────────
    var el = EventLoop.initBare(allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.encryption_mode = .disabled;

    // ── 7. Register the torrent context ──────────────────────
    const peer_id = "-VR0001-test00000001".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, peer_id);
    el.setTorrentCompletePieces(tid, &complete_pieces);

    // ── 8. Create listen socket and start accepting ──────────
    const listen = try createListenSocket();
    defer posix.close(listen.fd);

    try el.ensureAccepting(listen.fd);

    // ── 9. Submit a timeout so tick() doesn't block forever ──
    try el.submitTimeout(10_000_000); // 10ms

    // ── 10. Connect outbound peer to ourselves ───────────────
    const peer_addr = try std.net.Address.parseIp4("127.0.0.1", listen.port);
    _ = try el.addPeerForTorrent(peer_addr, tid);

    // ── 11. Tick until the piece is downloaded or timeout ────
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        el.tick() catch |err| {
            // CQE processing error -- log and continue
            std.debug.print("tick {d} error: {s}\n", .{ ticks, @errorName(err) });
            break;
        };

        // Check if the piece was downloaded
        if (tracker.completedCount() >= 1) break;

        // Re-submit timeout so the next tick doesn't block indefinitely
        el.submitTimeout(10_000_000) catch {};
    }

    // ── 12. Verify the piece was transferred ─────────────────
    const completed = tracker.completedCount();
    if (completed < 1) {
        std.debug.print("FAIL: piece not transferred after {d} ticks (completed={d})\n", .{ ticks, completed });
        return error.TestUnexpectedResult;
    }

    // ── 13. Verify data integrity: re-read from disk and hash ─
    var read_buf: [piece_data_len]u8 = undefined;
    const read_plan = try verify_mod.planPieceVerificationWithScratch(
        allocator,
        &session,
        0,
        &span_scratch,
    );
    defer read_plan.deinit(allocator);
    try store.readPiece(read_plan.spans, &read_buf);

    var actual_hash: [20]u8 = undefined;
    Sha1.hash(&read_buf, &actual_hash, .{});
    try std.testing.expectEqual(piece_hash, actual_hash);
    try std.testing.expectEqualSlices(u8, &piece_data, &read_buf);
}

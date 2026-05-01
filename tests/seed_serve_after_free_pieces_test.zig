const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const verify_mod = varuna.storage.verify;
const Sha1 = varuna.crypto.Sha1;
const Layout = varuna.torrent.layout.Layout;

// ── Regression test: seeder serves REQUEST after Session.freePieces() ──
//
// The freePieces() bug (commit a4579e9, "torrent: piece hash lifecycle —
// three-phase memory management"): when TorrentSession transitions to
// seed mode it calls session.freePieces(), which sets
// layout.piece_hashes = null. servePieceRequest in seed_handler.zig was
// then calling planPieceVerificationWithScratch, which unconditionally
// reads session.layout.pieceHash() and returned error.PiecesNotLoaded.
// The error was swallowed by `catch return;` so every BT REQUEST was
// silently dropped → leecher waited forever → 60s timeout.
//
// Test shape: ONE EventLoop, ONE Session in seed-mode (post-freePieces).
// The local EL plays the seeder role only — we don't engage its
// downloader-side completion path (which separately reads pieceHash and
// would also fail post-freePieces, but that's not what this test is for).
// The downloader is a manual TCP client thread that:
//   1. Connects to the EL's listen port,
//   2. Sends a plaintext BT handshake,
//   3. Reads back the peer's handshake + bitfield,
//   4. Sends INTERESTED, waits for UNCHOKE,
//   5. Sends REQUEST for one block of piece 0,
//   6. Reads back PIECE.
// Pre-Defense-1 step 6 hangs (REQUEST is silently dropped). Post-fix the
// PIECE message arrives and the test asserts the piece bytes match.
//
// Methodology note (from the freepieces-fix prompt): write the test
// FIRST against parent commit (with the bug) and confirm it FAILS;
// then ship Defenses 1+2 and confirm it PASSES.

const piece_data_len = 1024;
const max_ticks = 4000;

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

    var bound: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    try posix.getsockname(fd, @ptrCast(&bound), &len);
    const bound_addr = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(&bound)).* };
    return .{ .fd = fd, .port = bound_addr.getPort() };
}

// ── Manual BT peer (downloader role) ─────────────────────────
//
// Runs on a worker thread. Performs a synchronous BT exchange against
// the local EventLoop's listening seeder. Records whether a PIECE
// response with matching bytes arrives within the timeout.

const PeerResult = struct {
    /// Set true once a PIECE message for piece 0 with matching bytes arrives.
    piece_received: bool = false,
    /// Set true on any I/O or protocol error before piece_received fires.
    /// The seeder dropping our REQUEST silently looks identical to a hang —
    /// in that case piece_received stays false and the test times out.
    error_before_piece: bool = false,
};

const PeerCtx = struct {
    port: u16,
    info_hash: [20]u8,
    expected_piece: *const [piece_data_len]u8,
    result: PeerResult = .{},
};

fn runDownloaderPeer(ctx: *PeerCtx) void {
    runDownloaderPeerInner(ctx) catch {
        ctx.result.error_before_piece = true;
    };
}

fn runDownloaderPeerInner(ctx: *PeerCtx) !void {
    // Blocking TCP socket — simpler to code synchronously here.
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    );
    defer posix.close(fd);

    // Set a generous receive timeout: the test's tick-loop on the main
    // thread caps the EL run length, so this peer must not block longer
    // than the EL is going to live. 5 seconds is well above the 2000-tick
    // EL window with 10ms timeouts.
    const tv = posix.timeval{ .sec = 5, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    const addr = try std.net.Address.parseIp4("127.0.0.1", ctx.port);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    // ── Send BT handshake ────────────────────────────────────
    var hs: [68]u8 = undefined;
    hs[0] = 19;
    @memcpy(hs[1..20], "BitTorrent protocol");
    @memset(hs[20..28], 0);
    @memcpy(hs[28..48], &ctx.info_hash);
    @memcpy(hs[48..68], "-VR0001-fpfix0000002");
    _ = try posix.send(fd, &hs, 0);

    // ── Read peer handshake (68 bytes) ───────────────────────
    var peer_hs: [68]u8 = undefined;
    try recvExact(fd, &peer_hs);
    if (peer_hs[0] != 19) return error.BadHandshake;
    if (!std.mem.eql(u8, peer_hs[1..20], "BitTorrent protocol")) return error.BadHandshake;
    if (!std.mem.eql(u8, peer_hs[28..48], &ctx.info_hash)) return error.InfoHashMismatch;

    // ── Send BITFIELD: empty (we don't have piece 0) ─────────
    // Bitfield message: 4-byte length + 1-byte msg_id (5) + 1-byte bitfield (0).
    // 1 piece → 1 byte of bitfield, all zeros.
    const bitfield_msg = [_]u8{ 0, 0, 0, 2, 5, 0 };
    _ = try posix.send(fd, &bitfield_msg, 0);

    // ── Send INTERESTED (msg_id 2) ───────────────────────────
    const interested_msg = [_]u8{ 0, 0, 0, 1, 2 };
    _ = try posix.send(fd, &interested_msg, 0);

    // ── Read messages until we get UNCHOKE or PIECE ──────────
    // The seeder may send extension handshake (LTEP) before UNCHOKE; we
    // skip everything until we either see UNCHOKE (id 1) and then send
    // REQUEST, or directly see a PIECE message (id 7) for piece 0.
    var requested = false;
    const piece_data_offset: u32 = 0;
    const block_len: u32 = piece_data_len; // request full piece (small piece)

    var deadline_iters: u32 = 200; // 200 messages max — more than enough
    while (deadline_iters > 0) : (deadline_iters -= 1) {
        var len_buf: [4]u8 = undefined;
        try recvExact(fd, &len_buf);
        const msg_len = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len == 0) {
            // keep-alive; ignore
            continue;
        }
        if (msg_len > 1 + 8 + piece_data_len + 1024) return error.OversizeMessage;

        // Read the rest in chunks to avoid huge stack buffers.
        var msg_id: u8 = 0;
        try recvExact(fd, std.mem.asBytes(&msg_id));
        const payload_len = msg_len - 1;

        var payload: [piece_data_len + 16]u8 = undefined;
        if (payload_len > payload.len) return error.OversizePayload;
        if (payload_len > 0) {
            try recvExact(fd, payload[0..payload_len]);
        }

        switch (msg_id) {
            0 => {
                // CHOKE — peers shouldn't choke us in a healthy seeder
                // path, but tolerate it during early connection.
            },
            1 => {
                // UNCHOKE → send REQUEST(piece=0, offset=0, length=full)
                if (!requested) {
                    var req: [17]u8 = undefined;
                    std.mem.writeInt(u32, req[0..4], 13, .big); // length
                    req[4] = 6; // request id
                    std.mem.writeInt(u32, req[5..9], 0, .big); // piece_index
                    std.mem.writeInt(u32, req[9..13], piece_data_offset, .big);
                    std.mem.writeInt(u32, req[13..17], block_len, .big);
                    _ = try posix.send(fd, &req, 0);
                    requested = true;
                }
            },
            5 => {
                // BITFIELD — ignore
            },
            7 => {
                // PIECE — piece_index(4) + begin(4) + block(...)
                if (payload_len < 8) return error.ShortPieceMsg;
                const piece_idx = std.mem.readInt(u32, payload[0..4], .big);
                const begin = std.mem.readInt(u32, payload[4..8], .big);
                if (piece_idx != 0 or begin != piece_data_offset) {
                    return error.UnexpectedPieceMsg;
                }
                const block_data = payload[8..payload_len];
                if (block_data.len != block_len) return error.ShortBlock;
                if (std.mem.eql(u8, block_data, ctx.expected_piece)) {
                    ctx.result.piece_received = true;
                    return;
                } else {
                    return error.BlockBytesMismatch;
                }
            },
            20 => {
                // LTEP extension handshake — ignore
            },
            else => {
                // unknown message id; ignore
            },
        }
    }
}

fn recvExact(fd: posix.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try posix.recv(fd, buf[got..], 0);
        if (n == 0) return error.PeerClosed;
        got += n;
    }
}

test "seeder serves REQUEST after Session.freePieces() (regression: a4579e9)" {
    const allocator = std.testing.allocator;

    // ── 1. Prepare piece data + hash ─────────────────────────
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| {
        b.* = @truncate(i ^ 0x5A);
    }
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash);
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "data",
    });
    defer allocator.free(data_root);

    // ── 2. Load session FOR DOWNLOAD (so pieces is materialised) ─
    var session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    var store_init_io = varuna.io.real_io.RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
    defer store_init_io.deinit();
    var store = try PieceStore.init(allocator, &session, &store_init_io);
    defer store.deinit();

    // Write piece data to disk while pieceHash is still loaded.
    var span_scratch: [8]Layout.Span = undefined;
    const init_plan = try verify_mod.planPieceVerificationWithScratch(
        allocator,
        &session,
        0,
        &span_scratch,
    );
    defer init_plan.deinit(allocator);
    try store.writePiece(&store_init_io, init_plan.spans, &piece_data);
    try store.sync(&store_init_io);

    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    // ── 3. Seeder bitfield (piece 0 complete) + dummy tracker ─
    var complete_pieces = try Bitfield.init(allocator, 1);
    defer complete_pieces.deinit(allocator);
    try complete_pieces.set(0);

    // The PieceTracker is required by addTorrent's signature, but the
    // seeder side never consults it for serving REQUEST — only the
    // downloader-side completion path (which we don't exercise here)
    // would touch it. Use a fully-complete bitfield here too so the EL
    // doesn't try to download.
    var full_bf = try Bitfield.init(allocator, 1);
    defer full_bf.deinit(allocator);
    try full_bf.set(0);
    var tracker = try PieceTracker.init(
        allocator,
        1,
        piece_data_len,
        piece_data_len,
        &full_bf,
        piece_data_len,
    );
    defer tracker.deinit(allocator);

    // ── 4. ★ THE BUG TRIGGER: freePieces() before serving ★ ──
    //
    // Mirrors what TorrentSession does at:
    //   - src/daemon/torrent_session.zig:599 (skip-recheck, full bitfield)
    //   - src/daemon/torrent_session.zig:782 (post-recheck completion)
    //   - src/daemon/torrent_session.zig:907 (live-recheck completion)
    session.freePieces();
    try std.testing.expect(!session.hasPieceHashes());
    try std.testing.expect(session.layout.piece_hashes == null);
    try std.testing.expectError(
        error.PiecesNotLoaded,
        session.layout.pieceHash(0),
    );

    // ── 5. Wire up EventLoop ─────────────────────────────────
    var el = EventLoop.initBare(allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.encryption_mode = .disabled;

    const peer_id = "-VR0001-fpfix0000001".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, peer_id);
    el.setTorrentCompletePieces(tid, &complete_pieces);

    // ── 6. Listen socket ─────────────────────────────────────
    const listen = try createListenSocket();
    defer posix.close(listen.fd);

    try el.ensureAccepting(listen.fd);

    // ── 7. Spawn the manual downloader peer ──────────────────
    var ctx = PeerCtx{
        .port = listen.port,
        .info_hash = session.metainfo.info_hash,
        .expected_piece = &piece_data,
    };
    const peer_thread = try std.Thread.spawn(.{}, runDownloaderPeer, .{&ctx});

    // ── 8. Tick the EL until peer signals completion or timeout ─
    try el.submitTimeout(10_000_000);

    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        el.tick() catch |err| {
            std.debug.print("tick {d} error: {s}\n", .{ ticks, @errorName(err) });
            break;
        };
        if (ctx.result.piece_received or ctx.result.error_before_piece) break;
        el.submitTimeout(10_000_000) catch {};
    }

    // Give the peer thread a brief grace window to clean up.
    peer_thread.join();

    // ── 9. Assertion: piece transferred despite freePieces() ─
    if (!ctx.result.piece_received) {
        std.debug.print(
            "FAIL: PIECE not received after {d} ticks (error_before_piece={}). " ++
                "This is the freePieces() bug — Session.freePieces() left " ++
                "layout.piece_hashes == null, and pre-Defense-1 the seeder's " ++
                "planPieceVerificationWithScratch returned PiecesNotLoaded, " ++
                "silently dropping every REQUEST.\n",
            .{ ticks, ctx.result.error_before_piece },
        );
        return error.TestUnexpectedResult;
    }
}

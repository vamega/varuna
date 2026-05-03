const varuna = @import("varuna");
const std = @import("std");
const posix = std.posix;

const Bitfield = varuna.bitfield.Bitfield;
const EventLoop = varuna.io.event_loop.EventLoop;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;
const TorrentState = varuna.daemon.torrent_session.State;
const Transport = varuna.io.event_loop.Transport;

test {
    _ = varuna.daemon.torrent_session;
}

test "addPeersToEventLoop honors uTP-only transport for tracker peers" {
    const allocator = std.testing.allocator;
    const torrent_bytes =
        "d8:announce14:http://tracker4:infod6:lengthi4e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee";

    var loaded = try Session.load(allocator, torrent_bytes, "/tmp");
    defer loaded.deinit(allocator);

    var empty_bf = try Bitfield.init(allocator, loaded.pieceCount());
    defer empty_bf.deinit(allocator);

    var piece_tracker = try PieceTracker.init(
        allocator,
        loaded.pieceCount(),
        loaded.layout.piece_length,
        loaded.totalSize(),
        &empty_bf,
        0,
    );
    defer piece_tracker.deinit(allocator);

    var el = EventLoop.initBare(allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();
    el.transport_disposition = .utp_only;

    const pending = try allocator.alloc(std.net.Address, 1);
    pending[0] = try std.net.Address.parseIp4("127.0.0.1", 6881);
    const empty_fds = [_]posix.fd_t{};

    var session = TorrentSession{
        .allocator = allocator,
        .state = TorrentState.downloading,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = loaded.metainfo.info_hash,
        .info_hash_hex = std.fmt.bytesToHex(loaded.metainfo.info_hash, .lower),
        .name = "",
        .total_size = loaded.totalSize(),
        .piece_count = loaded.pieceCount(),
        .added_on = 0,
        .peer_id = "-VR0001-test00000001".*,
        .tracker_key = [_]u8{0} ** 8,
        .session = loaded,
        .piece_tracker = piece_tracker,
        .shared_fds = empty_fds[0..],
        .shared_event_loop = &el,
        .pending_peers = pending,
    };

    try std.testing.expect(session.addPeersToEventLoop());
    try std.testing.expectEqual(@as(u64, 1), session.conn_attempts);
    try std.testing.expectEqual(@as(u64, 0), session.conn_failures);
    try std.testing.expect(session.pending_peers == null);
    try std.testing.expectEqual(@as(u32, 1), el.peer_count);

    var found_utp_peer = false;
    for (el.peers) |*peer| {
        if (peer.state == .free) continue;
        found_utp_peer = true;
        try std.testing.expectEqual(Transport.utp, peer.transport);
        try std.testing.expect(peer.utp_slot != null);
    }
    try std.testing.expect(found_utp_peer);
}

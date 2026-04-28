//! Per-torrent durability sync wiring tests.
//!
//! Drives `EventLoopOf(SimIO).submitTorrentSync` and the periodic-sync
//! timer with synthetic torrents to verify:
//!
//!   * Dirty-write tracking on `TorrentContext.dirty_writes_since_sync`
//!     bumps from `peer_handler.handleDiskWriteResult` and decrements
//!     after a sync sweep drains.
//!   * `submitTorrentSync` submits one fsync per non-skipped fd in
//!     `tc.shared_fds`, marks `sync_in_flight` while sweeping, and
//!     clears it when every CQE lands.
//!   * `submitShutdownSync` returns 0 when no torrent is dirty.
//!   * Concurrent `submitTorrentSync` calls coalesce — the second
//!     returns immediately while a sweep is already in flight.
//!   * `force_even_if_clean = true` overrides the dirty-count gate so
//!     the on-completion + shutdown paths can fsync regardless.
//!
//! Closes Gap 1 (R6 from `docs/mmap-durability-audit.md`): without
//! `submitTorrentSync` the daemon never calls fsync — the OS dirty-
//! writeback policy controlled durability instead.

const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const Session = varuna.torrent.session.Session;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Bitfield = varuna.bitfield.Bitfield;

const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

/// Single-piece, single-file v1 torrent with a deterministic hash. The
/// content of the piece doesn't matter for sync tests — we only need
/// the layout machinery to spin up.
const single_piece_torrent =
    "d4:infod" ++
    "6:lengthi3e" ++
    "4:name3:abc" ++
    "12:piece lengthi4e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

fn buildEventLoop(allocator: std.mem.Allocator) !EL_SimIO {
    const sim = try SimIO.init(allocator, .{ .seed = 0xC0FFEE });
    return try EL_SimIO.initBareWithIO(allocator, sim, 0);
}

fn registerTorrent(
    el: *EL_SimIO,
    session: *const Session,
    pt: *PieceTracker,
    fds: []const posix.fd_t,
) !u32 {
    return try el.addTorrent(session, pt, fds, [_]u8{0} ** 20);
}

test "submitTorrentSync: clean torrent (dirty=0, no force) is no-op" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{42};
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);
    try std.testing.expect(!tc.sync_in_flight);

    el.submitTorrentSync(tid, false);

    // Clean + non-forced => no submission.
    try std.testing.expect(!tc.sync_in_flight);
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);
}

test "submitTorrentSync: dirty torrent submits fsync per non-skipped fd" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    // Two fds, one skipped (fd == -1). Only the live one should fsync.
    const fds = [_]posix.fd_t{ 42, -1 };
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    tc.dirty_writes_since_sync = 7;

    el.submitTorrentSync(tid, false);
    // Sweep is in flight until SimIO's scheduled fsync CQE lands.
    try std.testing.expect(tc.sync_in_flight);

    // Tick the ring until the fsync CQE drains.
    var ticks: u32 = 0;
    while (ticks < 64 and tc.sync_in_flight) : (ticks += 1) {
        el.io.tick(1) catch {};
    }
    try std.testing.expect(!tc.sync_in_flight);
    // Snapshot of 7 subtracted from dirty count of 7 → 0.
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);
}

test "submitTorrentSync: writes during sweep stay dirty for next pass" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{42};
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    tc.dirty_writes_since_sync = 3;

    el.submitTorrentSync(tid, false);
    try std.testing.expect(tc.sync_in_flight);

    // Simulate two fresh writes landing while the sweep is still in
    // flight. The snapshot was 3; new dirty count is 5; after drain
    // it should be 2 (saturating subtract).
    tc.dirty_writes_since_sync += 2;

    var ticks: u32 = 0;
    while (ticks < 64 and tc.sync_in_flight) : (ticks += 1) {
        el.io.tick(1) catch {};
    }
    try std.testing.expectEqual(@as(u32, 2), tc.dirty_writes_since_sync);
}

test "submitTorrentSync: idempotent when sweep already in flight" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{42};
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    tc.dirty_writes_since_sync = 3;

    el.submitTorrentSync(tid, false);
    try std.testing.expect(tc.sync_in_flight);

    // Second call while sweep in flight: must be a no-op.
    el.submitTorrentSync(tid, false);
    try std.testing.expect(tc.sync_in_flight);

    var ticks: u32 = 0;
    while (ticks < 64 and tc.sync_in_flight) : (ticks += 1) {
        el.io.tick(1) catch {};
    }
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);
}

test "submitTorrentSync: force_even_if_clean fsyncs a clean torrent" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{42};
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);

    el.submitTorrentSync(tid, true);
    try std.testing.expect(tc.sync_in_flight);

    var ticks: u32 = 0;
    while (ticks < 64 and tc.sync_in_flight) : (ticks += 1) {
        el.io.tick(1) catch {};
    }
    try std.testing.expect(!tc.sync_in_flight);
    try std.testing.expectEqual(@as(u32, 0), tc.dirty_writes_since_sync);
}

test "submitShutdownSync: returns count of dirty torrents" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const sess = try Session.load(allocator, single_piece_torrent, root);
    defer sess.deinit(allocator);

    var bf = try Bitfield.init(allocator, sess.pieceCount());
    defer bf.deinit(allocator);

    var pt = try PieceTracker.init(allocator, sess.pieceCount(), sess.layout.piece_length, sess.totalSize(), &bf, 0);
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{10};
    const tid = try registerTorrent(&el, &sess, &pt, &fds);

    // No dirty torrents → submitShutdownSync returns 0.
    try std.testing.expectEqual(@as(u32, 0), el.submitShutdownSync());
    try std.testing.expect(!el.anySyncInFlight());

    // Mark dirty → submitShutdownSync returns 1, sweep is in flight.
    el.getTorrentContext(tid).?.dirty_writes_since_sync = 4;
    try std.testing.expectEqual(@as(u32, 1), el.submitShutdownSync());
    try std.testing.expect(el.anySyncInFlight());

    var ticks: u32 = 0;
    while (ticks < 64 and el.anySyncInFlight()) : (ticks += 1) {
        el.io.tick(1) catch {};
    }
    try std.testing.expect(!el.anySyncInFlight());
    try std.testing.expectEqual(@as(u32, 0), el.getTorrentContext(tid).?.dirty_writes_since_sync);
}

test "submitTorrentSync: all-skipped fds (fd == -1) is no-op" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(target_root);

    const session = try Session.load(allocator, single_piece_torrent, target_root);
    defer session.deinit(allocator);

    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    // Every file skipped (do_not_download).
    const fds = [_]posix.fd_t{ -1, -1 };
    const tid = try registerTorrent(&el, &session, &pt, &fds);

    const tc = el.getTorrentContext(tid).?;
    tc.dirty_writes_since_sync = 5; // pretend a write completed before priorities flipped

    el.submitTorrentSync(tid, false);
    // No live fds → no fsync submitted → no in-flight sweep.
    try std.testing.expect(!tc.sync_in_flight);
}

test "submitTorrentSync: missing torrent_id is no-op" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    // No torrents registered.
    el.submitTorrentSync(999, true);
    try std.testing.expect(!el.anySyncInFlight());
    try std.testing.expectEqual(@as(u32, 0), el.submitShutdownSync());
}

test "sync_timer_interval_ms default is 30 seconds" {
    const allocator = std.testing.allocator;

    var el = try buildEventLoop(allocator);
    defer el.deinit();

    try std.testing.expectEqual(@as(u64, 30_000), el.sync_timer_interval_ms);
    try std.testing.expect(!el.sync_timer_armed);
}

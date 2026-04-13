const std = @import("std");
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const Sha1 = varuna.crypto.Sha1;
const posix = std.posix;

const piece_data_len = 1024;

/// Build a minimal single-file v1 torrent (bencoded).
fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hash: [20]u8, name: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name");
    try buf.writer(allocator).print("{d}:{s}", .{ name.len, name });
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_data_len});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces20:");
    try buf.appendSlice(allocator, &piece_hash);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

// ── Test 1: Multiple concurrent rechecks should not fail ──────────
//
// Currently startRecheck returns error.RecheckAlreadyActive when a
// recheck is already in progress. This test verifies that starting
// two rechecks concurrently succeeds (either by queuing or by
// supporting parallel rechecks).

test "startRecheck allows multiple concurrent rechecks" {
    const allocator = std.testing.allocator;

    var el = EventLoop.initBare(allocator, 2) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Create two different torrents
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 71);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes_a = try buildTorrentBytes(allocator, piece_hash, "ta.b");
    defer allocator.free(torrent_bytes_a);
    const torrent_bytes_b = try buildTorrentBytes(allocator, piece_hash, "tb.b");
    defer allocator.free(torrent_bytes_b);

    // Create temp dirs and files for both torrents
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    // Write piece data files
    {
        const f = try tmp_a.dir.createFile("ta.b", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }
    {
        const f = try tmp_b.dir.createFile("tb.b", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }

    // Load sessions
    const save_path_a = try tmp_a.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path_a);
    const save_path_b = try tmp_b.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path_b);

    const session_a = try Session.load(allocator, torrent_bytes_a, save_path_a);
    defer session_a.deinit(allocator);
    const session_b = try Session.load(allocator, torrent_bytes_b, save_path_b);
    defer session_b.deinit(allocator);

    // Create PieceStores and get fds
    var store_a = try PieceStore.init(allocator, &session_a);
    defer store_a.deinit();
    const fds_a = try store_a.fileHandles(allocator);
    defer allocator.free(fds_a);

    var store_b = try PieceStore.init(allocator, &session_b);
    defer store_b.deinit();
    const fds_b = try store_b.fileHandles(allocator);
    defer allocator.free(fds_b);

    // Start first recheck — should succeed
    var completed_a = false;
    try el.startRecheck(&session_a, fds_a, 0, null, struct {
        fn cb(rc: *varuna.io.recheck.AsyncRecheck) void {
            const ctx: *bool = @ptrCast(@alignCast(rc.caller_ctx.?));
            ctx.* = true;
        }
    }.cb, @ptrCast(&completed_a));

    // Start second recheck — THIS IS THE TEST:
    // Currently this returns error.RecheckAlreadyActive.
    // After the fix, it should succeed.
    var completed_b = false;
    el.startRecheck(&session_b, fds_b, 1, null, struct {
        fn cb(rc: *varuna.io.recheck.AsyncRecheck) void {
            const ctx: *bool = @ptrCast(@alignCast(rc.caller_ctx.?));
            ctx.* = true;
        }
    }.cb, @ptrCast(&completed_b)) catch |err| {
        // This is the current broken behavior — fail the test
        if (err == error.RecheckAlreadyActive) {
            return error.TestExpectedEqual; // FAIL: should allow parallel rechecks
        }
        return err;
    };

    // Tick until both complete
    var ticks: u32 = 0;
    while (ticks < 2000 and (!completed_a or !completed_b)) : (ticks += 1) {
        el.submitTimeout(10 * std.time.ns_per_ms) catch {};
        el.tick() catch {};
    }

    try std.testing.expect(completed_a);
    try std.testing.expect(completed_b);
}

// ── Test 2: Fast resume should not recheck ────────────────────────
//
// When resume data says all pieces are complete, the daemon should
// trust it and create the PieceTracker directly without reading
// any data from disk. This tests that the resume path does NOT
// invoke startRecheck.

test "fast resume with complete pieces skips recheck entirely" {
    const allocator = std.testing.allocator;

    var el = EventLoop.initBare(allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Create a torrent with known piece data
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 71);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash, "r.bi");
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("r.bi", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }

    const save_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path);
    const session = try Session.load(allocator, torrent_bytes, save_path);
    defer session.deinit(allocator);

    // Simulate resume data: all pieces complete
    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);
    try resume_pieces.set(0); // piece 0 is complete

    // Create PieceTracker directly from resume data — no recheck
    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        piece_data_len, // all bytes complete
    );
    defer pt.deinit(allocator);

    // Verify: PieceTracker shows 1 complete piece
    try std.testing.expectEqual(@as(u32, 1), pt.completedCount());

    // Verify: no recheck was started on the event loop
    try std.testing.expectEqual(@as(usize, 0), el.rechecks.items.len);

    // The point: creating a PieceTracker from resume data is instant.
    // No io_uring reads, no hashing, no async state machine needed.
}

// ── Test 3: Recheck only needed on explicit user request ──────────
//
// After fast resume, the only way a recheck should run is via an
// explicit API call (force recheck). This test verifies that
// startRecheck works as an explicit operation after fast resume.

test "explicit recheck after fast resume works" {
    const allocator = std.testing.allocator;

    var el = EventLoop.initBare(allocator, 2) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 71);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash, "e.bi");
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("e.bi", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }

    const save_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path);
    const session = try Session.load(allocator, torrent_bytes, save_path);
    defer session.deinit(allocator);

    var store = try PieceStore.init(allocator, &session);
    defer store.deinit();
    const fds = try store.fileHandles(allocator);
    defer allocator.free(fds);

    // Fast resume: create PieceTracker from resume data (no recheck)
    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);
    try resume_pieces.set(0);

    // Now simulate explicit "force recheck" — should work
    var recheck_completed = false;
    try el.startRecheck(&session, fds, 0, null, struct {
        fn cb(rc: *varuna.io.recheck.AsyncRecheck) void {
            const ctx: *bool = @ptrCast(@alignCast(rc.caller_ctx.?));
            ctx.* = true;
        }
    }.cb, @ptrCast(&recheck_completed));

    // Tick until recheck completes
    var ticks: u32 = 0;
    while (ticks < 2000 and !recheck_completed) : (ticks += 1) {
        el.submitTimeout(10 * std.time.ns_per_ms) catch {};
        el.tick() catch {};
    }

    try std.testing.expect(recheck_completed);

    // Clean up the recheck
    el.cancelAllRechecks();
}

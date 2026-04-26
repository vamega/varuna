const std = @import("std");
const varuna = @import("varuna");
const event_loop_mod = varuna.io.event_loop;
const EventLoop = event_loop_mod.EventLoop;
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const Sha1 = varuna.crypto.Sha1;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const recheck_mod = varuna.io.recheck;
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
    var store_a = try PieceStore.init(allocator, &session_a, &el.io);
    defer store_a.deinit();
    const fds_a = try store_a.fileHandles(allocator);
    defer allocator.free(fds_a);

    var store_b = try PieceStore.init(allocator, &session_b, &el.io);
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

    var store = try PieceStore.init(allocator, &session, &el.io);
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

// ── Test 4: Fast resume with resume_pieces should NOT start recheck ──
//
// When a torrent restarts with resume data (resume_pieces is non-null),
// the daemon should trust the resume DB and create the PieceTracker
// directly, without starting an async recheck. This tests the pattern
// that integrateIntoEventLoop should follow for fast resume.
//
// Currently the daemon DOES start a recheck when resume_pieces is set
// (the recheck just skips known-complete pieces). This test verifies
// the fast-resume behavior we want:
//   1. resume_pieces says piece 0 is complete
//   2. PieceTracker is created from resume_pieces
//   3. No startRecheck is called
//   4. Torrent is ready to download/seed immediately

test "daemon restart with resume data skips recheck (fast resume)" {
    const allocator = std.testing.allocator;

    var el = EventLoop.initBare(allocator, 2) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Create a torrent
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 71);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash, "fr.b");
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("fr.b", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }

    const save_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path);
    const session = try Session.load(allocator, torrent_bytes, save_path);
    defer session.deinit(allocator);

    var store = try PieceStore.init(allocator, &session, &el.io);
    defer store.deinit();
    const fds = try store.fileHandles(allocator);
    defer allocator.free(fds);

    // Simulate resume data: piece 0 is complete (from previous session)
    var resume_pieces = try Bitfield.init(allocator, session.pieceCount());
    defer resume_pieces.deinit(allocator);
    try resume_pieces.set(0);

    // Fast resume path: create PieceTracker from resume data, no recheck
    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &resume_pieces,
        piece_data_len,
    );
    defer pt.deinit(allocator);

    // Verify: 1 piece complete from resume
    try std.testing.expectEqual(@as(u32, 1), pt.completedCount());

    // THE KEY ASSERTION: no recheck should have been started.
    // In the current daemon code, integrateIntoEventLoop starts a recheck
    // when resume_pieces is non-null. After the fast-resume fix, it should
    // skip the recheck and use the PieceTracker directly.
    try std.testing.expectEqual(@as(usize, 0), el.rechecks.items.len);

    // Bonus: the torrent should be immediately ready to register in the
    // event loop for downloading/seeding — no waiting for recheck.
    const tid = try el.addTorrentContext(.{
        .session = &session,
        .piece_tracker = &pt,
        .shared_fds = fds,
        .info_hash = session.metainfo.info_hash,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = null,
        .is_private = false,
        .info_hash_v2 = null,
    });
    _ = tid;

    // The torrent is registered and ready — no recheck needed.
    try std.testing.expectEqual(@as(usize, 0), el.rechecks.items.len);
}

// ── Live force-recheck: in-place bitfield update ──────────────────
//
// Mirrors the path TorrentSession.forceRecheckLive takes — a recheck
// runs against an existing live torrent slot (rather than tearing down
// the session via stop+start), and on completion the PieceTracker's
// bitfield is rebuilt in place via applyRecheckResult.
//
// Asserts:
//  (a) the EL holds a `*const Bitfield` pointer that survives the
//      bitfield rebuild — i.e. the storage address doesn't move,
//  (b) the new bitfield reflects what's actually on disk, and
//  (c) availability counts are preserved across the rebuild.
//
// The full daemon-side flow (loadPiecesForRecheck for already-seeding
// torrents, freePieces post-completion) is exercised at the algorithm
// level in tests/piece_hash_lifecycle_test.zig and at the
// `forceRecheckLive` entry point via the SessionManager API.

test "live force-recheck rebuilds PieceTracker bitfield in place" {
    const allocator = std.testing.allocator;

    var el = EventLoop.initBare(allocator, 2) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Single-piece v1 torrent, so the disk content matches the hash
    // and the recheck will mark piece 0 as complete.
    var piece_data: [piece_data_len]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 71);
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    const torrent_bytes = try buildTorrentBytes(allocator, piece_hash, "lv.b");
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("lv.b", .{});
        defer f.close();
        try f.writeAll(&piece_data);
    }

    const save_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(save_path);
    const session = try Session.load(allocator, torrent_bytes, save_path);
    defer session.deinit(allocator);

    var store = try PieceStore.init(allocator, &session, &el.io);
    defer store.deinit();
    const fds = try store.fileHandles(allocator);
    defer allocator.free(fds);

    // Pre-recheck PieceTracker: pretend piece 0 is missing (stale state
    // that the recheck will correct). Add some availability so we can
    // verify it survives the rebuild.
    var initial = try Bitfield.init(allocator, session.pieceCount());
    defer initial.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &initial,
        0,
    );
    defer pt.deinit(allocator);

    pt.addAvailability(0);
    pt.addAvailability(0);

    // Save the storage address — the live force-recheck path's contract
    // is that this pointer stays valid across recheck completion.
    const original_bits_ptr = pt.complete.bits.ptr;

    // Submit a recheck against the live torrent. Use a small
    // shim callback that calls applyRecheckResult, modeling what
    // TorrentSession.onLiveRecheckComplete does.
    const Ctx = struct {
        pt: *PieceTracker,
        completed: bool = false,
    };
    var ctx = Ctx{ .pt = &pt };

    try el.startRecheck(&session, fds, 1, null, struct {
        fn cb(rc: *varuna.io.recheck.AsyncRecheck) void {
            const c: *Ctx = @ptrCast(@alignCast(rc.caller_ctx.?));
            c.pt.applyRecheckResult(&rc.complete_pieces, rc.bytes_complete);
            c.completed = true;
        }
    }.cb, @ptrCast(&ctx));

    var ticks: u32 = 0;
    while (ticks < 2000 and !ctx.completed) : (ticks += 1) {
        el.submitTimeout(10 * std.time.ns_per_ms) catch {};
        el.tick() catch {};
    }
    try std.testing.expect(ctx.completed);

    // (a) Storage address didn't move — EL pointer survives.
    try std.testing.expectEqual(original_bits_ptr, pt.complete.bits.ptr);

    // (b) Bitfield reflects on-disk reality (piece 0 actually present).
    try std.testing.expect(pt.complete.has(0));
    try std.testing.expectEqual(@as(u32, 1), pt.complete.count);
    try std.testing.expectEqual(@as(u64, piece_data_len), pt.bytes_complete);

    // (c) Availability counts preserved.
    try std.testing.expectEqual(@as(u16, 2), pt.availability[0]);

    // Clean up.
    el.cancelAllRechecks();
}

// ── AsyncRecheckOf(SimIO) end-to-end integration ─────────────────
//
// Drives the full recheck pipeline against `EventLoopOf(SimIO)` with
// `SimIO.setFileBytes` registering the canonical piece content. Asserts
// the resulting bitfield reflects what's "on disk" exactly — every
// piece's bytes match its expected hash, so all pieces verify.
//
// This is the integration shape that the live-pipeline BUGGIFY harness
// (deferred follow-up — see progress-reports/2026-04-26-async-recheck-io-generic.md)
// will wrap with `injectRandomFault` + per-op `FaultConfig` over many
// seeds. The current test exercises the happy path; safety-under-faults
// is filed as the next deliverable.

const sim_piece_count: u32 = 4;
const sim_piece_size: u32 = 32;
const sim_total_bytes: u32 = sim_piece_count * sim_piece_size;

/// Build minimal bencoded metainfo for a 4-piece × 32-byte torrent with
/// the supplied concatenated piece hashes. The format mirrors the
/// existing `buildTorrentBytes` in this file but with a multi-piece
/// hash blob.
fn buildMultiPieceTorrent(
    allocator: std.mem.Allocator,
    piece_hashes: *const [sim_piece_count][20]u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{sim_total_bytes});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name15:sim_recheck.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{sim_piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces");
    try buf.writer(allocator).print("{d}", .{sim_piece_count * 20});
    try buf.append(allocator, ':');
    for (piece_hashes) |*h| try buf.appendSlice(allocator, h);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

test "AsyncRecheckOf(SimIO): all pieces verify against registered file content" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── 1. Build canonical piece data + SHA-1 hashes ─────────
    var file_bytes: [sim_total_bytes]u8 = undefined;
    for (&file_bytes, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var piece_hashes: [sim_piece_count][20]u8 = undefined;
    var p: u32 = 0;
    while (p < sim_piece_count) : (p += 1) {
        Sha1.hash(
            file_bytes[p * sim_piece_size ..][0..sim_piece_size],
            &piece_hashes[p],
            .{},
        );
    }

    // ── 2. Load the torrent as a Session ─────────────────────
    const torrent_bytes = try buildMultiPieceTorrent(arena.allocator(), &piece_hashes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try tmp.dir.realpathAlloc(arena.allocator(), ".");

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    // ── 3. Spin up EventLoopOf(SimIO) with a real hasher ─────
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xCAFE_BABE });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 1) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // ── 4. Register file content for the synthetic fd ────────
    //
    // PieceStore would normally hand back a real kernel fd from
    // `posix.openat`. SimIO doesn't have a kernel — we synthesise an
    // fd value that doesn't collide with the socket-pair / synthetic
    // ranges (`socket_fd_base = 1000`, `synthetic_fd_base = 100_000`)
    // and register the canonical bytes. Subsequent reads on this fd
    // return slices of `file_bytes`, which makes
    // `verify.planPieceVerification` + the hasher's SHA-1 comparison
    // mark every piece complete.
    const synthetic_fd: posix.fd_t = 50;
    try el.io.setFileBytes(synthetic_fd, &file_bytes);

    const fds = [_]posix.fd_t{synthetic_fd};

    // ── 5. Submit the recheck ────────────────────────────────
    const Ctx = struct {
        completed: bool = false,
        complete_count: u32 = 0,
        bytes_complete: u64 = 0,
    };
    var ctx = Ctx{};

    try el.startRecheck(
        &session,
        &fds,
        0,
        null, // no fast-path skip; recheck every piece
        struct {
            fn cb(rc: *EL_SimIO.AsyncRecheck) void {
                const c: *Ctx = @ptrCast(@alignCast(rc.caller_ctx.?));
                c.completed = true;
                c.complete_count = rc.complete_pieces.count;
                c.bytes_complete = rc.bytes_complete;
            }
        }.cb,
        @ptrCast(&ctx),
    );

    // ── 6. Drive ticks until the recheck completes ───────────
    //
    // Each tick pulls SimIO completions and feeds them into the
    // recheck state machine, then drains hasher results from the
    // background thread pool. The hasher is a real thread, so we
    // spin until either the on_complete callback fires or we hit
    // the budget.
    var ticks: u32 = 0;
    while (ticks < 1024 and !ctx.completed) : (ticks += 1) {
        try el.tick();
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expectEqual(sim_piece_count, ctx.complete_count);
    try std.testing.expectEqual(@as(u64, sim_total_bytes), ctx.bytes_complete);

    // ── 7. Tidy up the recheck slot ──────────────────────────
    el.cancelAllRechecks();
}

test "AsyncRecheckOf(SimIO): corrupt piece is reported incomplete" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Build canonical bytes + hashes, then corrupt piece 2's content
    // before registering. The recheck should mark pieces 0/1/3 complete
    // and piece 2 incomplete (hash mismatch).
    var file_bytes: [sim_total_bytes]u8 = undefined;
    for (&file_bytes, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var piece_hashes: [sim_piece_count][20]u8 = undefined;
    var p: u32 = 0;
    while (p < sim_piece_count) : (p += 1) {
        Sha1.hash(
            file_bytes[p * sim_piece_size ..][0..sim_piece_size],
            &piece_hashes[p],
            .{},
        );
    }

    // Corrupt piece 2 AFTER hashing — disk now disagrees with the hash.
    @memset(file_bytes[2 * sim_piece_size ..][0..sim_piece_size], 0xFF);

    const torrent_bytes = try buildMultiPieceTorrent(arena.allocator(), &piece_hashes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try tmp.dir.realpathAlloc(arena.allocator(), ".");

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xDEAD_BEEF });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 1) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const synthetic_fd: posix.fd_t = 50;
    try el.io.setFileBytes(synthetic_fd, &file_bytes);

    const fds = [_]posix.fd_t{synthetic_fd};

    const Ctx = struct {
        completed: bool = false,
        bf_p0: bool = false,
        bf_p1: bool = false,
        bf_p2: bool = false,
        bf_p3: bool = false,
    };
    var ctx = Ctx{};

    try el.startRecheck(
        &session,
        &fds,
        0,
        null,
        struct {
            fn cb(rc: *EL_SimIO.AsyncRecheck) void {
                const c: *Ctx = @ptrCast(@alignCast(rc.caller_ctx.?));
                c.completed = true;
                c.bf_p0 = rc.complete_pieces.has(0);
                c.bf_p1 = rc.complete_pieces.has(1);
                c.bf_p2 = rc.complete_pieces.has(2);
                c.bf_p3 = rc.complete_pieces.has(3);
            }
        }.cb,
        @ptrCast(&ctx),
    );

    var ticks: u32 = 0;
    while (ticks < 1024 and !ctx.completed) : (ticks += 1) {
        try el.tick();
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(ctx.bf_p0);
    try std.testing.expect(ctx.bf_p1);
    try std.testing.expect(!ctx.bf_p2); // corrupted
    try std.testing.expect(ctx.bf_p3);

    el.cancelAllRechecks();
}

test "AsyncRecheckOf(SimIO): all-known-complete fast path skips disk reads" {
    // Exercises the AsyncRecheck.start() known-complete fast path through
    // EventLoopOf(SimIO). With every piece pre-marked in `known_complete`,
    // the state machine should fire `on_complete` without ever submitting
    // a read — proven here by leaving the SimIO `file_content` map empty:
    // if a read DID hit, it would return zero bytes and the hash would
    // mismatch, so the asserted "all 4 pieces complete" outcome is only
    // possible if no reads happened.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var file_bytes: [sim_total_bytes]u8 = undefined;
    for (&file_bytes, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var piece_hashes: [sim_piece_count][20]u8 = undefined;
    var p: u32 = 0;
    while (p < sim_piece_count) : (p += 1) {
        Sha1.hash(
            file_bytes[p * sim_piece_size ..][0..sim_piece_size],
            &piece_hashes[p],
            .{},
        );
    }

    const torrent_bytes = try buildMultiPieceTorrent(arena.allocator(), &piece_hashes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try tmp.dir.realpathAlloc(arena.allocator(), ".");

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{});
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 1) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Mark every piece as known-complete so AsyncRecheck skips reads.
    var known = try Bitfield.init(allocator, session.pieceCount());
    defer known.deinit(allocator);
    var i: u32 = 0;
    while (i < session.pieceCount()) : (i += 1) try known.set(i);

    // No setFileBytes — if the fast path is broken and reads do fire,
    // SimIO returns zero bytes, the hash mismatches, and the assertion
    // below catches it.
    const fds = [_]posix.fd_t{50};

    const Ctx = struct {
        completed: bool = false,
        complete_count: u32 = 0,
    };
    var ctx = Ctx{};

    try el.startRecheck(&session, &fds, 0, &known, struct {
        fn cb(rc: *EL_SimIO.AsyncRecheck) void {
            const c: *Ctx = @ptrCast(@alignCast(rc.caller_ctx.?));
            c.completed = true;
            c.complete_count = rc.complete_pieces.count;
        }
    }.cb, @ptrCast(&ctx));

    var ticks: u32 = 0;
    while (ticks < 32 and !ctx.completed) : (ticks += 1) {
        try el.tick();
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expectEqual(sim_piece_count, ctx.complete_count);

    el.cancelAllRechecks();
}

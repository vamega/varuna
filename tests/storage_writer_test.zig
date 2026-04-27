//! PieceStoreOf(SimIO) integration tests.
//!
//! Drives the parameterised piece store through SimIO so the
//! `fallocate` + `fsync` + `read` + `write` ops route through the IO
//! contract end-to-end. These tests force the second instantiation
//! (`PieceStoreOf(SimIO)`) through the typechecker and exercise the
//! happy-path (init creates files + sync flushes + writePiece submits
//! per-span writes + readPiece reconstructs piece data from
//! per-span reads) plus the fault-injected paths (fallocate ->
//! NoSpaceLeft, fsync -> InputOutput, write -> NoSpaceLeft, read ->
//! InputOutput) that the BUGGIFY harness will eventually wrap.
//!
//! PieceStore intentionally still uses real `std.fs.cwd().createFile`
//! to open the on-disk files — the tested surface is the *async*
//! pre-allocation + flush + per-piece I/O, not the file-open path.
//! Files end up zero-length under SimIO (no real kernel fallocate
//! fires); read content comes from `SimIO.setFileBytes`, which
//! sidesteps the simulator's "writes don't actually mutate disk"
//! decoupling for round-trip tests.

const std = @import("std");
const varuna = @import("varuna");
const Session = varuna.torrent.session.Session;
const writer_mod = varuna.storage.writer;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;

const PieceStoreOfSim = writer_mod.PieceStoreOf(SimIO);

/// Minimal single-file v1 torrent (bencoded). 3-byte file, 4-byte
/// pieces => 1 piece (the BT spec lets the last piece be short).
const torrent_3byte_single =
    "d4:infod" ++
    "6:lengthi3e" ++
    "4:name3:abc" ++
    "12:piece lengthi4e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

/// Multi-file v1 torrent: alpha (3 bytes) + beta/gamma (7 bytes), 4-byte
/// pieces. Two open files at PieceStore.init, so two fallocate
/// completions must drain before init returns. Piece 0 spans both
/// files: alpha[0..3] (3 bytes) + beta/gamma[0..1] (1 byte) = 4 bytes.
const torrent_multifile =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi7e4:pathl4:beta5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi4e" ++
    "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

/// 3-file v1 torrent: alpha (3 bytes) + beta (3 bytes) + gamma (3 bytes),
/// 9-byte piece length. Single piece spanning all three files (3 + 3 +
/// 3 = 9 bytes), so writePiece/readPiece submit three completions and
/// must drain all three before returning. Hash is a placeholder — these
/// tests don't exercise hash verification.
const torrent_3file =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi3e4:pathl4:betaee" ++
    "d6:lengthi3e4:pathl5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi9e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

test "PieceStoreOf(SimIO): init + sync happy path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = 0xfeedface });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    // Both files must be open (no priorities filtered).
    try std.testing.expect(store.files.len == 2);
    try std.testing.expect(store.files[0] != null);
    try std.testing.expect(store.files[1] != null);

    // Sync drains two fsyncs through SimIO -> contract -> heap. With no
    // fault injection this completes in a single tick.
    try store.sync();
}

test "PieceStoreOf(SimIO): fallocate fault propagates from init" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3byte_single, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = 0xdeadbeef,
        .faults = .{ .fallocate_error_probability = 1.0 },
    });
    defer sim.deinit();

    // PieceStore.init should propagate error.NoSpaceLeft from the
    // SimIO-injected fault. The file gets created (createFile is
    // synchronous, ahead of the contract call) but the state machine
    // returns the error and the caller's errdefer cleans up.
    const result = PieceStoreOfSim.init(allocator, &session, &sim);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "PieceStoreOf(SimIO): fsync fault propagates from sync" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3byte_single, target_root);
    defer session.deinit(allocator);

    // Build the store under a clean SimIO so init succeeds, then
    // flip the fault knob before invoking sync. (FaultConfig is on
    // sim.config — direct field write is cleaner than a fresh init.)
    var sim = try SimIO.init(allocator, .{ .seed = 0x12345678 });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    sim.config.faults.fsync_error_probability = 1.0;

    try std.testing.expectError(error.InputOutput, store.sync());
}

test "PieceStoreOf(SimIO): do_not_download priority skips fallocate" {
    // When file_priorities marks a file `do_not_download`, no file is
    // opened and no fallocate is submitted. With a single file marked
    // skip, the open_count is zero -> preallocateAll returns early,
    // -> init succeeds even with fallocate_error_probability=1.0.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3byte_single, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = 0xfacefeed,
        // Even with 100% fault, no fallocate will fire — proving the
        // skip path doesn't submit any contract calls.
        .faults = .{ .fallocate_error_probability = 1.0 },
    });
    defer sim.deinit();

    const FilePriority = varuna.torrent.file_priority.FilePriority;
    const priorities = [_]FilePriority{.do_not_download};
    var store = try PieceStoreOfSim.initWithPriorities(
        allocator,
        &session,
        &sim,
        priorities[0..],
    );
    defer store.deinit();

    try std.testing.expect(store.files[0] == null);
}

// ── writePiece / readPiece against the IO contract ────────

test "PieceStoreOf(SimIO): writePiece + readPiece across two spans" {
    // Round-trip: writePiece submits two SimIO writes (one per span);
    // readPiece submits two SimIO reads. Reads come back from
    // `SimIO.setFileBytes` registrations because SimIO writes don't
    // actually mutate disk content. The piece data assembled by
    // readPiece must match what writePiece accepted.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = 0x10001 });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.spans.len);

    // Submit the writes; both SimIO completions must drain cleanly.
    try store.writePiece(plan.spans, "spam");

    // Register expected post-write content per file. Piece 0 spans
    // alpha[0..3] = "spa" and beta/gamma[0..1] = "m".
    try sim.setFileBytes(store.files[0].?.handle, "spa");
    try sim.setFileBytes(store.files[1].?.handle, "m");

    var piece_buffer: [4]u8 = undefined;
    try store.readPiece(plan.spans, piece_buffer[0..]);
    try std.testing.expectEqualStrings("spam", &piece_buffer);
}

test "PieceStoreOf(SimIO): writePiece propagates SimIO write fault" {
    // write_error_probability = 1.0 means every per-span write
    // completes with `error.NoSpaceLeft`. writePiece must surface the
    // first one and the pending counter must drain cleanly so the
    // call returns rather than wedging on tick().
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    // Init under a clean SimIO so files open + fallocate succeed.
    var sim = try SimIO.init(allocator, .{ .seed = 0x20002 });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);

    // Flip the fault knob after init so only the writePiece submissions
    // see the fault. (FaultConfig is on sim.config — direct field
    // write is cleaner than a fresh init.)
    sim.config.faults.write_error_probability = 1.0;

    try std.testing.expectError(error.NoSpaceLeft, store.writePiece(plan.spans, "spam"));
}

test "PieceStoreOf(SimIO): readPiece propagates SimIO read fault" {
    // Mirror of the write-fault test: read_error_probability = 1.0
    // makes every per-span read complete with `error.InputOutput`.
    // readPiece must surface the first one.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = 0x30003 });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);

    sim.config.faults.read_error_probability = 1.0;

    var piece_buffer: [4]u8 = undefined;
    try std.testing.expectError(error.InputOutput, store.readPiece(plan.spans, piece_buffer[0..]));
}

// ── truncate fallback path (filesystem-portability) ───────

test "PieceStoreOf(SimIO): fallocate OperationNotSupported triggers truncate fallback" {
    // When fallocate returns OperationNotSupported (tmpfs <5.10,
    // FAT32, certain FUSE FSes), PieceStore.init must fall back to
    // io.truncate so each file is still extended to its declared
    // length. With truncate succeeding, init must return cleanly.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = 0x7777,
        .faults = .{
            // 100% of fallocate calls deliver OperationNotSupported
            // → fallback fires for every file.
            .fallocate_unsupported_probability = 1.0,
            // Truncate succeeds (default 0.0).
        },
    });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    // Both files should still be open; the fallback path doesn't
    // change file ownership, just the disk-extension primitive used.
    try std.testing.expect(store.files.len == 2);
    try std.testing.expect(store.files[0] != null);
    try std.testing.expect(store.files[1] != null);
}

test "PieceStoreOf(SimIO): truncate fault propagates from fallback path" {
    // Pair of fault knobs: fallocate forced to OperationNotSupported
    // (so the fallback runs), then truncate forced to InputOutput.
    // PieceStore.init must surface InputOutput, not silently succeed.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3byte_single, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = 0xbadbad,
        .faults = .{
            .fallocate_unsupported_probability = 1.0,
            .truncate_error_probability = 1.0,
        },
    });
    defer sim.deinit();

    const result = PieceStoreOfSim.init(allocator, &session, &sim);
    try std.testing.expectError(error.InputOutput, result);
}

test "PieceStoreOf(SimIO): writePiece + readPiece across three spans" {
    // 3-file torrent forces a 3-span piece. Exercises the multi-
    // completion drain path with N > 2 (the existing happy-path test
    // covers N = 2). Confirms `pending` decrements correctly when
    // three completions land in sequence.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3file, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = 0x40004 });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 3), store.files.len);

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), plan.spans.len);

    // Single piece of 9 bytes spanning alpha (3) + beta (3) + gamma (3).
    const piece_data: []const u8 = "ABCdef-XY"; // 9 bytes
    try store.writePiece(plan.spans, piece_data);

    try sim.setFileBytes(store.files[0].?.handle, "ABC");
    try sim.setFileBytes(store.files[1].?.handle, "def");
    try sim.setFileBytes(store.files[2].?.handle, "-XY");

    var piece_buffer: [9]u8 = undefined;
    try store.readPiece(plan.spans, piece_buffer[0..]);
    try std.testing.expectEqualStrings(piece_data, &piece_buffer);
}

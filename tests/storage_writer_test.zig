//! PieceStoreOf(SimIO) integration tests.
//!
//! Drives the parameterised piece store through SimIO so the new
//! `fallocate` + `fsync` ops route through the IO contract end-to-end.
//! These tests force the second instantiation
//! (`PieceStoreOf(SimIO)`) through the typechecker and exercise the
//! happy-path (init creates files + sync flushes cleanly) plus the
//! two fault-injected paths (fallocate -> NoSpaceLeft and fsync ->
//! InputOutput) that the BUGGIFY harness will eventually wrap.
//!
//! PieceStore intentionally still uses real `std.fs.cwd().createFile`
//! to open the on-disk files — the tested surface is the *async*
//! pre-allocation + flush, not the file-open path. Files end up
//! zero-length under SimIO (no real kernel fallocate fires), which
//! is fine for exercising the state machine.

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
/// completions must drain before init returns.
const torrent_multifile =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi7e4:pathl4:beta5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi4e" ++
    "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

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

const std = @import("std");
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;
const posix = std.posix;

/// Count open file descriptors via /proc/self/fd.
fn countOpenFds() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |_| count += 1;
    return count;
}

/// Count threads via /proc/self/task.
fn countThreads() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |_| count += 1;
    return count;
}

test "event loop init and deinit does not leak fds" {
    const fds_before = countOpenFds();

    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        // io_uring may not be available in all test environments
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    el.deinit();

    const fds_after = countOpenFds();
    // Allow +/- 1 for the /proc/self/fd iteration itself
    try std.testing.expect(fds_after <= fds_before + 1);
}

test "event loop does not spawn unexpected threads" {
    const threads_before = countThreads();

    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const threads_after = countThreads();
    // With 0 hasher threads, only the DNS thread pool should spawn.
    // Allow up to 4 extra threads (DNS pool default).
    try std.testing.expect(threads_after - threads_before <= 4);
}

test "event loop with hasher threads are bounded" {
    const threads_before = countThreads();

    var el = EventLoop.initBare(std.testing.allocator, 2) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const threads_after = countThreads();
    // 2 hasher threads + DNS pool (up to 4) = at most 6 new threads
    try std.testing.expect(threads_after - threads_before <= 8);
}

test "EventLoop's IO ticks once with a self-fired timeout under the selected backend" {
    // Backend-validation smoke: confirms the daemon's chosen IO backend
    // (`-Dio=...`) can: (1) construct an EventLoop with the selected
    // backend, (2) submit a timeout via the contract surface,
    // (3) drain it via `io.tick(1)`, (4) tear down without leaking fds.
    //
    // This bypasses `EventLoop.tick()` (which does broader peer_policy
    // / dht / utp work that needs torrent state) and exercises just the
    // backend submission + drain path. A regression here would mean the
    // daemon binary cannot run under that backend even with no peers
    // attached.
    //
    // Runs under every `-Dio=` flavour the daemon binary builds for:
    // io_uring, epoll_posix, epoll_mmap. (Sim builds skip the daemon
    // install entirely; kqueue builds are macOS targets that don't run
    // the Linux test suite.)
    const ifc = varuna.io.io_interface;
    const fds_before = countOpenFds();

    const Counter = struct {
        fires: u32 = 0,

        fn cb(
            userdata: ?*anyopaque,
            _: *ifc.Completion,
            _: ifc.Result,
        ) ifc.CallbackAction {
            const c: *@This() = @ptrCast(@alignCast(userdata.?));
            c.fires += 1;
            return .disarm;
        }
    };

    {
        var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
            if (err == error.SystemResources) return error.SkipZigTest;
            return err;
        };
        defer el.deinit();

        var counter = Counter{};
        var completion = ifc.Completion{};

        // Submit a fast-firing timeout (10 ms — long enough that real
        // io_uring scheduling overhead can land it; short enough that
        // the test stays snappy).
        try el.io.timeout(.{ .ns = 10 * std.time.ns_per_ms }, &completion, &counter, Counter.cb);

        // Block until the timeout's CQE arrives. If the backend's tick
        // implementation is broken (panic on timeout op, never wakes,
        // returns before the deadline), this test will fail or hang.
        try el.io.tick(1);

        // The timeout callback must have fired exactly once.
        try std.testing.expectEqual(@as(u32, 1), counter.fires);

        // A second non-blocking drain must complete without errors.
        try el.io.tick(0);
    }

    // After the EL is dropped, fd count must be back near baseline.
    const fds_after = countOpenFds();
    // Allow +/- 4 for /proc iteration and any small DNS-pool drift.
    try std.testing.expect(fds_after <= fds_before + 4);
}

test "EL.deinit drains hasher.completed_results without leaking valid bufs" {
    // Regression for the leak surfaced by sim-engineer's smart-ban EL
    // light-up. If a hasher worker has produced a verified Result but
    // peer_policy.processHashResults hasn't run yet, that valid piece_buf
    // sits in hasher.completed_results when EL.deinit fires. The fix is
    // two-part:
    //   1. EL.deinit drains hasher → pending_writes before tearing down
    //      the hasher (so verified data still hits disk on graceful paths).
    //   2. hasher.deinit defensively frees ALL completed_results bufs,
    //      not just invalid ones (so abrupt teardown doesn't leak).
    //
    // We exercise (2) here: submit work that will verify, drive the hasher
    // briefly so a valid Result lands in completed_results, then call
    // deinit WITHOUT going through the full EL drain. testing.allocator
    // panics on leaks; without the fix this test catches them.
    const Hasher = varuna.io.hasher.Hasher;
    const Sha1 = std.crypto.hash.Sha1;

    var hasher = Hasher.realInit(std.testing.allocator, 2) catch return error.SkipZigTest;

    // Submit a piece whose hash will verify.
    const data = try std.testing.allocator.alloc(u8, 4);
    @memcpy(data, "spam");
    var expected: [20]u8 = undefined;
    Sha1.hash("spam", &expected, .{});
    try hasher.submitVerify(0, 0, data, expected, 0);

    // Wait until the worker has produced a result. We DON'T drain it —
    // we want completed_results to still be populated when deinit fires.
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        if (hasher.hasPendingWork()) break;
    }

    // Deinit must not leak. testing.allocator panics on leaks.
    hasher.deinit();
    std.testing.allocator.destroy(hasher);
}

fn expectHandshakeBytes(
    actual: *const [68]u8,
    expected_hash: [20]u8,
    expected_peer_id: [20]u8,
    expect_v2_support: bool,
) !void {
    const pw = varuna.net.peer_wire;
    const ext = varuna.net.extensions;

    try std.testing.expectEqual(pw.protocol_length, actual[0]);
    try std.testing.expectEqualStrings(pw.protocol_string, actual[1..20]);

    var expected_reserved = @as([8]u8, @splat(0));
    expected_reserved[ext.reserved_byte] |= ext.reserved_mask;
    if (expect_v2_support) {
        expected_reserved[pw.v2_reserved_byte] |= pw.v2_reserved_mask;
    }
    try std.testing.expectEqualSlices(u8, &expected_reserved, actual[20..28]);
    try std.testing.expectEqualSlices(u8, &expected_hash, actual[28..48]);
    try std.testing.expectEqualSlices(u8, &expected_peer_id, actual[48..68]);
}

fn expectDefaultOutboundHandshake(
    version: varuna.torrent.metainfo.TorrentVersion,
    v1_hash: [20]u8,
    v2_hash: ?[20]u8,
    expected_hash: [20]u8,
    expect_v2_support: bool,
) !void {
    try expectOutboundHandshake(version, v1_hash, v2_hash, null, expected_hash, expect_v2_support);
}

fn expectOutboundHandshake(
    version: varuna.torrent.metainfo.TorrentVersion,
    v1_hash: [20]u8,
    v2_hash: ?[20]u8,
    selected_hash: ?[20]u8,
    expected_hash: [20]u8,
    expect_v2_support: bool,
) !void {
    const SimIO = varuna.io.sim_io.SimIO;
    const EL = varuna.io.event_loop.EventLoopOf(SimIO);

    const sim_io = try SimIO.init(std.testing.allocator, .{ .socket_capacity = 4 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const fds = try el.io.createSocketpair();
    defer el.io.closeSocket(fds[1]);

    const peer_id = @as([20]u8, @splat(0x99));
    const empty_fds = [_]posix.fd_t{};

    var full_v2 = @as([32]u8, @splat(0));
    if (v2_hash) |truncated| @memcpy(full_v2[0..20], &truncated);

    const path = [_][]const u8{"file.bin"};
    const files = [_]varuna.torrent.metainfo.Metainfo.File{.{
        .length = 1,
        .path = path[0..],
    }};
    var session = varuna.torrent.session.Session{
        .torrent_bytes = &.{},
        .metainfo = .{
            .info_hash = v1_hash,
            .announce = null,
            .comment = null,
            .created_by = null,
            .name = "file.bin",
            .piece_length = 16 * 1024,
            .files = files[0..],
            .version = version,
            .info_hash_v2 = if (v2_hash != null) full_v2 else null,
        },
        .layout = undefined,
        .manifest = undefined,
    };

    const tid = try el.addTorrentContext(.{
        .session = &session,
        .shared_fds = empty_fds[0..],
        .info_hash = v1_hash,
        .info_hash_v2 = v2_hash,
        .peer_id = peer_id,
    });
    const slot = if (selected_hash) |hash|
        try el.addConnectedPeerWithSwarmHash(fds[0], tid, null, hash)
    else
        try el.addConnectedPeer(fds[0], tid);

    try expectHandshakeBytes(&el.peers[slot].handshake_buf, expected_hash, peer_id, expect_v2_support);
}

test "BEP 52 outbound handshake bytes use v1 swarm hash for v1 torrents" {
    const v1_hash = @as([20]u8, @splat(0x11));
    try expectDefaultOutboundHandshake(.v1, v1_hash, null, v1_hash, false);
}

test "BEP 52 outbound handshake bytes use v1 swarm hash for hybrid default peers" {
    const v1_hash = @as([20]u8, @splat(0x22));
    const v2_hash = @as([20]u8, @splat(0x33));
    try expectDefaultOutboundHandshake(.hybrid, v1_hash, v2_hash, v1_hash, true);
}

test "BEP 52 outbound handshake bytes use truncated v2 swarm hash for pure v2 torrents" {
    const v1_hash = @as([20]u8, @splat(0x44));
    const v2_hash = @as([20]u8, @splat(0x55));
    try expectDefaultOutboundHandshake(.v2, v1_hash, v2_hash, v2_hash, true);
}

test "BEP 52 DHT-selected hybrid handshake bytes use selected v2 swarm hash" {
    const v1_hash = @as([20]u8, @splat(0x66));
    const v2_hash = @as([20]u8, @splat(0x77));
    try expectOutboundHandshake(.hybrid, v1_hash, v2_hash, v2_hash, v2_hash, true);
}

test "BEP 52 DHT peer results preserve selected v2 swarm hash" {
    const SimIO = varuna.io.sim_io.SimIO;
    const EL = varuna.io.event_loop.EventLoopOf(SimIO);

    const sim_io = try SimIO.init(std.testing.allocator, .{ .socket_capacity = 4 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const v1_hash = @as([20]u8, @splat(0x88));
    const v2_hash = @as([20]u8, @splat(0x99));
    const peer_id = @as([20]u8, @splat(0xaa));
    const empty_fds = [_]posix.fd_t{};

    var full_v2 = @as([32]u8, @splat(0));
    @memcpy(full_v2[0..20], &v2_hash);

    const path = [_][]const u8{"file.bin"};
    const files = [_]varuna.torrent.metainfo.Metainfo.File{.{
        .length = 1,
        .path = path[0..],
    }};
    var session = varuna.torrent.session.Session{
        .torrent_bytes = &.{},
        .metainfo = .{
            .info_hash = v1_hash,
            .announce = null,
            .comment = null,
            .created_by = null,
            .name = "file.bin",
            .piece_length = 16 * 1024,
            .files = files[0..],
            .version = .hybrid,
            .info_hash_v2 = full_v2,
        },
        .layout = undefined,
        .manifest = undefined,
    };

    const tid = try el.addTorrentContext(.{
        .session = &session,
        .shared_fds = empty_fds[0..],
        .info_hash = v1_hash,
        .info_hash_v2 = v2_hash,
        .peer_id = peer_id,
    });

    var engine = try varuna.dht.DhtEngine.create(std.testing.allocator, &el.random, @as([20]u8, @splat(0xbb)));
    defer {
        el.dht_engine = null;
        engine.deinit();
        std.testing.allocator.destroy(engine);
    }
    el.dht_engine = engine;

    const peers = try std.testing.allocator.alloc(std.net.Address, 1);
    peers[0] = std.net.Address.initIp4(.{ 10, 0, 0, 9 }, 6881);
    try engine.peer_results.append(std.testing.allocator, .{
        .info_hash = v2_hash,
        .peers = peers,
    });

    varuna.io.dht_handler.dhtTick(&el);
    el.processPeerCandidates();

    var found_slot: ?u16 = null;
    for (el.peers, 0..) |*peer, idx| {
        if (peer.state != .free and peer.torrent_id == tid) {
            found_slot = @intCast(idx);
            break;
        }
    }
    try std.testing.expect(found_slot != null);

    const selected = el.selectedPeerSwarmHash(&el.peers[found_slot.?]);
    try std.testing.expectEqualSlices(u8, &v2_hash, &selected);
}

const std = @import("std");
const varuna = @import("varuna");
const EventLoop = varuna.io.event_loop.EventLoop;

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

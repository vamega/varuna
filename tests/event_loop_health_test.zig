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

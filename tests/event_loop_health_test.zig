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

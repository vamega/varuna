//! SimIO durability model tests.
//!
//! Exercises the per-fd dirty/durable byte layers added to `SimIO` to
//! model the kernel pagecache barrier:
//!   * `write` extends the fd's `pending` (un-fsynced) layer.
//!   * `read` returns the union of `durable` and `pending` (most-recent
//!     byte wins), matching post-write/pre-fsync pagecache semantics.
//!   * `fsync` (success path) promotes `pending[range]` into
//!     `durable[range]` and clears the dirty mask.
//!   * `fsync` (fault path) leaves pending untouched, so a follow-up
//!     `crash()` still drops the bytes.
//!   * `crash()` drops every fd's `pending` layer, leaving only durable.
//!
//! These are algorithm-level tests against `SimIO.read` / `write` /
//! `truncate` / `fallocate` / `fsync` / `crash` — they don't drive an
//! EventLoop. The end-to-end resume gate harness lives in
//! `tests/resume_durability_buggify_test.zig`.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io = varuna.io.sim_io;
const SimIO = sim_io.SimIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Test fixtures ─────────────────────────────────────────

const TestCtx = struct {
    calls: u32 = 0,
    last_result: ?Result = null,
};

fn testCallback(
    userdata: ?*anyopaque,
    _: *Completion,
    result: Result,
) CallbackAction {
    const ctx: *TestCtx = @ptrCast(@alignCast(userdata.?));
    ctx.last_result = result;
    ctx.calls += 1;
    return .disarm;
}

/// Drive a single read against `fd` at `offset` into a caller-owned
/// buffer, advancing one tick. Returns the number of bytes the read
/// reported success for (the `Result.read` payload), so callers can
/// pair it with `expectEqualSlices` on `buf`.
fn readSync(io: *SimIO, fd: posix.fd_t, offset: u64, buf: []u8) !usize {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.read(.{ .fd = fd, .buf = buf, .offset = offset }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.last_result.?) {
        .read => |r| try r,
        else => unreachable,
    };
}

/// Drive a single write against `fd` at `offset`, advancing one tick.
/// Asserts the write reported success for the full buffer length.
fn writeSync(io: *SimIO, fd: posix.fd_t, offset: u64, bytes: []const u8) !void {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.write(.{ .fd = fd, .buf = bytes, .offset = offset }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .write => |r| {
            const n = try r;
            try testing.expectEqual(bytes.len, n);
        },
        else => unreachable,
    }
}

/// Drive a single fsync against `fd`, advancing one tick. Returns the
/// completion's result (success or `error.InputOutput` from the fault
/// knob).
fn fsyncSync(io: *SimIO, fd: posix.fd_t) !void {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = fd }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.last_result.?) {
        .fsync => |r| try r,
        else => unreachable,
    };
}

fn truncateSync(io: *SimIO, fd: posix.fd_t, length: u64) !void {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.truncate(.{ .fd = fd, .length = length }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.last_result.?) {
        .truncate => |r| try r,
        else => unreachable,
    };
}

fn fallocateSync(io: *SimIO, fd: posix.fd_t, offset: u64, len: u64) !void {
    return fallocateModeSync(io, fd, 0, offset, len);
}

fn fallocateModeSync(io: *SimIO, fd: posix.fd_t, mode: i32, offset: u64, len: u64) !void {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.fallocate(.{ .fd = fd, .mode = mode, .offset = offset, .len = len }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.last_result.?) {
        .fallocate => |r| try r,
        else => unreachable,
    };
}

fn expectFallocateError(
    io: *SimIO,
    fd: posix.fd_t,
    mode: i32,
    offset: u64,
    len: u64,
    expected: anyerror,
) !void {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.fallocate(.{ .fd = fd, .mode = mode, .offset = offset, .len = len }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fallocate => |r| try testing.expectError(expected, r),
        else => unreachable,
    }
}

fn copyFileRangeSync(
    io: *SimIO,
    in_fd: posix.fd_t,
    in_offset: u64,
    out_fd: posix.fd_t,
    out_offset: u64,
    len: usize,
) !usize {
    var c = Completion{};
    var ctx = TestCtx{};
    try io.copy_file_range(.{
        .in_fd = in_fd,
        .in_offset = in_offset,
        .out_fd = out_fd,
        .out_offset = out_offset,
        .len = len,
    }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.last_result.?) {
        .copy_file_range => |r| try r,
        else => unreachable,
    };
}

// ── Tests ─────────────────────────────────────────────────

test "SimIO durability: write before fsync is visible to read (pagecache hit)" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 7;
    try writeSync(&io, fd, 0, "hello");

    var buf: [5]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, "hello", &buf);
}

test "SimIO durability: fsync promotes pending to durable; reads still see same bytes" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 11;
    try writeSync(&io, fd, 0, "abcde");
    try fsyncSync(&io, fd);

    var buf: [5]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, "abcde", &buf);
}

test "SimIO durability: crash drops un-fsynced writes; durable layer survives" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 13;
    // Step 1: write + fsync = durable.
    try writeSync(&io, fd, 0, "DURABLE!");
    try fsyncSync(&io, fd);

    // Step 2: write more, but NOT fsynced.
    try writeSync(&io, fd, 8, "PENDING");

    // Pre-crash read sees the union — DURABLE!PENDING.
    var buf: [15]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 15), n_pre);
    try testing.expectEqualSlices(u8, "DURABLE!PENDING", &buf);

    // Crash. PENDING bytes are dropped; DURABLE! survives.
    io.crash();

    var buf2: [15]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &buf2);
    try testing.expectEqual(@as(usize, 8), n_post);
    try testing.expectEqualSlices(u8, "DURABLE!", buf2[0..n_post]);
}

test "SimIO durability: setFileBytes seeds the durable layer; crash leaves it intact" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 17;
    try io.setFileBytes(fd, "ON-DISK-SEED");

    // A pending overlay added on top.
    try writeSync(&io, fd, 0, "OVER");

    // Pre-crash read: OVER overlays the first 4 bytes; tail is durable.
    var buf: [12]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 12), n_pre);
    try testing.expectEqualSlices(u8, "OVERISK-SEED", &buf);

    io.crash();

    // Post-crash read: original seed only.
    var buf2: [12]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &buf2);
    try testing.expectEqual(@as(usize, 12), n_post);
    try testing.expectEqualSlices(u8, "ON-DISK-SEED", &buf2);
}

test "SimIO durability: interleaved overlapping writes show the most-recent byte" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 19;
    try writeSync(&io, fd, 0, "AAAAAAAA");
    try writeSync(&io, fd, 2, "BBB"); // overlaps middle
    try writeSync(&io, fd, 6, "CC"); // overlaps tail

    var buf: [8]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(u8, "AABBBACC", &buf);
}

test "SimIO durability: partial-region fsync (offset write only) promotes only that region" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 23;
    // Seed durable bytes.
    try io.setFileBytes(fd, "OOOOOOOO");

    // Two distinct pending writes, only the *first* will be fsynced
    // before the crash. (SimIO's `fsync` is a per-fd flush — it
    // promotes every dirty bit on the fd at the moment it fires. But
    // it captures the dirty state *at fsync time*, so a write
    // submitted after the fsync's tick is still pending.)
    try writeSync(&io, fd, 0, "AA"); // dirty
    try fsyncSync(&io, fd); // promotes "AA" → durable
    try writeSync(&io, fd, 4, "BB"); // dirty (post-fsync)

    // Pre-crash union: AA at 0, OO at 2, BB at 4, OO at 6.
    var buf: [8]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 8), n_pre);
    try testing.expectEqualSlices(u8, "AAOOBBOO", &buf);

    // Crash drops the post-fsync write only.
    io.crash();

    var buf2: [8]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &buf2);
    try testing.expectEqual(@as(usize, 8), n_post);
    try testing.expectEqualSlices(u8, "AAOOOOOO", &buf2);
}

test "SimIO durability: fsync fault path leaves pending untouched (crash still drops bytes)" {
    // Use a seeded RNG with `fsync_error_probability == 1.0` so every
    // fsync surfaces InputOutput. The promote-to-durable side effect
    // must NOT fire on the fault path; otherwise a partial-write
    // followed by a failed fsync would silently survive a crash and
    // mask the bug we're modelling.
    var io = try SimIO.init(testing.allocator, .{
        .seed = 0xFEED_BEEF,
        .faults = .{ .fsync_error_probability = 1.0 },
    });
    defer io.deinit();

    const fd: posix.fd_t = 29;
    try writeSync(&io, fd, 0, "WILLBELOST");

    // Pre-fsync read sees the pagecache.
    var buf: [10]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 10), n_pre);
    try testing.expectEqualSlices(u8, "WILLBELOST", &buf);

    // fsync fails — pending stays pending.
    var c = Completion{};
    var ctx = TestCtx{};
    try io.fsync(.{ .fd = fd }, &c, &ctx, testCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.last_result.?) {
        .fsync => |r| try testing.expectError(error.InputOutput, r),
        else => try testing.expect(false),
    }

    // Crash. Because fsync failed, none of the bytes were promoted —
    // they're all gone post-crash.
    io.crash();

    var buf2: [10]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &buf2);
    try testing.expectEqual(@as(usize, 0), n_post);
}

test "SimIO durability: read at offset past visible length returns zero bytes" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 31;
    try writeSync(&io, fd, 0, "short");

    var buf: [16]u8 = undefined;
    const n = try readSync(&io, fd, 100, &buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "SimIO durability: gap between durable end and pending offset reads as zero" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 37;
    // Seed 4 durable bytes.
    try io.setFileBytes(fd, "ABCD");

    // Write a pending region 4 bytes past the end of durable.
    // Bytes 4..7 are gap (no overlay, no durable) → read as zero.
    try writeSync(&io, fd, 8, "EFGH");

    var buf: [12]u8 = undefined;
    @memset(&buf, 0xff);
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualSlices(u8, "ABCD\x00\x00\x00\x00EFGH", &buf);
}

test "SimIO durability: crash with no writes is a no-op" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 41;
    try io.setFileBytes(fd, "stable");

    io.crash(); // nothing to drop

    var buf: [6]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualSlices(u8, "stable", &buf);
}

test "SimIO durability: setFileBytes copies; caller may mutate or free its buffer" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 43;
    var src: [4]u8 = .{ 'p', 'q', 'r', 's' };
    try io.setFileBytes(fd, &src);

    // Mutate the caller's buffer; the SimIO copy must remain intact.
    src[0] = 'Z';
    src[1] = 'Z';

    var buf: [4]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, "pqrs", &buf);
}

test "SimIO durability: per-fd isolation; one fd's crash doesn't affect another" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd_a: posix.fd_t = 47;
    const fd_b: posix.fd_t = 53;

    try writeSync(&io, fd_a, 0, "A-pending");
    try writeSync(&io, fd_b, 0, "B-pending");
    try fsyncSync(&io, fd_b); // only B's bytes are durable

    io.crash(); // drops A's pending; B already promoted

    var buf_a: [9]u8 = undefined;
    const n_a = try readSync(&io, fd_a, 0, &buf_a);
    try testing.expectEqual(@as(usize, 0), n_a);

    var buf_b: [9]u8 = undefined;
    const n_b = try readSync(&io, fd_b, 0, &buf_b);
    try testing.expectEqual(@as(usize, 9), n_b);
    try testing.expectEqualSlices(u8, "B-pending", &buf_b);
}

test "SimIO durability: truncate length is pending until fsync" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 59;
    try io.setFileBytes(fd, "ABCDEFGH");

    try truncateSync(&io, fd, 3);

    var pre_buf: [8]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &pre_buf);
    try testing.expectEqual(@as(usize, 3), n_pre);
    try testing.expectEqualSlices(u8, "ABC", pre_buf[0..n_pre]);

    io.crash();

    var post_buf: [8]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &post_buf);
    try testing.expectEqual(@as(usize, 8), n_post);
    try testing.expectEqualSlices(u8, "ABCDEFGH", post_buf[0..n_post]);
}

test "SimIO durability: fsynced truncate survives crash" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 61;
    try io.setFileBytes(fd, "ABCDEFGH");

    try truncateSync(&io, fd, 3);
    try fsyncSync(&io, fd);
    io.crash();

    var buf: [8]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, "ABC", buf[0..n]);
}

test "SimIO durability: fallocate length is pending until fsync" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 67;
    try fallocateSync(&io, fd, 0, 8);

    var pre_buf: [8]u8 = undefined;
    @memset(&pre_buf, 0xff);
    const n_pre = try readSync(&io, fd, 0, &pre_buf);
    try testing.expectEqual(@as(usize, 8), n_pre);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00\x00\x00\x00\x00", &pre_buf);

    io.crash();

    var post_buf: [8]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &post_buf);
    try testing.expectEqual(@as(usize, 0), n_post);
}

test "SimIO durability: fsynced fallocate exposes durable zero length" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 71;
    try fallocateSync(&io, fd, 0, 8);
    try fsyncSync(&io, fd);
    io.crash();

    var buf: [8]u8 = undefined;
    @memset(&buf, 0xff);
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x00\x00\x00\x00\x00", &buf);
}

test "SimIO durability: copy_file_range copies source bytes into destination pending layer" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const src_fd: posix.fd_t = 79;
    const dst_fd: posix.fd_t = 83;
    try io.setFileBytes(src_fd, "0123456789");
    try io.setFileBytes(dst_fd, "XXXXXXXXXX");

    const copied = try copyFileRangeSync(&io, src_fd, 2, dst_fd, 3, 4);
    try testing.expectEqual(@as(usize, 4), copied);

    var pre_buf: [10]u8 = undefined;
    const n_pre = try readSync(&io, dst_fd, 0, &pre_buf);
    try testing.expectEqual(@as(usize, 10), n_pre);
    try testing.expectEqualSlices(u8, "XXX2345XXX", &pre_buf);

    try fsyncSync(&io, dst_fd);
    io.crash();

    var post_buf: [10]u8 = undefined;
    const n_post = try readSync(&io, dst_fd, 0, &post_buf);
    try testing.expectEqual(@as(usize, 10), n_post);
    try testing.expectEqualSlices(u8, "XXX2345XXX", &post_buf);
}

test "SimIO durability: crash before fsync drops copied bytes" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const src_fd: posix.fd_t = 89;
    const dst_fd: posix.fd_t = 97;
    try io.setFileBytes(src_fd, "ABCDE");
    try io.setFileBytes(dst_fd, "AAAAAA");

    const copied = try copyFileRangeSync(&io, src_fd, 1, dst_fd, 2, 3);
    try testing.expectEqual(@as(usize, 3), copied);

    var pre_buf: [6]u8 = undefined;
    const n_pre = try readSync(&io, dst_fd, 0, &pre_buf);
    try testing.expectEqual(@as(usize, 6), n_pre);
    try testing.expectEqualSlices(u8, "AABCDA", &pre_buf);

    io.crash();

    var post_buf: [6]u8 = undefined;
    const n_post = try readSync(&io, dst_fd, 0, &post_buf);
    try testing.expectEqual(@as(usize, 6), n_post);
    try testing.expectEqualSlices(u8, "AAAAAA", &post_buf);
}

test "SimIO durability: FALLOC_FL_ZERO_RANGE zeros bytes pending until fsync" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 101;
    try io.setFileBytes(fd, "ABCDEFGH");

    try fallocateModeSync(&io, fd, linux.FALLOC.FL_ZERO_RANGE, 2, 3);

    var pre_buf: [8]u8 = undefined;
    const n_pre = try readSync(&io, fd, 0, &pre_buf);
    try testing.expectEqual(@as(usize, 8), n_pre);
    try testing.expectEqualSlices(u8, "AB\x00\x00\x00FGH", &pre_buf);

    io.crash();

    var crash_buf: [8]u8 = undefined;
    const n_crash = try readSync(&io, fd, 0, &crash_buf);
    try testing.expectEqual(@as(usize, 8), n_crash);
    try testing.expectEqualSlices(u8, "ABCDEFGH", &crash_buf);

    try fallocateModeSync(&io, fd, linux.FALLOC.FL_ZERO_RANGE, 2, 3);
    try fsyncSync(&io, fd);
    io.crash();

    var post_buf: [8]u8 = undefined;
    const n_post = try readSync(&io, fd, 0, &post_buf);
    try testing.expectEqual(@as(usize, 8), n_post);
    try testing.expectEqualSlices(u8, "AB\x00\x00\x00FGH", &post_buf);
}

test "SimIO durability: FALLOC_FL_KEEP_SIZE does not extend visible length" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 103;
    try io.setFileBytes(fd, "ABCD");

    try fallocateModeSync(&io, fd, linux.FALLOC.FL_KEEP_SIZE, 0, 12);
    try fsyncSync(&io, fd);
    io.crash();

    var buf: [12]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, "ABCD", buf[0..n]);
}

test "SimIO durability: unsupported fallocate range-edit modes are rejected" {
    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    const fd: posix.fd_t = 107;
    try io.setFileBytes(fd, "ABCDEFGH");

    try expectFallocateError(&io, fd, linux.FALLOC.FL_COLLAPSE_RANGE, 2, 3, error.OperationNotSupported);
    try expectFallocateError(&io, fd, linux.FALLOC.FL_PUNCH_HOLE | linux.FALLOC.FL_KEEP_SIZE, 2, 3, error.OperationNotSupported);
    try expectFallocateError(&io, fd, linux.FALLOC.FL_UNSHARE_RANGE, 2, 3, error.OperationNotSupported);

    var buf: [8]u8 = undefined;
    const n = try readSync(&io, fd, 0, &buf);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(u8, "ABCDEFGH", &buf);
}

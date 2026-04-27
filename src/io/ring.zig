const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Maximum number of pre-registered fixed buffers for READ_FIXED / WRITE_FIXED.
/// Each buffer is one piece-sized block; the pool is registered once at init.
pub const max_fixed_buffers = 64;

/// Fixed buffer pool for io_uring READ_FIXED / WRITE_FIXED.
/// Pre-registers page-aligned, pinned buffers with the kernel.
pub const FixedBufferPool = struct {
    bufs: ?[]posix.iovec = null,
    alloc: ?[]u8 = null,
    free: [max_fixed_buffers]bool = [_]bool{true} ** max_fixed_buffers,

    /// Register a pool of `count` fixed buffers of `buf_size` bytes each.
    /// These are page-aligned and pinned, suitable for READ_FIXED / WRITE_FIXED.
    pub fn registerBuffers(self: *FixedBufferPool, ring: *linux.IoUring, count: u16, buf_size: usize) !void {
        if (count > max_fixed_buffers) return error.TooManyBuffers;
        const iovec_bytes = @sizeOf(posix.iovec) * @as(usize, count);
        const backing = try std.heap.page_allocator.alloc(u8, iovec_bytes);
        const iovecs: []posix.iovec = @as([*]posix.iovec, @ptrCast(@alignCast(backing.ptr)))[0..count];

        for (iovecs) |*iov| {
            const mem = try posix.mmap(null, buf_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            iov.* = .{
                .base = @ptrCast(mem),
                .len = buf_size,
            };
        }

        try ring.register_buffers(iovecs);
        self.bufs = iovecs;
        self.alloc = backing;
        self.free = [_]bool{true} ** max_fixed_buffers;
    }

    /// Claim a free fixed buffer slot. Returns the index and a slice to the buffer.
    pub fn claimFixedBuffer(self: *FixedBufferPool) ?struct { index: u16, buf: []u8 } {
        const bufs = self.bufs orelse return null;
        for (&self.free, 0..) |*is_free, i| {
            if (i >= bufs.len) break;
            if (is_free.*) {
                is_free.* = false;
                const iov = bufs[i];
                return .{
                    .index = @intCast(i),
                    .buf = @as([*]u8, @ptrCast(iov.base))[0..iov.len],
                };
            }
        }
        return null;
    }

    /// Release a previously claimed fixed buffer slot.
    pub fn releaseFixedBuffer(self: *FixedBufferPool, index: u16) void {
        self.free[index] = true;
    }

    pub fn deinit(self: *FixedBufferPool, ring: *linux.IoUring) void {
        if (self.bufs != null) {
            ring.unregister_buffers() catch {};
            for (self.bufs.?) |iov| {
                posix.munmap(@alignCast(iov.base[0..iov.len]));
            }
            if (self.alloc) |a| std.heap.page_allocator.free(a);
            self.bufs = null;
            self.alloc = null;
        }
    }
};

/// CQE error code translation — maps io_uring completion error codes to
/// Zig error values.
pub fn checkCqe(cqe: linux.io_uring_cqe) !void {
    const e = cqe.err();
    switch (e) {
        .SUCCESS => {},
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .NETUNREACH => return error.NetworkUnreachable,
        .HOSTUNREACH => return error.HostUnreachable,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .PIPE => return error.BrokenPipe,
        .CONNABORTED => return error.ConnectionAborted,
        .CANCELED => return error.OperationCanceled,
        else => return posix.unexpectedErrno(e),
    }
}

/// Initialize an IoUring with optimization flags, falling back to plain
/// init if the flags are unsupported by the kernel.
pub fn initIoUring(entries: u16, flags: u32) !linux.IoUring {
    return linux.IoUring.init(entries, flags) catch
        try linux.IoUring.init(entries, 0);
}

/// Probe whether io_uring is available on this kernel.
pub fn probe() bool {
    var ring = linux.IoUring.init(4, 0) catch return false;
    ring.deinit();
    return true;
}

/// Per-op feature flags determined at ring init via
/// `IORING_REGISTER_PROBE`. Add fields here as new ops need runtime
/// detection (e.g. `IORING_OP_BIND`/`LISTEN` at 6.11+,
/// `IORING_OP_SETSOCKOPT` at 6.7+). The probe runs once per ring; the
/// result is cached on the backend.
///
/// Default-initialized values are all `false` — i.e. the safe answer
/// when we cannot determine support, which is what we want every caller
/// to fall back on.
pub const FeatureSupport = struct {
    /// `IORING_OP_FTRUNCATE`, kernel ≥6.9. Below that, RealIO falls
    /// back to a synchronous `posix.ftruncate(2)` (the only daemon
    /// caller is `PieceStore.init`'s filesystem-portability fallback,
    /// which already runs on a background thread).
    supports_ftruncate: bool = false,

    /// All-false sentinel used when the probe register itself isn't
    /// supported (kernel <5.6) or fails for any other reason. Every op
    /// gated on this struct must already have a synchronous fallback.
    pub const none: FeatureSupport = .{};
};

/// Probe the running kernel's per-op io_uring support via
/// `IORING_REGISTER_PROBE`. Caller owns `ring`; this function only
/// reads from it. On kernels that don't support the probe register
/// itself (kernel <5.6, returns `EINVAL`) we fall back to all-false —
/// every op gated on `FeatureSupport` must have a synchronous fallback,
/// so a failed probe is observably equivalent to "nothing extra is
/// supported".
pub fn probeFeatures(ring: *linux.IoUring) FeatureSupport {
    const p = ring.get_probe() catch return FeatureSupport.none;
    return .{
        .supports_ftruncate = p.is_supported(.FTRUNCATE),
    };
}

// ── Tests ─────────────────────────────────────────────────

fn skipIfUnavailable() !linux.IoUring {
    return linux.IoUring.init(16, 0) catch return error.SkipZigTest;
}

test "probe detects io_uring availability" {
    _ = probe();
}

test "probeFeatures runs without panic and returns a FeatureSupport" {
    var ring = skipIfUnavailable() catch return;
    defer ring.deinit();

    const features = probeFeatures(&ring);
    // We can't assert a specific value without pinning to a kernel
    // version: a 6.6 kernel reports `supports_ftruncate = false`, a
    // 6.9+ kernel reports `true`. Either is acceptable.
    _ = features;
}

test "probeFeatures FeatureSupport.none has every flag false" {
    const none = FeatureSupport.none;
    try std.testing.expectEqual(false, none.supports_ftruncate);
}

test "init and deinit ring" {
    var ring = try skipIfUnavailable();
    ring.deinit();
}

test "async timeout fires after specified duration" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    const ts = linux.kernel_timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
    _ = try ring.timeout(42, &ts, 0, 0);
    _ = try ring.submit();

    // Wait for the timeout CQE
    const cqe = try ring.copy_cqe();
    try std.testing.expectEqual(@as(u64, 42), cqe.user_data);
    // Timeout completion returns -ETIME
    try std.testing.expectEqual(linux.E.TIME, cqe.err());
}

test "async link_timeout cancels slow operation" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Create a connected socket pair
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Submit recv with link timeout -- recv will block (no data coming),
    // so the 10ms timeout should fire and cancel the recv.
    var recv_buf: [16]u8 = undefined;
    _ = try ring.recv(200, fds[0], .{ .buffer = &recv_buf }, 0);
    // Set IO_LINK on the recv SQE manually
    const sqes = ring.sq.sqes;
    sqes[(ring.sq.sqe_tail -% 1) & ring.sq.mask].flags |= linux.IOSQE_IO_LINK;
    const ts = linux.kernel_timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
    _ = try ring.link_timeout(201, &ts, 0);
    _ = try ring.submit();

    // Collect both CQEs
    const cqe1 = try ring.copy_cqe();
    const cqe2 = try ring.copy_cqe();

    // One should be the cancelled recv, the other the timeout
    const recv_cqe = if (cqe1.user_data == 200) cqe1 else cqe2;
    const timeout_cqe = if (cqe1.user_data == 201) cqe1 else cqe2;

    // The recv should be cancelled
    try std.testing.expectEqual(linux.E.CANCELED, recv_cqe.err());
    // The timeout fired (ETIME)
    try std.testing.expectEqual(linux.E.TIME, timeout_cqe.err());
}

test "cancel_async returns ENOENT for nonexistent operation" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Cancel a user_data that doesn't correspond to any pending op
    _ = try ring.cancel(1, 999999, 0);
    _ = try ring.submit();
    const cqe = try ring.copy_cqe();
    // Should return ENOENT since there's nothing to cancel
    try std.testing.expectEqual(linux.E.NOENT, cqe.err());
}

test "fixed buffer registration and claim/release" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var pool = FixedBufferPool{};
    defer pool.deinit(&ring);

    // Register 2 fixed buffers of 4096 bytes each
    pool.registerBuffers(&ring, 2, 4096) catch |err| {
        // ENOMEM or EPERM on some systems -- skip test
        if (err == error.Unexpected) return;
        return err;
    };

    // Claim first buffer
    const claimed = pool.claimFixedBuffer() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), claimed.index);
    try std.testing.expectEqual(@as(usize, 4096), claimed.buf.len);

    // Claim second buffer
    const claimed2 = pool.claimFixedBuffer() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 1), claimed2.index);

    // No more buffers available
    try std.testing.expectEqual(@as(?@TypeOf(claimed), null), pool.claimFixedBuffer());

    // Release first, re-claim should succeed
    pool.releaseFixedBuffer(claimed.index);
    const reclaimed = pool.claimFixedBuffer() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), reclaimed.index);

    pool.releaseFixedBuffer(reclaimed.index);
    pool.releaseFixedBuffer(claimed2.index);
}

test "checkCqe maps error codes correctly" {
    const success_cqe = linux.io_uring_cqe{ .user_data = 0, .res = 0, .flags = 0 };
    try checkCqe(success_cqe);

    const refused_cqe = linux.io_uring_cqe{ .user_data = 0, .res = -@as(i32, @intFromEnum(linux.E.CONNREFUSED)), .flags = 0 };
    try std.testing.expectError(error.ConnectionRefused, checkCqe(refused_cqe));

    const reset_cqe = linux.io_uring_cqe{ .user_data = 0, .res = -@as(i32, @intFromEnum(linux.E.CONNRESET)), .flags = 0 };
    try std.testing.expectError(error.ConnectionResetByPeer, checkCqe(reset_cqe));

    const pipe_cqe = linux.io_uring_cqe{ .user_data = 0, .res = -@as(i32, @intFromEnum(linux.E.PIPE)), .flags = 0 };
    try std.testing.expectError(error.BrokenPipe, checkCqe(pipe_cqe));
}

test "flush and drain_cqes collect completions" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Queue two timeouts with 0ns (fire immediately)
    const ts = linux.kernel_timespec{ .sec = 0, .nsec = 0 };
    _ = try ring.timeout(10, &ts, 0, 0);
    _ = try ring.timeout(20, &ts, 0, 0);

    // Flush and wait for both
    _ = try ring.submit_and_wait(2);

    // Drain both
    var cqes: [4]linux.io_uring_cqe = undefined;
    const count = try ring.copy_cqes(&cqes, 0);
    try std.testing.expect(count >= 2);
}

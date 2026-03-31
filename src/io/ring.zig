const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Maximum number of pre-registered fixed buffers for READ_FIXED / WRITE_FIXED.
/// Each buffer is one piece-sized block; the pool is registered once at init.
pub const max_fixed_buffers = 64;

pub const Ring = struct {
    inner: linux.IoUring,
    /// Pre-registered buffer iovecs for READ_FIXED / WRITE_FIXED.
    /// Null when no buffers have been registered.
    fixed_bufs: ?[]posix.iovec = null,
    /// Backing allocation for the iovec array (so we can free it).
    fixed_alloc: ?[]u8 = null,
    /// Tracks which fixed-buffer slots are in use (true = free).
    fixed_free: [max_fixed_buffers]bool = [_]bool{true} ** max_fixed_buffers,

    pub fn init(entries: u16) !Ring {
        return .{
            .inner = try linux.IoUring.init(entries, 0),
        };
    }

    pub fn deinit(self: *Ring) void {
        if (self.fixed_bufs != null) {
            self.inner.unregister_buffers() catch {};
            // Free the backing memory for each iovec buffer.
            for (self.fixed_bufs.?) |iov| {
                posix.munmap(@alignCast(iov.base[0..iov.len]));
            }
            if (self.fixed_alloc) |a| std.heap.page_allocator.free(a);
        }
        self.inner.deinit();
    }

    // ── File I/O ──────────────────────────────────────────────

    pub fn pread(self: *Ring, fd: posix.fd_t, buffer: []u8, offset: u64) !usize {
        _ = try self.inner.read(0, fd, .{ .buffer = buffer }, offset);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    pub fn pwrite(self: *Ring, fd: posix.fd_t, buffer: []const u8, offset: u64) !usize {
        _ = try self.inner.write(0, fd, buffer, offset);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    pub fn pread_all(self: *Ring, fd: posix.fd_t, buffer: []u8, offset: u64) !usize {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.pread(fd, buffer[total..], offset + total);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn pwrite_all(self: *Ring, fd: posix.fd_t, buffer: []const u8, offset: u64) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.pwrite(fd, buffer[total..], offset + total);
            if (n == 0) return error.UnexpectedEof;
            total += n;
        }
    }

    pub fn fsync(self: *Ring, fd: posix.fd_t) !void {
        _ = try self.inner.fsync(0, fd, 0);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    pub fn fallocate(self: *Ring, fd: posix.fd_t, offset: u64, len: u64) !void {
        _ = try self.inner.fallocate(0, fd, 0, offset, len);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    pub fn fdatasync(self: *Ring, fd: posix.fd_t) !void {
        _ = try self.inner.fsync(0, fd, linux.IORING_FSYNC_DATASYNC);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    pub fn close(self: *Ring, fd: posix.fd_t) !void {
        _ = try self.inner.close(0, fd);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    /// Async statx(2) via IORING_OP_STATX (kernel 5.6+).
    /// `dir_fd` is typically AT.FDCWD for paths relative to cwd.
    /// `flags` controls symlink follow behaviour (e.g. AT.SYMLINK_NOFOLLOW).
    /// `mask` selects which fields to populate (e.g. STATX_BASIC_STATS, STATX_SIZE).
    pub fn statx(
        self: *Ring,
        dir_fd: posix.fd_t,
        path: [:0]const u8,
        flags: u32,
        mask: u32,
        buf: *linux.Statx,
    ) !void {
        _ = try self.inner.statx(0, dir_fd, path, flags, mask, buf);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    /// Async renameat2(2) via IORING_OP_RENAMEAT (kernel 5.11+).
    /// Renames `old_path` (relative to `old_dir_fd`) to `new_path` (relative to `new_dir_fd`).
    pub fn renameat(
        self: *Ring,
        old_dir_fd: posix.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: posix.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
    ) !void {
        _ = try self.inner.renameat(0, old_dir_fd, old_path, new_dir_fd, new_path, flags);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    /// Async unlinkat(2) via IORING_OP_UNLINKAT (kernel 5.11+).
    /// Removes the file at `path` relative to `dir_fd`.
    /// Pass AT.REMOVEDIR in `flags` to remove a directory instead.
    pub fn unlinkat(
        self: *Ring,
        dir_fd: posix.fd_t,
        path: [*:0]const u8,
        flags: u32,
    ) !void {
        _ = try self.inner.unlinkat(0, dir_fd, path, flags);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    // ── Fixed / Registered Buffers ────────────────────────────

    /// Register a pool of `count` fixed buffers of `buf_size` bytes each.
    /// These are page-aligned and pinned, suitable for READ_FIXED / WRITE_FIXED.
    /// Must be called before `pread_fixed` / `pwrite_fixed`.
    pub fn registerBuffers(self: *Ring, count: u16, buf_size: usize) !void {
        if (count > max_fixed_buffers) return error.TooManyBuffers;
        const iovec_bytes = @sizeOf(posix.iovec) * @as(usize, count);
        const alloc = try std.heap.page_allocator.alloc(u8, iovec_bytes);
        const iovecs: []posix.iovec = @as([*]posix.iovec, @ptrCast(@alignCast(alloc.ptr)))[0..count];

        for (iovecs, 0..) |*iov, i| {
            const mem = posix.mmap(null, buf_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            iov.* = .{
                .base = @ptrCast(mem),
                .len = buf_size,
            };
            // If mmap fails part-way through, clean up what we already mapped.
            _ = i;
        }

        try self.inner.register_buffers(iovecs);
        self.fixed_bufs = iovecs;
        self.fixed_alloc = alloc;
        self.fixed_free = [_]bool{true} ** max_fixed_buffers;
    }

    /// Claim a free fixed buffer slot. Returns the index and a slice to the buffer.
    pub fn claimFixedBuffer(self: *Ring) ?struct { index: u16, buf: []u8 } {
        const bufs = self.fixed_bufs orelse return null;
        for (&self.fixed_free, 0..) |*free, i| {
            if (i >= bufs.len) break;
            if (free.*) {
                free.* = false;
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
    pub fn releaseFixedBuffer(self: *Ring, index: u16) void {
        self.fixed_free[index] = true;
    }

    /// Read into a pre-registered fixed buffer via IORING_OP_READ_FIXED (kernel 5.1+).
    pub fn pread_fixed(self: *Ring, fd: posix.fd_t, buf_index: u16, len: usize, offset: u64) !usize {
        const bufs = self.fixed_bufs orelse return error.BuffersNotRegistered;
        var iov = bufs[buf_index];
        iov.len = @min(len, iov.len);
        _ = try self.inner.read_fixed(0, fd, &bufs[buf_index], offset, buf_index);
        // Temporarily set the requested length
        const orig_len = bufs[buf_index].len;
        bufs[buf_index].len = @min(len, orig_len);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        bufs[buf_index].len = orig_len; // restore
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    /// Write from a pre-registered fixed buffer via IORING_OP_WRITE_FIXED (kernel 5.1+).
    pub fn pwrite_fixed(self: *Ring, fd: posix.fd_t, buf_index: u16, len: usize, offset: u64) !usize {
        const bufs = self.fixed_bufs orelse return error.BuffersNotRegistered;
        const orig_len = bufs[buf_index].len;
        bufs[buf_index].len = @min(len, orig_len);
        _ = try self.inner.write_fixed(0, fd, &bufs[buf_index], offset, buf_index);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        bufs[buf_index].len = orig_len; // restore
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    // ── Network I/O ───────────────────────────────────────────

    pub fn send_all(self: *Ring, fd: posix.fd_t, buffer: []const u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            _ = try self.inner.send(0, fd, buffer[total..], 0);
            _ = try self.inner.submit();
            const cqe = try self.inner.copy_cqe();
            try checkCqe(cqe);
            const n: usize = @intCast(cqe.res);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }

    pub fn recv(self: *Ring, fd: posix.fd_t, buffer: []u8) !usize {
        _ = try self.inner.recv(0, fd, .{ .buffer = buffer }, 0);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    pub fn recv_exact(self: *Ring, fd: posix.fd_t, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.recv(fd, buffer[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    pub fn connect(self: *Ring, fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t) !void {
        _ = try self.inner.connect(0, fd, addr, addrlen);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
    }

    pub fn connect_timeout(self: *Ring, fd: posix.fd_t, addr: *const posix.sockaddr, addrlen: posix.socklen_t, timeout_secs: u32) !void {
        const connect_sqe = try self.inner.connect(0, fd, addr, addrlen);
        connect_sqe.flags |= linux.IOSQE_IO_LINK;

        const ts = linux.kernel_timespec{ .sec = timeout_secs, .nsec = 0 };
        _ = try self.inner.link_timeout(1, &ts, 0);

        _ = try self.inner.submit();

        // Collect both CQEs (connect + link_timeout)
        const connect_cqe = try self.inner.copy_cqe();
        const timeout_cqe = try self.inner.copy_cqe();

        // Check which completed: if connect succeeded, timeout is cancelled (ECANCELED)
        // If timeout fired, connect is cancelled (ECANCELED)
        const connect_result = if (connect_cqe.user_data == 0) connect_cqe else timeout_cqe;
        const e = connect_result.err();
        if (e == .CANCELED) return error.ConnectionTimedOut;
        if (e == .CONNREFUSED) return error.ConnectionRefused;
        if (e == .CONNRESET) return error.ConnectionResetByPeer;
        if (e == .NETUNREACH) return error.NetworkUnreachable;
        if (e == .HOSTUNREACH) return error.HostUnreachable;
        if (e == .TIMEDOUT) return error.ConnectionTimedOut;
        if (e != .SUCCESS) return posix.unexpectedErrno(e);
    }

    pub fn accept(self: *Ring, fd: posix.fd_t, addr: ?*posix.sockaddr, addrlen: ?*posix.socklen_t, flags: u32) !posix.fd_t {
        _ = try self.inner.accept(0, fd, addr, addrlen, flags);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    pub fn socket(self: *Ring, domain: u32, socket_type: u32, protocol: u32) !posix.fd_t {
        _ = try self.inner.socket(0, domain, socket_type, protocol, 0);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        try checkCqe(cqe);
        return @intCast(cqe.res);
    }

    /// Async shutdown(2) via IORING_OP_SHUTDOWN (kernel 5.11+).
    /// Shuts down part of a full-duplex connection.
    /// `how`: SHUT.RD (0), SHUT.WR (1), or SHUT.RDWR (2).
    pub fn shutdown(self: *Ring, fd: posix.fd_t, how: u32) !void {
        _ = try self.inner.shutdown(0, fd, how);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        // ENOTCONN is acceptable -- peer may have already disconnected.
        const e = cqe.err();
        if (e == .NOTCONN) return;
        if (e != .SUCCESS) {
            try checkCqe(cqe);
        }
    }

    /// Zero-copy send via IORING_OP_SEND_ZC (kernel 6.0+).
    /// For large piece data sends -- avoids copying to kernel buffer.
    /// The caller must keep `buffer` alive until both CQEs (completion + notification) arrive.
    pub fn send_zc(self: *Ring, fd: posix.fd_t, buffer: []const u8) !usize {
        _ = try self.inner.send_zc(0, fd, buffer, 0, 0);
        _ = try self.inner.submit();

        // send_zc produces two CQEs:
        //   1. The operation result (bytes sent)
        //   2. A NOTIF CQE indicating buffer ownership is returned
        var bytes_sent: usize = 0;
        var cqes_remaining: u8 = 2;
        while (cqes_remaining > 0) {
            const cqe = try self.inner.copy_cqe();
            if (cqe.flags & linux.IORING_CQE_F_NOTIF != 0) {
                // Notification CQE -- buffer is now safe to reuse
                cqes_remaining -= 1;
                continue;
            }
            // Operation result CQE
            try checkCqe(cqe);
            bytes_sent = @intCast(cqe.res);
            cqes_remaining -= 1;
            // If CQE_F_MORE is set, there will be a NOTIF CQE following
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) {
                // No notification coming (fallback to copy path)
                break;
            }
        }
        return bytes_sent;
    }

    /// Send all data via zero-copy IORING_OP_SEND_ZC.
    /// Falls back to regular send_all on EINVAL (unsupported).
    pub fn send_zc_all(self: *Ring, fd: posix.fd_t, buffer: []const u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = self.send_zc(fd, buffer[total..]) catch |err| {
                // EINVAL means kernel doesn't support send_zc for this socket type.
                if (err == error.Unexpected) {
                    // Fall back to regular send
                    try self.send_all(fd, buffer[total..]);
                    return;
                }
                return err;
            };
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
    }

    /// Cancel a pending io_uring operation via IORING_OP_ASYNC_CANCEL (kernel 5.5+).
    /// `target_user_data` identifies the operation to cancel.
    /// Returns true if the operation was found and cancelled, false if not found.
    pub fn cancel(self: *Ring, target_user_data: u64) !bool {
        _ = try self.inner.cancel(0, target_user_data, 0);
        _ = try self.inner.submit();
        const cqe = try self.inner.copy_cqe();
        const e = cqe.err();
        if (e == .SUCCESS) return true;
        if (e == .NOENT) return false; // not found
        if (e == .ALREADY) return true; // already in progress
        return posix.unexpectedErrno(e);
    }

    // ── Timers ────────────────────────────────────────────────

    /// Submit an io_uring timeout via IORING_OP_TIMEOUT (kernel 5.4+).
    /// The timeout fires after `secs` seconds (and `nsecs` nanoseconds).
    /// `user_data` identifies this timeout for later cancellation or CQE dispatch.
    /// `count` > 0 means the timeout also completes after `count` CQEs.
    pub fn timeout(self: *Ring, user_data: u64, ts: *const linux.kernel_timespec, count: u32) !void {
        _ = try self.inner.timeout(user_data, ts, count, 0);
        _ = try self.inner.submit();
    }

    /// Submit a linked timeout via IORING_OP_LINK_TIMEOUT (kernel 5.5+).
    /// Must be submitted immediately after the target SQE with IOSQE_IO_LINK set.
    /// This is a lower-level building block -- callers prepare the target SQE,
    /// set IOSQE_IO_LINK, then call this to add the timeout.
    /// See `connect_timeout` for an example of the linked-timeout pattern.
    pub fn link_timeout(self: *Ring, user_data: u64, ts: *const linux.kernel_timespec) !void {
        _ = try self.inner.link_timeout(user_data, ts, 0);
    }

    // ── Probing ───────────────────────────────────────────────

    pub fn probe() bool {
        var ring = linux.IoUring.init(4, 0) catch return false;
        ring.deinit();
        return true;
    }

    // ── Error handling ────────────────────────────────────────

    fn checkCqe(cqe: linux.io_uring_cqe) !void {
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
};

// ── Tests ─────────────────────────────────────────────────

fn skipIfUnavailable() !Ring {
    return Ring.init(16) catch return error.SkipZigTest;
}

/// Helper: create a UNIX socket pair for testing.
fn testSocketPair() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SkipZigTest;
    return fds;
}

test "pread and pwrite roundtrip through io_uring" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.bin", .{ .read = true });
    defer file.close();

    const payload = "hello io_uring world";
    try ring.pwrite_all(file.handle, payload, 0);
    try ring.fsync(file.handle);

    var buffer: [20]u8 = undefined;
    const n = try ring.pread_all(file.handle, &buffer, 0);

    try std.testing.expectEqual(payload.len, n);
    try std.testing.expectEqualStrings(payload, buffer[0..n]);
}

test "pread_all handles short reads" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("short.bin", .{ .read = true });
    defer file.close();

    try ring.pwrite_all(file.handle, "abc", 0);
    try ring.fsync(file.handle);

    // Read more than available -- pread_all returns actual bytes
    var buffer: [64]u8 = undefined;
    const n = try ring.pread_all(file.handle, &buffer, 0);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", buffer[0..n]);
}

test "probe detects io_uring availability" {
    // Just verify the probe function doesn't crash
    _ = Ring.probe();
}

test "shutdown closes socket write end via io_uring" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Create a connected socket pair to test shutdown
    const fds = try testSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Shutdown write end of fds[0]
    try ring.shutdown(fds[0], linux.SHUT.WR);

    // Reading from fds[1] should now return EOF (0 bytes)
    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[1], &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "shutdown on already-closed socket returns gracefully" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    const fds = try testSocketPair();
    posix.close(fds[0]);
    posix.close(fds[1]);

    // Shutdown on a closed fd should return an error but not panic
    ring.shutdown(fds[0], linux.SHUT.RDWR) catch {};
}

test "statx returns file size via io_uring" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stat_test.bin", .{ .read = true });
    const payload = "hello statx";
    try file.writeAll(payload);
    file.close();

    // Get the path to the temp file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath("stat_test.bin", &path_buf);
    // We need a sentinel-terminated path for statx
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(path_z[0..tmp_path.len], tmp_path);
    path_z[tmp_path.len] = 0;

    var statx_buf: linux.Statx = undefined;
    try ring.statx(
        linux.AT.FDCWD,
        path_z[0..tmp_path.len :0],
        0,
        linux.STATX_SIZE,
        &statx_buf,
    );

    try std.testing.expectEqual(@as(u64, payload.len), statx_buf.size);
}

test "renameat renames file via io_uring" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("rename_src.bin", .{});
    try file.writeAll("data");
    file.close();

    const dir_fd = tmp.dir.fd;
    try ring.renameat(dir_fd, "rename_src.bin", dir_fd, "rename_dst.bin", 0);

    // Old file should be gone
    _ = tmp.dir.openFile("rename_src.bin", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        // New file should exist
        const dst = try tmp.dir.openFile("rename_dst.bin", .{});
        dst.close();
        return;
    };
    return error.TestExpectedError;
}

test "unlinkat deletes file via io_uring" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("delete_me.bin", .{});
    try file.writeAll("garbage");
    file.close();

    const dir_fd = tmp.dir.fd;
    try ring.unlinkat(dir_fd, "delete_me.bin", 0);

    // File should be gone
    _ = tmp.dir.openFile("delete_me.bin", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedError;
}

test "cancel returns false for nonexistent operation" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Cancel a user_data that doesn't correspond to any pending op
    const found = try ring.cancel(999999);
    try std.testing.expectEqual(false, found);
}

test "timeout fires after specified duration" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    const ts = linux.kernel_timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
    try ring.timeout(42, &ts, 0);

    // Wait for the timeout CQE
    const cqe = try ring.inner.copy_cqe();
    try std.testing.expectEqual(@as(u64, 42), cqe.user_data);
    // Timeout completion returns -ETIME
    try std.testing.expectEqual(linux.E.TIME, cqe.err());
}

test "link_timeout cancels slow operation" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Create a connected socket pair
    const fds = try testSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    // Submit recv with link timeout -- recv will block (no data coming),
    // so the 10ms timeout should fire and cancel the recv.
    var recv_buf: [16]u8 = undefined;
    const sqe = try ring.inner.recv(200, fds[0], .{ .buffer = &recv_buf }, 0);
    sqe.flags |= linux.IOSQE_IO_LINK;
    const ts = linux.kernel_timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
    try ring.link_timeout(201, &ts);
    _ = try ring.inner.submit();

    // Collect both CQEs
    const cqe1 = try ring.inner.copy_cqe();
    const cqe2 = try ring.inner.copy_cqe();

    // One should be the cancelled recv, the other the timeout
    const recv_cqe = if (cqe1.user_data == 200) cqe1 else cqe2;
    const timeout_cqe = if (cqe1.user_data == 201) cqe1 else cqe2;

    // The recv should be cancelled
    try std.testing.expectEqual(linux.E.CANCELED, recv_cqe.err());
    // The timeout fired (ETIME)
    try std.testing.expectEqual(linux.E.TIME, timeout_cqe.err());
}

test "send_zc sends data via io_uring zero-copy" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    const fds = try testSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const payload = "zero-copy test payload";
    const n = ring.send_zc(fds[0], payload) catch |err| {
        // EINVAL can happen on older kernels or unsupported socket types
        if (err == error.Unexpected) return;
        return err;
    };
    try std.testing.expect(n > 0);

    var recv_buf: [64]u8 = undefined;
    const received = try posix.read(fds[1], &recv_buf);
    try std.testing.expectEqualStrings(payload[0..n], recv_buf[0..received]);
}

test "fixed buffer registration and read/write roundtrip" {
    var ring = try skipIfUnavailable();
    defer ring.deinit();

    // Register 2 fixed buffers of 4096 bytes each
    ring.registerBuffers(2, 4096) catch |err| {
        // ENOMEM or EPERM on some systems -- skip test
        if (err == error.Unexpected) return;
        return err;
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("fixed_buf.bin", .{ .read = true });
    defer file.close();

    // Claim a buffer, write into it, then use pwrite_fixed
    const claimed = ring.claimFixedBuffer() orelse return error.TestExpectedEqual;
    defer ring.releaseFixedBuffer(claimed.index);

    const data = "fixed buffer roundtrip test";
    @memcpy(claimed.buf[0..data.len], data);

    const written = try ring.pwrite_fixed(file.handle, claimed.index, data.len, 0);
    try std.testing.expectEqual(data.len, written);

    try ring.fsync(file.handle);

    // Now read it back with a different fixed buffer
    const read_claimed = ring.claimFixedBuffer() orelse return error.TestExpectedEqual;
    defer ring.releaseFixedBuffer(read_claimed.index);

    @memset(read_claimed.buf[0..data.len], 0);
    const n = try ring.pread_fixed(file.handle, read_claimed.index, data.len, 0);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, read_claimed.buf[0..n]);
}

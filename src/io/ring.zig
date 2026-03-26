const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Ring = struct {
    inner: linux.IoUring,

    pub fn init(entries: u16) !Ring {
        return .{
            .inner = try linux.IoUring.init(entries, 0),
        };
    }

    pub fn deinit(self: *Ring) void {
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

    // ── Probing ───────────────────────────────────────────────

    pub fn probe() bool {
        var ring = linux.IoUring.init(4, 0) catch return false;
        ring.deinit();
        return true;
    }

    // ── Error handling ────────────────────────────────────────

    fn checkCqe(cqe: linux.io_uring_cqe) !void {
        const e = cqe.err();
        if (e != .SUCCESS) {
            return posix.unexpectedErrno(e);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────

fn skipIfUnavailable() !Ring {
    return Ring.init(16) catch return error.SkipZigTest;
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

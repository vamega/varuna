const std = @import("std");

/// Send a notification message to systemd via the $NOTIFY_SOCKET protocol.
/// This is best-effort: if the socket is not set or sending fails, the
/// function returns silently. Uses standard POSIX socket API (one-time
/// setup, not hot path -- no io_uring needed).
pub fn notify(msg: []const u8) void {
    const raw_path = std.posix.getenv("NOTIFY_SOCKET") orelse return;
    if (raw_path.len == 0) return;

    // Build the socket address. Abstract sockets use a leading '@' in the
    // env var, which maps to a leading NUL byte in sun_path.
    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);

    if (raw_path[0] == '@') {
        // Abstract socket: NUL byte followed by the rest of the name.
        if (raw_path.len - 1 > addr.path.len - 1) return; // name too long
        addr.path[0] = 0;
        @memcpy(addr.path[1..][0 .. raw_path.len - 1], raw_path[1..]);
    } else {
        if (raw_path.len > addr.path.len) return; // path too long
        @memcpy(addr.path[0..raw_path.len], raw_path);
    }

    const fd = std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return;
    defer std.posix.close(fd);

    const addr_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + raw_path.len);
    std.posix.connect(fd, @ptrCast(&addr), addr_len) catch return;

    _ = std.posix.write(fd, msg) catch return;
}

/// Notify systemd that the daemon is ready to serve.
pub fn notifyReady() void {
    notify("READY=1\n");
}

/// Notify systemd that the daemon is beginning shutdown.
pub fn notifyStopping() void {
    notify("STOPPING=1\n");
}

test "notify returns silently when NOTIFY_SOCKET is unset" {
    // Just ensure it doesn't crash or hang when there is no socket.
    // In the test environment $NOTIFY_SOCKET is not set, so this is a no-op.
    notify("READY=1\n");
    notifyReady();
    notifyStopping();
}

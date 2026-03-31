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

// ── Socket activation (sd_listen_fds protocol) ──────────

/// The starting file descriptor for socket activation (SD_LISTEN_FDS_START).
pub const listen_fds_start: std.posix.fd_t = 3;

/// Check for systemd socket activation. Returns a slice of inherited file
/// descriptors if $LISTEN_FDS and $LISTEN_PID indicate that systemd passed
/// sockets to this process. Returns null if socket activation is not active.
///
/// Per sd_listen_fds(3): the fds start at 3 and LISTEN_PID must match getpid().
/// We also unset the environment variables so child processes don't inherit them,
/// and set FD_CLOEXEC on each inherited fd (matching sd_listen_fds behaviour).
pub fn listenFds() ?[]const std.posix.fd_t {
    const pid_str = std.posix.getenv("LISTEN_PID") orelse return null;
    const fds_str = std.posix.getenv("LISTEN_FDS") orelse return null;

    // LISTEN_PID must match our PID
    const expected_pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return null;
    const our_pid = std.os.linux.getpid();
    if (expected_pid != our_pid) return null;

    const count = std.fmt.parseInt(usize, fds_str, 10) catch return null;
    if (count == 0) return null;
    if (count > max_listen_fds) return null;

    // Set FD_CLOEXEC on each inherited fd (systemd clears it before exec)
    for (0..count) |i| {
        const fd: std.posix.fd_t = @intCast(listen_fds_start + @as(std.posix.fd_t, @intCast(i)));
        const flags = std.posix.fcntl(fd, std.posix.F.GETFD, 0) catch continue;
        _ = std.posix.fcntl(fd, std.posix.F.SETFD, flags | std.posix.FD_CLOEXEC) catch {};
    }

    // Store fds in a static buffer so the caller gets a stable slice
    for (0..count) |i| {
        listen_fds_buf[i] = @intCast(listen_fds_start + @as(std.posix.fd_t, @intCast(i)));
    }

    return listen_fds_buf[0..count];
}

const max_listen_fds = 16;
var listen_fds_buf: [max_listen_fds]std.posix.fd_t = undefined;

/// Check if a specific fd from socket activation is a TCP listen socket
/// on the given port. Useful when systemd passes multiple sockets and the
/// daemon needs to identify which one is the API server vs peer listener.
pub fn isListenSocketOnPort(fd: std.posix.fd_t, expected_port: u16) bool {
    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    std.posix.getsockname(fd, &addr, &addr_len) catch return false;

    const address = std.net.Address{ .any = addr };
    return address.getPort() == expected_port;
}

test "notify returns silently when NOTIFY_SOCKET is unset" {
    // Just ensure it doesn't crash or hang when there is no socket.
    // In the test environment $NOTIFY_SOCKET is not set, so this is a no-op.
    notify("READY=1\n");
    notifyReady();
    notifyStopping();
}

test "listenFds returns null when env vars not set" {
    // In the test environment $LISTEN_FDS and $LISTEN_PID are not set
    try std.testing.expect(listenFds() == null);
}

test "isListenSocketOnPort returns false for invalid fd" {
    try std.testing.expect(!isListenSocketOnPort(-1, 8080));
}

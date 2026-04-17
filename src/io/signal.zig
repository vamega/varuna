const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

/// Set the shutdown flag programmatically (e.g., from signalfd dispatch).
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
}

/// Install traditional signal handlers as a fallback (e.g., for CLI tools
/// or if signalfd is not used). For the daemon event loop, prefer
/// createSignalFd() + io_uring POLL_ADD instead.
pub fn installHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(posix.SIG.TERM, &handler, null);
}

/// Create a signalfd for SIGINT and SIGTERM, and block those signals on
/// the calling thread so they are delivered to the signalfd instead of
/// invoking the default handler. Returns the signalfd file descriptor.
///
/// The caller should register this fd with io_uring POLL_ADD. When a
/// signal arrives, the poll CQE fires, and the caller reads the
/// signalfd_siginfo to consume the signal.
pub fn createSignalFd() !posix.fd_t {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, @intCast(posix.SIG.INT));
    linux.sigaddset(&mask, @intCast(posix.SIG.TERM));

    // Block SIGINT/SIGTERM on this thread so they go to the signalfd
    const rc = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    if (rc != 0) return error.SigprocmaskFailed;

    const fd_rc = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    const e = posix.errno(fd_rc);
    if (e != .SUCCESS) return posix.unexpectedErrno(e);
    return @intCast(fd_rc);
}

fn handleSignal(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

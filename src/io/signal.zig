const std = @import("std");
const posix = std.posix;

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub fn installHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(posix.SIG.TERM, &handler, null);
}

fn handleSignal(sig: i32) callconv(.c) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

const std = @import("std");
const posix = std.posix;

/// Apply SO_BINDTODEVICE to a socket. Requires CAP_NET_RAW or root.
/// Returns a descriptive error on EPERM (not root) or ENODEV (bad interface).
pub fn applyBindDevice(fd: posix.fd_t, device: []const u8) !void {
    // SO_BINDTODEVICE expects a null-terminated interface name up to IFNAMSIZ (16) bytes.
    const IFNAMSIZ = 16;
    if (device.len == 0 or device.len >= IFNAMSIZ) return error.InvalidInterfaceName;

    var buf: [IFNAMSIZ]u8 = undefined;
    @memcpy(buf[0..device.len], device);
    buf[device.len] = 0;

    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, buf[0 .. device.len + 1]) catch |err| switch (err) {
        error.PermissionDenied => return error.BindDevicePermissionDenied,
        error.NoDevice => return error.BindDeviceNotFound,
        else => return err,
    };
}

test "applyBindDevice rejects empty name" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const result = applyBindDevice(fd, "");
    try std.testing.expectError(error.InvalidInterfaceName, result);
}

test "applyBindDevice rejects oversized name" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const result = applyBindDevice(fd, "this_name_is_way_too_long_for_ifnamsiz");
    try std.testing.expectError(error.InvalidInterfaceName, result);
}

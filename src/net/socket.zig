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

/// Bind a socket to a specific local IP address (with port 0 for outbound sockets).
pub fn applyBindAddress(fd: posix.fd_t, address_str: []const u8, port: u16) !void {
    const addr = std.net.Address.parseIp4(address_str, port) catch
        std.net.Address.parseIp6(address_str, port) catch
        return error.InvalidBindAddress;

    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.AddressInUse => return error.BindAddressInUse,
        error.AddressNotAvailable => return error.BindAddressNotAvailable,
        else => return err,
    };
}

/// Apply bind_device and bind_address configuration to a socket.
/// Convenience wrapper that applies both options when set.
pub fn applyBindConfig(fd: posix.fd_t, bind_device: ?[]const u8, bind_address: ?[]const u8, port: u16) !void {
    if (bind_device) |device| {
        try applyBindDevice(fd, device);
    }
    if (bind_address) |address| {
        try applyBindAddress(fd, address, port);
    }
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

test "applyBindAddress rejects invalid address" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const result = applyBindAddress(fd, "not-an-ip", 0);
    try std.testing.expectError(error.InvalidBindAddress, result);
}

test "applyBindConfig with null options is no-op" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    try applyBindConfig(fd, null, null, 0);
}

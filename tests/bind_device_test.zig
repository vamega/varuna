const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const socket_util = varuna.net.socket;

// ── SO_BINDTODEVICE tests ───────────────────────────────────────
//
// These tests exercise the bind-device socket option logic in
// src/net/socket.zig.  SO_BINDTODEVICE requires CAP_NET_RAW or root,
// so tests that call setsockopt skip gracefully on EPERM.

// ═══════════════════════════════════════════════════════════════
// 1. Successful bind to loopback device (requires privileges)
// ═══════════════════════════════════════════════════════════════

test "socket binds to loopback device" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    socket_util.applyBindDevice(fd, "lo") catch |err| {
        if (err == error.BindDevicePermissionDenied) return error.SkipZigTest;
        return err;
    };

    // Verify the socket option was actually set by reading it back.
    var buf: [16]u8 = undefined;
    var len: u32 = buf.len;
    const rc = std.os.linux.getsockopt(fd, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, &buf, &len);
    const errno = std.posix.errno(rc);
    if (errno != .SUCCESS) return error.GetSockOptFailed;

    // The kernel returns the device name null-terminated.
    const device_name = std.mem.sliceTo(buf[0..len], 0);
    try std.testing.expectEqualStrings("lo", device_name);
}

// ═══════════════════════════════════════════════════════════════
// 2. Empty bind_device does not set SO_BINDTODEVICE
// ═══════════════════════════════════════════════════════════════

test "socket with empty bind_device does not set SO_BINDTODEVICE" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    // applyBindConfig with null device should be a no-op.
    try socket_util.applyBindConfig(fd, null, null, 0);

    // getsockopt on an unbound socket should return an empty name.
    var buf: [16]u8 = undefined;
    var len: u32 = buf.len;
    const rc = std.os.linux.getsockopt(fd, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, &buf, &len);
    const errno = std.posix.errno(rc);
    if (errno != .SUCCESS) return error.GetSockOptFailed;

    // Kernel returns either length 0 or a single null byte for unbound sockets.
    const device_name = std.mem.sliceTo(buf[0..len], 0);
    try std.testing.expectEqualStrings("", device_name);
}

// ═══════════════════════════════════════════════════════════════
// 3. Oversized device name is rejected
// ═══════════════════════════════════════════════════════════════

test "socket rejects oversized device name" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    // IFNAMSIZ is 16; a name of exactly 16 bytes should be rejected
    // (must be < 16 to leave room for the null terminator).
    const result_exact = socket_util.applyBindDevice(fd, "0123456789abcdef");
    try std.testing.expectError(error.InvalidInterfaceName, result_exact);

    // Clearly oversized name.
    const result_long = socket_util.applyBindDevice(fd, "this_name_is_way_too_long_for_ifnamsiz");
    try std.testing.expectError(error.InvalidInterfaceName, result_long);
}

// ═══════════════════════════════════════════════════════════════
// 4. Empty device name is rejected
// ═══════════════════════════════════════════════════════════════

test "socket rejects empty device name" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const result = socket_util.applyBindDevice(fd, "");
    try std.testing.expectError(error.InvalidInterfaceName, result);
}

// ═══════════════════════════════════════════════════════════════
// 5. applyBindConfig passes device through to applyBindDevice
// ═══════════════════════════════════════════════════════════════

test "applyBindConfig forwards bind_device to setsockopt" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    socket_util.applyBindConfig(fd, "lo", null, 0) catch |err| {
        if (err == error.BindDevicePermissionDenied) return error.SkipZigTest;
        return err;
    };

    // Verify device was bound.
    var buf: [16]u8 = undefined;
    var len: u32 = buf.len;
    const rc = std.os.linux.getsockopt(fd, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, &buf, &len);
    const errno = std.posix.errno(rc);
    if (errno != .SUCCESS) return error.GetSockOptFailed;

    const device_name = std.mem.sliceTo(buf[0..len], 0);
    try std.testing.expectEqualStrings("lo", device_name);
}

// ═══════════════════════════════════════════════════════════════
// 6. Non-existent device returns BindDeviceNotFound
// ═══════════════════════════════════════════════════════════════

test "socket rejects non-existent device" {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);

    const result = socket_util.applyBindDevice(fd, "noexist0");
    if (result) |_| {
        // Unexpected success — should not happen for a bogus interface.
        return error.UnexpectedSuccess;
    } else |err| {
        switch (err) {
            error.BindDevicePermissionDenied => return error.SkipZigTest,
            error.BindDeviceNotFound => {}, // expected
            else => return err,
        }
    }
}

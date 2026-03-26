const std = @import("std");
const posix = std.posix;
const Ring = @import("../io/ring.zig").Ring;

pub const AcceptResult = struct {
    fd: posix.fd_t,
    address: std.net.Address,
};

pub const default_connect_timeout_secs: u32 = 10;

pub fn tcpConnect(ring: *Ring, address: std.net.Address) !posix.fd_t {
    return tcpConnectTimeout(ring, address, default_connect_timeout_secs);
}

pub fn tcpConnectTimeout(ring: *Ring, address: std.net.Address, timeout_secs: u32) !posix.fd_t {
    const fd = try ring.socket(
        address.any.family,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(fd);

    if (timeout_secs > 0) {
        try ring.connect_timeout(fd, &address.any, address.getOsSockLen(), timeout_secs);
    } else {
        try ring.connect(fd, &address.any, address.getOsSockLen());
    }
    return fd;
}

pub fn tcpAccept(ring: *Ring, listen_fd: posix.fd_t) !AcceptResult {
    var addr: posix.sockaddr = undefined;
    var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);

    const fd = try ring.accept(listen_fd, &addr, &addrlen, posix.SOCK.CLOEXEC);
    return .{
        .fd = fd,
        .address = std.net.Address{ .any = addr },
    };
}

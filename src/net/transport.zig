const std = @import("std");
const posix = std.posix;
const Ring = @import("../io/ring.zig").Ring;

pub const AcceptResult = struct {
    fd: posix.fd_t,
    address: std.net.Address,
};

pub fn tcpConnect(ring: *Ring, address: std.net.Address) !posix.fd_t {
    const fd = try ring.socket(
        address.any.family,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(fd);

    try ring.connect(fd, &address.any, address.getOsSockLen());
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

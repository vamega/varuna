const std = @import("std");
const posix = std.posix;

/// Compare two network addresses for equality (IPv4 and IPv6).
/// Checks both address and port. IPv4-mapped IPv6 addresses compare equal
/// to their native IPv4 form.
/// Takes pointers to avoid 128-byte copies in loops (std.net.Address is a large union).
pub fn addressEql(a: *const std.net.Address, b: *const std.net.Address) bool {
    const a_port = addressPort(a) orelse return false;
    const b_port = addressPort(b) orelse return false;
    if (a_port != b_port) return false;

    if (ipv4Bytes(a)) |a4| {
        if (ipv4Bytes(b)) |b4| return std.mem.eql(u8, &a4, &b4);
    }

    if (a.any.family != b.any.family) return false;
    return switch (a.any.family) {
        posix.AF.INET6 => std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr),
        else => false,
    };
}

/// Return true when a tracker peer endpoint is the daemon's own announced
/// listen endpoint. A wildcard bind means "any local interface"; for that
/// case we only suppress loopback/unspecified endpoints with our exact port
/// so a remote peer that happens to use the same port is still accepted.
pub fn isSelfAnnounceEndpoint(bind_address: ?[]const u8, listen_port: u16, candidate: *const std.net.Address) bool {
    const candidate_port = addressPort(candidate) orelse return false;
    if (candidate_port != listen_port) return false;

    const bind = parseBindAddress(bind_address, listen_port) orelse {
        return bind_address == null and (isLoopback(candidate) or isUnspecified(candidate));
    };

    if (isUnspecified(&bind)) {
        return isLoopback(candidate) or isUnspecified(candidate);
    }

    return addressEql(&bind, candidate);
}

pub fn isLoopback(addr: *const std.net.Address) bool {
    if (ipv4Bytes(addr)) |ip| return ip[0] == 127;
    if (addr.any.family != posix.AF.INET6) return false;

    const loopback = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    return std.mem.eql(u8, &addr.in6.sa.addr, &loopback);
}

pub fn isUnspecified(addr: *const std.net.Address) bool {
    if (ipv4Bytes(addr)) |ip| return std.mem.eql(u8, &ip, &[_]u8{ 0, 0, 0, 0 });
    if (addr.any.family != posix.AF.INET6) return false;

    const unspecified = @as([16]u8, @splat(0));
    return std.mem.eql(u8, &addr.in6.sa.addr, &unspecified);
}

fn parseBindAddress(bind_address: ?[]const u8, port: u16) ?std.net.Address {
    const bind_str = bind_address orelse "0.0.0.0";
    if (std.net.Address.parseIp4(bind_str, port)) |addr| return addr else |_| {}
    if (std.net.Address.parseIp6(bind_str, port)) |addr| return addr else |_| {}
    return null;
}

fn addressPort(addr: *const std.net.Address) ?u16 {
    return switch (addr.any.family) {
        posix.AF.INET, posix.AF.INET6 => addr.getPort(),
        else => null,
    };
}

fn ipv4Bytes(addr: *const std.net.Address) ?[4]u8 {
    return switch (addr.any.family) {
        posix.AF.INET => @bitCast(addr.in.sa.addr),
        posix.AF.INET6 => ipv4MappedBytes(addr),
        else => null,
    };
}

fn ipv4MappedBytes(addr: *const std.net.Address) ?[4]u8 {
    if (addr.any.family != posix.AF.INET6) return null;
    const bytes = &addr.in6.sa.addr;
    const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (!std.mem.eql(u8, bytes[0..12], &mapped_prefix)) return null;
    return bytes[12..16].*;
}

test "addressEql treats IPv4-mapped IPv6 as native IPv4" {
    const v4 = try std.net.Address.parseIp4("127.0.0.1", 6881);
    const mapped = try std.net.Address.parseIp6("::ffff:127.0.0.1", 6881);
    const mapped_other_port = try std.net.Address.parseIp6("::ffff:127.0.0.1", 6882);

    try std.testing.expect(addressEql(&v4, &mapped));
    try std.testing.expect(!addressEql(&v4, &mapped_other_port));
}

test "isSelfAnnounceEndpoint skips wildcard-bound loopback on own port only" {
    const own = try std.net.Address.parseIp4("127.0.0.1", 6881);
    const other_port = try std.net.Address.parseIp4("127.0.0.1", 6882);
    const remote_same_port = try std.net.Address.parseIp4("10.0.0.1", 6881);

    try std.testing.expect(isSelfAnnounceEndpoint(null, 6881, &own));
    try std.testing.expect(!isSelfAnnounceEndpoint(null, 6881, &other_port));
    try std.testing.expect(!isSelfAnnounceEndpoint(null, 6881, &remote_same_port));
}

test "isSelfAnnounceEndpoint compares configured bind address with IPv4-mapped peers" {
    const mapped = try std.net.Address.parseIp6("::ffff:127.0.0.1", 6881);
    const remote = try std.net.Address.parseIp4("127.0.0.2", 6881);

    try std.testing.expect(isSelfAnnounceEndpoint("127.0.0.1", 6881, &mapped));
    try std.testing.expect(!isSelfAnnounceEndpoint("127.0.0.1", 6881, &remote));
}

const std = @import("std");
const posix = std.posix;

/// Compare two network addresses for equality (IPv4 and IPv6).
/// Checks both address and port.
pub fn addressEql(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    return switch (a.any.family) {
        posix.AF.INET => a.in.sa.addr == b.in.sa.addr and a.in.sa.port == b.in.sa.port,
        posix.AF.INET6 => std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr) and a.in6.sa.port == b.in6.sa.port,
        else => false,
    };
}

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn order(lhs: Version, rhs: Version) std.math.Order {
        return std.math.order(std.meta.Tuple(&.{ u32, u32, u32 }), .{
            lhs.major,
            lhs.minor,
            lhs.patch,
        }, .{
            rhs.major,
            rhs.minor,
            rhs.patch,
        });
    }
};

pub fn parseRelease(release: []const u8) !Version {
    var parts = std.mem.tokenizeScalar(u8, release, '.');

    const major = try parseComponent(parts.next() orelse return error.InvalidKernelRelease);
    const minor = try parseComponent(parts.next() orelse return error.InvalidKernelRelease);
    const patch = if (parts.next()) |component|
        try parseComponent(component)
    else
        0;

    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

fn parseComponent(component: []const u8) !u32 {
    const digits = component[0..countLeadingDigits(component)];
    if (digits.len == 0) {
        return error.InvalidKernelRelease;
    }

    return std.fmt.parseUnsigned(u32, digits, 10);
}

fn countLeadingDigits(input: []const u8) usize {
    for (input, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte)) {
            return index;
        }
    }

    return input.len;
}

test "parse simple release" {
    const version = try parseRelease("6.8.12");

    try std.testing.expectEqual(6, version.major);
    try std.testing.expectEqual(8, version.minor);
    try std.testing.expectEqual(12, version.patch);
}

test "parse wsl release suffix" {
    const version = try parseRelease("6.6.87.2-microsoft-standard-WSL2");

    try std.testing.expectEqual(6, version.major);
    try std.testing.expectEqual(6, version.minor);
    try std.testing.expectEqual(87, version.patch);
}

test "reject invalid release" {
    try std.testing.expectError(error.InvalidKernelRelease, parseRelease("wsl"));
}

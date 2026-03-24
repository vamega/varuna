const std = @import("std");
const kernel = @import("kernel.zig");

pub const minimum_supported = kernel.Version{
    .major = 6,
    .minor = 6,
    .patch = 0,
};

pub const preferred_supported = kernel.Version{
    .major = 6,
    .minor = 8,
    .patch = 0,
};

pub fn classify(version: kernel.Version) enum {
    unsupported,
    baseline,
    preferred,
} {
    if (version.order(minimum_supported) == .lt) {
        return .unsupported;
    }

    if (version.order(preferred_supported) == .lt) {
        return .baseline;
    }

    return .preferred;
}

test "classify kernel versions against repository policy" {
    try std.testing.expectEqual(.unsupported, classify(.{ .major = 6, .minor = 5, .patch = 19 }));
    try std.testing.expectEqual(.baseline, classify(.{ .major = 6, .minor = 6, .patch = 5 }));
    try std.testing.expectEqual(.preferred, classify(.{ .major = 6, .minor = 8, .patch = 0 }));
}

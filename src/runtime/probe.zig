const std = @import("std");
const kernel = @import("kernel.zig");
const requirements = @import("requirements.zig");

const ring_mod = @import("../io/ring.zig");

pub const Summary = struct {
    release: []const u8,
    build_info: []const u8,
    machine: []const u8,
    kernel_version: kernel.Version,
    support: requirements.SupportLevel,
    is_wsl: bool,
    io_uring_available: bool,

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.release);
        allocator.free(self.build_info);
        allocator.free(self.machine);
    }
};

pub fn ensureSupported(summary: Summary) !void {
    if (summary.support == .unsupported) return error.UnsupportedKernel;
    if (!summary.io_uring_available) return error.IoUringUnavailable;
}

pub fn detectCurrent(allocator: std.mem.Allocator) !Summary {
    const uts = std.posix.uname();
    return fromStrings(
        allocator,
        std.mem.sliceTo(&uts.release, 0),
        std.mem.sliceTo(&uts.version, 0),
        std.mem.sliceTo(&uts.machine, 0),
    );
}

pub fn fromStrings(
    allocator: std.mem.Allocator,
    release: []const u8,
    build_info: []const u8,
    machine: []const u8,
) !Summary {
    const release_copy = try allocator.dupe(u8, release);
    errdefer allocator.free(release_copy);

    const version_copy = try allocator.dupe(u8, build_info);
    errdefer allocator.free(version_copy);

    const machine_copy = try allocator.dupe(u8, machine);
    errdefer allocator.free(machine_copy);

    const parsed = try kernel.parseRelease(release);
    return .{
        .release = release_copy,
        .build_info = version_copy,
        .machine = machine_copy,
        .kernel_version = parsed,
        .support = requirements.classify(parsed),
        .is_wsl = containsInsensitive(release, "microsoft") or containsInsensitive(build_info, "microsoft"),
        .io_uring_available = ring_mod.probe(),
    };
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "classify WSL kernel summary" {
    const summary = try fromStrings(
        std.testing.allocator,
        "6.6.87.2-microsoft-standard-WSL2",
        "#1 SMP PREEMPT_DYNAMIC Microsoft",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), summary.kernel_version.major);
    try std.testing.expectEqual(@as(u32, 6), summary.kernel_version.minor);
    try std.testing.expectEqual(.baseline, summary.support);
    try std.testing.expect(summary.is_wsl);
}

test "classify preferred non WSL kernel summary" {
    const summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(.preferred, summary.support);
    try std.testing.expect(!summary.is_wsl);
}

test "ensureSupported rejects unsupported kernels" {
    const summary = try fromStrings(
        std.testing.allocator,
        "6.5.0-custom",
        "#1 SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnsupportedKernel, ensureSupported(summary));
}

test "ensureSupported rejects missing io_uring" {
    var summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);
    summary.io_uring_available = false;

    try std.testing.expectError(error.IoUringUnavailable, ensureSupported(summary));
}

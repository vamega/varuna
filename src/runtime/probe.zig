const std = @import("std");
const kernel = @import("kernel.zig");
const requirements = @import("requirements.zig");

pub const Summary = struct {
    release: []const u8,
    version_text: []const u8,
    machine: []const u8,
    kernel_version: kernel.Version,
    support: @TypeOf(requirements.classify(requirements.minimum_supported)),
    is_wsl: bool,
};

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
    version_text: []const u8,
    machine: []const u8,
) !Summary {
    const release_copy = try allocator.dupe(u8, release);
    errdefer allocator.free(release_copy);

    const version_copy = try allocator.dupe(u8, version_text);
    errdefer allocator.free(version_copy);

    const machine_copy = try allocator.dupe(u8, machine);
    errdefer allocator.free(machine_copy);

    const parsed = try kernel.parseRelease(release);
    return .{
        .release = release_copy,
        .version_text = version_copy,
        .machine = machine_copy,
        .kernel_version = parsed,
        .support = requirements.classify(parsed),
        .is_wsl = containsInsensitive(release, "microsoft") or containsInsensitive(version_text, "microsoft"),
    };
}

pub fn freeSummary(allocator: std.mem.Allocator, summary: Summary) void {
    allocator.free(summary.release);
    allocator.free(summary.version_text);
    allocator.free(summary.machine);
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
    defer freeSummary(std.testing.allocator, summary);

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
    defer freeSummary(std.testing.allocator, summary);

    try std.testing.expectEqual(.preferred, summary.support);
    try std.testing.expect(!summary.is_wsl);
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config_mod = @import("../config.zig");
const kernel = @import("kernel.zig");
const requirements = @import("requirements.zig");

const ring_mod = @import("../io/ring.zig");
const RuntimeIoBackend = config_mod.RuntimeIoBackend;

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
    if (build_options.io_backend == .sim) return;
    try ensureSupportedForBackend(summary, buildSelectedBackend());
}

pub fn selectRuntimeIoBackend(requested: RuntimeIoBackend, summary: Summary) !RuntimeIoBackend {
    const selected = if (requested == .auto) try defaultBackendForHost(summary) else requested;
    try ensurePlatformSupportsBackend(selected);
    try ensureSupportedForBackend(summary, selected);
    return selected;
}

pub fn ensureSupportedForBackend(summary: Summary, selected: RuntimeIoBackend) !void {
    switch (selected) {
        .auto => unreachable,
        .io_uring => {
            if (summary.support == .unsupported) return error.UnsupportedKernel;
            if (!summary.io_uring_available) return error.IoUringUnavailable;
        },
        .epoll_posix, .epoll_mmap, .kqueue_posix, .kqueue_mmap => {},
    }
}

fn defaultBackendForHost(summary: Summary) !RuntimeIoBackend {
    return switch (builtin.os.tag) {
        .linux => if (summary.support != .unsupported and summary.io_uring_available) .io_uring else .epoll_posix,
        .macos => .kqueue_posix,
        else => error.UnsupportedIoBackend,
    };
}

fn ensurePlatformSupportsBackend(selected: RuntimeIoBackend) !void {
    switch (selected) {
        .auto => unreachable,
        .io_uring, .epoll_posix, .epoll_mmap => {
            if (builtin.os.tag != .linux) return error.UnsupportedIoBackend;
        },
        .kqueue_posix, .kqueue_mmap => {
            if (builtin.os.tag != .macos) return error.UnsupportedIoBackend;
        },
    }
}

fn buildSelectedBackend() RuntimeIoBackend {
    return switch (build_options.io_backend) {
        .io_uring => .io_uring,
        .epoll_posix => .epoll_posix,
        .epoll_mmap => .epoll_mmap,
        .kqueue_posix => .kqueue_posix,
        .kqueue_mmap => .kqueue_mmap,
        .sim => .auto,
    };
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

test "ensureSupported applies kernel floor only to io_uring backend" {
    const summary = try fromStrings(
        std.testing.allocator,
        "6.5.0-custom",
        "#1 SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);

    switch (build_options.io_backend) {
        .io_uring => try std.testing.expectError(error.UnsupportedKernel, ensureSupported(summary)),
        else => try ensureSupported(summary),
    }
}

test "ensureSupported requires io_uring only for io_uring backend" {
    var summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);
    summary.io_uring_available = false;

    switch (build_options.io_backend) {
        .io_uring => try std.testing.expectError(error.IoUringUnavailable, ensureSupported(summary)),
        else => try ensureSupported(summary),
    }
}

test "runtime auto prefers io_uring when available on Linux" {
    var summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);
    summary.io_uring_available = true;

    switch (builtin.os.tag) {
        .linux => try std.testing.expectEqual(RuntimeIoBackend.io_uring, try selectRuntimeIoBackend(.auto, summary)),
        .macos => try std.testing.expectEqual(RuntimeIoBackend.kqueue_posix, try selectRuntimeIoBackend(.auto, summary)),
        else => try std.testing.expectError(error.UnsupportedIoBackend, selectRuntimeIoBackend(.auto, summary)),
    }
}

test "runtime auto falls back to epoll_posix on Linux when io_uring is unavailable" {
    var summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);
    summary.io_uring_available = false;

    switch (builtin.os.tag) {
        .linux => try std.testing.expectEqual(RuntimeIoBackend.epoll_posix, try selectRuntimeIoBackend(.auto, summary)),
        .macos => try std.testing.expectEqual(RuntimeIoBackend.kqueue_posix, try selectRuntimeIoBackend(.auto, summary)),
        else => try std.testing.expectError(error.UnsupportedIoBackend, selectRuntimeIoBackend(.auto, summary)),
    }
}

test "explicit io_uring still requires io_uring support" {
    var summary = try fromStrings(
        std.testing.allocator,
        "6.8.12-generic",
        "#12-Ubuntu SMP",
        "x86_64",
    );
    defer summary.deinit(std.testing.allocator);
    summary.io_uring_available = false;

    switch (builtin.os.tag) {
        .linux => try std.testing.expectError(error.IoUringUnavailable, selectRuntimeIoBackend(.io_uring, summary)),
        else => try std.testing.expectError(error.UnsupportedIoBackend, selectRuntimeIoBackend(.io_uring, summary)),
    }
}

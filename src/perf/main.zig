const std = @import("std");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const workloads = @import("workloads.zig");

var stdout_buffer: [4096]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status != .ok) std.debug.panic("leaked memory in varuna-perf", .{});
    }

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    var config = workloads.Config{};
    var scenario: ?workloads.Scenario = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "list")) {
            try printScenarioList();
            return;
        }
        if (std.mem.startsWith(u8, arg, "--iterations=")) {
            config.iterations = try std.fmt.parseUnsigned(usize, arg["--iterations=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--scale=")) {
            config.scale = try std.fmt.parseUnsigned(usize, arg["--scale=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--peers=")) {
            config.peers = try std.fmt.parseUnsigned(usize, arg["--peers=".len..], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--torrents=")) {
            config.torrents = try std.fmt.parseUnsigned(usize, arg["--torrents=".len..], 10);
            continue;
        }
        scenario = workloads.Scenario.parse(arg) orelse {
            std.debug.print("unknown scenario: {s}\n", .{arg});
            try printScenarioList();
            return error.InvalidArgument;
        };
    }

    if (scenario == null) {
        try printScenarioList();
        return;
    }

    var counting = CountingAllocator.init(gpa.allocator());
    const result = try workloads.run(scenario.?, &counting, config);
    try printResult(result);
}

fn printScenarioList() !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.print("scenarios:\n", .{});
    inline for (std.meta.fields(workloads.Scenario)) |field| {
        try stdout.print("  {s}\n", .{field.name});
    }
    try stdout.flush();
}

fn printResult(result: workloads.Result) !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;
    try stdout.print(
        "scenario={s} iterations={} elapsed_ns={} checksum={} alloc_calls={} resize_calls={} remap_calls={} free_calls={} failed_allocs={} failed_resizes={} failed_remaps={} bytes_allocated={} bytes_freed={} live_bytes={} peak_live_bytes={}\n",
        .{
            result.scenario,
            result.iterations,
            result.elapsed_ns,
            result.checksum,
            result.allocator.alloc_calls,
            result.allocator.resize_calls,
            result.allocator.remap_calls,
            result.allocator.free_calls,
            result.allocator.failed_allocs,
            result.allocator.failed_resizes,
            result.allocator.failed_remaps,
            result.allocator.bytes_allocated,
            result.allocator.bytes_freed,
            result.allocator.live_bytes,
            result.allocator.peak_live_bytes,
        },
    );
    try stdout.flush();
}

const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    varuna.io.signal.installHandlers();
    const cfg = varuna.config.loadDefault(allocator);

    // Check for --help or -h
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("varuna: BitTorrent daemon with io_uring and qBittorrent-compatible API\n\n", .{});
            try stdout.print("usage: varuna [--help] [--config <path>]\n\n", .{});
            try stdout.print("The daemon loads config from varuna.toml (or ~/.config/varuna/config.toml)\n", .{});
            try stdout.print("and exposes an HTTP API on {s}:{}\n\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
            try stdout.print("Use varuna-ctl to control the daemon.\n", .{});
            try stdout.print("Use varuna-tools for standalone operations (inspect, verify, create).\n", .{});
            try stdout.flush();
            return;
        }
    }

    try stdout.print("varuna daemon starting\n", .{});
    try varuna.app.writeStartupBanner(stdout);
    try stdout.print("api: http://{s}:{}\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
    try stdout.flush();

    // TODO: start session manager, HTTP API server on io_uring, torrent event loop
    // For now, just block until SIGINT
    while (!varuna.io.signal.isShutdownRequested()) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try stdout.print("\nshutting down...\n", .{});
    try stdout.flush();
}

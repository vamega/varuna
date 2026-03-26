const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    varuna.io.signal.installHandlers();
    const cfg = varuna.config.loadDefault(allocator);

    try stdout.print("varuna daemon starting\n", .{});
    try stdout.print("api: http://{s}:{}\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
    try stdout.flush();

    // TODO: start session manager, HTTP API server, event loop
    // For now, just block until SIGINT
    while (!varuna.io.signal.isShutdownRequested()) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try stdout.print("\nshutting down...\n", .{});
    try stdout.flush();
}

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

    // Check for --help
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("varuna: BitTorrent daemon with io_uring and qBittorrent-compatible API\n\n", .{});
            try stdout.print("usage: varuna [--help]\n\n", .{});
            try stdout.print("Config: varuna.toml or ~/.config/varuna/config.toml\n", .{});
            try stdout.print("API: http://{s}:{}\n\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
            try stdout.print("Use varuna-ctl to control the daemon.\n", .{});
            try stdout.print("Use varuna-tools for standalone operations.\n", .{});
            try stdout.flush();
            return;
        }
    }

    // Banner
    try stdout.print("varuna daemon starting\n", .{});
    try varuna.app.writeStartupBanner(stdout);
    try stdout.flush();

    // Session manager
    var session_manager = varuna.daemon.session_manager.SessionManager.init(allocator);
    defer session_manager.deinit();

    // API handler
    var api_handler = varuna.rpc.handlers.ApiHandler{
        .session_manager = &session_manager,
    };

    // HTTP API server (all I/O via io_uring)
    var api_server = varuna.rpc.server.ApiServer.init(allocator, cfg.daemon.api_bind, cfg.daemon.api_port) catch |err| {
        try stdout.print("failed to start API server: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return err;
    };
    defer api_server.deinit();

    // Set handler via a closure-like wrapper
    // Since we can't capture api_handler in a fn pointer, we use a global
    api_handler_global = &api_handler;
    api_server.setHandler(globalApiHandler);

    try stdout.print("api: http://{s}:{}\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
    try stdout.print("ready (Ctrl-C to stop)\n", .{});
    try stdout.flush();

    // Submit initial accept
    api_server.submitAccept() catch {};

    // Main loop: poll API server, check for shutdown
    while (!varuna.io.signal.isShutdownRequested()) {
        _ = api_server.poll() catch break;
        // Small sleep to avoid busy-spinning when no CQEs
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try stdout.print("\nshutting down...\n", .{});
    try stdout.flush();
}

// Global state for handler dispatch (Zig fn pointers can't capture state)
var api_handler_global: ?*varuna.rpc.handlers.ApiHandler = null;

fn globalApiHandler(allocator: std.mem.Allocator, request: varuna.rpc.server.Request) varuna.rpc.server.Response {
    if (api_handler_global) |handler| {
        return handler.handle(allocator, request);
    }
    return .{ .status = 500, .body = "{\"error\":\"handler not initialized\"}" };
}

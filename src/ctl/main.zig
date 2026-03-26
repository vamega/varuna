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

    const cfg = varuna.config.loadDefault(allocator);
    const api_port = cfg.daemon.api_port;
    const api_bind = cfg.daemon.api_bind;

    if (args.len <= 1) {
        try stdout.print("varuna-ctl: control the varuna daemon\n\n", .{});
        try stdout.print("usage:\n", .{});
        try stdout.print("  varuna-ctl list                           list all torrents\n", .{});
        try stdout.print("  varuna-ctl add <torrent-file> [--save-path <dir>]  add torrent\n", .{});
        try stdout.print("  varuna-ctl status <hash>                  torrent details\n", .{});
        try stdout.print("  varuna-ctl pause <hash>                   pause torrent\n", .{});
        try stdout.print("  varuna-ctl resume <hash>                  resume torrent\n", .{});
        try stdout.print("  varuna-ctl delete <hash> [--delete-files] delete torrent\n", .{});
        try stdout.print("\ndaemon: http://{s}:{}\n", .{ api_bind, api_port });
        try stdout.flush();
        return;
    }

    // TODO: implement commands by calling daemon HTTP API
    try stdout.print("varuna-ctl: command '", .{});
    try stdout.print("{s}", .{args[1]});
    try stdout.print("' not yet implemented\n", .{});
    try stdout.flush();
}

const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    varuna.io.signal.installHandlers();

    const cfg = varuna.config.loadDefault(allocator);
    varuna.app.run(allocator, args, stdout, cfg) catch |err| {
        if (varuna.io.signal.isShutdownRequested()) {
            try stdout.print("\nshutdown requested, cleaning up...\n", .{});
        } else {
            return err;
        }
    };
    try stdout.flush();
}

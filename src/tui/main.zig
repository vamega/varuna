const std = @import("std");
const tui = @import("varuna_tui");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var state = tui.model.AppState.init();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--snapshot")) {
        const frame = try tui.render.renderFrame(allocator, &state, .{
            .width = 140,
            .height = 38,
            .color = true,
        });
        defer allocator.free(frame);
        var stdout_buffer: [64 * 1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(frame);
        try stdout.flush();
        return;
    }

    try tui.app.run(allocator);
}

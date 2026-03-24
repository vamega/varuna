const std = @import("std");
const runtime = @import("runtime/root.zig");

pub fn writeStartupBanner(writer: *std.Io.Writer) !void {
    try writer.print("varuna bootstrap\n", .{});
    try writer.print("minimum kernel: {}.{}\n", .{
        runtime.requirements.minimum_supported.major,
        runtime.requirements.minimum_supported.minor,
    });
    try writer.print("preferred kernel: {}.{}\n", .{
        runtime.requirements.preferred_supported.major,
        runtime.requirements.preferred_supported.minor,
    });
}

test "startup banner mentions kernel floors" {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);

    var writer = output.writer(std.testing.allocator);
    try writeStartupBanner(&writer.interface);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "6.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "6.8") != null);
}

const std = @import("std");
const runtime = @import("runtime/root.zig");
const torrent = @import("torrent/root.zig");

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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const summary = runtime.probe.detectCurrent(arena.allocator()) catch |err| {
        try writer.print("kernel probe: unavailable ({s})\n", .{@errorName(err)});
        return;
    };

    try writer.print("current kernel: {s} ({s})\n", .{ summary.release, summary.machine });
    try writer.print("kernel support: {s}\n", .{@tagName(summary.support)});
    if (summary.is_wsl) {
        try writer.print("environment: wsl\n", .{});
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    if (args.len <= 1) {
        try writeStartupBanner(writer);
        try writeUsage(writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "download")) {
        if (args.len != 4) {
            return error.InvalidArguments;
        }
        try runDownload(allocator, args[2], args[3], writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "banner")) {
        try writeStartupBanner(writer);
        return;
    }

    return error.UnknownCommand;
}

fn runDownload(
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    target_root: []const u8,
    writer: *std.Io.Writer,
) !void {
    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const peer_id = torrent.peer_id.generate();
    const result = try torrent.client.download(allocator, torrent_bytes, target_root, .{
        .peer_id = peer_id,
        .status_writer = writer,
    });
    const info_hash_hex = std.fmt.bytesToHex(result.info_hash, .lower);

    try writer.print(
        "downloaded {} bytes, reused {} bytes, complete {} bytes across {} pieces, info_hash={s}\n",
        .{
            result.bytes_downloaded,
            result.bytes_reused,
            result.bytes_complete,
            result.piece_count,
            info_hash_hex[0..],
        },
    );
    try writer.flush();
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage:\n" ++
            "  varuna download <torrent-file> <target-root>\n" ++
            "  varuna banner\n",
    );
}

test "startup banner mentions kernel floors" {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);

    var writer = output.writer(std.testing.allocator);
    try writeStartupBanner(&writer.interface);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "6.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "6.8") != null);
}

test "usage shows download command" {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);

    var writer = output.writer(std.testing.allocator);
    try run(std.testing.allocator, &.{ "varuna" }, &writer.interface);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "varuna download") != null);
}

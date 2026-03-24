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
        const options = try parseTransferOptions(args[2..]);
        try runDownload(allocator, options, writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "seed")) {
        const options = try parseTransferOptions(args[2..]);
        try runSeed(allocator, options, writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "inspect")) {
        if (args.len != 3) {
            return error.InvalidArguments;
        }
        try runInspect(allocator, args[2], writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "banner")) {
        try writeStartupBanner(writer);
        return;
    }

    return error.UnknownCommand;
}

const TransferOptions = struct {
    torrent_path: []const u8,
    target_root: []const u8,
    port: u16 = 6881,
};

fn parseTransferOptions(args: []const []const u8) !TransferOptions {
    if (args.len < 2) {
        return error.InvalidArguments;
    }

    var options = TransferOptions{
        .torrent_path = args[0],
        .target_root = args[1],
    };

    var index: usize = 2;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.port = try parsePort(args[index]);
            index += 1;
            continue;
        }

        return error.InvalidArguments;
    }

    return options;
}

fn parsePort(value: []const u8) !u16 {
    const parsed = try std.fmt.parseInt(u32, value, 10);
    if (parsed == 0) {
        return error.InvalidArguments;
    }

    return std.math.cast(u16, parsed) orelse error.InvalidArguments;
}

fn runDownload(
    allocator: std.mem.Allocator,
    options: TransferOptions,
    writer: *std.Io.Writer,
) !void {
    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, options.torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const peer_id = torrent.peer_id.generate();
    const result = try torrent.client.download(allocator, torrent_bytes, options.target_root, .{
        .peer_id = peer_id,
        .port = options.port,
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

fn runSeed(
    allocator: std.mem.Allocator,
    options: TransferOptions,
    writer: *std.Io.Writer,
) !void {
    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, options.torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const peer_id = torrent.peer_id.generate();
    const result = try torrent.client.seed(allocator, torrent_bytes, options.target_root, .{
        .peer_id = peer_id,
        .port = options.port,
        .status_writer = writer,
    });
    const info_hash_hex = std.fmt.bytesToHex(result.info_hash, .lower);

    try writer.print(
        "seeded {} bytes from {} complete bytes across {} pieces, info_hash={s}\n",
        .{
            result.bytes_seeded,
            result.bytes_complete,
            result.piece_count,
            info_hash_hex[0..],
        },
    );
    try writer.flush();
}

fn runInspect(
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    writer: *std.Io.Writer,
) !void {
    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const metainfo = try torrent.metainfo.parse(allocator, torrent_bytes);
    defer torrent.metainfo.freeMetainfo(allocator, metainfo);

    const info_hash_hex = std.fmt.bytesToHex(metainfo.info_hash, .lower);
    try writer.print("name={s}\n", .{metainfo.name});
    try writer.print("info_hash={s}\n", .{info_hash_hex[0..]});
    try writer.print("announce={s}\n", .{metainfo.announce orelse ""});
    try writer.print("piece_length={}\n", .{metainfo.piece_length});
    try writer.print("pieces={}\n", .{metainfo.pieceCount()});
    try writer.print("total_size={}\n", .{metainfo.totalSize()});
    try writer.print("mode={s}\n", .{if (metainfo.isMultiFile()) "multi-file" else "single-file"});
    try writer.flush();
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage:\n" ++
            "  varuna download <torrent-file> <target-root> [--port <port>]\n" ++
            "  varuna seed <torrent-file> <target-root> [--port <port>]\n" ++
            "  varuna inspect <torrent-file>\n" ++
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
    try run(std.testing.allocator, &.{"varuna"}, &writer.interface);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "varuna download") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "varuna seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "varuna inspect") != null);
}

test "parse transfer options accepts explicit port" {
    const options = try parseTransferOptions(&.{ "fixture.torrent", "/tmp/download", "--port", "6882" });

    try std.testing.expectEqualStrings("fixture.torrent", options.torrent_path);
    try std.testing.expectEqualStrings("/tmp/download", options.target_root);
    try std.testing.expectEqual(@as(u16, 6882), options.port);
}

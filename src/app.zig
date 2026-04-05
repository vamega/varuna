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
    try writer.print("io_uring: {s}\n", .{if (summary.io_uring_available) "available" else "unavailable"});
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

    if (std.mem.eql(u8, args[1], "inspect")) {
        if (args.len != 3) {
            return error.InvalidArguments;
        }
        try runInspect(allocator, args[2], writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "verify")) {
        if (args.len < 4) {
            return error.InvalidArguments;
        }
        try runVerify(allocator, args[2], args[3], writer);
        return;
    }

    if (std.mem.eql(u8, args[1], "create")) {
        if (args.len < 4) {
            return error.InvalidArguments;
        }
        try runCreate(allocator, args[2], args[3], if (args.len > 4) args[4] else null, writer);
        return;
    }

    return error.UnknownCommand;
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
    if (metainfo.announce_list.len > 0) {
        for (metainfo.announce_list) |url| {
            try writer.print("announce_url={s}\n", .{url});
        }
    }
    if (metainfo.comment) |comment| {
        try writer.print("comment={s}\n", .{comment});
    }
    try writer.print("piece_length={}\n", .{metainfo.piece_length});
    try writer.print("pieces={}\n", .{try metainfo.pieceCount()});
    try writer.print("total_size={}\n", .{metainfo.totalSize()});
    try writer.print("mode={s}\n", .{if (metainfo.isMultiFile()) "multi-file" else "single-file"});
    if (metainfo.isPrivate()) {
        try writer.print("private=yes\n", .{});
    }
    try writer.flush();
}

fn runCreate(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    announce_url: []const u8,
    output_path: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    const is_dir = blk: {
        var dir = std.fs.cwd().openDir(file_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    const torrent_bytes = if (is_dir)
        try torrent.create.createDirectory(allocator, file_path, .{
            .announce_url = announce_url,
        })
    else
        try torrent.create.createSingleFile(allocator, file_path, .{
            .announce_url = announce_url,
        });
    defer allocator.free(torrent_bytes);

    const dest = output_path orelse blk: {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, std.fs.path.basename(file_path));
        try buf.appendSlice(allocator, ".torrent");
        const owned = try buf.toOwnedSlice(allocator);
        break :blk owned;
    };
    const should_free_dest = output_path == null;
    defer if (should_free_dest) allocator.free(dest);

    try std.fs.cwd().writeFile(.{ .sub_path = dest, .data = torrent_bytes });

    const info_hash = try torrent.info_hash.compute(torrent_bytes);
    const hex = std.fmt.bytesToHex(info_hash, .lower);
    try writer.print("created {s} ({} bytes), info_hash={s}\n", .{ dest, torrent_bytes.len, hex[0..] });
    try writer.flush();
}

fn runVerify(
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    target_root: []const u8,
    writer: *std.Io.Writer,
) !void {
    const Ring = @import("io/ring.zig").Ring;
    var ring = try Ring.init(16);
    defer ring.deinit();

    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const session = try torrent.session.Session.load(allocator, torrent_bytes, target_root);
    defer session.deinit(allocator);

    var store = try @import("storage/root.zig").writer.PieceStore.init(allocator, &session, &ring);
    defer store.deinit();

    var recheck = try @import("storage/root.zig").verify.recheckExistingData(allocator, &session, &store, null);
    defer recheck.deinit(allocator);

    const piece_count = session.pieceCount();
    const pct = if (piece_count > 0) (recheck.complete_pieces.count * 100) / piece_count else 0;

    try writer.print("name={s}\n", .{session.metainfo.name});
    try writer.print("pieces={}/{} ({}%)\n", .{ recheck.complete_pieces.count, piece_count, pct });
    try writer.print("complete={} bytes\n", .{recheck.bytes_complete});
    try writer.print("remaining={} bytes\n", .{session.totalSize() - recheck.bytes_complete});
    if (recheck.complete_pieces.count == piece_count) {
        try writer.print("status=complete\n", .{});
    } else {
        try writer.print("status=incomplete\n", .{});
    }
    try writer.flush();
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "usage:\n" ++
            "  varuna-tools create <file> <announce-url> [output.torrent]\n" ++
            "  varuna-tools inspect <torrent-file>\n" ++
            "  varuna-tools verify <torrent-file> <target-root>\n" ++
            "\n" ++
            "For downloading and seeding, use the varuna daemon with varuna-ctl.\n",
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

test "usage shows offline commands only" {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(std.testing.allocator);

    var writer = output.writer(std.testing.allocator);
    try run(std.testing.allocator, &.{"varuna-tools"}, &writer.interface);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "create") != null);
    // download and seed should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, output.items, "download <torrent") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "seed <torrent") == null);
}

const std = @import("std");
const runtime = @import("runtime/root.zig");
const torrent = @import("torrent/root.zig");

pub fn writeStartupBanner(writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const summary = runtime.probe.detectCurrent(arena.allocator()) catch |err| {
        try writer.print("varuna bootstrap\n", .{});
        try writer.print("minimum kernel: {}.{}\n", .{
            runtime.requirements.minimum_supported.major,
            runtime.requirements.minimum_supported.minor,
        });
        try writer.print("preferred kernel: {}.{}\n", .{
            runtime.requirements.preferred_supported.major,
            runtime.requirements.preferred_supported.minor,
        });
        try writer.print("kernel probe: unavailable ({s})\n", .{@errorName(err)});
        return;
    };

    try writeStartupBannerForSummary(writer, summary);
}

pub fn writeStartupBannerForSummary(
    writer: *std.Io.Writer,
    summary: runtime.probe.Summary,
) !void {
    try writer.print("varuna bootstrap\n", .{});
    try writer.print("minimum kernel: {}.{}\n", .{
        runtime.requirements.minimum_supported.major,
        runtime.requirements.minimum_supported.minor,
    });
    try writer.print("preferred kernel: {}.{}\n", .{
        runtime.requirements.preferred_supported.major,
        runtime.requirements.preferred_supported.minor,
    });

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
        try runCreate(allocator, args[2..], writer);
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
    if (metainfo.info_hash_v2) |v2_hash| {
        const v2_hex = std.fmt.bytesToHex(v2_hash, .lower);
        try writer.print("info_hash_v2={s}\n", .{v2_hex[0..]});
    }
    try writer.print("version={s}\n", .{@tagName(metainfo.version)});
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
    if (metainfo.private) {
        try writer.print("private=yes\n", .{});
    }
    try writer.flush();
}

fn runCreate(
    allocator: std.mem.Allocator,
    sub_args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    var announce_url: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var piece_length: u32 = 0;
    var name: ?[]const u8 = null;
    var private = false;
    var web_seed: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var threads: u32 = 0;
    var hybrid = false;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];

        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--announce")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            announce_url = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            output_path = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--piece-length")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            piece_length = parsePieceLength(sub_args[i]) orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            name = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--private")) {
            private = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--web-seed")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            web_seed = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--comment")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            comment = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            source = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= sub_args.len) return error.InvalidArguments;
            threads = std.fmt.parseInt(u32, sub_args[i], 10) catch return error.InvalidArguments;
            if (threads == 0) return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--hybrid")) {
            hybrid = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_path = arg;
        } else {
            return error.InvalidArguments;
        }
    }

    const file_path = input_path orelse return error.InvalidArguments;
    const announce = announce_url orelse return error.InvalidArguments;

    const options = torrent.create.CreateOptions{
        .announce_url = announce,
        .piece_length = piece_length,
        .name = name,
        .private = private,
        .comment = comment,
        .source = source,
        .web_seed = web_seed,
        .threads = threads,
        .hybrid = hybrid,
    };

    const is_dir = blk: {
        var dir = std.fs.cwd().openDir(file_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    var hash_stats: torrent.create.HashStats = undefined;
    const torrent_bytes = if (is_dir)
        try torrent.create.createDirectory(allocator, file_path, options, &hash_stats)
    else
        try torrent.create.createSingleFile(allocator, file_path, options, &hash_stats);
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

    const info_hash_val = try torrent.info_hash.compute(torrent_bytes);
    const hex = std.fmt.bytesToHex(info_hash_val, .lower);
    try writer.print("created {s} ({} bytes), info_hash={s}\n", .{ dest, torrent_bytes.len, hex[0..] });

    if (hybrid) {
        const v2_hash = try torrent.info_hash.computeV2(torrent_bytes);
        const v2_hex = std.fmt.bytesToHex(v2_hash, .lower);
        try writer.print("info_hash_v2={s}\n", .{v2_hex[0..]});
    }

    // Print hashing speed
    if (hash_stats.elapsed_ns > 0) {
        const elapsed_ms = hash_stats.elapsed_ns / std.time.ns_per_ms;
        const elapsed_s_f: f64 = @as(f64, @floatFromInt(hash_stats.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const mb_f: f64 = @as(f64, @floatFromInt(hash_stats.total_bytes)) / (1024.0 * 1024.0);
        const speed_mb_s: f64 = if (elapsed_s_f > 0) mb_f / elapsed_s_f else 0;

        if (elapsed_ms >= 1000) {
            try writer.print("hashed {} pieces ({d:.0} MB) in {d:.2}s ({d:.0} MB/s, {} threads)\n", .{
                hash_stats.piece_count,
                mb_f,
                elapsed_s_f,
                speed_mb_s,
                hash_stats.thread_count,
            });
        } else {
            try writer.print("hashed {} pieces ({d:.0} MB) in {}ms ({d:.0} MB/s, {} threads)\n", .{
                hash_stats.piece_count,
                mb_f,
                elapsed_ms,
                speed_mb_s,
                hash_stats.thread_count,
            });
        }
    }

    try writer.flush();
}

/// Parse a piece length argument. Accepts either raw byte values (e.g. "262144")
/// or power-of-2 exponents (e.g. "18" for 2^18 = 262144). Values <= 24 are
/// treated as exponents; larger values as raw byte counts.
fn parsePieceLength(s: []const u8) ?u32 {
    const val = std.fmt.parseInt(u64, s, 10) catch return null;
    if (val == 0) return null;
    if (val <= 24) {
        // Treat as power of 2
        const shift: u5 = @intCast(val);
        return @as(u32, 1) << shift;
    }
    return std.math.cast(u32, val);
}

fn runVerify(
    allocator: std.mem.Allocator,
    torrent_path: []const u8,
    target_root: []const u8,
    writer: *std.Io.Writer,
) !void {
    const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, torrent_path, 16 * 1024 * 1024);
    defer allocator.free(torrent_bytes);

    const session = try torrent.session.Session.load(allocator, torrent_bytes, target_root);
    defer session.deinit(allocator);

    var verify_io = try @import("io/real_io.zig").RealIO.init(.{ .entries = 16 });
    defer verify_io.deinit();

    var store = try @import("storage/root.zig").writer.PieceStore.init(allocator, &session, &verify_io);
    defer store.deinit();

    var recheck = try @import("storage/root.zig").verify.recheckExistingData(allocator, &session, &store, &verify_io, null);
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
            "  varuna-tools create [options] <input-path>\n" ++
            "    -a, --announce <url>      Tracker announce URL (required)\n" ++
            "    -o, --output <file>       Output .torrent file (default: <name>.torrent)\n" ++
            "    -l, --piece-length <n>    Piece length in bytes or power of 2 (default: auto)\n" ++
            "    -n, --name <name>         Torrent name (default: basename of input)\n" ++
            "    -p, --private             Mark as private torrent\n" ++
            "    -w, --web-seed <url>      BEP 19 web seed URL\n" ++
            "    -c, --comment <text>      Comment field\n" ++
            "    -s, --source <text>       Source field (private tracker identification)\n" ++
            "    --hybrid                  Create a hybrid v1+v2 torrent (BEP 52)\n" ++
            "\n" ++
            "  varuna-tools inspect <torrent-file>\n" ++
            "  varuna-tools verify <torrent-file> <target-root>\n" ++
            "\n" ++
            "For downloading and seeding, use the varuna daemon with varuna-ctl.\n",
    );
}

test "startup banner mentions kernel floors" {
    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    try writeStartupBanner(&allocating.writer);
    const items = allocating.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, items, "6.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "6.8") != null);
}

test "usage shows offline commands only" {
    var allocating = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating.deinit();
    try run(std.testing.allocator, &.{"varuna-tools"}, &allocating.writer);
    const items = allocating.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, items, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "create") != null);
    // download and seed should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, items, "download <torrent") == null);
    try std.testing.expect(std.mem.indexOf(u8, items, "seed <torrent") == null);
}

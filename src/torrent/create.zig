const std = @import("std");
const Sha1 = @import("../crypto/root.zig").Sha1;

pub const CreateOptions = struct {
    announce_url: []const u8,
    piece_length: u32 = 0, // 0 = auto-select based on total size
    name: ?[]const u8 = null,
    private: bool = false,
    comment: ?[]const u8 = null,
    source: ?[]const u8 = null,
    web_seed: ?[]const u8 = null,
    created_by: []const u8 = "varuna",
    creation_date: ?i64 = null, // unix timestamp; null = use current time
    threads: u32 = 0, // 0 = auto-detect from std.Thread.getCpuCount()
};

pub const HashStats = struct {
    piece_count: usize,
    total_bytes: u64,
    elapsed_ns: u64,
    thread_count: u32,
};

/// Select a piece length automatically based on total content size.
/// Follows mktorrent's heuristic: target ~1500 pieces, clamped to [16KB, 16MB].
fn autoPieceLength(total_size: u64) u32 {
    if (total_size == 0) return 256 * 1024;

    // Target roughly 1500 pieces
    const target_pieces: u64 = 1500;
    const ideal = total_size / target_pieces;

    // Round up to next power of 2
    const min_pl: u32 = 16 * 1024; // 16 KB
    const max_pl: u32 = 16 * 1024 * 1024; // 16 MB

    var pl: u32 = min_pl;
    while (pl < max_pl and @as(u64, pl) < ideal) {
        pl *= 2;
    }
    return pl;
}

/// Create a .torrent file for a single file.
/// Returns the raw bencode bytes of the torrent metainfo.
/// If `hash_stats` is non-null, it is populated with hashing performance data.
pub fn createSingleFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    options: CreateOptions,
    hash_stats: ?*HashStats,
) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    const name = options.name orelse std.fs.path.basename(file_path);
    const piece_length = if (options.piece_length == 0) autoPieceLength(file_size) else options.piece_length;

    // Hash all pieces
    const piece_count = computePieceCount(file_size, piece_length);
    const piece_hashes = try allocator.alloc(u8, piece_count * 20);
    defer allocator.free(piece_hashes);

    const thread_count = resolveThreadCount(options.threads);

    var timer = std.time.Timer.start() catch null;

    if (thread_count <= 1 or piece_count <= 1) {
        // Sequential path: single thread or single piece
        const read_buffer = try allocator.alloc(u8, piece_length);
        defer allocator.free(read_buffer);

        var piece_index: usize = 0;
        while (piece_index < piece_count) : (piece_index += 1) {
            const offset = piece_index * @as(usize, piece_length);
            const remaining = file_size - offset;
            const to_read: usize = @intCast(@min(remaining, piece_length));

            const n = try file.preadAll(read_buffer[0..to_read], offset);
            if (n != to_read) return error.UnexpectedEndOfFile;

            var digest: [20]u8 = undefined;
            Sha1.hash(read_buffer[0..to_read], &digest, .{});
            @memcpy(piece_hashes[piece_index * 20 ..][0..20], &digest);
        }
    } else {
        // Parallel hashing with pread (thread-safe, no shared seek position)
        try hashPiecesParallel(allocator, file, file_size, piece_length, piece_count, thread_count, piece_hashes);
    }

    if (hash_stats) |hs| {
        hs.* = .{
            .piece_count = piece_count,
            .total_bytes = file_size,
            .elapsed_ns = if (timer) |*t| t.read() else 0,
            .thread_count = thread_count,
        };
    }

    // Build bencode — keys must be in lexicographic order
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "d");

    // announce
    try bencodeString(allocator, &output, "announce");
    try bencodeString(allocator, &output, options.announce_url);

    // comment (optional)
    if (options.comment) |comment| {
        try bencodeString(allocator, &output, "comment");
        try bencodeString(allocator, &output, comment);
    }

    // created by
    try bencodeString(allocator, &output, "created by");
    try bencodeString(allocator, &output, options.created_by);

    // creation date
    {
        const ts = options.creation_date orelse std.time.timestamp();
        try bencodeString(allocator, &output, "creation date");
        try output.print(allocator, "i{}e", .{ts});
    }

    // info dict
    try bencodeString(allocator, &output, "info");
    try output.append(allocator, 'd');

    // info.length
    try bencodeString(allocator, &output, "length");
    try output.print(allocator, "i{}e", .{file_size});

    // info.name
    try bencodeString(allocator, &output, "name");
    try bencodeString(allocator, &output, name);

    // info.piece length
    try bencodeString(allocator, &output, "piece length");
    try output.print(allocator, "i{}e", .{piece_length});

    // info.pieces
    try bencodeString(allocator, &output, "pieces");
    try output.print(allocator, "{}:", .{piece_hashes.len});
    try output.appendSlice(allocator, piece_hashes);

    // info.private (optional, only if set)
    if (options.private) {
        try bencodeString(allocator, &output, "private");
        try output.appendSlice(allocator, "i1e");
    }

    // info.source (optional)
    if (options.source) |source| {
        try bencodeString(allocator, &output, "source");
        try bencodeString(allocator, &output, source);
    }

    try output.append(allocator, 'e'); // close info dict

    // url-list (optional, BEP 19)
    if (options.web_seed) |url| {
        try bencodeString(allocator, &output, "url-list");
        try bencodeString(allocator, &output, url);
    }

    try output.append(allocator, 'e'); // close root dict

    return output.toOwnedSlice(allocator);
}

const FileEntry = struct {
    relative_path: []const u8,
    full_path: []const u8,
    size: u64,
};

/// Create a .torrent file for a directory (multi-file torrent).
/// If `hash_stats` is non-null, it is populated with hashing performance data.
///
/// NOTE: Multi-file hashing is currently sequential because pieces can span
/// file boundaries. A future optimization could pre-read into a contiguous
/// buffer and hash pieces in parallel, or use a pipeline where sequential
/// reads feed parallel hashers.
pub fn createDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: CreateOptions,
    hash_stats: ?*HashStats,
) ![]u8 {
    const name = options.name orelse std.fs.path.basename(dir_path);

    // Collect all files
    var files = std.ArrayList(FileEntry).empty;
    defer {
        for (files.items) |entry| {
            allocator.free(entry.relative_path);
            allocator.free(entry.full_path);
        }
        files.deinit(allocator);
    }

    try collectFiles(allocator, dir_path, "", &files);

    // Sort by relative path for deterministic output
    std.mem.sort(FileEntry, files.items, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
        }
    }.lessThan);

    // Compute total size
    var total_size: u64 = 0;
    for (files.items) |entry| {
        total_size += entry.size;
    }
    if (total_size == 0) return error.EmptyDirectory;

    const piece_length = if (options.piece_length == 0) autoPieceLength(total_size) else options.piece_length;

    // Hash all pieces across concatenated files (sequential — see note above)
    const piece_count = computePieceCount(total_size, piece_length);
    const piece_hashes = try allocator.alloc(u8, piece_count * 20);
    defer allocator.free(piece_hashes);

    var timer = std.time.Timer.start() catch null;

    try hashMultiFilePieces(allocator, files.items, piece_length, piece_hashes);

    if (hash_stats) |hs| {
        hs.* = .{
            .piece_count = piece_count,
            .total_bytes = total_size,
            .elapsed_ns = if (timer) |*t| t.read() else 0,
            .thread_count = 1,
        };
    }

    // Build bencode — keys must be in lexicographic order
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "d");

    // announce
    try bencodeString(allocator, &output, "announce");
    try bencodeString(allocator, &output, options.announce_url);

    // comment (optional)
    if (options.comment) |comment| {
        try bencodeString(allocator, &output, "comment");
        try bencodeString(allocator, &output, comment);
    }

    // created by
    try bencodeString(allocator, &output, "created by");
    try bencodeString(allocator, &output, options.created_by);

    // creation date
    {
        const ts = options.creation_date orelse std.time.timestamp();
        try bencodeString(allocator, &output, "creation date");
        try output.print(allocator, "i{}e", .{ts});
    }

    // info dict
    try bencodeString(allocator, &output, "info");
    try output.append(allocator, 'd');

    // info.files list
    try bencodeString(allocator, &output, "files");
    try output.append(allocator, 'l');
    for (files.items) |entry| {
        try output.append(allocator, 'd');
        try bencodeString(allocator, &output, "length");
        try output.print(allocator, "i{}e", .{entry.size});
        try bencodeString(allocator, &output, "path");
        try output.append(allocator, 'l');
        // Split relative path into components
        var iter = std.mem.splitScalar(u8, entry.relative_path, std.fs.path.sep);
        while (iter.next()) |component| {
            try bencodeString(allocator, &output, component);
        }
        try output.appendSlice(allocator, "ee"); // close path list and file dict
    }
    try output.append(allocator, 'e'); // close files list

    // info.name
    try bencodeString(allocator, &output, "name");
    try bencodeString(allocator, &output, name);

    // info.piece length
    try bencodeString(allocator, &output, "piece length");
    try output.print(allocator, "i{}e", .{piece_length});

    // info.pieces
    try bencodeString(allocator, &output, "pieces");
    try output.print(allocator, "{}:", .{piece_hashes.len});
    try output.appendSlice(allocator, piece_hashes);

    // info.private (optional)
    if (options.private) {
        try bencodeString(allocator, &output, "private");
        try output.appendSlice(allocator, "i1e");
    }

    // info.source (optional)
    if (options.source) |source| {
        try bencodeString(allocator, &output, "source");
        try bencodeString(allocator, &output, source);
    }

    try output.append(allocator, 'e'); // close info dict

    // url-list (optional, BEP 19)
    if (options.web_seed) |url| {
        try bencodeString(allocator, &output, "url-list");
        try bencodeString(allocator, &output, url);
    }

    try output.append(allocator, 'e'); // close root dict
    return output.toOwnedSlice(allocator);
}

fn resolveThreadCount(requested: u32) u32 {
    if (requested != 0) return requested;
    return @intCast(std.Thread.getCpuCount() catch 1);
}

const HashWorkerContext = struct {
    file_handle: std.posix.fd_t,
    file_size: u64,
    piece_length: u32,
    piece_count: usize,
    piece_hashes: []u8,
    next_piece: std.atomic.Value(usize),
    error_flag: std.atomic.Value(bool),
};

fn hashPiecesParallel(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_size: u64,
    piece_length: u32,
    piece_count: usize,
    thread_count: u32,
    piece_hashes: []u8,
) !void {
    // Cap threads to piece count
    const actual_threads: u32 = @intCast(@min(thread_count, piece_count));

    var ctx = HashWorkerContext{
        .file_handle = file.handle,
        .file_size = file_size,
        .piece_length = piece_length,
        .piece_count = piece_count,
        .piece_hashes = piece_hashes,
        .next_piece = std.atomic.Value(usize).init(0),
        .error_flag = std.atomic.Value(bool).init(false),
    };

    // Spawn worker threads (main thread does not participate — keeps logic simple)
    const threads = try allocator.alloc(std.Thread, actual_threads);
    defer allocator.free(threads);

    // Each worker needs its own read buffer
    const buffers = try allocator.alloc([]u8, actual_threads);
    defer allocator.free(buffers);

    var spawned: u32 = 0;
    errdefer {
        // Signal remaining workers to stop, then join what we spawned
        ctx.error_flag.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
        for (buffers[0..spawned]) |buf| allocator.free(buf);
    }

    for (0..actual_threads) |i| {
        buffers[i] = try allocator.alloc(u8, piece_length);
        threads[i] = try std.Thread.spawn(.{}, hashWorkerFn, .{ &ctx, buffers[i] });
        spawned += 1;
    }

    // Join all workers
    for (threads[0..spawned]) |t| t.join();
    for (buffers[0..spawned]) |buf| allocator.free(buf);

    if (ctx.error_flag.load(.acquire)) return error.HashWorkerFailed;
}

fn hashWorkerFn(ctx: *HashWorkerContext, read_buffer: []u8) void {
    // Wrap the raw fd into a File so we can use preadAll (handles partial reads).
    const file = std.fs.File{ .handle = ctx.file_handle };

    while (true) {
        if (ctx.error_flag.load(.acquire)) return;

        const piece_index = ctx.next_piece.fetchAdd(1, .monotonic);
        if (piece_index >= ctx.piece_count) return;

        const offset: u64 = @as(u64, piece_index) * @as(u64, ctx.piece_length);
        const remaining = ctx.file_size - offset;
        const to_read: usize = @intCast(@min(remaining, ctx.piece_length));

        // preadAll is thread-safe: each call specifies its own offset, no shared seek.
        const n = file.preadAll(read_buffer[0..to_read], offset) catch {
            ctx.error_flag.store(true, .release);
            return;
        };
        if (n != to_read) {
            ctx.error_flag.store(true, .release);
            return;
        }

        var digest: [20]u8 = undefined;
        Sha1.hash(read_buffer[0..to_read], &digest, .{});
        // Each piece_index writes to a disjoint 20-byte slot — no synchronization needed.
        @memcpy(ctx.piece_hashes[piece_index * 20 ..][0..20], &digest);
    }
}

/// Encode a string as a bencode byte string (length-prefixed).
fn bencodeString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), s: []const u8) !void {
    try output.print(allocator, "{}:", .{s.len});
    try output.appendSlice(allocator, s);
}

fn collectFiles(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    prefix: []const u8,
    files: *std.ArrayList(FileEntry),
) !void {
    var dir = try std.fs.cwd().openDir(base_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fs.path.join(allocator, &.{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(rel);

        const full = try std.fs.path.join(allocator, &.{ base_path, entry.name });
        errdefer allocator.free(full);

        switch (entry.kind) {
            .file => {
                const stat = try std.fs.cwd().statFile(full);
                try files.append(allocator, .{
                    .relative_path = rel,
                    .full_path = full,
                    .size = stat.size,
                });
            },
            .directory => {
                defer allocator.free(full);
                try collectFiles(allocator, full, rel, files);
                allocator.free(rel);
            },
            else => {
                allocator.free(rel);
                allocator.free(full);
            },
        }
    }
}

fn hashMultiFilePieces(
    allocator: std.mem.Allocator,
    files: []const FileEntry,
    piece_length: u32,
    piece_hashes: []u8,
) !void {
    const read_buffer = try allocator.alloc(u8, piece_length);
    defer allocator.free(read_buffer);

    var hasher = Sha1.init(.{});
    var piece_index: usize = 0;
    var bytes_in_piece: usize = 0;

    for (files) |entry| {
        const file = try std.fs.cwd().openFile(entry.full_path, .{});
        defer file.close();

        var file_offset: u64 = 0;
        while (file_offset < entry.size) {
            const remaining_in_piece = @as(usize, piece_length) - bytes_in_piece;
            const remaining_in_file: usize = @intCast(entry.size - file_offset);
            const to_read = @min(remaining_in_piece, remaining_in_file);

            const n = try file.preadAll(read_buffer[0..to_read], file_offset);
            if (n != to_read) return error.UnexpectedEndOfFile;

            hasher.update(read_buffer[0..to_read]);
            bytes_in_piece += to_read;
            file_offset += to_read;

            if (bytes_in_piece == piece_length) {
                hasher.final(piece_hashes[piece_index * 20 ..][0..20]);
                hasher = Sha1.init(.{});
                piece_index += 1;
                bytes_in_piece = 0;
            }
        }
    }

    // Final partial piece
    if (bytes_in_piece > 0) {
        hasher.final(piece_hashes[piece_index * 20 ..][0..20]);
    }
}

fn computePieceCount(file_size: u64, piece_length: u32) usize {
    return @intCast((file_size + @as(u64, piece_length) - 1) / @as(u64, piece_length));
}

test "create single file torrent and parse it back" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test file
    {
        const file = try tmp.dir.createFile("test.bin", .{});
        defer file.close();
        try file.writeAll("hello world test data for torrent creation");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 16,
        .creation_date = 1700000000,
    }, null);
    defer allocator.free(torrent_bytes);

    // Parse it back
    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expectEqualStrings("test.bin", info.name);
    try std.testing.expectEqualStrings("http://tracker.example/announce", info.announce.?);
    try std.testing.expectEqual(@as(u32, 16), info.piece_length);
    try std.testing.expectEqual(@as(u64, 43), info.totalSize());
    try std.testing.expectEqual(@as(u32, 3), try info.pieceCount());
    try std.testing.expectEqualStrings("varuna", info.created_by.?);
    try std.testing.expectEqual(@as(i64, 1700000000), info.creation_date.?);
}

test "create multi-file torrent from directory" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test directory with files
    try tmp.dir.makePath("mydir/subdir");
    {
        const f = try tmp.dir.createFile("mydir/file_a.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }
    {
        const f = try tmp.dir.createFile("mydir/subdir/file_b.txt", .{});
        defer f.close();
        try f.writeAll("world!!");
    }

    const dir_path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "mydir",
    });
    defer allocator.free(dir_path);

    const torrent_bytes = try createDirectory(allocator, dir_path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 8,
        .creation_date = 1700000000,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expectEqualStrings("mydir", info.name);
    try std.testing.expect(info.isMultiFile());
    try std.testing.expectEqual(@as(usize, 2), info.files.len);
    try std.testing.expectEqual(@as(u64, 12), info.totalSize());
    try std.testing.expectEqual(@as(u32, 2), try info.pieceCount());
}

test "create torrent with private and source" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("test.bin", .{});
        defer file.close();
        try file.writeAll("private tracker content");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.private/announce",
        .piece_length = 256 * 1024,
        .private = true,
        .source = "PTP",
        .comment = "Test torrent",
        .creation_date = 1700000000,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expect(info.private);
    try std.testing.expectEqualStrings("Test torrent", info.comment.?);
}

test "create torrent with web seed" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("test.bin", .{});
        defer file.close();
        try file.writeAll("web seed content");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 256 * 1024,
        .web_seed = "http://example.com/files/test.bin",
        .creation_date = 1700000000,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo.parse(allocator, torrent_bytes);
    defer metainfo.freeMetainfo(allocator, info);

    try std.testing.expectEqual(@as(usize, 1), info.url_list.len);
    try std.testing.expectEqualStrings("http://example.com/files/test.bin", info.url_list[0]);
}

test "parallel hashing produces same result as sequential" {
    const allocator = std.testing.allocator;
    const metainfo = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test file with enough data for multiple pieces
    {
        const file = try tmp.dir.createFile("test_parallel.bin", .{});
        defer file.close();
        // Write 1024 bytes — with piece_length=64 that gives 16 pieces
        var buf: [1024]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);
        try file.writeAll(&buf);
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test_parallel.bin",
    });
    defer allocator.free(path);

    // Hash sequentially (1 thread)
    var stats_seq: HashStats = undefined;
    const seq_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 64,
        .creation_date = 1700000000,
        .threads = 1,
    }, &stats_seq);
    defer allocator.free(seq_bytes);

    // Hash in parallel (4 threads)
    var stats_par: HashStats = undefined;
    const par_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 64,
        .creation_date = 1700000000,
        .threads = 4,
    }, &stats_par);
    defer allocator.free(par_bytes);

    // The torrent files must be identical (same piece hashes, same bencode)
    try std.testing.expectEqualSlices(u8, seq_bytes, par_bytes);
    try std.testing.expectEqual(@as(usize, 16), stats_seq.piece_count);
    try std.testing.expectEqual(@as(usize, 16), stats_par.piece_count);
    try std.testing.expectEqual(@as(u32, 1), stats_seq.thread_count);
    try std.testing.expectEqual(@as(u32, 4), stats_par.thread_count);

    // Both should parse back to the same metainfo
    const info_seq = try metainfo.parse(allocator, seq_bytes);
    defer metainfo.freeMetainfo(allocator, info_seq);
    const info_par = try metainfo.parse(allocator, par_bytes);
    defer metainfo.freeMetainfo(allocator, info_par);

    try std.testing.expectEqual(info_seq.totalSize(), info_par.totalSize());
    try std.testing.expectEqual(try info_seq.pieceCount(), try info_par.pieceCount());
}

test "auto piece length selection" {
    // Small files should get small piece lengths
    try std.testing.expect(autoPieceLength(1024) >= 16 * 1024);

    // Medium files (~100 MB) should get ~64 KB pieces
    const medium = autoPieceLength(100 * 1024 * 1024);
    try std.testing.expect(medium >= 64 * 1024);
    try std.testing.expect(medium <= 256 * 1024);

    // Large files (~10 GB) should get larger pieces
    const large = autoPieceLength(10 * 1024 * 1024 * 1024);
    try std.testing.expect(large >= 4 * 1024 * 1024);

    // Zero-size fallback
    try std.testing.expectEqual(@as(u32, 256 * 1024), autoPieceLength(0));
}

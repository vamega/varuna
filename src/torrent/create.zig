const std = @import("std");
const Sha1 = @import("../crypto/root.zig").Sha1;
const Sha256 = @import("../crypto/root.zig").Sha256;
const merkle = @import("merkle.zig");

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
    hybrid: bool = false, // create a hybrid v1+v2 torrent (BEP 52)
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

    // Validate piece length for hybrid mode
    if (options.hybrid) try validateHybridPieceLength(piece_length);

    // Hash all pieces (SHA-1 for v1)
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

    // Compute v2 Merkle root and piece layers if hybrid
    var pieces_root: [32]u8 = undefined;
    var piece_layer_entry: ?PieceLayerEntry = null;
    defer if (piece_layer_entry) |ple| allocator.free(ple.layer_data);

    if (options.hybrid) {
        // Re-open file for SHA-256 hashing (separate read pass)
        const file2 = try std.fs.cwd().openFile(file_path, .{});
        defer file2.close();
        pieces_root = try computeFileMerkleRoot(allocator, file2, file_size, piece_length);

        // Compute piece layers (only needed for files with >= 2 pieces)
        const file3 = try std.fs.cwd().openFile(file_path, .{});
        defer file3.close();
        piece_layer_entry = try computePieceLayers(allocator, file3, file_size, piece_length);
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

    // info.file tree (hybrid only, before "length" in sorted order)
    if (options.hybrid) {
        try emitFileTreeSingle(allocator, &output, name, file_size, pieces_root);
    }

    // info.length
    try bencodeString(allocator, &output, "length");
    try output.print(allocator, "i{}e", .{file_size});

    // info.meta version (hybrid only, after "length" in sorted order)
    if (options.hybrid) {
        try bencodeString(allocator, &output, "meta version");
        try output.appendSlice(allocator, "i2e");
    }

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

    // piece layers (hybrid only, top-level key after "info")
    if (options.hybrid) {
        if (piece_layer_entry) |ple| {
            const entries = [_]PieceLayerEntry{ple};
            try emitPieceLayers(allocator, &output, &entries);
        }
    }

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

    // Validate piece length for hybrid mode
    if (options.hybrid) try validateHybridPieceLength(piece_length);

    // Hash all pieces across concatenated files (sequential — see note above)
    const piece_count = computePieceCount(total_size, piece_length);
    const piece_hashes = try allocator.alloc(u8, piece_count * 20);
    defer allocator.free(piece_hashes);

    var timer = std.time.Timer.start() catch null;

    try hashMultiFilePieces(allocator, files.items, piece_length, piece_hashes);

    // Compute v2 per-file Merkle roots and piece layers if hybrid
    var v2_infos: ?[]V2FileInfo = null;
    defer if (v2_infos) |infos| allocator.free(infos);

    var piece_layer_entries = std.ArrayList(PieceLayerEntry).empty;
    defer {
        for (piece_layer_entries.items) |ple| allocator.free(ple.layer_data);
        piece_layer_entries.deinit(allocator);
    }

    if (options.hybrid) {
        v2_infos = try computeMultiFileMerkleRoots(allocator, files.items, piece_length);

        // Compute piece layers for each file
        for (files.items) |entry| {
            if (entry.size == 0) continue;
            const file = try std.fs.cwd().openFile(entry.full_path, .{});
            defer file.close();
            if (try computePieceLayers(allocator, file, entry.size, piece_length)) |ple| {
                try piece_layer_entries.append(allocator, ple);
            }
        }
    }

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

    // info.file tree (hybrid only, before "files" in sorted order)
    if (options.hybrid) {
        try emitFileTreeMulti(allocator, &output, files.items, v2_infos.?);
    }

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

    // info.meta version (hybrid only, after "files" in sorted order)
    if (options.hybrid) {
        try bencodeString(allocator, &output, "meta version");
        try output.appendSlice(allocator, "i2e");
    }

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

    // piece layers (hybrid only, top-level key after "info")
    if (options.hybrid) {
        if (piece_layer_entries.items.len > 0) {
            try emitPieceLayers(allocator, &output, piece_layer_entries.items);
        }
    }

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

/// Validate that the piece length is suitable for BEP 52 hybrid torrents.
/// BEP 52 requires piece length to be a power of 2 and >= 16 KiB.
fn validateHybridPieceLength(piece_length: u32) !void {
    if (piece_length < 16 * 1024) return error.HybridPieceLengthTooSmall;
    if (piece_length & (piece_length - 1) != 0) return error.HybridPieceLengthNotPowerOf2;
}

/// Compute SHA-256 piece hashes for a single file and build the Merkle root.
/// Returns the 32-byte Merkle root hash.
fn computeFileMerkleRoot(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_size: u64,
    piece_length: u32,
) ![32]u8 {
    if (file_size == 0) return [_]u8{0} ** 32;

    const piece_count = computePieceCount(file_size, piece_length);
    const piece_hashes = try allocator.alloc([32]u8, piece_count);
    defer allocator.free(piece_hashes);

    const read_buffer = try allocator.alloc(u8, piece_length);
    defer allocator.free(read_buffer);

    var piece_index: usize = 0;
    while (piece_index < piece_count) : (piece_index += 1) {
        const offset = piece_index * @as(usize, piece_length);
        const remaining = file_size - offset;
        const to_read: usize = @intCast(@min(remaining, piece_length));

        const n = try file.preadAll(read_buffer[0..to_read], offset);
        if (n != to_read) return error.UnexpectedEndOfFile;

        // BEP 52: if the last piece is smaller than piece_length, we pad it
        // with zeros before hashing. Actually, per BEP 52, the leaf hash is
        // SHA-256 of the actual data (no padding for the last piece).
        Sha256.hash(read_buffer[0..to_read], &piece_hashes[piece_index], .{});
    }

    // Build Merkle tree and return root
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, piece_hashes);
    defer tree.deinit();
    return tree.root();
}

/// Per-file v2 metadata computed during hybrid torrent creation.
const V2FileInfo = struct {
    pieces_root: [32]u8,
    file_size: u64,
};

/// Compute SHA-256 piece hashes for each file in a multi-file torrent and
/// build the per-file Merkle roots. Also returns concatenated piece layer data
/// for the `piece layers` dict.
fn computeMultiFileMerkleRoots(
    allocator: std.mem.Allocator,
    files: []const FileEntry,
    piece_length: u32,
) ![]V2FileInfo {
    const v2_infos = try allocator.alloc(V2FileInfo, files.len);
    errdefer allocator.free(v2_infos);

    for (files, 0..) |entry, i| {
        if (entry.size == 0) {
            v2_infos[i] = .{
                .pieces_root = [_]u8{0} ** 32,
                .file_size = 0,
            };
            continue;
        }

        const file = try std.fs.cwd().openFile(entry.full_path, .{});
        defer file.close();

        v2_infos[i] = .{
            .pieces_root = try computeFileMerkleRoot(allocator, file, entry.size, piece_length),
            .file_size = entry.size,
        };
    }

    return v2_infos;
}

/// Compute per-file piece layer data for the `piece layers` dictionary.
/// Returns a list of (pieces_root, concatenated_sha256_hashes) pairs.
/// Files with <= 1 piece are excluded from piece layers (their root IS the piece hash).
const PieceLayerEntry = struct {
    pieces_root: [32]u8,
    layer_data: []u8,
};

fn computePieceLayers(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_size: u64,
    piece_length: u32,
) !?PieceLayerEntry {
    if (file_size == 0) return null;

    const piece_count = computePieceCount(file_size, piece_length);
    const piece_hashes = try allocator.alloc([32]u8, piece_count);
    defer allocator.free(piece_hashes);

    const read_buffer = try allocator.alloc(u8, piece_length);
    defer allocator.free(read_buffer);

    var piece_index: usize = 0;
    while (piece_index < piece_count) : (piece_index += 1) {
        const offset = piece_index * @as(usize, piece_length);
        const remaining = file_size - offset;
        const to_read: usize = @intCast(@min(remaining, piece_length));

        const n = try file.preadAll(read_buffer[0..to_read], offset);
        if (n != to_read) return error.UnexpectedEndOfFile;

        Sha256.hash(read_buffer[0..to_read], &piece_hashes[piece_index], .{});
    }

    // Build Merkle tree
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, piece_hashes);
    defer tree.deinit();

    const root_hash = tree.root();

    // Files with only one piece don't need a piece layer entry
    if (piece_count < 2) return null;

    // Concatenate piece hashes as the layer data
    const layer_data = try allocator.alloc(u8, piece_count * 32);
    for (piece_hashes, 0..) |h, idx| {
        @memcpy(layer_data[idx * 32 ..][0..32], &h);
    }

    return .{
        .pieces_root = root_hash,
        .layer_data = layer_data,
    };
}

/// Emit a BEP 52 `file tree` dictionary for a single file.
/// Structure: { filename: { "": { "length": N, "pieces root": <32 bytes> } } }
fn emitFileTreeSingle(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    name: []const u8,
    file_size: u64,
    pieces_root: [32]u8,
) !void {
    try bencodeString(allocator, output, "file tree");
    try output.append(allocator, 'd');
    // filename key
    try bencodeString(allocator, output, name);
    try output.append(allocator, 'd');
    // empty string key (file leaf marker)
    try bencodeString(allocator, output, "");
    try output.append(allocator, 'd');
    // length
    try bencodeString(allocator, output, "length");
    try output.print(allocator, "i{}e", .{file_size});
    // pieces root (only for non-zero files)
    if (file_size > 0) {
        try bencodeString(allocator, output, "pieces root");
        try output.print(allocator, "32:", .{});
        try output.appendSlice(allocator, &pieces_root);
    }
    try output.append(allocator, 'e'); // close leaf dict
    try output.append(allocator, 'e'); // close filename dict
    try output.append(allocator, 'e'); // close file tree dict
}

/// Emit a BEP 52 `file tree` dictionary for multiple files.
/// Files must be sorted by relative_path for deterministic output.
/// Structure:
///   { dir1: { file1: { "": { length: N, pieces root: <hash> } }, ... }, ... }
///
/// Since files are pre-sorted by path, we can emit the nested bencode structure
/// directly by tracking open directory dicts via a path component stack and
/// closing/opening as we transition between files.
fn emitFileTreeMulti(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    files: []const FileEntry,
    v2_infos: []const V2FileInfo,
) !void {
    // Split each file path into components upfront
    const PathComponents = struct {
        components: [][]const u8,
    };
    const all_components = try allocator.alloc(PathComponents, files.len);
    defer {
        for (all_components) |pc| allocator.free(pc.components);
        allocator.free(all_components);
    }

    for (files, 0..) |entry, i| {
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(allocator);
        var iter = std.mem.splitScalar(u8, entry.relative_path, std.fs.path.sep);
        while (iter.next()) |component| {
            try parts.append(allocator, component);
        }
        all_components[i] = .{ .components = try parts.toOwnedSlice(allocator) };
    }

    try bencodeString(allocator, output, "file tree");
    try output.append(allocator, 'd');

    // Track how many directory levels are currently open
    var open_depth: usize = 0;
    // Track the current open path components
    var current_path = std.ArrayList([]const u8).empty;
    defer current_path.deinit(allocator);

    for (files, 0..) |_, i| {
        const components = all_components[i].components;
        // components = [dir1, dir2, ..., filename]
        // directory components are all but the last
        const dir_depth = components.len - 1;

        // Find the common prefix between current open path and this file's directory path
        const common = blk: {
            const min_len = @min(current_path.items.len, dir_depth);
            var j: usize = 0;
            while (j < min_len) : (j += 1) {
                if (!std.mem.eql(u8, current_path.items[j], components[j])) break;
            }
            break :blk j;
        };

        // Close directories that are no longer shared
        while (open_depth > common) {
            try output.append(allocator, 'e'); // close dir dict
            open_depth -= 1;
            _ = current_path.pop();
        }

        // Open new directories
        while (open_depth < dir_depth) {
            try bencodeString(allocator, output, components[open_depth]);
            try output.append(allocator, 'd');
            try current_path.append(allocator, components[open_depth]);
            open_depth += 1;
        }

        // Emit the file entry
        const filename = components[components.len - 1];
        try bencodeString(allocator, output, filename);
        try output.append(allocator, 'd'); // file name dict
        try bencodeString(allocator, output, ""); // empty string key
        try output.append(allocator, 'd'); // leaf dict
        try bencodeString(allocator, output, "length");
        try output.print(allocator, "i{}e", .{v2_infos[i].file_size});
        if (v2_infos[i].file_size > 0) {
            try bencodeString(allocator, output, "pieces root");
            try output.print(allocator, "32:", .{});
            try output.appendSlice(allocator, &v2_infos[i].pieces_root);
        }
        try output.append(allocator, 'e'); // close leaf dict
        try output.append(allocator, 'e'); // close file name dict
    }

    // Close remaining open directories
    while (open_depth > 0) {
        try output.append(allocator, 'e');
        open_depth -= 1;
    }

    try output.append(allocator, 'e'); // close file tree dict
}

/// Emit the `piece layers` dictionary at the top level.
/// Keys are the pieces_root hashes (32-byte binary), values are concatenated
/// SHA-256 piece hashes. Only files with >= 2 pieces are included.
fn emitPieceLayers(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    entries: []const PieceLayerEntry,
) !void {
    if (entries.len == 0) return;

    // Sort entries by pieces_root (binary key order, per bencode spec)
    const sorted_indices = try allocator.alloc(usize, entries.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, sorted_indices, entries, struct {
        fn lessThan(e: []const PieceLayerEntry, a: usize, b: usize) bool {
            return std.mem.order(u8, &e[a].pieces_root, &e[b].pieces_root) == .lt;
        }
    }.lessThan);

    try bencodeString(allocator, output, "piece layers");
    try output.append(allocator, 'd');
    for (sorted_indices) |idx| {
        const entry = entries[idx];
        // Key is the 32-byte pieces_root
        try output.print(allocator, "32:", .{});
        try output.appendSlice(allocator, &entry.pieces_root);
        // Value is the concatenated piece hashes
        try output.print(allocator, "{}:", .{entry.layer_data.len});
        try output.appendSlice(allocator, entry.layer_data);
    }
    try output.append(allocator, 'e');
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
    // "hello world test data for torrent creation" = 42 bytes.
    try std.testing.expectEqual(@as(u64, 42), info.totalSize());
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

test "hybrid piece length validation" {
    // Must be >= 16 KiB
    try std.testing.expectError(error.HybridPieceLengthTooSmall, validateHybridPieceLength(8192));
    try std.testing.expectError(error.HybridPieceLengthTooSmall, validateHybridPieceLength(1));

    // Must be a power of 2
    try std.testing.expectError(error.HybridPieceLengthNotPowerOf2, validateHybridPieceLength(24576)); // 24 KiB, not power of 2

    // Valid values
    try validateHybridPieceLength(16 * 1024);
    try validateHybridPieceLength(32 * 1024);
    try validateHybridPieceLength(256 * 1024);
    try validateHybridPieceLength(1024 * 1024);
    try validateHybridPieceLength(16 * 1024 * 1024);
}

test "create hybrid single file torrent and parse it back" {
    const allocator = std.testing.allocator;
    const metainfo_mod = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test file large enough for multiple pieces at 16 KiB piece size
    {
        const file = try tmp.dir.createFile("test_hybrid.bin", .{});
        defer file.close();
        // Write 48 KiB of data => 3 pieces at 16 KiB piece length
        var buf: [16 * 1024]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);
        try file.writeAll(&buf);
        for (&buf, 0..) |*b, i| b.* = @truncate(i +% 100);
        try file.writeAll(&buf);
        for (&buf, 0..) |*b, i| b.* = @truncate(i +% 200);
        try file.writeAll(&buf);
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test_hybrid.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 16 * 1024,
        .creation_date = 1700000000,
        .hybrid = true,
    }, null);
    defer allocator.free(torrent_bytes);

    // Parse it back
    const info = try metainfo_mod.parse(allocator, torrent_bytes);
    defer metainfo_mod.freeMetainfo(allocator, info);

    // Check v1 fields
    try std.testing.expectEqualStrings("test_hybrid.bin", info.name);
    try std.testing.expectEqualStrings("http://tracker.example/announce", info.announce.?);
    try std.testing.expectEqual(@as(u32, 16 * 1024), info.piece_length);
    try std.testing.expectEqual(@as(u64, 48 * 1024), info.totalSize());
    try std.testing.expectEqual(@as(u32, 3), try info.pieceCount());

    // Check hybrid version detection
    try std.testing.expectEqual(metainfo_mod.TorrentVersion.hybrid, info.version);

    // Check v2 info hash is present
    try std.testing.expect(info.info_hash_v2 != null);

    // Check v2 file tree
    try std.testing.expect(info.file_tree_v2 != null);
    const v2_files = info.file_tree_v2.?;
    try std.testing.expectEqual(@as(usize, 1), v2_files.len);
    try std.testing.expectEqual(@as(u64, 48 * 1024), v2_files[0].length);
    try std.testing.expectEqual(@as(usize, 1), v2_files[0].path.len);
    try std.testing.expectEqualStrings("test_hybrid.bin", v2_files[0].path[0]);

    // Verify the pieces_root is not all zeros (file has data)
    try std.testing.expect(!std.mem.eql(u8, &v2_files[0].pieces_root, &([_]u8{0} ** 32)));
}

test "create hybrid multi-file torrent and parse it back" {
    const allocator = std.testing.allocator;
    const metainfo_mod = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test directory with files
    try tmp.dir.makePath("hybriddir/subdir");
    {
        const f = try tmp.dir.createFile("hybriddir/file_a.txt", .{});
        defer f.close();
        // Write 32 KiB
        var buf: [32 * 1024]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);
        try f.writeAll(&buf);
    }
    {
        const f = try tmp.dir.createFile("hybriddir/subdir/file_b.txt", .{});
        defer f.close();
        // Write 48 KiB
        var buf: [16 * 1024]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i +% 50);
        try f.writeAll(&buf);
        for (&buf, 0..) |*b, i| b.* = @truncate(i +% 100);
        try f.writeAll(&buf);
        for (&buf, 0..) |*b, i| b.* = @truncate(i +% 150);
        try f.writeAll(&buf);
    }

    const dir_path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "hybriddir",
    });
    defer allocator.free(dir_path);

    const torrent_bytes = try createDirectory(allocator, dir_path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 16 * 1024,
        .creation_date = 1700000000,
        .hybrid = true,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo_mod.parse(allocator, torrent_bytes);
    defer metainfo_mod.freeMetainfo(allocator, info);

    // Check v1 fields
    try std.testing.expectEqualStrings("hybriddir", info.name);
    try std.testing.expect(info.isMultiFile());
    try std.testing.expectEqual(@as(usize, 2), info.files.len);
    try std.testing.expectEqual(@as(u64, 80 * 1024), info.totalSize());

    // Check hybrid version
    try std.testing.expectEqual(metainfo_mod.TorrentVersion.hybrid, info.version);
    try std.testing.expect(info.info_hash_v2 != null);

    // Check v2 file tree
    try std.testing.expect(info.file_tree_v2 != null);
    const v2_files = info.file_tree_v2.?;
    try std.testing.expectEqual(@as(usize, 2), v2_files.len);

    // Files should be in sorted order
    // file_a.txt and subdir/file_b.txt
    try std.testing.expectEqual(@as(u64, 32 * 1024), v2_files[0].length);
    try std.testing.expectEqual(@as(u64, 48 * 1024), v2_files[1].length);
}

test "hybrid torrent Merkle root matches manual computation" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file with exactly 2 pieces at 16 KiB
    const piece_len = 16 * 1024;
    var piece1: [piece_len]u8 = undefined;
    var piece2: [piece_len]u8 = undefined;
    for (&piece1, 0..) |*b, i| b.* = @truncate(i);
    for (&piece2, 0..) |*b, i| b.* = @truncate(i +% 128);

    {
        const f = try tmp.dir.createFile("two_pieces.bin", .{});
        defer f.close();
        try f.writeAll(&piece1);
        try f.writeAll(&piece2);
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "two_pieces.bin",
    });
    defer allocator.free(path);

    // Compute expected Merkle root manually
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    Sha256.hash(&piece1, &h1, .{});
    Sha256.hash(&piece2, &h2, .{});
    const expected_root = merkle.hashPair(h1, h2);

    // Create hybrid torrent and extract the Merkle root
    const metainfo_mod = @import("metainfo.zig");
    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = piece_len,
        .creation_date = 1700000000,
        .hybrid = true,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo_mod.parse(allocator, torrent_bytes);
    defer metainfo_mod.freeMetainfo(allocator, info);

    const v2_files = info.file_tree_v2.?;
    try std.testing.expectEqual(expected_root, v2_files[0].pieces_root);
}

test "hybrid torrent rejects non-power-of-2 piece length" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("test.bin", .{});
        defer file.close();
        try file.writeAll("hello");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "test.bin",
    });
    defer allocator.free(path);

    // 48 KiB is not a power of 2
    try std.testing.expectError(error.HybridPieceLengthNotPowerOf2, createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 48 * 1024,
        .hybrid = true,
    }, null));

    // 8 KiB is below minimum
    try std.testing.expectError(error.HybridPieceLengthTooSmall, createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 8 * 1024,
        .hybrid = true,
    }, null));
}

test "v1 only torrent still works when hybrid is false" {
    // Verify that existing v1 path is unaffected
    const allocator = std.testing.allocator;
    const metainfo_mod = @import("metainfo.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile("v1only.bin", .{});
        defer file.close();
        try file.writeAll("v1 only data for testing");
    }

    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "v1only.bin",
    });
    defer allocator.free(path);

    const torrent_bytes = try createSingleFile(allocator, path, .{
        .announce_url = "http://tracker.example/announce",
        .piece_length = 16,
        .creation_date = 1700000000,
        .hybrid = false,
    }, null);
    defer allocator.free(torrent_bytes);

    const info = try metainfo_mod.parse(allocator, torrent_bytes);
    defer metainfo_mod.freeMetainfo(allocator, info);

    // Should be v1 only
    try std.testing.expectEqual(metainfo_mod.TorrentVersion.v1, info.version);
    try std.testing.expect(info.info_hash_v2 == null);
    try std.testing.expect(info.file_tree_v2 == null);
}

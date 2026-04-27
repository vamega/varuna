const std = @import("std");
const log = std.log.scoped(.web_seed);
const layout_mod = @import("../torrent/layout.zig");
const metainfo_mod = @import("../torrent/metainfo.zig");

/// State of a single web seed source.
pub const WebSeedState = enum {
    idle, // ready to request
    active, // currently downloading
    backoff, // temporarily failed, waiting before retry
    disabled, // permanently failed or removed
};

/// Per-web-seed tracking for BEP 19 (GetRight-style) sources.
pub const WebSeed = struct {
    url: []const u8, // base URL from url-list
    state: WebSeedState = .idle,
    /// Current piece being downloaded (valid when state == .active).
    current_piece: u32 = 0,
    /// Consecutive failure count for exponential backoff.
    consecutive_failures: u32 = 0,
    /// Timestamp (seconds) when backoff expires.
    backoff_until: i64 = 0,
    /// Total bytes downloaded from this web seed.
    bytes_downloaded: u64 = 0,
    /// Total successful piece downloads.
    pieces_downloaded: u32 = 0,
    /// Total failed requests.
    failed_requests: u32 = 0,
};

/// Per-torrent web seed manager. Tracks all web seed sources and
/// coordinates piece requests across them.
pub const WebSeedManager = struct {
    allocator: std.mem.Allocator,
    seeds: []WebSeed,
    /// Torrent name for multi-file path construction.
    torrent_name: []const u8,
    /// Whether this is a multi-file torrent.
    is_multi_file: bool,
    /// File list from metainfo for multi-file path building.
    files: []const metainfo_mod.Metainfo.File,
    /// Layout for piece-to-byte mapping.
    piece_length: u32,
    total_size: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        url_list: []const []const u8,
        torrent_name: []const u8,
        is_multi_file: bool,
        files: []const metainfo_mod.Metainfo.File,
        piece_length: u32,
        total_size: u64,
    ) !WebSeedManager {
        const seeds = try allocator.alloc(WebSeed, url_list.len);
        for (url_list, 0..) |url, i| {
            seeds[i] = .{ .url = url };
        }
        return .{
            .allocator = allocator,
            .seeds = seeds,
            .torrent_name = torrent_name,
            .is_multi_file = is_multi_file,
            .files = files,
            .piece_length = piece_length,
            .total_size = total_size,
        };
    }

    pub fn deinit(self: *WebSeedManager) void {
        self.allocator.free(self.seeds);
    }

    /// Returns the number of web seed sources.
    pub fn seedCount(self: *const WebSeedManager) usize {
        return self.seeds.len;
    }

    /// Returns the number of idle (available) web seeds.
    pub fn availableCount(self: *const WebSeedManager, now: i64) usize {
        var count: usize = 0;
        for (self.seeds) |seed| {
            if (seed.state == .idle) {
                count += 1;
            } else if (seed.state == .backoff and now >= seed.backoff_until) {
                count += 1;
            }
        }
        return count;
    }

    /// Find an idle web seed and assign a piece to it. Returns the seed index.
    pub fn assignPiece(self: *WebSeedManager, piece_index: u32, now: i64) ?usize {
        for (self.seeds, 0..) |*seed, i| {
            const available = seed.state == .idle or
                (seed.state == .backoff and now >= seed.backoff_until);
            if (available) {
                seed.state = .active;
                seed.current_piece = piece_index;
                return i;
            }
        }
        return null;
    }

    /// Mark a web seed as having successfully completed its piece download.
    pub fn markSuccess(self: *WebSeedManager, seed_index: usize, bytes: u64) void {
        if (seed_index >= self.seeds.len) return;
        var seed = &self.seeds[seed_index];
        seed.state = .idle;
        seed.consecutive_failures = 0;
        seed.bytes_downloaded += bytes;
        seed.pieces_downloaded += 1;
    }

    /// Mark a web seed as having failed. Applies exponential backoff.
    pub fn markFailure(self: *WebSeedManager, seed_index: usize, now: i64) void {
        if (seed_index >= self.seeds.len) return;
        var seed = &self.seeds[seed_index];
        seed.failed_requests += 1;
        seed.consecutive_failures += 1;

        // Exponential backoff: 5s, 10s, 20s, 40s, ..., max 300s
        const base_delay: i64 = 5;
        const shift: u6 = @intCast(@min(seed.consecutive_failures - 1, 6));
        const delay = @min(base_delay << shift, 300);
        seed.backoff_until = now + delay;
        seed.state = .backoff;

        // After 10 consecutive failures, disable the seed
        if (seed.consecutive_failures >= 10) {
            seed.state = .disabled;
        }
    }

    /// Disable a web seed permanently (e.g., 404 or other non-retryable error).
    pub fn disable(self: *WebSeedManager, seed_index: usize) void {
        if (seed_index >= self.seeds.len) return;
        self.seeds[seed_index].state = .disabled;
    }

    /// Build the full URL for downloading a piece from a BEP 19 web seed.
    ///
    /// For single-file torrents: the base URL points directly to the file.
    /// For multi-file torrents: the base URL is a directory, and we append
    /// the file path from the torrent metadata.
    ///
    /// Returns the URL. Caller owns the memory.
    pub fn buildFileUrl(
        self: *const WebSeedManager,
        allocator: std.mem.Allocator,
        seed_index: usize,
        file_index: u32,
    ) ![]u8 {
        if (seed_index >= self.seeds.len) return error.InvalidSeedIndex;
        const base_url = self.seeds[seed_index].url;

        if (!self.is_multi_file) {
            // Single-file: the URL is the complete file URL
            return try allocator.dupe(u8, base_url);
        }

        // Multi-file: append torrent_name/file_path to the base URL
        if (file_index >= self.files.len) return error.InvalidFileIndex;
        const file = self.files[file_index];

        var url_buf = std.ArrayList(u8).empty;
        defer url_buf.deinit(allocator);

        // Ensure base URL ends with '/'
        try url_buf.appendSlice(allocator, base_url);
        if (base_url.len > 0 and base_url[base_url.len - 1] != '/') {
            try url_buf.append(allocator, '/');
        }

        // Append file path components
        for (file.path, 0..) |component, i| {
            if (i > 0) try url_buf.append(allocator, '/');
            try appendUrlEncoded(&url_buf, allocator, component);
        }

        return url_buf.toOwnedSlice(allocator);
    }

    /// Compute the byte range within a file for a given piece.
    /// For single-file torrents, this is straightforward.
    /// For multi-file torrents where a piece spans files, this returns
    /// the ranges per file that need to be fetched.
    pub fn computePieceRanges(
        self: *const WebSeedManager,
        piece_index: u32,
        piece_count: u32,
        buffer: []FileRange,
    ) ![]FileRange {
        if (piece_index >= piece_count) return error.InvalidPieceIndex;

        if (!self.is_multi_file) {
            // Single-file: one range covering the piece bytes
            if (buffer.len < 1) return error.BufferTooSmall;
            const piece_start = @as(u64, piece_index) * self.piece_length;
            const piece_end = @min(piece_start + self.piece_length, self.total_size);
            buffer[0] = .{
                .file_index = 0,
                .range_start = piece_start,
                .range_end = piece_end - 1, // inclusive end for HTTP Range
                .piece_offset = 0,
                .length = @intCast(piece_end - piece_start),
            };
            return buffer[0..1];
        }

        // Multi-file: a piece may span multiple files
        const piece_start = @as(u64, piece_index) * self.piece_length;
        const piece_end = @min(piece_start + self.piece_length, self.total_size);

        var running_offset: u64 = 0;
        var next: usize = 0;

        for (self.files, 0..) |file, file_idx| {
            const file_start = running_offset;
            const file_end = file_start + file.length;
            running_offset = file_end;

            if (file.length == 0) continue;

            // Check overlap between [piece_start, piece_end) and [file_start, file_end)
            const overlap_start = @max(piece_start, file_start);
            const overlap_end = @min(piece_end, file_end);
            if (overlap_start >= overlap_end) continue;

            if (next >= buffer.len) return error.BufferTooSmall;

            buffer[next] = .{
                .file_index = @intCast(file_idx),
                .range_start = overlap_start - file_start,
                .range_end = overlap_end - file_start - 1, // inclusive
                .piece_offset = @intCast(overlap_start - piece_start),
                .length = @intCast(overlap_end - overlap_start),
            };
            next += 1;
        }

        return buffer[0..next];
    }

    /// Compute the byte ranges for a contiguous run of pieces starting at
    /// `first_piece` with `piece_count` pieces. For single-file torrents this
    /// produces a single range. For multi-file torrents it produces one range
    /// per file that the run spans.
    ///
    /// The returned `MultiPieceRange.length` and `buf_offset` are u32 to match
    /// the rest of the web-seed handler pipeline (the `run_buf` allocation is
    /// u32, `WebSeedSlot.total_bytes` is u32, `target_offset` is u32). The
    /// production caller bounds the run via the `web_seed_max_request_bytes`
    /// config (default 4 MB), so the u32 width is plenty in practice — but a
    /// misconfigured bound (e.g. > 4 GB) would previously panic the
    /// `@intCast(u64 -> u32)` here and crash the daemon on the first
    /// multi-piece request. The check below rejects with `error.RunTooLarge`
    /// instead, leaving the caller to retry with a smaller `count` or to
    /// surface a config error to the operator.
    pub fn computeMultiPieceRanges(
        self: *const WebSeedManager,
        first_piece: u32,
        count: u32,
        total_pieces: u32,
        buffer: []MultiPieceRange,
    ) ![]MultiPieceRange {
        if (first_piece >= total_pieces) return error.InvalidPieceIndex;
        const last_piece = @min(first_piece + count, total_pieces) - 1;

        // Byte range of the entire run within the torrent
        const run_start = @as(u64, first_piece) * self.piece_length;
        const run_end = @min(@as(u64, last_piece + 1) * self.piece_length, self.total_size);

        // Reject runs whose total byte span exceeds u32 — the rest of the
        // pipeline (run_buf alloc, WebSeedSlot.total_bytes, MultiPieceRange
        // .buf_offset / .length) is u32-bounded. Without this guard, a
        // misconfigured `web_seed_max_request_bytes` (e.g. 8 GB) would
        // panic the `@intCast` below on the first call.
        if (run_end - run_start > std.math.maxInt(u32)) return error.RunTooLarge;

        if (!self.is_multi_file) {
            // Single-file: one range covering all pieces
            if (buffer.len < 1) return error.BufferTooSmall;
            buffer[0] = .{
                .file_index = 0,
                .range_start = run_start,
                .range_end = run_end - 1,
                .buf_offset = 0,
                .length = @intCast(run_end - run_start),
            };
            return buffer[0..1];
        }

        // Multi-file: the piece run may span multiple files.
        var running_offset: u64 = 0;
        var next: usize = 0;
        var buf_offset: u32 = 0;

        for (self.files, 0..) |file, file_idx| {
            const file_start = running_offset;
            const file_end = file_start + file.length;
            running_offset = file_end;

            if (file.length == 0) continue;

            // Check overlap between [run_start, run_end) and [file_start, file_end)
            const overlap_start = @max(run_start, file_start);
            const overlap_end = @min(run_end, file_end);
            if (overlap_start >= overlap_end) continue;

            if (next >= buffer.len) return error.BufferTooSmall;

            // overlap_end - overlap_start <= run_end - run_start <= maxInt(u32)
            // by the upfront check, so this @intCast cannot panic.
            const length: u32 = @intCast(overlap_end - overlap_start);
            buffer[next] = .{
                .file_index = @intCast(file_idx),
                .range_start = overlap_start - file_start,
                .range_end = overlap_end - file_start - 1,
                .buf_offset = buf_offset,
                .length = length,
            };
            buf_offset += length;
            next += 1;
        }

        return buffer[0..next];
    }
};

/// A byte range within a single file that needs to be fetched for a piece.
pub const FileRange = struct {
    file_index: u32,
    /// Byte offset within the file (start of range, inclusive).
    range_start: u64,
    /// Byte offset within the file (end of range, inclusive for HTTP Range header).
    range_end: u64,
    /// Offset within the piece buffer where this data should be placed.
    piece_offset: u32,
    /// Number of bytes in this range.
    length: u32,
};

/// A contiguous byte range spanning multiple pieces in a single file,
/// used for multi-piece web seed requests.
pub const MultiPieceRange = struct {
    file_index: u32,
    /// Byte offset within the file (start of range, inclusive).
    range_start: u64,
    /// Byte offset within the file (end of range, inclusive for HTTP Range header).
    range_end: u64,
    /// Offset within the aggregate buffer where this data should be placed.
    buf_offset: u32,
    /// Number of bytes in this range.
    length: u32,
};

/// URL-encode a path component (percent-encode non-unreserved characters).
fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, hex[c >> 4]);
            try buf.append(allocator, hex[c & 0x0F]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

// ── Tests ────────────────────────────────────────────────

test "web seed manager init and deinit" {
    const urls = [_][]const u8{
        "http://example.com/file.bin",
        "https://mirror.example.com/file.bin",
    };
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 2), mgr.seedCount());
    try std.testing.expectEqual(@as(usize, 2), mgr.availableCount(0));
}

test "web seed assign and complete piece" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    // Assign piece 0 to seed 0
    const idx = mgr.assignPiece(0, 0);
    try std.testing.expectEqual(@as(?usize, 0), idx);
    try std.testing.expectEqual(WebSeedState.active, mgr.seeds[0].state);

    // No more seeds available
    try std.testing.expectEqual(@as(?usize, null), mgr.assignPiece(1, 0));

    // Mark success
    mgr.markSuccess(0, 256);
    try std.testing.expectEqual(WebSeedState.idle, mgr.seeds[0].state);
    try std.testing.expectEqual(@as(u64, 256), mgr.seeds[0].bytes_downloaded);
    try std.testing.expectEqual(@as(u32, 1), mgr.seeds[0].pieces_downloaded);
}

test "web seed failure backoff" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    const now: i64 = 100;

    // First failure: 5s backoff
    _ = mgr.assignPiece(0, now);
    mgr.markFailure(0, now);
    try std.testing.expectEqual(WebSeedState.backoff, mgr.seeds[0].state);
    try std.testing.expectEqual(@as(i64, 105), mgr.seeds[0].backoff_until);
    try std.testing.expectEqual(@as(usize, 0), mgr.availableCount(now));
    try std.testing.expectEqual(@as(usize, 1), mgr.availableCount(105));

    // Second failure: 10s backoff
    _ = mgr.assignPiece(0, 105);
    mgr.markFailure(0, 105);
    try std.testing.expectEqual(@as(i64, 115), mgr.seeds[0].backoff_until);
}

test "web seed disabled after 10 failures" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    // Simulate 10 consecutive failures
    var now: i64 = 0;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        mgr.seeds[0].state = .idle; // force back to idle for testing
        _ = mgr.assignPiece(0, now);
        mgr.markFailure(0, now);
        now += 1000;
    }

    try std.testing.expectEqual(WebSeedState.disabled, mgr.seeds[0].state);
    try std.testing.expectEqual(@as(usize, 0), mgr.availableCount(now));
}

test "compute piece ranges for single-file torrent" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1000, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1000,
    );
    defer mgr.deinit();

    var buf: [8]FileRange = undefined;

    // Piece 0: bytes 0-255
    const r0 = try mgr.computePieceRanges(0, 4, &buf);
    try std.testing.expectEqual(@as(usize, 1), r0.len);
    try std.testing.expectEqual(@as(u64, 0), r0[0].range_start);
    try std.testing.expectEqual(@as(u64, 255), r0[0].range_end);
    try std.testing.expectEqual(@as(u32, 256), r0[0].length);

    // Piece 3 (last piece): bytes 768-999
    const r3 = try mgr.computePieceRanges(3, 4, &buf);
    try std.testing.expectEqual(@as(usize, 1), r3.len);
    try std.testing.expectEqual(@as(u64, 768), r3[0].range_start);
    try std.testing.expectEqual(@as(u64, 999), r3[0].range_end);
    try std.testing.expectEqual(@as(u32, 232), r3[0].length);
}

test "compute piece ranges for multi-file torrent spanning files" {
    const urls = [_][]const u8{"http://example.com/torrent/"};
    const path0 = [_][]const u8{"alpha.bin"};
    const path1 = [_][]const u8{"beta.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 100, .path = &path0 },
        .{ .length = 200, .path = &path1 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "mydir",
        true,
        &files,
        128,
        300,
    );
    defer mgr.deinit();

    var buf: [8]FileRange = undefined;

    // Piece 0: bytes 0-127 spans alpha.bin (0-99) and beta.bin (0-27)
    const r0 = try mgr.computePieceRanges(0, 3, &buf);
    try std.testing.expectEqual(@as(usize, 2), r0.len);
    // First range: alpha.bin bytes 0-99
    try std.testing.expectEqual(@as(u32, 0), r0[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), r0[0].range_start);
    try std.testing.expectEqual(@as(u64, 99), r0[0].range_end);
    try std.testing.expectEqual(@as(u32, 0), r0[0].piece_offset);
    try std.testing.expectEqual(@as(u32, 100), r0[0].length);
    // Second range: beta.bin bytes 0-27
    try std.testing.expectEqual(@as(u32, 1), r0[1].file_index);
    try std.testing.expectEqual(@as(u64, 0), r0[1].range_start);
    try std.testing.expectEqual(@as(u64, 27), r0[1].range_end);
    try std.testing.expectEqual(@as(u32, 100), r0[1].piece_offset);
    try std.testing.expectEqual(@as(u32, 28), r0[1].length);
}

test "build file url for single-file torrent" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    const url = try mgr.buildFileUrl(std.testing.allocator, 0, 0);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://example.com/file.bin", url);
}

test "build file url for multi-file torrent" {
    const urls = [_][]const u8{"http://example.com/torrent/"};
    const path0 = [_][]const u8{"alpha.bin"};
    const path1 = [_][]const u8{ "sub dir", "beta file.bin" };
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 100, .path = &path0 },
        .{ .length = 200, .path = &path1 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "mydir",
        true,
        &files,
        128,
        300,
    );
    defer mgr.deinit();

    // First file: simple path
    const url0 = try mgr.buildFileUrl(std.testing.allocator, 0, 0);
    defer std.testing.allocator.free(url0);
    try std.testing.expectEqualStrings("http://example.com/torrent/alpha.bin", url0);

    // Second file: path with spaces gets percent-encoded
    const url1 = try mgr.buildFileUrl(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("http://example.com/torrent/sub%20dir/beta%20file.bin", url1);
}

test "build file url appends slash to base" {
    const urls = [_][]const u8{"http://example.com/torrent"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 100, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "mydir",
        true,
        &files,
        128,
        100,
    );
    defer mgr.deinit();

    const url = try mgr.buildFileUrl(std.testing.allocator, 0, 0);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://example.com/torrent/file.bin", url);
}

test "url encoding of special characters" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try appendUrlEncoded(&buf, std.testing.allocator, "hello world/foo+bar");
    try std.testing.expectEqualStrings("hello%20world%2Ffoo%2Bbar", buf.items);
}

test "compute piece ranges rejects out-of-bounds piece" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    var buf: [8]FileRange = undefined;
    try std.testing.expectError(error.InvalidPieceIndex, mgr.computePieceRanges(4, 4, &buf));
    try std.testing.expectError(error.InvalidPieceIndex, mgr.computePieceRanges(100, 4, &buf));
}

test "web seed success resets failure count" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    // Fail a few times
    _ = mgr.assignPiece(0, 0);
    mgr.markFailure(0, 0);
    mgr.seeds[0].state = .idle;
    _ = mgr.assignPiece(0, 100);
    mgr.markFailure(0, 100);
    try std.testing.expectEqual(@as(u32, 2), mgr.seeds[0].consecutive_failures);

    // Then succeed
    mgr.seeds[0].state = .idle;
    _ = mgr.assignPiece(0, 200);
    mgr.markSuccess(0, 256);
    try std.testing.expectEqual(@as(u32, 0), mgr.seeds[0].consecutive_failures);
    try std.testing.expectEqual(@as(u32, 2), mgr.seeds[0].failed_requests); // total failures preserved
}

test "disable web seed permanently" {
    const urls = [_][]const u8{
        "http://example.com/file.bin",
        "http://mirror.com/file.bin",
    };
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1024, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1024,
    );
    defer mgr.deinit();

    mgr.disable(0);
    try std.testing.expectEqual(WebSeedState.disabled, mgr.seeds[0].state);
    try std.testing.expectEqual(@as(usize, 1), mgr.availableCount(0));
}

test "compute multi-piece ranges for single-file torrent" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 1000, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        1000,
    );
    defer mgr.deinit();

    var buf: [16]MultiPieceRange = undefined;

    // All 4 pieces (0-3): bytes 0-999
    const r = try mgr.computeMultiPieceRanges(0, 4, 4, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(@as(u64, 0), r[0].range_start);
    try std.testing.expectEqual(@as(u64, 999), r[0].range_end);
    try std.testing.expectEqual(@as(u32, 0), r[0].buf_offset);
    try std.testing.expectEqual(@as(u32, 1000), r[0].length);

    // Pieces 1-2: bytes 256-767
    const r2 = try mgr.computeMultiPieceRanges(1, 2, 4, &buf);
    try std.testing.expectEqual(@as(usize, 1), r2.len);
    try std.testing.expectEqual(@as(u64, 256), r2[0].range_start);
    try std.testing.expectEqual(@as(u64, 767), r2[0].range_end);
    try std.testing.expectEqual(@as(u32, 512), r2[0].length);
}

test "compute multi-piece ranges for multi-file torrent" {
    const urls = [_][]const u8{"http://example.com/torrent/"};
    const path0 = [_][]const u8{"alpha.bin"};
    const path1 = [_][]const u8{"beta.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 300, .path = &path0 },
        .{ .length = 700, .path = &path1 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "mydir",
        true,
        &files,
        256,
        1000,
    );
    defer mgr.deinit();

    var buf: [16]MultiPieceRange = undefined;

    // All 4 pieces: bytes 0-1023 in torrent space, but last piece is 1000-256*3=232 bytes
    // File spans: alpha.bin 0-299, beta.bin 0-699
    // Piece run 0..3 = torrent bytes 0-999
    const r = try mgr.computeMultiPieceRanges(0, 4, 4, &buf);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    // alpha.bin: 0-299
    try std.testing.expectEqual(@as(u32, 0), r[0].file_index);
    try std.testing.expectEqual(@as(u64, 0), r[0].range_start);
    try std.testing.expectEqual(@as(u64, 299), r[0].range_end);
    try std.testing.expectEqual(@as(u32, 0), r[0].buf_offset);
    try std.testing.expectEqual(@as(u32, 300), r[0].length);
    // beta.bin: 0-699
    try std.testing.expectEqual(@as(u32, 1), r[1].file_index);
    try std.testing.expectEqual(@as(u64, 0), r[1].range_start);
    try std.testing.expectEqual(@as(u64, 699), r[1].range_end);
    try std.testing.expectEqual(@as(u32, 300), r[1].buf_offset);
    try std.testing.expectEqual(@as(u32, 700), r[1].length);
}

test "compute multi-piece ranges partial run" {
    const urls = [_][]const u8{"http://example.com/file.bin"};
    const path0 = [_][]const u8{"file.bin"};
    const files = [_]metainfo_mod.Metainfo.File{
        .{ .length = 2048, .path = &path0 },
    };

    var mgr = try WebSeedManager.init(
        std.testing.allocator,
        &urls,
        "file.bin",
        false,
        &files,
        256,
        2048,
    );
    defer mgr.deinit();

    var buf: [16]MultiPieceRange = undefined;

    // Pieces 2-5 of 8: bytes 512-1535
    const r = try mgr.computeMultiPieceRanges(2, 4, 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(@as(u64, 512), r[0].range_start);
    try std.testing.expectEqual(@as(u64, 1535), r[0].range_end);
    try std.testing.expectEqual(@as(u32, 1024), r[0].length);
}

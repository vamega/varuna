const std = @import("std");
const bencode = @import("bencode.zig");
const info_hash = @import("info_hash.zig");
const file_tree = @import("file_tree.zig");

/// Torrent version: v1 (BEP 3), v2 (BEP 52), or hybrid (both).
pub const TorrentVersion = enum {
    v1, // traditional: has "pieces" but no "file tree"
    v2, // pure v2: has "file tree" but no "pieces"
    hybrid, // both v1 and v2 metadata present
};

/// Per-file metadata from BEP 52 v2 file tree.
pub const V2File = struct {
    path: []const []const u8,
    length: u64,
    pieces_root: [32]u8, // SHA-256 Merkle root for this file
};

pub const Metainfo = struct {
    info_hash: [20]u8,
    announce: ?[]const u8,
    announce_list: []const []const u8 = &.{},
    comment: ?[]const u8,
    created_by: ?[]const u8,
    creation_date: ?i64 = null,
    name: []const u8,
    piece_length: u32,
    pieces: []const u8 = "", // may be empty for pure v2
    private: bool = false,
    /// Per-file metadata. `[]const File` rather than `[]File` because no
    /// production code mutates the slice contents post-parse — keeps test
    /// struct literals (which use stack-allocated const arrays) coercible
    /// without `@constCast`. Production parse path still owns the heap
    /// allocation and frees it via `freeMetainfo`.
    files: []const File,

    // BEP 19: GetRight-style web seed URLs (url-list key)
    url_list: []const []const u8 = &.{},
    // BEP 17: Hoffman-style HTTP seed URLs (httpseeds key)
    http_seeds: []const []const u8 = &.{},

    // v2 fields (BEP 52)
    version: TorrentVersion = .v1,
    info_hash_v2: ?[32]u8 = null, // SHA-256 info-hash (null for pure v1)
    file_tree_v2: ?[]V2File = null, // v2 per-file metadata

    pub const File = struct {
        length: u64,
        path: []const []const u8,
    };

    pub fn pieceCount(self: Metainfo) !u32 {
        if (self.version == .v2) {
            // For v2, piece count is derived from file sizes and piece_length
            return self.pieceCountFromFiles();
        }
        // For v1/hybrid: prefer the pieces table when present (authoritative —
        // catches torrents with extra/missing trailing data), but fall back to
        // file-size-derived count when pieces have been freed for seeding-only
        // (Phase 2 of the piece-hash lifecycle).
        if (self.pieces.len > 0) {
            return std.math.cast(u32, self.pieces.len / 20) orelse error.PieceCountOverflow;
        }
        return self.pieceCountFromFileSizes();
    }

    /// Compute piece count from v1 file sizes and piece_length. Used when the
    /// v1 `pieces` table is not materialised (Phase 2 seeding-only load).
    pub fn pieceCountFromFileSizes(self: Metainfo) !u32 {
        if (self.piece_length == 0) return error.InvalidPieceLength;
        const total = self.totalSize();
        if (total == 0) return error.EmptyTorrentData;
        const count = (total + self.piece_length - 1) / self.piece_length;
        return std.math.cast(u32, count) orelse error.PieceCountOverflow;
    }

    /// Compute piece count for v2 torrents from file tree metadata.
    /// In v2, pieces are file-aligned, so each file contributes ceil(length / piece_length) pieces.
    /// Requires v2 file tree metadata; returns error.V2FileTreeRequired if absent.
    pub fn pieceCountFromFiles(self: Metainfo) !u32 {
        const v2_files = self.file_tree_v2 orelse return error.V2FileTreeRequired;
        var total: u64 = 0;
        for (v2_files) |f| {
            if (f.length > 0) {
                total += (f.length + self.piece_length - 1) / self.piece_length;
            }
        }
        return std.math.cast(u32, total) orelse error.PieceCountOverflow;
    }

    pub fn pieceHash(self: Metainfo, piece_index: u32) ![]const u8 {
        if (piece_index >= try self.pieceCount()) {
            return error.InvalidPieceIndex;
        }
        if (self.version == .v2) {
            return error.UnsupportedForV2;
        }
        // Phase 2 of the piece-hash lifecycle: pieces may have been skipped
        // entirely (parseSeedingOnly) or freed mid-session (Session.freePieces).
        if (self.pieces.len == 0) {
            return error.PiecesNotLoaded;
        }

        const start = @as(usize, piece_index) * 20;
        return self.pieces[start .. start + 20];
    }

    pub fn totalSize(self: Metainfo) u64 {
        var total: u64 = 0;
        for (self.files) |file| {
            total +%= file.length;
        }
        return total;
    }

    pub fn isMultiFile(self: Metainfo) bool {
        return self.files.len > 1;
    }

    /// Returns true if this torrent has v2 metadata (pure v2 or hybrid).
    pub fn hasV2(self: Metainfo) bool {
        return self.version == .v2 or self.version == .hybrid;
    }

    /// Returns true if this torrent has v1 metadata (pure v1 or hybrid).
    pub fn hasV1(self: Metainfo) bool {
        return self.version == .v1 or self.version == .hybrid;
    }
};

/// Detect torrent version based on the presence of v1 and v2 fields.
pub fn detectVersion(info: []const bencode.Value.Entry) TorrentVersion {
    const has_pieces = bencode.dictGet(info, "pieces") != null;
    const has_file_tree = bencode.dictGet(info, "file tree") != null;
    if (has_pieces and has_file_tree) return .hybrid;
    if (has_file_tree) return .v2;
    return .v1;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Metainfo {
    return parseWithOptions(allocator, input, .{});
}

/// Parse a torrent's metainfo without materialising the v1 `pieces` field.
///
/// Used by Phase 2 of the piece-hash lifecycle (see `docs/piece-hash-lifecycle.md`):
/// when a session is loaded for a torrent already 100% complete, the per-piece
/// SHA-1 table buys nothing for seeding (the downloading peer verifies with their
/// own copy). Skipping the field saves `piece_count * 20` bytes per torrent.
///
/// Validation that the `pieces` field is present and well-formed is intentionally
/// skipped — for already-complete torrents the data has already been verified
/// against this table at least once. Recheck must call
/// `Session.loadPiecesForRecheck()` first to re-materialise the field.
pub fn parseSeedingOnly(allocator: std.mem.Allocator, input: []const u8) !Metainfo {
    return parseWithOptions(allocator, input, .{ .skip_pieces = true });
}

pub const ParseOptions = struct {
    /// When true, the v1 `pieces` field is not extracted from the bencode tree.
    /// The returned `Metainfo.pieces` is left as an empty slice. The field is
    /// still required to be present for v1/hybrid torrents (its presence is
    /// part of the format), but its bytes are not read.
    skip_pieces: bool = false,
};

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) !Metainfo {
    const digest = try info_hash.compute(input);
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const root_dict = try expectDict(root);
    const info = try expectDict(try getRequired(root_dict, "info"));

    const version = detectVersion(info);
    const name = try expectBytes(try getRequired(info, "name"));
    const piece_length = try expectU32(try getRequired(info, "piece length"));
    if (piece_length == 0) return error.InvalidPieceLength;

    // v1 pieces field: required for v1 and hybrid, absent for pure v2.
    // skip_pieces leaves the bytes unread (Phase 2 seeding-only fast path).
    var pieces: []const u8 = "";
    if (version == .v1 or version == .hybrid) {
        if (options.skip_pieces) {
            // Sanity-check presence without reading the bytes; the actual
            // field validation runs only when pieces are materialised
            // (e.g. via Session.loadPiecesForRecheck).
            _ = try getRequired(info, "pieces");
        } else {
            pieces = try expectBytes(try getRequired(info, "pieces"));
            if (pieces.len == 0 or pieces.len % 20 != 0) {
                return error.InvalidPiecesField;
            }
        }
    }

    // v1 file list: required for v1, populated from v1 fields for hybrid
    var files: []Metainfo.File = &.{};
    if (version == .v1 or version == .hybrid) {
        files = if (bencode.dictGet(info, "files")) |value|
            try parseMultiFileList(allocator, try expectList(value))
        else
            try parseSingleFileList(allocator, try expectU64(try getRequired(info, "length")), name);
    }
    errdefer {
        for (files) |f| allocator.free(f.path);
        if (files.len > 0) allocator.free(files);
    }

    // v2 file tree: required for v2 and hybrid
    var file_tree_v2: ?[]V2File = null;
    if (version == .v2 or version == .hybrid) {
        const ft_val = try getRequired(info, "file tree");
        const ft_dict = try expectDict(ft_val);
        file_tree_v2 = try file_tree.parseFileTree(allocator, ft_dict);
    }
    errdefer {
        if (file_tree_v2) |ft| file_tree.freeV2Files(allocator, ft);
    }

    // For pure v2, populate the v1 files array from the file tree for compatibility
    if (version == .v2) {
        if (file_tree_v2) |ft| {
            files = try allocator.alloc(Metainfo.File, ft.len);
            for (ft, 0..) |v2f, i| {
                const path_copy = try allocator.alloc([]const u8, v2f.path.len);
                @memcpy(path_copy, v2f.path);
                files[i] = .{
                    .length = v2f.length,
                    .path = path_copy,
                };
            }
        }
    }

    // v2 info-hash (SHA-256)
    var info_hash_v2: ?[32]u8 = null;
    if (version == .v2 or version == .hybrid) {
        info_hash_v2 = try info_hash.computeV2(input);
    }

    const announce_list = if (bencode.dictGet(root_dict, "announce-list")) |value|
        try parseAnnounceList(allocator, value)
    else
        try allocator.alloc([]const u8, 0);

    // BEP 19: url-list (GetRight-style web seeds)
    const url_list = if (bencode.dictGet(root_dict, "url-list")) |value|
        try parseUrlList(allocator, value)
    else
        try allocator.alloc([]const u8, 0);

    // BEP 17: httpseeds (Hoffman-style HTTP seeds)
    const http_seeds = if (bencode.dictGet(root_dict, "httpseeds")) |value|
        try parseStringList(allocator, value)
    else
        try allocator.alloc([]const u8, 0);

    return .{
        .info_hash = digest,
        .announce = if (bencode.dictGet(root_dict, "announce")) |value| try expectBytes(value) else null,
        .announce_list = announce_list,
        .url_list = url_list,
        .http_seeds = http_seeds,
        .comment = if (bencode.dictGet(root_dict, "comment")) |value| try expectBytes(value) else null,
        .created_by = if (bencode.dictGet(root_dict, "created by")) |value| try expectBytes(value) else null,
        .creation_date = if (bencode.dictGet(root_dict, "creation date")) |value| @as(i64, @intCast(try expectU64(value))) else null,
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .private = if (bencode.dictGet(info, "private")) |v| (try expectU64(v)) == 1 else false,
        .files = files,
        .version = version,
        .info_hash_v2 = info_hash_v2,
        .file_tree_v2 = file_tree_v2,
    };
}

fn parseAnnounceList(allocator: std.mem.Allocator, value: bencode.Value) ![]const []const u8 {
    const tiers = try expectList(value);
    var urls = std.ArrayList([]const u8).empty;
    defer urls.deinit(allocator);

    for (tiers) |tier| {
        const tier_list = try expectList(tier);
        for (tier_list) |url_value| {
            const url = try expectBytes(url_value);
            try urls.append(allocator, url);
        }
    }

    return urls.toOwnedSlice(allocator);
}

pub fn freeMetainfo(allocator: std.mem.Allocator, meta: Metainfo) void {
    if (meta.announce_list.len > 0) allocator.free(meta.announce_list);
    if (meta.url_list.len > 0) allocator.free(meta.url_list);
    if (meta.http_seeds.len > 0) allocator.free(meta.http_seeds);
    for (meta.files) |file| {
        allocator.free(file.path);
    }
    if (meta.files.len > 0) allocator.free(meta.files);
    if (meta.file_tree_v2) |ft| {
        file_tree.freeV2Files(allocator, ft);
    }
}

/// Parse BEP 19 url-list: can be a single string or a list of strings.
fn parseUrlList(allocator: std.mem.Allocator, value: bencode.Value) ![]const []const u8 {
    switch (value) {
        .bytes => |url| {
            const result = try allocator.alloc([]const u8, 1);
            result[0] = url;
            return result;
        },
        .list => |list| {
            var urls = std.ArrayList([]const u8).empty;
            defer urls.deinit(allocator);
            for (list) |item| {
                const url = expectBytes(item) catch continue;
                try urls.append(allocator, url);
            }
            return urls.toOwnedSlice(allocator);
        },
        else => return try allocator.alloc([]const u8, 0),
    }
}

/// Parse a bencode list of strings (used for BEP 17 httpseeds).
fn parseStringList(allocator: std.mem.Allocator, value: bencode.Value) ![]const []const u8 {
    const list = expectList(value) catch return try allocator.alloc([]const u8, 0);
    var urls = std.ArrayList([]const u8).empty;
    defer urls.deinit(allocator);
    for (list) |item| {
        const url = expectBytes(item) catch continue;
        try urls.append(allocator, url);
    }
    return urls.toOwnedSlice(allocator);
}

fn parseSingleFileList(
    allocator: std.mem.Allocator,
    length: u64,
    name: []const u8,
) ![]Metainfo.File {
    const path = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(path);
    path[0] = name;

    const files = try allocator.alloc(Metainfo.File, 1);
    files[0] = .{
        .length = length,
        .path = path,
    };
    return files;
}

fn parseMultiFileList(
    allocator: std.mem.Allocator,
    values: []const bencode.Value,
) ![]Metainfo.File {
    var files = try allocator.alloc(Metainfo.File, values.len);
    errdefer {
        for (files[0..values.len]) |file| {
            if (file.path.len != 0) allocator.free(file.path);
        }
        allocator.free(files);
    }

    for (values, 0..) |value, index| {
        const entry = try expectDict(value);
        const length = try expectU64(try getRequired(entry, "length"));
        const path = try parsePath(allocator, try expectList(try getRequired(entry, "path")));
        files[index] = .{
            .length = length,
            .path = path,
        };
    }

    return files;
}

fn parsePath(
    allocator: std.mem.Allocator,
    components: []const bencode.Value,
) ![]const []const u8 {
    if (components.len == 0) {
        return error.InvalidFilePath;
    }

    const path = try allocator.alloc([]const u8, components.len);
    errdefer allocator.free(path);

    for (components, 0..) |component, index| {
        path[index] = try expectBytes(component);
    }

    return path;
}

fn getRequired(dict: []const bencode.Value.Entry, key: []const u8) !bencode.Value {
    return bencode.dictGet(dict, key) orelse error.MissingRequiredField;
}

const BencodeTypeError = error{
    UnexpectedBencodeType,
    NegativeInteger,
    IntegerOverflow,
};

fn expectDict(value: bencode.Value) BencodeTypeError![]const bencode.Value.Entry {
    return switch (value) {
        .dict => |dict| dict,
        else => error.UnexpectedBencodeType,
    };
}

fn expectList(value: bencode.Value) BencodeTypeError![]const bencode.Value {
    return switch (value) {
        .list => |list| list,
        else => error.UnexpectedBencodeType,
    };
}

fn expectBytes(value: bencode.Value) BencodeTypeError![]const u8 {
    return switch (value) {
        .bytes => |bytes| bytes,
        else => error.UnexpectedBencodeType,
    };
}

fn expectU32(value: bencode.Value) BencodeTypeError!u32 {
    const integer = try expectU64(value);
    return std.math.cast(u32, integer) orelse error.IntegerOverflow;
}

fn expectU64(value: bencode.Value) BencodeTypeError!u64 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.NegativeInteger;
            return @intCast(integer);
        },
        else => error.UnexpectedBencodeType,
    };
}

test "parse single file torrent metainfo" {
    const input =
        "d8:announce14:http://tracker" ++ "10:created by6:varuna" ++ "4:infod6:lengthi5e" ++ "4:name8:test.bin" ++ "12:piece lengthi16384e" ++ "6:pieces20:abcdefghijklmnopqrstee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expectEqual(try info_hash.compute(input), metainfo.info_hash);
    try std.testing.expectEqualStrings("http://tracker", metainfo.announce.?);
    try std.testing.expectEqualStrings("varuna", metainfo.created_by.?);
    try std.testing.expectEqualStrings("test.bin", metainfo.name);
    try std.testing.expectEqual(@as(u32, 16384), metainfo.piece_length);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", metainfo.pieces);
    try std.testing.expectEqual(@as(usize, 1), metainfo.files.len);
    try std.testing.expectEqual(@as(u64, 5), metainfo.files[0].length);
    try std.testing.expectEqual(@as(usize, 1), metainfo.files[0].path.len);
    try std.testing.expectEqualStrings("test.bin", metainfo.files[0].path[0]);
}

test "parse multi file torrent metainfo" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi16384e" ++ "6:pieces20:abcdefghijklmnopqrstee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expectEqual(try info_hash.compute(input), metainfo.info_hash);
    try std.testing.expectEqualStrings("root", metainfo.name);
    try std.testing.expectEqual(@as(usize, 2), metainfo.files.len);
    try std.testing.expectEqual(@as(u64, 3), metainfo.files[0].length);
    try std.testing.expectEqualStrings("alpha", metainfo.files[0].path[0]);
    try std.testing.expectEqual(@as(u64, 7), metainfo.files[1].length);
    try std.testing.expectEqualStrings("beta", metainfo.files[1].path[0]);
    try std.testing.expectEqualStrings("gamma", metainfo.files[1].path[1]);
}

test "reject invalid pieces length" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces3:abcee";

    try std.testing.expectError(error.InvalidPiecesField, parse(std.testing.allocator, input));
}

test "piece hash accessors expose torrent piece metadata" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const info = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, info);

    try std.testing.expectEqual(@as(u32, 3), try info.pieceCount());
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try info.pieceHash(0));
    try std.testing.expectEqualStrings("UVWXYZ12345678", (try info.pieceHash(2))[6..]);
    try std.testing.expectEqual(@as(u64, 10), info.totalSize());
    try std.testing.expect(!info.isMultiFile());
    try std.testing.expectError(error.InvalidPieceIndex, info.pieceHash(3));
}

test "parse private flag in metainfo" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrst7:privatei1eee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expect(metainfo.private);
}

test "non-private torrent defaults to false" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const metainfo = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, metainfo);

    try std.testing.expect(!metainfo.private);
}

test "reject non-dictionary torrent root" {
    // `info_hash.findInfoBytes` runs before bencode parse and rejects
    // a non-dict root with `UnexpectedByte` (it expects 'd' at offset 0).
    // The test gets the earlier error rather than the expectDict
    // `UnexpectedBencodeType` it was originally written against.
    try std.testing.expectError(
        error.UnexpectedByte,
        parse(std.testing.allocator, "li1ei2ee"),
    );
}

test "reject non-integer piece length" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece length3:foo6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parse(std.testing.allocator, input),
    );
}

test "reject zero piece length" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi0e6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.InvalidPieceLength,
        parse(std.testing.allocator, input),
    );
}

test "reject negative file length" {
    const input =
        "d4:infod6:lengthi-1e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.NegativeInteger,
        parse(std.testing.allocator, input),
    );
}

// ── v2 / BEP 52 tests ─────────────────────────────────────

test "detect v1 version" {
    const info_entries = [_]bencode.Value.Entry{
        .{ .key = "pieces", .value = .{ .bytes = "12345678901234567890" } },
    };
    try std.testing.expectEqual(TorrentVersion.v1, detectVersion(&info_entries));
}

test "detect v2 version" {
    const info_entries = [_]bencode.Value.Entry{
        .{ .key = "file tree", .value = .{ .dict = &.{} } },
    };
    try std.testing.expectEqual(TorrentVersion.v2, detectVersion(&info_entries));
}

test "detect hybrid version" {
    const info_entries = [_]bencode.Value.Entry{
        .{ .key = "pieces", .value = .{ .bytes = "12345678901234567890" } },
        .{ .key = "file tree", .value = .{ .dict = &.{} } },
    };
    try std.testing.expectEqual(TorrentVersion.hybrid, detectVersion(&info_entries));
}

test "v1 torrent has correct version field" {
    const input =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(TorrentVersion.v1, meta.version);
    try std.testing.expect(meta.info_hash_v2 == null);
    try std.testing.expect(meta.file_tree_v2 == null);
    try std.testing.expect(meta.hasV1());
    try std.testing.expect(!meta.hasV2());
}

test "parse pure v2 torrent" {
    const pr = [_]u8{0xAA} ** 32;
    // Pure v2: has "file tree" but no "pieces"
    // info dict: { "name": "test", "piece length": 16384, "file tree": { "test.bin": { "": { "length": 5, "pieces root": <32 bytes> } } } }
    const input = "d4:infod9:file treed8:test.bind0:d6:lengthi5e11:pieces root32:" ++ pr ++ "eee4:name4:test12:piece lengthi16384eee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(TorrentVersion.v2, meta.version);
    try std.testing.expect(meta.info_hash_v2 != null);
    try std.testing.expect(meta.file_tree_v2 != null);
    try std.testing.expectEqual(@as(usize, 1), meta.file_tree_v2.?.len);
    try std.testing.expectEqual(@as(u64, 5), meta.file_tree_v2.?[0].length);
    try std.testing.expectEqual(pr, meta.file_tree_v2.?[0].pieces_root);
    try std.testing.expectEqualStrings("test.bin", meta.file_tree_v2.?[0].path[0]);
    try std.testing.expectError(error.UnsupportedForV2, meta.pieceHash(0));

    // v1 files array should be populated from file tree
    try std.testing.expectEqual(@as(usize, 1), meta.files.len);
    try std.testing.expectEqual(@as(u64, 5), meta.files[0].length);
    try std.testing.expectEqualStrings("test.bin", meta.files[0].path[0]);

    // pieces should be empty for pure v2
    try std.testing.expectEqualStrings("", meta.pieces);

    try std.testing.expect(!meta.hasV1());
    try std.testing.expect(meta.hasV2());
}

test "parse hybrid torrent" {
    const pr = [_]u8{0xCC} ** 32;
    // Hybrid: has both "pieces" and "file tree"
    const input = "d4:infod9:file treed8:test.bind0:d6:lengthi5e11:pieces root32:" ++ pr ++ "eee6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(TorrentVersion.hybrid, meta.version);
    try std.testing.expect(meta.info_hash_v2 != null);
    try std.testing.expect(meta.file_tree_v2 != null);
    try std.testing.expectEqual(@as(usize, 1), meta.file_tree_v2.?.len);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", meta.pieces);
    try std.testing.expectEqual(@as(usize, 1), meta.files.len);
    try std.testing.expect(meta.hasV1());
    try std.testing.expect(meta.hasV2());
}

// ── BEP 19 / BEP 17 web seed tests ───────────────────────

test "parse url-list as string" {
    // URL is 26 chars; bencode length prefix must match.
    const input =
        "d8:announce14:http://tracker4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrste8:url-list26:http://example.com/dl/filee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(@as(usize, 1), meta.url_list.len);
    try std.testing.expectEqualStrings("http://example.com/dl/file", meta.url_list[0]);
}

test "parse url-list as list" {
    // Both URLs are 26 chars; bencode length prefixes must match.
    const input =
        "d8:announce14:http://tracker4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrste8:url-listl26:http://example.com/dl/file26:http://mirror.com/dl2/fileee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(@as(usize, 2), meta.url_list.len);
    try std.testing.expectEqualStrings("http://example.com/dl/file", meta.url_list[0]);
    try std.testing.expectEqualStrings("http://mirror.com/dl2/file", meta.url_list[1]);
}

test "parse httpseeds" {
    // URL is 29 chars; bencode length prefix must match.
    const input =
        "d8:announce14:http://tracker9:httpseedsl29:http://seed.example.com/seed1e4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(@as(usize, 1), meta.http_seeds.len);
    try std.testing.expectEqualStrings("http://seed.example.com/seed1", meta.http_seeds[0]);
}

test "no url-list or httpseeds produces empty slices" {
    const input =
        "d8:announce14:http://tracker4:infod6:lengthi5e4:name8:test.bin12:piece lengthi16384e6:pieces20:abcdefghijklmnopqrstee";

    const meta = try parse(std.testing.allocator, input);
    defer freeMetainfo(std.testing.allocator, meta);

    try std.testing.expectEqual(@as(usize, 0), meta.url_list.len);
    try std.testing.expectEqual(@as(usize, 0), meta.http_seeds.len);
}

const std = @import("std");
const Sha1 = @import("../crypto/sha1.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const torrent = @import("../torrent/root.zig");
const writer = @import("writer.zig");

pub const PieceSet = @import("../bitfield.zig").Bitfield;

pub const RecheckState = struct {
    complete_pieces: PieceSet,
    bytes_complete: u64,

    pub fn deinit(self: *RecheckState, allocator: std.mem.Allocator) void {
        self.complete_pieces.deinit(allocator);
        self.* = undefined;
    }
};

pub const HashType = enum {
    sha1, // v1: SHA-1 (20 bytes)
    sha256, // v2: SHA-256 (32 bytes)
};

pub const PiecePlan = struct {
    piece_index: u32,
    piece_length: u32,
    expected_hash: [20]u8,
    expected_hash_v2: [32]u8 = [_]u8{0} ** 32,
    hash_type: HashType = .sha1,
    spans: []torrent.layout.Layout.Span,
};

pub fn planPieceVerification(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    piece_index: u32,
) !PiecePlan {
    const span_count = try session.layout.pieceSpanCount(piece_index);
    const spans = try allocator.alloc(torrent.layout.Layout.Span, span_count);
    errdefer allocator.free(spans);

    const mapped = try session.layout.mapPiece(piece_index, spans);
    const piece_size = try session.layout.pieceSize(piece_index);
    const version = session.layout.version;

    if (version == .v2) {
        // Pure v2: use SHA-256 and Merkle root verification
        const expected_v2 = try findV2PieceHash(session, piece_index);
        return .{
            .piece_index = piece_index,
            .piece_length = piece_size,
            .expected_hash = [_]u8{0} ** 20,
            .expected_hash_v2 = expected_v2,
            .hash_type = .sha256,
            .spans = mapped,
        };
    }

    // v1 or hybrid: use v1 SHA-1 hashes
    const piece_hash = try session.layout.pieceHash(piece_index);
    var expected_hash: [20]u8 = undefined;
    @memcpy(expected_hash[0..], piece_hash);

    return .{
        .piece_index = piece_index,
        .piece_length = piece_size,
        .expected_hash = expected_hash,
        .spans = mapped,
    };
}

/// Find the expected SHA-256 hash for a v2 piece by looking up the Merkle root
/// from the file tree. For single-piece files, the root IS the piece hash.
/// For multi-piece files, the caller needs the full Merkle tree for verification;
/// for now we return the Merkle root for the file (suitable for full-file verification).
fn findV2PieceHash(
    session: *const torrent.session.Session,
    piece_index: u32,
) ![32]u8 {
    if (session.metainfo.file_tree_v2) |v2_files| {
        for (session.layout.files, 0..) |file, file_idx| {
            if (file.length == 0) continue;
            if (piece_index >= file.first_piece and piece_index < file.end_piece_exclusive) {
                if (file_idx < v2_files.len) {
                    return v2_files[file_idx].pieces_root;
                }
            }
        }
    }
    return error.InvalidPieceIndex;
}

pub fn freePiecePlan(allocator: std.mem.Allocator, plan: PiecePlan) void {
    allocator.free(plan.spans);
}

pub fn verifyPieceBuffer(plan: PiecePlan, piece_data: []const u8) !bool {
    if (piece_data.len != plan.piece_length) {
        return error.InvalidPieceDataLength;
    }

    if (plan.hash_type == .sha256) {
        var actual: [32]u8 = undefined;
        Sha256.hash(piece_data, &actual, .{});
        return std.mem.eql(u8, actual[0..], plan.expected_hash_v2[0..]);
    }

    var actual: [20]u8 = undefined;
    Sha1.hash(piece_data, &actual, .{});
    return std.mem.eql(u8, actual[0..], plan.expected_hash[0..]);
}

/// Recheck existing data on disk, optionally skipping known-complete pieces.
/// Pass `known_complete` from resume state to avoid re-hashing verified pieces.
/// Pass `null` to force a full recheck (e.g. `varuna verify`).
pub fn recheckExistingData(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    store: *writer.PieceStore,
    known_complete: ?*const PieceSet,
) !RecheckState {
    var complete_pieces = try PieceSet.init(allocator, session.pieceCount());
    errdefer complete_pieces.deinit(allocator);

    const scratch = try allocator.alloc(u8, session.layout.piece_length);
    defer allocator.free(scratch);

    var bytes_complete: u64 = 0;
    var pieces_skipped: u32 = 0;
    var piece_index: u32 = 0;
    while (piece_index < session.pieceCount()) : (piece_index += 1) {
        // Fast path: trust resume state for this piece
        if (known_complete) |kc| {
            if (kc.has(piece_index)) {
                const plan = try planPieceVerification(allocator, session, piece_index);
                defer freePiecePlan(allocator, plan);
                try complete_pieces.set(piece_index);
                bytes_complete += plan.piece_length;
                pieces_skipped += 1;
                continue;
            }
        }

        const plan = try planPieceVerification(allocator, session, piece_index);
        defer freePiecePlan(allocator, plan);

        const piece_data = scratch[0..plan.piece_length];
        store.readPiece(plan.spans, piece_data) catch continue;
        if (try verifyPieceBuffer(plan, piece_data)) {
            try complete_pieces.set(piece_index);
            bytes_complete += plan.piece_length;
        }
    }

    return .{
        .complete_pieces = complete_pieces,
        .bytes_complete = bytes_complete,
    };
}

test "plan verification for multi file piece" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

    const loaded = try torrent.session.Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    const plan = try planPieceVerification(std.testing.allocator, &loaded, 0);
    defer freePiecePlan(std.testing.allocator, plan);

    try std.testing.expectEqual(@as(u32, 0), plan.piece_index);
    try std.testing.expectEqual(@as(u32, 4), plan.piece_length);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", plan.expected_hash[0..]);
    try std.testing.expectEqual(@as(usize, 2), plan.spans.len);
    try std.testing.expectEqual(@as(u32, 3), plan.spans[0].length);
    try std.testing.expectEqual(@as(u32, 1), plan.spans[1].length);
}

test "verify piece buffer against expected hash" {
    var hash: [20]u8 = undefined;
    Sha1.hash("spam", &hash, .{});

    const plan = PiecePlan{
        .piece_index = 0,
        .piece_length = 4,
        .expected_hash = hash,
        .spans = &.{},
    };

    try std.testing.expect(try verifyPieceBuffer(plan, "spam"));
    try std.testing.expect(!(try verifyPieceBuffer(plan, "eggs")));
    try std.testing.expectError(error.InvalidPieceDataLength, verifyPieceBuffer(plan, "sp"));
}

test "recheck existing on-disk pieces" {
    const Ring = @import("../io/ring.zig").Ring;
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    var hash0: [20]u8 = undefined;
    Sha1.hash("spam", &hash0, .{});

    var hash1: [20]u8 = undefined;
    Sha1.hash("eggs", &hash1, .{});

    const hashes = hash0 ++ hash1;
    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        "d4:infod6:lengthi8e4:name8:test.bin12:piece lengthi4e6:pieces40:{s}ee",
        .{hashes},
    );
    defer std.testing.allocator.free(input);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var store = try writer.PieceStore.init(std.testing.allocator, &session, &ring);
    defer store.deinit();

    const piece0 = try planPieceVerification(std.testing.allocator, &session, 0);
    defer freePiecePlan(std.testing.allocator, piece0);
    try store.writePiece(piece0.spans, "spam");

    var state = try recheckExistingData(std.testing.allocator, &session, &store, null);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(state.complete_pieces.has(0));
    try std.testing.expect(!state.complete_pieces.has(1));
    try std.testing.expectEqual(@as(u32, 1), state.complete_pieces.count);
    try std.testing.expectEqual(@as(u64, 4), state.bytes_complete);
}

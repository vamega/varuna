const std = @import("std");
const crypto = @import("../crypto/root.zig");
const Sha1 = crypto.Sha1;
const Sha256 = crypto.Sha256;
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
    spans_owned: bool = true,
    /// BEP 52: for multi-piece v2 files, the Merkle root (pieces_root) for the
    /// file this piece belongs to. Used together with piece_in_file and
    /// file_piece_count to verify via Merkle proof.
    v2_pieces_root: [32]u8 = [_]u8{0} ** 32,
    /// Index of this piece within its file (0-based).
    v2_piece_in_file: u32 = 0,
    /// Total number of pieces in the file this piece belongs to.
    v2_file_piece_count: u32 = 0,
};

pub fn planPieceVerification(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    piece_index: u32,
) !PiecePlan {
    return planPieceVerificationWithScratch(allocator, session, piece_index, &.{});
}

pub fn planPieceVerificationWithScratch(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    piece_index: u32,
    scratch: []torrent.layout.Layout.Span,
) !PiecePlan {
    const span_count = try session.layout.pieceSpanCount(piece_index);
    const use_scratch = span_count <= scratch.len;
    const spans = if (use_scratch)
        scratch[0..span_count]
    else
        try allocator.alloc(torrent.layout.Layout.Span, span_count);
    errdefer if (!use_scratch) allocator.free(spans);

    const mapped = try session.layout.mapPiece(piece_index, spans);
    const piece_size = try session.layout.pieceSize(piece_index);
    const version = session.layout.version;

    if (version == .v2) {
        // Pure v2: use SHA-256 and Merkle tree verification
        const v2_result = try findV2PieceHash(session, piece_index);
        // For single-piece files, pieces_root is the direct SHA-256 hash of the piece.
        // For multi-piece files, we set expected_hash_v2 to all zeros as a sentinel;
        // the actual verification uses the Merkle root via verifyPieceBuffer.
        const expected_v2 = if (v2_result.file_piece_count <= 1)
            v2_result.pieces_root
        else
            [_]u8{0} ** 32; // sentinel: Merkle verification needed
        return .{
            .piece_index = piece_index,
            .piece_length = piece_size,
            .expected_hash = [_]u8{0} ** 20,
            .expected_hash_v2 = expected_v2,
            .hash_type = .sha256,
            .spans = mapped,
            .spans_owned = !use_scratch,
            .v2_pieces_root = v2_result.pieces_root,
            .v2_piece_in_file = v2_result.piece_in_file,
            .v2_file_piece_count = v2_result.file_piece_count,
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
        .spans_owned = !use_scratch,
    };
}

/// Find the expected SHA-256 hash for a v2 piece.
///
/// For single-piece files, the pieces_root IS the leaf hash (SHA-256 of
/// the piece data). For multi-piece files, we need to verify against the
/// Merkle tree: we return a marker that tells verifyPieceBuffer to use
/// Merkle root verification instead of direct hash comparison.
///
/// The verification strategy for multi-piece v2 files:
///   1. The piece hash (SHA-256 of piece data) is computed during verification.
///   2. For single-piece files: compare directly against pieces_root.
///   3. For multi-piece files: the expected_hash_v2 is set to a sentinel,
///      and the PiecePlan includes the file's pieces_root and the piece's
///      position within the file so the caller can verify via Merkle proof.
fn findV2PieceHash(
    session: *const torrent.session.Session,
    piece_index: u32,
) !V2PieceHashResult {
    if (session.metainfo.file_tree_v2) |v2_files| {
        for (session.layout.files, 0..) |file, file_idx| {
            if (file.length == 0) continue;
            if (piece_index >= file.first_piece and piece_index < file.end_piece_exclusive) {
                if (file_idx < v2_files.len) {
                    const file_pieces = if (file.length == 0) @as(u32, 0) else @as(u32, @intCast((file.length + session.layout.piece_length - 1) / session.layout.piece_length));
                    if (file_pieces <= 1) {
                        // Single-piece file: pieces_root is the SHA-256 of the piece data
                        return .{
                            .pieces_root = v2_files[file_idx].pieces_root,
                            .piece_in_file = 0,
                            .file_piece_count = file_pieces,
                        };
                    }
                    // Multi-piece file: pieces_root is the Merkle root
                    return .{
                        .pieces_root = v2_files[file_idx].pieces_root,
                        .piece_in_file = piece_index - file.first_piece,
                        .file_piece_count = file_pieces,
                    };
                }
            }
        }
    }
    return error.InvalidPieceIndex;
}

const V2PieceHashResult = struct {
    pieces_root: [32]u8,
    piece_in_file: u32,
    file_piece_count: u32,
};

pub fn freePiecePlan(allocator: std.mem.Allocator, plan: PiecePlan) void {
    if (plan.spans_owned) allocator.free(plan.spans);
}

pub fn verifyPieceBuffer(plan: PiecePlan, piece_data: []const u8) !bool {
    if (piece_data.len != plan.piece_length) {
        return error.InvalidPieceDataLength;
    }

    if (plan.hash_type == .sha256) {
        var actual: [32]u8 = undefined;
        Sha256.hash(piece_data, &actual, .{});

        // For single-piece files, expected_hash_v2 is the direct SHA-256 hash.
        // For multi-piece files, expected_hash_v2 is all zeros (sentinel) and
        // a stand-alone piece cannot be trusted here because we do not have the
        // per-piece Merkle proof. Callers must defer acceptance until they can
        // verify the complete file Merkle root.
        if (plan.v2_file_piece_count > 1) {
            return error.DeferredMerkleVerificationRequired;
        }

        return std.mem.eql(u8, actual[0..], plan.expected_hash_v2[0..]);
    }

    var actual: [20]u8 = undefined;
    Sha1.hash(piece_data, &actual, .{});
    return std.mem.eql(u8, actual[0..], plan.expected_hash[0..]);
}

/// Verify all pieces belonging to a v2 file by building the Merkle tree
/// from their SHA-256 hashes and comparing the root against pieces_root.
///
/// This is the correct v2 verification for multi-piece files: individual
/// piece SHA-256 hashes are combined into a Merkle tree, and the tree root
/// must match the file's pieces_root from the torrent metadata.
///
/// `piece_data_slices` must contain the data for each piece in order
/// (piece 0 through piece N-1 of the file).
pub fn verifyV2FileComplete(
    allocator: std.mem.Allocator,
    pieces_root: [32]u8,
    piece_data_slices: []const []const u8,
) !bool {
    const merkle = torrent.merkle;
    if (piece_data_slices.len == 0) return false;

    // Compute SHA-256 hash for each piece
    const piece_hashes = try allocator.alloc([32]u8, piece_data_slices.len);
    defer allocator.free(piece_hashes);
    for (piece_data_slices, 0..) |piece_data, i| {
        piece_hashes[i] = merkle.hashLeaf(piece_data);
    }

    // Build the Merkle tree and compare root
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, piece_hashes);
    defer tree.deinit();

    return std.mem.eql(u8, &tree.root(), &pieces_root);
}

/// Verify a v2 file's Merkle root from pre-computed piece hashes.
/// This is more efficient than verifyV2FileComplete when piece hashes are
/// already available (e.g., from the hasher threadpool).
pub fn verifyV2MerkleRoot(
    allocator: std.mem.Allocator,
    pieces_root: [32]u8,
    piece_hashes: []const [32]u8,
) !bool {
    const merkle = torrent.merkle;
    if (piece_hashes.len == 0) return false;

    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, piece_hashes);
    defer tree.deinit();

    return std.mem.eql(u8, &tree.root(), &pieces_root);
}

/// Recheck existing data on disk, optionally skipping known-complete pieces.
/// Pass `known_complete` from resume state to avoid re-hashing verified pieces.
/// Pass `null` to force a full recheck (e.g. `varuna verify`).
///
/// For v2 torrents with multi-piece files, this does per-file Merkle root
/// verification: all pieces of a file must be readable and their combined
/// Merkle root must match the file's pieces_root from metadata.
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

    // For v2 torrents, verify per-file Merkle roots
    if (session.layout.version == .v2) {
        if (session.metainfo.file_tree_v2) |v2_files| {
            return recheckV2(allocator, session, store, known_complete, v2_files);
        }
    }

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

/// Recheck v2 torrent data using per-file Merkle root verification.
/// For each file, reads all pieces, computes their SHA-256 hashes, builds
/// the Merkle tree, and compares the root against pieces_root.
fn recheckV2(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    store: *writer.PieceStore,
    known_complete: ?*const PieceSet,
    v2_files: []const torrent.metainfo.V2File,
) !RecheckState {
    const merkle = torrent.merkle;
    var complete_pieces = try PieceSet.init(allocator, session.pieceCount());
    errdefer complete_pieces.deinit(allocator);

    const scratch = try allocator.alloc(u8, session.layout.piece_length);
    defer allocator.free(scratch);

    var bytes_complete: u64 = 0;

    for (session.layout.files, 0..) |file, file_idx| {
        if (file.length == 0) continue;
        if (file_idx >= v2_files.len) continue;

        const file_pieces = file.end_piece_exclusive - file.first_piece;
        if (file_pieces == 0) continue;

        // Check if all pieces for this file are already known complete
        if (known_complete) |kc| {
            var all_known = true;
            var pi = file.first_piece;
            while (pi < file.end_piece_exclusive) : (pi += 1) {
                if (!kc.has(pi)) {
                    all_known = false;
                    break;
                }
            }
            if (all_known) {
                // Trust resume state for this entire file
                pi = file.first_piece;
                while (pi < file.end_piece_exclusive) : (pi += 1) {
                    const psize = session.layout.pieceSize(pi) catch continue;
                    try complete_pieces.set(pi);
                    bytes_complete += psize;
                }
                continue;
            }
        }

        if (file_pieces == 1) {
            // Single-piece file: pieces_root is the direct SHA-256 hash
            const plan = try planPieceVerification(allocator, session, file.first_piece);
            defer freePiecePlan(allocator, plan);
            const piece_data = scratch[0..plan.piece_length];
            store.readPiece(plan.spans, piece_data) catch continue;
            var actual: [32]u8 = undefined;
            Sha256.hash(piece_data, &actual, .{});
            if (std.mem.eql(u8, &actual, &v2_files[file_idx].pieces_root)) {
                try complete_pieces.set(file.first_piece);
                bytes_complete += plan.piece_length;
            }
            continue;
        }

        // Multi-piece file: compute per-piece SHA-256 hashes, build Merkle tree
        const piece_hashes = allocator.alloc([32]u8, file_pieces) catch continue;
        defer allocator.free(piece_hashes);

        var all_readable = true;
        var pi: u32 = 0;
        while (pi < file_pieces) : (pi += 1) {
            const piece_index = file.first_piece + pi;
            const plan = planPieceVerification(allocator, session, piece_index) catch {
                all_readable = false;
                break;
            };
            defer freePiecePlan(allocator, plan);
            const piece_data = scratch[0..plan.piece_length];
            store.readPiece(plan.spans, piece_data) catch {
                all_readable = false;
                break;
            };
            piece_hashes[pi] = merkle.hashLeaf(piece_data);
        }

        if (!all_readable) continue;

        // Build Merkle tree and verify root
        var tree = merkle.MerkleTree.fromPieceHashes(allocator, piece_hashes) catch continue;
        defer tree.deinit();

        if (std.mem.eql(u8, &tree.root(), &v2_files[file_idx].pieces_root)) {
            // All pieces in this file are verified
            pi = 0;
            while (pi < file_pieces) : (pi += 1) {
                const piece_index = file.first_piece + pi;
                const psize = session.layout.pieceSize(piece_index) catch continue;
                try complete_pieces.set(piece_index);
                bytes_complete += psize;
            }
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

test "verify v2 single-piece file uses direct SHA-256 comparison" {
    var expected: [32]u8 = undefined;
    Sha256.hash("test", &expected, .{});

    const plan = PiecePlan{
        .piece_index = 0,
        .piece_length = 4,
        .expected_hash = [_]u8{0} ** 20,
        .expected_hash_v2 = expected,
        .hash_type = .sha256,
        .spans = &.{},
        .v2_pieces_root = expected,
        .v2_piece_in_file = 0,
        .v2_file_piece_count = 1,
    };

    try std.testing.expect(try verifyPieceBuffer(plan, "test"));
    try std.testing.expect(!(try verifyPieceBuffer(plan, "nope")));
}

test "verify v2 multi-piece file requires deferred Merkle verification" {
    const plan = PiecePlan{
        .piece_index = 0,
        .piece_length = 4,
        .expected_hash = [_]u8{0} ** 20,
        .expected_hash_v2 = [_]u8{0} ** 32, // sentinel for multi-piece
        .hash_type = .sha256,
        .spans = &.{},
        .v2_pieces_root = [_]u8{0xAA} ** 32,
        .v2_piece_in_file = 0,
        .v2_file_piece_count = 3,
    };

    try std.testing.expectError(error.DeferredMerkleVerificationRequired, verifyPieceBuffer(plan, "data"));
}

test "verifyV2MerkleRoot matches correct piece hashes" {
    const merkle = torrent.merkle;
    const h0 = merkle.hashLeaf("piece0_data");
    const h1 = merkle.hashLeaf("piece1_data");

    // Build the expected root
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &[_][32]u8{ h0, h1 });
    defer tree.deinit();
    const expected_root = tree.root();

    // Verify correct hashes match
    try std.testing.expect(try verifyV2MerkleRoot(
        std.testing.allocator,
        expected_root,
        &[_][32]u8{ h0, h1 },
    ));

    // Verify wrong hashes don't match
    const wrong = merkle.hashLeaf("wrong_data");
    try std.testing.expect(!(try verifyV2MerkleRoot(
        std.testing.allocator,
        expected_root,
        &[_][32]u8{ wrong, h1 },
    )));
}

test "verifyV2FileComplete builds tree from piece data" {
    const merkle = torrent.merkle;
    const data0 = "aaaa";
    const data1 = "bbbb";

    // Compute expected root
    const h0 = merkle.hashLeaf(data0);
    const h1 = merkle.hashLeaf(data1);
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &[_][32]u8{ h0, h1 });
    defer tree.deinit();
    const expected_root = tree.root();

    // Verify correct data matches
    try std.testing.expect(try verifyV2FileComplete(
        std.testing.allocator,
        expected_root,
        &[_][]const u8{ data0, data1 },
    ));

    // Verify wrong data doesn't match
    try std.testing.expect(!(try verifyV2FileComplete(
        std.testing.allocator,
        expected_root,
        &[_][]const u8{ data0, "cccc" },
    )));
}

test "recheck existing on-disk pieces" {
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

    var store = try writer.PieceStore.init(std.testing.allocator, &session);
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

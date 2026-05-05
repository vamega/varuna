const std = @import("std");
const merkle = @import("merkle.zig");
const metainfo = @import("metainfo.zig");
const layout = @import("layout.zig");

const log = std.log.scoped(.leaf_hashes);

/// Per-torrent storage for v2 piece leaf hashes received from peers via the
/// BEP 52 `hashes` message (msg_id 22).
///
/// In BEP 52, each piece's leaf hash (SHA-256 of the piece data) is needed
/// to verify pieces during download. For multi-piece v2 files we cannot
/// rebuild the Merkle tree until every piece is on disk, so we have to
/// trust peer-provided leaf hashes — but only after the proof attached to
/// the `hashes` message chains up to the file's authoritative `pieces_root`
/// from the torrent metadata.
///
/// This store holds the verified leaves, indexed by *global* piece index
/// (the same index space the rest of the codebase uses). Entries are
/// `null` until set, and once set they are immutable: a future hash
/// message that contradicts the stored value is rejected.
///
/// Memory: 32 bytes + 1 bit per piece. For a 1 GiB torrent at the default
/// 256 KiB piece size that's ~4 K pieces × 32 B = 128 KiB — small enough
/// to keep flat without LRU.
pub const LeafHashStore = struct {
    allocator: std.mem.Allocator,
    /// Per-piece leaf hash. `null` until verified.
    leaves: []?[32]u8,

    pub fn init(allocator: std.mem.Allocator, piece_count: u32) !LeafHashStore {
        const leaves = try allocator.alloc(?[32]u8, piece_count);
        @memset(leaves, null);
        return .{
            .allocator = allocator,
            .leaves = leaves,
        };
    }

    pub fn deinit(self: *LeafHashStore) void {
        self.allocator.free(self.leaves);
        self.* = undefined;
    }

    /// Look up the verified leaf hash for a global piece index.
    pub fn get(self: *const LeafHashStore, piece_index: u32) ?[32]u8 {
        if (piece_index >= self.leaves.len) return null;
        return self.leaves[piece_index];
    }

    /// Number of pieces with a stored verified leaf hash.
    pub fn count(self: *const LeafHashStore) u32 {
        var n: u32 = 0;
        for (self.leaves) |h| {
            if (h != null) n += 1;
        }
        return n;
    }
};

/// Verify a peer-provided BEP 52 `hashes` message (decoded form) against
/// the file's authoritative `pieces_root`, then store the contained leaves
/// in the `LeafHashStore`.
///
/// Returns true on successful verification + store, false otherwise.
///
/// Constraints (this implementation):
///   * `base_layer == 0` only — i.e. piece-level leaves, not internal
///     subtree roots. Higher-layer responses are decoded but not stored
///     here; full hash-tree fetch is a follow-up.
///   * `length` must be a power of two and the range `[index, index+length)`
///     must be `length`-aligned. This matches the canonical request shape
///     (subtree root at the parent layer is well-defined). Most v2 clients
///     send `index=0, length=padded_leaf_count, proof_layers=0` for a full
///     file leaf fetch — the simplest case and exercised by the tests.
///
/// Padding: file leaf layers are padded to the next power of two with
/// `merkle.zero_hash`. Padded leaves *are* stored as `null` in the store
/// (we only ever index by piece index, and padded-out positions are not
/// real pieces). The verification still validates the padded entries —
/// they have to match `merkle.zero_hash` or the proof would not chain up.
pub fn verifyAndStoreHashesResponse(
    store: *LeafHashStore,
    file_first_piece: u32,
    file_piece_count: u32,
    pieces_root: [32]u8,
    base_layer: u32,
    index: u32,
    received_hashes: []const [32]u8,
    proof: []const [32]u8,
) bool {
    if (base_layer != 0) {
        log.debug("ignoring non-leaf hashes response (base_layer={d})", .{base_layer});
        return false;
    }
    if (received_hashes.len == 0) return false;
    const length: u32 = @intCast(received_hashes.len);
    if (!std.math.isPowerOfTwo(length)) {
        log.debug("non-power-of-two leaf range length={d}", .{length});
        return false;
    }
    if (index % length != 0) {
        log.debug("leaf range not length-aligned: index={d} length={d}", .{ index, length });
        return false;
    }

    // Compute the subtree root from the received leaves. We allocate via
    // the store's allocator (typically the event-loop's general allocator)
    // for the working buffer — the message has already been buffered on the
    // wire, so a transient copy of the same shape adds no scaling concern.
    const current = store.allocator.alloc([32]u8, length) catch return false;
    defer store.allocator.free(current);
    @memcpy(current, received_hashes);

    var current_len: u32 = length;
    var idx_at_layer: u32 = index;
    while (current_len > 1) {
        const half = current_len / 2;
        for (0..half) |i| {
            current[i] = merkle.hashPair(current[i * 2], current[i * 2 + 1]);
        }
        current_len = half;
        idx_at_layer /= 2;
    }
    var subtree_root: [32]u8 = current[0];

    // Walk up using the proof.
    var idx = idx_at_layer;
    for (proof) |sibling| {
        if (idx & 1 == 0) {
            subtree_root = merkle.hashPair(subtree_root, sibling);
        } else {
            subtree_root = merkle.hashPair(sibling, subtree_root);
        }
        idx >>= 1;
    }

    if (!std.mem.eql(u8, &subtree_root, &pieces_root)) {
        log.debug("hash proof did not chain to expected root", .{});
        return false;
    }

    // Proof good. Store the leaves that fall inside the file's real piece
    // range. Padded-zero positions past `file_piece_count` are skipped.
    var stored: u32 = 0;
    for (received_hashes, 0..) |leaf, i| {
        const local_idx: u32 = index + @as(u32, @intCast(i));
        if (local_idx >= file_piece_count) break; // hit padding region
        const global_idx = file_first_piece + local_idx;
        if (global_idx >= store.leaves.len) break;
        if (store.leaves[global_idx]) |existing| {
            // Idempotent: same hash a second time is fine. A *different*
            // hash means the metadata or peer is buggy — log + reject.
            if (!std.mem.eql(u8, &existing, &leaf)) {
                log.warn("conflicting stored leaf hash for piece {d}", .{global_idx});
                return false;
            }
        } else {
            store.leaves[global_idx] = leaf;
            stored += 1;
        }
    }

    log.debug("stored {d} leaf hashes (file_first_piece={d}, range=[{d},{d}))", .{
        stored,
        file_first_piece,
        index,
        index + length,
    });
    return true;
}

// ── Tests ──────────────────────────────────────────────────

const testing = std.testing;

test "LeafHashStore init/get/count" {
    var store = try LeafHashStore.init(testing.allocator, 4);
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.count());
    try testing.expect(store.get(0) == null);
    try testing.expect(store.get(99) == null); // out of range -> null

    store.leaves[1] = @as([32]u8, @splat(0xAA));
    try testing.expectEqual(@as(u32, 1), store.count());
    try testing.expectEqual(@as([32]u8, @splat(0xAA)), store.get(1).?);
}

test "verifyAndStoreHashesResponse stores full leaf layer" {
    const allocator = testing.allocator;

    // Build a 4-piece file: leaves h0..h3, root = pieces_root.
    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");
    const h2 = merkle.hashLeaf("piece2");
    const h3 = merkle.hashLeaf("piece3");
    const piece_hashes = [_][32]u8{ h0, h1, h2, h3 };
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, &piece_hashes);
    defer tree.deinit();
    const root = tree.root();

    var store = try LeafHashStore.init(allocator, 4);
    defer store.deinit();

    // Peer sent us index=0, length=4, proof_layers=0 (full leaf layer).
    const ok = verifyAndStoreHashesResponse(
        &store,
        0, // file_first_piece
        4, // file_piece_count
        root,
        0, // base_layer
        0, // index
        &piece_hashes,
        &.{}, // no proof needed when range covers full layer
    );
    try testing.expect(ok);
    try testing.expectEqual(@as(u32, 4), store.count());
    try testing.expectEqual(h0, store.get(0).?);
    try testing.expectEqual(h3, store.get(3).?);
}

test "verifyAndStoreHashesResponse rejects wrong root" {
    const allocator = testing.allocator;

    const h0 = merkle.hashLeaf("p0");
    const h1 = merkle.hashLeaf("p1");
    const piece_hashes = [_][32]u8{ h0, h1 };

    var store = try LeafHashStore.init(allocator, 2);
    defer store.deinit();

    const wrong_root = @as([32]u8, @splat(0xFF));
    const ok = verifyAndStoreHashesResponse(
        &store,
        0,
        2,
        wrong_root,
        0,
        0,
        &piece_hashes,
        &.{},
    );
    try testing.expect(!ok);
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "verifyAndStoreHashesResponse with proof for partial range" {
    const allocator = testing.allocator;

    // 8 pieces -> tree depth 3 above leaves.
    var leaves: [8][32]u8 = undefined;
    for (0..8) |i| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(i), .little);
        leaves[i] = merkle.hashLeaf(&b);
    }
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, &leaves);
    defer tree.deinit();
    const root = tree.root();

    // Peer sends leaves [0..2) at base_layer 0, length 2. Proof must
    // climb 2 layers to hit the root: sibling at layer 1 (the
    // [2..4) subtree root) and sibling at layer 2 (the [4..8) subtree root).
    const sub_root_2_4 = merkle.hashPair(leaves[2], leaves[3]);
    const sub_root_4_6 = merkle.hashPair(leaves[4], leaves[5]);
    const sub_root_6_8 = merkle.hashPair(leaves[6], leaves[7]);
    const sub_root_4_8 = merkle.hashPair(sub_root_4_6, sub_root_6_8);
    const proof = [_][32]u8{ sub_root_2_4, sub_root_4_8 };

    var store = try LeafHashStore.init(allocator, 8);
    defer store.deinit();

    const partial = [_][32]u8{ leaves[0], leaves[1] };
    const ok = verifyAndStoreHashesResponse(
        &store,
        0, // file_first_piece
        8, // file_piece_count
        root,
        0,
        0, // index 0
        &partial,
        &proof,
    );
    try testing.expect(ok);
    try testing.expectEqual(@as(u32, 2), store.count());
    try testing.expectEqual(leaves[0], store.get(0).?);
    try testing.expectEqual(leaves[1], store.get(1).?);
}

test "verifyAndStoreHashesResponse rejects conflicting second store" {
    const allocator = testing.allocator;

    const h0 = merkle.hashLeaf("p0");
    const h1 = merkle.hashLeaf("p1");
    const piece_hashes = [_][32]u8{ h0, h1 };
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, &piece_hashes);
    defer tree.deinit();

    var store = try LeafHashStore.init(allocator, 2);
    defer store.deinit();

    // First store: succeeds.
    try testing.expect(verifyAndStoreHashesResponse(
        &store,
        0,
        2,
        tree.root(),
        0,
        0,
        &piece_hashes,
        &.{},
    ));

    // Manually tamper with stored value, then try to store the *real* hash again.
    // The real hash differs from the tampered value -> conflict rejection.
    store.leaves[0] = @as([32]u8, @splat(0xCC));
    try testing.expect(!verifyAndStoreHashesResponse(
        &store,
        0,
        2,
        tree.root(),
        0,
        0,
        &piece_hashes,
        &.{},
    ));
}

test "verifyAndStoreHashesResponse rejects non-power-of-two length" {
    const allocator = testing.allocator;
    var store = try LeafHashStore.init(allocator, 3);
    defer store.deinit();

    var hashes: [3][32]u8 = undefined;
    @memset(&hashes, @as([32]u8, @splat(0)));

    try testing.expect(!verifyAndStoreHashesResponse(
        &store,
        0,
        3,
        @as([32]u8, @splat(0)),
        0,
        0,
        &hashes,
        &.{},
    ));
}

test "BEP 52 hashes message round-trip stores leaves" {
    // Smoke test: build a hashes-message payload as a peer would send it,
    // decode it, run it through verifyAndStoreHashesResponse, and assert
    // the per-piece leaves end up in the store.
    const allocator = testing.allocator;
    const hash_exchange = @import("../net/hash_exchange.zig");

    // 4-piece file with a real Merkle root.
    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");
    const h2 = merkle.hashLeaf("piece2");
    const h3 = merkle.hashLeaf("piece3");
    const piece_hashes = [_][32]u8{ h0, h1, h2, h3 };
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, &piece_hashes);
    defer tree.deinit();
    const root = tree.root();

    // Peer constructs and sends a "full leaf layer" hashes response.
    const sent = hash_exchange.HashesResponse{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 4,
        .proof_layers = 0,
        .hashes = &piece_hashes,
        .proof = &.{},
    };
    const wire = try hash_exchange.encodeHashesResponse(allocator, sent);
    defer allocator.free(wire);

    // We decode the wire form (as the receiver would).
    const got = try hash_exchange.decodeHashesResponse(allocator, wire);
    defer hash_exchange.freeHashesResponse(allocator, got);

    // Verify + store.
    var store = try LeafHashStore.init(allocator, 4);
    defer store.deinit();

    try testing.expect(verifyAndStoreHashesResponse(
        &store,
        0, // file_first_piece
        4, // file_piece_count
        root,
        got.base_layer,
        got.index,
        got.hashes,
        got.proof,
    ));

    try testing.expectEqual(@as(u32, 4), store.count());
    try testing.expectEqual(h0, store.get(0).?);
    try testing.expectEqual(h1, store.get(1).?);
    try testing.expectEqual(h2, store.get(2).?);
    try testing.expectEqual(h3, store.get(3).?);
}

test "verifyAndStoreHashesResponse skips padded positions past file_piece_count" {
    const allocator = testing.allocator;

    // 3-piece file padded to 4 leaves.
    const h0 = merkle.hashLeaf("p0");
    const h1 = merkle.hashLeaf("p1");
    const h2 = merkle.hashLeaf("p2");
    const piece_hashes_padded = [_][32]u8{ h0, h1, h2, merkle.zero_hash };
    var tree = try merkle.MerkleTree.fromPieceHashes(allocator, &piece_hashes_padded);
    defer tree.deinit();

    var store = try LeafHashStore.init(allocator, 3);
    defer store.deinit();

    const ok = verifyAndStoreHashesResponse(
        &store,
        0,
        3, // only 3 real pieces
        tree.root(),
        0,
        0,
        &piece_hashes_padded,
        &.{},
    );
    try testing.expect(ok);
    try testing.expectEqual(@as(u32, 3), store.count());
    try testing.expectEqual(h0, store.get(0).?);
    try testing.expectEqual(h2, store.get(2).?);
}

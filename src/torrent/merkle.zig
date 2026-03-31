const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// SHA-256 Merkle tree for BEP 52 per-file piece verification.
///
/// In BitTorrent v2, each file has a Merkle hash tree where:
/// - Leaf nodes = SHA-256 of piece data (piece_length bytes each)
/// - Internal nodes = SHA-256(left_child ++ right_child)
/// - The tree is a balanced binary tree, padded with zero-hashes
/// - The root is stored in the .torrent as `pieces root` per file
pub const MerkleTree = struct {
    /// Flat array of node hashes in level-order.
    /// Layer 0 = leaves (piece hashes), layer N = root.
    /// Each layer is a slice of 32-byte SHA-256 digests.
    layers: []const [][32]u8,
    allocator: std.mem.Allocator,

    pub fn fromPieceHashes(allocator: std.mem.Allocator, piece_hashes: []const [32]u8) !MerkleTree {
        if (piece_hashes.len == 0) return error.EmptyPieceHashes;

        // Pad leaf count to the next power of 2
        const padded_count = nextPowerOf2(piece_hashes.len);

        var layer_list = std.ArrayList([][32]u8).empty;
        defer {
            // On error, free any layers we already allocated
            for (layer_list.items) |layer| allocator.free(layer);
            layer_list.deinit(allocator);
        }

        // Build leaf layer (layer 0)
        const leaves = try allocator.alloc([32]u8, padded_count);
        @memcpy(leaves[0..piece_hashes.len], piece_hashes);
        // Pad with zero hashes
        for (leaves[piece_hashes.len..]) |*h| h.* = zero_hash;
        try layer_list.append(allocator, leaves);

        // Build parent layers until we reach the root
        var current = leaves;
        while (current.len > 1) {
            const parent_count = current.len / 2;
            const parents = try allocator.alloc([32]u8, parent_count);
            for (0..parent_count) |i| {
                parents[i] = hashPair(current[i * 2], current[i * 2 + 1]);
            }
            try layer_list.append(allocator, parents);
            current = parents;
        }

        const layers = try layer_list.toOwnedSlice(allocator);
        return .{
            .layers = layers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MerkleTree) void {
        for (self.layers) |layer| self.allocator.free(layer);
        self.allocator.free(self.layers);
        self.* = undefined;
    }

    /// Return the Merkle root (top-level hash).
    pub fn root(self: *const MerkleTree) [32]u8 {
        return self.layers[self.layers.len - 1][0];
    }

    /// Verify a piece by computing its SHA-256 and comparing against the
    /// expected leaf hash in the tree.
    pub fn verifyPiece(self: *const MerkleTree, piece_index: u32, piece_data: []const u8) bool {
        if (piece_index >= self.layers[0].len) return false;
        const actual = hashLeaf(piece_data);
        return std.mem.eql(u8, &actual, &self.layers[0][piece_index]);
    }

    /// Extract the Merkle proof (sibling hashes) for a given piece index.
    /// The proof can be used to verify a piece without the full tree.
    pub fn proofForPiece(self: *const MerkleTree, allocator: std.mem.Allocator, piece_index: u32) ![][32]u8 {
        if (piece_index >= self.layers[0].len) return error.InvalidPieceIndex;

        const proof_len = self.layers.len - 1; // number of layers excluding the root
        const proof = try allocator.alloc([32]u8, proof_len);
        errdefer allocator.free(proof);

        var idx: u32 = piece_index;
        for (0..proof_len) |layer| {
            const sibling = idx ^ 1; // flip the last bit to get the sibling
            proof[layer] = self.layers[layer][sibling];
            idx >>= 1;
        }

        return proof;
    }

    /// Verify a piece using a Merkle proof against a known root hash.
    pub fn verifyProof(expected_root: [32]u8, piece_index: u32, piece_hash: [32]u8, proof: []const [32]u8) bool {
        var current = piece_hash;
        var idx = piece_index;
        for (proof) |sibling| {
            if (idx & 1 == 0) {
                current = hashPair(current, sibling);
            } else {
                current = hashPair(sibling, current);
            }
            idx >>= 1;
        }
        return std.mem.eql(u8, &current, &expected_root);
    }
};

/// Hash a single piece (leaf node) using SHA-256.
pub fn hashLeaf(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return digest;
}

/// Hash two child nodes to produce a parent node.
pub fn hashPair(left: [32]u8, right: [32]u8) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&left);
    hasher.update(&right);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// The zero hash used for padding incomplete Merkle tree layers.
/// SHA-256 of empty data.
pub const zero_hash: [32]u8 = blk: {
    @setEvalBranchQuota(10000);
    var digest: [32]u8 = undefined;
    Sha256.hash(&.{}, &digest, .{});
    break :blk digest;
};

/// Round up to the next power of 2 (minimum 1).
fn nextPowerOf2(n: usize) usize {
    if (n <= 1) return 1;
    var v = n - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    return v + 1;
}

// ── Tests ──────────────────────────────────────────────────

test "hash leaf produces SHA-256 of data" {
    const data = "hello world";
    const hash = hashLeaf(data);
    // Known SHA-256 of "hello world"
    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    try std.testing.expectEqual(expected, hash);
}

test "hash pair combines two hashes" {
    const a = hashLeaf("aaa");
    const b = hashLeaf("bbb");
    const combined = hashPair(a, b);
    // Verify it is SHA-256(a ++ b)
    var hasher = Sha256.init(.{});
    hasher.update(&a);
    hasher.update(&b);
    var expected: [32]u8 = undefined;
    hasher.final(&expected);
    try std.testing.expectEqual(expected, combined);
}

test "single leaf Merkle tree" {
    const leaf = hashLeaf("piece0");
    const hashes = [_][32]u8{leaf};
    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    // Single leaf: root == leaf
    try std.testing.expectEqual(leaf, tree.root());
    try std.testing.expect(tree.verifyPiece(0, "piece0"));
    try std.testing.expect(!tree.verifyPiece(0, "wrong"));
}

test "two leaf Merkle tree" {
    const h0 = hashLeaf("piece0");
    const h1 = hashLeaf("piece1");
    const hashes = [_][32]u8{ h0, h1 };
    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    const expected_root = hashPair(h0, h1);
    try std.testing.expectEqual(expected_root, tree.root());
    try std.testing.expectEqual(@as(usize, 2), tree.layers.len); // leaves + root
}

test "three leaf Merkle tree pads to four" {
    const h0 = hashLeaf("p0");
    const h1 = hashLeaf("p1");
    const h2 = hashLeaf("p2");
    const hashes = [_][32]u8{ h0, h1, h2 };
    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    // Should pad to 4 leaves
    try std.testing.expectEqual(@as(usize, 4), tree.layers[0].len);
    try std.testing.expectEqual(@as(usize, 3), tree.layers.len); // 4 leaves -> 2 internal -> 1 root

    // Verify the padded leaf is zero_hash
    try std.testing.expectEqual(zero_hash, tree.layers[0][3]);

    // Root = hash(hash(h0,h1), hash(h2, zero_hash))
    const left = hashPair(h0, h1);
    const right = hashPair(h2, zero_hash);
    const expected_root = hashPair(left, right);
    try std.testing.expectEqual(expected_root, tree.root());
}

test "Merkle proof verification roundtrip" {
    const h0 = hashLeaf("piece0");
    const h1 = hashLeaf("piece1");
    const h2 = hashLeaf("piece2");
    const h3 = hashLeaf("piece3");
    const hashes = [_][32]u8{ h0, h1, h2, h3 };
    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    const tree_root = tree.root();

    // Verify proof for each piece
    for (0..4) |i| {
        const proof = try tree.proofForPiece(std.testing.allocator, @intCast(i));
        defer std.testing.allocator.free(proof);

        try std.testing.expect(MerkleTree.verifyProof(tree_root, @intCast(i), hashes[i], proof));
        // Wrong hash should fail
        try std.testing.expect(!MerkleTree.verifyProof(tree_root, @intCast(i), zero_hash, proof));
    }
}

test "Merkle proof fails with wrong root" {
    const h0 = hashLeaf("piece0");
    const h1 = hashLeaf("piece1");
    const hashes = [_][32]u8{ h0, h1 };
    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    const proof = try tree.proofForPiece(std.testing.allocator, 0);
    defer std.testing.allocator.free(proof);

    var wrong_root: [32]u8 = [_]u8{0xff} ** 32;
    _ = &wrong_root;
    try std.testing.expect(!MerkleTree.verifyProof(wrong_root, 0, h0, proof));
}

test "empty piece hashes rejected" {
    const empty: []const [32]u8 = &.{};
    try std.testing.expectError(error.EmptyPieceHashes, MerkleTree.fromPieceHashes(std.testing.allocator, empty));
}

test "nextPowerOf2 correctness" {
    try std.testing.expectEqual(@as(usize, 1), nextPowerOf2(0));
    try std.testing.expectEqual(@as(usize, 1), nextPowerOf2(1));
    try std.testing.expectEqual(@as(usize, 2), nextPowerOf2(2));
    try std.testing.expectEqual(@as(usize, 4), nextPowerOf2(3));
    try std.testing.expectEqual(@as(usize, 4), nextPowerOf2(4));
    try std.testing.expectEqual(@as(usize, 8), nextPowerOf2(5));
    try std.testing.expectEqual(@as(usize, 16), nextPowerOf2(9));
    try std.testing.expectEqual(@as(usize, 1024), nextPowerOf2(1000));
}

test "large Merkle tree with 100 pieces" {
    var piece_hashes: [100][32]u8 = undefined;
    for (0..100) |i| {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(i), .little);
        piece_hashes[i] = hashLeaf(&buf);
    }

    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &piece_hashes);
    defer tree.deinit();

    // Padded to 128 leaves
    try std.testing.expectEqual(@as(usize, 128), tree.layers[0].len);
    // 128 -> 64 -> 32 -> 16 -> 8 -> 4 -> 2 -> 1 = 8 layers
    try std.testing.expectEqual(@as(usize, 8), tree.layers.len);
    try std.testing.expectEqual(@as(usize, 1), tree.layers[7].len);

    // Verify proof for the first and last real pieces
    const tree_root = tree.root();
    {
        const proof = try tree.proofForPiece(std.testing.allocator, 0);
        defer std.testing.allocator.free(proof);
        try std.testing.expect(MerkleTree.verifyProof(tree_root, 0, piece_hashes[0], proof));
    }
    {
        const proof = try tree.proofForPiece(std.testing.allocator, 99);
        defer std.testing.allocator.free(proof);
        try std.testing.expect(MerkleTree.verifyProof(tree_root, 99, piece_hashes[99], proof));
    }
}

test "verify piece data matches leaf in tree" {
    const data0 = "hello piece zero";
    const data1 = "hello piece one!";
    const h0 = hashLeaf(data0);
    const h1 = hashLeaf(data1);
    const hashes = [_][32]u8{ h0, h1 };

    var tree = try MerkleTree.fromPieceHashes(std.testing.allocator, &hashes);
    defer tree.deinit();

    try std.testing.expect(tree.verifyPiece(0, data0));
    try std.testing.expect(tree.verifyPiece(1, data1));
    try std.testing.expect(!tree.verifyPiece(0, data1));
    try std.testing.expect(!tree.verifyPiece(1, data0));
    try std.testing.expect(!tree.verifyPiece(2, data0)); // out of range
}

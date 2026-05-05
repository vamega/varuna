const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");
const merkle = @import("../torrent/merkle.zig");

/// BEP 52 hash exchange message types.
/// These are standard (non-extension) peer wire message IDs.
pub const msg_hash_request: u8 = 21;
pub const msg_hashes: u8 = 22;
pub const msg_hash_reject: u8 = 23;

/// A hash request message: the peer asks us for Merkle proof hashes.
///
/// Wire format (after 4-byte length prefix + msg_id byte):
///   file_index: u32 (big-endian) -- index of the file in the v2 file tree
///   base_layer: u32 (big-endian) -- the tree layer being requested (0 = piece/leaf layer)
///   index:      u32 (big-endian) -- starting hash index within that layer
///   length:     u32 (big-endian) -- number of hashes requested
///   proof_layers: u32 (big-endian) -- number of uncle/proof layers to include
pub const HashRequest = struct {
    file_index: u32,
    base_layer: u32,
    index: u32,
    length: u32,
    proof_layers: u32,
};

/// A hashes response message: we send Merkle proof hashes to the peer.
///
/// Wire format (after 4-byte length prefix + msg_id byte):
///   file_index: u32 (big-endian)
///   base_layer: u32 (big-endian)
///   index:      u32 (big-endian)
///   length:     u32 (big-endian)
///   proof_layers: u32 (big-endian)
///   hashes: length * 32 bytes (the requested hashes from base_layer)
///   proof:  proof_layers * 32 bytes (uncle hashes for verification)
pub const HashesResponse = struct {
    file_index: u32,
    base_layer: u32,
    index: u32,
    length: u32,
    proof_layers: u32,
    hashes: []const [32]u8,
    proof: []const [32]u8,
};

/// A hash reject message: we cannot provide the requested hashes.
///
/// Wire format is identical to HashRequest (echo back the request parameters).
pub const HashReject = HashRequest;

/// Decode a hash request message from the wire payload (after msg_id byte).
pub fn decodeHashRequest(payload: []const u8) !HashRequest {
    if (payload.len < 20) return error.MessageTooShort;
    return .{
        .file_index = std.mem.readInt(u32, payload[0..4], .big),
        .base_layer = std.mem.readInt(u32, payload[4..8], .big),
        .index = std.mem.readInt(u32, payload[8..12], .big),
        .length = std.mem.readInt(u32, payload[12..16], .big),
        .proof_layers = std.mem.readInt(u32, payload[16..20], .big),
    };
}

/// Encode a hash request message (without the framing 4-byte length + msg_id).
pub fn encodeHashRequest(req: HashRequest) [20]u8 {
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], req.file_index, .big);
    std.mem.writeInt(u32, buf[4..8], req.base_layer, .big);
    std.mem.writeInt(u32, buf[8..12], req.index, .big);
    std.mem.writeInt(u32, buf[12..16], req.length, .big);
    std.mem.writeInt(u32, buf[16..20], req.proof_layers, .big);
    return buf;
}

/// Encode a hashes response message payload (after msg_id byte).
pub fn encodeHashesResponse(allocator: std.mem.Allocator, resp: HashesResponse) ![]u8 {
    const header_len = 20;
    const hashes_len = resp.hashes.len * 32;
    const proof_len = resp.proof.len * 32;
    const total = header_len + hashes_len + proof_len;

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);

    std.mem.writeInt(u32, buf[0..4], resp.file_index, .big);
    std.mem.writeInt(u32, buf[4..8], resp.base_layer, .big);
    std.mem.writeInt(u32, buf[8..12], resp.index, .big);
    std.mem.writeInt(u32, buf[12..16], resp.length, .big);
    std.mem.writeInt(u32, buf[16..20], resp.proof_layers, .big);

    var offset: usize = header_len;
    for (resp.hashes) |h| {
        @memcpy(buf[offset .. offset + 32], &h);
        offset += 32;
    }
    for (resp.proof) |h| {
        @memcpy(buf[offset .. offset + 32], &h);
        offset += 32;
    }

    return buf;
}

/// Decode a hashes response message from the wire payload (after msg_id byte).
pub fn decodeHashesResponse(allocator: std.mem.Allocator, payload: []const u8) !HashesResponse {
    if (payload.len < 20) return error.MessageTooShort;

    const file_index = std.mem.readInt(u32, payload[0..4], .big);
    const base_layer = std.mem.readInt(u32, payload[4..8], .big);
    const index = std.mem.readInt(u32, payload[8..12], .big);
    const length = std.mem.readInt(u32, payload[12..16], .big);
    const proof_layers = std.mem.readInt(u32, payload[16..20], .big);

    const hashes_bytes = @as(usize, length) * 32;
    const proof_bytes = @as(usize, proof_layers) * 32;
    const expected_len = 20 + hashes_bytes + proof_bytes;

    if (payload.len < expected_len) return error.MessageTooShort;

    const hashes = try allocator.alloc([32]u8, length);
    errdefer allocator.free(hashes);
    for (0..length) |i| {
        const start = 20 + i * 32;
        @memcpy(&hashes[i], payload[start .. start + 32]);
    }

    const proof = try allocator.alloc([32]u8, proof_layers);
    errdefer allocator.free(proof);
    for (0..proof_layers) |i| {
        const start = 20 + hashes_bytes + i * 32;
        @memcpy(&proof[i], payload[start .. start + 32]);
    }

    return .{
        .file_index = file_index,
        .base_layer = base_layer,
        .index = index,
        .length = length,
        .proof_layers = proof_layers,
        .hashes = hashes,
        .proof = proof,
    };
}

/// Free a decoded HashesResponse.
pub fn freeHashesResponse(allocator: std.mem.Allocator, resp: HashesResponse) void {
    allocator.free(resp.hashes);
    allocator.free(resp.proof);
}

/// Build a hashes response for a given hash request using a Merkle tree.
/// Returns null if the request cannot be fulfilled (e.g., invalid layer/index).
pub fn buildHashesFromTree(
    allocator: std.mem.Allocator,
    tree: *const merkle.MerkleTree,
    req: HashRequest,
) !?HashesResponse {
    // Validate base_layer is within tree range
    if (req.base_layer >= tree.layers.len) return null;

    const layer = tree.layers[req.base_layer];
    const end_index = @as(u64, req.index) + @as(u64, req.length);
    if (end_index > layer.len) return null;
    if (req.length == 0) return null;

    // Extract the requested hashes from the layer
    const hashes = try allocator.alloc([32]u8, req.length);
    errdefer allocator.free(hashes);
    @memcpy(hashes, layer[req.index .. req.index + req.length]);

    // Build proof (uncle hashes up the tree for verification)
    const max_proof = @min(req.proof_layers, @as(u32, @intCast(tree.layers.len)) - req.base_layer - 1);
    const proof = try allocator.alloc([32]u8, max_proof);
    errdefer allocator.free(proof);

    // For each proof layer, we need the sibling hash of the subtree root
    // at that layer. The subtree covers indices [index, index+length) at base_layer.
    // At each higher layer, the range halves and we take the sibling of the range.
    var range_start: u32 = req.index;
    var range_end: u32 = req.index + req.length;
    for (0..max_proof) |pi| {
        const proof_layer = req.base_layer + @as(u32, @intCast(pi)) + 1;
        if (proof_layer >= tree.layers.len) break;

        // Parent range
        const parent_start = range_start / 2;
        const parent_end = (range_end + 1) / 2;
        _ = parent_end;

        // The sibling of the subtree at this level
        const sibling = parent_start ^ 1;
        const parent_layer = tree.layers[proof_layer];
        if (sibling < parent_layer.len) {
            proof[pi] = parent_layer[sibling];
        } else {
            proof[pi] = merkle.zero_hash;
        }

        range_start = parent_start;
        range_end = (range_end + 1) / 2;
    }

    return .{
        .file_index = req.file_index,
        .base_layer = req.base_layer,
        .index = req.index,
        .length = req.length,
        .proof_layers = max_proof,
        .hashes = hashes,
        .proof = proof,
    };
}

// ── Tests ──────────────────────────────────────────────────

test "encode and decode hash request roundtrip" {
    const req = HashRequest{
        .file_index = 1,
        .base_layer = 0,
        .index = 5,
        .length = 3,
        .proof_layers = 2,
    };
    const encoded = encodeHashRequest(req);
    const decoded = try decodeHashRequest(&encoded);
    try std.testing.expectEqual(req.file_index, decoded.file_index);
    try std.testing.expectEqual(req.base_layer, decoded.base_layer);
    try std.testing.expectEqual(req.index, decoded.index);
    try std.testing.expectEqual(req.length, decoded.length);
    try std.testing.expectEqual(req.proof_layers, decoded.proof_layers);
}

test "decode hash request rejects short payload" {
    const short = @as([19]u8, @splat(0));
    try std.testing.expectError(error.MessageTooShort, decodeHashRequest(&short));
}

test "encode and decode hashes response roundtrip" {
    const h0 = merkle.hashLeaf("data0");
    const h1 = merkle.hashLeaf("data1");
    const p0 = merkle.hashLeaf("proof0");
    const hashes = [_][32]u8{ h0, h1 };
    const proof = [_][32]u8{p0};

    const resp = HashesResponse{
        .file_index = 0,
        .base_layer = 0,
        .index = 2,
        .length = 2,
        .proof_layers = 1,
        .hashes = &hashes,
        .proof = &proof,
    };

    const encoded = try encodeHashesResponse(std.testing.allocator, resp);
    defer std.testing.allocator.free(encoded);

    const decoded = try decodeHashesResponse(std.testing.allocator, encoded);
    defer freeHashesResponse(std.testing.allocator, decoded);

    try std.testing.expectEqual(resp.file_index, decoded.file_index);
    try std.testing.expectEqual(resp.base_layer, decoded.base_layer);
    try std.testing.expectEqual(resp.index, decoded.index);
    try std.testing.expectEqual(resp.length, decoded.length);
    try std.testing.expectEqual(resp.proof_layers, decoded.proof_layers);
    try std.testing.expectEqual(@as(usize, 2), decoded.hashes.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.proof.len);
    try std.testing.expectEqual(h0, decoded.hashes[0]);
    try std.testing.expectEqual(h1, decoded.hashes[1]);
    try std.testing.expectEqual(p0, decoded.proof[0]);
}

test "decode hashes response rejects truncated payload" {
    // header (20) + 1 hash (32) = 52, but payload claims length=2
    var buf: [52]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0, .big); // file_index
    std.mem.writeInt(u32, buf[4..8], 0, .big); // base_layer
    std.mem.writeInt(u32, buf[8..12], 0, .big); // index
    std.mem.writeInt(u32, buf[12..16], 2, .big); // length=2 but only 1 hash in payload
    std.mem.writeInt(u32, buf[16..20], 0, .big); // proof_layers
    try std.testing.expectError(error.MessageTooShort, decodeHashesResponse(std.testing.allocator, &buf));
}

test "build hashes from Merkle tree" {
    // Build a 4-piece Merkle tree
    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");
    const h2 = merkle.hashLeaf("piece2");
    const h3 = merkle.hashLeaf("piece3");
    const piece_hashes = [_][32]u8{ h0, h1, h2, h3 };
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &piece_hashes);
    defer tree.deinit();

    // Request hashes for pieces 0-1 at the leaf layer
    const req = HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 2,
        .proof_layers = 1,
    };
    const resp = (try buildHashesFromTree(std.testing.allocator, &tree, req)).?;
    defer freeHashesResponse(std.testing.allocator, resp);

    try std.testing.expectEqual(@as(usize, 2), resp.hashes.len);
    try std.testing.expectEqual(h0, resp.hashes[0]);
    try std.testing.expectEqual(h1, resp.hashes[1]);
}

test "build hashes rejects invalid layer" {
    const h0 = merkle.hashLeaf("p0");
    const piece_hashes = [_][32]u8{h0};
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &piece_hashes);
    defer tree.deinit();

    const req = HashRequest{
        .file_index = 0,
        .base_layer = 99, // way beyond tree depth
        .index = 0,
        .length = 1,
        .proof_layers = 0,
    };
    const result = try buildHashesFromTree(std.testing.allocator, &tree, req);
    try std.testing.expect(result == null);
}

test "build hashes rejects out-of-range index" {
    const h0 = merkle.hashLeaf("p0");
    const h1 = merkle.hashLeaf("p1");
    const piece_hashes = [_][32]u8{ h0, h1 };
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &piece_hashes);
    defer tree.deinit();

    const req = HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 1,
        .length = 2, // would go past end (only 2 leaves total)
        .proof_layers = 0,
    };
    const result = try buildHashesFromTree(std.testing.allocator, &tree, req);
    try std.testing.expect(result == null);
}

test "build hashes rejects zero length" {
    const h0 = merkle.hashLeaf("p0");
    const piece_hashes = [_][32]u8{h0};
    var tree = try merkle.MerkleTree.fromPieceHashes(std.testing.allocator, &piece_hashes);
    defer tree.deinit();

    const req = HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 0,
        .proof_layers = 0,
    };
    const result = try buildHashesFromTree(std.testing.allocator, &tree, req);
    try std.testing.expect(result == null);
}

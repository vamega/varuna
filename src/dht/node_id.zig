const std = @import("std");

/// 160-bit node identifier used in the Kademlia DHT (BEP 5).
pub const NodeId = [20]u8;

/// Compact node info: ID + network address + liveness state.
pub const NodeInfo = struct {
    id: NodeId,
    address: std.net.Address,
    last_seen: i64 = 0, // unix timestamp
    ever_responded: bool = false, // "good" node qualifier
    failed_queries: u8 = 0, // consecutive failures
};

/// Generate a random 160-bit node ID.
pub fn generate() NodeId {
    var id: NodeId = undefined;
    std.crypto.random.bytes(&id);
    return id;
}

/// Compute the XOR distance between two node IDs.
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
    var result: NodeId = undefined;
    for (0..20) |i| {
        result[i] = a[i] ^ b[i];
    }
    return result;
}

/// Returns the index of the highest set bit in xorDistance(a, b).
/// Range 0..159. Determines which k-bucket the node belongs in.
/// Returns null if a == b (distance is zero).
pub fn distanceBucket(a: NodeId, b: NodeId) ?u8 {
    const dist = xorDistance(a, b);
    for (0..20) |i| {
        if (dist[i] != 0) {
            // Find highest set bit in this byte
            const byte_idx: u8 = @intCast(i);
            const bit_pos = 7 - @as(u8, @intCast(@ctz(
                @bitReverse(dist[i]),
            )));
            return (19 - byte_idx) * 8 + bit_pos;
        }
    }
    return null; // same ID
}

/// Compare two node IDs by XOR distance to a target.
/// Returns true if a is closer to target than b.
pub fn isCloser(target: NodeId, a: NodeId, b: NodeId) bool {
    const dist_a = xorDistance(target, a);
    const dist_b = xorDistance(target, b);
    return order(dist_a, dist_b) == .lt;
}

/// Lexicographic ordering of NodeIds (used for distance comparison).
pub fn order(a: NodeId, b: NodeId) std.math.Order {
    for (0..20) |i| {
        if (a[i] < b[i]) return .lt;
        if (a[i] > b[i]) return .gt;
    }
    return .eq;
}

/// Generate a random node ID that falls within a specific bucket range.
/// Used for bucket refresh: generates an ID whose XOR distance from
/// `own_id` has its highest bit at position `bucket_index`.
pub fn randomIdInBucket(own_id: NodeId, bucket_index: u8) NodeId {
    var id: NodeId = undefined;
    std.crypto.random.bytes(&id);

    // XOR with own_id to get a distance, then set the correct bit pattern
    var dist = xorDistance(own_id, id);

    // Clear all bits above bucket_index
    const byte_idx = 19 - (bucket_index / 8);
    const bit_idx = bucket_index % 8;

    // Clear all bytes before (more significant than) the target byte
    for (0..byte_idx) |i| {
        dist[i] = 0;
    }

    // In the target byte, clear bits above the target bit and set it
    const mask: u8 = @as(u8, 1) << @intCast(bit_idx);
    dist[byte_idx] = (dist[byte_idx] & (mask - 1)) | mask;

    // XOR back with own_id to get the actual node ID
    var result: NodeId = undefined;
    for (0..20) |i| {
        result[i] = own_id[i] ^ dist[i];
    }
    return result;
}

/// Encode a NodeInfo as 26 bytes of compact node info (BEP 5).
/// Format: 20-byte node ID + 4-byte IPv4 address + 2-byte port (big-endian).
pub fn encodeCompactNode(node: NodeInfo) [26]u8 {
    var buf: [26]u8 = undefined;
    @memcpy(buf[0..20], &node.id);
    const addr_bytes: [4]u8 = @bitCast(node.address.in.sa.addr);
    @memcpy(buf[20..24], &addr_bytes);
    std.mem.writeInt(u16, buf[24..26], node.address.getPort(), .big);
    return buf;
}

/// Decode 26 bytes of compact node info into a NodeInfo.
pub fn decodeCompactNode(data: *const [26]u8) NodeInfo {
    var id: NodeId = undefined;
    @memcpy(&id, data[0..20]);
    const addr_bytes = data[20..24].*;
    const port = std.mem.readInt(u16, data[24..26], .big);
    return .{
        .id = id,
        .address = std.net.Address.initIp4(addr_bytes, port),
    };
}

/// Decode a compact nodes string (multiple 26-byte entries).
pub fn decodeCompactNodes(allocator: std.mem.Allocator, data: []const u8) ![]NodeInfo {
    if (data.len % 26 != 0) return error.InvalidCompactNodes;
    const count = data.len / 26;
    const nodes = try allocator.alloc(NodeInfo, count);
    for (0..count) |i| {
        nodes[i] = decodeCompactNode(data[i * 26 ..][0..26]);
    }
    return nodes;
}

/// Encode multiple NodeInfos into a compact nodes string.
pub fn encodeCompactNodes(allocator: std.mem.Allocator, nodes: []const NodeInfo) ![]u8 {
    const buf = try allocator.alloc(u8, nodes.len * 26);
    for (nodes, 0..) |node, i| {
        const compact = encodeCompactNode(node);
        @memcpy(buf[i * 26 ..][0..26], &compact);
    }
    return buf;
}

// ── Tests ──────────────────────────────────────────────

test "xorDistance is symmetric" {
    const a = generate();
    const b = generate();
    const d1 = xorDistance(a, b);
    const d2 = xorDistance(b, a);
    try std.testing.expectEqual(d1, d2);
}

test "xorDistance with self is zero" {
    const a = generate();
    const d = xorDistance(a, a);
    try std.testing.expectEqual(d, [_]u8{0} ** 20);
}

test "distanceBucket returns null for same ID" {
    const a = generate();
    try std.testing.expect(distanceBucket(a, a) == null);
}

test "distanceBucket returns correct bucket" {
    var a: NodeId = [_]u8{0} ** 20;
    var b: NodeId = [_]u8{0} ** 20;

    // Set highest bit in b: byte 0, bit 7 -> bucket 159
    b[0] = 0x80;
    try std.testing.expectEqual(@as(u8, 159), distanceBucket(a, b).?);

    // Lowest bit: byte 19, bit 0 -> bucket 0
    b[0] = 0;
    b[19] = 0x01;
    try std.testing.expectEqual(@as(u8, 0), distanceBucket(a, b).?);

    // Byte 10, bit 4 -> bucket (19-10)*8 + 4 = 76
    b[19] = 0;
    b[10] = 0x10;
    try std.testing.expectEqual(@as(u8, 76), distanceBucket(a, b).?);

    // Reset a for clarity
    a = [_]u8{0} ** 20;
    b = [_]u8{0} ** 20;
    b[19] = 0x02; // bit 1 -> bucket 1
    try std.testing.expectEqual(@as(u8, 1), distanceBucket(a, b).?);
}

test "isCloser picks the closer node" {
    var target: NodeId = [_]u8{0} ** 20;
    target[19] = 0x10; // target has bit 4 set

    var a: NodeId = [_]u8{0} ** 20;
    a[19] = 0x11; // distance to target = 0x01

    var b: NodeId = [_]u8{0} ** 20;
    b[19] = 0x00; // distance to target = 0x10

    try std.testing.expect(isCloser(target, a, b)); // a is closer
    try std.testing.expect(!isCloser(target, b, a)); // b is farther
}

test "compact node encode/decode roundtrip" {
    const id = generate();
    const node = NodeInfo{
        .id = id,
        .address = std.net.Address.initIp4(.{ 192, 168, 1, 100 }, 6881),
    };
    const encoded = encodeCompactNode(node);
    const decoded = decodeCompactNode(&encoded);
    try std.testing.expectEqual(id, decoded.id);
    try std.testing.expectEqual(node.address.in.sa.addr, decoded.address.in.sa.addr);
    try std.testing.expectEqual(node.address.getPort(), decoded.address.getPort());
}

test "compact nodes batch encode/decode" {
    const allocator = std.testing.allocator;
    var nodes: [3]NodeInfo = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{
            .id = generate(),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, @intCast(6881 + i)),
        };
    }
    const encoded = try encodeCompactNodes(allocator, &nodes);
    defer allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 78), encoded.len);

    const decoded = try decodeCompactNodes(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    for (0..3) |i| {
        try std.testing.expectEqual(nodes[i].id, decoded[i].id);
    }
}

test "randomIdInBucket generates ID in correct bucket" {
    const own_id = generate();
    // Test several bucket indices
    for ([_]u8{ 0, 1, 10, 50, 100, 150, 159 }) |bucket| {
        const id = randomIdInBucket(own_id, bucket);
        const actual_bucket = distanceBucket(own_id, id).?;
        try std.testing.expectEqual(bucket, actual_bucket);
    }
}

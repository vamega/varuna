const std = @import("std");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;
const Random = @import("../runtime/random.zig").Random;

/// Maximum nodes per k-bucket (BEP 5).
pub const K: usize = 8;

/// 15 minutes in seconds -- threshold for "good" node status.
pub const good_timeout_secs: i64 = 15 * 60;

/// Refresh interval for stale buckets (15 minutes).
pub const refresh_interval_secs: i64 = 15 * 60;

pub const AddResult = enum {
    added,
    updated,
    bucket_full,
    replaced,
};

pub const NodeStatus = enum {
    good,
    questionable,
    bad,
};

/// Classify a node's status per BEP 5 section 2.
pub fn classifyNode(n: *const NodeInfo, now: i64) NodeStatus {
    if (n.failed_queries >= 2) return .bad;
    if (n.ever_responded and (now - n.last_seen) < good_timeout_secs) return .good;
    return .questionable;
}

pub const KBucket = struct {
    nodes: [K]NodeInfo = undefined,
    count: u8 = 0,
    last_changed: i64 = 0,

    pub fn isFull(self: *const KBucket) bool {
        return self.count >= K;
    }

    pub fn nodeCount(self: *const KBucket) u8 {
        return self.count;
    }

    /// Add a new node or update an existing one.
    pub fn addOrUpdate(self: *KBucket, info: NodeInfo, now: i64) AddResult {
        // Check if node already exists (update it)
        for (self.nodes[0..self.count]) |*n| {
            if (std.mem.eql(u8, &n.id, &info.id)) {
                n.last_seen = now;
                n.ever_responded = n.ever_responded or info.ever_responded;
                n.failed_queries = 0;
                n.address = info.address;
                self.last_changed = now;
                return .updated;
            }
        }

        // Not found -- try to add
        if (!self.isFull()) {
            self.nodes[self.count] = info;
            self.nodes[self.count].last_seen = now;
            self.count += 1;
            self.last_changed = now;
            return .added;
        }

        // Bucket full -- check if any node is bad and can be replaced
        for (self.nodes[0..self.count]) |*n| {
            if (classifyNode(n, now) == .bad) {
                n.* = info;
                n.last_seen = now;
                self.last_changed = now;
                return .replaced;
            }
        }

        return .bucket_full;
    }

    /// Find the least recently seen node (candidate for eviction ping).
    pub fn findLeastRecentlySeen(self: *KBucket) ?*NodeInfo {
        if (self.count == 0) return null;
        var oldest: *NodeInfo = &self.nodes[0];
        for (self.nodes[1..self.count]) |*n| {
            if (n.last_seen < oldest.last_seen) {
                oldest = n;
            }
        }
        return oldest;
    }

    /// Remove a node by ID (after failed ping).
    pub fn remove(self: *KBucket, id: NodeId) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, &self.nodes[i].id, &id)) {
                // Swap-remove
                if (i < self.count - 1) {
                    self.nodes[i] = self.nodes[self.count - 1];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Get nodes as a slice.
    pub fn getNodes(self: *const KBucket) []const NodeInfo {
        return self.nodes[0..self.count];
    }

    /// Mark a node as having failed a query.
    pub fn markFailed(self: *KBucket, id: NodeId) void {
        for (self.nodes[0..self.count]) |*n| {
            if (std.mem.eql(u8, &n.id, &id)) {
                n.failed_queries +|= 1;
                return;
            }
        }
    }

    /// Mark a node as having responded.
    pub fn markResponded(self: *KBucket, id: NodeId, now: i64) void {
        for (self.nodes[0..self.count]) |*n| {
            if (std.mem.eql(u8, &n.id, &id)) {
                n.last_seen = now;
                n.ever_responded = true;
                n.failed_queries = 0;
                return;
            }
        }
    }
};

pub const RoutingTable = struct {
    own_id: NodeId,
    buckets: [160]KBucket,

    pub fn init(own_id: NodeId) RoutingTable {
        return .{
            .own_id = own_id,
            .buckets = [_]KBucket{KBucket{}} ** 160,
        };
    }

    /// Add a node to the routing table.
    pub fn addNode(self: *RoutingTable, info: NodeInfo, now: i64) AddResult {
        // Don't add ourselves
        if (std.mem.eql(u8, &info.id, &self.own_id)) return .updated;

        const bucket_idx = node_id.distanceBucket(self.own_id, info.id) orelse return .updated;
        return self.buckets[bucket_idx].addOrUpdate(info, now);
    }

    /// Find the K closest nodes to a target ID.
    /// Returns nodes sorted by XOR distance to target.
    pub fn findClosest(self: *const RoutingTable, target: NodeId, count: u8, buf: []NodeInfo) u8 {
        // Collect candidate nodes from all buckets
        var candidates_buf: [160 * K]NodeInfo = undefined;
        var candidate_count: usize = 0;

        for (&self.buckets) |*bucket| {
            for (bucket.getNodes()) |n| {
                if (candidate_count < candidates_buf.len) {
                    candidates_buf[candidate_count] = n;
                    candidate_count += 1;
                }
            }
        }

        // Sort by distance to target
        const candidates = candidates_buf[0..candidate_count];
        std.mem.sort(NodeInfo, candidates, target, struct {
            fn lessThan(ctx: NodeId, a: NodeInfo, b: NodeInfo) bool {
                return node_id.isCloser(ctx, a.id, b.id);
            }
        }.lessThan);

        // Return up to count nodes
        const requested: usize = @min(@as(usize, count), buf.len);
        const actual_count_usize = @min(requested, candidate_count);
        const actual_count: u8 = @intCast(actual_count_usize);
        @memcpy(buf[0..actual_count], candidates[0..actual_count]);
        return actual_count;
    }

    /// Find a bucket that needs refresh (not changed in 15 minutes).
    /// Returns the bucket index or null.
    pub fn needsRefresh(self: *const RoutingTable, now: i64) ?u8 {
        for (0..160) |i| {
            const bucket = &self.buckets[i];
            if (bucket.count > 0 and (now - bucket.last_changed) >= refresh_interval_secs) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Total number of nodes across all buckets.
    pub fn nodeCount(self: *const RoutingTable) usize {
        var count: usize = 0;
        for (&self.buckets) |*bucket| {
            count += bucket.count;
        }
        return count;
    }

    /// Count of "good" nodes (responded recently).
    pub fn goodNodeCount(self: *const RoutingTable, now: i64) usize {
        var count: usize = 0;
        for (&self.buckets) |*bucket| {
            for (bucket.getNodes()) |*n| {
                if (classifyNode(n, now) == .good) {
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Mark a node as having responded to a query.
    pub fn markResponded(self: *RoutingTable, id: NodeId, now: i64) void {
        const bucket_idx = node_id.distanceBucket(self.own_id, id) orelse return;
        self.buckets[bucket_idx].markResponded(id, now);
    }

    /// Mark a node as having failed a query.
    pub fn markFailed(self: *RoutingTable, id: NodeId) void {
        const bucket_idx = node_id.distanceBucket(self.own_id, id) orelse return;
        self.buckets[bucket_idx].markFailed(id);
    }

    /// Remove a node from the routing table.
    pub fn removeNode(self: *RoutingTable, id: NodeId) bool {
        const bucket_idx = node_id.distanceBucket(self.own_id, id) orelse return false;
        return self.buckets[bucket_idx].remove(id);
    }

    /// Collect up to `max_nodes` good nodes for persistence.
    /// Picks the most recently seen nodes from each non-empty bucket.
    pub fn collectForPersistence(self: *const RoutingTable, buf: []NodeInfo, now: i64) usize {
        var count: usize = 0;
        for (&self.buckets) |*bucket| {
            for (bucket.getNodes()) |*n| {
                if (count >= buf.len) return count;
                if (classifyNode(n, now) == .good or
                    classifyNode(n, now) == .questionable)
                {
                    buf[count] = n.*;
                    count += 1;
                }
            }
        }
        return count;
    }
};

// ── Tests ──────────────────────────────────────────────

test "empty routing table has zero nodes" {
    var rng = Random.simRandom(0x400);
    const own_id = node_id.generateRandom(&rng);
    const table = RoutingTable.init(own_id);
    try std.testing.expectEqual(@as(usize, 0), table.nodeCount());
}

test "add node to routing table" {
    var rng = Random.simRandom(0x401);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    const other = NodeInfo{
        .id = node_id.generateRandom(&rng),
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    };

    const result = table.addNode(other, now);
    try std.testing.expect(result == .added);
    try std.testing.expectEqual(@as(usize, 1), table.nodeCount());
}

test "update existing node" {
    var rng = Random.simRandom(0x402);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    const other_id = node_id.generateRandom(&rng);
    const info = NodeInfo{
        .id = other_id,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    };

    _ = table.addNode(info, now);
    const result = table.addNode(info, now + 100);
    try std.testing.expect(result == .updated);
    try std.testing.expectEqual(@as(usize, 1), table.nodeCount());
}

test "bucket full returns bucket_full" {
    var own_id: NodeId = [_]u8{0} ** 20;
    own_id[0] = 0xFF; // own_id starts with 0xFF
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    // Fill bucket 159 (highest bit differs) with K nodes
    for (0..K) |i| {
        var id: NodeId = [_]u8{0} ** 20;
        // These all start with 0x0X, so XOR with own_id (0xFF...) has bit 159 set
        id[0] = @intCast(i);
        id[19] = @intCast(i + 1); // ensure unique
        _ = table.addNode(.{
            .id = id,
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
            .ever_responded = true,
        }, now);
    }

    try std.testing.expectEqual(@as(usize, K), table.nodeCount());

    // Try to add one more to the same bucket
    var extra_id: NodeId = [_]u8{0} ** 20;
    extra_id[0] = 0x0A;
    extra_id[19] = 0xFF;
    const result = table.addNode(.{
        .id = extra_id,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 99 }, 6881),
    }, now);

    try std.testing.expect(result == .bucket_full);
}

test "bad node gets replaced" {
    var own_id: NodeId = [_]u8{0} ** 20;
    own_id[0] = 0xFF;
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    // Fill a bucket
    var bad_id: NodeId = undefined;
    for (0..K) |i| {
        var id: NodeId = [_]u8{0} ** 20;
        id[0] = @intCast(i);
        id[19] = @intCast(i + 1);
        _ = table.addNode(.{
            .id = id,
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        }, now);
        if (i == 0) bad_id = id;
    }

    // Mark first node as bad
    table.markFailed(bad_id);
    table.markFailed(bad_id);

    // Now add a new node -- it should replace the bad one
    var new_id: NodeId = [_]u8{0} ** 20;
    new_id[0] = 0x0B;
    new_id[19] = 0xAA;
    const result = table.addNode(.{
        .id = new_id,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 200 }, 6881),
    }, now);

    try std.testing.expect(result == .replaced);
    try std.testing.expectEqual(@as(usize, K), table.nodeCount());
}

test "findClosest returns sorted results" {
    var rng = Random.simRandom(0x403);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    // Add several nodes
    for (0..20) |_| {
        _ = table.addNode(.{
            .id = node_id.generateRandom(&rng),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
        }, now);
    }

    const target = node_id.generateRandom(&rng);
    var buf: [8]NodeInfo = undefined;
    const count = table.findClosest(target, 8, &buf);
    try std.testing.expect(count > 0);

    // Verify sorted by distance
    for (1..count) |i| {
        try std.testing.expect(!node_id.isCloser(target, buf[i].id, buf[i - 1].id));
    }
}

test "findClosest clamps after collecting more than 255 nodes" {
    var rng = Random.simRandom(0x406);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    for (0..160) |bucket| {
        for (0..2) |slot| {
            _ = table.addNode(.{
                .id = node_id.randomIdInBucket(&rng, own_id, @intCast(bucket)),
                .address = std.net.Address.initIp4(.{
                    10,
                    @intCast(bucket),
                    @intCast(slot),
                    @intCast((bucket + slot) % 250 + 1),
                }, 6881),
            }, now);
        }
    }
    try std.testing.expect(table.nodeCount() > 255);

    const target = [_]u8{0x55} ** 20;
    var buf: [8]NodeInfo = undefined;
    const count = table.findClosest(target, 8, &buf);
    try std.testing.expectEqual(@as(u8, 8), count);
}

test "needsRefresh detects stale buckets" {
    var rng = Random.simRandom(0x404);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    // Add a node -- bucket is fresh
    const other = NodeInfo{
        .id = node_id.generateRandom(&rng),
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    };
    _ = table.addNode(other, now);

    // Should not need refresh yet
    try std.testing.expect(table.needsRefresh(now) == null);

    // After 15 minutes, should need refresh
    try std.testing.expect(table.needsRefresh(now + refresh_interval_secs) != null);
}

test "node classification" {
    var rng = Random.simRandom(0x405);
    const now: i64 = 1000000;

    // Good: responded recently
    const good_node = NodeInfo{
        .id = node_id.generateRandom(&rng),
        .address = undefined,
        .last_seen = now - 100,
        .ever_responded = true,
        .failed_queries = 0,
    };
    try std.testing.expect(classifyNode(&good_node, now) == .good);

    // Questionable: not seen recently
    const questionable_node = NodeInfo{
        .id = node_id.generateRandom(&rng),
        .address = undefined,
        .last_seen = now - good_timeout_secs - 1,
        .ever_responded = true,
        .failed_queries = 0,
    };
    try std.testing.expect(classifyNode(&questionable_node, now) == .questionable);

    // Bad: multiple failures
    const bad_node = NodeInfo{
        .id = node_id.generateRandom(&rng),
        .address = undefined,
        .last_seen = now,
        .ever_responded = true,
        .failed_queries = 2,
    };
    try std.testing.expect(classifyNode(&bad_node, now) == .bad);
}

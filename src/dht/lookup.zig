const std = @import("std");
const address = @import("../net/address.zig");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;
const routing_table = @import("routing_table.zig");
const RoutingTable = routing_table.RoutingTable;
const Random = @import("../runtime/random.zig").Random;
pub const K = routing_table.K;

/// Maximum number of candidates tracked during a lookup.
///
/// Public swarms often need more breadth than the strict Kademlia closest-K
/// walk to quickly discover enough reachable peers. libtorrent defaults to
/// aggressive lookups with a broader search fan-out; keep enough candidates
/// to continue walking while peer values arrive from the tail of the search.
const max_candidates: usize = 256;

/// Alpha: number of concurrent queries per lookup round.
pub const alpha: u8 = 5;

/// State of a candidate node during iterative lookup.
const CandidateState = enum {
    pending, // discovered but not yet queried
    queried, // query sent, awaiting response
    responded, // response received
    failed, // no response (timeout / error)
};

const Candidate = struct {
    info: NodeInfo,
    state: CandidateState,
    /// Token received from this node's get_peers response.
    token: ?[64]u8 = null,
    token_len: u8 = 0,
};

/// Iterative lookup state machine (BEP 5 section 2.3).
///
/// Used for both find_node and get_peers lookups. Maintains a set of
/// candidate nodes sorted by XOR distance to the target, and queries
/// them alpha at a time until no closer nodes are discovered.
pub const Lookup = struct {
    target: NodeId,
    candidates: [max_candidates]Candidate = undefined,
    candidate_count: usize = 0,
    /// Peers discovered during get_peers lookups.
    peers: [256]std.net.Address = undefined,
    peer_count: usize = 0,
    state: State = .in_progress,
    /// Type of lookup.
    kind: Kind = .find_node,

    pub const State = enum { in_progress, done };
    pub const Kind = enum { find_node, get_peers };

    /// Initialize a lookup from the routing table's closest nodes.
    pub fn init(target: NodeId, kind: Kind) Lookup {
        return .{
            .target = target,
            .kind = kind,
        };
    }

    /// Seed the lookup with initial candidates from the routing table.
    pub fn seed(self: *Lookup, table: *const RoutingTable) void {
        var buf: [K]NodeInfo = undefined;
        const count = table.findClosest(self.target, @intCast(K), &buf);
        for (buf[0..count]) |info| {
            self.addCandidate(info);
        }
    }

    /// Seed the lookup with explicit nodes (e.g., bootstrap nodes).
    pub fn seedNodes(self: *Lookup, nodes: []const NodeInfo) void {
        for (nodes) |info| {
            self.addCandidate(info);
        }
    }

    /// Get the next batch of nodes to query (up to alpha pending candidates).
    /// Returns slices into the candidate array. Caller should send queries
    /// and call markQueried() for each.
    pub fn nextToQuery(self: *Lookup, buf: *[alpha]NodeInfo) u8 {
        return self.nextToQueryN(buf);
    }

    /// Like nextToQuery but accepts any buffer size (for bootstrap fan-out).
    pub fn nextToQueryN(self: *Lookup, buf: []NodeInfo) u8 {
        if (self.state == .done) return 0;

        var in_flight: usize = 0;
        for (self.candidates[0..self.candidate_count]) |c| {
            if (c.state == .queried) in_flight += 1;
        }
        if (in_flight >= buf.len) return 0;

        const allowance = buf.len - in_flight;
        var count: usize = 0;
        for (0..self.candidate_count) |ci| {
            if (count >= allowance) break;
            if (self.candidates[ci].state == .pending) {
                buf[count] = self.candidates[ci].info;
                self.candidates[ci].state = .queried;
                count += 1;
            }
        }

        // If no pending candidates remain and all queried have responded/failed,
        // the lookup is complete.
        if (count == 0) {
            var any_queried = false;
            for (self.candidates[0..self.candidate_count]) |c| {
                if (c.state == .queried) {
                    any_queried = true;
                    break;
                }
            }
            if (!any_queried) {
                self.state = .done;
            }
        }

        return @intCast(count);
    }

    /// Handle a response from a queried node. Adds newly discovered nodes
    /// and peers to the candidate/peer sets.
    pub fn handleResponse(
        self: *Lookup,
        from: NodeId,
        new_nodes: ?[]const NodeInfo,
        new_peers: ?[]const std.net.Address,
        token: ?[]const u8,
    ) void {
        // Mark the node as responded and save token
        for (0..self.candidate_count) |ci| {
            if (std.mem.eql(u8, &self.candidates[ci].info.id, &from)) {
                self.candidates[ci].state = .responded;
                if (token) |t| {
                    if (t.len <= 64) {
                        var tok: [64]u8 = undefined;
                        @memcpy(tok[0..t.len], t);
                        self.candidates[ci].token = tok;
                        self.candidates[ci].token_len = @intCast(t.len);
                    }
                }
                break;
            }
        }

        // Add newly discovered nodes as candidates
        if (new_nodes) |nodes| {
            for (nodes) |info| {
                self.addCandidate(info);
            }
        }

        // Collect discovered peers
        if (new_peers) |peers| {
            for (peers) |addr| {
                if (self.peer_count < self.peers.len) {
                    // Deduplicate
                    var dup = false;
                    for (self.peers[0..self.peer_count]) |existing| {
                        if (address.addressEql(&existing, &addr)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        self.peers[self.peer_count] = addr;
                        self.peer_count += 1;
                    }
                }
            }
        }
    }

    /// Mark a queried node as failed (timeout / error).
    pub fn markFailed(self: *Lookup, id: NodeId) void {
        for (0..self.candidate_count) |ci| {
            if (std.mem.eql(u8, &self.candidates[ci].info.id, &id)) {
                self.candidates[ci].state = .failed;
                break;
            }
        }
    }

    /// Return a candidate from queried back to pending when the engine
    /// could not actually enqueue the outbound query.
    pub fn markPending(self: *Lookup, id: NodeId) void {
        for (0..self.candidate_count) |ci| {
            if (std.mem.eql(u8, &self.candidates[ci].info.id, &id) and self.candidates[ci].state == .queried) {
                self.candidates[ci].state = .pending;
                break;
            }
        }
    }

    /// Check if the lookup is complete.
    pub fn isDone(self: *const Lookup) bool {
        return self.state == .done;
    }

    /// Get the K closest responded nodes (for announce_peer follow-up).
    pub fn getClosestResponded(self: *const Lookup, buf: *[K]NodeInfo) u8 {
        var count: u8 = 0;
        for (self.candidates[0..self.candidate_count]) |c| {
            if (count >= K) break;
            if (c.state == .responded) {
                buf[count] = c.info;
                count += 1;
            }
        }
        return count;
    }

    /// Get token for a specific node (saved from get_peers response).
    pub fn getToken(self: *const Lookup, id: NodeId) ?[]const u8 {
        for (self.candidates[0..self.candidate_count]) |c| {
            if (std.mem.eql(u8, &c.info.id, &id) and c.token_len > 0) {
                return c.token.?[0..c.token_len];
            }
        }
        return null;
    }

    /// Get discovered peers.
    pub fn getPeers(self: *const Lookup) []const std.net.Address {
        return self.peers[0..self.peer_count];
    }

    // ── Internal ────────────────────────────────────────

    fn addCandidate(self: *Lookup, info: NodeInfo) void {
        // Don't add duplicates
        for (self.candidates[0..self.candidate_count]) |c| {
            if (std.mem.eql(u8, &c.info.id, &info.id)) return;
        }

        if (self.candidate_count < max_candidates) {
            self.candidates[self.candidate_count] = .{
                .info = info,
                .state = .pending,
            };
            self.candidate_count += 1;
            // Re-sort by distance to target
            self.sortCandidates();
        } else {
            // Check if this node is closer than the farthest candidate
            const farthest = &self.candidates[self.candidate_count - 1];
            if (node_id.isCloser(self.target, info.id, farthest.info.id)) {
                // Replace farthest pending node (don't replace queried/responded)
                if (farthest.state == .pending) {
                    farthest.* = .{
                        .info = info,
                        .state = .pending,
                    };
                    self.sortCandidates();
                }
            }
        }
    }

    fn sortCandidates(self: *Lookup) void {
        const target = self.target;
        std.mem.sort(Candidate, self.candidates[0..self.candidate_count], target, struct {
            fn lessThan(ctx: NodeId, a: Candidate, b: Candidate) bool {
                return node_id.isCloser(ctx, a.info.id, b.info.id);
            }
        }.lessThan);
    }
};

// ── Tests ──────────────────────────────────────────────

test "lookup initializes empty" {
    var rng = Random.simRandom(0x500);
    const target = node_id.generateRandom(&rng);
    const lk = Lookup.init(target, .find_node);
    try std.testing.expect(!lk.isDone());
    try std.testing.expectEqual(@as(usize, 0), lk.candidate_count);
}

test "lookup seed populates candidates" {
    var rng = Random.simRandom(0x501);
    const own_id = node_id.generateRandom(&rng);
    var table = RoutingTable.init(own_id);
    const now: i64 = 1000000;

    for (0..10) |_| {
        _ = table.addNode(.{
            .id = node_id.generateRandom(&rng),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
        }, now);
    }

    const target = node_id.generateRandom(&rng);
    var lk = Lookup.init(target, .find_node);
    lk.seed(&table);
    try std.testing.expect(lk.candidate_count > 0);
    try std.testing.expect(lk.candidate_count <= K);
}

test "nextToQuery returns alpha nodes" {
    var rng = Random.simRandom(0x502);
    var lk = Lookup.init(node_id.generateRandom(&rng), .find_node);

    for (0..5) |i| {
        var id: NodeId = [_]u8{0} ** 20;
        id[19] = @intCast(i + 1);
        lk.addCandidate(.{
            .id = id,
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        });
    }

    var buf: [alpha]NodeInfo = undefined;
    const count = lk.nextToQuery(&buf);
    try std.testing.expectEqual(@as(u8, alpha), count);
}

test "nextToQuery respects alpha as concurrent in-flight limit" {
    var rng = Random.simRandom(0x5021);
    var lk = Lookup.init(node_id.generateRandom(&rng), .find_node);

    for (0..10) |i| {
        var id: NodeId = [_]u8{0} ** 20;
        id[19] = @intCast(i + 1);
        lk.addCandidate(.{
            .id = id,
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        });
    }

    var buf: [alpha]NodeInfo = undefined;
    const first = lk.nextToQuery(&buf);
    try std.testing.expectEqual(@as(u8, alpha), first);

    const second = lk.nextToQuery(&buf);
    try std.testing.expectEqual(@as(u8, 0), second);
    try std.testing.expect(!lk.isDone());

    lk.handleResponse(buf[0].id, null, null, null);
    const third = lk.nextToQuery(&buf);
    try std.testing.expectEqual(@as(u8, 1), third);
}

test "lookup completes when no pending candidates" {
    var rng = Random.simRandom(0x503);
    var lk = Lookup.init(node_id.generateRandom(&rng), .find_node);

    var id: NodeId = [_]u8{0} ** 20;
    id[19] = 1;
    lk.addCandidate(.{
        .id = id,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    });

    var buf: [alpha]NodeInfo = undefined;
    _ = lk.nextToQuery(&buf);
    lk.handleResponse(id, null, null, null);

    const count2 = lk.nextToQuery(&buf);
    try std.testing.expectEqual(@as(u8, 0), count2);
    try std.testing.expect(lk.isDone());
}

test "handleResponse adds new candidates" {
    var rng = Random.simRandom(0x504);
    var lk = Lookup.init(node_id.generateRandom(&rng), .find_node);

    var id1: NodeId = [_]u8{0} ** 20;
    id1[19] = 1;
    lk.addCandidate(.{
        .id = id1,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    });

    var buf: [alpha]NodeInfo = undefined;
    _ = lk.nextToQuery(&buf);

    var new_nodes: [2]NodeInfo = undefined;
    for (&new_nodes, 0..) |*n, i| {
        var nid: NodeId = [_]u8{0} ** 20;
        nid[19] = @intCast(i + 10);
        n.* = .{
            .id = nid,
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 10) }, 6881),
        };
    }

    lk.handleResponse(id1, &new_nodes, null, null);
    try std.testing.expectEqual(@as(usize, 3), lk.candidate_count);
}

test "handleResponse collects peers" {
    var rng = Random.simRandom(0x505);
    var lk = Lookup.init(node_id.generateRandom(&rng), .get_peers);

    var id1: NodeId = [_]u8{0} ** 20;
    id1[19] = 1;
    lk.addCandidate(.{
        .id = id1,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    });

    var buf: [alpha]NodeInfo = undefined;
    _ = lk.nextToQuery(&buf);

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 172, 16, 0, 1 }, 51413),
        std.net.Address.initIp4(.{ 172, 16, 0, 2 }, 51414),
    };

    lk.handleResponse(id1, null, &peers, null);
    try std.testing.expectEqual(@as(usize, 2), lk.peer_count);
}

test "peer deduplication" {
    var rng = Random.simRandom(0x506);
    var lk = Lookup.init(node_id.generateRandom(&rng), .get_peers);

    var id1: NodeId = [_]u8{0} ** 20;
    id1[19] = 1;
    lk.addCandidate(.{
        .id = id1,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    });

    var buf: [alpha]NodeInfo = undefined;
    _ = lk.nextToQuery(&buf);

    const peer = std.net.Address.initIp4(.{ 172, 16, 0, 1 }, 51413);

    lk.handleResponse(id1, null, &[_]std.net.Address{peer}, null);
    var id2: NodeId = [_]u8{0} ** 20;
    id2[19] = 2;
    lk.addCandidate(.{
        .id = id2,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 2 }, 6881),
    });
    lk.candidates[1].state = .queried;
    lk.handleResponse(id2, null, &[_]std.net.Address{peer}, null);

    try std.testing.expectEqual(@as(usize, 1), lk.peer_count);
}

test "candidate deduplication" {
    var rng = Random.simRandom(0x507);
    var lk = Lookup.init(node_id.generateRandom(&rng), .find_node);

    var id: NodeId = [_]u8{0} ** 20;
    id[19] = 1;
    const info = NodeInfo{
        .id = id,
        .address = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881),
    };

    lk.addCandidate(info);
    lk.addCandidate(info); // duplicate
    try std.testing.expectEqual(@as(usize, 1), lk.candidate_count);
}

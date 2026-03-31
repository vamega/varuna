const std = @import("std");
const Bitfield = @import("../bitfield.zig").Bitfield;

/// BEP 16 super-seeding state tracker.
///
/// In super-seed mode, the seeder sends individual HAVE messages instead
/// of a full bitfield, and only advertises pieces that the peer is missing.
/// Each piece is tracked to see which peers have received it. The goal is
/// to ensure each piece is sent to exactly one peer during initial seeding,
/// maximizing piece diversity in the swarm.
pub const SuperSeedState = struct {
    allocator: std.mem.Allocator,
    piece_count: u32,

    /// For each peer slot, tracks which pieces we have advertised to them.
    /// Key: peer slot index. Value: bitfield of advertised pieces.
    advertised: std.AutoHashMapUnmanaged(u16, Bitfield),

    /// Counts how many unique peers have confirmed they received each piece
    /// (via HAVE messages from them). Used to prioritize sending rare pieces.
    piece_distribution: []u16,

    /// Round-robin hint for picking the next piece to advertise.
    next_piece_hint: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, piece_count: u32) !SuperSeedState {
        const dist = try allocator.alloc(u16, piece_count);
        @memset(dist, 0);
        return .{
            .allocator = allocator,
            .piece_count = piece_count,
            .advertised = .empty,
            .piece_distribution = dist,
        };
    }

    pub fn deinit(self: *SuperSeedState) void {
        var it = self.advertised.valueIterator();
        while (it.next()) |bf| {
            bf.deinit(self.allocator);
        }
        self.advertised.deinit(self.allocator);
        self.allocator.free(self.piece_distribution);
        self.* = undefined;
    }

    /// Register a new peer. Called when an inbound peer completes handshake.
    pub fn addPeer(self: *SuperSeedState, slot: u16) void {
        var bf = Bitfield.init(self.allocator, self.piece_count) catch return;
        self.advertised.put(self.allocator, slot, bf) catch {
            bf.deinit(self.allocator);
        };
    }

    /// Remove a peer (disconnected).
    pub fn removePeer(self: *SuperSeedState, slot: u16) void {
        if (self.advertised.fetchRemove(slot)) |entry| {
            var bf = entry.value;
            bf.deinit(self.allocator);
        }
    }

    /// Pick the best piece to advertise to a given peer. Returns null if
    /// there is nothing useful to send (peer already knows all pieces we
    /// have advertised, or all pieces have been distributed).
    ///
    /// Strategy: find the piece with the lowest distribution count that
    /// we haven't yet advertised to this peer. Ties broken by round-robin.
    pub fn pickPieceForPeer(
        self: *SuperSeedState,
        slot: u16,
        peer_bitfield: ?Bitfield,
    ) ?u32 {
        const adv = self.advertised.getPtr(slot) orelse return null;

        var best_piece: ?u32 = null;
        var best_dist: u16 = std.math.maxInt(u16);

        // Scan from hint for better cache locality
        var scanned: u32 = 0;
        var idx = self.next_piece_hint;
        while (scanned < self.piece_count) : (scanned += 1) {
            defer idx = if (idx + 1 >= self.piece_count) 0 else idx + 1;

            // Skip pieces we already told this peer about
            if (adv.has(idx)) continue;

            // Skip pieces the peer already has (from their bitfield)
            if (peer_bitfield) |pb| {
                if (pb.has(idx)) continue;
            }

            const dist = self.piece_distribution[idx];
            if (dist < best_dist) {
                best_dist = dist;
                best_piece = idx;
                // Perfect: a piece no one has seen yet
                if (dist == 0) break;
            }
        }

        if (best_piece) |bp| {
            adv.set(bp) catch {};
            // Advance hint past this piece for next call
            self.next_piece_hint = if (bp + 1 >= self.piece_count) 0 else bp + 1;
        }

        return best_piece;
    }

    /// Record that a peer now has a piece (they sent us a HAVE message).
    /// This increments the distribution count for that piece.
    pub fn recordPeerHave(self: *SuperSeedState, piece_index: u32) void {
        if (piece_index < self.piece_count) {
            if (self.piece_distribution[piece_index] < std.math.maxInt(u16)) {
                self.piece_distribution[piece_index] += 1;
            }
        }
    }

    /// Check whether super-seeding has distributed all pieces to at least
    /// one peer each. When this returns true, it may be beneficial to
    /// disable super-seed mode and switch to normal seeding.
    pub fn isFullyDistributed(self: *const SuperSeedState) bool {
        for (self.piece_distribution) |count| {
            if (count == 0) return false;
        }
        return true;
    }
};

// ── Tests ────────────────────────────────────────────────

test "super seed picks least distributed piece" {
    var ss = try SuperSeedState.init(std.testing.allocator, 4);
    defer ss.deinit();

    ss.addPeer(0);

    // Initially all distribution counts are 0, should pick piece 0 (hint starts there)
    const p1 = ss.pickPieceForPeer(0, null);
    try std.testing.expectEqual(@as(?u32, 0), p1);

    // Next pick should skip piece 0 (already advertised to peer 0)
    const p2 = ss.pickPieceForPeer(0, null);
    try std.testing.expectEqual(@as(?u32, 1), p2);
}

test "super seed avoids pieces peer already has" {
    var ss = try SuperSeedState.init(std.testing.allocator, 4);
    defer ss.deinit();

    ss.addPeer(0);

    // Peer already has pieces 0 and 1
    var peer_bf = try Bitfield.init(std.testing.allocator, 4);
    defer peer_bf.deinit(std.testing.allocator);
    try peer_bf.set(0);
    try peer_bf.set(1);

    const p = ss.pickPieceForPeer(0, peer_bf);
    try std.testing.expectEqual(@as(?u32, 2), p);
}

test "super seed tracks distribution" {
    var ss = try SuperSeedState.init(std.testing.allocator, 3);
    defer ss.deinit();

    try std.testing.expect(!ss.isFullyDistributed());

    ss.recordPeerHave(0);
    ss.recordPeerHave(1);
    try std.testing.expect(!ss.isFullyDistributed());

    ss.recordPeerHave(2);
    try std.testing.expect(ss.isFullyDistributed());
}

test "super seed remove peer cleans up" {
    var ss = try SuperSeedState.init(std.testing.allocator, 4);
    defer ss.deinit();

    ss.addPeer(5);
    try std.testing.expect(ss.advertised.get(5) != null);

    ss.removePeer(5);
    try std.testing.expect(ss.advertised.get(5) == null);
}

test "super seed prefers less distributed pieces" {
    var ss = try SuperSeedState.init(std.testing.allocator, 4);
    defer ss.deinit();

    // Simulate: pieces 0,1,2 have been distributed, piece 3 hasn't
    ss.piece_distribution[0] = 3;
    ss.piece_distribution[1] = 2;
    ss.piece_distribution[2] = 1;
    ss.piece_distribution[3] = 0;

    ss.addPeer(0);

    const p = ss.pickPieceForPeer(0, null);
    try std.testing.expectEqual(@as(?u32, 3), p);
}

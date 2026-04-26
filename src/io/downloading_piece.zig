const std = @import("std");

/// Per-block state in a DownloadingPiece.
pub const BlockState = enum(u2) {
    /// No peer has claimed or received this block.
    none,
    /// A peer has sent a REQUEST for this block.
    requested,
    /// A peer has delivered a valid PIECE message for this block.
    received,
};

/// Per-block metadata: tracks which peer owns (requested or received) each block.
pub const BlockInfo = struct {
    state: BlockState = .none,
    /// Peer slot that requested or received this block. Used by the
    /// picker for live tracking (`releaseBlocksForPeer`,
    /// `attributedCountForPeer`, etc.). NOT used for smart-ban
    /// attribution — that needs the address (slot indices reuse on
    /// peer churn). See `delivered_address` below.
    peer_slot: u16 = 0,
    /// Address of the peer that delivered this block. Populated in
    /// `markBlockReceived` from the live peer's address at receive
    /// time, NOT looked up from the peer slot at snapshot time. The
    /// distinction matters when a peer disconnects (or is banned, or
    /// churns its IP) between block delivery and piece completion:
    /// the slot may have been reused for a different peer by the
    /// time `snapshotAttributionForSmartBan` runs, but the address
    /// recorded here stays accurate. Smart-ban Phase 2 ban-targeting
    /// reads this directly so a corrupt peer that misbehaves and
    /// disconnects fast (intentionally evasive, or kicked by Phase
    /// 0 trust-points) cannot escape attribution by losing their slot.
    /// Null when state == .none (no delivery yet); also null after
    /// `releaseBlocksForPeer` resets a `.requested` block back to
    /// `.none`.
    delivered_address: ?std.net.Address = null,
};

/// Shared per-piece download state.  Multiple peers can reference the same
/// DownloadingPiece to contribute blocks concurrently.  All access is
/// single-threaded (event loop) so no synchronisation is required.
pub const DownloadingPiece = struct {
    piece_index: u32,
    torrent_id: u32,
    /// Shared piece buffer; all participating peers write into this.
    buf: []u8,
    /// Per-block state and peer attribution.
    block_infos: []BlockInfo,
    blocks_total: u16,
    blocks_received: u16 = 0,
    blocks_requested: u16 = 0,
    /// Number of peers currently referencing this DownloadingPiece
    /// (via `downloading_piece` or `next_downloading_piece`).
    peer_count: u8 = 0,

    /// Return the index of the next unrequested block, or null if all
    /// blocks have been requested or received.
    pub fn nextUnrequestedBlock(self: *const DownloadingPiece) ?u16 {
        for (self.block_infos, 0..) |bi, i| {
            if (bi.state == .none) return @intCast(i);
        }
        return null;
    }

    /// Mark a block as requested by a peer.  Returns true if the block
    /// was previously unrequested (.none), false otherwise.
    pub fn markBlockRequested(self: *DownloadingPiece, block_index: u16, peer_slot: u16) bool {
        if (block_index >= self.blocks_total) return false;
        const bi = &self.block_infos[block_index];
        if (bi.state != .none) return false;
        bi.state = .requested;
        bi.peer_slot = peer_slot;
        self.blocks_requested += 1;
        return true;
    }

    /// Mark a block as received.  Writes the block data into the shared
    /// buffer.  Returns true if this block was not yet received (first
    /// delivery wins), false for duplicates.
    ///
    /// `peer_address` is captured into `bi.delivered_address` for
    /// smart-ban Phase 2 attribution that survives peer-slot reuse
    /// (see `BlockInfo.delivered_address` doc comment).
    pub fn markBlockReceived(
        self: *DownloadingPiece,
        block_index: u16,
        peer_slot: u16,
        peer_address: std.net.Address,
        block_offset: u32,
        block_data: []const u8,
    ) bool {
        if (block_index >= self.blocks_total) return false;
        const bi = &self.block_infos[block_index];
        if (bi.state == .received) return false; // duplicate
        const start: usize = @intCast(block_offset);
        const end = start + block_data.len;
        if (end > self.buf.len) return false;
        @memcpy(self.buf[start..end], block_data);
        if (bi.state == .none) {
            // Was unrequested (e.g. unsolicited block) -- count it as requested too
            self.blocks_requested += 1;
        }
        bi.state = .received;
        bi.peer_slot = peer_slot;
        bi.delivered_address = peer_address;
        self.blocks_received += 1;
        return true;
    }

    /// Returns true when every block in the piece has been received.
    pub fn isComplete(self: *const DownloadingPiece) bool {
        return self.blocks_received >= self.blocks_total;
    }

    /// Release all blocks owned by a specific peer (requested but not
    /// yet received).  Used when a peer is choked, disconnects, or is
    /// removed.  Already-received blocks are kept.
    pub fn releaseBlocksForPeer(self: *DownloadingPiece, peer_slot: u16) void {
        for (self.block_infos) |*bi| {
            if (bi.peer_slot == peer_slot and bi.state == .requested) {
                bi.state = .none;
                bi.peer_slot = 0;
                if (self.blocks_requested > 0) self.blocks_requested -= 1;
            }
        }
    }

    /// Returns the count of blocks in .none state (available for requesting).
    pub fn unrequestedCount(self: *const DownloadingPiece) u16 {
        var count: u16 = 0;
        for (self.block_infos) |bi| {
            if (bi.state == .none) count += 1;
        }
        return count;
    }

    /// Returns the count of blocks currently requested by a specific peer.
    pub fn requestedCountForPeer(self: *const DownloadingPiece, peer_slot: u16) u16 {
        var count: u16 = 0;
        for (self.block_infos) |bi| {
            if (bi.peer_slot == peer_slot and bi.state == .requested) count += 1;
        }
        return count;
    }

    /// Returns the count of blocks attributed to a specific peer in any
    /// non-`.none` state (requested *or* received). Used by the
    /// multi-source picker as the "fair share" bound: a peer should
    /// not claim more blocks than its share of `blocks_total /
    /// peer_count`. Counts all attributed blocks (not just in-flight)
    /// because `.received` blocks still represent work done by this
    /// peer — the downloader shouldn't keep claiming blocks for a peer
    /// that has already pulled its share.
    pub fn attributedCountForPeer(self: *const DownloadingPiece, peer_slot: u16) u16 {
        var count: u16 = 0;
        for (self.block_infos) |bi| {
            if (bi.peer_slot == peer_slot and bi.state != .none) count += 1;
        }
        return count;
    }

    /// Returns the first block in `.requested` state attributed to a peer
    /// other than `exclude_peer_slot`, or null if every `.requested`
    /// block belongs to that peer (or no blocks are `.requested`).
    /// Used by the multi-source picker for **block-stealing**: when a
    /// peer joins a DP that's fully claimed but incomplete, it issues
    /// duplicate requests for blocks another peer already claimed.
    /// Whichever peer delivers first wins attribution via
    /// `markBlockReceived` (which returns false for the loser's
    /// duplicate; the data is dropped).
    ///
    /// The exclude bound prevents self-stealing: a peer's own
    /// outstanding requests don't count as stealable since duplicate
    /// requests against your own outstanding ones are pure overhead.
    /// Does not mutate state — block-stealing leaves attribution at
    /// the original requester until delivery, since either peer might
    /// win the race.
    pub fn nextStealableBlock(self: *const DownloadingPiece, exclude_peer_slot: u16) ?u16 {
        for (self.block_infos, 0..) |bi, i| {
            if (bi.state == .requested and bi.peer_slot != exclude_peer_slot) {
                return @intCast(i);
            }
        }
        return null;
    }
};

/// Composite key for the downloading_pieces registry.
pub const DownloadingPieceKey = struct {
    torrent_id: u32,
    piece_index: u32,
};

/// HashMap context for DownloadingPieceKey (used by std.HashMapUnmanaged).
pub const DownloadingPieceContext = struct {
    pub fn hash(_: DownloadingPieceContext, key: DownloadingPieceKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.torrent_id));
        h.update(std.mem.asBytes(&key.piece_index));
        return h.final();
    }

    pub fn eql(_: DownloadingPieceContext, a: DownloadingPieceKey, b: DownloadingPieceKey) bool {
        return a.torrent_id == b.torrent_id and a.piece_index == b.piece_index;
    }
};

pub const DownloadingPieceMap = std.HashMapUnmanaged(
    DownloadingPieceKey,
    *DownloadingPiece,
    DownloadingPieceContext,
    std.hash_map.default_max_load_percentage,
);

/// Create a new DownloadingPiece, allocating the buffer and block_infos.
pub fn createDownloadingPiece(
    allocator: std.mem.Allocator,
    piece_index: u32,
    torrent_id: u32,
    piece_size: u32,
    block_count: u16,
) !*DownloadingPiece {
    const buf = try allocator.alloc(u8, piece_size);
    errdefer allocator.free(buf);
    const block_infos = try allocator.alloc(BlockInfo, block_count);
    errdefer allocator.free(block_infos);
    @memset(block_infos, BlockInfo{});
    const dp = try allocator.create(DownloadingPiece);
    dp.* = .{
        .piece_index = piece_index,
        .torrent_id = torrent_id,
        .buf = buf,
        .block_infos = block_infos,
        .blocks_total = block_count,
    };
    return dp;
}

/// Destroy a DownloadingPiece, freeing block_infos.  The piece buffer
/// (dp.buf) is NOT freed here because it may have been handed off to
/// the hasher.  The caller is responsible for freeing buf when appropriate.
pub fn destroyDownloadingPiece(allocator: std.mem.Allocator, dp: *DownloadingPiece) void {
    allocator.free(dp.block_infos);
    allocator.destroy(dp);
}

/// Destroy a DownloadingPiece AND free its piece buffer.  Use this when
/// the piece is being abandoned (no hasher submission).
pub fn destroyDownloadingPieceFull(allocator: std.mem.Allocator, dp: *DownloadingPiece) void {
    allocator.free(dp.buf);
    allocator.free(dp.block_infos);
    allocator.destroy(dp);
}

/// Sentinel address for tests that don't care about per-peer
/// attribution. Real callers (`protocol.processMessage`) pass the
/// peer's actual `peer.address`.
const test_address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

// ── Unit tests ──────────────────────────────────────────

const testing = std.testing;

test "nextUnrequestedBlock returns first unrequested" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 64 * 1024, 4);
    defer destroyDownloadingPieceFull(allocator, dp);

    try testing.expectEqual(@as(?u16, 0), dp.nextUnrequestedBlock());

    _ = dp.markBlockRequested(0, 10);
    try testing.expectEqual(@as(?u16, 1), dp.nextUnrequestedBlock());

    _ = dp.markBlockRequested(1, 10);
    _ = dp.markBlockRequested(2, 10);
    try testing.expectEqual(@as(?u16, 3), dp.nextUnrequestedBlock());

    _ = dp.markBlockRequested(3, 10);
    try testing.expectEqual(@as(?u16, null), dp.nextUnrequestedBlock());
}

test "markBlockReceived writes data and increments counter" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 4, 2);
    defer destroyDownloadingPieceFull(allocator, dp);

    _ = dp.markBlockRequested(0, 5);
    const ok = dp.markBlockReceived(0, 5, test_address, 0, &.{ 0xAA, 0xBB });
    try testing.expect(ok);
    try testing.expectEqual(@as(u16, 1), dp.blocks_received);
    try testing.expectEqual(@as(u8, 0xAA), dp.buf[0]);
    try testing.expectEqual(@as(u8, 0xBB), dp.buf[1]);
    try testing.expectEqual(BlockState.received, dp.block_infos[0].state);
}

test "markBlockReceived rejects duplicate" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 4, 2);
    defer destroyDownloadingPieceFull(allocator, dp);

    _ = dp.markBlockRequested(0, 5);
    _ = dp.markBlockReceived(0, 5, test_address, 0, &.{ 0xAA, 0xBB });
    const dup = dp.markBlockReceived(0, 7, test_address, 0, &.{ 0xCC, 0xDD });
    try testing.expect(!dup);
    try testing.expectEqual(@as(u16, 1), dp.blocks_received);
    // Original data preserved
    try testing.expectEqual(@as(u8, 0xAA), dp.buf[0]);
}

test "isComplete returns true when all blocks received" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 4, 2);
    defer destroyDownloadingPieceFull(allocator, dp);

    try testing.expect(!dp.isComplete());
    _ = dp.markBlockReceived(0, 1, test_address, 0, &.{ 0x01, 0x02 });
    try testing.expect(!dp.isComplete());
    _ = dp.markBlockReceived(1, 2, test_address, 2, &.{ 0x03, 0x04 });
    try testing.expect(dp.isComplete());
}

test "releaseBlocksForPeer frees requested blocks" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 64 * 1024, 4);
    defer destroyDownloadingPieceFull(allocator, dp);

    _ = dp.markBlockRequested(0, 10);
    _ = dp.markBlockRequested(1, 10);
    _ = dp.markBlockRequested(2, 20);
    _ = dp.markBlockReceived(0, 10, test_address, 0, &.{0xFF});

    dp.releaseBlocksForPeer(10);

    // Block 0 was received -- should stay received
    try testing.expectEqual(BlockState.received, dp.block_infos[0].state);
    // Block 1 was only requested by peer 10 -- should be released
    try testing.expectEqual(BlockState.none, dp.block_infos[1].state);
    // Block 2 was requested by peer 20 -- should stay
    try testing.expectEqual(BlockState.requested, dp.block_infos[2].state);
    // Block 3 was never requested -- stays none
    try testing.expectEqual(BlockState.none, dp.block_infos[3].state);
    // blocks_requested should be decremented by 1 (block 1 released)
    try testing.expectEqual(@as(u16, 3), dp.blocks_requested);
}

test "unrequestedCount tracks available blocks" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 64 * 1024, 4);
    defer destroyDownloadingPieceFull(allocator, dp);

    try testing.expectEqual(@as(u16, 4), dp.unrequestedCount());
    _ = dp.markBlockRequested(0, 1);
    try testing.expectEqual(@as(u16, 3), dp.unrequestedCount());
    _ = dp.markBlockReceived(1, 2, test_address, 16384, &.{0});
    try testing.expectEqual(@as(u16, 2), dp.unrequestedCount());
}

test "markBlockReceived on unsolicited block counts as requested" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 4, 2);
    defer destroyDownloadingPieceFull(allocator, dp);

    // Receive block 0 without prior request
    const ok = dp.markBlockReceived(0, 5, test_address, 0, &.{ 0xAA, 0xBB });
    try testing.expect(ok);
    try testing.expectEqual(@as(u16, 1), dp.blocks_requested);
    try testing.expectEqual(@as(u16, 1), dp.blocks_received);
}

test "peer_count tracks references" {
    const allocator = testing.allocator;
    const dp = try createDownloadingPiece(allocator, 0, 0, 4, 2);
    defer destroyDownloadingPieceFull(allocator, dp);

    try testing.expectEqual(@as(u8, 0), dp.peer_count);
    dp.peer_count += 1;
    try testing.expectEqual(@as(u8, 1), dp.peer_count);
    dp.peer_count += 1;
    try testing.expectEqual(@as(u8, 2), dp.peer_count);
    dp.peer_count -= 1;
    try testing.expectEqual(@as(u8, 1), dp.peer_count);
}

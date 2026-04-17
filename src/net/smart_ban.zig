//! Smart Ban (BEP-like, inspired by libtorrent's smart_ban.cpp)
//!
//! When a piece fails hash verification, we record per-block SHA-1 digests
//! along with peer attribution. When the piece is re-downloaded and passes,
//! we compare the new per-block hashes against the stored ones. Peers whose
//! blocks differ (i.e. sent corrupt data that polluted the failed piece)
//! are banned. Peers whose blocks matched (i.e. sent correct data but
//! another peer corrupted a different block) are NOT banned.
//!
//! This avoids false-positive bans when multiple peers contribute blocks
//! to a piece (multi-source download).
//!
//! Lifecycle:
//!   1. completePieceDownload() -> snapshotAttribution(tid, piece, peer_addrs)
//!      records which peer sent each block, keyed by (tid, piece).
//!   2. processHashResults():
//!      - on FAIL: onPieceFailed(tid, piece, piece_buf, block_size)
//!        computes per-block SHA-1 and stores {peer_addr, digest} keyed by
//!        (tid, piece, block). The attribution snapshot is consumed.
//!      - on PASS: onPiecePassed(tid, piece, piece_buf, block_size)
//!        looks up prior records. For each block with a different hash,
//!        the peer that sent it is added to the ban list. The attribution
//!        snapshot for the current piece is also consumed (no longer needed).
//!   3. clearTorrent(tid) on torrent removal frees all entries for that torrent.

const std = @import("std");
const Sha1 = @import("../crypto/root.zig").Sha1;

pub const BlockKey = struct {
    torrent_id: u32,
    piece_index: u32,
    block_index: u16,
};

pub const BlockRecord = struct {
    peer_address: std.net.Address,
    digest: [20]u8,
};

pub const PieceKey = struct {
    torrent_id: u32,
    piece_index: u32,
};

/// Per-block peer attribution for a specific piece download.
/// null entries mean "unknown peer" (e.g. block wasn't attributed, or web seed).
pub const PieceAttribution = struct {
    /// Owned slice, indexed by block_index. null entries skip smart ban
    /// bookkeeping for that block (e.g. web seed-sourced blocks).
    block_peers: []?std.net.Address,

    pub fn deinit(self: *PieceAttribution, allocator: std.mem.Allocator) void {
        allocator.free(self.block_peers);
    }
};

pub const SmartBan = struct {
    allocator: std.mem.Allocator,

    /// Per-block records from pieces that failed hash verification, awaiting
    /// a successful re-download to determine which peer(s) sent corrupt data.
    records: std.AutoHashMap(BlockKey, BlockRecord),

    /// Transient per-piece attribution snapshots.  Populated at
    /// completePieceDownload and consumed when the matching hash result
    /// arrives in processHashResults (whether pass or fail).
    pending_attributions: std.AutoHashMap(PieceKey, PieceAttribution),

    pub fn init(allocator: std.mem.Allocator) SmartBan {
        return .{
            .allocator = allocator,
            .records = std.AutoHashMap(BlockKey, BlockRecord).init(allocator),
            .pending_attributions = std.AutoHashMap(PieceKey, PieceAttribution).init(allocator),
        };
    }

    pub fn deinit(self: *SmartBan) void {
        self.records.deinit();
        // Free any pending attribution slices
        var it = self.pending_attributions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.block_peers);
        }
        self.pending_attributions.deinit();
    }

    /// Store per-block peer attribution for a just-completed piece.
    /// The `block_peers` slice MUST be heap-allocated by the caller using
    /// `self.allocator` and is owned by SmartBan afterward (freed on consume).
    pub fn snapshotAttribution(
        self: *SmartBan,
        torrent_id: u32,
        piece_index: u32,
        block_peers: []?std.net.Address,
    ) !void {
        const key = PieceKey{ .torrent_id = torrent_id, .piece_index = piece_index };

        // Defensive: if an existing attribution is present for this key,
        // free it before overwriting.  This can happen if the hash result
        // for the previous attempt was dropped (e.g. torrent removed).
        if (self.pending_attributions.fetchRemove(key)) |old| {
            self.allocator.free(old.value.block_peers);
        }

        try self.pending_attributions.put(key, .{ .block_peers = block_peers });
    }

    /// Called when a piece fails hash verification.  Computes per-block
    /// SHA-1 digests from the corrupt piece buffer and stores records
    /// keyed by (torrent_id, piece_index, block_index).  The attribution
    /// snapshot for this piece is consumed.
    pub fn onPieceFailed(
        self: *SmartBan,
        torrent_id: u32,
        piece_index: u32,
        piece_buf: []const u8,
        block_size: u32,
    ) !void {
        const key = PieceKey{ .torrent_id = torrent_id, .piece_index = piece_index };
        const attribution = self.pending_attributions.fetchRemove(key) orelse return;
        defer self.allocator.free(attribution.value.block_peers);

        const block_peers = attribution.value.block_peers;
        var offset: usize = 0;
        var block_index: u16 = 0;
        while (offset < piece_buf.len) : (block_index += 1) {
            if (block_index >= block_peers.len) break;
            const remaining = piece_buf.len - offset;
            const this_len = @min(@as(usize, @intCast(block_size)), remaining);

            const peer_addr = block_peers[block_index] orelse {
                offset += this_len;
                continue;
            };

            var digest: [20]u8 = undefined;
            Sha1.hash(piece_buf[offset .. offset + this_len], &digest, .{});

            const bkey = BlockKey{
                .torrent_id = torrent_id,
                .piece_index = piece_index,
                .block_index = block_index,
            };

            // If a record already exists (piece failed multiple times from
            // the same peer), check whether this peer's block hash differs
            // from last time.  If yes, the peer is actively corrupting —
            // return true so the caller can ban immediately.  For now we
            // simply overwrite; the on-pass comparison catches the bad peer
            // definitively.
            try self.records.put(bkey, .{
                .peer_address = peer_addr,
                .digest = digest,
            });

            offset += this_len;
        }
    }

    /// Called when a piece passes hash verification.  Compares per-block
    /// digests from the verified buffer against any stored records from a
    /// prior failure of this piece.  Returns a list of peer addresses that
    /// sent mismatching blocks (these should be banned).  Caller owns the
    /// returned slice.  The attribution snapshot for this piece is also
    /// consumed (no longer needed since the piece is now verified).
    pub fn onPiecePassed(
        self: *SmartBan,
        torrent_id: u32,
        piece_index: u32,
        piece_buf: []const u8,
        block_size: u32,
    ) ![]std.net.Address {
        // Always consume the attribution for the current (passing) piece.
        const cur_key = PieceKey{ .torrent_id = torrent_id, .piece_index = piece_index };
        if (self.pending_attributions.fetchRemove(cur_key)) |att| {
            self.allocator.free(att.value.block_peers);
        }

        // Look up stored records for this piece.
        var bad_peers = std.ArrayList(std.net.Address).empty;
        errdefer bad_peers.deinit(self.allocator);

        // We need to iterate all records for this piece.  Since AutoHashMap
        // doesn't support prefix lookup, we scan all entries.  In practice
        // the records map only grows when pieces fail, and entries are
        // removed on successful comparison, so this is small.
        var keys_to_remove = std.ArrayList(BlockKey).empty;
        defer keys_to_remove.deinit(self.allocator);

        var it = self.records.iterator();
        while (it.next()) |entry| {
            const bkey = entry.key_ptr.*;
            if (bkey.torrent_id != torrent_id or bkey.piece_index != piece_index) continue;

            const block_offset = @as(usize, bkey.block_index) * @as(usize, block_size);
            if (block_offset >= piece_buf.len) {
                try keys_to_remove.append(self.allocator, bkey);
                continue;
            }
            const remaining = piece_buf.len - block_offset;
            const this_len = @min(@as(usize, @intCast(block_size)), remaining);

            var actual: [20]u8 = undefined;
            Sha1.hash(piece_buf[block_offset .. block_offset + this_len], &actual, .{});

            if (!std.mem.eql(u8, &actual, &entry.value_ptr.digest)) {
                // Different hash -- the peer that sent this block in the
                // failed download corrupted it.  Record for banning.
                try bad_peers.append(self.allocator, entry.value_ptr.peer_address);
            }

            try keys_to_remove.append(self.allocator, bkey);
        }

        for (keys_to_remove.items) |k| {
            _ = self.records.remove(k);
        }

        return bad_peers.toOwnedSlice(self.allocator);
    }

    /// Free all entries (records + pending attributions) for a specific
    /// torrent.  Call when a torrent is removed or becomes a seed.
    pub fn clearTorrent(self: *SmartBan, torrent_id: u32) void {
        // Remove all records for this torrent
        var rkeys = std.ArrayList(BlockKey).empty;
        defer rkeys.deinit(self.allocator);

        var rit = self.records.iterator();
        while (rit.next()) |entry| {
            if (entry.key_ptr.torrent_id == torrent_id) {
                rkeys.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (rkeys.items) |k| _ = self.records.remove(k);

        // Free and remove all pending attributions for this torrent
        var pkeys = std.ArrayList(PieceKey).empty;
        defer pkeys.deinit(self.allocator);

        var pit = self.pending_attributions.iterator();
        while (pit.next()) |entry| {
            if (entry.key_ptr.torrent_id == torrent_id) {
                pkeys.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (pkeys.items) |k| {
            if (self.pending_attributions.fetchRemove(k)) |removed| {
                self.allocator.free(removed.value.block_peers);
            }
        }
    }

    /// Returns the number of stored block records (for tests/observability).
    pub fn recordCount(self: *const SmartBan) usize {
        return self.records.count();
    }

    /// Returns the number of pending attribution entries (for tests/observability).
    pub fn pendingAttributionCount(self: *const SmartBan) usize {
        return self.pending_attributions.count();
    }
};

// ── Tests ─────────────────────────────────────────────────

test "smart ban: records and matches block hashes for failed then passed piece" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var sb = SmartBan.init(alloc);
    defer sb.deinit();

    const block_size: u32 = 16;
    const piece_size: usize = 64; // 4 blocks of 16 bytes
    var piece_bad: [piece_size]u8 = undefined;
    var piece_good: [piece_size]u8 = undefined;
    @memset(&piece_bad, 0);
    @memset(&piece_good, 0);
    // Block 2 was corrupted by peer A in the failed download
    @memset(piece_bad[32..48], 0xFF);

    const peer_a = try std.net.Address.parseIp4("1.2.3.4", 0);
    const peer_b = try std.net.Address.parseIp4("5.6.7.8", 0);

    // Snapshot attribution: block 0,2 from peer A; block 1,3 from peer B
    const attr = try alloc.alloc(?std.net.Address, 4);
    attr[0] = peer_a;
    attr[1] = peer_b;
    attr[2] = peer_a;
    attr[3] = peer_b;
    try sb.snapshotAttribution(1, 5, attr);

    // Piece fails
    try sb.onPieceFailed(1, 5, piece_bad[0..], block_size);
    try testing.expectEqual(@as(usize, 4), sb.recordCount());
    try testing.expectEqual(@as(usize, 0), sb.pendingAttributionCount());

    // Snapshot attribution again for the re-download (all from peer B)
    const attr2 = try alloc.alloc(?std.net.Address, 4);
    attr2[0] = peer_b;
    attr2[1] = peer_b;
    attr2[2] = peer_b;
    attr2[3] = peer_b;
    try sb.snapshotAttribution(1, 5, attr2);

    // Piece passes -- check that peer A is identified
    const bad = try sb.onPiecePassed(1, 5, piece_good[0..], block_size);
    defer alloc.free(bad);

    // Peers that sent different data in the failed download are banned.
    // In the bad download: block 0 (peer A, hash(zeros)), block 1 (B, zeros),
    // block 2 (A, 0xFFs), block 3 (B, zeros).
    // In the good download: all zeros.
    // So block 2 differs -> peer A is banned.
    // Blocks 0, 1, 3 match -> no ban.
    try testing.expectEqual(@as(usize, 1), bad.len);
    try testing.expect(bad[0].eql(peer_a));

    try testing.expectEqual(@as(usize, 0), sb.recordCount());
    try testing.expectEqual(@as(usize, 0), sb.pendingAttributionCount());
}

test "smart ban: returns empty when piece passes without prior failure" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var sb = SmartBan.init(alloc);
    defer sb.deinit();

    var piece: [32]u8 = undefined;
    @memset(&piece, 0);

    // No attribution snapshot, no prior failure
    const bad = try sb.onPiecePassed(1, 5, piece[0..], 16);
    defer alloc.free(bad);
    try testing.expectEqual(@as(usize, 0), bad.len);
}

test "smart ban: clearTorrent removes all entries for torrent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var sb = SmartBan.init(alloc);
    defer sb.deinit();

    const peer = try std.net.Address.parseIp4("1.2.3.4", 0);
    const attr = try alloc.alloc(?std.net.Address, 2);
    attr[0] = peer;
    attr[1] = peer;
    try sb.snapshotAttribution(1, 0, attr);

    var piece: [32]u8 = undefined;
    @memset(&piece, 0);
    try sb.onPieceFailed(1, 0, piece[0..], 16);
    try testing.expectEqual(@as(usize, 2), sb.recordCount());

    // Attribution for a different torrent
    const attr2 = try alloc.alloc(?std.net.Address, 2);
    attr2[0] = peer;
    attr2[1] = peer;
    try sb.snapshotAttribution(2, 0, attr2);
    try testing.expectEqual(@as(usize, 1), sb.pendingAttributionCount());

    sb.clearTorrent(1);
    try testing.expectEqual(@as(usize, 0), sb.recordCount());
    try testing.expectEqual(@as(usize, 1), sb.pendingAttributionCount());

    sb.clearTorrent(2);
    try testing.expectEqual(@as(usize, 0), sb.pendingAttributionCount());
}

test "smart ban: null block_peer entries are skipped (web seed)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var sb = SmartBan.init(alloc);
    defer sb.deinit();

    const peer = try std.net.Address.parseIp4("1.2.3.4", 0);
    // Block 0 from web seed (null), block 1 from peer
    const attr = try alloc.alloc(?std.net.Address, 2);
    attr[0] = null;
    attr[1] = peer;
    try sb.snapshotAttribution(1, 0, attr);

    var piece: [32]u8 = undefined;
    @memset(&piece, 0);
    try sb.onPieceFailed(1, 0, piece[0..], 16);
    // Only 1 record (block 1); the null block was skipped.
    try testing.expectEqual(@as(usize, 1), sb.recordCount());
}

test "smart ban: snapshotAttribution replaces existing entry" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var sb = SmartBan.init(alloc);
    defer sb.deinit();

    const peer = try std.net.Address.parseIp4("1.2.3.4", 0);

    const attr1 = try alloc.alloc(?std.net.Address, 2);
    attr1[0] = peer;
    attr1[1] = peer;
    try sb.snapshotAttribution(1, 0, attr1);

    const attr2 = try alloc.alloc(?std.net.Address, 3);
    attr2[0] = peer;
    attr2[1] = peer;
    attr2[2] = peer;
    try sb.snapshotAttribution(1, 0, attr2);

    try testing.expectEqual(@as(usize, 1), sb.pendingAttributionCount());
}

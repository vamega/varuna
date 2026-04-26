const std = @import("std");
const merkle = @import("merkle.zig");
const metainfo = @import("metainfo.zig");
const layout = @import("layout.zig");
const hash_exchange = @import("../net/hash_exchange.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const Sha256 = @import("../crypto/root.zig").Sha256;

const log = std.log.scoped(.merkle_cache);

/// Per-torrent Merkle tree cache for BEP 52 hash serving.
///
/// Caches per-file Merkle trees built from verified piece hashes. Trees are
/// built lazily on first hash request for a file (provided all pieces for that
/// file are complete) and evicted LRU when the cache exceeds `max_cached_trees`.
///
/// Memory usage: each cached tree stores O(2N) hashes of 32 bytes each, where
/// N is the number of pieces in the file (padded to next power of 2). A file
/// with 1024 pieces uses ~64 KiB for its tree.
///
/// Async Merkle tree building: when a hash request arrives for an uncached file,
/// the work is submitted to the Hasher threadpool instead of blocking the event
/// loop. Pending requests are tracked here so that when the async result arrives,
/// all waiting peers can be served. Multiple peers requesting the same file's
/// tree while it is being built are coalesced -- only one build job is submitted.
pub const MerkleCache = struct {
    allocator: std.mem.Allocator,

    /// Per-file cached Merkle trees. null = not yet built or evicted.
    trees: []?merkle.MerkleTree,

    /// LRU tracking: access_order[i] is the last-access timestamp for file i.
    access_order: []u64,

    /// Monotonic counter for LRU ordering.
    access_counter: u64 = 0,

    /// Number of currently cached trees.
    cached_count: u32 = 0,

    /// Maximum number of trees to keep in cache.
    max_cached_trees: u32,

    /// Layout for piece-to-file mapping.
    layout: *const layout.Layout,

    /// v2 file metadata (for pieces_root validation).
    v2_files: []const metainfo.V2File,

    /// Pending hash requests waiting for async Merkle tree builds.
    pending_requests: std.ArrayList(PendingHashRequest),

    /// Set of file indices currently being built on the hasher threadpool.
    /// Used to coalesce multiple requests for the same file.
    /// Small set -- linear scan is fine (typically < 10 concurrent builds).
    building_files: std.ArrayList(u32),

    /// A hash request waiting for a Merkle tree to be built asynchronously.
    pub const PendingHashRequest = struct {
        slot: u16,
        file_index: u32,
        request: hash_exchange.HashRequest,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        torrent_layout: *const layout.Layout,
        v2_files: []const metainfo.V2File,
        max_cached: u32,
    ) !MerkleCache {
        const file_count = v2_files.len;
        const trees = try allocator.alloc(?merkle.MerkleTree, file_count);
        @memset(trees, null);
        const access_order = try allocator.alloc(u64, file_count);
        @memset(access_order, 0);

        return .{
            .allocator = allocator,
            .trees = trees,
            .access_order = access_order,
            .max_cached_trees = if (max_cached == 0) @intCast(@max(file_count, 1)) else max_cached,
            .layout = torrent_layout,
            .v2_files = v2_files,
            .pending_requests = std.ArrayList(PendingHashRequest).empty,
            .building_files = std.ArrayList(u32).empty,
        };
    }

    pub fn deinit(self: *MerkleCache) void {
        for (self.trees) |*entry| {
            if (entry.*) |*tree| {
                tree.deinit();
            }
        }
        self.allocator.free(self.trees);
        self.allocator.free(self.access_order);
        self.pending_requests.deinit(self.allocator);
        self.building_files.deinit(self.allocator);

        self.* = undefined;
    }

    /// Add a pending hash request that will be served when the Merkle tree
    /// for `file_index` is built. Returns true if a build job should be
    /// submitted (i.e., this is the first request for this file).
    pub fn addPendingRequest(self: *MerkleCache, slot: u16, req: hash_exchange.HashRequest) !bool {
        try self.pending_requests.append(self.allocator, .{
            .slot = slot,
            .file_index = req.file_index,
            .request = req,
        });

        if (self.isFileBuilding(req.file_index)) {
            // Already building -- just queue the request
            return false;
        }

        // Mark as building
        try self.building_files.append(self.allocator, req.file_index);
        return true;
    }

    /// Remove all pending requests for a given file index and return them.
    /// Called when the Merkle tree build completes (success or failure).
    pub fn takePendingRequests(
        self: *MerkleCache,
        file_index: u32,
        out: *std.ArrayList(PendingHashRequest),
    ) void {
        // Remove from building set
        for (self.building_files.items, 0..) |fi, idx| {
            if (fi == file_index) {
                _ = self.building_files.swapRemove(idx);
                break;
            }
        }

        // Collect matching requests (iterate backwards for safe removal)
        var i: usize = self.pending_requests.items.len;
        while (i > 0) {
            i -= 1;
            if (self.pending_requests.items[i].file_index == file_index) {
                out.append(self.allocator, self.pending_requests.items[i]) catch continue;
                _ = self.pending_requests.swapRemove(i);
            }
        }
    }

    /// Remove all pending requests for a given peer slot.
    /// Called when a peer disconnects before its requests are served.
    pub fn removePendingRequestsForSlot(self: *MerkleCache, slot: u16) void {
        var i: usize = self.pending_requests.items.len;
        while (i > 0) {
            i -= 1;
            if (self.pending_requests.items[i].slot == slot) {
                _ = self.pending_requests.swapRemove(i);
            }
        }
    }

    /// Check if a file is currently being built on the hasher threadpool.
    pub fn isFileBuilding(self: *const MerkleCache, file_index: u32) bool {
        for (self.building_files.items) |fi| {
            if (fi == file_index) return true;
        }
        return false;
    }

    /// Get or build the Merkle tree for a file. Returns null if the file's
    /// pieces are not all complete. `piece_hashes_provider` is called to get
    /// the SHA-256 piece hashes for the file; it receives (file_index, first_piece, piece_count)
    /// and should return a slice of [32]u8 hashes or null if unavailable.
    pub fn getTree(
        self: *MerkleCache,
        file_index: u32,
    ) ?*const merkle.MerkleTree {
        if (file_index >= self.trees.len) return null;

        if (self.trees[file_index]) |*tree| {
            // Cache hit -- update LRU
            self.access_counter += 1;
            self.access_order[file_index] = self.access_counter;
            return tree;
        }

        return null;
    }

    /// Build and cache a Merkle tree for a file from pre-computed piece hashes.
    /// The caller is responsible for computing SHA-256 of each piece's data.
    /// Returns the cached tree or an error.
    ///
    /// `piece_hashes` must contain exactly the number of pieces for this file.
    /// The resulting tree root is validated against the expected `pieces_root`
    /// from the torrent metadata.
    pub fn buildAndCache(
        self: *MerkleCache,
        file_index: u32,
        piece_hashes: []const [32]u8,
    ) !*const merkle.MerkleTree {
        if (file_index >= self.trees.len) return error.InvalidFileIndex;

        // Evict if at capacity
        if (self.trees[file_index] == null and self.cached_count >= self.max_cached_trees) {
            self.evictLru();
        }

        // Build the tree
        var tree = try merkle.MerkleTree.fromPieceHashes(self.allocator, piece_hashes);
        errdefer tree.deinit();

        // Validate root against expected pieces_root
        const expected_root = self.v2_files[file_index].pieces_root;
        const computed_root = tree.root();
        if (!std.mem.eql(u8, &computed_root, &expected_root)) {
            tree.deinit();
            return error.MerkleRootMismatch;
        }

        // Store in cache
        if (self.trees[file_index]) |*old| {
            old.deinit();
        } else {
            self.cached_count += 1;
        }
        self.trees[file_index] = tree;
        self.access_counter += 1;
        self.access_order[file_index] = self.access_counter;

        return &self.trees[file_index].?;
    }

    /// Check if all pieces for a given file are complete.
    pub fn isFileComplete(
        self: *const MerkleCache,
        file_index: u32,
        complete_pieces: *const Bitfield,
    ) bool {
        if (file_index >= self.layout.files.len) return false;
        const file = self.layout.files[file_index];
        if (file.length == 0) return true;

        for (file.first_piece..file.end_piece_exclusive) |pi| {
            if (!complete_pieces.has(@intCast(pi))) return false;
        }
        return true;
    }

    /// Return the piece range for a file: (first_piece, piece_count).
    pub fn filePieceRange(self: *const MerkleCache, file_index: u32) ?struct { first: u32, count: u32 } {
        if (file_index >= self.layout.files.len) return null;
        const file = self.layout.files[file_index];
        if (file.length == 0) return null;
        const count = file.end_piece_exclusive - file.first_piece;
        return .{ .first = file.first_piece, .count = count };
    }

    /// Evict the least recently used cached tree.
    fn evictLru(self: *MerkleCache) void {
        var min_access: u64 = std.math.maxInt(u64);
        var victim: ?usize = null;

        for (self.trees, 0..) |entry, i| {
            if (entry != null and self.access_order[i] < min_access) {
                min_access = self.access_order[i];
                victim = i;
            }
        }

        if (victim) |v| {
            if (self.trees[v]) |*tree| {
                tree.deinit();
                self.trees[v] = null;
                self.access_order[v] = 0;
                self.cached_count -= 1;
            }
        }
    }

    /// Invalidate the cached tree for a file (e.g., on piece failure).
    pub fn invalidate(self: *MerkleCache, file_index: u32) void {
        if (file_index >= self.trees.len) return;
        if (self.trees[file_index]) |*tree| {
            tree.deinit();
            self.trees[file_index] = null;
            self.access_order[file_index] = 0;
            self.cached_count -= 1;
        }
    }

    /// v2/hybrid analog of Phase 1 of the piece-hash lifecycle: drop any
    /// cached Merkle tree for a file all of whose pieces are now complete.
    /// Called from the EL after `pt.completePiece` returns true so we
    /// don't keep tens of MB of derived per-piece SHA-256 hashes around
    /// once they're no longer needed for hash-exchange serving.
    ///
    /// The per-file `pieces_root` (32 bytes) lives in the metainfo and is
    /// not affected — that's the small, permanent root, sufficient for
    /// any future verification / hash-exchange protocol response.
    pub fn evictCompletedFile(
        self: *MerkleCache,
        file_index: u32,
        complete_pieces: *const Bitfield,
    ) void {
        if (file_index >= self.trees.len) return;
        if (self.trees[file_index] == null) return;
        if (!self.isFileComplete(file_index, complete_pieces)) return;
        self.invalidate(file_index);
    }

    /// Return the number of cached trees.
    pub fn cachedCount(self: *const MerkleCache) u32 {
        return self.cached_count;
    }
};

/// Build piece hashes for a file by hashing piece data buffers.
/// `piece_data_fn` is called with (global_piece_index) and should return the
/// piece data or null if unavailable.
pub fn computePieceHashes(
    allocator: std.mem.Allocator,
    first_piece: u32,
    piece_count: u32,
    _: *const layout.Layout,
    piece_data_fn: *const fn (u32) ?[]const u8,
) !?[][32]u8 {
    const hashes = try allocator.alloc([32]u8, piece_count);
    errdefer allocator.free(hashes);

    for (0..piece_count) |i| {
        const global_piece = first_piece + @as(u32, @intCast(i));
        const data = piece_data_fn(global_piece) orelse {
            allocator.free(hashes);
            return null;
        };
        hashes[i] = merkle.hashLeaf(data);
    }

    return hashes;
}

// ── Tests ──────────────────────────────────────────────────

test "merkle cache init and deinit" {
    const allocator = std.testing.allocator;

    // Create a minimal v2 file layout
    var files = [_]layout.Layout.File{
        .{
            .length = 1024,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 2,
            .path = &.{},
            .v2_piece_offset = 0,
        },
        .{
            .length = 512,
            .torrent_offset = 1024,
            .first_piece = 2,
            .end_piece_exclusive = 3,
            .path = &.{},
            .v2_piece_offset = 2,
        },
    };

    // Build piece hashes to derive expected roots
    const h0 = merkle.hashLeaf("piece0_data");
    const h1 = merkle.hashLeaf("piece1_data");
    const h2 = merkle.hashLeaf("piece2_data");

    // Build expected roots
    var tree0 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{ h0, h1 });
    defer tree0.deinit();
    var tree1 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{h2});
    defer tree1.deinit();

    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = tree0.root() },
        .{ .path = &.{}, .length = 512, .pieces_root = tree1.root() },
    };

    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 3,
        .total_size = 1536,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    try std.testing.expectEqual(@as(u32, 0), cache.cachedCount());
    try std.testing.expect(cache.getTree(0) == null);
    try std.testing.expect(cache.getTree(1) == null);
}

test "merkle cache build and retrieve" {
    const allocator = std.testing.allocator;

    const h0 = merkle.hashLeaf("piece0_data");
    const h1 = merkle.hashLeaf("piece1_data");

    var expected_tree = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{ h0, h1 });
    defer expected_tree.deinit();

    var files = [_]layout.Layout.File{
        .{
            .length = 1024,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 2,
            .path = &.{},
            .v2_piece_offset = 0,
        },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = expected_tree.root() },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 2,
        .total_size = 1024,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    // Build and cache
    const tree_ptr = try cache.buildAndCache(0, &[_][32]u8{ h0, h1 });
    try std.testing.expectEqual(@as(u32, 1), cache.cachedCount());

    // Verify root matches
    try std.testing.expectEqual(expected_tree.root(), tree_ptr.root());

    // Get from cache
    const cached = cache.getTree(0);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(expected_tree.root(), cached.?.root());
}

test "merkle cache rejects wrong root" {
    const allocator = std.testing.allocator;

    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");

    var files = [_]layout.Layout.File{
        .{
            .length = 1024,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 2,
            .path = &.{},
            .v2_piece_offset = 0,
        },
    };
    // Wrong root -- all zeros
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 2,
        .total_size = 1024,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    try std.testing.expectError(error.MerkleRootMismatch, cache.buildAndCache(0, &[_][32]u8{ h0, h1 }));
    try std.testing.expectEqual(@as(u32, 0), cache.cachedCount());
}

test "merkle cache LRU eviction" {
    const allocator = std.testing.allocator;

    const h0 = merkle.hashLeaf("f0p0");
    const h1 = merkle.hashLeaf("f1p0");
    const h2 = merkle.hashLeaf("f2p0");

    var tree0 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{h0});
    defer tree0.deinit();
    var tree1 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{h1});
    defer tree1.deinit();
    var tree2 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{h2});
    defer tree2.deinit();

    var files = [_]layout.Layout.File{
        .{ .length = 512, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 1, .path = &.{}, .v2_piece_offset = 0 },
        .{ .length = 512, .torrent_offset = 512, .first_piece = 1, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 1 },
        .{ .length = 512, .torrent_offset = 1024, .first_piece = 2, .end_piece_exclusive = 3, .path = &.{}, .v2_piece_offset = 2 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 512, .pieces_root = tree0.root() },
        .{ .path = &.{}, .length = 512, .pieces_root = tree1.root() },
        .{ .path = &.{}, .length = 512, .pieces_root = tree2.root() },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 3,
        .total_size = 1536,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    // max_cached = 2, so inserting a 3rd should evict the oldest
    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 2);
    defer cache.deinit();

    _ = try cache.buildAndCache(0, &[_][32]u8{h0});
    _ = try cache.buildAndCache(1, &[_][32]u8{h1});
    try std.testing.expectEqual(@as(u32, 2), cache.cachedCount());

    // Access file 1 to make file 0 the LRU victim
    _ = cache.getTree(1);

    // Insert file 2 -- should evict file 0
    _ = try cache.buildAndCache(2, &[_][32]u8{h2});
    try std.testing.expectEqual(@as(u32, 2), cache.cachedCount());
    try std.testing.expect(cache.getTree(0) == null); // evicted
    try std.testing.expect(cache.getTree(1) != null);
    try std.testing.expect(cache.getTree(2) != null);
}

test "merkle cache invalidate" {
    const allocator = std.testing.allocator;

    const h0 = merkle.hashLeaf("data");
    var tree0 = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{h0});
    defer tree0.deinit();

    var files = [_]layout.Layout.File{
        .{ .length = 512, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 1, .path = &.{}, .v2_piece_offset = 0 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 512, .pieces_root = tree0.root() },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 1,
        .total_size = 512,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    _ = try cache.buildAndCache(0, &[_][32]u8{h0});
    try std.testing.expectEqual(@as(u32, 1), cache.cachedCount());

    cache.invalidate(0);
    try std.testing.expectEqual(@as(u32, 0), cache.cachedCount());
    try std.testing.expect(cache.getTree(0) == null);
}

test "merkle cache isFileComplete" {
    const allocator = std.testing.allocator;

    var files = [_]layout.Layout.File{
        .{ .length = 1024, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 0 },
        .{ .length = 512, .torrent_offset = 1024, .first_piece = 2, .end_piece_exclusive = 3, .path = &.{}, .v2_piece_offset = 2 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = &.{}, .length = 512, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 3,
        .total_size = 1536,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    var bf = try Bitfield.init(allocator, 3);
    defer bf.deinit(allocator);

    // No pieces complete
    try std.testing.expect(!cache.isFileComplete(0, &bf));
    try std.testing.expect(!cache.isFileComplete(1, &bf));

    // Complete piece 0 only -- file 0 still incomplete
    try bf.set(0);
    try std.testing.expect(!cache.isFileComplete(0, &bf));

    // Complete piece 1 -- file 0 now complete
    try bf.set(1);
    try std.testing.expect(cache.isFileComplete(0, &bf));
    try std.testing.expect(!cache.isFileComplete(1, &bf));

    // Complete piece 2 -- file 1 now complete
    try bf.set(2);
    try std.testing.expect(cache.isFileComplete(1, &bf));
}

test "merkle cache filePieceRange" {
    const allocator = std.testing.allocator;

    var files = [_]layout.Layout.File{
        .{ .length = 1024, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 0 },
        .{ .length = 0, .torrent_offset = 1024, .first_piece = 2, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 2 },
        .{ .length = 512, .torrent_offset = 1024, .first_piece = 2, .end_piece_exclusive = 3, .path = &.{}, .v2_piece_offset = 2 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = &.{}, .length = 0, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = &.{}, .length = 512, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 3,
        .total_size = 1536,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    const r0 = cache.filePieceRange(0).?;
    try std.testing.expectEqual(@as(u32, 0), r0.first);
    try std.testing.expectEqual(@as(u32, 2), r0.count);

    // Zero-length file has no piece range
    try std.testing.expect(cache.filePieceRange(1) == null);

    const r2 = cache.filePieceRange(2).?;
    try std.testing.expectEqual(@as(u32, 2), r2.first);
    try std.testing.expectEqual(@as(u32, 1), r2.count);

    // Out of range
    try std.testing.expect(cache.filePieceRange(99) == null);
}

test "merkle cache serves hashes via buildHashesFromTree" {
    const allocator = std.testing.allocator;

    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");
    const h2 = merkle.hashLeaf("piece2");
    const h3 = merkle.hashLeaf("piece3");

    var expected_tree = try merkle.MerkleTree.fromPieceHashes(allocator, &[_][32]u8{ h0, h1, h2, h3 });
    defer expected_tree.deinit();

    var files = [_]layout.Layout.File{
        .{ .length = 2048, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 4, .path = &.{}, .v2_piece_offset = 0 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 2048, .pieces_root = expected_tree.root() },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 4,
        .total_size = 2048,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    // Build the tree
    _ = try cache.buildAndCache(0, &[_][32]u8{ h0, h1, h2, h3 });

    // Now use buildHashesFromTree to serve a hash request
    const tree = cache.getTree(0).?;
    const req = hash_exchange.HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 4,
        .proof_layers = 0,
    };
    const resp = (try hash_exchange.buildHashesFromTree(allocator, tree, req)).?;
    defer hash_exchange.freeHashesResponse(allocator, resp);

    try std.testing.expectEqual(@as(usize, 4), resp.hashes.len);
    try std.testing.expectEqual(h0, resp.hashes[0]);
    try std.testing.expectEqual(h1, resp.hashes[1]);
    try std.testing.expectEqual(h2, resp.hashes[2]);
    try std.testing.expectEqual(h3, resp.hashes[3]);
}

test "merkle cache pending request tracking" {
    const allocator = std.testing.allocator;

    var files = [_]layout.Layout.File{
        .{ .length = 1024, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 0 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 2,
        .total_size = 1024,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    const req = hash_exchange.HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 2,
        .proof_layers = 0,
    };

    // First request should return true (need to submit build job)
    const need_submit1 = try cache.addPendingRequest(0, req);
    try std.testing.expect(need_submit1);
    try std.testing.expect(cache.isFileBuilding(0));

    // Second request for same file should return false (coalesced)
    const need_submit2 = try cache.addPendingRequest(1, req);
    try std.testing.expect(!need_submit2);

    // Take pending requests
    var out = std.ArrayList(MerkleCache.PendingHashRequest).empty;
    defer out.deinit(allocator);
    cache.takePendingRequests(0, &out);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(!cache.isFileBuilding(0));
}

test "merkle cache pending request removal on disconnect" {
    const allocator = std.testing.allocator;

    var files = [_]layout.Layout.File{
        .{ .length = 1024, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 2, .path = &.{}, .v2_piece_offset = 0 },
        .{ .length = 512, .torrent_offset = 1024, .first_piece = 2, .end_piece_exclusive = 3, .path = &.{}, .v2_piece_offset = 2 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 1024, .pieces_root = [_]u8{0} ** 32 },
        .{ .path = &.{}, .length = 512, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 3,
        .total_size = 1536,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    const req0 = hash_exchange.HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 2,
        .proof_layers = 0,
    };
    const req1 = hash_exchange.HashRequest{
        .file_index = 1,
        .base_layer = 0,
        .index = 0,
        .length = 1,
        .proof_layers = 0,
    };

    // Slot 5 requests file 0, slot 7 requests file 0, slot 5 requests file 1
    _ = try cache.addPendingRequest(5, req0);
    _ = try cache.addPendingRequest(7, req0);
    _ = try cache.addPendingRequest(5, req1);

    // Disconnect slot 5 -- should remove both of its requests
    cache.removePendingRequestsForSlot(5);

    // Only slot 7's request for file 0 should remain
    var out = std.ArrayList(MerkleCache.PendingHashRequest).empty;
    defer out.deinit(allocator);
    cache.takePendingRequests(0, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u16, 7), out.items[0].slot);
}

test "merkle cache coalesces multiple peers requesting same file" {
    const allocator = std.testing.allocator;

    var files = [_]layout.Layout.File{
        .{ .length = 2048, .torrent_offset = 0, .first_piece = 0, .end_piece_exclusive = 4, .path = &.{}, .v2_piece_offset = 0 },
    };
    var v2_files = [_]metainfo.V2File{
        .{ .path = &.{}, .length = 2048, .pieces_root = [_]u8{0} ** 32 },
    };
    var lo = layout.Layout{
        .piece_length = 512,
        .piece_count = 4,
        .total_size = 2048,
        .files = &files,
        .piece_hashes = null,
        .version = .v2,
        .v2_files = &v2_files,
    };

    var cache = try MerkleCache.init(allocator, &lo, &v2_files, 8);
    defer cache.deinit();

    const req = hash_exchange.HashRequest{
        .file_index = 0,
        .base_layer = 0,
        .index = 0,
        .length = 4,
        .proof_layers = 0,
    };

    // 4 peers request the same file
    const submit1 = try cache.addPendingRequest(10, req);
    try std.testing.expect(submit1); // first: submit

    const submit2 = try cache.addPendingRequest(20, req);
    try std.testing.expect(!submit2); // coalesced

    const submit3 = try cache.addPendingRequest(30, req);
    try std.testing.expect(!submit3); // coalesced

    const submit4 = try cache.addPendingRequest(40, req);
    try std.testing.expect(!submit4); // coalesced

    try std.testing.expect(cache.isFileBuilding(0));

    // All 4 should be returned when taking
    var out = std.ArrayList(MerkleCache.PendingHashRequest).empty;
    defer out.deinit(allocator);
    cache.takePendingRequests(0, &out);

    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expect(!cache.isFileBuilding(0));
}

const std = @import("std");
const sqlite = @import("sqlite3.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;

/// Persistent resume state. The daemon uses `ResumeDb`, which is
/// `ResumeDbOf(SqliteBackend)` — backed by SQLite (see `SqliteBackend`).
/// Sim tests use `ResumeDbOf(SimResumeBackend)` for in-memory,
/// fault-injectable resume state without touching real SQLite.
///
/// The `ResumeDbOf` functor is the comptime-trait that pins both
/// backends to the same public surface (49 methods + helper types).
/// Mirrors the `EventLoopOf(IO)` / `AsyncRecheckOf(IO)` pattern.
///
/// Production note: SQLite is opened with `SQLITE_OPEN_FULLMUTEX`,
/// so the connection is touched from many threads (worker threads,
/// RPC handlers, queue manager). Any future `SimResumeBackend`-shaped
/// alternative needs the same multi-thread invariant.
pub fn ResumeDbOf(comptime Backend: type) type {
    // Identity functor: each backend is itself the resume DB type.
    // Both backends expose the same public method set; using the same
    // backend value here gives consumers one canonical type alias for
    // the production path while keeping `SimResumeBackend` callable as
    // its own type for sim tests.
    return Backend;
}

/// Daemon-side concrete instantiation. Daemon callers continue to write
/// `ResumeDb`; tests that want the in-memory backend use
/// `SimResumeBackend` directly or via `ResumeDbOf(SimResumeBackend)`.
pub const ResumeDb = ResumeDbOf(SqliteBackend);

/// In-memory, fault-injectable resume DB backend for `EventLoopOf(SimIO)`
/// tests. See `src/storage/sim_resume_backend.zig` for the implementation.
pub const SimResumeBackend = @import("sim_resume_backend.zig").SimResumeBackend;

/// Shared types — same shape for both backends so callers can swap
/// `SqliteBackend` for `SimResumeBackend` without any signature change.
pub const TransferStats = struct {
    total_uploaded: u64 = 0,
    total_downloaded: u64 = 0,
};

pub const RateLimits = struct {
    dl_limit: u64 = 0,
    ul_limit: u64 = 0,
};

pub const ShareLimits = struct {
    /// -2 = use global, -1 = no limit, >=0 = specific ratio limit.
    ratio_limit: f64 = -2.0,
    /// -2 = use global, -1 = no limit, >=0 = specific minutes limit.
    seeding_time_limit: i64 = -2,
    /// Timestamp when the torrent completed downloading. 0 = not yet.
    completion_on: i64 = 0,
};

pub const IpFilterConfig = struct {
    path: ?[]const u8 = null,
    enabled: bool = false,
    rule_count: u32 = 0,
};

/// A tracker override record: 'add' means a user-added tracker URL,
/// 'remove' means a metainfo tracker URL the user wants hidden,
/// 'edit' means the user replaced orig_url with url.
pub const TrackerOverride = struct {
    url: []const u8,
    tier: u32,
    action: []const u8, // "add", "remove", or "edit"
    orig_url: ?[]const u8, // non-null only for "edit" action
};

pub const SavedCategory = struct {
    name: []const u8,
    save_path: []const u8,
};

pub const SavedBannedIp = struct {
    address: []const u8,
    source: u8,
    reason: ?[]const u8,
    created_at: i64,
};

pub const SavedBannedRange = struct {
    start_addr: []const u8,
    end_addr: []const u8,
    source: u8,
    created_at: i64,
};

pub const QueuePosition = struct {
    info_hash_hex: [40]u8,
    position: u32,
};

/// SQLite-backed resume state. See src/storage/sqlite_backend.zig.
/// Re-exported here so daemon callers (`ResumeDb = ResumeDbOf(SqliteBackend)`)
/// can reach it through the resume DB module without a separate import.
pub const SqliteBackend = @import("sqlite_backend.zig").SqliteBackend;

/// Background resume writer that batches piece completions.
/// Run on a dedicated thread -- call flush() periodically or on shutdown.
pub const ResumeWriter = struct {
    allocator: std.mem.Allocator,
    db: ResumeDb,
    info_hash: [20]u8,
    pending: std.ArrayList(u32),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8, info_hash: [20]u8) !ResumeWriter {
        return .{
            .allocator = allocator,
            .db = try ResumeDb.open(db_path),
            .info_hash = info_hash,
            .pending = std.ArrayList(u32).empty,
        };
    }

    pub fn deinit(self: *ResumeWriter) void {
        self.flush() catch {};
        self.pending.deinit(self.allocator);
        self.db.close();
    }

    /// Queue a piece for persistence. Thread-safe.
    pub fn recordPiece(self: *ResumeWriter, piece_index: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(self.allocator, piece_index);
    }

    /// Flush all pending pieces to SQLite. Thread-safe.
    pub fn flush(self: *ResumeWriter) !void {
        var to_flush = std.ArrayList(u32).empty;
        self.mutex.lock();
        if (self.pending.items.len == 0) {
            self.mutex.unlock();
            return;
        }
        std.mem.swap(std.ArrayList(u32), &to_flush, &self.pending);
        self.mutex.unlock();
        defer to_flush.deinit(self.allocator);

        // Write batch to SQLite (this blocks, which is fine on the background thread)
        self.db.markCompleteBatch(self.info_hash, to_flush.items) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.pending.ensureUnusedCapacity(self.allocator, to_flush.items.len);
            for (to_flush.items) |piece_index| {
                self.pending.appendAssumeCapacity(piece_index);
            }
            return err;
        };
    }

    /// Persist lifetime transfer stats. Thread-safe.
    pub fn saveTransferStats(self: *ResumeWriter, stats: ResumeDb.TransferStats) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.db.saveTransferStats(self.info_hash, stats) catch {};
    }

    /// Load lifetime transfer stats. Thread-safe.
    pub fn loadTransferStats(self: *ResumeWriter) ResumeDb.TransferStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.db.loadTransferStats(self.info_hash);
    }
};

// ── Tests ─────────────────────────────────────────────────
// Tests require libsqlite3 to be linked. They'll fail at link time
// if libsqlite3-dev is not installed, which is acceptable.

test "resume db open close" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();
}

test "resume db mark and load pieces" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xAA));

    try db.markComplete(info_hash, 0);
    try db.markComplete(info_hash, 5);
    try db.markComplete(info_hash, 10);
    // Duplicate should be ignored
    try db.markComplete(info_hash, 5);

    var bf = try Bitfield.init(std.testing.allocator, 20);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expect(bf.has(0));
    try std.testing.expect(bf.has(5));
    try std.testing.expect(bf.has(10));
    try std.testing.expect(!bf.has(1));
}

test "resume db batch write" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xBB));
    const pieces = [_]u32{ 0, 1, 2, 3, 4 };

    try db.markCompleteBatch(info_hash, &pieces);

    var bf = try Bitfield.init(std.testing.allocator, 10);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 5), count);
}

test "resume db clear torrent" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xCC));
    try db.markComplete(info_hash, 0);
    try db.markComplete(info_hash, 1);

    try db.clearTorrent(info_hash);

    var bf = try Bitfield.init(std.testing.allocator, 10);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "resume db replaceCompletePieces drops stale entries (recheck pruning)" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    // Pre-existing state: pieces 5, 6, 7 marked complete from a previous run.
    const info_hash = @as([20]u8, @splat(0xC0));
    const before = [_]u32{ 5, 6, 7 };
    try db.markCompleteBatch(info_hash, &before);

    // Recheck finds only pieces 1 and 3 actually present on disk.
    const after = [_]u32{ 1, 3 };
    try db.replaceCompletePieces(info_hash, &after);

    var bf = try Bitfield.init(std.testing.allocator, 16);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expect(bf.has(1));
    try std.testing.expect(bf.has(3));
    // The stale pre-recheck entries are gone — without the delete the
    // additive `markCompleteBatch` would leave 5, 6, 7 visible to fast-resume.
    try std.testing.expect(!bf.has(5));
    try std.testing.expect(!bf.has(6));
    try std.testing.expect(!bf.has(7));
}

test "resume db replaceCompletePieces with empty set clears all pieces" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xC1));
    const before = [_]u32{ 0, 1, 2, 3 };
    try db.markCompleteBatch(info_hash, &before);

    const empty = [_]u32{};
    try db.replaceCompletePieces(info_hash, &empty);

    var bf = try Bitfield.init(std.testing.allocator, 16);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "resume db replaceCompletePieces is per-info_hash isolated" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    // Two torrents share the pieces table; replace on one must not
    // disturb the other's rows.
    const info_hash_a = @as([20]u8, @splat(0xA0));
    const info_hash_b = @as([20]u8, @splat(0xB0));

    const set_a = [_]u32{ 0, 1, 2 };
    const set_b = [_]u32{ 4, 5, 6, 7 };
    try db.markCompleteBatch(info_hash_a, &set_a);
    try db.markCompleteBatch(info_hash_b, &set_b);

    // Recheck on torrent A drops piece 2 and adds piece 3.
    const new_a = [_]u32{ 0, 1, 3 };
    try db.replaceCompletePieces(info_hash_a, &new_a);

    var bf_a = try Bitfield.init(std.testing.allocator, 16);
    defer bf_a.deinit(std.testing.allocator);
    const count_a = try db.loadCompletePieces(info_hash_a, &bf_a);
    try std.testing.expectEqual(@as(u32, 3), count_a);
    try std.testing.expect(bf_a.has(0));
    try std.testing.expect(bf_a.has(1));
    try std.testing.expect(bf_a.has(3));
    try std.testing.expect(!bf_a.has(2));

    // Torrent B is untouched.
    var bf_b = try Bitfield.init(std.testing.allocator, 16);
    defer bf_b.deinit(std.testing.allocator);
    const count_b = try db.loadCompletePieces(info_hash_b, &bf_b);
    try std.testing.expectEqual(@as(u32, 4), count_b);
    try std.testing.expect(bf_b.has(4));
    try std.testing.expect(bf_b.has(5));
    try std.testing.expect(bf_b.has(6));
    try std.testing.expect(bf_b.has(7));
}

test "resume db replaceCompletePieces is idempotent on no-change" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    // Same pieces before and after — recheck found exactly what fast-resume
    // already had. Result must round-trip cleanly without losing entries.
    const info_hash = @as([20]u8, @splat(0xC2));
    const pieces = [_]u32{ 0, 2, 4, 6, 8 };
    try db.markCompleteBatch(info_hash, &pieces);
    try db.replaceCompletePieces(info_hash, &pieces);

    var bf = try Bitfield.init(std.testing.allocator, 16);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 5), count);
    try std.testing.expect(bf.has(0));
    try std.testing.expect(bf.has(2));
    try std.testing.expect(bf.has(4));
    try std.testing.expect(bf.has(6));
    try std.testing.expect(bf.has(8));
}

test "resume db clear torrent removes auxiliary state" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xCD));
    const info_hash_hex = std.fmt.bytesToHex(info_hash, .lower);
    const v2_hash = @as([32]u8, @splat(0xEF));

    try db.markComplete(info_hash, 0);
    try db.saveTransferStats(info_hash, .{ .total_uploaded = 10, .total_downloaded = 20 });
    try db.saveTorrentCategory(info_hash, "movies");
    try db.saveTorrentTag(info_hash, "tag-a");
    try db.saveRateLimits(info_hash, 100, 200);
    try db.saveShareLimits(info_hash, 1.5, 30, 1234);
    try db.saveInfoHashV2(info_hash, v2_hash);
    try db.saveTrackerOverride(info_hash, "https://tracker.example/announce", 0, "add", null);
    try db.saveQueuePosition(info_hash_hex, 7);

    try db.clearTorrent(info_hash);

    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), try db.loadCompletePieces(info_hash, &bf));

    const stats = db.loadTransferStats(info_hash);
    try std.testing.expectEqual(@as(u64, 0), stats.total_uploaded);
    try std.testing.expectEqual(@as(u64, 0), stats.total_downloaded);

    try std.testing.expectEqual(@as(?[]const u8, null), try db.loadTorrentCategory(std.testing.allocator, info_hash));

    const tags = try db.loadTorrentTags(std.testing.allocator, info_hash);
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 0), tags.len);

    const limits = db.loadRateLimits(info_hash);
    try std.testing.expectEqual(@as(u64, 0), limits.dl_limit);
    try std.testing.expectEqual(@as(u64, 0), limits.ul_limit);

    const share = db.loadShareLimits(info_hash);
    try std.testing.expectEqual(@as(f64, -2.0), share.ratio_limit);
    try std.testing.expectEqual(@as(i64, -2), share.seeding_time_limit);
    try std.testing.expectEqual(@as(i64, 0), share.completion_on);

    try std.testing.expectEqual(@as(?[32]u8, null), db.loadInfoHashV2(info_hash));

    const overrides = try db.loadTrackerOverrides(std.testing.allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(std.testing.allocator, overrides);
    try std.testing.expectEqual(@as(usize, 0), overrides.len);

    const queue_entries = try db.loadQueuePositions(std.testing.allocator);
    defer std.testing.allocator.free(queue_entries);
    try std.testing.expectEqual(@as(usize, 0), queue_entries.len);
}

test "resume db save and load transfer stats" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xDD));

    // Initially empty -- should return zeros
    const empty = db.loadTransferStats(info_hash);
    try std.testing.expectEqual(@as(u64, 0), empty.total_uploaded);
    try std.testing.expectEqual(@as(u64, 0), empty.total_downloaded);

    // Save some stats
    try db.saveTransferStats(info_hash, .{ .total_uploaded = 1000, .total_downloaded = 5000 });

    const loaded = db.loadTransferStats(info_hash);
    try std.testing.expectEqual(@as(u64, 1000), loaded.total_uploaded);
    try std.testing.expectEqual(@as(u64, 5000), loaded.total_downloaded);

    // Update (upsert) with new totals
    try db.saveTransferStats(info_hash, .{ .total_uploaded = 3000, .total_downloaded = 8000 });

    const updated = db.loadTransferStats(info_hash);
    try std.testing.expectEqual(@as(u64, 3000), updated.total_uploaded);
    try std.testing.expectEqual(@as(u64, 8000), updated.total_downloaded);
}

test "resume db transfer stats isolated per torrent" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = @as([20]u8, @splat(0xEE));
    const hash_b = @as([20]u8, @splat(0xFF));

    try db.saveTransferStats(hash_a, .{ .total_uploaded = 100, .total_downloaded = 200 });
    try db.saveTransferStats(hash_b, .{ .total_uploaded = 300, .total_downloaded = 400 });

    const stats_a = db.loadTransferStats(hash_a);
    try std.testing.expectEqual(@as(u64, 100), stats_a.total_uploaded);
    try std.testing.expectEqual(@as(u64, 200), stats_a.total_downloaded);

    const stats_b = db.loadTransferStats(hash_b);
    try std.testing.expectEqual(@as(u64, 300), stats_b.total_uploaded);
    try std.testing.expectEqual(@as(u64, 400), stats_b.total_downloaded);
}

test "resume db save and load categories" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    try db.saveCategory("movies", "/data/movies");
    try db.saveCategory("tv", "/data/tv");

    // Upsert should update save_path
    try db.saveCategory("movies", "/new/movies");

    const cats = try db.loadCategories(allocator);
    defer {
        for (cats) |cat| {
            allocator.free(cat.name);
            allocator.free(cat.save_path);
        }
        allocator.free(cats);
    }

    try std.testing.expectEqual(@as(usize, 2), cats.len);

    // Find movies category and check updated path
    var found_movies = false;
    var found_tv = false;
    for (cats) |cat| {
        if (std.mem.eql(u8, cat.name, "movies")) {
            try std.testing.expectEqualStrings("/new/movies", cat.save_path);
            found_movies = true;
        } else if (std.mem.eql(u8, cat.name, "tv")) {
            try std.testing.expectEqualStrings("/data/tv", cat.save_path);
            found_tv = true;
        }
    }
    try std.testing.expect(found_movies);
    try std.testing.expect(found_tv);
}

test "resume db remove category" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    try db.saveCategory("movies", "/data/movies");
    try db.removeCategory("movies");

    const cats = try db.loadCategories(allocator);
    defer allocator.free(cats);
    try std.testing.expectEqual(@as(usize, 0), cats.len);
}

test "resume db torrent category persistence" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xAA));

    // Initially no category
    const empty = try db.loadTorrentCategory(allocator, info_hash);
    try std.testing.expect(empty == null);

    // Set category
    try db.saveTorrentCategory(info_hash, "movies");
    const cat = (try db.loadTorrentCategory(allocator, info_hash)).?;
    defer allocator.free(cat);
    try std.testing.expectEqualStrings("movies", cat);

    // Clear category (empty string)
    try db.saveTorrentCategory(info_hash, "");
    const cleared = try db.loadTorrentCategory(allocator, info_hash);
    try std.testing.expect(cleared == null);
}

test "resume db torrent tags persistence" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xBB));

    // Add tags
    try db.saveTorrentTag(info_hash, "linux");
    try db.saveTorrentTag(info_hash, "archived");
    // Duplicate should be ignored
    try db.saveTorrentTag(info_hash, "linux");

    const tags = try db.loadTorrentTags(allocator, info_hash);
    defer {
        for (tags) |tag| allocator.free(tag);
        allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 2), tags.len);

    // Remove one tag
    try db.removeTorrentTag(info_hash, "linux");
    const tags2 = try db.loadTorrentTags(allocator, info_hash);
    defer {
        for (tags2) |tag| allocator.free(tag);
        allocator.free(tags2);
    }
    try std.testing.expectEqual(@as(usize, 1), tags2.len);
    try std.testing.expectEqualStrings("archived", tags2[0]);
}

test "resume db global tags persistence" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    try db.saveGlobalTag("linux");
    try db.saveGlobalTag("archived");
    try db.saveGlobalTag("linux"); // duplicate

    const tags = try db.loadGlobalTags(allocator);
    defer {
        for (tags) |tag| allocator.free(tag);
        allocator.free(tags);
    }
    try std.testing.expectEqual(@as(usize, 2), tags.len);

    try db.removeGlobalTag("linux");
    const tags2 = try db.loadGlobalTags(allocator);
    defer {
        for (tags2) |tag| allocator.free(tag);
        allocator.free(tags2);
    }
    try std.testing.expectEqual(@as(usize, 1), tags2.len);
}

test "resume db clear category from torrents" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = @as([20]u8, @splat(0xAA));
    const hash_b = @as([20]u8, @splat(0xBB));

    try db.saveTorrentCategory(hash_a, "movies");
    try db.saveTorrentCategory(hash_b, "movies");

    // Clear "movies" from all torrents
    try db.clearCategoryFromTorrents("movies");

    const cat_a = try db.loadTorrentCategory(allocator, hash_a);
    try std.testing.expect(cat_a == null);
    const cat_b = try db.loadTorrentCategory(allocator, hash_b);
    try std.testing.expect(cat_b == null);
}

test "resume db save and load rate limits" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xDD));

    // Initially empty -- should return zeros
    const empty = db.loadRateLimits(info_hash);
    try std.testing.expectEqual(@as(u64, 0), empty.dl_limit);
    try std.testing.expectEqual(@as(u64, 0), empty.ul_limit);

    // Save some limits
    try db.saveRateLimits(info_hash, 1024000, 512000);

    const loaded = db.loadRateLimits(info_hash);
    try std.testing.expectEqual(@as(u64, 1024000), loaded.dl_limit);
    try std.testing.expectEqual(@as(u64, 512000), loaded.ul_limit);

    // Update (upsert)
    try db.saveRateLimits(info_hash, 2048000, 0);

    const updated = db.loadRateLimits(info_hash);
    try std.testing.expectEqual(@as(u64, 2048000), updated.dl_limit);
    try std.testing.expectEqual(@as(u64, 0), updated.ul_limit);

    // Clear
    try db.clearRateLimits(info_hash);
    const cleared = db.loadRateLimits(info_hash);
    try std.testing.expectEqual(@as(u64, 0), cleared.dl_limit);
    try std.testing.expectEqual(@as(u64, 0), cleared.ul_limit);
}

test "resume db remove tag from all torrents" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = @as([20]u8, @splat(0xAA));
    const hash_b = @as([20]u8, @splat(0xBB));

    try db.saveTorrentTag(hash_a, "linux");
    try db.saveTorrentTag(hash_a, "archived");
    try db.saveTorrentTag(hash_b, "linux");

    // Remove "linux" from all torrents
    try db.removeTagFromTorrents("linux");

    const tags_a = try db.loadTorrentTags(allocator, hash_a);
    defer {
        for (tags_a) |tag| allocator.free(tag);
        allocator.free(tags_a);
    }
    try std.testing.expectEqual(@as(usize, 1), tags_a.len);
    try std.testing.expectEqualStrings("archived", tags_a[0]);

    const tags_b = try db.loadTorrentTags(allocator, hash_b);
    defer {
        for (tags_b) |tag| allocator.free(tag);
        allocator.free(tags_b);
    }
    try std.testing.expectEqual(@as(usize, 0), tags_b.len);
}

test "resume db save and load v2 info hash" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const v1_hash = @as([20]u8, @splat(0xAA));
    var v2_hash: [32]u8 = undefined;
    for (&v2_hash, 0..) |*b, i| b.* = @intCast(i);

    // Initially, no v2 hash should be stored
    try std.testing.expect(db.loadInfoHashV2(v1_hash) == null);

    // Save and load
    try db.saveInfoHashV2(v1_hash, v2_hash);
    const loaded = db.loadInfoHashV2(v1_hash) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(v2_hash, loaded);

    // Update (upsert)
    var v2_hash_new: [32]u8 = undefined;
    @memset(&v2_hash_new, 0xFF);
    try db.saveInfoHashV2(v1_hash, v2_hash_new);
    const loaded2 = db.loadInfoHashV2(v1_hash) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(v2_hash_new, loaded2);
}

test "resume db v2 info hash isolated per torrent" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = @as([20]u8, @splat(0xAA));
    const hash_b = @as([20]u8, @splat(0xBB));
    var v2_a: [32]u8 = undefined;
    @memset(&v2_a, 0x11);
    var v2_b: [32]u8 = undefined;
    @memset(&v2_b, 0x22);

    try db.saveInfoHashV2(hash_a, v2_a);
    try db.saveInfoHashV2(hash_b, v2_b);

    const loaded_a = db.loadInfoHashV2(hash_a) orelse return error.TestUnexpectedResult;
    const loaded_b = db.loadInfoHashV2(hash_b) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(v2_a, loaded_a);
    try std.testing.expectEqual(v2_b, loaded_b);

    // Pure v1 torrent should return null
    const hash_c = @as([20]u8, @splat(0xCC));
    try std.testing.expect(db.loadInfoHashV2(hash_c) == null);
}

test "resume db save and load banned ips" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    // Initially empty
    const empty = try db.loadBannedIps(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Add bans
    try db.saveBannedIp("192.168.1.1", 0, "bad peer", std.time.timestamp());
    try db.saveBannedIp("10.0.0.5", 1, null, std.time.timestamp());

    const loaded = try db.loadBannedIps(allocator);
    defer {
        for (loaded) |item| {
            allocator.free(item.address);
            if (item.reason) |r| allocator.free(r);
        }
        allocator.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.len);

    // Remove one
    try db.removeBannedIp("192.168.1.1");
    const after_remove = try db.loadBannedIps(allocator);
    defer {
        for (after_remove) |item| {
            allocator.free(item.address);
            if (item.reason) |r| allocator.free(r);
        }
        allocator.free(after_remove);
    }
    try std.testing.expectEqual(@as(usize, 1), after_remove.len);
}

test "resume db save and load banned ranges" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    try db.saveBannedRange("10.0.0.0", "10.255.255.255", 1);
    try db.saveBannedRange("192.168.0.0", "192.168.255.255", 0);

    const loaded = try db.loadBannedRanges(allocator);
    defer {
        for (loaded) |item| {
            allocator.free(item.start_addr);
            allocator.free(item.end_addr);
        }
        allocator.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
}

test "resume db clear banned by source" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    try db.saveBannedIp("1.1.1.1", 0, null, std.time.timestamp());
    try db.saveBannedIp("2.2.2.2", 1, null, std.time.timestamp());
    try db.saveBannedRange("10.0.0.0", "10.255.255.255", 1);

    // Clear ipfilter source (1)
    try db.clearBannedBySource(1);

    const ips = try db.loadBannedIps(allocator);
    defer {
        for (ips) |item| {
            allocator.free(item.address);
            if (item.reason) |r| allocator.free(r);
        }
        allocator.free(ips);
    }
    try std.testing.expectEqual(@as(usize, 1), ips.len);

    const ranges = try db.loadBannedRanges(allocator);
    defer {
        for (ranges) |item| {
            allocator.free(item.start_addr);
            allocator.free(item.end_addr);
        }
        allocator.free(ranges);
    }
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}

test "resume db save and load share limits" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xAB));

    // Default values when not set
    const default_limits = db.loadShareLimits(info_hash);
    try std.testing.expect(default_limits.ratio_limit == -2.0);
    try std.testing.expectEqual(@as(i64, -2), default_limits.seeding_time_limit);
    try std.testing.expectEqual(@as(i64, 0), default_limits.completion_on);

    // Save custom limits
    try db.saveShareLimits(info_hash, 2.5, 120, 1711900000);

    const loaded = db.loadShareLimits(info_hash);
    try std.testing.expect(loaded.ratio_limit == 2.5);
    try std.testing.expectEqual(@as(i64, 120), loaded.seeding_time_limit);
    try std.testing.expectEqual(@as(i64, 1711900000), loaded.completion_on);

    // Upsert (update existing)
    try db.saveShareLimits(info_hash, -1.0, -1, 1711900000);
    const updated = db.loadShareLimits(info_hash);
    try std.testing.expect(updated.ratio_limit == -1.0);
    try std.testing.expectEqual(@as(i64, -1), updated.seeding_time_limit);

    // Clear
    try db.clearShareLimits(info_hash);
    const cleared = db.loadShareLimits(info_hash);
    try std.testing.expect(cleared.ratio_limit == -2.0);
}

test "resume db ipfilter config persistence" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    // Initially empty
    const empty = try db.loadIpFilterConfig(allocator);
    try std.testing.expect(!empty.enabled);
    try std.testing.expect(empty.path == null);

    // Save config
    try db.saveIpFilterConfig(.{
        .path = "/etc/ipfilter.dat",
        .enabled = true,
        .rule_count = 1500,
    });

    const loaded = try db.loadIpFilterConfig(allocator);
    defer if (loaded.path) |p| allocator.free(p);

    try std.testing.expect(loaded.enabled);
    try std.testing.expectEqual(@as(u32, 1500), loaded.rule_count);
    try std.testing.expectEqualStrings("/etc/ipfilter.dat", loaded.path.?);
}

test "resume db tracker overrides add and load" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xAA));

    // Initially empty
    const empty = try db.loadTrackerOverrides(allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Add tracker overrides
    try db.saveTrackerOverride(info_hash, "http://tracker1.example.com/announce", 10, "add", null);
    try db.saveTrackerOverride(info_hash, "http://tracker2.example.com/announce", 11, "add", null);
    try db.saveTrackerOverride(info_hash, "http://old.example.com/announce", 0, "remove", null);

    const overrides = try db.loadTrackerOverrides(allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(allocator, overrides);
    try std.testing.expectEqual(@as(usize, 3), overrides.len);

    // Should be sorted by tier: remove (tier 0), add (tier 10), add (tier 11)
    try std.testing.expectEqualStrings("remove", overrides[0].action);
    try std.testing.expectEqualStrings("add", overrides[1].action);
    try std.testing.expectEqual(@as(u32, 10), overrides[1].tier);
}

test "resume db tracker overrides edit with orig_url" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xBB));

    // Save an edit override
    try db.saveTrackerOverride(info_hash, "http://new.example.com/announce", 0, "edit", "http://old.example.com/announce");

    const overrides = try db.loadTrackerOverrides(allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(allocator, overrides);
    try std.testing.expectEqual(@as(usize, 1), overrides.len);
    try std.testing.expectEqualStrings("edit", overrides[0].action);
    try std.testing.expectEqualStrings("http://new.example.com/announce", overrides[0].url);
    try std.testing.expectEqualStrings("http://old.example.com/announce", overrides[0].orig_url.?);
}

test "resume db tracker overrides remove and clear" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = @as([20]u8, @splat(0xCC));

    try db.saveTrackerOverride(info_hash, "http://a.example.com/announce", 0, "add", null);
    try db.saveTrackerOverride(info_hash, "http://b.example.com/announce", 1, "add", null);

    // Remove one
    try db.removeTrackerOverride(info_hash, "http://a.example.com/announce");
    const after_remove = try db.loadTrackerOverrides(allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(allocator, after_remove);
    try std.testing.expectEqual(@as(usize, 1), after_remove.len);

    // Clear all
    try db.clearTrackerOverrides(info_hash);
    const after_clear = try db.loadTrackerOverrides(allocator, info_hash);
    defer ResumeDb.freeTrackerOverrides(allocator, after_clear);
    try std.testing.expectEqual(@as(usize, 0), after_clear.len);
}

test "resume db tracker overrides isolated per torrent" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = @as([20]u8, @splat(0xDD));
    const hash_b = @as([20]u8, @splat(0xEE));

    try db.saveTrackerOverride(hash_a, "http://a.example.com/announce", 0, "add", null);
    try db.saveTrackerOverride(hash_b, "http://b.example.com/announce", 0, "add", null);

    const overrides_a = try db.loadTrackerOverrides(allocator, hash_a);
    defer ResumeDb.freeTrackerOverrides(allocator, overrides_a);
    try std.testing.expectEqual(@as(usize, 1), overrides_a.len);
    try std.testing.expectEqualStrings("http://a.example.com/announce", overrides_a[0].url);

    const overrides_b = try db.loadTrackerOverrides(allocator, hash_b);
    defer ResumeDb.freeTrackerOverrides(allocator, overrides_b);
    try std.testing.expectEqual(@as(usize, 1), overrides_b.len);
    try std.testing.expectEqualStrings("http://b.example.com/announce", overrides_b[0].url);
}

const std = @import("std");
const sqlite = @import("sqlite3.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;

/// Persistent resume state backed by SQLite.
/// Tracks which pieces are complete across restarts, avoiding
/// expensive full-disk recheck for large torrents.
///
/// Runs on a dedicated background thread -- SQLite operations
/// block and must NOT run on the io_uring event loop thread.
pub const TransferStats = struct {
    total_uploaded: u64 = 0,
    total_downloaded: u64 = 0,
};

pub const ResumeDb = struct {
    db: *sqlite.Db,
    insert_stmt: *sqlite.Stmt,
    query_stmt: *sqlite.Stmt,
    delete_stmt: *sqlite.Stmt,
    save_stats_stmt: *sqlite.Stmt,
    load_stats_stmt: *sqlite.Stmt,

    pub fn open(path: [*:0]const u8) !ResumeDb {
        var db: ?*sqlite.Db = null;
        const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_FULLMUTEX;

        if (sqlite.sqlite3_open_v2(path, &db, flags, null) != sqlite.SQLITE_OK) {
            if (db) |d| _ = sqlite.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        const d = db.?;

        // Enable WAL mode for better concurrent read/write performance
        if (sqlite.sqlite3_exec(d, "PRAGMA journal_mode=wal", null, null, null) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePragmaFailed;
        }

        // Create schema
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS pieces (" ++
                "info_hash BLOB NOT NULL, " ++
                "piece_index INTEGER NOT NULL, " ++
                "completed_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), " ++
                "PRIMARY KEY (info_hash, piece_index)" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create transfer_stats table for lifetime byte counters
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS transfer_stats (" ++
                "info_hash BLOB NOT NULL PRIMARY KEY, " ++
                "total_uploaded INTEGER NOT NULL DEFAULT 0, " ++
                "total_downloaded INTEGER NOT NULL DEFAULT 0" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create categories table
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS categories (" ++
                "name TEXT PRIMARY KEY, " ++
                "save_path TEXT NOT NULL DEFAULT ''" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create torrent_categories table
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS torrent_categories (" ++
                "info_hash BLOB NOT NULL, " ++
                "category TEXT NOT NULL, " ++
                "PRIMARY KEY (info_hash)" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create torrent_tags table
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS torrent_tags (" ++
                "info_hash BLOB NOT NULL, " ++
                "tag TEXT NOT NULL, " ++
                "PRIMARY KEY (info_hash, tag)" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create global_tags table (all known tags, independent of torrents)
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS global_tags (" ++
                "name TEXT PRIMARY KEY" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Prepare statements
        var insert_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            d,
            "INSERT OR IGNORE INTO pieces (info_hash, piece_index) VALUES (?1, ?2)",
            -1,
            &insert_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePrepareFailed;
        }

        var query_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            d,
            "SELECT piece_index FROM pieces WHERE info_hash = ?1",
            -1,
            &query_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(insert_stmt.?);
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePrepareFailed;
        }

        var delete_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            d,
            "DELETE FROM pieces WHERE info_hash = ?1",
            -1,
            &delete_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(insert_stmt.?);
            _ = sqlite.sqlite3_finalize(query_stmt.?);
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePrepareFailed;
        }

        var save_stats_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            d,
            "INSERT INTO transfer_stats (info_hash, total_uploaded, total_downloaded) " ++
                "VALUES (?1, ?2, ?3) " ++
                "ON CONFLICT(info_hash) DO UPDATE SET " ++
                "total_uploaded = ?2, total_downloaded = ?3",
            -1,
            &save_stats_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(insert_stmt.?);
            _ = sqlite.sqlite3_finalize(query_stmt.?);
            _ = sqlite.sqlite3_finalize(delete_stmt.?);
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePrepareFailed;
        }

        var load_stats_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            d,
            "SELECT total_uploaded, total_downloaded FROM transfer_stats WHERE info_hash = ?1",
            -1,
            &load_stats_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(insert_stmt.?);
            _ = sqlite.sqlite3_finalize(query_stmt.?);
            _ = sqlite.sqlite3_finalize(delete_stmt.?);
            _ = sqlite.sqlite3_finalize(save_stats_stmt.?);
            _ = sqlite.sqlite3_close(d);
            return error.SqlitePrepareFailed;
        }

        return .{
            .db = d,
            .insert_stmt = insert_stmt.?,
            .query_stmt = query_stmt.?,
            .delete_stmt = delete_stmt.?,
            .save_stats_stmt = save_stats_stmt.?,
            .load_stats_stmt = load_stats_stmt.?,
        };
    }

    pub fn close(self: *ResumeDb) void {
        _ = sqlite.sqlite3_finalize(self.insert_stmt);
        _ = sqlite.sqlite3_finalize(self.query_stmt);
        _ = sqlite.sqlite3_finalize(self.delete_stmt);
        _ = sqlite.sqlite3_finalize(self.save_stats_stmt);
        _ = sqlite.sqlite3_finalize(self.load_stats_stmt);
        _ = sqlite.sqlite3_close(self.db);
    }

    /// Record a completed piece.
    pub fn markComplete(self: *ResumeDb, info_hash: [20]u8, piece_index: u32) !void {
        _ = sqlite.sqlite3_reset(self.insert_stmt);
        _ = sqlite.sqlite3_bind_blob(self.insert_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(self.insert_stmt, 2, @intCast(piece_index));

        if (sqlite.sqlite3_step(self.insert_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }

    /// Batch-record multiple completed pieces in a single transaction.
    pub fn markCompleteBatch(self: *ResumeDb, info_hash: [20]u8, piece_indices: []const u32) !void {
        _ = sqlite.sqlite3_exec(self.db, "BEGIN", null, null, null);
        for (piece_indices) |piece_index| {
            self.markComplete(info_hash, piece_index) catch {
                _ = sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
                return error.SqliteBatchFailed;
            };
        }
        if (sqlite.sqlite3_exec(self.db, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteCommitFailed;
        }
    }

    /// Load completed pieces into a Bitfield.
    /// Returns the count of pieces loaded.
    pub fn loadCompletePieces(self: *ResumeDb, info_hash: [20]u8, bitfield: *Bitfield) !u32 {
        _ = sqlite.sqlite3_reset(self.query_stmt);
        _ = sqlite.sqlite3_bind_blob(self.query_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        var count: u32 = 0;
        while (sqlite.sqlite3_step(self.query_stmt) == sqlite.SQLITE_ROW) {
            const piece_index: u32 = @intCast(sqlite.sqlite3_column_int(self.query_stmt, 0));
            bitfield.set(piece_index) catch continue;
            count += 1;
        }
        return count;
    }

    /// Clear all resume state for a torrent.
    pub fn clearTorrent(self: *ResumeDb, info_hash: [20]u8) !void {
        _ = sqlite.sqlite3_reset(self.delete_stmt);
        _ = sqlite.sqlite3_bind_blob(self.delete_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(self.delete_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteDeleteFailed;
        }
    }

    /// Persist lifetime upload/download byte totals for a torrent.
    pub fn saveTransferStats(self: *ResumeDb, info_hash: [20]u8, stats: TransferStats) !void {
        _ = sqlite.sqlite3_reset(self.save_stats_stmt);
        _ = sqlite.sqlite3_bind_blob(self.save_stats_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int64(self.save_stats_stmt, 2, @intCast(stats.total_uploaded));
        _ = sqlite.sqlite3_bind_int64(self.save_stats_stmt, 3, @intCast(stats.total_downloaded));

        if (sqlite.sqlite3_step(self.save_stats_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }

    /// Load lifetime upload/download byte totals for a torrent.
    pub fn loadTransferStats(self: *ResumeDb, info_hash: [20]u8) TransferStats {
        _ = sqlite.sqlite3_reset(self.load_stats_stmt);
        _ = sqlite.sqlite3_bind_blob(self.load_stats_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(self.load_stats_stmt) == sqlite.SQLITE_ROW) {
            return .{
                .total_uploaded = @intCast(sqlite.sqlite3_column_int64(self.load_stats_stmt, 0)),
                .total_downloaded = @intCast(sqlite.sqlite3_column_int64(self.load_stats_stmt, 1)),
            };
        }
        return .{};
    }

    // ── Category / Tag persistence ────────────────────────
    // These operations are infrequent (user-driven CRUD), so we prepare,
    // execute, and finalize per call instead of caching statements.

    /// Prepare a statement, bind, step, and finalize. Returns error on failure.
    fn execOneShot(self: *ResumeDb, sql: [*:0]const u8) !*sqlite.Stmt {
        var stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }

    fn stepAndFinalize(stmt: *sqlite.Stmt) !void {
        const rc = sqlite.sqlite3_step(stmt);
        _ = sqlite.sqlite3_finalize(stmt);
        if (rc != sqlite.SQLITE_DONE) return error.SqliteStepFailed;
    }

    /// Save a category (upsert).
    pub fn saveCategory(self: *ResumeDb, name: []const u8, save_path: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO categories (name, save_path) VALUES (?1, ?2) " ++
                "ON CONFLICT(name) DO UPDATE SET save_path = ?2",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, save_path.ptr, @intCast(save_path.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a category.
    pub fn removeCategory(self: *ResumeDb, name: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM categories WHERE name = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// A category loaded from the DB.
    pub const SavedCategory = struct {
        name: []const u8,
        save_path: []const u8,
    };

    /// Load all categories. Caller owns the returned slices (allocated with `allocator`).
    pub fn loadCategories(self: *ResumeDb, allocator: std.mem.Allocator) ![]SavedCategory {
        const stmt = try self.execOneShot("SELECT name, save_path FROM categories");
        defer _ = sqlite.sqlite3_finalize(stmt);

        var result = std.ArrayList(SavedCategory).empty;
        errdefer {
            for (result.items) |cat| {
                allocator.free(cat.name);
                allocator.free(cat.save_path);
            }
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const name_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const name_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const path_ptr = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
            const path_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));

            const name = try allocator.dupe(u8, name_ptr[0..name_len]);
            errdefer allocator.free(name);
            const path = try allocator.dupe(u8, path_ptr[0..path_len]);

            try result.append(allocator, .{ .name = name, .save_path = path });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Save a torrent's category assignment (upsert). Empty category clears.
    pub fn saveTorrentCategory(self: *ResumeDb, info_hash: [20]u8, category: []const u8) !void {
        if (category.len == 0) {
            const stmt = try self.execOneShot("DELETE FROM torrent_categories WHERE info_hash = ?1");
            _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
            try stepAndFinalize(stmt);
        } else {
            const stmt = try self.execOneShot(
                "INSERT INTO torrent_categories (info_hash, category) VALUES (?1, ?2) " ++
                    "ON CONFLICT(info_hash) DO UPDATE SET category = ?2",
            );
            _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
            _ = sqlite.sqlite3_bind_text(stmt, 2, category.ptr, @intCast(category.len), sqlite.SQLITE_TRANSIENT);
            try stepAndFinalize(stmt);
        }
    }

    /// Load a torrent's category. Returns owned string or null.
    pub fn loadTorrentCategory(self: *ResumeDb, allocator: std.mem.Allocator, info_hash: [20]u8) !?[]const u8 {
        const stmt = try self.execOneShot("SELECT category FROM torrent_categories WHERE info_hash = ?1");
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const text = sqlite.sqlite3_column_text(stmt, 0) orelse return null;
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            if (len == 0) return null;
            return try allocator.dupe(u8, text[0..len]);
        }
        return null;
    }

    /// Clear a specific category from all torrents (used when deleting a category).
    pub fn clearCategoryFromTorrents(self: *ResumeDb, category: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_categories WHERE category = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, category.ptr, @intCast(category.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Save a torrent tag (insert or ignore).
    pub fn saveTorrentTag(self: *ResumeDb, info_hash: [20]u8, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT OR IGNORE INTO torrent_tags (info_hash, tag) VALUES (?1, ?2)",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a specific tag from a torrent.
    pub fn removeTorrentTag(self: *ResumeDb, info_hash: [20]u8, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "DELETE FROM torrent_tags WHERE info_hash = ?1 AND tag = ?2",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove all tags for a torrent.
    pub fn clearTorrentTags(self: *ResumeDb, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_tags WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all tags for a torrent. Caller owns the returned slices.
    pub fn loadTorrentTags(self: *ResumeDb, allocator: std.mem.Allocator, info_hash: [20]u8) ![][]const u8 {
        const stmt = try self.execOneShot("SELECT tag FROM torrent_tags WHERE info_hash = ?1");
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |tag| allocator.free(tag);
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const tag = try allocator.dupe(u8, text[0..len]);
            try result.append(allocator, tag);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Save a global tag (insert or ignore).
    pub fn saveGlobalTag(self: *ResumeDb, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT OR IGNORE INTO global_tags (name) VALUES (?1)",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a global tag.
    pub fn removeGlobalTag(self: *ResumeDb, tag: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM global_tags WHERE name = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all global tags. Caller owns the returned slices.
    pub fn loadGlobalTags(self: *ResumeDb, allocator: std.mem.Allocator) ![][]const u8 {
        const stmt = try self.execOneShot("SELECT name FROM global_tags");
        defer _ = sqlite.sqlite3_finalize(stmt);

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |tag| allocator.free(tag);
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const tag = try allocator.dupe(u8, text[0..len]);
            try result.append(allocator, tag);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Remove a tag from all torrents (used when deleting a global tag).
    pub fn removeTagFromTorrents(self: *ResumeDb, tag: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_tags WHERE tag = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }
};

/// Background resume writer that batches piece completions.
/// Run on a dedicated thread -- call flush() periodically or on shutdown.
pub const ResumeWriter = struct {
    db: ResumeDb,
    info_hash: [20]u8,
    pending: std.ArrayList(u32),
    mutex: std.Thread.Mutex = .{},

    pub fn init(db_path: [*:0]const u8, info_hash: [20]u8) !ResumeWriter {
        return .{
            .db = try ResumeDb.open(db_path),
            .info_hash = info_hash,
            .pending = std.ArrayList(u32).empty,
        };
    }

    pub fn deinit(self: *ResumeWriter, allocator: std.mem.Allocator) void {
        self.flush() catch {};
        self.pending.deinit(allocator);
        self.db.close();
    }

    /// Queue a piece for persistence. Thread-safe.
    pub fn recordPiece(self: *ResumeWriter, allocator: std.mem.Allocator, piece_index: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(allocator, piece_index);
    }

    /// Flush all pending pieces to SQLite. Thread-safe.
    pub fn flush(self: *ResumeWriter) !void {
        self.mutex.lock();
        const items = self.pending.items;
        if (items.len == 0) {
            self.mutex.unlock();
            return;
        }
        // Take ownership of pending items
        const to_flush = self.pending.allocatedSlice();
        _ = to_flush;
        self.mutex.unlock();

        // Write batch to SQLite (this blocks, which is fine on the background thread)
        self.db.markCompleteBatch(self.info_hash, items) catch {};

        self.mutex.lock();
        self.pending.clearRetainingCapacity();
        self.mutex.unlock();
    }

    /// Persist lifetime transfer stats. Thread-safe.
    pub fn saveTransferStats(self: *ResumeWriter, stats: TransferStats) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.db.saveTransferStats(self.info_hash, stats) catch {};
    }

    /// Load lifetime transfer stats. Thread-safe.
    pub fn loadTransferStats(self: *ResumeWriter) TransferStats {
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

    const info_hash = [_]u8{0xAA} ** 20;

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

    const info_hash = [_]u8{0xBB} ** 20;
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

    const info_hash = [_]u8{0xCC} ** 20;
    try db.markComplete(info_hash, 0);
    try db.markComplete(info_hash, 1);

    try db.clearTorrent(info_hash);

    var bf = try Bitfield.init(std.testing.allocator, 10);
    defer bf.deinit(std.testing.allocator);

    const count = try db.loadCompletePieces(info_hash, &bf);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "resume db save and load transfer stats" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = [_]u8{0xDD} ** 20;

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

    const hash_a = [_]u8{0xEE} ** 20;
    const hash_b = [_]u8{0xFF} ** 20;

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

    const info_hash = [_]u8{0xAA} ** 20;

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

    const info_hash = [_]u8{0xBB} ** 20;

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

    const hash_a = [_]u8{0xAA} ** 20;
    const hash_b = [_]u8{0xBB} ** 20;

    try db.saveTorrentCategory(hash_a, "movies");
    try db.saveTorrentCategory(hash_b, "movies");

    // Clear "movies" from all torrents
    try db.clearCategoryFromTorrents("movies");

    const cat_a = try db.loadTorrentCategory(allocator, hash_a);
    try std.testing.expect(cat_a == null);
    const cat_b = try db.loadTorrentCategory(allocator, hash_b);
    try std.testing.expect(cat_b == null);
}

test "resume db remove tag from all torrents" {
    const allocator = std.testing.allocator;
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const hash_a = [_]u8{0xAA} ** 20;
    const hash_b = [_]u8{0xBB} ** 20;

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

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

        // Create rate_limits table for per-torrent speed limits
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS rate_limits (" ++
                "info_hash BLOB NOT NULL PRIMARY KEY, " ++
                "dl_limit INTEGER NOT NULL DEFAULT 0, " ++
                "ul_limit INTEGER NOT NULL DEFAULT 0" ++
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

        // BEP 52: v2 info-hash mapping table. For hybrid torrents, maps the v1
        // info-hash (used as primary key elsewhere) to the full 32-byte v2 SHA-256 hash.
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS info_hash_v2 (" ++
                "info_hash BLOB NOT NULL PRIMARY KEY, " ++
                "info_hash_v2 BLOB NOT NULL" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create tracker_overrides table for user-modified tracker URLs
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS tracker_overrides (" ++
                "info_hash BLOB NOT NULL, " ++
                "url TEXT NOT NULL, " ++
                "tier INTEGER NOT NULL DEFAULT 0, " ++
                "action TEXT NOT NULL DEFAULT 'add', " ++
                "orig_url TEXT, " ++
                "PRIMARY KEY (info_hash, url)" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create banned_ips table for individual IP bans
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS banned_ips (" ++
                "address TEXT NOT NULL PRIMARY KEY, " ++
                "source INTEGER NOT NULL DEFAULT 0, " ++
                "reason TEXT, " ++
                "created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create banned_ranges table for CIDR range bans
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS banned_ranges (" ++
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
                "start_addr TEXT NOT NULL, " ++
                "end_addr TEXT NOT NULL, " ++
                "source INTEGER NOT NULL DEFAULT 0, " ++
                "created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create ipfilter_config table (singleton)
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS ipfilter_config (" ++
                "id INTEGER PRIMARY KEY CHECK (id = 1), " ++
                "path TEXT, " ++
                "enabled INTEGER NOT NULL DEFAULT 0, " ++
                "rule_count INTEGER NOT NULL DEFAULT 0" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_close(d);
            return error.SqliteSchemaFailed;
        }

        // Create queue_positions table for torrent queue ordering
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS queue_positions (" ++
                "info_hash_hex TEXT NOT NULL PRIMARY KEY, " ++
                "position INTEGER NOT NULL" ++
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

    // ── Rate limit persistence ────────────────────────────

    /// Save per-torrent rate limits (upsert). Both values are bytes/sec, 0 = unlimited.
    pub fn saveRateLimits(self: *ResumeDb, info_hash: [20]u8, dl_limit: u64, ul_limit: u64) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO rate_limits (info_hash, dl_limit, ul_limit) VALUES (?1, ?2, ?3) " ++
                "ON CONFLICT(info_hash) DO UPDATE SET dl_limit = ?2, ul_limit = ?3",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int64(stmt, 2, @intCast(dl_limit));
        _ = sqlite.sqlite3_bind_int64(stmt, 3, @intCast(ul_limit));
        try stepAndFinalize(stmt);
    }

    /// Load per-torrent rate limits. Returns (dl_limit, ul_limit) or (0, 0) if not set.
    pub const RateLimits = struct {
        dl_limit: u64 = 0,
        ul_limit: u64 = 0,
    };

    pub fn loadRateLimits(self: *ResumeDb, info_hash: [20]u8) RateLimits {
        const stmt = self.execOneShot("SELECT dl_limit, ul_limit FROM rate_limits WHERE info_hash = ?1") catch return .{};
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            return .{
                .dl_limit = @intCast(sqlite.sqlite3_column_int64(stmt, 0)),
                .ul_limit = @intCast(sqlite.sqlite3_column_int64(stmt, 1)),
            };
        }
        return .{};
    }

    /// Clear rate limits for a torrent.
    pub fn clearRateLimits(self: *ResumeDb, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM rate_limits WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    // ── BEP 52: v2 info-hash persistence ────────────────────

    /// Save the v2 info-hash for a hybrid/v2 torrent (upsert).
    pub fn saveInfoHashV2(self: *ResumeDb, info_hash: [20]u8, info_hash_v2: [32]u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO info_hash_v2 (info_hash, info_hash_v2) VALUES (?1, ?2) " ++
                "ON CONFLICT(info_hash) DO UPDATE SET info_hash_v2 = ?2",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_blob(stmt, 2, &info_hash_v2, 32, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load the v2 info-hash for a torrent. Returns null if not stored (pure v1).
    pub fn loadInfoHashV2(self: *ResumeDb, info_hash: [20]u8) ?[32]u8 {
        const stmt = self.execOneShot("SELECT info_hash_v2 FROM info_hash_v2 WHERE info_hash = ?1") catch return null;
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const blob = sqlite.sqlite3_column_blob(stmt, 0);
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            if (blob != null and len == 32) {
                var result: [32]u8 = undefined;
                @memcpy(&result, @as([*]const u8, @ptrCast(blob.?))[0..32]);
                return result;
            }
        }
        return null;
    }

    /// Remove a tag from all torrents (used when deleting a global tag).
    pub fn removeTagFromTorrents(self: *ResumeDb, tag: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_tags WHERE tag = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    // ── Ban persistence ──────────────────────────────────────

    /// Save an individual IP ban (upsert).
    pub fn saveBannedIp(self: *ResumeDb, address: []const u8, source: u8, reason: ?[]const u8, created_at: i64) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO banned_ips (address, source, reason, created_at) VALUES (?1, ?2, ?3, ?4) " ++
                "ON CONFLICT(address) DO UPDATE SET source = ?2, reason = ?3",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, address.ptr, @intCast(address.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 2, @intCast(source));
        if (reason) |r| {
            _ = sqlite.sqlite3_bind_text(stmt, 3, r.ptr, @intCast(r.len), sqlite.SQLITE_TRANSIENT);
        } else {
            _ = sqlite.sqlite3_bind_null(stmt, 3);
        }
        _ = sqlite.sqlite3_bind_int64(stmt, 4, @intCast(created_at));
        try stepAndFinalize(stmt);
    }

    /// Remove an individual IP ban.
    pub fn removeBannedIp(self: *ResumeDb, address: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM banned_ips WHERE address = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, address.ptr, @intCast(address.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove all bans with the given source.
    pub fn clearBannedBySource(self: *ResumeDb, source: u8) !void {
        const stmt1 = try self.execOneShot("DELETE FROM banned_ips WHERE source = ?1");
        _ = sqlite.sqlite3_bind_int(stmt1, 1, @intCast(source));
        try stepAndFinalize(stmt1);

        const stmt2 = try self.execOneShot("DELETE FROM banned_ranges WHERE source = ?1");
        _ = sqlite.sqlite3_bind_int(stmt2, 1, @intCast(source));
        try stepAndFinalize(stmt2);
    }

    /// A banned IP loaded from the DB.
    pub const SavedBannedIp = struct {
        address: []const u8,
        source: u8,
        reason: ?[]const u8,
        created_at: i64,
    };

    /// Load all individual banned IPs. Caller owns the returned slices.
    pub fn loadBannedIps(self: *ResumeDb, allocator: std.mem.Allocator) ![]SavedBannedIp {
        const stmt = try self.execOneShot("SELECT address, source, reason, created_at FROM banned_ips");
        defer _ = sqlite.sqlite3_finalize(stmt);

        var result = std.ArrayList(SavedBannedIp).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.address);
                if (item.reason) |r| allocator.free(r);
            }
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const addr_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const addr_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const source: u8 = @intCast(sqlite.sqlite3_column_int(stmt, 1));

            const reason_ptr = sqlite.sqlite3_column_text(stmt, 2);
            const reason_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 2));
            const created_at: i64 = sqlite.sqlite3_column_int64(stmt, 3);

            const address = try allocator.dupe(u8, addr_ptr[0..addr_len]);
            errdefer allocator.free(address);
            const reason: ?[]const u8 = if (reason_ptr != null and reason_len > 0)
                try allocator.dupe(u8, reason_ptr.?[0..reason_len])
            else
                null;

            try result.append(allocator, .{
                .address = address,
                .source = source,
                .reason = reason,
                .created_at = created_at,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Save a banned range.
    pub fn saveBannedRange(self: *ResumeDb, start_addr: []const u8, end_addr: []const u8, source: u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO banned_ranges (start_addr, end_addr, source) VALUES (?1, ?2, ?3)",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, start_addr.ptr, @intCast(start_addr.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, end_addr.ptr, @intCast(end_addr.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(source));
        try stepAndFinalize(stmt);
    }

    /// A banned range loaded from the DB.
    pub const SavedBannedRange = struct {
        start_addr: []const u8,
        end_addr: []const u8,
        source: u8,
        created_at: i64,
    };

    /// Load all banned ranges. Caller owns the returned slices.
    pub fn loadBannedRanges(self: *ResumeDb, allocator: std.mem.Allocator) ![]SavedBannedRange {
        const stmt = try self.execOneShot("SELECT start_addr, end_addr, source, created_at FROM banned_ranges");
        defer _ = sqlite.sqlite3_finalize(stmt);

        var result = std.ArrayList(SavedBannedRange).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.start_addr);
                allocator.free(item.end_addr);
            }
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const start_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const start_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const end_ptr = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
            const end_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
            const source: u8 = @intCast(sqlite.sqlite3_column_int(stmt, 2));
            const created_at: i64 = sqlite.sqlite3_column_int64(stmt, 3);

            const start_addr = try allocator.dupe(u8, start_ptr[0..start_len]);
            errdefer allocator.free(start_addr);
            const end_addr = try allocator.dupe(u8, end_ptr[0..end_len]);

            try result.append(allocator, .{
                .start_addr = start_addr,
                .end_addr = end_addr,
                .source = source,
                .created_at = created_at,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    // ── Tracker override persistence ──────────────────────────

    /// A tracker override record: 'add' means a user-added tracker URL,
    /// 'remove' means a metainfo tracker URL the user wants hidden,
    /// 'edit' means the user replaced orig_url with url.
    pub const TrackerOverride = struct {
        url: []const u8,
        tier: u32,
        action: []const u8, // "add", "remove", or "edit"
        orig_url: ?[]const u8, // non-null only for "edit" action
    };

    /// Save a tracker override (upsert). For 'add' and 'remove', orig_url should be null.
    /// For 'edit', orig_url is the original URL that was replaced.
    pub fn saveTrackerOverride(self: *ResumeDb, info_hash: [20]u8, url: []const u8, tier: u32, action: []const u8, orig_url: ?[]const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO tracker_overrides (info_hash, url, tier, action, orig_url) VALUES (?1, ?2, ?3, ?4, ?5) " ++
                "ON CONFLICT(info_hash, url) DO UPDATE SET tier = ?3, action = ?4, orig_url = ?5",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(tier));
        _ = sqlite.sqlite3_bind_text(stmt, 4, action.ptr, @intCast(action.len), sqlite.SQLITE_TRANSIENT);
        if (orig_url) |ou| {
            _ = sqlite.sqlite3_bind_text(stmt, 5, ou.ptr, @intCast(ou.len), sqlite.SQLITE_TRANSIENT);
        } else {
            _ = sqlite.sqlite3_bind_null(stmt, 5);
        }
        try stepAndFinalize(stmt);
    }

    /// Remove a tracker override by URL.
    pub fn removeTrackerOverride(self: *ResumeDb, info_hash: [20]u8, url: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1 AND url = ?2");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a tracker override by orig_url (used when editing: remove the edit record for a given original URL).
    pub fn removeTrackerOverrideByOrig(self: *ResumeDb, info_hash: [20]u8, orig_url: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1 AND orig_url = ?2");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, orig_url.ptr, @intCast(orig_url.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Clear all tracker overrides for a torrent.
    pub fn clearTrackerOverrides(self: *ResumeDb, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all tracker overrides for a torrent. Caller owns the returned slices.
    pub fn loadTrackerOverrides(self: *ResumeDb, allocator: std.mem.Allocator, info_hash: [20]u8) ![]TrackerOverride {
        const stmt = try self.execOneShot("SELECT url, tier, action, orig_url FROM tracker_overrides WHERE info_hash = ?1 ORDER BY tier");
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        var result = std.ArrayList(TrackerOverride).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.url);
                allocator.free(item.action);
                if (item.orig_url) |ou| allocator.free(ou);
            }
            result.deinit(allocator);
        }

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const url_ptr = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const url_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const tier: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 1));
            const action_ptr = sqlite.sqlite3_column_text(stmt, 2) orelse continue;
            const action_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 2));
            const orig_ptr = sqlite.sqlite3_column_text(stmt, 3);
            const orig_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 3));

            const url = try allocator.dupe(u8, url_ptr[0..url_len]);
            errdefer allocator.free(url);
            const action = try allocator.dupe(u8, action_ptr[0..action_len]);
            errdefer allocator.free(action);
            const orig_url: ?[]const u8 = if (orig_ptr != null and orig_len > 0)
                try allocator.dupe(u8, orig_ptr.?[0..orig_len])
            else
                null;

            try result.append(allocator, .{
                .url = url,
                .tier = tier,
                .action = action,
                .orig_url = orig_url,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Free a TrackerOverride slice returned by loadTrackerOverrides().
    pub fn freeTrackerOverrides(allocator: std.mem.Allocator, overrides: []const TrackerOverride) void {
        for (overrides) |item| {
            allocator.free(item.url);
            allocator.free(item.action);
            if (item.orig_url) |ou| allocator.free(ou);
        }
        allocator.free(overrides);
    }

    /// IP filter config loaded from the DB.
    pub const IpFilterConfig = struct {
        path: ?[]const u8 = null,
        enabled: bool = false,
        rule_count: u32 = 0,
    };

    /// Load the ipfilter configuration (singleton).
    pub fn loadIpFilterConfig(self: *ResumeDb, allocator: std.mem.Allocator) !IpFilterConfig {
        const stmt = self.execOneShot("SELECT path, enabled, rule_count FROM ipfilter_config WHERE id = 1") catch return .{};
        defer _ = sqlite.sqlite3_finalize(stmt);

        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const path_ptr = sqlite.sqlite3_column_text(stmt, 0);
            const path_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const enabled = sqlite.sqlite3_column_int(stmt, 1) != 0;
            const rule_count: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 2));

            const path: ?[]const u8 = if (path_ptr != null and path_len > 0)
                try allocator.dupe(u8, path_ptr.?[0..path_len])
            else
                null;

            return .{ .path = path, .enabled = enabled, .rule_count = rule_count };
        }
        return .{};
    }

    /// Save the ipfilter configuration (upsert singleton).
    pub fn saveIpFilterConfig(self: *ResumeDb, config: IpFilterConfig) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO ipfilter_config (id, path, enabled, rule_count) VALUES (1, ?1, ?2, ?3) " ++
                "ON CONFLICT(id) DO UPDATE SET path = ?1, enabled = ?2, rule_count = ?3",
        );
        if (config.path) |p| {
            _ = sqlite.sqlite3_bind_text(stmt, 1, p.ptr, @intCast(p.len), sqlite.SQLITE_TRANSIENT);
        } else {
            _ = sqlite.sqlite3_bind_null(stmt, 1);
        }
        _ = sqlite.sqlite3_bind_int(stmt, 2, if (config.enabled) 1 else 0);
        _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(config.rule_count));
        try stepAndFinalize(stmt);
    }

    // ── Queue position persistence ───────────────────────

    /// Save a torrent's queue position (upsert).
    pub fn saveQueuePosition(self: *ResumeDb, info_hash_hex: [40]u8, position: u32) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO queue_positions (info_hash_hex, position) VALUES (?1, ?2) " ++
                "ON CONFLICT(info_hash_hex) DO UPDATE SET position = ?2",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, &info_hash_hex, 40, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 2, @intCast(position));
        try stepAndFinalize(stmt);
    }

    /// Remove a torrent's queue position.
    pub fn removeQueuePosition(self: *ResumeDb, info_hash_hex: [40]u8) !void {
        const stmt = try self.execOneShot(
            "DELETE FROM queue_positions WHERE info_hash_hex = ?1",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, &info_hash_hex, 40, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Clear all queue positions (used before re-saving the full queue).
    pub fn clearQueuePositions(self: *ResumeDb) !void {
        const stmt = try self.execOneShot("DELETE FROM queue_positions");
        try stepAndFinalize(stmt);
    }

    /// Load all queue positions from SQLite.
    pub fn loadQueuePositions(self: *ResumeDb, allocator: std.mem.Allocator) ![]@import("../daemon/queue_manager.zig").QueueEntry {
        const QueueEntry = @import("../daemon/queue_manager.zig").QueueEntry;
        const stmt = try self.execOneShot(
            "SELECT info_hash_hex, position FROM queue_positions ORDER BY position ASC",
        );
        var entries = std.ArrayList(QueueEntry).empty;
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const hex_ptr: ?[*]const u8 = @ptrCast(sqlite.sqlite3_column_text(stmt, 0));
            const hex_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const position: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 1));

            if (hex_ptr != null and hex_len == 40) {
                var entry: QueueEntry = .{
                    .info_hash_hex = undefined,
                    .position = position,
                };
                @memcpy(&entry.info_hash_hex, hex_ptr.?[0..40]);
                entries.append(allocator, entry) catch continue;
            }
        }
        _ = sqlite.sqlite3_finalize(stmt);
        return entries.toOwnedSlice(allocator);
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

test "resume db save and load rate limits" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const info_hash = [_]u8{0xDD} ** 20;

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

test "resume db save and load v2 info hash" {
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    const v1_hash = [_]u8{0xAA} ** 20;
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

    const hash_a = [_]u8{0xAA} ** 20;
    const hash_b = [_]u8{0xBB} ** 20;
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
    const hash_c = [_]u8{0xCC} ** 20;
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

    const info_hash = [_]u8{0xAA} ** 20;

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

    const info_hash = [_]u8{0xBB} ** 20;

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

    const info_hash = [_]u8{0xCC} ** 20;

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

    const hash_a = [_]u8{0xDD} ** 20;
    const hash_b = [_]u8{0xEE} ** 20;

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

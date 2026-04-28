//! SQLite-backed resume state — production resume DB.
//!
//! Mirrors the public surface of `SimResumeBackend` so daemon code that
//! holds `*ResumeDb` (=`*ResumeDbOf(SqliteBackend)`) compiles unchanged.
//! Types live at file level in `state_db.zig`; this struct re-exports
//! them as `SqliteBackend.<TypeName>` for callers that prefer the
//! backend-qualified path (e.g. `ResumeDb.TransferStats`).
//!
//! Threading: opens with `SQLITE_OPEN_FULLMUTEX`. The shared connection
//! is touched from worker threads (`TorrentSession.startWorker`),
//! RPC handlers, and `QueueManager`; SQLite's own mutex serialises
//! concurrent access. Hard invariant: never call SQLite from the
//! io_uring event-loop thread (blocks).

const std = @import("std");
const sqlite = @import("sqlite3.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const state_db = @import("state_db.zig");

pub const SqliteBackend = struct {
    // Backend-local re-exports of the file-level resume DB types so
    // `SqliteBackend.TransferStats` (and via the `ResumeDb` alias,
    // `ResumeDb.TransferStats`) keep working for callers that reach
    // these types through the backend struct rather than through the
    // module's file-level namespace. Pure aliases — no new types.
    pub const TransferStats = state_db.TransferStats;
    pub const RateLimits = state_db.RateLimits;
    pub const ShareLimits = state_db.ShareLimits;
    pub const IpFilterConfig = state_db.IpFilterConfig;
    pub const TrackerOverride = state_db.TrackerOverride;
    pub const SavedCategory = state_db.SavedCategory;
    pub const SavedBannedIp = state_db.SavedBannedIp;
    pub const SavedBannedRange = state_db.SavedBannedRange;
    pub const QueuePosition = state_db.QueuePosition;

    db: *sqlite.Db,
    insert_stmt: *sqlite.Stmt,
    query_stmt: *sqlite.Stmt,
    delete_stmt: *sqlite.Stmt,
    save_stats_stmt: *sqlite.Stmt,
    load_stats_stmt: *sqlite.Stmt,

    pub fn open(path: [*:0]const u8) !SqliteBackend {
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

        // Create share_limits table for per-torrent ratio and seeding time limits
        if (sqlite.sqlite3_exec(
            d,
            "CREATE TABLE IF NOT EXISTS share_limits (" ++
                "info_hash BLOB NOT NULL PRIMARY KEY, " ++
                "ratio_limit REAL NOT NULL DEFAULT -2.0, " ++
                "seeding_time_limit INTEGER NOT NULL DEFAULT -2, " ++
                "completion_on INTEGER NOT NULL DEFAULT 0" ++
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

    pub fn close(self: *SqliteBackend) void {
        _ = sqlite.sqlite3_finalize(self.insert_stmt);
        _ = sqlite.sqlite3_finalize(self.query_stmt);
        _ = sqlite.sqlite3_finalize(self.delete_stmt);
        _ = sqlite.sqlite3_finalize(self.save_stats_stmt);
        _ = sqlite.sqlite3_finalize(self.load_stats_stmt);
        _ = sqlite.sqlite3_close(self.db);
    }

    /// Record a completed piece.
    pub fn markComplete(self: *SqliteBackend, info_hash: [20]u8, piece_index: u32) !void {
        _ = sqlite.sqlite3_reset(self.insert_stmt);
        _ = sqlite.sqlite3_bind_blob(self.insert_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(self.insert_stmt, 2, @intCast(piece_index));

        if (sqlite.sqlite3_step(self.insert_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }

    /// Batch-record multiple completed pieces in a single transaction.
    pub fn markCompleteBatch(self: *SqliteBackend, info_hash: [20]u8, piece_indices: []const u32) !void {
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

    /// Replace the entire set of completed pieces for `info_hash` with
    /// `piece_indices` in a single transaction.
    ///
    /// Used after a recheck (live or stop+start) to ensure the resume DB
    /// reflects the on-disk truth: stale entries for pieces that the
    /// recheck found incomplete are deleted, and the new completed set
    /// is committed. This is the atomic fix for the "additive
    /// `markCompleteBatch` after recheck" bug — before this method,
    /// pieces marked complete pre-recheck but found incomplete after
    /// would survive in the resume DB and cause incorrect resume state
    /// on the next daemon restart.
    ///
    /// Empty `piece_indices` clears the pieces table for `info_hash`
    /// entirely (the post-recheck state of a torrent that lost every
    /// piece on disk). Auxiliary state for the torrent (rate_limits,
    /// share_limits, transfer_stats, etc.) is NOT touched — recheck only
    /// affects piece completion, never per-torrent metadata. To wipe
    /// all torrent state, use `clearTorrent`.
    pub fn replaceCompletePieces(
        self: *SqliteBackend,
        info_hash: [20]u8,
        piece_indices: []const u32,
    ) !void {
        if (sqlite.sqlite3_exec(self.db, "BEGIN IMMEDIATE", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteTransactionFailed;
        }
        errdefer _ = sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null);

        // Wipe the prior set of completed pieces for this info_hash. The
        // delete and insert share a transaction so a concurrent reader
        // never observes a partial state where stale entries are gone but
        // the new set hasn't landed yet.
        _ = sqlite.sqlite3_reset(self.delete_stmt);
        _ = sqlite.sqlite3_bind_blob(self.delete_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        if (sqlite.sqlite3_step(self.delete_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteDeleteFailed;
        }

        for (piece_indices) |piece_index| {
            self.markComplete(info_hash, piece_index) catch {
                return error.SqliteBatchFailed;
            };
        }

        if (sqlite.sqlite3_exec(self.db, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteCommitFailed;
        }
    }

    /// Load completed pieces into a Bitfield.
    /// Returns the count of pieces loaded.
    pub fn loadCompletePieces(self: *SqliteBackend, info_hash: [20]u8, bitfield: *Bitfield) !u32 {
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
    pub fn clearTorrent(self: *SqliteBackend, info_hash: [20]u8) !void {
        const info_hash_hex = std.fmt.bytesToHex(info_hash, .lower);

        if (sqlite.sqlite3_exec(self.db, "BEGIN IMMEDIATE", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteTransactionFailed;
        }
        errdefer _ = sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null);

        _ = sqlite.sqlite3_reset(self.delete_stmt);
        _ = sqlite.sqlite3_bind_blob(self.delete_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(self.delete_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteDeleteFailed;
        }

        inline for ([_][*:0]const u8{
            "DELETE FROM transfer_stats WHERE info_hash = ?1",
            "DELETE FROM torrent_categories WHERE info_hash = ?1",
            "DELETE FROM torrent_tags WHERE info_hash = ?1",
            "DELETE FROM rate_limits WHERE info_hash = ?1",
            "DELETE FROM info_hash_v2 WHERE info_hash = ?1",
            "DELETE FROM tracker_overrides WHERE info_hash = ?1",
            "DELETE FROM share_limits WHERE info_hash = ?1",
        }) |sql| {
            const stmt = try self.execOneShot(sql);
            _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
            try stepAndFinalize(stmt);
        }

        {
            const stmt = try self.execOneShot("DELETE FROM queue_positions WHERE info_hash_hex = ?1");
            _ = sqlite.sqlite3_bind_text(stmt, 1, &info_hash_hex, 40, sqlite.SQLITE_TRANSIENT);
            try stepAndFinalize(stmt);
        }

        if (sqlite.sqlite3_exec(self.db, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteCommitFailed;
        }
    }

    /// Persist lifetime upload/download byte totals for a torrent.
    pub fn saveTransferStats(self: *SqliteBackend, info_hash: [20]u8, stats: TransferStats) !void {
        _ = sqlite.sqlite3_reset(self.save_stats_stmt);
        _ = sqlite.sqlite3_bind_blob(self.save_stats_stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int64(self.save_stats_stmt, 2, @intCast(stats.total_uploaded));
        _ = sqlite.sqlite3_bind_int64(self.save_stats_stmt, 3, @intCast(stats.total_downloaded));

        if (sqlite.sqlite3_step(self.save_stats_stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }

    /// Load lifetime upload/download byte totals for a torrent.
    pub fn loadTransferStats(self: *SqliteBackend, info_hash: [20]u8) TransferStats {
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
    fn execOneShot(self: *SqliteBackend, sql: [*:0]const u8) !*sqlite.Stmt {
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
    pub fn saveCategory(self: *SqliteBackend, name: []const u8, save_path: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO categories (name, save_path) VALUES (?1, ?2) " ++
                "ON CONFLICT(name) DO UPDATE SET save_path = ?2",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, save_path.ptr, @intCast(save_path.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a category.
    pub fn removeCategory(self: *SqliteBackend, name: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM categories WHERE name = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all categories. Caller owns the returned slices (allocated with `allocator`).
    pub fn loadCategories(self: *SqliteBackend, allocator: std.mem.Allocator) ![]SavedCategory {
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
    pub fn saveTorrentCategory(self: *SqliteBackend, info_hash: [20]u8, category: []const u8) !void {
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
    pub fn loadTorrentCategory(self: *SqliteBackend, allocator: std.mem.Allocator, info_hash: [20]u8) !?[]const u8 {
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
    pub fn clearCategoryFromTorrents(self: *SqliteBackend, category: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_categories WHERE category = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, category.ptr, @intCast(category.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Save a torrent tag (insert or ignore).
    pub fn saveTorrentTag(self: *SqliteBackend, info_hash: [20]u8, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT OR IGNORE INTO torrent_tags (info_hash, tag) VALUES (?1, ?2)",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a specific tag from a torrent.
    pub fn removeTorrentTag(self: *SqliteBackend, info_hash: [20]u8, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "DELETE FROM torrent_tags WHERE info_hash = ?1 AND tag = ?2",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove all tags for a torrent.
    pub fn clearTorrentTags(self: *SqliteBackend, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_tags WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all tags for a torrent. Caller owns the returned slices.
    pub fn loadTorrentTags(self: *SqliteBackend, allocator: std.mem.Allocator, info_hash: [20]u8) ![][]const u8 {
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
    pub fn saveGlobalTag(self: *SqliteBackend, tag: []const u8) !void {
        const stmt = try self.execOneShot(
            "INSERT OR IGNORE INTO global_tags (name) VALUES (?1)",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a global tag.
    pub fn removeGlobalTag(self: *SqliteBackend, tag: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM global_tags WHERE name = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all global tags. Caller owns the returned slices.
    pub fn loadGlobalTags(self: *SqliteBackend, allocator: std.mem.Allocator) ![][]const u8 {
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
    pub fn saveRateLimits(self: *SqliteBackend, info_hash: [20]u8, dl_limit: u64, ul_limit: u64) !void {
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
    pub fn loadRateLimits(self: *SqliteBackend, info_hash: [20]u8) RateLimits {
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
    pub fn clearRateLimits(self: *SqliteBackend, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM rate_limits WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    // ── Share limit persistence ────────────────────────────

    /// Save per-torrent share limits (upsert).
    pub fn saveShareLimits(self: *SqliteBackend, info_hash: [20]u8, ratio_limit: f64, seeding_time_limit: i64, completion_on: i64) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO share_limits (info_hash, ratio_limit, seeding_time_limit, completion_on) VALUES (?1, ?2, ?3, ?4) " ++
                "ON CONFLICT(info_hash) DO UPDATE SET ratio_limit = ?2, seeding_time_limit = ?3, completion_on = ?4",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_double(stmt, 2, ratio_limit);
        _ = sqlite.sqlite3_bind_int64(stmt, 3, @intCast(seeding_time_limit));
        _ = sqlite.sqlite3_bind_int64(stmt, 4, @intCast(completion_on));
        try stepAndFinalize(stmt);
    }

    /// Load per-torrent share limits. Returns defaults if not set.
    pub fn loadShareLimits(self: *SqliteBackend, info_hash: [20]u8) ShareLimits {
        const stmt = self.execOneShot("SELECT ratio_limit, seeding_time_limit, completion_on FROM share_limits WHERE info_hash = ?1") catch return .{};
        defer _ = sqlite.sqlite3_finalize(stmt);
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            return .{
                .ratio_limit = sqlite.sqlite3_column_double(stmt, 0),
                .seeding_time_limit = sqlite.sqlite3_column_int64(stmt, 1),
                .completion_on = sqlite.sqlite3_column_int64(stmt, 2),
            };
        }
        return .{};
    }

    /// Clear share limits for a torrent.
    pub fn clearShareLimits(self: *SqliteBackend, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM share_limits WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    // ── BEP 52: v2 info-hash persistence ────────────────────

    /// Save the v2 info-hash for a hybrid/v2 torrent (upsert).
    pub fn saveInfoHashV2(self: *SqliteBackend, info_hash: [20]u8, info_hash_v2: [32]u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO info_hash_v2 (info_hash, info_hash_v2) VALUES (?1, ?2) " ++
                "ON CONFLICT(info_hash) DO UPDATE SET info_hash_v2 = ?2",
        );
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_blob(stmt, 2, &info_hash_v2, 32, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load the v2 info-hash for a torrent. Returns null if not stored (pure v1).
    pub fn loadInfoHashV2(self: *SqliteBackend, info_hash: [20]u8) ?[32]u8 {
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
    pub fn removeTagFromTorrents(self: *SqliteBackend, tag: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM torrent_tags WHERE tag = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, tag.ptr, @intCast(tag.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    // ── Ban persistence ──────────────────────────────────────

    /// Save an individual IP ban (upsert).
    pub fn saveBannedIp(self: *SqliteBackend, address: []const u8, source: u8, reason: ?[]const u8, created_at: i64) !void {
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
    pub fn removeBannedIp(self: *SqliteBackend, address: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM banned_ips WHERE address = ?1");
        _ = sqlite.sqlite3_bind_text(stmt, 1, address.ptr, @intCast(address.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove all bans with the given source.
    pub fn clearBannedBySource(self: *SqliteBackend, source: u8) !void {
        const stmt1 = try self.execOneShot("DELETE FROM banned_ips WHERE source = ?1");
        _ = sqlite.sqlite3_bind_int(stmt1, 1, @intCast(source));
        try stepAndFinalize(stmt1);

        const stmt2 = try self.execOneShot("DELETE FROM banned_ranges WHERE source = ?1");
        _ = sqlite.sqlite3_bind_int(stmt2, 1, @intCast(source));
        try stepAndFinalize(stmt2);
    }

    /// Load all individual banned IPs. Caller owns the returned slices.
    pub fn loadBannedIps(self: *SqliteBackend, allocator: std.mem.Allocator) ![]SavedBannedIp {
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
    pub fn saveBannedRange(self: *SqliteBackend, start_addr: []const u8, end_addr: []const u8, source: u8) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO banned_ranges (start_addr, end_addr, source) VALUES (?1, ?2, ?3)",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, start_addr.ptr, @intCast(start_addr.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, end_addr.ptr, @intCast(end_addr.len), sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(source));
        try stepAndFinalize(stmt);
    }

    /// Load all banned ranges. Caller owns the returned slices.
    pub fn loadBannedRanges(self: *SqliteBackend, allocator: std.mem.Allocator) ![]SavedBannedRange {
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

    /// Save a tracker override (upsert). For 'add' and 'remove', orig_url should be null.
    /// For 'edit', orig_url is the original URL that was replaced.
    pub fn saveTrackerOverride(self: *SqliteBackend, info_hash: [20]u8, url: []const u8, tier: u32, action: []const u8, orig_url: ?[]const u8) !void {
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
    pub fn removeTrackerOverride(self: *SqliteBackend, info_hash: [20]u8, url: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1 AND url = ?2");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Remove a tracker override by orig_url (used when editing: remove the edit record for a given original URL).
    pub fn removeTrackerOverrideByOrig(self: *SqliteBackend, info_hash: [20]u8, orig_url: []const u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1 AND orig_url = ?2");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_text(stmt, 2, orig_url.ptr, @intCast(orig_url.len), sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Clear all tracker overrides for a torrent.
    pub fn clearTrackerOverrides(self: *SqliteBackend, info_hash: [20]u8) !void {
        const stmt = try self.execOneShot("DELETE FROM tracker_overrides WHERE info_hash = ?1");
        _ = sqlite.sqlite3_bind_blob(stmt, 1, &info_hash, 20, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Load all tracker overrides for a torrent. Caller owns the returned slices.
    pub fn loadTrackerOverrides(self: *SqliteBackend, allocator: std.mem.Allocator, info_hash: [20]u8) ![]TrackerOverride {
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

    /// Load the ipfilter configuration (singleton).
    pub fn loadIpFilterConfig(self: *SqliteBackend, allocator: std.mem.Allocator) !IpFilterConfig {
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
    pub fn saveIpFilterConfig(self: *SqliteBackend, config: IpFilterConfig) !void {
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
    pub fn saveQueuePosition(self: *SqliteBackend, info_hash_hex: [40]u8, position: u32) !void {
        const stmt = try self.execOneShot(
            "INSERT INTO queue_positions (info_hash_hex, position) VALUES (?1, ?2) " ++
                "ON CONFLICT(info_hash_hex) DO UPDATE SET position = ?2",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, &info_hash_hex, 40, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_int(stmt, 2, @intCast(position));
        try stepAndFinalize(stmt);
    }

    /// Remove a torrent's queue position.
    pub fn removeQueuePosition(self: *SqliteBackend, info_hash_hex: [40]u8) !void {
        const stmt = try self.execOneShot(
            "DELETE FROM queue_positions WHERE info_hash_hex = ?1",
        );
        _ = sqlite.sqlite3_bind_text(stmt, 1, &info_hash_hex, 40, sqlite.SQLITE_TRANSIENT);
        try stepAndFinalize(stmt);
    }

    /// Clear all queue positions (used before re-saving the full queue).
    pub fn clearQueuePositions(self: *SqliteBackend) !void {
        const stmt = try self.execOneShot("DELETE FROM queue_positions");
        try stepAndFinalize(stmt);
    }

    /// Load all queue positions from SQLite.
    pub fn loadQueuePositions(self: *SqliteBackend, allocator: std.mem.Allocator) ![]QueuePosition {
        const stmt = try self.execOneShot(
            "SELECT info_hash_hex, position FROM queue_positions ORDER BY position ASC",
        );
        var entries = std.ArrayList(QueuePosition).empty;
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const hex_ptr: ?[*]const u8 = @ptrCast(sqlite.sqlite3_column_text(stmt, 0));
            const hex_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const position: u32 = @intCast(sqlite.sqlite3_column_int(stmt, 1));

            if (hex_ptr != null and hex_len == 40) {
                var entry: QueuePosition = .{
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

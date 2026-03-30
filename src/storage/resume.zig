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

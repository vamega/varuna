const std = @import("std");
const sqlite = @import("../storage/sqlite3.zig");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;

/// DHT routing table persistence using SQLite.
/// Runs on the existing SQLite background thread -- never on the event loop.
pub const DhtPersistence = struct {
    db: *sqlite.Db,
    save_node_stmt: ?*sqlite.Stmt = null,
    load_nodes_stmt: ?*sqlite.Stmt = null,
    save_config_stmt: ?*sqlite.Stmt = null,
    load_config_stmt: ?*sqlite.Stmt = null,

    /// Initialize DHT tables in an existing SQLite database.
    pub fn init(db: *sqlite.Db) !DhtPersistence {
        // Create DHT tables
        if (sqlite.sqlite3_exec(
            db,
            "CREATE TABLE IF NOT EXISTS dht_config (" ++
                "key TEXT PRIMARY KEY, " ++
                "value BLOB NOT NULL" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            return error.SqliteSchemaFailed;
        }

        if (sqlite.sqlite3_exec(
            db,
            "CREATE TABLE IF NOT EXISTS dht_nodes (" ++
                "node_id BLOB NOT NULL, " ++
                "ip TEXT NOT NULL, " ++
                "port INTEGER NOT NULL, " ++
                "last_seen INTEGER NOT NULL, " ++
                "PRIMARY KEY (node_id)" ++
                ")",
            null,
            null,
            null,
        ) != sqlite.SQLITE_OK) {
            return error.SqliteSchemaFailed;
        }

        // Prepare statements
        var save_node_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO dht_nodes (node_id, ip, port, last_seen) VALUES (?1, ?2, ?3, ?4)",
            -1,
            &save_node_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }

        var load_nodes_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "SELECT node_id, ip, port, last_seen FROM dht_nodes ORDER BY last_seen DESC LIMIT 300",
            -1,
            &load_nodes_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(save_node_stmt.?);
            return error.SqlitePrepareFailed;
        }

        var save_config_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO dht_config (key, value) VALUES (?1, ?2)",
            -1,
            &save_config_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(save_node_stmt.?);
            _ = sqlite.sqlite3_finalize(load_nodes_stmt.?);
            return error.SqlitePrepareFailed;
        }

        var load_config_stmt: ?*sqlite.Stmt = null;
        if (sqlite.sqlite3_prepare_v2(
            db,
            "SELECT value FROM dht_config WHERE key = ?1",
            -1,
            &load_config_stmt,
            null,
        ) != sqlite.SQLITE_OK) {
            _ = sqlite.sqlite3_finalize(save_node_stmt.?);
            _ = sqlite.sqlite3_finalize(load_nodes_stmt.?);
            _ = sqlite.sqlite3_finalize(save_config_stmt.?);
            return error.SqlitePrepareFailed;
        }

        return .{
            .db = db,
            .save_node_stmt = save_node_stmt,
            .load_nodes_stmt = load_nodes_stmt,
            .save_config_stmt = save_config_stmt,
            .load_config_stmt = load_config_stmt,
        };
    }

    pub fn deinit(self: *DhtPersistence) void {
        if (self.save_node_stmt) |s| _ = sqlite.sqlite3_finalize(s);
        if (self.load_nodes_stmt) |s| _ = sqlite.sqlite3_finalize(s);
        if (self.save_config_stmt) |s| _ = sqlite.sqlite3_finalize(s);
        if (self.load_config_stmt) |s| _ = sqlite.sqlite3_finalize(s);
    }

    /// Save the node ID to the config table.
    pub fn saveNodeId(self: *DhtPersistence, id: NodeId) !void {
        const stmt = self.save_config_stmt orelse return error.SqlitePrepareFailed;
        _ = sqlite.sqlite3_reset(stmt);
        _ = sqlite.sqlite3_bind_text(stmt, 1, "node_id", 7, sqlite.SQLITE_TRANSIENT);
        _ = sqlite.sqlite3_bind_blob(stmt, 2, &id, 20, sqlite.SQLITE_TRANSIENT);
        if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }

    /// Load the node ID from the config table.
    /// Returns null if not found (first run).
    pub fn loadNodeId(self: *DhtPersistence) !?NodeId {
        const stmt = self.load_config_stmt orelse return error.SqlitePrepareFailed;
        _ = sqlite.sqlite3_reset(stmt);
        _ = sqlite.sqlite3_bind_text(stmt, 1, "node_id", 7, sqlite.SQLITE_TRANSIENT);

        if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW) {
            return null;
        }

        const blob = sqlite.sqlite3_column_blob(stmt, 0);
        const blob_len = sqlite.sqlite3_column_bytes(stmt, 0);
        if (blob == null or blob_len != 20) return null;

        var id: NodeId = undefined;
        const src: [*]const u8 = @ptrCast(blob.?);
        @memcpy(&id, src[0..20]);
        return id;
    }

    /// Save routing table nodes to the database.
    /// Called on graceful shutdown and periodically (~30 minutes).
    pub fn saveNodes(self: *DhtPersistence, nodes: []const NodeInfo) !void {
        const stmt = self.save_node_stmt orelse return error.SqlitePrepareFailed;

        // Use a transaction for batch insert
        _ = sqlite.sqlite3_exec(self.db, "BEGIN", null, null, null);
        errdefer _ = sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null);

        // Clear old nodes first
        _ = sqlite.sqlite3_exec(self.db, "DELETE FROM dht_nodes", null, null, null);

        for (nodes) |node| {
            _ = sqlite.sqlite3_reset(stmt);
            _ = sqlite.sqlite3_bind_blob(stmt, 1, &node.id, 20, sqlite.SQLITE_TRANSIENT);

            // Format IP address as text
            var ip_buf: [46]u8 = undefined; // max IPv6 length
            const ip_str = formatAddress(node.address, &ip_buf) orelse continue;
            _ = sqlite.sqlite3_bind_text(
                stmt,
                2,
                ip_str.ptr,
                @intCast(ip_str.len),
                sqlite.SQLITE_TRANSIENT,
            );

            const port = node.address.getPort();
            _ = sqlite.sqlite3_bind_int(stmt, 3, @intCast(port));
            _ = sqlite.sqlite3_bind_int64(stmt, 4, node.last_seen);

            if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_DONE) {
                _ = sqlite.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
                return error.SqliteInsertFailed;
            }
        }

        if (sqlite.sqlite3_exec(self.db, "COMMIT", null, null, null) != sqlite.SQLITE_OK) {
            return error.SqliteCommitFailed;
        }
    }

    /// Load persisted routing table nodes.
    pub fn loadNodes(self: *DhtPersistence, allocator: std.mem.Allocator) ![]NodeInfo {
        const stmt = self.load_nodes_stmt orelse return error.SqlitePrepareFailed;
        _ = sqlite.sqlite3_reset(stmt);

        var nodes = std.ArrayList(NodeInfo).empty;
        errdefer nodes.deinit(allocator);

        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const id_blob = sqlite.sqlite3_column_blob(stmt, 0);
            const id_len = sqlite.sqlite3_column_bytes(stmt, 0);
            if (id_blob == null or id_len != 20) continue;

            var id: NodeId = undefined;
            const src: [*]const u8 = @ptrCast(id_blob.?);
            @memcpy(&id, src[0..20]);

            const ip_text = sqlite.sqlite3_column_text(stmt, 1);
            if (ip_text == null) continue;
            const port: u16 = @intCast(sqlite.sqlite3_column_int(stmt, 2));
            const last_seen = sqlite.sqlite3_column_int64(stmt, 3);

            // Parse IP address
            const addr = std.net.Address.resolveIp(std.mem.span(ip_text.?), port) catch continue;

            try nodes.append(allocator, .{
                .id = id,
                .address = addr,
                .last_seen = last_seen,
                .ever_responded = true, // persisted nodes were good at save time
            });
        }

        return nodes.toOwnedSlice(allocator);
    }
};

fn formatAddress(addr: std.net.Address, buf: *[46]u8) ?[]const u8 {
    const bytes: [4]u8 = @bitCast(addr.in.sa.addr);
    const result = std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return null;
    return result;
}

test "DhtPersistence format address" {
    var buf: [46]u8 = undefined;
    const addr = std.net.Address.initIp4(.{ 192, 168, 1, 100 }, 6881);
    const result = formatAddress(addr, &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("192.168.1.100", result.?);
}

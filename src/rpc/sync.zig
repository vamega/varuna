const std = @import("std");
const TorrentStats = @import("../daemon/torrent_session.zig").Stats;
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const json_mod = @import("json.zig");
const compat = @import("compat.zig");

/// Delta sync state for the /api/v2/sync/maindata endpoint.
/// Tracks torrent snapshots across request IDs so that only changes
/// are returned to clients polling every 1-2 seconds.
pub const SyncState = struct {
    allocator: std.mem.Allocator,
    /// Monotonically increasing response ID.
    current_rid: u64 = 0,
    /// Ring buffer of snapshots, indexed by rid % max_snapshots.
    snapshots: [max_snapshots]?Snapshot = [_]?Snapshot{null} ** max_snapshots,

    const max_snapshots = 100;

    const Snapshot = struct {
        /// The rid this snapshot was created for.
        rid: u64,
        /// Map of info_hash_hex -> hash of the serialized stats, for cheap change detection.
        torrent_hashes: std.StringHashMap(u64),

        fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            // Keys are owned copies
            var iter = self.torrent_hashes.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.torrent_hashes.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) SyncState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SyncState) void {
        for (&self.snapshots) |*slot| {
            if (slot.*) |*snap| {
                snap.deinit(self.allocator);
                slot.* = null;
            }
        }
    }

    /// Compute a delta response as JSON. Returns owned slice.
    /// `request_rid` is the rid the client sent (0 = full sync).
    pub fn computeDelta(
        self: *SyncState,
        session_manager: *SessionManager,
        allocator: std.mem.Allocator,
        request_rid: u64,
    ) ![]u8 {
        // Fetch current torrent stats
        const stats = try session_manager.getAllStats(allocator);
        defer allocator.free(stats);

        // Get global transfer info
        const el = session_manager.shared_event_loop;
        const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
        const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;

        var total_dl_speed: u64 = 0;
        var total_ul_speed: u64 = 0;
        var total_dl_data: u64 = 0;
        var total_ul_data: u64 = 0;
        for (stats) |stat| {
            total_dl_speed += stat.download_speed;
            total_ul_speed += stat.upload_speed;
            total_dl_data += stat.bytes_downloaded;
            total_ul_data += stat.bytes_uploaded;
        }

        // Determine if this is a full update
        const prev_snapshot = self.getSnapshot(request_rid);
        const full_update = request_rid == 0 or prev_snapshot == null;

        // Build current torrent hash map for change detection
        var current_hashes = std.StringHashMap(u64).init(allocator);
        defer current_hashes.deinit();
        for (stats) |stat| {
            try current_hashes.put(&stat.info_hash_hex, statsHash(stat));
        }

        // Bump rid
        self.current_rid += 1;
        const response_rid = self.current_rid;

        // Build JSON
        var json = std.ArrayList(u8).empty;
        errdefer json.deinit(allocator);

        try json.appendSlice(allocator, "{\"rid\":");
        try json.print(allocator, "{}", .{response_rid});

        try json.appendSlice(allocator, ",\"full_update\":");
        try json.appendSlice(allocator, if (full_update) "true" else "false");

        // Torrents section: only changed torrents (or all if full update)
        try json.appendSlice(allocator, ",\"torrents\":{");
        var first_torrent = true;
        for (stats) |stat| {
            const include = if (full_update)
                true
            else if (prev_snapshot) |prev| blk: {
                const prev_hash = prev.torrent_hashes.get(&stat.info_hash_hex);
                break :blk prev_hash == null or prev_hash.? != statsHash(stat);
            } else true;

            if (include) {
                if (!first_torrent) try json.append(allocator, ',');
                first_torrent = false;
                try json.append(allocator, '"');
                try json.appendSlice(allocator, &stat.info_hash_hex);
                try json.appendSlice(allocator, "\":");
                try serializeTorrentObject(allocator, &json, stat);
            }
        }
        try json.append(allocator, '}');

        // Torrents removed: hashes present in previous snapshot but absent now
        try json.appendSlice(allocator, ",\"torrents_removed\":[");
        if (!full_update) {
            if (prev_snapshot) |prev| {
                var first_removed = true;
                var prev_iter = prev.torrent_hashes.iterator();
                while (prev_iter.next()) |entry| {
                    if (!current_hashes.contains(entry.key_ptr.*)) {
                        if (!first_removed) try json.append(allocator, ',');
                        first_removed = false;
                        try json.append(allocator, '"');
                        try json.appendSlice(allocator, entry.key_ptr.*);
                        try json.append(allocator, '"');
                    }
                }
            }
        }
        try json.append(allocator, ']');

        // Categories
        try json.appendSlice(allocator, ",\"categories\":");
        {
            session_manager.mutex.lock();
            defer session_manager.mutex.unlock();
            const cat_json = try session_manager.category_store.serializeJson(allocator);
            defer allocator.free(cat_json);
            try json.appendSlice(allocator, cat_json);
        }

        // Tags
        try json.appendSlice(allocator, ",\"tags\":");
        {
            session_manager.mutex.lock();
            defer session_manager.mutex.unlock();
            const tag_json = try session_manager.tag_store.serializeJson(allocator);
            defer allocator.free(tag_json);
            try json.appendSlice(allocator, tag_json);
        }

        // Server state (includes all fields qui's ServerState interface expects)
        try json.print(allocator, ",\"server_state\":{{\"connection_status\":\"connected\",\"dht_nodes\":0,\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{},\"alltime_dl\":{},\"alltime_ul\":{},\"queueing\":false,\"use_alt_speed_limits\":false,\"refresh_interval\":1500,\"free_space_on_disk\":0,\"total_peer_connections\":0}}", .{
            total_dl_speed,
            total_ul_speed,
            total_dl_data,
            total_ul_data,
            dl_limit,
            ul_limit,
            total_dl_data,
            total_ul_data,
        });

        try json.append(allocator, '}');

        // Store snapshot for future delta comparisons
        self.storeSnapshot(response_rid, stats);

        return json.toOwnedSlice(allocator);
    }

    /// Look up a previous snapshot by rid.
    fn getSnapshot(self: *const SyncState, rid: u64) ?*const Snapshot {
        if (rid == 0) return null;
        const slot = rid % max_snapshots;
        if (self.snapshots[slot]) |*snap| {
            if (snap.rid == rid) return snap;
        }
        return null;
    }

    /// Store a snapshot in the circular buffer.
    fn storeSnapshot(self: *SyncState, rid: u64, stats: []const TorrentStats) void {
        const slot = rid % max_snapshots;

        // Free previous snapshot in this slot
        if (self.snapshots[slot]) |*old| {
            old.deinit(self.allocator);
        }

        var hashes = std.StringHashMap(u64).init(self.allocator);
        for (stats) |stat| {
            const key = self.allocator.dupe(u8, &stat.info_hash_hex) catch continue;
            hashes.put(key, statsHash(stat)) catch {
                self.allocator.free(key);
                continue;
            };
        }

        self.snapshots[slot] = .{
            .rid = rid,
            .torrent_hashes = hashes,
        };
    }
};

/// Compute a cheap hash of the key stats fields for change detection.
fn statsHash(stat: TorrentStats) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&stat.state));
    hasher.update(std.mem.asBytes(&stat.progress));
    hasher.update(std.mem.asBytes(&stat.download_speed));
    hasher.update(std.mem.asBytes(&stat.upload_speed));
    hasher.update(std.mem.asBytes(&stat.pieces_have));
    hasher.update(std.mem.asBytes(&stat.bytes_downloaded));
    hasher.update(std.mem.asBytes(&stat.bytes_uploaded));
    hasher.update(std.mem.asBytes(&stat.peers_connected));
    hasher.update(std.mem.asBytes(&stat.dl_limit));
    hasher.update(std.mem.asBytes(&stat.ul_limit));
    hasher.update(std.mem.asBytes(&stat.eta));
    hasher.update(std.mem.asBytes(&stat.ratio));
    hasher.update(std.mem.asBytes(&stat.sequential_download));
    hasher.update(std.mem.asBytes(&stat.is_private));
    hasher.update(std.mem.asBytes(&stat.scrape_complete));
    hasher.update(std.mem.asBytes(&stat.scrape_incomplete));
    hasher.update(stat.category);
    hasher.update(stat.tags);
    return hasher.final();
}

/// Serialize a full torrent stats object as a JSON object.
/// Includes all fields that qui's Torrent interface expects.
fn serializeTorrentObject(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentStats) !void {
    const esc = json_mod.jsonSafe;
    const qbt_state = compat.torrentStateString(stat.state, stat.progress);
    const now = std.time.timestamp();
    const time_active: i64 = now - stat.added_on;
    const amount_left: u64 = if (stat.total_size > stat.bytes_downloaded) stat.total_size - stat.bytes_downloaded else 0;
    const completion_on: i64 = if (stat.progress >= 1.0) stat.added_on else -1;

    // Split into two print calls to stay under the 32-argument limit.
    try json.print(
        allocator,
        "{{\"name\":\"{f}\",\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"\",\"state\":\"{s}\",\"size\":{},\"total_size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":{},\"num_leechs\":{},\"num_complete\":{},\"num_incomplete\":{},\"added_on\":{},\"completion_on\":{},\"save_path\":\"{f}\",\"content_path\":\"{f}\",\"download_path\":\"\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{s},\"private\":{s}",
        .{
            esc(stat.name),
            stat.info_hash_hex,
            stat.info_hash_hex,
            qbt_state,
            stat.total_size,
            stat.total_size,
            stat.progress,
            stat.download_speed,
            stat.upload_speed,
            stat.scrape_complete,
            stat.peers_connected,
            stat.scrape_complete,
            stat.scrape_incomplete,
            stat.added_on,
            completion_on,
            esc(stat.save_path),
            esc(stat.save_path),
            stat.pieces_have,
            stat.pieces_total,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            @as([]const u8, if (stat.sequential_download) "true" else "false"),
            @as([]const u8, if (stat.is_private) "true" else "false"),
        },
    );

    try json.print(
        allocator,
        ",\"f_l_piece_prio\":false,\"force_start\":false,\"super_seeding\":false,\"auto_tmm\":false,\"category\":\"{f}\",\"tags\":\"{f}\",\"tracker\":\"\",\"trackers_count\":0,\"amount_left\":{},\"completed\":{},\"downloaded\":{},\"downloaded_session\":{},\"uploaded\":{},\"uploaded_session\":{},\"time_active\":{},\"seeding_time\":{},\"last_activity\":{},\"seen_complete\":-1,\"priority\":0,\"availability\":-1,\"max_ratio\":-1,\"max_seeding_time\":-1,\"ratio_limit\":-1,\"seeding_time_limit\":-1,\"popularity\":0,\"magnet_uri\":\"\",\"reannounce\":0}}",
        .{
            esc(stat.category),
            esc(stat.tags),
            amount_left,
            stat.bytes_downloaded,
            stat.bytes_downloaded,
            stat.bytes_downloaded,
            stat.bytes_uploaded,
            stat.bytes_uploaded,
            time_active,
            @as(i64, if (stat.state == .seeding) time_active else 0),
            now,
        },
    );
}

// ── Tests ─────────────────────────────────────────────────

test "sync state full update on rid 0" {
    const allocator = std.testing.allocator;
    var sync = SyncState.init(allocator);
    defer sync.deinit();

    // We can't easily construct a SessionManager with mock data in a unit test,
    // so test the statsHash and snapshot machinery directly.
    const stat1 = TorrentStats{
        .state = .downloading,
        .progress = 0.5,
        .download_speed = 1000,
        .upload_speed = 0,
        .pieces_have = 5,
        .pieces_total = 10,
        .total_size = 10000,
        .name = "test",
        .info_hash_hex = "abcdef0123456789abcdef0123456789abcdef01".*,
    };

    const stat2 = TorrentStats{
        .state = .downloading,
        .progress = 0.6,
        .download_speed = 1000,
        .upload_speed = 0,
        .pieces_have = 5,
        .pieces_total = 10,
        .total_size = 10000,
        .name = "test",
        .info_hash_hex = "abcdef0123456789abcdef0123456789abcdef01".*,
    };

    // Same stats with different progress should produce different hashes
    const h1 = statsHash(stat1);
    const h2 = statsHash(stat2);
    try std.testing.expect(h1 != h2);

    // Same stats should produce identical hashes
    const h3 = statsHash(stat1);
    try std.testing.expectEqual(h1, h3);
}

test "sync state snapshot circular buffer" {
    const allocator = std.testing.allocator;
    var sync = SyncState.init(allocator);
    defer sync.deinit();

    const stats = [_]TorrentStats{.{
        .state = .downloading,
        .progress = 0.5,
        .name = "test",
        .info_hash_hex = "abcdef0123456789abcdef0123456789abcdef01".*,
    }};

    // Store a snapshot at rid 1
    sync.storeSnapshot(1, &stats);
    try std.testing.expect(sync.getSnapshot(1) != null);
    try std.testing.expect(sync.getSnapshot(2) == null);

    // Overwrite: store at rid 1 + max_snapshots should evict rid 1
    sync.storeSnapshot(1 + SyncState.max_snapshots, &stats);
    try std.testing.expect(sync.getSnapshot(1) == null);
    try std.testing.expect(sync.getSnapshot(1 + SyncState.max_snapshots) != null);
}

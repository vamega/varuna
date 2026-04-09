const std = @import("std");
const TorrentStats = @import("../daemon/torrent_session.zig").Stats;
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const compat = @import("compat.zig");
const json_esc = @import("json.zig");

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
        torrent_hashes: std.AutoHashMap([40]u8, u64),

        fn deinit(self: *Snapshot) void {
            self.torrent_hashes.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) SyncState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SyncState) void {
        for (&self.snapshots) |*slot| {
            if (slot.*) |*snap| {
                snap.deinit();
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

        // Get global transfer info via facade
        const transfer = session_manager.getTransferInfo(allocator) catch SessionManager.TransferInfo{};
        const dl_limit = transfer.dl_limit;
        const ul_limit = transfer.ul_limit;
        const dht_nodes = transfer.dht_nodes;
        const total_dl_speed = transfer.dl_speed;
        const total_ul_speed = transfer.ul_speed;
        const total_dl_data = transfer.dl_data;
        const total_ul_data = transfer.ul_data;

        // Determine if this is a full update
        const prev_snapshot = self.getSnapshot(request_rid);
        const full_update = request_rid == 0 or prev_snapshot == null;

        // Build current torrent hash map for change detection
        var current_hashes = std.AutoHashMap([40]u8, u64).init(allocator);
        defer current_hashes.deinit();
        for (stats) |stat| {
            try current_hashes.put(stat.info_hash_hex, statsHash(stat));
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
                const prev_hash = prev.torrent_hashes.get(stat.info_hash_hex);
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
                        try json.appendSlice(allocator, entry.key_ptr.*[0..]);
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
            const cat_json = try session_manager.category_store.cachedJson();
            try json.appendSlice(allocator, cat_json);
        }

        // Tags
        try json.appendSlice(allocator, ",\"tags\":");
        {
            session_manager.mutex.lock();
            defer session_manager.mutex.unlock();
            const tag_json = try session_manager.tag_store.cachedJson();
            try json.appendSlice(allocator, tag_json);
        }

        // Server state (includes all fields qui's ServerState interface expects)
        try json.print(allocator, ",\"server_state\":{{\"connection_status\":\"connected\",\"dht_nodes\":{},\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{},\"alltime_dl\":{},\"alltime_ul\":{},\"queueing\":false,\"use_alt_speed_limits\":false,\"refresh_interval\":1500,\"free_space_on_disk\":0,\"total_peer_connections\":0}}", .{
            dht_nodes,
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
            old.deinit();
        }

        var hashes = std.AutoHashMap([40]u8, u64).init(self.allocator);
        for (stats) |stat| {
            hashes.put(stat.info_hash_hex, statsHash(stat)) catch continue;
        }

        self.snapshots[slot] = .{
            .rid = rid,
            .torrent_hashes = hashes,
        };
    }
};

/// Delta sync state for /api/v2/sync/torrentPeers.
/// Snapshots are scoped by torrent hash so rid-based polling can return only
/// changed peers and removed peer keys.
pub const PeerSyncState = struct {
    allocator: std.mem.Allocator,
    current_rid: u64 = 0,
    snapshots: [max_snapshots]?Snapshot = [_]?Snapshot{null} ** max_snapshots,

    const max_snapshots = 100;

    const Snapshot = struct {
        rid: u64,
        torrent_hash: [40]u8,
        peer_hashes: std.StringHashMap(u64),

        fn deinit(self: *Snapshot) void {
            var iter = self.peer_hashes.iterator();
            while (iter.next()) |entry| {
                self.peer_hashes.allocator.free(entry.key_ptr.*);
            }
            self.peer_hashes.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) PeerSyncState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PeerSyncState) void {
        for (&self.snapshots) |*slot| {
            if (slot.*) |*snap| {
                snap.deinit();
                slot.* = null;
            }
        }
    }

    pub fn computeDelta(
        self: *PeerSyncState,
        session_manager: *SessionManager,
        allocator: std.mem.Allocator,
        torrent_hash: []const u8,
        request_rid: u64,
    ) ![]u8 {
        const peers = try session_manager.getTorrentPeers(allocator, torrent_hash);
        defer SessionManager.freePeerInfos(allocator, peers);

        const prev_snapshot = self.getSnapshot(request_rid, torrent_hash);
        const full_update = request_rid == 0 or prev_snapshot == null;

        var current_hashes = std.StringHashMap(u64).init(allocator);
        defer current_hashes.deinit();
        for (peers) |peer| {
            try current_hashes.put(peer.ip, peerHash(peer));
        }

        self.current_rid += 1;
        const response_rid = self.current_rid;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.print(allocator, "{{\"rid\":{},\"full_update\":{s},\"peers\":{{", .{
            response_rid,
            if (full_update) "true" else "false",
        });

        var first_peer = true;
        for (peers) |peer| {
            const include = if (full_update)
                true
            else if (prev_snapshot) |prev| blk: {
                const prev_hash = prev.peer_hashes.get(peer.ip);
                break :blk prev_hash == null or prev_hash.? != peerHash(peer);
            } else true;

            if (!include) continue;
            if (!first_peer) try out.append(allocator, ',');
            first_peer = false;
            try serializePeerObject(allocator, &out, peer);
        }
        try out.appendSlice(allocator, "},\"peers_removed\":[");

        if (!full_update) {
            if (prev_snapshot) |prev| {
                var first_removed = true;
                var iter = prev.peer_hashes.iterator();
                while (iter.next()) |entry| {
                    if (!current_hashes.contains(entry.key_ptr.*)) {
                        if (!first_removed) try out.append(allocator, ',');
                        first_removed = false;
                        try out.writer(allocator).print("\"{f}\"", .{json_esc.jsonSafe(entry.key_ptr.*)});
                    }
                }
            }
        }

        try out.appendSlice(allocator, "],\"show_flags\":true}");
        self.storeSnapshot(response_rid, torrent_hash, peers);
        return out.toOwnedSlice(allocator);
    }

    fn getSnapshot(self: *const PeerSyncState, rid: u64, torrent_hash: []const u8) ?*const Snapshot {
        if (rid == 0 or torrent_hash.len != 40) return null;
        const slot = rid % max_snapshots;
        if (self.snapshots[slot]) |*snap| {
            if (snap.rid == rid and std.mem.eql(u8, snap.torrent_hash[0..], torrent_hash)) return snap;
        }
        return null;
    }

    fn storeSnapshot(
        self: *PeerSyncState,
        rid: u64,
        torrent_hash: []const u8,
        peers: []const SessionManager.PeerInfo,
    ) void {
        if (torrent_hash.len != 40) return;
        const slot = rid % max_snapshots;
        if (self.snapshots[slot]) |*old| old.deinit();

        var hash_buf: [40]u8 = undefined;
        @memcpy(&hash_buf, torrent_hash[0..40]);

        var peer_hashes = std.StringHashMap(u64).init(self.allocator);
        for (peers) |peer| {
            const key = self.allocator.dupe(u8, peer.ip) catch continue;
            peer_hashes.put(key, peerHash(peer)) catch {
                self.allocator.free(key);
                continue;
            };
        }

        self.snapshots[slot] = .{
            .rid = rid,
            .torrent_hash = hash_buf,
            .peer_hashes = peer_hashes,
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
/// Delegates to compat.serializeTorrentJson with include_partial_seed=false.
fn serializeTorrentObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), stat: TorrentStats) !void {
    return compat.serializeTorrentJson(allocator, out, stat, false);
}

fn peerHash(peer: SessionManager.PeerInfo) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(peer.ip);
    hasher.update(std.mem.asBytes(&peer.port));
    hasher.update(peer.client);
    hasher.update(peer.flags);
    hasher.update(std.mem.asBytes(&peer.dl_speed));
    hasher.update(std.mem.asBytes(&peer.ul_speed));
    hasher.update(std.mem.asBytes(&peer.downloaded));
    hasher.update(std.mem.asBytes(&peer.uploaded));
    hasher.update(std.mem.asBytes(&peer.progress));
    hasher.update(std.mem.asBytes(&peer.upload_only));
    return hasher.final();
}

fn serializePeerObject(
    allocator: std.mem.Allocator,
    json_buf: *std.ArrayList(u8),
    peer: SessionManager.PeerInfo,
) !void {
    const esc = json_esc.jsonSafe;
    try json_buf.writer(allocator).print("\"{f}\":{{\"client\":\"{f}\",\"connection\":\"\",\"country\":\"\",\"country_code\":\"\",\"dl_speed\":{},\"downloaded\":{},\"files\":\"\",\"flags\":\"{f}\",\"flags_desc\":\"\",\"ip\":\"{f}\",\"port\":{},\"progress\":{d:.4},\"relevance\":1,\"up_speed\":{},\"uploaded\":{},\"upload_only\":{}}}", .{
        esc(peer.ip),
        esc(peer.client),
        peer.dl_speed,
        peer.downloaded,
        esc(peer.flags),
        esc(peer.ip),
        peer.port,
        peer.progress,
        peer.ul_speed,
        peer.uploaded,
        peer.upload_only,
    });
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

test "peer sync snapshot is scoped by torrent hash" {
    var state = PeerSyncState.init(std.testing.allocator);
    defer state.deinit();

    const peers = [_]SessionManager.PeerInfo{
        .{
            .ip = "127.0.0.1:6881",
            .port = 6881,
            .client = "qBittorrent",
            .flags = "DX",
            .dl_speed = 1,
            .ul_speed = 2,
            .downloaded = 3,
            .uploaded = 4,
            .progress = 0.5,
            .upload_only = false,
        },
    };

    state.storeSnapshot(1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &peers);
    try std.testing.expect(state.getSnapshot(1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(state.getSnapshot(1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == null);
}

test "peer hash changes when peer fields change" {
    const base = SessionManager.PeerInfo{
        .ip = "127.0.0.1:6881",
        .port = 6881,
        .client = "qBittorrent",
        .flags = "DX",
        .dl_speed = 1,
        .ul_speed = 2,
        .downloaded = 3,
        .uploaded = 4,
        .progress = 0.5,
        .upload_only = false,
    };
    var changed = base;
    changed.dl_speed = 99;
    try std.testing.expect(peerHash(base) != peerHash(changed));
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

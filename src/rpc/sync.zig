const std = @import("std");
const TorrentStats = @import("../daemon/torrent_session.zig").Stats;
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const compat = @import("compat.zig");
const json_body = @import("json_body.zig");

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
        session_manager: anytype,
        allocator: std.mem.Allocator,
        request_rid: u64,
    ) ![]u8 {
        const SessionManagerType = @TypeOf(session_manager.*);

        // Fetch current torrent stats
        const stats = try session_manager.getAllStats(allocator);
        defer allocator.free(stats);

        // Get global transfer info via facade
        const transfer = session_manager.getTransferInfo(allocator) catch SessionManagerType.TransferInfo{};
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

        // Server state includes all fields qui's ServerState interface expects.
        try json.appendSlice(allocator, ",\"server_state\":");
        try json_body.append(allocator, &json, SyncServerStateResponse{
            .dht_nodes = dht_nodes,
            .dl_info_speed = total_dl_speed,
            .up_info_speed = total_ul_speed,
            .dl_info_data = total_dl_data,
            .up_info_data = total_ul_data,
            .dl_rate_limit = dl_limit,
            .up_rate_limit = ul_limit,
            .alltime_dl = total_dl_data,
            .alltime_ul = total_ul_data,
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

const SyncServerStateResponse = struct {
    connection_status: []const u8 = "connected",
    dht_nodes: usize,
    dl_info_speed: u64,
    up_info_speed: u64,
    dl_info_data: u64,
    up_info_data: u64,
    dl_rate_limit: u64,
    up_rate_limit: u64,
    alltime_dl: u64,
    alltime_ul: u64,
    queueing: bool = false,
    use_alt_speed_limits: bool = false,
    refresh_interval: u16 = 1500,
    free_space_on_disk: u8 = 0,
    total_peer_connections: u8 = 0,
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
        session_manager: anytype,
        allocator: std.mem.Allocator,
        torrent_hash: []const u8,
        request_rid: u64,
    ) ![]u8 {
        const SessionManagerType = @TypeOf(session_manager.*);
        const peers = try session_manager.getTorrentPeers(allocator, torrent_hash);
        defer SessionManagerType.freePeerInfos(allocator, peers);

        const prev_snapshot = self.getSnapshot(request_rid, torrent_hash);
        const full_update = request_rid == 0 or prev_snapshot == null;

        var current_hashes = std.StringHashMap(u64).init(allocator);
        defer current_hashes.deinit();
        var current_keys = std.ArrayList([]u8).empty;
        defer {
            for (current_keys.items) |key| allocator.free(key);
            current_keys.deinit(allocator);
        }
        for (peers) |peer| {
            const key = try peerKeyAlloc(allocator, peer);
            errdefer allocator.free(key);
            try current_hashes.put(key, peerHash(peer));
            try current_keys.append(allocator, key);
        }

        self.current_rid += 1;
        const response_rid = self.current_rid;

        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();

        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

        try json.beginObject();
        try json.objectField("rid");
        try json.write(response_rid);
        try json.objectField("full_update");
        try json.write(full_update);
        try json.objectField("peers");
        try json.beginObject();

        for (peers, current_keys.items) |peer, key| {
            const include = if (full_update)
                true
            else if (prev_snapshot) |prev| blk: {
                const prev_hash = prev.peer_hashes.get(key);
                break :blk prev_hash == null or prev_hash.? != peerHash(peer);
            } else true;

            if (!include) continue;
            try json.objectField(key);
            try json.write(peerJson(peer));
        }
        try json.endObject();

        try json.objectField("peers_removed");
        try json.beginArray();
        if (!full_update) {
            if (prev_snapshot) |prev| {
                var iter = prev.peer_hashes.iterator();
                while (iter.next()) |entry| {
                    if (!current_hashes.contains(entry.key_ptr.*)) {
                        try json.write(entry.key_ptr.*);
                    }
                }
            }
        }
        try json.endArray();

        try json.objectField("show_flags");
        try json.write(true);
        try json.endObject();
        self.storeSnapshot(response_rid, torrent_hash, peers);
        return out.toOwnedSlice();
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
        peers: anytype,
    ) void {
        if (torrent_hash.len != 40) return;
        const slot = rid % max_snapshots;
        if (self.snapshots[slot]) |*old| old.deinit();

        var hash_buf: [40]u8 = undefined;
        @memcpy(&hash_buf, torrent_hash[0..40]);

        var peer_hashes = std.StringHashMap(u64).init(self.allocator);
        for (peers) |peer| {
            const key = peerKeyAlloc(self.allocator, peer) catch continue;
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

fn peerHash(peer: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(peer.ip);
    hasher.update(std.mem.asBytes(&peer.port));
    hasher.update(peer.state);
    hasher.update(peer.mode);
    hasher.update(peer.transport);
    hasher.update(peer.client);
    hasher.update(peer.flags);
    hasher.update(std.mem.asBytes(&peer.dl_speed));
    hasher.update(std.mem.asBytes(&peer.ul_speed));
    hasher.update(std.mem.asBytes(&peer.downloaded));
    hasher.update(std.mem.asBytes(&peer.uploaded));
    hasher.update(std.mem.asBytes(&peer.progress));
    hasher.update(std.mem.asBytes(&peer.upload_only));
    hasher.update(std.mem.asBytes(&peer.hashfails));
    hasher.update(std.mem.asBytes(&peer.availability_known));
    hasher.update(std.mem.asBytes(&peer.availability_count));
    hasher.update(std.mem.asBytes(&peer.availability_pieces));
    hasher.update(std.mem.asBytes(&peer.current_piece));
    hasher.update(std.mem.asBytes(&peer.next_piece));
    hasher.update(std.mem.asBytes(&peer.inflight_requests));
    hasher.update(std.mem.asBytes(&peer.request_target_depth));
    hasher.update(std.mem.asBytes(&peer.request_age_secs));
    hasher.update(std.mem.asBytes(&peer.last_piece_age_secs));
    hasher.update(std.mem.asBytes(&peer.pipeline_sent));
    hasher.update(std.mem.asBytes(&peer.next_pipeline_sent));
    hasher.update(std.mem.asBytes(&peer.blocks_received));
    hasher.update(std.mem.asBytes(&peer.blocks_expected));
    hasher.update(std.mem.asBytes(&peer.send_pending));
    hasher.update(std.mem.asBytes(&peer.recv_pending));
    hasher.update(std.mem.asBytes(&peer.connect_pending));
    hasher.update(std.mem.asBytes(&peer.peer_choking));
    hasher.update(std.mem.asBytes(&peer.am_interested));
    hasher.update(std.mem.asBytes(&peer.extensions_supported));
    hasher.update(std.mem.asBytes(&peer.utp_cwnd));
    hasher.update(std.mem.asBytes(&peer.utp_bytes_in_flight));
    hasher.update(std.mem.asBytes(&peer.utp_out_buf_count));
    hasher.update(std.mem.asBytes(&peer.utp_pending_send_bytes));
    hasher.update(std.mem.asBytes(&peer.utp_rto_us));
    return hasher.final();
}

fn peerKeyAlloc(allocator: std.mem.Allocator, peer: anytype) ![]u8 {
    if (std.mem.indexOfScalar(u8, peer.ip, ':') != null and !std.mem.startsWith(u8, peer.ip, "[")) {
        return std.fmt.allocPrint(allocator, "[{s}]:{}", .{ peer.ip, peer.port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{}", .{ peer.ip, peer.port });
}

const PeerJson = struct {
    client: []const u8,
    connection: []const u8 = "",
    country: []const u8 = "",
    country_code: []const u8 = "",
    dl_speed: u64,
    downloaded: u64,
    files: []const u8 = "",
    flags: []const u8,
    flags_desc: []const u8 = "",
    hashfails: u8,
    ip: []const u8,
    port: u16,
    progress: f64,
    relevance: u8 = 1,
    up_speed: u64,
    uploaded: u64,
    upload_only: bool,
    state: []const u8,
    mode: []const u8,
    transport: []const u8,
    availability_known: bool,
    availability_count: u32,
    availability_pieces: u32,
    current_piece: ?u32,
    next_piece: ?u32,
    inflight_requests: u32,
    request_target_depth: u32,
    request_age_secs: i64,
    last_piece_age_secs: i64,
    pipeline_sent: u32,
    next_pipeline_sent: u32,
    blocks_received: u32,
    blocks_expected: u32,
    send_pending: bool,
    recv_pending: bool,
    connect_pending: bool,
    peer_choking: bool,
    am_interested: bool,
    extensions_supported: bool,
    utp_cwnd: u32,
    utp_bytes_in_flight: u32,
    utp_out_buf_count: u16,
    utp_pending_send_bytes: u32,
    utp_rto_us: u32,
};

fn peerJson(peer: anytype) PeerJson {
    return .{
        .client = peer.client,
        .dl_speed = peer.dl_speed,
        .downloaded = peer.downloaded,
        .flags = peer.flags,
        .hashfails = peer.hashfails,
        .ip = peer.ip,
        .port = peer.port,
        .progress = peer.progress,
        .up_speed = peer.ul_speed,
        .uploaded = peer.uploaded,
        .upload_only = peer.upload_only,
        .state = peer.state,
        .mode = peer.mode,
        .transport = peer.transport,
        .availability_known = peer.availability_known,
        .availability_count = peer.availability_count,
        .availability_pieces = peer.availability_pieces,
        .current_piece = peer.current_piece,
        .next_piece = peer.next_piece,
        .inflight_requests = peer.inflight_requests,
        .request_target_depth = peer.request_target_depth,
        .request_age_secs = peer.request_age_secs,
        .last_piece_age_secs = peer.last_piece_age_secs,
        .pipeline_sent = peer.pipeline_sent,
        .next_pipeline_sent = peer.next_pipeline_sent,
        .blocks_received = peer.blocks_received,
        .blocks_expected = peer.blocks_expected,
        .send_pending = peer.send_pending,
        .recv_pending = peer.recv_pending,
        .connect_pending = peer.connect_pending,
        .peer_choking = peer.peer_choking,
        .am_interested = peer.am_interested,
        .extensions_supported = peer.extensions_supported,
        .utp_cwnd = peer.utp_cwnd,
        .utp_bytes_in_flight = peer.utp_bytes_in_flight,
        .utp_out_buf_count = peer.utp_out_buf_count,
        .utp_pending_send_bytes = peer.utp_pending_send_bytes,
        .utp_rto_us = peer.utp_rto_us,
    };
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

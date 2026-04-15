const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const Stats = @import("torrent_session.zig").Stats;
const TorrentState = @import("torrent_session.zig").State;
const categories_mod = @import("categories.zig");
pub const CategoryStore = categories_mod.CategoryStore;
pub const TagStore = categories_mod.TagStore;
pub const QueueManager = @import("queue_manager.zig").QueueManager;
pub const QueueConfig = @import("queue_manager.zig").QueueConfig;
const ResumeDb = @import("../storage/state_db.zig").ResumeDb;
const BanList = @import("../net/ban_list.zig").BanList;
const TrackerExecutor = @import("tracker_executor.zig").TrackerExecutor;
const UdpTrackerExecutor = @import("udp_tracker_executor.zig").UdpTrackerExecutor;

/// Manages multiple torrent sessions for the daemon.
/// Thread-safe: the API server and event loop can access concurrently.
const EventLoop = @import("../io/event_loop.zig").EventLoop;

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    sessions: std.StringHashMap(*TorrentSession),
    shared_event_loop: ?*EventLoop = null,
    default_save_path: []const u8 = "/tmp/varuna-downloads",
    port: u16 = 6881,
    max_peers: u32 = 50,
    hasher_threads: u32 = 4,
    resume_db_path: ?[*:0]const u8 = null,
    /// Masquerade as a different client for peer ID generation (e.g. "qBittorrent 5.1.4").
    masquerade_as: ?[]const u8 = null,
    /// Disable tracker announces; rely on DHT/PEX for peer discovery.
    disable_trackers: bool = false,

    // ── Global share ratio / seeding time limits ──────────
    /// Whether global ratio limit enforcement is enabled.
    max_ratio_enabled: bool = false,
    /// Target share ratio. -1 = disabled.
    max_ratio: f64 = -1.0,
    /// Action when limit reached: 0 = pause, 1 = remove.
    max_ratio_act: u8 = 0,
    /// Whether global seeding time limit enforcement is enabled.
    max_seeding_time_enabled: bool = false,
    /// Maximum minutes to seed after completion. -1 = disabled.
    max_seeding_time: i64 = -1,

    /// In-memory category and tag stores.
    category_store: CategoryStore,
    tag_store: TagStore,

    /// Queue manager for controlling how many torrents are active.
    queue_manager: QueueManager,
    /// Torrents currently being relocated by setLocation().
    relocating_torrents: std.AutoHashMap([40]u8, void),

    /// Shared resume DB for category/tag persistence. Opened once, shared
    /// with all sessions. null if no resume_db_path is configured.
    resume_db: ?ResumeDb = null,

    /// Shared ban list for peer IP filtering. Owned by SessionManager,
    /// shared with EventLoop (read-only ban checks) and API handlers (mutations).
    ban_list: ?*BanList = null,

    /// Shared tracker executor for daemon-side announces and scrapes.
    tracker_executor: ?*TrackerExecutor = null,

    /// Shared UDP tracker executor for daemon-side UDP announces and scrapes (BEP 15).
    udp_tracker_executor: ?*UdpTrackerExecutor = null,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*TorrentSession).init(allocator),
            .category_store = CategoryStore.init(allocator),
            .tag_store = TagStore.init(allocator),
            .queue_manager = QueueManager.init(allocator),
            .relocating_torrents = std.AutoHashMap([40]u8, void).init(allocator),
        };
    }

    /// Open the resume DB and load persisted categories and tags into
    /// the in-memory stores. Call after setting resume_db_path and before
    /// accepting API requests.
    pub fn loadCategoriesAndTags(self: *SessionManager) void {
        const db_path = self.resume_db_path orelse return;
        var db = ResumeDb.open(db_path) catch return;

        // Load categories
        if (db.loadCategories(self.allocator)) |cats| {
            for (cats) |cat| {
                self.category_store.create(cat.name, cat.save_path) catch {};
                // create() dupes the strings, so free the DB copies
                self.allocator.free(cat.name);
                self.allocator.free(cat.save_path);
            }
            self.allocator.free(cats);
        } else |_| {}

        // Load global tags
        if (db.loadGlobalTags(self.allocator)) |tags| {
            for (tags) |tag| {
                self.tag_store.create(tag) catch {};
                self.allocator.free(tag);
            }
            self.allocator.free(tags);
        } else |_| {}

        self.resume_db = db;

        // Load queue positions from SQLite
        self.queue_manager.loadFromDb(&db);

        // Load ban list from SQLite
        self.loadBanList();
    }

    /// Enable or disable DHT at runtime. If no engine was created at startup,
    /// toggling remains a no-op.
    pub fn setDhtEnabled(self: *SessionManager, enabled: bool) void {
        const el = self.shared_event_loop orelse return;
        const engine = el.dht_engine orelse return;
        engine.enabled = enabled;
    }

    pub fn deinit(self: *SessionManager) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
        self.category_store.deinit();
        self.tag_store.deinit();
        self.queue_manager.deinit();
        self.relocating_torrents.deinit();
        if (self.ban_list) |bl| {
            bl.deinit();
            self.allocator.destroy(bl);
        }
        if (self.tracker_executor) |executor| {
            executor.destroy();
            self.tracker_executor = null;
        }
        if (self.udp_tracker_executor) |executor| {
            executor.destroy();
            self.udp_tracker_executor = null;
        }
        if (self.resume_db) |*db| db.close();
    }

    /// Add a torrent from raw .torrent bytes.
    pub fn addTorrent(
        self: *SessionManager,
        torrent_bytes: []const u8,
        save_path: []const u8,
    ) !*TorrentSession {
        const session = try self.allocator.create(TorrentSession);
        errdefer self.allocator.destroy(session);

        session.* = try TorrentSession.create(self.allocator, torrent_bytes, save_path, self.masquerade_as);
        errdefer session.deinit();

        try self.configureManagedSession(session);
        return try self.registerSession(session);
    }

    /// Add a torrent from a magnet URI (BEP 9).
    /// Metadata will be fetched from peers before the download begins.
    pub fn addMagnet(
        self: *SessionManager,
        magnet_uri: []const u8,
        save_path: []const u8,
    ) !*TorrentSession {
        const session = try self.allocator.create(TorrentSession);
        errdefer self.allocator.destroy(session);

        session.* = try TorrentSession.createFromMagnet(self.allocator, magnet_uri, save_path, self.masquerade_as);
        errdefer session.deinit();

        try self.configureManagedSession(session);
        return try self.registerSession(session);
    }

    fn configureManagedSession(self: *SessionManager, session: *TorrentSession) !void {
        session.port = self.port;
        session.max_peers = self.max_peers;
        session.hasher_threads = self.hasher_threads;
        session.resume_db_path = self.resume_db_path;
        session.shared_event_loop = self.shared_event_loop orelse return error.SharedEventLoopNotConfigured;
        session.tracker_executor = try self.ensureTrackerExecutor();
        session.udp_tracker_executor = try self.ensureUdpTrackerExecutor();
        session.disable_trackers = self.disable_trackers;
    }

    fn registerSession(self: *SessionManager, session: *TorrentSession) !*TorrentSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(&session.info_hash_hex)) |_| {
            return error.TorrentAlreadyExists;
        }

        try self.sessions.put(&session.info_hash_hex, session);
        _ = self.queue_manager.addTorrent(session.info_hash_hex) catch 0;

        if (self.queue_manager.config.enabled and
            !self.queue_manager.shouldBeActive(session.info_hash_hex, &self.sessions))
        {
            session.state = .queued;
        } else {
            session.start();
        }

        self.persistQueuePositionsLocked();
        return session;
    }

    /// Remove a torrent by info hash hex string.
    pub fn removeTorrent(self: *SessionManager, hash: []const u8) !void {
        return self.removeTorrentEx(hash, false);
    }

    /// Remove a torrent with optional file deletion.
    /// When delete_files is true, removes all data files and empty parent
    /// directories under the torrent's save_path.
    pub fn removeTorrentEx(self: *SessionManager, hash: []const u8, delete_files: bool) !void {
        self.mutex.lock();

        if (hash.len == 40) {
            var hash_buf: [40]u8 = undefined;
            @memcpy(&hash_buf, hash[0..40]);
            if (self.relocating_torrents.contains(hash_buf)) {
                self.mutex.unlock();
                return error.TorrentBusy;
            }
        }

        const kv = self.sessions.fetchRemove(hash) orelse {
            self.mutex.unlock();
            return error.TorrentNotFound;
        };
        var session = kv.value;

        // Remove from queue
        self.queue_manager.removeTorrent(session.info_hash_hex);

        // Grab info we need before deinit
        const save_path = self.allocator.dupe(u8, session.save_path) catch {
            self.mutex.unlock();
            session.stop();
            session.deinit();
            self.allocator.destroy(session);
            return;
        };
        defer self.allocator.free(save_path);

        const info_hash = session.info_hash;

        // Get file paths if we need to delete files
        const file_paths: ?[]const []const u8 = if (delete_files) blk: {
            if (session.session) |*sess| {
                var paths = std.ArrayList([]const u8).empty;
                for (sess.metainfo.files) |file| {
                    var name_len: usize = 0;
                    for (file.path, 0..) |component, ci| {
                        if (ci > 0) name_len += 1;
                        name_len += component.len;
                    }
                    const name_buf = self.allocator.alloc(u8, name_len) catch continue;
                    var pos: usize = 0;
                    for (file.path, 0..) |component, ci| {
                        if (ci > 0) {
                            name_buf[pos] = '/';
                            pos += 1;
                        }
                        @memcpy(name_buf[pos..][0..component.len], component);
                        pos += component.len;
                    }
                    paths.append(self.allocator, name_buf) catch {
                        self.allocator.free(name_buf);
                        continue;
                    };
                }
                break :blk paths.toOwnedSlice(self.allocator) catch null;
            } else break :blk null;
        } else null;
        defer if (file_paths) |fps| {
            for (fps) |fp| self.allocator.free(fp);
            self.allocator.free(fps);
        };

        // Also get the torrent name for multi-file torrents
        const torrent_name = if (delete_files)
            self.allocator.dupe(u8, session.name) catch null
        else
            null;
        defer if (torrent_name) |tn| self.allocator.free(tn);

        self.mutex.unlock();

        // Stop and clean up the session
        session.stop();
        session.deinit();
        self.allocator.destroy(session);

        // Clean up resume DB entries for this torrent
        if (self.resume_db) |*db| {
            db.clearTorrent(info_hash) catch {};
            db.clearRateLimits(info_hash) catch {};
            db.clearShareLimits(info_hash) catch {};
            db.clearTorrentTags(info_hash) catch {};
            db.saveTorrentCategory(info_hash, "") catch {};
        }

        // Delete data files if requested
        if (delete_files) {
            if (file_paths) |fps| {
                for (fps) |relative_path| {
                    // Build full path: save_path/name/relative_path (multi-file)
                    // or save_path/relative_path (single-file)
                    var path_buf: [4096]u8 = undefined;
                    const full_path = if (torrent_name) |tn|
                        std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ save_path, tn, relative_path }) catch continue
                    else
                        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ save_path, relative_path }) catch continue;

                    std.fs.deleteFileAbsolute(full_path) catch {};
                }
            }

            // Clean up empty directories (bottom-up)
            cleanupEmptyDirs(save_path, torrent_name);
        }

        // A slot may have opened up -- start queued torrents if applicable
        self.runQueueEnforcement();
        self.persistQueuePositions();
    }

    // ── Ban list management ──────────────────────────────

    /// Initialize the ban list and load persisted bans from SQLite.
    fn loadBanList(self: *SessionManager) void {
        const bl = self.allocator.create(BanList) catch return;
        bl.* = BanList.init(self.allocator);

        // Load individual bans
        if (self.resume_db) |*db| {
            if (db.loadBannedIps(self.allocator)) |bans| {
                defer {
                    for (bans) |item| {
                        self.allocator.free(item.address);
                        if (item.reason) |r| self.allocator.free(r);
                    }
                    self.allocator.free(bans);
                }
                for (bans) |item| {
                    const source: BanList.BanSource = if (item.source == 1) .ipfilter else .manual;
                    _ = bl.banIpStr(item.address, item.reason, source, item.created_at) catch continue;
                }
            } else |_| {}

            // Load ranges
            if (db.loadBannedRanges(self.allocator)) |ranges| {
                defer {
                    for (ranges) |item| {
                        self.allocator.free(item.start_addr);
                        self.allocator.free(item.end_addr);
                    }
                    self.allocator.free(ranges);
                }
                for (ranges) |item| {
                    const source: BanList.BanSource = if (item.source == 1) .ipfilter else .manual;
                    const range_str_buf = std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ item.start_addr, item.end_addr }) catch continue;
                    defer self.allocator.free(range_str_buf);
                    if (BanList.parseRange(range_str_buf)) |range| {
                        switch (range) {
                            .v4 => |r| bl.banRangeV4(r.start, r.end, source) catch {},
                            .v6 => |r| bl.banRangeV6(r.start, r.end, source) catch {},
                        }
                    }
                }
            } else |_| {}
        }

        self.ban_list = bl;

        // Also set ban list on event loop if already running
        if (self.shared_event_loop) |el| {
            el.ban_list = bl;
        }
    }

    /// Persist the current ban list to SQLite (called from API handlers).
    /// Runs the SQLite operations on the calling thread; since ban changes are
    /// infrequent (user-driven), this is acceptable. For frequent changes, the
    /// ResumeWriter batching pattern could be used.
    pub fn persistBanList(self: *SessionManager) void {
        var db = self.resume_db orelse return;
        const bl = self.ban_list orelse return;

        // Clear existing DB entries and re-write all
        db.clearBannedBySource(0) catch {}; // manual
        db.clearBannedBySource(1) catch {}; // ipfilter

        // Save individual bans
        const bans = bl.listBans(self.allocator) catch return;
        defer {
            for (bans) |info| {
                self.allocator.free(info.ip_str);
                if (info.reason) |r| self.allocator.free(r);
            }
            self.allocator.free(bans);
        }
        for (bans) |info| {
            db.saveBannedIp(info.ip_str, @intFromEnum(info.source), info.reason, info.created_at) catch {};
        }

        // Save ranges
        const ranges = bl.listRanges(self.allocator) catch return;
        defer {
            for (ranges) |info| {
                self.allocator.free(info.start_str);
                self.allocator.free(info.end_str);
            }
            self.allocator.free(ranges);
        }
        for (ranges) |info| {
            db.saveBannedRange(info.start_str, info.end_str, @intFromEnum(info.source)) catch {};
        }
    }

    /// Remove empty directories under save_path/torrent_name, bottom-up.
    fn cleanupEmptyDirs(save_path: []const u8, torrent_name: ?[]const u8) void {
        var path_buf: [4096]u8 = undefined;
        const base = if (torrent_name) |tn|
            std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ save_path, tn }) catch return
        else
            save_path;

        // Try to delete the torrent directory (will fail if not empty, which is fine)
        removeEmptyTree(base);
    }

    /// Recursively try to remove empty directories.
    fn removeEmptyTree(path: []const u8) void {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;

        var has_entries = false;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                var sub_buf: [4096]u8 = undefined;
                const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ path, entry.name }) catch {
                    has_entries = true;
                    continue;
                };
                removeEmptyTree(sub_path);
                // Check if sub-dir still exists
                std.fs.accessAbsolute(sub_path, .{}) catch {
                    // sub-dir was removed, don't count it
                    continue;
                };
            }
            has_entries = true;
        }
        dir.close();

        if (!has_entries) {
            std.fs.deleteDirAbsolute(path) catch {};
        }
    }

    /// Pause a torrent.
    pub fn pauseTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.pause();

        // A slot opened up -- start queued torrents if applicable
        self.runQueueEnforcementLocked();
    }

    /// Resume a torrent. If queueing is enabled, the torrent may go to
    /// queued state instead of immediately starting.
    pub fn resumeTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        if (session.state == .queued) {
            // The torrent was queued -- attempt to make it active
            if (self.queue_manager.config.enabled) {
                // Check eligibility BEFORE starting anything to avoid spawning
                // a thread that gets immediately killed.
                if (self.queue_manager.shouldBeActive(session.info_hash_hex, &self.sessions)) {
                    session.state = .paused;
                    session.unpause();
                }
                // else: leave it queued, do not start anything
            } else {
                session.state = .paused;
                session.unpause();
            }
        } else {
            session.unpause();
        }
    }

    /// Get stats for all torrents.
    pub fn getAllStats(self: *SessionManager, allocator: std.mem.Allocator) ![]Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = std.ArrayList(Stats).empty;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            var s = entry.value_ptr.*.getStats();
            s.queue_position = self.queue_manager.getPosition(entry.value_ptr.*.info_hash_hex) orelse 0;
            try stats.append(allocator, s);
        }
        return stats.toOwnedSlice(allocator);
    }

    /// Aggregated global transfer statistics for the /api/v2/transfer/info
    /// and /api/v2/sync/maindata server_state sections.
    pub const TransferInfo = struct {
        dl_speed: u64 = 0,
        ul_speed: u64 = 0,
        dl_data: u64 = 0,
        ul_data: u64 = 0,
        dl_limit: u64 = 0,
        ul_limit: u64 = 0,
        dht_nodes: usize = 0,
    };

    /// Aggregate per-torrent stats and global event loop state into a
    /// single TransferInfo. Avoids duplicate logic in handlers.zig and sync.zig.
    pub fn getTransferInfo(self: *SessionManager, allocator: std.mem.Allocator) !TransferInfo {
        const stats = try self.getAllStats(allocator);
        defer allocator.free(stats);

        var info = TransferInfo{};
        for (stats) |stat| {
            info.dl_speed += stat.download_speed;
            info.ul_speed += stat.upload_speed;
            info.dl_data += stat.bytes_downloaded;
            info.ul_data += stat.bytes_uploaded;
        }

        if (self.shared_event_loop) |el| {
            info.dl_limit = el.getGlobalDlLimit();
            info.ul_limit = el.getGlobalUlLimit();
            info.dht_nodes = el.getDhtNodeCount();
        }

        return info;
    }

    /// Get stats for a single torrent.
    pub fn getStats(self: *SessionManager, hash: []const u8) !Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        var s = session.getStats();
        s.queue_position = self.queue_manager.getPosition(session.info_hash_hex) orelse 0;
        return s;
    }

    /// Toggle sequential download mode for a torrent.
    pub fn setSequentialDownload(self: *SessionManager, hash: []const u8, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.sequential_download = enabled;
        // Propagate to the piece tracker so claimPiece() uses the right strategy.
        session.applySequentialMode();
    }

    /// Set file priority for specific file indices.
    /// priority: 0=skip, 1=normal, 6=high, 7=max
    pub fn setFilePriority(self: *SessionManager, hash: []const u8, file_indices: []const u32, priority: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const meta = if (session.session) |*s| s.metainfo else return error.TorrentNotReady;
        const file_count = meta.files.len;

        // Lazily allocate file_priorities array (default all to 1=normal)
        if (session.file_priorities == null) {
            const fp = try self.allocator.alloc(u8, file_count);
            @memset(fp, 1);
            session.file_priorities = fp;
        }

        const fp = session.file_priorities.?;
        for (file_indices) |idx| {
            if (idx < fp.len) {
                fp[idx] = priority;
            }
        }

        // Rebuild the wanted-piece mask and apply it to the piece tracker
        // so claimPiece() immediately respects the new priorities.
        _ = session.applyFilePriorities();
    }

    /// Enable or disable BEP 16 super-seeding for a torrent.
    pub fn setSuperSeeding(self: *SessionManager, hash: []const u8, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.setSuperSeeding(enabled);
    }

    /// Add tracker URLs to a torrent (user override). Triggers re-announce.
    pub fn addTrackers(self: *SessionManager, hash: []const u8, urls: []const []const u8) !void {
        self.mutex.lock();
        const session = self.sessions.get(hash) orelse {
            self.mutex.unlock();
            return error.TorrentNotFound;
        };
        session.addTrackerUrls(urls) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();

        // Trigger a re-announce on the background thread
        self.forceReannounce(hash) catch {};
    }

    /// Remove tracker URLs from a torrent (user override). Persists removal.
    pub fn removeTrackers(self: *SessionManager, hash: []const u8, urls: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        try session.removeTrackerUrls(urls);
    }

    /// Replace one tracker URL with another (user override). Triggers re-announce.
    pub fn editTracker(self: *SessionManager, hash: []const u8, orig_url: []const u8, new_url: []const u8) !void {
        self.mutex.lock();
        const session = self.sessions.get(hash) orelse {
            self.mutex.unlock();
            return error.TorrentNotFound;
        };
        session.editTrackerUrl(orig_url, new_url) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();

        // Trigger a re-announce on the background thread
        self.forceReannounce(hash) catch {};
    }

    /// Force re-announce to tracker for a torrent.
    pub fn forceReannounce(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        try session.scheduleReannounce();
    }

    fn ensureTrackerExecutor(self: *SessionManager) !*TrackerExecutor {
        if (self.tracker_executor == null) {
            const el = self.shared_event_loop orelse return error.SharedEventLoopNotConfigured;
            self.tracker_executor = try TrackerExecutor.create(self.allocator, &el.ring, .{});
            // Wire into event loop for CQE dispatch
            el.tracker_executor = self.tracker_executor;
        }
        return self.tracker_executor.?;
    }

    fn ensureUdpTrackerExecutor(self: *SessionManager) !*UdpTrackerExecutor {
        if (self.udp_tracker_executor == null) {
            const el = self.shared_event_loop orelse return error.SharedEventLoopNotConfigured;
            self.udp_tracker_executor = try UdpTrackerExecutor.create(self.allocator, &el.ring, .{});
            // Wire into event loop for CQE dispatch
            el.udp_tracker_executor = self.udp_tracker_executor;
        }
        return self.udp_tracker_executor.?;
    }

    /// Force piece recheck for a torrent: stop, recheck, resume.
    pub fn forceRecheck(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        // Stop the session (joins threads, frees runtime state)
        session.stop();
        // Restart it (will recheck from disk)
        session.start();
    }

    // ── Queue management ─────────────────────────────────

    /// Move torrent to top of queue (highest priority).
    pub fn queueTopPrio(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        self.queue_manager.moveToTop(session.info_hash_hex);
        self.runQueueEnforcementLocked();
        self.persistQueuePositionsLocked();
    }

    /// Move torrent to bottom of queue (lowest priority).
    pub fn queueBottomPrio(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        self.queue_manager.moveToBottom(session.info_hash_hex);
        self.runQueueEnforcementLocked();
        self.persistQueuePositionsLocked();
    }

    /// Increase torrent priority (move up in queue).
    pub fn queueIncreasePrio(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        self.queue_manager.increasePriority(session.info_hash_hex);
        self.runQueueEnforcementLocked();
        self.persistQueuePositionsLocked();
    }

    /// Decrease torrent priority (move down in queue).
    pub fn queueDecreasePrio(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        self.queue_manager.decreasePriority(session.info_hash_hex);
        self.runQueueEnforcementLocked();
        self.persistQueuePositionsLocked();
    }

    /// Run queue enforcement: start queued torrents if slots are available.
    /// Called from contexts where the mutex is NOT held.
    pub fn runQueueEnforcement(self: *SessionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.runQueueEnforcementLocked();
    }

    /// Run queue enforcement while the mutex is already held.
    fn runQueueEnforcementLocked(self: *SessionManager) void {
        const result = self.queue_manager.enforce(&self.sessions);

        for (result.to_queue[0..result.queue_count]) |hash| {
            if (self.sessions.get(&hash)) |session| {
                if (session.state == .downloading or session.state == .seeding) {
                    session.pause();
                    session.state = .queued;
                }
            }
        }

        for (result.to_start[0..result.start_count]) |hash| {
            if (self.sessions.get(&hash)) |session| {
                if (session.state == .queued) {
                    session.state = .paused; // so unpause sees .paused
                    session.unpause();
                }
            }
        }
    }

    /// Persist queue positions to SQLite. Acquires mutex.
    fn persistQueuePositions(self: *SessionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.persistQueuePositionsLocked();
    }

    /// Persist queue positions to SQLite. Caller must hold mutex.
    fn persistQueuePositionsLocked(self: *SessionManager) void {
        if (self.resume_db) |*db| {
            self.queue_manager.saveToDb(db);
        }
    }

    /// Load queue positions from the resume DB and apply config.
    /// Call after setting resume_db_path and before accepting API requests.
    pub fn loadQueueState(self: *SessionManager) void {
        if (self.resume_db) |*db| {
            self.queue_manager.loadFromDb(db);
        }
    }

    // ── Category / Tag operations ─────────────────────────

    /// Assign a category to a torrent. Empty string clears the category.
    pub fn setTorrentCategory(self: *SessionManager, hash: []const u8, category_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        // Validate that the category exists (unless clearing)
        if (category_name.len > 0) {
            if (self.category_store.get(category_name) == null) return error.CategoryNotFound;
        }

        // Free old category
        if (session.category) |old| self.allocator.free(old);

        if (category_name.len > 0) {
            session.category = try self.allocator.dupe(u8, category_name);
        } else {
            session.category = null;
        }

        // Persist to DB
        if (self.resume_db) |*db| {
            db.saveTorrentCategory(session.info_hash, category_name) catch {};
        }
    }

    /// Add tags to a torrent. Tags are also registered in the global tag store.
    pub fn addTorrentTags(self: *SessionManager, hash: []const u8, tag_names: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        var iter = std.mem.splitScalar(u8, tag_names, ',');
        while (iter.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " ");
            if (tag.len == 0) continue;

            // Register globally
            try self.tag_store.create(tag);
            if (self.resume_db) |*db| db.saveGlobalTag(tag) catch {};

            // Check if torrent already has this tag
            var found = false;
            for (session.tags.items) |existing| {
                if (std.mem.eql(u8, existing, tag)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const owned = try self.allocator.dupe(u8, tag);
                try session.tags.append(self.allocator, owned);
                if (self.resume_db) |*db| db.saveTorrentTag(session.info_hash, tag) catch {};
            }
        }
        session.rebuildTagsString();
    }

    /// Remove tags from a torrent (does not remove from global tag store).
    pub fn removeTorrentTags(self: *SessionManager, hash: []const u8, tag_names: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        var iter = std.mem.splitScalar(u8, tag_names, ',');
        while (iter.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " ");
            if (tag.len == 0) continue;

            // Find and remove from torrent's tag list
            var i: usize = 0;
            while (i < session.tags.items.len) {
                if (std.mem.eql(u8, session.tags.items[i], tag)) {
                    self.allocator.free(session.tags.items[i]);
                    _ = session.tags.swapRemove(i);
                    if (self.resume_db) |*db| db.removeTorrentTag(session.info_hash, tag) catch {};
                    break;
                }
                i += 1;
            }
        }
        session.rebuildTagsString();
    }

    /// Relocate torrent data to a new path. Pauses the torrent, moves files,
    /// and updates the save_path. The actual file move is done on the calling
    /// thread (which is the RPC handler thread, not the event loop).
    pub fn setLocation(self: *SessionManager, hash: []const u8, new_path: []const u8) !void {
        self.mutex.lock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        if (self.relocating_torrents.contains(session.info_hash_hex)) {
            self.mutex.unlock();
            return error.TorrentBusy;
        }
        try self.relocating_torrents.put(session.info_hash_hex, {});
        const was_active = session.state == .downloading or session.state == .seeding;
        const info_hash_hex = session.info_hash_hex;
        const old_path = try self.allocator.dupe(u8, session.save_path);
        errdefer self.allocator.free(old_path);

        // Pause if active (stop I/O to the files)
        if (was_active) {
            session.pause();
        }
        self.mutex.unlock();
        defer self.allocator.free(old_path);

        // Move files from old save_path to new_path
        moveDataFiles(old_path, new_path) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.relocating_torrents.remove(info_hash_hex);
            if (self.sessions.get(hash)) |live_session| {
                if (was_active and live_session.state != .queued) {
                    live_session.unpause();
                }
            }
            return err;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.relocating_torrents.remove(info_hash_hex);
        const live_session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        // Update save_path
        const owned_new_path = try self.allocator.dupe(u8, new_path);
        self.allocator.free(live_session.save_path);
        live_session.save_path = owned_new_path;

        // Resume if it was active
        if (was_active) {
            live_session.unpause();
        }
    }

    /// Move all files and subdirectories from src to dst using standard fs ops.
    /// This is a one-time operation, not hot-path -- standard I/O is acceptable.
    fn moveDataFiles(src: []const u8, dst: []const u8) !void {
        // Ensure destination directory exists
        std.fs.makeDirAbsolute(dst) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Try rename first (fast path: same filesystem)
        // We need to iterate src and rename each entry
        var dir = std.fs.openDirAbsolute(src, .{ .iterate = true }) catch return error.SourceNotFound;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return error.IterateFailed) |entry| {
            // Build full paths
            var src_buf: [4096]u8 = undefined;
            var dst_buf: [4096]u8 = undefined;

            const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src, entry.name }) catch continue;
            const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ dst, entry.name }) catch continue;

            // Try rename (works if same filesystem)
            std.fs.renameAbsolute(src_path, dst_path) catch {
                // Cross-filesystem: copy + delete
                if (entry.kind == .directory) {
                    // Recursively move subdirectory
                    moveDataFiles(src_path, dst_path) catch continue;
                    std.fs.deleteDirAbsolute(src_path) catch {};
                } else {
                    // Copy file using read/write loop
                    const src_file = std.fs.openFileAbsolute(src_path, .{}) catch continue;
                    defer src_file.close();
                    const dst_file = std.fs.createFileAbsolute(dst_path, .{}) catch continue;
                    defer dst_file.close();

                    var copy_buf: [65536]u8 = undefined;
                    var copy_ok = true;
                    while (true) {
                        const bytes_read = std.posix.read(src_file.handle, &copy_buf) catch {
                            copy_ok = false;
                            break;
                        };
                        if (bytes_read == 0) break;
                        var written: usize = 0;
                        while (written < bytes_read) {
                            const w = std.posix.write(dst_file.handle, copy_buf[written..bytes_read]) catch {
                                copy_ok = false;
                                break;
                            };
                            written += w;
                        }
                        if (!copy_ok) break;
                    }
                    if (copy_ok) {
                        std.fs.deleteFileAbsolute(src_path) catch {};
                    }
                }
            };
        }
    }

    pub fn count(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    /// Set per-torrent download speed limit (bytes/sec). 0 = unlimited.
    /// Persists to SQLite so the limit survives daemon restarts.
    pub fn setTorrentDlLimit(self: *SessionManager, hash: []const u8, limit: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.dl_limit = limit;

        // Apply to event loop if running
        if (self.shared_event_loop) |el| {
            if (session.torrent_id_in_shared) |tid| {
                el.setTorrentDlLimit(tid, limit);
            }
        }

        // Persist to DB
        if (self.resume_db) |*db| {
            db.saveRateLimits(session.info_hash, session.dl_limit, session.ul_limit) catch {};
        }
    }

    /// Set per-torrent upload speed limit (bytes/sec). 0 = unlimited.
    /// Persists to SQLite so the limit survives daemon restarts.
    pub fn setTorrentUlLimit(self: *SessionManager, hash: []const u8, limit: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.ul_limit = limit;

        // Apply to event loop if running
        if (self.shared_event_loop) |el| {
            if (session.torrent_id_in_shared) |tid| {
                el.setTorrentUlLimit(tid, limit);
            }
        }

        // Persist to DB
        if (self.resume_db) |*db| {
            db.saveRateLimits(session.info_hash, session.dl_limit, session.ul_limit) catch {};
        }
    }

    // ── Share limit management ─────────────────────────────

    /// Set per-torrent share limits (ratio and seeding time).
    /// ratio_limit: -2 = use global, -1 = no limit, >=0 = specific ratio.
    /// seeding_time_limit: -2 = use global, -1 = no limit, >=0 = minutes.
    pub fn setShareLimits(self: *SessionManager, hash: []const u8, ratio_limit: f64, seeding_time_limit: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.ratio_limit = ratio_limit;
        session.seeding_time_limit = seeding_time_limit;

        // Persist to DB
        if (self.resume_db) |*db| {
            db.saveShareLimits(session.info_hash, ratio_limit, seeding_time_limit, session.completion_on) catch {};
        }
    }

    /// Check all seeding torrents against share ratio and seeding time limits.
    /// Pauses or removes torrents that exceed their limits.
    /// Called periodically from the main loop (~every 30 seconds).
    /// Returns the number of torrents acted upon.
    pub fn checkShareLimits(self: *SessionManager) u32 {
        self.mutex.lock();

        // Collect hashes of torrents that need action (we can't modify sessions
        // map while iterating, and pauseTorrent/removeTorrent need to lock mutex).
        var to_pause: [64][40]u8 = undefined;
        var to_remove: [64][40]u8 = undefined;
        var pause_count: u32 = 0;
        var remove_count: u32 = 0;

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.state != .seeding) continue;

            const stats = session.getStats();
            const act = self.checkTorrentShareLimit(session, stats);
            switch (act) {
                .none => {},
                .pause => {
                    if (pause_count < to_pause.len) {
                        to_pause[pause_count] = stats.info_hash_hex;
                        pause_count += 1;
                    }
                },
                .remove => {
                    if (remove_count < to_remove.len) {
                        to_remove[remove_count] = stats.info_hash_hex;
                        remove_count += 1;
                    }
                },
            }
        }

        self.mutex.unlock();

        // Apply actions outside the lock
        var acted: u32 = 0;
        for (to_pause[0..pause_count]) |*hash_hex| {
            self.pauseTorrent(hash_hex) catch continue;
            std.log.info("share limit: paused torrent {s}", .{hash_hex});
            acted += 1;
        }
        for (to_remove[0..remove_count]) |*hash_hex| {
            self.removeTorrent(hash_hex) catch continue;
            std.log.info("share limit: removed torrent {s}", .{hash_hex});
            acted += 1;
        }

        return acted;
    }

    const ShareLimitAction = enum { none, pause, remove };

    /// Determine what action (if any) should be taken for a single torrent
    /// based on its effective share limits.
    fn checkTorrentShareLimit(self: *const SessionManager, session: *const TorrentSession, stats: Stats) ShareLimitAction {
        // Determine effective ratio limit for this torrent
        const effective_ratio: f64 = if (session.ratio_limit >= -1.0 and session.ratio_limit != -2.0)
            session.ratio_limit // per-torrent override
        else if (self.max_ratio_enabled and self.max_ratio >= 0.0)
            self.max_ratio // global setting
        else
            -1.0; // disabled

        // Determine effective seeding time limit (in minutes)
        const effective_seeding_time: i64 = if (session.seeding_time_limit >= -1 and session.seeding_time_limit != -2)
            session.seeding_time_limit // per-torrent override
        else if (self.max_seeding_time_enabled and self.max_seeding_time >= 0)
            self.max_seeding_time // global setting
        else
            -1; // disabled

        // Check ratio limit
        if (effective_ratio >= 0.0 and stats.ratio >= effective_ratio) {
            return if (self.max_ratio_act == 1) .remove else .pause;
        }

        // Check seeding time limit (compare seconds vs minutes)
        if (effective_seeding_time >= 0 and stats.seeding_time > 0) {
            const limit_secs = effective_seeding_time * 60;
            if (stats.seeding_time >= limit_secs) {
                return if (self.max_ratio_act == 1) .remove else .pause;
            }
        }

        return .none;
    }

    /// Persist completion_on timestamp for a torrent (called when transitioning to seeding).
    pub fn persistCompletionOn(self: *SessionManager, info_hash: [20]u8, ratio_limit: f64, seeding_time_limit: i64, completion_on: i64) void {
        if (self.resume_db) |*db| {
            db.saveShareLimits(info_hash, ratio_limit, seeding_time_limit, completion_on) catch {};
        }
    }

    // ── Connection diagnostics ─────────────────────────────

    /// Per-torrent connection health diagnostics.
    pub const ConnDiagnostics = struct {
        connection_attempts: u64 = 0,
        connection_failures: u64 = 0,
        timeout_failures: u64 = 0,
        refused_failures: u64 = 0,
        peers_connected: u16 = 0,
        peers_half_open: u16 = 0,
    };

    /// Get connection diagnostics for a torrent.
    pub fn getConnDiagnostics(self: *SessionManager, hash: []const u8) !ConnDiagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        var diag = ConnDiagnostics{};

        // Get peer count from event loop
        if (self.shared_event_loop) |el| {
            if (session.torrent_id_in_shared) |tid| {
                diag.peers_connected = el.peerCountForTorrent(tid);
                diag.peers_half_open = el.halfOpenCount();
            }
        }

        // Get per-torrent connection stats from the session
        diag.connection_attempts = session.conn_attempts;
        diag.connection_failures = session.conn_failures;
        diag.timeout_failures = session.conn_timeout_failures;
        diag.refused_failures = session.conn_refused_failures;

        return diag;
    }

    // ── Thread-safe data accessors for RPC handlers ────────────
    // These methods copy data while holding the mutex so that RPC handlers
    // never hold a raw TorrentSession pointer after the mutex is released.

    /// Per-file information returned by getSessionFiles().
    pub const FileInfo = struct {
        name: []const u8, // owned, caller must free
        size: u64,
        progress: f64,
        priority: u8,
        first_piece: u32,
        last_piece: u32,
    };

    /// Free a FileInfo slice returned by getSessionFiles().
    pub fn freeFileInfos(allocator: std.mem.Allocator, infos: []const FileInfo) void {
        for (infos) |fi| allocator.free(fi.name);
        allocator.free(infos);
    }

    /// Return per-file info for a torrent, copying all data under the mutex.
    pub fn getSessionFiles(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![]const FileInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const sess = session.session orelse return error.TorrentNotReady;
        const meta = sess.metainfo;
        const layout = sess.layout;

        var result = try allocator.alloc(FileInfo, meta.files.len);
        var built: usize = 0;
        errdefer {
            for (result[0..built]) |fi| allocator.free(fi.name);
            allocator.free(result);
        }

        for (meta.files, 0..) |file, i| {
            // Build file name from path components
            var name_len: usize = 0;
            for (file.path, 0..) |component, ci| {
                if (ci > 0) name_len += 1; // separator
                name_len += component.len;
            }
            const name_buf = try allocator.alloc(u8, name_len);
            var pos: usize = 0;
            for (file.path, 0..) |component, ci| {
                if (ci > 0) {
                    name_buf[pos] = '/';
                    pos += 1;
                }
                @memcpy(name_buf[pos..][0..component.len], component);
                pos += component.len;
            }

            // Compute per-file progress while taking the PieceTracker's own lock.
            const layout_file = layout.files[i];
            var file_progress: f64 = 0.0;
            if (session.piece_tracker) |*pt| {
                const total_file_pieces = layout_file.end_piece_exclusive - layout_file.first_piece;
                if (total_file_pieces > 0) {
                    const pieces_complete = pt.countCompleteInRange(layout_file.first_piece, layout_file.end_piece_exclusive);
                    file_progress = @as(f64, @floatFromInt(pieces_complete)) / @as(f64, @floatFromInt(total_file_pieces));
                }
            }

            const priority: u8 = if (session.file_priorities) |fp|
                if (i < fp.len) fp[i] else 1
            else
                1;

            // Piece range from layout (end_piece_exclusive - 1 = last piece index)
            const last_piece: u32 = if (layout_file.end_piece_exclusive > layout_file.first_piece)
                layout_file.end_piece_exclusive - 1
            else
                layout_file.first_piece;

            result[i] = .{
                .name = name_buf,
                .size = file.length,
                .progress = file_progress,
                .priority = priority,
                .first_piece = layout_file.first_piece,
                .last_piece = last_piece,
            };
            built += 1;
        }

        return result;
    }

    /// Tracker information returned by getSessionTrackers().
    pub const TrackerInfo = struct {
        url: []const u8, // owned, caller must free
        status: u8,
        tier: u32,
        num_peers: u16,
        num_seeds: u32,
        num_leeches: u32,
        num_downloaded: u32,
    };

    /// Free a TrackerInfo slice returned by getSessionTrackers().
    pub fn freeTrackerInfos(allocator: std.mem.Allocator, infos: []const TrackerInfo) void {
        for (infos) |ti| allocator.free(ti.url);
        allocator.free(infos);
    }

    /// Return tracker info for a torrent, copying all data under the mutex.
    /// Applies tracker overrides (user-added, removed, edited URLs).
    pub fn getSessionTrackers(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![]const TrackerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const sess = session.session orelse return error.TorrentNotReady;
        const meta = sess.metainfo;
        const stats = session.getStats();
        const overrides = &session.tracker_overrides;

        // Build effective tracker list with overrides applied
        var result_list = std.ArrayList(TrackerInfo).empty;
        errdefer {
            for (result_list.items) |ti| allocator.free(ti.url);
            result_list.deinit(allocator);
        }

        var tier: u32 = 0;

        if (meta.announce) |url| {
            if (!overrides.isRemoved(url)) {
                const effective = overrides.getEdit(url) orelse url;
                const status: u8 = if (session.state == .downloading or session.state == .seeding or session.state == .metadata_fetching) 2 else 1;
                try result_list.append(allocator, .{
                    .url = try allocator.dupe(u8, effective),
                    .status = status,
                    .tier = tier,
                    .num_peers = stats.peers_connected,
                    .num_seeds = stats.scrape_complete,
                    .num_leeches = stats.scrape_incomplete,
                    .num_downloaded = stats.scrape_downloaded,
                });
                tier += 1;
            }
        }

        for (meta.announce_list) |url| {
            if (overrides.isRemoved(url)) continue;
            if (meta.announce) |primary| {
                if (std.mem.eql(u8, url, primary)) continue;
            }
            const effective = overrides.getEdit(url) orelse url;
            // Check not already added (dedup)
            var dup = false;
            for (result_list.items) |existing| {
                if (std.mem.eql(u8, existing.url, effective)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try result_list.append(allocator, .{
                .url = try allocator.dupe(u8, effective),
                .status = 1,
                .tier = tier,
                .num_peers = 0,
                .num_seeds = 0,
                .num_leeches = 0,
                .num_downloaded = 0,
            });
            tier += 1;
        }

        // Add user-added trackers
        for (overrides.added.items) |entry| {
            var dup = false;
            for (result_list.items) |existing| {
                if (std.mem.eql(u8, existing.url, entry.url)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try result_list.append(allocator, .{
                .url = try allocator.dupe(u8, entry.url),
                .status = 1,
                .tier = entry.tier,
                .num_peers = 0,
                .num_seeds = 0,
                .num_leeches = 0,
                .num_downloaded = 0,
            });
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Properties information returned by getSessionProperties().
    pub const PropertiesInfo = struct {
        state: TorrentState,
        total_size: u64,
        pieces_have: u32,
        pieces_total: u32,
        download_speed: u64,
        upload_speed: u64,
        dl_limit: u64,
        ul_limit: u64,
        eta: i64,
        ratio: f64,
        peers_connected: u16,
        added_on: i64,
        bytes_downloaded: u64,
        bytes_uploaded: u64,
        sequential_download: bool,
        is_private: bool,
        super_seeding: bool,
        partial_seed: bool,
        save_path: []const u8, // owned, caller must free
        comment: []const u8, // owned, caller must free
        piece_size: u32,
        info_hash_hex: [40]u8 = [_]u8{'0'} ** 40,
        /// BEP 52: full v2 info-hash (32 bytes). null for pure v1.
        info_hash_v2: ?[32]u8 = null,
        name: []const u8, // owned, caller must free
        created_by: []const u8, // owned, caller must free
        creation_date: ?i64,
        trackers_count: u32,
        web_seeds_count: u32 = 0, // BEP 19 url-list + BEP 17 httpseeds
        /// Tracker scrape: total seeders.
        scrape_complete: u32 = 0,
        /// Tracker scrape: total leechers.
        scrape_incomplete: u32 = 0,
        /// Per-torrent ratio limit (-2 = use global, -1 = no limit, >=0 = specific).
        ratio_limit: f64 = -2.0,
        /// Per-torrent seeding time limit in minutes (-2 = use global, -1 = no limit, >=0 = minutes).
        seeding_time_limit: i64 = -2,
        /// Seeding time in seconds (since completion).
        seeding_time: i64 = 0,
        /// Timestamp when the torrent completed downloading.
        completion_on: i64 = 0,
    };

    /// Free a PropertiesInfo returned by getSessionProperties().
    pub fn freePropertiesInfo(allocator: std.mem.Allocator, info: PropertiesInfo) void {
        allocator.free(info.save_path);
        allocator.free(info.comment);
        allocator.free(info.name);
        allocator.free(info.created_by);
    }

    /// Return torrent properties, copying all data under the mutex.
    pub fn getSessionProperties(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) !PropertiesInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const stats = session.getStats();
        const meta_opt = if (session.session) |*sess| &sess.metainfo else null;
        const comment: []const u8 = if (meta_opt) |m| (m.comment orelse "") else "";
        const piece_size: u32 = if (meta_opt) |m| m.piece_length else 0;
        const created_by: []const u8 = if (meta_opt) |m| (m.created_by orelse "") else "";
        const name = stats.name;

        return .{
            .state = stats.state,
            .total_size = stats.total_size,
            .pieces_have = stats.pieces_have,
            .pieces_total = stats.pieces_total,
            .download_speed = stats.download_speed,
            .upload_speed = stats.upload_speed,
            .dl_limit = stats.dl_limit,
            .ul_limit = stats.ul_limit,
            .eta = stats.eta,
            .ratio = stats.ratio,
            .peers_connected = stats.peers_connected,
            .added_on = stats.added_on,
            .bytes_downloaded = stats.bytes_downloaded,
            .bytes_uploaded = stats.bytes_uploaded,
            .sequential_download = stats.sequential_download,
            .is_private = stats.is_private,
            .super_seeding = stats.super_seeding,
            .partial_seed = stats.partial_seed,
            .save_path = try allocator.dupe(u8, stats.save_path),
            .comment = try allocator.dupe(u8, comment),
            .piece_size = piece_size,
            .info_hash_hex = stats.info_hash_hex,
            .info_hash_v2 = stats.info_hash_v2,
            .name = try allocator.dupe(u8, name),
            .created_by = try allocator.dupe(u8, created_by),
            .creation_date = if (meta_opt) |m| m.creation_date else null,
            .trackers_count = stats.trackers_count,
            .web_seeds_count = if (meta_opt) |m| @intCast(m.url_list.len + m.http_seeds.len) else 0,
            .scrape_complete = stats.scrape_complete,
            .scrape_incomplete = stats.scrape_incomplete,
            .ratio_limit = stats.ratio_limit,
            .seeding_time_limit = stats.seeding_time_limit,
            .seeding_time = stats.seeding_time,
            .completion_on = stats.completion_on,
        };
    }

    /// Return web seed URLs (BEP 19 url-list + BEP 17 httpseeds) for a torrent.
    /// Caller owns the returned slice and each string within it.
    pub fn getWebSeedUrls(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const meta_opt = if (session.session) |*sess| &sess.metainfo else null;
        const meta = meta_opt orelse return try allocator.alloc([]const u8, 0);

        const total = meta.url_list.len + meta.http_seeds.len;
        var urls = try allocator.alloc([]const u8, total);
        errdefer {
            for (urls) |u| allocator.free(u);
            allocator.free(urls);
        }

        var i: usize = 0;
        for (meta.url_list) |url| {
            urls[i] = try allocator.dupe(u8, url);
            i += 1;
        }
        for (meta.http_seeds) |url| {
            urls[i] = try allocator.dupe(u8, url);
            i += 1;
        }

        return urls;
    }

    /// Set global download speed limit (bytes/sec). 0 = unlimited.
    pub fn setGlobalDlLimit(self: *SessionManager, limit: u64) void {
        if (self.shared_event_loop) |el| {
            el.setGlobalDlLimit(limit);
        }
    }

    /// Set global upload speed limit (bytes/sec). 0 = unlimited.
    pub fn setGlobalUlLimit(self: *SessionManager, limit: u64) void {
        if (self.shared_event_loop) |el| {
            el.setGlobalUlLimit(limit);
        }
    }

    /// Rename a torrent (update its display name).
    pub fn renameTorrent(self: *SessionManager, hash: []const u8, new_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const owned_name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(session.name);
        session.name = owned_name;
    }

    /// Toggle sequential download mode for a torrent (flip current value).
    pub fn toggleSequentialDownload(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.sequential_download = !session.sequential_download;
        session.applySequentialMode();
    }

    /// Force-start a torrent, bypassing queue limits.
    pub fn forceStartTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;

        if (session.state == .queued) {
            session.state = .paused;
            session.unpause();
        } else if (session.state == .paused or session.state == .stopped) {
            session.unpause();
        }
        // If already downloading/seeding, no-op.
    }

    /// Get piece states for a torrent: 0=not downloaded, 1=downloading, 2=downloaded.
    pub fn getPieceStates(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        if (session.session == null) return error.TorrentNotReady;

        const piece_count = session.piece_count;
        if (piece_count == 0) return try allocator.alloc(u8, 0);

        var states = try allocator.alloc(u8, piece_count);
        @memset(states, 0);

        if (session.piece_tracker) |*pt| {
            var i: u32 = 0;
            while (i < piece_count) : (i += 1) {
                if (pt.complete.has(i)) {
                    states[i] = 2;
                } else if (pt.in_progress.has(i)) {
                    states[i] = 1;
                }
            }
        }

        return states;
    }

    /// Get piece hashes as hex-encoded strings for a torrent.
    pub fn getPieceHashes(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const sess = session.session orelse return error.TorrentNotReady;
        const meta = sess.metainfo;

        if (meta.pieces.len == 0) return try allocator.alloc([]const u8, 0);

        const piece_count = meta.pieces.len / 20;
        var hashes = try allocator.alloc([]const u8, piece_count);
        var built: usize = 0;
        errdefer {
            for (hashes[0..built]) |h| allocator.free(h);
            allocator.free(hashes);
        }

        var i: usize = 0;
        while (i < piece_count) : (i += 1) {
            const piece_hash = meta.pieces[i * 20 ..][0..20];
            const hex_arr = std.fmt.bytesToHex(piece_hash, .lower);
            const hex = try allocator.dupe(u8, &hex_arr);
            hashes[built] = hex;
            built += 1;
        }

        return hashes;
    }

    /// Add manually-specified peers to a torrent.
    /// peers_str is comma-separated "IP:port" entries.
    pub fn addManualPeers(self: *SessionManager, hash: []const u8, peers_str: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const el = self.shared_event_loop orelse return;
        const tid = session.torrent_id_in_shared orelse return;

        var iter = std.mem.splitScalar(u8, peers_str, ',');
        while (iter.next()) |peer_str| {
            const trimmed = std.mem.trim(u8, peer_str, " \t\r\n");
            if (trimmed.len == 0) continue;

            // Parse IP:port
            const addr = parseIpPort(trimmed) orelse continue;
            _ = el.addPeerAutoTransport(addr, tid) catch continue;
        }
    }

    /// Parse an "IP:port" string into a std.net.Address.
    pub fn parseIpPort(str: []const u8) ?std.net.Address {
        // Find the last ':' for port separator
        const colon = std.mem.lastIndexOfScalar(u8, str, ':') orelse return null;
        if (colon == 0 or colon + 1 >= str.len) return null;

        const ip_str = str[0..colon];
        const port_str = str[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return null;

        return std.net.Address.parseIp4(ip_str, port) catch
            std.net.Address.parseIp6(ip_str, port) catch return null;
    }

    /// Peer information returned by getTorrentPeers().
    pub const PeerInfo = struct {
        /// IP:port string, owned by caller.
        ip: []const u8,
        port: u16,
        /// Peer client identification string (from peer ID convention).
        client: []const u8,
        /// Connection flags: D=downloading, U=uploading, d=interested, u=peer interested,
        /// E=encrypted, X=extension protocol, I=incoming, O=outbound, u=uTP.
        flags: []const u8,
        dl_speed: u64,
        ul_speed: u64,
        downloaded: u64,
        uploaded: u64,
        /// Peer progress (0.0-1.0).
        progress: f64,
        /// BEP 21: peer is a partial seed (upload_only).
        upload_only: bool = false,
    };

    pub fn freePeerInfos(allocator: std.mem.Allocator, infos: []const PeerInfo) void {
        for (infos) |pi| {
            allocator.free(pi.ip);
            allocator.free(pi.client);
            allocator.free(pi.flags);
        }
        allocator.free(infos);
    }

    /// Return peer info for a torrent, copying all data under the mutex.
    pub fn getTorrentPeers(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![]const PeerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        // Get the event loop and torrent ID
        const el = session.shared_event_loop orelse return try allocator.alloc(PeerInfo, 0);
        const tid = session.torrent_id_in_shared orelse return try allocator.alloc(PeerInfo, 0);

        var result = std.ArrayList(PeerInfo).empty;
        errdefer {
            for (result.items) |pi| {
                allocator.free(pi.ip);
                allocator.free(pi.client);
                allocator.free(pi.flags);
            }
            result.deinit(allocator);
        }

        for (el.peers) |*peer| {
            if (peer.state == .free) continue;
            if (peer.torrent_id != tid) continue;

            // Format IP address
            const ip_str = try std.fmt.allocPrint(allocator, "{any}", .{peer.address});
            errdefer allocator.free(ip_str);

            const port: u16 = peer.address.getPort();

            // Build flags string
            var flags_buf: [16]u8 = undefined;
            var fpos: usize = 0;
            if (!peer.peer_choking and peer.am_interested) {
                flags_buf[fpos] = 'D';
                fpos += 1;
            }
            if (!peer.am_choking and peer.peer_interested) {
                flags_buf[fpos] = 'U';
                fpos += 1;
            }
            if (peer.am_interested) {
                flags_buf[fpos] = 'd';
                fpos += 1;
            }
            if (peer.peer_interested) {
                flags_buf[fpos] = 'u';
                fpos += 1;
            }
            if (peer.crypto.isEncrypted()) {
                flags_buf[fpos] = 'E';
                fpos += 1;
            }
            if (peer.extensions_supported) {
                flags_buf[fpos] = 'X';
                fpos += 1;
            }
            if (peer.transport == .utp) {
                flags_buf[fpos] = 'P'; // uTP protocol
                fpos += 1;
            }
            const flags_str = try allocator.dupe(u8, flags_buf[0..fpos]);
            errdefer allocator.free(flags_str);

            // Peer progress from bitfield
            const progress: f64 = if (peer.availability) |*bf| blk: {
                const total_pieces = bf.piece_count;
                if (total_pieces == 0) break :blk 0.0;
                break :blk @as(f64, @floatFromInt(bf.count)) / @as(f64, @floatFromInt(total_pieces));
            } else 0.0;

            // Client ID from peer handshake peer ID
            const peer_id_mod = @import("../net/peer_id.zig");
            const client_str = if (peer.has_peer_id)
                peer_id_mod.peerIdToClientName(allocator, &peer.remote_peer_id) catch try allocator.dupe(u8, "")
            else
                try allocator.dupe(u8, "");

            try result.append(allocator, .{
                .ip = ip_str,
                .port = port,
                .client = client_str,
                .flags = flags_str,
                .dl_speed = peer.current_dl_speed,
                .ul_speed = peer.current_ul_speed,
                .downloaded = peer.bytes_downloaded_from,
                .uploaded = peer.bytes_uploaded_to,
                .progress = progress,
                .upload_only = peer.upload_only,
            });
        }

        return result.toOwnedSlice(allocator);
    }
};

test "session manager add and list" {
    // This test needs io_uring for PieceStore, so skip if unavailable
    var ring = std.os.linux.IoUring.init(4, 0) catch return error.SkipZigTest;
    ring.deinit();
}

test "checkTorrentShareLimit ratio enforcement" {
    var sm = SessionManager.init(std.testing.allocator);
    defer sm.deinit();

    // Global ratio limit: 2.0, action = pause
    sm.max_ratio_enabled = true;
    sm.max_ratio = 2.0;
    sm.max_ratio_act = 0;

    // Simulated torrent session with no per-torrent override
    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .torrent_bytes = &.{},
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "test",
        .total_size = 1000,
        .piece_count = 10,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
    };

    // Ratio below limit: no action
    var stats = Stats{ .state = .seeding, .progress = 1.0, .ratio = 1.5, .seeding_time = 0 };
    try std.testing.expectEqual(SessionManager.ShareLimitAction.none, sm.checkTorrentShareLimit(&session, stats));

    // Ratio at limit: should pause
    stats.ratio = 2.0;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.pause, sm.checkTorrentShareLimit(&session, stats));

    // Ratio above limit: should pause
    stats.ratio = 3.0;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.pause, sm.checkTorrentShareLimit(&session, stats));

    // Change action to remove
    sm.max_ratio_act = 1;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.remove, sm.checkTorrentShareLimit(&session, stats));
}

test "checkTorrentShareLimit seeding time enforcement" {
    var sm = SessionManager.init(std.testing.allocator);
    defer sm.deinit();

    // Global seeding time limit: 60 minutes, action = pause
    sm.max_seeding_time_enabled = true;
    sm.max_seeding_time = 60;
    sm.max_ratio_act = 0;

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .torrent_bytes = &.{},
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "test",
        .total_size = 1000,
        .piece_count = 10,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
    };

    // Seeding time below limit: no action
    var stats = Stats{ .state = .seeding, .progress = 1.0, .ratio = 0.5, .seeding_time = 30 * 60 }; // 30 min
    try std.testing.expectEqual(SessionManager.ShareLimitAction.none, sm.checkTorrentShareLimit(&session, stats));

    // Seeding time at limit: should pause (60 min = 3600 sec)
    stats.seeding_time = 60 * 60;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.pause, sm.checkTorrentShareLimit(&session, stats));

    // Seeding time above limit
    stats.seeding_time = 90 * 60;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.pause, sm.checkTorrentShareLimit(&session, stats));
}

test "checkTorrentShareLimit per-torrent override" {
    var sm = SessionManager.init(std.testing.allocator);
    defer sm.deinit();

    // Global ratio limit: 2.0
    sm.max_ratio_enabled = true;
    sm.max_ratio = 2.0;
    sm.max_ratio_act = 0;

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .torrent_bytes = &.{},
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "test",
        .total_size = 1000,
        .piece_count = 10,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
    };

    // Per-torrent override: ratio_limit = 5.0 (higher than global)
    session.ratio_limit = 5.0;

    // Ratio 3.0 exceeds global (2.0) but not per-torrent (5.0): no action
    var stats = Stats{ .state = .seeding, .progress = 1.0, .ratio = 3.0, .seeding_time = 0 };
    try std.testing.expectEqual(SessionManager.ShareLimitAction.none, sm.checkTorrentShareLimit(&session, stats));

    // Ratio 5.0 meets per-torrent limit: should pause
    stats.ratio = 5.0;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.pause, sm.checkTorrentShareLimit(&session, stats));

    // Per-torrent override: -1 = no limit (disables even global)
    session.ratio_limit = -1.0;
    stats.ratio = 100.0;
    try std.testing.expectEqual(SessionManager.ShareLimitAction.none, sm.checkTorrentShareLimit(&session, stats));
}

test "checkTorrentShareLimit disabled by default" {
    var sm = SessionManager.init(std.testing.allocator);
    defer sm.deinit();

    // Both limits disabled (default)
    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .torrent_bytes = &.{},
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "test",
        .total_size = 1000,
        .piece_count = 10,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
    };

    // Even with high ratio and long seeding time, no action
    const stats = Stats{ .state = .seeding, .progress = 1.0, .ratio = 100.0, .seeding_time = 999999 };
    try std.testing.expectEqual(SessionManager.ShareLimitAction.none, sm.checkTorrentShareLimit(&session, stats));
}

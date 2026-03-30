const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const Stats = @import("torrent_session.zig").Stats;
const categories_mod = @import("categories.zig");
pub const CategoryStore = categories_mod.CategoryStore;
pub const TagStore = categories_mod.TagStore;
const ResumeDb = @import("../storage/resume.zig").ResumeDb;

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

    /// In-memory category and tag stores.
    category_store: CategoryStore,
    tag_store: TagStore,

    /// Shared resume DB for category/tag persistence. Opened once, shared
    /// with all sessions. null if no resume_db_path is configured.
    resume_db: ?ResumeDb = null,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*TorrentSession).init(allocator),
            .category_store = CategoryStore.init(allocator),
            .tag_store = TagStore.init(allocator),
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

        session.* = try TorrentSession.create(self.allocator, torrent_bytes, save_path);
        errdefer session.deinit();

        session.port = self.port;
        session.max_peers = self.max_peers;
        session.hasher_threads = self.hasher_threads;
        session.resume_db_path = self.resume_db_path;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check for duplicate -- use pointer to session's stable memory
        if (self.sessions.get(&session.info_hash_hex)) |_| {
            session.deinit();
            self.allocator.destroy(session);
            return error.TorrentAlreadyExists;
        }

        try self.sessions.put(&session.info_hash_hex, session);

        // Auto-start (with shared event loop if available)
        session.startWithEventLoop(self.shared_event_loop);

        return session;
    }

    /// Remove a torrent by info hash hex string.
    pub fn removeTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const kv = self.sessions.fetchRemove(hash) orelse return error.TorrentNotFound;
        var session = kv.value;
        session.stop();
        session.deinit();
        self.allocator.destroy(session);
    }

    /// Pause a torrent.
    pub fn pauseTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.pause();
    }

    /// Resume a torrent.
    pub fn resumeTorrent(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        session.resume_session();
    }

    /// Get stats for all torrents.
    pub fn getAllStats(self: *SessionManager, allocator: std.mem.Allocator) ![]Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = std.ArrayList(Stats).empty;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try stats.append(allocator, entry.value_ptr.*.getStats());
        }
        return stats.toOwnedSlice(allocator);
    }

    /// Get stats for a single torrent.
    pub fn getStats(self: *SessionManager, hash: []const u8) !Stats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        return session.getStats();
    }

    /// Get direct access to a TorrentSession by hash. Caller must not store the pointer
    /// beyond the scope of a single request (the session could be removed concurrently).
    pub fn getSession(self: *SessionManager, hash: []const u8) !*TorrentSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.sessions.get(hash) orelse error.TorrentNotFound;
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

    /// Force re-announce to tracker for a torrent.
    pub fn forceReannounce(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        // Spawn a background thread to do the announce (blocking HTTP is fine there).
        // Uses the session's shared announce_ring to avoid creating a new ring per announce.
        if (session.announcing.swap(true, .acq_rel)) return; // already announcing
        const thread = std.Thread.spawn(.{}, TorrentSession.announceCompletedWorker, .{session}) catch {
            session.announcing.store(false, .release);
            return;
        };
        thread.detach();
    }

    /// Force piece recheck for a torrent: stop, recheck, resume.
    pub fn forceRecheck(self: *SessionManager, hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        // Stop the session (joins threads, frees runtime state)
        session.stop();
        // Restart it (will recheck from disk)
        session.startWithEventLoop(self.shared_event_loop);
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

    pub fn count(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    /// Set per-torrent download speed limit (bytes/sec). 0 = unlimited.
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
    }

    /// Set per-torrent upload speed limit (bytes/sec). 0 = unlimited.
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

            // Compute per-file progress
            const layout_file = layout.files[i];
            var file_progress: f64 = 0.0;
            if (session.piece_tracker) |*pt| {
                var pieces_complete: u32 = 0;
                var total_file_pieces: u32 = 0;
                var pidx: u32 = layout_file.first_piece;
                while (pidx < layout_file.end_piece_exclusive) : (pidx += 1) {
                    total_file_pieces += 1;
                    if (pt.complete.has(pidx)) {
                        pieces_complete += 1;
                    }
                }
                if (total_file_pieces > 0) {
                    file_progress = @as(f64, @floatFromInt(pieces_complete)) / @as(f64, @floatFromInt(total_file_pieces));
                }
            }

            const priority: u8 = if (session.file_priorities) |fp|
                if (i < fp.len) fp[i] else 1
            else
                1;

            result[i] = .{
                .name = name_buf,
                .size = file.length,
                .progress = file_progress,
                .priority = priority,
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
    pub fn getSessionTrackers(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) ![]const TrackerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const sess = session.session orelse return error.TorrentNotReady;
        const meta = sess.metainfo;
        const stats = session.getStats();

        // Count trackers: primary announce (if any) + announce_list (minus duplicates)
        var tracker_count: usize = 0;
        if (meta.announce != null) tracker_count += 1;
        for (meta.announce_list) |url| {
            if (meta.announce) |primary| {
                if (std.mem.eql(u8, url, primary)) continue;
            }
            tracker_count += 1;
        }

        var result = try allocator.alloc(TrackerInfo, tracker_count);
        var built: usize = 0;
        errdefer {
            for (result[0..built]) |ti| allocator.free(ti.url);
            allocator.free(result);
        }

        var tier: u32 = 0;

        if (meta.announce) |url| {
            const status: u8 = if (session.state == .downloading or session.state == .seeding) 2 else 1;
            result[built] = .{
                .url = try allocator.dupe(u8, url),
                .status = status,
                .tier = tier,
                .num_peers = stats.peers_connected,
                .num_seeds = stats.scrape_complete,
                .num_leeches = stats.scrape_incomplete,
                .num_downloaded = stats.scrape_downloaded,
            };
            built += 1;
            tier += 1;
        }

        for (meta.announce_list) |url| {
            if (meta.announce) |primary| {
                if (std.mem.eql(u8, url, primary)) continue;
            }
            result[built] = .{
                .url = try allocator.dupe(u8, url),
                .status = 1,
                .tier = tier,
                .num_peers = 0,
                .num_seeds = 0,
                .num_leeches = 0,
                .num_downloaded = 0,
            };
            built += 1;
            tier += 1;
        }

        return result;
    }

    /// Properties information returned by getSessionProperties().
    pub const PropertiesInfo = struct {
        stats: Stats,
        comment: []const u8, // owned, caller must free
        piece_size: u32,
    };

    /// Free a PropertiesInfo returned by getSessionProperties().
    pub fn freePropertiesInfo(allocator: std.mem.Allocator, info: PropertiesInfo) void {
        allocator.free(info.comment);
    }

    /// Return torrent properties, copying all data under the mutex.
    pub fn getSessionProperties(self: *SessionManager, allocator: std.mem.Allocator, hash: []const u8) !PropertiesInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const stats = session.getStats();
        const comment: []const u8 = if (session.session) |*sess| (sess.metainfo.comment orelse "") else "";
        const piece_size: u32 = if (session.session) |*sess| sess.metainfo.piece_length else 0;

        return .{
            .stats = stats,
            .comment = try allocator.dupe(u8, comment),
            .piece_size = piece_size,
        };
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
};

test "session manager add and list" {
    // This test needs io_uring for PieceStore, so skip if unavailable
    const Ring = @import("../io/ring.zig").Ring;
    _ = Ring.init(4) catch return error.SkipZigTest;
}

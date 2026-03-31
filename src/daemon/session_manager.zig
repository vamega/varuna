const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const Stats = @import("torrent_session.zig").Stats;
const TorrentState = @import("torrent_session.zig").State;
const categories_mod = @import("categories.zig");
pub const CategoryStore = categories_mod.CategoryStore;
pub const TagStore = categories_mod.TagStore;
const ResumeDb = @import("../storage/resume.zig").ResumeDb;
const BanList = @import("../net/ban_list.zig").BanList;

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

    /// In-memory category and tag stores.
    category_store: CategoryStore,
    tag_store: TagStore,

    /// Shared resume DB for category/tag persistence. Opened once, shared
    /// with all sessions. null if no resume_db_path is configured.
    resume_db: ?ResumeDb = null,

    /// Shared ban list for peer IP filtering. Owned by SessionManager,
    /// shared with EventLoop (read-only ban checks) and API handlers (mutations).
    ban_list: ?*BanList = null,

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

        // Load ban list from SQLite
        self.loadBanList();
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
        if (self.ban_list) |bl| {
            bl.deinit();
            self.allocator.destroy(bl);
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

        session.port = self.port;
        session.max_peers = self.max_peers;
        session.hasher_threads = self.hasher_threads;
        session.resume_db_path = self.resume_db_path;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check for duplicate
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
        return self.removeTorrentEx(hash, false);
    }

    /// Remove a torrent with optional file deletion.
    /// When delete_files is true, removes all data files and empty parent
    /// directories under the torrent's save_path.
    pub fn removeTorrentEx(self: *SessionManager, hash: []const u8, delete_files: bool) !void {
        self.mutex.lock();

        const kv = self.sessions.fetchRemove(hash) orelse {
            self.mutex.unlock();
            return error.TorrentNotFound;
        };
        var session = kv.value;

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

    /// Relocate torrent data to a new path. Pauses the torrent, moves files,
    /// and updates the save_path. The actual file move is done on the calling
    /// thread (which is the RPC handler thread, not the event loop).
    pub fn setLocation(self: *SessionManager, hash: []const u8, new_path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(hash) orelse return error.TorrentNotFound;
        const was_active = session.state == .downloading or session.state == .seeding;

        // Pause if active (stop I/O to the files)
        if (was_active) {
            session.pause();
        }

        // Move files from old save_path to new_path
        const old_path = session.save_path;
        moveDataFiles(old_path, new_path) catch |err| {
            // Resume if we paused
            if (was_active) session.resume_session();
            return err;
        };

        // Update save_path
        const owned_new_path = try self.allocator.dupe(u8, new_path);
        self.allocator.free(old_path);
        session.save_path = owned_new_path;

        // Resume if it was active
        if (was_active) {
            session.resume_session();
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
        } else if (session.event_loop) |*el| {
            diag.peers_connected = el.peer_count;
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
            const status: u8 = if (session.state == .downloading or session.state == .seeding or session.state == .metadata_fetching) 2 else 1;
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
        save_path: []const u8, // owned, caller must free
        comment: []const u8, // owned, caller must free
        piece_size: u32,
        info_hash_hex: [40]u8 = [_]u8{'0'} ** 40,
        name: []const u8, // owned, caller must free
        created_by: []const u8, // owned, caller must free
        creation_date: i64,
        trackers_count: u32,
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
            .save_path = try allocator.dupe(u8, stats.save_path),
            .comment = try allocator.dupe(u8, comment),
            .piece_size = piece_size,
            .info_hash_hex = stats.info_hash_hex,
            .name = try allocator.dupe(u8, name),
            .created_by = try allocator.dupe(u8, created_by),
            .creation_date = -1, // Not currently stored in metainfo
            .trackers_count = stats.trackers_count,
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
        const el: *EventLoop = session.shared_event_loop orelse
            (if (session.event_loop) |*solo| solo else return try allocator.alloc(PeerInfo, 0));
        const tid: u8 = session.torrent_id_in_shared orelse 0;

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
            });
        }

        return result.toOwnedSlice(allocator);
    }
};

test "session manager add and list" {
    // This test needs io_uring for PieceStore, so skip if unavailable
    const Ring = @import("../io/ring.zig").Ring;
    _ = Ring.init(4) catch return error.SkipZigTest;
}

const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const Stats = @import("torrent_session.zig").Stats;
const categories_mod = @import("categories.zig");
pub const CategoryStore = categories_mod.CategoryStore;
pub const TagStore = categories_mod.TagStore;

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

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*TorrentSession).init(allocator),
            .category_store = CategoryStore.init(allocator),
            .tag_store = TagStore.init(allocator),
        };
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

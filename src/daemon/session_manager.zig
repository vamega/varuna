const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const Stats = @import("torrent_session.zig").Stats;

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

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*TorrentSession).init(allocator),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
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

    pub fn count(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }
};

test "session manager add and list" {
    // This test needs io_uring for PieceStore, so skip if unavailable
    const Ring = @import("../io/ring.zig").Ring;
    _ = Ring.init(4) catch return error.SkipZigTest;
}

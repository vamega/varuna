const std = @import("std");
const TorrentSession = @import("torrent_session.zig").TorrentSession;
const TorrentState = @import("torrent_session.zig").State;
const ResumeDb = @import("../storage/state_db.zig").ResumeDb;

/// Queue configuration (from TOML config or API preferences).
pub const QueueConfig = struct {
    /// Whether queueing is enabled at all. When false, all torrents are active.
    enabled: bool = false,
    /// Max number of torrents actively downloading. -1 = unlimited.
    max_active_downloads: i32 = 5,
    /// Max number of torrents actively seeding. -1 = unlimited.
    max_active_uploads: i32 = 5,
    /// Overall max active torrents (downloading + seeding). -1 = unlimited.
    max_active_torrents: i32 = -1,
};

/// Manages torrent queue ordering and enforces active-torrent limits.
///
/// Queue positions are 1-based integers. Each torrent has exactly one
/// queue position. When a torrent is removed, positions are compacted.
///
/// Thread safety: callers must hold the SessionManager mutex before
/// calling any QueueManager method.
pub const QueueManager = struct {
    allocator: std.mem.Allocator,
    config: QueueConfig = .{},

    /// Ordered list of info-hash hex keys (borrowed from TorrentSession).
    /// Index 0 = queue position 1, index 1 = position 2, etc.
    queue: std.ArrayList([40]u8) = std.ArrayList([40]u8).empty,

    pub fn init(allocator: std.mem.Allocator) QueueManager {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueueManager) void {
        self.queue.deinit(self.allocator);
    }

    /// Add a torrent to the bottom of the queue. Returns its 1-based position.
    pub fn addTorrent(self: *QueueManager, info_hash_hex: [40]u8) !u32 {
        try self.queue.append(self.allocator, info_hash_hex);
        return @intCast(self.queue.items.len);
    }

    /// Remove a torrent from the queue and compact positions.
    pub fn removeTorrent(self: *QueueManager, info_hash_hex: [40]u8) void {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                _ = self.queue.orderedRemove(i);
                return;
            }
        }
    }

    /// Get the 1-based queue position of a torrent. Returns null if not found.
    pub fn getPosition(self: *const QueueManager, info_hash_hex: [40]u8) ?u32 {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                return @intCast(i + 1);
            }
        }
        return null;
    }

    /// Move a torrent to the top of the queue (position 1).
    pub fn moveToTop(self: *QueueManager, info_hash_hex: [40]u8) void {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                if (i == 0) return; // already at top
                const saved = item;
                // Shift everything down
                var j: usize = i;
                while (j > 0) : (j -= 1) {
                    self.queue.items[j] = self.queue.items[j - 1];
                }
                self.queue.items[0] = saved;
                return;
            }
        }
    }

    /// Move a torrent to the bottom of the queue.
    pub fn moveToBottom(self: *QueueManager, info_hash_hex: [40]u8) void {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                if (i == self.queue.items.len - 1) return; // already at bottom
                const saved = item;
                // Shift everything up
                var j: usize = i;
                while (j < self.queue.items.len - 1) : (j += 1) {
                    self.queue.items[j] = self.queue.items[j + 1];
                }
                self.queue.items[self.queue.items.len - 1] = saved;
                return;
            }
        }
    }

    /// Increase priority (move up one position, lower number = higher priority).
    pub fn increasePriority(self: *QueueManager, info_hash_hex: [40]u8) void {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                if (i == 0) return; // already at top
                // Swap with the item above
                const tmp = self.queue.items[i - 1];
                self.queue.items[i - 1] = self.queue.items[i];
                self.queue.items[i] = tmp;
                return;
            }
        }
    }

    /// Decrease priority (move down one position, higher number = lower priority).
    pub fn decreasePriority(self: *QueueManager, info_hash_hex: [40]u8) void {
        for (self.queue.items, 0..) |item, i| {
            if (std.mem.eql(u8, &item, &info_hash_hex)) {
                if (i == self.queue.items.len - 1) return; // already at bottom
                // Swap with the item below
                const tmp = self.queue.items[i + 1];
                self.queue.items[i + 1] = self.queue.items[i];
                self.queue.items[i] = tmp;
                return;
            }
        }
    }

    /// Determine whether a torrent should be active or queued based on current limits.
    /// Takes the sessions map to inspect torrent states.
    ///
    /// Returns true if the torrent should be started (has a slot), false if it
    /// should be queued.
    pub fn shouldBeActive(
        self: *const QueueManager,
        info_hash_hex: [40]u8,
        sessions: anytype,
    ) bool {
        if (!self.config.enabled) return true;

        // Count currently active downloads and uploads ahead of this torrent in the queue.
        // Also determine this torrent's type (download vs upload).
        const target_session = sessions.get(&info_hash_hex) orelse return true;
        const is_download = isDownloading(target_session);

        var active_downloads: u32 = 0;
        var active_uploads: u32 = 0;
        var active_total: u32 = 0;

        // Walk the queue in priority order. For each torrent ahead of (or equal to)
        // this one, count it if it is active.
        for (self.queue.items) |hash| {
            const session = sessions.get(&hash) orelse continue;
            const state = session.state;

            // Skip paused/stopped/error/checking/queued -- they don't consume slots
            if (state == .paused or state == .stopped or state == .@"error" or
                state == .checking or state == .metadata_fetching or state == .queued)
            {
                continue;
            }

            // This torrent is active (downloading or seeding)
            if (isDownloading(session)) {
                active_downloads += 1;
            } else {
                active_uploads += 1;
            }
            active_total += 1;
        }

        // Now check if adding this torrent (if it is currently queued) would exceed limits
        if (target_session.state != .queued) {
            // Already active, let it stay active
            return true;
        }

        // Check overall limit
        if (self.config.max_active_torrents >= 0) {
            if (active_total >= @as(u32, @intCast(self.config.max_active_torrents))) return false;
        }

        // Check per-type limits
        if (is_download) {
            if (self.config.max_active_downloads >= 0) {
                if (active_downloads >= @as(u32, @intCast(self.config.max_active_downloads))) return false;
            }
        } else {
            if (self.config.max_active_uploads >= 0) {
                if (active_uploads >= @as(u32, @intCast(self.config.max_active_uploads))) return false;
            }
        }

        return true;
    }

    /// Run queue enforcement: walk the queue in priority order, decide which
    /// torrents fit within active-slot limits, and return two lists:
    ///   - `to_start`: queued torrents that should become active
    ///   - `to_queue`: active torrents that exceed limits and should be demoted
    ///
    /// The caller must actually start/queue the sessions.
    pub fn enforce(
        self: *const QueueManager,
        sessions: anytype,
    ) EnforceResult {
        var result = EnforceResult{};
        if (!self.config.enabled) return result;

        var active_downloads: u32 = 0;
        var active_uploads: u32 = 0;
        var active_total: u32 = 0;

        for (self.queue.items) |hash| {
            const session = sessions.get(&hash) orelse continue;
            const state = session.state;
            if (!(state == .downloading or state == .seeding or state == .queued)) continue;

            const is_download = state != .seeding;
            const within_total = self.config.max_active_torrents < 0 or
                active_total < @as(u32, @intCast(self.config.max_active_torrents));
            const within_type = if (is_download)
                (self.config.max_active_downloads < 0 or
                    active_downloads < @as(u32, @intCast(self.config.max_active_downloads)))
            else
                (self.config.max_active_uploads < 0 or
                    active_uploads < @as(u32, @intCast(self.config.max_active_uploads)));

            if (within_total and within_type) {
                active_total += 1;
                if (is_download) {
                    active_downloads += 1;
                } else {
                    active_uploads += 1;
                }

                if (state == .queued and result.start_count < result.to_start.len) {
                    result.to_start[result.start_count] = hash;
                    result.start_count += 1;
                }
                continue;
            }

            if ((state == .downloading or state == .seeding) and result.queue_count < result.to_queue.len) {
                result.to_queue[result.queue_count] = hash;
                result.queue_count += 1;
            }
        }

        return result;
    }

    pub const EnforceResult = struct {
        const MAX_BATCH = 32;
        to_start: [MAX_BATCH][40]u8 = undefined,
        start_count: usize = 0,
        to_queue: [MAX_BATCH][40]u8 = undefined,
        queue_count: usize = 0,
    };

    /// Persist queue positions to SQLite.
    pub fn saveToDb(self: *const QueueManager, db: *ResumeDb) void {
        db.clearQueuePositions() catch return;
        for (self.queue.items, 0..) |hash, i| {
            db.saveQueuePosition(hash, @intCast(i + 1)) catch {};
        }
    }

    /// Load queue positions from SQLite and rebuild the ordered list.
    pub fn loadFromDb(self: *QueueManager, db: *ResumeDb) void {
        const QueuePosition = @import("../storage/state_db.zig").QueuePosition;
        const entries = db.loadQueuePositions(self.allocator) catch return;
        defer {
            self.allocator.free(entries);
        }

        // Sort by position
        std.mem.sort(QueuePosition, entries, {}, struct {
            fn lessThan(_: void, a: QueuePosition, b: QueuePosition) bool {
                return a.position < b.position;
            }
        }.lessThan);

        // Rebuild queue
        self.queue.clearRetainingCapacity();
        for (entries) |entry| {
            self.queue.append(self.allocator, entry.info_hash_hex) catch {};
        }
    }

    fn isDownloading(session: anytype) bool {
        return session.state != .seeding;
    }
};

pub const QueueEntry = struct {
    info_hash_hex: [40]u8,
    position: u32,
};

// ── Tests ─────────────────────────────────────────────────

test "queue position management" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    // Add three torrents
    const pos1 = try qm.addTorrent(hash_a);
    const pos2 = try qm.addTorrent(hash_b);
    const pos3 = try qm.addTorrent(hash_c);

    try std.testing.expectEqual(@as(u32, 1), pos1);
    try std.testing.expectEqual(@as(u32, 2), pos2);
    try std.testing.expectEqual(@as(u32, 3), pos3);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_a));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_b));
    try std.testing.expectEqual(@as(?u32, 3), qm.getPosition(hash_c));
}

test "queue remove compacts positions" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    _ = try qm.addTorrent(hash_a);
    _ = try qm.addTorrent(hash_b);
    _ = try qm.addTorrent(hash_c);

    qm.removeTorrent(hash_b);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_a));
    try std.testing.expectEqual(@as(?u32, null), qm.getPosition(hash_b));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_c));
}

test "queue move to top" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    _ = try qm.addTorrent(hash_a);
    _ = try qm.addTorrent(hash_b);
    _ = try qm.addTorrent(hash_c);

    qm.moveToTop(hash_c);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_c));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_a));
    try std.testing.expectEqual(@as(?u32, 3), qm.getPosition(hash_b));
}

test "queue move to bottom" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    _ = try qm.addTorrent(hash_a);
    _ = try qm.addTorrent(hash_b);
    _ = try qm.addTorrent(hash_c);

    qm.moveToBottom(hash_a);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_b));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_c));
    try std.testing.expectEqual(@as(?u32, 3), qm.getPosition(hash_a));
}

test "queue increase priority" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    _ = try qm.addTorrent(hash_a);
    _ = try qm.addTorrent(hash_b);
    _ = try qm.addTorrent(hash_c);

    // Move B up (from pos 2 to pos 1)
    qm.increasePriority(hash_b);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_b));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_a));
    try std.testing.expectEqual(@as(?u32, 3), qm.getPosition(hash_c));
}

test "queue decrease priority" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    const hash_b = @as([40]u8, @splat('b'));
    const hash_c = @as([40]u8, @splat('c'));

    _ = try qm.addTorrent(hash_a);
    _ = try qm.addTorrent(hash_b);
    _ = try qm.addTorrent(hash_c);

    // Move B down (from pos 2 to pos 3)
    qm.decreasePriority(hash_b);

    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_a));
    try std.testing.expectEqual(@as(?u32, 2), qm.getPosition(hash_c));
    try std.testing.expectEqual(@as(?u32, 3), qm.getPosition(hash_b));
}

test "queue increase priority at top is no-op" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    _ = try qm.addTorrent(hash_a);

    qm.increasePriority(hash_a);
    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_a));
}

test "queue decrease priority at bottom is no-op" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();

    const hash_a = @as([40]u8, @splat('a'));
    _ = try qm.addTorrent(hash_a);

    qm.decreasePriority(hash_a);
    try std.testing.expectEqual(@as(?u32, 1), qm.getPosition(hash_a));
}

test "queue disabled means all torrents active" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();
    qm.config.enabled = false;

    // With an empty sessions map, shouldBeActive should return true
    var sessions = std.StringHashMap(*TorrentSession).init(allocator);
    defer sessions.deinit();

    const hash = @as([40]u8, @splat('a'));
    _ = try qm.addTorrent(hash);
    try std.testing.expect(qm.shouldBeActive(hash, &sessions));
}

test "queue enforcement with limits" {
    const allocator = std.testing.allocator;
    var qm = QueueManager.init(allocator);
    defer qm.deinit();
    qm.config.enabled = true;
    qm.config.max_active_downloads = 1;
    qm.config.max_active_uploads = -1;
    qm.config.max_active_torrents = -1;

    // We cannot easily create TorrentSessions in tests without full
    // torrent bytes, so we test the enforcement logic structurally.
    // The enforce method with an empty sessions map should return
    // nothing to start or queue.
    var sessions = std.StringHashMap(*TorrentSession).init(allocator);
    defer sessions.deinit();

    const result = qm.enforce(&sessions);
    try std.testing.expectEqual(@as(usize, 0), result.start_count);
    try std.testing.expectEqual(@as(usize, 0), result.queue_count);
}

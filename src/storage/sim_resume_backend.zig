//! In-memory, fault-injectable resume DB backend for `EventLoopOf(SimIO)`
//! tests. Mirrors the public surface of `SqliteBackend` (the production
//! resume DB backend) so daemon code that holds `*ResumeDb` keeps
//! compiling under either backend.
//!
//! Implementation notes:
//!   - Per-table `std.AutoHashMapUnmanaged` / `std.StringHashMapUnmanaged`
//!     for the same access shape as the SQLite tables. Owned strings
//!     are duped on insert so callers can free their inputs immediately.
//!   - `std.Thread.Mutex` for the same multi-thread access pattern as
//!     `SQLITE_OPEN_FULLMUTEX` — workers, RPC handlers, queue manager
//!     all share one backend instance.
//!   - `FaultConfig` knobs let BUGGIFY-shaped tests inject commit
//!     failures, lost reads, and corrupted reads. Mirrors
//!     `src/io/sim_io.zig`'s `FaultConfig` per-op probability shape.
//!
//! See `docs/sqlite-simulation-and-replacement.md` §2 for the design.

const std = @import("std");

const state_db = @import("state_db.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;

pub const SimResumeBackend = struct {
    // Re-exports for parity with `SqliteBackend.<Type>` access shape and
    // for `state_db.TransferStats` to be reachable through the backend.
    pub const TransferStats = state_db.TransferStats;
    pub const RateLimits = state_db.RateLimits;
    pub const ShareLimits = state_db.ShareLimits;
    pub const IpFilterConfig = state_db.IpFilterConfig;
    pub const TrackerOverride = state_db.TrackerOverride;
    pub const SavedCategory = state_db.SavedCategory;
    pub const SavedBannedIp = state_db.SavedBannedIp;
    pub const SavedBannedRange = state_db.SavedBannedRange;
    pub const QueuePosition = state_db.QueuePosition;

    pub const FaultConfig = struct {
        /// Probability that a write call returns `error.SqliteCommitFailed`
        /// (covers `markComplete`, `markCompleteBatch`, `replaceCompletePieces`,
        /// `saveTransferStats`, and the RPC-driven setters).
        commit_failure_probability: f32 = 0.0,

        /// Probability that a read call observes "no rows" even if rows
        /// exist (covers `loadCompletePieces`, `loadTransferStats`,
        /// `loadRateLimits`, etc.). Used to test "did we recover from a
        /// silent read miss" recovery paths.
        read_failure_probability: f32 = 0.0,

        /// Probability that a load call returns the data corrupted —
        /// e.g. a bitfield with random extra/missing bits, or a
        /// transfer-stats row with random byte counts. Useful for
        /// asserting that recheck recovers when the resume DB lies.
        ///
        /// Currently scoped to `loadCompletePieces` (the highest-leverage
        /// surface — recheck pruning depends on this read being honest).
        read_corruption_probability: f32 = 0.0,

        /// Probability that a transaction is reported committed but the
        /// effect is not actually applied (lost write / silently dropped
        /// commit). Distinct from `commit_failure_probability` — the
        /// caller observes success but the DB is unchanged. Models a
        /// power-loss between WAL append and apply.
        silent_drop_probability: f32 = 0.0,
    };

    allocator: std.mem.Allocator,
    /// Mirrors `SQLITE_OPEN_FULLMUTEX`: every public method takes the
    /// mutex. Multiple worker threads / RPC handlers can share one
    /// backend instance.
    mutex: std.Thread.Mutex = .{},
    /// Per-instance RNG so tests can swap seeds without a global.
    rng: std.Random.DefaultPrng,
    fault_config: FaultConfig = .{},

    // ── Tables (in-memory) ─────────────────────────────────
    //
    // Keyed exactly like the SQLite primary keys. Owned strings are
    // duped into `allocator` on insert; deinit frees them.

    pieces: std.AutoHashMapUnmanaged(PieceKey, void) = .{},
    transfer_stats: std.AutoHashMapUnmanaged([20]u8, TransferStats) = .{},
    categories: std.StringHashMapUnmanaged([]const u8) = .{}, // name -> save_path
    torrent_categories: std.AutoHashMapUnmanaged([20]u8, []const u8) = .{},
    /// `(info_hash, tag)` is small enough to keep in an unsorted list —
    /// keys with slice fields can't go through `std.AutoHashMap`, and the
    /// per-torrent tag count is bounded by user-supplied tag config (~10s).
    torrent_tags: std.ArrayListUnmanaged(TorrentTagRow) = .{},
    global_tags: std.StringHashMapUnmanaged(void) = .{},
    rate_limits: std.AutoHashMapUnmanaged([20]u8, RateLimits) = .{},
    share_limits: std.AutoHashMapUnmanaged([20]u8, ShareLimits) = .{},
    info_hash_v2: std.AutoHashMapUnmanaged([20]u8, [32]u8) = .{},
    /// Same reason as `torrent_tags` — `(info_hash, url)` keys with a
    /// slice field can't use `std.AutoHashMap`, and per-torrent override
    /// counts are bounded by user input (~ tens).
    tracker_overrides: std.ArrayListUnmanaged(TrackerOverrideRow) = .{},
    banned_ips: std.StringHashMapUnmanaged(BannedIpRow) = .{},
    banned_ranges: std.ArrayListUnmanaged(BannedRangeRow) = .{},
    next_banned_range_id: u64 = 1,
    ipfilter_config: ?IpFilterConfigRow = null,
    queue_positions: std.AutoHashMapUnmanaged([40]u8, u32) = .{},

    // ── Row types ──────────────────────────────────────────

    pub const PieceKey = struct { info_hash: [20]u8, piece_index: u32 };

    pub const TorrentTagRow = struct {
        info_hash: [20]u8,
        tag_text: []const u8, // owned
    };

    pub const TrackerOverrideRow = struct {
        info_hash: [20]u8,
        url: []const u8, // owned
        tier: u32,
        action: []const u8, // owned, "add"/"remove"/"edit"
        orig_url: ?[]const u8, // owned (or null)
    };

    pub const BannedIpRow = struct {
        source: u8,
        reason: ?[]const u8, // owned (or null)
        created_at: i64,
    };

    pub const BannedRangeRow = struct {
        id: u64,
        start_addr: []const u8, // owned
        end_addr: []const u8, // owned
        source: u8,
        created_at: i64,
    };

    pub const IpFilterConfigRow = struct {
        path: ?[]const u8 = null, // owned (or null)
        enabled: bool = false,
        rule_count: u32 = 0,
    };

    // ── Lifecycle ──────────────────────────────────────────

    /// Mirror `SqliteBackend.open(path)` shape so test code can swap
    /// the backend without touching the call site. `path` is ignored.
    pub fn open(_: [*:0]const u8) !SimResumeBackend {
        return init(std.heap.page_allocator, 0);
    }

    /// Preferred constructor for tests: pass the seed explicitly so
    /// fault injection is deterministic across runs.
    pub fn init(allocator: std.mem.Allocator, seed: u64) SimResumeBackend {
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Mirror `SqliteBackend.close()` — frees all in-memory state.
    pub fn close(self: *SimResumeBackend) void {
        self.deinit();
    }

    pub fn deinit(self: *SimResumeBackend) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.pieces.deinit(self.allocator);
        self.transfer_stats.deinit(self.allocator);

        // Free owned strings in categories
        var cat_it = self.categories.iterator();
        while (cat_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.categories.deinit(self.allocator);

        var tcat_it = self.torrent_categories.iterator();
        while (tcat_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.torrent_categories.deinit(self.allocator);

        for (self.torrent_tags.items) |row| {
            self.allocator.free(row.tag_text);
        }
        self.torrent_tags.deinit(self.allocator);

        var gt_it = self.global_tags.iterator();
        while (gt_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.global_tags.deinit(self.allocator);

        self.rate_limits.deinit(self.allocator);
        self.share_limits.deinit(self.allocator);
        self.info_hash_v2.deinit(self.allocator);

        for (self.tracker_overrides.items) |row| {
            self.allocator.free(row.url);
            self.allocator.free(row.action);
            if (row.orig_url) |ou| self.allocator.free(ou);
        }
        self.tracker_overrides.deinit(self.allocator);

        var bi_it = self.banned_ips.iterator();
        while (bi_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.reason) |r| self.allocator.free(r);
        }
        self.banned_ips.deinit(self.allocator);

        for (self.banned_ranges.items) |row| {
            self.allocator.free(row.start_addr);
            self.allocator.free(row.end_addr);
        }
        self.banned_ranges.deinit(self.allocator);

        if (self.ipfilter_config) |cfg| {
            if (cfg.path) |p| self.allocator.free(p);
        }
        self.ipfilter_config = null;

        self.queue_positions.deinit(self.allocator);
    }

    // ── Fault helpers ──────────────────────────────────────

    fn shouldCommitFault(self: *SimResumeBackend) bool {
        if (self.fault_config.commit_failure_probability <= 0.0) return false;
        return self.rng.random().float(f32) < self.fault_config.commit_failure_probability;
    }

    fn shouldReadFault(self: *SimResumeBackend) bool {
        if (self.fault_config.read_failure_probability <= 0.0) return false;
        return self.rng.random().float(f32) < self.fault_config.read_failure_probability;
    }

    fn shouldReadCorrupt(self: *SimResumeBackend) bool {
        if (self.fault_config.read_corruption_probability <= 0.0) return false;
        return self.rng.random().float(f32) < self.fault_config.read_corruption_probability;
    }

    fn shouldSilentDrop(self: *SimResumeBackend) bool {
        if (self.fault_config.silent_drop_probability <= 0.0) return false;
        return self.rng.random().float(f32) < self.fault_config.silent_drop_probability;
    }

    // ── Pieces table ───────────────────────────────────────

    pub fn markComplete(self: *SimResumeBackend, info_hash: [20]u8, piece_index: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return; // success reported, no apply
        try self.pieces.put(self.allocator, .{ .info_hash = info_hash, .piece_index = piece_index }, {});
    }

    pub fn markCompleteBatch(self: *SimResumeBackend, info_hash: [20]u8, piece_indices: []const u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        for (piece_indices) |idx| {
            try self.pieces.put(self.allocator, .{ .info_hash = info_hash, .piece_index = idx }, {});
        }
    }

    pub fn replaceCompletePieces(
        self: *SimResumeBackend,
        info_hash: [20]u8,
        piece_indices: []const u32,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        // Atomic swap: drop existing rows for info_hash, then insert new set.
        // Mirrors `BEGIN IMMEDIATE … COMMIT` in `SqliteBackend.replaceCompletePieces`.
        // Under the mutex, no concurrent reader observes a partial state.
        var to_remove = std.ArrayList(PieceKey).empty;
        defer to_remove.deinit(self.allocator);
        var it = self.pieces.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, &entry.key_ptr.info_hash, &info_hash)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (to_remove.items) |key| _ = self.pieces.remove(key);
        for (piece_indices) |idx| {
            try self.pieces.put(self.allocator, .{ .info_hash = info_hash, .piece_index = idx }, {});
        }
    }

    pub fn loadCompletePieces(self: *SimResumeBackend, info_hash: [20]u8, bitfield: *Bitfield) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return 0; // simulate "no rows even though they exist"

        var count: u32 = 0;
        var it = self.pieces.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, &entry.key_ptr.info_hash, &info_hash)) continue;
            const piece_index = entry.key_ptr.piece_index;
            if (self.shouldReadCorrupt()) {
                // Corrupt by flipping to a different (random) piece index in
                // the valid range. Models a SQLite that returned the wrong
                // row. The caller (recheck pipeline) must handle this.
                _ = bitfield.set(self.rng.random().uintLessThan(u32, bitfield.piece_count)) catch continue;
            } else {
                bitfield.set(piece_index) catch continue;
            }
            count += 1;
        }
        return count;
    }

    pub fn clearTorrent(self: *SimResumeBackend, info_hash: [20]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        // pieces
        {
            var to_remove = std.ArrayList(PieceKey).empty;
            defer to_remove.deinit(self.allocator);
            var it = self.pieces.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, &entry.key_ptr.info_hash, &info_hash)) {
                    try to_remove.append(self.allocator, entry.key_ptr.*);
                }
            }
            for (to_remove.items) |key| _ = self.pieces.remove(key);
        }

        _ = self.transfer_stats.remove(info_hash);

        if (self.torrent_categories.fetchRemove(info_hash)) |kv| {
            self.allocator.free(kv.value);
        }

        // torrent_tags
        {
            var i: usize = 0;
            while (i < self.torrent_tags.items.len) {
                if (std.mem.eql(u8, &self.torrent_tags.items[i].info_hash, &info_hash)) {
                    const removed = self.torrent_tags.swapRemove(i);
                    self.allocator.free(removed.tag_text);
                } else {
                    i += 1;
                }
            }
        }

        _ = self.rate_limits.remove(info_hash);
        _ = self.share_limits.remove(info_hash);
        _ = self.info_hash_v2.remove(info_hash);

        // tracker_overrides
        {
            var i: usize = 0;
            while (i < self.tracker_overrides.items.len) {
                if (std.mem.eql(u8, &self.tracker_overrides.items[i].info_hash, &info_hash)) {
                    const removed = self.tracker_overrides.swapRemove(i);
                    self.allocator.free(removed.url);
                    self.allocator.free(removed.action);
                    if (removed.orig_url) |ou| self.allocator.free(ou);
                } else {
                    i += 1;
                }
            }
        }

        // queue_positions: keyed by info_hash_hex
        const info_hash_hex = std.fmt.bytesToHex(info_hash, .lower);
        _ = self.queue_positions.remove(info_hash_hex);
    }

    // ── Transfer stats ─────────────────────────────────────

    pub fn saveTransferStats(self: *SimResumeBackend, info_hash: [20]u8, stats: TransferStats) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        try self.transfer_stats.put(self.allocator, info_hash, stats);
    }

    pub fn loadTransferStats(self: *SimResumeBackend, info_hash: [20]u8) TransferStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return .{};
        return self.transfer_stats.get(info_hash) orelse .{};
    }

    // ── Categories (global) ────────────────────────────────

    pub fn saveCategory(self: *SimResumeBackend, name: []const u8, save_path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (self.categories.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, save_path);
        } else {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_path = try self.allocator.dupe(u8, save_path);
            errdefer self.allocator.free(owned_path);
            try self.categories.put(self.allocator, owned_name, owned_path);
        }
    }

    pub fn removeCategory(self: *SimResumeBackend, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (self.categories.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn loadCategories(self: *SimResumeBackend, allocator: std.mem.Allocator) ![]SavedCategory {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(SavedCategory).empty;
        errdefer {
            for (result.items) |cat| {
                allocator.free(cat.name);
                allocator.free(cat.save_path);
            }
            result.deinit(allocator);
        }

        var it = self.categories.iterator();
        while (it.next()) |entry| {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);
            const path = try allocator.dupe(u8, entry.value_ptr.*);
            try result.append(allocator, .{ .name = name, .save_path = path });
        }

        return result.toOwnedSlice(allocator);
    }

    // ── Torrent categories ─────────────────────────────────

    pub fn saveTorrentCategory(self: *SimResumeBackend, info_hash: [20]u8, category: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (category.len == 0) {
            if (self.torrent_categories.fetchRemove(info_hash)) |kv| {
                self.allocator.free(kv.value);
            }
            return;
        }
        if (self.torrent_categories.getPtr(info_hash)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, category);
        } else {
            const owned = try self.allocator.dupe(u8, category);
            errdefer self.allocator.free(owned);
            try self.torrent_categories.put(self.allocator, info_hash, owned);
        }
    }

    pub fn loadTorrentCategory(self: *SimResumeBackend, allocator: std.mem.Allocator, info_hash: [20]u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return null;
        const value = self.torrent_categories.get(info_hash) orelse return null;
        return try allocator.dupe(u8, value);
    }

    pub fn clearCategoryFromTorrents(self: *SimResumeBackend, category: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var to_remove = std.ArrayList([20]u8).empty;
        defer to_remove.deinit(self.allocator);
        var it = self.torrent_categories.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, category)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (to_remove.items) |key| {
            if (self.torrent_categories.fetchRemove(key)) |kv| self.allocator.free(kv.value);
        }
    }

    // ── Torrent tags ──────────────────────────────────────

    pub fn saveTorrentTag(self: *SimResumeBackend, info_hash: [20]u8, tag: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        // Insert-or-ignore semantics. Linear scan over (info_hash, tag).
        for (self.torrent_tags.items) |row| {
            if (std.mem.eql(u8, &row.info_hash, &info_hash) and
                std.mem.eql(u8, row.tag_text, tag))
            {
                return;
            }
        }
        const owned = try self.allocator.dupe(u8, tag);
        errdefer self.allocator.free(owned);
        try self.torrent_tags.append(self.allocator, .{
            .info_hash = info_hash,
            .tag_text = owned,
        });
    }

    pub fn removeTorrentTag(self: *SimResumeBackend, info_hash: [20]u8, tag: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.torrent_tags.items.len) {
            const row = self.torrent_tags.items[i];
            if (std.mem.eql(u8, &row.info_hash, &info_hash) and
                std.mem.eql(u8, row.tag_text, tag))
            {
                const removed = self.torrent_tags.swapRemove(i);
                self.allocator.free(removed.tag_text);
                return;
            }
            i += 1;
        }
    }

    pub fn clearTorrentTags(self: *SimResumeBackend, info_hash: [20]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.torrent_tags.items.len) {
            if (std.mem.eql(u8, &self.torrent_tags.items[i].info_hash, &info_hash)) {
                const removed = self.torrent_tags.swapRemove(i);
                self.allocator.free(removed.tag_text);
            } else {
                i += 1;
            }
        }
    }

    pub fn loadTorrentTags(self: *SimResumeBackend, allocator: std.mem.Allocator, info_hash: [20]u8) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |tag| allocator.free(tag);
            result.deinit(allocator);
        }
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        for (self.torrent_tags.items) |row| {
            if (std.mem.eql(u8, &row.info_hash, &info_hash)) {
                const owned = try allocator.dupe(u8, row.tag_text);
                try result.append(allocator, owned);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn removeTagFromTorrents(self: *SimResumeBackend, tag: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.torrent_tags.items.len) {
            if (std.mem.eql(u8, self.torrent_tags.items[i].tag_text, tag)) {
                const removed = self.torrent_tags.swapRemove(i);
                self.allocator.free(removed.tag_text);
            } else {
                i += 1;
            }
        }
    }

    // ── Global tags ───────────────────────────────────────

    pub fn saveGlobalTag(self: *SimResumeBackend, tag: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (self.global_tags.contains(tag)) return;
        const owned = try self.allocator.dupe(u8, tag);
        errdefer self.allocator.free(owned);
        try self.global_tags.put(self.allocator, owned, {});
    }

    pub fn removeGlobalTag(self: *SimResumeBackend, tag: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (self.global_tags.fetchRemove(tag)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    pub fn loadGlobalTags(self: *SimResumeBackend, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |tag| allocator.free(tag);
            result.deinit(allocator);
        }
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        var it = self.global_tags.iterator();
        while (it.next()) |entry| {
            const owned = try allocator.dupe(u8, entry.key_ptr.*);
            try result.append(allocator, owned);
        }
        return result.toOwnedSlice(allocator);
    }

    // ── Rate limits ───────────────────────────────────────

    pub fn saveRateLimits(self: *SimResumeBackend, info_hash: [20]u8, dl_limit: u64, ul_limit: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        try self.rate_limits.put(self.allocator, info_hash, .{
            .dl_limit = dl_limit,
            .ul_limit = ul_limit,
        });
    }

    pub fn loadRateLimits(self: *SimResumeBackend, info_hash: [20]u8) RateLimits {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return .{};
        return self.rate_limits.get(info_hash) orelse .{};
    }

    pub fn clearRateLimits(self: *SimResumeBackend, info_hash: [20]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        _ = self.rate_limits.remove(info_hash);
    }

    // ── Share limits ──────────────────────────────────────

    pub fn saveShareLimits(self: *SimResumeBackend, info_hash: [20]u8, ratio_limit: f64, seeding_time_limit: i64, completion_on: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        try self.share_limits.put(self.allocator, info_hash, .{
            .ratio_limit = ratio_limit,
            .seeding_time_limit = seeding_time_limit,
            .completion_on = completion_on,
        });
    }

    pub fn loadShareLimits(self: *SimResumeBackend, info_hash: [20]u8) ShareLimits {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return .{};
        return self.share_limits.get(info_hash) orelse .{};
    }

    pub fn clearShareLimits(self: *SimResumeBackend, info_hash: [20]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        _ = self.share_limits.remove(info_hash);
    }

    // ── Info hash v2 ──────────────────────────────────────

    pub fn saveInfoHashV2(self: *SimResumeBackend, info_hash: [20]u8, info_hash_v2: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        try self.info_hash_v2.put(self.allocator, info_hash, info_hash_v2);
    }

    pub fn loadInfoHashV2(self: *SimResumeBackend, info_hash: [20]u8) ?[32]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return null;
        return self.info_hash_v2.get(info_hash);
    }

    // ── Banned IPs ────────────────────────────────────────

    pub fn saveBannedIp(self: *SimResumeBackend, address: []const u8, source: u8, reason: ?[]const u8, created_at: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        if (self.banned_ips.getPtr(address)) |existing| {
            // Upsert: replace source/reason but keep original created_at? SQL upsert
            // (`ON CONFLICT(address) DO UPDATE SET source = ?2, reason = ?3`) does
            // not touch created_at, so neither do we.
            existing.source = source;
            if (existing.reason) |old| self.allocator.free(old);
            existing.reason = if (reason) |r| try self.allocator.dupe(u8, r) else null;
            return;
        }
        const owned_addr = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(owned_addr);
        const owned_reason: ?[]const u8 = if (reason) |r| try self.allocator.dupe(u8, r) else null;
        try self.banned_ips.put(self.allocator, owned_addr, .{
            .source = source,
            .reason = owned_reason,
            .created_at = created_at,
        });
    }

    pub fn removeBannedIp(self: *SimResumeBackend, address: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        if (self.banned_ips.fetchRemove(address)) |kv| {
            self.allocator.free(kv.key);
            if (kv.value.reason) |r| self.allocator.free(r);
        }
    }

    pub fn clearBannedBySource(self: *SimResumeBackend, source: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        // banned_ips
        var ip_keys = std.ArrayList([]const u8).empty;
        defer ip_keys.deinit(self.allocator);
        var it = self.banned_ips.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source == source) {
                try ip_keys.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (ip_keys.items) |k| {
            if (self.banned_ips.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                if (kv.value.reason) |r| self.allocator.free(r);
            }
        }

        // banned_ranges (filter in place)
        var i: usize = 0;
        while (i < self.banned_ranges.items.len) {
            if (self.banned_ranges.items[i].source == source) {
                const row = self.banned_ranges.swapRemove(i);
                self.allocator.free(row.start_addr);
                self.allocator.free(row.end_addr);
            } else {
                i += 1;
            }
        }
    }

    pub fn loadBannedIps(self: *SimResumeBackend, allocator: std.mem.Allocator) ![]SavedBannedIp {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(SavedBannedIp).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.address);
                if (item.reason) |r| allocator.free(r);
            }
            result.deinit(allocator);
        }
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        var it = self.banned_ips.iterator();
        while (it.next()) |entry| {
            const addr = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(addr);
            const reason: ?[]const u8 = if (entry.value_ptr.reason) |r| try allocator.dupe(u8, r) else null;
            try result.append(allocator, .{
                .address = addr,
                .source = entry.value_ptr.source,
                .reason = reason,
                .created_at = entry.value_ptr.created_at,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    // ── Banned ranges ─────────────────────────────────────

    pub fn saveBannedRange(self: *SimResumeBackend, start_addr: []const u8, end_addr: []const u8, source: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        const owned_start = try self.allocator.dupe(u8, start_addr);
        errdefer self.allocator.free(owned_start);
        const owned_end = try self.allocator.dupe(u8, end_addr);
        errdefer self.allocator.free(owned_end);
        const id = self.next_banned_range_id;
        self.next_banned_range_id += 1;
        try self.banned_ranges.append(self.allocator, .{
            .id = id,
            .start_addr = owned_start,
            .end_addr = owned_end,
            .source = source,
            .created_at = std.time.timestamp(),
        });
    }

    pub fn loadBannedRanges(self: *SimResumeBackend, allocator: std.mem.Allocator) ![]SavedBannedRange {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(SavedBannedRange).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.start_addr);
                allocator.free(item.end_addr);
            }
            result.deinit(allocator);
        }
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        for (self.banned_ranges.items) |row| {
            const s = try allocator.dupe(u8, row.start_addr);
            errdefer allocator.free(s);
            const e = try allocator.dupe(u8, row.end_addr);
            try result.append(allocator, .{
                .start_addr = s,
                .end_addr = e,
                .source = row.source,
                .created_at = row.created_at,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    // ── Tracker overrides ─────────────────────────────────

    pub fn saveTrackerOverride(self: *SimResumeBackend, info_hash: [20]u8, url: []const u8, tier: u32, action: []const u8, orig_url: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        // Upsert by (info_hash, url).
        for (self.tracker_overrides.items) |*row| {
            if (std.mem.eql(u8, &row.info_hash, &info_hash) and
                std.mem.eql(u8, row.url, url))
            {
                self.allocator.free(row.action);
                row.action = try self.allocator.dupe(u8, action);
                if (row.orig_url) |old| self.allocator.free(old);
                row.orig_url = if (orig_url) |o| try self.allocator.dupe(u8, o) else null;
                row.tier = tier;
                return;
            }
        }
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);
        const owned_orig: ?[]const u8 = if (orig_url) |o| try self.allocator.dupe(u8, o) else null;
        try self.tracker_overrides.append(self.allocator, .{
            .info_hash = info_hash,
            .url = owned_url,
            .tier = tier,
            .action = owned_action,
            .orig_url = owned_orig,
        });
    }

    pub fn removeTrackerOverride(self: *SimResumeBackend, info_hash: [20]u8, url: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.tracker_overrides.items.len) {
            const row = self.tracker_overrides.items[i];
            if (std.mem.eql(u8, &row.info_hash, &info_hash) and
                std.mem.eql(u8, row.url, url))
            {
                const removed = self.tracker_overrides.swapRemove(i);
                self.allocator.free(removed.url);
                self.allocator.free(removed.action);
                if (removed.orig_url) |ou| self.allocator.free(ou);
                return;
            }
            i += 1;
        }
    }

    pub fn removeTrackerOverrideByOrig(self: *SimResumeBackend, info_hash: [20]u8, orig_url: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.tracker_overrides.items.len) {
            const row = self.tracker_overrides.items[i];
            if (std.mem.eql(u8, &row.info_hash, &info_hash)) {
                if (row.orig_url) |ou| {
                    if (std.mem.eql(u8, ou, orig_url)) {
                        const removed = self.tracker_overrides.swapRemove(i);
                        self.allocator.free(removed.url);
                        self.allocator.free(removed.action);
                        if (removed.orig_url) |o| self.allocator.free(o);
                        continue;
                    }
                }
            }
            i += 1;
        }
    }

    pub fn clearTrackerOverrides(self: *SimResumeBackend, info_hash: [20]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        var i: usize = 0;
        while (i < self.tracker_overrides.items.len) {
            if (std.mem.eql(u8, &self.tracker_overrides.items[i].info_hash, &info_hash)) {
                const removed = self.tracker_overrides.swapRemove(i);
                self.allocator.free(removed.url);
                self.allocator.free(removed.action);
                if (removed.orig_url) |ou| self.allocator.free(ou);
            } else {
                i += 1;
            }
        }
    }

    pub fn loadTrackerOverrides(self: *SimResumeBackend, allocator: std.mem.Allocator, info_hash: [20]u8) ![]TrackerOverride {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(TrackerOverride).empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item.url);
                allocator.free(item.action);
                if (item.orig_url) |ou| allocator.free(ou);
            }
            result.deinit(allocator);
        }
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        for (self.tracker_overrides.items) |row| {
            if (!std.mem.eql(u8, &row.info_hash, &info_hash)) continue;
            const url = try allocator.dupe(u8, row.url);
            errdefer allocator.free(url);
            const action = try allocator.dupe(u8, row.action);
            errdefer allocator.free(action);
            const orig: ?[]const u8 = if (row.orig_url) |o| try allocator.dupe(u8, o) else null;
            try result.append(allocator, .{
                .url = url,
                .tier = row.tier,
                .action = action,
                .orig_url = orig,
            });
        }
        // Sort by tier ASC to match SqliteBackend's ORDER BY tier.
        const Lt = struct {
            fn lt(_: void, a: TrackerOverride, b: TrackerOverride) bool {
                return a.tier < b.tier;
            }
        };
        const slice = try result.toOwnedSlice(allocator);
        std.mem.sort(TrackerOverride, slice, {}, Lt.lt);
        return slice;
    }

    /// Static helper, mirrors `SqliteBackend.freeTrackerOverrides`.
    pub fn freeTrackerOverrides(allocator: std.mem.Allocator, overrides: []const TrackerOverride) void {
        for (overrides) |item| {
            allocator.free(item.url);
            allocator.free(item.action);
            if (item.orig_url) |ou| allocator.free(ou);
        }
        allocator.free(overrides);
    }

    // ── IP filter config (singleton) ──────────────────────

    pub fn loadIpFilterConfig(self: *SimResumeBackend, allocator: std.mem.Allocator) !IpFilterConfig {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldReadFault()) return .{};
        const cfg = self.ipfilter_config orelse return .{};
        const path: ?[]const u8 = if (cfg.path) |p| try allocator.dupe(u8, p) else null;
        return .{
            .path = path,
            .enabled = cfg.enabled,
            .rule_count = cfg.rule_count,
        };
    }

    pub fn saveIpFilterConfig(self: *SimResumeBackend, config: IpFilterConfig) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;

        if (self.ipfilter_config) |old| {
            if (old.path) |p| self.allocator.free(p);
        }
        const owned_path: ?[]const u8 = if (config.path) |p| try self.allocator.dupe(u8, p) else null;
        self.ipfilter_config = .{
            .path = owned_path,
            .enabled = config.enabled,
            .rule_count = config.rule_count,
        };
    }

    // ── Queue positions ───────────────────────────────────

    pub fn saveQueuePosition(self: *SimResumeBackend, info_hash_hex: [40]u8, position: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        try self.queue_positions.put(self.allocator, info_hash_hex, position);
    }

    pub fn removeQueuePosition(self: *SimResumeBackend, info_hash_hex: [40]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        _ = self.queue_positions.remove(info_hash_hex);
    }

    pub fn clearQueuePositions(self: *SimResumeBackend) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shouldCommitFault()) return error.SqliteCommitFailed;
        if (self.shouldSilentDrop()) return;
        self.queue_positions.clearRetainingCapacity();
    }

    pub fn loadQueuePositions(self: *SimResumeBackend, allocator: std.mem.Allocator) ![]QueuePosition {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(QueuePosition).empty;
        errdefer result.deinit(allocator);
        if (self.shouldReadFault()) return result.toOwnedSlice(allocator);

        var it = self.queue_positions.iterator();
        while (it.next()) |entry| {
            try result.append(allocator, .{
                .info_hash_hex = entry.key_ptr.*,
                .position = entry.value_ptr.*,
            });
        }
        // Sort ASC by position to match `SqliteBackend.loadQueuePositions`.
        const Lt = struct {
            fn lt(_: void, a: QueuePosition, b: QueuePosition) bool {
                return a.position < b.position;
            }
        };
        const slice = try result.toOwnedSlice(allocator);
        std.mem.sort(QueuePosition, slice, {}, Lt.lt);
        return slice;
    }
};

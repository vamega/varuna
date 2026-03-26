const std = @import("std");
const posix = std.posix;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const Ring = @import("../io/ring.zig").Ring;
const EventLoop = @import("../io/event_loop.zig").EventLoop;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;

pub const State = enum {
    checking,
    downloading,
    seeding,
    paused,
    stopped,
    @"error",
};

pub const Stats = struct {
    state: State,
    progress: f64, // 0.0 to 1.0
    download_speed: u64 = 0,
    upload_speed: u64 = 0,
    pieces_have: u32 = 0,
    pieces_total: u32 = 0,
    total_size: u64 = 0,
    bytes_downloaded: u64 = 0,
    bytes_uploaded: u64 = 0,
    peers_connected: u16 = 0,
    name: []const u8 = "",
    info_hash_hex: [40]u8 = [_]u8{'0'} ** 40,
    save_path: []const u8 = "",
    added_on: i64 = 0,
};

pub const TorrentSession = struct {
    allocator: std.mem.Allocator,
    state: State = .stopped,
    torrent_bytes: []const u8,
    save_path: []const u8,
    session: ?session_mod.Session = null,
    piece_tracker: ?PieceTracker = null,
    store: ?storage.writer.PieceStore = null,
    ring: ?Ring = null,
    shared_fds: ?[]posix.fd_t = null,
    info_hash: [20]u8,
    info_hash_hex: [40]u8,
    name: []const u8,
    total_size: u64,
    piece_count: u32,
    added_on: i64,
    error_message: ?[]const u8 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        save_path: []const u8,
    ) !TorrentSession {
        // Parse torrent metadata without fully loading session
        const owned_bytes = try allocator.dupe(u8, torrent_bytes);
        errdefer allocator.free(owned_bytes);

        const meta = try @import("../torrent/metainfo.zig").parse(allocator, owned_bytes);
        defer @import("../torrent/metainfo.zig").freeMetainfo(allocator, meta);

        const owned_save_path = try allocator.dupe(u8, save_path);
        errdefer allocator.free(owned_save_path);

        const owned_name = try allocator.dupe(u8, meta.name);
        errdefer allocator.free(owned_name);

        return .{
            .allocator = allocator,
            .torrent_bytes = owned_bytes,
            .save_path = owned_save_path,
            .info_hash = meta.info_hash,
            .info_hash_hex = std.fmt.bytesToHex(meta.info_hash, .lower),
            .name = owned_name,
            .total_size = meta.totalSize(),
            .piece_count = try meta.pieceCount(),
            .added_on = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *TorrentSession) void {
        self.stopInternal();
        self.allocator.free(self.torrent_bytes);
        self.allocator.free(self.save_path);
        self.allocator.free(self.name);
        if (self.error_message) |msg| self.allocator.free(msg);
    }

    pub fn start(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding or self.state == .checking) return;

        self.state = .checking;
        // Load session, recheck, announce -- on a background thread
        const thread = std.Thread.spawn(.{}, startWorker, .{self}) catch {
            self.state = .@"error";
            return;
        };
        thread.detach();
    }

    pub fn pause(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding) {
            self.state = .paused;
            // TODO: stop event loop, disconnect peers
        }
    }

    pub fn resume_session(self: *TorrentSession) void {
        if (self.state == .paused) {
            self.start();
        }
    }

    pub fn stop(self: *TorrentSession) void {
        self.stopInternal();
        self.state = .stopped;
    }

    pub fn getStats(self: *const TorrentSession) Stats {
        const pieces_have = if (self.piece_tracker) |*pt| pt.completedCount() else 0;
        const progress = if (self.piece_count > 0)
            @as(f64, @floatFromInt(pieces_have)) / @as(f64, @floatFromInt(self.piece_count))
        else
            0.0;

        return .{
            .state = self.state,
            .progress = progress,
            .pieces_have = pieces_have,
            .pieces_total = self.piece_count,
            .total_size = self.total_size,
            .name = self.name,
            .info_hash_hex = self.info_hash_hex,
            .save_path = self.save_path,
            .added_on = self.added_on,
            .peers_connected = 0, // TODO: from event loop
        };
    }

    fn startWorker(self: *TorrentSession) void {
        self.doStart() catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
        };
    }

    fn doStart(self: *TorrentSession) !void {
        // Initialize ring for file I/O
        const ring = try Ring.init(16);
        self.ring = ring;

        // Load session
        const session = try session_mod.Session.load(self.allocator, self.torrent_bytes, self.save_path);
        self.session = session;

        // Create PieceStore
        const store = try storage.writer.PieceStore.init(self.allocator, &self.session.?, &self.ring.?);
        self.store = store;

        // Recheck existing data
        var recheck = try storage.verify.recheckExistingData(self.allocator, &self.session.?, &self.store.?, null);
        defer recheck.deinit(self.allocator);

        // Create piece tracker
        self.piece_tracker = try PieceTracker.init(
            self.allocator,
            session.pieceCount(),
            session.layout.piece_length,
            session.totalSize(),
            &recheck.complete_pieces,
            recheck.bytes_complete,
        );

        if (recheck.bytes_complete == session.totalSize()) {
            self.state = .seeding;
        } else {
            self.state = .downloading;
            // TODO: announce to tracker, start event loop with peers
        }
    }

    fn stopInternal(self: *TorrentSession) void {
        if (self.shared_fds) |fds| {
            self.allocator.free(fds);
            self.shared_fds = null;
        }
        if (self.store) |*s| {
            s.deinit();
            self.store = null;
        }
        if (self.piece_tracker) |*pt| {
            pt.deinit(self.allocator);
            self.piece_tracker = null;
        }
        if (self.session) |s| {
            s.deinit(self.allocator);
            self.session = null;
        }
        if (self.ring) |*r| {
            r.deinit();
            self.ring = null;
        }
    }
};

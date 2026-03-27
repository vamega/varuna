const std = @import("std");
const posix = std.posix;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const Ring = @import("../io/ring.zig").Ring;
const EventLoop = @import("../io/event_loop.zig").EventLoop;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const signal = @import("../io/signal.zig");
const peer_id_mod = @import("../torrent/peer_id.zig");

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
    progress: f64,
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
    error_msg: ?[]const u8 = null,
};

pub const TorrentSession = struct {
    allocator: std.mem.Allocator,
    state: State = .stopped,
    torrent_bytes: []const u8,
    save_path: []const u8,

    // Parsed metadata
    info_hash: [20]u8,
    info_hash_hex: [40]u8,
    name: []const u8,
    total_size: u64,
    piece_count: u32,
    added_on: i64,
    peer_id: [20]u8,

    // Runtime state (created on start, freed on stop)
    session: ?session_mod.Session = null,
    piece_tracker: ?PieceTracker = null,
    store: ?storage.writer.PieceStore = null,
    ring: ?Ring = null,
    shared_fds: ?[]posix.fd_t = null,
    event_loop: ?EventLoop = null,
    thread: ?std.Thread = null,

    // Config
    port: u16 = 6881,
    max_peers: u32 = 50,
    hasher_threads: u32 = 4,

    error_message: ?[]const u8 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        save_path: []const u8,
    ) !TorrentSession {
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
            .peer_id = peer_id_mod.generate(),
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
        self.thread = std.Thread.spawn(.{}, startWorker, .{self}) catch {
            self.state = .@"error";
            return;
        };
    }

    pub fn pause(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding) {
            self.state = .paused;
            if (self.event_loop) |*el| el.stop();
        }
    }

    pub fn resume_session(self: *TorrentSession) void {
        if (self.state == .paused) {
            self.start();
        }
    }

    pub fn stop(self: *TorrentSession) void {
        if (self.event_loop) |*el| el.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.stopInternal();
        self.state = .stopped;
    }

    pub fn getStats(self: *TorrentSession) Stats {
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
            .peers_connected = if (self.event_loop) |*el| el.peer_count else 0,
            .error_msg = self.error_message,
        };
    }

    // ── Background thread ─────────────────────────────────

    fn startWorker(self: *TorrentSession) void {
        self.doStart() catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
        };
    }

    fn doStart(self: *TorrentSession) !void {
        const ring = try Ring.init(16);
        self.ring = ring;

        const session = try session_mod.Session.load(self.allocator, self.torrent_bytes, self.save_path);
        self.session = session;

        const store = try storage.writer.PieceStore.init(self.allocator, &self.session.?, &self.ring.?);
        self.store = store;

        // Recheck
        self.state = .checking;
        var recheck = try storage.verify.recheckExistingData(self.allocator, &self.session.?, &self.store.?, null);
        defer recheck.deinit(self.allocator);

        const piece_tracker = try PieceTracker.init(
            self.allocator,
            session.pieceCount(),
            session.layout.piece_length,
            session.totalSize(),
            &recheck.complete_pieces,
            recheck.bytes_complete,
        );
        self.piece_tracker = piece_tracker;

        if (recheck.bytes_complete == session.totalSize()) {
            self.state = .seeding;
            // TODO: announce as seeder, accept inbound peers
            return;
        }

        // Download: announce to tracker, get peers, run event loop
        self.state = .downloading;

        const announce_url = session.metainfo.announce orelse return error.MissingAnnounceUrl;
        const announce_response = tracker.announce.fetchAuto(self.allocator, &self.ring.?, .{
            .announce_url = announce_url,
            .info_hash = session.metainfo.info_hash,
            .peer_id = self.peer_id,
            .port = self.port,
            .left = session.totalSize() - recheck.bytes_complete,
        }) catch {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "tracker announce failed: {s}", .{announce_url}) catch null;
            return;
        };
        defer tracker.announce.freeResponse(self.allocator, announce_response);

        if (announce_response.peers.len == 0) {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "no peers from tracker", .{}) catch null;
            return;
        }

        // Get shared file handles
        const shared_fds = try self.store.?.fileHandles(self.allocator);
        self.shared_fds = shared_fds;

        // Create and run event loop
        const event_loop = try EventLoop.init(
            self.allocator,
            &self.session.?,
            &self.piece_tracker.?,
            shared_fds,
            self.peer_id,
            self.hasher_threads,
        );
        self.event_loop = event_loop;

        // Add peers
        var peers_added: u32 = 0;
        for (announce_response.peers) |peer| {
            if (peers_added >= self.max_peers) break;
            _ = self.event_loop.?.addPeer(peer.address) catch continue;
            peers_added += 1;
        }

        if (peers_added == 0) {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "could not connect to any peers", .{}) catch null;
            return;
        }

        // Submit timeout for periodic checks
        self.event_loop.?.submitTimeout(2 * std.time.ns_per_s) catch {};

        // Run event loop until complete, paused, or shutdown
        while (self.state == .downloading and !signal.isShutdownRequested()) {
            self.event_loop.?.tick() catch break;

            if (self.piece_tracker.?.isComplete()) {
                // Drain hasher results + pending disk writes
                var drain: u32 = 0;
                while (drain < 200) : (drain += 1) {
                    self.event_loop.?.processHashResults();
                    if (self.event_loop.?.pending_writes.items.len > 0) {
                        self.event_loop.?.submitTimeout(10 * std.time.ns_per_ms) catch {};
                        self.event_loop.?.tick() catch break;
                    } else if (drain > 50) {
                        break;
                    } else {
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                    }
                }

                self.state = .seeding;
                self.store.?.sync() catch {};

                // Send completed event (best-effort)
                if (tracker.announce.fetchAuto(self.allocator, &self.ring.?, .{
                    .announce_url = announce_url,
                    .info_hash = session.metainfo.info_hash,
                    .peer_id = self.peer_id,
                    .port = self.port,
                    .left = 0,
                    .event = .completed,
                })) |resp| {
                    tracker.announce.freeResponse(self.allocator, resp);
                } else |_| {}
                break;
            }

            if (self.event_loop.?.peer_count == 0) break;

            // Re-submit timeout
            self.event_loop.?.submitTimeout(2 * std.time.ns_per_s) catch {};
        }
    }

    fn stopInternal(self: *TorrentSession) void {
        if (self.event_loop) |*el| {
            el.deinit();
            self.event_loop = null;
        }
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

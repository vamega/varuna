const std = @import("std");
const posix = std.posix;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const EventLoop = @import("../io/event_loop.zig").EventLoop;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const file_priority = @import("../torrent/file_priority.zig");
const FilePriority = file_priority.FilePriority;
const peer_id_mod = @import("../torrent/peer_id.zig");
const magnet_mod = @import("../torrent/magnet.zig");
const ut_metadata = @import("../net/ut_metadata.zig");
const metadata_fetch = @import("../net/metadata_fetch.zig");
const ResumeWriter = storage.resume_state.ResumeWriter;
const ResumeDb = storage.resume_state.ResumeDb;
const TrackerExecutor = @import("tracker_executor.zig").TrackerExecutor;
const UdpTrackerExecutor = @import("udp_tracker_executor.zig").UdpTrackerExecutor;
const TorrentId = @import("../io/event_loop.zig").TorrentId;
const Bitfield = @import("../bitfield.zig").Bitfield;
const AsyncRecheck = @import("../io/recheck.zig").AsyncRecheck;
const AsyncMetadataFetch = @import("../io/metadata_handler.zig").AsyncMetadataFetch;

/// Mutable tracker URL storage. Tracks user-added, user-removed,
/// and user-edited tracker URLs as overlays on top of the metainfo
/// announce-list. Persisted to SQLite via the `tracker_overrides` table.
pub const TrackerOverrides = struct {
    /// URLs added by the user (not in metainfo). Each entry is (url, tier).
    added: std.ArrayList(TrackerEntry) = std.ArrayList(TrackerEntry).empty,
    /// URLs from metainfo that the user wants removed.
    removed: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    /// URL replacements: orig_url -> new_url.
    edits: std.ArrayList(TrackerEdit) = std.ArrayList(TrackerEdit).empty,

    pub const TrackerEntry = struct {
        url: []const u8,
        tier: u32,
    };

    pub const TrackerEdit = struct {
        orig_url: []const u8,
        new_url: []const u8,
    };

    pub fn deinit(self: *TrackerOverrides, allocator: std.mem.Allocator) void {
        for (self.added.items) |entry| allocator.free(entry.url);
        self.added.deinit(allocator);
        for (self.removed.items) |url| allocator.free(url);
        self.removed.deinit(allocator);
        for (self.edits.items) |edit| {
            allocator.free(edit.orig_url);
            allocator.free(edit.new_url);
        }
        self.edits.deinit(allocator);
    }

    /// Check if a URL is in the removed list.
    pub fn isRemoved(self: *const TrackerOverrides, url: []const u8) bool {
        for (self.removed.items) |removed_url| {
            if (std.mem.eql(u8, removed_url, url)) return true;
        }
        return false;
    }

    /// Get the replacement URL for an edited tracker, or null if not edited.
    pub fn getEdit(self: *const TrackerOverrides, orig_url: []const u8) ?[]const u8 {
        for (self.edits.items) |edit| {
            if (std.mem.eql(u8, edit.orig_url, orig_url)) return edit.new_url;
        }
        return null;
    }

    /// Get the highest tier number across metainfo + added trackers.
    pub fn maxAddedTier(self: *const TrackerOverrides) u32 {
        var max: u32 = 0;
        for (self.added.items) |entry| {
            if (entry.tier > max) max = entry.tier;
        }
        return max;
    }
};

pub const State = enum {
    checking,
    metadata_fetching,
    downloading,
    seeding,
    paused,
    stopped,
    queued,
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
    /// Per-torrent download speed limit (bytes/sec). 0 = unlimited.
    dl_limit: u64 = 0,
    /// Per-torrent upload speed limit (bytes/sec). 0 = unlimited.
    ul_limit: u64 = 0,
    /// Estimated time remaining in seconds. -1 if unknown or not downloading.
    eta: i64 = -1,
    /// Share ratio: bytes_uploaded / bytes_downloaded. 0.0 if no downloads yet.
    ratio: f64 = 0.0,
    /// Whether sequential download mode is enabled.
    sequential_download: bool = false,
    /// Whether this is a private torrent (BEP 27).
    is_private: bool = false,
    /// Whether BEP 16 super-seeding is enabled.
    super_seeding: bool = false,
    /// BEP 21: whether we are a partial seed (upload_only). All wanted
    /// files are complete but not all pieces in the torrent.
    partial_seed: bool = false,
    /// Tracker scrape result: seeders, leechers, snatches.
    scrape_complete: u32 = 0,
    scrape_incomplete: u32 = 0,
    scrape_downloaded: u32 = 0,
    /// Category assigned to this torrent (empty string if none).
    category: []const u8 = "",
    /// Comma-separated tags assigned to this torrent (empty string if none).
    tags: []const u8 = "",

    // ── Metadata fetch progress (BEP 9 magnet links) ────
    /// Total metadata size in bytes (0 if not yet known).
    metadata_size: u32 = 0,
    /// Number of metadata pieces received so far.
    metadata_pieces_received: u32 = 0,
    /// Total number of metadata pieces needed.
    metadata_pieces_total: u32 = 0,
    /// Number of peers attempted for metadata download.
    metadata_peers_attempted: u32 = 0,
    /// Number of peers that support ut_metadata.
    metadata_peers_with_metadata: u32 = 0,
    /// BEP 52: full v2 info-hash (32 bytes, SHA-256). null for pure v1.
    info_hash_v2: ?[32]u8 = null,
    /// Queue position (1-based). 0 means not queued or queueing disabled.
    queue_position: u32 = 0,
    /// Per-torrent ratio limit override (-2 = use global, -1 = no limit, >=0 = specific).
    ratio_limit: f64 = -2.0,
    /// Per-torrent seeding time limit override in minutes (-2 = use global, -1 = no limit, >=0 = specific).
    seeding_time_limit: i64 = -2,
    /// Timestamp when the torrent completed downloading (0 if not yet complete).
    completion_on: i64 = 0,
    /// Seeding time in seconds (time since completion, 0 if not seeding).
    seeding_time: i64 = 0,
    /// Primary tracker URL (first announce URL). Empty string if none.
    tracker: []const u8 = "",
    /// Total number of tracker URLs configured for this torrent.
    trackers_count: u32 = 0,
    /// Content path: for single-file torrents the full file path,
    /// for multi-file torrents the directory path.
    content_path: []const u8 = "",
    /// Number of files in this torrent.
    num_files: u32 = 0,
};

pub const TorrentSession = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
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
    tracker_key: [8]u8,

    // BEP 52: full v2 info-hash (32 bytes, SHA-256). null for pure v1.
    info_hash_v2: ?[32]u8 = null,

    // Runtime state (created on start, freed on stop)
    session: ?session_mod.Session = null,
    piece_tracker: ?PieceTracker = null,
    store: ?storage.writer.PieceStore = null,
    shared_fds: ?[]posix.fd_t = null,
    shared_event_loop: ?*EventLoop = null,
    tracker_executor: ?*TrackerExecutor = null,
    udp_tracker_executor: ?*UdpTrackerExecutor = null,
    torrent_id_in_shared: ?TorrentId = null,
    pending_peers: ?[]std.net.Address = null, // peers waiting for main thread to add
    pending_seed_setup: bool = false, // signals main thread to set up seed mode
    background_init_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // signals main thread that background init finished
    resume_pieces: ?Bitfield = null, // known-complete pieces from resume DB, consumed by async recheck
    dht_registered: bool = false, // whether DHT requestPeers has been called
    thread: ?std.Thread = null,
    announcing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    announce_jobs_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Resume state persistence (runs on background thread)
    resume_writer: ?ResumeWriter = null,
    resume_last_count: u32 = 0,

    // Lifetime transfer stats baseline loaded from DB on startup.
    // Current session totals (from event loop peers) are added on top.
    baseline_uploaded: u64 = 0,
    baseline_downloaded: u64 = 0,

    // Metainfo flags
    is_private: bool = false,

    // Config
    port: u16 = 6881,
    /// Skip tracker announces and rely on DHT/PEX for peer discovery.
    /// Set from config.network.disable_trackers. Private torrents ignore this.
    disable_trackers: bool = false,
    max_peers: u32 = 50,
    hasher_threads: u32 = 4,
    resume_db_path: ?[*:0]const u8 = null,

    // Per-torrent speed limits (bytes/sec, 0 = unlimited)
    dl_limit: u64 = 0,
    ul_limit: u64 = 0,

    // Per-torrent share limits (-2 = use global, -1 = disabled, >=0 = override)
    /// Ratio limit override. -2 = use global setting, -1 = no limit, >=0 = specific limit.
    ratio_limit: f64 = -2.0,
    /// Seeding time limit override in minutes. -2 = use global, -1 = no limit, >=0 = specific.
    seeding_time_limit: i64 = -2,

    /// Timestamp when the torrent completed downloading (all pieces have).
    /// 0 means not yet completed. Used to compute seeding time accurately.
    completion_on: i64 = 0,

    // Sequential download mode (stored, but actual piece picking depends on workstream B)
    sequential_download: bool = false,

    // BEP 16: super-seeding mode (initial seed optimization)
    super_seeding: bool = false,

    // Per-file priorities: 0=skip, 1=normal, 6=high, 7=max (stored, actual selective
    // download depends on workstream B). null means all files are normal priority.
    file_priorities: ?[]u8 = null,

    error_message: ?[]const u8 = null,

    // Category and tags
    category: ?[]const u8 = null,
    tags: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty,
    /// Pre-computed comma-separated tags string for Stats serialization.
    tags_string: ?[]const u8 = null,

    // Tracker URL overrides (user-added/removed/edited trackers, persisted in SQLite)
    // These are applied on top of the metainfo's announce-list.
    tracker_overrides: TrackerOverrides = .{},

    // Connection diagnostics (updated from event loop callbacks)
    conn_attempts: u64 = 0,
    conn_failures: u64 = 0,
    conn_timeout_failures: u64 = 0,
    conn_refused_failures: u64 = 0,

    // Scrape state
    scrape_result: ?tracker.scrape.ScrapeResult = null,
    last_scrape_time: i64 = 0,
    scraping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scrape_jobs_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Magnet link state (BEP 9)
    is_magnet: bool = false,
    magnet_trackers: ?[]const []const u8 = null,
    metadata_assembler: ?ut_metadata.MetadataAssembler = null,
    /// Latest metadata fetch progress snapshot (updated during fetch).
    metadata_fetch_progress: ?metadata_fetch.FetchProgress = null,

    pub fn createFromMagnet(
        allocator: std.mem.Allocator,
        magnet_uri: []const u8,
        save_path: []const u8,
        masquerade_as: ?[]const u8,
    ) !TorrentSession {
        const parsed = try magnet_mod.parse(allocator, magnet_uri);
        errdefer parsed.deinit(allocator);

        const owned_save_path = try allocator.dupe(u8, save_path);
        errdefer allocator.free(owned_save_path);

        const owned_name = if (parsed.display_name) |dn|
            try allocator.dupe(u8, dn)
        else
            try allocator.dupe(u8, &std.fmt.bytesToHex(parsed.info_hash, .lower));
        errdefer allocator.free(owned_name);

        // We take ownership of the tracker URLs from the parsed magnet
        // (they are already heap-allocated by magnet.parse).
        const trackers = parsed.trackers;

        // Free display_name since we duped it above. Don't free trackers -- we own them now.
        if (parsed.display_name) |dn| allocator.free(dn);
        // Don't call parsed.deinit() -- we stole trackers ownership.

        return .{
            .allocator = allocator,
            .torrent_bytes = &.{}, // no torrent bytes yet
            .save_path = owned_save_path,
            .info_hash = parsed.info_hash,
            .info_hash_hex = std.fmt.bytesToHex(parsed.info_hash, .lower),
            .name = owned_name,
            .total_size = 0, // unknown until metadata fetched
            .piece_count = 0, // unknown until metadata fetched
            .added_on = std.time.timestamp(),
            .peer_id = try peer_id_mod.generate(masquerade_as),
            .tracker_key = tracker.announce.Request.generateKey(),
            .is_magnet = true,
            .magnet_trackers = if (trackers.len > 0) trackers else null,
        };
    }

    pub fn create(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        save_path: []const u8,
        masquerade_as: ?[]const u8,
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
            .peer_id = try peer_id_mod.generate(masquerade_as),
            .tracker_key = tracker.announce.Request.generateKey(),
            .is_private = meta.private,
            .info_hash_v2 = meta.info_hash_v2,
        };
    }

    pub fn deinit(self: *TorrentSession) void {
        self.stop();
        if (self.resume_pieces) |*rp| rp.deinit(self.allocator);
        if (self.pending_peers) |pp| self.allocator.free(pp);
        if (self.torrent_bytes.len > 0) self.allocator.free(self.torrent_bytes);
        self.allocator.free(self.save_path);
        self.allocator.free(self.name);
        if (self.file_priorities) |fp| self.allocator.free(fp);
        if (self.error_message) |msg| self.allocator.free(msg);
        if (self.category) |cat| self.allocator.free(cat);
        for (self.tags.items) |tag| self.allocator.free(tag);
        self.tags.deinit(self.allocator);
        if (self.tags_string) |ts| self.allocator.free(ts);
        self.tracker_overrides.deinit(self.allocator);
        // Magnet-specific cleanup
        if (self.magnet_trackers) |trackers| {
            for (trackers) |tr| self.allocator.free(tr);
            self.allocator.free(trackers);
        }
        if (self.metadata_assembler) |*ma| ma.deinit();
    }

    /// Start in daemon mode with the configured shared event loop.
    pub fn start(self: *TorrentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.startLocked();
    }

    fn startLocked(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding or self.state == .checking or self.state == .metadata_fetching) return;
        if (self.shared_event_loop == null) {
            self.state = .@"error";
            if (self.error_message == null) {
                self.error_message = std.fmt.allocPrint(self.allocator, "shared event loop required", .{}) catch null;
            }
            return;
        }

        self.state = .checking;
        self.thread = std.Thread.spawn(.{}, startWorker, .{self}) catch {
            self.state = .@"error";
            return;
        };
    }

    pub fn pause(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding) {
            self.state = .paused;
            self.detachFromSharedEventLoop();
            // Wait for background thread to exit
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            // Flush resume state after thread has exited
            self.persistNewCompletions();
            self.flushResume();
        }
    }

    pub fn unpause(self: *TorrentSession) void {
        if (self.state == .paused) {
            // Clean up old resources before restarting
            self.waitForBackgroundNetworkJobs();
            self.stopInternal();
            self.start();
        }
    }

    pub fn stop(self: *TorrentSession) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.detachFromSharedEventLoop();
        self.waitForBackgroundNetworkJobs();
        self.stopInternal();
        self.state = .stopped;
    }

    /// Called by the main thread after the background init thread completes
    /// and the session is in .checking state. Starts async piece recheck
    /// on the event loop. Returns true if recheck was started.
    pub fn integrateIntoEventLoop(self: *TorrentSession) bool {
        // Snapshot state under lock, then release before starting async
        // operations whose completion callbacks will re-acquire the mutex.
        const Action = enum { none, metadata_fetch, recheck, skip_recheck };
        var action: Action = .none;
        var sel_ptr: ?*EventLoop = null;
        var peers_snapshot: ?[]const std.net.Address = null;
        var known_ptr: ?*const Bitfield = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.background_init_done.load(.acquire)) return false;
            sel_ptr = self.shared_event_loop;
            if (sel_ptr == null) return false;

            if (self.state == .metadata_fetching) {
                action = .metadata_fetch;
                peers_snapshot = self.pending_peers orelse &[_]std.net.Address{};
                self.background_init_done.store(false, .release);
            } else if (self.state == .checking and self.session != null and self.shared_fds != null) {
                // If there's no resume data, skip the expensive piece-by-piece
                // recheck — all pieces are known incomplete (fresh download).
                if (self.resume_pieces == null) {
                    action = .skip_recheck;
                } else {
                    action = .recheck;
                    known_ptr = if (self.resume_pieces) |*rp| rp else null;
                }
                self.background_init_done.store(false, .release);
            }
        }

        const sel = sel_ptr orelse return false;

        switch (action) {
            .metadata_fetch => {
                sel.startMetadataFetch(
                    self.info_hash,
                    self.peer_id,
                    self.port,
                    self.is_private,
                    peers_snapshot.?,
                    onMetadataFetchComplete,
                    @ptrCast(self),
                ) catch {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.state = .@"error";
                    self.error_message = std.fmt.allocPrint(self.allocator, "failed to start async metadata fetch", .{}) catch null;
                    return false;
                };
                return true;
            },
            .recheck => {
                sel.startRecheck(
                    &self.session.?,
                    self.shared_fds.?,
                    0,
                    known_ptr,
                    onRecheckComplete,
                    @ptrCast(self),
                ) catch {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    self.state = .@"error";
                    self.error_message = std.fmt.allocPrint(self.allocator, "failed to start async recheck", .{}) catch null;
                    return false;
                };
                return true;
            },
            .skip_recheck => {
                // Fresh download with no resume data — skip piece-by-piece
                // recheck and create an empty PieceTracker immediately.
                self.mutex.lock();
                defer self.mutex.unlock();

                const session = &(self.session orelse return false);
                var empty_bf = Bitfield.init(self.allocator, session.pieceCount()) catch return false;
                const pt = PieceTracker.init(
                    self.allocator,
                    session.pieceCount(),
                    session.layout.piece_length,
                    session.totalSize(),
                    &empty_bf,
                    0,
                ) catch {
                    empty_bf.deinit(self.allocator);
                    return false;
                };
                empty_bf.deinit(self.allocator);
                self.piece_tracker = pt;
                self.state = .downloading;
                if (self.pending_peers == null) {
                    self.pending_peers = self.allocator.alloc(std.net.Address, 0) catch null;
                }
                return true;
            },
            .none => return false,
        }
    }

    /// Called by the main thread to add peers to the event loop after
    /// recheck completes and the session transitions to downloading/seeding.
    /// Returns true if peers were added.
    pub fn addPeersToEventLoop(self: *TorrentSession) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sel = self.shared_event_loop orelse {
            std.log.warn("addPeersToEventLoop: no shared_event_loop", .{});
            return false;
        };
        const peers = self.pending_peers orelse {
            std.log.warn("addPeersToEventLoop: no pending_peers", .{});
            return false;
        };
        defer {
            self.allocator.free(peers);
            self.pending_peers = null;
        }

        if (self.session == null or self.piece_tracker == null or self.shared_fds == null) {
            std.log.warn("addPeersToEventLoop: missing state: session={} pt={} fds={}", .{
                self.session != null, self.piece_tracker != null, self.shared_fds != null,
            });
            return false;
        }

        const tid = sel.addTorrentWithKey(
            &self.session.?,
            &self.piece_tracker.?,
            self.shared_fds.?,
            self.peer_id,
            self.tracker_key,
            self.is_private,
        ) catch return false;
        self.torrent_id_in_shared = tid;

        // Set complete_pieces immediately so peers see the bitfield
        // during handshake. Must happen before addPeerForTorrent.
        if (self.piece_tracker) |*pt| {
            sel.setTorrentCompletePieces(tid, &pt.complete);
        }

        // Apply per-torrent speed limits to the event loop context
        if (self.dl_limit > 0) sel.setTorrentDlLimit(tid, self.dl_limit);
        if (self.ul_limit > 0) sel.setTorrentUlLimit(tid, self.ul_limit);

        // Apply file priorities (selective download) and sequential mode
        // to the piece tracker so claimPiece() respects them.
        _ = self.applyFilePriorities();
        self.applySequentialMode();

        var added: u32 = 0;
        for (peers) |addr| {
            self.conn_attempts += 1;
            _ = sel.addPeerForTorrent(addr, tid) catch {
                self.conn_failures += 1;
                continue;
            };
            added += 1;
        }

        // DHT peer discovery: force an immediate requery now that the torrent
        // is registered in the event loop (findTorrentIdByInfoHash will work).
        if (!self.is_private) {
            if (sel.dht_engine) |engine| {
                engine.forceRequery(self.info_hash);
            }
        }

        // Schedule initial announce now that the torrent is registered.
        if (self.state == .seeding) {
            self.scheduleCompletedAnnounce() catch |err| {
                std.log.warn("scheduleCompletedAnnounce failed: {s}", .{@errorName(err)});
            };
        } else if (self.state == .downloading) {
            self.scheduleReannounce() catch |err| {
                std.log.warn("scheduleReannounce failed: {s}", .{@errorName(err)});
            };
        }

        return added > 0 or self.state == .downloading or self.state == .seeding;
    }

    /// AsyncRecheck completion callback. Runs on the event loop thread.
    /// Creates PieceTracker from results, persists to resume DB, transitions
    /// state, and schedules announce via timerfd.
    fn onRecheckComplete(recheck: *AsyncRecheck) void {
        const self: *TorrentSession = if (recheck.caller_ctx) |ctx|
            @ptrCast(@alignCast(ctx))
        else
            return;

        const log = std.log.scoped(.torrent_session);
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = &(self.session orelse return);

        // Persist recheck results to resume DB for next startup
        if (self.resume_writer) |*rw| {
            var completed_pieces = std.ArrayList(u32).empty;
            defer completed_pieces.deinit(self.allocator);
            var idx: u32 = 0;
            while (idx < session.pieceCount()) : (idx += 1) {
                if (recheck.complete_pieces.has(idx)) {
                    completed_pieces.append(self.allocator, idx) catch {};
                }
            }
            if (completed_pieces.items.len > 0) {
                rw.db.markCompleteBatch(session.metainfo.info_hash, completed_pieces.items) catch {};
            }
        }
        self.resume_last_count = recheck.complete_pieces.count;

        // Create PieceTracker from recheck results
        // Snapshot recheck results before destroying it
        const recheck_bytes_complete = recheck.bytes_complete;
        const recheck_pieces_count = recheck.complete_pieces.count;

        const piece_tracker = PieceTracker.init(
            self.allocator,
            session.pieceCount(),
            session.layout.piece_length,
            session.totalSize(),
            &recheck.complete_pieces,
            recheck_bytes_complete,
        ) catch {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "failed to create piece tracker", .{}) catch null;
            // Still clean up the recheck
            if (self.shared_event_loop) |sel| sel.cancelRecheckForTorrent(recheck.torrent_id);
            return;
        };
        self.piece_tracker = piece_tracker;

        // Clean up the async recheck on the event loop (frees recheck struct)
        if (self.shared_event_loop) |sel| {
            sel.cancelRecheckForTorrent(recheck.torrent_id);
        }

        // Free resume_pieces now that recheck is done
        if (self.resume_pieces) |*rp| {
            rp.deinit(self.allocator);
            self.resume_pieces = null;
        }

        if (recheck_bytes_complete == session.totalSize()) {
            self.state = .seeding;
            if (self.completion_on == 0) {
                self.completion_on = std.time.timestamp();
            }
            self.pending_seed_setup = true;
            log.info("recheck complete: all pieces valid, entering seed mode", .{});
        } else {
            self.state = .downloading;
            log.info("recheck complete: {d}/{d} pieces, entering download mode", .{
                recheck_pieces_count,
                session.pieceCount(),
            });
        }

        // Set pending_peers so main loop calls addPeersToEventLoop, which
        // registers the torrent context and schedules the initial announce.
        if (self.pending_peers == null) {
            self.pending_peers = self.allocator.alloc(std.net.Address, 0) catch null;
        }
    }

    /// timerfd callback for jittered initial announce after recheck completes.
    fn onJitteredAnnounce(ctx: *anyopaque) void {
        const self: *TorrentSession = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state == .downloading or self.state == .seeding) {
            self.scheduleReannounce() catch {};
        }
    }

    /// Compute a deterministic jitter delay in milliseconds for the initial announce.
    /// Uses info_hash bytes for deterministic spread, capped at 5 seconds.
    fn computeAnnounceJitterMs(self: *const TorrentSession) u64 {
        const base_interval: u64 = 1800; // default tracker interval in seconds
        const max_delay_ms = (base_interval / 4) * std.time.ms_per_s;
        if (max_delay_ms == 0) return 0;
        const seed = @as(u64, self.info_hash[0]) |
            (@as(u64, self.info_hash[1]) << 8) |
            (@as(u64, self.info_hash[2]) << 16) |
            (@as(u64, self.info_hash[3]) << 24);
        const delay_ms = seed % max_delay_ms;
        return @min(delay_ms, 5 * std.time.ms_per_s);
    }

    /// Convert raw API priority (0=skip, 1=normal, 6=high, 7=max) to FilePriority enum.
    fn apiPriorityToEnum(raw: u8) FilePriority {
        return switch (raw) {
            0 => .do_not_download,
            6, 7 => .high,
            else => .normal,
        };
    }

    /// Build a wanted-piece mask from the current file_priorities and apply it
    /// to the piece_tracker via setWanted(). If no files are marked
    /// do_not_download the mask is cleared (want everything).
    /// Returns true if a mask was applied, false if all files are wanted.
    pub fn applyFilePriorities(self: *TorrentSession) bool {
        const pt = &(self.piece_tracker orelse return false);
        const sess = &(self.session orelse return false);
        const fp_raw = self.file_priorities orelse {
            // No priority array at all -- want everything.
            const old = pt.swapWanted(null);
            if (old) |o| {
                var copy = o;
                copy.deinit(self.allocator);
            }
            return false;
        };

        // Convert raw u8 priorities to FilePriority enums (stack-allocate up to 256 files,
        // heap-allocate for larger torrents).
        var stack_buf: [256]FilePriority = undefined;
        const fp_enums: []FilePriority = if (fp_raw.len <= stack_buf.len)
            stack_buf[0..fp_raw.len]
        else
            self.allocator.alloc(FilePriority, fp_raw.len) catch return false;
        defer if (fp_raw.len > stack_buf.len) self.allocator.free(fp_enums);

        for (fp_raw, 0..) |raw, i| {
            fp_enums[i] = apiPriorityToEnum(raw);
        }

        if (file_priority.allWanted(fp_enums)) {
            const old = pt.swapWanted(null);
            if (old) |o| {
                var copy = o;
                copy.deinit(self.allocator);
            }
            return false;
        }

        const mask = file_priority.buildPieceMask(
            self.allocator,
            &sess.layout,
            fp_enums,
        ) catch return false;

        // Swap in the new mask and free the old one. swapWanted atomically
        // replaces the mask under the PieceTracker mutex, so concurrent
        // claimPiece() calls see either the old or new mask, never a freed one.
        const old = pt.swapWanted(mask);
        if (old) |o| {
            var copy = o;
            copy.deinit(self.allocator);
        }
        return true;
    }

    /// Propagate the sequential_download flag to the piece_tracker.
    pub fn applySequentialMode(self: *TorrentSession) void {
        if (self.piece_tracker) |*pt| {
            pt.setSequential(self.sequential_download);
        }
    }

    /// Enable or disable BEP 16 super-seeding mode. Only meaningful when
    /// the torrent is in seeding state. The event loop manages the actual
    /// super-seed protocol behavior.
    pub fn setSuperSeeding(self: *TorrentSession, enabled: bool) void {
        self.super_seeding = enabled;
        const el = self.shared_event_loop orelse return;
        if (self.torrent_id_in_shared) |tid| {
            if (enabled) {
                el.enableSuperSeed(tid) catch {};
            } else {
                el.disableSuperSeed(tid);
            }
        }
    }

    /// Returns the pre-computed comma-separated tags string.
    fn getTagsString(self: *const TorrentSession) []const u8 {
        return self.tags_string orelse "";
    }

    /// Rebuild the cached comma-separated tags string. Must be called whenever
    /// the tags list changes. Caller must hold the SessionManager mutex.
    pub fn rebuildTagsString(self: *TorrentSession) void {
        if (self.tags_string) |old| {
            self.allocator.free(old);
            self.tags_string = null;
        }
        if (self.tags.items.len == 0) return;
        var total_len: usize = 0;
        for (self.tags.items, 0..) |tag, i| {
            if (i > 0) total_len += 2; // ", "
            total_len += tag.len;
        }
        const buf = self.allocator.alloc(u8, total_len) catch return;
        var pos: usize = 0;
        for (self.tags.items, 0..) |tag, i| {
            if (i > 0) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
            @memcpy(buf[pos..][0..tag.len], tag);
            pos += tag.len;
        }
        self.tags_string = buf;
    }

    fn isPartialSeed(self: *TorrentSession) bool {
        if (self.piece_tracker) |*pt| {
            return pt.isPartialSeed();
        }
        return false;
    }

    fn statsState(self: *const TorrentSession, pieces_have: u32, partial_seed: bool) State {
        if (self.state == .downloading and self.piece_count > 0 and pieces_have == self.piece_count) {
            return .seeding;
        }
        if (self.state == .downloading and partial_seed) {
            return .seeding;
        }
        return self.state;
    }

    pub fn getStats(self: *TorrentSession) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pieces_have = if (self.piece_tracker) |*pt| pt.completedCount() else 0;
        const progress = if (self.piece_count > 0)
            @as(f64, @floatFromInt(pieces_have)) / @as(f64, @floatFromInt(self.piece_count))
        else
            0.0;
        const partial_seed = self.isPartialSeed();
        const stats_state = self.statsState(pieces_have, partial_seed);

        // Read speed stats from the event loop
        const speed_stats = if (self.shared_event_loop) |sel|
            if (self.torrent_id_in_shared) |tid| sel.getSpeedStats(tid) else @import("../io/event_loop.zig").SpeedStats{}
        else
            @import("../io/event_loop.zig").SpeedStats{};

        // Lifetime totals = persisted baseline + current session
        const total_downloaded = self.baseline_downloaded + speed_stats.dl_total;
        const total_uploaded = self.baseline_uploaded + speed_stats.ul_total;

        // Compute ETA: bytes_remaining / download_speed
        const bytes_remaining = if (self.total_size > speed_stats.dl_total)
            self.total_size - speed_stats.dl_total
        else
            0;
        const eta: i64 = if (stats_state == .downloading and speed_stats.dl_speed > 0)
            @intCast(bytes_remaining / speed_stats.dl_speed)
        else
            -1;

        // Compute share ratio: uploaded / downloaded (lifetime)
        const ratio: f64 = if (total_downloaded > 0)
            @as(f64, @floatFromInt(total_uploaded)) / @as(f64, @floatFromInt(total_downloaded))
        else
            0.0;

        // Extract tracker and file metadata from parsed session (if available)
        const meta_opt = if (self.session) |*s| s.metainfo else null;
        const overrides = &self.tracker_overrides;
        // Primary tracker: use edited URL if applicable, or first added URL
        const tracker_url: []const u8 = if (meta_opt) |m| blk: {
            if (m.announce) |url| {
                if (!overrides.isRemoved(url)) {
                    break :blk overrides.getEdit(url) orelse url;
                }
            }
            // If primary was removed, try first available metainfo URL
            for (m.announce_list) |url| {
                if (!overrides.isRemoved(url)) {
                    break :blk overrides.getEdit(url) orelse url;
                }
            }
            // Try first user-added tracker
            if (overrides.added.items.len > 0) break :blk overrides.added.items[0].url;
            break :blk "";
        } else if (overrides.added.items.len > 0) overrides.added.items[0].url else "";
        const trackers_count: u32 = if (meta_opt) |m| blk: {
            var count: u32 = 0;
            if (m.announce) |url| {
                if (!overrides.isRemoved(url)) count += 1;
            }
            for (m.announce_list) |url| {
                if (overrides.isRemoved(url)) continue;
                if (m.announce) |primary| {
                    if (!std.mem.eql(u8, url, primary)) count += 1;
                } else {
                    count += 1;
                }
            }
            count += @intCast(overrides.added.items.len);
            break :blk count;
        } else @intCast(overrides.added.items.len);

        // content_path: single-file = save_path/name, multi-file = save_path/torrent_name
        const content_path: []const u8 = if (meta_opt) |m|
            (if (m.files.len == 1) self.save_path else self.save_path)
        else
            self.save_path;

        const num_files: u32 = if (meta_opt) |m|
            @intCast(m.files.len)
        else
            0;

        return .{
            .state = stats_state,
            .progress = progress,
            .download_speed = speed_stats.dl_speed,
            .upload_speed = speed_stats.ul_speed,
            .pieces_have = pieces_have,
            .pieces_total = self.piece_count,
            .total_size = self.total_size,
            .bytes_downloaded = total_downloaded,
            .bytes_uploaded = total_uploaded,
            .name = self.name,
            .info_hash_hex = self.info_hash_hex,
            .save_path = self.save_path,
            .added_on = self.added_on,
            .peers_connected = if (self.shared_event_loop) |sel| if (self.torrent_id_in_shared) |tid| sel.peerCountForTorrent(tid) else 0 else 0,
            .error_msg = self.error_message,
            .dl_limit = self.dl_limit,
            .ul_limit = self.ul_limit,
            .eta = eta,
            .ratio = ratio,
            .sequential_download = self.sequential_download,
            .is_private = self.is_private,
            .super_seeding = self.super_seeding,
            .info_hash_v2 = self.info_hash_v2,
            .partial_seed = partial_seed,
            .scrape_complete = if (self.scrape_result) |sr| sr.complete else 0,
            .scrape_incomplete = if (self.scrape_result) |sr| sr.incomplete else 0,
            .scrape_downloaded = if (self.scrape_result) |sr| sr.downloaded else 0,
            .category = self.category orelse "",
            .tags = self.getTagsString(),
            .metadata_size = if (self.metadata_fetch_progress) |p| p.metadata_size else 0,
            .metadata_pieces_received = if (self.metadata_fetch_progress) |p| p.pieces_received else 0,
            .metadata_pieces_total = if (self.metadata_fetch_progress) |p| p.pieces_total else 0,
            .metadata_peers_attempted = if (self.metadata_fetch_progress) |p| p.peers_attempted else 0,
            .metadata_peers_with_metadata = if (self.metadata_fetch_progress) |p| p.peers_with_metadata else 0,
            .ratio_limit = self.ratio_limit,
            .seeding_time_limit = self.seeding_time_limit,
            .completion_on = self.completion_on,
            .seeding_time = if (stats_state == .seeding and self.completion_on > 0) std.time.timestamp() - self.completion_on else 0,
            .tracker = tracker_url,
            .trackers_count = trackers_count,
            .content_path = content_path,
            .num_files = num_files,
        };
    }

    // ── Background thread ─────────────────────────────────

    fn startWorker(self: *TorrentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.doStartBackground() catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
        };
    }

    /// Background thread phase: parse torrent, create PieceStore, load resume DB.
    /// Does NOT do piece verification (that moves to the event loop via AsyncRecheck)
    /// and does NOT do blocking tracker announces (those use the ring-based executors).
    fn doStartBackground(self: *TorrentSession) !void {
        // Magnet link: collect peers via tracker announce, then hand off
        // to the event loop for async BEP 9 metadata fetch.
        if (self.is_magnet and self.torrent_bytes.len == 0) {
            try self.collectMagnetPeers();
            return; // event loop will start async metadata fetch
        }

        const session = try session_mod.Session.load(self.allocator, self.torrent_bytes, self.save_path);
        self.session = session;

        const store = try storage.writer.PieceStore.init(self.allocator, &self.session.?);
        self.store = store;

        // Open resume DB and load known-complete pieces (fast path: skip rehash)
        if (self.resume_db_path) |db_path| {
            if (ResumeWriter.init(self.allocator, db_path, session.metainfo.info_hash)) |rw| {
                self.resume_writer = rw;
                // Load known-complete pieces from DB
                var bf = Bitfield.init(self.allocator, session.pieceCount()) catch null;
                if (bf) |*loaded_bf| {
                    const loaded_count = self.resume_writer.?.db.loadCompletePieces(session.metainfo.info_hash, loaded_bf) catch 0;
                    if (loaded_count > 0) {
                        self.resume_pieces = loaded_bf.*;
                    } else {
                        loaded_bf.deinit(self.allocator);
                    }
                }
                // Load lifetime transfer stats so share ratio survives restarts
                const transfer_stats = self.resume_writer.?.loadTransferStats();
                self.baseline_uploaded = transfer_stats.total_uploaded;
                self.baseline_downloaded = transfer_stats.total_downloaded;

                // Load persisted rate limits for this torrent
                {
                    const limits = self.resume_writer.?.db.loadRateLimits(session.metainfo.info_hash);
                    if (limits.dl_limit > 0) self.dl_limit = limits.dl_limit;
                    if (limits.ul_limit > 0) self.ul_limit = limits.ul_limit;
                }

                // Load persisted share limits (ratio/seeding time overrides + completion_on)
                {
                    const share = self.resume_writer.?.db.loadShareLimits(session.metainfo.info_hash);
                    self.ratio_limit = share.ratio_limit;
                    self.seeding_time_limit = share.seeding_time_limit;
                    if (share.completion_on > 0) self.completion_on = share.completion_on;
                }

                // Load persisted category and tags for this torrent
                if (self.category == null) {
                    if (self.resume_writer.?.db.loadTorrentCategory(self.allocator, session.metainfo.info_hash)) |cat| {
                        self.category = cat;
                    } else |_| {}
                }
                if (self.tags.items.len == 0) {
                    if (self.resume_writer.?.db.loadTorrentTags(self.allocator, session.metainfo.info_hash)) |tags| {
                        for (tags) |tag| {
                            self.tags.append(self.allocator, tag) catch {
                                self.allocator.free(tag);
                            };
                        }
                        self.allocator.free(tags);
                        self.rebuildTagsString();
                    } else |_| {}
                }

                // Load persisted tracker overrides for this torrent
                if (self.tracker_overrides.added.items.len == 0 and
                    self.tracker_overrides.removed.items.len == 0 and
                    self.tracker_overrides.edits.items.len == 0)
                {
                    self.loadTrackerOverrides();
                }

                // BEP 52: persist v2 info-hash if this is a hybrid/v2 torrent
                if (session.metainfo.info_hash_v2) |v2_hash| {
                    self.resume_writer.?.db.saveInfoHashV2(session.metainfo.info_hash, v2_hash) catch {};
                }
                // If we have a v2 hash from metainfo, use it; otherwise try loading from DB
                if (self.info_hash_v2 == null) {
                    if (session.metainfo.info_hash_v2) |v2_hash| {
                        self.info_hash_v2 = v2_hash;
                    } else {
                        self.info_hash_v2 = self.resume_writer.?.db.loadInfoHashV2(session.metainfo.info_hash);
                    }
                }
            } else |_| {}
        }

        // Get shared file handles (needed for both recheck and serving pieces)
        const shared_fds = try self.store.?.fileHandles(self.allocator);
        self.shared_fds = shared_fds;

        // Stay in .checking state -- the event loop will run async recheck
        // via integrateIntoEventLoop -> startRecheck.
        self.state = .checking;
        self.background_init_done.store(true, .release);
    }

    fn stopInternal(self: *TorrentSession) void {
        // Flush resume state before tearing down (runs on caller's thread,
        // which is always a background thread -- never the event loop thread)
        self.persistNewCompletions();
        self.flushResume();
        if (self.resume_writer) |*rw| {
            rw.deinit();
            self.resume_writer = null;
        }

        if (self.resume_pieces) |*rp| {
            rp.deinit(self.allocator);
            self.resume_pieces = null;
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
        self.torrent_id_in_shared = null;
        self.pending_seed_setup = false;
        self.background_init_done.store(false, .release);
    }

    /// Called by the main thread to set up seed mode for this session
    /// in the shared event loop. Creates the torrent context if needed,
    /// sets complete_pieces, and returns true on success.
    pub fn integrateSeedIntoEventLoop(self: *TorrentSession) bool {
        const sel = self.shared_event_loop orelse return false;
        if (self.session == null or self.piece_tracker == null or self.shared_fds == null) return false;

        // Ensure the torrent is registered in the shared event loop
        if (self.torrent_id_in_shared == null) {
            const tid = sel.addTorrentWithKey(
                &self.session.?,
                &self.piece_tracker.?,
                self.shared_fds.?,
                self.peer_id,
                self.tracker_key,
                self.is_private,
            ) catch return false;
            self.torrent_id_in_shared = tid;

            // Apply per-torrent speed limits to the event loop context
            if (self.dl_limit > 0) sel.setTorrentDlLimit(tid, self.dl_limit);
            if (self.ul_limit > 0) sel.setTorrentUlLimit(tid, self.ul_limit);

            // Apply file priorities and sequential mode
            _ = self.applyFilePriorities();
            self.applySequentialMode();
        }

        // Set the complete_pieces bitfield so seed mode can serve pieces
        sel.setTorrentCompletePieces(
            self.torrent_id_in_shared.?,
            &self.piece_tracker.?.complete,
        );

        // DHT announce: tell the network we are seeding this torrent.
        // Disabled for private torrents (BEP 27).
        if (!self.is_private) {
            if (sel.dht_engine) |engine| {
                engine.announcePeer(self.info_hash, self.port) catch {};
            }
        }

        self.pending_seed_setup = false;
        return true;
    }

    /// Check if this session just completed downloading and needs seed setup.
    /// Called from the main thread during periodic checks.
    pub fn checkSeedTransition(self: *TorrentSession) bool {
        if (self.state != .downloading) return false;
        const pt = &(self.piece_tracker orelse return false);
        if (!pt.isComplete()) return false;

        // Transition to seeding
        self.state = .seeding;
        if (self.completion_on == 0) {
            self.completion_on = std.time.timestamp();
        }
        self.persistNewCompletions();
        self.flushResume();

        // Signal seed setup needed
        self.pending_seed_setup = true;

        self.scheduleCompletedAnnounce() catch {};

        return true;
    }

    fn makeAnnounceRequest(self: *TorrentSession, event: ?tracker.announce.Request.Event) ?tracker.announce.Request {
        const session = &(self.session orelse return null);
        return .{
            .announce_url = "",
            .info_hash = session.metainfo.info_hash,
            .peer_id = self.peer_id,
            .port = self.port,
            .left = 0,
            .event = event,
            .key = self.tracker_key,
            .info_hash_v2 = self.info_hash_v2,
        };
    }

    fn getTrackerHostForUrl(url: []const u8) ?[]const u8 {
        return (@import("../io/http.zig").parseUrl(url) catch return null).host;
    }

    fn submitTrackerJob(self: *TorrentSession, url: []const u8, host: []const u8, on_complete: TrackerExecutor.CompletionFn) !void {
        const executor = self.tracker_executor orelse return error.MissingTrackerExecutor;
        if (url.len > 2048) return error.UrlTooLong;
        if (host.len > 253) return error.HostNameTooLong;

        var job = TrackerExecutor.Job{
            .context = @ptrCast(self),
            .on_complete = on_complete,
            .url_len = @intCast(url.len),
            .host_len = @intCast(host.len),
        };
        @memcpy(job.url[0..url.len], url);
        @memcpy(job.host[0..host.len], host);
        try executor.submit(job);
    }

    pub fn scheduleCompletedAnnounce(self: *TorrentSession) !void {
        const request = self.makeAnnounceRequest(.completed) orelse return;
        if (self.announcing.swap(true, .acq_rel)) return;
        errdefer self.announcing.store(false, .release);
        try self.scheduleAnnounceJobs(request);
    }

    pub fn scheduleReannounce(self: *TorrentSession) !void {
        const request = self.makeAnnounceRequest(null) orelse return;
        if (self.announcing.swap(true, .acq_rel)) return;
        errdefer self.announcing.store(false, .release);
        try self.scheduleAnnounceJobs(request);
    }

    fn scheduleAnnounceJobs(self: *TorrentSession, base_request: tracker.announce.Request) !void {
        const session = &(self.session orelse return error.MissingSession);
        const tracker_urls = try self.buildTrackerUrls(session);
        defer self.allocator.free(tracker_urls);
        if (tracker_urls.len == 0) return error.NoTrackers;

        self.announce_jobs_in_flight.store(0, .release);
        var submitted: u32 = 0;

        for (tracker_urls) |tracker_url| {
            var request = base_request;
            request.announce_url = tracker_url;

            if (self.trySubmitUdpAnnounce(request)) {
                _ = self.announce_jobs_in_flight.fetchAdd(1, .acq_rel);
                submitted += 1;
                continue;
            }

            const host = getTrackerHostForUrl(tracker_url) orelse continue;
            const url = tracker.announce.buildUrl(self.allocator, request) catch continue;
            defer self.allocator.free(url);
            self.submitTrackerJob(url, host, announceComplete) catch continue;
            _ = self.announce_jobs_in_flight.fetchAdd(1, .acq_rel);
            submitted += 1;
        }

        if (submitted == 0) {
            self.announcing.store(false, .release);
            return error.NoTrackers;
        }
    }

    /// Try to submit an announce via the UDP tracker executor.
    /// Returns true if the URL was a UDP URL and the job was submitted.
    fn trySubmitUdpAnnounce(self: *TorrentSession, request: tracker.announce.Request) bool {
        const udp_mod = @import("../tracker/udp.zig");

        const parsed = udp_mod.parseUdpUrl(request.announce_url) orelse return false;
        const executor = self.udp_tracker_executor orelse return false;

        const key_value: u32 = if (request.key) |k| std.mem.readInt(u32, k[0..4], .big) else udp_mod.generateTransactionId();
        var job = UdpTrackerExecutor.Job{
            .context = @ptrCast(self),
            .on_complete = udpAnnounceComplete,
            .kind = .announce,
            .port = parsed.port,
            .info_hash = request.info_hash,
            .peer_id = request.peer_id,
            .downloaded = request.downloaded,
            .left = request.left,
            .uploaded = request.uploaded,
            .event = udp_mod.eventToUdp(request.event),
            .key = key_value,
            .num_want = @intCast(@min(request.numwant, std.math.maxInt(i32))),
            .listen_port = request.port,
            .host_len = @intCast(parsed.host.len),
        };
        @memcpy(job.host[0..parsed.host.len], parsed.host);
        executor.submit(job) catch return false;
        return true;
    }

    fn udpAnnounceComplete(context: *anyopaque, result: @import("udp_tracker_executor.zig").UdpTrackerExecutor.RequestResult) void {
        const self: *TorrentSession = @ptrCast(@alignCast(context));
        defer self.finishAnnounceJob();

        if (result.err) |_| return;
        const body = result.body orelse return;
        if (body.len < 20) return;

        const udp_mod = @import("../tracker/udp.zig");
        const ann_resp = udp_mod.AnnounceResponse.decode(body) catch return;
        const peers = ann_resp.parsePeers(self.allocator) catch return;
        defer self.allocator.free(peers);

        const el = self.shared_event_loop orelse return;

        // Update the announce interval on the event loop.
        if (ann_resp.interval > 0) {
            el.announce_interval = ann_resp.interval;
        }

        if (peers.len == 0) return;
        const addrs = self.allocator.alloc(std.net.Address, peers.len) catch return;
        for (peers, 0..) |peer, i| {
            addrs[i] = peer.address;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const tid = self.torrent_id_in_shared orelse {
            self.allocator.free(addrs);
            return;
        };
        el.enqueueAnnounceResult(tid, addrs) catch self.allocator.free(addrs);
    }

    fn announceComplete(context: *anyopaque, result: TrackerExecutor.RequestResult) void {
        const self: *TorrentSession = @ptrCast(@alignCast(context));
        defer self.finishAnnounceJob();
        const body = result.body orelse return;
        const resp = tracker.announce.parseResponse(self.allocator, body) catch return;
        defer tracker.announce.freeResponse(self.allocator, resp);

        const el = self.shared_event_loop orelse return;

        // Update the announce interval on the event loop.
        if (resp.interval > 0) {
            el.announce_interval = resp.interval;
        }

        // Collect peer addresses for the event loop to pick up.
        if (resp.peers.len == 0) return;
        const addrs = self.allocator.alloc(std.net.Address, resp.peers.len) catch return;
        for (resp.peers, 0..) |peer, i| {
            addrs[i] = peer.address;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const tid = self.torrent_id_in_shared orelse {
            self.allocator.free(addrs);
            return;
        };
        el.enqueueAnnounceResult(tid, addrs) catch self.allocator.free(addrs);
    }

    /// Trigger a background scrape if enough time has passed (30 minutes).
    /// Safe to call from any thread. The shared tracker executor performs the
    /// scrape and updates scrape_result atomically.
    pub fn maybeScrape(self: *TorrentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .downloading and self.state != .seeding) return;
        const now = std.time.timestamp();
        const scrape_interval: i64 = 30 * 60; // 30 minutes
        if (now - self.last_scrape_time < scrape_interval) return;

        // Avoid overlapping scrapes
        if (self.scraping.swap(true, .acq_rel)) return;

        self.last_scrape_time = now;
        self.scheduleScrape() catch {
            self.scraping.store(false, .release);
        };
    }

    fn scheduleScrape(self: *TorrentSession) !void {
        const session = &(self.session orelse return error.MissingSession);
        const tracker_urls = try self.buildTrackerUrls(session);
        defer self.allocator.free(tracker_urls);
        if (tracker_urls.len == 0) return error.NoTrackers;

        self.scrape_jobs_in_flight.store(0, .release);
        var submitted: u32 = 0;

        for (tracker_urls) |announce_url| {
            if (self.trySubmitUdpScrape(announce_url, session.metainfo.info_hash)) {
                _ = self.scrape_jobs_in_flight.fetchAdd(1, .acq_rel);
                submitted += 1;
                continue;
            }

            const host = getTrackerHostForUrl(announce_url) orelse continue;
            const scrape_url = tracker.scrape.buildScrapeUrl(self.allocator, announce_url, session.metainfo.info_hash) catch continue;
            defer self.allocator.free(scrape_url);
            self.submitTrackerJob(scrape_url, host, scrapeComplete) catch continue;
            _ = self.scrape_jobs_in_flight.fetchAdd(1, .acq_rel);
            submitted += 1;
        }

        if (submitted == 0) {
            self.scraping.store(false, .release);
            return error.NoTrackers;
        }
    }

    fn trySubmitUdpScrape(self: *TorrentSession, announce_url: []const u8, info_hash: [20]u8) bool {
        const udp_mod = @import("../tracker/udp.zig");

        const parsed = udp_mod.parseUdpUrl(announce_url) orelse return false;
        const executor = self.udp_tracker_executor orelse return false;

        var job = UdpTrackerExecutor.Job{
            .context = @ptrCast(self),
            .on_complete = udpScrapeComplete,
            .kind = .scrape,
            .port = parsed.port,
            .info_hash = info_hash,
            .host_len = @intCast(parsed.host.len),
        };
        @memcpy(job.host[0..parsed.host.len], parsed.host);
        executor.submit(job) catch return false;
        return true;
    }

    fn udpScrapeComplete(context: *anyopaque, result: @import("udp_tracker_executor.zig").UdpTrackerExecutor.RequestResult) void {
        const self: *TorrentSession = @ptrCast(@alignCast(context));
        defer self.finishScrapeJob();

        if (result.err) |_| return;
        const body = result.body orelse return;
        if (body.len < 20) return;

        const udp_mod = @import("../tracker/udp.zig");
        const header = udp_mod.ScrapeResponse.decodeHeader(body) catch return;
        const entry = udp_mod.ScrapeResponse.parseEntry(header.entry_data, 0) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.scrape_result = .{
            .complete = entry.seeders,
            .incomplete = entry.leechers,
            .downloaded = entry.completed,
        };
    }

    fn scrapeComplete(context: *anyopaque, result: TrackerExecutor.RequestResult) void {
        const self: *TorrentSession = @ptrCast(@alignCast(context));
        defer self.finishScrapeJob();
        if (result.body) |body| {
            self.mutex.lock();
            defer self.mutex.unlock();
            const session = &(self.session orelse return);
            if (tracker.scrape.parseScrapeResponse(self.allocator, body, session.metainfo.info_hash)) |scrape_result| {
                self.scrape_result = scrape_result;
            } else |_| {}
        }
    }

    fn finishAnnounceJob(self: *TorrentSession) void {
        const remaining = self.announce_jobs_in_flight.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) self.announcing.store(false, .release);
    }

    fn finishScrapeJob(self: *TorrentSession) void {
        const remaining = self.scrape_jobs_in_flight.fetchSub(1, .acq_rel) - 1;
        if (remaining == 0) self.scraping.store(false, .release);
    }

    // ── Magnet metadata fetching (BEP 9) ────────────────────

    /// Collect peers for a magnet link via tracker announces.
    /// Runs on the background thread. Stores peers for the event loop
    /// to use with the async BEP 9 metadata fetch.
    fn collectMagnetPeers(self: *TorrentSession) !void {
        const tlog = std.log.scoped(.metadata_fetch);

        self.state = .metadata_fetching;
        self.metadata_fetch_progress = .{ .state = .announcing };

        const tracker_urls = self.magnet_trackers orelse {
            self.error_message = std.fmt.allocPrint(self.allocator, "no tracker URLs in magnet link", .{}) catch null;
            return error.NoTrackers;
        };

        var peer_list = std.ArrayList(std.net.Address).empty;
        defer peer_list.deinit(self.allocator);

        for (tracker_urls) |url| {
            const resp = tracker.announce.fetchAuto(self.allocator, .{
                .announce_url = url,
                .info_hash = self.info_hash,
                .peer_id = self.peer_id,
                .port = self.port,
                .left = 1, // we need metadata
                .key = self.tracker_key,
            }) catch |err| {
                tlog.debug("tracker announce failed for {s}: {s}", .{ url, @errorName(err) });
                continue;
            };
            defer tracker.announce.freeResponse(self.allocator, resp);

            for (resp.peers) |peer| {
                peer_list.append(self.allocator, peer.address) catch {};
            }
        }

        tlog.info("magnet: collected {d} peers from {d} trackers", .{ peer_list.items.len, tracker_urls.len });

        // Store peers for event loop integration
        self.pending_peers = peer_list.toOwnedSlice(self.allocator) catch null;
        self.metadata_fetch_progress = .{ .state = .connecting };
        self.background_init_done.store(true, .release);
    }

    /// Callback from async metadata fetch completion. Runs on the event loop thread.
    /// If metadata was successfully downloaded, continues with Session.load + recheck.
    fn onMetadataFetchComplete(mf: *AsyncMetadataFetch) void {
        const self: *TorrentSession = if (mf.caller_ctx) |ctx|
            @ptrCast(@alignCast(ctx))
        else
            return;

        const mlog = std.log.scoped(.metadata_fetch);
        self.mutex.lock();
        defer self.mutex.unlock();

        const sel = self.shared_event_loop orelse {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "event loop gone during metadata fetch", .{}) catch null;
            return;
        };

        // Clean up the pending_peers (already consumed by AsyncMetadataFetch)
        if (self.pending_peers) |pp| {
            self.allocator.free(pp);
            self.pending_peers = null;
        }

        const info_bytes = mf.result_bytes orelse {
            mlog.warn("metadata fetch failed: no result", .{});
            self.state = .@"error";
            self.metadata_fetch_progress = .{ .state = .failed };
            self.error_message = std.fmt.allocPrint(self.allocator, "metadata fetch failed: all peers exhausted", .{}) catch null;
            // Clean up the fetch state
            sel.metadata_fetch = null;
            mf.destroy();
            return;
        };

        self.metadata_fetch_progress = .{
            .state = .completed,
            .pieces_received = mf.assembler.piece_count,
            .pieces_total = mf.assembler.piece_count,
            .metadata_size = mf.assembler.total_size,
            .peers_attempted = mf.peers_attempted,
        };

        // Build a minimal .torrent file wrapping the raw info dictionary
        const torrent_bytes = self.buildTorrentBytes(info_bytes) catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "failed to build torrent: {s}", .{@errorName(err)}) catch null;
            sel.metadata_fetch = null;
            mf.destroy();
            return;
        };

        // Clean up metadata fetch before continuing (frees assembler and info_bytes)
        sel.metadata_fetch = null;
        mf.destroy();

        self.torrent_bytes = torrent_bytes;

        // Parse the torrent to update metadata fields
        const metainfo = @import("../torrent/metainfo.zig");
        const meta = metainfo.parse(self.allocator, torrent_bytes) catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "metadata parse failed: {s}", .{@errorName(err)}) catch null;
            return;
        };
        defer metainfo.freeMetainfo(self.allocator, meta);

        self.total_size = meta.totalSize();
        self.piece_count = meta.pieceCount() catch 0;

        if (self.is_magnet) {
            const new_name = self.allocator.dupe(u8, meta.name) catch null;
            if (new_name) |nn| {
                self.allocator.free(self.name);
                self.name = nn;
            }
        }

        mlog.info("metadata downloaded: {s} ({d} bytes)", .{ self.name, self.total_size });

        // Now do the normal Session.load + PieceStore.init + start recheck path.
        // This is similar to doStartBackground but runs on the event loop thread.
        // The one-time file creation in PieceStore.init is an acceptable exception
        // per the io_uring policy.
        const session = session_mod.Session.load(self.allocator, torrent_bytes, self.save_path) catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "session load failed: {s}", .{@errorName(err)}) catch null;
            return;
        };
        self.session = session;

        const store_result = storage.writer.PieceStore.init(self.allocator, &self.session.?);
        if (store_result) |pstore| {
            self.store = pstore;
        } else |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "piece store init failed: {s}", .{@errorName(err)}) catch null;
            return;
        }

        // Get shared file handles
        const shared_fds = self.store.?.fileHandles(self.allocator) catch |err| {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "file handles failed: {s}", .{@errorName(err)}) catch null;
            return;
        };
        self.shared_fds = shared_fds;

        // Start async recheck
        self.state = .checking;
        sel.startRecheck(
            &self.session.?,
            shared_fds,
            0,
            null, // no resume pieces for fresh magnet
            onRecheckComplete,
            @ptrCast(self),
        ) catch {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "failed to start recheck after metadata fetch", .{}) catch null;
            return;
        };
    }

    /// Build a minimal .torrent file wrapping the raw info dictionary.
    fn buildTorrentBytes(self: *TorrentSession, info_bytes: []const u8) ![]const u8 {
        // Build: d8:announce<url>4:info<raw info dict>e
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        try buf.append(self.allocator, 'd');

        // Add announce URL from magnet trackers
        if (self.magnet_trackers) |trackers| {
            if (trackers.len > 0) {
                try buf.print(self.allocator, "8:announce{}:", .{trackers[0].len});
                try buf.appendSlice(self.allocator, trackers[0]);

                // Add announce-list if multiple trackers
                if (trackers.len > 1) {
                    try buf.appendSlice(self.allocator, "13:announce-listl");
                    for (trackers) |tr| {
                        try buf.append(self.allocator, 'l');
                        try buf.print(self.allocator, "{}:", .{tr.len});
                        try buf.appendSlice(self.allocator, tr);
                        try buf.append(self.allocator, 'e');
                    }
                    try buf.append(self.allocator, 'e');
                }
            }
        }

        // Add raw info dict
        try buf.appendSlice(self.allocator, "4:info");
        try buf.appendSlice(self.allocator, info_bytes);

        try buf.append(self.allocator, 'e');

        return buf.toOwnedSlice(self.allocator);
    }

    /// Build a deduplicated list of tracker URLs from announce + announce-list.
    fn buildTrackerUrls(self: *TorrentSession, session: *const session_mod.Session) ![]const []const u8 {
        var urls = std.ArrayList([]const u8).empty;
        defer urls.deinit(self.allocator);

        const overrides = &self.tracker_overrides;

        // Add metainfo trackers, applying edits and removals
        if (session.metainfo.announce) |url| {
            if (!overrides.isRemoved(url)) {
                const effective = overrides.getEdit(url) orelse url;
                try urls.append(self.allocator, effective);
            }
        }
        for (session.metainfo.announce_list) |url| {
            if (overrides.isRemoved(url)) continue;
            const effective = overrides.getEdit(url) orelse url;
            var already_added = false;
            for (urls.items) |existing| {
                if (std.mem.eql(u8, existing, effective)) {
                    already_added = true;
                    break;
                }
            }
            if (!already_added) try urls.append(self.allocator, effective);
        }

        // Add user-added trackers
        for (overrides.added.items) |entry| {
            var already_added = false;
            for (urls.items) |existing| {
                if (std.mem.eql(u8, existing, entry.url)) {
                    already_added = true;
                    break;
                }
            }
            if (!already_added) try urls.append(self.allocator, entry.url);
        }

        return urls.toOwnedSlice(self.allocator);
    }

    // ── Tracker override operations ─────────────────────────

    /// Add one or more tracker URLs (each goes into a new tier).
    /// Persists to SQLite and triggers a re-announce.
    pub fn addTrackerUrls(self: *TorrentSession, urls: []const []const u8) !void {
        // Determine next tier number
        var next_tier: u32 = 0;
        if (self.session) |*s| {
            if (s.metainfo.announce != null) next_tier += 1;
            next_tier += @intCast(s.metainfo.announce_list.len);
        }
        if (self.tracker_overrides.added.items.len > 0) {
            next_tier = self.tracker_overrides.maxAddedTier() + 1;
        }

        for (urls) |url| {
            if (url.len == 0) continue;
            // Skip duplicates
            var duplicate = false;
            for (self.tracker_overrides.added.items) |entry| {
                if (std.mem.eql(u8, entry.url, url)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            const owned_url = try self.allocator.dupe(u8, url);
            errdefer self.allocator.free(owned_url);
            try self.tracker_overrides.added.append(self.allocator, .{
                .url = owned_url,
                .tier = next_tier,
            });
            next_tier += 1;

            // Persist to SQLite
            self.persistTrackerOverride(owned_url, next_tier - 1, "add", null);
        }
    }

    /// Remove tracker URLs from the effective tracker list.
    /// If the URL is user-added, removes it from the added list.
    /// If the URL is from metainfo, adds a 'remove' override.
    pub fn removeTrackerUrls(self: *TorrentSession, urls: []const []const u8) !void {
        for (urls) |url| {
            if (url.len == 0) continue;

            // Check if this is a user-added tracker
            var removed_added = false;
            var i: usize = 0;
            while (i < self.tracker_overrides.added.items.len) {
                if (std.mem.eql(u8, self.tracker_overrides.added.items[i].url, url)) {
                    self.allocator.free(self.tracker_overrides.added.items[i].url);
                    _ = self.tracker_overrides.added.orderedRemove(i);
                    removed_added = true;
                    // Remove from SQLite
                    self.unpersistTrackerOverride(url);
                    break;
                }
                i += 1;
            }
            if (removed_added) continue;

            // Check if it's an edit replacement URL
            var removed_edit = false;
            i = 0;
            while (i < self.tracker_overrides.edits.items.len) {
                if (std.mem.eql(u8, self.tracker_overrides.edits.items[i].new_url, url)) {
                    const edit = self.tracker_overrides.edits.items[i];
                    self.allocator.free(edit.orig_url);
                    self.allocator.free(edit.new_url);
                    _ = self.tracker_overrides.edits.orderedRemove(i);
                    removed_edit = true;
                    self.unpersistTrackerOverride(url);
                    break;
                }
                i += 1;
            }
            if (removed_edit) continue;

            // It's a metainfo tracker -- add a 'remove' override
            // Check not already in removed list
            var already_removed = false;
            for (self.tracker_overrides.removed.items) |r| {
                if (std.mem.eql(u8, r, url)) {
                    already_removed = true;
                    break;
                }
            }
            if (!already_removed) {
                const owned_url = try self.allocator.dupe(u8, url);
                errdefer self.allocator.free(owned_url);
                try self.tracker_overrides.removed.append(self.allocator, owned_url);
                self.persistTrackerOverride(owned_url, 0, "remove", null);
            }
        }
    }

    /// Replace one tracker URL with another.
    /// Works for metainfo URLs, user-added URLs, and previously-edited URLs.
    pub fn editTrackerUrl(self: *TorrentSession, orig_url: []const u8, new_url: []const u8) !void {
        if (orig_url.len == 0 or new_url.len == 0) return error.InvalidUrl;
        if (std.mem.eql(u8, orig_url, new_url)) return; // no-op

        // Check if orig_url is a user-added tracker
        for (self.tracker_overrides.added.items) |*entry| {
            if (std.mem.eql(u8, entry.url, orig_url)) {
                // Replace in-place
                const owned_new = try self.allocator.dupe(u8, new_url);
                self.unpersistTrackerOverride(orig_url);
                self.allocator.free(entry.url);
                entry.url = owned_new;
                self.persistTrackerOverride(owned_new, entry.tier, "add", null);
                return;
            }
        }

        // Check if orig_url is already an edited URL (new_url of an existing edit)
        for (self.tracker_overrides.edits.items) |*edit| {
            if (std.mem.eql(u8, edit.new_url, orig_url)) {
                // Update the replacement
                const owned_new = try self.allocator.dupe(u8, new_url);
                self.unpersistTrackerOverride(orig_url);
                self.allocator.free(edit.new_url);
                edit.new_url = owned_new;
                self.persistTrackerOverride(owned_new, 0, "edit", edit.orig_url);
                return;
            }
        }

        // It's a metainfo URL -- create a new edit override
        const owned_orig = try self.allocator.dupe(u8, orig_url);
        errdefer self.allocator.free(owned_orig);
        const owned_new = try self.allocator.dupe(u8, new_url);
        errdefer self.allocator.free(owned_new);
        try self.tracker_overrides.edits.append(self.allocator, .{
            .orig_url = owned_orig,
            .new_url = owned_new,
        });
        self.persistTrackerOverride(owned_new, 0, "edit", owned_orig);
    }

    /// Load tracker overrides from SQLite into the in-memory state.
    pub fn loadTrackerOverrides(self: *TorrentSession) void {
        const db_path = self.resume_db_path orelse return;
        var db = ResumeDb.open(db_path) catch return;
        defer db.close();

        const overrides = db.loadTrackerOverrides(self.allocator, self.info_hash) catch return;
        defer ResumeDb.freeTrackerOverrides(self.allocator, overrides);

        for (overrides) |ov| {
            if (std.mem.eql(u8, ov.action, "add")) {
                const owned = self.allocator.dupe(u8, ov.url) catch continue;
                self.tracker_overrides.added.append(self.allocator, .{
                    .url = owned,
                    .tier = ov.tier,
                }) catch {
                    self.allocator.free(owned);
                };
            } else if (std.mem.eql(u8, ov.action, "remove")) {
                const owned = self.allocator.dupe(u8, ov.url) catch continue;
                self.tracker_overrides.removed.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
            } else if (std.mem.eql(u8, ov.action, "edit")) {
                if (ov.orig_url) |orig| {
                    const owned_new = self.allocator.dupe(u8, ov.url) catch continue;
                    const owned_orig = self.allocator.dupe(u8, orig) catch {
                        self.allocator.free(owned_new);
                        continue;
                    };
                    self.tracker_overrides.edits.append(self.allocator, .{
                        .orig_url = owned_orig,
                        .new_url = owned_new,
                    }) catch {
                        self.allocator.free(owned_new);
                        self.allocator.free(owned_orig);
                    };
                }
            }
        }
    }

    /// Persist a single tracker override to SQLite (best-effort, ignores errors).
    fn persistTrackerOverride(self: *TorrentSession, url: []const u8, tier: u32, action: []const u8, orig_url: ?[]const u8) void {
        const db_path = self.resume_db_path orelse return;
        var db = ResumeDb.open(db_path) catch return;
        defer db.close();
        db.saveTrackerOverride(self.info_hash, url, tier, action, orig_url) catch {};
    }

    /// Remove a tracker override from SQLite (best-effort, ignores errors).
    fn unpersistTrackerOverride(self: *TorrentSession, url: []const u8) void {
        const db_path = self.resume_db_path orelse return;
        var db = ResumeDb.open(db_path) catch return;
        defer db.close();
        db.removeTrackerOverride(self.info_hash, url) catch {};
    }

    // ── Resume persistence helpers ────────────────────────

    /// Scan piece_tracker for newly completed pieces since last check
    /// and queue them in the resume writer. Safe to call from any thread
    /// (ResumeWriter.recordPiece is mutex-protected).
    pub fn persistNewCompletions(self: *TorrentSession) void {
        const rw = &(self.resume_writer orelse return);
        const pt = &(self.piece_tracker orelse return);
        const current_count = pt.completedCount();
        if (current_count == self.resume_last_count) return;

        // Scan for newly completed pieces
        var i: u32 = 0;
        while (i < self.piece_count) : (i += 1) {
            if (pt.isPieceComplete(i)) {
                rw.recordPiece(i) catch {};
            }
        }
        self.resume_last_count = current_count;
    }

    /// Flush pending resume writes to SQLite, including lifetime
    /// transfer stats. Safe to call from any thread -- the actual
    /// SQLite I/O is blocking, which is fine because this is never
    /// called from the io_uring event loop thread.
    pub fn flushResume(self: *TorrentSession) void {
        if (self.resume_writer) |*rw| {
            rw.flush() catch {};

            // Persist lifetime transfer stats (baseline + current session)
            const speed_stats = if (self.shared_event_loop) |sel|
                if (self.torrent_id_in_shared) |tid| sel.getSpeedStats(tid) else @import("../io/event_loop.zig").SpeedStats{}
            else
                @import("../io/event_loop.zig").SpeedStats{};

            rw.saveTransferStats(.{
                .total_uploaded = self.baseline_uploaded + speed_stats.ul_total,
                .total_downloaded = self.baseline_downloaded + speed_stats.dl_total,
            });
        }
    }

    fn detachFromSharedEventLoop(self: *TorrentSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sel = self.shared_event_loop orelse return;
        // Cancel any active metadata fetch for this session
        if (sel.metadata_fetch) |mf| {
            if (mf.caller_ctx) |ctx| {
                const mf_session: *TorrentSession = @ptrCast(@alignCast(ctx));
                if (mf_session == self) {
                    sel.cancelMetadataFetch();
                }
            }
        }
        if (self.torrent_id_in_shared) |tid| {
            sel.removeTorrent(tid);
            self.torrent_id_in_shared = null;
        }
        self.pending_seed_setup = false;
    }

    fn waitForBackgroundNetworkJobs(self: *TorrentSession) void {
        while (self.announcing.load(.acquire) or self.scraping.load(.acquire)) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
};

fn initTestEventLoop(allocator: std.mem.Allocator) !EventLoop {
    return EventLoop.initBare(allocator, 0);
}

fn deinitTestEventLoop(_: std.mem.Allocator, el: *EventLoop) void {
    el.deinit();
}

test "getStats does not mutate completion state" {
    var initial_complete = try Bitfield.init(std.testing.allocator, 1);
    defer initial_complete.deinit(std.testing.allocator);
    try initial_complete.set(0);

    var piece_tracker = try PieceTracker.init(
        std.testing.allocator,
        1,
        16 * 1024,
        16 * 1024,
        &initial_complete,
        16 * 1024,
    );
    defer piece_tracker.deinit(std.testing.allocator);

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .state = .downloading,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "",
        .total_size = 16 * 1024,
        .piece_count = 1,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
        .piece_tracker = piece_tracker,
    };

    const stats = session.getStats();
    try std.testing.expectEqual(State.seeding, stats.state);
    try std.testing.expectEqual(State.downloading, session.state);
    try std.testing.expectEqual(@as(i64, 0), session.completion_on);
    try std.testing.expectEqual(@as(i64, 0), stats.completion_on);
}

test "checkSeedTransition is the seeding state mutation point" {
    var initial_complete = try Bitfield.init(std.testing.allocator, 1);
    defer initial_complete.deinit(std.testing.allocator);
    try initial_complete.set(0);

    var piece_tracker = try PieceTracker.init(
        std.testing.allocator,
        1,
        16 * 1024,
        16 * 1024,
        &initial_complete,
        16 * 1024,
    );
    defer piece_tracker.deinit(std.testing.allocator);

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .state = .downloading,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "",
        .total_size = 16 * 1024,
        .piece_count = 1,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
        .piece_tracker = piece_tracker,
    };

    try std.testing.expect(session.checkSeedTransition());
    try std.testing.expectEqual(State.seeding, session.state);
    try std.testing.expect(session.completion_on > 0);
    try std.testing.expect(session.pending_seed_setup);
}

test "stop detaches torrent from shared event loop" {
    var el = try initTestEventLoop(std.testing.allocator);
    defer deinitTestEventLoop(std.testing.allocator, &el);

    const empty_fds = [_]posix.fd_t{};
    _ = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    });

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .state = .downloading,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "",
        .total_size = 0,
        .piece_count = 0,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
        .shared_event_loop = &el,
        .torrent_id_in_shared = 0,
    };

    session.stop();

    try std.testing.expectEqual(State.stopped, session.state);
    try std.testing.expect(session.torrent_id_in_shared == null);
    try std.testing.expect(session.pending_seed_setup == false);
    try std.testing.expect(el.getTorrentContextConst(0) == null);
    try std.testing.expectEqual(@as(u32, 0), el.torrent_count);
}

test "unpause preserves shared event loop mode" {
    var el = try initTestEventLoop(std.testing.allocator);
    defer deinitTestEventLoop(std.testing.allocator, &el);

    var session = TorrentSession{
        .allocator = std.testing.allocator,
        .state = .paused,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "",
        .total_size = 0,
        .piece_count = 0,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
        .shared_event_loop = &el,
    };

    session.unpause();
    if (session.thread) |t| {
        t.join();
        session.thread = null;
    }

    try std.testing.expect(session.shared_event_loop == &el);

    session.stop();
    if (session.error_message) |msg| {
        std.testing.allocator.free(msg);
        session.error_message = null;
    }
}

test "buildTrackerUrls includes effective tracker set with overrides" {
    const torrent_bytes =
        "d8:announce18:http://primary.test13:announce-listll20:http://backup1.testel20:http://backup2.testee4:infod6:lengthi4e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee";

    var loaded = try session_mod.Session.load(std.testing.allocator, torrent_bytes, "/tmp");
    defer loaded.deinit(std.testing.allocator);

    var ts = TorrentSession{
        .allocator = std.testing.allocator,
        .torrent_bytes = "",
        .save_path = "",
        .info_hash = [_]u8{0} ** 20,
        .info_hash_hex = [_]u8{'0'} ** 40,
        .name = "",
        .total_size = 0,
        .piece_count = 0,
        .added_on = 0,
        .peer_id = [_]u8{0} ** 20,
        .tracker_key = [_]u8{0} ** 8,
        .session = loaded,
    };
    defer ts.tracker_overrides.deinit(std.testing.allocator);
    ts.session = null;

    const edited_primary = try std.testing.allocator.dupe(u8, "http://edited-primary.test");
    const removed_backup = try std.testing.allocator.dupe(u8, "http://backup1.test");
    const added_tracker = try std.testing.allocator.dupe(u8, "http://added.test");

    try ts.tracker_overrides.edits.append(std.testing.allocator, .{
        .orig_url = try std.testing.allocator.dupe(u8, "http://primary.test"),
        .new_url = edited_primary,
    });
    try ts.tracker_overrides.removed.append(std.testing.allocator, removed_backup);
    try ts.tracker_overrides.added.append(std.testing.allocator, .{
        .url = added_tracker,
        .tier = 3,
    });

    const urls = try ts.buildTrackerUrls(&loaded);
    defer std.testing.allocator.free(urls);

    try std.testing.expectEqual(@as(usize, 3), urls.len);
    try std.testing.expectEqualStrings("http://edited-primary.test", urls[0]);
    try std.testing.expectEqualStrings("http://backup2.test", urls[1]);
    try std.testing.expectEqualStrings("http://added.test", urls[2]);
}

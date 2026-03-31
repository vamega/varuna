const std = @import("std");
const posix = std.posix;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const Ring = @import("../io/ring.zig").Ring;
const EventLoop = @import("../io/event_loop.zig").EventLoop;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const file_priority = @import("../torrent/file_priority.zig");
const FilePriority = file_priority.FilePriority;
const signal = @import("../io/signal.zig");
const peer_id_mod = @import("../torrent/peer_id.zig");
const magnet_mod = @import("../torrent/magnet.zig");
const ut_metadata = @import("../net/ut_metadata.zig");
const metadata_fetch = @import("../net/metadata_fetch.zig");
const ResumeWriter = storage.resume_state.ResumeWriter;
const DnsResolver = @import("../io/dns.zig").DnsResolver;

pub const State = enum {
    checking,
    metadata_fetching,
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
    ring: ?Ring = null,
    shared_fds: ?[]posix.fd_t = null,
    event_loop: ?EventLoop = null,
    shared_event_loop: ?*EventLoop = null,
    torrent_id_in_shared: ?u8 = null,
    pending_peers: ?[]std.net.Address = null, // peers waiting for main thread to add
    pending_seed_setup: bool = false, // signals main thread to set up seed mode
    thread: ?std.Thread = null,
    // Shared ring for background announce HTTP I/O (created once, reused).
    // Separate from the main event loop ring to avoid blocking peer I/O.
    announce_ring: ?Ring = null,
    announce_ring_mutex: std.Thread.Mutex = .{},
    announcing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Shared DNS resolver with TTL-based caching. Avoids spawning a thread
    // for every DNS lookup during tracker announce/scrape. Created lazily
    // on the first tracker operation.
    dns_resolver: ?DnsResolver = null,

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
    max_peers: u32 = 50,
    hasher_threads: u32 = 4,
    resume_db_path: ?[*:0]const u8 = null,

    // Per-torrent speed limits (bytes/sec, 0 = unlimited)
    dl_limit: u64 = 0,
    ul_limit: u64 = 0,

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

    // Connection diagnostics (updated from event loop callbacks)
    conn_attempts: u64 = 0,
    conn_failures: u64 = 0,
    conn_timeout_failures: u64 = 0,
    conn_refused_failures: u64 = 0,

    // Scrape state
    scrape_result: ?tracker.scrape.ScrapeResult = null,
    last_scrape_time: i64 = 0,
    scraping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            .peer_id = peer_id_mod.generate(),
            .tracker_key = tracker.announce.Request.generateKey(),
            .is_magnet = true,
            .magnet_trackers = if (trackers.len > 0) trackers else null,
        };
    }

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
            .tracker_key = tracker.announce.Request.generateKey(),
            .is_private = meta.isPrivate(),
            .info_hash_v2 = meta.info_hash_v2,
        };
    }

    pub fn deinit(self: *TorrentSession) void {
        self.stop();
        if (self.dns_resolver) |*r| r.deinit(self.allocator);
        if (self.announce_ring) |*r| {
            r.deinit();
            self.announce_ring = null;
        }
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
        // Magnet-specific cleanup
        if (self.magnet_trackers) |trackers| {
            for (trackers) |tr| self.allocator.free(tr);
            self.allocator.free(trackers);
        }
        if (self.metadata_assembler) |*ma| ma.deinit();
    }

    /// Get a pointer to the DNS resolver, lazily initializing it on first use.
    /// Returns null if initialization fails.
    fn getDnsResolver(self: *TorrentSession) ?*DnsResolver {
        if (self.dns_resolver == null) {
            self.dns_resolver = DnsResolver.init(self.allocator) catch return null;
        }
        return &self.dns_resolver.?;
    }

    /// Start with own event loop (for varuna-tools, backwards compat).
    pub fn start(self: *TorrentSession) void {
        self.startWithEventLoop(null);
    }

    /// Start with a shared event loop (for daemon mode).
    /// Recheck runs on a background thread. When ready, peers are
    /// added to the shared event loop instead of creating a new one.
    pub fn startWithEventLoop(self: *TorrentSession, shared_el: ?*EventLoop) void {
        if (self.state == .downloading or self.state == .seeding or self.state == .checking or self.state == .metadata_fetching) return;

        self.state = .checking;
        self.shared_event_loop = shared_el;
        self.thread = std.Thread.spawn(.{}, startWorker, .{self}) catch {
            self.state = .@"error";
            return;
        };
    }

    pub fn pause(self: *TorrentSession) void {
        if (self.state == .downloading or self.state == .seeding) {
            self.state = .paused;
            if (self.event_loop) |*el| {
                el.stop();
            } else {
                self.detachFromSharedEventLoop();
            }
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

    pub fn resume_session(self: *TorrentSession) void {
        if (self.state == .paused) {
            // Clean up old resources before restarting
            self.waitForBackgroundNetworkJobs();
            self.stopInternal();
            self.startWithEventLoop(self.shared_event_loop);
        }
    }

    pub fn stop(self: *TorrentSession) void {
        if (self.event_loop) |*el| el.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.detachFromSharedEventLoop();
        self.waitForBackgroundNetworkJobs();
        self.stopInternal();
        self.state = .stopped;
    }

    /// Called by the main thread to integrate this session into the shared
    /// event loop after the background recheck thread completes.
    /// Returns true if peers were added.
    pub fn integrateIntoEventLoop(self: *TorrentSession) bool {
        const sel = self.shared_event_loop orelse return false;
        const peers = self.pending_peers orelse return false;
        defer {
            self.allocator.free(peers);
            self.pending_peers = null;
        }

        if (self.session == null or self.piece_tracker == null or self.shared_fds == null) return false;

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
        return added > 0;
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
        const el = self.shared_event_loop orelse {
            if (self.event_loop) |*own_el| {
                if (enabled) {
                    own_el.enableSuperSeed(0) catch {};
                } else {
                    own_el.disableSuperSeed(0);
                }
            }
            return;
        };
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

    pub fn getStats(self: *TorrentSession) Stats {
        const pieces_have = if (self.piece_tracker) |*pt| pt.completedCount() else 0;
        const progress = if (self.piece_count > 0)
            @as(f64, @floatFromInt(pieces_have)) / @as(f64, @floatFromInt(self.piece_count))
        else
            0.0;

        // Auto-transition to seeding when all pieces are complete
        if (self.state == .downloading and pieces_have == self.piece_count and self.piece_count > 0) {
            self.state = .seeding;
        }

        // Read speed stats from the event loop
        const speed_stats = if (self.shared_event_loop) |sel|
            if (self.torrent_id_in_shared) |tid| sel.getSpeedStats(tid) else @import("../io/event_loop.zig").SpeedStats{}
        else if (self.event_loop) |*el|
            el.getSpeedStats(0)
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
        const eta: i64 = if (self.state == .downloading and speed_stats.dl_speed > 0)
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
        const tracker_url: []const u8 = if (meta_opt) |m| (m.announce orelse "") else "";
        const trackers_count: u32 = if (meta_opt) |m| blk: {
            var count: u32 = 0;
            if (m.announce != null) count += 1;
            for (m.announce_list) |url| {
                if (m.announce) |primary| {
                    if (!std.mem.eql(u8, url, primary)) count += 1;
                } else {
                    count += 1;
                }
            }
            break :blk count;
        } else 0;

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
            .state = self.state,
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
            .peers_connected = if (self.event_loop) |*el| el.peer_count else if (self.shared_event_loop) |sel| if (self.torrent_id_in_shared) |tid| sel.peerCountForTorrent(tid) else 0 else 0,
            .error_msg = self.error_message,
            .dl_limit = self.dl_limit,
            .ul_limit = self.ul_limit,
            .eta = eta,
            .ratio = ratio,
            .sequential_download = self.sequential_download,
            .is_private = self.is_private,
            .super_seeding = self.super_seeding,
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
            .tracker = tracker_url,
            .trackers_count = trackers_count,
            .content_path = content_path,
            .num_files = num_files,
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
        // Magnet link: first fetch metadata from peers before normal download
        if (self.is_magnet and self.torrent_bytes.len == 0) {
            try self.fetchMetadata();
            // After metadata fetch, torrent_bytes is populated and is_magnet
            // state transitions. Fall through to normal download path.
        }

        const ring = try Ring.init(16);
        self.ring = ring;

        const session = try session_mod.Session.load(self.allocator, self.torrent_bytes, self.save_path);
        self.session = session;

        const store = try storage.writer.PieceStore.init(self.allocator, &self.session.?, &self.ring.?);
        self.store = store;

        // Open resume DB and load known-complete pieces (fast path: skip rehash)
        var resume_pieces: ?storage.verify.PieceSet = null;
        defer if (resume_pieces) |*rp| rp.deinit(self.allocator);

        if (self.resume_db_path) |db_path| {
            if (ResumeWriter.init(db_path, session.metainfo.info_hash)) |rw| {
                self.resume_writer = rw;
                // Load known-complete pieces from DB
                var bf = storage.verify.PieceSet.init(self.allocator, session.pieceCount()) catch null;
                if (bf) |*loaded_bf| {
                    const loaded_count = self.resume_writer.?.db.loadCompletePieces(session.metainfo.info_hash, loaded_bf) catch 0;
                    if (loaded_count > 0) {
                        resume_pieces = loaded_bf.*;
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

        // Recheck with resume fast path (skips hashing known-complete pieces)
        self.state = .checking;
        const known_ptr: ?*const storage.verify.PieceSet = if (resume_pieces) |*rp| rp else null;
        var recheck = try storage.verify.recheckExistingData(self.allocator, &self.session.?, &self.store.?, known_ptr);
        defer recheck.deinit(self.allocator);

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
            // Get shared file handles for serving pieces
            const shared_fds = try self.store.?.fileHandles(self.allocator);
            self.shared_fds = shared_fds;

            self.state = .seeding;
            if (self.shared_event_loop != null) {
                // Daemon mode: signal main thread to set up seed mode
                self.pending_seed_setup = true;
                // Announce as seeder on this background thread (blocking HTTP is fine here)
                self.announceAsSeeder();
            }
            return;
        }

        // Download: announce to tracker, get peers, run event loop
        self.state = .downloading;

        // Initial announce delay: random 0 to interval/4 to stagger multiple torrents
        // and avoid thundering herd on the tracker when many torrents start at once.
        {
            const base_interval: u64 = 1800; // default tracker interval
            const max_delay_ns = (base_interval / 4) * std.time.ns_per_s;
            if (max_delay_ns > 0) {
                // Simple hash-based jitter using info_hash bytes for deterministic spread
                const seed = @as(u64, self.info_hash[0]) |
                    (@as(u64, self.info_hash[1]) << 8) |
                    (@as(u64, self.info_hash[2]) << 16) |
                    (@as(u64, self.info_hash[3]) << 24);
                const delay_ns = seed % max_delay_ns;
                // Cap at 5 seconds to avoid excessive startup delay
                const capped_delay = @min(delay_ns, 5 * std.time.ns_per_s);
                if (capped_delay > 0) {
                    std.Thread.sleep(capped_delay);
                }
            }
        }

        const tracker_urls = self.buildTrackerUrls(&session) catch {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "no announce URL available", .{}) catch null;
            return;
        };
        defer self.allocator.free(tracker_urls);

        if (tracker_urls.len == 0) {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "no announce URL available", .{}) catch null;
            return;
        }

        // BEP 12: announce to all tiers simultaneously. First successful
        // response with peers wins; the rest are discarded.
        const multi_result = tracker.multi_announce.announceParallel(
            self.allocator,
            tracker_urls,
            .{
                .announce_url = "", // overridden per-URL inside announceParallel
                .info_hash = session.metainfo.info_hash,
                .peer_id = self.peer_id,
                .port = self.port,
                .left = session.totalSize() - recheck.bytes_complete,
                .key = self.tracker_key,
                .info_hash_v2 = self.info_hash_v2,
            },
        ) catch {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "tracker announce failed for all URLs", .{}) catch null;
            return;
        };
        const announce_resp = multi_result.response;
        const announce_url: []const u8 = tracker_urls[multi_result.url_index];
        defer tracker.announce.freeResponse(self.allocator, announce_resp);

        // Get shared file handles
        const shared_fds = try self.store.?.fileHandles(self.allocator);
        self.shared_fds = shared_fds;

        if (self.shared_event_loop != null) {
            // Daemon mode: store peer addresses for the main thread to add
            // (the event loop is NOT thread-safe, so we can't add peers here)
            var peer_list = std.ArrayList(std.net.Address).empty;
            defer peer_list.deinit(self.allocator);
            for (announce_resp.peers) |peer| {
                if (peer_list.items.len >= self.max_peers) break;
                peer_list.append(self.allocator, peer.address) catch continue;
            }

            if (peer_list.items.len == 0) {
                self.state = .@"error";
                self.error_message = std.fmt.allocPrint(self.allocator, "no reachable peers", .{}) catch null;
                return;
            }

            // Store peers for main thread to process
            self.pending_peers = peer_list.toOwnedSlice(self.allocator) catch null;
            self.state = .downloading;
            // Background thread exits -- main thread will call integrateIntoEventLoop()
            return;
        }

        // Standalone mode: create and run own event loop (for varuna-tools)
        const event_loop = try EventLoop.init(
            self.allocator,
            &self.session.?,
            &self.piece_tracker.?,
            shared_fds,
            self.peer_id,
            self.hasher_threads,
        );
        self.event_loop = event_loop;

        // Apply file priorities and sequential mode for standalone mode too.
        _ = self.applyFilePriorities();
        self.applySequentialMode();

        var peers_added: u32 = 0;
        for (announce_resp.peers) |peer| {
            if (peers_added >= self.max_peers) break;
            self.conn_attempts += 1;
            _ = self.event_loop.?.addPeer(peer.address) catch {
                self.conn_failures += 1;
                continue;
            };
            peers_added += 1;
        }

        if (peers_added == 0) {
            self.state = .@"error";
            self.error_message = std.fmt.allocPrint(self.allocator, "could not connect to any peers", .{}) catch null;
            return;
        }

        self.event_loop.?.submitTimeout(2 * std.time.ns_per_s) catch {};

        while (self.state == .downloading and !signal.isShutdownRequested()) {
            self.event_loop.?.tick() catch break;

            // Persist newly completed pieces to resume DB
            self.persistNewCompletions();

            if (self.piece_tracker.?.isComplete()) {
                var drain: u32 = 0;
                while (drain < 200) : (drain += 1) {
                    self.event_loop.?.processHashResults();
                    if (self.event_loop.?.pending_writes.count() > 0) {
                        self.event_loop.?.submitTimeout(10 * std.time.ns_per_ms) catch {};
                        self.event_loop.?.tick() catch break;
                    } else if (drain > 50) {
                        break;
                    } else {
                        self.event_loop.?.submitTimeout(10 * std.time.ns_per_ms) catch {};
                        self.event_loop.?.tick() catch break;
                    }
                }

                self.state = .seeding;
                self.store.?.sync() catch {};
                self.persistNewCompletions();
                self.flushResume();

                if (tracker.announce.fetchAutoWithDns(self.allocator, &self.ring.?, self.getDnsResolver(), .{
                    .announce_url = announce_url,
                    .info_hash = session.metainfo.info_hash,
                    .peer_id = self.peer_id,
                    .port = self.port,
                    .left = 0,
                    .event = .completed,
                    .key = self.tracker_key,
                    .info_hash_v2 = self.info_hash_v2,
                })) |resp| {
                    tracker.announce.freeResponse(self.allocator, resp);
                } else |_| {}
                break;
            }

            if (self.event_loop.?.peer_count == 0) break;
            self.event_loop.?.submitTimeout(2 * std.time.ns_per_s) catch {};
        }
    }

    fn stopInternal(self: *TorrentSession) void {
        // Flush resume state before tearing down (runs on caller's thread,
        // which is always a background thread -- never the event loop thread)
        self.persistNewCompletions();
        self.flushResume();
        if (self.resume_writer) |*rw| {
            rw.deinit(self.allocator);
            self.resume_writer = null;
        }

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
        self.torrent_id_in_shared = null;
        self.pending_seed_setup = false;
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
        self.persistNewCompletions();
        self.flushResume();

        // Signal seed setup needed
        self.pending_seed_setup = true;

        // Announce completion on a background thread (blocking HTTP).
        // Uses the shared announce_ring to avoid creating a new ring per announce.
        if (!self.announcing.swap(true, .acq_rel)) {
            const thread = std.Thread.spawn(.{}, announceCompletedWorker, .{self}) catch {
                self.announcing.store(false, .release);
                return true;
            };
            thread.detach();
        }

        return true;
    }

    /// Announce to the tracker as a completed seeder (called from background thread).
    fn announceAsSeeder(self: *TorrentSession) void {
        const session = &(self.session orelse return);
        const announce_url = session.metainfo.announce orelse return;

        if (tracker.announce.fetchAutoWithDns(self.allocator, &self.ring.?, self.getDnsResolver(), .{
            .announce_url = announce_url,
            .info_hash = session.metainfo.info_hash,
            .peer_id = self.peer_id,
            .port = self.port,
            .left = 0,
            .event = .completed,
            .key = self.tracker_key,
            .info_hash_v2 = self.info_hash_v2,
        })) |resp| {
            tracker.announce.freeResponse(self.allocator, resp);
        } else |_| {}
    }

    pub fn announceCompletedWorker(self: *TorrentSession) void {
        defer self.announcing.store(false, .release);

        self.announce_ring_mutex.lock();
        defer self.announce_ring_mutex.unlock();

        // Lazily create the shared announce ring (reused across announces)
        if (self.announce_ring == null) {
            self.announce_ring = Ring.init(16) catch return;
        }

        const session = &(self.session orelse return);
        const announce_url = session.metainfo.announce orelse return;

        if (tracker.announce.fetchAutoWithDns(self.allocator, &self.announce_ring.?, self.getDnsResolver(), .{
            .announce_url = announce_url,
            .info_hash = session.metainfo.info_hash,
            .peer_id = self.peer_id,
            .port = self.port,
            .left = 0,
            .event = .completed,
            .key = self.tracker_key,
            .info_hash_v2 = self.info_hash_v2,
        })) |resp| {
            tracker.announce.freeResponse(self.allocator, resp);
        } else |_| {}
    }

    /// Trigger a background scrape if enough time has passed (30 minutes).
    /// Safe to call from any thread. The scrape runs on a detached background
    /// thread and updates scrape_result atomically.
    pub fn maybeScrape(self: *TorrentSession) void {
        if (self.state != .downloading and self.state != .seeding) return;
        const now = std.time.timestamp();
        const scrape_interval: i64 = 30 * 60; // 30 minutes
        if (now - self.last_scrape_time < scrape_interval) return;

        // Avoid overlapping scrapes
        if (self.scraping.swap(true, .acq_rel)) return;

        self.last_scrape_time = now;
        const thread = std.Thread.spawn(.{}, scrapeWorker, .{self}) catch {
            self.scraping.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn scrapeWorker(self: *TorrentSession) void {
        defer self.scraping.store(false, .release);

        self.announce_ring_mutex.lock();
        defer self.announce_ring_mutex.unlock();

        // Lazily create the shared announce ring (reused across announces and scrapes)
        if (self.announce_ring == null) {
            self.announce_ring = Ring.init(16) catch return;
        }

        const session = &(self.session orelse return);
        const announce_url = session.metainfo.announce orelse return;

        if (tracker.scrape.scrapeAutoWithDns(
            self.allocator,
            &self.announce_ring.?,
            self.getDnsResolver(),
            announce_url,
            session.metainfo.info_hash,
        )) |result| {
            self.scrape_result = result;
        } else |_| {}
    }

    // ── Magnet metadata fetching (BEP 9) ────────────────────

    /// Fetch metadata from peers for a magnet link.
    /// This runs on the background thread before the normal download path.
    /// Uses the resilient MetadataFetcher which handles multi-peer retry,
    /// per-peer timeouts, and progress reporting.
    fn fetchMetadata(self: *TorrentSession) !void {
        const log = std.log.scoped(.metadata_fetch);

        self.state = .metadata_fetching;

        var ring = try Ring.init(16);
        defer ring.deinit();

        // Get tracker URLs from magnet link
        const tracker_urls = self.magnet_trackers orelse {
            self.error_message = std.fmt.allocPrint(self.allocator, "no tracker URLs in magnet link", .{}) catch null;
            return error.NoTrackers;
        };

        // Initialize the multi-peer metadata fetcher
        var fetcher = metadata_fetch.MetadataFetcher.init(
            self.allocator,
            self.info_hash,
            self.peer_id,
            self.port,
            self.is_private,
        );
        defer fetcher.deinit();

        // Announce to all trackers to collect peers
        self.metadata_fetch_progress = .{ .state = .announcing };
        for (tracker_urls) |url| {
            const resp = tracker.announce.fetchAuto(self.allocator, &ring, .{
                .announce_url = url,
                .info_hash = self.info_hash,
                .peer_id = self.peer_id,
                .port = self.port,
                .left = 1, // we need metadata
                .key = self.tracker_key,
            }) catch |err| {
                log.debug("tracker announce failed for {s}: {s}", .{ url, @errorName(err) });
                continue;
            };
            defer tracker.announce.freeResponse(self.allocator, resp);

            for (resp.peers) |peer| {
                fetcher.addPeer(peer.address);
            }
        }

        // Run the fetcher (handles multi-peer retry, timeouts, progress)
        const info_bytes = fetcher.fetch() catch |err| {
            self.metadata_fetch_progress = fetcher.getProgress();
            self.error_message = std.fmt.allocPrint(self.allocator, "metadata fetch failed: {s}", .{@errorName(err)}) catch null;
            return error.MetadataFetchFailed;
        };

        // Update progress snapshot
        self.metadata_fetch_progress = fetcher.getProgress();

        // Build a minimal .torrent file: d8:announce<url>4:info<raw info dict>e
        const torrent_bytes = try self.buildTorrentBytes(info_bytes);
        self.torrent_bytes = torrent_bytes;

        // Update metadata now that we know the actual info
        const meta = @import("../torrent/metainfo.zig").parse(self.allocator, torrent_bytes) catch |err| {
            self.error_message = std.fmt.allocPrint(self.allocator, "metadata parse failed: {s}", .{@errorName(err)}) catch null;
            return err;
        };
        defer @import("../torrent/metainfo.zig").freeMetainfo(self.allocator, meta);

        self.total_size = meta.totalSize();
        self.piece_count = meta.pieceCount() catch 0;

        // Update name if we had a placeholder
        if (self.is_magnet) {
            const new_name = self.allocator.dupe(u8, meta.name) catch null;
            if (new_name) |nn| {
                self.allocator.free(self.name);
                self.name = nn;
            }
        }

        log.info("metadata downloaded successfully: {s} ({d} bytes)", .{ self.name, self.total_size });
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

        if (session.metainfo.announce) |url| {
            try urls.append(self.allocator, url);
        }
        for (session.metainfo.announce_list) |url| {
            var already_added = false;
            for (urls.items) |existing| {
                if (std.mem.eql(u8, existing, url)) {
                    already_added = true;
                    break;
                }
            }
            if (!already_added) try urls.append(self.allocator, url);
        }

        return urls.toOwnedSlice(self.allocator);
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
                rw.recordPiece(self.allocator, i) catch {};
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
            else if (self.event_loop) |*el|
                el.getSpeedStats(0)
            else
                @import("../io/event_loop.zig").SpeedStats{};

            rw.saveTransferStats(.{
                .total_uploaded = self.baseline_uploaded + speed_stats.ul_total,
                .total_downloaded = self.baseline_downloaded + speed_stats.dl_total,
            });
        }
    }

    fn detachFromSharedEventLoop(self: *TorrentSession) void {
        const sel = self.shared_event_loop orelse return;
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
    const peers = try allocator.alloc(EventLoop.Peer, 1);
    @memset(peers, EventLoop.Peer{});
    return .{
        .ring = undefined,
        .allocator = allocator,
        .peers = peers,
        .pending_writes = .empty,
        .pending_sends = std.ArrayList(EventLoop.PendingSend).empty,
        .pending_reads = std.ArrayList(EventLoop.PendingPieceRead).empty,
        .queued_responses = std.ArrayList(EventLoop.QueuedBlockResponse).empty,
        .idle_peers = std.ArrayList(u16).empty,
    };
}

fn deinitTestEventLoop(allocator: std.mem.Allocator, el: *EventLoop) void {
    el.pending_writes.deinit(allocator);
    el.pending_sends.deinit(allocator);
    el.pending_reads.deinit(allocator);
    el.queued_responses.deinit(allocator);
    el.idle_peers.deinit(allocator);
    allocator.free(el.peers);
}

test "stop detaches torrent from shared event loop" {
    var el = try initTestEventLoop(std.testing.allocator);
    defer deinitTestEventLoop(std.testing.allocator, &el);

    const empty_fds = [_]posix.fd_t{};
    el.torrents[0] = .{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    };
    el.torrent_count = 1;

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
    try std.testing.expect(el.torrents[0] == null);
    try std.testing.expectEqual(@as(u8, 0), el.torrent_count);
}

test "resume_session preserves shared event loop mode" {
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

    session.resume_session();
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

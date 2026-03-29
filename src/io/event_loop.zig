const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const pw = @import("../net/peer_wire.zig");
const Hasher = @import("hasher.zig").Hasher;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const socket_util = @import("../net/socket.zig");

const max_peers: u16 = 4096;
const cqe_batch_size = 64;
const pipeline_depth: u32 = 5;

// ── User data encoding ────────────────────────────────────

pub const OpType = enum(u8) {
    peer_connect = 0,
    peer_recv = 1,
    peer_send = 2,
    accept = 3,
    disk_read = 4,
    disk_write = 5,
    http_connect = 6,
    http_send = 7,
    http_recv = 8,
    timeout = 9,
    cancel = 10,
};

pub const OpData = struct {
    slot: u16,
    op_type: OpType,
    context: u40,
};

pub fn encodeUserData(op: OpData) u64 {
    return (@as(u64, op.slot) << 48) |
        (@as(u64, @intFromEnum(op.op_type)) << 40) |
        @as(u64, op.context);
}

pub fn decodeUserData(user_data: u64) OpData {
    return .{
        .slot = @intCast(user_data >> 48),
        .op_type = @enumFromInt(@as(u8, @intCast((user_data >> 40) & 0xFF))),
        .context = @intCast(user_data & 0xFFFFFFFFFF),
    };
}

// ── Peer ──────────────────────────────────────────────────

pub const PeerMode = enum {
    download, // we connected out -- we request pieces
    seed, // peer connected to us -- we serve pieces
};

pub const PeerState = enum {
    free,
    connecting,
    handshake_send,
    handshake_recv,
    inbound_handshake_recv,
    inbound_handshake_send, // sending our handshake back
    inbound_bitfield_send, // sending bitfield
    inbound_unchoke_send, // sending unchoke
    active_recv_header,
    active_recv_body,
    disconnecting,
};

pub const Peer = struct {
    fd: posix.fd_t = -1,
    state: PeerState = .free,
    mode: PeerMode = .download,
    torrent_id: u8 = 0,
    address: std.net.Address = undefined,

    // Recv state: small header buffer, then body on demand
    header_buf: [4]u8 = undefined,
    header_offset: usize = 0,
    handshake_buf: [68]u8 = undefined,
    handshake_offset: usize = 0,
    small_body_buf: [16]u8 = undefined,
    body_buf: ?[]u8 = null,
    body_is_heap: bool = false,
    body_offset: usize = 0,
    body_expected: usize = 0,

    // Peer wire state
    send_pending: bool = false,
    peer_choking: bool = true,
    am_choking: bool = true,
    am_interested: bool = false,
    peer_interested: bool = false,
    availability_known: bool = false,
    availability: ?Bitfield = null,

    // Timing and stats
    last_activity: i64 = 0,
    bytes_downloaded_from: u64 = 0, // bytes we received from this peer
    bytes_uploaded_to: u64 = 0, // bytes we sent to this peer

    // Piece download state
    current_piece: ?u32 = null,
    piece_buf: ?[]u8 = null,
    blocks_received: u32 = 0,
    blocks_expected: u32 = 0,
    pipeline_sent: u32 = 0,
    inflight_requests: u32 = 0,
};

// ── Torrent context (per-torrent state within shared event loop) ──

pub const max_torrents: u8 = 64;

pub const SpeedStats = struct {
    dl_speed: u64 = 0,
    ul_speed: u64 = 0,
    dl_total: u64 = 0,
    ul_total: u64 = 0,
};

pub const TorrentContext = struct {
    session: ?*const session_mod.Session = null,
    piece_tracker: ?*PieceTracker = null,
    shared_fds: []const posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,
    tracker_key: ?[8]u8 = null,
    complete_pieces: ?*const Bitfield = null,
    active: bool = true,

    // Speed tracking (updated every ~2 seconds in tick)
    last_speed_check: i64 = 0,
    last_dl_bytes: u64 = 0,
    last_ul_bytes: u64 = 0,
    current_dl_speed: u64 = 0,
    current_ul_speed: u64 = 0,

    // Per-torrent rate limiters (0 = unlimited)
    rate_limiter: RateLimiter = RateLimiter.initComptime(0, 0),
};

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    const PendingWriteKey = struct {
        piece_index: u32,
        torrent_id: u8,
    };

    const PendingWrite = struct {
        piece_index: u32,
        torrent_id: u8,
        slot: u16,
        buf: []u8,
        spans_remaining: u32,
    };

    const PendingSend = struct {
        buf: []u8,
        sent: usize = 0,
        slot: u16,
    };

    /// Queued piece block response for batched sending.
    /// Multiple blocks queued in the same tick are combined into one send.
    const QueuedBlockResponse = struct {
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
    };

    /// Tracks an async piece read for seed mode.
    /// For multi-span pieces, multiple io_uring reads are submitted.
    /// When all reads complete, the piece response is sent.
    const PendingPieceRead = struct {
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
        read_buf: []u8,
        piece_size: u32,
        reads_remaining: u32, // number of io_uring read CQEs still pending
    };

    ring: linux.IoUring,
    allocator: std.mem.Allocator,
    peers: []Peer,
    peer_count: u16 = 0,
    running: bool = true,

    // Multi-torrent contexts
    torrents: [max_torrents]?TorrentContext = [_]?TorrentContext{null} ** max_torrents,
    torrent_count: u8 = 0,

    // Listening port for tracker announces
    port: u16 = 6881,

    // Bind configuration for outbound sockets
    bind_device: ?[]const u8 = null,
    bind_address: ?[]const u8 = null,

    // Accept socket for seeding (-1 if not seeding)
    listen_fd: posix.fd_t = -1,

    // Complete pieces bitfield (for seeding -- which pieces we can serve)
    complete_pieces: ?*const Bitfield = null,

    // Timeout storage (must outlive the SQE)
    timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },
    timeout_pending: bool = false,

    // Pending disk writes: track buffers that io_uring is writing to disk.
    pending_writes: std.AutoHashMapUnmanaged(PendingWriteKey, PendingWrite),

    // Pending sends: track allocated send buffers (for seed piece responses).
    pending_sends: std.ArrayList(PendingSend),

    // Pending piece reads: async disk reads for seed piece serving.
    pending_reads: std.ArrayList(PendingPieceRead),

    // Piece read cache for seed mode (avoid re-reading from disk per block)
    cached_piece_index: ?u32 = null,
    cached_piece_data: ?[]u8 = null,
    cached_piece_len: usize = 0,

    // Queued piece block responses (batched per tick, flushed after CQE dispatch)
    queued_responses: std.ArrayList(QueuedBlockResponse),

    // Connection limits
    max_connections: u32 = 500,
    max_peers_per_torrent: u32 = 100,
    max_half_open: u32 = 50,
    half_open_count: u32 = 0,

    // Re-announce state
    announce_url: ?[]const u8 = null,
    announce_interval: u32 = 1800,
    last_announce_time: i64 = 0,
    announce_jitter_secs: i32 = 0, // random jitter applied to this torrent's interval
    min_peers_for_reannounce: u16 = 1, // re-announce when below this

    // Global rate limiter (applies across all torrents, 0 = unlimited)
    global_rate_limiter: RateLimiter = RateLimiter.initComptime(0, 0),

    // Background hasher for SHA verification (off event loop thread)
    last_unchoke_recalc: i64 = 0,
    hasher: ?*Hasher = null,
    hash_result_swap: std.ArrayList(Hasher.Result) = std.ArrayList(Hasher.Result).empty,

    // Compact list of peer slots that are idle (active, unchoked, have
    // availability, and need a piece assignment).  Avoids scanning all
    // max_peers slots every tick in tryAssignPieces.
    idle_peers: std.ArrayList(u16),

    /// Create a bare event loop with no initial torrent (for daemon mode).
    pub fn initBare(allocator: std.mem.Allocator, hasher_threads: u32) !EventLoop {
        const peers = try allocator.alloc(Peer, max_peers);
        @memset(peers, Peer{});

        const hasher = if (hasher_threads > 0)
            Hasher.create(allocator, hasher_threads) catch null
        else
            null;

        return .{
            .ring = try linux.IoUring.init(256, 0),
            .allocator = allocator,
            .peers = peers,
            .pending_writes = .empty,
            .pending_sends = std.ArrayList(PendingSend).empty,
            .pending_reads = std.ArrayList(PendingPieceRead).empty,
            .queued_responses = try std.ArrayList(QueuedBlockResponse).initCapacity(allocator, 256),
            .idle_peers = std.ArrayList(u16).empty,
            .hasher = hasher,
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
        hasher_threads: u32,
    ) !EventLoop {
        const peers = try allocator.alloc(Peer, max_peers);
        @memset(peers, Peer{});

        // Only create hasher for download mode (seed doesn't need SHA verification)
        const hasher = if (hasher_threads > 0)
            Hasher.create(allocator, hasher_threads) catch null
        else
            null;

        var el = EventLoop{
            .ring = try linux.IoUring.init(256, 0),
            .allocator = allocator,
            .peers = peers,
            .pending_writes = .empty,
            .pending_sends = std.ArrayList(PendingSend).empty,
            .pending_reads = std.ArrayList(PendingPieceRead).empty,
            .queued_responses = try std.ArrayList(QueuedBlockResponse).initCapacity(allocator, 256),
            .idle_peers = std.ArrayList(u16).empty,
            .hasher = hasher,
        };

        // Register as torrent 0 for backwards compatibility
        el.torrents[0] = .{
            .session = session,
            .piece_tracker = piece_tracker,
            .shared_fds = shared_fds,
            .info_hash = session.metainfo.info_hash,
            .peer_id = peer_id,
        };
        el.torrent_count = 1;

        return el;
    }

    /// Add a new torrent context to the event loop. Returns torrent_id.
    pub fn addTorrent(
        self: *EventLoop,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
    ) !u8 {
        return self.addTorrentWithKey(session, piece_tracker, shared_fds, peer_id, null);
    }

    /// Add a new torrent context with a tracker key. Returns torrent_id.
    pub fn addTorrentWithKey(
        self: *EventLoop,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
        tracker_key: ?[8]u8,
    ) !u8 {
        for (&self.torrents, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{
                    .session = session,
                    .piece_tracker = piece_tracker,
                    .shared_fds = shared_fds,
                    .info_hash = session.metainfo.info_hash,
                    .peer_id = peer_id,
                    .tracker_key = tracker_key,
                };
                self.torrent_count += 1;
                return @intCast(i);
            }
        }
        return error.TooManyTorrents;
    }

    /// Set the complete_pieces bitfield for a torrent (enables seed mode).
    pub fn setTorrentCompletePieces(self: *EventLoop, torrent_id: u8, cp: *const Bitfield) void {
        if (torrent_id < max_torrents) {
            if (self.torrents[torrent_id]) |*tc| {
                tc.complete_pieces = cp;
            }
        }
        // Also set global complete_pieces for backwards compatibility with standalone mode
        self.complete_pieces = cp;
    }

    /// Ensure the event loop is accepting inbound connections.
    /// Safe to call multiple times -- only sets up accepting once.
    pub fn ensureAccepting(self: *EventLoop, listen_fd: posix.fd_t) !void {
        if (self.listen_fd >= 0) return;
        self.listen_fd = listen_fd;
        try self.submitAccept();
    }

    /// Count the number of active peers for a specific torrent.
    pub fn peerCountForTorrent(self: *const EventLoop, torrent_id: u8) u16 {
        var count: u16 = 0;
        for (self.peers) |*peer| {
            if (peer.state != .free and peer.torrent_id == torrent_id) {
                count += 1;
            }
        }
        return count;
    }

    /// Get speed and total byte stats for a specific torrent.
    pub fn getSpeedStats(self: *const EventLoop, torrent_id: u8) SpeedStats {
        if (torrent_id >= max_torrents) return .{};
        const tc = self.torrents[torrent_id] orelse return .{};

        // Sum current totals from all peers for this torrent
        var dl_total: u64 = 0;
        var ul_total: u64 = 0;
        for (self.peers) |*peer| {
            if (peer.state != .free and peer.torrent_id == torrent_id) {
                dl_total += peer.bytes_downloaded_from;
                ul_total += peer.bytes_uploaded_to;
            }
        }

        return .{
            .dl_speed = tc.current_dl_speed,
            .ul_speed = tc.current_ul_speed,
            .dl_total = dl_total,
            .ul_total = ul_total,
        };
    }

    /// Update speed counters for all active torrents (called from tick).
    fn updateSpeedCounters(self: *EventLoop) void {
        const now = std.time.timestamp();

        for (&self.torrents, 0..) |*slot, idx| {
            const tc = &(slot.* orelse continue);
            const tid: u8 = @intCast(idx);

            // Sum bytes across peers for this torrent
            var dl_total: u64 = 0;
            var ul_total: u64 = 0;
            for (self.peers) |*peer| {
                if (peer.state != .free and peer.torrent_id == tid) {
                    dl_total += peer.bytes_downloaded_from;
                    ul_total += peer.bytes_uploaded_to;
                }
            }

            if (tc.last_speed_check == 0) {
                // First check: initialize baselines, no speed yet
                tc.last_speed_check = now;
                tc.last_dl_bytes = dl_total;
                tc.last_ul_bytes = ul_total;
                continue;
            }

            const elapsed = now - tc.last_speed_check;
            if (elapsed < 2) continue;

            const elapsed_u: u64 = @intCast(elapsed);
            const dl_delta = dl_total -| tc.last_dl_bytes;
            const ul_delta = ul_total -| tc.last_ul_bytes;

            tc.current_dl_speed = dl_delta / elapsed_u;
            tc.current_ul_speed = ul_delta / elapsed_u;
            tc.last_speed_check = now;
            tc.last_dl_bytes = dl_total;
            tc.last_ul_bytes = ul_total;
        }
    }

    /// Remove a torrent context and disconnect all its peers.
    pub fn removeTorrent(self: *EventLoop, torrent_id: u8) void {
        // Disconnect all peers for this torrent
        for (self.peers, 0..) |*peer, i| {
            if (peer.state != .free and peer.torrent_id == torrent_id) {
                self.removePeer(@intCast(i));
            }
        }
        self.torrents[torrent_id] = null;
        if (self.torrent_count > 0) self.torrent_count -= 1;
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.hasher) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
        // Free piece cache
        if (self.cached_piece_data) |d| self.allocator.free(d);
        // Free any pending write/send buffers
        {
            var it = self.pending_writes.valueIterator();
            while (it.next()) |pending| {
                self.allocator.free(pending.buf);
            }
        }
        self.pending_writes.deinit(self.allocator);
        for (self.pending_sends.items) |ps| {
            self.allocator.free(ps.buf);
        }
        self.pending_sends.deinit(self.allocator);
        for (self.pending_reads.items) |pr| {
            self.allocator.free(pr.read_buf);
        }
        self.pending_reads.deinit(self.allocator);
        self.queued_responses.deinit(self.allocator);
        self.idle_peers.deinit(self.allocator);
        self.hash_result_swap.deinit(self.allocator);
        for (self.peers) |*peer| {
            self.cleanupPeer(peer);
        }
        self.allocator.free(self.peers);
        self.ring.deinit();
    }

    pub fn addPeer(self: *EventLoop, address: std.net.Address) !u16 {
        return self.addPeerForTorrent(address, 0);
    }

    pub fn addPeerForTorrent(self: *EventLoop, address: std.net.Address, torrent_id: u8) !u16 {
        // Validate address family
        const family = address.any.family;
        if (family != posix.AF.INET and family != posix.AF.INET6) {
            return error.InvalidAddressFamily;
        }

        if (self.torrents[torrent_id] == null) return error.TorrentNotFound;

        // Enforce global connection limit
        if (self.peer_count >= self.max_connections) {
            log.warn("global connection limit reached ({d}/{d})", .{ self.peer_count, self.max_connections });
            return error.ConnectionLimitReached;
        }

        // Enforce per-torrent connection limit
        if (self.peerCountForTorrent(torrent_id) >= self.max_peers_per_torrent) {
            log.warn("per-torrent connection limit reached for torrent {d} ({d}/{d})", .{
                torrent_id,
                self.peerCountForTorrent(torrent_id),
                self.max_peers_per_torrent,
            });
            return error.TorrentConnectionLimitReached;
        }

        // Enforce half-open connection limit
        if (self.half_open_count >= self.max_half_open) {
            return error.HalfOpenLimitReached;
        }

        // Log warning when approaching global limit (>90%)
        const threshold = self.max_connections / 10 * 9;
        if (self.peer_count >= threshold and self.peer_count < self.max_connections) {
            log.warn("approaching global connection limit ({d}/{d})", .{ self.peer_count, self.max_connections });
        }

        const slot = self.allocSlot() orelse return error.TooManyPeers;
        const peer = &self.peers[slot];
        peer.* = Peer{
            .state = .connecting,
            .torrent_id = torrent_id,
            .address = address,
        };

        const fd = try posix.socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);
        peer.fd = fd;

        // Apply bind configuration (SO_BINDTODEVICE and/or local address) to outbound socket
        try socket_util.applyBindConfig(fd, self.bind_device, self.bind_address, 0);

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_connect, .context = 0 });
        // Use peer.address (stored in slot) not the parameter (stack-local, dangling after return)
        _ = try self.ring.connect(ud, fd, &peer.address.any, peer.address.getOsSockLen());

        self.peer_count += 1;
        self.half_open_count += 1;
        return slot;
    }

    /// Start accepting inbound connections for seeding.
    pub fn startAccepting(self: *EventLoop, listen_fd: posix.fd_t, complete_pieces: *const Bitfield) !void {
        self.listen_fd = listen_fd;
        self.complete_pieces = complete_pieces;
        try self.submitAccept();
    }

    fn submitAccept(self: *EventLoop) !void {
        if (self.listen_fd < 0) return;
        const ud = encodeUserData(.{ .slot = 0, .op_type = .accept, .context = 0 });
        _ = try self.ring.accept(ud, self.listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
    }

    pub fn removePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        // Track half-open connection cleanup
        if (peer.state == .connecting and self.half_open_count > 0) {
            self.half_open_count -= 1;
        }
        if (peer.current_piece) |piece_index| {
            if (self.getTorrentContext(peer.torrent_id)) |tc| {
                if (tc.piece_tracker) |pt| pt.releasePiece(piece_index);
            }
        }
        self.unmarkIdle(slot);
        self.cleanupPeer(peer);
        peer.* = Peer{};
        if (self.peer_count > 0) self.peer_count -= 1;
    }

    pub fn run(self: *EventLoop) !void {
        const signal = @import("signal.zig");
        while (self.running and !(if (self.getTorrentContext(0)) |tc| if (tc.piece_tracker) |pt| pt.isComplete() else false else false)) {
            if (signal.isShutdownRequested()) {
                self.running = false;
                break;
            }
            try self.tick();
            if (self.peer_count == 0) break;
        }
    }

    /// Run one iteration of the event loop. Blocks until at least one
    /// CQE is available. Returns the number of CQEs processed.
    const peer_timeout_secs: i64 = 60;
    const unchoke_interval_secs: i64 = 30;
    const max_unchoked: u32 = 4;
    const optimistic_unchoke_slots: u32 = 1;

    /// Configure re-announce parameters.
    pub fn setAnnounce(self: *EventLoop, url: []const u8, interval: u32) void {
        self.announce_url = url;
        self.announce_interval = interval;
        self.last_announce_time = std.time.timestamp();
    }

    pub fn tick(self: *EventLoop) !void {
        self.processHashResults();
        self.checkPeerTimeouts();
        self.checkReannounce();
        self.recalculateUnchokes();
        self.tryAssignPieces();
        self.updateSpeedCounters();

        // Flush any queued SQEs before waiting
        _ = self.ring.submit() catch |err| {
            log.warn("ring submit (pre-wait): {s}", .{@errorName(err)});
        };
        _ = try self.ring.submit_and_wait(1);

        var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, 0);

        for (cqes[0..count]) |cqe| {
            self.dispatch(cqe);
        }

        // Batch-send any queued piece block responses
        self.flushQueuedResponses();

        // Flush any SQEs queued during dispatch (piece responses, block requests, etc.)
        _ = self.ring.submit() catch |err| {
            log.warn("ring submit (post-dispatch): {s}", .{@errorName(err)});
        };
    }

    /// Submit a timeout SQE so that submit_and_wait returns even if
    /// no I/O completes. This allows the caller to do periodic work.
    pub fn submitTimeout(self: *EventLoop, timeout_ns: u64) !void {
        if (self.timeout_pending) return; // previous timeout SQE still in flight
        self.timeout_ts = .{
            .sec = @intCast(timeout_ns / std.time.ns_per_s),
            .nsec = @intCast(timeout_ns % std.time.ns_per_s),
        };
        const ud = encodeUserData(.{ .slot = 0, .op_type = .timeout, .context = 0 });
        _ = try self.ring.timeout(ud, &self.timeout_ts, 0, 0);
        self.timeout_pending = true;
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    // ── Rate limiting ────────────────────────────────────

    /// Set global download rate limit (bytes/sec). 0 = unlimited.
    pub fn setGlobalDlLimit(self: *EventLoop, rate: u64) void {
        self.global_rate_limiter.setDownloadRate(rate);
    }

    /// Set global upload rate limit (bytes/sec). 0 = unlimited.
    pub fn setGlobalUlLimit(self: *EventLoop, rate: u64) void {
        self.global_rate_limiter.setUploadRate(rate);
    }

    /// Get global download rate limit (bytes/sec). 0 = unlimited.
    pub fn getGlobalDlLimit(self: *const EventLoop) u64 {
        return self.global_rate_limiter.download.rate;
    }

    /// Get global upload rate limit (bytes/sec). 0 = unlimited.
    pub fn getGlobalUlLimit(self: *const EventLoop) u64 {
        return self.global_rate_limiter.upload.rate;
    }

    /// Set per-torrent download rate limit (bytes/sec). 0 = unlimited.
    pub fn setTorrentDlLimit(self: *EventLoop, torrent_id: u8, rate: u64) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            tc.rate_limiter.setDownloadRate(rate);
        }
    }

    /// Set per-torrent upload rate limit (bytes/sec). 0 = unlimited.
    pub fn setTorrentUlLimit(self: *EventLoop, torrent_id: u8, rate: u64) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            tc.rate_limiter.setUploadRate(rate);
        }
    }

    /// Get per-torrent download rate limit (bytes/sec). 0 = unlimited.
    pub fn getTorrentDlLimit(self: *const EventLoop, torrent_id: u8) u64 {
        if (torrent_id >= max_torrents) return 0;
        const tc = self.torrents[torrent_id] orelse return 0;
        return tc.rate_limiter.download.rate;
    }

    /// Get per-torrent upload rate limit (bytes/sec). 0 = unlimited.
    pub fn getTorrentUlLimit(self: *const EventLoop, torrent_id: u8) u64 {
        if (torrent_id >= max_torrents) return 0;
        const tc = self.torrents[torrent_id] orelse return 0;
        return tc.rate_limiter.upload.rate;
    }

    /// Check if a download of `amount` bytes is allowed by both per-torrent
    /// and global rate limiters. Returns the number of bytes allowed (may be
    /// less than requested). Returns 0 if throttled.
    fn consumeDownloadTokens(self: *EventLoop, torrent_id: u8, amount: u64) u64 {
        // Check per-torrent limit first
        var allowed = amount;
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (tc.rate_limiter.download.isActive()) {
                allowed = tc.rate_limiter.download.consume(allowed);
                if (allowed == 0) return 0;
            }
        }
        // Then check global limit
        if (self.global_rate_limiter.download.isActive()) {
            allowed = self.global_rate_limiter.download.consume(allowed);
        }
        return allowed;
    }

    /// Check if an upload of `amount` bytes is allowed by both per-torrent
    /// and global rate limiters. Returns the number of bytes allowed.
    fn consumeUploadTokens(self: *EventLoop, torrent_id: u8, amount: u64) u64 {
        var allowed = amount;
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (tc.rate_limiter.upload.isActive()) {
                allowed = tc.rate_limiter.upload.consume(allowed);
                if (allowed == 0) return 0;
            }
        }
        if (self.global_rate_limiter.upload.isActive()) {
            allowed = self.global_rate_limiter.upload.consume(allowed);
        }
        return allowed;
    }

    /// Check if download is currently throttled for a torrent.
    fn isDownloadThrottled(self: *EventLoop, torrent_id: u8) bool {
        if (self.global_rate_limiter.download.isActive()) {
            if (self.global_rate_limiter.download.available() == 0) return true;
        }
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (tc.rate_limiter.download.isActive()) {
                if (tc.rate_limiter.download.available() == 0) return true;
            }
        }
        return false;
    }

    /// Check if upload is currently throttled for a torrent.
    fn isUploadThrottled(self: *EventLoop, torrent_id: u8) bool {
        if (self.global_rate_limiter.upload.isActive()) {
            if (self.global_rate_limiter.upload.available() == 0) return true;
        }
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (tc.rate_limiter.upload.isActive()) {
                if (tc.rate_limiter.upload.available() == 0) return true;
            }
        }
        return false;
    }

    // ── CQE dispatch ──────────────────────────────────────

    fn dispatch(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        const op = decodeUserData(cqe.user_data);
        switch (op.op_type) {
            .peer_connect => self.handleConnect(op.slot, cqe),
            .peer_recv => self.handleRecv(op.slot, cqe),
            .peer_send => self.handleSend(op.slot, cqe),
            .disk_write => self.handleDiskWrite(op.slot, cqe),
            .accept => self.handleAccept(cqe),
            .disk_read => self.handleSeedDiskRead(cqe),
            .timeout => {
                self.timeout_pending = false;
            },
            .http_connect, .http_send, .http_recv, .cancel => {},
        }
    }

    fn handleAccept(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            // Accept failed, try again
            log.warn("accept failed: errno={d}", .{-cqe.res});
            self.submitAccept() catch |err| {
                log.err("re-submit accept after failure: {s}", .{@errorName(err)});
            };
            return;
        }
        const new_fd: posix.fd_t = @intCast(cqe.res);

        // Enforce global connection limit on inbound connections
        if (self.peer_count >= self.max_connections) {
            log.warn("rejecting inbound connection: global limit reached ({d}/{d})", .{
                self.peer_count,
                self.max_connections,
            });
            posix.close(new_fd);
            self.submitAccept() catch |err| {
                log.err("re-submit accept after connection limit: {s}", .{@errorName(err)});
            };
            return;
        }

        // Allocate a peer slot for the inbound connection
        const slot = self.allocSlot() orelse {
            posix.close(new_fd);
            self.submitAccept() catch |err| {
                log.err("re-submit accept after slot exhaustion: {s}", .{@errorName(err)});
            };
            return;
        };

        const peer = &self.peers[slot];
        peer.* = Peer{
            .fd = new_fd,
            .state = .inbound_handshake_recv,
            .mode = .seed,
        };
        peer.handshake_offset = 0;
        self.peer_count += 1;

        // Start receiving the peer's handshake
        self.submitHandshakeRecv(slot) catch {
            self.removePeer(slot);
        };

        // Re-submit accept for more connections
        self.submitAccept() catch |err| {
            log.err("re-submit accept: {s}", .{@errorName(err)});
        };
    }

    fn handleConnect(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        // Connection attempt completed (success or failure) -- no longer half-open
        if (self.half_open_count > 0) self.half_open_count -= 1;

        if (cqe.res < 0) {
            self.removePeer(slot);
            return;
        }
        const peer = &self.peers[slot];
        peer.state = .handshake_send;
        peer.last_activity = std.time.timestamp();

        // Build and send handshake using the peer's torrent context
        const tc = self.getTorrentContext(peer.torrent_id) orelse {
            self.removePeer(slot);
            return;
        };
        var buf: [68]u8 = undefined;
        buf[0] = pw.protocol_length;
        @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
        @memset(buf[20..28], 0);
        @memcpy(buf[28..48], tc.info_hash[0..]);
        @memcpy(buf[48..68], tc.peer_id[0..]);
        @memcpy(peer.handshake_buf[0..68], &buf);

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
        _ = self.ring.send(ud, peer.fd, peer.handshake_buf[0..68], 0) catch {
            self.removePeer(slot);
            return;
        };
        peer.send_pending = true;
    }

    fn handleSend(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        const peer = &self.peers[slot];
        if (cqe.res <= 0) {
            // Check if this was a tracked send buffer -- free it on error
            const op = decodeUserData(cqe.user_data);
            if (op.context == 1) self.freePendingSend(slot);
            self.removePeer(slot);
            return;
        }

        // Check if this was a tracked send buffer (context=1)
        const op = decodeUserData(cqe.user_data);
        if (op.context == 1) {
            const bytes_sent: usize = @intCast(cqe.res);
            // Check for partial send and re-submit remainder
            if (!self.handlePartialSend(slot, bytes_sent)) {
                // Full send complete, free the buffer
                self.freePendingSend(slot);
            }
        }

        peer.send_pending = false;

        switch (peer.state) {
            .handshake_send => {
                // Now recv peer's handshake
                peer.state = .handshake_recv;
                peer.handshake_offset = 0;
                self.submitHandshakeRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .inbound_handshake_send => {
                // Handshake sent -- send bitfield if we have pieces
                const tc_bp = self.getTorrentContext(peer.torrent_id);
                if ((if (tc_bp) |t| t.complete_pieces else null) orelse self.complete_pieces) |cp| {
                    peer.state = .inbound_bitfield_send;
                    self.submitMessage(slot, 5, cp.bits) catch {
                        self.removePeer(slot);
                    };
                } else {
                    // No bitfield to send, go straight to unchoke
                    peer.state = .inbound_unchoke_send;
                    peer.am_choking = false;
                    self.submitMessage(slot, 1, &.{}) catch {
                        self.removePeer(slot);
                    };
                }
            },
            .inbound_bitfield_send => {
                // Bitfield sent -- now send unchoke
                peer.state = .inbound_unchoke_send;
                peer.am_choking = false;
                self.submitMessage(slot, 1, &.{}) catch {
                    self.removePeer(slot);
                };
            },
            .inbound_unchoke_send => {
                // Unchoke sent -- go active
                peer.state = .active_recv_header;
                peer.header_offset = 0;
                self.submitHeaderRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .active_recv_header, .active_recv_body => {
                // Piece request sent or other send completed
                // If we have more pipeline slots, send more requests
                self.tryFillPipeline(slot) catch {
                    self.removePeer(slot);
                };
            },
            else => {},
        }
    }

    fn handleRecv(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        const peer = &self.peers[slot];
        if (cqe.res <= 0) {
            self.removePeer(slot);
            return;
        }
        const n: usize = @intCast(cqe.res);
        const tc_recv = self.getTorrentContext(peer.torrent_id) orelse {
            self.removePeer(slot);
            return;
        };

        switch (peer.state) {
            .handshake_recv => {
                peer.handshake_offset += n;
                if (peer.handshake_offset < 68) {
                    self.submitHandshakeRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Validate handshake
                if (!std.mem.eql(u8, peer.handshake_buf[28..48], tc_recv.info_hash[0..])) {
                    self.removePeer(slot);
                    return;
                }
                // Send interested message
                self.submitMessage(slot, 2, &.{}) catch {
                    self.removePeer(slot);
                    return;
                };
                peer.am_interested = true;
                peer.state = .active_recv_header;
                peer.header_offset = 0;
                self.submitHeaderRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .inbound_handshake_recv => {
                // Seed mode: we received the peer's handshake
                peer.handshake_offset += n;
                if (peer.handshake_offset < 68) {
                    self.submitHandshakeRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Match info_hash against all registered torrents
                const inbound_hash = peer.handshake_buf[28..48];
                var resp_tc: *const TorrentContext = tc_recv;
                var resp_tid: u8 = peer.torrent_id;
                var matched = false;
                for (&self.torrents, 0..) |*tslot, ti| {
                    if (tslot.*) |*tc_match| {
                        if (tc_match.active and std.mem.eql(u8, &tc_match.info_hash, inbound_hash)) {
                            resp_tc = tc_match;
                            resp_tid = @intCast(ti);
                            matched = true;
                            break;
                        }
                    }
                }
                if (!matched) {
                    self.removePeer(slot);
                    return;
                }
                peer.torrent_id = resp_tid;
                // Send our handshake back
                peer.state = .inbound_handshake_send;
                var buf: [68]u8 = undefined;
                buf[0] = pw.protocol_length;
                @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
                @memset(buf[20..28], 0);
                @memcpy(buf[28..48], &resp_tc.info_hash);
                @memcpy(buf[48..68], &resp_tc.peer_id);
                @memcpy(peer.handshake_buf[0..68], &buf);
                const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
                _ = self.ring.send(ud, peer.fd, peer.handshake_buf[0..68], 0) catch {
                    self.removePeer(slot);
                    return;
                };
                peer.send_pending = true;
            },
            .active_recv_header => {
                peer.header_offset += n;
                if (peer.header_offset < 4) {
                    self.submitHeaderRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Parse message length
                const msg_len = std.mem.readInt(u32, &peer.header_buf, .big);
                if (msg_len == 0) {
                    // Keep-alive -- peer is alive
                    peer.last_activity = std.time.timestamp();
                    peer.header_offset = 0;
                    self.submitHeaderRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                if (msg_len > pw.max_message_length) {
                    self.removePeer(slot);
                    return;
                }
                // Use inline buffer for small messages, heap for large ones
                if (msg_len <= peer.small_body_buf.len) {
                    peer.body_buf = peer.small_body_buf[0..msg_len];
                    peer.body_is_heap = false;
                } else {
                    peer.body_buf = self.allocator.alloc(u8, msg_len) catch {
                        self.removePeer(slot);
                        return;
                    };
                    peer.body_is_heap = true;
                }
                peer.body_offset = 0;
                peer.body_expected = msg_len;
                peer.state = .active_recv_body;
                self.submitBodyRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .active_recv_body => {
                peer.body_offset += n;
                if (peer.body_offset < peer.body_expected) {
                    self.submitBodyRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Full message received -- process it
                self.processMessage(slot);
                // Free body and read next header
                if (peer.body_is_heap) {
                    if (peer.body_buf) |buf| self.allocator.free(buf);
                }
                peer.body_buf = null;
                peer.body_is_heap = false;
                peer.state = .active_recv_header;
                peer.header_offset = 0;
                self.submitHeaderRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            else => {},
        }
    }

    fn handleDiskWrite(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        _ = slot;
        const op = decodeUserData(cqe.user_data);
        const piece_index: u32 = @intCast(op.context & 0xFFFFFFFF);
        const write_torrent_id: u8 = @intCast((op.context >> 32) & 0xFF);

        // Find the pending write for this piece and decrement spans_remaining
        const key = PendingWriteKey{ .piece_index = piece_index, .torrent_id = write_torrent_id };
        if (self.pending_writes.getPtr(key)) |pending_w| {
            // Check for write errors (disk full, I/O error, etc.)
            if (cqe.res < 0) {
                log.err("disk write failed for piece {d} torrent {d}: errno={d}", .{
                    piece_index, write_torrent_id, -cqe.res,
                });
                // Release the piece back so it can be re-downloaded
                if (self.getTorrentContext(pending_w.torrent_id)) |tc| {
                    if (tc.piece_tracker) |pt| pt.releasePiece(piece_index);
                }
                self.allocator.free(pending_w.buf);
                _ = self.pending_writes.remove(key);
                return;
            }

            pending_w.spans_remaining -= 1;
            if (pending_w.spans_remaining == 0) {
                // All spans written -- mark piece complete and free buffer
                if (self.getTorrentContext(pending_w.torrent_id)) |tc| {
                    if (tc.session) |sess| {
                        if (piece_index < sess.pieceCount()) {
                            const piece_length = sess.layout.pieceSize(piece_index) catch 0;
                            if (tc.piece_tracker) |pt| _ = pt.completePiece(piece_index, piece_length);
                        }
                    }
                }
                self.allocator.free(pending_w.buf);
                _ = self.pending_writes.remove(key);
            }
        }
    }

    // ── Message processing ────────────────────────────────

    fn processMessage(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const body = peer.body_buf orelse return;
        if (body.len == 0) return;

        // Any message from the peer means it's alive
        peer.last_activity = std.time.timestamp();

        const id = body[0];
        const payload = body[1..];

        switch (id) {
            0 => { // choke
                peer.peer_choking = true;
                // Clear pipeline state
                peer.inflight_requests = 0;
                peer.pipeline_sent = peer.blocks_received;
                self.unmarkIdle(slot);
            },
            1 => {
                peer.peer_choking = false; // unchoke
                self.markIdle(slot);
            },
            2 => { // interested
                peer.peer_interested = true;
                // For seed mode, unchoking is now handled by recalculateUnchokes
                // But for immediate responsiveness, unchoke if under the limit
                if (peer.mode == .seed and peer.am_choking) {
                    peer.am_choking = false;
                    self.submitMessage(slot, 1, &.{}) catch {};
                }
            },
            3 => {
                peer.peer_interested = false;
            }, // not interested
            4 => { // have
                if (payload.len >= 4) {
                    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                    if (peer.availability) |*bf| {
                        bf.set(piece_index) catch {};
                    }
                    peer.availability_known = true;
                    if (self.getTorrentContext(peer.torrent_id)) |tc| {
                        if (tc.piece_tracker) |pt| pt.addAvailability(piece_index);
                    }
                    self.markIdle(slot);
                }
            },
            5 => { // bitfield
                const tc_bf = self.getTorrentContext(peer.torrent_id) orelse return;
                if (peer.availability == null) {
                    const sess = tc_bf.session orelse return;
                    peer.availability = Bitfield.init(self.allocator, sess.pieceCount()) catch return;
                }
                if (peer.availability) |*bf| {
                    bf.importBitfield(payload);
                }
                peer.availability_known = true;
                if (tc_bf.piece_tracker) |pt| pt.addBitfieldAvailability(payload);
                self.markIdle(slot);
            },
            6 => { // request
                if (peer.mode == .seed and !peer.am_choking and payload.len >= 12) {
                    self.servePieceRequest(slot, payload);
                }
            },
            7 => { // piece
                if (payload.len >= 8) {
                    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                    const block_offset = std.mem.readInt(u32, payload[4..8], .big);
                    const block_data = payload[8..];

                    // Consume download tokens for rate limiting accounting
                    _ = self.consumeDownloadTokens(peer.torrent_id, block_data.len);

                    if (peer.current_piece != null and peer.current_piece.? == piece_index) {
                        if (peer.piece_buf) |pbuf| {
                            const start: usize = @intCast(block_offset);
                            const end = start + block_data.len;
                            if (end <= pbuf.len) {
                                @memcpy(pbuf[start..end], block_data);
                                peer.blocks_received += 1;
                                peer.bytes_downloaded_from += block_data.len;
                                if (peer.inflight_requests > 0) peer.inflight_requests -= 1;

                                if (peer.blocks_received >= peer.blocks_expected) {
                                    self.completePieceDownload(slot);
                                } else {
                                    // Refill pipeline — request more blocks if slots available.
                                    // Without this, pieces with more blocks than pipeline_depth stall.
                                    self.tryFillPipeline(slot) catch |err| {
                                        log.debug("pipeline refill failed for slot {d}: {s}", .{ slot, @errorName(err) });
                                    };
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    // ── Re-announce ─────────────────────────────────────────

    fn checkReannounce(self: *EventLoop) void {
        const url = self.announce_url orelse return;
        if (self.peer_count >= self.min_peers_for_reannounce) return;

        const now = std.time.timestamp();
        // Apply jitter to the announce interval (±10% of interval)
        const jittered_interval = @as(i64, self.announce_interval) + @as(i64, self.announce_jitter_secs);
        const effective_interval = @max(jittered_interval, 60); // floor at 60s
        if (now - self.last_announce_time < effective_interval) return;

        self.last_announce_time = now;
        // Generate new jitter for next cycle: ±10% of interval
        self.announce_jitter_secs = self.generateAnnounceJitter();

        // Re-announce using a temporary blocking Ring (not on event loop ring)
        const RingType = @import("ring.zig").Ring;
        var tmp_ring = RingType.init(16) catch return;
        defer tmp_ring.deinit();

        const tc = self.getTorrentContext(0) orelse return;
        const pt = tc.piece_tracker orelse return;
        const tracker_mod = @import("../tracker/root.zig");
        const response = tracker_mod.announce.fetchAuto(self.allocator, &tmp_ring, .{
            .announce_url = url,
            .info_hash = tc.info_hash,
            .peer_id = tc.peer_id,
            .port = self.port,
            .left = if (pt.isComplete()) 0 else pt.bytesRemaining(),
            .event = null,
            .key = tc.tracker_key,
        }) catch return;
        defer tracker_mod.announce.freeResponse(self.allocator, response);

        // Add new peers (respect connection limits)
        for (response.peers) |peer| {
            if (self.peer_count >= self.max_connections) break;
            _ = self.addPeer(peer.address) catch continue;
        }
    }

    /// Generate random jitter for announce interval: ±10% of the interval.
    fn generateAnnounceJitter(self: *const EventLoop) i32 {
        const interval: i32 = @intCast(self.announce_interval);
        const jitter_range = @divTrunc(interval, 5); // 20% total range (±10%)
        if (jitter_range == 0) return 0;
        // Use timestamp-based seed for simple PRNG (good enough for jitter)
        const now: u64 = @bitCast(std.time.timestamp());
        const hash = now *% 6364136223846793005 +% 1442695040888963407;
        const raw: u32 = @truncate(hash >> 33);
        const jitter: i32 = @as(i32, @intCast(raw % @as(u32, @intCast(jitter_range + 1)))) - @divTrunc(jitter_range, 2);
        return jitter;
    }

    // ── Peer timeout ───────────────────────────────────────

    fn checkPeerTimeouts(self: *EventLoop) void {
        const now = std.time.timestamp();
        for (self.peers, 0..) |*peer, i| {
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.last_activity == 0) continue;
            if (peer.mode == .seed) continue; // don't timeout seed peers

            if (now - peer.last_activity > peer_timeout_secs) {
                self.removePeer(@intCast(i));
            }
        }
    }

    // ── Choking algorithm (tit-for-tat) ─────────────────

    fn recalculateUnchokes(self: *EventLoop) void {
        const now = std.time.timestamp();
        if (now - self.last_unchoke_recalc < unchoke_interval_secs) return;
        self.last_unchoke_recalc = now;

        // Collect active seed-mode peers that are interested
        var interested_peers: [max_peers]u16 = undefined;
        var interested_count: u32 = 0;

        for (self.peers, 0..) |*peer, i| {
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.mode != .seed) continue;
            if (!peer.peer_interested) continue;
            if (interested_count < max_peers) {
                interested_peers[interested_count] = @intCast(i);
                interested_count += 1;
            }
        }

        if (interested_count == 0) return;

        // Sort by bytes_downloaded_from (peers that give us most data get unchoked first)
        // For seed-only mode, all peers upload equally, so use bytes_uploaded_to to spread
        const peers_slice = interested_peers[0..interested_count];
        const context = self;
        std.mem.sort(u16, peers_slice, context, struct {
            fn lessThan(ctx: *EventLoop, a: u16, b: u16) bool {
                return ctx.peers[a].bytes_downloaded_from > ctx.peers[b].bytes_downloaded_from;
            }
        }.lessThan);

        // Unchoke top N, choke the rest
        var unchoked: u32 = 0;
        for (peers_slice) |slot| {
            const peer = &self.peers[slot];
            if (unchoked < max_unchoked + optimistic_unchoke_slots) {
                if (peer.am_choking) {
                    peer.am_choking = false;
                    self.submitMessage(slot, 1, &.{}) catch |err| {
                        log.debug("unchoke send for slot {d}: {s}", .{ slot, @errorName(err) });
                    }; // unchoke
                }
                unchoked += 1;
            } else {
                if (!peer.am_choking) {
                    peer.am_choking = true;
                    self.submitMessage(slot, 0, &.{}) catch |err| {
                        log.debug("choke send for slot {d}: {s}", .{ slot, @errorName(err) });
                    }; // choke
                }
            }
        }
    }

    // ── Piece upload (seed mode) ─────────────────────────

    fn servePieceRequest(self: *EventLoop, slot: u16, payload: []const u8) void {
        const piece_index = std.mem.readInt(u32, payload[0..4], .big);
        const block_offset = std.mem.readInt(u32, payload[4..8], .big);
        const block_length = std.mem.readInt(u32, payload[8..12], .big);

        const peer = &self.peers[slot];

        // Check upload rate limit -- drop request if throttled
        if (self.isUploadThrottled(peer.torrent_id)) return;

        const tc = self.getTorrentContext(peer.torrent_id) orelse return;
        const sess = tc.session orelse return;

        // Validate
        // Use per-torrent complete_pieces, falling back to global
        const cp = tc.complete_pieces orelse self.complete_pieces orelse return;
        if (!cp.has(piece_index)) return;
        const piece_size = sess.layout.pieceSize(piece_index) catch return;
        if (block_offset + block_length > piece_size) return;

        // If piece is cached, queue for batched send (flushed after CQE dispatch)
        if (self.cached_piece_index != null and self.cached_piece_index.? == piece_index) {
            self.queued_responses.append(self.allocator, .{
                .slot = slot,
                .piece_index = piece_index,
                .block_offset = block_offset,
                .block_length = block_length,
            }) catch |err| {
                log.warn("queue cached piece response: {s}", .{@errorName(err)});
            };
            return;
        }

        // Submit async io_uring reads for all spans (no blocking)
        const plan = storage.verify.planPieceVerification(self.allocator, sess, piece_index) catch return;
        defer storage.verify.freePiecePlan(self.allocator, plan);

        if (plan.spans.len == 0) return;

        const read_buf = self.allocator.alloc(u8, piece_size) catch return;
        const span_count: u32 = @intCast(plan.spans.len);

        self.pending_reads.append(self.allocator, .{
            .slot = slot,
            .piece_index = piece_index,
            .block_offset = block_offset,
            .block_length = block_length,
            .read_buf = read_buf,
            .piece_size = piece_size,
            .reads_remaining = span_count,
        }) catch {
            self.allocator.free(read_buf);
            return;
        };

        // Submit one io_uring read per span (all non-blocking)
        for (plan.spans) |span| {
            const target = read_buf[span.piece_offset .. span.piece_offset + span.length];
            const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_read, .context = @intCast(piece_index) });
            _ = self.ring.read(ud, tc.shared_fds[span.file_index], .{ .buffer = target }, span.file_offset) catch |err| {
                log.warn("disk read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
            };
        }
    }

    fn handleSeedDiskRead(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        const op = decodeUserData(cqe.user_data);
        const piece_index: u32 = @intCast(op.context);

        // Find the matching pending read and decrement reads_remaining
        for (self.pending_reads.items) |*pr| {
            if (pr.piece_index == piece_index and pr.slot == op.slot) {
                if (cqe.res <= 0) {
                    // Read failed -- abort this pending read entirely
                    pr.reads_remaining = 0;
                    self.allocator.free(pr.read_buf);
                    // Remove from list
                    const idx = (@intFromPtr(pr) - @intFromPtr(self.pending_reads.items.ptr)) / @sizeOf(PendingPieceRead);
                    _ = self.pending_reads.swapRemove(idx);
                    return;
                }

                pr.reads_remaining -= 1;
                if (pr.reads_remaining == 0) {
                    // All spans read -- update cache and send
                    const slot = pr.slot;
                    const pi = pr.piece_index;
                    const bo = pr.block_offset;
                    const bl = pr.block_length;
                    const buf = pr.read_buf;
                    const ps = pr.piece_size;

                    // Remove from pending list
                    const idx = (@intFromPtr(pr) - @intFromPtr(self.pending_reads.items.ptr)) / @sizeOf(PendingPieceRead);
                    _ = self.pending_reads.swapRemove(idx);

                    // Update cache
                    if (self.cached_piece_data) |old| self.allocator.free(old);
                    self.cached_piece_data = buf;
                    self.cached_piece_index = pi;
                    self.cached_piece_len = ps;

                    // Queue for batched send (flushed after CQE dispatch)
                    self.queued_responses.append(self.allocator, .{
                        .slot = slot,
                        .piece_index = pi,
                        .block_offset = bo,
                        .block_length = bl,
                    }) catch {
                        // Fallback: send individually
                        self.sendPieceBlock(slot, pi, bo, bl, buf);
                    };
                }
                return;
            }
        }
    }

    /// Flush all queued piece block responses, batching by peer slot.
    /// All blocks for a given peer are concatenated into one send buffer.
    fn flushQueuedResponses(self: *EventLoop) void {
        if (self.queued_responses.items.len == 0) return;
        const cached_data = self.cached_piece_data orelse {
            self.queued_responses.items.len = 0;
            return;
        };

        // Process all queued responses, grouping by slot.
        // Since most responses in a tick are for the same peer, we use a simple
        // approach: sort by slot, then batch consecutive entries.
        const items = self.queued_responses.items;

        // Sort by slot for grouping
        std.mem.sort(QueuedBlockResponse, items, {}, struct {
            fn lessThan(_: void, a: QueuedBlockResponse, b: QueuedBlockResponse) bool {
                return a.slot < b.slot;
            }
        }.lessThan);

        var i: usize = 0;
        while (i < items.len) {
            const current_slot = items[i].slot;

            // Find end of this peer's batch
            var j = i + 1;
            while (j < items.len and items[j].slot == current_slot) j += 1;
            const batch = items[i..j];

            // Calculate total send buffer size
            var total_len: usize = 0;
            for (batch) |resp| {
                total_len += 4 + 1 + 8 + @as(usize, resp.block_length); // len_prefix + msg_id + piece_index + offset + data
            }

            // Allocate single buffer for all blocks
            const send_buf = self.allocator.alloc(u8, total_len) catch {
                // Fallback: send individually
                for (batch) |resp| {
                    self.sendPieceBlock(resp.slot, resp.piece_index, resp.block_offset, resp.block_length, cached_data);
                }
                i = j;
                continue;
            };

            // Pack all block responses into the buffer
            var offset: usize = 0;
            var total_uploaded: u64 = 0;
            for (batch) |resp| {
                const msg_len: u32 = 1 + 8 + resp.block_length;
                std.mem.writeInt(u32, send_buf[offset..][0..4], msg_len, .big);
                send_buf[offset + 4] = 7; // piece message id
                std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], resp.piece_index, .big);
                std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], resp.block_offset, .big);
                const data_start: usize = @intCast(resp.block_offset);
                @memcpy(send_buf[offset + 13 ..][0..resp.block_length], cached_data[data_start..][0..resp.block_length]);
                offset += 4 + 1 + 8 + @as(usize, resp.block_length);
                total_uploaded += resp.block_length;
            }

            const peer = &self.peers[current_slot];

            // Skip if peer disconnected between queueing and flushing
            if (peer.state == .free or peer.state == .disconnecting) {
                self.allocator.free(send_buf);
                i = j;
                continue;
            }

            // Consume upload tokens for rate limiting
            _ = self.consumeUploadTokens(peer.torrent_id, total_uploaded);

            peer.bytes_uploaded_to += total_uploaded;

            self.pending_sends.append(self.allocator, .{
                .buf = send_buf,
                .slot = current_slot,
            }) catch {
                self.allocator.free(send_buf);
                i = j;
                continue;
            };

            const ud = encodeUserData(.{ .slot = current_slot, .op_type = .peer_send, .context = 1 });
            _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
                self.allocator.free(send_buf);
                i = j;
                continue;
            };
            peer.send_pending = true;

            i = j;
        }

        self.queued_responses.items.len = 0;
    }

    fn sendPieceBlock(self: *EventLoop, slot: u16, piece_index: u32, block_offset: u32, block_length: u32, read_buf: []u8) void {
        const peer = &self.peers[slot];

        // Check upload rate limit
        if (self.isUploadThrottled(peer.torrent_id)) return;

        const msg_len: u32 = 1 + 8 + block_length;
        const total_len: usize = 4 + @as(usize, msg_len);
        const send_buf = self.allocator.alloc(u8, total_len) catch return;

        std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
        send_buf[4] = 7;
        std.mem.writeInt(u32, send_buf[5..9], piece_index, .big);
        std.mem.writeInt(u32, send_buf[9..13], block_offset, .big);
        @memcpy(send_buf[13..total_len], read_buf[@intCast(block_offset)..][0..block_length]);

        // Consume upload tokens
        _ = self.consumeUploadTokens(peer.torrent_id, block_length);
        peer.bytes_uploaded_to += block_length;

        self.pending_sends.append(self.allocator, .{
            .buf = send_buf,
            .slot = slot,
        }) catch {
            self.allocator.free(send_buf);
            return;
        };

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 });
        _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
            self.allocator.free(send_buf);
            return;
        };
        peer.send_pending = true;
    }

    // ── Idle-peer tracking (for efficient tryAssignPieces) ─

    /// Returns true when a slot is eligible for piece assignment.
    fn isIdleCandidate(peer: *const Peer) bool {
        return (peer.state == .active_recv_header or peer.state == .active_recv_body) and
            peer.current_piece == null and
            !peer.peer_choking and
            peer.availability_known;
    }

    /// Add a slot to the idle_peers list if it is eligible and not already present.
    fn markIdle(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        if (!isIdleCandidate(peer)) return;
        // Avoid duplicates by scanning the (small) list.
        for (self.idle_peers.items) |s| {
            if (s == slot) return;
        }
        self.idle_peers.append(self.allocator, slot) catch |err| {
            log.debug("idle_peers append for slot {d}: {s}", .{ slot, @errorName(err) });
        };
    }

    /// Remove a slot from the idle_peers list (swap-remove for O(1)).
    fn unmarkIdle(self: *EventLoop, slot: u16) void {
        for (self.idle_peers.items, 0..) |s, idx| {
            if (s == slot) {
                _ = self.idle_peers.swapRemove(idx);
                return;
            }
        }
    }

    // ── Piece download coordination ───────────────────────

    fn tryAssignPieces(self: *EventLoop) void {
        var i: usize = 0;
        while (i < self.idle_peers.items.len) {
            const slot = self.idle_peers.items[i];
            const peer = &self.peers[slot];

            // Re-check eligibility (state may have changed since enqueue).
            if (!isIdleCandidate(peer)) {
                _ = self.idle_peers.swapRemove(i);
                continue;
            }

            // Skip piece assignment when download is throttled
            if (self.isDownloadThrottled(peer.torrent_id)) {
                i += 1;
                continue;
            }

            const tc = self.getTorrentContext(peer.torrent_id) orelse {
                _ = self.idle_peers.swapRemove(i);
                continue;
            };
            const pt = tc.piece_tracker orelse {
                _ = self.idle_peers.swapRemove(i);
                continue;
            };

            const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
            const piece_index = pt.claimPiece(peer_bf) orelse {
                // No piece available for this peer right now; keep it in the
                // list so we retry next tick.
                i += 1;
                continue;
            };

            self.startPieceDownload(slot, piece_index) catch {
                pt.releasePiece(piece_index);
                i += 1;
                continue;
            };

            // Successfully assigned -- remove from idle list.
            _ = self.idle_peers.swapRemove(i);
        }
    }

    fn startPieceDownload(self: *EventLoop, slot: u16, piece_index: u32) !void {
        const peer = &self.peers[slot];
        const tc = self.getTorrentContext(peer.torrent_id) orelse return error.TorrentNotFound;
        const sess = tc.session orelse return error.TorrentNotFound;
        const piece_size = try sess.layout.pieceSize(piece_index);
        const geometry = sess.geometry();
        const block_count = try geometry.blockCount(piece_index);

        peer.current_piece = piece_index;
        peer.piece_buf = try self.allocator.alloc(u8, piece_size);
        peer.blocks_received = 0;
        peer.blocks_expected = block_count;
        peer.pipeline_sent = 0;
        peer.inflight_requests = 0;

        try self.tryFillPipeline(slot);
    }

    fn tryFillPipeline(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        const piece_index = peer.current_piece orelse return;
        if (peer.peer_choking) return;
        if (peer.send_pending) return;

        // Skip filling pipeline when download is throttled
        if (self.isDownloadThrottled(peer.torrent_id)) return;

        const tc = self.getTorrentContext(peer.torrent_id) orelse return;
        const sess = tc.session orelse return;
        const geometry = sess.geometry();

        // Count how many requests to send
        var to_send: u32 = 0;
        while (peer.inflight_requests + to_send < pipeline_depth and peer.pipeline_sent + to_send < peer.blocks_expected) {
            to_send += 1;
        }
        if (to_send == 0) return;

        // Build all requests into one buffer (17 bytes each: 4 len + 1 id + 12 payload)
        const request_size: usize = 17;
        const total_len = request_size * to_send;
        const send_buf = self.allocator.alloc(u8, total_len) catch return;

        var i: u32 = 0;
        while (i < to_send) : (i += 1) {
            const req = geometry.requestForBlock(piece_index, peer.pipeline_sent + i) catch {
                self.allocator.free(send_buf);
                return;
            };
            const offset = i * request_size;
            // 4-byte length prefix
            std.mem.writeInt(u32, send_buf[offset..][0..4], 13, .big); // 1 + 12
            send_buf[offset + 4] = 6; // request message id
            std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], req.piece_index, .big);
            std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], req.piece_offset, .big);
            std.mem.writeInt(u32, send_buf[offset + 13 ..][0..4], req.length, .big);
        }

        // Track for cleanup
        self.pending_sends.append(self.allocator, .{ .buf = send_buf, .slot = slot }) catch {
            self.allocator.free(send_buf);
            return;
        };

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 });
        _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
            self.allocator.free(send_buf);
            return;
        };
        peer.send_pending = true;
        peer.pipeline_sent += to_send;
        peer.inflight_requests += to_send;
    }

    fn completePieceDownload(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const piece_index = peer.current_piece orelse return;
        const piece_buf = peer.piece_buf orelse return;

        const tc = self.getTorrentContext(peer.torrent_id) orelse return;
        const sess = tc.session orelse return;
        const pt = tc.piece_tracker orelse return;

        // Get the expected hash for this piece
        const expected_hash = sess.layout.pieceHash(piece_index) catch {
            pt.releasePiece(piece_index);
            peer.current_piece = null;
            self.markIdle(slot);
            return;
        };
        var hash: [20]u8 = undefined;
        @memcpy(&hash, expected_hash);

        if (self.hasher) |h| {
            // Submit to background hasher thread (non-blocking)
            h.submitVerify(slot, piece_index, piece_buf, hash, peer.torrent_id) catch {
                pt.releasePiece(piece_index);
                peer.current_piece = null;
                self.markIdle(slot);
                return;
            };
            // Don't free piece_buf -- the hasher owns it now.
            // The peer can start downloading another piece immediately.
            peer.piece_buf = null;
            peer.current_piece = null;
            self.markIdle(slot);
        } else {
            // Fallback: inline verification and write (blocks event loop).
            // This path is only reached if the hasher thread pool failed to create.
            var actual: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(piece_buf[0..piece_buf.len], &actual, .{});
            const valid = std.mem.eql(u8, &actual, &hash);
            if (valid) {
                // Write piece to disk via io_uring
                const plan = storage.verify.planPieceVerification(self.allocator, sess, piece_index) catch {
                    pt.releasePiece(piece_index);
                    self.allocator.free(piece_buf);
                    peer.piece_buf = null;
                    peer.current_piece = null;
                    self.markIdle(slot);
                    return;
                };
                defer storage.verify.freePiecePlan(self.allocator, plan);

                const span_count: u32 = @intCast(plan.spans.len);
                if (span_count == 0) {
                    pt.releasePiece(piece_index);
                    self.allocator.free(piece_buf);
                    peer.piece_buf = null;
                    peer.current_piece = null;
                    self.markIdle(slot);
                    return;
                }

                // Track pending writes for completion
                self.pending_writes.put(self.allocator, .{
                    .piece_index = piece_index,
                    .torrent_id = peer.torrent_id,
                }, .{
                    .piece_index = piece_index,
                    .torrent_id = peer.torrent_id,
                    .slot = slot,
                    .buf = piece_buf,
                    .spans_remaining = span_count,
                }) catch {
                    pt.releasePiece(piece_index);
                    self.allocator.free(piece_buf);
                    peer.piece_buf = null;
                    peer.current_piece = null;
                    self.markIdle(slot);
                    return;
                };

                for (plan.spans) |span| {
                    const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
                    const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_write, .context = @as(u40, @intCast(peer.torrent_id)) << 32 | @as(u40, piece_index) });
                    _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                        log.warn("inline disk write for piece {d}: {s}", .{ piece_index, @errorName(err) });
                        continue;
                    };
                }
                // Buffer ownership transferred to pending_writes; will be freed on completion
                peer.piece_buf = null;
            } else {
                // Hash mismatch -- release piece and free buffer
                pt.releasePiece(piece_index);
                self.allocator.free(piece_buf);
                peer.piece_buf = null;
            }
            peer.current_piece = null;
            self.markIdle(slot);
        }
    }

    /// Process completed hash results from the background hasher.
    /// Called each tick from the event loop.
    pub fn processHashResults(self: *EventLoop) void {
        const h = self.hasher orelse return;
        const results = h.drainResultsInto(&self.hash_result_swap);
        for (results) |result| {
            // Use torrent_id stored in the hash result (not from the slot,
            // which may have been freed and reassigned since submission).
            const torrent_id = result.torrent_id;
            const tc = self.getTorrentContext(torrent_id) orelse {
                self.allocator.free(result.piece_buf);
                continue;
            };

            if (result.valid) {
                const sess = tc.session orelse {
                    self.allocator.free(result.piece_buf);
                    continue;
                };

                // Endgame duplicate: another peer already verified this piece
                // and a write is in flight. Skip the duplicate -- just free
                // the buffer and mark the piece complete (the first write
                // will handle persistence).
                const pending_key = PendingWriteKey{
                    .piece_index = result.piece_index,
                    .torrent_id = torrent_id,
                };
                if (self.pending_writes.contains(pending_key)) {
                    log.debug("skipping duplicate write for piece {d} torrent {d} (endgame)", .{
                        result.piece_index, torrent_id,
                    });
                    self.allocator.free(result.piece_buf);
                    continue;
                }

                // Write verified piece to disk via io_uring
                const plan = storage.verify.planPieceVerification(self.allocator, sess, result.piece_index) catch {
                    self.allocator.free(result.piece_buf);
                    continue;
                };
                defer storage.verify.freePiecePlan(self.allocator, plan);

                const span_count: u32 = @intCast(plan.spans.len);
                if (span_count == 0) {
                    self.allocator.free(result.piece_buf);
                    continue;
                }

                // Track the buffer so we can free it after all writes complete
                self.pending_writes.put(self.allocator, .{
                    .piece_index = result.piece_index,
                    .torrent_id = torrent_id,
                }, .{
                    .piece_index = result.piece_index,
                    .torrent_id = torrent_id,
                    .slot = result.slot,
                    .buf = result.piece_buf,
                    .spans_remaining = span_count,
                }) catch {
                    self.allocator.free(result.piece_buf);
                    continue;
                };

                for (plan.spans) |span| {
                    const block = result.piece_buf[span.piece_offset .. span.piece_offset + span.length];
                    const ud = encodeUserData(.{ .slot = result.slot, .op_type = .disk_write, .context = @as(u40, @intCast(torrent_id)) << 32 | @as(u40, result.piece_index) });
                    _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                        log.warn("disk write submit for piece {d}: {s}", .{ result.piece_index, @errorName(err) });
                        continue;
                    };
                }
            } else {
                // Hash mismatch -- release piece back to pool
                if (tc.piece_tracker) |pt| pt.releasePiece(result.piece_index);
                self.allocator.free(result.piece_buf);
            }
        }
        // Results are already swapped out of the hasher -- no clearResults needed.
        self.hash_result_swap.clearRetainingCapacity();
    }

    // ── SQE helpers ───────────────────────────────────────

    fn submitHandshakeRecv(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        const buf = peer.handshake_buf[peer.handshake_offset..68];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
        _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0);
    }

    fn submitHeaderRecv(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        const buf = peer.header_buf[peer.header_offset..4];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
        _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0);
    }

    fn submitBodyRecv(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        const buf = peer.body_buf orelse return error.NullBuffer;
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
        _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf[peer.body_offset..peer.body_expected] }, 0);
    }

    fn submitMessage(self: *EventLoop, slot: u16, id: u8, payload: []const u8) !void {
        const peer = &self.peers[slot];
        // Build framed message: 4-byte length + id + payload
        const msg_len = @as(u32, @intCast(1 + payload.len));
        var header: [5]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], msg_len, .big);
        header[4] = id;

        // For small messages, combine into one send
        if (payload.len <= 12) {
            var combined: [17]u8 = undefined; // 5 + 12
            @memcpy(combined[0..5], &header);
            @memcpy(combined[5 .. 5 + payload.len], payload);
            // Store in handshake_buf (reused as small send buffer)
            @memcpy(peer.handshake_buf[0 .. 5 + payload.len], combined[0 .. 5 + payload.len]);
            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
            _ = try self.ring.send(ud, peer.fd, peer.handshake_buf[0 .. 5 + payload.len], 0);
            peer.send_pending = true;
        } else {
            // For larger messages, allocate a buffer for the complete message
            const total_len = 5 + payload.len;
            const send_buf = try self.allocator.alloc(u8, total_len);
            @memcpy(send_buf[0..5], &header);
            @memcpy(send_buf[5..total_len], payload);

            // Track for cleanup
            try self.pending_sends.append(self.allocator, .{ .buf = send_buf, .slot = slot });

            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 }); // context=1 = tracked
            _ = try self.ring.send(ud, peer.fd, send_buf, 0);
            peer.send_pending = true;
        }
    }

    /// Handle partial send: re-submit remaining bytes. Returns true if partial (more to send).
    fn handlePartialSend(self: *EventLoop, slot: u16, bytes_sent: usize) bool {
        for (self.pending_sends.items) |*ps| {
            if (ps.slot == slot) {
                ps.sent += bytes_sent;
                if (ps.sent < ps.buf.len) {
                    // Partial send -- re-submit remainder
                    const remaining = ps.buf[ps.sent..];
                    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 });
                    _ = self.ring.send(ud, self.peers[slot].fd, remaining, 0) catch {
                        return false; // treat as complete on error
                    };
                    self.peers[slot].send_pending = true;
                    return true;
                }
                return false; // fully sent
            }
        }
        return false;
    }

    fn freePendingSend(self: *EventLoop, slot: u16) void {
        var i: usize = 0;
        while (i < self.pending_sends.items.len) {
            if (self.pending_sends.items[i].slot == slot) {
                self.allocator.free(self.pending_sends.items[i].buf);
                _ = self.pending_sends.swapRemove(i);
                // Don't increment i -- swapRemove moved a new element here.
                // Don't return -- there may be more entries for this slot.
                continue;
            }
            i += 1;
        }
    }

    fn getTorrentContext(self: *EventLoop, torrent_id: u8) ?*TorrentContext {
        if (torrent_id >= max_torrents) return null;
        return if (self.torrents[torrent_id]) |*tc| tc else null;
    }

    fn cleanupPeer(self: *EventLoop, peer: *Peer) void {
        if (peer.fd >= 0) posix.close(peer.fd);
        if (peer.body_is_heap) {
            if (peer.body_buf) |buf| self.allocator.free(buf);
        }
        if (peer.piece_buf) |buf| self.allocator.free(buf);
        if (peer.availability) |*bf| bf.deinit(self.allocator);
    }

    fn allocSlot(self: *EventLoop) ?u16 {
        for (self.peers, 0..) |*peer, i| {
            if (peer.state == .free) return @intCast(i);
        }
        return null;
    }
};

// ── Tests ─────────────────────────────────────────────────

test "user data encode/decode roundtrip" {
    const op = OpData{ .slot = 42, .op_type = .peer_recv, .context = 12345 };
    const encoded = encodeUserData(op);
    const decoded = decodeUserData(encoded);

    try std.testing.expectEqual(@as(u16, 42), decoded.slot);
    try std.testing.expectEqual(OpType.peer_recv, decoded.op_type);
    try std.testing.expectEqual(@as(u40, 12345), decoded.context);
}

test "user data max values" {
    const op = OpData{ .slot = 65535, .op_type = .cancel, .context = std.math.maxInt(u40) };
    const decoded = decodeUserData(encodeUserData(op));

    try std.testing.expectEqual(@as(u16, 65535), decoded.slot);
    try std.testing.expectEqual(OpType.cancel, decoded.op_type);
    try std.testing.expectEqual(std.math.maxInt(u40), decoded.context);
}

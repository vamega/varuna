const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const session_mod = @import("../torrent/session.zig");
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const Hasher = @import("hasher.zig").Hasher;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const pex_mod = @import("../net/pex.zig");
const socket_util = @import("../net/socket.zig");
const utp_mod = @import("../net/utp.zig");
const utp_mgr = @import("../net/utp_manager.zig");
const mse = @import("../crypto/mse.zig");
const SuperSeedState = @import("super_seed.zig").SuperSeedState;
const HugePageCache = @import("../storage/huge_page_cache.zig").HugePageCache;
const MerkleCache = @import("../torrent/merkle_cache.zig").MerkleCache;

// Sub-modules: focused implementations that operate on *EventLoop
const peer_handler = @import("peer_handler.zig");
const protocol = @import("protocol.zig");
const seed_handler = @import("seed_handler.zig");
const peer_policy = @import("peer_policy.zig");
const utp_handler = @import("utp_handler.zig");
const dht_handler = @import("dht_handler.zig");

pub const max_peers: u16 = 4096;
const cqe_batch_size = 64;

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
    utp_recv = 11,
    utp_send = 12,
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

pub const Transport = enum {
    tcp,
    utp,
};

pub const PeerState = enum {
    free,
    connecting,
    mse_handshake_send, // MSE/PE: sending during async MSE handshake (outbound)
    mse_handshake_recv, // MSE/PE: receiving during async MSE handshake (outbound)
    mse_resp_send, // MSE/PE: sending during async MSE handshake (inbound responder)
    mse_resp_recv, // MSE/PE: receiving during async MSE handshake (inbound responder)
    handshake_send,
    handshake_recv,
    extension_handshake_send, // BEP 10: sending extension handshake after peer handshake
    inbound_handshake_recv,
    inbound_handshake_send, // sending our handshake back
    inbound_extension_handshake_send, // BEP 10: sending extension handshake (inbound)
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
    transport: Transport = .tcp,
    torrent_id: u8 = 0,
    address: std.net.Address = undefined,
    utp_slot: ?u16 = null, // UtpManager slot index (only for uTP peers)

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

    // Remote peer identification (from handshake)
    remote_peer_id: [20]u8 = [_]u8{0} ** 20,
    has_peer_id: bool = false,

    // Timing and stats
    last_activity: i64 = 0,
    bytes_downloaded_from: u64 = 0, // bytes we received from this peer
    bytes_uploaded_to: u64 = 0, // bytes we sent to this peer

    // Per-peer speed tracking (rolling window, updated every ~2s in tick)
    last_speed_check: i64 = 0,
    last_dl_bytes: u64 = 0,
    last_ul_bytes: u64 = 0,
    current_dl_speed: u64 = 0,
    current_ul_speed: u64 = 0,

    // Piece download state
    current_piece: ?u32 = null,
    piece_buf: ?[]u8 = null,
    blocks_received: u32 = 0,
    blocks_expected: u32 = 0,
    pipeline_sent: u32 = 0,
    inflight_requests: u32 = 0,

    // BEP 10 extension protocol state
    extensions_supported: bool = false, // peer advertised BEP 10 support
    extension_ids: ?ext.ExtensionIds = null, // peer's extension ID mapping

    // BEP 11 PEX state (per-peer, tracks what we have sent to this peer)
    pex_state: ?*pex_mod.PexState = null,

    // MSE/PE (BEP 6) encryption state
    crypto: mse.PeerCrypto = mse.PeerCrypto.plaintext,
    // Async MSE handshake state (heap-allocated, freed on completion/disconnect)
    mse_initiator: ?*mse.MseInitiatorHandshake = null,
    mse_responder: ?*mse.MseResponderHandshake = null,
    // Track whether this peer previously rejected MSE (don't retry on reconnect)
    mse_rejected: bool = false,
    // Track whether we're in MSE fallback (reconnecting without MSE)
    mse_fallback: bool = false,
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
    is_private: bool = false,

    // BEP 52: v2 info-hash (SHA-256, truncated to 20 bytes for handshake matching).
    // null for pure v1 torrents. For hybrid torrents, inbound peers may connect
    // using either the v1 or v2 info-hash.
    info_hash_v2: ?[20]u8 = null,

    // Speed tracking (updated every ~2 seconds in tick)
    last_speed_check: i64 = 0,
    last_dl_bytes: u64 = 0,
    last_ul_bytes: u64 = 0,
    current_dl_speed: u64 = 0,
    current_ul_speed: u64 = 0,

    // Per-torrent rate limiters (0 = unlimited)
    rate_limiter: RateLimiter = RateLimiter.initComptime(0, 0),

    // BEP 11 PEX state (per-torrent, tracks currently connected peers)
    pex_state: ?*pex_mod.TorrentPexState = null,

    // BEP 16: super-seeding state (null if super-seeding is disabled)
    super_seed: ?*SuperSeedState = null,

    // BEP 52: per-file Merkle tree cache for hash serving
    merkle_cache: ?*MerkleCache = null,
};

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    pub const PendingWriteKey = struct {
        piece_index: u32,
        torrent_id: u8,
    };

    pub const PendingWrite = struct {
        piece_index: u32,
        torrent_id: u8,
        slot: u16,
        buf: []u8,
        spans_remaining: u32,
        write_failed: bool = false,
    };

    pub const PendingSend = struct {
        buf: []u8,
        sent: usize = 0,
        slot: u16,
        /// Unique ID for matching CQEs to the correct PendingSend when
        /// multiple sends are in-flight for the same slot.
        send_id: u32,
    };

    /// A uTP packet waiting to be sent over the UDP socket.
    /// Sized for a full UDP datagram (header + payload).
    pub const UtpQueuedPacket = struct {
        data: [1500]u8 = undefined,
        len: usize = 0,
        remote: std.net.Address,
    };

    /// Queued piece block response for batched sending.
    /// Multiple blocks queued in the same tick are combined into one send.
    /// Each entry owns an exact copy of the block bytes to keep batching
    /// correct even if the piece cache changes before flush.
    pub const QueuedBlockResponse = struct {
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
        block_data: []u8,
    };

    /// Tracks an async piece read for seed mode.
    /// For multi-span pieces, multiple io_uring reads are submitted.
    /// When all reads complete, the piece response is sent.
    pub const PendingPieceRead = struct {
        read_id: u32,
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
        read_buf: []u8,
        piece_size: u32,
        reads_remaining: u32, // number of successfully submitted read CQEs still pending
        from_pool: bool = false, // true if read_buf is from huge page pool (don't free)
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

    // MSE/PE (BEP 6) encryption mode
    encryption_mode: mse.EncryptionMode = .preferred,

    // Accept socket for seeding (-1 if not seeding)
    listen_fd: posix.fd_t = -1,

    // uTP over UDP: single UDP socket + connection multiplexer
    udp_fd: posix.fd_t = -1,
    utp_manager: ?*utp_mgr.UtpManager = null,
    // Persistent recv buffer and msghdr for io_uring RECVMSG
    utp_recv_buf: [1500]u8 = undefined,
    utp_recv_iov: [1]posix.iovec = undefined,
    utp_recv_addr: posix.sockaddr align(4) = undefined,
    utp_recv_msg: posix.msghdr = undefined,
    // Persistent send buffer and msghdr for io_uring SENDMSG
    utp_send_buf: [1500]u8 = undefined,
    utp_send_iov: [1]posix.iovec_const = undefined,
    utp_send_addr: posix.sockaddr align(4) = undefined,
    utp_send_msg: posix.msghdr_const = undefined,
    utp_send_pending: bool = false,
    // Outbound packet queue (when a send is already in flight)
    utp_send_queue: std.ArrayList(UtpQueuedPacket) = std.ArrayList(UtpQueuedPacket).empty,

    // DHT (BEP 5): distributed hash table engine for trackerless peer discovery.
    // Shares the UDP socket with uTP. Incoming datagrams starting with 'd'
    // (bencode dict) are routed to DHT; others go to uTP.
    dht_engine: ?*@import("../dht/dht.zig").DhtEngine = null,

    // Complete pieces bitfield (for seeding -- which pieces we can serve)
    complete_pieces: ?*const Bitfield = null,

    // Timeout storage (must outlive the SQE)
    timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },
    timeout_pending: bool = false,

    // Pending disk writes: track buffers that io_uring is writing to disk.
    pending_writes: std.AutoHashMapUnmanaged(PendingWriteKey, PendingWrite),

    // Pending sends: track allocated send buffers (for seed piece responses).
    pending_sends: std.ArrayList(PendingSend),
    // Monotonic counter for unique PendingSend identification across CQEs.
    // Starts at 1 because context=0 means "untracked send" (no PendingSend entry).
    next_send_id: u32 = 1,

    // Pending piece reads: async disk reads for seed piece serving.
    pending_reads: std.ArrayList(PendingPieceRead),
    next_seed_read_id: u32 = 1,

    // Piece read cache for seed mode (avoid re-reading from disk per block)
    cached_piece_index: ?u32 = null,
    cached_piece_data: ?[]u8 = null,
    cached_piece_len: usize = 0,
    cached_piece_from_pool: bool = false, // true if from huge page pool (don't free)

    // Huge page piece cache buffer pool (optional, configured at init time).
    // When allocated, piece read buffers are served from this pool instead
    // of the general-purpose allocator. Reduces TLB pressure for large torrents.
    huge_page_cache: ?HugePageCache = null,

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
    // Background announce thread state: announce runs on a background thread
    // with its own io_uring ring to avoid blocking the main event loop.
    // The ring is created once and reused across announces.
    announce_ring: ?@import("ring.zig").Ring = null,
    announcing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Peers discovered by the background announce thread, picked up by the
    // main thread on the next tick. Protected by atomic flag.
    announce_result_peers: ?[]std.net.Address = null,
    announce_results_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    // ── Lifecycle ──────────────────────────────────────────

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

    pub fn deinit(self: *EventLoop) void {
        if (self.hasher) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }

        // ── Phase 1: Close all file descriptors ──────────────────
        // Close peer fds, listen fd, and UDP fd so the kernel cancels
        // pending io_uring operations that reference our buffers.
        // Do NOT free buffers yet -- the kernel may still be
        // completing cancelled SQEs that reference them.
        for (self.peers) |*peer| {
            // Clean up uTP slot state
            if (peer.transport == .utp) {
                if (peer.utp_slot) |utp_slot| {
                    if (self.utp_manager) |mgr| {
                        const now_us = @import("utp_handler.zig").utpNowUs();
                        _ = mgr.reset(utp_slot, now_us);
                    }
                }
            }
            if (peer.fd >= 0) {
                posix.close(peer.fd);
                peer.fd = -1;
            }
        }
        if (self.listen_fd >= 0) {
            posix.close(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.udp_fd >= 0) {
            posix.close(self.udp_fd);
            self.udp_fd = -1;
        }

        // ── Phase 2: Drain the ring ──────────────────────────────
        // After closing fds, any in-flight SQEs will complete with
        // errors. Drain all remaining CQEs so the kernel is finished
        // touching our buffer memory before we free it. This prevents
        // use-after-free under GPA (debug poison 0xAA fill on free).
        self.drainRemainingCqes();

        // ── Phase 3: Free all buffers ────────────────────────────
        // Now that the kernel has completed all pending operations,
        // it is safe to free the buffers they referenced.
        // Free piece cache (only if not from huge page pool)
        if (self.cached_piece_data) |d| {
            if (!self.cached_piece_from_pool) self.allocator.free(d);
        }
        // Free huge page cache pool
        if (self.huge_page_cache) |*hpc| hpc.deinit();
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
            if (!pr.from_pool) self.allocator.free(pr.read_buf);
        }
        self.pending_reads.deinit(self.allocator);
        for (self.queued_responses.items) |resp| {
            self.allocator.free(resp.block_data);
        }
        self.queued_responses.deinit(self.allocator);
        self.idle_peers.deinit(self.allocator);
        self.hash_result_swap.deinit(self.allocator);
        for (self.peers) |*peer| {
            // fd already closed in Phase 1; free remaining heap buffers
            if (peer.body_is_heap) {
                if (peer.body_buf) |buf| self.allocator.free(buf);
            }
            if (peer.piece_buf) |buf| self.allocator.free(buf);
            if (peer.availability) |*bf| bf.deinit(self.allocator);
            // Free async MSE handshake state
            if (peer.mse_initiator) |mi| self.allocator.destroy(mi);
            if (peer.mse_responder) |mr| self.allocator.destroy(mr);
        }
        self.allocator.free(self.peers);
        // Clean up torrent PEX state
        for (&self.torrents) |*tslot| {
            if (tslot.*) |*tc| {
                if (tc.pex_state) |tps| {
                    tps.deinit(self.allocator);
                    self.allocator.destroy(tps);
                }
            }
        }
        // Clean up shared announce ring (created once, reused across announces)
        if (self.announce_ring) |*r| r.deinit();
        if (self.announce_result_peers) |peers| self.allocator.free(peers);
        // Clean up uTP resources
        if (self.utp_manager) |mgr| self.allocator.destroy(mgr);
        self.utp_send_queue.deinit(self.allocator);

        // ── Phase 4: Tear down the ring ──────────────────────────
        self.ring.deinit();
    }

    /// Drain all remaining CQEs from the ring after fds are closed.
    /// Used during deinit to ensure the kernel is done with our buffers
    /// before we free them.
    fn drainRemainingCqes(self: *EventLoop) void {
        // Submit any queued SQEs so they complete (with errors, since fds are closed)
        _ = self.ring.submit() catch {};

        // Drain CQEs in batches until none remain.  Use a bounded loop
        // to avoid hanging if the ring keeps producing completions.
        var drain_rounds: u32 = 0;
        while (drain_rounds < 64) : (drain_rounds += 1) {
            var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
            const count = self.ring.copy_cqes(&cqes, 0) catch break;
            if (count == 0) break;
            // Discard all completions -- we only care that the kernel
            // has finished touching the buffer memory.
        }
    }

    // ── Torrent management ─────────────────────────────────

    /// Add a new torrent context to the event loop. Returns torrent_id.
    pub fn addTorrent(
        self: *EventLoop,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
    ) !u8 {
        return self.addTorrentWithKey(session, piece_tracker, shared_fds, peer_id, null, false);
    }

    /// Add a new torrent context with a tracker key. Returns torrent_id.
    pub fn addTorrentWithKey(
        self: *EventLoop,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
        tracker_key: ?[8]u8,
        is_private: bool,
    ) !u8 {
        // BEP 52: derive truncated v2 info-hash for handshake matching
        const v2_hash: ?[20]u8 = if (session.metainfo.info_hash_v2) |full_v2| blk: {
            var truncated: [20]u8 = undefined;
            @memcpy(&truncated, full_v2[0..20]);
            break :blk truncated;
        } else null;

        for (&self.torrents, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{
                    .session = session,
                    .piece_tracker = piece_tracker,
                    .shared_fds = shared_fds,
                    .info_hash = session.metainfo.info_hash,
                    .peer_id = peer_id,
                    .tracker_key = tracker_key,
                    .is_private = is_private,
                    .info_hash_v2 = v2_hash,
                };
                self.torrent_count += 1;
                return @intCast(i);
            }
        }
        return error.TooManyTorrents;
    }

    /// Check whether peer discovery (DHT, PEX, LSD) is allowed for a torrent.
    /// Private torrents MUST only use tracker-provided peers.
    pub fn isPeerDiscoveryAllowed(self: *EventLoop, torrent_id: u8) bool {
        if (self.getTorrentContext(torrent_id)) |tc| {
            return !tc.is_private;
        }
        return true;
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

    /// Initialize the BEP 52 Merkle tree cache for a v2/hybrid torrent.
    /// Must be called after the torrent is added and has a valid session.
    /// Safe to call for v1 torrents (no-op) or multiple times (idempotent).
    pub fn initMerkleCache(self: *EventLoop, torrent_id: u8) void {
        const tc = self.getTorrentContext(torrent_id) orelse return;
        if (tc.merkle_cache != null) return; // already initialized

        const session = tc.session orelse return;
        if (!session.metainfo.hasV2()) return;
        const v2_files = session.metainfo.file_tree_v2 orelse return;

        const mc = self.allocator.create(MerkleCache) catch return;
        mc.* = MerkleCache.init(
            self.allocator,
            &session.layout,
            v2_files,
            32, // cache up to 32 trees by default
        ) catch {
            self.allocator.destroy(mc);
            return;
        };
        tc.merkle_cache = mc;
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

    /// Return the current half-open (connecting) peer count.
    pub fn halfOpenCount(self: *const EventLoop) u16 {
        return @intCast(@min(self.half_open_count, std.math.maxInt(u16)));
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

    /// Remove a torrent context and disconnect all its peers.
    pub fn removeTorrent(self: *EventLoop, torrent_id: u8) void {
        // Disconnect all peers for this torrent
        for (self.peers, 0..) |*peer, i| {
            if (peer.state != .free and peer.torrent_id == torrent_id) {
                self.removePeer(@intCast(i));
            }
        }
        // Clean up PEX state
        if (self.torrents[torrent_id]) |*tc| {
            if (tc.pex_state) |tps| {
                tps.deinit(self.allocator);
                self.allocator.destroy(tps);
            }
            // Clean up BEP 16 super-seed state
            if (tc.super_seed) |ss| {
                ss.deinit();
                self.allocator.destroy(ss);
                tc.super_seed = null;
            }
            // Clean up BEP 52 Merkle tree cache
            if (tc.merkle_cache) |mc| {
                mc.deinit();
                self.allocator.destroy(mc);
                tc.merkle_cache = null;
            }
        }
        self.torrents[torrent_id] = null;
        if (self.torrent_count > 0) self.torrent_count -= 1;
    }

    // ── Peer management ────────────────────────────────────

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

    /// Initiate an outbound uTP connection to a peer. Creates the uTP
    /// socket via the UtpManager, sends the SYN packet, and allocates a
    /// peer slot in the event loop.
    pub fn addUtpPeer(self: *EventLoop, address: std.net.Address, torrent_id: u8) !u16 {
        // Ensure the UDP socket and manager are ready.
        if (self.udp_fd < 0 or self.utp_manager == null) {
            try self.startUtpListener();
        }

        const mgr = self.utp_manager orelse return error.NoUtpManager;

        if (self.peer_count >= self.max_connections) {
            return error.ConnectionLimitReached;
        }
        if (self.half_open_count >= self.max_half_open) {
            return error.HalfOpenLimitReached;
        }

        const now_us = utp_handler.utpNowUs();
        const conn = mgr.connect(address, now_us) catch |err| {
            log.warn("uTP connect failed: {s}", .{@errorName(err)});
            return error.UtpConnectFailed;
        };

        // Allocate a peer slot.
        const peer_slot = self.allocSlot() orelse {
            // Clean up the uTP connection.
            _ = mgr.reset(conn.slot, now_us);
            return error.TooManyPeers;
        };

        const peer = &self.peers[peer_slot];
        peer.* = Peer{
            .fd = -1,
            .state = .connecting,
            .mode = .download,
            .transport = .utp,
            .torrent_id = torrent_id,
            .utp_slot = conn.slot,
            .address = address,
        };
        self.peer_count += 1;
        self.half_open_count += 1;

        // Send the SYN packet via the UDP socket.
        utp_handler.utpSendPacket(self, &conn.syn_packet, address);

        log.info("initiating outbound uTP connection to {any}", .{address});
        return peer_slot;
    }

    /// Start accepting inbound connections for seeding.
    pub fn startAccepting(self: *EventLoop, listen_fd: posix.fd_t, complete_pieces: *const Bitfield) !void {
        self.listen_fd = listen_fd;
        self.complete_pieces = complete_pieces;
        try self.submitAccept();
    }

    /// Start listening for inbound uTP connections on a UDP socket.
    /// Creates the UDP socket, binds it to the daemon's listen port,
    /// initializes the UtpManager, and submits the first RECVMSG.
    pub fn startUtpListener(self: *EventLoop) !void {
        if (self.udp_fd >= 0) return; // already listening

        // Create UDP socket
        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
        errdefer posix.close(fd);

        // Allow address reuse
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Bind to the same port as TCP
        const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        try posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen());

        self.udp_fd = fd;

        // Initialize UtpManager
        const mgr = try self.allocator.create(utp_mgr.UtpManager);
        mgr.* = utp_mgr.UtpManager.init(self.allocator);
        self.utp_manager = mgr;

        // Submit first RECVMSG
        try utp_handler.submitUtpRecv(self);
        log.info("uTP listener started on UDP port {d}", .{self.port});
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
        // BEP 11: notify torrent PEX state that this peer disconnected
        if (peer.state != .free and peer.state != .connecting) {
            if (self.getTorrentContext(peer.torrent_id)) |tc| {
                if (tc.pex_state) |tps| {
                    tps.removePeer(peer.address);
                }
            }
        }
        // BEP 16: clean up super-seed tracking for this peer
        if (self.getTorrentContext(peer.torrent_id)) |tc| {
            if (tc.super_seed) |ss| ss.removePeer(slot);
        }
        self.unmarkIdle(slot);

        // Free any tracked send buffers before closing the fd.  After
        // close, stale CQEs will arrive for this slot -- the guard in
        // handleSend will ignore them because the slot is .free.
        self.freeAllPendingSends(slot);

        self.cleanupPeer(peer);
        peer.* = Peer{};
        if (self.peer_count > 0) self.peer_count -= 1;
    }

    // ── Run loop ───────────────────────────────────────────

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

    /// Configure re-announce parameters.
    pub fn setAnnounce(self: *EventLoop, url: []const u8, interval: u32) void {
        self.announce_url = url;
        self.announce_interval = interval;
        self.last_announce_time = std.time.timestamp();
    }

    pub fn tick(self: *EventLoop) !void {
        peer_policy.processHashResults(self);
        peer_policy.checkPeerTimeouts(self);
        peer_policy.checkReannounce(self);
        peer_policy.recalculateUnchokes(self);
        peer_policy.tryAssignPieces(self);
        peer_policy.updateSpeedCounters(self);
        peer_policy.checkPex(self);
        utp_handler.utpTick(self);
        dht_handler.dhtTick(self);

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
        seed_handler.flushQueuedResponses(self);

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

    /// Process completed hash results from the background hasher.
    /// Public wrapper for external callers (e.g. torrent_session).
    pub fn processHashResults(self: *EventLoop) void {
        peer_policy.processHashResults(self);
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

    /// Enable BEP 16 super-seeding for a torrent. The seeder will send
    /// individual HAVE messages instead of a full bitfield, tracking
    /// which pieces each peer has seen to maximize piece diversity.
    pub fn enableSuperSeed(self: *EventLoop, torrent_id: u8) !void {
        const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
        if (tc.super_seed != null) return; // already enabled
        const sess = tc.session orelse return error.NoSession;

        const ss = try self.allocator.create(SuperSeedState);
        ss.* = try SuperSeedState.init(self.allocator, try sess.metainfo.pieceCount());
        tc.super_seed = ss;
    }

    /// Disable BEP 16 super-seeding for a torrent.
    pub fn disableSuperSeed(self: *EventLoop, torrent_id: u8) void {
        const tc = self.getTorrentContext(torrent_id) orelse return;
        if (tc.super_seed) |ss| {
            ss.deinit();
            self.allocator.destroy(ss);
            tc.super_seed = null;
        }
    }

    /// Check if super-seeding is enabled for a torrent.
    pub fn isSuperSeedEnabled(self: *const EventLoop, torrent_id: u8) bool {
        if (torrent_id >= max_torrents) return false;
        const tc = self.torrents[torrent_id] orelse return false;
        return tc.super_seed != null;
    }

    /// Configure the huge page piece cache. Call after init, before tick.
    /// `capacity` is the desired cache size in bytes (0 = default 64 MB).
    /// `use_huge_pages` controls whether MAP_HUGETLB is attempted.
    pub fn initHugePageCache(self: *EventLoop, capacity: u64, use_huge_pages: bool) void {
        const default_cache_size: usize = 64 * 1024 * 1024; // 64 MB
        const size: usize = if (capacity > 0) @intCast(@min(capacity, 1 << 32)) else default_cache_size;
        self.huge_page_cache = HugePageCache.init(size, use_huge_pages);
        if (self.huge_page_cache.?.isAllocated()) {
            log.info("piece cache: {d} MB ({s})", .{
                self.huge_page_cache.?.capacity / (1024 * 1024),
                if (self.huge_page_cache.?.using_huge_pages) "huge pages" else "regular pages",
            });
        }
    }

    /// Check if a download of `amount` bytes is allowed by both per-torrent
    /// and global rate limiters. Returns the number of bytes allowed (may be
    /// less than requested). Returns 0 if throttled.
    pub fn consumeDownloadTokens(self: *EventLoop, torrent_id: u8, amount: u64) u64 {
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
    pub fn consumeUploadTokens(self: *EventLoop, torrent_id: u8, amount: u64) u64 {
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
    pub fn isDownloadThrottled(self: *EventLoop, torrent_id: u8) bool {
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
    pub fn isUploadThrottled(self: *EventLoop, torrent_id: u8) bool {
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
            .peer_connect => peer_handler.handleConnect(self, op.slot, cqe),
            .peer_recv => peer_handler.handleRecv(self, op.slot, cqe),
            .peer_send => peer_handler.handleSend(self, op.slot, cqe),
            .disk_write => peer_handler.handleDiskWrite(self, op.slot, cqe),
            .accept => peer_handler.handleAccept(self, cqe),
            .disk_read => seed_handler.handleSeedDiskRead(self, cqe),
            .timeout => {
                self.timeout_pending = false;
            },
            .utp_recv => utp_handler.handleUtpRecv(self, cqe),
            .utp_send => utp_handler.handleUtpSend(self, cqe),
            .http_connect, .http_send, .http_recv, .cancel => {},
        }
    }

    // ── Idle-peer tracking (for efficient tryAssignPieces) ─

    /// Returns true when a slot is eligible for piece assignment.
    pub fn isIdleCandidate(peer: *const Peer) bool {
        return (peer.state == .active_recv_header or peer.state == .active_recv_body) and
            peer.current_piece == null and
            !peer.peer_choking and
            peer.availability_known;
    }

    /// Add a slot to the idle_peers list if it is eligible and not already present.
    pub fn markIdle(self: *EventLoop, slot: u16) void {
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
    pub fn unmarkIdle(self: *EventLoop, slot: u16) void {
        for (self.idle_peers.items, 0..) |s, idx| {
            if (s == slot) {
                _ = self.idle_peers.swapRemove(idx);
                return;
            }
        }
    }

    // ── Internal helpers ─────────────────────────────────

    pub fn submitAccept(self: *EventLoop) !void {
        if (self.listen_fd < 0) return;
        const ud = encodeUserData(.{ .slot = 0, .op_type = .accept, .context = 0 });
        _ = try self.ring.accept(ud, self.listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
    }

    /// Allocate a unique send_id for a new PendingSend and return the
    /// encoded user data with the send_id in the context field.
    /// Allocate a unique send_id for a new PendingSend and return the
    /// encoded user data with the send_id in the context field.
    /// send_id is never 0, since context=0 means "untracked send".
    pub fn nextTrackedSendUserData(self: *EventLoop, slot: u16) struct { ud: u64, send_id: u32 } {
        const id = self.next_send_id;
        self.next_send_id +%= 1;
        if (self.next_send_id == 0) self.next_send_id = 1;
        return .{
            .ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = @as(u40, id) }),
            .send_id = id,
        };
    }

    /// Handle partial send: re-submit remaining bytes. Returns true if partial (more to send).
    /// Matches by send_id (extracted from the CQE context field) so that multiple
    /// in-flight sends for the same slot are correctly distinguished.
    pub fn handlePartialSend(self: *EventLoop, slot: u16, send_id: u32, bytes_sent: usize) bool {
        for (self.pending_sends.items) |*ps| {
            if (ps.slot == slot and ps.send_id == send_id) {
                ps.sent += bytes_sent;
                if (ps.sent < ps.buf.len) {
                    // Partial send -- re-submit remainder with same send_id
                    const remaining = ps.buf[ps.sent..];
                    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = @as(u40, send_id) });
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

    /// Free ONE pending send buffer matching the send_id.
    /// Called when a single send CQE completes -- each CQE corresponds to
    /// exactly one buffer.  Freeing all buffers for a slot here would be a
    /// use-after-free when multiple tracked sends are in flight for the
    /// same peer (e.g. extension handshake + piece response).
    pub fn freeOnePendingSend(self: *EventLoop, slot: u16, send_id: u32) void {
        for (self.pending_sends.items, 0..) |ps, i| {
            if (ps.slot == slot and ps.send_id == send_id) {
                self.allocator.free(ps.buf);
                _ = self.pending_sends.swapRemove(i);
                return;
            }
        }
    }

    /// Free ALL pending send buffers for the given slot.
    /// Called during peer removal to clean up any buffers that won't be
    /// reclaimed by future CQE processing (the fd is closed so remaining
    /// CQEs will arrive as errors for a potentially-reused slot).
    fn freeAllPendingSends(self: *EventLoop, slot: u16) void {
        var i: usize = 0;
        while (i < self.pending_sends.items.len) {
            if (self.pending_sends.items[i].slot == slot) {
                self.allocator.free(self.pending_sends.items[i].buf);
                _ = self.pending_sends.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    pub fn getTorrentContext(self: *EventLoop, torrent_id: u8) ?*TorrentContext {
        if (torrent_id >= max_torrents) return null;
        return if (self.torrents[torrent_id]) |*tc| tc else null;
    }

    pub fn allocSlot(self: *EventLoop) ?u16 {
        for (self.peers, 0..) |*peer, i| {
            if (peer.state == .free) return @intCast(i);
        }
        return null;
    }

    fn cleanupPeer(self: *EventLoop, peer: *Peer) void {
        // Clean up uTP slot if this is a uTP peer
        if (peer.transport == .utp) {
            if (peer.utp_slot) |utp_slot| {
                if (self.utp_manager) |mgr| {
                    const now_us = utp_handler.utpNowUs();
                    _ = mgr.reset(utp_slot, now_us);
                }
            }
        }
        if (peer.fd >= 0) {
            // Clean TCP shutdown before close -- signal peer we are done,
            // allowing them to drain any buffered data (IORING_OP_SHUTDOWN).
            if (peer.transport == .tcp) {
                self.shutdownPeerFd(peer.fd);
            }
            posix.close(peer.fd);
        }
        if (peer.body_is_heap) {
            if (peer.body_buf) |buf| self.allocator.free(buf);
        }
        if (peer.piece_buf) |buf| self.allocator.free(buf);
        if (peer.availability) |*bf| bf.deinit(self.allocator);
        if (peer.pex_state) |ps| {
            ps.deinit(self.allocator);
            self.allocator.destroy(ps);
        }
        // Free async MSE handshake state
        if (peer.mse_initiator) |mi| self.allocator.destroy(mi);
        if (peer.mse_responder) |mr| self.allocator.destroy(mr);
    }

    /// Issue shutdown(SHUT_RDWR) on a TCP peer fd for clean disconnect.
    /// Uses conventional syscall since this is a cleanup path (not hot path).
    /// Best-effort: errors do not prevent close().
    fn shutdownPeerFd(_: *EventLoop, fd: posix.fd_t) void {
        _ = linux.shutdown(fd, linux.SHUT.RDWR);
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

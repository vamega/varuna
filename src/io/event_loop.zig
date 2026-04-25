const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const Bitfield = @import("../bitfield.zig").Bitfield;
const config_mod = @import("../config.zig");
const TransportDisposition = config_mod.TransportDisposition;
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
const ring_mod = @import("ring.zig");
const real_io_mod = @import("real_io.zig");
pub const RealIO = real_io_mod.RealIO;
pub const io_interface = @import("io_interface.zig");
const SuperSeedState = @import("super_seed.zig").SuperSeedState;
const HugePageCache = @import("../storage/huge_page_cache.zig").HugePageCache;
const MerkleCache = @import("../torrent/merkle_cache.zig").MerkleCache;
const BanList = @import("../net/ban_list.zig").BanList;
const SmartBan = @import("../net/smart_ban.zig").SmartBan;
const dp_mod = @import("downloading_piece.zig");
pub const DownloadingPiece = dp_mod.DownloadingPiece;
pub const DownloadingPieceKey = dp_mod.DownloadingPieceKey;
pub const DownloadingPieceMap = dp_mod.DownloadingPieceMap;

// Sub-modules: focused implementations that operate on *EventLoop
const peer_handler = @import("peer_handler.zig");
const protocol = @import("protocol.zig");
const seed_handler = @import("seed_handler.zig");
const peer_policy = @import("peer_policy.zig");
const utp_handler = @import("utp_handler.zig");
const dht_handler = @import("dht_handler.zig");
const metadata_handler = @import("metadata_handler.zig");
const web_seed_handler = @import("web_seed_handler.zig");

// ── Re-exported type definitions (moved to types.zig) ────

pub const types = @import("types.zig");
pub const max_peers = types.max_peers;
pub const TorrentId = types.TorrentId;
pub const OpType = types.OpType;
pub const OpData = types.OpData;
pub const encodeUserData = types.encodeUserData;
pub const decodeUserData = types.decodeUserData;
pub const PeerMode = types.PeerMode;
pub const Transport = types.Transport;
pub const PeerState = types.PeerState;
pub const Peer = types.Peer;
pub const SpeedStats = types.SpeedStats;
pub const TorrentContext = types.TorrentContext;

const clock_mod = @import("clock.zig");
pub const Clock = clock_mod.Clock;

const cqe_batch_size = 64;

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    pub const small_send_capacity: usize = 256;
    const small_send_slots: usize = max_peers * 2;
    const default_torrent_capacity: usize = 64;

    pub const PendingWriteKey = struct {
        piece_index: u32,
        torrent_id: TorrentId,
    };

    pub const PendingWrite = struct {
        write_id: u32,
        piece_index: u32,
        torrent_id: TorrentId,
        slot: u16,
        buf: []u8,
        spans_remaining: u32,
        write_failed: bool = false,
    };

    // ── Re-exported buffer pool types (moved to buffer_pools.zig) ──
    const bp = @import("buffer_pools.zig");
    pub const PieceBuffer = bp.PieceBuffer;
    const PieceBufferPool = bp.PieceBufferPool;
    pub const VectoredSendState = bp.VectoredSendState;
    const vectored_send_backing_align = bp.vectored_send_backing_align;
    const VectoredSendLayout = bp.VectoredSendLayout;
    const VectoredSendPool = bp.VectoredSendPool;
    pub const PendingSend = bp.PendingSend;
    const SmallSendPool = bp.SmallSendPool;

    /// A uTP packet waiting to be sent over the UDP socket.
    /// Sized for a full UDP datagram (header + payload).
    pub const UtpQueuedPacket = struct {
        data: [1500]u8 = undefined,
        len: usize = 0,
        remote: std.net.Address,
    };

    /// A one-shot timer callback scheduled via scheduleTimer().
    /// Fired when the monotonic clock passes fire_at_ms.
    pub const TimerCallback = struct {
        fire_at_ms: i64, // monotonic clock target in milliseconds
        context: *anyopaque,
        callback: *const fn (*anyopaque) void,
    };

    /// Queued piece block response for batched sending.
    /// Multiple blocks queued in the same tick are combined into one send.
    pub const QueuedBlockResponse = struct {
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
        piece_buffer: *PieceBuffer,
    };

    const DeferredPieceBuffer = struct {
        piece_buffer: *PieceBuffer,
    };

    /// Tracks an async piece read for seed mode.
    /// For multi-span pieces, multiple io_uring reads are submitted.
    /// When all reads complete, the piece response is sent.
    pub const PendingPieceRead = struct {
        pub const max_spans: usize = 8;

        read_id: u32,
        slot: u16,
        piece_index: u32,
        block_offset: u32,
        block_length: u32,
        piece_buffer: *PieceBuffer,
        reads_remaining: u32, // number of successfully submitted read CQEs still pending
        submitted_span_count: u8 = 0,
        expected_read_lengths: [max_spans]u32 = [_]u32{0} ** max_spans,
    };

    pub const AnnounceResult = struct {
        torrent_id: TorrentId,
        peers: []std.net.Address,
    };

    ring: linux.IoUring,
    /// New `io_interface`-based backend used by migrated call sites. During
    /// Stage 2 the legacy `ring` and the new `io` coexist on separate ring
    /// instances. `ring` carries the packed-userdata legacy ops; `io` carries
    /// `*Completion`-keyed ops via `RealIO`. Both share the same fds. Once
    /// every call site is migrated (Stage 2 #12), `ring` is removed.
    io: RealIO,
    allocator: std.mem.Allocator,
    peers: []Peer,
    peer_count: u16 = 0,
    running: bool = true,
    clock: Clock = .real,

    /// Graceful shutdown: when true, the event loop stops accepting new work
    /// and waits for in-flight transfers to complete before setting running=false.
    draining: bool = false,
    /// Monotonic timestamp (seconds) when the drain timeout expires and
    /// shutdown is forced regardless of pending work.
    drain_deadline: i64 = 0,
    /// Configurable drain timeout in seconds (0 = immediate shutdown).
    shutdown_timeout: u32 = 10,

    // Multi-torrent contexts
    torrents: std.ArrayList(?TorrentContext),
    free_torrent_ids: std.ArrayList(TorrentId),
    active_torrent_ids: std.ArrayList(TorrentId),
    torrents_with_peers: std.ArrayList(TorrentId),
    info_hash_to_torrent: std.AutoHashMap([20]u8, TorrentId),
    mse_req2_to_hash: std.AutoHashMap([20]u8, [20]u8),
    torrent_count: TorrentId = 0,

    // Listening port for tracker announces
    port: u16 = 6881,

    // Bind configuration for outbound sockets
    bind_device: ?[]const u8 = null,
    bind_address: ?[]const u8 = null,

    // MSE/PE (BEP 6) encryption mode
    encryption_mode: mse.EncryptionMode = .preferred,

    // Runtime feature toggles (can be changed via API)
    pex_enabled: bool = true,
    /// Fine-grained transport control: which TCP/uTP directions are allowed.
    transport_disposition: TransportDisposition = TransportDisposition.tcp_and_utp,
    /// Monotonic counter for alternating between TCP and uTP connections.
    /// When both outgoing TCP and uTP are enabled, even values use TCP and odd values use uTP.
    utp_transport_counter: u32 = 0,

    // signalfd for SIGINT/SIGTERM — produces a CQE via `io.poll` when
    // a shutdown signal arrives. The callback (`signalPollComplete`)
    // sets `running = false` and re-arms after the first signal so a
    // second signal forces immediate shutdown.
    signal_fd: posix.fd_t = -1,
    signal_completion: io_interface.Completion = .{},

    // Accept socket for seeding (-1 if not seeding)
    listen_fd: posix.fd_t = -1,
    // Caller-owned completion for the multishot accept on `listen_fd`.
    // Re-armed by `peerAcceptComplete` when the kernel clears F_MORE.
    accept_completion: io_interface.Completion = .{},
    /// Tracking completion for cancelling the multishot accept during
    /// `stopTcpListener`. Lives on the EventLoop because the cancel
    /// CQE must arrive before the accept's `accept_completion` is
    /// reused.
    accept_cancel_completion: io_interface.Completion = .{},

    // uTP over UDP: single UDP socket + connection multiplexer
    udp_fd: posix.fd_t = -1,
    utp_manager: ?*utp_mgr.UtpManager = null,
    // Persistent recv buffer and msghdr for io_uring RECVMSG
    utp_recv_buf: [1500]u8 = undefined,
    utp_recv_iov: [1]posix.iovec = undefined,
    // sockaddr.storage is large enough for IPv4, IPv6, and any other family.
    utp_recv_addr: std.net.Address = undefined,
    utp_recv_msg: posix.msghdr = undefined,
    // Persistent send buffer and msghdr for io_uring SENDMSG
    utp_send_buf: [1500]u8 = undefined,
    utp_send_iov: [1]posix.iovec_const = undefined,
    // sockaddr.storage is large enough for IPv4, IPv6, and any other family.
    utp_send_addr: std.net.Address = undefined,
    utp_send_msg: posix.msghdr_const = undefined,
    utp_send_pending: bool = false,
    // Outbound packet queue (when a send is already in flight)
    utp_send_queue: std.ArrayList(UtpQueuedPacket) = std.ArrayList(UtpQueuedPacket).empty,

    // DHT (BEP 5): distributed hash table engine for trackerless peer discovery.
    // Shares the UDP socket with uTP. Incoming datagrams starting with 'd'
    // (bencode dict) are routed to DHT; others go to uTP.
    dht_engine: ?*@import("../dht/dht.zig").DhtEngine = null,

    // API server (shares the event loop's ring)
    api_server: ?*@import("../rpc/server.zig").ApiServer = null,

    // Generic HTTP executor (shares the event loop's ring).
    // CQEs for http_socket/http_connect/http_send/http_recv route here.
    http_executor: ?*@import("http_executor.zig").HttpExecutor = null,

    // Tracker executor (thin wrapper around http_executor, shares the event loop's ring)
    tracker_executor: ?*@import("../daemon/tracker_executor.zig").TrackerExecutor = null,

    // UDP tracker executor (shares the event loop's ring, BEP 15)
    udp_tracker_executor: ?*@import("../daemon/udp_tracker_executor.zig").UdpTrackerExecutor = null,

    // Complete pieces bitfield (for seeding -- which pieces we can serve)
    complete_pieces: ?*const Bitfield = null,

    // Timeout storage (must outlive the SQE)
    timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },
    timeout_pending: bool = false,

    // One-shot timer callbacks driven by `io.timeout` on the new
    // io_interface ring. The completion is owned by the EventLoop and
    // re-armed for each next-earliest deadline.
    tick_timeout_completion: io_interface.Completion = .{},
    timer_pending: bool = false,
    timer_callbacks: std.ArrayList(TimerCallback) = std.ArrayList(TimerCallback).empty,

    // Pending disk writes: track buffers that io_uring is writing to disk.
    pending_writes: std.AutoHashMapUnmanaged(u32, PendingWrite),
    pending_write_lookup: std.AutoHashMapUnmanaged(PendingWriteKey, u32),
    next_pending_write_id: u32 = 1,

    // Pending sends: track allocated send buffers (for seed piece responses).
    pending_sends: std.ArrayList(PendingSend),
    small_send_pool: SmallSendPool,
    // Monotonic counter for unique PendingSend identification across CQEs.
    // Starts at 1 because context=0 means "untracked send" (no PendingSend entry).
    next_send_id: u32 = 1,

    // Pending piece reads: async disk reads for seed piece serving.
    pending_reads: std.ArrayList(PendingPieceRead),
    next_seed_read_id: u32 = 1,

    // Piece read cache for seed mode (avoid re-reading from disk per block)
    cached_piece_index: ?u32 = null,
    cached_piece_buffer: ?*PieceBuffer = null,

    // Huge page piece cache buffer pool (optional, configured at init time).
    // When allocated, piece read buffers are served from this pool instead
    // of the general-purpose allocator. Reduces TLB pressure for large torrents.
    huge_page_cache: ?HugePageCache = null,
    piece_buffer_pool: PieceBufferPool = .{},
    vectored_send_pool: VectoredSendPool = .{},

    // Queued piece block responses (batched per tick, flushed after CQE dispatch)
    queued_responses: std.ArrayList(QueuedBlockResponse),
    deferred_piece_buffers: std.ArrayList(DeferredPieceBuffer),

    // Connection limits
    max_connections: u32 = 500,
    max_peers_per_torrent: u32 = 100,
    max_half_open: u32 = 50,
    half_open_count: u32 = 0,

    // Re-announce result handoff: daemon tracker sessions enqueue
    // per-torrent peer results here; the event loop drains them on tick.
    announce_interval: u32 = 1800,
    announce_results: std.ArrayList(AnnounceResult),
    announce_mutex: std.Thread.Mutex = .{},

    // Global rate limiter (applies across all torrents, 0 = unlimited)
    global_rate_limiter: RateLimiter = RateLimiter.initComptime(0, 0),

    // Peer banning: shared ban list (owned by SessionManager, shared with API handlers)
    ban_list: ?*BanList = null,
    // Atomic flag set by API handlers when bans change; checked in tick()
    ban_list_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Smart Ban: per-block SHA-1 attribution for detecting peers that send
    // corrupt data without false-positive-banning other peers on the same piece.
    // Populated at piece completion, consumed at hash result processing.
    smart_ban: ?*SmartBan = null,

    // Background hasher for SHA verification (off event loop thread)
    last_unchoke_recalc: i64 = 0,
    last_optimistic_unchoke: i64 = 0,
    hasher: ?*Hasher = null,
    hash_result_swap: std.ArrayList(Hasher.Result) = std.ArrayList(Hasher.Result).empty,
    merkle_result_swap: std.ArrayList(Hasher.MerkleResult) = std.ArrayList(Hasher.MerkleResult).empty,

    // Async piece recheck state machines (multiple rechecks can run in parallel)
    rechecks: std.ArrayList(*@import("recheck.zig").AsyncRecheck) = std.ArrayList(*@import("recheck.zig").AsyncRecheck).empty,

    // Async BEP 9 metadata fetch state machine (null when no fetch is active)
    metadata_fetch: ?*metadata_handler.AsyncMetadataFetch = null,

    // BEP 19: web seed download slots
    web_seed_slots: [web_seed_handler.max_web_seed_slots]web_seed_handler.WebSeedSlot =
        [_]web_seed_handler.WebSeedSlot{.{}} ** web_seed_handler.max_web_seed_slots,
    /// Maximum bytes per web seed HTTP Range request (batches multiple pieces).
    web_seed_max_request_bytes: u32 = 4 * 1024 * 1024,

    // Compact list of peer slots that are idle (active, unchoked, have
    // availability, and need a piece assignment).  Avoids scanning all
    // max_peers slots every tick in tryAssignPieces.
    idle_peers: std.ArrayList(u16),
    active_peer_slots: std.ArrayList(u16),

    // Multi-source piece assembly: shared per-piece download state.
    // Key = (torrent_id, piece_index), Value = heap-allocated DownloadingPiece.
    downloading_pieces: DownloadingPieceMap = .empty,

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
            .ring = try ring_mod.initIoUring(256, linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER),
            // Second ring instance for the new io_interface backend. Same
            // size as the legacy ring; same flags (with kernel fallback in
            // RealIO.init). Each call site flips atomically between `ring`
            // and `io` during the Stage 2 migration.
            .io = try RealIO.init(.{
                .entries = 256,
                .flags = linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER,
            }),
            .allocator = allocator,
            .peers = peers,
            .torrents = try std.ArrayList(?TorrentContext).initCapacity(allocator, default_torrent_capacity),
            .free_torrent_ids = std.ArrayList(TorrentId).empty,
            .active_torrent_ids = try std.ArrayList(TorrentId).initCapacity(allocator, default_torrent_capacity),
            .torrents_with_peers = std.ArrayList(TorrentId).empty,
            .info_hash_to_torrent = std.AutoHashMap([20]u8, TorrentId).init(allocator),
            .mse_req2_to_hash = std.AutoHashMap([20]u8, [20]u8).init(allocator),
            .pending_writes = .empty,
            .pending_write_lookup = .empty,
            .pending_sends = std.ArrayList(PendingSend).empty,
            .small_send_pool = try SmallSendPool.init(allocator, small_send_slots, small_send_capacity),
            .pending_reads = std.ArrayList(PendingPieceRead).empty,
            .queued_responses = try std.ArrayList(QueuedBlockResponse).initCapacity(allocator, 256),
            .deferred_piece_buffers = std.ArrayList(DeferredPieceBuffer).empty,
            .announce_results = std.ArrayList(AnnounceResult).empty,
            .idle_peers = std.ArrayList(u16).empty,
            .active_peer_slots = std.ArrayList(u16).empty,
            .hasher = hasher,
        };
    }

    /// Create a signalfd for SIGINT/SIGTERM and arm a one-shot
    /// `io.poll(POLL_IN)` against it. When a signal arrives, the
    /// completion fires and `signalPollComplete` decides between graceful
    /// drain and immediate shutdown.
    pub fn installSignalFd(self: *EventLoop) !void {
        const signal = @import("signal.zig");
        const fd = try signal.createSignalFd();
        self.signal_fd = fd;
        try self.io.poll(
            .{ .fd = fd, .events = linux.POLL.IN },
            &self.signal_completion,
            self,
            signalPollComplete,
        );
    }

    /// Callback for `signal_completion`. Fires when the kernel posts a
    /// readable signalfd. First fire enters graceful drain (or immediate
    /// shutdown if `shutdown_timeout == 0`); a second fire while draining
    /// forces immediate exit. Re-arms after the first fire so the second
    /// signal is caught.
    fn signalPollComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        _: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *EventLoop = @ptrCast(@alignCast(userdata.?));
        const signal = @import("signal.zig");
        if (self.draining) {
            log.info("second shutdown signal received, forcing immediate exit", .{});
            self.running = false;
            signal.requestShutdown();
            return .disarm;
        }
        if (self.shutdown_timeout == 0) {
            log.info("shutdown signal received via signalfd", .{});
            self.running = false;
            signal.requestShutdown();
            return .disarm;
        }
        log.info("shutting down gracefully, draining in-flight transfers (timeout={d}s)...", .{self.shutdown_timeout});
        self.draining = true;
        self.drain_deadline = self.clock.now() + @as(i64, @intCast(self.shutdown_timeout));
        // Re-arm so a second signal during drain forces immediate exit.
        return .rearm;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
        hasher_threads: u32,
    ) !EventLoop {
        var el = try initBare(allocator, hasher_threads);

        const tid = try el.addTorrent(session, piece_tracker, shared_fds, peer_id);
        std.debug.assert(tid == 0);

        return el;
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.hasher) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }

        // ── Phase 0: Flush pending disk writes ────────────────────
        // Before closing fds, drain any in-flight piece writes so that
        // hash-verified data is not lost on shutdown.
        {
            _ = self.ring.submit() catch {};
            self.io.tick(0) catch {};
            var flush_rounds: u32 = 0;
            while (self.pending_writes.count() > 0 and flush_rounds < 100) : (flush_rounds += 1) {
                _ = self.ring.submit_and_wait(1) catch break;
                var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
                const count = self.ring.copy_cqes(&cqes, 0) catch break;
                for (cqes[0..count]) |cqe| {
                    self.dispatch(cqe);
                }
                // Also drain io_interface completions that may have been
                // produced during this round (e.g. async fsync after a
                // piece write completes on the legacy ring).
                self.io.tick(0) catch {};
            }
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
        // Note: listen_fd is NOT closed here -- it is owned by the caller
        // (e.g. std.net.Server in client.zig) and will be closed by the caller's defer.
        if (self.udp_fd >= 0) {
            posix.close(self.udp_fd);
            self.udp_fd = -1;
        }
        if (self.signal_fd >= 0) {
            posix.close(self.signal_fd);
            self.signal_fd = -1;
        }

        // ── Phase 2: Drain the ring ──────────────────────────────
        // After closing fds, any in-flight SQEs will complete with
        // errors. Drain all remaining CQEs so the kernel is finished
        // touching our buffer memory before we free it.
        //
        // Null out external references first — stale CQEs from closed
        // fds may route to handlers for already-freed objects (e.g. DHT
        // engine freed by main() before this deinit runs).
        self.dht_engine = null;
        self.http_executor = null;
        self.tracker_executor = null;
        self.udp_tracker_executor = null;
        self.drainRemainingCqes();

        // Clean up active async state machines (metadata fetch, recheck)
        self.cancelMetadataFetch();
        self.cancelAllRechecks();

        // Free web seed slot buffers (in-flight downloads that didn't complete)
        for (&self.web_seed_slots) |*ws| {
            if (ws.buf) |buf| self.allocator.free(buf);
            ws.* = .{};
        }

        // ── Phase 3: Free all buffers ────────────────────────────
        // Now that the kernel has completed all pending operations,
        // it is safe to free the buffers they referenced.
        // Free piece cache (only if not from huge page pool)
        if (self.cached_piece_buffer) |piece_buffer| {
            self.releasePieceBuffer(piece_buffer);
        }
        // Free huge page cache pool
        {
            var it = self.pending_writes.valueIterator();
            while (it.next()) |pending| {
                self.allocator.free(pending.buf);
            }
        }
        self.pending_writes.deinit(self.allocator);
        self.pending_write_lookup.deinit(self.allocator);
        for (self.pending_sends.items) |ps| {
            self.releasePendingSend(ps);
        }
        self.pending_sends.deinit(self.allocator);
        self.vectored_send_pool.deinit(self.allocator);
        self.small_send_pool.deinit(self.allocator);
        for (self.pending_reads.items) |pr| {
            self.releasePieceBuffer(pr.piece_buffer);
        }
        self.pending_reads.deinit(self.allocator);
        for (self.deferred_piece_buffers.items) |piece_buf| {
            self.releasePieceBuffer(piece_buf.piece_buffer);
        }
        self.deferred_piece_buffers.deinit(self.allocator);
        self.piece_buffer_pool.deinit(self.allocator);
        if (self.huge_page_cache) |*hpc| hpc.deinit();
        self.queued_responses.deinit(self.allocator);
        self.idle_peers.deinit(self.allocator);
        self.active_peer_slots.deinit(self.allocator);
        // Free any abandoned DownloadingPieces (partial downloads that never completed)
        {
            var dp_it = self.downloading_pieces.valueIterator();
            while (dp_it.next()) |dp_ptr| {
                dp_mod.destroyDownloadingPieceFull(self.allocator, dp_ptr.*);
            }
            self.downloading_pieces.deinit(self.allocator);
        }
        self.torrents_with_peers.deinit(self.allocator);
        self.hash_result_swap.deinit(self.allocator);
        // Free any unclaimed Merkle results (piece_hashes ownership)
        for (self.merkle_result_swap.items) |mr| {
            if (mr.piece_hashes) |h| self.allocator.free(h);
        }
        self.merkle_result_swap.deinit(self.allocator);
        for (self.peers) |*peer| {
            // fd already closed in Phase 1; free remaining heap buffers
            if (peer.body_is_heap) {
                if (peer.body_buf) |buf| self.allocator.free(buf);
            }
            // piece_buf/next_piece_buf: only free if NOT owned by a DownloadingPiece
            // (DownloadingPiece buffers are freed in the downloading_pieces cleanup above)
            if (peer.downloading_piece == null) {
                if (peer.piece_buf) |buf| self.allocator.free(buf);
            }
            if (peer.next_downloading_piece == null) {
                if (peer.next_piece_buf) |buf| self.allocator.free(buf);
            }
            if (peer.availability) |*bf| bf.deinit(self.allocator);
            if (peer.pex_state) |ps| {
                ps.deinit(self.allocator);
                self.allocator.destroy(ps);
            }
            if (peer.mse_known_hashes) |hashes| self.allocator.free(hashes);
            // Free async MSE handshake state
            if (peer.mse_initiator) |mi| self.allocator.destroy(mi);
            if (peer.mse_responder) |mr| self.allocator.destroy(mr);
        }
        self.allocator.free(self.peers);
        // Clean up torrent PEX state and web seed managers
        for (self.active_torrent_ids.items) |torrent_id| {
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (tc.pex_state) |tps| {
                    tps.deinit(self.allocator);
                    self.allocator.destroy(tps);
                }
                if (tc.web_seed_manager) |wsm| {
                    wsm.deinit();
                    self.allocator.destroy(wsm);
                }
                tc.peer_slots.deinit(self.allocator);
            }
        }
        self.torrents.deinit(self.allocator);
        self.free_torrent_ids.deinit(self.allocator);
        self.active_torrent_ids.deinit(self.allocator);
        self.info_hash_to_torrent.deinit();
        self.mse_req2_to_hash.deinit();
        for (self.announce_results.items) |result| self.allocator.free(result.peers);
        self.announce_results.deinit(self.allocator);
        // Clean up uTP resources
        if (self.utp_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
        self.utp_send_queue.deinit(self.allocator);
        self.timer_callbacks.deinit(self.allocator);

        // ── Phase 4: Tear down the ring ──────────────────────────
        self.ring.deinit();
        self.io.deinit();
    }

    /// Drain all remaining CQEs from the ring after fds are closed.
    /// Used during deinit to ensure the kernel is done with our buffers
    /// before we free them.
    fn drainRemainingCqes(self: *EventLoop) void {
        // Submit any queued SQEs so they complete (with errors, since fds are closed)
        _ = self.ring.submit() catch {};
        self.io.tick(0) catch {};

        // Keep dispatching until tracked buffer-owning operations are gone.
        // This ensures late CQEs release the resources they reference before
        // we free backing memory during deinit.
        var drain_rounds: u32 = 0;
        while (drain_rounds < 256 and self.pendingBufferOperations() > 0) : (drain_rounds += 1) {
            _ = self.ring.submit_and_wait(1) catch break;
            var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
            const count = self.ring.copy_cqes(&cqes, 0) catch break;
            if (count == 0) {
                // No legacy CQEs this round; still try to drain new-ring
                // completions before continuing.
                self.io.tick(0) catch {};
                continue;
            }
            for (cqes[0..count]) |cqe| {
                self.dispatch(cqe);
            }
            self.io.tick(0) catch {};
        }

        // Best-effort final sweep for non-owning completions that may still be queued.
        drain_rounds = 0;
        while (drain_rounds < 32) : (drain_rounds += 1) {
            var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
            const count = self.ring.copy_cqes(&cqes, 0) catch break;
            if (count == 0) break;
            for (cqes[0..count]) |cqe| {
                self.dispatch(cqe);
            }
        }
        self.io.tick(0) catch {};

        if (self.pendingBufferOperations() > 0) {
            log.warn(
                "event loop shutdown left tracked resources pending (writes={d}, sends={d}, reads={d}, timeout_pending={})",
                .{
                    self.pending_writes.count(),
                    self.pending_sends.items.len,
                    self.pending_reads.items.len,
                    self.timeout_pending,
                },
            );
        }
    }

    fn pendingBufferOperations(self: *const EventLoop) usize {
        var count = self.pending_writes.count() + self.pending_sends.items.len + self.pending_reads.items.len;
        if (self.timeout_pending) count += 1;
        return count;
    }

    // ── Torrent management ─────────────────────────────────

    /// Add a new torrent context to the event loop. Returns torrent_id.
    pub fn addTorrent(
        self: *EventLoop,
        session: *const session_mod.Session,
        piece_tracker: *PieceTracker,
        shared_fds: []const posix.fd_t,
        peer_id: [20]u8,
    ) !TorrentId {
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
    ) !TorrentId {
        // BEP 52: derive truncated v2 info-hash for handshake matching
        const v2_hash: ?[20]u8 = if (session.metainfo.info_hash_v2) |full_v2| blk: {
            var truncated: [20]u8 = undefined;
            @memcpy(&truncated, full_v2[0..20]);
            break :blk truncated;
        } else null;

        return self.addTorrentContext(.{
            .session = session,
            .piece_tracker = piece_tracker,
            .shared_fds = shared_fds,
            .info_hash = session.metainfo.info_hash,
            .peer_id = peer_id,
            .tracker_key = tracker_key,
            .is_private = is_private,
            .info_hash_v2 = v2_hash,
        });
    }

    pub fn addTorrentContext(self: *EventLoop, tc: TorrentContext) !TorrentId {
        const torrent_id = if (self.free_torrent_ids.pop()) |free_id|
            free_id
        else blk: {
            const new_id: TorrentId = @intCast(self.torrents.items.len);
            try self.torrents.append(self.allocator, null);
            break :blk new_id;
        };

        self.torrents.items[torrent_id] = tc;
        errdefer self.torrents.items[torrent_id] = null;

        try self.registerTorrentHashes(torrent_id, tc.info_hash, tc.info_hash_v2);
        errdefer self.unregisterTorrentHashes(tc.info_hash, tc.info_hash_v2);

        try self.active_torrent_ids.append(self.allocator, torrent_id);
        self.torrent_count += 1;
        return torrent_id;
    }

    /// Check whether peer discovery (DHT, PEX, LSD) is allowed for a torrent.
    /// Private torrents MUST only use tracker-provided peers.
    pub fn isPeerDiscoveryAllowed(self: *EventLoop, torrent_id: TorrentId) bool {
        if (self.getTorrentContext(torrent_id)) |tc| {
            return !tc.is_private;
        }
        return true;
    }

    /// Set the complete_pieces bitfield for a torrent (enables seed mode).
    pub fn setTorrentCompletePieces(self: *EventLoop, torrent_id: TorrentId, cp: *const Bitfield) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            tc.complete_pieces = cp;
        }
        // Also set global complete_pieces for backwards compatibility with standalone mode
        self.complete_pieces = cp;
    }

    /// Initialize the BEP 52 Merkle tree cache for a v2/hybrid torrent.
    /// Must be called after the torrent is added and has a valid session.
    /// Safe to call for v1 torrents (no-op) or multiple times (idempotent).
    pub fn initMerkleCache(self: *EventLoop, torrent_id: TorrentId) void {
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
    pub fn peerCountForTorrent(self: *const EventLoop, torrent_id: TorrentId) u16 {
        const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
        return @intCast(@min(tc.peer_slots.items.len, std.math.maxInt(u16)));
    }

    /// Return the current half-open (connecting) peer count.
    pub fn halfOpenCount(self: *const EventLoop) u16 {
        return @intCast(@min(self.half_open_count, std.math.maxInt(u16)));
    }

    /// Get speed and total byte stats for a specific torrent.
    pub fn getSpeedStats(self: *const EventLoop, torrent_id: TorrentId) SpeedStats {
        const tc = self.getTorrentContextConst(torrent_id) orelse return .{};

        return .{
            .dl_speed = tc.current_dl_speed,
            .ul_speed = tc.current_ul_speed,
            .dl_total = tc.downloaded_bytes,
            .ul_total = tc.uploaded_bytes,
        };
    }

    pub fn accountTorrentBytes(self: *EventLoop, torrent_id: TorrentId, dl_bytes: usize, ul_bytes: usize) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (dl_bytes != 0) tc.downloaded_bytes +%= @intCast(dl_bytes);
            if (ul_bytes != 0) tc.uploaded_bytes +%= @intCast(ul_bytes);
        }
    }

    /// Remove a torrent context and disconnect all its peers.
    pub fn removeTorrent(self: *EventLoop, torrent_id: TorrentId) void {
        // Smart Ban: free any per-block records / pending attribution for
        // this torrent (otherwise they'd leak).
        if (self.smart_ban) |sb| sb.clearTorrent(torrent_id);

        // Disconnect all peers for this torrent
        var to_remove = std.ArrayList(u16).empty;
        defer to_remove.deinit(self.allocator);

        if (self.getTorrentContext(torrent_id)) |tc| {
            for (tc.peer_slots.items) |slot| {
                to_remove.append(self.allocator, slot) catch break;
            }
        }
        for (to_remove.items) |slot| self.removePeer(slot);
        // Clean up PEX state
        if (self.getTorrentContext(torrent_id)) |tc| {
            if (tc.pex_state) |tps| {
                tps.deinit(self.allocator);
                self.allocator.destroy(tps);
            }
            tc.peer_slots.deinit(self.allocator);
            tc.peer_slots = std.ArrayList(u16).empty;
            tc.torrent_peer_list_index = null;
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
            self.unregisterTorrentHashes(tc.info_hash, tc.info_hash_v2);
        }
        self.torrents.items[torrent_id] = null;
        self.removeActiveTorrentId(torrent_id);
        self.free_torrent_ids.append(self.allocator, torrent_id) catch {};
        if (self.torrent_count > 0) self.torrent_count -= 1;
    }

    pub fn attachPeerToTorrent(self: *EventLoop, torrent_id: TorrentId, slot: u16) void {
        const tc = self.getTorrentContext(torrent_id) orelse return;
        const peer = &self.peers[slot];
        if (peer.torrent_peer_index != null) return;

        peer.torrent_peer_index = @intCast(tc.peer_slots.items.len);
        tc.peer_slots.append(self.allocator, slot) catch {
            peer.torrent_peer_index = null;
            return;
        };

        if (tc.peer_slots.items.len == 1) {
            tc.torrent_peer_list_index = @intCast(self.torrents_with_peers.items.len);
            self.torrents_with_peers.append(self.allocator, torrent_id) catch {
                _ = tc.peer_slots.pop();
                peer.torrent_peer_index = null;
                tc.torrent_peer_list_index = null;
            };
        }
    }

    fn detachPeerFromTorrent(self: *EventLoop, torrent_id: TorrentId, slot: u16) void {
        const tc = self.getTorrentContext(torrent_id) orelse return;
        const peer = &self.peers[slot];
        const idx = peer.torrent_peer_index orelse return;
        if (idx < tc.peer_slots.items.len) {
            if (idx + 1 < tc.peer_slots.items.len) {
                const moved_slot = tc.peer_slots.items[tc.peer_slots.items.len - 1];
                _ = tc.peer_slots.swapRemove(idx);
                self.peers[moved_slot].torrent_peer_index = idx;
            } else {
                _ = tc.peer_slots.swapRemove(idx);
            }
        }
        peer.torrent_peer_index = null;

        if (tc.peer_slots.items.len == 0) {
            if (tc.torrent_peer_list_index) |list_idx| {
                if (list_idx + 1 < self.torrents_with_peers.items.len) {
                    const moved_tid = self.torrents_with_peers.items[self.torrents_with_peers.items.len - 1];
                    _ = self.torrents_with_peers.swapRemove(list_idx);
                    if (self.getTorrentContext(moved_tid)) |moved_tc| {
                        moved_tc.torrent_peer_list_index = list_idx;
                    }
                } else {
                    _ = self.torrents_with_peers.swapRemove(list_idx);
                }
            }
            tc.torrent_peer_list_index = null;
        }
    }

    // ── Peer management ────────────────────────────────────

    /// Select the transport for a new outbound connection based on the
    /// transport disposition. When both outgoing TCP and uTP are enabled,
    /// alternates using a simple counter (approximately 50/50 split).
    /// When only one outgoing transport is enabled, always returns that one.
    pub fn selectTransport(self: *EventLoop) Transport {
        const disp = self.transport_disposition;
        if (disp.outgoing_tcp and disp.outgoing_utp) {
            // Both enabled: alternate
            const counter = self.utp_transport_counter;
            self.utp_transport_counter = counter +% 1;
            return if (counter % 2 == 0) .tcp else .utp;
        }
        if (disp.outgoing_utp) return .utp;
        // Default to TCP (includes the case where neither is enabled,
        // which is a misconfiguration but safe to fall back to TCP).
        return .tcp;
    }

    /// Add a peer using the transport selected by `selectTransport()`.
    /// When uTP is selected but the connection fails (e.g. no UDP socket),
    /// falls back to TCP transparently.
    pub fn addPeerAutoTransport(self: *EventLoop, address: std.net.Address, torrent_id: TorrentId) !u16 {
        const transport = self.selectTransport();
        if (transport == .utp) {
            return self.addUtpPeer(address, torrent_id) catch |err| switch (err) {
                error.NoUtpManager, error.UtpConnectFailed => return self.addPeerForTorrent(address, torrent_id),
                else => return err,
            };
        }
        return self.addPeerForTorrent(address, torrent_id);
    }

    pub fn addPeer(self: *EventLoop, address: std.net.Address) !u16 {
        return self.addPeerForTorrent(address, 0);
    }

    pub fn addPeerForTorrent(self: *EventLoop, address: std.net.Address, torrent_id: TorrentId) !u16 {
        // Reject new outbound connections during graceful shutdown drain
        if (self.draining) return error.ShuttingDown;

        // Validate address family
        const family = address.any.family;
        if (family != posix.AF.INET and family != posix.AF.INET6) {
            return error.InvalidAddressFamily;
        }

        // Check ban list before creating socket
        if (self.ban_list) |bl| {
            if (bl.isBanned(address)) {
                return error.BannedPeer;
            }
        }

        if (self.getTorrentContext(torrent_id) == null) return error.TorrentNotFound;

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

        // Submit async socket creation via io_uring (IORING_OP_SOCKET, kernel 5.19+).
        // The CQE handler (peer_handler.handleSocketCreated) will configure the fd
        // and chain the CONNECT SQE.
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_socket, .context = 0 });
        _ = try self.ring.socket(ud, family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP, 0);

        self.peer_count += 1;
        self.half_open_count += 1;
        self.markActivePeer(slot);
        self.attachPeerToTorrent(torrent_id, slot);
        return slot;
    }

    /// Register a pre-connected fd as an outbound peer for `torrent_id`.
    /// Bypasses the async socket/connect SQE chain — intended for testing
    /// with socketpairs. MSE is skipped; the peer uses plaintext BitTorrent.
    pub fn addConnectedPeer(self: *EventLoop, fd: posix.fd_t, torrent_id: TorrentId) !u16 {
        if (self.getTorrentContext(torrent_id) == null) return error.TorrentNotFound;
        if (self.peer_count >= self.max_connections) return error.ConnectionLimitReached;

        const slot = self.allocSlot() orelse return error.TooManyPeers;
        const peer = &self.peers[slot];
        peer.* = Peer{
            .fd = fd,
            .state = .connecting,
            .mode = .outbound,
            .torrent_id = torrent_id,
            .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
        };
        peer.last_activity = self.clock.now();

        self.peer_count += 1;
        self.markActivePeer(slot);
        self.attachPeerToTorrent(torrent_id, slot);
        peer_handler.sendBtHandshake(self, slot);
        return slot;
    }

    /// Initiate an outbound uTP connection to a peer. Creates the uTP
    /// socket via the UtpManager, sends the SYN packet, and allocates a
    /// peer slot in the event loop.
    pub fn addUtpPeer(self: *EventLoop, address: std.net.Address, torrent_id: TorrentId) !u16 {
        // Reject new outbound connections during graceful shutdown drain
        if (self.draining) return error.ShuttingDown;

        // Check ban list before allocating uTP socket
        if (self.ban_list) |bl| {
            if (bl.isBanned(address)) {
                return error.BannedPeer;
            }
        }

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
            .mode = .outbound,
            .transport = .utp,
            .torrent_id = torrent_id,
            .utp_slot = conn.slot,
            .address = address,
        };
        self.peer_count += 1;
        self.half_open_count += 1;
        self.markActivePeer(peer_slot);
        self.attachPeerToTorrent(torrent_id, peer_slot);

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

    /// Start listening for inbound uTP/DHT connections on a UDP socket.
    /// Creates a dual-stack IPv6 UDP socket (handles IPv4-mapped addresses too),
    /// binds to the daemon's listen port, initializes the UtpManager, and
    /// submits the first RECVMSG.
    pub fn startUtpListener(self: *EventLoop) !void {
        if (self.udp_fd >= 0) return; // already listening

        // Create a dual-stack IPv6 UDP socket. When IPV6_V6ONLY is 0, the
        // kernel also accepts IPv4 connections via IPv4-mapped addresses.
        const fd = try posix.socket(
            posix.AF.INET6,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
        errdefer posix.close(fd);

        // Allow address reuse
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Disable IPV6_V6ONLY so IPv4 connections arrive as IPv4-mapped addresses.
        posix.setsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, &std.mem.toBytes(@as(c_int, 0))) catch {};

        // Apply SO_BINDTODEVICE if configured (keeps traffic on a specific interface).
        if (self.bind_device) |device| {
            socket_util.applyBindDevice(fd, device) catch |err| {
                log.warn("UDP socket SO_BINDTODEVICE({s}) failed: {s}", .{ device, @errorName(err) });
            };
        }

        // Bind to :: (all interfaces) on the configured port.
        const bind_addr = std.net.Address.initIp6(
            std.mem.zeroes([16]u8), // ::
            self.port,
            0, // flowinfo
            0, // scope_id
        );
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

    /// Stop the UDP listener (uTP/DHT). Cancels the pending RECVMSG,
    /// closes the UDP socket via io_uring, and frees the UtpManager.
    /// The cancel and close CQEs will be processed on the next tick;
    /// setting udp_fd = -1 immediately ensures the dispatch loop ignores them.
    pub fn stopUtpListener(self: *EventLoop) void {
        if (self.udp_fd < 0) return;
        const fd = self.udp_fd;
        self.udp_fd = -1;

        // Cancel the pending RECVMSG SQE
        const recv_ud = encodeUserData(.{ .slot = 0, .op_type = .utp_recv, .context = 0 });
        const cancel_ud = encodeUserData(.{ .slot = 0, .op_type = .cancel, .context = 0 });
        _ = self.ring.cancel(cancel_ud, recv_ud, 0) catch {};

        // Close the fd via io_uring (avoids racing with the pending CQE)
        _ = self.ring.close(cancel_ud, fd) catch {
            // Fallback to synchronous close if we can't get an SQE
            posix.close(fd);
        };

        if (self.utp_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
            self.utp_manager = null;
        }
        log.info("uTP listener stopped", .{});
    }

    /// Create and bind a TCP listen socket on the configured port.
    /// Tries each port in [port, port] (single port for now).
    /// Submits the first ACCEPT to the ring.
    pub fn startTcpListener(self: *EventLoop) !void {
        if (self.listen_fd >= 0) return; // already listening

        const bind_addr_str = self.bind_address orelse "0.0.0.0";
        const addr = std.net.Address.parseIp4(bind_addr_str, self.port) catch
            std.net.Address.parseIp6(bind_addr_str, self.port) catch
            return error.InvalidBindAddress;

        const fd = try posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(fd);

        const one: u32 = 1;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};

        if (self.bind_device) |device| {
            try socket_util.applyBindDevice(fd, device);
        }

        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 128);

        self.listen_fd = fd;
        try self.submitAccept();
        log.info("TCP listener started on port {d}", .{self.port});
    }

    /// Stop the TCP listener. Cancels the pending multishot ACCEPT,
    /// then closes the listen socket via io_uring. Setting listen_fd = -1
    /// immediately ensures the dispatch loop ignores stale CQEs.
    pub fn stopTcpListener(self: *EventLoop) void {
        if (self.listen_fd < 0) return;
        const fd = self.listen_fd;
        self.listen_fd = -1;

        // Cancel the in-flight multishot accept on the io_interface ring.
        // The cancel completion's callback drops the result on the floor
        // (we don't care whether it landed before close).
        self.io.cancel(
            .{ .target = &self.accept_completion },
            &self.accept_cancel_completion,
            null,
            ignoredCancelComplete,
        ) catch {};

        // Close via io_uring on the legacy ring with a sentinel user_data
        // (cancel op type) — the dispatch arm for `.cancel` is a no-op.
        const cancel_ud = encodeUserData(.{ .slot = 0, .op_type = .cancel, .context = 0 });
        _ = self.ring.close(cancel_ud, fd) catch {
            posix.close(fd);
        };

        log.info("TCP listener stopped", .{});
    }

    /// No-op callback used when we don't care about a cancel result —
    /// e.g. the multishot accept cancel during `stopTcpListener`.
    fn ignoredCancelComplete(
        _: ?*anyopaque,
        _: *io_interface.Completion,
        _: io_interface.Result,
    ) io_interface.CallbackAction {
        return .disarm;
    }

    /// Ensure listeners match the current transport disposition.
    /// Call after changing transport_disposition at runtime.
    /// Starts or stops TCP and UDP listeners as needed.
    pub fn reconcileListeners(self: *EventLoop) void {
        const disp = self.transport_disposition;
        const dht_active = self.dht_engine != null;

        // TCP listener
        if (disp.incoming_tcp) {
            if (self.listen_fd < 0) {
                self.startTcpListener() catch |err| {
                    log.warn("failed to start TCP listener on transport change: {s}", .{@errorName(err)});
                    self.transport_disposition.incoming_tcp = false;
                };
            }
        } else {
            self.stopTcpListener();
        }

        // UDP listener: needed for incoming_utp or DHT
        if (disp.incoming_utp or dht_active) {
            if (self.udp_fd < 0) {
                self.startUtpListener() catch |err| {
                    log.warn("failed to start UDP listener on transport change: {s}", .{@errorName(err)});
                    self.transport_disposition.incoming_utp = false;
                    self.transport_disposition.outgoing_utp = false;
                };
            }
        } else {
            self.stopUtpListener();
        }
    }

    pub fn removePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        // Track half-open connection cleanup
        if (peer.state == .connecting and self.half_open_count > 0) {
            self.half_open_count -= 1;
        }
        // Detach from DownloadingPiece (releases requested blocks, manages lifecycle)
        if (peer.downloading_piece != null) {
            peer_policy.detachPeerFromDownloadingPiece(self, peer);
        } else if (peer.current_piece) |piece_index| {
            // Legacy path: no DownloadingPiece
            if (self.getTorrentContext(peer.torrent_id)) |tc| {
                if (tc.piece_tracker) |pt| pt.releasePiece(piece_index);
            }
        }
        if (peer.next_downloading_piece != null) {
            peer_policy.detachPeerFromNextDownloadingPiece(self, peer);
        } else if (peer.next_piece) |next_index| {
            if (self.getTorrentContext(peer.torrent_id)) |tc| {
                if (tc.piece_tracker) |pt| pt.releasePiece(next_index);
            }
            if (peer.next_piece_buf) |buf| self.allocator.free(buf);
            peer.next_piece_buf = null; // prevent double-free in cleanupPeer
        }
        // Decrement per-piece availability counters so rarest-first stays accurate
        if (peer.availability_known) {
            if (peer.availability) |*bf| {
                if (self.getTorrentContext(peer.torrent_id)) |tc| {
                    if (tc.piece_tracker) |pt| pt.removeBitfieldAvailability(bf);
                }
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
            // BEP 52: discard pending Merkle hash requests for this peer
            if (tc.merkle_cache) |mc| mc.removePendingRequestsForSlot(slot);
        }
        self.detachPeerFromTorrent(peer.torrent_id, slot);
        self.unmarkIdle(slot);
        self.unmarkActivePeer(slot);

        // Free any tracked send buffers before closing the fd.  After
        // close, stale CQEs will arrive for this slot -- the guard in
        // handleSend will ignore them because the slot is .free.
        self.freeAllPendingSends(slot);

        const torrent_id = peer.torrent_id;
        self.cleanupPeer(peer);
        peer.* = Peer{};
        if (self.peer_count > 0) self.peer_count -= 1;

        if (self.peerCountForTorrent(torrent_id) == 0) {
            if (self.getTorrentContext(torrent_id)) |tc| {
                tc.current_dl_speed = 0;
                tc.current_ul_speed = 0;
                tc.last_dl_bytes = 0;
                tc.last_ul_bytes = 0;
                tc.last_speed_check = 0;
            }
        }
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

    pub fn tick(self: *EventLoop) !void {
        // Check if ban list was updated by API handlers
        if (self.ban_list_dirty.swap(false, .acquire)) {
            self.enforceBans();
        }

        peer_policy.processHashResults(self);
        peer_policy.processMerkleResults(self);
        peer_policy.checkPeerTimeouts(self);
        peer_policy.checkReannounce(self);
        peer_policy.recalculateUnchokes(self);
        peer_policy.tryAssignPieces(self);
        web_seed_handler.tryAssignWebSeedPieces(self);
        peer_policy.updateSpeedCounters(self);
        peer_policy.sendKeepAlives(self);
        peer_policy.checkPex(self);
        peer_policy.checkPartialSeed(self);
        utp_handler.utpTick(self);
        dht_handler.dhtTick(self);
        if (self.http_executor) |he| he.tick();
        if (self.udp_tracker_executor) |ute| ute.tick();

        // Flush any queued SQEs before waiting
        _ = self.ring.submit() catch |err| {
            log.warn("ring submit (pre-wait): {s}", .{@errorName(err)});
        };
        // Submit pending SQEs on the new io_interface ring without waiting
        // (the legacy ring's submit_and_wait below provides forward
        // progress during the Stage 2 transition; once everything is
        // migrated, the wait moves here).
        self.io.tick(0) catch |err| {
            log.warn("io tick (pre-wait): {s}", .{@errorName(err)});
        };
        _ = try self.ring.submit_and_wait(1);

        var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, 0);

        for (cqes[0..count]) |cqe| {
            self.dispatch(cqe);
        }

        // Drain any io_interface CQEs that arrived in parallel with the
        // legacy ring's wait. Non-blocking; callbacks fire on the same
        // event-loop thread.
        self.io.tick(0) catch |err| {
            log.warn("io tick (post-dispatch): {s}", .{@errorName(err)});
        };

        // Batch-send any queued piece block responses
        seed_handler.flushQueuedResponses(self);

        // Flush any SQEs queued during dispatch (piece responses, block requests, etc.)
        _ = self.ring.submit() catch |err| {
            log.warn("ring submit (post-dispatch): {s}", .{@errorName(err)});
        };
        self.io.tick(0) catch |err| {
            log.warn("io tick (post-flush): {s}", .{@errorName(err)});
        };

        // Graceful shutdown drain check
        if (self.draining) {
            if (!self.hasPendingTransferWork()) {
                log.info("drain complete, all in-flight transfers finished", .{});
                const signal = @import("signal.zig");
                signal.requestShutdown();
                self.running = false;
            } else if (self.clock.now() >= self.drain_deadline) {
                log.info("drain timeout expired, forcing shutdown", .{});
                const signal = @import("signal.zig");
                signal.requestShutdown();
                self.running = false;
            }
        }
    }

    /// Returns true if there is in-flight transfer work that should complete
    /// before a graceful shutdown. Checks pending disk writes, hasher work,
    /// and peers with active piece downloads.
    pub fn hasPendingTransferWork(self: *EventLoop) bool {
        // Pending disk writes
        if (self.pending_writes.count() > 0) return true;

        // Hasher has pending jobs or results
        if (self.hasher) |h| {
            if (h.hasPendingWork()) return true;
        }

        // Peers with in-flight piece downloads
        for (self.active_peer_slots.items) |slot| {
            const peer = &self.peers[slot];
            if (peer.current_piece != null) return true;
        }

        return false;
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

    // ── io.timeout-based one-shot timers ────────────────────

    /// Schedule a one-shot timer that fires `delay_ms` milliseconds from now.
    /// When the timer fires, `callback(context)` is invoked from the event
    /// loop thread during CQE dispatch.
    pub fn scheduleTimer(self: *EventLoop, delay_ms: u64, context: *anyopaque, callback: *const fn (*anyopaque) void) !void {
        const now_ms = nowMonotonicMs();
        const fire_at_ms: i64 = now_ms +| @as(i64, @intCast(@min(delay_ms, std.math.maxInt(i63))));

        try self.timer_callbacks.append(self.allocator, .{
            .fire_at_ms = fire_at_ms,
            .context = context,
            .callback = callback,
        });

        self.armNextTimer();
    }

    /// Arm `tick_timeout_completion` against the earliest pending callback's
    /// deadline. If a timeout is already in flight we leave it; the next
    /// callback dispatch (`tickTimeoutComplete`) re-arms with the up-to-date
    /// soonest deadline, which is sufficient because `fireExpiredTimers`
    /// drains *all* expired entries every wakeup.
    fn armNextTimer(self: *EventLoop) void {
        if (self.timer_callbacks.items.len == 0) return;
        if (self.timer_pending) return; // CQE will fire fireExpiredTimers + re-arm.

        // Find earliest deadline.
        var earliest_ms: i64 = std.math.maxInt(i64);
        for (self.timer_callbacks.items) |cb| {
            if (cb.fire_at_ms < earliest_ms) earliest_ms = cb.fire_at_ms;
        }

        const now_ms = nowMonotonicMs();
        const delta_ms: i64 = @max(earliest_ms - now_ms, 1); // at least 1ms
        const ns: u64 = @as(u64, @intCast(delta_ms)) * std.time.ns_per_ms;

        self.io.timeout(
            .{ .ns = ns },
            &self.tick_timeout_completion,
            self,
            tickTimeoutComplete,
        ) catch |err| {
            log.warn("io.timeout submit: {s}", .{@errorName(err)});
            return;
        };
        self.timer_pending = true;
    }

    /// Callback for `tick_timeout_completion`. Fires expired timers and
    /// re-arms the completion if more callbacks remain.
    fn tickTimeoutComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        _: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *EventLoop = @ptrCast(@alignCast(userdata.?));
        self.timer_pending = false;
        self.fireExpiredTimers();
        return .disarm;
    }

    /// Fire all timer callbacks whose deadline has passed, then re-arm
    /// for the next pending timer (if any).
    fn fireExpiredTimers(self: *EventLoop) void {
        const now_ms = nowMonotonicMs();

        var i: usize = 0;
        while (i < self.timer_callbacks.items.len) {
            if (self.timer_callbacks.items[i].fire_at_ms <= now_ms) {
                const cb = self.timer_callbacks.swapRemove(i);
                cb.callback(cb.context);
                // don't increment i -- swapRemove moved the last element here
            } else {
                i += 1;
            }
        }

        // Re-arm for next pending timer
        if (self.timer_callbacks.items.len > 0) {
            self.armNextTimer();
        }
    }

    /// Return the current monotonic clock in milliseconds.
    /// Uses CLOCK_MONOTONIC to match the timerfd clock source.
    fn nowMonotonicMs() i64 {
        const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
        return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    /// Process completed hash results from the background hasher.
    /// Public wrapper for external callers (e.g. torrent_session).
    pub fn processHashResults(self: *EventLoop) void {
        peer_policy.processHashResults(self);
    }

    // ── Async piece recheck ────────────────────────────

    /// Start an asynchronous piece recheck for a torrent.
    /// The recheck runs concurrently with normal event loop operation,
    /// using io_uring reads and the background hasher thread pool.
    /// Multiple rechecks may run in parallel for different torrents.
    /// `caller_ctx` is an opaque pointer stored on the AsyncRecheck for
    /// the on_complete callback to retrieve its parent object.
    pub fn startRecheck(
        self: *EventLoop,
        session: *const @import("../torrent/session.zig").Session,
        fds: []const posix.fd_t,
        torrent_id: TorrentId,
        known_complete: ?*const Bitfield,
        on_complete: ?*const fn (*@import("recheck.zig").AsyncRecheck) void,
        caller_ctx: ?*anyopaque,
    ) !void {
        const h = self.hasher orelse return error.NoHasher;

        const rc = try @import("recheck.zig").AsyncRecheck.create(
            self.allocator,
            session,
            fds,
            &self.io,
            h,
            torrent_id,
            known_complete,
            on_complete,
            caller_ctx,
        );
        try self.rechecks.append(self.allocator, rc);
        rc.start();
    }

    /// Cancel and destroy the recheck for a specific torrent. Safe to call
    /// if no recheck is active for that torrent.
    pub fn cancelRecheckForTorrent(self: *EventLoop, torrent_id: TorrentId) void {
        var i: usize = 0;
        while (i < self.rechecks.items.len) {
            if (self.rechecks.items[i].torrent_id == torrent_id) {
                const rc = self.rechecks.swapRemove(i);
                rc.destroy();
                // Don't increment i — swapRemove moved the last element here
            } else {
                i += 1;
            }
        }
    }

    /// Cancel and destroy all active rechecks. Used during shutdown.
    pub fn cancelAllRechecks(self: *EventLoop) void {
        for (self.rechecks.items) |rc| {
            rc.destroy();
        }
        self.rechecks.deinit(self.allocator);
        self.rechecks = std.ArrayList(*@import("recheck.zig").AsyncRecheck).empty;
    }

    // ── Async metadata fetch ─────────────────────────────

    /// Start an async BEP 9 metadata fetch for a magnet link.
    /// The on_complete callback fires when metadata is available or all peers fail.
    pub fn startMetadataFetch(
        self: *EventLoop,
        info_hash: [20]u8,
        peer_id: [20]u8,
        port: u16,
        is_private: bool,
        peers: []const std.net.Address,
        on_complete: ?*const fn (*metadata_handler.AsyncMetadataFetch) void,
        caller_ctx: ?*anyopaque,
    ) !void {
        if (self.metadata_fetch != null) return error.MetadataFetchAlreadyActive;

        self.metadata_fetch = try metadata_handler.AsyncMetadataFetch.create(
            self.allocator,
            &self.ring,
            info_hash,
            peer_id,
            port,
            is_private,
            peers,
            on_complete,
            caller_ctx,
        );
        self.metadata_fetch.?.start();
    }

    /// Cancel and destroy an active metadata fetch. Safe to call if none is active.
    pub fn cancelMetadataFetch(self: *EventLoop) void {
        if (self.metadata_fetch) |mf| {
            mf.destroy();
            self.metadata_fetch = null;
        }
    }

    // ── Peer banning ────────────────────────────────────

    /// Scan all connected peers and disconnect any that are banned.
    /// Called from tick() when the ban_list_dirty flag is set.
    pub fn enforceBans(self: *EventLoop) void {
        const bl = self.ban_list orelse return;
        for (self.peers, 0..) |*peer, i| {
            if (peer.state == .free) continue;
            if (bl.isBanned(peer.address)) {
                log.info("disconnecting banned peer: {any}", .{peer.address});
                self.removePeer(@intCast(i));
            }
        }
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

    /// Get the number of nodes in the DHT routing table.
    /// Returns 0 if DHT is not enabled.
    pub fn getDhtNodeCount(self: *const EventLoop) usize {
        if (self.dht_engine) |engine| {
            return engine.table.nodeCount();
        }
        return 0;
    }

    /// Set per-torrent download rate limit (bytes/sec). 0 = unlimited.
    pub fn setTorrentDlLimit(self: *EventLoop, torrent_id: TorrentId, rate: u64) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            tc.rate_limiter.setDownloadRate(rate);
        }
    }

    /// Set per-torrent upload rate limit (bytes/sec). 0 = unlimited.
    pub fn setTorrentUlLimit(self: *EventLoop, torrent_id: TorrentId, rate: u64) void {
        if (self.getTorrentContext(torrent_id)) |tc| {
            tc.rate_limiter.setUploadRate(rate);
        }
    }

    /// Get per-torrent download rate limit (bytes/sec). 0 = unlimited.
    pub fn getTorrentDlLimit(self: *const EventLoop, torrent_id: TorrentId) u64 {
        const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
        return tc.rate_limiter.download.rate;
    }

    /// Get per-torrent upload rate limit (bytes/sec). 0 = unlimited.
    pub fn getTorrentUlLimit(self: *const EventLoop, torrent_id: TorrentId) u64 {
        const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
        return tc.rate_limiter.upload.rate;
    }

    /// Enable BEP 16 super-seeding for a torrent. The seeder will send
    /// individual HAVE messages instead of a full bitfield, tracking
    /// which pieces each peer has seen to maximize piece diversity.
    pub fn enableSuperSeed(self: *EventLoop, torrent_id: TorrentId) !void {
        const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
        if (tc.super_seed != null) return; // already enabled
        const sess = tc.session orelse return error.NoSession;

        const ss = try self.allocator.create(SuperSeedState);
        ss.* = try SuperSeedState.init(self.allocator, try sess.metainfo.pieceCount());
        tc.super_seed = ss;
    }

    /// Disable BEP 16 super-seeding for a torrent.
    pub fn disableSuperSeed(self: *EventLoop, torrent_id: TorrentId) void {
        const tc = self.getTorrentContext(torrent_id) orelse return;
        if (tc.super_seed) |ss| {
            ss.deinit();
            self.allocator.destroy(ss);
            tc.super_seed = null;
        }
    }

    /// Check if super-seeding is enabled for a torrent.
    pub fn isSuperSeedEnabled(self: *const EventLoop, torrent_id: TorrentId) bool {
        const tc = self.getTorrentContextConst(torrent_id) orelse return false;
        return tc.super_seed != null;
    }

    /// Configure the huge page piece cache. Call after init, before tick.
    /// `capacity` is the desired cache size in bytes (0 = default 64 MB).
    pub fn initHugePageCache(self: *EventLoop, capacity: u64) void {
        const default_cache_size: usize = 64 * 1024 * 1024; // 64 MB
        const size: usize = if (capacity > 0) @intCast(@min(capacity, 1 << 32)) else default_cache_size;
        self.huge_page_cache = HugePageCache.init(self.allocator, size);
        if (self.huge_page_cache.?.isAllocated()) {
            log.info("piece cache: {d} MB ({s})", .{
                self.huge_page_cache.?.capacity / (1024 * 1024),
                if (self.huge_page_cache.?.huge_page_hint_enabled) "MADV_HUGEPAGE hint" else "regular pages",
            });
        }
    }

    /// Check if a download of `amount` bytes is allowed by both per-torrent
    /// and global rate limiters. Returns the number of bytes allowed (may be
    /// less than requested). Returns 0 if throttled.
    pub fn consumeDownloadTokens(self: *EventLoop, torrent_id: TorrentId, amount: u64) u64 {
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
    pub fn consumeUploadTokens(self: *EventLoop, torrent_id: TorrentId, amount: u64) u64 {
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
    pub fn isDownloadThrottled(self: *EventLoop, torrent_id: TorrentId) bool {
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
    pub fn isUploadThrottled(self: *EventLoop, torrent_id: TorrentId) bool {
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
            .peer_socket => peer_handler.handleSocketCreated(self, op.slot, cqe),
            .peer_connect => peer_handler.handleConnect(self, op.slot, cqe),
            .peer_send => peer_handler.handleSend(self, op.slot, cqe),
            .disk_write => peer_handler.handleDiskWrite(self, op.slot, cqe),
            .disk_read => seed_handler.handleSeedDiskRead(self, cqe),
            .timeout => {
                self.timeout_pending = false;
            },
            .utp_recv => utp_handler.handleUtpRecv(self, cqe),
            .utp_send => utp_handler.handleUtpSend(self, cqe),
            .http_socket, .http_connect, .http_send, .http_recv => {
                if (self.http_executor) |he| he.dispatchCqe(cqe);
            },
            .cancel => {},
            .api_accept => if (self.api_server) |srv| srv.handleAcceptCqe(cqe),
            .api_recv => if (self.api_server) |srv| srv.handleRecvCqe(op.slot, op.context, cqe),
            .api_send => if (self.api_server) |srv| srv.handleSendCqe(op.slot, op.context, cqe),
            .udp_socket, .udp_tracker_send, .udp_tracker_recv => {
                if (self.udp_tracker_executor) |ute| ute.dispatchCqe(cqe);
            },
            .metadata_connect, .metadata_send, .metadata_recv => {
                if (self.metadata_fetch) |mf| mf.handleCqe(op.op_type, op.slot, cqe.res);
            },
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
    /// Immediately tries to claim a piece and start downloading so that a peer
    /// that sends UNCHOKE + HAVE + EOF in rapid succession still gets served
    /// before the EOF CQE lands and removes the slot.
    pub fn markIdle(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        if (!isIdleCandidate(peer)) return;
        if (peer.idle_peer_index != null) return;

        // Try to claim a piece and start the download immediately rather than
        // waiting for the next tick's processIdlePeers pass.
        const policy = @import("peer_policy.zig");
        if (self.getTorrentContext(peer.torrent_id)) |tc| {
            if (!tc.upload_only and !self.isDownloadThrottled(peer.torrent_id)) {
                // First try joining an existing DownloadingPiece (multi-source)
                if (policy.tryJoinExistingPiece(self, slot, peer)) {
                    return; // joined existing download; don't add to idle queue
                }
                // Then try claiming a new piece
                if (tc.piece_tracker) |pt| {
                    const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
                    if (pt.claimPiece(peer_bf)) |piece_index| {
                        if (policy.startPieceDownload(self, slot, piece_index)) {
                            return; // piece claimed and started; don't add to idle queue
                        } else |_| {
                            pt.releasePiece(piece_index);
                            // startPieceDownload failed; fall through to add to idle queue
                        }
                    }
                }
            }
        }

        // No piece available right now -- add to idle queue for next tick.
        const idx: u16 = @intCast(self.idle_peers.items.len);
        self.idle_peers.append(self.allocator, slot) catch |err| {
            log.debug("idle_peers append for slot {d}: {s}", .{ slot, @errorName(err) });
            return;
        };
        peer.idle_peer_index = idx;
    }

    /// Remove a slot from the idle_peers list (swap-remove for O(1)).
    pub fn unmarkIdle(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const idx = peer.idle_peer_index orelse return;
        if (idx + 1 < self.idle_peers.items.len) {
            const moved_slot = self.idle_peers.items[self.idle_peers.items.len - 1];
            _ = self.idle_peers.swapRemove(idx);
            self.peers[moved_slot].idle_peer_index = idx;
        } else {
            _ = self.idle_peers.swapRemove(idx);
        }
        peer.idle_peer_index = null;
    }

    pub fn markActivePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        if (peer.active_peer_index != null) return;
        const idx: u16 = @intCast(self.active_peer_slots.items.len);
        self.active_peer_slots.append(self.allocator, slot) catch |err| {
            log.debug("active_peer_slots append for slot {d}: {s}", .{ slot, @errorName(err) });
            return;
        };
        peer.active_peer_index = idx;
    }

    pub fn unmarkActivePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const idx = peer.active_peer_index orelse return;
        if (idx + 1 < self.active_peer_slots.items.len) {
            const moved_slot = self.active_peer_slots.items[self.active_peer_slots.items.len - 1];
            _ = self.active_peer_slots.swapRemove(idx);
            self.peers[moved_slot].active_peer_index = idx;
        } else {
            _ = self.active_peer_slots.swapRemove(idx);
        }
        peer.active_peer_index = null;
    }

    // ── Internal helpers ─────────────────────────────────

    pub fn submitAccept(self: *EventLoop) !void {
        if (self.listen_fd < 0) return;
        try self.io.accept(
            .{ .fd = self.listen_fd, .multishot = true },
            &self.accept_completion,
            self,
            peer_handler.peerAcceptComplete,
        );
    }

    pub fn createPieceBuffer(self: *EventLoop, size: usize) !*PieceBuffer {
        return self.piece_buffer_pool.acquire(self.allocator, if (self.huge_page_cache) |*hpc| hpc else null, size);
    }

    pub fn acquireVectoredSendState(self: *EventLoop, batch_len: usize) !*VectoredSendState {
        const state = try self.vectored_send_pool.acquire(self.allocator, batch_len);
        const layout = vectoredSendLayout(state.backing_capacity);
        const headers_bytes = @sizeOf([13]u8) * batch_len;
        const iovecs_len = batch_len * 2;
        const refs_len = batch_len;

        state.headers = std.mem.bytesAsSlice([13]u8, state.backing[layout.headers_offset .. layout.headers_offset + headers_bytes]);
        state.iovecs = @as([*]posix.iovec_const, @ptrCast(@alignCast(state.backing.ptr + layout.iovecs_offset)))[0..iovecs_len];
        state.piece_buffers = @as([*]*PieceBuffer, @ptrCast(@alignCast(state.backing.ptr + layout.refs_offset)))[0..refs_len];
        state.msg = .{
            .name = null,
            .namelen = 0,
            .iov = state.iovecs.ptr,
            .iovlen = state.iovecs.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        state.iov_index = 0;
        state.next_free = null;
        return state;
    }

    pub fn retainPieceBuffer(self: *EventLoop, piece_buffer: *PieceBuffer) void {
        _ = self;
        piece_buffer.ref_count += 1;
    }

    pub fn releasePieceBuffer(self: *EventLoop, piece_buffer: *PieceBuffer) void {
        std.debug.assert(piece_buffer.ref_count > 0);
        piece_buffer.ref_count -= 1;
        if (piece_buffer.ref_count != 0) return;

        self.piece_buffer_pool.release(self.allocator, if (self.huge_page_cache) |*hpc| hpc else null, piece_buffer);
    }

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
    pub const PartialSendResult = enum {
        resubmitted,
        complete,
        failed,
    };

    pub fn handlePartialSend(self: *EventLoop, slot: u16, send_id: u32, bytes_sent: usize) PartialSendResult {
        for (self.pending_sends.items) |*ps| {
            if (ps.slot == slot and ps.send_id == send_id) {
                ps.sent += bytes_sent;
                switch (ps.storage) {
                    .owned => |owned| {
                        if (ps.sent < owned.buf.len) {
                            const remaining = owned.buf[ps.sent..];
                            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = @as(u40, send_id) });
                            _ = self.ring.send(ud, self.peers[slot].fd, remaining, 0) catch {
                                return .failed;
                            };
                            self.peers[slot].send_pending = true;
                            return .resubmitted;
                        }
                    },
                    .vectored => |state| {
                        if (state.advance(bytes_sent)) {
                            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = @as(u40, send_id) });
                            _ = self.ring.sendmsg(ud, self.peers[slot].fd, &state.msg, 0) catch {
                                return .failed;
                            };
                            self.peers[slot].send_pending = true;
                            return .resubmitted;
                        }
                    },
                }
                return .complete;
            }
        }
        return .complete;
    }

    /// Free ONE pending send buffer matching the send_id.
    /// Called when a single send CQE completes -- each CQE corresponds to
    /// exactly one buffer.  Freeing all buffers for a slot here would be a
    /// use-after-free when multiple tracked sends are in flight for the
    /// same peer (e.g. extension handshake + piece response).
    pub fn freeOnePendingSend(self: *EventLoop, slot: u16, send_id: u32) void {
        for (self.pending_sends.items, 0..) |ps, i| {
            if (ps.slot == slot and ps.send_id == send_id) {
                self.releasePendingSend(ps);
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
                self.releasePendingSend(self.pending_sends.items[i]);
                _ = self.pending_sends.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    pub fn hasPendingSendForSlot(self: *const EventLoop, slot: u16) bool {
        for (self.pending_sends.items) |ps| {
            if (ps.slot == slot) return true;
        }
        return false;
    }

    fn releaseVectoredSendState(self: *EventLoop, state: *VectoredSendState) void {
        for (state.piece_buffers) |piece_buffer| {
            self.releasePieceBuffer(piece_buffer);
        }
        self.vectored_send_pool.release(self.allocator, state);
    }

    fn releasePendingSend(self: *EventLoop, pending_send: PendingSend) void {
        switch (pending_send.storage) {
            .owned => |owned| {
                if (owned.small_slot) |small_slot| {
                    self.small_send_pool.release(small_slot);
                } else {
                    self.allocator.free(owned.buf);
                }
            },
            .vectored => |state| self.releaseVectoredSendState(state),
        }
    }

    pub fn trackPendingSendCopy(self: *EventLoop, slot: u16, send_id: u32, data: []const u8) ![]const u8 {
        if (self.small_send_pool.alloc(data, small_send_capacity)) |entry| {
            errdefer self.small_send_pool.release(entry.slot);
            try self.pending_sends.append(self.allocator, .{
                .slot = slot,
                .send_id = send_id,
                .storage = .{
                    .owned = .{
                        .buf = entry.buf,
                        .small_slot = entry.slot,
                    },
                },
            });
            return self.pending_sends.items[self.pending_sends.items.len - 1].storage.owned.buf;
        }

        const heap_buf = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(heap_buf);
        try self.pending_sends.append(self.allocator, .{
            .slot = slot,
            .send_id = send_id,
            .storage = .{
                .owned = .{
                    .buf = heap_buf,
                },
            },
        });
        return self.pending_sends.items[self.pending_sends.items.len - 1].storage.owned.buf;
    }

    pub fn trackPendingSendOwned(self: *EventLoop, slot: u16, send_id: u32, buf: []u8) ![]const u8 {
        if (self.small_send_pool.alloc(buf, small_send_capacity)) |entry| {
            errdefer self.small_send_pool.release(entry.slot);

            try self.pending_sends.append(self.allocator, .{
                .slot = slot,
                .send_id = send_id,
                .storage = .{
                    .owned = .{
                        .buf = entry.buf,
                        .small_slot = entry.slot,
                    },
                },
            });
            self.allocator.free(buf);
            return self.pending_sends.items[self.pending_sends.items.len - 1].storage.owned.buf;
        }

        try self.pending_sends.append(self.allocator, .{
            .slot = slot,
            .send_id = send_id,
            .storage = .{
                .owned = .{
                    .buf = buf,
                },
            },
        });
        return self.pending_sends.items[self.pending_sends.items.len - 1].storage.owned.buf;
    }

    pub fn trackPendingSendVectored(self: *EventLoop, slot: u16, send_id: u32, state: *VectoredSendState) !void {
        errdefer self.releaseVectoredSendState(state);
        try self.pending_sends.append(self.allocator, .{
            .slot = slot,
            .send_id = send_id,
            .storage = .{
                .vectored = state,
            },
        });
    }

    const vectoredSendLayout = bp.vectoredSendLayout;

    pub fn nextPendingWriteId(self: *EventLoop) u32 {
        const write_id = self.next_pending_write_id;
        self.next_pending_write_id +%= 1;
        if (self.next_pending_write_id == 0) self.next_pending_write_id = 1;
        return write_id;
    }

    pub fn createPendingWrite(self: *EventLoop, key: PendingWriteKey, pending_write: PendingWrite) !u32 {
        const write_id = self.nextPendingWriteId();

        try self.pending_writes.put(self.allocator, write_id, pending_write);
        errdefer _ = self.pending_writes.remove(write_id);

        try self.pending_write_lookup.put(self.allocator, key, write_id);
        self.pending_writes.getPtr(write_id).?.write_id = write_id;
        return write_id;
    }

    pub fn getPendingWrite(self: *EventLoop, key: PendingWriteKey) ?*PendingWrite {
        const write_id = self.pending_write_lookup.get(key) orelse return null;
        return self.pending_writes.getPtr(write_id);
    }

    pub fn hasPendingWrite(self: *const EventLoop, key: PendingWriteKey) bool {
        return self.pending_write_lookup.contains(key);
    }

    pub fn removePendingWrite(self: *EventLoop, key: PendingWriteKey) ?PendingWrite {
        const write_id = self.pending_write_lookup.get(key) orelse return null;
        _ = self.pending_write_lookup.remove(key);
        return if (self.pending_writes.fetchRemove(write_id)) |entry| entry.value else null;
    }

    pub fn getPendingWriteById(self: *EventLoop, write_id: u32) ?*PendingWrite {
        return self.pending_writes.getPtr(write_id);
    }

    pub fn removePendingWriteById(self: *EventLoop, write_id: u32) ?PendingWrite {
        const removed = self.pending_writes.fetchRemove(write_id) orelse return null;
        _ = self.pending_write_lookup.remove(.{
            .piece_index = removed.value.piece_index,
            .torrent_id = removed.value.torrent_id,
        });
        return removed.value;
    }

    pub fn getTorrentContext(self: *EventLoop, torrent_id: TorrentId) ?*TorrentContext {
        if (torrent_id >= self.torrents.items.len) return null;
        return if (self.torrents.items[torrent_id]) |*tc| tc else null;
    }

    pub fn getTorrentContextConst(self: *const EventLoop, torrent_id: TorrentId) ?*const TorrentContext {
        if (torrent_id >= self.torrents.items.len) return null;
        return if (self.torrents.items[torrent_id]) |*tc| tc else null;
    }

    pub fn enqueueAnnounceResult(self: *EventLoop, torrent_id: TorrentId, peers: []std.net.Address) !void {
        self.announce_mutex.lock();
        defer self.announce_mutex.unlock();
        try self.announce_results.append(self.allocator, .{
            .torrent_id = torrent_id,
            .peers = peers,
        });
    }

    pub fn findTorrentIdByInfoHash(self: *const EventLoop, info_hash: []const u8) ?TorrentId {
        if (info_hash.len != 20) return null;
        var key: [20]u8 = undefined;
        @memcpy(&key, info_hash[0..20]);
        return self.info_hash_to_torrent.get(key);
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
        // piece_buf/next_piece_buf: only free if NOT owned by a DownloadingPiece
        if (peer.downloading_piece == null) {
            if (peer.piece_buf) |buf| self.allocator.free(buf);
        }
        if (peer.next_downloading_piece == null) {
            if (peer.next_piece_buf) |buf| self.allocator.free(buf);
        }
        if (peer.availability) |*bf| bf.deinit(self.allocator);
        if (peer.pex_state) |ps| {
            ps.deinit(self.allocator);
            self.allocator.destroy(ps);
        }
        if (peer.mse_known_hashes) |hashes| self.allocator.free(hashes);
        // Free async MSE handshake state
        if (peer.mse_initiator) |mi| self.allocator.destroy(mi);
        if (peer.mse_responder) |mr| self.allocator.destroy(mr);
    }

    fn registerTorrentHashes(self: *EventLoop, torrent_id: TorrentId, info_hash: [20]u8, info_hash_v2: ?[20]u8) !void {
        const hash_slot = try self.info_hash_to_torrent.getOrPut(info_hash);
        if (hash_slot.found_existing and hash_slot.value_ptr.* != torrent_id) return error.DuplicateInfoHash;
        hash_slot.value_ptr.* = torrent_id;
        try self.mse_req2_to_hash.put(mse.hashReq2ForInfoHash(info_hash), info_hash);

        if (info_hash_v2) |v2_hash| {
            if (!std.mem.eql(u8, &v2_hash, &info_hash)) {
                const v2_slot = try self.info_hash_to_torrent.getOrPut(v2_hash);
                if (v2_slot.found_existing and v2_slot.value_ptr.* != torrent_id) {
                    if (!hash_slot.found_existing) _ = self.info_hash_to_torrent.remove(info_hash);
                    _ = self.mse_req2_to_hash.remove(mse.hashReq2ForInfoHash(info_hash));
                    return error.DuplicateInfoHash;
                }
                v2_slot.value_ptr.* = torrent_id;
                try self.mse_req2_to_hash.put(mse.hashReq2ForInfoHash(v2_hash), v2_hash);
            }
        }
    }

    fn unregisterTorrentHashes(self: *EventLoop, info_hash: [20]u8, info_hash_v2: ?[20]u8) void {
        _ = self.info_hash_to_torrent.remove(info_hash);
        _ = self.mse_req2_to_hash.remove(mse.hashReq2ForInfoHash(info_hash));
        if (info_hash_v2) |v2_hash| {
            if (!std.mem.eql(u8, &v2_hash, &info_hash)) {
                _ = self.info_hash_to_torrent.remove(v2_hash);
                _ = self.mse_req2_to_hash.remove(mse.hashReq2ForInfoHash(v2_hash));
            }
        }
    }

    fn removeActiveTorrentId(self: *EventLoop, torrent_id: TorrentId) void {
        for (self.active_torrent_ids.items, 0..) |active_id, idx| {
            if (active_id == torrent_id) {
                _ = self.active_torrent_ids.swapRemove(idx);
                return;
            }
        }
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

test "event loop supports high torrent counts with hashed lookup and slot reuse" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const torrent_count: u32 = 20_000;

    var reused_hash: [20]u8 = undefined;

    for (0..torrent_count) |idx| {
        var info_hash = [_]u8{0} ** 20;
        var peer_id = [_]u8{0} ** 20;
        std.mem.writeInt(u32, info_hash[0..4], @intCast(idx), .little);
        std.mem.writeInt(u32, peer_id[0..4], @intCast(idx), .big);
        info_hash[4] = 0xA5;
        peer_id[4] = 0x5A;

        const torrent_id = try el.addTorrentContext(.{
            .shared_fds = empty_fds[0..],
            .info_hash = info_hash,
            .peer_id = peer_id,
        });
        try std.testing.expectEqual(@as(TorrentId, @intCast(idx)), torrent_id);
        try std.testing.expectEqual(torrent_id, el.findTorrentIdByInfoHash(&info_hash));

        if (idx == 4_096) reused_hash = info_hash;
    }

    try std.testing.expectEqual(torrent_count, el.torrent_count);
    try std.testing.expectEqual(@as(?TorrentId, 4_096), el.findTorrentIdByInfoHash(&reused_hash));

    el.removeTorrent(4_096);
    try std.testing.expect(el.findTorrentIdByInfoHash(&reused_hash) == null);

    var replacement_hash = [_]u8{0} ** 20;
    replacement_hash[0] = 0xFE;
    replacement_hash[1] = 0xED;
    replacement_hash[2] = 0xFA;
    replacement_hash[3] = 0xCE;
    replacement_hash[4] = 0x01;

    const replacement_id = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = replacement_hash,
        .peer_id = [_]u8{1} ** 20,
    });
    try std.testing.expectEqual(@as(TorrentId, 4_096), replacement_id);
    try std.testing.expectEqual(@as(?TorrentId, replacement_id), el.findTorrentIdByInfoHash(&replacement_hash));
}

test "announce results are queued per torrent" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const peers_a = try std.testing.allocator.alloc(std.net.Address, 1);
    peers_a[0] = try std.net.Address.parseIp4("127.0.0.1", 6881);
    const peers_b = try std.testing.allocator.alloc(std.net.Address, 2);
    peers_b[0] = try std.net.Address.parseIp4("127.0.0.2", 6882);
    peers_b[1] = try std.net.Address.parseIp4("127.0.0.3", 6883);

    try el.enqueueAnnounceResult(3, peers_a);
    try el.enqueueAnnounceResult(7, peers_b);

    el.announce_mutex.lock();
    defer el.announce_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 2), el.announce_results.items.len);
    try std.testing.expectEqual(@as(TorrentId, 3), el.announce_results.items[0].torrent_id);
    try std.testing.expectEqual(@as(TorrentId, 7), el.announce_results.items[1].torrent_id);
    try std.testing.expectEqual(@as(usize, 1), el.announce_results.items[0].peers.len);
    try std.testing.expectEqual(@as(usize, 2), el.announce_results.items[1].peers.len);
}

test "peer and torrent membership indices stay consistent across swap-remove" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const tid0 = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x11} ** 20,
        .peer_id = [_]u8{0x22} ** 20,
    });
    const tid1 = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x33} ** 20,
        .peer_id = [_]u8{0x44} ** 20,
    });

    const torrent0_slots = [_]u16{ 0, 1, 2 };
    for (torrent0_slots) |slot| {
        el.peers[slot].state = .active_recv_header;
        el.peers[slot].torrent_id = tid0;
        el.peers[slot].availability_known = true;
        el.peers[slot].peer_choking = false;
        el.attachPeerToTorrent(tid0, slot);
        el.markActivePeer(slot);
        el.markIdle(slot);
    }

    el.peers[3].state = .active_recv_header;
    el.peers[3].torrent_id = tid1;
    el.peers[3].availability_known = true;
    el.peers[3].peer_choking = false;
    el.attachPeerToTorrent(tid1, 3);
    el.markActivePeer(3);
    el.markIdle(3);

    try std.testing.expectEqual(@as(usize, 4), el.active_peer_slots.items.len);
    try std.testing.expectEqual(@as(usize, 4), el.idle_peers.items.len);
    try std.testing.expectEqual(@as(usize, 2), el.torrents_with_peers.items.len);

    el.unmarkIdle(1);
    try std.testing.expectEqual(@as(?u16, null), el.peers[1].idle_peer_index);
    try std.testing.expectEqual(@as(?u16, 1), el.peers[3].idle_peer_index);
    try std.testing.expectEqual(@as(u16, 3), el.idle_peers.items[1]);

    el.unmarkActivePeer(1);
    try std.testing.expectEqual(@as(?u16, null), el.peers[1].active_peer_index);
    try std.testing.expectEqual(@as(?u16, 1), el.peers[3].active_peer_index);
    try std.testing.expectEqual(@as(u16, 3), el.active_peer_slots.items[1]);

    el.detachPeerFromTorrent(tid0, 1);
    try std.testing.expectEqual(@as(?u16, null), el.peers[1].torrent_peer_index);
    try std.testing.expectEqual(@as(?u16, 1), el.peers[2].torrent_peer_index);
    try std.testing.expectEqual(@as(u16, 2), el.getTorrentContext(tid0).?.peer_slots.items[1]);

    el.detachPeerFromTorrent(tid0, 0);
    try std.testing.expectEqual(@as(?u16, 0), el.peers[2].torrent_peer_index);
    try std.testing.expectEqual(@as(u16, 2), el.getTorrentContext(tid0).?.peer_slots.items[0]);

    el.detachPeerFromTorrent(tid0, 2);
    const tc0 = el.getTorrentContext(tid0).?;
    const tc1 = el.getTorrentContext(tid1).?;
    try std.testing.expectEqual(@as(usize, 0), tc0.peer_slots.items.len);
    try std.testing.expectEqual(@as(?u32, null), tc0.torrent_peer_list_index);
    try std.testing.expectEqual(@as(?u32, 0), tc1.torrent_peer_list_index);
    try std.testing.expectEqual(@as(usize, 1), el.torrents_with_peers.items.len);
    try std.testing.expectEqual(tid1, el.torrents_with_peers.items[0]);
}

test "selectTransport always returns tcp when outgoing utp disabled" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_only;

    // All calls should return TCP
    for (0..10) |_| {
        try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    }
}

test "selectTransport alternates tcp and utp when both outgoing enabled" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_and_utp;
    el.utp_transport_counter = 0;

    // Even counter -> TCP, odd counter -> uTP
    try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    try std.testing.expectEqual(Transport.utp, el.selectTransport());
    try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    try std.testing.expectEqual(Transport.utp, el.selectTransport());

    // Verify counter is incrementing
    try std.testing.expectEqual(@as(u32, 4), el.utp_transport_counter);
}

test "selectTransport yields approximately 50/50 split" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_and_utp;
    el.utp_transport_counter = 0;

    var tcp_count: u32 = 0;
    var utp_count: u32 = 0;
    for (0..100) |_| {
        const t = el.selectTransport();
        if (t == .tcp) tcp_count += 1 else utp_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 50), tcp_count);
    try std.testing.expectEqual(@as(u32, 50), utp_count);
}

test "selectTransport returns utp only when outgoing_tcp disabled" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.utp_only;

    for (0..10) |_| {
        try std.testing.expectEqual(Transport.utp, el.selectTransport());
    }
}

test "selectTransport falls back to tcp when no outgoing enabled" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = false,
        .incoming_tcp = true,
        .incoming_utp = true,
    };

    // Falls back to TCP as a safe default
    for (0..10) |_| {
        try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    }
}


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
const addr_mod = @import("../net/address.zig");
const utp_mod = @import("../net/utp.zig");
const utp_mgr = @import("../net/utp_manager.zig");
const mse = @import("../crypto/mse.zig");
const ring_mod = @import("ring.zig");
const backend = @import("backend.zig");
pub const RealIO = backend.RealIO;
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

const recheck_mod = @import("recheck.zig");
const http_executor_mod = @import("http_executor.zig");
const tracker_executor_mod = @import("../tracker/executor.zig");
const udp_tracker_executor_mod = @import("../tracker/udp_executor.zig");
const rpc_server_mod = @import("../rpc/server.zig");

// Sub-modules: focused implementations that operate on *EventLoop
const peer_handler = @import("peer_handler.zig");
const protocol = @import("protocol.zig");
const seed_handler = @import("seed_handler.zig");
const peer_policy = @import("peer_policy.zig");
const utp_handler = @import("utp_handler.zig");
const dht_handler = @import("dht_handler.zig");
const metadata_handler = @import("metadata_handler.zig");
const web_seed_handler = @import("web_seed_handler.zig");
const peer_candidates_mod = @import("peer_candidates.zig");

// ── Re-exported type definitions (moved to types.zig) ────

pub const types = @import("types.zig");
pub const max_peers = types.max_peers;
pub const TorrentId = types.TorrentId;
pub const PeerMode = types.PeerMode;
pub const Transport = types.Transport;
pub const PeerState = types.PeerState;
pub const Peer = types.Peer;
pub const SpeedStats = types.SpeedStats;
pub const TorrentContext = types.TorrentContext;
pub const PeerCandidateSource = peer_candidates_mod.PeerCandidateSource;

const clock_mod = @import("clock.zig");
pub const Clock = clock_mod.Clock;
const random_mod = @import("../runtime/random.zig");
pub const Random = random_mod.Random;

const cqe_batch_size = 64;

// ── Event loop ────────────────────────────────────────────
//
// `EventLoop` is generic over its IO backend at compile time. Daemon
// callsites use the concrete `EventLoop = EventLoopOf(RealIO)` alias
// declared below the function; sim tests instantiate `EventLoopOf(SimIO)`
// directly. The struct body and methods are identical for either; only
// the `io: IO` field type and any direct `IO.init` calls vary.
//
// Cross-module handler functions (peer_handler / utp_handler / protocol /
// seed_handler / web_seed_handler / dht_handler) take `self: anytype` so
// they work with either instantiation without per-IO duplication of
// signatures.

pub fn EventLoopOf(comptime IO: type) type {
    return struct {
        const Self = @This();

        pub const small_send_capacity: usize = 256;
        const small_send_slots: usize = max_peers * 2;
        const default_torrent_capacity: usize = 64;

        // Per-IO instantiation of the recheck state machine. The daemon
        // sees `AsyncRecheck = AsyncRecheckOf(RealIO)`; sim tests see
        // `AsyncRecheckOf(SimIO)` with the same surface.
        pub const AsyncRecheck = recheck_mod.AsyncRecheckOf(IO);

        // Same shape for AsyncMetadataFetch — daemon sees the RealIO
        // instantiation; sim tests instantiate `AsyncMetadataFetchOf(SimIO)`
        // through this alias.
        pub const AsyncMetadataFetch = metadata_handler.AsyncMetadataFetchOf(IO);
        pub const HttpExecutor = http_executor_mod.HttpExecutorOf(IO);
        pub const TrackerExecutor = tracker_executor_mod.TrackerExecutorOf(IO);
        pub const UdpTrackerExecutor = udp_tracker_executor_mod.UdpTrackerExecutorOf(IO);
        pub const ApiServer = rpc_server_mod.ApiServerOf(IO);

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
        pub const PendingSendPool = bp.PendingSendPool;
        const SmallSendPool = bp.SmallSendPool;

        /// A uTP packet waiting to be sent over the UDP socket.
        /// Sized for a full UDP datagram (header + payload).
        pub const UtpQueuedPacket = struct {
            data: [1500]u8 = undefined,
            len: usize = 0,
            remote: std.net.Address,
        };

        pub const utp_send_slot_count: usize = 64;

        pub const UtpSendSlot = struct {
            data: [1500]u8 = undefined,
            len: usize = 0,
            remote: std.net.Address = undefined,
            addr: std.net.Address = undefined,
            original_family: posix.sa_family_t = 0,
            iov: [1]posix.iovec_const = undefined,
            msg: posix.msghdr_const = undefined,
            completion: io_interface.Completion = .{},
            active: bool = false,
        };

        pub const utp_recv_slot_count: usize = 8;

        pub const UtpRecvSlot = struct {
            data: [1500]u8 = undefined,
            iov: [1]posix.iovec = undefined,
            addr: std.net.Address = undefined,
            msg: posix.msghdr = undefined,
            completion: io_interface.Completion = .{},
            active: bool = false,
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
            expected_read_lengths: [max_spans]u32 = @as([max_spans]u32, @splat(0)),
        };

        pub const AnnounceResult = struct {
            torrent_id: TorrentId,
            peers: []std.net.Address,
        };

        /// `io_interface`-based io_uring backend driving every async op.
        /// Stage 2 replaced the legacy packed-userdata ring with a single
        /// caller-owned-Completion model.
        io: IO,
        allocator: std.mem.Allocator,
        peers: []Peer,
        peer_count: u16 = 0,
        running: bool = true,
        clock: Clock = .real,
        /// Daemon-wide CSPRNG (`runtime.Random`). Both production and
        /// simulation paths read here. Initialized once in `initBare`
        /// from the OS CSPRNG (`Random.realRandom()` reads 32 bytes
        /// from `getrandom(2)` and seeds ChaCha8). Tests driving sim
        /// time should overwrite this field with a
        /// `Random.simRandom(seed)` value before submitting any work
        /// — both non-crypto paths (UDP tracker tx-ids, smart-ban
        /// tie-breaks, jittered delays) and crypto-sensitive paths
        /// (MSE handshake DH keys, peer IDs, DHT node IDs, DHT
        /// tokens, RPC SID) draw from this single source. See
        /// `runtime/random.zig` for the threat model and migration
        /// history.
        random: Random,

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
        utp_settings: utp_mod.UtpSettings = .{},
        utp_preallocate_packet_pool: bool = false,
        // Persistent recv slots and msghdrs for concurrent io_uring RECVMSGs.
        utp_recv_slots: [utp_recv_slot_count]UtpRecvSlot =
            @as([utp_recv_slot_count]UtpRecvSlot, @splat(.{})),
        utp_recv_active: u16 = 0,
        utp_recv_next_slot: u16 = 0,
        // Persistent send slots and msghdrs for concurrent io_uring SENDMSGs.
        utp_send_slots: [utp_send_slot_count]UtpSendSlot =
            @as([utp_send_slot_count]UtpSendSlot, @splat(.{})),
        utp_send_inflight: u16 = 0,
        utp_send_next_slot: u16 = 0,
        utp_send_pending: bool = false,
        udp_ipv6_unreachable: bool = false,
        // Outbound packet queue (when a send is already in flight)
        utp_send_queue: std.ArrayList(UtpQueuedPacket) = std.ArrayList(UtpQueuedPacket).empty,
        // send completions live in utp_send_slots; recv completions live in utp_recv_slots.

        // DHT (BEP 5): distributed hash table engine for trackerless peer discovery.
        // Shares the UDP socket with uTP. Incoming datagrams starting with 'd'
        // (bencode dict) are routed to DHT; others go to uTP.
        dht_engine: ?*@import("../dht/dht.zig").DhtEngine = null,

        // API server (shares the event loop's ring)
        api_server: ?*ApiServer = null,

        // Generic HTTP executor (shares the event loop's ring).
        // CQEs for http_socket/http_connect/http_send/http_recv route here.
        http_executor: ?*HttpExecutor = null,

        // Tracker executor (thin wrapper around http_executor, shares the event loop's ring).
        // Lives in `src/tracker/` so the dependency points downward
        // (io ← tracker, never io → daemon). The EventLoop only stores
        // the pointer and nulls it on deinit; daemon callers (SessionManager)
        // construct the executor and wire it in.
        tracker_executor: ?*TrackerExecutor = null,

        // UDP tracker executor (shares the event loop's ring, BEP 15).
        // Same layering rule as `tracker_executor` above — lives in
        // `src/tracker/`. EventLoop calls `tick()` once per loop iteration
        // (see below); construction and lifecycle live in SessionManager.
        udp_tracker_executor: ?*UdpTrackerExecutor = null,

        // Complete pieces bitfield (for seeding -- which pieces we can serve)
        complete_pieces: ?*const Bitfield = null,

        /// Wake-up timeout completion. Used by `submitTimeout` to break a
        /// blocking `io.tick(1)` after a deadline so external callers (tests,
        /// perf, daemon startup) can poll periodically.
        wake_timeout_completion: io_interface.Completion = .{},
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
        // The PendingSends themselves live in `pending_send_pool`; this list
        // holds pointers into the pool for O(N) lookup by (slot, send_id).
        pending_sends: std.ArrayList(*PendingSend),
        pending_send_pool: PendingSendPool,
        small_send_pool: SmallSendPool,
        // Monotonic counter for unique PendingSend identification across CQEs.
        // Starts at 1; send_id == 0 is reserved as the pool's "free slot"
        // sentinel (see `PendingSend.send_id` comment).
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
        peer_connect_timeout_ns: u64 = peer_handler.default_peer_connect_timeout_ns,
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
        rechecks: std.ArrayList(*AsyncRecheck) = std.ArrayList(*AsyncRecheck).empty,

        // Async BEP 9 metadata fetch state machine (null when no fetch is active)
        metadata_fetch: ?*AsyncMetadataFetch = null,

        // Stage 4 zero-alloc: pre-allocated worst-case storage for the
        // ut_metadata assembler. BEP 9 says at most one in-flight fetch
        // per torrent; `startMetadataFetch` further serialises across
        // torrents (`metadata_fetch != null` gate). One buffer is
        // therefore enough for the daemon. Sized at
        // `ut_metadata.max_metadata_size` (10 MiB current cap; BEP 9
        // protocol limit is 16 MiB). Allocated on first
        // `startMetadataFetch` call and retained across fetches; freed
        // in `deinit`.
        metadata_assembly_buffer: ?[]u8 = null,
        metadata_assembly_received: ?[]bool = null,

        // BEP 19: web seed download slots
        web_seed_slots: [web_seed_handler.max_web_seed_slots]web_seed_handler.WebSeedSlot =
            @as([web_seed_handler.max_web_seed_slots]web_seed_handler.WebSeedSlot, @splat(.{})),
        /// Maximum bytes per web seed HTTP Range request (batches multiple pieces).
        web_seed_max_request_bytes: u32 = 16 * 1024 * 1024,

        // Compact list of peer slots that are idle (active, unchoked, have
        // availability, and need a piece assignment).  Avoids scanning all
        // max_peers slots every tick in tryAssignPieces.
        idle_peers: std.ArrayList(u16),
        active_peer_slots: std.ArrayList(u16),

        // Multi-source piece assembly: shared per-piece download state.
        // Key = (torrent_id, piece_index), Value = heap-allocated DownloadingPiece.
        downloading_pieces: DownloadingPieceMap = .empty,

        // ── Periodic durability sync ──────────────────────────
        // Interval (ms) between periodic `submitTorrentSync` sweeps for
        // every torrent with `dirty_writes_since_sync > 0`. 30 s matches
        // the OS dirty-writeback default (`vm.dirty_expire_centisecs` =
        // 3000 by default on Linux) — close enough that we're not adding
        // material write amplification, but tight enough that a
        // SIGKILL'd daemon loses at most ~30 s of pending pieces from
        // pagecache rather than relying on the OS's eventual writeback.
        sync_timer_interval_ms: u64 = 30_000,
        sync_timer_armed: bool = false,

        // ── Lifecycle ──────────────────────────────────────────

        /// Create a bare event loop with no initial torrent (for daemon mode).
        ///
        /// Constructs the backend-selected `RealIO` via
        /// `backend.initEventLoop`, which dispatches on `-Dio=`. Under
        /// the default `-Dio=io_uring` this preserves the historical
        /// 256-entry ring + COOP_TASKRUN/SINGLE_ISSUER flags. SimIO-
        /// backed callers (sim tests) bypass this path entirely via
        /// `initBareWithIO`, passing a SimIO instance configured with
        /// the test's socket pool capacity.
        pub fn initBare(allocator: std.mem.Allocator, hasher_threads: u32) !@This() {
            const io = try backend.initEventLoopFor(IO, allocator);
            return initBareWithIO(allocator, io, hasher_threads);
        }

        /// Create a bare event loop with a pre-built IO backend instance.
        /// The caller is responsible for constructing the IO appropriate
        /// for the instantiation: `RealIO.init(...)` for the daemon path
        /// or `SimIO.init(allocator, .{...})` for sim tests.
        pub fn initBareWithIO(allocator: std.mem.Allocator, io: IO, hasher_threads: u32) !@This() {
            const peers = try allocator.alloc(Peer, max_peers);
            @memset(peers, Peer{});

            const hasher = if (hasher_threads > 0)
                Hasher.realInit(allocator, hasher_threads) catch null
            else
                null;

            return .{
                .io = io,
                .allocator = allocator,
                .peers = peers,
                .random = Random.realRandom(),
                .torrents = try std.ArrayList(?TorrentContext).initCapacity(allocator, default_torrent_capacity),
                .free_torrent_ids = std.ArrayList(TorrentId).empty,
                .active_torrent_ids = try std.ArrayList(TorrentId).initCapacity(allocator, default_torrent_capacity),
                .torrents_with_peers = std.ArrayList(TorrentId).empty,
                .info_hash_to_torrent = std.AutoHashMap([20]u8, TorrentId).init(allocator),
                .mse_req2_to_hash = std.AutoHashMap([20]u8, [20]u8).init(allocator),
                .pending_writes = .empty,
                .pending_write_lookup = .empty,
                .pending_sends = std.ArrayList(*PendingSend).empty,
                // Pool capacity: max_peers (4096) * worst-case in-flight tracked
                // sends per peer (4 — pipeline refill + keepalive + piece response
                // + extension handshake leeway). Sized once at init; if the pool
                // exhausts under abnormal load, callers see error.OutOfMemory and
                // the daemon retries on the next refill cycle.
                .pending_send_pool = try PendingSendPool.init(allocator, max_peers * 4),
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
        pub fn installSignalFd(self: *Self) !void {
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
            const self: *Self = @ptrCast(@alignCast(userdata.?));
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
        ) !Self {
            var el = try initBare(allocator, hasher_threads);

            const tid = try el.addTorrent(session, piece_tracker, shared_fds, peer_id);
            std.debug.assert(tid == 0);

            return el;
        }

        pub fn deinit(self: *Self) void {
            // Mark draining at deinit start. The signal-handler graceful-
            // shutdown path already sets this; tests and crash paths
            // calling deinit directly didn't, which left the picker /
            // hash-submission paths thinking new work was acceptable
            // even as the hasher was being torn down.
            // `peer_policy.completePieceDownload` (and any other
            // hash-submitting path) checks this flag and drops new
            // submissions during teardown. Idempotent if already set.
            self.draining = true;

            // ── Phase -1: Drain hasher → pending_writes ──────────────
            // Before tearing down the hasher, give any verified piece
            // results a chance to land on disk. The graceful-shutdown
            // path drains via the daemon's main loop, but tests and
            // crash paths call deinit directly with hasher.completed_results
            // potentially holding valid bufs whose disk writes haven't
            // been kicked off yet. Run a bounded drain loop:
            //   tick → processHashResults pulls completed_results into
            //   pending_writes → tick fires the writes → repeat.
            // hasher.deinit defensively frees any leftover completed_results
            // bufs (see hasher.deinit) so even if the drain is incomplete
            // we don't leak; it just means some verified data may be lost.
            if (self.hasher) |h| {
                var drain_rounds: u32 = 0;
                while ((h.hasPendingWork() or self.pending_writes.count() > 0) and
                    drain_rounds < 100) : (drain_rounds += 1)
                {
                    self.io.tick(0) catch break;
                    peer_policy.processHashResults(self);
                    self.io.tick(0) catch break;
                }
                h.deinit();
                self.allocator.destroy(h);
                // Null the pointer so any post-destroy submitVerify
                // attempt (residual CQEs in Phase 2 drainRemainingCqes)
                // hits the `self.hasher == null` guard in
                // completePieceDownload rather than UAFing on freed
                // memory.
                self.hasher = null;
            }

            // ── Phase 0: Flush pending disk writes ────────────────────
            // Belt-and-braces: drain any pending_writes that the hasher
            // drain above queued. The drain loop already ticks them, but
            // this catches any still-in-flight on the legacy path.
            {
                var flush_rounds: u32 = 0;
                while (self.pending_writes.count() > 0 and flush_rounds < 100) : (flush_rounds += 1) {
                    self.io.tick(1) catch break;
                }
            }

            // ── Phase 0.5: Sync dirty torrents to disk ────────────────
            // After every pending write has landed (Phase -1 / Phase 0
            // drained them), submit one fsync sweep per torrent that
            // has un-fsync'd writes. Then tick until those fsyncs
            // complete. Without this the OS pagecache controls
            // durability: a SIGKILL or power loss seconds after
            // shutdown can lose recently-completed pieces. See
            // `submitTorrentSync` for the per-fd mechanics.
            {
                _ = self.submitShutdownSync();
                var sync_rounds: u32 = 0;
                while (self.anySyncInFlight() and sync_rounds < 100) : (sync_rounds += 1) {
                    self.io.tick(1) catch break;
                }
            }

            // ── Phase 1: Close all file descriptors ──────────────────
            // Close peer fds, listen fd, and UDP fd so the kernel cancels
            // pending io_uring operations that reference our buffers.
            // Do NOT free buffers yet -- the kernel may still be
            // completing cancelled SQEs that reference them.
            if (self.listen_fd >= 0) {
                self.listen_fd = -1;
                self.io.cancel(
                    .{ .target = &self.accept_completion },
                    &self.accept_cancel_completion,
                    null,
                    ignoredCancelComplete,
                ) catch {};
            }
            for (self.peers, 0..) |*peer, slot_index| {
                // Clean up uTP slot state
                if (peer.transport == .utp) {
                    if (peer.utp_slot) |utp_slot| {
                        if (self.utp_manager) |mgr| {
                            const now_us = self.clock.nowUs32();
                            _ = mgr.reset(utp_slot, now_us);
                        }
                    }
                }
                if (peer.fd >= 0) {
                    const slot: u16 = @intCast(slot_index);
                    self.freeAllPendingSends(slot);
                    const embedded_completions = peerEmbeddedCompletionCount(peer);
                    if (embedded_completions > 0 and peer.state != .disconnecting) {
                        peer.state = .disconnecting;
                        peer.disconnecting_completions = embedded_completions;
                    }
                    const fd = peer.fd;
                    peer.fd = -1;
                    self.io.closeSocket(fd);
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

            // Free the shared metadata-assembly buffer (Stage 4 zero-alloc).
            if (self.metadata_assembly_buffer) |buf| {
                self.allocator.free(buf);
                self.metadata_assembly_buffer = null;
            }
            if (self.metadata_assembly_received) |recv| {
                self.allocator.free(recv);
                self.metadata_assembly_received = null;
            }

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
            self.pending_send_pool.deinit(self.allocator);
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
                for (peer.extra_prefetch_pieces) |slot| {
                    if (slot.downloading_piece == null) {
                        if (slot.buf) |buf| self.allocator.free(buf);
                    }
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
                    tc.pending_resume_durability.deinit(self.allocator);
                    tc.durable_resume_pieces.deinit(self.allocator);
                    tc.peer_candidates.deinit(self.allocator);
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
            self.io.deinit();
        }

        /// Drain pending CQEs from the io_interface ring after fds are closed.
        /// Used during deinit to ensure the kernel has finished touching any
        /// buffers we're about to free.
        fn drainRemainingCqes(self: *Self) void {
            var drain_rounds: u32 = 0;
            while (drain_rounds < 256 and self.pendingBufferOperations() > 0) : (drain_rounds += 1) {
                self.io.tick(1) catch break;
            }
            // Best-effort non-blocking sweep.
            drain_rounds = 0;
            while (drain_rounds < 32) : (drain_rounds += 1) {
                self.io.tick(0) catch break;
            }

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

        fn pendingBufferOperations(self: *const Self) usize {
            var count = self.pending_writes.count() + self.pending_sends.items.len + self.pending_reads.items.len;
            if (self.timeout_pending) count += 1;
            return count;
        }

        // ── Torrent management ─────────────────────────────────

        /// Add a new torrent context to the event loop. Returns torrent_id.
        pub fn addTorrent(
            self: *Self,
            session: *const session_mod.Session,
            piece_tracker: *PieceTracker,
            shared_fds: []const posix.fd_t,
            peer_id: [20]u8,
        ) !TorrentId {
            return self.addTorrentWithKey(session, piece_tracker, shared_fds, peer_id, null, false);
        }

        /// Add a new torrent context with a tracker key. Returns torrent_id.
        pub fn addTorrentWithKey(
            self: *Self,
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

        pub fn addTorrentContext(self: *Self, tc: TorrentContext) !TorrentId {
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
        pub fn isPeerDiscoveryAllowed(self: *Self, torrent_id: TorrentId) bool {
            if (self.getTorrentContext(torrent_id)) |tc| {
                return !tc.is_private;
            }
            return true;
        }

        /// Set the complete_pieces bitfield for a torrent (enables seed mode).
        pub fn setTorrentCompletePieces(self: *Self, torrent_id: TorrentId, cp: *const Bitfield) void {
            if (self.getTorrentContext(torrent_id)) |tc| {
                tc.complete_pieces = cp;
            }
            // Also set global complete_pieces for backwards compatibility with standalone mode
            self.complete_pieces = cp;
        }

        /// Initialize the BEP 52 Merkle tree cache for a v2/hybrid torrent.
        /// Must be called after the torrent is added and has a valid session.
        /// Safe to call for v1 torrents (no-op) or multiple times (idempotent).
        pub fn initMerkleCache(self: *Self, torrent_id: TorrentId) void {
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
        pub fn ensureAccepting(self: *Self, listen_fd: posix.fd_t) !void {
            if (self.listen_fd >= 0) return;
            self.listen_fd = listen_fd;
            try self.submitAccept();
        }

        /// Count the number of active peers for a specific torrent.
        pub fn peerCountForTorrent(self: *const Self, torrent_id: TorrentId) u16 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
            return @intCast(@min(tc.peer_slots.items.len, std.math.maxInt(u16)));
        }

        /// Count peers that have moved past the half-open connection phase.
        /// Half-open slots are limited separately by `max_half_open`; counting
        /// them against the per-torrent connected-peer cap makes uTP swarms
        /// under-connect when many SYNs are in flight.
        pub fn establishedPeerCountForTorrent(self: *const Self, torrent_id: TorrentId) u16 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
            var count: u16 = 0;
            for (tc.peer_slots.items) |slot| {
                const peer = &self.peers[slot];
                if (peer.state == .free or peer.state == .connecting or peer.state == .disconnecting) continue;
                count += 1;
            }
            return count;
        }

        /// Return the current half-open (connecting) peer count.
        pub fn halfOpenCount(self: *const Self) u16 {
            return @intCast(@min(self.half_open_count, std.math.maxInt(u16)));
        }

        /// Get speed and total byte stats for a specific torrent.
        pub fn getSpeedStats(self: *const Self, torrent_id: TorrentId) SpeedStats {
            const tc = self.getTorrentContextConst(torrent_id) orelse return .{};

            return .{
                .dl_speed = tc.current_dl_speed,
                .ul_speed = tc.current_ul_speed,
                .dl_total = tc.downloaded_bytes,
                .ul_total = tc.uploaded_bytes,
            };
        }

        pub fn accountTorrentBytes(self: *Self, torrent_id: TorrentId, dl_bytes: usize, ul_bytes: usize) void {
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (dl_bytes != 0) tc.downloaded_bytes +%= @intCast(dl_bytes);
                if (ul_bytes != 0) tc.uploaded_bytes +%= @intCast(ul_bytes);
            }
        }

        /// Remove a torrent context and disconnect all its peers.
        pub fn removeTorrent(self: *Self, torrent_id: TorrentId) void {
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
                // Clean up BEP 52 peer-provided leaf hash store.
                if (tc.leaf_hashes) |lh| {
                    lh.deinit();
                    self.allocator.destroy(lh);
                    tc.leaf_hashes = null;
                }
                tc.pending_resume_durability.deinit(self.allocator);
                tc.pending_resume_durability = std.ArrayList(u32).empty;
                tc.durable_resume_pieces.deinit(self.allocator);
                tc.durable_resume_pieces = std.ArrayList(u32).empty;
                tc.peer_candidates.deinit(self.allocator);
                tc.peer_candidates = .{};
                self.unregisterTorrentHashes(tc.info_hash, tc.info_hash_v2);
            }
            self.torrents.items[torrent_id] = null;
            self.removeActiveTorrentId(torrent_id);
            self.free_torrent_ids.append(self.allocator, torrent_id) catch {};
            if (self.torrent_count > 0) self.torrent_count -= 1;
        }

        pub fn attachPeerToTorrent(self: *Self, torrent_id: TorrentId, slot: u16) void {
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

        fn detachPeerFromTorrent(self: *Self, torrent_id: TorrentId, slot: u16) void {
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
        /// prefer TCP; libtorrent/qBittorrent only choose outgoing uTP when
        /// TCP is disabled or the peer is already known to support uTP.
        pub fn selectTransport(self: *Self) Transport {
            const disp = self.transport_disposition;
            if (disp.outgoing_tcp) return .tcp;
            if (disp.outgoing_utp) return .utp;
            // Default to TCP (includes the case where neither is enabled,
            // which is a misconfiguration but safe to fall back to TCP).
            return .tcp;
        }

        fn contextDefaultOutboundSwarmHash(tc: *const TorrentContext) [20]u8 {
            if (tc.info_hash_v2) |v2_hash| {
                if (tc.session) |session| {
                    if (session.metainfo.version == .v2) return v2_hash;
                }
            }
            return tc.info_hash;
        }

        fn contextHasSwarmHash(tc: *const TorrentContext, swarm_hash: [20]u8) bool {
            if (std.mem.eql(u8, swarm_hash[0..], tc.info_hash[0..])) return true;
            if (tc.info_hash_v2) |v2_hash| {
                return std.mem.eql(u8, swarm_hash[0..], v2_hash[0..]);
            }
            return false;
        }

        fn storePeerSwarmHash(_: *const Self, peer: *Peer, swarm_hash: [20]u8) void {
            @memcpy(peer.handshake_buf[28..48], &swarm_hash);
        }

        pub fn defaultOutboundSwarmHash(self: *const Self, torrent_id: TorrentId) ![20]u8 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return error.TorrentNotFound;
            return contextDefaultOutboundSwarmHash(tc);
        }

        pub fn normalizeOutboundSwarmHash(self: *const Self, torrent_id: TorrentId, swarm_hash: [20]u8) ![20]u8 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return error.TorrentNotFound;
            if (!contextHasSwarmHash(tc, swarm_hash)) return error.InvalidSwarmHash;
            return swarm_hash;
        }

        pub fn selectedPeerSwarmHash(self: *const Self, peer: *const Peer) [20]u8 {
            var selected: [20]u8 = undefined;
            @memcpy(&selected, peer.handshake_buf[28..48]);

            const tc = self.getTorrentContextConst(peer.torrent_id) orelse return selected;
            if (contextHasSwarmHash(tc, selected)) return selected;
            return contextDefaultOutboundSwarmHash(tc);
        }

        pub fn enqueuePeerCandidate(
            self: *Self,
            address: std.net.Address,
            torrent_id: TorrentId,
            source: PeerCandidateSource,
        ) !bool {
            const swarm_hash = try self.defaultOutboundSwarmHash(torrent_id);
            return self.enqueuePeerCandidateWithSwarmHash(address, torrent_id, swarm_hash, source);
        }

        pub fn enqueuePeerCandidateWithSwarmHash(
            self: *Self,
            address: std.net.Address,
            torrent_id: TorrentId,
            swarm_hash: [20]u8,
            source: PeerCandidateSource,
        ) !bool {
            const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
            if (tc.is_private and (source == .dht or source == .pex)) {
                return error.PrivateTorrentPeerDiscoveryDisabled;
            }

            const family = address.any.family;
            if (family != posix.AF.INET and family != posix.AF.INET6) {
                return error.InvalidAddressFamily;
            }
            if (addr_mod.isSelfAnnounceEndpoint(self.bind_address, self.port, &address)) return false;
            if (self.isPeerAddressKnown(torrent_id, address)) return false;
            if (self.ban_list) |bl| {
                if (bl.isBanned(address)) return false;
            }

            const selected_hash = try self.normalizeOutboundSwarmHash(torrent_id, swarm_hash);
            return tc.peer_candidates.add(self.allocator, address, selected_hash, source, self.clock.now());
        }

        pub fn peerCandidateCount(self: *const Self, torrent_id: TorrentId) usize {
            const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
            return tc.peer_candidates.count();
        }

        fn isPeerAddressKnown(self: *const Self, torrent_id: TorrentId, addr: std.net.Address) bool {
            const tc = self.getTorrentContextConst(torrent_id) orelse return false;
            for (tc.peer_slots.items) |slot| {
                const peer = &self.peers[slot];
                if (peer.state == .free or peer.state == .disconnecting) continue;
                if (addr_mod.addressEql(&peer.address, &addr)) return true;
            }
            return false;
        }

        pub fn processPeerCandidates(self: *Self) void {
            for (self.active_torrent_ids.items) |torrent_id| {
                self.processPeerCandidatesForTorrent(torrent_id);
            }
        }

        fn processPeerCandidatesForTorrent(self: *Self, torrent_id: TorrentId) void {
            while (self.peer_count < self.max_connections and self.half_open_count < self.max_half_open) {
                if (self.establishedPeerCountForTorrent(torrent_id) >= self.max_peers_per_torrent) return;
                const now = self.clock.now();
                const candidate = blk: {
                    const tc = self.getTorrentContext(torrent_id) orelse return;
                    var idx_opt = tc.peer_candidates.nextConnectableIndex(now);
                    while (idx_opt) |idx| {
                        const entry = tc.peer_candidates.entries.items[idx];
                        if (self.isPeerAddressKnown(torrent_id, entry.address) or
                            addr_mod.isSelfAnnounceEndpoint(self.bind_address, self.port, &entry.address) or
                            (self.ban_list != null and self.ban_list.?.isBanned(entry.address)))
                        {
                            tc.peer_candidates.markAttempt(idx, now);
                            idx_opt = tc.peer_candidates.nextConnectableIndex(now);
                            continue;
                        }
                        tc.peer_candidates.markAttempt(idx, now);
                        break :blk entry;
                    }
                    return;
                };

                _ = self.addPeerAutoTransportWithSwarmHash(
                    candidate.address,
                    torrent_id,
                    candidate.swarm_hash,
                ) catch |err| switch (err) {
                    error.ConnectionLimitReached,
                    error.TorrentConnectionLimitReached,
                    error.HalfOpenLimitReached,
                    error.TooManyPeers,
                    => return,
                    else => continue,
                };
            }
        }

        /// Add a peer using the transport selected by `selectTransport()`.
        /// In mixed TCP/uTP mode this starts optimistically over uTP; setup
        /// errors and later unconfirmed-connect timeouts retry over TCP when
        /// outbound TCP is enabled by the transport disposition.
        pub fn addPeerAutoTransport(self: *Self, address: std.net.Address, torrent_id: TorrentId) !u16 {
            const swarm_hash = try self.defaultOutboundSwarmHash(torrent_id);
            return self.addPeerAutoTransportWithSwarmHash(address, torrent_id, swarm_hash);
        }

        /// Add a peer using a caller-selected 20-byte swarm hash. DHT v2
        /// lookups use this to preserve the selected v2 truncated SHA-256
        /// hash through transport selection and into the outbound handshake.
        pub fn addPeerAutoTransportWithSwarmHash(
            self: *Self,
            address: std.net.Address,
            torrent_id: TorrentId,
            swarm_hash: [20]u8,
        ) !u16 {
            const selected_hash = try self.normalizeOutboundSwarmHash(torrent_id, swarm_hash);
            const transport = self.selectTransport();
            if (transport == .utp) {
                return self.addUtpPeerWithSwarmHash(address, torrent_id, selected_hash) catch |err| switch (err) {
                    error.NoUtpManager, error.UtpConnectFailed => {
                        if (self.transport_disposition.outgoing_tcp) {
                            return self.addPeerForTorrentWithSwarmHash(address, torrent_id, selected_hash);
                        }
                        return err;
                    },
                    else => return err,
                };
            }
            return self.addPeerForTorrentWithSwarmHash(address, torrent_id, selected_hash);
        }

        pub fn addPeer(self: *Self, address: std.net.Address) !u16 {
            return self.addPeerForTorrent(address, 0);
        }

        pub fn addPeerForTorrent(self: *Self, address: std.net.Address, torrent_id: TorrentId) !u16 {
            const swarm_hash = try self.defaultOutboundSwarmHash(torrent_id);
            return self.addPeerForTorrentWithSwarmHash(address, torrent_id, swarm_hash);
        }

        pub fn addPeerForTorrentWithSwarmHash(
            self: *Self,
            address: std.net.Address,
            torrent_id: TorrentId,
            swarm_hash: [20]u8,
        ) !u16 {
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

            const selected_hash = try self.normalizeOutboundSwarmHash(torrent_id, swarm_hash);

            // Enforce global connection limit
            if (self.peer_count >= self.max_connections) {
                log.warn("global connection limit reached ({d}/{d})", .{ self.peer_count, self.max_connections });
                return error.ConnectionLimitReached;
            }

            // Enforce per-torrent established-peer limit. Half-open
            // connection attempts are governed by `max_half_open`.
            if (self.establishedPeerCountForTorrent(torrent_id) >= self.max_peers_per_torrent) {
                log.warn("per-torrent connection limit reached for torrent {d} ({d}/{d})", .{
                    torrent_id,
                    self.establishedPeerCountForTorrent(torrent_id),
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
            self.storePeerSwarmHash(peer, selected_hash);

            peer.connect_pending = true;
            self.peer_count += 1;
            self.half_open_count += 1;
            self.markActivePeer(slot);
            self.attachPeerToTorrent(torrent_id, slot);

            // Submit async socket creation via io_interface. The callback
            // (peer_handler.peerSocketCompleteFor(Self)) configures the fd
            // and chains the connect.
            self.io.socket(
                .{ .domain = family, .sock_type = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, .protocol = posix.IPPROTO.TCP },
                &peer.connect_completion,
                self,
                peer_handler.peerSocketCompleteFor(Self),
            ) catch |err| {
                self.removePeer(slot);
                return err;
            };
            return slot;
        }

        /// Register a pre-connected fd as an outbound peer for `torrent_id`.
        /// Bypasses the async socket/connect SQE chain — intended for testing
        /// with socketpairs. MSE is skipped; the peer uses plaintext BitTorrent.
        pub fn addConnectedPeer(self: *Self, fd: posix.fd_t, torrent_id: TorrentId) !u16 {
            return self.addConnectedPeerWithAddress(fd, torrent_id, null);
        }

        /// Variant of `addConnectedPeer` that lets the caller supply the peer
        /// address used for ban tracking. Sim tests that spin up many SimPeer
        /// seeders need distinct addresses so per-peer ban state doesn't bleed
        /// across peers (BanList keys on address). When `address_opt` is null,
        /// defaults to 127.0.0.1 like the original entry point.
        pub fn addConnectedPeerWithAddress(
            self: *Self,
            fd: posix.fd_t,
            torrent_id: TorrentId,
            address_opt: ?std.net.Address,
        ) !u16 {
            const swarm_hash = try self.defaultOutboundSwarmHash(torrent_id);
            return self.addConnectedPeerWithSwarmHash(fd, torrent_id, address_opt, swarm_hash);
        }

        pub fn addConnectedPeerWithSwarmHash(
            self: *Self,
            fd: posix.fd_t,
            torrent_id: TorrentId,
            address_opt: ?std.net.Address,
            swarm_hash: [20]u8,
        ) !u16 {
            const selected_hash = try self.normalizeOutboundSwarmHash(torrent_id, swarm_hash);
            if (self.peer_count >= self.max_connections) return error.ConnectionLimitReached;

            const slot = self.allocSlot() orelse return error.TooManyPeers;
            const peer = &self.peers[slot];
            peer.* = Peer{
                .fd = fd,
                .state = .connecting,
                .mode = .outbound,
                .torrent_id = torrent_id,
                .address = address_opt orelse std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0),
            };
            self.storePeerSwarmHash(peer, selected_hash);
            peer.last_activity = self.clock.now();

            self.peer_count += 1;
            self.markActivePeer(slot);
            self.attachPeerToTorrent(torrent_id, slot);
            peer_handler.sendBtHandshake(self, slot);
            return slot;
        }

        /// Register a pre-connected inbound fd for `torrent_id`. Test/sim-only
        /// shortcut around the production `accept_multishot` path: the caller
        /// (typically a `Simulator` driver) has already set up a socketpair
        /// and assigned one end to a SimPeer; this routes the other end into
        /// an EventLoop peer slot in the post-accept inbound state, ready to
        /// receive the BitTorrent handshake from the peer side.
        ///
        /// Mirrors `peer_handler.handleAccepted` but skips ban-list / drain /
        /// disposition / connection-limit checks (the caller is the sim, not
        /// the network). The torrent_id is known up front so we can attach
        /// immediately rather than wait for the handshake's info_hash match.
        pub fn addInboundPeer(
            self: *Self,
            torrent_id: TorrentId,
            fd: posix.fd_t,
            peer_addr: std.net.Address,
        ) !u16 {
            if (self.getTorrentContext(torrent_id) == null) return error.TorrentNotFound;
            if (self.peer_count >= self.max_connections) return error.ConnectionLimitReached;

            const slot = self.allocSlot() orelse return error.TooManyPeers;
            const peer = &self.peers[slot];
            peer.* = Peer{
                .fd = fd,
                .state = .inbound_handshake_recv,
                .mode = .inbound,
                .torrent_id = torrent_id,
                .address = peer_addr,
            };
            peer.handshake_offset = 0;
            peer.last_activity = self.clock.now();

            self.peer_count += 1;
            self.markActivePeer(slot);
            self.attachPeerToTorrent(torrent_id, slot);

            // Start receiving the peer's handshake. On submission failure,
            // unwind the slot so the caller doesn't see a half-formed peer.
            protocol.submitHandshakeRecv(self, slot) catch |err| {
                self.removePeer(slot);
                return err;
            };
            return slot;
        }

        /// Read-only view of a peer slot's interesting fields. Used by sim
        /// tests that assert on smart-ban / trust / piece-progress state
        /// without reaching into the private `Peer` struct.
        pub const PeerView = struct {
            address: std.net.Address,
            trust_points: i8,
            hashfails: u8,
            is_banned: bool,
            blocks_received: u32,
            bytes_downloaded: u64,
            bytes_uploaded: u64,
        };

        /// Return a snapshot of the peer at `slot`, or null if the slot is
        /// unused. `is_banned` consults the shared `BanList` if one is
        /// installed, else reports false.
        pub fn getPeerView(self: *Self, slot: u16) ?PeerView {
            if (slot >= self.peers.len) return null;
            const peer = &self.peers[slot];
            if (peer.state == .free) return null;
            const banned = if (self.ban_list) |bl| bl.isBanned(peer.address) else false;
            return .{
                .address = peer.address,
                .trust_points = peer.trust_points,
                .hashfails = peer.hashfails,
                .is_banned = banned,
                .blocks_received = peer.blocks_received,
                .bytes_downloaded = peer.bytes_downloaded_from,
                .bytes_uploaded = peer.bytes_uploaded_to,
            };
        }

        /// Returns true if the torrent's piece tracker reports this piece as
        /// complete (downloaded + verified). Returns false if the torrent
        /// doesn't exist or has no piece tracker attached.
        pub fn isPieceComplete(self: *Self, torrent_id: TorrentId, piece_index: u32) bool {
            const tc = self.getTorrentContext(torrent_id) orelse return false;
            const pt = tc.piece_tracker orelse return false;
            return pt.isPieceComplete(piece_index);
        }

        /// Sentinel value for `getBlockAttribution` entries whose block
        /// is in `.none` state (not yet requested by any peer). Tests
        /// distinguish unattributed blocks from real slot indices via
        /// this value rather than `0`, since slot 0 is a valid peer.
        pub const attribution_unset: u16 = std.math.maxInt(u16);

        /// Snapshot per-block peer attribution for the active download
        /// of `piece_index` in `torrent_id`. Each entry in the returned
        /// slice is the slot that requested or delivered the
        /// corresponding block (or `attribution_unset` for `.none`-
        /// state blocks). Returns null if the torrent has no active
        /// `DownloadingPiece` for this piece (e.g. the piece is
        /// complete, has been abandoned, or hasn't been claimed yet).
        ///
        /// Caller-allocated `out` buffer must be at least
        /// `dp.blocks_total` long; the returned slice is a sub-slice
        /// of `out`. Caller-buffered to avoid heap allocation in the
        /// hot test loop and to let the test hold the snapshot across
        /// ticks even after the underlying DP is destroyed (e.g. piece
        /// completed, attribution copied into smart-ban records).
        ///
        /// Test-only API. Slot indices are stable across `removePeer`
        /// (peer.state goes `.free` until `allocSlot` reuses), which
        /// gives tests precise mid-tick attribution observability.
        /// Resolve slot → address via `getPeerView(slot).?.address` if
        /// the test wants to compare against `BanList.isBanned`.
        pub fn getBlockAttribution(
            self: *Self,
            torrent_id: TorrentId,
            piece_index: u32,
            out: []u16,
        ) ?[]const u16 {
            const key = DownloadingPieceKey{
                .torrent_id = torrent_id,
                .piece_index = piece_index,
            };
            const dp = self.downloading_pieces.get(key) orelse return null;
            if (out.len < dp.block_infos.len) return null;
            for (dp.block_infos, 0..) |bi, i| {
                out[i] = if (bi.state == .none) attribution_unset else bi.peer_slot;
            }
            return out[0..dp.block_infos.len];
        }

        /// Initiate an outbound uTP connection to a peer. Creates the uTP
        /// socket via the UtpManager, sends the SYN packet, and allocates a
        /// peer slot in the event loop.
        pub fn addUtpPeer(self: *Self, address: std.net.Address, torrent_id: TorrentId) !u16 {
            const swarm_hash = try self.defaultOutboundSwarmHash(torrent_id);
            return self.addUtpPeerWithSwarmHash(address, torrent_id, swarm_hash);
        }

        pub fn addUtpPeerWithSwarmHash(
            self: *Self,
            address: std.net.Address,
            torrent_id: TorrentId,
            swarm_hash: [20]u8,
        ) !u16 {
            // Reject new outbound connections during graceful shutdown drain
            if (self.draining) return error.ShuttingDown;
            const selected_hash = try self.normalizeOutboundSwarmHash(torrent_id, swarm_hash);

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
            if (self.establishedPeerCountForTorrent(torrent_id) >= self.max_peers_per_torrent) {
                return error.TorrentConnectionLimitReached;
            }
            if (self.half_open_count >= self.max_half_open) {
                return error.HalfOpenLimitReached;
            }

            const now_us = self.clock.nowUs32();
            const conn = mgr.connect(&self.random, address, now_us) catch |err| {
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
            self.storePeerSwarmHash(peer, selected_hash);
            self.peer_count += 1;
            self.half_open_count += 1;
            self.markActivePeer(peer_slot);
            self.attachPeerToTorrent(torrent_id, peer_slot);

            // Send the SYN packet via the UDP socket.
            utp_handler.utpSendPacket(self, &conn.syn_packet, address);

            log.info("initiating outbound uTP connection to {f}", .{address});
            return peer_slot;
        }

        /// Start accepting inbound connections for seeding.
        pub fn startAccepting(self: *Self, listen_fd: posix.fd_t, complete_pieces: *const Bitfield) !void {
            self.listen_fd = listen_fd;
            self.complete_pieces = complete_pieces;
            try self.submitAccept();
        }

        /// Start listening for inbound uTP/DHT connections on a UDP socket.
        /// Creates a dual-stack IPv6 UDP socket (handles IPv4-mapped addresses too),
        /// binds to the daemon's listen port, initializes the UtpManager, and
        /// submits the first RECVMSG.
        pub fn startUtpListener(self: *Self) !void {
            if (self.udp_fd >= 0) return; // already listening

            // Create a dual-stack IPv6 UDP socket. When IPV6_V6ONLY is 0, the
            // kernel also accepts IPv4 connections via IPv4-mapped addresses.
            const fd = try posix.socket(
                posix.AF.INET6,
                posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
                posix.IPPROTO.UDP,
            );
            errdefer posix.close(fd);

            // Allow address reuse. Routes through `IORING_OP_URING_CMD`
            // + `SOCKET_URING_OP_SETSOCKOPT` on kernel ≥6.7
            // (`feature_support.supports_setsockopt == true`); sync
            // `posix.setsockopt(2)` fallback otherwise. Best-effort —
            // log on failure but proceed (matching prior behaviour).
            const reuse_one = std.mem.toBytes(@as(c_int, 1));
            io_interface.setsockoptBlocking(&self.io, .{
                .fd = fd,
                .level = posix.SOL.SOCKET,
                .optname = posix.SO.REUSEADDR,
                .optval = &reuse_one,
            }) catch {};

            // Disable IPV6_V6ONLY so IPv4 connections arrive as IPv4-mapped addresses.
            const v6only_zero = std.mem.toBytes(@as(c_int, 0));
            io_interface.setsockoptBlocking(&self.io, .{
                .fd = fd,
                .level = linux.IPPROTO.IPV6,
                .optname = linux.IPV6.V6ONLY,
                .optval = &v6only_zero,
            }) catch {};

            // uTP and DHT share this UDP socket. The Linux default receive
            // buffer (~208 KiB on many systems) drops packets under public
            // swarm fan-in well before the daemon saturates the link. Ask for
            // a larger buffer; the kernel may cap it at net.core.rmem_max.
            const recv_buf_bytes = std.mem.toBytes(@as(c_int, 8 * 1024 * 1024));
            io_interface.setsockoptBlocking(&self.io, .{
                .fd = fd,
                .level = posix.SOL.SOCKET,
                .optname = posix.SO.RCVBUF,
                .optval = &recv_buf_bytes,
            }) catch |err| {
                log.warn("UDP socket SO_RCVBUF failed: {s}", .{@errorName(err)});
            };

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
            // Routes through `IORING_OP_BIND` on kernel ≥6.11
            // (`feature_support.supports_bind == true`); on older
            // kernels the contract method falls back to `posix.bind(2)`
            // inline. See `io_interface.bindBlocking`.
            try io_interface.bindBlocking(&self.io, .{ .fd = fd, .addr = bind_addr });

            self.udp_fd = fd;

            // Initialize UtpManager
            const mgr = try self.allocator.create(utp_mgr.UtpManager);
            mgr.* = try utp_mgr.UtpManager.initWithSettings(
                self.allocator,
                self.utp_settings,
                self.utp_preallocate_packet_pool,
            );
            self.utp_manager = mgr;

            // Keep multiple RECVMSG SQEs posted so the shared DHT/uTP UDP
            // socket can drain public-swarm bursts without serializing each
            // datagram on a fresh submit/complete cycle.
            try utp_handler.submitInitialUtpRecvs(self);
            log.info("uTP listener started on UDP port {d}", .{self.port});
        }

        /// Stop the UDP listener (uTP/DHT). Closing the fd completes pending
        /// RECVMSG/SENDMSG SQEs with errors; setting udp_fd = -1 immediately
        /// ensures callbacks do not re-arm receives.
        pub fn stopUtpListener(self: *Self) void {
            if (self.udp_fd < 0) return;
            const fd = self.udp_fd;
            self.udp_fd = -1;

            posix.close(fd);

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
        pub fn startTcpListener(self: *Self) !void {
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
            io_interface.setsockoptBlocking(&self.io, .{
                .fd = fd,
                .level = posix.SOL.SOCKET,
                .optname = posix.SO.REUSEADDR,
                .optval = std.mem.asBytes(&one),
            }) catch {};

            if (self.bind_device) |device| {
                try socket_util.applyBindDevice(fd, device);
            }

            // Routes through io_uring on kernel ≥6.11; sync fallback
            // otherwise. See `io_interface.bindBlocking`.
            try io_interface.bindBlocking(&self.io, .{ .fd = fd, .addr = addr });
            try io_interface.listenBlocking(&self.io, .{ .fd = fd, .backlog = 128 });

            self.listen_fd = fd;
            try self.submitAccept();
            log.info("TCP listener started on port {d}", .{self.port});
        }

        /// Stop the TCP listener. Cancels the pending multishot ACCEPT,
        /// then closes the listen socket via io_uring. Setting listen_fd = -1
        /// immediately ensures the dispatch loop ignores stale CQEs.
        pub fn stopTcpListener(self: *Self) void {
            if (self.listen_fd < 0) return;
            const fd = self.listen_fd;
            self.listen_fd = -1;

            // Cancel the in-flight multishot accept on the io_interface ring.
            self.io.cancel(
                .{ .target = &self.accept_completion },
                &self.accept_cancel_completion,
                null,
                ignoredCancelComplete,
            ) catch {};
            posix.close(fd);

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
        pub fn reconcileListeners(self: *Self) void {
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
                } else if (disp.toEnableUtp()) {
                    if (self.utp_manager) |mgr| {
                        mgr.ensurePacketPoolPreallocated() catch |err| {
                            log.warn("failed to preallocate uTP packet pool on transport change: {s}", .{@errorName(err)});
                        };
                    }
                }
            } else {
                self.stopUtpListener();
            }
        }

        pub fn removePeer(self: *Self, slot: u16) void {
            const peer = &self.peers[slot];
            if (peer.state == .disconnecting) return;
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
            peer_policy.detachPeerFromPrefetchPieces(self, peer);
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

            // Free any tracked send buffers before closing the fd. Ghost
            // PendingSends stay claimed until their CQEs arrive.
            self.freeAllPendingSends(slot);

            const torrent_id = peer.torrent_id;
            const embedded_completions = peerEmbeddedCompletionCount(peer);
            if (embedded_completions > 0) {
                const fd = peer.fd;
                const transport = peer.transport;
                peer.state = .disconnecting;
                peer.disconnecting_completions = embedded_completions;
                if (fd >= 0) {
                    if (transport == .tcp) {
                        self.shutdownPeerFd(fd);
                    }
                    peer.fd = -1;
                    self.io.closeSocket(fd);
                }
            } else {
                self.cleanupPeer(peer);
                peer.* = Peer{};
            }
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

        fn peerEmbeddedCompletionCount(peer: *const Peer) u8 {
            var count: u8 = 0;
            if (peer.connect_pending) count += 1;
            if (peer.recv_pending) count += 1;
            if (peer.untracked_send_pending) count += 1;
            return count;
        }

        pub fn completeDisconnectingPeerCompletion(self: *Self, slot: u16) void {
            const peer = &self.peers[slot];
            if (peer.state != .disconnecting) return;
            if (peer.disconnecting_completions > 0) {
                peer.disconnecting_completions -= 1;
            }
            if (peer.disconnecting_completions != 0) return;

            self.cleanupPeer(peer);
            peer.* = Peer{};
        }

        // ── Run loop ───────────────────────────────────────────

        pub fn run(self: *Self) !void {
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

        pub fn tick(self: *Self) !void {
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
            self.processPeerCandidates();
            if (self.http_executor) |he| he.tick();
            if (self.udp_tracker_executor) |ute| ute.tick();

            // Block on the io_interface ring — every active op type lives
            // there (peer recv/send/connect/socket, accept, disk r/w,
            // timer, signal poll, HTTP/RPC/metadata/uTP/UDP tracker).
            // Callbacks fire from inside the tick.
            self.io.tick(1) catch |err| {
                log.warn("io tick (wait): {s}", .{@errorName(err)});
            };

            // Batch-send any queued piece block responses
            seed_handler.flushQueuedResponses(self);

            // Drain any io_interface CQEs that were produced by callbacks
            // re-arming during the dispatch above (e.g. submitHeaderRecv
            // chained from a body-recv callback).
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
        pub fn hasPendingTransferWork(self: *Self) bool {
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
        pub fn submitTimeout(self: *Self, timeout_ns: u64) !void {
            if (self.timeout_pending) return; // previous timeout still in flight
            try self.io.timeout(
                .{ .ns = timeout_ns },
                &self.wake_timeout_completion,
                self,
                wakeTimeoutComplete,
            );
            self.timeout_pending = true;
        }

        fn wakeTimeoutComplete(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            _: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            self.timeout_pending = false;
            return .disarm;
        }

        // ── io.timeout-based one-shot timers ────────────────────

        /// Schedule a one-shot timer that fires `delay_ms` milliseconds from now.
        /// When the timer fires, `callback(context)` is invoked from the event
        /// loop thread during CQE dispatch.
        pub fn scheduleTimer(self: *Self, delay_ms: u64, context: *anyopaque, callback: *const fn (*anyopaque) void) !void {
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
        fn armNextTimer(self: *Self) void {
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
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            self.timer_pending = false;
            self.fireExpiredTimers();
            return .disarm;
        }

        /// Fire all timer callbacks whose deadline has passed, then re-arm
        /// for the next pending timer (if any).
        fn fireExpiredTimers(self: *Self) void {
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

        pub fn stop(self: *Self) void {
            self.running = false;
        }

        // ── Per-torrent durability sync ──────────────────────────

        /// Per-submission tracking for an in-flight `submitTorrentSync`.
        /// Heap-allocated when the sweep starts; freed when the last
        /// fsync CQE lands. The completions slab lives alongside so a
        /// single allocation pair drops at the end.
        ///
        /// Why a heap-allocated context instead of a stack one: the
        /// callback can fire long after the submitter returns (we don't
        /// block on `io.tick` like `PieceStore.sync` does), so the ctx
        /// must outlive the call frame.
        const TorrentSyncCtx = struct {
            el: *Self,
            torrent_id: TorrentId,
            pending: u32,
            /// Snapshot of `dirty_writes_since_sync` at submit time. On
            /// successful drain we subtract this (saturating at 0)
            /// rather than zeroing — writes that completed *during*
            /// the fsync sweep are still un-fsync'd and should remain
            /// dirty for the next sync sweep to flush.
            dirty_snapshot: u32,
            /// Number of pending resume-completion pieces covered by this
            /// sweep. Pieces appended after submission remain pending.
            pending_resume_snapshot_len: usize,
            /// First fsync error seen across the sweep, surfaced via
            /// log only — the daemon has no good recovery path beyond
            /// "try again next sync interval".
            first_error: ?anyerror = null,
            completions: []io_interface.Completion,
        };

        /// Submit one async fsync per open file in `tc.shared_fds` for
        /// the given torrent, datasync mode (skip metadata, like the
        /// existing `PieceStore.sync` shape). The sweep is fire-and-
        /// forget at the call-site level: the per-fsync CQEs land later
        /// and the last one frees the heap-allocated context, clears
        /// `tc.sync_in_flight`, and decrements `dirty_writes_since_sync`
        /// by the snapshotted count.
        ///
        /// Idempotent: if a sweep is already in flight for this torrent
        /// (`tc.sync_in_flight`), returns immediately so periodic timer
        /// + completion-hook + shutdown drain don't pile parallel
        /// fsyncs on the same fds. Also returns if `dirty_writes_since_sync`
        /// is zero (nothing to flush).
        ///
        /// Caller may pass `force_even_if_clean = true` to fsync regardless
        /// of dirty count — used by the shutdown drain so a clean torrent
        /// still flushes any earlier-session pagecache before exit.
        pub fn submitTorrentSync(
            self: *Self,
            torrent_id: TorrentId,
            force_even_if_clean: bool,
        ) void {
            const tc = self.getTorrentContext(torrent_id) orelse return;
            if (tc.sync_in_flight) return;
            if (!force_even_if_clean and tc.dirty_writes_since_sync == 0) return;

            // Count non-skipped fds (do_not_download files have fd == -1).
            var open_count: u32 = 0;
            for (tc.shared_fds) |fd| {
                if (fd >= 0) open_count += 1;
            }
            if (open_count == 0) return;

            const completions = self.allocator.alignedAlloc(
                io_interface.Completion,
                .of(io_interface.Completion),
                open_count,
            ) catch |err| {
                log.warn("torrent {d} sync alloc completions: {s}", .{ torrent_id, @errorName(err) });
                return;
            };
            @memset(completions, .{});

            const ctx = self.allocator.create(TorrentSyncCtx) catch |err| {
                log.warn("torrent {d} sync alloc ctx: {s}", .{ torrent_id, @errorName(err) });
                self.allocator.free(completions);
                return;
            };
            ctx.* = .{
                .el = self,
                .torrent_id = torrent_id,
                .pending = open_count,
                .dirty_snapshot = tc.dirty_writes_since_sync,
                .pending_resume_snapshot_len = tc.pending_resume_durability.items.len,
                .completions = completions,
            };
            tc.sync_in_flight = true;

            var i: usize = 0;
            for (tc.shared_fds) |fd| {
                if (fd < 0) continue;
                self.io.fsync(
                    .{ .fd = fd, .datasync = true },
                    &completions[i],
                    ctx,
                    torrentSyncCallback,
                ) catch |err| {
                    log.warn("torrent {d} fsync submit fd={d}: {s}", .{ torrent_id, fd, @errorName(err) });
                    if (ctx.first_error == null) ctx.first_error = err;
                    ctx.pending -= 1;
                };
                i += 1;
            }

            // If every submit failed before arming any completion, the
            // pending counter is already at 0 — clean up here since the
            // callback will never fire.
            if (ctx.pending == 0) {
                tc.sync_in_flight = false;
                self.allocator.free(ctx.completions);
                self.allocator.destroy(ctx);
            }
        }

        fn torrentSyncCallback(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const ctx: *TorrentSyncCtx = @ptrCast(@alignCast(userdata.?));
            std.debug.assert(ctx.pending > 0);
            ctx.pending -= 1;
            switch (result) {
                .fsync => |r| _ = r catch |err| {
                    if (ctx.first_error == null) ctx.first_error = err;
                    log.warn("torrent {d} fsync CQE: {s}", .{ ctx.torrent_id, @errorName(err) });
                },
                else => {
                    // Defensive: an unexpected result variant means a
                    // backend mis-routed our completion. Log and
                    // continue draining so we don't deadlock the ctx
                    // refcount.
                    log.warn("torrent {d} sync: unexpected result variant", .{ctx.torrent_id});
                },
            }

            if (ctx.pending == 0) {
                if (ctx.el.getTorrentContext(ctx.torrent_id)) |tc| {
                    tc.sync_in_flight = false;
                    if (ctx.first_error == null) {
                        if (ctx.pending_resume_snapshot_len > 0) {
                            const ready_count = @min(
                                ctx.pending_resume_snapshot_len,
                                tc.pending_resume_durability.items.len,
                            );
                            const ready = tc.pending_resume_durability.items[0..ready_count];
                            tc.durable_resume_pieces.appendSlice(ctx.el.allocator, ready) catch |err| {
                                ctx.first_error = err;
                                log.warn("torrent {d} durable resume queue append: {s}", .{
                                    ctx.torrent_id,
                                    @errorName(err),
                                });
                            };
                            if (ctx.first_error == null) {
                                std.mem.copyForwards(
                                    u32,
                                    tc.pending_resume_durability.items[0 .. tc.pending_resume_durability.items.len - ready_count],
                                    tc.pending_resume_durability.items[ready_count..],
                                );
                                tc.pending_resume_durability.shrinkRetainingCapacity(
                                    tc.pending_resume_durability.items.len - ready_count,
                                );
                            }
                        }
                    }
                    if (ctx.first_error == null) {
                        // Saturating subtract: any writes that completed
                        // during the sweep stay dirty for the next pass.
                        tc.dirty_writes_since_sync -|= ctx.dirty_snapshot;
                    }
                    // On error: leave dirty count untouched so the next
                    // periodic sync retries.
                }
                ctx.el.allocator.free(ctx.completions);
                ctx.el.allocator.destroy(ctx);
            }
            return .disarm;
        }

        pub fn markPieceAwaitingDurability(
            self: *Self,
            torrent_id: TorrentId,
            piece_index: u32,
        ) !void {
            const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
            tc.dirty_writes_since_sync +|= 1;
            try tc.pending_resume_durability.append(self.allocator, piece_index);
        }

        pub fn markPieceDurableForResume(
            self: *Self,
            torrent_id: TorrentId,
            piece_index: u32,
        ) !void {
            const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
            try tc.durable_resume_pieces.append(self.allocator, piece_index);
        }

        pub fn drainDurableResumePieces(
            self: *Self,
            torrent_id: TorrentId,
            allocator: std.mem.Allocator,
            out: *std.ArrayList(u32),
        ) !void {
            const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
            if (tc.durable_resume_pieces.items.len == 0) return;
            try out.appendSlice(allocator, tc.durable_resume_pieces.items);
            tc.durable_resume_pieces.clearRetainingCapacity();
        }

        /// Schedule the periodic torrent-sync sweep. Self-rescheduling:
        /// each fire iterates every torrent and submits a sync sweep
        /// for those with `dirty_writes_since_sync > 0`, then re-arms
        /// the timer. Idempotent — repeated calls don't stack timers
        /// thanks to the `sync_timer_armed` flag.
        ///
        /// Called once from the daemon's startup path after the
        /// EventLoop is fully wired. Stops re-arming itself when the
        /// loop enters drain (`self.draining = true`); the shutdown
        /// path runs its own final sync sweep through `submitTorrentSync`.
        pub fn startPeriodicSync(self: *Self) void {
            if (self.sync_timer_armed) return;
            self.armPeriodicSync();
        }

        fn armPeriodicSync(self: *Self) void {
            if (self.draining) return;
            self.scheduleTimer(self.sync_timer_interval_ms, self, periodicSyncFire) catch |err| {
                log.warn("periodic sync arm failed: {s}", .{@errorName(err)});
                self.sync_timer_armed = false;
                return;
            };
            self.sync_timer_armed = true;
        }

        fn periodicSyncFire(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.sync_timer_armed = false;

            // Stop self-rearming once we're draining — the shutdown path
            // submits its own sync sweep that includes every dirty torrent.
            if (self.draining) return;

            for (self.torrents.items, 0..) |maybe_tc, idx| {
                if (maybe_tc) |tc| {
                    if (tc.active and tc.dirty_writes_since_sync > 0 and !tc.sync_in_flight) {
                        self.submitTorrentSync(@intCast(idx), false);
                    }
                }
            }

            // Re-arm for the next interval.
            self.armPeriodicSync();
        }

        /// Submit a sync sweep for every torrent. Used by the shutdown
        /// drain path so any pieces that landed in the pagecache during
        /// the session reach disk before fds close. Returns the number
        /// of sweeps submitted so the caller can decide whether to tick
        /// the ring waiting for completions.
        pub fn submitShutdownSync(self: *Self) u32 {
            var submitted: u32 = 0;
            for (self.torrents.items, 0..) |maybe_tc, idx| {
                if (maybe_tc) |tc| {
                    if (tc.dirty_writes_since_sync > 0 and !tc.sync_in_flight) {
                        self.submitTorrentSync(@intCast(idx), false);
                        submitted += 1;
                    }
                }
            }
            return submitted;
        }

        /// True iff any torrent has an in-flight sync sweep. Used by
        /// `deinit` to drain shutdown syncs before closing fds.
        pub fn anySyncInFlight(self: *const Self) bool {
            for (self.torrents.items) |maybe_tc| {
                if (maybe_tc) |tc| {
                    if (tc.sync_in_flight) return true;
                }
            }
            return false;
        }

        /// Process completed hash results from the background hasher.
        /// Public wrapper for external callers (e.g. torrent_session).
        pub fn processHashResults(self: *Self) void {
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
            self: *Self,
            session: *const @import("../torrent/session.zig").Session,
            fds: []const posix.fd_t,
            torrent_id: TorrentId,
            known_complete: ?*const Bitfield,
            on_complete: ?*const fn (*AsyncRecheck) void,
            caller_ctx: ?*anyopaque,
        ) !void {
            const h = self.hasher orelse return error.NoHasher;

            const rc = try AsyncRecheck.create(
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
        pub fn cancelRecheckForTorrent(self: *Self, torrent_id: TorrentId) void {
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
        pub fn cancelAllRechecks(self: *Self) void {
            for (self.rechecks.items) |rc| {
                rc.destroy();
            }
            self.rechecks.deinit(self.allocator);
            self.rechecks = std.ArrayList(*AsyncRecheck).empty;
        }

        // ── Async metadata fetch ─────────────────────────────

        /// Start an async BEP 9 metadata fetch for a magnet link.
        /// The on_complete callback fires when metadata is available or all peers fail.
        ///
        /// On first call, the worst-case-sized assembly buffer
        /// (`max_metadata_size` bytes) and `received` array are
        /// allocated and retained for the lifetime of the EventLoop.
        /// All subsequent fetches reuse these slices, eliminating the
        /// per-fetch heap alloc that the original BEP 9 path
        /// performed inside `MetadataAssembler.setSize`. BEP 9 admits
        /// at most one in-flight metadata fetch per torrent; this code
        /// further serialises across torrents via the
        /// `metadata_fetch != null` gate, so a single shared buffer is
        /// always sufficient.
        pub fn startMetadataFetch(
            self: *Self,
            info_hash: [20]u8,
            peer_id: [20]u8,
            port: u16,
            is_private: bool,
            peers: []const std.net.Address,
            on_complete: ?*const fn (*AsyncMetadataFetch) void,
            caller_ctx: ?*anyopaque,
        ) !void {
            if (self.metadata_fetch != null) return error.MetadataFetchAlreadyActive;

            // Lazy first-use allocation of the shared assembly storage.
            // Subsequent fetches reuse these slices.
            if (self.metadata_assembly_buffer == null) {
                const ut = @import("../net/ut_metadata.zig");
                const buf = try self.allocator.alloc(u8, ut.max_metadata_size);
                errdefer self.allocator.free(buf);
                const recv = try self.allocator.alloc(bool, ut.max_piece_count);
                self.metadata_assembly_buffer = buf;
                self.metadata_assembly_received = recv;
            }

            self.metadata_fetch = try AsyncMetadataFetch.create(
                self.allocator,
                &self.io,
                info_hash,
                peer_id,
                port,
                is_private,
                peers,
                on_complete,
                caller_ctx,
                self.metadata_assembly_buffer,
                self.metadata_assembly_received,
            );
            self.metadata_fetch.?.start();
        }

        /// Cancel and destroy an active metadata fetch. Safe to call if none is active.
        pub fn cancelMetadataFetch(self: *Self) void {
            if (self.metadata_fetch) |mf| {
                mf.destroy();
                self.metadata_fetch = null;
            }
        }

        // ── Peer banning ────────────────────────────────────

        /// Scan all connected peers and disconnect any that are banned.
        /// Called from tick() when the ban_list_dirty flag is set.
        pub fn enforceBans(self: *Self) void {
            const bl = self.ban_list orelse return;
            for (self.peers, 0..) |*peer, i| {
                if (peer.state == .free) continue;
                if (bl.isBanned(peer.address)) {
                    log.info("disconnecting banned peer: {f}", .{peer.address});
                    self.removePeer(@intCast(i));
                }
            }
        }

        // ── Rate limiting ────────────────────────────────────

        /// Set global download rate limit (bytes/sec). 0 = unlimited.
        pub fn setGlobalDlLimit(self: *Self, rate: u64) void {
            self.global_rate_limiter.setDownloadRate(rate, self.clock.nowNs());
        }

        /// Set global upload rate limit (bytes/sec). 0 = unlimited.
        pub fn setGlobalUlLimit(self: *Self, rate: u64) void {
            self.global_rate_limiter.setUploadRate(rate, self.clock.nowNs());
        }

        /// Get global download rate limit (bytes/sec). 0 = unlimited.
        pub fn getGlobalDlLimit(self: *const Self) u64 {
            return self.global_rate_limiter.download.rate;
        }

        /// Get global upload rate limit (bytes/sec). 0 = unlimited.
        pub fn getGlobalUlLimit(self: *const Self) u64 {
            return self.global_rate_limiter.upload.rate;
        }

        /// Get the number of nodes in the DHT routing table.
        /// Returns 0 if DHT is not enabled.
        pub fn getDhtNodeCount(self: *const Self) usize {
            if (self.dht_engine) |engine| {
                return engine.table.nodeCount();
            }
            return 0;
        }

        /// Set per-torrent download rate limit (bytes/sec). 0 = unlimited.
        pub fn setTorrentDlLimit(self: *Self, torrent_id: TorrentId, rate: u64) void {
            if (self.getTorrentContext(torrent_id)) |tc| {
                tc.rate_limiter.setDownloadRate(rate, self.clock.nowNs());
            }
        }

        /// Set per-torrent upload rate limit (bytes/sec). 0 = unlimited.
        pub fn setTorrentUlLimit(self: *Self, torrent_id: TorrentId, rate: u64) void {
            if (self.getTorrentContext(torrent_id)) |tc| {
                tc.rate_limiter.setUploadRate(rate, self.clock.nowNs());
            }
        }

        /// Get per-torrent download rate limit (bytes/sec). 0 = unlimited.
        pub fn getTorrentDlLimit(self: *const Self, torrent_id: TorrentId) u64 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
            return tc.rate_limiter.download.rate;
        }

        /// Get per-torrent upload rate limit (bytes/sec). 0 = unlimited.
        pub fn getTorrentUlLimit(self: *const Self, torrent_id: TorrentId) u64 {
            const tc = self.getTorrentContextConst(torrent_id) orelse return 0;
            return tc.rate_limiter.upload.rate;
        }

        /// Enable BEP 16 super-seeding for a torrent. The seeder will send
        /// individual HAVE messages instead of a full bitfield, tracking
        /// which pieces each peer has seen to maximize piece diversity.
        pub fn enableSuperSeed(self: *Self, torrent_id: TorrentId) !void {
            const tc = self.getTorrentContext(torrent_id) orelse return error.TorrentNotFound;
            if (tc.super_seed != null) return; // already enabled
            const sess = tc.session orelse return error.NoSession;

            const ss = try self.allocator.create(SuperSeedState);
            ss.* = try SuperSeedState.init(self.allocator, try sess.metainfo.pieceCount());
            tc.super_seed = ss;
        }

        /// Disable BEP 16 super-seeding for a torrent.
        pub fn disableSuperSeed(self: *Self, torrent_id: TorrentId) void {
            const tc = self.getTorrentContext(torrent_id) orelse return;
            if (tc.super_seed) |ss| {
                ss.deinit();
                self.allocator.destroy(ss);
                tc.super_seed = null;
            }
        }

        /// Check if super-seeding is enabled for a torrent.
        pub fn isSuperSeedEnabled(self: *const Self, torrent_id: TorrentId) bool {
            const tc = self.getTorrentContextConst(torrent_id) orelse return false;
            return tc.super_seed != null;
        }

        /// Configure the huge page piece cache. Call after init, before tick.
        /// `capacity` is the desired cache size in bytes (0 = default 64 MB).
        pub fn initHugePageCache(self: *Self, capacity: u64) void {
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
        pub fn consumeDownloadTokens(self: *Self, torrent_id: TorrentId, amount: u64) u64 {
            const now_ns = self.clock.nowNs();
            // Check per-torrent limit first
            var allowed = amount;
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (tc.rate_limiter.download.isActive()) {
                    allowed = tc.rate_limiter.download.consumeAt(allowed, now_ns);
                    if (allowed == 0) return 0;
                }
            }
            // Then check global limit
            if (self.global_rate_limiter.download.isActive()) {
                allowed = self.global_rate_limiter.download.consumeAt(allowed, now_ns);
            }
            return allowed;
        }

        /// Check if an upload of `amount` bytes is allowed by both per-torrent
        /// and global rate limiters. Returns the number of bytes allowed.
        pub fn consumeUploadTokens(self: *Self, torrent_id: TorrentId, amount: u64) u64 {
            const now_ns = self.clock.nowNs();
            var allowed = amount;
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (tc.rate_limiter.upload.isActive()) {
                    allowed = tc.rate_limiter.upload.consumeAt(allowed, now_ns);
                    if (allowed == 0) return 0;
                }
            }
            if (self.global_rate_limiter.upload.isActive()) {
                allowed = self.global_rate_limiter.upload.consumeAt(allowed, now_ns);
            }
            return allowed;
        }

        /// Check if download is currently throttled for a torrent.
        pub fn isDownloadThrottled(self: *Self, torrent_id: TorrentId) bool {
            const now_ns = self.clock.nowNs();
            if (self.global_rate_limiter.download.isActive()) {
                if (self.global_rate_limiter.download.availableAt(now_ns) == 0) return true;
            }
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (tc.rate_limiter.download.isActive()) {
                    if (tc.rate_limiter.download.availableAt(now_ns) == 0) return true;
                }
            }
            return false;
        }

        /// Check if upload is currently throttled for a torrent.
        pub fn isUploadThrottled(self: *Self, torrent_id: TorrentId) bool {
            const now_ns = self.clock.nowNs();
            if (self.global_rate_limiter.upload.isActive()) {
                if (self.global_rate_limiter.upload.availableAt(now_ns) == 0) return true;
            }
            if (self.getTorrentContext(torrent_id)) |tc| {
                if (tc.rate_limiter.upload.isActive()) {
                    if (tc.rate_limiter.upload.availableAt(now_ns) == 0) return true;
                }
            }
            return false;
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
        pub fn markIdle(self: *Self, slot: u16) void {
            const peer = &self.peers[slot];
            if (!isIdleCandidate(peer)) return;
            if (peer.idle_peer_index != null) return;

            // Try to claim a piece and start the download immediately rather than
            // waiting for the next tick's processIdlePeers pass.
            const policy = @import("peer_policy.zig");
            if (self.getTorrentContext(peer.torrent_id)) |tc| {
                if (!tc.upload_only and !self.isDownloadThrottled(peer.torrent_id)) {
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
                    // If no fresh piece is claimable, join an in-flight piece
                    // as a fallback. This preserves multi-source assembly for
                    // scarce pieces without crowding every idle peer onto work
                    // that could instead proceed independently.
                    if (policy.tryJoinExistingPiece(self, slot, peer)) {
                        return; // joined existing download; don't add to idle queue
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
        pub fn unmarkIdle(self: *Self, slot: u16) void {
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

        pub fn markActivePeer(self: *Self, slot: u16) void {
            const peer = &self.peers[slot];
            if (peer.active_peer_index != null) return;
            const idx: u16 = @intCast(self.active_peer_slots.items.len);
            self.active_peer_slots.append(self.allocator, slot) catch |err| {
                log.debug("active_peer_slots append for slot {d}: {s}", .{ slot, @errorName(err) });
                return;
            };
            peer.active_peer_index = idx;
        }

        pub fn unmarkActivePeer(self: *Self, slot: u16) void {
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

        pub fn submitAccept(self: *Self) !void {
            if (self.listen_fd < 0) return;
            try self.io.accept(
                .{ .fd = self.listen_fd, .multishot = true },
                &self.accept_completion,
                self,
                peer_handler.peerAcceptCompleteFor(Self),
            );
        }

        pub fn createPieceBuffer(self: *Self, size: usize) !*PieceBuffer {
            return self.piece_buffer_pool.acquire(self.allocator, if (self.huge_page_cache) |*hpc| hpc else null, size);
        }

        pub fn acquireVectoredSendState(self: *Self, batch_len: usize) !*VectoredSendState {
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

        pub fn retainPieceBuffer(self: *Self, piece_buffer: *PieceBuffer) void {
            _ = self;
            piece_buffer.ref_count += 1;
        }

        pub fn releasePieceBuffer(self: *Self, piece_buffer: *PieceBuffer) void {
            std.debug.assert(piece_buffer.ref_count > 0);
            piece_buffer.ref_count -= 1;
            if (piece_buffer.ref_count != 0) return;

            self.piece_buffer_pool.release(self.allocator, if (self.huge_page_cache) |*hpc| hpc else null, piece_buffer);
        }

        /// Allocate a unique send_id for a new PendingSend.
        /// `send_id` is never 0; legacy callers used context=0 to mean
        /// "untracked send", a distinction now expressed as
        /// `Peer.send_completion` vs a heap-allocated `PendingSend`.
        pub fn nextSendId(self: *Self) u32 {
            const id = self.next_send_id;
            self.next_send_id +%= 1;
            if (self.next_send_id == 0) self.next_send_id = 1;
            return id;
        }

        pub const PartialSendResult = enum {
            resubmitted,
            complete,
            failed,
        };

        /// Handle partial send for a tracked PendingSend: re-submit remaining bytes
        /// via the io_interface backend on the same completion.
        pub fn handlePartialSend(self: *Self, ps: *PendingSend, bytes_sent: usize) PartialSendResult {
            ps.sent += bytes_sent;
            switch (ps.storage) {
                .owned => |owned| {
                    if (ps.sent < owned.buf.len) {
                        const remaining = owned.buf[ps.sent..];
                        self.io.send(
                            .{ .fd = self.peers[ps.slot].fd, .buf = remaining },
                            &ps.completion,
                            self,
                            peer_handler.pendingSendCompleteFor(Self),
                        ) catch {
                            return .failed;
                        };
                        self.peers[ps.slot].send_pending = true;
                        return .resubmitted;
                    }
                },
                .vectored => |state| {
                    if (state.advance(bytes_sent)) {
                        self.io.sendmsg(
                            .{ .fd = self.peers[ps.slot].fd, .msg = &state.msg },
                            &ps.completion,
                            self,
                            peer_handler.pendingSendCompleteFor(Self),
                        ) catch {
                            return .failed;
                        };
                        self.peers[ps.slot].send_pending = true;
                        return .resubmitted;
                    }
                },
                .ghost => return .complete, // peer was removed; the CQE will route through the peer-freed branch in handleSendResult
                .free => unreachable, // active PendingSend can't be in `free` state
            }
            return .complete;
        }

        /// Find a PendingSend by (slot, send_id). Returns null if not present.
        pub fn findPendingSend(self: *Self, slot: u16, send_id: u32) ?*PendingSend {
            for (self.pending_sends.items) |ps| {
                if (ps.slot == slot and ps.send_id == send_id) return ps;
            }
            return null;
        }

        /// Free ONE pending send buffer matching the send_id.
        /// Called when a single send CQE completes -- each CQE corresponds to
        /// exactly one buffer.  Freeing all buffers for a slot here would be a
        /// use-after-free when multiple tracked sends are in flight for the
        /// same peer (e.g. extension handshake + piece response).
        pub fn freeOnePendingSend(self: *Self, slot: u16, send_id: u32) void {
            for (self.pending_sends.items, 0..) |ps, i| {
                if (ps.slot == slot and ps.send_id == send_id) {
                    self.releasePendingSend(ps);
                    _ = self.pending_sends.swapRemove(i);
                    return;
                }
            }
        }

        /// Mark all pending sends for a peer as ghosts (buffer freed,
        /// pool slot retained until CQE fires). Called during peer
        /// removal. The entries stay in `pending_sends` so that when
        /// the in-flight send's CQE eventually arrives — possibly with
        /// a -EBADF / BrokenPipe error after the fd close, possibly
        /// successfully if the kernel already flushed — the callback's
        /// peer-freed branch can find the (slot, send_id) entry and
        /// route through `releasePendingSend(.ghost)` for the final
        /// pool release.
        ///
        /// Eagerly returning the pool slot here would be a UAF: the
        /// SimIO/RealIO completion heap still references the
        /// Completion, and the next pool claim would re-hand-out the
        /// slot to a different peer's send. When the original send
        /// finally fires, the @fieldParentPtr recovery would resolve
        /// to the new peer's data — wrong-peer trust adjustments,
        /// double-free of the new peer's buffer, etc.
        fn freeAllPendingSends(self: *Self, slot: u16) void {
            for (self.pending_sends.items) |ps| {
                if (ps.slot == slot) {
                    self.markPendingSendGhost(ps);
                }
            }
        }

        pub fn hasPendingSendForSlot(self: *const Self, slot: u16) bool {
            for (self.pending_sends.items) |ps| {
                if (ps.slot == slot) return true;
            }
            return false;
        }

        fn hasPendingSendForSlotExcept(self: *const Self, slot: u16, excluded: *const PendingSend) bool {
            for (self.pending_sends.items) |ps| {
                if (ps != excluded and ps.slot == slot) return true;
            }
            return false;
        }

        fn releaseVectoredSendState(self: *Self, state: *VectoredSendState) void {
            for (state.piece_buffers) |piece_buffer| {
                self.releasePieceBuffer(piece_buffer);
            }
            self.vectored_send_pool.release(self.allocator, state);
        }

        fn releasePendingSend(self: *Self, pending_send: *PendingSend) void {
            switch (pending_send.storage) {
                .owned => |owned| {
                    if (owned.small_slot) |small_slot| {
                        self.small_send_pool.release(small_slot);
                    } else {
                        self.allocator.free(owned.buf);
                    }
                },
                .vectored => |state| self.releaseVectoredSendState(state),
                .ghost => {
                    // Buffer was already freed by `freeAllPendingSends` when
                    // the peer was removed mid-send. The pool slot was kept
                    // claimed until now (CQE fired) so SimIO/RealIO's heap
                    // reference to `completion` resolved cleanly. Pool
                    // release below is the only remaining cleanup.
                },
                .free => unreachable, // releasing an already-released PendingSend
            }
            self.pending_send_pool.release(pending_send);
        }

        /// Mark a PendingSend as a "ghost": free its buffer (peer is
        /// gone, the bytes are dead) but keep the pool slot claimed
        /// until the in-flight CQE fires. This avoids a UAF where the
        /// pool would re-hand the slot to a new caller before SimIO/
        /// RealIO finishes with the original Completion. The CQE
        /// callback (`handleSendResult` peer-freed branch) drives the
        /// final pool release via `freeOnePendingSend` →
        /// `releasePendingSend(.ghost)`.
        fn markPendingSendGhost(self: *Self, pending_send: *PendingSend) void {
            switch (pending_send.storage) {
                .owned => |owned| {
                    if (owned.small_slot) |small_slot| {
                        self.small_send_pool.release(small_slot);
                    } else {
                        self.allocator.free(owned.buf);
                    }
                },
                .vectored => |state| self.releaseVectoredSendState(state),
                .ghost => return, // idempotent: already marked
                .free => unreachable, // marking an already-released PendingSend
            }
            pending_send.storage = .ghost;
        }

        /// Claim a PendingSend slot from the per-EventLoop pool and append it to
        /// the active list. Zero-alloc on the hot path (the pool's storage is
        /// pre-allocated at init); the kernel sees stable Completion addresses
        /// because pool slots never move.
        fn appendPendingSend(self: *Self, ps: PendingSend) !*PendingSend {
            const slot = self.pending_send_pool.claim() orelse return error.OutOfMemory;
            slot.* = ps;
            // Reset the embedded Completion to a fresh state. Pool slots are
            // reused; the previous tenant's `_backend_state` (RealState) had
            // `in_flight = false` set by `dispatchCqe` before its callback fired,
            // but explicit reset is cheap and defensive.
            slot.completion = .{};
            self.pending_sends.append(self.allocator, slot) catch |err| {
                self.pending_send_pool.release(slot);
                return err;
            };
            return slot;
        }

        /// Submit the in-flight send for a PendingSend through the io_interface
        /// backend on the PendingSend's embedded completion. Picks `io.send` or
        /// `io.sendmsg` based on the storage variant.
        ///
        /// Lifetime note: for the vectored variant, `ps.storage.vectored` is a
        /// heap-allocated `*VectoredSendState` from `vectored_send_pool` and the
        /// `&state.msg` pointer the kernel sees outlives the SQE because (a) the
        /// PendingSend itself has a stable heap address (carrying the Completion
        /// the kernel CQE references), and (b) the VectoredSendState is only
        /// freed by `freeOnePendingSend(slot, send_id)` after the CQE arrives.
        pub fn submitPendingSend(self: *Self, ps: *PendingSend) !void {
            const peer = &self.peers[ps.slot];
            peer.send_pending = true;
            switch (ps.storage) {
                .owned => |owned| self.io.send(
                    .{ .fd = peer.fd, .buf = owned.buf },
                    &ps.completion,
                    self,
                    peer_handler.pendingSendCompleteFor(Self),
                ) catch |err| {
                    peer.send_pending = peer.untracked_send_pending or self.hasPendingSendForSlotExcept(ps.slot, ps);
                    return err;
                },
                .vectored => |state| self.io.sendmsg(
                    .{ .fd = peer.fd, .msg = &state.msg },
                    &ps.completion,
                    self,
                    peer_handler.pendingSendCompleteFor(Self),
                ) catch |err| {
                    peer.send_pending = peer.untracked_send_pending or self.hasPendingSendForSlotExcept(ps.slot, ps);
                    return err;
                },
                .ghost => unreachable, // submitPendingSend is called only on freshly-claimed slots; ghost is a post-removal state
                .free => unreachable, // active PendingSend can't be in `free` state
            }
        }

        pub fn trackPendingSendCopy(self: *Self, slot: u16, send_id: u32, data: []const u8) !*PendingSend {
            if (self.small_send_pool.alloc(data, small_send_capacity)) |entry| {
                errdefer self.small_send_pool.release(entry.slot);
                return try self.appendPendingSend(.{
                    .slot = slot,
                    .send_id = send_id,
                    .storage = .{
                        .owned = .{
                            .buf = entry.buf,
                            .small_slot = entry.slot,
                        },
                    },
                });
            }

            const heap_buf = try self.allocator.dupe(u8, data);
            errdefer self.allocator.free(heap_buf);
            return try self.appendPendingSend(.{
                .slot = slot,
                .send_id = send_id,
                .storage = .{ .owned = .{ .buf = heap_buf } },
            });
        }

        pub fn trackPendingSendOwned(self: *Self, slot: u16, send_id: u32, buf: []u8) !*PendingSend {
            if (self.small_send_pool.alloc(buf, small_send_capacity)) |entry| {
                errdefer self.small_send_pool.release(entry.slot);
                const ps = try self.appendPendingSend(.{
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
                return ps;
            }

            return try self.appendPendingSend(.{
                .slot = slot,
                .send_id = send_id,
                .storage = .{ .owned = .{ .buf = buf } },
            });
        }

        pub fn trackPendingSendVectored(self: *Self, slot: u16, send_id: u32, state: *VectoredSendState) !*PendingSend {
            errdefer self.releaseVectoredSendState(state);
            return try self.appendPendingSend(.{
                .slot = slot,
                .send_id = send_id,
                .storage = .{ .vectored = state },
            });
        }

        const vectoredSendLayout = bp.vectoredSendLayout;

        pub fn nextPendingWriteId(self: *Self) u32 {
            const write_id = self.next_pending_write_id;
            self.next_pending_write_id +%= 1;
            if (self.next_pending_write_id == 0) self.next_pending_write_id = 1;
            return write_id;
        }

        pub fn createPendingWrite(self: *Self, key: PendingWriteKey, pending_write: PendingWrite) !u32 {
            const write_id = self.nextPendingWriteId();

            try self.pending_writes.put(self.allocator, write_id, pending_write);
            errdefer _ = self.pending_writes.remove(write_id);

            try self.pending_write_lookup.put(self.allocator, key, write_id);
            self.pending_writes.getPtr(write_id).?.write_id = write_id;
            return write_id;
        }

        pub fn getPendingWrite(self: *Self, key: PendingWriteKey) ?*PendingWrite {
            const write_id = self.pending_write_lookup.get(key) orelse return null;
            return self.pending_writes.getPtr(write_id);
        }

        pub fn hasPendingWrite(self: *const Self, key: PendingWriteKey) bool {
            return self.pending_write_lookup.contains(key);
        }

        pub fn removePendingWrite(self: *Self, key: PendingWriteKey) ?PendingWrite {
            const write_id = self.pending_write_lookup.get(key) orelse return null;
            _ = self.pending_write_lookup.remove(key);
            return if (self.pending_writes.fetchRemove(write_id)) |entry| entry.value else null;
        }

        pub fn getPendingWriteById(self: *Self, write_id: u32) ?*PendingWrite {
            return self.pending_writes.getPtr(write_id);
        }

        pub fn removePendingWriteById(self: *Self, write_id: u32) ?PendingWrite {
            const removed = self.pending_writes.fetchRemove(write_id) orelse return null;
            _ = self.pending_write_lookup.remove(.{
                .piece_index = removed.value.piece_index,
                .torrent_id = removed.value.torrent_id,
            });
            return removed.value;
        }

        pub fn getTorrentContext(self: *Self, torrent_id: TorrentId) ?*TorrentContext {
            if (torrent_id >= self.torrents.items.len) return null;
            return if (self.torrents.items[torrent_id]) |*tc| tc else null;
        }

        pub fn getTorrentContextConst(self: *const Self, torrent_id: TorrentId) ?*const TorrentContext {
            if (torrent_id >= self.torrents.items.len) return null;
            return if (self.torrents.items[torrent_id]) |*tc| tc else null;
        }

        pub fn enqueueAnnounceResult(self: *Self, torrent_id: TorrentId, peers: []std.net.Address) !void {
            self.announce_mutex.lock();
            defer self.announce_mutex.unlock();
            try self.announce_results.append(self.allocator, .{
                .torrent_id = torrent_id,
                .peers = peers,
            });
        }

        pub fn findTorrentIdByInfoHash(self: *const Self, info_hash: []const u8) ?TorrentId {
            if (info_hash.len != 20) return null;
            var key: [20]u8 = undefined;
            @memcpy(&key, info_hash[0..20]);
            return self.info_hash_to_torrent.get(key);
        }

        pub fn allocSlot(self: *Self) ?u16 {
            for (self.peers, 0..) |*peer, i| {
                if (peer.state == .free) return @intCast(i);
            }
            return null;
        }

        fn cleanupPeer(self: *Self, peer: *Peer) void {
            // Clean up uTP slot if this is a uTP peer
            if (peer.transport == .utp) {
                if (peer.utp_slot) |utp_slot| {
                    if (self.utp_manager) |mgr| {
                        const now_us = self.clock.nowUs32();
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
                self.io.closeSocket(peer.fd);
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
            for (peer.extra_prefetch_pieces) |slot| {
                if (slot.downloading_piece == null) {
                    if (slot.buf) |buf| self.allocator.free(buf);
                }
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

        fn registerTorrentHashes(self: *Self, torrent_id: TorrentId, info_hash: [20]u8, info_hash_v2: ?[20]u8) !void {
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

        fn unregisterTorrentHashes(self: *Self, info_hash: [20]u8, info_hash_v2: ?[20]u8) void {
            _ = self.info_hash_to_torrent.remove(info_hash);
            _ = self.mse_req2_to_hash.remove(mse.hashReq2ForInfoHash(info_hash));
            if (info_hash_v2) |v2_hash| {
                if (!std.mem.eql(u8, &v2_hash, &info_hash)) {
                    _ = self.info_hash_to_torrent.remove(v2_hash);
                    _ = self.mse_req2_to_hash.remove(mse.hashReq2ForInfoHash(v2_hash));
                }
            }
        }

        fn removeActiveTorrentId(self: *Self, torrent_id: TorrentId) void {
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
        fn shutdownPeerFd(_: *Self, fd: posix.fd_t) void {
            _ = linux.shutdown(fd, linux.SHUT.RDWR);
        }
    };
}

/// Daemon's concrete instantiation. Daemon callers continue to write
/// `EventLoop` and `EventLoop.method(...)`; tests that instantiate
/// against SimIO write `EventLoopOf(SimIO)` directly.
pub const EventLoop = EventLoopOf(RealIO);

// ── Tests ─────────────────────────────────────────────────

test "event loop supports high torrent counts with hashed lookup and slot reuse" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const torrent_count: u32 = 20_000;

    var reused_hash: [20]u8 = undefined;

    for (0..torrent_count) |idx| {
        var info_hash = @as([20]u8, @splat(0));
        var peer_id = @as([20]u8, @splat(0));
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

    var replacement_hash = @as([20]u8, @splat(0));
    replacement_hash[0] = 0xFE;
    replacement_hash[1] = 0xED;
    replacement_hash[2] = 0xFA;
    replacement_hash[3] = 0xCE;
    replacement_hash[4] = 0x01;

    const replacement_id = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = replacement_hash,
        .peer_id = @as([20]u8, @splat(1)),
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

test "peer candidates persist when connection capacity is exhausted" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = @as([20]u8, @splat(0xA1)),
        .peer_id = @as([20]u8, @splat(0xB2)),
    });

    const peer_a = try std.net.Address.parseIp4("127.0.0.10", 6882);
    const peer_b = try std.net.Address.parseIp4("127.0.0.11", 6883);

    try std.testing.expect(try el.enqueuePeerCandidate(peer_a, tid, .tracker));
    try std.testing.expect(try el.enqueuePeerCandidate(peer_b, tid, .tracker));
    try std.testing.expect(!try el.enqueuePeerCandidate(peer_a, tid, .tracker));

    el.max_half_open = 0;
    el.processPeerCandidates();

    try std.testing.expectEqual(@as(usize, 2), el.peerCandidateCount(tid));
    try std.testing.expectEqual(@as(u32, 0), el.peer_count);
    try std.testing.expectEqual(@as(u32, 0), el.half_open_count);
}

test "established peer count excludes half-open candidates" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = @as([20]u8, @splat(0xA3)),
        .peer_id = @as([20]u8, @splat(0xB4)),
    });

    el.peers[0].state = .connecting;
    el.peers[0].torrent_id = tid;
    el.attachPeerToTorrent(tid, 0);

    el.peers[1].state = .active_recv_header;
    el.peers[1].torrent_id = tid;
    el.attachPeerToTorrent(tid, 1);

    el.peers[2].state = .handshake_recv;
    el.peers[2].torrent_id = tid;
    el.attachPeerToTorrent(tid, 2);

    try std.testing.expectEqual(@as(u16, 3), el.peerCountForTorrent(tid));
    try std.testing.expectEqual(@as(u16, 2), el.establishedPeerCountForTorrent(tid));
}

test "private torrents reject DHT and PEX peer candidates" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = @as([20]u8, @splat(0xC1)),
        .peer_id = @as([20]u8, @splat(0xD2)),
        .is_private = true,
    });

    const dht_peer = try std.net.Address.parseIp4("127.0.0.12", 6881);
    const pex_peer = try std.net.Address.parseIp4("127.0.0.13", 6881);
    const tracker_peer = try std.net.Address.parseIp4("127.0.0.14", 6882);

    try std.testing.expectError(error.PrivateTorrentPeerDiscoveryDisabled, el.enqueuePeerCandidate(dht_peer, tid, .dht));
    try std.testing.expectError(error.PrivateTorrentPeerDiscoveryDisabled, el.enqueuePeerCandidate(pex_peer, tid, .pex));
    try std.testing.expect(try el.enqueuePeerCandidate(tracker_peer, tid, .tracker));
    try std.testing.expectEqual(@as(usize, 1), el.peerCandidateCount(tid));
}

test "peer and torrent membership indices stay consistent across swap-remove" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]posix.fd_t{};
    const tid0 = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = @as([20]u8, @splat(0x11)),
        .peer_id = @as([20]u8, @splat(0x22)),
    });
    const tid1 = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = @as([20]u8, @splat(0x33)),
        .peer_id = @as([20]u8, @splat(0x44)),
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

test "selectTransport prefers tcp when both outgoing enabled" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_and_utp;

    try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    try std.testing.expectEqual(Transport.tcp, el.selectTransport());
}

test "selectTransport consistently chooses tcp in mixed mode" {
    const allocator = std.testing.allocator;
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_and_utp;

    var tcp_count: u32 = 0;
    var utp_count: u32 = 0;
    for (0..100) |_| {
        const t = el.selectTransport();
        if (t == .tcp) tcp_count += 1 else utp_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 100), tcp_count);
    try std.testing.expectEqual(@as(u32, 0), utp_count);
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

const std = @import("std");
const posix = std.posix;
const io_interface = @import("io_interface.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const session_mod = @import("../torrent/session.zig");
const ext = @import("../net/extensions.zig");
const pex_mod = @import("../net/pex.zig");
const mse = @import("../crypto/mse.zig");
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const SuperSeedState = @import("super_seed.zig").SuperSeedState;
const MerkleCache = @import("../torrent/merkle_cache.zig").MerkleCache;
const WebSeedManager = @import("../net/web_seed.zig").WebSeedManager;

// ── Constants ────────────────────────────────────────────

pub const max_peers: u16 = 4096;
pub const TorrentId = u32;

// ── User data encoding ────────────────────────────────────

pub const OpType = enum(u8) {
    peer_connect = 0,
    peer_send = 2,
    timeout = 9,
    cancel = 10,
    utp_recv = 11,
    utp_send = 12,
    api_accept = 13,
    api_recv = 14,
    api_send = 15,
    udp_tracker_send = 16,
    udp_tracker_recv = 17,
    metadata_connect = 20,
    metadata_send = 21,
    metadata_recv = 22,
    peer_socket = 23,
    udp_socket = 25,
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
    outbound, // we connected out -- we request pieces
    inbound, // peer connected to us -- we serve pieces
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
    mode: PeerMode = .outbound,
    transport: Transport = .tcp,
    torrent_id: TorrentId = 0,
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
    torrent_peer_index: ?u16 = null,
    idle_peer_index: ?u16 = null,
    active_peer_index: ?u16 = null,
    blocks_received: u32 = 0,
    blocks_expected: u32 = 0,
    pipeline_sent: u32 = 0,
    inflight_requests: u32 = 0,

    // Multi-source piece assembly: shared DownloadingPiece for current and next piece.
    downloading_piece: ?*@import("downloading_piece.zig").DownloadingPiece = null,
    next_downloading_piece: ?*@import("downloading_piece.zig").DownloadingPiece = null,

    // Pre-claimed next piece (pipeline overlap: requests sent before current piece completes)
    next_piece: ?u32 = null,
    next_piece_buf: ?[]u8 = null,
    next_blocks_expected: u32 = 0,
    next_blocks_received: u32 = 0,
    next_pipeline_sent: u32 = 0,

    // BEP 10 extension protocol state
    extensions_supported: bool = false, // peer advertised BEP 10 support
    extension_ids: ?ext.ExtensionIds = null, // peer's extension ID mapping

    // BEP 21: partial seed (upload_only) — peer has some pieces and is
    // willing to upload but not interested in downloading from us.
    upload_only: bool = false,

    // BEP 11 PEX state (per-peer, tracks what we have sent to this peer)
    pex_state: ?*pex_mod.PexState = null,

    // Trust tracking (Smart Ban Phase 0)
    hashfails: u8 = 0, // pieces that failed hash verification from this peer
    trust_points: i8 = 0, // reputation: decremented on failure, incremented on success

    // MSE/PE (BEP 6) encryption state
    crypto: mse.PeerCrypto = mse.PeerCrypto.plaintext,
    // Async MSE handshake state (heap-allocated, freed on completion/disconnect)
    mse_initiator: ?*mse.MseInitiatorHandshake = null,
    mse_responder: ?*mse.MseResponderHandshake = null,
    mse_known_hashes: ?[]const [20]u8 = null,
    // Track whether this peer previously rejected MSE (don't retry on reconnect)
    mse_rejected: bool = false,
    // Track whether we're in MSE fallback (reconnecting without MSE)
    mse_fallback: bool = false,
    // Remaining bytes to send for the current MSE send operation.
    // Used to handle partial sends during MSE handshake without prematurely
    // advancing the state machine.
    mse_send_remaining: []const u8 = &.{},

    // Caller-owned completion for the peer's in-flight recv on the
    // io_interface backend. Recvs are naturally serial per peer (handshake,
    // header, body, MSE chunks); only one is in flight at a time. The
    // callback (`peer_handler.peerRecvComplete`) re-derives the slot via
    // pointer arithmetic on `EventLoop.peers` and dispatches.
    recv_completion: io_interface.Completion = .{},
};

// ── Torrent context (per-torrent state within shared event loop) ──

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
    downloaded_bytes: u64 = 0,
    uploaded_bytes: u64 = 0,

    // Per-torrent rate limiters (0 = unlimited)
    rate_limiter: RateLimiter = RateLimiter.initComptime(0, 0),

    // BEP 11 PEX state (per-torrent, tracks currently connected peers)
    pex_state: ?*pex_mod.TorrentPexState = null,

    // BEP 16: super-seeding state (null if super-seeding is disabled)
    super_seed: ?*SuperSeedState = null,

    // BEP 21: we are a partial seed (upload_only). All wanted pieces are complete
    // but not all pieces in the torrent. We upload what we have but don't download.
    upload_only: bool = false,

    // BEP 52: per-file Merkle tree cache for hash serving
    merkle_cache: ?*MerkleCache = null,

    // BEP 19: web seed manager (GetRight-style HTTP seeding)
    web_seed_manager: ?*WebSeedManager = null,

    // Slots of peers currently attached to this torrent.
    peer_slots: std.ArrayList(u16) = std.ArrayList(u16).empty,
    torrent_peer_list_index: ?u32 = null,
};

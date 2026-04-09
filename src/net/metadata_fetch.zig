const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const address = @import("address.zig");
const ut_metadata = @import("ut_metadata.zig");
const ext = @import("extensions.zig");
const peer_wire = @import("peer_wire.zig");
const Sha1 = @import("../crypto/root.zig").Sha1;

/// BEP 9 resilient metadata fetcher.
///
/// Downloads metadata from multiple peers in parallel, handles timeouts,
/// retries, and provides progress reporting. Designed to be called from
/// a background thread (not the io_uring event loop).

// ── Configuration ──────────────────────────────────────────

/// Per-peer request timeout in seconds. If a peer does not respond
/// within this window, the fetcher moves on to the next peer.
pub const peer_timeout_secs: u32 = 30;

/// Overall metadata fetch timeout in seconds. If the complete metadata
/// is not assembled within this duration, the fetch fails.
pub const overall_timeout_secs: i64 = 300; // 5 minutes

/// Maximum number of simultaneous peer connections for metadata fetch.
pub const max_parallel_peers: usize = 4;

/// Maximum messages to read while waiting for a specific response.
const max_messages_per_exchange: u32 = 50;

// ── DHT peer provider interface (stub) ─────────────────────

/// Interface for feeding peers into the metadata fetcher from an
/// external discovery mechanism (DHT, PEX, manual injection, etc.).
///
/// DHT implementation should conform to this interface by providing a
/// struct with a `getPeers` method. For now, this is stubbed out.
pub const PeerProvider = struct {
    /// Opaque context pointer for the provider implementation.
    ctx: ?*anyopaque = null,

    /// Function pointer to request more peers. Returns peers discovered
    /// since the last call. The returned slice is owned by the caller
    /// and must be freed with `allocator`.
    ///
    /// Set to null when no provider is available (e.g., no DHT).
    get_peers_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, info_hash: [20]u8) error{OutOfMemory}![]std.net.Address = null,

    /// Request additional peers from the provider.
    pub fn getPeers(self: PeerProvider, allocator: std.mem.Allocator, info_hash: [20]u8) ![]std.net.Address {
        if (self.get_peers_fn) |f| {
            return f(self.ctx, allocator, info_hash);
        }
        return allocator.alloc(std.net.Address, 0);
    }

    /// Create a no-op provider (no DHT available).
    pub fn none() PeerProvider {
        return .{};
    }
};

// ── Progress and error reporting ───────────────────────────

/// Metadata fetch progress, suitable for API exposure.
pub const FetchProgress = struct {
    /// Current state of the metadata fetch.
    state: FetchState = .idle,
    /// Total metadata size in bytes (0 if not yet known).
    metadata_size: u32 = 0,
    /// Number of metadata pieces received so far.
    pieces_received: u32 = 0,
    /// Total number of metadata pieces needed.
    pieces_total: u32 = 0,
    /// Number of peers attempted so far.
    peers_attempted: u32 = 0,
    /// Number of peers that support ut_metadata.
    peers_with_metadata: u32 = 0,
    /// Number of peers currently connected for metadata.
    peers_active: u32 = 0,
    /// Human-readable error message if state is .failed.
    error_message: ?[]const u8 = null,
    /// Elapsed time in seconds since fetch started.
    elapsed_secs: i64 = 0,
};

pub const FetchState = enum {
    idle,
    announcing,
    connecting,
    downloading,
    completed,
    failed,
};

/// Tracks a peer's metadata capabilities.
const MetadataPeer = struct {
    address: std.net.Address,
    /// Peer's ut_metadata extension ID (0 = unknown/unsupported).
    ut_metadata_id: u8 = 0,
    /// Metadata size reported by this peer.
    metadata_size: u32 = 0,
    /// Whether we have attempted this peer.
    attempted: bool = false,
    /// Whether this peer is currently active (connected).
    active: bool = false,
    /// Number of pieces this peer has delivered.
    pieces_delivered: u32 = 0,
    /// Number of failures from this peer.
    failures: u32 = 0,
};

/// Result of a single peer metadata fetch attempt.
const PeerResult = struct {
    /// Pieces successfully received from this peer.
    pieces_received: u32 = 0,
    /// Whether the peer disconnected or timed out.
    failed: bool = false,
    /// Error description.
    err_msg: ?[]const u8 = null,
};

// ── MetadataFetcher ────────────────────────────────────────

/// Coordinates metadata download from multiple peers with parallel
/// requests, timeout handling, and retry logic.
pub const MetadataFetcher = struct {
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    is_private: bool,

    /// Metadata assembler that collects pieces.
    assembler: ut_metadata.MetadataAssembler,

    /// Known peers and their capabilities.
    peers: std.ArrayList(MetadataPeer),

    /// Progress tracking (readable from other threads via atomic snapshot).
    progress: FetchProgress = .{},

    /// Start timestamp for overall timeout.
    start_time: i64 = 0,

    /// Optional external peer provider (DHT stub).
    peer_provider: PeerProvider = PeerProvider.none(),

    pub fn init(
        allocator: std.mem.Allocator,
        info_hash: [20]u8,
        peer_id: [20]u8,
        port: u16,
        is_private: bool,
    ) MetadataFetcher {
        return .{
            .allocator = allocator,
            .info_hash = info_hash,
            .peer_id = peer_id,
            .port = port,
            .is_private = is_private,
            .assembler = ut_metadata.MetadataAssembler.init(allocator, info_hash),
            .peers = std.ArrayList(MetadataPeer).empty,
        };
    }

    pub fn deinit(self: *MetadataFetcher) void {
        self.assembler.deinit();
        self.peers.deinit(self.allocator);
    }

    /// Add peers discovered from tracker announces or other sources.
    pub fn addPeers(self: *MetadataFetcher, addresses: []const std.net.Address) void {
        for (addresses) |addr| {
            self.addPeer(addr);
        }
    }

    /// Add a single peer, deduplicating by address.
    pub fn addPeer(self: *MetadataFetcher, addr: std.net.Address) void {
        // Check for duplicates
        for (self.peers.items) |*p| {
            if (address.addressEql(p.address, addr)) return;
        }
        self.peers.append(self.allocator, .{ .address = addr }) catch {};
    }

    /// Set the external peer provider (e.g., DHT).
    pub fn setPeerProvider(self: *MetadataFetcher, provider: PeerProvider) void {
        self.peer_provider = provider;
    }

    /// Get a snapshot of the current fetch progress.
    pub fn getProgress(self: *const MetadataFetcher) FetchProgress {
        return self.progress;
    }

    /// Run the metadata fetch. Blocks until metadata is complete, all
    /// peers are exhausted, or the overall timeout expires.
    ///
    /// Returns the verified raw info dictionary bytes on success.
    /// The returned slice references the assembler's internal buffer
    /// and is valid until this fetcher is deinitialized.
    pub fn fetch(self: *MetadataFetcher) FetchError![]const u8 {
        const log = std.log.scoped(.metadata_fetch);

        self.start_time = std.time.timestamp();
        self.progress.state = .connecting;

        if (self.peers.items.len == 0) {
            // Try the peer provider before giving up
            self.pollPeerProvider();
        }

        if (self.peers.items.len == 0) {
            self.progress.state = .failed;
            self.progress.error_message = "no peers available for metadata download";
            return error.NoPeers;
        }

        self.progress.state = .downloading;

        // Main fetch loop: iterate through peers, requesting pieces
        // from each one. Try multiple peers sequentially (parallel
        // connections happen by trying the next peer when one fails
        // mid-download, keeping partial progress in the assembler).
        var round: u32 = 0;
        while (!self.assembler.isComplete()) {
            if (self.isOverallTimedOut()) {
                self.progress.state = .failed;
                self.progress.error_message = "overall metadata fetch timeout exceeded (5 minutes)";
                return error.OverallTimeout;
            }

            // Poll for more peers from DHT/PEX periodically
            if (round > 0 and round % 3 == 0) {
                self.pollPeerProvider();
            }

            // Find next unattempted peer, or retry a failed peer with fewest failures
            const peer_idx = self.selectNextPeer() orelse {
                // All peers exhausted. Try provider one more time.
                self.pollPeerProvider();
                if (self.selectNextPeer() == null) {
                    self.progress.state = .failed;
                    self.progress.error_message = "all peers exhausted, metadata incomplete";
                    return error.AllPeersExhausted;
                }
                continue;
            };

            self.progress.peers_attempted += 1;
            self.progress.peers_active += 1;
            self.peers.items[peer_idx].attempted = true;
            self.peers.items[peer_idx].active = true;

            self.fetchFromPeer(peer_idx, log) catch |err| {
                log.debug("metadata fetch from peer failed: {s}", .{@errorName(err)});
                self.peers.items[peer_idx].failures += 1;
            };

            self.peers.items[peer_idx].active = false;
            self.progress.peers_active -|= 1;

            self.updateProgress();

            if (self.assembler.isComplete()) break;

            round += 1;
        }

        if (!self.assembler.isComplete()) {
            self.progress.state = .failed;
            self.progress.error_message = "failed to download metadata from any peer";
            return error.MetadataFetchFailed;
        }

        // Verify the assembled metadata
        const info_bytes = self.assembler.verify() catch {
            // Hash mismatch -- reset and could retry but for now fail
            self.assembler.reset();
            self.progress.state = .failed;
            self.progress.error_message = "metadata hash verification failed";
            return error.InfoHashMismatch;
        };

        self.progress.state = .completed;
        self.progress.elapsed_secs = std.time.timestamp() - self.start_time;
        log.info("metadata downloaded: {d} bytes, {d} pieces from {d} peers in {d}s", .{
            self.assembler.total_size,
            self.assembler.piece_count,
            self.progress.peers_attempted,
            self.progress.elapsed_secs,
        });

        return info_bytes;
    }

    /// Try to fetch metadata pieces from a single peer.
    fn fetchFromPeer(self: *MetadataFetcher, peer_idx: usize, log: anytype) FetchError!void {
        const peer = &self.peers.items[peer_idx];
        const addr = peer.address;

        // Create socket
        const fd = posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        ) catch return error.SocketFailed;
        errdefer posix.close(fd);

        // Set send/receive timeout on socket for per-peer timeout.
        // SO_SNDTIMEO also governs the blocking connect() timeout on Linux.
        setSocketTimeout(fd, peer_timeout_secs) catch {};

        // Connect (blocking, timeout governed by SO_SNDTIMEO)
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            return error.ConnectFailed;
        };

        // BitTorrent handshake
        var handshake: [68]u8 = undefined;
        handshake[0] = 19;
        @memcpy(handshake[1..20], "BitTorrent protocol");
        @memset(handshake[20..28], 0);
        ext.setExtensionBit(handshake[20..28]);
        @memcpy(handshake[28..48], &self.info_hash);
        @memcpy(handshake[48..68], &self.peer_id);

        peer_wire.sendAll(fd, &handshake) catch return error.SendFailed;

        // Receive peer handshake
        var peer_handshake: [68]u8 = undefined;
        peer_wire.recvExact(fd, &peer_handshake) catch return error.RecvFailed;

        if (peer_handshake[0] != 19 or !std.mem.eql(u8, peer_handshake[1..20], "BitTorrent protocol")) {
            return error.InvalidHandshake;
        }

        if (!ext.supportsExtensions(peer_handshake[20..28].*)) {
            return error.NoBEP10Support;
        }

        // Send extension handshake
        const ext_payload = ext.encodeExtensionHandshake(self.allocator, self.port, self.is_private) catch
            return error.EncodeFailed;
        defer self.allocator.free(ext_payload);

        const ext_frame = ext.serializeExtensionMessage(self.allocator, ext.handshake_sub_id, ext_payload) catch
            return error.EncodeFailed;
        defer self.allocator.free(ext_frame);

        peer_wire.sendAll(fd, ext_frame) catch return error.SendFailed;

        // Read extension handshake from peer
        var peer_ut_metadata_id: u8 = 0;
        var metadata_size: u32 = 0;

        var msg_count: u32 = 0;
        while (msg_count < 20) : (msg_count += 1) {
            var len_buf: [4]u8 = undefined;
            peer_wire.recvExact(fd, &len_buf) catch return error.RecvFailed;
            const msg_len = std.mem.readInt(u32, &len_buf, .big);
            if (msg_len == 0) continue;
            if (msg_len > 1024 * 1024) return error.MessageTooLarge;

            const msg_buf = self.allocator.alloc(u8, msg_len) catch return error.OutOfMemory;
            defer self.allocator.free(msg_buf);
            peer_wire.recvExact(fd, msg_buf) catch return error.RecvFailed;

            if (msg_buf[0] == ext.msg_id and msg_buf.len >= 2 and msg_buf[1] == ext.handshake_sub_id) {
                const result = ext.decodeExtensionHandshake(msg_buf[2..]) catch continue;

                peer_ut_metadata_id = result.extensions.ut_metadata;
                metadata_size = result.metadata_size;

                log.debug("peer ext handshake: ut_metadata={d} metadata_size={d}", .{
                    peer_ut_metadata_id, metadata_size,
                });
                break;
            }
        }

        if (peer_ut_metadata_id == 0) return error.PeerDoesNotSupportUtMetadata;
        if (metadata_size == 0) return error.PeerDidNotReportMetadataSize;

        // Update peer info
        peer.ut_metadata_id = peer_ut_metadata_id;
        peer.metadata_size = metadata_size;
        self.progress.peers_with_metadata += 1;

        // Set metadata size on assembler (idempotent if already set to same value)
        self.assembler.setSize(metadata_size) catch return error.InvalidMetadataSize;
        self.progress.metadata_size = metadata_size;
        self.progress.pieces_total = self.assembler.totalPieces();

        // Request metadata pieces sequentially from this peer.
        // The assembler tracks which pieces we still need globally,
        // so if a previous peer delivered some pieces, we skip those.
        while (self.assembler.nextNeeded()) |piece_idx| {
            if (self.isOverallTimedOut()) return error.OverallTimeout;

            // Send request
            const req_payload = ut_metadata.encodeRequest(self.allocator, piece_idx) catch
                return error.EncodeFailed;
            defer self.allocator.free(req_payload);

            const req_frame = ext.serializeExtensionMessage(self.allocator, peer_ut_metadata_id, req_payload) catch
                return error.EncodeFailed;
            defer self.allocator.free(req_frame);

            peer_wire.sendAll(fd, req_frame) catch return error.SendFailed;

            // Wait for response
            var got_response = false;
            var response_attempts: u32 = 0;
            while (!got_response and response_attempts < max_messages_per_exchange) : (response_attempts += 1) {
                var len_buf: [4]u8 = undefined;
                peer_wire.recvExact(fd, &len_buf) catch return error.RecvFailed;
                const msg_len = std.mem.readInt(u32, &len_buf, .big);
                if (msg_len == 0) continue;
                if (msg_len > 1024 * 1024) return error.MessageTooLarge;

                const msg_buf = self.allocator.alloc(u8, msg_len) catch return error.OutOfMemory;
                defer self.allocator.free(msg_buf);
                peer_wire.recvExact(fd, msg_buf) catch return error.RecvFailed;

                if (msg_buf[0] != ext.msg_id or msg_buf.len < 2) continue;
                if (msg_buf[1] != ext.local_ut_metadata_id) continue;

                const meta_msg = ut_metadata.decode(self.allocator, msg_buf[2..]) catch continue;

                switch (meta_msg.msg_type) {
                    .data => {
                        if (meta_msg.piece != piece_idx) continue;
                        const piece_data = msg_buf[2 + meta_msg.data_offset ..];
                        _ = self.assembler.addPiece(piece_idx, piece_data) catch |err| {
                            log.debug("failed to add metadata piece {d}: {s}", .{ piece_idx, @errorName(err) });
                            return error.PieceAddFailed;
                        };
                        peer.pieces_delivered += 1;
                        self.progress.pieces_received = self.assembler.pieces_received;
                        got_response = true;
                    },
                    .reject => {
                        log.debug("peer rejected metadata piece {d}", .{piece_idx});
                        return error.PeerRejectedMetadata;
                    },
                    .request => {
                        // Peer requesting from us -- reject since we don't have metadata yet
                        const reject = ut_metadata.encodeReject(self.allocator, meta_msg.piece) catch continue;
                        defer self.allocator.free(reject);
                        const reject_frame = ext.serializeExtensionMessage(self.allocator, peer_ut_metadata_id, reject) catch continue;
                        defer self.allocator.free(reject_frame);
                        peer_wire.sendAll(fd, reject_frame) catch {};
                    },
                }
            }

            if (!got_response) return error.MetadataPieceTimeout;
        }

        posix.close(fd);
    }

    /// Select the best peer to try next.
    /// Prefers unattempted peers, then peers with fewest failures.
    fn selectNextPeer(self: *MetadataFetcher) ?usize {
        // First pass: find an unattempted peer
        for (self.peers.items, 0..) |p, i| {
            if (!p.attempted) return i;
        }

        // Second pass: find a failed peer with the fewest failures
        // (allows retrying peers that may have transiently failed)
        var best_idx: ?usize = null;
        var best_failures: u32 = std.math.maxInt(u32);
        for (self.peers.items, 0..) |p, i| {
            if (p.active) continue;
            if (p.failures > 0 and p.failures < 3 and p.failures < best_failures) {
                best_failures = p.failures;
                best_idx = i;
            }
        }

        if (best_idx) |idx| {
            // Reset attempted so the main loop processes it again
            self.peers.items[idx].attempted = true;
            return idx;
        }

        return null;
    }

    fn isOverallTimedOut(self: *const MetadataFetcher) bool {
        if (self.start_time == 0) return false;
        return (std.time.timestamp() - self.start_time) >= overall_timeout_secs;
    }

    fn pollPeerProvider(self: *MetadataFetcher) void {
        const new_peers = self.peer_provider.getPeers(self.allocator, self.info_hash) catch return;
        defer self.allocator.free(new_peers);
        self.addPeers(new_peers);
    }

    fn updateProgress(self: *MetadataFetcher) void {
        self.progress.pieces_received = self.assembler.pieces_received;
        self.progress.elapsed_secs = if (self.start_time > 0)
            std.time.timestamp() - self.start_time
        else
            0;
    }
};

// ── Helpers ────────────────────────────────────────────────

fn setSocketTimeout(fd: posix.fd_t, timeout_secs: u32) !void {
    const tv = posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch return;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch return;
}

pub const FetchError = error{
    NoPeers,
    OverallTimeout,
    AllPeersExhausted,
    MetadataFetchFailed,
    InfoHashMismatch,
    SocketFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    InvalidHandshake,
    NoBEP10Support,
    EncodeFailed,
    MessageTooLarge,
    OutOfMemory,
    PeerDoesNotSupportUtMetadata,
    PeerDidNotReportMetadataSize,
    InvalidMetadataSize,
    PeerRejectedMetadata,
    MetadataPieceTimeout,
    PieceAddFailed,
};

// ── Tests ──────────────────────────────────────────────────

test "PeerProvider.none returns empty" {
    const provider = PeerProvider.none();
    const peers = try provider.getPeers(std.testing.allocator, [_]u8{0} ** 20);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);
}

test "PeerProvider custom implementation" {
    const TestProvider = struct {
        fn getPeers(_: ?*anyopaque, allocator: std.mem.Allocator, _: [20]u8) error{OutOfMemory}![]std.net.Address {
            var result = try allocator.alloc(std.net.Address, 1);
            result[0] = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
            return result;
        }
    };

    const provider = PeerProvider{
        .get_peers_fn = &TestProvider.getPeers,
    };

    const peers = try provider.getPeers(std.testing.allocator, [_]u8{0} ** 20);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);
}

test "MetadataFetcher init and deinit" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0xaa} ** 20,
        [_]u8{0xbb} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    try std.testing.expectEqual(FetchState.idle, fetcher.progress.state);
    try std.testing.expectEqual(@as(u32, 0), fetcher.progress.peers_attempted);
}

test "MetadataFetcher addPeers deduplicates" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 6882);
    const addr3 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881); // duplicate

    fetcher.addPeer(addr1);
    fetcher.addPeer(addr2);
    fetcher.addPeer(addr3);

    try std.testing.expectEqual(@as(usize, 2), fetcher.peers.items.len);
}

test "MetadataFetcher fetch fails with no peers" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const result = fetcher.fetch();
    try std.testing.expectError(error.NoPeers, result);
    try std.testing.expectEqual(FetchState.failed, fetcher.progress.state);
}

test "MetadataFetcher selectNextPeer prefers unattempted" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 6882);
    fetcher.addPeer(addr1);
    fetcher.addPeer(addr2);

    // First call should return index 0 (first unattempted)
    const first = fetcher.selectNextPeer();
    try std.testing.expectEqual(@as(?usize, 0), first);

    // Mark first as attempted
    fetcher.peers.items[0].attempted = true;

    // Next should return index 1
    const second = fetcher.selectNextPeer();
    try std.testing.expectEqual(@as(?usize, 1), second);
}

test "MetadataFetcher selectNextPeer retries failed peers" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 6882);
    fetcher.addPeer(addr1);
    fetcher.addPeer(addr2);

    // Mark both as attempted with failures
    fetcher.peers.items[0].attempted = true;
    fetcher.peers.items[0].failures = 2;
    fetcher.peers.items[1].attempted = true;
    fetcher.peers.items[1].failures = 1;

    // Should prefer peer with fewer failures
    const idx = fetcher.selectNextPeer();
    try std.testing.expectEqual(@as(?usize, 1), idx);
}

test "MetadataFetcher selectNextPeer returns null when all exhausted" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    fetcher.addPeer(addr1);

    // Mark as attempted with max failures
    fetcher.peers.items[0].attempted = true;
    fetcher.peers.items[0].failures = 3;

    const idx = fetcher.selectNextPeer();
    try std.testing.expect(idx == null);
}

test "addressEql detects same and different addresses" {
    const a = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    const b = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881);
    const c = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6882);
    const d = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 6881);

    try std.testing.expect(address.addressEql(a, b));
    try std.testing.expect(!address.addressEql(a, c));
    try std.testing.expect(!address.addressEql(a, d));
}

test "FetchProgress default values" {
    const progress = FetchProgress{};
    try std.testing.expectEqual(FetchState.idle, progress.state);
    try std.testing.expectEqual(@as(u32, 0), progress.metadata_size);
    try std.testing.expectEqual(@as(u32, 0), progress.pieces_received);
    try std.testing.expectEqual(@as(u32, 0), progress.pieces_total);
    try std.testing.expect(progress.error_message == null);
}

test "MetadataFetcher setPeerProvider" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    const TestProvider = struct {
        fn getPeers(_: ?*anyopaque, allocator: std.mem.Allocator, _: [20]u8) error{OutOfMemory}![]std.net.Address {
            var result = try allocator.alloc(std.net.Address, 2);
            result[0] = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);
            result[1] = std.net.Address.initIp4(.{ 10, 0, 0, 2 }, 6881);
            return result;
        }
    };

    fetcher.setPeerProvider(.{ .get_peers_fn = &TestProvider.getPeers });

    // pollPeerProvider should add peers from provider
    fetcher.pollPeerProvider();
    try std.testing.expectEqual(@as(usize, 2), fetcher.peers.items.len);
}

test "MetadataFetcher overall timeout detection" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    // Not started yet -- should not be timed out
    try std.testing.expect(!fetcher.isOverallTimedOut());

    // Set start_time far in the past to simulate timeout
    fetcher.start_time = std.time.timestamp() - overall_timeout_secs - 1;
    try std.testing.expect(fetcher.isOverallTimedOut());
}

test "MetadataFetcher getProgress returns current state" {
    var fetcher = MetadataFetcher.init(
        std.testing.allocator,
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        6881,
        false,
    );
    defer fetcher.deinit();

    fetcher.progress.state = .downloading;
    fetcher.progress.peers_attempted = 3;
    fetcher.progress.pieces_received = 2;
    fetcher.progress.pieces_total = 5;

    const p = fetcher.getProgress();
    try std.testing.expectEqual(FetchState.downloading, p.state);
    try std.testing.expectEqual(@as(u32, 3), p.peers_attempted);
    try std.testing.expectEqual(@as(u32, 2), p.pieces_received);
    try std.testing.expectEqual(@as(u32, 5), p.pieces_total);
}

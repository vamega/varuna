const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const session_mod = @import("../torrent/session.zig");
const storage = @import("../storage/root.zig");
const pw = @import("../net/peer_wire.zig");
const Hasher = @import("hasher.zig").Hasher;

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

pub const PeerState = enum {
    free,
    connecting,
    handshake_send,
    handshake_recv,
    active_recv_header,
    active_recv_body,
    disconnecting,
};

pub const Peer = struct {
    fd: posix.fd_t = -1,
    state: PeerState = .free,
    address: std.net.Address = undefined,

    // Recv state: small header buffer, then body on demand
    header_buf: [4]u8 = undefined,
    header_offset: usize = 0,
    handshake_buf: [68]u8 = undefined,
    handshake_offset: usize = 0,
    body_buf: ?[]u8 = null,
    body_offset: usize = 0,
    body_expected: usize = 0,

    // Peer wire state
    send_pending: bool = false,
    peer_choking: bool = true,
    am_interested: bool = false,
    availability_known: bool = false,
    availability: ?Bitfield = null,

    // Piece download state
    current_piece: ?u32 = null,
    piece_buf: ?[]u8 = null,
    blocks_received: u32 = 0,
    blocks_expected: u32 = 0,
    pipeline_sent: u32 = 0,
    inflight_requests: u32 = 0,
};

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    ring: linux.IoUring,
    allocator: std.mem.Allocator,
    peers: []Peer,
    peer_count: u16 = 0,
    running: bool = true,

    // Session context
    session: *const session_mod.Session,
    piece_tracker: *PieceTracker,
    shared_fds: []const posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,

    // Background hasher for SHA verification (off event loop thread)
    hasher: ?Hasher = null,

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

        const hasher = Hasher.init(allocator, hasher_threads) catch null;

        return .{
            .ring = try linux.IoUring.init(256, 0),
            .allocator = allocator,
            .peers = peers,
            .session = session,
            .piece_tracker = piece_tracker,
            .shared_fds = shared_fds,
            .info_hash = session.metainfo.info_hash,
            .peer_id = peer_id,
            .hasher = hasher,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.hasher) |*h| h.deinit();
        for (self.peers) |*peer| {
            self.cleanupPeer(peer);
        }
        self.allocator.free(self.peers);
        self.ring.deinit();
    }

    pub fn addPeer(self: *EventLoop, address: std.net.Address) !u16 {
        const slot = self.allocSlot() orelse return error.TooManyPeers;
        const peer = &self.peers[slot];
        peer.* = Peer{
            .state = .connecting,
            .address = address,
        };

        const fd = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        peer.fd = fd;

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_connect, .context = 0 });
        _ = try self.ring.connect(ud, fd, &address.any, address.getOsSockLen());

        self.peer_count += 1;
        return slot;
    }

    pub fn removePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        if (peer.current_piece) |piece_index| {
            self.piece_tracker.releasePiece(piece_index);
        }
        self.cleanupPeer(peer);
        peer.* = Peer{};
        if (self.peer_count > 0) self.peer_count -= 1;
    }

    pub fn run(self: *EventLoop) !void {
        while (self.running and !self.piece_tracker.isComplete()) {
            try self.tick();
            if (self.peer_count == 0) break;
        }
    }

    /// Run one iteration of the event loop. Blocks until at least one
    /// CQE is available. Returns the number of CQEs processed.
    pub fn tick(self: *EventLoop) !void {
        self.processHashResults();
        self.tryAssignPieces();

        _ = try self.ring.submit_and_wait(1);

        var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, 0);

        for (cqes[0..count]) |cqe| {
            self.dispatch(cqe);
        }
    }

    /// Submit a timeout SQE so that submit_and_wait returns even if
    /// no I/O completes. This allows the caller to do periodic work.
    pub fn submitTimeout(self: *EventLoop, timeout_ns: u64) !void {
        const ts = linux.kernel_timespec{
            .sec = @intCast(timeout_ns / std.time.ns_per_s),
            .nsec = @intCast(timeout_ns % std.time.ns_per_s),
        };
        const ud = encodeUserData(.{ .slot = 0, .op_type = .timeout, .context = 0 });
        _ = try self.ring.timeout(ud, &ts, 0, 0);
    }

    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    // ── CQE dispatch ──────────────────────────────────────

    fn dispatch(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        const op = decodeUserData(cqe.user_data);
        switch (op.op_type) {
            .peer_connect => self.handleConnect(op.slot, cqe),
            .peer_recv => self.handleRecv(op.slot, cqe),
            .peer_send => self.handleSend(op.slot, cqe),
            .disk_write => self.handleDiskWrite(op.slot, cqe),
            .accept, .disk_read, .http_connect, .http_send, .http_recv, .timeout, .cancel => {},
        }
    }

    fn handleConnect(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            self.removePeer(slot);
            return;
        }
        const peer = &self.peers[slot];
        peer.state = .handshake_send;

        // Build and send handshake
        var buf: [68]u8 = undefined;
        buf[0] = pw.protocol_length;
        @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
        @memset(buf[20..28], 0);
        @memcpy(buf[28..48], self.info_hash[0..]);
        @memcpy(buf[48..68], self.peer_id[0..]);
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
            self.removePeer(slot);
            return;
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
                if (!std.mem.eql(u8, peer.handshake_buf[28..48], self.info_hash[0..])) {
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
                    // Keep-alive
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
                // Allocate body buffer and start reading
                peer.body_buf = self.allocator.alloc(u8, msg_len) catch {
                    self.removePeer(slot);
                    return;
                };
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
                if (peer.body_buf) |buf| {
                    self.allocator.free(buf);
                    peer.body_buf = null;
                }
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
        // Piece write completed via io_uring -- mark piece as done.
        // The piece_index is encoded in the op context.
        const op = decodeUserData(cqe.user_data);
        const piece_index: u32 = @intCast(op.context);
        if (piece_index < self.session.pieceCount()) {
            const piece_length = self.session.layout.pieceSize(piece_index) catch 0;
            _ = self.piece_tracker.completePiece(piece_index, piece_length);
        }
        // Note: piece_buf is freed after all spans are written.
        // For simplicity, we free on the last span write.
        // TODO: track span write count for multi-span pieces.
    }

    // ── Message processing ────────────────────────────────

    fn processMessage(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const body = peer.body_buf orelse return;
        if (body.len == 0) return;

        const id = body[0];
        const payload = body[1..];

        switch (id) {
            0 => { // choke
                peer.peer_choking = true;
                // Clear pipeline state
                peer.inflight_requests = 0;
                peer.pipeline_sent = peer.blocks_received;
            },
            1 => peer.peer_choking = false, // unchoke
            2 => {}, // interested
            3 => {}, // not interested
            4 => { // have
                if (payload.len >= 4) {
                    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                    if (peer.availability) |*bf| {
                        bf.set(piece_index) catch {};
                    }
                    peer.availability_known = true;
                    self.piece_tracker.addAvailability(piece_index);
                }
            },
            5 => { // bitfield
                if (peer.availability == null) {
                    peer.availability = Bitfield.init(self.allocator, self.session.pieceCount()) catch return;
                }
                if (peer.availability) |*bf| {
                    bf.importBitfield(payload);
                }
                peer.availability_known = true;
                self.piece_tracker.addBitfieldAvailability(payload);
            },
            7 => { // piece
                if (payload.len >= 8) {
                    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                    const block_offset = std.mem.readInt(u32, payload[4..8], .big);
                    const block_data = payload[8..];

                    if (peer.current_piece != null and peer.current_piece.? == piece_index) {
                        if (peer.piece_buf) |pbuf| {
                            const start: usize = @intCast(block_offset);
                            const end = start + block_data.len;
                            if (end <= pbuf.len) {
                                @memcpy(pbuf[start..end], block_data);
                                peer.blocks_received += 1;
                                if (peer.inflight_requests > 0) peer.inflight_requests -= 1;

                                if (peer.blocks_received >= peer.blocks_expected) {
                                    self.completePieceDownload(slot);
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    // ── Piece download coordination ───────────────────────

    fn tryAssignPieces(self: *EventLoop) void {
        for (self.peers, 0..) |*peer, i| {
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
            if (peer.current_piece != null) continue;
            if (peer.peer_choking) continue;
            if (!peer.availability_known) continue;

            const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
            const piece_index = self.piece_tracker.claimPiece(peer_bf) orelse continue;

            self.startPieceDownload(@intCast(i), piece_index) catch {
                self.piece_tracker.releasePiece(piece_index);
            };
        }
    }

    fn startPieceDownload(self: *EventLoop, slot: u16, piece_index: u32) !void {
        const peer = &self.peers[slot];
        const piece_size = try self.session.layout.pieceSize(piece_index);
        const geometry = self.session.geometry();
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

        const geometry = self.session.geometry();

        while (peer.inflight_requests < pipeline_depth and peer.pipeline_sent < peer.blocks_expected) {
            const req = try geometry.requestForBlock(piece_index, peer.pipeline_sent);
            var payload: [12]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], req.piece_index, .big);
            std.mem.writeInt(u32, payload[4..8], req.piece_offset, .big);
            std.mem.writeInt(u32, payload[8..12], req.length, .big);
            try self.submitMessage(slot, 6, &payload);
            peer.pipeline_sent += 1;
            peer.inflight_requests += 1;
        }
    }

    fn completePieceDownload(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        const piece_index = peer.current_piece orelse return;
        const piece_buf = peer.piece_buf orelse return;

        // Get the expected hash for this piece
        const expected_hash = self.session.layout.pieceHash(piece_index) catch {
            self.piece_tracker.releasePiece(piece_index);
            peer.current_piece = null;
            return;
        };
        var hash: [20]u8 = undefined;
        @memcpy(&hash, expected_hash);

        if (self.hasher) |*h| {
            // Submit to background hasher thread (non-blocking)
            h.submitVerify(slot, piece_index, piece_buf, hash) catch {
                self.piece_tracker.releasePiece(piece_index);
                peer.current_piece = null;
                return;
            };
            // Don't free piece_buf -- the hasher owns it now.
            // The peer can start downloading another piece immediately.
            peer.piece_buf = null;
            peer.current_piece = null;
        } else {
            // Fallback: inline verification (blocks event loop)
            var actual: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(piece_buf[0..@intCast(peer.blocks_expected * 16384)], &actual, .{});
            // Simplified inline path -- use hasher in production
            self.piece_tracker.releasePiece(piece_index);
            peer.current_piece = null;
        }
    }

    /// Process completed hash results from the background hasher.
    /// Called each tick from the event loop.
    fn processHashResults(self: *EventLoop) void {
        const h = &(self.hasher orelse return);
        const results = h.drainResults();
        for (results) |result| {
            if (result.valid) {
                // Write verified piece to disk via io_uring
                const plan = storage.verify.planPieceVerification(self.allocator, self.session, result.piece_index) catch continue;
                defer storage.verify.freePiecePlan(self.allocator, plan);

                for (plan.spans) |span| {
                    const block = result.piece_buf[span.piece_offset .. span.piece_offset + span.length];
                    const ud = encodeUserData(.{ .slot = result.slot, .op_type = .disk_write, .context = @intCast(result.piece_index) });
                    _ = self.ring.write(ud, self.shared_fds[span.file_index], block, span.file_offset) catch continue;
                }
                // Piece completion finalized in handleDiskWrite
            } else {
                // Hash mismatch -- release piece back to pool
                self.piece_tracker.releasePiece(result.piece_index);
                self.allocator.free(result.piece_buf);
            }
        }
        h.clearResults();
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
            // For larger messages, send header then payload separately
            @memcpy(peer.handshake_buf[0..5], &header);
            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
            _ = try self.ring.send(ud, peer.fd, peer.handshake_buf[0..5], 0);
            peer.send_pending = true;
        }
    }

    fn cleanupPeer(self: *EventLoop, peer: *Peer) void {
        if (peer.fd >= 0) posix.close(peer.fd);
        if (peer.body_buf) |buf| self.allocator.free(buf);
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

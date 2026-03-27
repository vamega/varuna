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
    body_buf: ?[]u8 = null,
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

pub const TorrentContext = struct {
    session: *const session_mod.Session,
    piece_tracker: *PieceTracker,
    shared_fds: []const posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,
    complete_pieces: ?*const Bitfield = null,
    active: bool = true,
};

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    const PendingWrite = struct {
        piece_index: u32,
        torrent_id: u8,
        buf: []u8,
        spans_remaining: u32,
    };

    const PendingSend = struct {
        buf: []u8,
        slot: u16,
    };

    ring: linux.IoUring,
    allocator: std.mem.Allocator,
    peers: []Peer,
    peer_count: u16 = 0,
    running: bool = true,

    // Multi-torrent contexts
    torrents: [max_torrents]?TorrentContext = [_]?TorrentContext{null} ** max_torrents,
    torrent_count: u8 = 0,

    // Legacy single-torrent pointers (used by existing code, point to torrents[0])
    session: *const session_mod.Session,
    piece_tracker: *PieceTracker,
    shared_fds: []const posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,

    // Accept socket for seeding (-1 if not seeding)
    listen_fd: posix.fd_t = -1,

    // Complete pieces bitfield (for seeding -- which pieces we can serve)
    complete_pieces: ?*const Bitfield = null,

    // Timeout storage (must outlive the SQE)
    timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },

    // Pending disk writes: track buffers that io_uring is writing to disk.
    pending_writes: std.ArrayList(PendingWrite),

    // Pending sends: track allocated send buffers (for seed piece responses).
    pending_sends: std.ArrayList(PendingSend),

    // Background hasher for SHA verification (off event loop thread)
    last_unchoke_recalc: i64 = 0,
    hasher: ?*Hasher = null,

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

        const hasher = Hasher.create(allocator, hasher_threads) catch null;

        var el = EventLoop{
            .ring = try linux.IoUring.init(256, 0),
            .allocator = allocator,
            .peers = peers,
            .session = session,
            .piece_tracker = piece_tracker,
            .shared_fds = shared_fds,
            .info_hash = session.metainfo.info_hash,
            .peer_id = peer_id,
            .pending_writes = std.ArrayList(PendingWrite).empty,
            .pending_sends = std.ArrayList(PendingSend).empty,
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
        for (&self.torrents, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{
                    .session = session,
                    .piece_tracker = piece_tracker,
                    .shared_fds = shared_fds,
                    .info_hash = session.metainfo.info_hash,
                    .peer_id = peer_id,
                };
                self.torrent_count += 1;
                return @intCast(i);
            }
        }
        return error.TooManyTorrents;
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
        // Free any pending write/send buffers
        for (self.pending_writes.items) |pending| {
            self.allocator.free(pending.buf);
        }
        self.pending_writes.deinit(self.allocator);
        for (self.pending_sends.items) |ps| {
            self.allocator.free(ps.buf);
        }
        self.pending_sends.deinit(self.allocator);
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
        peer.fd = fd;

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_connect, .context = 0 });
        // Use peer.address (stored in slot) not the parameter (stack-local, dangling after return)
        _ = try self.ring.connect(ud, fd, &peer.address.any, peer.address.getOsSockLen());

        self.peer_count += 1;
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
        if (peer.current_piece) |piece_index| {
            self.piece_tracker.releasePiece(piece_index);
        }
        self.cleanupPeer(peer);
        peer.* = Peer{};
        if (self.peer_count > 0) self.peer_count -= 1;
    }

    pub fn run(self: *EventLoop) !void {
        const signal = @import("signal.zig");
        while (self.running and !self.piece_tracker.isComplete()) {
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
    const peer_timeout_secs: i64 = 30;
    const unchoke_interval_secs: i64 = 30;
    const max_unchoked: u32 = 4;
    const optimistic_unchoke_slots: u32 = 1;


    pub fn tick(self: *EventLoop) !void {
        self.processHashResults();
        self.checkPeerTimeouts();
        self.recalculateUnchokes();
        self.tryAssignPieces();

        // Flush any queued SQEs before waiting
        _ = self.ring.submit() catch {};
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
        self.timeout_ts = .{
            .sec = @intCast(timeout_ns / std.time.ns_per_s),
            .nsec = @intCast(timeout_ns % std.time.ns_per_s),
        };
        const ud = encodeUserData(.{ .slot = 0, .op_type = .timeout, .context = 0 });
        _ = try self.ring.timeout(ud, &self.timeout_ts, 0, 0);
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
            .accept => self.handleAccept(cqe),
            .disk_read, .http_connect, .http_send, .http_recv, .timeout, .cancel => {},
        }
    }

    fn handleAccept(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            // Accept failed, try again
            self.submitAccept() catch {};
            return;
        }
        const new_fd: posix.fd_t = @intCast(cqe.res);

        // Allocate a peer slot for the inbound connection
        const slot = self.allocSlot() orelse {
            posix.close(new_fd);
            self.submitAccept() catch {};
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
        self.submitAccept() catch {};
    }

    fn handleConnect(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
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
        // Check if this was a tracked send buffer (context=1 from servePieceRequest)
        const op = decodeUserData(cqe.user_data);
        if (op.context == 1) {
            self.freePendingSend(slot);
        }

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
            .inbound_handshake_send => {
                // Handshake sent -- send bitfield if we have pieces
                if (self.complete_pieces) |cp| {
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
                // Validate info_hash
                if (!std.mem.eql(u8, peer.handshake_buf[28..48], tc_recv.info_hash[0..])) {
                    self.removePeer(slot);
                    return;
                }
                // Send our handshake back
                peer.state = .inbound_handshake_send;
                var buf: [68]u8 = undefined;
                buf[0] = pw.protocol_length;
                @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
                @memset(buf[20..28], 0);
                @memcpy(buf[28..48], tc_recv.info_hash[0..]);
                @memcpy(buf[48..68], tc_recv.peer_id[0..]);
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
        const op = decodeUserData(cqe.user_data);
        const piece_index: u32 = @intCast(op.context);

        // Find the pending write for this piece and decrement spans_remaining
        var i: usize = 0;
        while (i < self.pending_writes.items.len) {
            const pending_w = &self.pending_writes.items[i];
            if (pending_w.piece_index == piece_index) {
                pending_w.spans_remaining -= 1;
                if (pending_w.spans_remaining == 0) {
                    // All spans written -- mark piece complete and free buffer
                    if (piece_index < self.session.pieceCount()) {
                        const piece_length = self.session.layout.pieceSize(piece_index) catch 0;
                        _ = self.piece_tracker.completePiece(piece_index, piece_length);
                    }
                    self.allocator.free(pending_w.buf);
                    _ = self.pending_writes.swapRemove(i);
                }
                return;
            }
            i += 1;
        }
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
            1 => {
                peer.peer_choking = false; // unchoke
                peer.last_activity = std.time.timestamp();
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
            3 => { peer.peer_interested = false; }, // not interested
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

                    if (peer.current_piece != null and peer.current_piece.? == piece_index) {
                        if (peer.piece_buf) |pbuf| {
                            const start: usize = @intCast(block_offset);
                            const end = start + block_data.len;
                            if (end <= pbuf.len) {
                                @memcpy(pbuf[start..end], block_data);
                                peer.blocks_received += 1;
                                peer.last_activity = std.time.timestamp();
                                peer.bytes_downloaded_from += block_data.len;
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
                    self.submitMessage(slot, 1, &.{}) catch {}; // unchoke
                }
                unchoked += 1;
            } else {
                if (!peer.am_choking) {
                    peer.am_choking = true;
                    self.submitMessage(slot, 0, &.{}) catch {}; // choke
                }
            }
        }
    }

    // ── Piece upload (seed mode) ─────────────────────────

    fn servePieceRequest(self: *EventLoop, slot: u16, payload: []const u8) void {
        const piece_index = std.mem.readInt(u32, payload[0..4], .big);
        const block_offset = std.mem.readInt(u32, payload[4..8], .big);
        const block_length = std.mem.readInt(u32, payload[8..12], .big);

        // Validate
        const cp = self.complete_pieces orelse return;
        if (!cp.has(piece_index)) return;
        const piece_size = self.session.layout.pieceSize(piece_index) catch return;
        if (block_offset + block_length > piece_size) return;

        // Read piece data from disk
        const plan = storage.verify.planPieceVerification(self.allocator, self.session, piece_index) catch return;
        defer storage.verify.freePiecePlan(self.allocator, plan);

        const read_buf = self.allocator.alloc(u8, piece_size) catch return;
        defer self.allocator.free(read_buf);

        // Read from disk (blocking pread -- small, from page cache)
        // TODO: use io_uring pread for fully async disk read
        for (plan.spans) |span| {
            const block = read_buf[span.piece_offset .. span.piece_offset + span.length];
            _ = posix.pread(self.shared_fds[span.file_index], block, span.file_offset) catch return;
        }

        // Build complete piece message in one buffer: 4-byte len + id(7) + piece_index + block_offset + data
        const msg_len: u32 = 1 + 8 + block_length;
        const total_len: usize = 4 + @as(usize, msg_len);
        const send_buf = self.allocator.alloc(u8, total_len) catch return;

        std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
        send_buf[4] = 7;
        std.mem.writeInt(u32, send_buf[5..9], piece_index, .big);
        std.mem.writeInt(u32, send_buf[9..13], block_offset, .big);
        @memcpy(send_buf[13..total_len], read_buf[@intCast(block_offset)..][0..block_length]);

        const peer = &self.peers[slot];
        peer.bytes_uploaded_to += block_length;

        // Track the send buffer for cleanup after CQE
        self.pending_sends.append(self.allocator, .{
            .buf = send_buf,
            .slot = slot,
        }) catch {
            self.allocator.free(send_buf);
            return;
        };

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 }); // context=1 means tracked send
        _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
            self.allocator.free(send_buf);
            return;
        };
        peer.send_pending = true;
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

        if (self.hasher) |h| {
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
    pub fn processHashResults(self: *EventLoop) void {
        const h = self.hasher orelse return;
        const results = h.drainResults();
        for (results) |result| {
            if (result.valid) {
                // Write verified piece to disk via io_uring
                const plan = storage.verify.planPieceVerification(self.allocator, self.session, result.piece_index) catch {
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
                self.pending_writes.append(self.allocator, .{
                    .piece_index = result.piece_index,
                    .torrent_id = 0, // TODO: get from hasher result
                    .buf = result.piece_buf,
                    .spans_remaining = span_count,
                }) catch {
                    self.allocator.free(result.piece_buf);
                    continue;
                };

                for (plan.spans) |span| {
                    const block = result.piece_buf[span.piece_offset .. span.piece_offset + span.length];
                    const ud = encodeUserData(.{ .slot = result.slot, .op_type = .disk_write, .context = @intCast(result.piece_index) });
                    _ = self.ring.write(ud, self.shared_fds[span.file_index], block, span.file_offset) catch continue;
                }
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

    fn freePendingSend(self: *EventLoop, slot: u16) void {
        var i: usize = 0;
        while (i < self.pending_sends.items.len) {
            if (self.pending_sends.items[i].slot == slot) {
                self.allocator.free(self.pending_sends.items[i].buf);
                _ = self.pending_sends.swapRemove(i);
                return;
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

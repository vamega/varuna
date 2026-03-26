const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;

const max_peers: u16 = 4096;
const cqe_batch_size = 64;

// ── User data encoding ────────────────────────────────────
// Pack operation context into 64-bit user_data for CQE dispatch.
//   bits [63:48] = slot index (u16)
//   bits [47:40] = op type (u8)
//   bits [39:0]  = op context (u40)

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

// ── Peer slot ─────────────────────────────────────────────

pub const PeerState = enum {
    free,
    connecting,
    handshake_send,
    handshake_recv,
    active,
    disconnecting,
};

pub const Peer = struct {
    fd: posix.fd_t = -1,
    state: PeerState = .free,
    address: std.net.Address = undefined,
    recv_buf: [4 + 1024 * 1024]u8 = undefined, // message length + max message
    recv_offset: usize = 0,
    recv_expected: usize = 0,
    send_pending: bool = false,
    am_interested: bool = false,
    peer_choking: bool = true,
    availability: ?*Bitfield = null,
    current_piece: ?u32 = null,
};

// ── Event loop ────────────────────────────────────────────

pub const EventLoop = struct {
    ring: linux.IoUring,
    allocator: std.mem.Allocator,
    peers: [max_peers]Peer,
    peer_count: u16 = 0,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        return .{
            .ring = try linux.IoUring.init(256, 0),
            .allocator = allocator,
            .peers = [_]Peer{.{}} ** max_peers,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        // Close any open peer fds
        for (&self.peers) |*peer| {
            if (peer.state != .free and peer.fd >= 0) {
                posix.close(peer.fd);
                peer.state = .free;
            }
        }
        self.ring.deinit();
    }

    /// Allocate a peer slot and initiate a connect.
    pub fn addPeer(self: *EventLoop, address: std.net.Address) !u16 {
        const slot = self.allocSlot() orelse return error.TooManyPeers;
        const peer = &self.peers[slot];
        peer.* = .{
            .state = .connecting,
            .address = address,
        };

        // Create socket
        const fd = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        peer.fd = fd;

        // Submit connect SQE
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_connect, .context = 0 });
        _ = try self.ring.connect(ud, fd, &address.any, address.getOsSockLen());

        self.peer_count += 1;
        return slot;
    }

    /// Remove a peer and close its socket.
    pub fn removePeer(self: *EventLoop, slot: u16) void {
        const peer = &self.peers[slot];
        if (peer.fd >= 0) {
            posix.close(peer.fd);
        }
        if (peer.availability) |bf| {
            bf.deinit(self.allocator);
            self.allocator.destroy(bf);
        }
        peer.* = .{};
        if (self.peer_count > 0) self.peer_count -= 1;
    }

    /// Run the event loop until stopped.
    pub fn run(self: *EventLoop) !void {
        while (self.running) {
            _ = try self.ring.submit_and_wait(1);

            var cqes: [cqe_batch_size]linux.io_uring_cqe = undefined;
            const count = try self.ring.copy_cqes(&cqes, 0);

            for (cqes[0..count]) |cqe| {
                self.dispatch(cqe);
            }
        }
    }

    /// Stop the event loop.
    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }

    fn dispatch(self: *EventLoop, cqe: linux.io_uring_cqe) void {
        const op = decodeUserData(cqe.user_data);
        switch (op.op_type) {
            .peer_connect => self.handlePeerConnect(op.slot, cqe),
            .peer_recv => self.handlePeerRecv(op.slot, cqe),
            .peer_send => self.handlePeerSend(op.slot, cqe),
            .accept => {}, // TODO
            .disk_read => {}, // TODO
            .disk_write => {}, // TODO
            .http_connect => {}, // TODO
            .http_send => {}, // TODO
            .http_recv => {}, // TODO
            .timeout => {}, // TODO
            .cancel => {},
        }
    }

    fn handlePeerConnect(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        const peer = &self.peers[slot];
        if (cqe.res < 0) {
            // Connect failed
            self.removePeer(slot);
            return;
        }
        // Connect succeeded -- start handshake
        peer.state = .handshake_send;
        self.submitHandshakeSend(slot) catch {
            self.removePeer(slot);
        };
    }

    fn handlePeerSend(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        const peer = &self.peers[slot];
        if (cqe.res <= 0) {
            self.removePeer(slot);
            return;
        }
        peer.send_pending = false;

        switch (peer.state) {
            .handshake_send => {
                // Handshake sent, now recv the peer's handshake
                peer.state = .handshake_recv;
                peer.recv_offset = 0;
                peer.recv_expected = 68; // BT handshake is 68 bytes
                self.submitRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .active => {
                // Send completed, can send more if needed
            },
            else => {},
        }
    }

    fn handlePeerRecv(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
        const peer = &self.peers[slot];
        if (cqe.res <= 0) {
            self.removePeer(slot);
            return;
        }
        const n: usize = @intCast(cqe.res);
        peer.recv_offset += n;

        switch (peer.state) {
            .handshake_recv => {
                if (peer.recv_offset < peer.recv_expected) {
                    // Partial handshake, keep reading
                    self.submitRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Full handshake received -- validate and transition to active
                // TODO: validate info_hash
                peer.state = .active;
                peer.recv_offset = 0;
                peer.recv_expected = 4; // message length prefix
                self.submitRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            .active => {
                // Message framing: first 4 bytes are length, then body
                // TODO: full message parsing
                if (peer.recv_offset < peer.recv_expected) {
                    self.submitRecv(slot) catch {
                        self.removePeer(slot);
                    };
                    return;
                }
                // Message complete -- process and read next
                peer.recv_offset = 0;
                peer.recv_expected = 4;
                self.submitRecv(slot) catch {
                    self.removePeer(slot);
                };
            },
            else => {},
        }
    }

    // ── SQE submission helpers ─────────────────────────────

    fn submitHandshakeSend(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        // Build handshake in send buffer area (reuse recv_buf temporarily)
        const pw = @import("../net/peer_wire.zig");
        var buf: [68]u8 = undefined;
        buf[0] = pw.protocol_length;
        @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
        @memset(buf[20..28], 0); // reserved
        // TODO: copy info_hash and peer_id from session context
        @memset(buf[28..48], 0); // placeholder info_hash
        @memset(buf[48..68], 0); // placeholder peer_id

        @memcpy(peer.recv_buf[0..68], &buf);
        peer.send_pending = true;

        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
        _ = try self.ring.send(ud, peer.fd, peer.recv_buf[0..68], 0);
    }

    fn submitRecv(self: *EventLoop, slot: u16) !void {
        const peer = &self.peers[slot];
        const buf = peer.recv_buf[peer.recv_offset..peer.recv_expected];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
        _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0);
    }

    fn allocSlot(self: *EventLoop) ?u16 {
        for (&self.peers, 0..) |*peer, i| {
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

test "event loop init and deinit" {
    var loop = EventLoop.init(std.testing.allocator) catch return error.SkipZigTest;
    defer loop.deinit();

    try std.testing.expectEqual(@as(u16, 0), loop.peer_count);
}

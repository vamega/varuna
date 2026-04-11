const std = @import("std");
const utp = @import("utp.zig");
const Header = utp.Header;
const UtpSocket = utp.UtpSocket;
const State = utp.State;

/// Maximum number of concurrent uTP connections.
pub const max_connections: u16 = 512;

/// UtpManager multiplexes many uTP connections over a single UDP socket.
/// It routes incoming packets by connection_id to the correct UtpSocket,
/// handles SYN packets for new inbound connections, and provides a
/// connect/accept API.
pub const UtpManager = struct {
    /// Connection table indexed by slot. Sockets are heap-allocated on
    /// demand so that zero-connection baseline is near zero (512 pointers
    /// = 4 KiB instead of 24 MiB for 4096 inline UtpSocket structs).
    connections: [max_connections]?*UtpSocket = [_]?*UtpSocket{null} ** max_connections,

    /// Whether each slot is in use.
    slot_active: [max_connections]bool = [_]bool{false} ** max_connections,

    /// Number of active connections.
    active_count: u16 = 0,

    /// Pending inbound connections (accept queue).
    accept_queue: [accept_queue_size]u16 = undefined,
    accept_head: u16 = 0,
    accept_tail: u16 = 0,

    /// Allocator for any dynamic allocations (reorder buffers, etc.).
    allocator: std.mem.Allocator,

    const accept_queue_size: u16 = 128;

    pub fn init(allocator: std.mem.Allocator) UtpManager {
        return .{
            .allocator = allocator,
        };
    }

    /// Free all heap-allocated sockets. Call before destroying the manager.
    pub fn deinit(self: *UtpManager) void {
        for (0..max_connections) |i| {
            if (self.connections[i]) |sock| {
                sock.deinit();
                self.allocator.destroy(sock);
                self.connections[i] = null;
            }
        }
        self.active_count = 0;
    }

    /// Initiate an outbound uTP connection. Returns the slot index and
    /// the SYN packet to send.
    pub fn connect(self: *UtpManager, remote: std.net.Address, now_us: u32) !ConnectResult {
        const slot = self.allocSlot() orelse return error.TooManyConnections;
        const sock = self.connections[slot].?;
        sock.remote_addr = remote;
        sock.allocator = self.allocator;

        const syn_pkt = sock.connect(now_us);

        return .{
            .slot = slot,
            .syn_packet = syn_pkt,
            .remote = remote,
        };
    }

    /// Accept a pending inbound connection. Returns null if the accept
    /// queue is empty.
    pub fn accept(self: *UtpManager) ?u16 {
        if (self.accept_head == self.accept_tail) return null;
        const slot = self.accept_queue[self.accept_head % accept_queue_size];
        self.accept_head +%= 1;
        return slot;
    }

    /// Process a received UDP datagram. Routes to the correct connection
    /// or creates a new inbound connection for SYN packets.
    /// Returns an optional response packet and the associated slot.
    pub fn processPacket(self: *UtpManager, data: []const u8, remote: std.net.Address, now_us: u32) ?PacketResult {
        const hdr = Header.decode(data) orelse return null;
        const payload = if (data.len > Header.size) data[Header.size..] else &[_]u8{};

        // Route by connection_id.
        if (hdr.packet_type == .st_syn) {
            return self.handleSyn(hdr, remote, now_us);
        }

        // For non-SYN packets, look up by connection_id matching recv_id.
        const slot = self.findByRecvIdRemote(hdr.connection_id, remote) orelse {
            // Unknown connection -- send RESET.
            return self.makeResetResponse(hdr, remote, now_us);
        };

        const sock = self.connections[slot].?;
        const result = sock.processPacket(hdr, payload, now_us);

        // Check for connection close.
        if (sock.state == .closed or sock.state == .reset) {
            self.freeSlot(slot);
        }

        return .{
            .slot = slot,
            .response = result.response,
            .data = result.data,
            .data_len = result.data_len,
            .remote = remote,
            .new_connection = false,
        };
    }

    /// Close a connection gracefully by sending FIN.
    pub fn close(self: *UtpManager, slot: u16, now_us: u32) ?[Header.size]u8 {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        const sock = self.connections[slot].?;
        const fin = sock.createFinPacket(now_us);
        return fin;
    }

    /// Force-close a connection with RESET.
    pub fn reset(self: *UtpManager, slot: u16, now_us: u32) ?[Header.size]u8 {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        const sock = self.connections[slot].?;
        const rst = sock.createResetPacket(now_us);
        self.freeSlot(slot);
        return rst;
    }

    /// Create a data packet for a connection. Returns header bytes or
    /// null if the window is full.
    pub fn createDataPacket(self: *UtpManager, slot: u16, payload_len: u16, now_us: u32) ?[Header.size]u8 {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        return self.connections[slot].?.createDataPacket(payload_len, now_us);
    }

    /// Get a reference to a socket by slot.
    pub fn getSocket(self: *UtpManager, slot: u16) ?*UtpSocket {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        return self.connections[slot];
    }

    /// Get the remote address for a connection.
    pub fn getRemoteAddress(self: *const UtpManager, slot: u16) ?std.net.Address {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        return self.connections[slot].?.remote_addr;
    }

    /// Check all connections for timeouts. Returns a list of slots that
    /// timed out (caller should retransmit or close them).
    pub fn checkTimeouts(self: *UtpManager, now_us: u32, out_buf: []u16) u16 {
        var count: u16 = 0;
        for (0..max_connections) |i| {
            if (!self.slot_active[i]) continue;
            const slot: u16 = @intCast(i);
            const sock = self.connections[slot].?;
            if (sock.isTimedOut(now_us)) {
                sock.handleTimeout();
                if (count < out_buf.len) {
                    out_buf[count] = slot;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// Collect retransmission packets from all connections that timed out.
    /// Returns entries with the data to resend and the remote address.
    pub fn collectRetransmits(self: *UtpManager, now_us: u32, out: []RetransmitResult) u16 {
        var count: u16 = 0;
        for (0..max_connections) |i| {
            if (!self.slot_active[i]) continue;
            const slot: u16 = @intCast(i);
            const sock = self.connections[slot].?;

            var entries: [8]utp.RetransmitEntry = undefined;
            const n = sock.collectRetransmits(&entries, now_us);
            for (entries[0..n]) |entry| {
                if (count >= out.len) return count;
                out[count] = .{
                    .slot = slot,
                    .data = entry.data,
                    .remote = sock.remote_addr,
                };
                count += 1;
            }
        }
        return count;
    }

    /// Returns the number of active connections.
    pub fn connectionCount(self: *const UtpManager) u16 {
        return self.active_count;
    }

    // ── Internal ─────────────────────────────────────────

    fn handleSyn(self: *UtpManager, hdr: Header, remote: std.net.Address, now_us: u32) ?PacketResult {
        // Check for duplicate SYN (existing connection with matching recv_id).
        const existing = self.findByRecvIdRemote(hdr.connection_id +% 1, remote);
        if (existing) |slot| {
            // Resend SYN-ACK.
            const response = self.connections[slot].?.makeAck(now_us);
            return .{
                .slot = slot,
                .response = response,
                .data = null,
                .data_len = 0,
                .remote = remote,
                .new_connection = false,
            };
        }

        const slot = self.allocSlot() orelse return null;
        const sock = self.connections[slot].?;
        sock.remote_addr = remote;
        sock.allocator = self.allocator;

        const syn_ack = sock.acceptSyn(hdr, now_us);

        // Enqueue for accept().
        const queue_idx = self.accept_tail % accept_queue_size;
        self.accept_queue[queue_idx] = slot;
        self.accept_tail +%= 1;

        return .{
            .slot = slot,
            .response = syn_ack,
            .data = null,
            .data_len = 0,
            .remote = remote,
            .new_connection = true,
        };
    }

    fn findByRecvIdRemote(self: *const UtpManager, conn_id: u16, remote: std.net.Address) ?u16 {
        for (self.slot_active, self.connections, 0..) |active, maybe_conn, i| {
            if (!active) continue;
            const conn = maybe_conn orelse continue;
            if (conn.recv_id != conn_id) continue;
            if (@import("address.zig").addressEql(&conn.remote_addr, &remote)) {
                return @intCast(i);
            }
        }
        return null;
    }

    fn makeResetResponse(self: *UtpManager, hdr: Header, remote: std.net.Address, now_us: u32) ?PacketResult {
        _ = self;
        const rst = Header{
            .packet_type = .st_reset,
            .extension = .none,
            .connection_id = hdr.connection_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = 0,
            .wnd_size = 0,
            .seq_nr = 0,
            .ack_nr = hdr.seq_nr,
        };
        return .{
            .slot = 0,
            .response = rst.encode(),
            .data = null,
            .data_len = 0,
            .remote = remote,
            .new_connection = false,
        };
    }

    fn allocSlot(self: *UtpManager) ?u16 {
        if (self.active_count >= max_connections) return null;
        for (0..max_connections) |i| {
            if (!self.slot_active[i]) {
                const sock = self.allocator.create(UtpSocket) catch return null;
                sock.* = .{};
                self.connections[i] = sock;
                self.slot_active[i] = true;
                self.active_count += 1;
                return @intCast(i);
            }
        }
        return null;
    }

    fn freeSlot(self: *UtpManager, slot: u16) void {
        if (slot >= max_connections or !self.slot_active[slot]) return;
        if (self.connections[slot]) |sock| {
            sock.deinit();
            self.allocator.destroy(sock);
            self.connections[slot] = null;
        }
        self.slot_active[slot] = false;
        self.active_count -= 1;
    }
};

/// Result of collectRetransmits: a packet that needs re-sending.
pub const RetransmitResult = struct {
    slot: u16,
    data: []u8,
    remote: std.net.Address,
};

/// Result of a connect() call.
pub const ConnectResult = struct {
    slot: u16,
    syn_packet: [Header.size]u8,
    remote: std.net.Address,
};

/// Result of processing a received packet.
pub const PacketResult = struct {
    slot: u16,
    response: ?[Header.size]u8,
    data: ?[]const u8,
    data_len: u16,
    remote: std.net.Address,
    new_connection: bool,
};

// ── Tests ─────────────────────────────────────────────────

test "manager connect allocates slot and produces SYN" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const result = try mgr.connect(remote, 1_000_000);
    try std.testing.expect(result.slot < max_connections);
    try std.testing.expectEqual(@as(u16, 1), mgr.connectionCount());

    const hdr = Header.decode(&result.syn_packet).?;
    try std.testing.expectEqual(utp.PacketType.st_syn, hdr.packet_type);
}

test "manager processes SYN and queues for accept" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);

    // Build a SYN packet.
    const syn_hdr = Header{
        .packet_type = .st_syn,
        .extension = .none,
        .connection_id = 500,
        .timestamp_us = 1_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 0,
    };
    const syn_buf = syn_hdr.encode();

    const result = mgr.processPacket(&syn_buf, remote, 1_001_000);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.new_connection);
    try std.testing.expect(result.?.response != null);

    // Accept should return the slot.
    const slot = mgr.accept();
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(result.?.slot, slot.?);

    // Connection should be in connected state.
    const sock = mgr.getSocket(slot.?).?;
    try std.testing.expectEqual(State.connected, sock.state);
}

test "manager resets unknown connection_id" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);

    // Send a DATA packet to an unknown connection.
    const data_hdr = Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 9999,
        .timestamp_us = 1_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 5,
        .ack_nr = 0,
    };
    const buf = data_hdr.encode();

    const result = mgr.processPacket(&buf, remote, 1_001_000);
    try std.testing.expect(result != null);
    // Should get a RESET response.
    const resp = Header.decode(&result.?.response.?).?;
    try std.testing.expectEqual(utp.PacketType.st_reset, resp.packet_type);
}

test "manager full handshake between two managers" {
    var client_mgr = UtpManager.init(std.testing.allocator);
    defer client_mgr.deinit();
    var server_mgr = UtpManager.init(std.testing.allocator);
    defer server_mgr.deinit();
    const client_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 5000);
    const server_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6000);

    // Client sends SYN.
    const conn = try client_mgr.connect(server_addr, 1_000_000);

    // Server receives SYN.
    const srv_result = server_mgr.processPacket(&conn.syn_packet, client_addr, 1_001_000);
    try std.testing.expect(srv_result != null);
    try std.testing.expect(srv_result.?.new_connection);

    // Server accept.
    const srv_slot = server_mgr.accept().?;
    try std.testing.expectEqual(State.connected, server_mgr.getSocket(srv_slot).?.state);

    // Client receives SYN-ACK.
    const cli_result = client_mgr.processPacket(&srv_result.?.response.?, server_addr, 1_002_000);
    try std.testing.expect(cli_result != null);
    try std.testing.expectEqual(State.connected, client_mgr.getSocket(conn.slot).?.state);
}

test "manager close sends FIN" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const conn = try mgr.connect(remote, 1_000_000);
    // Manually transition to connected for testing.
    mgr.connections[conn.slot].?.state = .connected;

    const fin = mgr.close(conn.slot, 2_000_000);
    try std.testing.expect(fin != null);

    const hdr = Header.decode(&fin.?).?;
    try std.testing.expectEqual(utp.PacketType.st_fin, hdr.packet_type);
}

test "manager connection count tracks correctly" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    try std.testing.expectEqual(@as(u16, 0), mgr.connectionCount());

    const c1 = try mgr.connect(remote, 1_000_000);
    try std.testing.expectEqual(@as(u16, 1), mgr.connectionCount());

    const c2 = try mgr.connect(remote, 1_000_000);
    try std.testing.expectEqual(@as(u16, 2), mgr.connectionCount());

    // Reset one connection -- should free the slot.
    _ = mgr.reset(c1.slot, 2_000_000);
    try std.testing.expectEqual(@as(u16, 1), mgr.connectionCount());

    _ = mgr.reset(c2.slot, 2_000_000);
    try std.testing.expectEqual(@as(u16, 0), mgr.connectionCount());
}

test "manager connect sets allocator on socket" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const conn = try mgr.connect(remote, 1_000_000);
    const sock = mgr.getSocket(conn.slot).?;
    try std.testing.expect(sock.allocator != null);

    // Clean up.
    _ = mgr.reset(conn.slot, 2_000_000);
}

test "manager handshake with retransmission and data exchange" {
    var client_mgr = UtpManager.init(std.testing.allocator);
    defer client_mgr.deinit();
    var server_mgr = UtpManager.init(std.testing.allocator);
    defer server_mgr.deinit();
    const client_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 5000);
    const server_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6000);

    // Client connects.
    const conn = try client_mgr.connect(server_addr, 1_000_000);
    const client_sock = client_mgr.getSocket(conn.slot).?;
    try std.testing.expectEqual(@as(u16, 1), client_sock.out_buf_count);

    // Server receives SYN.
    const srv_result = server_mgr.processPacket(&conn.syn_packet, client_addr, 1_001_000).?;
    try std.testing.expect(srv_result.new_connection);
    _ = server_mgr.accept().?;

    // Client receives SYN-ACK -- SYN should be acked.
    _ = client_mgr.processPacket(&srv_result.response.?, server_addr, 1_002_000);
    try std.testing.expectEqual(utp.State.connected, client_sock.state);
    try std.testing.expectEqual(@as(u16, 0), client_sock.out_buf_count);

    // Client sends data.
    const payload = "hello";
    const hdr_bytes = client_mgr.createDataPacket(conn.slot, @intCast(payload.len), 1_003_000);
    try std.testing.expect(hdr_bytes != null);

    // Buffer the data packet for retransmission.
    const pkt_seq = std.mem.readInt(u16, hdr_bytes.?[16..18], .big);
    var datagram: [utp.Header.size + payload.len]u8 = undefined;
    @memcpy(datagram[0..utp.Header.size], &hdr_bytes.?);
    @memcpy(datagram[utp.Header.size..], payload);
    client_sock.bufferSentPacket(pkt_seq, &datagram, @intCast(payload.len), 1_003_000);

    try std.testing.expectEqual(@as(u16, 1), client_sock.out_buf_count);

    // Clean up.
    _ = client_mgr.reset(conn.slot, 3_000_000);
}

test "manager collectRetransmits returns timed-out packets" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const conn = try mgr.connect(remote, 1_000_000);
    const sock = mgr.getSocket(conn.slot).?;

    // Manually transition to connected and buffer a data packet.
    sock.state = .connected;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    const hdr = sock.createDataPacket(50, 2_000_000) orelse return error.WindowBlocked;
    var datagram: [utp.Header.size + 50]u8 = undefined;
    @memcpy(datagram[0..utp.Header.size], &hdr);
    @memset(datagram[utp.Header.size..], 0xAA);
    sock.bufferSentPacket(10, &datagram, 50, 2_000_000);

    // Simulate timeout.
    var timeout_buf: [64]u16 = undefined;
    // Advance time past RTO (initial 1s).
    const timeout_count = mgr.checkTimeouts(3_500_000, &timeout_buf);
    try std.testing.expect(timeout_count > 0);

    // Collect retransmits.
    var retransmits: [16]RetransmitResult = undefined;
    const retx_count = mgr.collectRetransmits(3_500_000, &retransmits);
    try std.testing.expect(retx_count > 0);
    try std.testing.expectEqual(conn.slot, retransmits[0].slot);

    // Clean up.
    _ = mgr.reset(conn.slot, 4_000_000);
}

test "manager freeSlot cleans up outbound buffers" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const conn = try mgr.connect(remote, 1_000_000);

    // SYN is buffered with allocator-owned data.
    const sock = mgr.getSocket(conn.slot).?;
    try std.testing.expect(sock.out_buf[sock.out_seq_start % 128].packet_buf != null);

    // Reset frees the slot and the outbound buffers.
    _ = mgr.reset(conn.slot, 2_000_000);
    try std.testing.expectEqual(@as(u16, 0), mgr.connectionCount());
}

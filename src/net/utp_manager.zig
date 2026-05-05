const std = @import("std");
const utp = @import("utp.zig");
const UtpPacketPool = @import("utp_packet_pool.zig").UtpPacketPool;
const Header = utp.Header;
const UtpSocket = utp.UtpSocket;
const State = utp.State;
const Random = @import("../runtime/random.zig").Random;

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
    connections: [max_connections]?*UtpSocket = @as([max_connections]?*UtpSocket, @splat(null)),

    /// Whether each slot is in use.
    slot_active: [max_connections]bool = @as([max_connections]bool, @splat(false)),

    /// Number of active connections.
    active_count: u16 = 0,

    /// Pending inbound connections (accept queue).
    accept_queue: [accept_queue_size]u16 = undefined,
    accept_head: u16 = 0,
    accept_tail: u16 = 0,

    /// Allocator for any dynamic allocations (reorder buffers, etc.).
    allocator: std.mem.Allocator,

    settings: utp.UtpSettings = .{},
    packet_pool: UtpPacketPool,

    const accept_queue_size: u16 = 128;

    pub fn init(allocator: std.mem.Allocator) UtpManager {
        return initWithSettingsNoPrealloc(allocator, .{});
    }

    pub fn initWithSettingsNoPrealloc(allocator: std.mem.Allocator, settings: utp.UtpSettings) UtpManager {
        return .{
            .allocator = allocator,
            .settings = settings,
            .packet_pool = UtpPacketPool.initEmpty(allocator, .{
                .initial_bytes = settings.packet_pool_initial_bytes,
                .max_bytes = settings.packet_pool_max_bytes,
                .mtu_slot_bytes = utp.max_datagram,
            }),
        };
    }

    pub fn initWithSettings(allocator: std.mem.Allocator, settings: utp.UtpSettings, preallocate_pool: bool) !UtpManager {
        var mgr = initWithSettingsNoPrealloc(allocator, settings);
        errdefer mgr.deinit();
        if (preallocate_pool) {
            try mgr.packet_pool.preallocate(settings.packet_pool_initial_bytes);
        }
        return mgr;
    }

    pub fn ensurePacketPoolPreallocated(self: *UtpManager) !void {
        try self.packet_pool.preallocate(self.settings.packet_pool_initial_bytes);
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
        self.packet_pool.deinit();
        self.active_count = 0;
    }

    /// Initiate an outbound uTP connection. Returns the slot index and
    /// the SYN packet to send.
    pub fn connect(self: *UtpManager, random: *Random, remote: std.net.Address, now_us: u32) !ConnectResult {
        const slot = self.allocSlot() orelse return error.TooManyConnections;
        const sock = self.connections[slot].?;
        sock.remote_addr = remote;
        sock.allocator = self.allocator;

        const syn_pkt = sock.connect(random, now_us) catch |err| {
            self.freeSlot(slot);
            return err;
        };

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
        const raw_payload = if (data.len > Header.size) data[Header.size..] else &[_]u8{};

        // Walk and strip any uTP extension headers. BEP 29's extension
        // chain is `(next_ext: u8, len: u8, ext_data: [len]u8)*` placed
        // immediately after the main header; the BT framing layer must
        // see only what follows the last extension. Skipping the chain
        // also means a peer that sets `hdr.extension = selective_ack`
        // with a chunk of BT keepalive bytes after the SACK bitmask gets
        // its BT bytes interpreted correctly instead of fed through with
        // SACK header bytes mixed in.
        //
        // Truncated chains (ext_len > remaining bytes) are rejected by
        // returning null — the daemon drops the malformed datagram.
        const payload = stripExtensions(hdr.extension, raw_payload) orelse return null;
        const sack = findSelectiveAck(hdr.extension, raw_payload);

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
        const result = sock.processPacketWithSack(hdr, payload, now_us, sack);

        var packet_result = PacketResult{
            .slot = slot,
            .response = result.response,
            .response_len = result.response_len,
            .data = result.data,
            .data_len = result.data_len,
            .reorder_delivered = result.reorder_delivered,
            .reorder_data = result.reorder_data,
            .remote = remote,
            .new_connection = false,
        };

        // Check for connection close. Note: freeSlot destroys the
        // socket and frees `sock.delivered_payloads`, so any slices
        // we copied into `packet_result.reorder_data` would dangle.
        // The protocol guarantees no data is delivered for a closed/
        // reset socket — `processPacket` short-circuits in `.st_fin`
        // and `.st_reset` before reaching the data path — so an
        // empty `reorder_data` is the only safe outcome here.
        if (sock.state == .closed or sock.state == .reset) {
            packet_result.reorder_delivered = 0;
            packet_result.reorder_data = @as([utp.max_reorder_buf]?[]const u8, @splat(null));
            self.freeSlot(slot);
        }

        return packet_result;
    }

    /// Close a connection gracefully by sending FIN.
    pub fn close(self: *UtpManager, slot: u16, now_us: u32) !?[Header.size]u8 {
        if (slot >= max_connections or !self.slot_active[slot]) return null;
        const sock = self.connections[slot].?;
        const fin = try sock.createFinPacket(now_us);
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

    /// Collect outbound uTP connections whose SYN has not been confirmed
    /// before the connect deadline. This is intentionally separate from
    /// retransmission timeout handling so a large batch of timed-out sockets
    /// cannot strand half-open peers behind a small retransmit buffer.
    pub fn checkUnconfirmedConnectTimeouts(self: *UtpManager, now_us: u32, out_buf: []u16) u16 {
        var count: u16 = 0;
        for (0..max_connections) |i| {
            if (!self.slot_active[i]) continue;
            const slot: u16 = @intCast(i);
            const sock = self.connections[slot].?;
            if (!sock.unconfirmedConnectTimedOut(now_us)) continue;
            if (count >= out_buf.len) return count;
            out_buf[count] = slot;
            count += 1;
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
            const response = self.connections[slot].?.makeAckPacket(now_us);
            return .{
                .slot = slot,
                .response = response.bytes,
                .response_len = response.len,
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
            .response = utp.AckPacket.fromHeader(syn_ack).bytes,
            .response_len = Header.size,
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
            .response = utp.AckPacket.fromHeader(rst.encode()).bytes,
            .response_len = Header.size,
            .data = null,
            .data_len = 0,
            .remote = remote,
            .new_connection = false,
        };
    }

    /// Walk a uTP extension chain starting from `initial_ext`, consuming
    /// each `(next_ext: u8, len: u8, [len]u8)` header in turn. Returns
    /// the trailing slice (the BT framing layer's payload) once a
    /// `next_ext == .none` terminator is reached, or null if the chain
    /// is truncated relative to the datagram length.
    ///
    /// Each iteration consumes at least 2 bytes (the per-extension
    /// header), so the loop is bounded by `payload.len / 2` — no
    /// explicit iteration cap is needed.
    fn stripExtensions(initial_ext: utp.Extension, payload: []const u8) ?[]const u8 {
        var current_ext = initial_ext;
        var remaining = payload;
        while (current_ext != .none) {
            if (remaining.len < 2) return null;
            const next_ext: utp.Extension = @enumFromInt(remaining[0]);
            const ext_len: usize = remaining[1];
            // Bound the per-extension length by the SACK cap so a
            // peer-controlled `len` of 36/.../252 (multiple of 4, > 32)
            // can't sneak past as an unknown-extension skip — keeps the
            // wire-side bound consistent with `SelectiveAck.decode`.
            // For truly unknown extensions (`_`), still trust the
            // declared length since we don't know its semantics —
            // the truncation check on `remaining.len < 2 + ext_len`
            // is the only safety net there.
            if (current_ext == .selective_ack and ext_len > utp.sack_bitmask_max) return null;
            if (remaining.len < 2 + ext_len) return null;
            remaining = remaining[2 + ext_len ..];
            current_ext = next_ext;
        }
        return remaining;
    }

    fn findSelectiveAck(initial_ext: utp.Extension, payload: []const u8) ?utp.SelectiveAck {
        var current_ext = initial_ext;
        var remaining = payload;
        while (current_ext != .none) {
            if (remaining.len < 2) return null;
            const next_ext: utp.Extension = @enumFromInt(remaining[0]);
            const ext_len: usize = remaining[1];
            if (remaining.len < 2 + ext_len) return null;
            if (current_ext == .selective_ack) {
                return utp.SelectiveAck.decode(remaining[0 .. 2 + ext_len]);
            }
            remaining = remaining[2 + ext_len ..];
            current_ext = next_ext;
        }
        return null;
    }

    fn allocSlot(self: *UtpManager) ?u16 {
        if (self.active_count >= max_connections) return null;
        for (0..max_connections) |i| {
            if (!self.slot_active[i]) {
                const sock = self.allocator.create(UtpSocket) catch return null;
                sock.* = .{};
                sock.applySettings(self.settings);
                sock.packet_pool = &self.packet_pool;
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
    response: ?[utp.max_ack_size]u8,
    response_len: u8 = 0,
    data: ?[]const u8,
    data_len: u16,
    /// Number of additional payloads drained from the reorder buffer.
    /// The slices are in `reorder_data[0..reorder_delivered]`.
    reorder_delivered: u16 = 0,
    /// Slices to payloads delivered from the reorder buffer (in
    /// ascending sequence order). Each slice points into per-socket
    /// owned storage and is only valid until the next call to
    /// `UtpManager.processPacket` on the same connection.
    reorder_data: [utp.max_reorder_buf]?[]const u8 = @as([utp.max_reorder_buf]?[]const u8, @splat(null)),
    remote: std.net.Address,
    new_connection: bool,
};

// ── Tests ─────────────────────────────────────────────────

/// File-scoped sim-seeded CSPRNG for the UtpManager test fixtures.
/// The connection-id is a 16-bit collision-avoidance value, not a
/// security primitive — these tests treat it as opaque.
var utp_test_rng: Random = Random.simRandom(0xa70);

test "manager connect allocates slot and produces SYN" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const result = try mgr.connect(&utp_test_rng, remote, 1_000_000);
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
    const conn = try client_mgr.connect(&utp_test_rng, server_addr, 1_000_000);

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

    const conn = try mgr.connect(&utp_test_rng, remote, 1_000_000);
    // Manually transition to connected for testing.
    mgr.connections[conn.slot].?.state = .connected;

    const fin = try mgr.close(conn.slot, 2_000_000);
    try std.testing.expect(fin != null);

    const hdr = Header.decode(&fin.?).?;
    try std.testing.expectEqual(utp.PacketType.st_fin, hdr.packet_type);
}

test "manager connection count tracks correctly" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    try std.testing.expectEqual(@as(u16, 0), mgr.connectionCount());

    const c1 = try mgr.connect(&utp_test_rng, remote, 1_000_000);
    try std.testing.expectEqual(@as(u16, 1), mgr.connectionCount());

    const c2 = try mgr.connect(&utp_test_rng, remote, 1_000_000);
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

    const conn = try mgr.connect(&utp_test_rng, remote, 1_000_000);
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
    const conn = try client_mgr.connect(&utp_test_rng, server_addr, 1_000_000);
    const client_sock = client_mgr.getSocket(conn.slot).?;
    try std.testing.expectEqual(@as(u16, 1), client_sock.outBufCount());

    // Server receives SYN.
    const srv_result = server_mgr.processPacket(&conn.syn_packet, client_addr, 1_001_000).?;
    try std.testing.expect(srv_result.new_connection);
    _ = server_mgr.accept().?;

    // Client receives SYN-ACK -- SYN should be acked.
    _ = client_mgr.processPacket(&srv_result.response.?, server_addr, 1_002_000);
    try std.testing.expectEqual(utp.State.connected, client_sock.state);
    try std.testing.expectEqual(@as(u16, 0), client_sock.outBufCount());

    // Client sends data.
    const payload = "hello";
    const hdr_bytes = client_mgr.createDataPacket(conn.slot, @intCast(payload.len), 1_003_000);
    try std.testing.expect(hdr_bytes != null);

    // Buffer the data packet for retransmission.
    const pkt_seq = std.mem.readInt(u16, hdr_bytes.?[16..18], .big);
    var datagram: [utp.Header.size + payload.len]u8 = undefined;
    @memcpy(datagram[0..utp.Header.size], &hdr_bytes.?);
    @memcpy(datagram[utp.Header.size..], payload);
    try client_sock.bufferSentPacket(pkt_seq, &datagram, @intCast(payload.len), 1_003_000);

    try std.testing.expectEqual(@as(u16, 1), client_sock.outBufCount());

    // Clean up.
    _ = client_mgr.reset(conn.slot, 3_000_000);
}

test "manager collectRetransmits returns timed-out packets" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    // `connect` already buffers the SYN as the first outbound packet at
    // out_seq_start=0. The previous version of this test manually
    // overrode `seq_nr=10; out_seq_start=10;` which left the SYN
    // orphaned at idx 0; handleTimeout then marked an empty slot at
    // idx 10 as needs_resend, and collectRetransmits returned zero.
    // Use the natural buffered SYN as the timeout target instead.
    const conn = try mgr.connect(&utp_test_rng, remote, 1_000_000);

    // Simulate timeout: advance past the initial RTO (1s).
    var timeout_buf: [64]u16 = undefined;
    const timeout_count = mgr.checkTimeouts(3_500_000, &timeout_buf);
    try std.testing.expect(timeout_count > 0);

    // Collect retransmits — the SYN should come back since it is the
    // oldest unacked packet.
    var retransmits: [16]RetransmitResult = undefined;
    const retx_count = mgr.collectRetransmits(3_500_000, &retransmits);
    try std.testing.expect(retx_count > 0);
    try std.testing.expectEqual(conn.slot, retransmits[0].slot);

    // Clean up.
    _ = mgr.reset(conn.slot, 4_000_000);
}

test "manager collects unconfirmed connect timeouts beyond retransmit batch size" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();

    const attempts = 96;
    var i: u16 = 0;
    while (i < attempts) : (i += 1) {
        const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 20_000 + i);
        _ = try mgr.connect(&utp_test_rng, remote, 1_000_000);
    }

    var timeout_buf: [64]u16 = undefined;
    const retransmit_timeout_count = mgr.checkTimeouts(4_000_000, &timeout_buf);
    try std.testing.expectEqual(@as(u16, 64), retransmit_timeout_count);

    var connect_timeout_buf: [attempts]u16 = undefined;
    const connect_timeout_count = mgr.checkUnconfirmedConnectTimeouts(4_000_000, &connect_timeout_buf);
    try std.testing.expectEqual(@as(u16, attempts), connect_timeout_count);
}

test "manager freeSlot cleans up outbound buffers" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);

    const conn = try mgr.connect(&utp_test_rng, remote, 1_000_000);

    // SYN is buffered in the manager-owned packet pool for retransmission.
    const sock = mgr.getSocket(conn.slot).?;
    try std.testing.expect(sock.outPacketForSeq(sock.out_seq_start).?.packet_len != 0);
    try std.testing.expect(mgr.packet_pool.stats().used_bytes > 0);

    // Reset frees the slot and the outbound buffers.
    _ = mgr.reset(conn.slot, 2_000_000);
    try std.testing.expectEqual(@as(u16, 0), mgr.connectionCount());
    try std.testing.expectEqual(@as(u64, 0), mgr.packet_pool.stats().used_bytes);
}

test "manager can preallocate packet pool after UDP listener already exists" {
    var mgr = UtpManager.initWithSettingsNoPrealloc(std.testing.allocator, .{
        .packet_pool_initial_bytes = 1024,
        .packet_pool_max_bytes = 1024,
    });
    defer mgr.deinit();

    try std.testing.expectEqual(@as(u64, 0), mgr.packet_pool.stats().capacity_bytes);
    try mgr.ensurePacketPoolPreallocated();
    try std.testing.expectEqual(@as(u64, 1024), mgr.packet_pool.stats().capacity_bytes);
}

// ── Extension chain regression tests ──────────────────────
//
// Background: src/net/utp_manager.zig:processPacket previously treated
// `data[Header.size..]` as the entire BT payload regardless of
// `hdr.extension`. When a peer set extension == selective_ack the
// SACK header bytes were fed into the BT framing layer as if they
// were BT message bytes — protocol-correctness, not memory-safety
// (filed in progress-reports/2026-04-26-audit-hunt-round3.md).
//
// `stripExtensions` walks the chain. These tests pin its behavior on
// the wire shapes the brief called out: single SACK extension before
// BT bytes, multi-hop chain, and truncated chain.

test "stripExtensions: no extension passes payload through" {
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const out = UtpManager.stripExtensions(.none, &payload).?;
    try std.testing.expectEqualSlices(u8, &payload, out);
}

test "stripExtensions: SACK extension is consumed before BT bytes" {
    // Layout: ext_chain = (next_ext=none, len=4, [4]u8 SACK bitmask)
    // followed by 4 zero bytes (a BT keepalive: u32 length prefix = 0).
    const datagram = [_]u8{
        0, // next_ext = .none (terminates chain)
        4, // len = 4 bytes of SACK bitmask
        0xAA, 0xBB, 0xCC, 0xDD, // SACK bitmask
        0, 0, 0, 0, // BT keepalive (length prefix = 0)
    };
    const out = UtpManager.stripExtensions(.selective_ack, &datagram).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out);
}

test "stripExtensions: multi-hop chain consumes every extension" {
    // Two chained extensions: first selective_ack, then an unknown
    // type (value 7), then terminator. BT bytes follow.
    const datagram = [_]u8{
        7, // next_ext = unknown type 7
        4, // len = 4 (SACK bitmask)
        0x11, 0x22, 0x33, 0x44, // SACK bitmask
        0, // next_ext = .none
        2, // len = 2
        0x55, 0x66, // unknown extension data
        0xAB, 0xCD, // BT bytes
    };
    const out = UtpManager.stripExtensions(.selective_ack, &datagram).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD }, out);
}

test "stripExtensions: truncated extension is rejected" {
    // ext_len claims 16 bytes but only 4 are present after the
    // 2-byte extension header.
    const datagram = [_]u8{
        0, // next_ext = .none
        16, // len = 16 (lie)
        0x01, 0x02, 0x03, 0x04, // only 4 bytes of "data"
    };
    try std.testing.expect(UtpManager.stripExtensions(.selective_ack, &datagram) == null);
}

test "stripExtensions: missing per-extension header is rejected" {
    // hdr says there's a SACK extension but the datagram has zero
    // bytes after the main header.
    const datagram = [_]u8{};
    try std.testing.expect(UtpManager.stripExtensions(.selective_ack, &datagram) == null);
    // Single byte (less than 2-byte ext header) is also rejected.
    const one_byte = [_]u8{0xAA};
    try std.testing.expect(UtpManager.stripExtensions(.selective_ack, &one_byte) == null);
}

test "stripExtensions: SACK len > sack_bitmask_max is rejected" {
    // The decoder's bound (sack_bitmask_max = 32) is enforced here
    // too, so a peer can't sneak a 252-byte SACK past as a generic
    // "skip 252 bytes" extension and confuse downstream framing.
    var datagram: [256]u8 = undefined;
    datagram[0] = 0; // next_ext = .none
    datagram[1] = 36; // len = 36 (multiple of 4, > 32)
    @memset(datagram[2..38], 0);
    try std.testing.expect(UtpManager.stripExtensions(.selective_ack, datagram[0..38]) == null);
}

test "stripExtensions: chain bounded by datagram length" {
    // A chain that never terminates within the datagram is
    // rejected. Each hop here advertises another hop forever.
    const datagram = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 }; // 8 chained empty extensions, never terminating
    try std.testing.expect(UtpManager.stripExtensions(.selective_ack, &datagram) == null);
}

test "manager processes SACK + BT keepalive correctly through full pipeline" {
    // End-to-end: build a uTP DATA packet with a SACK extension and
    // 4 zero BT keepalive bytes after it. The manager's processPacket
    // must surface a 4-byte payload (the keepalive) — not 6 bytes
    // (SACK header + keepalive intermixed).
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);

    // Establish a connection: SYN + SYN-ACK.
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
    const syn_result = mgr.processPacket(&syn_buf, remote, 1_000_000).?;
    const slot = mgr.accept().?;
    _ = syn_result;

    // Build a DATA packet (seq 2) with hdr.extension = selective_ack
    // followed by a SACK chain (ext header + 4 bytes) + 4 BT keepalive.
    const data_hdr = Header{
        .packet_type = .st_data,
        .extension = .selective_ack,
        .connection_id = mgr.getSocket(slot).?.recv_id, // recv on responder side
        .timestamp_us = 2_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 2, // ack_nr was set to 1 by acceptSyn, so next is 2
        .ack_nr = 0,
    };
    var pkt: [Header.size + 2 + 4 + 4]u8 = undefined;
    @memcpy(pkt[0..Header.size], &data_hdr.encode());
    // Ext chain: next_ext=none, len=4, 4 SACK bytes
    pkt[Header.size + 0] = 0;
    pkt[Header.size + 1] = 4;
    pkt[Header.size + 2] = 0xAA;
    pkt[Header.size + 3] = 0xBB;
    pkt[Header.size + 4] = 0xCC;
    pkt[Header.size + 5] = 0xDD;
    // BT keepalive: 4 zero bytes
    pkt[Header.size + 6] = 0;
    pkt[Header.size + 7] = 0;
    pkt[Header.size + 8] = 0;
    pkt[Header.size + 9] = 0;

    const result = mgr.processPacket(&pkt, remote, 2_000_000).?;
    try std.testing.expect(result.data != null);
    // The BT layer should see only the 4 keepalive bytes.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result.data.?);
}

test "manager rejects datagram with truncated extension chain" {
    var mgr = UtpManager.init(std.testing.allocator);
    defer mgr.deinit();
    const remote = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);

    // Establish a connection.
    const syn_hdr = Header{
        .packet_type = .st_syn,
        .extension = .none,
        .connection_id = 600,
        .timestamp_us = 1_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 0,
    };
    const syn_buf = syn_hdr.encode();
    _ = mgr.processPacket(&syn_buf, remote, 1_000_000).?;
    const slot = mgr.accept().?;

    // DATA packet with a SACK extension claiming 16 bytes but only
    // 4 trailing bytes are present.
    const data_hdr = Header{
        .packet_type = .st_data,
        .extension = .selective_ack,
        .connection_id = mgr.getSocket(slot).?.recv_id,
        .timestamp_us = 2_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 2,
        .ack_nr = 0,
    };
    var pkt: [Header.size + 2 + 4]u8 = undefined;
    @memcpy(pkt[0..Header.size], &data_hdr.encode());
    pkt[Header.size + 0] = 0;
    pkt[Header.size + 1] = 16; // lie — 16 bytes claimed, 4 present
    pkt[Header.size + 2] = 0x01;
    pkt[Header.size + 3] = 0x02;
    pkt[Header.size + 4] = 0x03;
    pkt[Header.size + 5] = 0x04;

    // Manager should drop the malformed datagram cleanly (no crash).
    const result = mgr.processPacket(&pkt, remote, 2_000_000);
    try std.testing.expect(result == null);
}

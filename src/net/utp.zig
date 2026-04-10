const std = @import("std");
const Ledbat = @import("ledbat.zig").Ledbat;

/// uTP (Micro Transport Protocol, BEP 29) packet types.
pub const PacketType = enum(u4) {
    st_data = 0,
    st_fin = 1,
    st_state = 2,
    st_reset = 3,
    st_syn = 4,
};

/// uTP protocol version.
pub const version: u4 = 1;

/// uTP extension types.
pub const Extension = enum(u8) {
    none = 0,
    selective_ack = 1,
    _,
};

/// uTP packet header (20 bytes, network byte order).
pub const Header = struct {
    packet_type: PacketType,
    extension: Extension,
    connection_id: u16,
    timestamp_us: u32,
    timestamp_diff_us: u32,
    wnd_size: u32,
    seq_nr: u16,
    ack_nr: u16,

    pub const size: usize = 20;

    /// Encode a header into a 20-byte buffer (big-endian / network order).
    pub fn encode(self: Header) [size]u8 {
        var buf: [size]u8 = undefined;
        // type_ver: high nibble = type, low nibble = version
        buf[0] = (@as(u8, @intFromEnum(self.packet_type)) << 4) | version;
        buf[1] = @intFromEnum(self.extension);
        std.mem.writeInt(u16, buf[2..4], self.connection_id, .big);
        std.mem.writeInt(u32, buf[4..8], self.timestamp_us, .big);
        std.mem.writeInt(u32, buf[8..12], self.timestamp_diff_us, .big);
        std.mem.writeInt(u32, buf[12..16], self.wnd_size, .big);
        std.mem.writeInt(u16, buf[16..18], self.seq_nr, .big);
        std.mem.writeInt(u16, buf[18..20], self.ack_nr, .big);
        return buf;
    }

    /// Decode a header from a 20-byte buffer. Returns null if the
    /// version nibble is not 1 or the buffer is too short.
    pub fn decode(buf: []const u8) ?Header {
        if (buf.len < size) return null;

        const type_ver = buf[0];
        const pkt_type_val = type_ver >> 4;
        const ver = type_ver & 0x0F;

        if (ver != version) return null;

        // Validate packet type range.
        const pkt_type: PacketType = std.meta.intToEnum(PacketType, @as(u4, @intCast(pkt_type_val))) catch return null;

        return .{
            .packet_type = pkt_type,
            .extension = @enumFromInt(buf[1]),
            .connection_id = std.mem.readInt(u16, buf[2..4], .big),
            .timestamp_us = std.mem.readInt(u32, buf[4..8], .big),
            .timestamp_diff_us = std.mem.readInt(u32, buf[8..12], .big),
            .wnd_size = std.mem.readInt(u32, buf[12..16], .big),
            .seq_nr = std.mem.readInt(u16, buf[16..18], .big),
            .ack_nr = std.mem.readInt(u16, buf[18..20], .big),
        };
    }
};

/// Selective ACK extension header. Follows immediately after the main
/// header when extension == selective_ack. The bitmask indicates which
/// packets after ack_nr+2 have been received (ack_nr+1 is implicitly
/// not received -- that is the gap being NACKed).
pub const SelectiveAck = struct {
    /// Next extension type.
    next_extension: Extension,
    /// Bitmask length in bytes (must be a multiple of 4, BEP 29).
    len: u8,
    /// Bitmask data (up to 32 bytes = 256 sequence numbers).
    bitmask: [32]u8 = [_]u8{0} ** 32,

    /// Minimum overhead: 2 bytes header + 4 bytes bitmask.
    pub const min_size: usize = 6;

    pub fn encode(self: SelectiveAck, buf: []u8) usize {
        if (buf.len < 2 + self.len) return 0;
        buf[0] = @intFromEnum(self.next_extension);
        buf[1] = self.len;
        @memcpy(buf[2 .. 2 + self.len], self.bitmask[0..self.len]);
        return 2 + @as(usize, self.len);
    }

    pub fn decode(buf: []const u8) ?SelectiveAck {
        if (buf.len < 2) return null;
        const len = buf[1];
        if (len == 0 or len % 4 != 0 or buf.len < 2 + @as(usize, len)) return null;
        var sack = SelectiveAck{
            .next_extension = @enumFromInt(buf[0]),
            .len = len,
        };
        @memcpy(sack.bitmask[0..len], buf[2 .. 2 + len]);
        return sack;
    }

    /// Check whether the bit for sequence number (ack_nr + 2 + bit_index)
    /// is set in the bitmask.
    pub fn isAcked(self: *const SelectiveAck, bit_index: u16) bool {
        const byte_idx = bit_index / 8;
        const bit_idx: u3 = @intCast(bit_index % 8);
        if (byte_idx >= self.len) return false;
        // BEP 29: bit 0 of byte 0 = ack_nr+2, bit 1 = ack_nr+3, ...
        return (self.bitmask[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    /// Set the bit for a given index.
    pub fn setBit(self: *SelectiveAck, bit_index: u16) void {
        const byte_idx = bit_index / 8;
        const bit_idx: u3 = @intCast(bit_index % 8);
        if (byte_idx >= self.len) return;
        self.bitmask[byte_idx] |= (@as(u8, 1) << bit_idx);
    }
};

/// Circular sequence number comparison (16-bit wrapping).
/// Returns true if `a` is less than `b` in the circular sequence space.
pub fn seqLessThan(a: u16, b: u16) bool {
    // a < b if the signed difference (a - b) is negative,
    // i.e., the subtraction wraps past the halfway point.
    const diff: i16 = @bitCast(a -% b);
    return diff < 0;
}

/// Circular sequence number difference: a - b (signed, wrapping).
pub fn seqDiff(a: u16, b: u16) i16 {
    return @bitCast(a -% b);
}

/// uTP connection states.
pub const State = enum {
    idle,
    syn_sent,
    syn_recv,
    connected,
    fin_sent,
    closed,
    reset,
};

/// Maximum number of out-of-order packets we buffer.
const max_reorder_buf = 64;

/// Maximum number of unacknowledged outbound packets.
const max_outbuf = 128;

/// Default receive window size advertised (256 KiB).
pub const default_recv_window: u32 = 256 * 1024;

/// RTO bounds.
const min_rto_us: u32 = 500_000; // 500 ms
const max_rto_us: u32 = 60_000_000; // 60 s
const initial_rto_us: u32 = 1_000_000; // 1 s

/// Maximum payload size per uTP packet (MTU - IP - UDP - uTP header).
pub const max_payload: u16 = 1400 - Header.size;

/// An outbound packet waiting for acknowledgement.
/// Owns a copy of the payload for retransmission.
pub const OutPacket = struct {
    seq_nr: u16 = 0,
    /// Owned copy of the full UDP datagram (header + payload) for retransmission.
    /// Null for slots that have been acked and reclaimed.
    packet_buf: ?[]u8 = null,
    /// Length of the payload portion (excluding header).
    payload_len: u16 = 0,
    send_time_us: u32 = 0,
    retransmit_count: u8 = 0,
    acked: bool = false,
    /// Whether this packet needs retransmission (set on timeout/loss detection).
    needs_resend: bool = false,

    /// Free the owned packet buffer.
    pub fn deinit(self: *OutPacket, allocator: std.mem.Allocator) void {
        if (self.packet_buf) |buf| {
            allocator.free(buf);
            self.packet_buf = null;
        }
    }
};

/// An entry in the receive reorder buffer.
pub const ReorderEntry = struct {
    seq_nr: u16,
    data: []const u8,
    present: bool = false,
};

/// uTP socket: represents one logical connection, identified by
/// connection_id on a shared UDP socket.
pub const UtpSocket = struct {
    state: State = .idle,

    /// Our connection_id for receiving (initiator: random R, recv_id = R,
    /// send_id = R+1). For the peer these are swapped.
    recv_id: u16 = 0,
    send_id: u16 = 0,

    /// Sequence numbers.
    seq_nr: u16 = 1,
    ack_nr: u16 = 0,

    /// Remote peer's advertised receive window in bytes.
    peer_wnd_size: u32 = default_recv_window,

    /// Our advertised receive window.
    recv_wnd_size: u32 = default_recv_window,

    /// Bytes currently buffered for delivery (used to calculate our window).
    recv_buf_bytes: u32 = 0,

    /// LEDBAT congestion control state.
    ledbat: Ledbat = Ledbat.init(),

    /// Timestamp of the last packet we received (microseconds).
    last_recv_timestamp: u32 = 0,
    /// Our timestamp when we received it.
    last_recv_time: u32 = 0,

    /// RTT estimator (Karn's algorithm).
    srtt: u32 = 0,
    rttvar: u32 = 0,
    rto: u32 = initial_rto_us,
    rtt_initialized: bool = false,

    /// Outbound packet buffer (circular, max_outbuf entries).
    out_buf: [max_outbuf]OutPacket = [_]OutPacket{.{}} ** max_outbuf,
    out_buf_count: u16 = 0,
    /// Sequence number of the oldest unacknowledged packet.
    out_seq_start: u16 = 1,

    /// Receive reorder buffer.
    reorder_buf: [max_reorder_buf]ReorderEntry = [_]ReorderEntry{.{ .seq_nr = 0, .data = &.{}, .present = false }} ** max_reorder_buf,

    /// Duplicate ACK counter for fast retransmit.
    dup_ack_count: u8 = 0,

    /// Timestamp of the last packet we sent.
    last_send_time_us: u32 = 0,

    /// Remote address (set on connect/accept).
    remote_addr: std.net.Address = undefined,

    /// Allocator for owned packet buffers in the retransmission buffer.
    allocator: ?std.mem.Allocator = null,

    // ── Public API ───────────────────────────────────────

    /// Free all owned outbound packet buffers. Call on socket teardown.
    pub fn deinit(self: *UtpSocket) void {
        const alloc = self.allocator orelse return;
        for (&self.out_buf) |*pkt| {
            pkt.deinit(alloc);
        }
    }

    /// Begin an outbound connection. Generates a SYN packet and stores
    /// it in the outbound buffer for retransmission on timeout.
    /// Returns the encoded SYN packet to send.
    pub fn connect(self: *UtpSocket, now_us: u32) [Header.size]u8 {
        // Generate random connection_id.
        var rng_buf: [2]u8 = undefined;
        std.crypto.random.bytes(&rng_buf);
        const conn_id = std.mem.readInt(u16, &rng_buf, .little);

        self.recv_id = conn_id;
        self.send_id = conn_id +% 1;
        self.seq_nr = 1;
        self.state = .syn_sent;

        const hdr = Header{
            .packet_type = .st_syn,
            .extension = .none,
            .connection_id = self.recv_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = 0,
            .wnd_size = self.recv_wnd_size,
            .seq_nr = self.seq_nr,
            .ack_nr = 0,
        };

        const encoded = hdr.encode();

        // Store SYN in outbound buffer for retransmission.
        self.bufferOutPacket(self.seq_nr, &encoded, 0, now_us);

        self.seq_nr +%= 1;
        self.last_send_time_us = now_us;
        return encoded;
    }

    /// Process a received SYN (called by the manager for inbound connections).
    /// Returns the SYN-ACK (ST_STATE) packet to send back.
    pub fn acceptSyn(self: *UtpSocket, syn: Header, now_us: u32) [Header.size]u8 {
        // For inbound connections: recv_id = syn.connection_id + 1,
        // send_id = syn.connection_id.
        self.recv_id = syn.connection_id +% 1;
        self.send_id = syn.connection_id;
        self.ack_nr = syn.seq_nr;
        self.seq_nr = 1;
        self.state = .connected;
        self.last_recv_timestamp = syn.timestamp_us;
        self.last_recv_time = now_us;

        const hdr = Header{
            .packet_type = .st_state,
            .extension = .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = now_us -% syn.timestamp_us,
            .wnd_size = self.recv_wnd_size,
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };

        self.last_send_time_us = now_us;
        return hdr.encode();
    }

    /// Process a received packet. Returns an optional response packet
    /// to send (ACK, etc.) and any payload data delivered in order.
    pub fn processPacket(self: *UtpSocket, hdr: Header, payload: []const u8, now_us: u32) ProcessResult {
        var result = ProcessResult{};

        // Update timestamps for delay measurement.
        self.last_recv_timestamp = hdr.timestamp_us;
        self.last_recv_time = now_us;
        self.peer_wnd_size = hdr.wnd_size;

        const timestamp_diff = now_us -% hdr.timestamp_us;

        switch (hdr.packet_type) {
            .st_reset => {
                self.state = .reset;
                return result;
            },
            .st_syn => {
                // Duplicate SYN -- resend SYN-ACK.
                if (self.state == .connected or self.state == .syn_recv) {
                    result.response = self.makeAck(now_us);
                }
                return result;
            },
            .st_state => {
                // ACK-only packet.
                if (self.state == .syn_sent) {
                    // SYN-ACK received: complete handshake.
                    self.ack_nr = hdr.seq_nr;
                    self.state = .connected;
                }
                self.processAck(hdr.ack_nr, timestamp_diff, now_us);
                return result;
            },
            .st_data => {
                if (self.state != .connected and self.state != .fin_sent) return result;

                // Process ACK piggy-backed on data.
                self.processAck(hdr.ack_nr, timestamp_diff, now_us);

                // Check if this is the next expected sequence number.
                if (hdr.seq_nr == self.ack_nr +% 1) {
                    self.ack_nr = hdr.seq_nr;
                    result.data = payload;
                    result.data_len = @intCast(payload.len);

                    // Deliver any buffered out-of-order packets.
                    result.reorder_delivered = self.deliverReordered();
                } else if (seqLessThan(self.ack_nr +% 1, hdr.seq_nr)) {
                    // Future packet -- buffer for reordering.
                    self.bufferReorder(hdr.seq_nr, payload);
                }
                // else: old duplicate, ignore.

                result.response = self.makeAck(now_us);
                return result;
            },
            .st_fin => {
                if (self.state != .connected) return result;

                self.processAck(hdr.ack_nr, timestamp_diff, now_us);
                self.ack_nr = hdr.seq_nr;
                self.state = .closed;

                // ACK the FIN.
                result.response = self.makeAck(now_us);
                return result;
            },
        }
    }

    /// Create a data packet header and buffer the full packet (header + payload)
    /// for retransmission. Returns header bytes and advances seq_nr.
    /// The caller is responsible for sending header ++ payload over UDP.
    /// Returns null if the send window is exhausted or the outbound buffer is full.
    pub fn createDataPacket(self: *UtpSocket, payload_len: u16, now_us: u32) ?[Header.size]u8 {
        if (self.state != .connected) return null;
        if (self.out_buf_count >= max_outbuf) return null;

        // Check congestion window.
        const bytes_in_flight = self.bytesInFlight();
        const cwnd = self.ledbat.window();
        const effective_wnd = @min(cwnd, self.peer_wnd_size);
        if (bytes_in_flight + payload_len > effective_wnd) return null;

        const hdr = Header{
            .packet_type = .st_data,
            .extension = .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = self.timestampDiff(now_us),
            .wnd_size = self.advertisedWindow(),
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };

        const encoded = hdr.encode();
        self.seq_nr +%= 1;
        self.last_send_time_us = now_us;
        return encoded;
    }

    /// Buffer a sent data packet for retransmission. Must be called after
    /// createDataPacket with the full datagram (header + payload).
    /// This stores an owned copy so the original buffer can be reused.
    pub fn bufferSentPacket(self: *UtpSocket, seq_nr: u16, datagram: []const u8, payload_len: u16, now_us: u32) void {
        self.bufferOutPacket(seq_nr, datagram, payload_len, now_us);
    }

    /// Create a FIN packet to initiate graceful shutdown.
    pub fn createFinPacket(self: *UtpSocket, now_us: u32) ?[Header.size]u8 {
        if (self.state != .connected) return null;

        self.state = .fin_sent;

        const hdr = Header{
            .packet_type = .st_fin,
            .extension = .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = self.timestampDiff(now_us),
            .wnd_size = self.advertisedWindow(),
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };

        self.seq_nr +%= 1;
        self.last_send_time_us = now_us;
        return hdr.encode();
    }

    /// Create a RESET packet.
    pub fn createResetPacket(self: *UtpSocket, now_us: u32) [Header.size]u8 {
        self.state = .reset;

        const hdr = Header{
            .packet_type = .st_reset,
            .extension = .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = self.timestampDiff(now_us),
            .wnd_size = 0,
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };

        return hdr.encode();
    }

    /// Returns estimated bytes currently in flight (unacknowledged).
    pub fn bytesInFlight(self: *const UtpSocket) u32 {
        var total: u32 = 0;
        var i: u16 = 0;
        while (i < self.out_buf_count) : (i += 1) {
            const idx = (self.out_seq_start +% i) % max_outbuf;
            const pkt = &self.out_buf[idx];
            if (!pkt.acked) {
                total += @as(u32, pkt.payload_len) + @as(u32, Header.size);
            }
        }
        return total;
    }

    /// Check if a retransmission timeout has elapsed.
    pub fn isTimedOut(self: *const UtpSocket, now_us: u32) bool {
        if (self.last_send_time_us == 0) return false;
        if (self.state == .idle or self.state == .closed or self.state == .reset) return false;
        return (now_us -% self.last_send_time_us) >= self.rto;
    }

    /// Handle a retransmission timeout event. Marks the oldest unacked
    /// packet for retransmission and applies exponential backoff.
    pub fn handleTimeout(self: *UtpSocket) void {
        self.ledbat.onTimeout();
        // Double the RTO (exponential backoff).
        self.rto = @min(self.rto *| 2, max_rto_us);

        // Mark the oldest unacked packet for resend.
        if (self.out_buf_count > 0) {
            const idx = self.out_seq_start % max_outbuf;
            var pkt = &self.out_buf[idx];
            if (!pkt.acked) {
                pkt.needs_resend = true;
            }
        }
    }

    /// Collect packets that need retransmission. Returns the number of
    /// packets written to `out`. Each entry is the packet buffer slice
    /// that should be re-sent over UDP.
    pub fn collectRetransmits(self: *UtpSocket, out: []RetransmitEntry, now_us: u32) u16 {
        var count: u16 = 0;
        var i: u16 = 0;
        while (i < self.out_buf_count and count < out.len) : (i += 1) {
            const idx = (self.out_seq_start +% i) % max_outbuf;
            var pkt = &self.out_buf[idx];
            if (pkt.needs_resend and !pkt.acked) {
                if (pkt.packet_buf) |buf| {
                    // Update the timestamp in the header before retransmitting.
                    std.mem.writeInt(u32, buf[4..8], now_us, .big);
                    out[count] = .{ .data = buf, .seq_nr = pkt.seq_nr };
                    pkt.needs_resend = false;
                    pkt.retransmit_count += 1;
                    pkt.send_time_us = now_us;
                    count += 1;
                }
            }
        }
        self.last_send_time_us = now_us;
        return count;
    }

    // ── Internal ─────────────────────────────────────────

    fn processAck(self: *UtpSocket, ack_nr: u16, delay_us: u32, now_us: u32) void {
        // Walk through outbuf and mark acked packets.
        var newly_acked_bytes: u32 = 0;
        var advanced = false;

        while (self.out_buf_count > 0) {
            const idx = self.out_seq_start % max_outbuf;
            var pkt = &self.out_buf[idx];

            if (seqLessThan(ack_nr, pkt.seq_nr)) break;

            // This packet is acknowledged.
            if (!pkt.acked) {
                pkt.acked = true;
                newly_acked_bytes += @as(u32, pkt.payload_len) + @as(u32, Header.size);

                // RTT sample (skip retransmitted packets per Karn's algorithm).
                if (pkt.retransmit_count == 0) {
                    self.updateRtt(now_us -% pkt.send_time_us);
                }
            }

            // Free the owned packet buffer now that it is acked.
            if (self.allocator) |alloc| {
                pkt.deinit(alloc);
            }

            self.out_seq_start +%= 1;
            self.out_buf_count -= 1;
            advanced = true;
        }

        if (newly_acked_bytes > 0) {
            self.ledbat.onAck(newly_acked_bytes, delay_us, now_us);
            self.dup_ack_count = 0;
        } else if (advanced == false and self.out_buf_count > 0) {
            // Duplicate ACK.
            self.dup_ack_count += 1;
            if (self.dup_ack_count >= 3) {
                // Mark oldest unacked for fast retransmit.
                const fast_idx = self.out_seq_start % max_outbuf;
                self.out_buf[fast_idx].needs_resend = true;
                self.ledbat.onLoss();
                self.dup_ack_count = 0;
            }
        }
    }

    fn updateRtt(self: *UtpSocket, rtt_us: u32) void {
        if (!self.rtt_initialized) {
            self.srtt = rtt_us;
            self.rttvar = rtt_us / 2;
            self.rtt_initialized = true;
        } else {
            // RFC 6298 smoothed RTT.
            const diff = if (rtt_us > self.srtt) rtt_us - self.srtt else self.srtt - rtt_us;
            self.rttvar = (3 * self.rttvar + diff) / 4;
            self.srtt = (7 * self.srtt + rtt_us) / 8;
        }

        // RTO = SRTT + 4 * RTTVAR, clamped.
        self.rto = @min(@max(self.srtt + 4 * self.rttvar, min_rto_us), max_rto_us);
    }

    pub fn makeAck(self: *UtpSocket, now_us: u32) [Header.size]u8 {
        const hdr = Header{
            .packet_type = .st_state,
            .extension = .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = self.timestampDiff(now_us),
            .wnd_size = self.advertisedWindow(),
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };
        return hdr.encode();
    }

    fn timestampDiff(self: *const UtpSocket, now_us: u32) u32 {
        if (self.last_recv_time == 0) return 0;
        return now_us -% self.last_recv_timestamp;
    }

    fn advertisedWindow(self: *const UtpSocket) u32 {
        if (self.recv_buf_bytes >= self.recv_wnd_size) return 0;
        return self.recv_wnd_size - self.recv_buf_bytes;
    }

    /// Store a packet in the outbound buffer for retransmission.
    /// `header_data` is the encoded header (or full datagram for control packets).
    /// `payload_len` is the length of payload following the header (0 for control).
    fn bufferOutPacket(self: *UtpSocket, seq_nr: u16, header_data: []const u8, payload_len: u16, now_us: u32) void {
        if (self.out_buf_count >= max_outbuf) return;

        const idx = (self.out_seq_start +% self.out_buf_count) % max_outbuf;

        // Allocate owned copy if we have an allocator.
        var owned_buf: ?[]u8 = null;
        if (self.allocator) |alloc| {
            owned_buf = alloc.alloc(u8, header_data.len) catch null;
            if (owned_buf) |buf| {
                @memcpy(buf, header_data);
            }
        }

        self.out_buf[idx] = .{
            .seq_nr = seq_nr,
            .packet_buf = owned_buf,
            .payload_len = payload_len,
            .send_time_us = now_us,
        };
        self.out_buf_count += 1;
    }

    fn bufferReorder(self: *UtpSocket, seq: u16, data: []const u8) void {
        const offset = seqDiff(seq, self.ack_nr +% 1);
        if (offset <= 0 or offset >= max_reorder_buf) return;
        const idx: usize = @intCast(@as(u16, @intCast(offset)) % max_reorder_buf);
        self.reorder_buf[idx] = .{
            .seq_nr = seq,
            .data = data,
            .present = true,
        };
    }

    fn deliverReordered(self: *UtpSocket) u16 {
        var count: u16 = 0;
        while (count < max_reorder_buf) {
            const next_seq = self.ack_nr +% 1;
            const idx: usize = @intCast(next_seq % max_reorder_buf);
            if (!self.reorder_buf[idx].present or self.reorder_buf[idx].seq_nr != next_seq) break;
            self.ack_nr = next_seq;
            self.reorder_buf[idx].present = false;
            count += 1;
        }
        return count;
    }
};

/// Result of processing an incoming packet.
pub const ProcessResult = struct {
    /// Optional response packet (ACK) to send back.
    response: ?[Header.size]u8 = null,
    /// Delivered in-order payload data (slice into the input buffer).
    data: ?[]const u8 = null,
    /// Length of delivered data.
    data_len: u16 = 0,
    /// Number of additional packets delivered from the reorder buffer.
    reorder_delivered: u16 = 0,
};

/// An entry returned by collectRetransmits -- a packet that needs resending.
pub const RetransmitEntry = struct {
    /// Full datagram (header + payload) to re-send over UDP.
    data: []u8,
    seq_nr: u16,
};

// ── Tests ─────────────────────────────────────────────────

test "header encode/decode roundtrip" {
    const original = Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 0x1234,
        .timestamp_us = 1_000_000,
        .timestamp_diff_us = 50_000,
        .wnd_size = 65536,
        .seq_nr = 100,
        .ack_nr = 99,
    };

    const encoded = original.encode();
    const decoded = Header.decode(&encoded) orelse return error.DecodeFailed;

    try std.testing.expectEqual(original.packet_type, decoded.packet_type);
    try std.testing.expectEqual(original.extension, decoded.extension);
    try std.testing.expectEqual(original.connection_id, decoded.connection_id);
    try std.testing.expectEqual(original.timestamp_us, decoded.timestamp_us);
    try std.testing.expectEqual(original.timestamp_diff_us, decoded.timestamp_diff_us);
    try std.testing.expectEqual(original.wnd_size, decoded.wnd_size);
    try std.testing.expectEqual(original.seq_nr, decoded.seq_nr);
    try std.testing.expectEqual(original.ack_nr, decoded.ack_nr);
}

test "header decode rejects wrong version" {
    var buf = (Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 0,
        .timestamp_us = 0,
        .timestamp_diff_us = 0,
        .wnd_size = 0,
        .seq_nr = 0,
        .ack_nr = 0,
    }).encode();

    // Corrupt version to 2.
    buf[0] = (buf[0] & 0xF0) | 2;
    try std.testing.expect(Header.decode(&buf) == null);
}

test "header decode rejects short buffer" {
    const buf = [_]u8{0} ** 10;
    try std.testing.expect(Header.decode(&buf) == null);
}

test "header encodes all packet types" {
    inline for (std.meta.fields(PacketType)) |field| {
        const pt: PacketType = @enumFromInt(field.value);
        const hdr = Header{
            .packet_type = pt,
            .extension = .none,
            .connection_id = 42,
            .timestamp_us = 0,
            .timestamp_diff_us = 0,
            .wnd_size = 0,
            .seq_nr = 0,
            .ack_nr = 0,
        };
        const encoded = hdr.encode();
        const decoded = Header.decode(&encoded) orelse return error.DecodeFailed;
        try std.testing.expectEqual(pt, decoded.packet_type);
    }
}

test "header type_ver byte layout" {
    const hdr = Header{
        .packet_type = .st_syn,
        .extension = .none,
        .connection_id = 0,
        .timestamp_us = 0,
        .timestamp_diff_us = 0,
        .wnd_size = 0,
        .seq_nr = 0,
        .ack_nr = 0,
    };
    const encoded = hdr.encode();
    // SYN = 4, version = 1, so type_ver = 0x41.
    try std.testing.expectEqual(@as(u8, 0x41), encoded[0]);
}

test "header connection_id big-endian" {
    const hdr = Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 0xABCD,
        .timestamp_us = 0,
        .timestamp_diff_us = 0,
        .wnd_size = 0,
        .seq_nr = 0,
        .ack_nr = 0,
    };
    const encoded = hdr.encode();
    try std.testing.expectEqual(@as(u8, 0xAB), encoded[2]);
    try std.testing.expectEqual(@as(u8, 0xCD), encoded[3]);
}

test "selective ack encode/decode roundtrip" {
    var sack = SelectiveAck{
        .next_extension = .none,
        .len = 4,
    };
    sack.setBit(0);
    sack.setBit(2);
    sack.setBit(7);

    var buf: [6]u8 = undefined;
    const written = sack.encode(&buf);
    try std.testing.expectEqual(@as(usize, 6), written);

    const decoded = SelectiveAck.decode(&buf) orelse return error.DecodeFailed;
    try std.testing.expect(decoded.isAcked(0));
    try std.testing.expect(!decoded.isAcked(1));
    try std.testing.expect(decoded.isAcked(2));
    try std.testing.expect(decoded.isAcked(7));
}

test "seqLessThan handles wraparound" {
    try std.testing.expect(seqLessThan(0xFFFE, 0x0001));
    try std.testing.expect(!seqLessThan(0x0001, 0xFFFE));
    try std.testing.expect(seqLessThan(100, 200));
    try std.testing.expect(!seqLessThan(200, 100));
    try std.testing.expect(!seqLessThan(100, 100));
}

test "seqDiff wrapping arithmetic" {
    try std.testing.expectEqual(@as(i16, 1), seqDiff(101, 100));
    try std.testing.expectEqual(@as(i16, -1), seqDiff(100, 101));
    // Wraparound: 0x0001 - 0xFFFF = 2.
    try std.testing.expectEqual(@as(i16, 2), seqDiff(0x0001, 0xFFFF));
}

test "connect produces SYN packet" {
    var sock = UtpSocket{};
    const pkt = sock.connect(1_000_000);

    const hdr = Header.decode(&pkt) orelse return error.DecodeFailed;
    try std.testing.expectEqual(PacketType.st_syn, hdr.packet_type);
    try std.testing.expectEqual(@as(u32, 1_000_000), hdr.timestamp_us);
    try std.testing.expectEqual(State.syn_sent, sock.state);
    try std.testing.expectEqual(sock.recv_id, hdr.connection_id);
}

test "acceptSyn transitions to connected" {
    var sock = UtpSocket{};
    const syn_hdr = Header{
        .packet_type = .st_syn,
        .extension = .none,
        .connection_id = 100,
        .timestamp_us = 500_000,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 0,
    };

    const response = sock.acceptSyn(syn_hdr, 600_000);
    const ack_hdr = Header.decode(&response) orelse return error.DecodeFailed;

    try std.testing.expectEqual(State.connected, sock.state);
    try std.testing.expectEqual(PacketType.st_state, ack_hdr.packet_type);
    try std.testing.expectEqual(@as(u16, 100), ack_hdr.connection_id);
    try std.testing.expectEqual(@as(u16, 1), ack_hdr.ack_nr);
    try std.testing.expectEqual(@as(u16, 101), sock.recv_id);
    try std.testing.expectEqual(@as(u16, 100), sock.send_id);
}

test "three-way handshake" {
    // Initiator (client).
    var client = UtpSocket{};
    const syn_pkt = client.connect(1_000_000);
    const syn_hdr = Header.decode(&syn_pkt).?;

    // Responder (server) receives SYN.
    var server = UtpSocket{};
    const syn_ack_pkt = server.acceptSyn(syn_hdr, 1_001_000);
    const syn_ack_hdr = Header.decode(&syn_ack_pkt).?;

    try std.testing.expectEqual(State.connected, server.state);

    // Client receives SYN-ACK (ST_STATE).
    const result = client.processPacket(syn_ack_hdr, &.{}, 1_002_000);
    _ = result;

    try std.testing.expectEqual(State.connected, client.state);

    // Connection IDs should be complementary.
    try std.testing.expectEqual(client.recv_id, server.send_id);
    try std.testing.expectEqual(client.send_id, server.recv_id);
}

test "data delivery in order" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;

    const payload = "hello";
    const hdr = Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 10,
        .timestamp_us = 100,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 6, // ack_nr + 1 = next expected
        .ack_nr = 0,
    };

    const result = sock.processPacket(hdr, payload, 200);
    try std.testing.expect(result.data != null);
    try std.testing.expectEqualStrings("hello", result.data.?);
    try std.testing.expectEqual(@as(u16, 6), sock.ack_nr);
    try std.testing.expect(result.response != null);
}

test "out-of-order packet is buffered" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;

    // Receive seq 8 (skip 6, 7).
    const hdr = Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 10,
        .timestamp_us = 100,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = 8,
        .ack_nr = 0,
    };

    const result = sock.processPacket(hdr, "future", 200);
    // Should not deliver data (out of order).
    try std.testing.expect(result.data == null);
    // ack_nr should not advance.
    try std.testing.expectEqual(@as(u16, 5), sock.ack_nr);
}

test "FIN transitions to closed" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;

    const hdr = Header{
        .packet_type = .st_fin,
        .extension = .none,
        .connection_id = 10,
        .timestamp_us = 100,
        .timestamp_diff_us = 0,
        .wnd_size = 0,
        .seq_nr = 6,
        .ack_nr = 0,
    };

    const result = sock.processPacket(hdr, &.{}, 200);
    try std.testing.expectEqual(State.closed, sock.state);
    try std.testing.expect(result.response != null);
}

test "RESET transitions to reset state" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;

    const hdr = Header{
        .packet_type = .st_reset,
        .extension = .none,
        .connection_id = 10,
        .timestamp_us = 100,
        .timestamp_diff_us = 0,
        .wnd_size = 0,
        .seq_nr = 0,
        .ack_nr = 0,
    };

    _ = sock.processPacket(hdr, &.{}, 200);
    try std.testing.expectEqual(State.reset, sock.state);
}

test "createDataPacket respects congestion window" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;
    sock.seq_nr = 1;
    sock.out_seq_start = 1;

    // With default LEDBAT init window (~2800), we should be able
    // to create at least one packet.
    const hdr_bytes = sock.createDataPacket(100, 1_000_000);
    try std.testing.expect(hdr_bytes != null);

    const hdr = Header.decode(&hdr_bytes.?).?;
    try std.testing.expectEqual(PacketType.st_data, hdr.packet_type);
    try std.testing.expectEqual(@as(u16, 10), hdr.connection_id);
}

test "createFinPacket transitions state" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;

    const fin_bytes = sock.createFinPacket(1_000_000);
    try std.testing.expect(fin_bytes != null);

    const hdr = Header.decode(&fin_bytes.?).?;
    try std.testing.expectEqual(PacketType.st_fin, hdr.packet_type);
    try std.testing.expectEqual(State.fin_sent, sock.state);
}

test "createResetPacket" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 10;

    const rst_bytes = sock.createResetPacket(1_000_000);
    const hdr = Header.decode(&rst_bytes).?;

    try std.testing.expectEqual(PacketType.st_reset, hdr.packet_type);
    try std.testing.expectEqual(State.reset, sock.state);
}

test "RTT estimation updates RTO" {
    var sock = UtpSocket{};
    sock.state = .connected;

    // First sample initializes.
    sock.updateRtt(100_000);
    try std.testing.expect(sock.rtt_initialized);
    try std.testing.expectEqual(@as(u32, 100_000), sock.srtt);

    // Second sample smooths.
    sock.updateRtt(120_000);
    try std.testing.expect(sock.srtt > 100_000);
    try std.testing.expect(sock.rto >= min_rto_us);
}

test "timeout detection" {
    var sock = UtpSocket{};
    sock.last_send_time_us = 1_000_000;
    sock.rto = 500_000;

    // Not timed out yet.
    try std.testing.expect(!sock.isTimedOut(1_400_000));
    // Timed out.
    try std.testing.expect(sock.isTimedOut(1_600_000));
}

// ── Fuzz and edge case tests ─────────────────────────────

test "fuzz uTP header decode" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // Header.decode must not panic on any input
            _ = Header.decode(input);

            // If buffer is long enough, also exercise SelectiveAck.decode
            if (input.len >= Header.size + 2) {
                _ = SelectiveAck.decode(input[Header.size..]);
            }
        }
    }.run, .{
        .corpus = &.{
            // Valid SYN packet (version 1, type 4=SYN)
            &(Header{ .packet_type = .st_syn, .extension = .none, .connection_id = 1234, .timestamp_us = 0, .timestamp_diff_us = 0, .wnd_size = 65535, .seq_nr = 1, .ack_nr = 0 }).encode(),
            // Valid DATA packet
            &(Header{ .packet_type = .st_data, .extension = .none, .connection_id = 5678, .timestamp_us = 100, .timestamp_diff_us = 50, .wnd_size = 32768, .seq_nr = 10, .ack_nr = 9 }).encode(),
            // Wrong version (should return null)
            &[_]u8{ 0x42, 0x00 } ++ [_]u8{0} ** 18,
            // Too short
            "",
            &[_]u8{0x41},
            &[_]u8{0} ** 19,
            // All zeros (version 0, should reject)
            &[_]u8{0} ** 20,
            // All 0xFF
            &[_]u8{0xFF} ** 20,
        },
    });
}

test "uTP header decode edge cases: single byte inputs" {
    var buf: [1]u8 = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        buf[0] = @intCast(byte);
        // Must return null for any single byte (too short)
        try std.testing.expect(Header.decode(&buf) == null);
    }
}

test "uTP header decode rejects all invalid versions" {
    var buf = [_]u8{0} ** 20;
    // Version nibble is low nibble of byte 0
    // Only version 1 is valid
    for (0..16) |v| {
        buf[0] = @as(u8, @intCast(v)); // type=0 (st_data), version=v
        const result = Header.decode(&buf);
        if (v == 1) {
            try std.testing.expect(result != null);
        } else {
            try std.testing.expect(result == null);
        }
    }
}

test "uTP selective ack decode edge cases" {
    // Empty buffer
    try std.testing.expect(SelectiveAck.decode("") == null);
    // Single byte
    try std.testing.expect(SelectiveAck.decode(&[_]u8{0}) == null);
    // len=0 (invalid)
    try std.testing.expect(SelectiveAck.decode(&[_]u8{ 0, 0 }) == null);
    // len not multiple of 4
    try std.testing.expect(SelectiveAck.decode(&[_]u8{ 0, 3, 0, 0, 0 }) == null);
    // len=4 but buffer too short
    try std.testing.expect(SelectiveAck.decode(&[_]u8{ 0, 4, 0 }) == null);
    // Valid: len=4 with enough data
    const valid = SelectiveAck.decode(&[_]u8{ 0, 4, 0xFF, 0, 0, 0 });
    try std.testing.expect(valid != null);
}

// ── Outbound connection tests ────────────────────────────

test "connect stores SYN in outbound buffer for retransmission" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    defer sock.deinit();

    _ = sock.connect(1_000_000);

    // SYN should be stored in the outbound buffer.
    try std.testing.expectEqual(@as(u16, 1), sock.out_buf_count);
    const pkt = &sock.out_buf[sock.out_seq_start % max_outbuf];
    try std.testing.expect(pkt.packet_buf != null);
    try std.testing.expectEqual(@as(u16, 0), pkt.payload_len);

    // Verify the stored packet is a valid SYN.
    const stored_hdr = Header.decode(pkt.packet_buf.?) orelse return error.DecodeFailed;
    try std.testing.expectEqual(PacketType.st_syn, stored_hdr.packet_type);
}

test "outbound data packet is buffered for retransmission" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    const hdr_bytes = sock.createDataPacket(100, 2_000_000) orelse
        return error.WindowBlocked;
    try std.testing.expect(Header.decode(&hdr_bytes) != null);

    // Now buffer the full datagram.
    var datagram: [Header.size + 100]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr_bytes);
    @memset(datagram[Header.size..], 0xAB);
    sock.bufferSentPacket(10, &datagram, 100, 2_000_000);

    try std.testing.expectEqual(@as(u16, 1), sock.out_buf_count);
    const pkt = &sock.out_buf[10 % max_outbuf];
    try std.testing.expect(pkt.packet_buf != null);
    try std.testing.expectEqual(@as(u16, 100), pkt.payload_len);
}

test "timeout marks oldest unacked packet for retransmission" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    // Create and buffer a data packet.
    const hdr_bytes = sock.createDataPacket(50, 1_000_000) orelse
        return error.WindowBlocked;
    var datagram: [Header.size + 50]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr_bytes);
    @memset(datagram[Header.size..], 0xCD);
    sock.bufferSentPacket(10, &datagram, 50, 1_000_000);

    // Trigger timeout.
    sock.handleTimeout();

    try std.testing.expect(sock.out_buf[10 % max_outbuf].needs_resend);

    // Collect retransmits.
    var entries: [8]RetransmitEntry = undefined;
    const count = sock.collectRetransmits(&entries, 2_000_000);
    try std.testing.expectEqual(@as(u16, 1), count);
    try std.testing.expectEqual(@as(u16, 10), entries[0].seq_nr);
}

test "acked packets are freed from outbound buffer" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    // Buffer two data packets.
    const hdr1 = sock.createDataPacket(50, 1_000_000) orelse return error.WindowBlocked;
    var d1: [Header.size + 50]u8 = undefined;
    @memcpy(d1[0..Header.size], &hdr1);
    @memset(d1[Header.size..], 0x01);
    sock.bufferSentPacket(10, &d1, 50, 1_000_000);

    const hdr2 = sock.createDataPacket(60, 1_001_000) orelse return error.WindowBlocked;
    var d2: [Header.size + 60]u8 = undefined;
    @memcpy(d2[0..Header.size], &hdr2);
    @memset(d2[Header.size..], 0x02);
    sock.bufferSentPacket(11, &d2, 60, 1_001_000);

    try std.testing.expectEqual(@as(u16, 2), sock.out_buf_count);

    // ACK the first packet (ack_nr = 10 means seq 10 is acked).
    const ack_hdr = Header{
        .packet_type = .st_state,
        .extension = .none,
        .connection_id = sock.recv_id,
        .timestamp_us = 1_100_000,
        .timestamp_diff_us = 100_000,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 10,
    };
    _ = sock.processPacket(ack_hdr, &.{}, 1_200_000);

    // First packet should be freed.
    try std.testing.expectEqual(@as(u16, 1), sock.out_buf_count);
    try std.testing.expectEqual(@as(u16, 11), sock.out_seq_start);
}

test "triple duplicate ACK triggers fast retransmit" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 12;
    sock.out_seq_start = 10;
    defer sock.deinit();

    // Buffer two data packets.
    var d1: [Header.size + 50]u8 = undefined;
    @memset(&d1, 0x01);
    sock.bufferSentPacket(10, &d1, 50, 1_000_000);
    var d2: [Header.size + 50]u8 = undefined;
    @memset(&d2, 0x02);
    sock.bufferSentPacket(11, &d2, 50, 1_001_000);

    sock.out_buf_count = 2;

    // Send 3 duplicate ACKs for seq 9 (meaning seq 10 is not acked).
    const make_dup_ack = struct {
        fn f(recv_id: u16) Header {
            return Header{
                .packet_type = .st_state,
                .extension = .none,
                .connection_id = recv_id,
                .timestamp_us = 1_100_000,
                .timestamp_diff_us = 100_000,
                .wnd_size = 65536,
                .seq_nr = 1,
                .ack_nr = 9,
            };
        }
    }.f;

    _ = sock.processPacket(make_dup_ack(sock.recv_id), &.{}, 1_200_000);
    _ = sock.processPacket(make_dup_ack(sock.recv_id), &.{}, 1_300_000);
    _ = sock.processPacket(make_dup_ack(sock.recv_id), &.{}, 1_400_000);

    // After 3 dup acks, the oldest packet should be marked for resend.
    try std.testing.expect(sock.out_buf[10 % max_outbuf].needs_resend);
}

test "three-way handshake with retransmission buffer" {
    const allocator = std.testing.allocator;

    // Client initiates outbound connection.
    var client = UtpSocket{};
    client.allocator = allocator;
    defer client.deinit();
    const syn_pkt = client.connect(1_000_000);
    const syn_hdr = Header.decode(&syn_pkt).?;

    try std.testing.expectEqual(State.syn_sent, client.state);
    try std.testing.expectEqual(@as(u16, 1), client.out_buf_count);

    // Server receives SYN and responds with SYN-ACK.
    var server = UtpSocket{};
    server.allocator = allocator;
    defer server.deinit();
    const syn_ack_pkt = server.acceptSyn(syn_hdr, 1_001_000);
    const syn_ack_hdr = Header.decode(&syn_ack_pkt).?;

    try std.testing.expectEqual(State.connected, server.state);

    // Client receives SYN-ACK -- transitions to connected.
    // The SYN-ACK acks the client's SYN (ack_nr should match client's SYN seq_nr).
    _ = client.processPacket(syn_ack_hdr, &.{}, 1_002_000);

    try std.testing.expectEqual(State.connected, client.state);
    // SYN should be acked and freed from outbound buffer.
    try std.testing.expectEqual(@as(u16, 0), client.out_buf_count);

    // Connection IDs complementary.
    try std.testing.expectEqual(client.recv_id, server.send_id);
    try std.testing.expectEqual(client.send_id, server.recv_id);
}

test "bytesInFlight tracks actual payload sizes" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    try std.testing.expectEqual(@as(u32, 0), sock.bytesInFlight());

    // Buffer a 100-byte payload packet.
    const hdr = sock.createDataPacket(100, 1_000_000) orelse return error.WindowBlocked;
    var d: [Header.size + 100]u8 = undefined;
    @memcpy(d[0..Header.size], &hdr);
    sock.bufferSentPacket(10, &d, 100, 1_000_000);

    try std.testing.expectEqual(@as(u32, 100 + Header.size), sock.bytesInFlight());
}

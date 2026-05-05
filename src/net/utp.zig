const std = @import("std");
const Ledbat = @import("ledbat.zig").Ledbat;
pub const UtpSettings = @import("utp_settings.zig").UtpSettings;
const packet_pool_mod = @import("utp_packet_pool.zig");
pub const UtpPacketHandle = packet_pool_mod.UtpPacketHandle;
pub const UtpPacketPool = packet_pool_mod.UtpPacketPool;
const Random = @import("../runtime/random.zig").Random;

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
/// Maximum SACK bitmask size we are willing to accept on the wire.
/// BEP 29 allows a u8 length, but the in-memory `bitmask` array is fixed
/// at 32 bytes (256 sequence numbers). Anything larger is either a
/// malformed peer or an adversarial input designed to trigger an
/// out-of-bounds `@memcpy` panic in `SelectiveAck.decode`.
pub const sack_bitmask_max: u8 = 32;

pub const SelectiveAck = struct {
    /// Next extension type.
    next_extension: Extension,
    /// Bitmask length in bytes (must be a multiple of 4, BEP 29).
    len: u8,
    /// Bitmask data (up to 32 bytes = 256 sequence numbers).
    bitmask: [sack_bitmask_max]u8 = @as([sack_bitmask_max]u8, @splat(0)),

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
        // The on-wire `len` is u8, so up to 252 is "valid" per the
        // length encoding alone, but the in-memory `bitmask` is only
        // 32 bytes. A peer-controlled `len` of 36/40/.../252 (multiple
        // of 4, > 32) would bypass the BEP 29 multiple-of-4 check and
        // panic the `@memcpy` below with "index out of bounds". Cap to
        // the local capacity. (Also defends `setBit`/`isAcked`, both
        // of which compare `byte_idx >= self.len` against `bitmask[byte_idx]`.)
        if (len == 0 or len > sack_bitmask_max or len % 4 != 0) return null;
        if (buf.len < 2 + @as(usize, len)) return null;
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

/// SACK bitmask bytes carried by ACK packets we generate. Thirty-two bytes
/// cover the full local reorder window (`ack_nr + 2` through `ack_nr + 257`).
pub const ack_sack_bytes: u8 = sack_bitmask_max;
pub const max_ack_size: usize = Header.size + 2 + ack_sack_bytes;

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
pub const max_reorder_buf = 256;

/// Maximum number of unacknowledged outbound packets retained for
/// retransmission. This is a per-socket bound on dynamic storage, not inline
/// socket footprint.
pub const max_outbuf: usize = 512;

/// Default receive window size advertised (1 MiB, matching libtorrent's default).
pub const default_recv_window: u32 = 1024 * 1024;

/// RTO bounds.
const default_min_rto_us: u32 = 500_000; // 500 ms
const max_rto_us: u32 = 60_000_000; // 60 s
const initial_rto_us: u32 = 1_000_000; // 1 s
pub const default_connect_timeout_us: u32 = 3_000_000; // 3 s, matching libtorrent's default

/// Maximum payload size per uTP packet (MTU - IP - UDP - uTP header).
pub const max_payload: u16 = 1400 - Header.size;
pub const max_datagram: usize = Header.size + max_payload;

/// An outbound packet waiting for acknowledgement.
/// Stores a packet-pool handle to the full datagram for retransmission.
/// `UtpSocket.out_buf` owns the handle until ACK/SACK cleanup or teardown.
pub const OutPacket = struct {
    seq_nr: u16 = 0,
    handle: ?UtpPacketHandle = null,
    packet_len: u16 = 0,
    /// Length of the payload portion (excluding header).
    payload_len: u16 = 0,
    send_time_us: u32 = 0,
    retransmit_count: u8 = 0,
    acked: bool = false,
    /// Whether this packet needs retransmission (set on timeout/loss detection).
    needs_resend: bool = false,

    pub fn datagram(self: *OutPacket) ?[]u8 {
        if (self.packet_len == 0) return null;
        const handle = self.handle orelse return null;
        return handle.buf[0..self.packet_len];
    }

    /// Return retained packet storage after ACK/SACK cleanup or socket teardown.
    pub fn deinit(self: *OutPacket, pool: ?*UtpPacketPool) void {
        if (self.handle) |handle| {
            if (pool) |p| p.free(handle);
        }
        self.handle = null;
        self.packet_len = 0;
    }
};

/// An entry in the receive reorder buffer.
///
/// `data` is an owned heap-allocated copy of the payload — the source
/// buffer (`event_loop.utp_recv_buf`) is reused on every datagram, so a
/// borrowed slice would be a use-after-free by the time the gap is
/// filled and the deliverer reads it back. `bufferReorder` allocates,
/// `deliverReordered` transfers ownership to `UtpSocket.delivered_payloads`,
/// and `deinit` cleans up any leftover slots.
pub const ReorderEntry = struct {
    seq_nr: u16,
    data: ?[]u8 = null,
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
    settings: UtpSettings = .{},

    /// Timestamp of the last packet we received (microseconds).
    last_recv_timestamp: u32 = 0,
    /// Our timestamp when we received it.
    last_recv_time: u32 = 0,

    /// RTT estimator (Karn's algorithm).
    srtt: u32 = 0,
    rttvar: u32 = 0,
    rto: u32 = initial_rto_us,
    rtt_initialized: bool = false,

    /// Outbound packet buffer, ordered by uTP sequence number from
    /// `out_seq_start`. It is bounded by `max_outbuf` but allocated on demand
    /// so idle sockets do not reserve retransmit storage.
    out_buf: std.ArrayList(OutPacket) = .empty,
    out_buf_head: usize = 0,
    /// Sequence number of the oldest unacknowledged packet.
    out_seq_start: u16 = 1,

    /// Receive reorder buffer.
    reorder_buf: [max_reorder_buf]ReorderEntry = @as([max_reorder_buf]ReorderEntry, @splat(.{ .seq_nr = 0, .data = null, .present = false })),

    /// Owned copies of the most recent batch of reorder-buffered payloads
    /// flushed by `deliverReordered`. The slices in `ProcessResult.reorder_data`
    /// reference these. Freed at the start of the next `deliverReordered`
    /// call (so the caller can read them during result handling) and on
    /// `deinit`.
    delivered_payloads: [max_reorder_buf]?[]u8 = @as([max_reorder_buf]?[]u8, @splat(null)),
    delivered_count: u16 = 0,

    /// Ordered application byte-stream data waiting for congestion/window
    /// space. `utp_handler` drains this into DATA packets as ACKs open
    /// capacity; keeping it here preserves uTP stream ordering across
    /// multiple peer-wire messages.
    pending_send: std.ArrayList(u8) = std.ArrayList(u8).empty,
    pending_send_offset: usize = 0,

    /// Duplicate ACK counter for fast retransmit.
    dup_ack_count: u8 = 0,

    /// Timestamp of the last packet we sent.
    last_send_time_us: u32 = 0,
    /// Timestamp of the original outbound SYN. Retransmits update
    /// `last_send_time_us`, but the connect deadline is measured from
    /// the first SYN just like libtorrent's unconfirmed uTP timeout.
    connect_started_us: ?u32 = null,
    /// Set when retransmission timeout handling decided the configured
    /// resend limit has been exceeded and the manager should reset/close.
    timeout_close_pending: bool = false,

    /// Remote address (set on connect/accept).
    remote_addr: std.net.Address = undefined,

    /// Allocator for owned packet buffers in the retransmission buffer.
    allocator: ?std.mem.Allocator = null,
    packet_pool: ?*UtpPacketPool = null,

    // ── Public API ───────────────────────────────────────

    /// Free all owned outbound packet buffers and any in-flight reorder
    /// buffer storage. Call on socket teardown.
    pub fn deinit(self: *UtpSocket) void {
        const alloc = self.allocator orelse return;
        for (self.out_buf.items) |*pkt| pkt.deinit(self.packet_pool);
        self.out_buf.deinit(alloc);
        for (&self.reorder_buf) |*entry| {
            if (entry.data) |buf| {
                alloc.free(buf);
                entry.data = null;
            }
            entry.present = false;
        }
        for (self.delivered_payloads[0..self.delivered_count]) |maybe| {
            if (maybe) |buf| alloc.free(buf);
        }
        self.delivered_count = 0;
        self.pending_send.deinit(alloc);
        self.pending_send_offset = 0;
    }

    pub fn applySettings(self: *UtpSocket, settings: UtpSettings) void {
        self.settings = settings;
        self.ledbat = Ledbat.initWithTargetDelay(settings.targetDelayUs());
        self.rto = @max(initial_rto_us, settings.minTimeoutUs());
    }

    /// Begin an outbound connection. Generates a SYN packet and stores
    /// it in the outbound buffer for retransmission on timeout.
    /// Returns the encoded SYN packet to send.
    ///
    /// `random` is the daemon-wide CSPRNG (`runtime.Random`). The uTP
    /// connection-id is a 16-bit collision-avoidance token, not a
    /// security primitive — the protocol tolerates collisions — but
    /// it goes through the same daemon-wide source for sim
    /// determinism.
    pub fn connect(self: *UtpSocket, random: *Random, now_us: u32) ![Header.size]u8 {
        // Generate random connection_id.
        var rng_buf: [2]u8 = undefined;
        random.bytes(&rng_buf);
        const conn_id = std.mem.readInt(u16, &rng_buf, .little);

        self.recv_id = conn_id;
        self.send_id = conn_id +% 1;
        self.seq_nr = 1;
        self.state = .syn_sent;
        self.connect_started_us = now_us;

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
        try self.bufferOutPacket(self.seq_nr, &encoded, 0, now_us);

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
        return self.processPacketWithSack(hdr, payload, now_us, null);
    }

    pub fn processPacketWithSack(self: *UtpSocket, hdr: Header, payload: []const u8, now_us: u32, sack: ?SelectiveAck) ProcessResult {
        var result = ProcessResult{};

        // Update timestamps for delay measurement.
        self.last_recv_timestamp = hdr.timestamp_us;
        self.last_recv_time = now_us;
        self.peer_wnd_size = hdr.wnd_size;

        const ack_delay_us = hdr.timestamp_diff_us;

        switch (hdr.packet_type) {
            .st_reset => {
                self.state = .reset;
                return result;
            },
            .st_syn => {
                // Duplicate SYN -- resend SYN-ACK.
                if (self.state == .connected or self.state == .syn_recv) {
                    result.setResponse(self.makeAckPacket(now_us));
                }
                return result;
            },
            .st_state => {
                // ACK-only packet.
                if (self.state == .syn_sent) {
                    // SYN-ACK received: complete handshake. ST_STATE does
                    // not consume receive sequence space, so expect the
                    // peer's first DATA at hdr.seq_nr.
                    self.ack_nr = hdr.seq_nr -% 1;
                    self.state = .connected;
                    self.connect_started_us = null;
                }
                self.processAck(hdr.ack_nr, sack, ack_delay_us, now_us);
                return result;
            },
            .st_data => {
                if (self.state != .connected and self.state != .fin_sent) return result;

                // Process ACK piggy-backed on data.
                self.processAck(hdr.ack_nr, sack, ack_delay_us, now_us);

                // Check if this is the next expected sequence number.
                if (hdr.seq_nr == self.ack_nr +% 1) {
                    self.ack_nr = hdr.seq_nr;
                    result.data = payload;
                    result.data_len = @intCast(payload.len);

                    // Deliver any buffered out-of-order packets.
                    result.reorder_delivered = self.deliverReordered(&result);
                } else if (seqLessThan(self.ack_nr +% 1, hdr.seq_nr)) {
                    // Future packet -- buffer for reordering.
                    self.bufferReorder(hdr.seq_nr, payload);
                }
                // else: old duplicate, ignore.

                result.setResponse(self.makeAckPacket(now_us));
                return result;
            },
            .st_fin => {
                if (self.state != .connected) return result;

                self.processAck(hdr.ack_nr, sack, ack_delay_us, now_us);
                self.ack_nr = hdr.seq_nr;
                self.state = .closed;

                // ACK the FIN.
                result.setResponse(self.makeAckPacket(now_us));
                return result;
            },
        }
    }

    pub fn outBufCount(self: *const UtpSocket) u16 {
        return @intCast(self.out_buf.items.len - self.out_buf_head);
    }

    pub fn outPacketForSeq(self: *UtpSocket, seq_nr: u16) ?*OutPacket {
        const offset = seqDiff(seq_nr, self.out_seq_start);
        if (offset < 0) return null;
        const idx: usize = self.out_buf_head + @as(usize, @intCast(offset));
        if (idx >= self.out_buf.items.len) return null;
        return &self.out_buf.items[idx];
    }

    /// Create a data packet header. The caller must pass the full datagram to
    /// `bufferSentPacket`; sequence state advances only after that retain step
    /// succeeds, so packet-pool pressure cannot create sequence gaps.
    /// Returns null if the send window is exhausted or the outbound buffer is full.
    pub fn createDataPacket(self: *UtpSocket, payload_len: u16, now_us: u32) ?[Header.size]u8 {
        if (self.state != .connected) return null;
        if (@as(usize, self.outBufCount()) >= max_outbuf) return null;

        if (payload_len == 0 or payload_len > self.availablePayloadWindow()) return null;

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
        return encoded;
    }

    /// Buffer a sent data packet for retransmission. Must be called after
    /// createDataPacket with the full datagram (header + payload).
    /// This stores an owned copy so the original buffer can be reused.
    pub fn bufferSentPacket(self: *UtpSocket, seq_nr: u16, datagram: []const u8, payload_len: u16, now_us: u32) !void {
        try self.bufferOutPacket(seq_nr, datagram, payload_len, now_us);
        if (seq_nr == self.seq_nr) {
            self.seq_nr +%= 1;
        }
        self.last_send_time_us = now_us;
    }

    /// Append bytes to the ordered application send queue.
    pub fn queueSendBytes(self: *UtpSocket, data: []const u8) !void {
        if (data.len == 0) return;
        const alloc = self.allocator orelse return error.NoAllocator;
        self.compactPendingSend();
        try self.pending_send.appendSlice(alloc, data);
    }

    /// Return the not-yet-packetized application bytes.
    pub fn pendingSendSlice(self: *const UtpSocket) []const u8 {
        return self.pending_send.items[self.pending_send_offset..];
    }

    /// Mark bytes as packetized into uTP DATA packets.
    pub fn consumePendingSend(self: *UtpSocket, amount: usize) void {
        self.pending_send_offset += @min(amount, self.pendingSendSlice().len);
        self.compactPendingSend();
    }

    pub fn hasPendingSend(self: *const UtpSocket) bool {
        return self.pending_send_offset < self.pending_send.items.len;
    }

    /// Create a FIN packet to initiate graceful shutdown.
    pub fn createFinPacket(self: *UtpSocket, now_us: u32) !?[Header.size]u8 {
        if (self.state != .connected) return null;

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

        const encoded = hdr.encode();
        try self.bufferOutPacket(self.seq_nr, &encoded, 0, now_us);

        self.state = .fin_sent;
        self.seq_nr +%= 1;
        self.last_send_time_us = now_us;
        return encoded;
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
        for (self.out_buf.items[self.out_buf_head..]) |*pkt| {
            if (!pkt.acked) {
                total += @as(u32, pkt.payload_len) + @as(u32, Header.size);
            }
        }
        return total;
    }

    /// Maximum DATA payload that can be packetized right now without
    /// exceeding the peer receive window or local congestion window.
    pub fn availablePayloadWindow(self: *const UtpSocket) u16 {
        if (self.state != .connected) return 0;
        if (@as(usize, self.outBufCount()) >= max_outbuf) return 0;

        const bytes_in_flight = self.bytesInFlight();
        const effective_wnd = @min(self.ledbat.window(), self.peer_wnd_size);
        if (bytes_in_flight >= effective_wnd) return 0;

        const available = effective_wnd - bytes_in_flight;
        return @intCast(@min(@as(u32, max_payload), available));
    }

    /// Check if a retransmission timeout has elapsed.
    pub fn isTimedOut(self: *const UtpSocket, now_us: u32) bool {
        if (self.last_send_time_us == 0) return false;
        if (self.state == .idle or self.state == .closed or self.state == .reset) return false;
        return (now_us -% self.last_send_time_us) >= self.rto;
    }

    /// True when an outbound SYN has not been confirmed inside the
    /// connection-establishment deadline. This intentionally ignores
    /// retransmit timestamps so a silent peer fails after the connect
    /// window instead of after exponential RTO backoff reaches the
    /// general connection teardown threshold.
    pub fn unconfirmedConnectTimedOut(self: *const UtpSocket, now_us: u32) bool {
        if (self.state != .syn_sent) return false;
        const started = self.connect_started_us orelse return false;
        return (now_us -% started) >= self.settings.connectTimeoutUs();
    }

    /// True when the next retransmission timeout should tear down the socket
    /// instead of scheduling another resend.
    pub fn shouldCloseAfterTimeout(self: *UtpSocket) bool {
        for (self.out_buf.items[self.out_buf_head..]) |*pkt| {
            if (pkt.acked) continue;
            if (pkt.retransmit_count >= self.resendLimitForPacket(pkt)) return true;
        }
        return false;
    }

    /// Handle a retransmission timeout event. Marks outstanding unacked
    /// packets for retransmission and applies exponential backoff.
    pub fn handleTimeout(self: *UtpSocket) void {
        if (self.shouldCloseAfterTimeout()) {
            self.timeout_close_pending = true;
            self.state = .reset;
            return;
        }

        self.ledbat.onTimeout();
        // Double the RTO (exponential backoff).
        self.rto = @min(self.rto *| 2, max_rto_us);

        // Mark every outstanding packet. Congestion/window checks still govern
        // how many retransmits are emitted on this tick.
        for (self.out_buf.items[self.out_buf_head..]) |*pkt| {
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
        for (self.out_buf.items[self.out_buf_head..]) |*pkt| {
            if (count >= out.len) break;
            if (pkt.needs_resend and !pkt.acked) {
                if (pkt.datagram()) |buf| {
                    // Refresh mutable header fields before retransmitting so
                    // resent DATA carries current ACK/window state.
                    std.mem.writeInt(u32, buf[4..8], now_us, .big);
                    std.mem.writeInt(u32, buf[8..12], self.timestampDiff(now_us), .big);
                    std.mem.writeInt(u32, buf[12..16], self.advertisedWindow(), .big);
                    std.mem.writeInt(u16, buf[18..20], self.ack_nr, .big);
                    out[count] = .{ .data = buf, .seq_nr = pkt.seq_nr };
                    pkt.needs_resend = false;
                    pkt.retransmit_count += 1;
                    pkt.send_time_us = now_us;
                    count += 1;
                }
            }
        }
        if (count > 0) {
            self.last_send_time_us = now_us;
        }
        return count;
    }

    // ── Internal ─────────────────────────────────────────

    fn processAck(self: *UtpSocket, ack_nr: u16, sack: ?SelectiveAck, delay_us: u32, now_us: u32) void {
        // Walk through outbuf and mark acked packets.
        var newly_acked_bytes: u32 = 0;
        var advanced = false;

        while (self.outBufCount() > 0) {
            var pkt = &self.out_buf.items[self.out_buf_head];

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
            pkt.deinit(self.packet_pool);

            self.out_seq_start +%= 1;
            self.out_buf_head += 1;
            advanced = true;
        }
        self.compactOutBuf();

        if (sack) |s| {
            for (self.out_buf.items[self.out_buf_head..]) |*pkt| {
                if (pkt.acked) continue;
                const sack_offset = seqDiff(pkt.seq_nr, ack_nr +% 2);
                if (sack_offset < 0) continue;
                const bit_index: u16 = @intCast(sack_offset);
                if (!s.isAcked(bit_index)) continue;

                pkt.acked = true;
                newly_acked_bytes += @as(u32, pkt.payload_len) + @as(u32, Header.size);
                if (pkt.retransmit_count == 0) {
                    self.updateRtt(now_us -% pkt.send_time_us);
                }
                pkt.deinit(self.packet_pool);
            }
        }

        if (newly_acked_bytes > 0) {
            self.ledbat.onAck(newly_acked_bytes, delay_us, now_us);
            self.dup_ack_count = 0;
        } else if (advanced == false and self.outBufCount() > 0) {
            // Duplicate ACK.
            self.dup_ack_count += 1;
            if (self.dup_ack_count >= 3) {
                // Mark oldest unacked for fast retransmit.
                self.out_buf.items[self.out_buf_head].needs_resend = true;
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
        self.rto = @min(@max(self.srtt + 4 * self.rttvar, self.settings.minTimeoutUs()), max_rto_us);
    }

    pub fn makeAck(self: *UtpSocket, now_us: u32) [Header.size]u8 {
        const packet = self.makeAckPacket(now_us);
        var header: [Header.size]u8 = undefined;
        @memcpy(&header, packet.bytes[0..Header.size]);
        return header;
    }

    pub fn makeAckPacket(self: *UtpSocket, now_us: u32) AckPacket {
        var packet = AckPacket{};
        const sack = self.buildSelectiveAck();
        const hdr = Header{
            .packet_type = .st_state,
            .extension = if (sack != null) .selective_ack else .none,
            .connection_id = self.send_id,
            .timestamp_us = now_us,
            .timestamp_diff_us = self.timestampDiff(now_us),
            .wnd_size = self.advertisedWindow(),
            .seq_nr = self.seq_nr,
            .ack_nr = self.ack_nr,
        };
        const encoded = hdr.encode();
        @memcpy(packet.bytes[0..Header.size], &encoded);
        packet.len = Header.size;
        if (sack) |s| {
            packet.len += @intCast(s.encode(packet.bytes[Header.size..]));
        }
        return packet;
    }

    fn buildSelectiveAck(self: *const UtpSocket) ?SelectiveAck {
        var sack = SelectiveAck{
            .next_extension = .none,
            .len = ack_sack_bytes,
        };
        var any = false;
        for (self.reorder_buf) |entry| {
            if (!entry.present) continue;
            const bit_index = seqDiff(entry.seq_nr, self.ack_nr +% 2);
            if (bit_index < 0) continue;
            const bit_u16: u16 = @intCast(bit_index);
            if (bit_u16 >= @as(u16, sack.len) * 8) continue;
            sack.setBit(bit_u16);
            any = true;
        }
        return if (any) sack else null;
    }

    fn timestampDiff(self: *const UtpSocket, now_us: u32) u32 {
        _ = now_us;
        if (self.last_recv_time == 0) return 0;
        return self.last_recv_time -% self.last_recv_timestamp;
    }

    fn resendLimitForPacket(self: *UtpSocket, pkt: *OutPacket) u8 {
        const data = pkt.datagram() orelse return self.settings.data_resends;
        if (data.len < Header.size) return self.settings.data_resends;
        const hdr = Header.decode(data[0..Header.size]) orelse return self.settings.data_resends;
        return switch (hdr.packet_type) {
            .st_syn => self.settings.syn_resends,
            .st_fin => self.settings.fin_resends,
            else => self.settings.data_resends,
        };
    }

    fn advertisedWindow(self: *const UtpSocket) u32 {
        if (self.recv_buf_bytes >= self.recv_wnd_size) return 0;
        return self.recv_wnd_size - self.recv_buf_bytes;
    }

    /// Store a packet in the outbound buffer for retransmission.
    /// `header_data` is the encoded header (or full datagram for control packets).
    /// `payload_len` is the length of payload following the header (0 for control).
    fn bufferOutPacket(self: *UtpSocket, seq_nr: u16, header_data: []const u8, payload_len: u16, now_us: u32) !void {
        if (@as(usize, self.outBufCount()) >= max_outbuf) return error.OutboundBufferFull;
        if (header_data.len > max_datagram) return error.DatagramTooLarge;
        const alloc = self.allocator orelse return error.NoAllocator;
        const pool = self.packet_pool orelse return error.PacketPoolUnavailable;
        if (self.outBufCount() == 0) {
            self.out_buf.clearRetainingCapacity();
            self.out_buf_head = 0;
            self.out_seq_start = seq_nr;
        }

        const handle = try pool.alloc(header_data.len);
        errdefer pool.free(handle);
        @memcpy(handle.bytes(), header_data);

        const packet = OutPacket{
            .seq_nr = seq_nr,
            .handle = handle,
            .packet_len = @intCast(header_data.len),
            .payload_len = payload_len,
            .send_time_us = now_us,
        };
        try self.out_buf.append(alloc, packet);
    }

    fn compactOutBuf(self: *UtpSocket) void {
        if (self.out_buf_head == 0) return;
        if (self.out_buf_head >= self.out_buf.items.len) {
            self.out_buf.clearRetainingCapacity();
            self.out_buf_head = 0;
            return;
        }
        if (self.out_buf_head < 64 and self.out_buf_head * 2 < self.out_buf.items.len) return;
        const remaining = self.out_buf.items[self.out_buf_head..];
        std.mem.copyForwards(OutPacket, self.out_buf.items[0..remaining.len], remaining);
        self.out_buf.shrinkRetainingCapacity(remaining.len);
        self.out_buf_head = 0;
    }

    fn compactPendingSend(self: *UtpSocket) void {
        if (self.pending_send_offset == 0) return;
        if (self.pending_send_offset >= self.pending_send.items.len) {
            self.pending_send.clearRetainingCapacity();
            self.pending_send_offset = 0;
            return;
        }
        if (self.pending_send_offset < 64 * 1024 and self.pending_send_offset * 2 < self.pending_send.items.len) {
            return;
        }
        const remaining = self.pending_send.items[self.pending_send_offset..];
        std.mem.copyForwards(u8, self.pending_send.items[0..remaining.len], remaining);
        self.pending_send.shrinkRetainingCapacity(remaining.len);
        self.pending_send_offset = 0;
    }

    fn bufferReorder(self: *UtpSocket, seq: u16, data: []const u8) void {
        // Reject too-far-future packets (outside the reorder window).
        const offset = seqDiff(seq, self.ack_nr +% 1);
        if (offset <= 0 or offset >= max_reorder_buf) return;
        // Must index by absolute `seq % max_reorder_buf` so `deliverReordered`
        // can find the slot when the gap is filled. Indexing by `offset`
        // (the prior bug) hides entries from the deliverer because
        // `next_seq % max_reorder_buf` does not equal
        // `(next_seq - ack_nr - 1) % max_reorder_buf` in the general case.
        const idx: usize = seq % max_reorder_buf;

        const alloc = self.allocator orelse return;

        // Free any prior occupant of this slot. A duplicate retransmit at
        // the same sequence number, or a stale entry left over after a
        // delivery cycle that didn't visit this slot, would otherwise leak.
        if (self.reorder_buf[idx].data) |old| {
            alloc.free(old);
            self.reorder_buf[idx].data = null;
        }

        // Copy the payload into per-slot owned storage. The source slice
        // points into `event_loop.utp_recv_buf`, which is reused on every
        // datagram — a borrowed slice would be a use-after-free by the
        // time the gap is filled and the deliverer reads it.
        const owned = alloc.alloc(u8, data.len) catch {
            self.reorder_buf[idx].present = false;
            return;
        };
        @memcpy(owned, data);

        self.reorder_buf[idx] = .{
            .seq_nr = seq,
            .data = owned,
            .present = true,
        };
    }

    fn deliverReordered(self: *UtpSocket, result: *ProcessResult) u16 {
        // Free the previous batch's delivered payloads. Slices the caller
        // received via `ProcessResult.reorder_data` are valid up to (but
        // not including) the next `deliverReordered` call on the same
        // socket — that's the contract documented on `ProcessResult`.
        if (self.allocator) |alloc| {
            for (self.delivered_payloads[0..self.delivered_count]) |maybe| {
                if (maybe) |buf| alloc.free(buf);
            }
        }
        @memset(self.delivered_payloads[0..self.delivered_count], null);
        self.delivered_count = 0;

        var count: u16 = 0;
        while (count < max_reorder_buf) {
            const next_seq = self.ack_nr +% 1;
            const idx: usize = next_seq % max_reorder_buf;
            if (!self.reorder_buf[idx].present or self.reorder_buf[idx].seq_nr != next_seq) break;
            self.ack_nr = next_seq;
            // Transfer ownership: the slice stays alive in
            // `delivered_payloads` so the caller can read it through
            // `result.reorder_data` for the duration of result handling.
            const owned = self.reorder_buf[idx].data;
            self.delivered_payloads[count] = owned;
            result.reorder_data[count] = owned;
            self.reorder_buf[idx].data = null;
            self.reorder_buf[idx].present = false;
            count += 1;
        }
        self.delivered_count = count;
        return count;
    }
};

/// Result of processing an incoming packet.
pub const ProcessResult = struct {
    /// Optional response packet (ACK) to send back.
    response: ?[max_ack_size]u8 = null,
    response_len: u8 = 0,
    /// Delivered in-order payload data (slice into the input buffer).
    data: ?[]const u8 = null,
    /// Length of delivered data.
    data_len: u16 = 0,
    /// Number of additional packets delivered from the reorder buffer.
    reorder_delivered: u16 = 0,
    /// Slices to the payloads delivered from the reorder buffer.
    /// Indexed `[0, reorder_delivered)`, in ascending sequence order.
    /// Each slice references socket-owned storage (`UtpSocket.delivered_payloads`)
    /// and remains valid until the next call to `processPacket` on the
    /// same socket, after which the storage may be freed and reused.
    /// The caller must consume (or copy) these payloads before the next
    /// processPacket invocation.
    reorder_data: [max_reorder_buf]?[]const u8 = @as([max_reorder_buf]?[]const u8, @splat(null)),

    pub fn setResponse(self: *ProcessResult, packet: AckPacket) void {
        self.response = packet.bytes;
        self.response_len = packet.len;
    }
};

pub const AckPacket = struct {
    bytes: [max_ack_size]u8 = @as([max_ack_size]u8, @splat(0)),
    len: u8 = Header.size,

    pub fn fromHeader(header: [Header.size]u8) AckPacket {
        var packet = AckPacket{};
        @memcpy(packet.bytes[0..Header.size], &header);
        return packet;
    }
};

/// An entry returned by collectRetransmits -- a packet that needs resending.
pub const RetransmitEntry = struct {
    /// Full datagram (header + payload) to re-send over UDP.
    data: []u8,
    seq_nr: u16,
};

// ── Tests ─────────────────────────────────────────────────

fn initTestPacketPool() !UtpPacketPool {
    return UtpPacketPool.init(std.testing.allocator, .{
        .initial_bytes = 512 * 1024,
        .max_bytes = 2 * 1024 * 1024,
        .mtu_slot_bytes = max_datagram,
    });
}

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
    const buf = @as([10]u8, @splat(0));
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
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    defer sock.deinit();
    var rng = Random.simRandom(0x900);
    const pkt = try sock.connect(&rng, 1_000_000);

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
    const allocator = std.testing.allocator;
    var client = UtpSocket{};
    client.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    client.packet_pool = &pool;
    defer client.deinit();
    var rng = Random.simRandom(0x901);
    const syn_pkt = try client.connect(&rng, 1_000_000);
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

test "ACK for out-of-order data carries selective ACK bits" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;
    defer sock.deinit();

    const result = sock.processPacket(makeReorderHdr(8), "future", 200);
    try std.testing.expect(result.response != null);
    try std.testing.expect(result.response_len > Header.size);

    const resp = result.response.?;
    const hdr = Header.decode(resp[0..Header.size]).?;
    try std.testing.expectEqual(Extension.selective_ack, hdr.extension);
    try std.testing.expectEqual(@as(u16, 5), hdr.ack_nr);

    const sack = SelectiveAck.decode(resp[Header.size..result.response_len]).?;
    try std.testing.expect(!sack.isAcked(0));
    try std.testing.expect(sack.isAcked(1));
}

// ── Reorder buffer regression tests ────────────────────────
//
// The reorder buffer historically had two bugs (filed in
// `progress-reports/2026-04-26-audit-hunt-round3.md` and fixed
// alongside this test surface):
//
//   1. Indexing mismatch — `bufferReorder` indexed by offset from
//      `ack_nr+1` but `deliverReordered` indexed by absolute
//      `seq_nr % max_reorder_buf`. Stored entries were unreachable, so
//      out-of-order packets were silently dropped.
//   2. Slice ownership — `data` was a borrowed slice into the shared
//      `event_loop.utp_recv_buf`. After the next datagram arrived the
//      deliverer would have read whatever happened to be there last —
//      a use-after-free that the indexing bug masked.

fn makeReorderHdr(seq: u16) Header {
    return .{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 10,
        .timestamp_us = 100,
        .timestamp_diff_us = 0,
        .wnd_size = 65536,
        .seq_nr = seq,
        .ack_nr = 0,
    };
}

test "reorder buffer delivers buffered packets when gap is filled" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 5;
    defer sock.deinit();

    // Buffer seq 8 and seq 7 out of order (gap at seq 6).
    _ = sock.processPacket(makeReorderHdr(8), "eight", 200);
    _ = sock.processPacket(makeReorderHdr(7), "seven", 200);
    try std.testing.expectEqual(@as(u16, 5), sock.ack_nr);

    // Seq 6 fills the gap. Reorder delivery should drain seq 7 and 8.
    const result = sock.processPacket(makeReorderHdr(6), "six", 200);
    try std.testing.expectEqualStrings("six", result.data.?);
    try std.testing.expectEqual(@as(u16, 2), result.reorder_delivered);
    try std.testing.expectEqual(@as(u16, 8), sock.ack_nr);
    try std.testing.expectEqualStrings("seven", result.reorder_data[0].?);
    try std.testing.expectEqualStrings("eight", result.reorder_data[1].?);
}

test "reorder buffer delivers reverse-ordered burst with correct content" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    // Receive seq 5, 4, 3, 2 (out of order); then seq 1 fills the gap.
    _ = sock.processPacket(makeReorderHdr(5), "PKT5", 200);
    _ = sock.processPacket(makeReorderHdr(4), "PKT4", 200);
    _ = sock.processPacket(makeReorderHdr(3), "PKT3", 200);
    _ = sock.processPacket(makeReorderHdr(2), "PKT2", 200);
    try std.testing.expectEqual(@as(u16, 0), sock.ack_nr);

    const result = sock.processPacket(makeReorderHdr(1), "PKT1", 200);
    try std.testing.expectEqualStrings("PKT1", result.data.?);
    try std.testing.expectEqual(@as(u16, 4), result.reorder_delivered);
    try std.testing.expectEqual(@as(u16, 5), sock.ack_nr);

    // Verify the buffered payloads were delivered in correct order with
    // correct content.
    try std.testing.expectEqualStrings("PKT2", result.reorder_data[0].?);
    try std.testing.expectEqualStrings("PKT3", result.reorder_data[1].?);
    try std.testing.expectEqualStrings("PKT4", result.reorder_data[2].?);
    try std.testing.expectEqualStrings("PKT5", result.reorder_data[3].?);
}

test "reorder buffer survives utp_recv_buf reuse (UAF regression)" {
    // The exact UAF scenario the round-3 audit flagged: bufferReorder
    // historically stored a borrowed slice into a shared recv buffer.
    // After the next datagram arrived and overwrote the buffer, the
    // deliverer would have read whatever happened to be there last,
    // not the original payload. This test reproduces the scenario by
    // mutating the source buffer between buffering and delivery and
    // asserting the delivered content matches what was originally
    // received.
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    var shared_recv_buf: [16]u8 = undefined;

    // First datagram: seq 2 (out of order). Payload "ORIGINAL".
    @memcpy(shared_recv_buf[0..8], "ORIGINAL");
    _ = sock.processPacket(makeReorderHdr(2), shared_recv_buf[0..8], 200);

    // Reuse the recv buffer with garbage — this is what would happen
    // when the next UDP datagram arrives. A borrowed-slice implementation
    // would now have its reorder entry pointing at "GARBAGE!".
    @memcpy(shared_recv_buf[0..8], "GARBAGE!");

    // Now seq 1 arrives in-order, also reusing the same buffer. The
    // reorder delivery must surface the ORIGINAL bytes, not GARBAGE.
    @memcpy(shared_recv_buf[0..6], "FIRST!");
    const result = sock.processPacket(makeReorderHdr(1), shared_recv_buf[0..6], 300);
    try std.testing.expectEqualStrings("FIRST!", result.data.?);
    try std.testing.expectEqual(@as(u16, 1), result.reorder_delivered);
    try std.testing.expectEqualStrings("ORIGINAL", result.reorder_data[0].?);
}

test "reorder buffer delivers across multiple bursts without slot collision" {
    // Sequence numbers reuse the reorder index space. After delivering
    // one batch, buffer the next one and assert no collision with
    // leftover state and no leak (testing.allocator catches leaks).
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    // Burst 1: buffer seq 3, 2 with ack_nr=0; deliver via seq 1.
    _ = sock.processPacket(makeReorderHdr(3), "AAA", 200);
    _ = sock.processPacket(makeReorderHdr(2), "BBB", 200);
    const r1 = sock.processPacket(makeReorderHdr(1), "CCC", 200);
    try std.testing.expectEqual(@as(u16, 2), r1.reorder_delivered);
    try std.testing.expectEqual(@as(u16, 3), sock.ack_nr);

    // Burst 2: buffer seq 6, 5 with ack_nr=3; deliver via seq 4.
    _ = sock.processPacket(makeReorderHdr(6), "DDD", 300);
    _ = sock.processPacket(makeReorderHdr(5), "EEE", 300);
    const r2 = sock.processPacket(makeReorderHdr(4), "FFF", 300);
    try std.testing.expectEqualStrings("FFF", r2.data.?);
    try std.testing.expectEqual(@as(u16, 2), r2.reorder_delivered);
    try std.testing.expectEqualStrings("EEE", r2.reorder_data[0].?);
    try std.testing.expectEqualStrings("DDD", r2.reorder_data[1].?);
    try std.testing.expectEqual(@as(u16, 6), sock.ack_nr);
}

test "reorder buffer slot eviction frees prior occupant" {
    // If a peer (re)transmits a duplicate out-of-order packet to the
    // same slot, bufferReorder must free the previous occupant before
    // writing the new copy. testing.allocator catches leaks. This also
    // exercises the slot-eviction path: reorder slots filled with full-sized
    // payloads, then re-filled with new payloads after the first batch
    // is delivered.
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    // Buffer seq 3 once; then again with different content (eviction).
    _ = sock.processPacket(makeReorderHdr(3), "FIRST", 200);
    _ = sock.processPacket(makeReorderHdr(3), "SECOND", 200);

    // Buffer seq 2 and deliver via seq 1.
    _ = sock.processPacket(makeReorderHdr(2), "TWO", 200);
    const r = sock.processPacket(makeReorderHdr(1), "ONE", 200);
    try std.testing.expectEqual(@as(u16, 2), r.reorder_delivered);
    // The latest copy of seq 3 should have won; SECOND, not FIRST.
    try std.testing.expectEqualStrings("TWO", r.reorder_data[0].?);
    try std.testing.expectEqualStrings("SECOND", r.reorder_data[1].?);
}

test "reorder buffer fills window slots and delivers cleanly" {
    // The window allows offsets in (0, max_reorder_buf). Fill all
    // reorder slots ahead of the gap, then deliver via
    // the gap-filler. testing.allocator catches leaks across the
    // full-buffer path.
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    // Buffer seq max_reorder_buf..2, all out of order. The gap is at 1.
    var seq: u16 = max_reorder_buf;
    while (seq >= 2) : (seq -= 1) {
        var payload_buf: [4]u8 = undefined;
        std.mem.writeInt(u16, payload_buf[0..2], seq, .big);
        payload_buf[2] = 0xCC;
        payload_buf[3] = 0xDD;
        _ = sock.processPacket(makeReorderHdr(seq), &payload_buf, 200);
    }
    try std.testing.expectEqual(@as(u16, 0), sock.ack_nr);

    // Fill the gap with seq 1. All buffered packets should drain.
    const r = sock.processPacket(makeReorderHdr(1), "GAP!", 200);
    try std.testing.expectEqual(@as(u16, max_reorder_buf - 1), r.reorder_delivered);
    try std.testing.expectEqual(@as(u16, max_reorder_buf), sock.ack_nr);
    // Spot-check the first and last payloads in delivery order.
    var expected_first: [4]u8 = undefined;
    std.mem.writeInt(u16, expected_first[0..2], 2, .big);
    expected_first[2] = 0xCC;
    expected_first[3] = 0xDD;
    try std.testing.expectEqualSlices(u8, &expected_first, r.reorder_data[0].?);
    var expected_last: [4]u8 = undefined;
    std.mem.writeInt(u16, expected_last[0..2], max_reorder_buf, .big);
    expected_last[2] = 0xCC;
    expected_last[3] = 0xDD;
    try std.testing.expectEqualSlices(u8, &expected_last, r.reorder_data[max_reorder_buf - 2].?);
}

test "reorder buffer deinit frees pending slots without leak" {
    // If a socket is destroyed with reorder slots still occupied
    // (e.g. peer aborted before the gap filled), deinit must free
    // every owned payload. testing.allocator catches leaks.
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;

    // Buffer several out-of-order packets and never deliver them.
    _ = sock.processPacket(makeReorderHdr(5), "x", 200);
    _ = sock.processPacket(makeReorderHdr(7), "yy", 200);
    _ = sock.processPacket(makeReorderHdr(9), "zzz", 200);

    sock.deinit();
    // No leak = pass.
}

test "reorder buffer rejects out-of-window seq numbers" {
    // The reorder window only accepts offsets in (0, max_reorder_buf). A peer
    // sending seq=ack_nr+>=max_reorder_buf must be silently dropped, not buffered
    // (otherwise it could overwrite an in-window slot because of the
    // modular indexing).
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.state = .connected;
    sock.send_id = 10;
    sock.ack_nr = 0;
    defer sock.deinit();

    // Buffer a legitimate seq 5.
    _ = sock.processPacket(makeReorderHdr(5), "legit", 200);
    try std.testing.expect(sock.reorder_buf[5].present);
    try std.testing.expectEqualStrings("legit", sock.reorder_buf[5].data.?);

    // Send a seq beyond the reorder window with the same slot index. This
    // must not displace the legitimate seq 5 entry.
    _ = sock.processPacket(makeReorderHdr(5 + max_reorder_buf), "evilevil", 200);
    try std.testing.expect(sock.reorder_buf[5].present);
    try std.testing.expectEqualStrings("legit", sock.reorder_buf[5].data.?);
    try std.testing.expectEqual(@as(u16, 5), sock.reorder_buf[5].seq_nr);
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
    sock.allocator = std.testing.allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    defer sock.deinit();
    sock.state = .connected;
    sock.send_id = 10;

    const fin_bytes = try sock.createFinPacket(1_000_000);
    try std.testing.expect(fin_bytes != null);

    const hdr = Header.decode(&fin_bytes.?).?;
    try std.testing.expectEqual(PacketType.st_fin, hdr.packet_type);
    try std.testing.expectEqual(State.fin_sent, sock.state);
    try std.testing.expectEqual(@as(u16, 1), sock.outBufCount());
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
    try std.testing.expect(sock.rto >= default_min_rto_us);
}

test "timeout detection" {
    var sock = UtpSocket{};
    // isTimedOut explicitly returns false for `.idle`, `.closed`, and
    // `.reset` so torn-down sockets don't keep tripping the manager's
    // timeout sweep. The test must put the socket in an "alive" state
    // for the timing comparison to actually run.
    sock.state = .connected;
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
            &([_]u8{ 0x42, 0x00 } ++ @as([18]u8, @splat(0))),
            // Too short
            "",
            &[_]u8{0x41},
            &@as([19]u8, @splat(0)),
            // All zeros (version 0, should reject)
            &@as([20]u8, @splat(0)),
            // All 0xFF
            &@as([20]u8, @splat(0xFF)),
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
    var buf = @as([20]u8, @splat(0));
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
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    defer sock.deinit();

    var rng = Random.simRandom(0x902);
    _ = try sock.connect(&rng, 1_000_000);

    // SYN should be stored in the outbound buffer.
    try std.testing.expectEqual(@as(u16, 1), sock.outBufCount());
    const pkt = sock.outPacketForSeq(sock.out_seq_start).?;
    try std.testing.expect(pkt.datagram() != null);
    try std.testing.expectEqual(@as(u16, 0), pkt.payload_len);

    // Verify the stored packet is a valid SYN.
    const stored_hdr = Header.decode(pkt.datagram().?) orelse return error.DecodeFailed;
    try std.testing.expectEqual(PacketType.st_syn, stored_hdr.packet_type);
}

test "outbound data packet is buffered for retransmission" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
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
    try sock.bufferSentPacket(10, &datagram, 100, 2_000_000);

    try std.testing.expectEqual(@as(u16, 1), sock.outBufCount());
    const pkt = sock.outPacketForSeq(10).?;
    try std.testing.expect(pkt.datagram() != null);
    try std.testing.expectEqual(@as(u16, 100), pkt.payload_len);
}

test "outbound retransmit buffer grows beyond former inline cap" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    sock.ledbat.cwnd = Ledbat.max_cwnd;
    sock.peer_wnd_size = default_recv_window;
    defer sock.deinit();

    const packets = 256;
    var i: usize = 0;
    while (i < packets) : (i += 1) {
        const seq: u16 = @intCast(10 + i);
        const hdr = sock.createDataPacket(100, 1_000_000 + @as(u32, @intCast(i))) orelse
            return error.WindowBlocked;
        var datagram: [Header.size + 100]u8 = undefined;
        @memcpy(datagram[0..Header.size], &hdr);
        @memset(datagram[Header.size..], 0xaa);
        try sock.bufferSentPacket(seq, &datagram, 100, 1_000_000 + @as(u32, @intCast(i)));
    }

    try std.testing.expectEqual(@as(u16, packets), sock.outBufCount());
    try std.testing.expect(sock.out_buf.capacity >= packets);
    try std.testing.expect(sock.outPacketForSeq(10) != null);
    try std.testing.expect(sock.outPacketForSeq(10 + packets - 1) != null);
}

test "timeout marks oldest unacked packet for retransmission" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
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
    try sock.bufferSentPacket(10, &datagram, 50, 1_000_000);

    // Trigger timeout.
    sock.handleTimeout();

    try std.testing.expect(sock.outPacketForSeq(10).?.needs_resend);

    // Collect retransmits.
    var entries: [8]RetransmitEntry = undefined;
    const count = sock.collectRetransmits(&entries, 2_000_000);
    try std.testing.expectEqual(@as(u16, 1), count);
    try std.testing.expectEqual(@as(u16, 10), entries[0].seq_nr);
}

test "packet pool exhaustion fails outbound buffering without leaking handle" {
    const allocator = std.testing.allocator;
    var pool = try UtpPacketPool.init(allocator, .{
        .initial_bytes = 64,
        .max_bytes = 64,
        .mtu_slot_bytes = max_datagram,
        .growth_chunk_bytes = 64,
    });
    defer pool.deinit();

    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;

    const hdr = (Header{
        .packet_type = .st_data,
        .extension = .none,
        .connection_id = 42,
        .timestamp_us = 1_000_000,
        .timestamp_diff_us = 0,
        .wnd_size = default_recv_window,
        .seq_nr = 10,
        .ack_nr = 0,
    }).encode();

    try sock.bufferSentPacket(10, &hdr, 0, 1_000_000);
    try std.testing.expectEqual(@as(u64, 64), pool.stats().used_bytes);

    try std.testing.expectError(error.PacketPoolExhausted, sock.bufferSentPacket(11, &hdr, 0, 1_001_000));
    try std.testing.expectEqual(@as(u16, 1), sock.outBufCount());
    try std.testing.expectEqual(@as(u64, 64), pool.stats().used_bytes);

    sock.deinit();
    try std.testing.expectEqual(@as(u64, 0), pool.stats().used_bytes);
}

test "packet pool exhaustion after DATA header creation does not consume sequence" {
    const allocator = std.testing.allocator;
    var pool = try UtpPacketPool.init(allocator, .{
        .initial_bytes = 64,
        .max_bytes = 64,
        .mtu_slot_bytes = max_datagram,
        .growth_chunk_bytes = 64,
    });
    defer pool.deinit();

    const filler = try pool.alloc(20);
    defer pool.free(filler);

    var sock = UtpSocket{};
    sock.allocator = allocator;
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    const hdr = sock.createDataPacket(1, 1_000_000) orelse return error.WindowBlocked;
    var datagram: [Header.size + 1]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr);
    datagram[Header.size] = 0xaa;

    try std.testing.expectError(error.PacketPoolExhausted, sock.bufferSentPacket(10, &datagram, 1, 1_000_000));
    try std.testing.expectEqual(@as(u16, 10), sock.seq_nr);
    try std.testing.expectEqual(@as(u16, 0), sock.outBufCount());
    try std.testing.expectEqual(@as(u64, 64), pool.stats().used_bytes);
}

test "SYN resend limit resets socket after configured retries" {
    var sock = UtpSocket{};
    sock.allocator = std.testing.allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.applySettings(.{
        .syn_resends = 1,
        .connect_timeout_ms = 60_000,
    });
    defer sock.deinit();

    var rng = Random.simRandom(0x510);
    _ = try sock.connect(&rng, 1_000_000);

    sock.handleTimeout();
    try std.testing.expect(!sock.timeout_close_pending);

    var entries: [1]RetransmitEntry = undefined;
    try std.testing.expectEqual(@as(u16, 1), sock.collectRetransmits(&entries, 2_000_000));
    try std.testing.expectEqual(@as(u8, 1), sock.outPacketForSeq(sock.out_seq_start).?.retransmit_count);

    sock.handleTimeout();
    try std.testing.expect(sock.timeout_close_pending);
    try std.testing.expectEqual(State.reset, sock.state);
}

test "FIN resend limit resets socket after configured retries" {
    var sock = UtpSocket{};
    sock.allocator = std.testing.allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.applySettings(.{ .fin_resends = 1 });
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    _ = try sock.createFinPacket(1_000_000);

    sock.handleTimeout();
    try std.testing.expect(!sock.timeout_close_pending);

    var entries: [1]RetransmitEntry = undefined;
    try std.testing.expectEqual(@as(u16, 1), sock.collectRetransmits(&entries, 2_000_000));
    try std.testing.expectEqual(@as(u8, 1), sock.outPacketForSeq(10).?.retransmit_count);

    sock.handleTimeout();
    try std.testing.expect(sock.timeout_close_pending);
    try std.testing.expectEqual(State.reset, sock.state);
}

test "DATA resend limit resets socket after configured retries" {
    var sock = UtpSocket{};
    sock.allocator = std.testing.allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.applySettings(.{ .data_resends = 1 });
    sock.state = .connected;
    sock.send_id = 42;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    const hdr = sock.createDataPacket(100, 1_000_000) orelse return error.WindowBlocked;
    var datagram: [Header.size + 100]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr);
    @memset(datagram[Header.size..], 0xaa);
    try sock.bufferSentPacket(10, &datagram, 100, 1_000_000);

    sock.handleTimeout();
    try std.testing.expect(!sock.timeout_close_pending);

    var entries: [1]RetransmitEntry = undefined;
    try std.testing.expectEqual(@as(u16, 1), sock.collectRetransmits(&entries, 2_000_000));
    try std.testing.expectEqual(@as(u8, 1), sock.outPacketForSeq(10).?.retransmit_count);

    sock.handleTimeout();
    try std.testing.expect(sock.timeout_close_pending);
    try std.testing.expectEqual(State.reset, sock.state);
}

test "unconfirmed connect timeout uses original SYN timestamp" {
    var sock = UtpSocket{};
    sock.allocator = std.testing.allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    defer sock.deinit();

    var rng = Random.simRandom(0xc017);
    _ = try sock.connect(&rng, 1_000_000);
    try std.testing.expect(!sock.unconfirmedConnectTimedOut(3_999_999));

    sock.handleTimeout();
    var entries: [1]RetransmitEntry = undefined;
    const count = sock.collectRetransmits(&entries, 2_000_000);
    try std.testing.expectEqual(@as(u16, 1), count);
    try std.testing.expectEqual(@as(u32, 2_000_000), sock.last_send_time_us);

    try std.testing.expect(sock.unconfirmedConnectTimedOut(4_000_000));
}

test "acked packets are freed from outbound buffer" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
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
    try sock.bufferSentPacket(10, &d1, 50, 1_000_000);

    const hdr2 = sock.createDataPacket(60, 1_001_000) orelse return error.WindowBlocked;
    var d2: [Header.size + 60]u8 = undefined;
    @memcpy(d2[0..Header.size], &hdr2);
    @memset(d2[Header.size..], 0x02);
    try sock.bufferSentPacket(11, &d2, 60, 1_001_000);

    try std.testing.expectEqual(@as(u16, 2), sock.outBufCount());

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
    try std.testing.expectEqual(@as(u16, 1), sock.outBufCount());
    try std.testing.expectEqual(@as(u16, 11), sock.out_seq_start);
}

test "cumulative ACK returns packet pool handle" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    const hdr = sock.createDataPacket(50, 1_000_000) orelse return error.WindowBlocked;
    var datagram: [Header.size + 50]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr);
    @memset(datagram[Header.size..], 0x01);
    try sock.bufferSentPacket(10, &datagram, 50, 1_000_000);
    try std.testing.expect(pool.stats().used_bytes > 0);

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

    try std.testing.expectEqual(@as(u16, 0), sock.outBufCount());
    try std.testing.expectEqual(@as(u64, 0), pool.stats().used_bytes);
}

test "ACK delay sample uses peer-reported timestamp diff" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    defer sock.deinit();

    const hdr = sock.createDataPacket(100, 1_000_000) orelse return error.WindowBlocked;
    var datagram: [Header.size + 100]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr);
    @memset(datagram[Header.size..], 0xaa);
    try sock.bufferSentPacket(10, &datagram, 100, 1_000_000);

    const ack_hdr = Header{
        .packet_type = .st_state,
        .extension = .none,
        .connection_id = sock.recv_id,
        // Remote clocks are not synchronized with ours. This timestamp
        // must not be subtracted from our local clock for LEDBAT.
        .timestamp_us = 3_000_000_000,
        .timestamp_diff_us = 5_000,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 10,
    };
    _ = sock.processPacket(ack_hdr, &.{}, 1_100_000);

    try std.testing.expectEqual(@as(u32, 5_000), sock.ledbat.base_delay);
}

test "outgoing timestamp diff uses receive-time sample" {
    var sock = UtpSocket{};
    sock.state = .connected;
    sock.send_id = 42;
    sock.ack_nr = 9;
    sock.last_recv_timestamp = 900_000;
    sock.last_recv_time = 1_000_000;

    const ack = Header.decode(&sock.makeAck(1_001_500)).?;
    try std.testing.expectEqual(@as(u32, 100_000), ack.timestamp_diff_us);
}

test "triple duplicate ACK triggers fast retransmit" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 12;
    sock.out_seq_start = 10;
    defer sock.deinit();

    // Buffer two data packets.
    var d1: [Header.size + 50]u8 = undefined;
    @memset(&d1, 0x01);
    try sock.bufferSentPacket(10, &d1, 50, 1_000_000);
    var d2: [Header.size + 50]u8 = undefined;
    @memset(&d2, 0x02);
    try sock.bufferSentPacket(11, &d2, 50, 1_001_000);

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
    try std.testing.expect(sock.outPacketForSeq(10).?.needs_resend);
}

test "incoming selective ACK frees non-contiguous outbound packets" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 13;
    sock.out_seq_start = 10;
    defer sock.deinit();

    inline for (.{ 10, 11, 12 }) |seq| {
        var datagram: [Header.size + 100]u8 = undefined;
        @memset(&datagram, @as(u8, seq));
        try sock.bufferSentPacket(seq, &datagram, 100, 1_000_000 + seq);
    }
    const used_before_sack = pool.stats().used_bytes;
    try std.testing.expect(used_before_sack > 0);

    var sack = SelectiveAck{ .next_extension = .none, .len = 4 };
    sack.setBit(0); // ack_nr 9 => seq 11
    sack.setBit(1); // ack_nr 9 => seq 12

    const ack_hdr = Header{
        .packet_type = .st_state,
        .extension = .selective_ack,
        .connection_id = sock.recv_id,
        .timestamp_us = 1_100_000,
        .timestamp_diff_us = 10_000,
        .wnd_size = 65536,
        .seq_nr = 1,
        .ack_nr = 9,
    };
    _ = sock.processPacketWithSack(ack_hdr, &.{}, 1_200_000, sack);

    try std.testing.expect(!sock.outPacketForSeq(10).?.acked);
    try std.testing.expect(sock.outPacketForSeq(11).?.acked);
    try std.testing.expect(sock.outPacketForSeq(12).?.acked);
    try std.testing.expectEqual(@as(u16, 3), sock.outBufCount());
    try std.testing.expectEqual(@as(u32, Header.size + 100), sock.bytesInFlight());
    const retained = sock.outPacketForSeq(10).?.handle.?.capacity;
    try std.testing.expectEqual(@as(u64, retained), pool.stats().used_bytes);
    try std.testing.expect(pool.stats().used_bytes < used_before_sack);
}

test "retransmit refreshes timestamp ack and window header fields" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
    sock.state = .connected;
    sock.send_id = 42;
    sock.recv_id = 41;
    sock.seq_nr = 10;
    sock.out_seq_start = 10;
    sock.ack_nr = 7;
    sock.last_recv_timestamp = 900_000;
    sock.last_recv_time = 1_000_000;
    sock.recv_wnd_size = 32 * 1024;
    defer sock.deinit();

    const hdr = sock.createDataPacket(100, 1_000_000) orelse return error.WindowBlocked;
    var datagram: [Header.size + 100]u8 = undefined;
    @memcpy(datagram[0..Header.size], &hdr);
    @memset(datagram[Header.size..], 0xaa);
    try sock.bufferSentPacket(10, &datagram, 100, 1_000_000);
    sock.ack_nr = 9;
    sock.recv_buf_bytes = 1024;
    sock.outPacketForSeq(10).?.needs_resend = true;

    var entries: [1]RetransmitEntry = undefined;
    const n = sock.collectRetransmits(&entries, 1_200_000);
    try std.testing.expectEqual(@as(u16, 1), n);

    const refreshed = Header.decode(entries[0].data[0..Header.size]).?;
    try std.testing.expectEqual(@as(u32, 1_200_000), refreshed.timestamp_us);
    try std.testing.expectEqual(@as(u32, 100_000), refreshed.timestamp_diff_us);
    try std.testing.expectEqual(@as(u32, 32 * 1024 - 1024), refreshed.wnd_size);
    try std.testing.expectEqual(@as(u16, 9), refreshed.ack_nr);
}

test "three-way handshake with retransmission buffer" {
    const allocator = std.testing.allocator;

    // Client initiates outbound connection.
    var client = UtpSocket{};
    client.allocator = allocator;
    var client_pool = try initTestPacketPool();
    defer client_pool.deinit();
    client.packet_pool = &client_pool;
    defer client.deinit();
    var rng = Random.simRandom(0x903);
    const syn_pkt = try client.connect(&rng, 1_000_000);
    const syn_hdr = Header.decode(&syn_pkt).?;

    try std.testing.expectEqual(State.syn_sent, client.state);
    try std.testing.expectEqual(@as(u16, 1), client.outBufCount());

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
    try std.testing.expectEqual(@as(u16, 0), client.outBufCount());

    // Connection IDs complementary.
    try std.testing.expectEqual(client.recv_id, server.send_id);
    try std.testing.expectEqual(client.send_id, server.recv_id);
}

test "bytesInFlight tracks actual payload sizes" {
    const allocator = std.testing.allocator;
    var sock = UtpSocket{};
    sock.allocator = allocator;
    var pool = try initTestPacketPool();
    defer pool.deinit();
    sock.packet_pool = &pool;
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
    try sock.bufferSentPacket(10, &d, 100, 1_000_000);

    try std.testing.expectEqual(@as(u32, 100 + Header.size), sock.bytesInFlight());
}

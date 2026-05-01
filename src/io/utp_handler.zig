const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const utp_mod = @import("../net/utp.zig");
const utp_mgr = @import("../net/utp_manager.zig");
const Peer = @import("event_loop.zig").Peer;
const protocol = @import("protocol.zig");
const io_interface = @import("io_interface.zig");

// ── uTP transport ──────────────────────────────────────

/// Submit a RECVMSG SQE for the UDP socket to receive the next datagram.
pub fn submitUtpRecv(self: anytype) !void {
    if (self.udp_fd < 0) return;

    // Set up iovec pointing to the recv buffer
    self.utp_recv_iov[0] = .{
        .base = &self.utp_recv_buf,
        .len = self.utp_recv_buf.len,
    };

    // Initialize the source address storage (large enough for IPv4 and IPv6).
    self.utp_recv_addr = std.mem.zeroes(std.net.Address);

    // Set up msghdr. namelen is set to the full storage size so the kernel
    // can write an IPv6 sockaddr_in6 if needed; it updates namelen on return.
    self.utp_recv_msg = .{
        .name = @ptrCast(&self.utp_recv_addr),
        .namelen = @sizeOf(std.net.Address),
        .iov = &self.utp_recv_iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    try self.io.recvmsg(
        .{ .fd = self.udp_fd, .msg = &self.utp_recv_msg },
        &self.utp_recv_completion,
        self,
        utpRecvCompleteFor(@TypeOf(self.*)),
    );
}

fn utpRecvCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const res: i32 = switch (result) {
                .recvmsg => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |err| if (err == error.OperationCanceled) -125 else -1, // -ECANCELED
                else => -1,
            };
            handleUtpRecvResult(self, res);
            return .disarm; // re-armed by handleUtpRecvResult via submitUtpRecv
        }
    }.cb;
}

/// Submit a SENDMSG SQE to send a uTP packet over UDP.
pub fn submitUtpSend(self: anytype, data: []const u8, remote: std.net.Address) !void {
    if (self.udp_fd < 0) return;

    // Copy data into send buffer
    const len = @min(data.len, self.utp_send_buf.len);
    @memcpy(self.utp_send_buf[0..len], data[0..len]);

    // Set up iovec
    // Need to cast the const buffer pointer to iovec_const
    self.utp_send_iov[0] = .{
        .base = @ptrCast(&self.utp_send_buf),
        .len = len,
    };

    // Set up destination address. If the UDP socket is AF.INET6 (dual-stack)
    // and the remote is an IPv4 address, convert to IPv4-mapped IPv6 so the
    // kernel can route it correctly.
    self.utp_send_addr = toSendAddr(remote);

    // Set up msghdr_const
    self.utp_send_msg = .{
        .name = @ptrCast(&self.utp_send_addr),
        .namelen = self.utp_send_addr.getOsSockLen(),
        .iov = @ptrCast(&self.utp_send_iov),
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    try self.io.sendmsg(
        .{ .fd = self.udp_fd, .msg = &self.utp_send_msg },
        &self.utp_send_completion,
        self,
        utpSendCompleteFor(@TypeOf(self.*)),
    );
    self.utp_send_pending = true;
}

fn utpSendCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const res: i32 = switch (result) {
                .sendmsg => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                else => -1,
            };
            handleUtpSendResult(self, res);
            return .disarm;
        }
    }.cb;
}

/// Queue a uTP packet for sending. If no send is in flight, submit immediately.
pub fn utpSendPacket(self: anytype, data: []const u8, remote: std.net.Address) void {
    const UtpQueuedPacket = @TypeOf(self.*).UtpQueuedPacket;
    if (self.utp_send_pending) {
        // Queue for later
        var pkt = UtpQueuedPacket{
            .len = @min(data.len, 1500),
            .remote = remote,
        };
        @memcpy(pkt.data[0..pkt.len], data[0..pkt.len]);
        self.utp_send_queue.append(self.allocator, pkt) catch {
            log.warn("uTP send queue full, dropping packet", .{});
        };
    } else {
        submitUtpSend(self, data, remote) catch |err| {
            log.warn("uTP send failed: {s}", .{@errorName(err)});
        };
    }
}

/// Drain the uTP send queue: submit the next queued packet.
pub fn utpDrainSendQueue(self: anytype) void {
    if (self.utp_send_queue.items.len == 0) return;
    const pkt = self.utp_send_queue.orderedRemove(0);
    submitUtpSend(self, pkt.data[0..pkt.len], pkt.remote) catch |err| {
        log.warn("uTP queued send failed: {s}", .{@errorName(err)});
        // Try next packet
        self.utp_send_pending = false;
        utpDrainSendQueue(self);
    };
}

fn handleUtpRecvResult(self: anytype, recv_res: i32) void {
    // Always re-submit recv for the next datagram
    defer submitUtpRecv(self) catch |err| {
        log.err("failed to re-submit uTP recv: {s}", .{@errorName(err)});
    };

    if (recv_res < 0) {
        // ECANCELED is expected when stopUtpListener cancels the pending recvmsg.
        if (recv_res != -125) {
            log.warn("uTP recvmsg failed: res={d}", .{recv_res});
        }
        return;
    }

    const datagram_len: usize = @intCast(recv_res);
    if (datagram_len == 0) return;

    const data = self.utp_recv_buf[0..datagram_len];

    // The remote address was written into utp_recv_addr by the kernel.
    // On a dual-stack IPv6 socket, IPv4 peers arrive as IPv4-mapped IPv6
    // addresses (::ffff:x.x.x.x, AF.INET6). Normalize these back to AF.INET
    // so DHT and uTP code can treat them uniformly.
    const remote = normalizeMappedAddr(self.utp_recv_addr);

    // Demux DHT vs uTP: bencode dicts start with 'd' (0x64), uTP starts with version nibble 0x01
    if (data[0] == 'd') {
        const dht_handler = @import("dht_handler.zig");
        dht_handler.handleDhtRecv(self, data, remote);
        return;
    }

    const mgr = self.utp_manager orelse return;
    if (datagram_len < utp_mod.Header.size) return; // too short for a uTP header

    // Get microsecond timestamp for uTP
    const now_us = utpNowUs();

    // Process the packet through the UtpManager
    const result = mgr.processPacket(data, remote, now_us) orelse return;

    // Send response packet if any
    if (result.response) |resp| {
        utpSendPacket(self, &resp, result.remote);
    }

    // Handle new inbound connections
    if (result.new_connection) {
        acceptUtpConnection(self, mgr);
    }

    // Check if an outbound connection just completed the handshake
    // (SYN-ACK received, socket transitioned to connected).
    if (!result.new_connection) {
        checkOutboundUtpConnect(self, result.slot, mgr);
    }

    // Handle delivered data for existing connections.
    if (result.data) |utp_data| {
        deliverUtpData(self, result.slot, utp_data);
    }
    // Drain any payloads that the reorder buffer flushed in this call
    // (out-of-order packets whose gap was just filled). Slices reference
    // socket-owned storage that's freed on the next processPacket call;
    // deliverUtpData copies into the peer's body buffer immediately.
    for (0..result.reorder_delivered) |i| {
        if (result.reorder_data[i]) |buf| {
            deliverUtpData(self, result.slot, buf);
        }
    }
}

fn handleUtpSendResult(self: anytype, send_res: i32) void {
    self.utp_send_pending = false;

    if (send_res < 0) {
        log.warn("uTP sendmsg failed: res={d}", .{send_res});
    }

    // Drain the send queue
    utpDrainSendQueue(self);
}

/// Check if an outbound uTP connection just completed the three-way
/// handshake (peer was in .connecting state, socket is now .connected).
/// If so, begin the peer wire protocol handshake over uTP.
fn checkOutboundUtpConnect(self: anytype, utp_slot: u16, mgr: *utp_mgr.UtpManager) void {
    const peer_slot = findPeerByUtpSlot(self, utp_slot) orelse return;
    const peer = &self.peers[peer_slot];

    if (peer.state != .connecting) return;

    const sock = mgr.getSocket(utp_slot) orelse return;
    if (sock.state != .connected) return;

    // uTP handshake complete -- connection is established.
    if (self.half_open_count > 0) self.half_open_count -= 1;
    peer.state = .handshake_send;
    peer.last_activity = self.clock.now();

    log.info("outbound uTP connection established to {f}", .{peer.address});

    // Build and send BitTorrent handshake over uTP.
    const tc = self.getTorrentContext(peer.torrent_id) orelse {
        self.removePeer(peer_slot);
        return;
    };
    const swarm_hash = self.selectedPeerSwarmHash(peer);
    var buf: [68]u8 = undefined;
    buf[0] = pw.protocol_length;
    @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
    @memset(buf[20..28], 0);
    buf[20 + ext.reserved_byte] |= ext.reserved_mask;
    // BEP 52: advertise v2 protocol support for v2/hybrid torrents
    if (tc.info_hash_v2 != null) {
        buf[20 + pw.v2_reserved_byte] |= pw.v2_reserved_mask;
    }
    @memcpy(buf[28..48], &swarm_hash);
    @memcpy(buf[48..68], &tc.peer_id);

    utpSendData(self, peer_slot, &buf) catch {
        self.removePeer(peer_slot);
        return;
    };

    // Transition to waiting for the peer's handshake response.
    peer.state = .handshake_recv;
    peer.handshake_offset = 0;
}

/// Accept pending inbound uTP connections and create Peer entries.
fn acceptUtpConnection(self: anytype, mgr: *utp_mgr.UtpManager) void {
    while (mgr.accept()) |utp_slot| {
        // Reject inbound uTP connections during graceful shutdown drain
        if (self.draining) {
            log.debug("rejected inbound uTP connection: shutting down", .{});
            const now_us = utpNowUs();
            if (mgr.reset(utp_slot, now_us)) |rst| {
                const remote = mgr.getRemoteAddress(utp_slot) orelse continue;
                utpSendPacket(self, &rst, remote);
            }
            continue;
        }

        // Reject inbound uTP if transport disposition disables it
        if (!self.transport_disposition.incoming_utp) {
            log.debug("rejected inbound uTP connection: incoming_utp disabled", .{});
            const now_us = utpNowUs();
            if (mgr.reset(utp_slot, now_us)) |rst| {
                const remote = mgr.getRemoteAddress(utp_slot) orelse continue;
                utpSendPacket(self, &rst, remote);
            }
            continue;
        }

        // Enforce global connection limit
        if (self.peer_count >= self.max_connections) {
            log.warn("rejecting inbound uTP connection: global limit reached", .{});
            const now_us = utpNowUs();
            if (mgr.reset(utp_slot, now_us)) |rst| {
                const remote = mgr.getRemoteAddress(utp_slot) orelse continue;
                utpSendPacket(self, &rst, remote);
            }
            continue;
        }

        const peer_slot = self.allocSlot() orelse {
            log.warn("rejecting inbound uTP connection: no peer slots", .{});
            const now_us = utpNowUs();
            if (mgr.reset(utp_slot, now_us)) |rst| {
                const remote = mgr.getRemoteAddress(utp_slot) orelse continue;
                utpSendPacket(self, &rst, remote);
            }
            continue;
        };

        const remote_addr = mgr.getRemoteAddress(utp_slot) orelse continue;
        const peer = &self.peers[peer_slot];
        peer.* = Peer{
            .fd = -1, // uTP peers don't have a direct fd
            .state = .inbound_handshake_recv,
            .mode = .inbound,
            .transport = .utp,
            .utp_slot = utp_slot,
            .address = remote_addr,
        };
        self.peer_count += 1;
        self.markActivePeer(peer_slot);

        log.info("accepted inbound uTP connection from {f}", .{remote_addr});

        // For uTP peers, data arrives via the UtpSocket ordered byte stream.
        // We don't submit io_uring recv -- data is delivered via deliverUtpData.
        // The peer will receive handshake data through the uTP data channel.
        // For now we just mark the peer as waiting for the handshake.
        peer.handshake_offset = 0;
    }
}

/// Deliver ordered byte-stream data from a uTP socket to the peer wire layer.
/// This maps uTP slot -> peer slot and feeds data as if it came from a TCP recv.
fn deliverUtpData(self: anytype, utp_slot: u16, data: []const u8) void {
    // Find the peer associated with this uTP slot
    const peer_slot = findPeerByUtpSlot(self, utp_slot) orelse return;
    const peer = &self.peers[peer_slot];

    if (peer.state == .free) return;

    switch (peer.state) {
        .handshake_recv => {
            // Outbound uTP peer: receiving the peer's handshake response.
            const remaining = 68 - peer.handshake_offset;
            const to_copy = @min(data.len, remaining);
            @memcpy(peer.handshake_buf[peer.handshake_offset .. peer.handshake_offset + to_copy], data[0..to_copy]);
            peer.handshake_offset += to_copy;

            if (peer.handshake_offset >= 68) {
                processUtpOutboundHandshake(self, peer_slot);
                if (peer.state == .free) return;
                // Feed any remaining data.
                if (to_copy < data.len) {
                    deliverUtpData(self, utp_slot, data[to_copy..]);
                }
            }
        },
        .inbound_handshake_recv => {
            // Feed data into handshake buffer
            const remaining = 68 - peer.handshake_offset;
            const to_copy = @min(data.len, remaining);
            @memcpy(peer.handshake_buf[peer.handshake_offset .. peer.handshake_offset + to_copy], data[0..to_copy]);
            peer.handshake_offset += to_copy;

            if (peer.handshake_offset >= 68) {
                // Process the completed handshake
                processUtpInboundHandshake(self, peer_slot);
                if (peer.state == .free) return;
                // Feed any remaining data.
                if (to_copy < data.len) {
                    deliverUtpData(self, utp_slot, data[to_copy..]);
                }
            }
        },
        .active_recv_header => {
            // Feed data into header buffer
            const remaining = 4 - peer.header_offset;
            const to_copy = @min(data.len, remaining);
            @memcpy(peer.header_buf[peer.header_offset .. peer.header_offset + to_copy], data[0..to_copy]);
            peer.header_offset += to_copy;

            if (peer.header_offset >= 4) {
                const msg_len = std.mem.readInt(u32, &peer.header_buf, .big);
                if (msg_len == 0) {
                    // Keep-alive
                    peer.last_activity = self.clock.now();
                    peer.header_offset = 0;
                    return;
                }
                if (msg_len > pw.max_message_length) {
                    self.removePeer(peer_slot);
                    return;
                }
                if (msg_len <= peer.small_body_buf.len) {
                    peer.body_buf = peer.small_body_buf[0..msg_len];
                    peer.body_is_heap = false;
                } else {
                    peer.body_buf = self.allocator.alloc(u8, msg_len) catch {
                        self.removePeer(peer_slot);
                        return;
                    };
                    peer.body_is_heap = true;
                }
                peer.body_offset = 0;
                peer.body_expected = msg_len;
                peer.state = .active_recv_body;

                // Feed any remaining data into the body
                if (to_copy < data.len) {
                    deliverUtpData(self, utp_slot, data[to_copy..]);
                }
            }
        },
        .active_recv_body => {
            const remaining = peer.body_expected - peer.body_offset;
            const to_copy = @min(data.len, remaining);
            if (peer.body_buf) |buf| {
                @memcpy(buf[peer.body_offset .. peer.body_offset + to_copy], data[0..to_copy]);
            }
            peer.body_offset += to_copy;

            if (peer.body_offset >= peer.body_expected) {
                // Full message received
                protocol.processMessage(self, peer_slot);
                if (peer.state != .active_recv_body) return;
                if (peer.body_is_heap) {
                    if (peer.body_buf) |buf| self.allocator.free(buf);
                }
                peer.body_buf = null;
                peer.body_is_heap = false;
                peer.state = .active_recv_header;
                peer.header_offset = 0;

                // Feed remaining data
                if (to_copy < data.len) {
                    deliverUtpData(self, utp_slot, data[to_copy..]);
                }
            }
        },
        else => {},
    }
}

/// Process a completed outbound handshake response from a uTP peer.
/// This is the uTP equivalent of the TCP handshake_recv path.
fn processUtpOutboundHandshake(self: anytype, peer_slot: u16) void {
    const peer = &self.peers[peer_slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse {
        self.removePeer(peer_slot);
        return;
    };

    pw.validateHandshakePrefix(peer.handshake_buf[0..68]) catch {
        self.removePeer(peer_slot);
        return;
    };

    // Validate info_hash matches what we expected (v1 or v2 for BEP 52).
    const recv_hash = peer.handshake_buf[28..48];
    const v1_match = std.mem.eql(u8, recv_hash, tc.info_hash[0..]);
    const v2_match = if (tc.info_hash_v2) |v2| std.mem.eql(u8, recv_hash, v2[0..]) else false;
    if (!v1_match and !v2_match) {
        self.removePeer(peer_slot);
        return;
    }
    // Store remote peer ID for client identification
    @memcpy(&peer.remote_peer_id, peer.handshake_buf[48..68]);
    peer.has_peer_id = true;

    // BEP 10: check if peer supports extensions.
    const recv_reserved = peer.handshake_buf[20..28];
    peer.extensions_supported = ext.supportsExtensions(recv_reserved[0..8].*);

    if (peer.extensions_supported) {
        // Send extension handshake over uTP.
        peer.state = .extension_handshake_send;
        submitUtpExtensionHandshake(self, peer_slot) catch {
            // Extension handshake failed; fall through to interested.
            sendUtpInterestedAndGoActive(self, peer_slot);
            return;
        };
        handleUtpSendComplete(self, peer_slot);
    } else {
        sendUtpInterestedAndGoActive(self, peer_slot);
    }
}

/// Process a completed inbound handshake from a uTP peer.
fn processUtpInboundHandshake(self: anytype, peer_slot: u16) void {
    const peer = &self.peers[peer_slot];

    pw.validateHandshakePrefix(peer.handshake_buf[0..68]) catch {
        self.removePeer(peer_slot);
        return;
    };

    const inbound_hash = peer.handshake_buf[28..48];
    var response_hash: [20]u8 = undefined;
    @memcpy(&response_hash, inbound_hash);

    // Match info_hash against all registered torrents.
    // BEP 52: also match on the truncated v2 info-hash for hybrid torrents.
    const resp_tid = self.findTorrentIdByInfoHash(inbound_hash) orelse {
        self.removePeer(peer_slot);
        return;
    };
    peer.torrent_id = resp_tid;
    self.attachPeerToTorrent(resp_tid, peer_slot);
    // Store remote peer ID for client identification
    @memcpy(&peer.remote_peer_id, peer.handshake_buf[48..68]);
    peer.has_peer_id = true;

    // BEP 10: check if inbound peer supports extensions
    const inbound_reserved = peer.handshake_buf[20..28];
    peer.extensions_supported = ext.supportsExtensions(inbound_reserved[0..8].*);

    // Send our handshake back via uTP
    const tc = self.getTorrentContext(resp_tid) orelse {
        self.removePeer(peer_slot);
        return;
    };
    var buf: [68]u8 = undefined;
    buf[0] = pw.protocol_length;
    @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
    @memset(buf[20..28], 0);
    buf[20 + ext.reserved_byte] |= ext.reserved_mask;
    // BEP 52: advertise v2 protocol support for v2/hybrid torrents
    if (tc.info_hash_v2 != null) {
        buf[20 + pw.v2_reserved_byte] |= pw.v2_reserved_mask;
    }
    @memcpy(buf[28..48], &response_hash);
    @memcpy(buf[48..68], &tc.peer_id);

    utpSendData(self, peer_slot, &buf) catch {
        self.removePeer(peer_slot);
        return;
    };
    peer.state = .inbound_handshake_send;
    // For uTP, the send completion is immediate from our perspective --
    // transition to the next state directly since there's no send CQE to wait for.
    handleUtpSendComplete(self, peer_slot);
}

/// Send data over a uTP connection (wraps it in uTP DATA packets).
/// Stores the packet in the outbound buffer for retransmission.
pub fn utpSendData(self: anytype, peer_slot: u16, data: []const u8) !void {
    const peer = &self.peers[peer_slot];
    const utp_slot = peer.utp_slot orelse return error.NotUtpPeer;
    const mgr = self.utp_manager orelse return error.NoUtpManager;
    const remote = mgr.getRemoteAddress(utp_slot) orelse return error.NoRemoteAddress;

    const now_us = utpNowUs();

    // Fragment data into MTU-sized uTP DATA packets.
    // Each packet carries at most (MTU - uTP header) bytes of payload.
    const max_payload = 1400 - utp_mod.Header.size; // conservative MTU
    var offset: usize = 0;
    while (offset < data.len) {
        const chunk_len = @min(data.len - offset, max_payload);

        const hdr_bytes = mgr.createDataPacket(utp_slot, @intCast(chunk_len), now_us) orelse {
            // Congestion window full — we'll retry on the next tick.
            // Partial sends are OK; the peer will request missing blocks.
            if (offset > 0) return; // sent some data, that's progress
            return error.WindowFull;
        };

        const pkt_seq_nr = std.mem.readInt(u16, hdr_bytes[16..18], .big);

        var send_buf: [1400]u8 = undefined;
        const total = utp_mod.Header.size + chunk_len;
        @memcpy(send_buf[0..utp_mod.Header.size], &hdr_bytes);
        @memcpy(send_buf[utp_mod.Header.size..][0..chunk_len], data[offset..][0..chunk_len]);

        const sock = mgr.getSocket(utp_slot) orelse return error.NoSocket;
        sock.bufferSentPacket(pkt_seq_nr, send_buf[0..total], @intCast(chunk_len), now_us);

        utpSendPacket(self, send_buf[0..total], remote);
        offset += chunk_len;
    }
}

/// Handle the completion of a uTP send for a peer. Since uTP sends don't
/// have per-peer CQEs, this drives the peer state machine forward.
fn handleUtpSendComplete(self: anytype, peer_slot: u16) void {
    const peer = &self.peers[peer_slot];

    switch (peer.state) {
        // ── Outbound connection flow ──
        .extension_handshake_send => {
            // BEP 10: extension handshake sent. Now send interested and go active.
            sendUtpInterestedAndGoActive(self, peer_slot);
        },
        // ── Inbound connection flow ──
        .inbound_handshake_send => {
            if (peer.extensions_supported) {
                peer.state = .inbound_extension_handshake_send;
                submitUtpExtensionHandshake(self, peer_slot) catch {
                    sendUtpInboundBitfieldOrUnchoke(self, peer_slot);
                    return;
                };
                // Drive the state machine forward — without this, the peer
                // stays in .inbound_extension_handshake_send and deliverUtpData
                // drops all incoming data in the `else => {}` branch.
                handleUtpSendComplete(self, peer_slot);
            } else {
                sendUtpInboundBitfieldOrUnchoke(self, peer_slot);
            }
        },
        .inbound_extension_handshake_send => {
            sendUtpInboundBitfieldOrUnchoke(self, peer_slot);
        },
        .inbound_bitfield_send => {
            peer.state = .inbound_unchoke_send;
            peer.am_choking = false;
            utpSendMessage(self, peer_slot, 1, &.{}) catch {
                self.removePeer(peer_slot);
                return;
            };
            handleUtpSendComplete(self, peer_slot);
        },
        .inbound_unchoke_send => {
            peer.state = .active_recv_header;
            peer.header_offset = 0;
            // uTP peers don't need a recv SQE -- data arrives via deliverUtpData
        },
        .active_recv_header, .active_recv_body => {
            // Outbound data (piece request, etc.) sent. Nothing to do here
            // for uTP -- pipeline filling is handled by the policy layer.
        },
        else => {},
    }
}

/// Send interested message and transition an outbound uTP peer to active
/// download mode. This is the uTP equivalent of protocol.sendInterestedAndGoActive.
fn sendUtpInterestedAndGoActive(self: anytype, peer_slot: u16) void {
    const peer = &self.peers[peer_slot];
    peer.am_interested = true;
    // Message ID 2 = interested
    utpSendMessage(self, peer_slot, 2, &.{}) catch {
        self.removePeer(peer_slot);
        return;
    };
    peer.state = .active_recv_header;
    peer.header_offset = 0;
    // uTP peers don't need a recv SQE -- data arrives via deliverUtpData
}

/// Send a BEP 10 extension handshake over uTP.
fn submitUtpExtensionHandshake(self: anytype, peer_slot: u16) !void {
    const peer = &self.peers[peer_slot];
    const is_private = if (self.getTorrentContext(peer.torrent_id)) |tc| tc.is_private else false;
    const ext_payload = try ext.encodeExtensionHandshake(self.allocator, self.port, is_private);
    defer self.allocator.free(ext_payload);
    const frame = try ext.serializeExtensionMessage(self.allocator, ext.handshake_sub_id, ext_payload);
    defer self.allocator.free(frame);
    try utpSendData(self, peer_slot, frame);
}

/// Send bitfield or unchoke for an inbound uTP peer.
fn sendUtpInboundBitfieldOrUnchoke(self: anytype, peer_slot: u16) void {
    const peer = &self.peers[peer_slot];
    const tc_bp = self.getTorrentContext(peer.torrent_id);
    if ((if (tc_bp) |t| t.complete_pieces else null) orelse self.complete_pieces) |cp| {
        peer.state = .inbound_bitfield_send;
        utpSendMessage(self, peer_slot, 5, cp.bits) catch {
            self.removePeer(peer_slot);
            return;
        };
        handleUtpSendComplete(self, peer_slot);
    } else {
        peer.state = .inbound_unchoke_send;
        peer.am_choking = false;
        utpSendMessage(self, peer_slot, 1, &.{}) catch {
            self.removePeer(peer_slot);
            return;
        };
        handleUtpSendComplete(self, peer_slot);
    }
}

/// Send a framed peer wire message over uTP.
pub fn utpSendMessage(self: anytype, peer_slot: u16, id: u8, payload: []const u8) !void {
    const msg_len = @as(u32, @intCast(1 + payload.len));
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], msg_len, .big);
    header[4] = id;

    if (payload.len <= 12) {
        var combined: [17]u8 = undefined;
        @memcpy(combined[0..5], &header);
        @memcpy(combined[5 .. 5 + payload.len], payload);
        try utpSendData(self, peer_slot, combined[0 .. 5 + payload.len]);
    } else {
        const total_len = 5 + payload.len;
        const send_buf = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(send_buf);
        @memcpy(send_buf[0..5], &header);
        @memcpy(send_buf[5..total_len], payload);
        try utpSendData(self, peer_slot, send_buf);
    }
}

/// Find the peer slot associated with a uTP connection slot.
pub fn findPeerByUtpSlot(self: anytype, utp_slot: u16) ?u16 {
    for (self.peers, 0..) |*peer, i| {
        if (peer.state != .free and peer.transport == .utp and peer.utp_slot != null and peer.utp_slot.? == utp_slot) {
            return @intCast(i);
        }
    }
    return null;
}

/// Process uTP timeouts for all active connections. Retransmits packets
/// that have timed out and closes connections that have backed off too much.
pub fn utpTick(self: anytype) void {
    const mgr = self.utp_manager orelse return;
    const now_us = utpNowUs();

    var timeout_buf: [64]u16 = undefined;
    const timeout_count = mgr.checkTimeouts(now_us, &timeout_buf);

    // Close connections that have backed off too much.
    for (timeout_buf[0..timeout_count]) |utp_slot| {
        const sock = mgr.getSocket(utp_slot) orelse continue;
        if (sock.rto >= 30_000_000) { // 30 seconds
            if (mgr.reset(utp_slot, now_us)) |rst| {
                if (mgr.getRemoteAddress(utp_slot)) |remote| {
                    utpSendPacket(self, &rst, remote);
                }
            }
            // Remove the associated peer
            if (findPeerByUtpSlot(self, utp_slot)) |peer_slot| {
                self.removePeer(peer_slot);
            }
        }
    }

    // Collect and retransmit packets marked for resend.
    var retransmit_buf: [32]utp_mgr.RetransmitResult = undefined;
    const retransmit_count = mgr.collectRetransmits(now_us, &retransmit_buf);
    for (retransmit_buf[0..retransmit_count]) |entry| {
        utpSendPacket(self, entry.data, entry.remote);
    }
}

/// Get current time in microseconds (wrapping u32 for uTP timestamps).
pub fn utpNowUs() u32 {
    const ts = std.time.microTimestamp();
    return @truncate(@as(u64, @intCast(ts)));
}

test "uTP handshake delivery rejects invalid protocol prefix" {
    const event_loop_mod = @import("event_loop.zig");
    const SimIO = @import("sim_io.zig").SimIO;
    const EL = event_loop_mod.EventLoopOf(SimIO);

    const sim_io = try SimIO.init(std.testing.allocator, .{ .seed = 0x5251 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const info_hash = [_]u8{0xAA} ** 20;
    const peer_id = [_]u8{0xBB} ** 20;
    const empty_fds = [_]posix.fd_t{};
    const torrent_id = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = info_hash,
        .peer_id = peer_id,
    });

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{
        .fd = -1,
        .state = .handshake_recv,
        .mode = .outbound,
        .transport = .utp,
        .torrent_id = torrent_id,
        .utp_slot = 7,
    };
    el.peer_count = 1;
    el.markActivePeer(slot);
    el.attachPeerToTorrent(torrent_id, slot);

    var handshake = pw.serializeHandshake(info_hash, peer_id);
    handshake[1] = 'X';
    deliverUtpData(&el, 7, &handshake);

    try std.testing.expectEqual(event_loop_mod.PeerState.free, el.peers[slot].state);
}

test "uTP body delivery does not re-arm a slot removed by message processing" {
    const event_loop_mod = @import("event_loop.zig");
    const SimIO = @import("sim_io.zig").SimIO;
    const session_mod = @import("../torrent/session.zig");
    const layout_mod = @import("../torrent/layout.zig");
    const EL = event_loop_mod.EventLoopOf(SimIO);

    const sim_io = try SimIO.init(std.testing.allocator, .{ .seed = 0x5252 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    var fake_session = session_mod.Session{
        .torrent_bytes = &.{},
        .metainfo = undefined,
        .layout = layout_mod.Layout{
            .piece_length = 16 * 1024,
            .piece_count = 9,
            .total_size = 9 * 16 * 1024,
            .files = &.{},
        },
        .manifest = undefined,
        .pieces_allocator = std.testing.allocator,
    };
    const empty_fds = [_]posix.fd_t{};
    const torrent_id = try el.addTorrentContext(.{
        .session = &fake_session,
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    });

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{
        .fd = -1,
        .state = .active_recv_header,
        .mode = .outbound,
        .transport = .utp,
        .torrent_id = torrent_id,
        .utp_slot = 7,
    };
    el.peer_count = 1;
    el.markActivePeer(slot);
    el.attachPeerToTorrent(torrent_id, slot);

    const invalid_bitfield_frame = [_]u8{ 0, 0, 0, 2, 5, 0x80 };
    deliverUtpData(&el, 7, &invalid_bitfield_frame);

    try std.testing.expectEqual(event_loop_mod.PeerState.free, el.peers[slot].state);
}

/// Normalize an IPv4-mapped IPv6 address (::ffff:x.x.x.x) to a plain IPv4
/// address. On a dual-stack IPv6 socket, incoming IPv4 datagrams have family
/// AF.INET6 with the first 10 bytes zero and bytes 10-11 = 0xffff. Return the
/// address unchanged for native IPv6 or native IPv4 addresses.
fn normalizeMappedAddr(addr: std.net.Address) std.net.Address {
    if (addr.any.family != std.posix.AF.INET6) return addr;
    const bytes = &addr.in6.sa.addr;
    // IPv4-mapped prefix: 10 zero bytes + 0xff 0xff
    const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (!std.mem.eql(u8, bytes[0..12], &mapped_prefix)) return addr;
    // Bytes 12-15 are the IPv4 address (network byte order)
    const ipv4: [4]u8 = bytes[12..16].*;
    const port = addr.in6.getPort();
    return std.net.Address.initIp4(ipv4, port);
}

/// Convert an address for sending on a dual-stack IPv6 socket.
/// If the destination is an IPv4 address, convert it to an IPv4-mapped
/// IPv6 address (::ffff:x.x.x.x) so sendmsg works on the AF.INET6 socket.
fn toSendAddr(addr: std.net.Address) std.net.Address {
    if (addr.any.family != std.posix.AF.INET) return addr;
    // Build ::ffff:x.x.x.x from the IPv4 address bytes.
    const ip4: [4]u8 = @bitCast(addr.in.sa.addr);
    var ip6: [16]u8 = std.mem.zeroes([16]u8);
    ip6[10] = 0xff;
    ip6[11] = 0xff;
    ip6[12] = ip4[0];
    ip6[13] = ip4[1];
    ip6[14] = ip4[2];
    ip6[15] = ip4[3];
    return std.net.Address.initIp6(ip6, addr.getPort(), 0, 0);
}

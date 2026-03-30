const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const EventLoop = @import("event_loop.zig").EventLoop;
const Peer = @import("event_loop.zig").Peer;
const TorrentContext = @import("event_loop.zig").TorrentContext;
const encodeUserData = @import("event_loop.zig").encodeUserData;

// ── Peer wire protocol message processing ─────────────────

pub fn processMessage(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const body = peer.body_buf orelse return;
    if (body.len == 0) return;

    // Any message from the peer means it's alive
    peer.last_activity = std.time.timestamp();

    const id = body[0];
    const payload = body[1..];

    switch (id) {
        0 => { // choke
            peer.peer_choking = true;
            // Clear pipeline state
            peer.inflight_requests = 0;
            peer.pipeline_sent = peer.blocks_received;
            self.unmarkIdle(slot);
        },
        1 => {
            peer.peer_choking = false; // unchoke
            self.markIdle(slot);
        },
        2 => { // interested
            peer.peer_interested = true;
            // For seed mode, unchoking is now handled by recalculateUnchokes
            // But for immediate responsiveness, unchoke if under the limit
            if (peer.mode == .seed and peer.am_choking) {
                peer.am_choking = false;
                submitMessage(self, slot, 1, &.{}) catch {};
            }
        },
        3 => {
            peer.peer_interested = false;
        }, // not interested
        4 => { // have
            if (payload.len >= 4) {
                const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                if (peer.availability) |*bf| {
                    bf.set(piece_index) catch {};
                }
                peer.availability_known = true;
                if (self.getTorrentContext(peer.torrent_id)) |tc| {
                    if (tc.piece_tracker) |pt| pt.addAvailability(piece_index);
                }
                self.markIdle(slot);
            }
        },
        5 => { // bitfield
            const tc_bf = self.getTorrentContext(peer.torrent_id) orelse return;
            if (peer.availability == null) {
                const sess = tc_bf.session orelse return;
                peer.availability = Bitfield.init(self.allocator, sess.pieceCount()) catch return;
            }
            if (peer.availability) |*bf| {
                bf.importBitfield(payload);
            }
            peer.availability_known = true;
            if (tc_bf.piece_tracker) |pt| pt.addBitfieldAvailability(payload);
            self.markIdle(slot);
        },
        6 => { // request
            if (peer.mode == .seed and !peer.am_choking and payload.len >= 12) {
                const seed = @import("seed_handler.zig");
                seed.servePieceRequest(self, slot, payload);
            }
        },
        7 => { // piece
            if (payload.len >= 8) {
                const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                const block_offset = std.mem.readInt(u32, payload[4..8], .big);
                const block_data = payload[8..];

                // Consume download tokens for rate limiting accounting
                _ = self.consumeDownloadTokens(peer.torrent_id, block_data.len);

                if (peer.current_piece != null and peer.current_piece.? == piece_index) {
                    if (peer.piece_buf) |pbuf| {
                        const start: usize = @intCast(block_offset);
                        const end = start + block_data.len;
                        if (end <= pbuf.len) {
                            @memcpy(pbuf[start..end], block_data);
                            peer.blocks_received += 1;
                            peer.bytes_downloaded_from += block_data.len;
                            if (peer.inflight_requests > 0) peer.inflight_requests -= 1;

                            if (peer.blocks_received >= peer.blocks_expected) {
                                const policy = @import("peer_policy.zig");
                                policy.completePieceDownload(self, slot);
                            } else {
                                // Refill pipeline — request more blocks if slots available.
                                // Without this, pieces with more blocks than pipeline_depth stall.
                                const policy = @import("peer_policy.zig");
                                policy.tryFillPipeline(self, slot) catch |err| {
                                    log.debug("pipeline refill failed for slot {d}: {s}", .{ slot, @errorName(err) });
                                };
                            }
                        }
                    }
                }
            }
        },
        ext.msg_id => {
            // BEP 10: extension message
            if (payload.len < 1) return;
            const sub_id = payload[0];
            const ext_payload = payload[1..];

            if (sub_id == ext.handshake_sub_id) {
                // Extension handshake: parse peer's extension map
                var result = ext.decodeExtensionHandshake(self.allocator, ext_payload) catch {
                    log.debug("slot {d}: failed to decode extension handshake", .{slot});
                    return;
                };
                peer.extension_ids = result.handshake.extensions;
                log.debug("slot {d}: peer extensions: ut_metadata={d} ut_pex={d} client={s}", .{
                    slot,
                    result.handshake.extensions.ut_metadata,
                    result.handshake.extensions.ut_pex,
                    result.handshake.client,
                });
                ext.freeDecoded(self.allocator, &result);
            } else {
                // Extension-specific message -- stub for future handlers
                log.debug("slot {d}: unhandled extension message sub_id={d} len={d}", .{
                    slot, sub_id, ext_payload.len,
                });
            }
        },
        else => {},
    }
}

// ── SQE helpers ───────────────────────────────────────

pub fn submitHandshakeRecv(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    const buf = peer.handshake_buf[peer.handshake_offset..68];
    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
    _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0);
}

pub fn submitHeaderRecv(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    const buf = peer.header_buf[peer.header_offset..4];
    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
    _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0);
}

pub fn submitBodyRecv(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    const buf = peer.body_buf orelse return error.NullBuffer;
    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
    _ = try self.ring.recv(ud, peer.fd, .{ .buffer = buf[peer.body_offset..peer.body_expected] }, 0);
}

pub fn submitMessage(self: *EventLoop, slot: u16, id: u8, payload: []const u8) !void {
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

/// Send our BEP 10 extension handshake as a tracked (heap-allocated) send.
pub fn submitExtensionHandshake(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    // Encode the bencoded extension handshake payload
    const ext_payload = try ext.encodeExtensionHandshake(self.allocator, self.port);
    defer self.allocator.free(ext_payload);

    // Build the full framed message: 4-byte len | msg_id=20 | sub_id=0 | payload
    const frame = try ext.serializeExtensionMessage(self.allocator, ext.handshake_sub_id, ext_payload);

    // Track for cleanup
    try self.pending_sends.append(self.allocator, .{ .buf = frame, .slot = slot });

    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 }); // context=1 = tracked
    _ = try self.ring.send(ud, peer.fd, frame, 0);
    peer.send_pending = true;
}

/// Helper: send interested and transition to active recv (outbound download peer).
pub fn sendInterestedAndGoActive(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    submitMessage(self, slot, 2, &.{}) catch {
        self.removePeer(slot);
        return;
    };
    peer.am_interested = true;
    peer.state = .active_recv_header;
    peer.header_offset = 0;
    submitHeaderRecv(self, slot) catch {
        self.removePeer(slot);
    };
}

/// Helper: send bitfield (if available) then unchoke for an inbound seed peer.
pub fn sendInboundBitfieldOrUnchoke(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const tc_bp = self.getTorrentContext(peer.torrent_id);
    if ((if (tc_bp) |t| t.complete_pieces else null) orelse self.complete_pieces) |cp| {
        peer.state = .inbound_bitfield_send;
        submitMessage(self, slot, 5, cp.bits) catch {
            self.removePeer(slot);
        };
    } else {
        // No bitfield to send, go straight to unchoke
        peer.state = .inbound_unchoke_send;
        peer.am_choking = false;
        submitMessage(self, slot, 1, &.{}) catch {
            self.removePeer(slot);
        };
    }
}

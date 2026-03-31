const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const mse = @import("../crypto/mse.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const Peer = @import("event_loop.zig").Peer;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const decodeUserData = @import("event_loop.zig").decodeUserData;
const protocol = @import("protocol.zig");

// ── CQE dispatch handlers ──────────────────────────────

pub fn handleAccept(self: *EventLoop, cqe: linux.io_uring_cqe) void {
    if (cqe.res < 0) {
        // Accept failed, try again
        log.warn("accept failed: errno={d}", .{-cqe.res});
        self.submitAccept() catch |err| {
            log.err("re-submit accept after failure: {s}", .{@errorName(err)});
        };
        return;
    }
    const new_fd: posix.fd_t = @intCast(cqe.res);

    // Enforce global connection limit on inbound connections
    if (self.peer_count >= self.max_connections) {
        log.warn("rejecting inbound connection: global limit reached ({d}/{d})", .{
            self.peer_count,
            self.max_connections,
        });
        posix.close(new_fd);
        self.submitAccept() catch |err| {
            log.err("re-submit accept after connection limit: {s}", .{@errorName(err)});
        };
        return;
    }

    // Allocate a peer slot for the inbound connection
    const slot = self.allocSlot() orelse {
        posix.close(new_fd);
        self.submitAccept() catch |err| {
            log.err("re-submit accept after slot exhaustion: {s}", .{@errorName(err)});
        };
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
    protocol.submitHandshakeRecv(self, slot) catch {
        self.removePeer(slot);
    };

    // Re-submit accept for more connections
    self.submitAccept() catch |err| {
        log.err("re-submit accept: {s}", .{@errorName(err)});
    };
}

pub fn handleConnect(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
    // Connection attempt completed (success or failure) -- no longer half-open
    if (self.half_open_count > 0) self.half_open_count -= 1;

    const peer = &self.peers[slot];
    // Guard: stale CQE for an already-freed slot
    if (peer.state == .free) return;

    if (cqe.res < 0) {
        self.removePeer(slot);
        return;
    }
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
    // BEP 10: advertise extension protocol support
    buf[20 + ext.reserved_byte] |= ext.reserved_mask;
    @memcpy(buf[28..48], tc.info_hash[0..]);
    @memcpy(buf[48..68], tc.peer_id[0..]);
    @memcpy(peer.handshake_buf[0..68], &buf);
    // MSE/PE: encrypt handshake before sending
    peer.crypto.encryptBuf(peer.handshake_buf[0..68]);

    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
    _ = self.ring.send(ud, peer.fd, peer.handshake_buf[0..68], 0) catch {
        self.removePeer(slot);
        return;
    };
    peer.send_pending = true;
}

pub fn handleSend(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
    const peer = &self.peers[slot];
    const op = decodeUserData(cqe.user_data);
    const send_id: u32 = @truncate(op.context);

    // Guard: if the peer slot was already freed (stale CQE from a
    // previously-closed fd), just free the tracked buffer if any.
    if (peer.state == .free) {
        if (op.context != 0) self.freeOnePendingSend(slot, send_id);
        return;
    }

    if (cqe.res <= 0) {
        // Check if this was a tracked send buffer -- free it on error.
        // Only free ONE buffer: removePeer will clean up the rest.
        if (op.context != 0) self.freeOnePendingSend(slot, send_id);
        self.removePeer(slot);
        return;
    }

    // Check if this was a tracked send buffer (context != 0, send_id encoded)
    if (op.context != 0) {
        const bytes_sent: usize = @intCast(cqe.res);
        // Check for partial send and re-submit remainder
        if (!self.handlePartialSend(slot, send_id, bytes_sent)) {
            // Full send complete, free the buffer
            self.freeOnePendingSend(slot, send_id);
        }
    }

    peer.send_pending = false;

    switch (peer.state) {
        .handshake_send => {
            // Now recv peer's handshake
            peer.state = .handshake_recv;
            peer.handshake_offset = 0;
            protocol.submitHandshakeRecv(self, slot) catch {
                self.removePeer(slot);
            };
        },
        .extension_handshake_send => {
            // BEP 10: extension handshake sent (outbound peer).
            // Now send interested and go active.
            protocol.sendInterestedAndGoActive(self, slot);
        },
        .inbound_handshake_send => {
            // Handshake sent -- send extension handshake if peer supports BEP 10
            if (peer.extensions_supported) {
                peer.state = .inbound_extension_handshake_send;
                protocol.submitExtensionHandshake(self, slot) catch {
                    // Fall through to bitfield/unchoke on failure
                    protocol.sendInboundBitfieldOrUnchoke(self, slot);
                };
            } else {
                protocol.sendInboundBitfieldOrUnchoke(self, slot);
            }
        },
        .inbound_extension_handshake_send => {
            // BEP 10: extension handshake sent (inbound peer).
            // Continue with bitfield/unchoke.
            protocol.sendInboundBitfieldOrUnchoke(self, slot);
        },
        .inbound_bitfield_send => {
            // Bitfield sent -- now send unchoke
            peer.state = .inbound_unchoke_send;
            peer.am_choking = false;
            protocol.submitMessage(self, slot, 1, &.{}) catch {
                self.removePeer(slot);
            };
        },
        .inbound_unchoke_send => {
            // Unchoke sent -- go active
            peer.state = .active_recv_header;
            peer.header_offset = 0;
            protocol.submitHeaderRecv(self, slot) catch {
                self.removePeer(slot);
            };
        },
        .active_recv_header, .active_recv_body => {
            // Piece request sent or other send completed
            // If we have more pipeline slots, send more requests
            const policy = @import("peer_policy.zig");
            policy.tryFillPipeline(self, slot) catch {
                self.removePeer(slot);
            };
        },
        else => {},
    }
}

pub fn handleRecv(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
    const peer = &self.peers[slot];

    // Guard: if the peer slot was already freed (stale CQE from a
    // previously-closed fd), ignore the completion entirely.
    if (peer.state == .free) return;

    if (cqe.res <= 0) {
        self.removePeer(slot);
        return;
    }
    const n: usize = @intCast(cqe.res);
    const tc_recv = self.getTorrentContext(peer.torrent_id) orelse {
        self.removePeer(slot);
        return;
    };

    // MSE/PE (BEP 6): decrypt newly received bytes in-place when crypto is active.
    // This happens transparently before any protocol parsing.
    if (peer.crypto.isEncrypted()) {
        switch (peer.state) {
            .handshake_recv, .inbound_handshake_recv => {
                const start = peer.handshake_offset;
                peer.crypto.decryptBuf(peer.handshake_buf[start .. start + n]);
            },
            .active_recv_header => {
                const start = peer.header_offset;
                peer.crypto.decryptBuf(peer.header_buf[start .. start + n]);
            },
            .active_recv_body => {
                if (peer.body_buf) |buf| {
                    const start = peer.body_offset;
                    peer.crypto.decryptBuf(buf[start .. start + n]);
                }
            },
            else => {},
        }
    }

    switch (peer.state) {
        .handshake_recv => {
            peer.handshake_offset += n;
            if (peer.handshake_offset < 68) {
                protocol.submitHandshakeRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Validate handshake
            if (!std.mem.eql(u8, peer.handshake_buf[28..48], tc_recv.info_hash[0..])) {
                self.removePeer(slot);
                return;
            }
            // BEP 10: check if peer supports extensions
            const recv_reserved = peer.handshake_buf[20..28];
            peer.extensions_supported = ext.supportsExtensions(recv_reserved[0..8].*);

            if (peer.extensions_supported) {
                // Send extension handshake first, then interested on send completion
                protocol.submitExtensionHandshake(self, slot) catch {
                    // Extension handshake failed; fall through to send interested anyway
                    protocol.sendInterestedAndGoActive(self, slot);
                    return;
                };
                peer.state = .extension_handshake_send;
                // Don't start header recv yet -- sendInterestedAndGoActive will do it
                // after the extension handshake send completes.
            } else {
                protocol.sendInterestedAndGoActive(self, slot);
            }
        },
        .inbound_handshake_recv => {
            // Seed mode: we received the peer's handshake
            peer.handshake_offset += n;
            if (peer.handshake_offset < 68) {
                protocol.submitHandshakeRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Match info_hash against all registered torrents
            const inbound_hash = peer.handshake_buf[28..48];
            var resp_tc: *const @import("event_loop.zig").TorrentContext = tc_recv;
            var resp_tid: u8 = peer.torrent_id;
            var matched = false;
            for (&self.torrents, 0..) |*tslot, ti| {
                if (tslot.*) |*tc_match| {
                    if (tc_match.active and std.mem.eql(u8, &tc_match.info_hash, inbound_hash)) {
                        resp_tc = tc_match;
                        resp_tid = @intCast(ti);
                        matched = true;
                        break;
                    }
                }
            }
            if (!matched) {
                self.removePeer(slot);
                return;
            }
            peer.torrent_id = resp_tid;
            // BEP 10: check if inbound peer supports extensions
            const inbound_reserved = peer.handshake_buf[20..28];
            peer.extensions_supported = ext.supportsExtensions(inbound_reserved[0..8].*);
            // Send our handshake back
            peer.state = .inbound_handshake_send;
            var buf: [68]u8 = undefined;
            buf[0] = pw.protocol_length;
            @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
            @memset(buf[20..28], 0);
            // BEP 10: advertise extension protocol support
            buf[20 + ext.reserved_byte] |= ext.reserved_mask;
            @memcpy(buf[28..48], &resp_tc.info_hash);
            @memcpy(buf[48..68], &resp_tc.peer_id);
            @memcpy(peer.handshake_buf[0..68], &buf);
            // MSE/PE: encrypt handshake before sending
            peer.crypto.encryptBuf(peer.handshake_buf[0..68]);
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
                protocol.submitHeaderRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Parse message length
            const msg_len = std.mem.readInt(u32, &peer.header_buf, .big);
            if (msg_len == 0) {
                // Keep-alive -- peer is alive
                peer.last_activity = std.time.timestamp();
                peer.header_offset = 0;
                protocol.submitHeaderRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            if (msg_len > pw.max_message_length) {
                self.removePeer(slot);
                return;
            }
            // Use inline buffer for small messages, heap for large ones
            if (msg_len <= peer.small_body_buf.len) {
                peer.body_buf = peer.small_body_buf[0..msg_len];
                peer.body_is_heap = false;
            } else {
                peer.body_buf = self.allocator.alloc(u8, msg_len) catch {
                    self.removePeer(slot);
                    return;
                };
                peer.body_is_heap = true;
            }
            peer.body_offset = 0;
            peer.body_expected = msg_len;
            peer.state = .active_recv_body;
            protocol.submitBodyRecv(self, slot) catch {
                self.removePeer(slot);
            };
        },
        .active_recv_body => {
            peer.body_offset += n;
            if (peer.body_offset < peer.body_expected) {
                protocol.submitBodyRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Full message received -- process it
            protocol.processMessage(self, slot);
            // Free body and read next header
            if (peer.body_is_heap) {
                if (peer.body_buf) |buf| self.allocator.free(buf);
            }
            peer.body_buf = null;
            peer.body_is_heap = false;
            peer.state = .active_recv_header;
            peer.header_offset = 0;
            protocol.submitHeaderRecv(self, slot) catch {
                self.removePeer(slot);
            };
        },
        else => {},
    }
}

pub fn handleDiskWrite(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
    _ = slot;
    const op = decodeUserData(cqe.user_data);
    const piece_index: u32 = @intCast(op.context & 0xFFFFFFFF);
    const write_torrent_id: u8 = @intCast((op.context >> 32) & 0xFF);

    const PendingWriteKey = EventLoop.PendingWriteKey;

    // Find the pending write for this piece and decrement spans_remaining
    const key = PendingWriteKey{ .piece_index = piece_index, .torrent_id = write_torrent_id };
    if (self.pending_writes.getPtr(key)) |pending_w| {
        // Check for write errors (disk full, I/O error, etc.)
        if (cqe.res < 0) {
            log.err("disk write failed for piece {d} torrent {d}: errno={d}", .{
                piece_index, write_torrent_id, -cqe.res,
            });
            // Release the piece back so it can be re-downloaded
            if (self.getTorrentContext(pending_w.torrent_id)) |tc| {
                if (tc.piece_tracker) |pt| pt.releasePiece(piece_index);
            }
            self.allocator.free(pending_w.buf);
            _ = self.pending_writes.remove(key);
            return;
        }

        pending_w.spans_remaining -= 1;
        if (pending_w.spans_remaining == 0) {
            // All submitted spans completed. If any submit failed earlier,
            // release the piece so it can be downloaded again.
            if (self.getTorrentContext(pending_w.torrent_id)) |tc| {
                if (pending_w.write_failed) {
                    if (tc.piece_tracker) |pt| pt.releasePiece(piece_index);
                } else if (tc.session) |sess| {
                    if (piece_index < sess.pieceCount()) {
                        const piece_length = sess.layout.pieceSize(piece_index) catch 0;
                        if (tc.piece_tracker) |pt| _ = pt.completePiece(piece_index, piece_length);
                    }
                }
            }
            self.allocator.free(pending_w.buf);
            _ = self.pending_writes.remove(key);
        }
    }
}

test "handleDiskWrite releases piece when any submit failed" {
    const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
    const Bitfield = @import("../bitfield.zig").Bitfield;

    const peers = try std.testing.allocator.alloc(Peer, 1);
    defer std.testing.allocator.free(peers);
    @memset(peers, Peer{});

    var el: EventLoop = .{
        .ring = undefined,
        .allocator = std.testing.allocator,
        .peers = peers,
        .pending_writes = .empty,
        .pending_sends = std.ArrayList(EventLoop.PendingSend).empty,
        .pending_reads = std.ArrayList(EventLoop.PendingPieceRead).empty,
        .queued_responses = std.ArrayList(EventLoop.QueuedBlockResponse).empty,
        .idle_peers = std.ArrayList(u16).empty,
    };
    defer {
        el.pending_writes.deinit(std.testing.allocator);
        el.pending_sends.deinit(std.testing.allocator);
        el.pending_reads.deinit(std.testing.allocator);
        el.queued_responses.deinit(std.testing.allocator);
        el.idle_peers.deinit(std.testing.allocator);
    }

    var initial_complete = try Bitfield.init(std.testing.allocator, 1);
    defer initial_complete.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 1, 16, 16, &initial_complete, 0);
    defer tracker.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 0), tracker.claimPiece(null));

    const empty_fds = [_]posix.fd_t{};
    el.torrents[0] = .{
        .piece_tracker = &tracker,
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    };
    el.torrent_count = 1;

    const buf = try std.testing.allocator.alloc(u8, 16);
    try el.pending_writes.put(std.testing.allocator, .{
        .piece_index = 0,
        .torrent_id = 0,
    }, .{
        .piece_index = 0,
        .torrent_id = 0,
        .slot = 0,
        .buf = buf,
        .spans_remaining = 1,
        .write_failed = true,
    });

    var cqe = std.mem.zeroes(linux.io_uring_cqe);
    cqe.user_data = encodeUserData(.{
        .slot = 0,
        .op_type = .disk_write,
        .context = 0,
    });
    cqe.res = 16;

    handleDiskWrite(&el, 0, cqe);

    try std.testing.expectEqual(@as(usize, 0), el.pending_writes.count());
    try std.testing.expectEqual(@as(u32, 0), tracker.completedCount());
    try std.testing.expectEqual(@as(?u32, 0), tracker.claimPiece(null));
}

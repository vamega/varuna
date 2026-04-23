const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.event_loop);
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const mse = @import("../crypto/mse.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const Peer = @import("event_loop.zig").Peer;
const PeerState = @import("event_loop.zig").PeerState;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const decodeUserData = @import("event_loop.zig").decodeUserData;
const protocol = @import("protocol.zig");
const socket_util = @import("../net/socket.zig");
const BanList = @import("../net/ban_list.zig").BanList;

// ── CQE dispatch handlers ──────────────────────────────

pub fn handleAccept(self: *EventLoop, cqe: linux.io_uring_cqe) void {
    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
    if (cqe.res < 0) {
        const e = cqe.err();
        // ECANCELED is expected when stopTcpListener cancels the pending accept.
        if (e != .CANCELED) {
            log.warn("accept failed: errno={d}", .{-cqe.res});
        }
        if (!more) self.submitAccept() catch |err| {
            log.err("re-submit accept after failure: {s}", .{@errorName(err)});
        };
        return;
    }
    const new_fd: posix.fd_t = @intCast(cqe.res);

    // Resolve the peer's remote address up-front. Every downstream code path
    // that touches peer.address (ban checks, PEX duplicate-connection filter,
    // smart ban, /sync/torrentPeers) assumes it's a valid std.net.Address —
    // if we leave it `undefined` we get stack-garbage behaviour: silent
    // false-match on addressEql (killing good connections as "duplicates")
    // and panics in getPort on unexpected families. Bail on peers we can't
    // identify rather than carry an unknown address forward.
    var peer_addr_storage: posix.sockaddr.storage = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const getpeername_rc = std.os.linux.getpeername(new_fd, @ptrCast(&peer_addr_storage), &addr_len);
    if (@as(i32, @bitCast(@as(u32, @truncate(getpeername_rc)))) < 0) {
        log.debug("rejected inbound: getpeername failed", .{});
        posix.close(new_fd);
        if (!more) self.submitAccept() catch {};
        return;
    }
    const peer_address = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(&peer_addr_storage)).* };

    // Check ban list using the resolved address.
    if (self.ban_list) |bl| {
        if (bl.isBanned(peer_address)) {
            log.debug("rejected banned inbound peer", .{});
            posix.close(new_fd);
            if (!more) self.submitAccept() catch {};
            return;
        }
    }

    // Reject inbound connections during graceful shutdown drain
    if (self.draining) {
        log.debug("rejected inbound connection: shutting down", .{});
        posix.close(new_fd);
        if (!more) self.submitAccept() catch {};
        return;
    }

    // Reject inbound TCP if transport disposition disables it
    if (!self.transport_disposition.incoming_tcp) {
        log.debug("rejected inbound TCP connection: incoming_tcp disabled", .{});
        posix.close(new_fd);
        if (!more) self.submitAccept() catch {};
        return;
    }

    // Enforce global connection limit on inbound connections
    if (self.peer_count >= self.max_connections) {
        log.warn("rejecting inbound connection: global limit reached ({d}/{d})", .{
            self.peer_count,
            self.max_connections,
        });
        posix.close(new_fd);
        if (!more) self.submitAccept() catch |err| {
            log.err("re-submit accept after connection limit: {s}", .{@errorName(err)});
        };
        return;
    }

    // Allocate a peer slot for the inbound connection
    const slot = self.allocSlot() orelse {
        posix.close(new_fd);
        if (!more) self.submitAccept() catch |err| {
            log.err("re-submit accept after slot exhaustion: {s}", .{@errorName(err)});
        };
        return;
    };

    const peer = &self.peers[slot];
    peer.* = Peer{
        .fd = new_fd,
        .state = .inbound_handshake_recv,
        .mode = .inbound,
        .address = peer_address,
    };
    peer.handshake_offset = 0;
    self.peer_count += 1;

    socket_util.configurePeerSocket(new_fd);

    self.markActivePeer(slot);

    // Start receiving the peer's handshake
    protocol.submitHandshakeRecv(self, slot) catch {
        self.removePeer(slot);
    };

    // Re-submit accept only if the multishot stream ended.
    if (!more) self.submitAccept() catch |err| {
        log.err("re-submit accept: {s}", .{@errorName(err)});
    };
}

/// Handle completion of async socket creation (IORING_OP_SOCKET).
/// Configures the new fd (TCP options, bind config) and chains the
/// CONNECT SQE to initiate the peer connection.
pub fn handleSocketCreated(self: *EventLoop, slot: u16, cqe: linux.io_uring_cqe) void {
    const peer = &self.peers[slot];
    if (peer.state == .free) {
        // Slot was freed while socket creation was pending — close the fd.
        if (cqe.res >= 0) posix.close(@intCast(cqe.res));
        return;
    }

    // Guard: if the peer is not in connecting state, this is a stale socket
    // CQE from a slot that was reused while a previous socket creation was
    // in-flight. Close the new fd and ignore the CQE.
    if (peer.state != .connecting) {
        log.debug("slot {d}: ignoring stale socket CQE (state={s})", .{
            slot, @tagName(peer.state),
        });
        if (cqe.res >= 0) posix.close(@intCast(cqe.res));
        return;
    }

    if (cqe.res < 0) {
        log.warn("async socket creation failed for slot {d}: errno={d}", .{ slot, -cqe.res });
        self.removePeer(slot);
        return;
    }

    const fd: posix.fd_t = @intCast(cqe.res);
    peer.fd = fd;

    socket_util.configurePeerSocket(fd);
    socket_util.applyBindConfig(fd, self.bind_device, self.bind_address, 0) catch {
        self.removePeer(slot);
        return;
    };

    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_connect, .context = 0 });
    _ = self.ring.connect(ud, fd, &peer.address.any, peer.address.getOsSockLen()) catch {
        self.removePeer(slot);
        return;
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
    peer.last_activity = std.time.timestamp();

    // Guard: if the peer is not in connecting state, this is a stale connect CQE
    // from a slot that was reused while a previous connect was still in-flight.
    // On localhost, TCP connects complete near-instantly and the CQE may arrive
    // after the slot has been freed and reallocated for a new connection. Ignoring
    // the stale CQE prevents corrupting the new connection's MSE handshake state.
    if (peer.state != .connecting) {
        log.debug("slot {d}: ignoring stale connect CQE (state={s})", .{
            slot, @tagName(peer.state),
        });
        return;
    }

    // Determine if we should initiate MSE handshake
    const should_mse = shouldInitiateMse(self, peer);
    if (should_mse) {
        startMseInitiator(self, slot) catch {
            self.removePeer(slot);
        };
        return;
    }

    // No MSE -- go directly to BT handshake
    sendBtHandshake(self, slot);
}

/// Start the async MSE initiator handshake for an outbound peer.
fn startMseInitiator(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse return error.TorrentNotFound;

    // Allocate MSE initiator state
    const mi = try self.allocator.create(mse.MseInitiatorHandshake);
    mi.* = mse.MseInitiatorHandshake.init(tc.info_hash, self.encryption_mode);
    peer.mse_initiator = mi;

    // Get first action (send DH key)
    const action = mi.start();
    switch (action) {
        .send => |data| {
            peer.state = .mse_handshake_send;
            peer.mse_send_remaining = data;
            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
            _ = self.ring.send(ud, peer.fd, data, 0) catch {
                return error.SubmitFailed;
            };
            peer.send_pending = true;
        },
        else => return error.UnexpectedAction,
    }
}

/// Determine whether to initiate MSE on an outbound connection.
fn shouldInitiateMse(self: *EventLoop, peer: *const Peer) bool {
    // Never MSE if mode is disabled
    if (self.encryption_mode == .disabled) return false;
    // Don't retry MSE if this peer previously rejected it
    if (peer.mse_rejected) return false;
    // Don't MSE if we're in fallback mode (reconnecting without MSE)
    if (peer.mse_fallback) return false;
    // In "enabled" mode, don't initiate MSE -- only accept it
    if (self.encryption_mode == .enabled) return false;
    // "forced" and "preferred" modes: initiate MSE
    return true;
}

/// Send a standard BitTorrent protocol handshake (no MSE).
fn sendBtHandshake(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse {
        self.removePeer(slot);
        return;
    };
    peer.state = .handshake_send;

    var buf: [68]u8 = undefined;
    buf[0] = pw.protocol_length;
    @memcpy(buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
    @memset(buf[20..28], 0);
    // BEP 10: advertise extension protocol support
    buf[20 + ext.reserved_byte] |= ext.reserved_mask;
    // BEP 52: advertise v2 protocol support for v2/hybrid torrents
    if (tc.info_hash_v2 != null) {
        buf[20 + pw.v2_reserved_byte] |= pw.v2_reserved_mask;
    }
    @memcpy(buf[28..48], tc.info_hash[0..]);
    @memcpy(buf[48..68], tc.peer_id[0..]);
    @memcpy(peer.handshake_buf[0..68], &buf);
    // MSE/PE: encrypt handshake before sending (if MSE was negotiated)
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
        // Guard: if the peer is reconnecting (connecting state), this is a stale
        // send CQE from the previous connection's fd. Ignore it.
        if (peer.state == .connecting) {
            log.debug("slot {d}: ignoring stale send error during reconnect", .{slot});
            return;
        }
        // MSE fallback: if send failed during MSE handshake and mode is "preferred",
        // try reconnecting without MSE
        if (peer.state == .mse_handshake_send and self.encryption_mode == .preferred and !peer.mse_fallback) {
            log.debug("slot {d}: MSE send failed (res={}), attempting plaintext fallback", .{ slot, cqe.res });
            attemptMseFallback(self, slot);
            return;
        }
        self.removePeer(slot);
        return;
    }

    // Check if this was a tracked send buffer (context != 0, send_id encoded)
    if (op.context != 0) {
        const bytes_sent: usize = @intCast(cqe.res);
        switch (self.handlePartialSend(slot, send_id, bytes_sent)) {
            .resubmitted => {},
            .complete => self.freeOnePendingSend(slot, send_id),
            .failed => {
                self.freeOnePendingSend(slot, send_id);
                self.removePeer(slot);
                return;
            },
        }
    }

    peer.send_pending = self.hasPendingSendForSlot(slot);

    switch (peer.state) {
        .mse_handshake_send => {
            // MSE initiator: handle partial send before advancing state machine
            const bytes_sent: usize = @intCast(cqe.res);
            peer.mse_send_remaining = peer.mse_send_remaining[bytes_sent..];
            if (peer.mse_send_remaining.len > 0) {
                // Partial send -- resubmit remaining bytes without advancing state machine
                const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
                _ = self.ring.send(ud, peer.fd, peer.mse_send_remaining, 0) catch {
                    self.removePeer(slot);
                };
                return;
            }
            if (peer.mse_initiator) |mi| {
                const action = mi.feedSend();
                executeMseAction(self, slot, action, true);
            } else {
                self.removePeer(slot);
            }
        },
        .mse_resp_send => {
            // MSE responder: handle partial send before advancing state machine
            const bytes_sent: usize = @intCast(cqe.res);
            peer.mse_send_remaining = peer.mse_send_remaining[bytes_sent..];
            if (peer.mse_send_remaining.len > 0) {
                // Partial send -- resubmit remaining bytes without advancing state machine
                const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
                _ = self.ring.send(ud, peer.fd, peer.mse_send_remaining, 0) catch {
                    self.removePeer(slot);
                };
                return;
            }
            if (peer.mse_responder) |mr| {
                const action = mr.feedSend();
                executeMseAction(self, slot, action, false);
            } else {
                self.removePeer(slot);
            }
        },
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
        // Guard: if the peer is reconnecting (connecting state), this is a stale
        // recv CQE from the previous connection's fd. Ignore it.
        if (peer.state == .connecting) {
            log.debug("slot {d}: ignoring stale recv error during reconnect", .{slot});
            return;
        }
        // MSE fallback: if MSE handshake recv failed and mode is "preferred",
        // reconnect without MSE
        if (peer.state == .mse_handshake_recv or peer.state == .mse_resp_recv) {
            if (self.encryption_mode == .preferred and !peer.mse_fallback) {
                log.debug("slot {d}: MSE recv failed (state={s} res={}), attempting plaintext fallback", .{ slot, @tagName(peer.state), cqe.res });
                attemptMseFallback(self, slot);
                return;
            }
        }
        self.removePeer(slot);
        return;
    }
    const n: usize = @intCast(cqe.res);

    // MSE handshake states: the async state machine manages its own
    // encryption, so handle them before the crypto.decryptBuf block.
    switch (peer.state) {
        .mse_handshake_recv => {
            if (peer.mse_initiator) |mi| {
                const action = mi.feedRecv(n);
                executeMseAction(self, slot, action, true);
            } else {
                self.removePeer(slot);
            }
            return;
        },
        .mse_resp_recv => {
            if (peer.mse_responder) |mr| {
                const action = mr.feedRecv(n);
                executeMseAction(self, slot, action, false);
            } else {
                self.removePeer(slot);
            }
            return;
        },
        else => {},
    }

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
            const tc_recv = self.getTorrentContext(peer.torrent_id) orelse {
                self.removePeer(slot);
                return;
            };
            peer.handshake_offset += n;
            if (peer.handshake_offset < 68) {
                protocol.submitHandshakeRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Validate handshake: accept v1 or v2 (BEP 52) info-hash
            const recv_hash = peer.handshake_buf[28..48];
            const v1_match = std.mem.eql(u8, recv_hash, tc_recv.info_hash[0..]);
            const v2_match = if (tc_recv.info_hash_v2) |v2| std.mem.eql(u8, recv_hash, v2[0..]) else false;
            if (!v1_match and !v2_match) {
                self.removePeer(slot);
                return;
            }
            // Store remote peer ID for client identification
            @memcpy(&peer.remote_peer_id, peer.handshake_buf[48..68]);
            peer.has_peer_id = true;
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
            // MSE detection: on the very first bytes of an inbound connection,
            // check if this looks like an MSE handshake (not BT protocol).
            if (peer.handshake_offset == 0 and n > 0) {
                if (detectAndHandleInboundMse(self, slot, peer.handshake_buf[0], n)) {
                    // MSE responder started -- it took ownership of n bytes
                    return;
                }
                // If encryption is forced but first byte looks like BT, reject
                if (self.encryption_mode == .forced and peer.handshake_buf[0] == pw.protocol_length) {
                    log.debug("slot {d}: rejecting plaintext inbound (encryption=forced)", .{slot});
                    self.removePeer(slot);
                    return;
                }
            }
            // Seed mode: we received the peer's handshake
            peer.handshake_offset += n;
            if (peer.handshake_offset < 68) {
                protocol.submitHandshakeRecv(self, slot) catch {
                    self.removePeer(slot);
                };
                return;
            }
            // Match info_hash against all registered torrents.
            // BEP 52: for hybrid torrents, also match on the truncated v2 info-hash
            // since v2-capable peers may use the SHA-256 info-hash in the handshake.
            const inbound_hash = peer.handshake_buf[28..48];
            const resp_tid = self.findTorrentIdByInfoHash(inbound_hash) orelse {
                self.removePeer(slot);
                return;
            };
            const resp_tc = self.getTorrentContext(resp_tid) orelse {
                self.removePeer(slot);
                return;
            };
            peer.torrent_id = resp_tid;
            self.attachPeerToTorrent(resp_tid, slot);
            // Store remote peer ID for client identification
            @memcpy(&peer.remote_peer_id, peer.handshake_buf[48..68]);
            peer.has_peer_id = true;
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
            // BEP 52: advertise v2 protocol support for v2/hybrid torrents
            if (resp_tc.info_hash_v2 != null) {
                buf[20 + pw.v2_reserved_byte] |= pw.v2_reserved_mask;
            }
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
    const write_id: u32 = @truncate(op.context);

    if (self.getPendingWriteById(write_id)) |pending_w| {
        const piece_index = pending_w.piece_index;
        // Check for write errors (disk full, I/O error, etc.)
        if (cqe.res < 0) {
            log.err("disk write failed for piece {d} torrent {d}: errno={d}", .{
                piece_index, pending_w.torrent_id, -cqe.res,
            });
            // Mark as failed but do NOT free the buffer yet -- other spans
            // may still be in-flight in io_uring and reference it.
            // The buffer is freed when spans_remaining reaches 0.
            pending_w.write_failed = true;
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
            _ = self.removePendingWriteById(write_id);
        }
    }
}

// ── MSE async handshake helpers ──────────────────────────

/// Execute an MseAction returned by the async state machine.
/// `is_initiator` controls which state (mse_handshake_* vs mse_resp_*) to use.
fn executeMseAction(self: *EventLoop, slot: u16, action: mse.MseAction, is_initiator: bool) void {
    const peer = &self.peers[slot];
    switch (action) {
        .send => |data| {
            const state: PeerState = if (is_initiator) .mse_handshake_send else .mse_resp_send;
            peer.state = state;
            peer.mse_send_remaining = data;
            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
            _ = self.ring.send(ud, peer.fd, data, 0) catch {
                handleMseFailure(self, slot, is_initiator);
                return;
            };
            peer.send_pending = true;
        },
        .recv => |buf| {
            const state: PeerState = if (is_initiator) .mse_handshake_recv else .mse_resp_recv;
            peer.state = state;
            const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
            _ = self.ring.recv(ud, peer.fd, .{ .buffer = buf }, 0) catch {
                handleMseFailure(self, slot, is_initiator);
                return;
            };
        },
        .complete => {
            // MSE handshake succeeded -- extract crypto state and proceed to BT handshake
            if (is_initiator) {
                if (peer.mse_initiator) |mi| {
                    peer.crypto = mi.result();
                    self.allocator.destroy(mi);
                    peer.mse_initiator = null;
                    log.info("slot {d}: MSE handshake complete (initiator, method={s})", .{
                        slot,
                        if (peer.crypto.crypto_method == mse.crypto_rc4) "RC4" else "plaintext",
                    });
                    // Proceed to BT handshake
                    sendBtHandshake(self, slot);
                } else {
                    self.removePeer(slot);
                }
            } else {
                if (peer.mse_responder) |mr| {
                    peer.crypto = mr.result();
                    // Set the torrent_id based on matched info-hash
                    if (mr.matchedInfoHash()) |hash| {
                        if (self.findTorrentIdByInfoHash(&hash)) |tid| {
                            peer.torrent_id = tid;
                            self.attachPeerToTorrent(tid, slot);
                        }
                    }
                    self.allocator.destroy(mr);
                    peer.mse_responder = null;
                    log.info("slot {d}: MSE handshake complete (responder, method={s})", .{
                        slot,
                        if (peer.crypto.crypto_method == mse.crypto_rc4) "RC4" else "plaintext",
                    });
                    // Now receive the BT handshake (which follows MSE)
                    peer.state = .inbound_handshake_recv;
                    peer.handshake_offset = 0;
                    protocol.submitHandshakeRecv(self, slot) catch {
                        self.removePeer(slot);
                    };
                } else {
                    self.removePeer(slot);
                }
            }
        },
        .failed => |err| {
            log.debug("slot {d}: MSE handshake failed: {s}", .{
                slot, @tagName(err),
            });
            handleMseFailure(self, slot, is_initiator);
        },
    }
}

/// Handle MSE failure -- either fallback to plaintext or disconnect.
fn handleMseFailure(self: *EventLoop, slot: u16, is_initiator: bool) void {
    const peer = &self.peers[slot];

    // Clean up MSE state
    if (is_initiator) {
        if (peer.mse_initiator) |mi| {
            self.allocator.destroy(mi);
            peer.mse_initiator = null;
        }
    } else {
        if (peer.mse_responder) |mr| {
            self.allocator.destroy(mr);
            peer.mse_responder = null;
        }
    }

    // If mode is "preferred" and we're the initiator, try reconnecting without MSE
    if (is_initiator and self.encryption_mode == .preferred and !peer.mse_fallback) {
        attemptMseFallback(self, slot);
        return;
    }

    // If mode is "enabled" and we're the responder, fall back to treating
    // the data as a plaintext BT handshake (handled in handleAccept)
    if (!is_initiator and self.encryption_mode != .forced) {
        // The connection is already established -- just switch to inbound BT handshake.
        // Note: we already consumed some bytes during MSE scanning so we can't easily
        // re-parse them. Disconnect and let the peer reconnect.
        self.removePeer(slot);
        return;
    }

    self.removePeer(slot);
}

/// Attempt to reconnect to a peer without MSE (plaintext fallback).
fn attemptMseFallback(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const address = peer.address;
    const torrent_id = peer.torrent_id;

    log.info("slot {d}: MSE failed, attempting plaintext fallback", .{slot});

    // Mark that this peer rejected MSE so we don't retry
    // We need to remember this across the reconnect
    peer.mse_rejected = true;

    // Close the current connection
    if (peer.fd >= 0) {
        posix.close(peer.fd);
        peer.fd = -1;
    }
    // Clean up MSE state
    if (peer.mse_initiator) |mi| {
        self.allocator.destroy(mi);
        peer.mse_initiator = null;
    }
    if (peer.mse_responder) |mr| {
        self.allocator.destroy(mr);
        peer.mse_responder = null;
    }

    // Reset peer state for reconnect
    peer.state = .connecting;
    peer.mse_fallback = true;
    peer.crypto = mse.PeerCrypto.plaintext;
    peer.handshake_offset = 0;

    // Submit async socket creation — handleSocketCreated will configure
    // the fd and chain the CONNECT SQE.
    const family = address.any.family;
    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_socket, .context = 0 });
    _ = self.ring.socket(ud, family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP, 0) catch {
        self.removePeer(slot);
        return;
    };
    if (self.half_open_count < self.max_half_open) {
        self.half_open_count += 1;
    }
    peer.torrent_id = torrent_id;
}

/// Start an inbound MSE responder handshake for a peer that sent
/// non-BT-protocol bytes.
/// `bytes_received` is the number of bytes already in `peer.handshake_buf`
/// from the initial inbound recv (may be more than 1).
fn startMseResponder(self: *EventLoop, slot: u16, bytes_received: usize) void {
    const peer = &self.peers[slot];

    if (self.mse_req2_to_hash.count() == 0) {
        self.removePeer(slot);
        return;
    }

    // Allocate responder state
    const mr = self.allocator.create(mse.MseResponderHandshake) catch {
        self.removePeer(slot);
        return;
    };
    mr.* = mse.MseResponderHandshake.initWithLookup(&self.mse_req2_to_hash, self.encryption_mode);
    peer.mse_responder = mr;

    // Copy all bytes already received into the DH key buffer.
    // The initial inbound recv is for 68 bytes (BT handshake size), so we may
    // have received up to 68 bytes of the initiator's DH key (96 bytes total).
    const copy_len = @min(bytes_received, mse.dh_key_size);
    @memcpy(mr.peer_public_key[0..copy_len], peer.handshake_buf[0..copy_len]);
    mr.recv_offset = copy_len;

    if (mr.recv_offset < mse.dh_key_size) {
        peer.state = .mse_resp_recv;
        const recv_buf = mr.peer_public_key[mr.recv_offset..];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_recv, .context = 0 });
        _ = self.ring.recv(ud, peer.fd, .{ .buffer = recv_buf }, 0) catch {
            self.removePeer(slot);
            return;
        };
    } else {
        // Already have the full DH key -- feed it directly.
        const action = mr.feedRecv(mse.dh_key_size);
        executeMseAction(self, slot, action, false);
    }
}

/// Detect whether the first received byte on an inbound connection looks
/// like an MSE DH key exchange (not a BT protocol handshake).
/// Called from handleRecv when we get the first bytes on an inbound peer.
/// `n` is the total number of bytes already received into `peer.handshake_buf`.
pub fn detectAndHandleInboundMse(self: *EventLoop, slot: u16, first_byte: u8, n: usize) bool {
    // If encryption is disabled, never try MSE detection
    if (self.encryption_mode == .disabled) return false;

    // BT handshake starts with 0x13 (protocol string length = 19)
    if (first_byte == pw.protocol_length) return false;

    // If encryption mode is not "forced", and first byte is 0x13,
    // treat as plaintext. For non-0x13 first bytes, try MSE.
    // In "forced" mode, all inbound connections must be MSE.
    if (self.encryption_mode == .forced or mse.looksLikeMse(&[_]u8{first_byte})) {
        startMseResponder(self, slot, n);
        return true;
    }

    return false;
}

test "handleDiskWrite releases piece when any submit failed" {
    const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
    const Bitfield = @import("../bitfield.zig").Bitfield;
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(std.testing.allocator, 1);
    defer initial_complete.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 1, 16, 16, &initial_complete, 0);
    defer tracker.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 0), tracker.claimPiece(null));

    const empty_fds = [_]posix.fd_t{};
    _ = try el.addTorrentContext(.{
        .piece_tracker = &tracker,
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    });

    const buf = try std.testing.allocator.alloc(u8, 16);
    const write_id = try el.createPendingWrite(.{
        .piece_index = 0,
        .torrent_id = 0,
    }, .{
        .write_id = 0,
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
        .context = write_id,
    });
    cqe.res = 16;

    handleDiskWrite(&el, 0, cqe);

    try std.testing.expectEqual(@as(usize, 0), el.pending_writes.count());
    try std.testing.expectEqual(@as(u32, 0), tracker.completedCount());
    try std.testing.expectEqual(@as(?u32, 0), tracker.claimPiece(null));
}

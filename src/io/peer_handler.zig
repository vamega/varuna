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
const protocol = @import("protocol.zig");
const io_interface = @import("io_interface.zig");
const peer_policy = @import("peer_policy.zig");
const socket_util = @import("../net/socket.zig");
const BanList = @import("../net/ban_list.zig").BanList;

// ── Generic callback shape ────────────────────────────────
//
// `EventLoop` is parameterised over a comptime `IO: type` (see
// `EventLoopOf` in event_loop.zig). Each callback below is exposed via a
// factory `xCompleteFor(comptime EL: type)` that returns a concrete
// `io_interface.Callback` baked against that EL instantiation. The
// factory's inner cast `*EL = @ptrCast(userdata)` varies per type;
// everything else stays shared. Helper functions take `self: anytype`
// so the compiler infers the EL at the callsite.

// ── CQE dispatch handlers ──────────────────────────────

/// Factory for the multishot-accept callback bound to
/// `EventLoop.accept_completion`. Returns `.rearm` so the listener stays
/// open across CQEs.
pub fn peerAcceptCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));

            const accepted = switch (result) {
                .accept => |r| r catch |err| {
                    // ECANCELED is expected when stopTcpListener cancels
                    // the pending accept; other errors are worth surfacing.
                    if (err != error.OperationCanceled) {
                        log.warn("accept failed: {s}", .{@errorName(err)});
                    }
                    return .rearm;
                },
                else => return .disarm,
            };

            handleAccepted(self, accepted.fd);
            return .rearm;
        }
    }.cb;
}

/// Apply the policy/ban/limit checks against a freshly accepted fd and,
/// if it's keepable, install it as an inbound peer slot.
fn handleAccepted(self: anytype, new_fd: posix.fd_t) void {
    // Resolve the peer's remote address up-front. Every downstream code path
    // that touches peer.address (ban checks, PEX duplicate-connection filter
    // in protocol.zig:isPeerAlreadyConnected, smart ban, /sync/torrentPeers,
    // session_manager.getPort) assumes it's a valid std.net.Address — if we
    // leave it `undefined` we get stack-garbage behaviour: silent false-match
    // on addressEql (killing good connections as "duplicates") and an
    // `unreachable` panic in getPort on unexpected sa_family values.
    // Bail on peers we can't identify rather than carry an unknown address.
    var peer_addr_storage: posix.sockaddr.storage = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const getpeername_rc = std.os.linux.getpeername(new_fd, @ptrCast(&peer_addr_storage), &addr_len);
    if (@as(i32, @bitCast(@as(u32, @truncate(getpeername_rc)))) < 0) {
        log.debug("rejected inbound: getpeername failed", .{});
        posix.close(new_fd);
        return;
    }
    const peer_address = std.net.Address{ .any = @as(*posix.sockaddr, @ptrCast(&peer_addr_storage)).* };

    // Check ban list using the resolved address.
    if (self.ban_list) |bl| {
        if (bl.isBanned(peer_address)) {
            log.debug("rejected banned inbound peer", .{});
            posix.close(new_fd);
            return;
        }
    }

    // Reject inbound connections during graceful shutdown drain
    if (self.draining) {
        log.debug("rejected inbound connection: shutting down", .{});
        posix.close(new_fd);
        return;
    }

    // Reject inbound TCP if transport disposition disables it
    if (!self.transport_disposition.incoming_tcp) {
        log.debug("rejected inbound TCP connection: incoming_tcp disabled", .{});
        posix.close(new_fd);
        return;
    }

    // Enforce global connection limit on inbound connections
    if (self.peer_count >= self.max_connections) {
        log.warn("rejecting inbound connection: global limit reached ({d}/{d})", .{
            self.peer_count,
            self.max_connections,
        });
        posix.close(new_fd);
        return;
    }

    // Allocate a peer slot for the inbound connection
    const slot = self.allocSlot() orelse {
        posix.close(new_fd);
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
}

/// Factory: callback bound to `Peer.connect_completion`. Invoked when
/// async socket creation lands. Configures the new fd and chains the
/// connect on the same completion.
pub fn peerSocketCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const peer: *Peer = @fieldParentPtr("connect_completion", completion);
            const offset = @intFromPtr(peer) - @intFromPtr(self.peers.ptr);
            const slot: u16 = @intCast(offset / @sizeOf(Peer));
            handleSocketResult(self, slot, switch (result) {
                .socket => |r| if (r) |fd| @intCast(fd) else |_| -1,
                else => -1,
            });
            return .disarm;
        }
    }.cb;
}

fn handleSocketResult(self: anytype, slot: u16, res: i32) void {
    const peer = &self.peers[slot];
    if (peer.state == .free) {
        // Route through the IO contract (RealIO -> posix.close;
        // SimIO -> mark synthetic slot closed). Raw posix.close on
        // a SimIO synthetic fd panics with BADF.
        if (res >= 0) self.io.closeSocket(@intCast(res));
        return;
    }

    if (peer.state != .connecting) {
        log.debug("slot {d}: ignoring stale socket CQE (state={s})", .{
            slot, @tagName(peer.state),
        });
        if (res >= 0) self.io.closeSocket(@intCast(res));
        return;
    }

    if (res < 0) {
        log.warn("async socket creation failed for slot {d}: res={d}", .{ slot, res });
        self.removePeer(slot);
        return;
    }

    const fd: posix.fd_t = @intCast(res);
    peer.fd = fd;

    // SimIO synthetic fds aren't real kernel fds — `setsockopt` panics
    // on `BADF` (unreachable, not a returned error). Mirror the gate
    // used by `metadata_handler.connectPeer`: only configure / bind on
    // the real kernel path.
    const sim_io_mod = @import("sim_io.zig");
    const SelfTy = @TypeOf(self.*);
    const is_sim_io = comptime @hasField(SelfTy, "io") and
        @TypeOf(self.io) == sim_io_mod.SimIO;
    if (comptime !is_sim_io) {
        socket_util.configurePeerSocket(fd);
        socket_util.applyBindConfig(fd, self.bind_device, self.bind_address, 0) catch {
            self.removePeer(slot);
            return;
        };
    }

    self.io.connect(
        .{ .fd = fd, .addr = peer.address },
        &peer.connect_completion,
        self,
        peerConnectCompleteFor(@TypeOf(self.*)),
    ) catch {
        self.removePeer(slot);
        return;
    };
}

/// Factory: callback bound to `Peer.connect_completion` (after socket
/// creation chains a connect on the same completion). Translates the
/// connect result and feeds `handleConnectResult`.
pub fn peerConnectCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const peer: *Peer = @fieldParentPtr("connect_completion", completion);
            const offset = @intFromPtr(peer) - @intFromPtr(self.peers.ptr);
            const slot: u16 = @intCast(offset / @sizeOf(Peer));
            const ok = switch (result) {
                .connect => |r| if (r) |_| true else |_| false,
                else => false,
            };
            handleConnectResult(self, slot, if (ok) 0 else -1);
            return .disarm;
        }
    }.cb;
}

fn handleConnectResult(self: anytype, slot: u16, res: i32) void {
    // Connection attempt completed (success or failure) -- no longer half-open
    if (self.half_open_count > 0) self.half_open_count -= 1;

    const peer = &self.peers[slot];
    // Guard: stale CQE for an already-freed slot
    if (peer.state == .free) return;

    if (res < 0) {
        self.removePeer(slot);
        return;
    }
    peer.last_activity = self.clock.now();

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
fn startMseInitiator(self: anytype, slot: u16) !void {
    const peer = &self.peers[slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse return error.TorrentNotFound;

    // Allocate MSE initiator state
    const mi = try self.allocator.create(mse.MseInitiatorHandshake);
    mi.* = mse.MseInitiatorHandshake.init(&self.random, tc.info_hash, self.encryption_mode);
    peer.mse_initiator = mi;

    // Get first action (send DH key)
    const action = mi.start();
    switch (action) {
        .send => |data| {
            peer.state = .mse_handshake_send;
            peer.mse_send_remaining = data;
            self.io.send(
                .{ .fd = peer.fd, .buf = data },
                &peer.send_completion,
                self,
                peerSendCompleteFor(@TypeOf(self.*)),
            ) catch {
                return error.SubmitFailed;
            };
            peer.send_pending = true;
        },
        else => return error.UnexpectedAction,
    }
}

/// Determine whether to initiate MSE on an outbound connection.
fn shouldInitiateMse(self: anytype, peer: *const Peer) bool {
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
pub fn sendBtHandshake(self: anytype, slot: u16) void {
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

    self.io.send(
        .{ .fd = peer.fd, .buf = peer.handshake_buf[0..68] },
        &peer.send_completion,
        self,
        peerSendCompleteFor(@TypeOf(self.*)),
    ) catch {
        self.removePeer(slot);
        return;
    };
    peer.send_pending = true;
}

/// Factory: callback for an untracked peer send (handshake / MSE /
/// state-machine transition messages). Driven by `Peer.send_completion`.
/// Tracked sends (PendingSend) use `pendingSendCompleteFor` instead.
pub fn peerSendCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const peer: *Peer = @fieldParentPtr("send_completion", completion);
            const offset = @intFromPtr(peer) - @intFromPtr(self.peers.ptr);
            const slot: u16 = @intCast(offset / @sizeOf(Peer));
            const res: i32 = switch (result) {
                .send => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                else => -1,
            };
            handleSendResult(self, slot, 0, res);
            return .disarm;
        }
    }.cb;
}

/// Factory: callback for a tracked peer send (PendingSend with a
/// heap-owned or vectored buffer). Driven by `PendingSend.completion`.
/// Recovers the PendingSend pointer via `@fieldParentPtr` and feeds
/// `handleSendResult` with the (slot, send_id) pair.
pub fn pendingSendCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const ps: *@import("buffer_pools.zig").PendingSend = @fieldParentPtr("completion", completion);
            const slot = ps.slot;
            const send_id = ps.send_id;
            const res: i32 = switch (result) {
                .send => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                .sendmsg => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                else => -1,
            };
            handleSendResult(self, slot, send_id, res);
            return .disarm;
        }
    }.cb;
}

fn handleSendResult(self: anytype, slot: u16, send_id: u32, send_res: i32) void {
    const peer = &self.peers[slot];

    // Guard: if the peer slot was already freed (stale CQE from a
    // previously-closed fd), just free the tracked buffer if any.
    if (peer.state == .free) {
        if (send_id != 0) self.freeOnePendingSend(slot, send_id);
        return;
    }

    if (send_res <= 0) {
        // Check if this was a tracked send buffer -- free it on error.
        // Only free ONE buffer: removePeer will clean up the rest.
        if (send_id != 0) self.freeOnePendingSend(slot, send_id);
        // Guard: if the peer is reconnecting (connecting state), this is a stale
        // send CQE from the previous connection's fd. Ignore it.
        if (peer.state == .connecting) {
            log.debug("slot {d}: ignoring stale send error during reconnect", .{slot});
            return;
        }
        // MSE fallback: if send failed during MSE handshake and mode is "preferred",
        // try reconnecting without MSE
        if (peer.state == .mse_handshake_send and self.encryption_mode == .preferred and !peer.mse_fallback) {
            log.debug("slot {d}: MSE send failed (res={}), attempting plaintext fallback", .{ slot, send_res });
            attemptMseFallback(self, slot);
            return;
        }
        self.removePeer(slot);
        return;
    }

    // Tracked send (PendingSend): handle partial / complete / failed.
    if (send_id != 0) {
        if (self.findPendingSend(slot, send_id)) |ps| {
            const bytes_sent: usize = @intCast(send_res);
            switch (self.handlePartialSend(ps, bytes_sent)) {
                .resubmitted => {},
                .complete => self.freeOnePendingSend(slot, send_id),
                .failed => {
                    self.freeOnePendingSend(slot, send_id);
                    self.removePeer(slot);
                    return;
                },
            }
        }
    }

    peer.send_pending = self.hasPendingSendForSlot(slot);

    switch (peer.state) {
        .mse_handshake_send => {
            // MSE initiator: handle partial send before advancing state machine
            const bytes_sent: usize = @intCast(send_res);
            peer.mse_send_remaining = peer.mse_send_remaining[bytes_sent..];
            if (peer.mse_send_remaining.len > 0) {
                // Partial send -- resubmit remaining bytes on the same untracked
                // send_completion without advancing the state machine.
                self.io.send(
                    .{ .fd = peer.fd, .buf = peer.mse_send_remaining },
                    &peer.send_completion,
                    self,
                    peerSendCompleteFor(@TypeOf(self.*)),
                ) catch {
                    self.removePeer(slot);
                };
                peer.send_pending = true;
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
            const bytes_sent: usize = @intCast(send_res);
            peer.mse_send_remaining = peer.mse_send_remaining[bytes_sent..];
            if (peer.mse_send_remaining.len > 0) {
                self.io.send(
                    .{ .fd = peer.fd, .buf = peer.mse_send_remaining },
                    &peer.send_completion,
                    self,
                    peerSendCompleteFor(@TypeOf(self.*)),
                ) catch {
                    self.removePeer(slot);
                };
                peer.send_pending = true;
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
            // BEP 10: extension handshake sent (outbound peer). Advertise our
            // pieces (BITFIELD) before declaring interest, so the remote side
            // knows what we have. This matters when a seeder opens the
            // outbound side of a connection (e.g. via a tracker peer list):
            // without this, the remote never learns we have pieces and the
            // transfer stalls.
            protocol.sendOutboundBitfieldThenInterested(self, slot);
        },
        .outbound_bitfield_send => {
            // BITFIELD sent (outbound peer) — now send interested and go active.
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

pub fn handleRecv(self: anytype, slot: u16, cqe: linux.io_uring_cqe) void {
    handleRecvResult(self, slot, cqe.res);
}

/// Factory: callback bound to `Peer.recv_completion`. The completion's
/// address lets us recover the owning `Peer` (via @fieldParentPtr) and
/// from there the slot index in `EventLoop.peers`. `userdata` carries
/// the owning `*EL`.
pub fn peerRecvCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *EL = @ptrCast(@alignCast(userdata.?));
            const peer: *Peer = @fieldParentPtr("recv_completion", completion);
            const offset = @intFromPtr(peer) - @intFromPtr(self.peers.ptr);
            const slot: u16 = @intCast(offset / @sizeOf(Peer));

            const res: i32 = switch (result) {
                .recv => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |err|
                    errToCqeRes(err),
                else => unreachable,
            };
            handleRecvResult(self, slot, res);
            return .disarm;
        }
    }.cb;
}

/// Translate a recv error into a synthetic negative cqe.res value.
/// Matches the kernel's convention that errors are negative errnos. The
/// exact mapping is unimportant — `handleRecvResult` only checks `<= 0`.
inline fn errToCqeRes(_: anyerror) i32 {
    return -1;
}

fn handleRecvResult(self: anytype, slot: u16, recv_res: i32) void {
    const peer = &self.peers[slot];

    // Guard: if the peer slot was already freed (stale CQE from a
    // previously-closed fd), ignore the completion entirely.
    if (peer.state == .free) return;

    if (recv_res <= 0) {
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
                log.debug("slot {d}: MSE recv failed (state={s} res={}), attempting plaintext fallback", .{ slot, @tagName(peer.state), recv_res });
                attemptMseFallback(self, slot);
                return;
            }
        }
        self.removePeer(slot);
        return;
    }
    const n: usize = @intCast(recv_res);

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
                // Send extension handshake first, then bitfield/interested on send completion
                protocol.submitExtensionHandshake(self, slot) catch {
                    // Extension handshake failed; fall through to bitfield+interested
                    protocol.sendOutboundBitfieldThenInterested(self, slot);
                    return;
                };
                peer.state = .extension_handshake_send;
                // Don't start header recv yet — sendOutboundBitfieldThenInterested
                // (via the .extension_handshake_send send completion) will do it.
            } else {
                protocol.sendOutboundBitfieldThenInterested(self, slot);
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
            self.io.send(
                .{ .fd = peer.fd, .buf = peer.handshake_buf[0..68] },
                &peer.send_completion,
                self,
                peerSendCompleteFor(@TypeOf(self.*)),
            ) catch {
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
                peer.last_activity = self.clock.now();
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

/// Per-write tracking for `io.write` so the callback can find the
/// owning EventLoop + write_id. Heap-allocated; one per submitted span,
/// freed by `diskWriteCompleteFor(EL).cb`. The PendingWrite that
/// aggregates spans still lives on the EventLoop via `pending_writes`.
///
/// Generic over the EventLoop instantiation `EL` so a SimIO-driven
/// EventLoop and a RealIO-driven one each get their own DiskWriteOp
/// type with the right `el` pointer.
pub fn DiskWriteOpOf(comptime EL: type) type {
    return struct {
        completion: io_interface.Completion = .{},
        el: *EL,
        write_id: u32,
    };
}

/// Backwards-compat alias for daemon callsites that pre-date the
/// parameterisation. Resolves to `DiskWriteOpOf(EventLoop)`.
pub const DiskWriteOp = DiskWriteOpOf(EventLoop);

/// Factory: callback bound to a `DiskWriteOp.completion`. Translates
/// the result into a synthetic `cqe.res`-shaped i32, feeds the
/// existing `handleDiskWriteResult`, and frees the tracking struct.
pub fn diskWriteCompleteFor(comptime EL: type) io_interface.Callback {
    return struct {
        fn failWrite(op: *DiskWriteOpOf(EL)) void {
            const el = op.el;
            const write_id = op.write_id;
            el.allocator.destroy(op);
            handleDiskWriteResult(el, write_id, -1);
        }

        fn cb(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const op: *DiskWriteOpOf(EL) = @ptrCast(@alignCast(userdata.?));
            const submitted = switch (completion.op) {
                .write => |write_op| write_op,
                else => {
                    failWrite(op);
                    return .disarm;
                },
            };

            const written = switch (result) {
                .write => |r| r catch {
                    failWrite(op);
                    return .disarm;
                },
                else => {
                    failWrite(op);
                    return .disarm;
                },
            };

            if (written == 0) {
                failWrite(op);
                return .disarm;
            }

            if (written < submitted.buf.len) {
                op.el.io.write(
                    .{
                        .fd = submitted.fd,
                        .buf = submitted.buf[written..],
                        .offset = submitted.offset + @as(u64, @intCast(written)),
                    },
                    completion,
                    op,
                    diskWriteCompleteFor(EL),
                ) catch {
                    failWrite(op);
                    return .disarm;
                };
                return .disarm;
            }

            const res = std.math.cast(i32, written) orelse std.math.maxInt(i32);
            const el = op.el;
            const write_id = op.write_id;
            el.allocator.destroy(op);
            handleDiskWriteResult(el, write_id, res);
            return .disarm;
        }
    }.cb;
}

fn handleDiskWriteResult(self: anytype, write_id: u32, res: i32) void {
    if (self.getPendingWriteById(write_id)) |pending_w| {
        const piece_index = pending_w.piece_index;
        // Check for write errors (disk full, I/O error, etc.)
        if (res < 0) {
            log.err("disk write failed for piece {d} torrent {d}: errno={d}", .{
                piece_index, pending_w.torrent_id, -res,
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
                        if (tc.piece_tracker) |pt| {
                            const first_completion = pt.completePiece(piece_index, piece_length);
                            // Mark the torrent as having un-fsync'd writes.
                            // The pagecache holds this piece until either the
                            // periodic sync timer, completion hook, or
                            // shutdown drain submits an fsync sweep — see
                            // `EventLoop.submitTorrentSync`. Bumped only on
                            // the first completion to keep the counter aligned
                            // with distinct verified-and-persisted pieces;
                            // duplicate completions (endgame races) wrote the
                            // same data so don't add new dirty state.
                            if (first_completion) {
                                tc.dirty_writes_since_sync +|= 1;
                                // Phase 1 of the piece-hash lifecycle: free the
                                // SHA-1 hash now that the piece is verified-and-
                                // persisted. Skip duplicate completions (endgame
                                // races) since the first completion already
                                // handled the lifecycle hook.
                                peer_policy.onPieceVerifiedAndPersisted(self, pending_w.torrent_id, piece_index);
                            }
                        }
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
fn executeMseAction(self: anytype, slot: u16, action: mse.MseAction, is_initiator: bool) void {
    const peer = &self.peers[slot];
    switch (action) {
        .send => |data| {
            const state: PeerState = if (is_initiator) .mse_handshake_send else .mse_resp_send;
            peer.state = state;
            peer.mse_send_remaining = data;
            self.io.send(
                .{ .fd = peer.fd, .buf = data },
                &peer.send_completion,
                self,
                peerSendCompleteFor(@TypeOf(self.*)),
            ) catch {
                handleMseFailure(self, slot, is_initiator);
                return;
            };
            peer.send_pending = true;
        },
        .recv => |buf| {
            const state: PeerState = if (is_initiator) .mse_handshake_recv else .mse_resp_recv;
            peer.state = state;
            self.io.recv(
                .{ .fd = peer.fd, .buf = buf },
                &peer.recv_completion,
                self,
                peerRecvCompleteFor(@TypeOf(self.*)),
            ) catch {
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
fn handleMseFailure(self: anytype, slot: u16, is_initiator: bool) void {
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
fn attemptMseFallback(self: anytype, slot: u16) void {
    const peer = &self.peers[slot];
    const address = peer.address;
    const torrent_id = peer.torrent_id;

    log.info("slot {d}: MSE failed, attempting plaintext fallback", .{slot});

    // Mark that this peer rejected MSE so we don't retry
    // We need to remember this across the reconnect
    peer.mse_rejected = true;

    // Close the current connection. Route through `self.io.closeSocket`
    // so SimIO's synthetic-fd path stays sound (raw `posix.close` panics
    // with BADF — `unreachable, // Always a race condition` — on a SimIO
    // synthetic fd) and the io_uring policy stays uniform across all
    // daemon paths.
    if (peer.fd >= 0) {
        self.io.closeSocket(peer.fd);
        peer.fd = -1;
    }
    // Clean up MSE state. Safe here because attemptMseFallback is
    // only entered from the recv/send error path: the failing op's
    // CQE just fired, and the MSE state machine never has more than
    // one op in flight at a time (it alternates send / recv per
    // phase). So the kernel is no longer holding a pointer into
    // the about-to-be-freed `mi` / `mr` buffers.
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

    // Submit async socket creation — peerSocketComplete will configure
    // the fd and chain the connect.
    const family = address.any.family;
    self.io.socket(
        .{ .domain = family, .sock_type = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, .protocol = posix.IPPROTO.TCP },
        &peer.connect_completion,
        self,
        peerSocketCompleteFor(@TypeOf(self.*)),
    ) catch {
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
fn startMseResponder(self: anytype, slot: u16, bytes_received: usize) void {
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
    mr.* = mse.MseResponderHandshake.initWithLookup(&self.random, &self.mse_req2_to_hash, self.encryption_mode);
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
        self.io.recv(
            .{ .fd = peer.fd, .buf = recv_buf },
            &peer.recv_completion,
            self,
            peerRecvCompleteFor(@TypeOf(self.*)),
        ) catch {
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
pub fn detectAndHandleInboundMse(self: anytype, slot: u16, first_byte: u8, n: usize) bool {
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

    handleDiskWriteResult(&el, write_id, 16);

    try std.testing.expectEqual(@as(usize, 0), el.pending_writes.count());
    try std.testing.expectEqual(@as(u32, 0), tracker.completedCount());
    try std.testing.expectEqual(@as(?u32, 0), tracker.claimPiece(null));
}

test "diskWriteComplete resubmits short positive writes" {
    const sim_io = @import("sim_io.zig");
    const SimEventLoop = @import("event_loop.zig").EventLoopOf(sim_io.SimIO);

    const ShortWrite = struct {
        forced: bool = false,

        fn hook(sim: *sim_io.SimIO, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.forced) return;

            var idx: u32 = 0;
            while (idx < sim.pending_len) : (idx += 1) {
                switch (sim.pending[idx].completion.op) {
                    .write => |op| {
                        if (op.buf.len == 16) {
                            sim.pending[idx].result = .{ .write = @as(usize, 4) };
                            self.forced = true;
                            return;
                        }
                    },
                    else => {},
                }
            }
        }
    };

    var short_write = ShortWrite{};
    var sim = try sim_io.SimIO.init(std.testing.allocator, .{ .max_ops_per_tick = 1 });
    sim.pre_tick_hook = ShortWrite.hook;
    sim.pre_tick_ctx = &short_write;

    var el = try SimEventLoop.initBareWithIO(std.testing.allocator, sim, 0);
    defer el.deinit();

    const buf = try std.testing.allocator.alloc(u8, 16);
    @memset(buf, 0xAB);

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
    });

    const EL = @TypeOf(el);
    const wop = try std.testing.allocator.create(DiskWriteOpOf(EL));
    wop.* = .{ .el = &el, .write_id = write_id };

    try el.io.write(
        .{ .fd = 42, .buf = buf, .offset = 100 },
        &wop.completion,
        wop,
        diskWriteCompleteFor(EL),
    );

    try el.io.tick(1);

    try std.testing.expect(short_write.forced);
    try std.testing.expectEqual(@as(usize, 1), el.pending_writes.count());
    const pending_w = el.getPendingWriteById(write_id) orelse return error.MissingPendingWrite;
    try std.testing.expectEqual(@as(u32, 1), pending_w.spans_remaining);
    try std.testing.expectEqual(@as(u32, 0), pending_w.piece_index);
    try std.testing.expectEqual(@as(usize, 1), el.io.pending_len);
    switch (wop.completion.op) {
        .write => |op| {
            try std.testing.expectEqual(@as(posix.fd_t, 42), op.fd);
            try std.testing.expectEqual(@as(u64, 104), op.offset);
            try std.testing.expectEqual(@as(usize, 12), op.buf.len);
            try std.testing.expectEqualSlices(u8, buf[4..], op.buf);
        },
        else => return error.ExpectedWriteResubmission,
    }

    try el.io.tick(1);

    try std.testing.expectEqual(@as(usize, 0), el.pending_writes.count());
}

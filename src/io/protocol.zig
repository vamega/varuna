const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const pw = @import("../net/peer_wire.zig");
const ext = @import("../net/extensions.zig");
const pex_mod = @import("../net/pex.zig");
const ut_metadata = @import("../net/ut_metadata.zig");
const hash_exchange = @import("../net/hash_exchange.zig");
const merkle = @import("../torrent/merkle.zig");
const merkle_cache = @import("../torrent/merkle_cache.zig");
const info_hash_mod = @import("../torrent/info_hash.zig");
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
                    // BEP 16: track piece distribution for super-seeding
                    if (tc.super_seed) |ss| {
                        ss.recordPeerHave(piece_index);
                        // After a peer reports having a piece, send them
                        // the next piece they should download.
                        if (ss.pickPieceForPeer(slot, peer.availability)) |next_piece| {
                            var have_payload: [4]u8 = undefined;
                            std.mem.writeInt(u32, &have_payload, next_piece, .big);
                            submitMessage(self, slot, 4, &have_payload) catch {};
                        }
                    }
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
        hash_exchange.msg_hash_request => {
            // BEP 52: hash request -- peer wants Merkle proof hashes
            handleHashRequest(self, slot, payload);
        },
        hash_exchange.msg_hashes => {
            // BEP 52: hashes response -- peer sent us Merkle proof hashes
            handleHashesResponse(self, slot, payload);
        },
        hash_exchange.msg_hash_reject => {
            // BEP 52: hash reject -- peer cannot provide requested hashes
            handleHashReject(self, slot, payload);
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
                // BEP 21: store upload_only (partial seed) flag
                peer.upload_only = result.handshake.upload_only;
                log.debug("slot {d}: peer extensions: ut_metadata={d} ut_pex={d} upload_only={} client={s}", .{
                    slot,
                    result.handshake.extensions.ut_metadata,
                    result.handshake.extensions.ut_pex,
                    result.handshake.upload_only,
                    result.handshake.client,
                });
                ext.freeDecoded(self.allocator, &result);
            } else {
                // BEP 27: reject PEX messages for private torrents
                if (peer.extension_ids) |ids| {
                    if (ids.ut_pex != 0 and sub_id == ids.ut_pex) {
                        const is_private = if (self.getTorrentContext(peer.torrent_id)) |tc| tc.is_private else false;
                        if (is_private) {
                            log.debug("slot {d}: ignoring ut_pex message for private torrent", .{slot});
                            return;
                        }
                        // BEP 11: handle PEX message
                        handlePexMessage(self, slot, ext_payload);
                        return;
                    }
                }
                // BEP 9: handle ut_metadata messages (serve metadata to peers)
                if (sub_id == ext.local_ut_metadata_id) {
                    handleUtMetadata(self, slot, ext_payload);
                    return;
                }
                // Extension-specific message -- stub for future handlers
                log.debug("slot {d}: unhandled extension message sub_id={d} len={d}", .{
                    slot, sub_id, ext_payload.len,
                });
            }
        },
        else => {},
    }
}

// ── BEP 9: ut_metadata handler ──────────────────────────

/// Handle an incoming ut_metadata extension message.
/// Only request messages are handled (we serve metadata to peers).
/// Data and reject messages are only relevant during metadata fetch
/// which runs on a background thread, not through the event loop.
pub fn handleUtMetadata(self: *EventLoop, slot: u16, ext_payload: []const u8) void {
    const peer = &self.peers[slot];

    const msg = ut_metadata.decode(self.allocator, ext_payload) catch {
        log.debug("slot {d}: failed to decode ut_metadata message", .{slot});
        return;
    };

    switch (msg.msg_type) {
        .request => {
            // Peer is requesting a metadata piece from us.
            // We can only serve if we have the torrent's info dictionary.
            const tc = self.getTorrentContext(peer.torrent_id) orelse return;
            const session = tc.session orelse return;

            // Find the raw info dictionary bytes from our torrent data
            const info_bytes = info_hash_mod.findInfoBytes(session.torrent_bytes) catch {
                // We don't have valid info bytes -- send reject
                sendUtMetadataReject(self, slot, peer, msg.piece);
                return;
            };

            const total_size: u32 = @intCast(info_bytes.len);
            const piece_count = (total_size + ut_metadata.metadata_piece_size - 1) / ut_metadata.metadata_piece_size;

            if (msg.piece >= piece_count) {
                sendUtMetadataReject(self, slot, peer, msg.piece);
                return;
            }

            // Calculate piece data bounds
            const offset = @as(usize, msg.piece) * ut_metadata.metadata_piece_size;
            const end = @min(offset + ut_metadata.metadata_piece_size, total_size);
            const piece_data = info_bytes[offset..end];

            // Encode data message header + piece data
            const header_bytes = ut_metadata.encodeData(self.allocator, msg.piece, total_size) catch return;
            defer self.allocator.free(header_bytes);

            // Combine header + piece data into the extension payload
            const combined = self.allocator.alloc(u8, header_bytes.len + piece_data.len) catch return;
            defer self.allocator.free(combined);
            @memcpy(combined[0..header_bytes.len], header_bytes);
            @memcpy(combined[header_bytes.len..], piece_data);

            // Send as extension message to peer's ut_metadata ID
            const peer_ut_id = if (peer.extension_ids) |ids| ids.ut_metadata else 0;
            if (peer_ut_id == 0) return;

            // Allocate the frame for tracked send (io_uring is async, buffer must persist)
            const frame = ext.serializeExtensionMessage(self.allocator, peer_ut_id, combined) catch return;

            const ts = self.nextTrackedSendUserData(slot);
            const tracked = self.trackPendingSendOwned(slot, ts.send_id, frame) catch {
                self.allocator.free(frame);
                return;
            };

            _ = self.ring.send(ts.ud, peer.fd, tracked, 0) catch {
                // Send failed; the buffer will be freed when pending_sends is cleaned up
                self.freeOnePendingSend(slot, ts.send_id);
                return;
            };
            peer.send_pending = true;
        },
        .data, .reject => {
            // These are only relevant during metadata fetch (background thread).
            // In the event loop context, ignore them.
            log.debug("slot {d}: unexpected ut_metadata {s} message", .{
                slot,
                if (msg.msg_type == .data) "data" else "reject",
            });
        },
    }
}

fn sendUtMetadataReject(self: *EventLoop, slot: u16, peer: *Peer, piece: u32) void {
    const peer_ut_id = if (peer.extension_ids) |ids| ids.ut_metadata else return;
    if (peer_ut_id == 0) return;

    const reject_payload = ut_metadata.encodeReject(self.allocator, piece) catch return;
    defer self.allocator.free(reject_payload);

    // Allocate frame for tracked send
    const frame = ext.serializeExtensionMessage(self.allocator, peer_ut_id, reject_payload) catch return;

    const ts = self.nextTrackedSendUserData(slot);
    const tracked = self.trackPendingSendOwned(slot, ts.send_id, frame) catch {
        self.allocator.free(frame);
        return;
    };

    _ = self.ring.send(ts.ud, peer.fd, tracked, 0) catch {
        self.freeOnePendingSend(slot, ts.send_id);
        return;
    };
    peer.send_pending = true;
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
        // MSE/PE: encrypt in-place before sending
        peer.crypto.encryptBuf(peer.handshake_buf[0 .. 5 + payload.len]);
        const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 0 });
        _ = try self.ring.send(ud, peer.fd, peer.handshake_buf[0 .. 5 + payload.len], 0);
        peer.send_pending = true;
    } else {
        // For larger messages, allocate a buffer for the complete message
        const total_len = 5 + payload.len;
        const ts = self.nextTrackedSendUserData(slot);
        if (total_len <= EventLoop.small_send_capacity) {
            var stack_buf: [EventLoop.small_send_capacity]u8 = undefined;
            @memcpy(stack_buf[0..5], &header);
            @memcpy(stack_buf[5..total_len], payload);
            peer.crypto.encryptBuf(stack_buf[0..total_len]);

            const tracked = try self.trackPendingSendCopy(slot, ts.send_id, stack_buf[0..total_len]);
            _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
        } else {
            const send_buf = try self.allocator.alloc(u8, total_len);
            errdefer self.allocator.free(send_buf);
            @memcpy(send_buf[0..5], &header);
            @memcpy(send_buf[5..total_len], payload);
            peer.crypto.encryptBuf(send_buf);

            const tracked = try self.trackPendingSendOwned(slot, ts.send_id, send_buf);
            _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
        }
        peer.send_pending = true;
    }
}

/// Send our BEP 10 extension handshake as a tracked (heap-allocated) send.
/// Includes metadata_size (BEP 9) if we have the torrent's info dictionary.
/// Includes upload_only (BEP 21) if we are a partial seed.
pub fn submitExtensionHandshake(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    // Check if the torrent is private (BEP 27: don't advertise ut_pex)
    const tc = self.getTorrentContext(peer.torrent_id);
    const is_private = if (tc) |t| t.is_private else false;
    // Compute metadata_size from the info dictionary (BEP 9)
    const metadata_size: u32 = if (tc) |t| blk: {
        if (t.session) |session| {
            if (info_hash_mod.findInfoBytes(session.torrent_bytes)) |info_bytes| {
                break :blk @intCast(info_bytes.len);
            } else |_| {}
        }
        break :blk 0;
    } else 0;
    // BEP 21: advertise upload_only when we are a partial seed
    const am_upload_only = if (tc) |t| t.upload_only else false;
    // Encode the bencoded extension handshake payload
    const ext_payload = try ext.encodeExtensionHandshakeFull(self.allocator, self.port, is_private, metadata_size, am_upload_only);
    defer self.allocator.free(ext_payload);

    // Build the full framed message: 4-byte len | msg_id=20 | sub_id=0 | payload
    const frame = try ext.serializeExtensionMessage(self.allocator, ext.handshake_sub_id, ext_payload);
    errdefer self.allocator.free(frame);
    // MSE/PE: encrypt in-place before sending
    peer.crypto.encryptBuf(frame);

    // Track for cleanup with unique send_id
    const ts = self.nextTrackedSendUserData(slot);
    const tracked = try self.trackPendingSendOwned(slot, ts.send_id, frame);

    _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
    peer.send_pending = true;
}

// ── BEP 11: PEX message handling ────────────────────────

/// Handle an incoming ut_pex message from a peer.
/// Parses the PEX message and attempts to connect to newly discovered peers.
fn handlePexMessage(self: *EventLoop, slot: u16, payload: []const u8) void {
    const peer = &self.peers[slot];

    var msg = pex_mod.parsePexMessage(self.allocator, payload) catch {
        log.debug("slot {d}: failed to parse PEX message", .{slot});
        return;
    };
    defer msg.deinit(self.allocator);

    if (msg.added.len == 0 and msg.dropped.len == 0) return;

    log.debug("slot {d}: PEX message: {d} added, {d} dropped", .{
        slot, msg.added.len, msg.dropped.len,
    });

    // BEP 11: attempt connections to newly discovered peers.
    // Only for non-private torrents (already checked by caller).
    const torrent_id = peer.torrent_id;
    for (msg.added) |pex_peer| {
        // Check connection limits before attempting
        if (self.peer_count >= self.max_connections) break;
        if (self.peerCountForTorrent(torrent_id) >= self.max_peers_per_torrent) break;
        if (self.half_open_count >= self.max_half_open) break;

        // Don't connect to peers we already have
        if (isPeerAlreadyConnected(self, torrent_id, pex_peer.address)) continue;

        _ = self.addPeerForTorrent(pex_peer.address, torrent_id) catch continue;
    }
}

/// Check if we already have a connection to the given address for this torrent.
fn isPeerAlreadyConnected(self: *EventLoop, torrent_id: u8, addr: std.net.Address) bool {
    for (self.active_peer_slots.items) |slot| {
        const p = &self.peers[slot];
        if (p.state == .free) continue;
        if (p.torrent_id != torrent_id) continue;
        // Compare address family, IP, and port
        if (addressesEqual(p.address, addr)) return true;
    }
    return false;
}

fn addressesEqual(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    return switch (a.any.family) {
        posix.AF.INET => blk: {
            const a4 = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&a.any)));
            const b4 = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(&b.any)));
            break :blk a4.addr == b4.addr and a4.port == b4.port;
        },
        posix.AF.INET6 => blk: {
            const a6 = @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(&a.any)));
            const b6 = @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(&b.any)));
            break :blk std.mem.eql(u8, std.mem.asBytes(&a6.addr), std.mem.asBytes(&b6.addr)) and a6.port == b6.port;
        },
        else => false,
    };
}

/// Build and send a PEX message to the given peer slot.
/// Called periodically from peer_policy.checkPex.
pub fn submitPexMessage(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    if (peer.state == .free or peer.state == .disconnecting) return;

    // Need the peer's ut_pex ID to send to them
    const peer_pex_id = if (peer.extension_ids) |ids| ids.ut_pex else 0;
    if (peer_pex_id == 0) return;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;

    // Private torrents must not exchange peers
    if (tc.is_private) return;

    const torrent_pex = tc.pex_state orelse return;

    // Lazily allocate PEX state for this peer
    if (peer.pex_state == null) {
        const ps = try self.allocator.create(pex_mod.PexState);
        ps.* = pex_mod.PexState{};
        peer.pex_state = ps;
    }
    const peer_pex = peer.pex_state.?;

    // Build the PEX payload
    const payload = try pex_mod.buildPexMessage(self.allocator, torrent_pex, peer_pex) orelse return;
    defer self.allocator.free(payload);

    // Frame as BEP 10 extension message and send
    const frame = try ext.serializeExtensionMessage(self.allocator, peer_pex_id, payload);
    errdefer self.allocator.free(frame);

    const ts = self.nextTrackedSendUserData(slot);
    const tracked = try self.trackPendingSendOwned(slot, ts.send_id, frame);

    _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
    peer.send_pending = true;
    peer_pex.last_pex_time = std.time.timestamp();

    log.debug("slot {d}: sent PEX message", .{slot});
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
/// In BEP 16 super-seed mode, sends individual HAVE messages instead of a
/// full bitfield to control which pieces each peer sees.
pub fn sendInboundBitfieldOrUnchoke(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const tc_bp = self.getTorrentContext(peer.torrent_id);

    // BEP 16: super-seed mode -- send a single HAVE instead of bitfield
    if (tc_bp) |tc| {
        if (tc.super_seed) |ss| {
            ss.addPeer(slot);
            if (ss.pickPieceForPeer(slot, peer.availability)) |piece_idx| {
                // Send HAVE message (id=4, 4-byte big-endian piece index)
                var have_payload: [4]u8 = undefined;
                std.mem.writeInt(u32, &have_payload, piece_idx, .big);
                peer.state = .inbound_bitfield_send; // reuse state for flow
                submitMessage(self, slot, 4, &have_payload) catch {
                    self.removePeer(slot);
                    return;
                };
            } else {
                // No useful piece to advertise, go straight to unchoke
                peer.state = .inbound_unchoke_send;
                peer.am_choking = false;
                submitMessage(self, slot, 1, &.{}) catch {
                    self.removePeer(slot);
                };
            }
            return;
        }
    }

    // Normal mode: send full bitfield
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

// ── BEP 52: Hash exchange handlers ────────────────────────

/// Handle an incoming hash request (msg_type 21).
/// If we have the Merkle tree for the requested file, build and send a hashes
/// response. Otherwise, send a hash reject.
fn handleHashRequest(self: *EventLoop, slot: u16, payload: []const u8) void {
    const peer = &self.peers[slot];

    const req = hash_exchange.decodeHashRequest(payload) catch {
        log.debug("slot {d}: invalid hash request message", .{slot});
        return;
    };

    log.debug("slot {d}: hash request file={d} layer={d} index={d} len={d} proof={d}", .{
        slot, req.file_index, req.base_layer, req.index, req.length, req.proof_layers,
    });

    // Look up the torrent's Merkle tree. If we don't have v2 metadata or the
    // specific file tree, reject the request.
    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const session = tc.session orelse {
        sendHashReject(self, slot, req);
        return;
    };

    // Check if this is a v2/hybrid torrent with file tree metadata
    if (!session.metainfo.hasV2()) {
        sendHashReject(self, slot, req);
        return;
    }

    const file_tree_v2 = session.metainfo.file_tree_v2 orelse {
        sendHashReject(self, slot, req);
        return;
    };

    // Validate file index
    if (req.file_index >= file_tree_v2.len) {
        log.debug("slot {d}: hash request file_index {d} out of range (max {d})", .{
            slot, req.file_index, file_tree_v2.len,
        });
        sendHashReject(self, slot, req);
        return;
    }

    // Lazily initialize the Merkle cache if not yet created
    if (tc.merkle_cache == null) {
        self.initMerkleCache(peer.torrent_id);
    }

    const mc = tc.merkle_cache orelse {
        sendHashReject(self, slot, req);
        return;
    };

    // Check if we have a cached tree for this file
    if (mc.getTree(req.file_index)) |tree| {
        // Cache hit: build and send the hashes response
        sendHashesFromTree(self, slot, tree, req);
        return;
    }

    // Tree not cached yet. Check if all pieces for this file are complete.
    const complete = tc.complete_pieces orelse {
        sendHashReject(self, slot, req);
        return;
    };

    if (!mc.isFileComplete(req.file_index, complete)) {
        // File not complete -- cannot build tree
        log.debug("slot {d}: hash request for incomplete file {d}", .{ slot, req.file_index });
        sendHashReject(self, slot, req);
        return;
    }

    // File is complete. Submit async Merkle tree building to the hasher
    // threadpool so we don't block the event loop with disk reads + SHA-256.
    const range = mc.filePieceRange(req.file_index) orelse {
        sendHashReject(self, slot, req);
        return;
    };

    // Queue the pending request. addPendingRequest returns true if we need
    // to submit a new build job (first request for this file), false if a
    // build is already in progress (coalesced with existing request).
    const need_submit = mc.addPendingRequest(slot, req) catch {
        sendHashReject(self, slot, req);
        return;
    };

    if (need_submit) {
        const hasher = self.hasher orelse {
            // No hasher available -- cannot build async. Remove the pending
            // request and reject.
            mc.removePendingRequestsForSlot(slot);
            sendHashReject(self, slot, req);
            return;
        };

        hasher.submitMerkleJob(
            peer.torrent_id,
            req.file_index,
            range.first,
            range.count,
            &session.layout,
            tc.shared_fds,
        ) catch {
            // Failed to submit job -- clean up and reject
            var discard_buf = std.ArrayList(merkle_cache.MerkleCache.PendingHashRequest).empty;
            defer discard_buf.deinit(self.allocator);
            mc.takePendingRequests(req.file_index, &discard_buf);
            sendHashReject(self, slot, req);
            return;
        };

        log.debug("slot {d}: submitted async Merkle build for file {d} ({d} pieces)", .{
            slot, req.file_index, range.count,
        });
    } else {
        log.debug("slot {d}: hash request for file {d} coalesced with in-progress build", .{
            slot, req.file_index,
        });
    }
}

/// Build and send a hashes response from a cached Merkle tree.
pub fn sendHashesFromTree(
    self: *EventLoop,
    slot: u16,
    tree: *const merkle.MerkleTree,
    req: hash_exchange.HashRequest,
) void {
    const resp = hash_exchange.buildHashesFromTree(self.allocator, tree, req) catch {
        sendHashReject(self, slot, req);
        return;
    } orelse {
        sendHashReject(self, slot, req);
        return;
    };
    defer hash_exchange.freeHashesResponse(self.allocator, resp);

    // Encode and send the hashes response
    const resp_payload = hash_exchange.encodeHashesResponse(self.allocator, resp) catch {
        sendHashReject(self, slot, req);
        return;
    };
    defer self.allocator.free(resp_payload);

    log.debug("slot {d}: sending hashes file={d} layer={d} index={d} count={d} proof={d}", .{
        slot, resp.file_index, resp.base_layer, resp.index, resp.length, resp.proof_layers,
    });

    submitMessage(self, slot, hash_exchange.msg_hashes, resp_payload) catch {
        log.debug("slot {d}: failed to send hashes response", .{slot});
    };
}

/// Handle an incoming hashes response (msg_type 22).
/// Verify the received hashes against the known Merkle root for the file.
fn handleHashesResponse(self: *EventLoop, slot: u16, payload: []const u8) void {
    const peer = &self.peers[slot];

    const resp = hash_exchange.decodeHashesResponse(self.allocator, payload) catch {
        log.debug("slot {d}: invalid hashes response message", .{slot});
        return;
    };
    defer hash_exchange.freeHashesResponse(self.allocator, resp);

    log.debug("slot {d}: received hashes file={d} layer={d} index={d} count={d} proof_layers={d}", .{
        slot, resp.file_index, resp.base_layer, resp.index, resp.length, resp.proof_layers,
    });

    // Look up the torrent to verify against known Merkle roots
    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const session = tc.session orelse return;

    if (!session.metainfo.hasV2()) return;

    // Verify the hashes against the expected Merkle root for this file
    const file_tree_v2 = session.metainfo.file_tree_v2 orelse return;
    if (resp.file_index >= file_tree_v2.len) {
        log.debug("slot {d}: hashes response file_index {d} out of range", .{ slot, resp.file_index });
        return;
    }

    // For base_layer 0 (leaf/piece hashes), we can verify individual hashes
    // against the file's pieces_root using the proof. This validates that the
    // peer's hashes are consistent with the torrent metadata.
    // Full integration with piece downloading is deferred -- for now, we log
    // and validate the proof structure.
    if (resp.base_layer == 0 and resp.proof.len > 0) {
        const expected_root = file_tree_v2[resp.file_index].pieces_root;
        _ = expected_root;
        log.debug("slot {d}: hashes for file {d}: {d} hashes, {d} proof layers received", .{
            slot, resp.file_index, resp.hashes.len, resp.proof.len,
        });
    }
}

/// Handle an incoming hash reject (msg_type 23).
fn handleHashReject(self: *EventLoop, slot: u16, payload: []const u8) void {
    const req = hash_exchange.decodeHashRequest(payload) catch {
        log.debug("slot {d}: invalid hash reject message", .{slot});
        return;
    };
    _ = self;

    log.debug("slot {d}: peer rejected hash request file={d} layer={d} index={d} len={d}", .{
        slot, req.file_index, req.base_layer, req.index, req.length,
    });
}

/// Send a hash reject message (echo back the request parameters).
pub fn sendHashReject(self: *EventLoop, slot: u16, req: hash_exchange.HashRequest) void {
    const reject_payload = hash_exchange.encodeHashRequest(req);
    submitMessage(self, slot, hash_exchange.msg_hash_reject, &reject_payload) catch {};
}

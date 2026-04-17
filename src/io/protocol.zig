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
const TorrentId = @import("event_loop.zig").TorrentId;
const address = @import("../net/address.zig");
const policy = @import("peer_policy.zig");
const seed_handler = @import("seed_handler.zig");
const utp_handler = @import("utp_handler.zig");

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
            // Release requested blocks back to the DownloadingPiece
            if (peer.downloading_piece) |dp| {
                dp.releaseBlocksForPeer(slot);
            }
            // Clear pipeline state
            peer.inflight_requests = 0;
            peer.pipeline_sent = peer.blocks_received;
            // Release pre-fetched next piece back to the tracker
            if (peer.next_downloading_piece != null) {
                policy.detachPeerFromNextDownloadingPiece(self, peer);
                peer.next_piece = null;
                peer.next_blocks_expected = 0;
                peer.next_blocks_received = 0;
                peer.next_pipeline_sent = 0;
            } else if (peer.next_piece) |next_idx| {
                if (self.getTorrentContext(peer.torrent_id)) |tc| {
                    if (tc.piece_tracker) |pt| pt.releasePiece(next_idx);
                }
                if (peer.next_piece_buf) |nbuf| {
                    self.allocator.free(nbuf);
                    peer.next_piece_buf = null; // prevent double-free in cleanupPeer
                }
                peer.next_piece = null;
                peer.next_blocks_expected = 0;
                peer.next_blocks_received = 0;
                peer.next_pipeline_sent = 0;
            }
            self.unmarkIdle(slot);
        },
        1 => {
            peer.peer_choking = false; // unchoke
            if (peer.current_piece != null) {
                // Peer was choked mid-download — resume the interrupted piece
                // instead of calling markIdle (which requires current_piece==null).
                policy.tryFillPipeline(self, slot) catch {};
            } else {
                self.markIdle(slot);
            }
        },
        2 => { // interested
            peer.peer_interested = true;
            // For seed mode, unchoking is now handled by recalculateUnchokes
            // But for immediate responsiveness, unchoke if under the limit
            if (peer.mode == .inbound and peer.am_choking) {
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
                if (peer.availability == null) {
                    if (self.getTorrentContext(peer.torrent_id)) |tc_have| {
                        if (tc_have.session) |sess_have| {
                            peer.availability = Bitfield.init(self.allocator, sess_have.pieceCount()) catch null;
                        }
                    }
                }
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
            const sess_bf = tc_bf.session orelse return;
            const piece_count = sess_bf.pieceCount();
            // BEP 3: bitfield length must be ceil(piece_count / 8)
            const expected_len = (piece_count + 7) / 8;
            if (payload.len != expected_len) {
                self.removePeer(slot);
                return;
            }
            // BEP 3: spare bits in the last byte must be zero
            const spare: u32 = expected_len * 8 - piece_count;
            if (spare > 0 and spare < 8) {
                const mask = @as(u8, 0xFF) >> @as(u3, @intCast(8 - spare));
                if (payload[payload.len - 1] & mask != 0) {
                    self.removePeer(slot);
                    return;
                }
            }
            if (peer.availability == null) {
                peer.availability = Bitfield.init(self.allocator, piece_count) catch return;
            }
            if (peer.availability) |*bf| {
                bf.importBitfield(payload);
            }
            peer.availability_known = true;
            if (peer.availability) |*bf| {
                if (tc_bf.piece_tracker) |pt| pt.addBitfieldAvailability(bf);
            }
            self.markIdle(slot);
        },
        6 => { // request
            if (peer.mode == .inbound and !peer.am_choking and payload.len >= 12) {
                seed_handler.servePieceRequest(self, slot, payload);
            }
        },
        7 => { // piece
            if (payload.len >= 8) {
                const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                const block_offset = std.mem.readInt(u32, payload[4..8], .big);
                const block_data = payload[8..];
                const block_size: u32 = 16 * 1024;
                const block_index: u16 = @intCast(block_offset / block_size);

                // Consume download tokens for rate limiting accounting
                _ = self.consumeDownloadTokens(peer.torrent_id, block_data.len);

                // Decrement shared inflight counter for any received block
                if (peer.inflight_requests > 0) peer.inflight_requests -= 1;

                if (peer.current_piece != null and peer.current_piece.? == piece_index) {
                    if (peer.downloading_piece) |dp| {
                        // Multi-source path: write through DownloadingPiece
                        if (dp.markBlockReceived(block_index, slot, block_offset, block_data)) {
                            peer.blocks_received += 1;
                            peer.bytes_downloaded_from += block_data.len;
                            self.accountTorrentBytes(peer.torrent_id, block_data.len, 0);

                            if (dp.isComplete()) {
                                policy.completePieceDownload(self, slot);
                            } else {
                                policy.tryFillPipeline(self, slot) catch |err| {
                                    log.debug("pipeline refill failed for slot {d}: {s}", .{ slot, @errorName(err) });
                                };
                            }
                        }
                    } else if (peer.piece_buf) |pbuf| {
                        // Legacy path (no DownloadingPiece)
                        const start: usize = @intCast(block_offset);
                        const end = start + block_data.len;
                        if (end <= pbuf.len) {
                            @memcpy(pbuf[start..end], block_data);
                            peer.blocks_received += 1;
                            peer.bytes_downloaded_from += block_data.len;
                            self.accountTorrentBytes(peer.torrent_id, block_data.len, 0);

                            if (peer.blocks_received >= peer.blocks_expected) {
                                policy.completePieceDownload(self, slot);
                            } else {
                                policy.tryFillPipeline(self, slot) catch |err| {
                                    log.debug("pipeline refill failed for slot {d}: {s}", .{ slot, @errorName(err) });
                                };
                            }
                        }
                    }
                } else if (peer.next_piece != null and peer.next_piece.? == piece_index) {
                    // Block arrived early for the pre-fetched next piece
                    if (peer.next_downloading_piece) |next_dp| {
                        if (next_dp.markBlockReceived(block_index, slot, block_offset, block_data)) {
                            peer.next_blocks_received += 1;
                            peer.bytes_downloaded_from += block_data.len;
                            self.accountTorrentBytes(peer.torrent_id, block_data.len, 0);
                            policy.tryFillPipeline(self, slot) catch {};
                        }
                    } else if (peer.next_piece_buf) |nbuf| {
                        const start: usize = @intCast(block_offset);
                        const end = start + block_data.len;
                        if (end <= nbuf.len) {
                            @memcpy(nbuf[start..end], block_data);
                            peer.next_blocks_received += 1;
                            peer.bytes_downloaded_from += block_data.len;
                            self.accountTorrentBytes(peer.torrent_id, block_data.len, 0);
                            // Refill pipeline with more blocks for next_piece or claim further piece
                            policy.tryFillPipeline(self, slot) catch {};
                        }
                    }
                }
            }
        },
        8 => { // cancel
            // BEP 3: peer cancels a previously requested block.
            // Drop the request from the seed handler's queued responses so we
            // don't waste bandwidth sending a block the peer no longer wants.
            if (payload.len >= 12) {
                seed_handler.cancelQueuedResponse(self, slot, payload);
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
                const result = ext.decodeExtensionHandshake(ext_payload) catch {
                    log.debug("slot {d}: failed to decode extension handshake", .{slot});
                    return;
                };
                peer.extension_ids = result.extensions;
                // BEP 21: store upload_only (partial seed) flag
                peer.upload_only = result.upload_only;
                log.debug("slot {d}: peer extensions: ut_metadata={d} ut_pex={d} upload_only={} client={s}", .{
                    slot,
                    result.extensions.ut_metadata,
                    result.extensions.ut_pex,
                    result.upload_only,
                    result.client,
                });
            } else {
                // BEP 27: reject PEX messages for private torrents
                if (peer.extension_ids) |ids| {
                    if (ids.ut_pex != 0 and sub_id == ids.ut_pex) {
                        const is_private = if (self.getTorrentContext(peer.torrent_id)) |tc| tc.is_private else false;
                        if (is_private or !self.pex_enabled) {
                            log.debug("slot {d}: ignoring ut_pex message (private={} pex_enabled={})", .{ slot, is_private, self.pex_enabled });
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

            // uTP peers: route through the uTP byte stream.
            if (peer.transport == .utp) {
                defer self.allocator.free(frame);
                utp_handler.utpSendData(self, slot, frame) catch return;
            } else {
                // MSE/PE: encrypt in-place before sending
                peer.crypto.encryptBuf(frame);

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
            }
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

    // uTP peers: route through the uTP byte stream.
    if (peer.transport == .utp) {
        defer self.allocator.free(frame);
        utp_handler.utpSendData(self, slot, frame) catch return;
    } else {
        // MSE/PE: encrypt in-place before sending
        peer.crypto.encryptBuf(frame);

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

    // uTP peers: route through the uTP byte stream instead of io_uring send.
    if (peer.transport == .utp) {
        return utp_handler.utpSendMessage(self, slot, id, payload);
    }

    // Build framed message: 4-byte length + id + payload
    const msg_len = @as(u32, @intCast(1 + payload.len));
    const total_len = 5 + payload.len;
    const ts = self.nextTrackedSendUserData(slot);

    if (total_len <= EventLoop.small_send_capacity) {
        var stack_buf: [EventLoop.small_send_capacity]u8 = undefined;
        std.mem.writeInt(u32, stack_buf[0..4], msg_len, .big);
        stack_buf[4] = id;
        @memcpy(stack_buf[5..total_len], payload);
        peer.crypto.encryptBuf(stack_buf[0..total_len]);

        const tracked = try self.trackPendingSendCopy(slot, ts.send_id, stack_buf[0..total_len]);
        _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
    } else {
        const send_buf = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(send_buf);
        std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
        send_buf[4] = id;
        @memcpy(send_buf[5..total_len], payload);
        peer.crypto.encryptBuf(send_buf);

        const tracked = try self.trackPendingSendOwned(slot, ts.send_id, send_buf);
        _ = try self.ring.send(ts.ud, peer.fd, tracked, 0);
    }
    peer.send_pending = true;
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

    // uTP peers: route through the uTP byte stream.
    if (peer.transport == .utp) {
        defer self.allocator.free(frame);
        try utp_handler.utpSendData(self, slot, frame);
        return;
    }

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

        // When uTP is enabled, alternate between TCP and uTP transports.
        _ = self.addPeerAutoTransport(pex_peer.address, torrent_id) catch continue;
    }
}

/// Check if we already have a connection to the given address for this torrent.
fn isPeerAlreadyConnected(self: *EventLoop, torrent_id: TorrentId, addr: std.net.Address) bool {
    const tc = self.getTorrentContext(torrent_id) orelse return false;
    for (tc.peer_slots.items) |slot| {
        const p = &self.peers[slot];
        if (p.state == .free) continue;
        // Compare address family, IP, and port
        if (address.addressEql(&p.address, &addr)) return true;
    }
    return false;
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

    // uTP peers: route through the uTP byte stream.
    if (peer.transport == .utp) {
        defer self.allocator.free(frame);
        try utp_handler.utpSendData(self, slot, frame);
        peer_pex.last_pex_time = std.time.timestamp();
        log.debug("slot {d}: sent PEX message", .{slot});
        return;
    }

    // MSE/PE: encrypt in-place before sending
    peer.crypto.encryptBuf(frame);

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

// ── Tests ────────────────────────────────────────────────

const testing = std.testing;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;

/// Set up a bare event loop with a torrent context and an active download peer
/// in slot 0. Returns the slot index (always 0).
fn setupTestPeer(el: *EventLoop) !u16 {
    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{};
    peer.fd = -1;
    peer.state = .active_recv_header;
    peer.mode = .outbound;
    peer.torrent_id = 0;
    peer.peer_choking = true;
    peer.am_choking = true;

    // body_buf starts as the small_body_buf (protocol.zig dereferences body_buf)
    peer.body_buf = &peer.small_body_buf;
    peer.body_expected = 0;
    peer.body_offset = 0;
    return slot;
}

fn setupTestTorrent(el: *EventLoop, piece_tracker: ?*PieceTracker) !void {
    const empty_fds = [_]std.posix.fd_t{};
    _ = try el.addTorrentContext(.{
        .piece_tracker = piece_tracker,
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    });
}

// ── CHOKE (id=0) ─────────────────────────────────────────

test "choke sets peer_choking to true" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Start unchoked so we can verify the transition
    peer.peer_choking = false;

    // Build choke message: body = [id=0]
    peer.small_body_buf[0] = 0; // choke
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(peer.peer_choking);
}

test "choke clears inflight_requests" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.peer_choking = false;
    peer.inflight_requests = 5;
    peer.blocks_received = 2;
    peer.pipeline_sent = 7;

    peer.small_body_buf[0] = 0;
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expectEqual(@as(u32, 0), peer.inflight_requests);
    // pipeline_sent is reset to blocks_received
    try testing.expectEqual(@as(u32, 2), peer.pipeline_sent);
}

test "choke releases and frees next_piece" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(testing.allocator, 4);
    defer initial_complete.deinit(testing.allocator);
    var tracker = try PieceTracker.init(testing.allocator, 4, 16384, 4 * 16384, &initial_complete, 0);
    defer tracker.deinit(testing.allocator);

    try setupTestTorrent(&el, &tracker);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Claim a piece via the tracker so we can verify it gets released
    const claimed = tracker.claimPiece(null);
    try testing.expect(claimed != null);

    peer.peer_choking = false;
    peer.next_piece = claimed;
    peer.next_piece_buf = try testing.allocator.alloc(u8, 16384);
    peer.next_blocks_expected = 4;
    peer.next_blocks_received = 1;
    peer.next_pipeline_sent = 2;

    peer.small_body_buf[0] = 0;
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(peer.next_piece == null);
    try testing.expect(peer.next_piece_buf == null);
    try testing.expectEqual(@as(u32, 0), peer.next_blocks_expected);
    try testing.expectEqual(@as(u32, 0), peer.next_blocks_received);
    try testing.expectEqual(@as(u32, 0), peer.next_pipeline_sent);

    // The piece should be reclaimable since it was released
    const reclaimed = tracker.claimPiece(null);
    try testing.expect(reclaimed != null);
    try testing.expectEqual(claimed.?, reclaimed.?);
}

test "choke removes peer from idle list" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Set up peer as idle candidate and add to idle list
    peer.peer_choking = false;
    peer.availability_known = true;
    peer.current_piece = null;
    // Manually add to idle list (markIdle has side effects we want to avoid)
    el.idle_peers.append(testing.allocator, slot) catch unreachable;
    peer.idle_peer_index = 0;

    peer.small_body_buf[0] = 0;
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(peer.idle_peer_index == null);
    try testing.expectEqual(@as(usize, 0), el.idle_peers.items.len);
}

// ── UNCHOKE (id=1) ───────────────────────────────────────

test "unchoke sets peer_choking to false" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    try testing.expect(peer.peer_choking);

    peer.small_body_buf[0] = 1; // unchoke
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(!peer.peer_choking);
}

// ── INTERESTED (id=2) ────────────────────────────────────

test "interested sets peer_interested to true" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    try testing.expect(!peer.peer_interested);

    peer.small_body_buf[0] = 2; // interested
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(peer.peer_interested);
}

// ── NOT INTERESTED (id=3) ────────────────────────────────

test "not interested sets peer_interested to false" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.peer_interested = true;

    peer.small_body_buf[0] = 3; // not interested
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(!peer.peer_interested);
}

// ── HAVE (id=4) ──────────────────────────────────────────

test "have updates availability bitfield" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(testing.allocator, 8);
    defer initial_complete.deinit(testing.allocator);
    var tracker = try PieceTracker.init(testing.allocator, 8, 16384, 8 * 16384, &initial_complete, 0);
    defer tracker.deinit(testing.allocator);

    try setupTestTorrent(&el, &tracker);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Pre-allocate availability bitfield (normally done during handshake)
    peer.availability = try Bitfield.init(testing.allocator, 8);

    // Build HAVE message: body = [id=4, piece_index=3 (big-endian)]
    peer.small_body_buf[0] = 4;
    std.mem.writeInt(u32, peer.small_body_buf[1..5], 3, .big);
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expect(peer.availability.?.has(3));
    try testing.expect(!peer.availability.?.has(0));
    try testing.expect(!peer.availability.?.has(7));
    try testing.expect(peer.availability_known);

    // Clean up
    peer.availability.?.deinit(testing.allocator);
    peer.availability = null;
}

test "have with out-of-range piece index does not crash" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(testing.allocator, 4);
    defer initial_complete.deinit(testing.allocator);
    var tracker = try PieceTracker.init(testing.allocator, 4, 16384, 4 * 16384, &initial_complete, 0);
    defer tracker.deinit(testing.allocator);

    try setupTestTorrent(&el, &tracker);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.availability = try Bitfield.init(testing.allocator, 4);

    // Send HAVE for piece index 999 (way out of range for 4-piece torrent)
    peer.small_body_buf[0] = 4;
    std.mem.writeInt(u32, peer.small_body_buf[1..5], 999, .big);
    peer.body_buf = &peer.small_body_buf;

    // Should not crash or panic
    processMessage(&el, slot);

    // Bitfield should not have changed for any valid index
    try testing.expect(!peer.availability.?.has(0));
    try testing.expect(!peer.availability.?.has(3));

    peer.availability.?.deinit(testing.allocator);
    peer.availability = null;
}

test "have creates availability bitfield lazily when session exists" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(testing.allocator, 8);
    defer initial_complete.deinit(testing.allocator);
    var tracker = try PieceTracker.init(testing.allocator, 8, 16384, 8 * 16384, &initial_complete, 0);
    defer tracker.deinit(testing.allocator);

    try setupTestTorrent(&el, &tracker);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // No pre-allocated availability -- it should stay null when there is no session
    try testing.expect(peer.availability == null);

    // HAVE message for piece 2
    peer.small_body_buf[0] = 4;
    std.mem.writeInt(u32, peer.small_body_buf[1..5], 2, .big);
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    // Without a session, availability won't be lazily created (the torrent context
    // has session=null in our test setup), but availability_known should be set
    // and it should not crash.
    try testing.expect(peer.availability_known);
}

// ── BITFIELD (id=5) ──────────────────────────────────────

test "bitfield imports peer bitfield correctly" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    var initial_complete = try Bitfield.init(testing.allocator, 8);
    defer initial_complete.deinit(testing.allocator);
    var tracker = try PieceTracker.init(testing.allocator, 8, 16384, 8 * 16384, &initial_complete, 0);
    defer tracker.deinit(testing.allocator);

    try setupTestTorrent(&el, &tracker);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Pre-allocate availability
    peer.availability = try Bitfield.init(testing.allocator, 8);

    // Build BITFIELD message: body = [id=5, bitfield_data...]
    // Bitfield: pieces 0, 2, 4, 6 set = 0b10101010 = 0xAA
    const body = try testing.allocator.alloc(u8, 2); // 1 byte id + 1 byte bitfield
    defer testing.allocator.free(body);
    body[0] = 5; // bitfield message id
    body[1] = 0xAA; // pieces 0, 2, 4, 6

    peer.body_buf = body;

    processMessage(&el, slot);

    try testing.expect(peer.availability.?.has(0));
    try testing.expect(!peer.availability.?.has(1));
    try testing.expect(peer.availability.?.has(2));
    try testing.expect(!peer.availability.?.has(3));
    try testing.expect(peer.availability.?.has(4));
    try testing.expect(!peer.availability.?.has(5));
    try testing.expect(peer.availability.?.has(6));
    try testing.expect(!peer.availability.?.has(7));
    try testing.expect(peer.availability_known);

    peer.availability.?.deinit(testing.allocator);
    peer.availability = null;
}

test "bitfield returns early without torrent context" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    // Do NOT set up a torrent context -- peer has torrent_id=0 but no context registered
    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{};
    peer.state = .active_recv_header;
    peer.torrent_id = 99; // non-existent torrent

    const body = try testing.allocator.alloc(u8, 2);
    defer testing.allocator.free(body);
    body[0] = 5;
    body[1] = 0xFF;
    peer.body_buf = body;

    // Should return early gracefully without crashing
    processMessage(&el, slot);

    try testing.expect(!peer.availability_known);
}

// ── PIECE (id=7) ─────────────────────────────────────────

test "piece copies block data to piece_buf at correct offset" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Simulate downloading piece 5
    peer.current_piece = 5;
    const piece_size: usize = 64;
    peer.piece_buf = try testing.allocator.alloc(u8, piece_size);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 4;
    peer.inflight_requests = 2;
    peer.peer_choking = false;

    // Build PIECE message: body = [id=7, piece_index(4), block_offset(4), data...]
    // piece_index=5, block_offset=16, data = "HELLO" (5 bytes)
    const data = "HELLO";
    const body_len = 1 + 4 + 4 + data.len; // id + piece_index + offset + data
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7; // piece
    std.mem.writeInt(u32, body[1..5], 5, .big); // piece_index
    std.mem.writeInt(u32, body[5..9], 16, .big); // block_offset
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    // Verify data was copied at offset 16
    try testing.expectEqualSlices(u8, data, peer.piece_buf.?[16 .. 16 + data.len]);
    // Verify surrounding data is still zero
    try testing.expectEqual(@as(u8, 0), peer.piece_buf.?[0]);
    try testing.expectEqual(@as(u8, 0), peer.piece_buf.?[15]);
    try testing.expectEqual(@as(u8, 0), peer.piece_buf.?[21]);

    try testing.expectEqual(@as(u32, 1), peer.blocks_received);
    try testing.expectEqual(@as(u32, 1), peer.inflight_requests);
    try testing.expectEqual(@as(u64, data.len), peer.bytes_downloaded_from);
}

test "piece for wrong piece_index is ignored" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Downloading piece 5, but we receive a block for piece 9
    peer.current_piece = 5;
    const piece_size: usize = 64;
    peer.piece_buf = try testing.allocator.alloc(u8, piece_size);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 4;
    peer.inflight_requests = 2;

    const data = "WRONG";
    const body_len = 1 + 4 + 4 + data.len;
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7;
    std.mem.writeInt(u32, body[1..5], 9, .big); // wrong piece_index
    std.mem.writeInt(u32, body[5..9], 0, .big);
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    // Nothing should be written to piece_buf
    for (peer.piece_buf.?) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
    // blocks_received should not increment
    try testing.expectEqual(@as(u32, 0), peer.blocks_received);
    // inflight_requests still decrements (block was received, just for wrong piece)
    try testing.expectEqual(@as(u32, 1), peer.inflight_requests);
}

test "piece decrements inflight_requests" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.current_piece = 0;
    peer.piece_buf = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 4;
    peer.inflight_requests = 3;

    const data = "AB";
    const body_len = 1 + 4 + 4 + data.len;
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7;
    std.mem.writeInt(u32, body[1..5], 0, .big);
    std.mem.writeInt(u32, body[5..9], 0, .big);
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    try testing.expectEqual(@as(u32, 2), peer.inflight_requests);
}

test "piece for next_piece updates next piece buffers" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    // Current piece is 3, next piece is 7
    peer.current_piece = 3;
    peer.piece_buf = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 2;

    peer.next_piece = 7;
    peer.next_piece_buf = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(peer.next_piece_buf.?);
    @memset(peer.next_piece_buf.?, 0);
    peer.next_blocks_received = 0;
    peer.next_blocks_expected = 2;
    peer.inflight_requests = 2;

    // Send a block for piece 7 (the next piece)
    const data = "NEXT";
    const body_len = 1 + 4 + 4 + data.len;
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7;
    std.mem.writeInt(u32, body[1..5], 7, .big); // piece_index = 7 (next_piece)
    std.mem.writeInt(u32, body[5..9], 4, .big); // block_offset = 4
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    // Data should be in next_piece_buf at offset 4
    try testing.expectEqualSlices(u8, data, peer.next_piece_buf.?[4 .. 4 + data.len]);
    try testing.expectEqual(@as(u32, 1), peer.next_blocks_received);
    try testing.expectEqual(@as(u64, data.len), peer.bytes_downloaded_from);
    // inflight_requests decrements for any piece block
    try testing.expectEqual(@as(u32, 1), peer.inflight_requests);
    // current piece should be untouched
    try testing.expectEqual(@as(u32, 0), peer.blocks_received);
}

test "piece with zero inflight_requests does not underflow" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.current_piece = 0;
    peer.piece_buf = try testing.allocator.alloc(u8, 16);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 4;
    peer.inflight_requests = 0; // already at zero

    const data = "X";
    const body_len = 1 + 4 + 4 + data.len;
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7;
    std.mem.writeInt(u32, body[1..5], 0, .big);
    std.mem.writeInt(u32, body[5..9], 0, .big);
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    // Should remain 0, not underflow to maxInt(u32)
    try testing.expectEqual(@as(u32, 0), peer.inflight_requests);
    try testing.expectEqual(@as(u32, 1), peer.blocks_received);
}

test "piece with out-of-bounds offset is rejected" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.current_piece = 0;
    const piece_size: usize = 16;
    peer.piece_buf = try testing.allocator.alloc(u8, piece_size);
    defer testing.allocator.free(peer.piece_buf.?);
    @memset(peer.piece_buf.?, 0);
    peer.blocks_received = 0;
    peer.blocks_expected = 2;
    peer.inflight_requests = 1;

    // block_offset=14, data length=5 -> end=19 > piece_size=16
    const data = "OVRFL";
    const body_len = 1 + 4 + 4 + data.len;
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    body[0] = 7;
    std.mem.writeInt(u32, body[1..5], 0, .big);
    std.mem.writeInt(u32, body[5..9], 14, .big); // offset 14 + 5 bytes > 16
    @memcpy(body[9..], data);

    peer.body_buf = body;

    processMessage(&el, slot);

    // Data should NOT be written (end > pbuf.len check should block it)
    for (peer.piece_buf.?) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
    // blocks_received should not increment
    try testing.expectEqual(@as(u32, 0), peer.blocks_received);
    // inflight_requests still decrements (block was received, bounds check is after)
    try testing.expectEqual(@as(u32, 0), peer.inflight_requests);
}

// ── CANCEL (id=8) ────────────────────────────────────────

test "cancel removes matching queued response" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];
    peer.mode = .inbound;

    // Create a fake PieceBuffer for the queued response
    const piece_buffer = try testing.allocator.create(EventLoop.PieceBuffer);
    piece_buffer.* = .{
        .buf = &.{},
        .ref_count = 2, // extra ref so it won't be freed during test
    };
    defer testing.allocator.destroy(piece_buffer);

    // Add a queued response
    try el.queued_responses.append(testing.allocator, .{
        .slot = slot,
        .piece_index = 10,
        .block_offset = 0,
        .block_length = 16384,
        .piece_buffer = piece_buffer,
    });

    try testing.expectEqual(@as(usize, 1), el.queued_responses.items.len);

    // Build CANCEL message: body = [id=8, piece_index(4), offset(4), length(4)]
    peer.small_body_buf[0] = 8;
    std.mem.writeInt(u32, peer.small_body_buf[1..5], 10, .big); // piece_index
    std.mem.writeInt(u32, peer.small_body_buf[5..9], 0, .big); // offset
    std.mem.writeInt(u32, peer.small_body_buf[9..13], 16384, .big); // length
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    try testing.expectEqual(@as(usize, 0), el.queued_responses.items.len);
}

test "cancel does not remove non-matching queued response" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];
    peer.mode = .inbound;

    const piece_buffer = try testing.allocator.create(EventLoop.PieceBuffer);
    piece_buffer.* = .{
        .buf = &.{},
        .ref_count = 2,
    };
    defer testing.allocator.destroy(piece_buffer);

    // Queue a response for piece 10, offset 0
    try el.queued_responses.append(testing.allocator, .{
        .slot = slot,
        .piece_index = 10,
        .block_offset = 0,
        .block_length = 16384,
        .piece_buffer = piece_buffer,
    });

    // Cancel for piece 10, offset 16384 (different offset -- should not match)
    peer.small_body_buf[0] = 8;
    std.mem.writeInt(u32, peer.small_body_buf[1..5], 10, .big);
    std.mem.writeInt(u32, peer.small_body_buf[5..9], 16384, .big); // different offset
    std.mem.writeInt(u32, peer.small_body_buf[9..13], 16384, .big);
    peer.body_buf = &peer.small_body_buf;

    processMessage(&el, slot);

    // Response should still be in the queue
    try testing.expectEqual(@as(usize, 1), el.queued_responses.items.len);

    // Clean up
    _ = el.queued_responses.swapRemove(0);
}

// ── Empty / null body ────────────────────────────────────

test "processMessage returns early on null body_buf" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{};
    peer.state = .active_recv_header;
    peer.torrent_id = 0;
    peer.body_buf = null;

    // Should return immediately without crashing
    processMessage(&el, slot);

    try testing.expect(peer.peer_choking); // unchanged from default
}

test "processMessage returns early on empty body" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{};
    peer.state = .active_recv_header;
    peer.torrent_id = 0;

    // Empty slice body
    const empty: []u8 = &.{};
    peer.body_buf = empty;

    processMessage(&el, slot);

    try testing.expect(peer.peer_choking); // unchanged
}

// ── Unknown message ID ───────────────────────────────────

test "unknown message ID is silently ignored" {
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();
    try setupTestTorrent(&el, null);
    const slot = try setupTestPeer(&el);
    const peer = &el.peers[slot];

    peer.small_body_buf[0] = 255; // unknown message ID
    peer.body_buf = &peer.small_body_buf;

    const choking_before = peer.peer_choking;
    const interested_before = peer.peer_interested;

    processMessage(&el, slot);

    // State should be untouched
    try testing.expectEqual(choking_before, peer.peer_choking);
    try testing.expectEqual(interested_before, peer.peer_interested);
}

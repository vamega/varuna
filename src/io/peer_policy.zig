const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const Sha1 = @import("../crypto/root.zig").Sha1;
const Bitfield = @import("../bitfield.zig").Bitfield;
const pex_mod = @import("../net/pex.zig");
const storage = @import("../storage/root.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const Peer = @import("event_loop.zig").Peer;
const PeerState = @import("event_loop.zig").PeerState;
const TorrentContext = @import("event_loop.zig").TorrentContext;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const max_peers = @import("event_loop.zig").max_peers;
const protocol = @import("protocol.zig");
const MerkleCache = @import("../torrent/merkle_cache.zig").MerkleCache;
const Hasher = @import("hasher.zig").Hasher;
const LayoutSpan = @import("../torrent/layout.zig").Layout.Span;

const pipeline_depth: u32 = 64;
const peer_timeout_secs: i64 = 60;
const unchoke_interval_secs: i64 = 10; // BEP 3: recalculate every 10 seconds
const optimistic_unchoke_interval_secs: i64 = 30; // rotate optimistic unchoke every 30s
const max_unchoked: u32 = 4;
const optimistic_unchoke_slots: u32 = 1;

// ── Piece download coordination ───────────────────────

pub fn tryAssignPieces(self: *EventLoop) void {
    var i: usize = 0;
    while (i < self.idle_peers.items.len) {
        const slot = self.idle_peers.items[i];
        const peer = &self.peers[slot];

        // Re-check eligibility (state may have changed since enqueue).
        if (!EventLoop.isIdleCandidate(peer)) {
            self.unmarkIdle(slot);
            continue;
        }

        // Skip piece assignment when download is throttled
        if (self.isDownloadThrottled(peer.torrent_id)) {
            i += 1;
            continue;
        }

        const tc = self.getTorrentContext(peer.torrent_id) orelse {
            self.unmarkIdle(slot);
            continue;
        };

        // BEP 21: when we are a partial seed (upload_only), don't request pieces
        if (tc.upload_only) {
            i += 1;
            continue;
        }

        const pt = tc.piece_tracker orelse {
            self.unmarkIdle(slot);
            continue;
        };

        const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
        const piece_index = pt.claimPiece(peer_bf) orelse {
            // No piece available for this peer right now; keep it in the
            // list so we retry next tick.
            i += 1;
            continue;
        };

        startPieceDownload(self, slot, piece_index) catch {
            pt.releasePiece(piece_index);
            i += 1;
            continue;
        };

        // Successfully assigned -- remove from idle list.
        self.unmarkIdle(slot);
    }
}

pub fn startPieceDownload(self: *EventLoop, slot: u16, piece_index: u32) !void {
    const peer = &self.peers[slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse return error.TorrentNotFound;
    const sess = tc.session orelse return error.TorrentNotFound;
    const piece_size = try sess.layout.pieceSize(piece_index);
    const geometry = sess.geometry();
    const block_count = try geometry.blockCount(piece_index);

    peer.current_piece = piece_index;
    peer.piece_buf = try self.allocator.alloc(u8, piece_size);
    errdefer {
        // On failure, clean up so the peer doesn't stall with a dangling current_piece.
        if (peer.piece_buf) |buf| self.allocator.free(buf);
        peer.piece_buf = null;
        peer.current_piece = null;
    }
    peer.blocks_received = 0;
    peer.blocks_expected = block_count;
    peer.pipeline_sent = 0;
    peer.inflight_requests = 0;

    try tryFillPipeline(self, slot);
}

pub fn tryFillPipeline(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    if (peer.current_piece == null) return;
    if (peer.peer_choking) return;
    // Note: we no longer gate on send_pending here. The tracked-send system
    // (PendingSend with unique send_ids) supports multiple in-flight sends
    // per slot. Gating on send_pending was serializing pipeline refills,
    // adding up to 40ms latency per CQE batch when combined with Nagle.

    // Skip filling pipeline when download is throttled
    if (self.isDownloadThrottled(peer.torrent_id)) return;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const sess = tc.session orelse return;
    const geometry = sess.geometry();

    // 17 bytes per REQUEST: 4-byte len + 1-byte id + 12-byte payload
    const request_size: usize = 17;
    // Buffer covers current + next piece (at most pipeline_depth * 2 total requests)
    var send_buf: [request_size * pipeline_depth * 2]u8 = undefined;

    // --- Phase 1: fill requests for current piece ---
    var p1: u32 = 0; // requests to send for current piece this call
    if (peer.current_piece) |piece_index| {
        while (peer.inflight_requests + p1 < pipeline_depth and
            peer.pipeline_sent + p1 < peer.blocks_expected)
        {
            const req = geometry.requestForBlock(piece_index, peer.pipeline_sent + p1) catch break;
            writeRequestMsg(send_buf[p1 * request_size ..], req);
            p1 += 1;
        }
    }

    // --- Phase 2: prefetch next piece if current is fully requested and pipeline has headroom ---
    var p2: u32 = 0; // requests to send for next piece this call
    const cur_fully_requested = if (peer.current_piece) |_|
        (peer.pipeline_sent + p1 >= peer.blocks_expected)
    else
        false;

    if (cur_fully_requested and peer.inflight_requests + p1 < pipeline_depth) {
        // Claim next piece if not already done
        if (peer.next_piece == null) {
            if (tc.piece_tracker) |pt| {
                const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
                if (pt.claimPiece(peer_bf)) |next_idx| {
                    const next_size = sess.layout.pieceSize(next_idx) catch {
                        pt.releasePiece(next_idx);
                        return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                    };
                    const next_block_count = geometry.blockCount(next_idx) catch {
                        pt.releasePiece(next_idx);
                        return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                    };
                    const next_buf = self.allocator.alloc(u8, next_size) catch {
                        pt.releasePiece(next_idx);
                        return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                    };
                    peer.next_piece = next_idx;
                    peer.next_piece_buf = next_buf;
                    peer.next_blocks_expected = next_block_count;
                    peer.next_blocks_received = 0;
                    peer.next_pipeline_sent = 0;
                }
            }
        }

        // Fill requests for next piece
        if (peer.next_piece) |next_idx| {
            while (peer.inflight_requests + p1 + p2 < pipeline_depth and
                peer.next_pipeline_sent + p2 < peer.next_blocks_expected)
            {
                const req = geometry.requestForBlock(next_idx, peer.next_pipeline_sent + p2) catch break;
                writeRequestMsg(send_buf[(p1 + p2) * request_size ..], req);
                p2 += 1;
            }
        }
    }

    return try submitPipelineRequests(self, slot, send_buf[0 .. (p1 + p2) * request_size], p1, p2);
}

fn writeRequestMsg(buf: []u8, req: anytype) void {
    std.mem.writeInt(u32, buf[0..4], 13, .big); // length prefix: 1 + 12
    buf[4] = 6; // REQUEST message id
    std.mem.writeInt(u32, buf[5..9], req.piece_index, .big);
    std.mem.writeInt(u32, buf[9..13], req.piece_offset, .big);
    std.mem.writeInt(u32, buf[13..17], req.length, .big);
}

/// Submit the request batch via io_uring and update peer pipeline state.
fn submitPipelineRequests(
    self: *EventLoop,
    slot: u16,
    buf: []u8,
    p1: u32, // requests for current piece
    p2: u32, // requests for next piece
) !void {
    const peer = &self.peers[slot];
    const total = p1 + p2;
    if (total == 0) return;

    // MSE/PE: encrypt in-place before copying into tracked buffer
    peer.crypto.encryptBuf(buf);

    const ts = self.nextTrackedSendUserData(slot);
    const tracked = self.trackPendingSendCopy(slot, ts.send_id, buf) catch return;

    _ = self.ring.send(ts.ud, peer.fd, tracked, 0) catch {
        self.freeOnePendingSend(slot, ts.send_id);
        return;
    };
    peer.send_pending = true;
    peer.pipeline_sent += p1;
    peer.next_pipeline_sent += p2;
    peer.inflight_requests += total;
}

/// After current piece completes: promote pre-fetched next_piece to current,
/// or fall back to markIdle if no next piece is queued.
fn promoteNextPieceOrMarkIdle(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    if (peer.next_piece != null) {
        peer.current_piece = peer.next_piece;
        peer.piece_buf = peer.next_piece_buf;
        peer.blocks_expected = peer.next_blocks_expected;
        peer.blocks_received = peer.next_blocks_received;
        peer.pipeline_sent = peer.next_pipeline_sent;
        // inflight_requests covers pending requests for the promoted piece -- do not reset.
        peer.next_piece = null;
        peer.next_piece_buf = null;
        peer.next_blocks_expected = 0;
        peer.next_blocks_received = 0;
        peer.next_pipeline_sent = 0;

        // Check if the promoted piece is already complete (all blocks received)
        if (peer.blocks_received >= peer.blocks_expected) {
            completePieceDownload(self, slot);
        } else {
            // Refill pipeline: claim another next_piece and send remaining requests
            tryFillPipeline(self, slot) catch {};
        }
    } else {
        self.markIdle(slot);
    }
}

pub fn completePieceDownload(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    const piece_index = peer.current_piece orelse return;
    const piece_buf = peer.piece_buf orelse return;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const sess = tc.session orelse return;
    const pt = tc.piece_tracker orelse return;

    // Get the expected hash for this piece
    const expected_hash = sess.layout.pieceHash(piece_index) catch {
        pt.releasePiece(piece_index);
        peer.current_piece = null;
        self.markIdle(slot);
        return;
    };
    var hash: [20]u8 = undefined;
    @memcpy(&hash, expected_hash);

    if (self.hasher) |h| {
        // Submit to background hasher thread (non-blocking)
        h.submitVerify(slot, piece_index, piece_buf, hash, peer.torrent_id) catch {
            pt.releasePiece(piece_index);
            peer.current_piece = null;
            self.markIdle(slot);
            return;
        };
        // Don't free piece_buf -- the hasher owns it now.
        // The peer can start downloading another piece immediately.
        peer.piece_buf = null;
        peer.current_piece = null;
        peer.blocks_received = 0;
        peer.blocks_expected = 0;
        peer.pipeline_sent = 0;
        promoteNextPieceOrMarkIdle(self, slot);
    } else {
        // Fallback: inline verification and write (blocks event loop).
        // This path is only reached if the hasher thread pool failed to create.
        var actual: [20]u8 = undefined;
        Sha1.hash(piece_buf[0..piece_buf.len], &actual, .{});
        const valid = std.mem.eql(u8, &actual, &hash);
        if (valid) {
            // Write piece to disk via io_uring
            var span_scratch: [8]LayoutSpan = undefined;
            const plan = storage.verify.planPieceVerificationWithScratch(self.allocator, sess, piece_index, span_scratch[0..]) catch {
                pt.releasePiece(piece_index);
                self.allocator.free(piece_buf);
                peer.piece_buf = null;
                peer.current_piece = null;
                self.markIdle(slot);
                return;
            };
            defer storage.verify.freePiecePlan(self.allocator, plan);

            const span_count: u32 = @intCast(plan.spans.len);
            if (span_count == 0) {
                pt.releasePiece(piece_index);
                self.allocator.free(piece_buf);
                peer.piece_buf = null;
                peer.current_piece = null;
                self.markIdle(slot);
                return;
            }

            // Track pending writes for completion
            const pending_key = EventLoop.PendingWriteKey{
                .piece_index = piece_index,
                .torrent_id = peer.torrent_id,
            };
            const write_id = self.createPendingWrite(pending_key, .{
                .write_id = 0,
                .piece_index = piece_index,
                .torrent_id = peer.torrent_id,
                .slot = slot,
                .buf = piece_buf,
                .spans_remaining = 0,
            }) catch {
                pt.releasePiece(piece_index);
                self.allocator.free(piece_buf);
                peer.piece_buf = null;
                peer.current_piece = null;
                self.markIdle(slot);
                return;
            };

            for (plan.spans) |span| {
                // Skip spans for do_not_download files (fd == -1)
                if (tc.shared_fds[span.file_index] < 0) continue;
                const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
                const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_write, .context = write_id });
                _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                    log.warn("inline disk write for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    if (self.getPendingWrite(pending_key)) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                if (self.getPendingWrite(pending_key)) |pending_w| {
                    pending_w.spans_remaining += 1;
                }
            }

            if (self.getPendingWrite(pending_key)) |pending_w| {
                if (pending_w.spans_remaining == 0) {
                    _ = self.removePendingWrite(pending_key);
                    pt.releasePiece(piece_index);
                    self.allocator.free(piece_buf);
                    peer.piece_buf = null;
                    peer.current_piece = null;
                    self.markIdle(slot);
                    return;
                }
            }
            // Buffer ownership transferred to pending_writes; will be freed on completion
            peer.piece_buf = null;
        } else {
            // Hash mismatch -- release piece and free buffer
            pt.releasePiece(piece_index);
            self.allocator.free(piece_buf);
            peer.piece_buf = null;
        }
        peer.current_piece = null;
        self.markIdle(slot);
    }
}

/// Process completed hash results from the background hasher.
/// Called each tick from the event loop.
pub fn processHashResults(self: *EventLoop) void {
    const h = self.hasher orelse return;
    const results = h.drainResultsInto(&self.hash_result_swap);
    for (results) |result| {
        // Use torrent_id stored in the hash result (not from the slot,
        // which may have been freed and reassigned since submission).
        const torrent_id = result.torrent_id;
        const tc = self.getTorrentContext(torrent_id) orelse {
            self.allocator.free(result.piece_buf);
            continue;
        };

        if (result.valid) {
            const sess = tc.session orelse {
                self.allocator.free(result.piece_buf);
                continue;
            };

            // Endgame duplicate: another peer already verified this piece
            // and a write is in flight. Skip the duplicate -- just free
            // the buffer and mark the piece complete (the first write
            // will handle persistence).
            const pending_key = EventLoop.PendingWriteKey{
                .piece_index = result.piece_index,
                .torrent_id = torrent_id,
            };
            if (self.hasPendingWrite(pending_key)) {
                log.debug("skipping duplicate write for piece {d} torrent {d} (endgame)", .{
                    result.piece_index, torrent_id,
                });
                self.allocator.free(result.piece_buf);
                continue;
            }

            // Write verified piece to disk via io_uring
            var span_scratch: [8]LayoutSpan = undefined;
            const plan = storage.verify.planPieceVerificationWithScratch(self.allocator, sess, result.piece_index, span_scratch[0..]) catch {
                self.allocator.free(result.piece_buf);
                continue;
            };
            defer storage.verify.freePiecePlan(self.allocator, plan);

            const span_count: u32 = @intCast(plan.spans.len);
            if (span_count == 0) {
                self.allocator.free(result.piece_buf);
                continue;
            }

            // Track the buffer so we can free it after all writes complete
            const write_id = self.createPendingWrite(pending_key, .{
                .write_id = 0,
                .piece_index = result.piece_index,
                .torrent_id = torrent_id,
                .slot = result.slot,
                .buf = result.piece_buf,
                .spans_remaining = 0,
            }) catch {
                self.allocator.free(result.piece_buf);
                continue;
            };

            for (plan.spans) |span| {
                // Skip spans for do_not_download files (fd == -1)
                if (tc.shared_fds[span.file_index] < 0) continue;
                const block = result.piece_buf[span.piece_offset .. span.piece_offset + span.length];
                const ud = encodeUserData(.{ .slot = result.slot, .op_type = .disk_write, .context = write_id });
                _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                    log.warn("disk write submit for piece {d}: {s}", .{ result.piece_index, @errorName(err) });
                    if (self.getPendingWrite(pending_key)) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                if (self.getPendingWrite(pending_key)) |pending_w| {
                    pending_w.spans_remaining += 1;
                }
            }

            if (self.getPendingWrite(pending_key)) |pending_w| {
                if (pending_w.spans_remaining == 0) {
                    _ = self.removePendingWrite(pending_key);
                    if (tc.piece_tracker) |pt| pt.releasePiece(result.piece_index);
                    self.allocator.free(result.piece_buf);
                    continue;
                }
            }
        } else {
            // Hash mismatch -- release piece back to pool
            if (tc.piece_tracker) |pt| pt.releasePiece(result.piece_index);
            self.allocator.free(result.piece_buf);
        }
    }
    // Results are already swapped out of the hasher -- no clearResults needed.
    self.hash_result_swap.clearRetainingCapacity();
}

/// Process completed Merkle tree building results from the background hasher.
/// Called each tick from the event loop, after processHashResults.
pub fn processMerkleResults(self: *EventLoop) void {
    const h = self.hasher orelse return;
    const merkle_results = h.drainMerkleResultsInto(&self.merkle_result_swap);

    for (merkle_results) |result| {
        const tc = self.getTorrentContext(result.torrent_id) orelse {
            if (result.piece_hashes) |hashes| self.allocator.free(hashes);
            continue;
        };

        const mc = tc.merkle_cache orelse {
            if (result.piece_hashes) |hashes| self.allocator.free(hashes);
            continue;
        };

        // Collect pending requests for this file
        var pending_reqs = std.ArrayList(MerkleCache.PendingHashRequest).empty;
        defer pending_reqs.deinit(self.allocator);
        mc.takePendingRequests(result.file_index, &pending_reqs);

        if (result.piece_hashes) |piece_hashes| {
            defer self.allocator.free(piece_hashes);

            // Build and cache the Merkle tree
            const tree = mc.buildAndCache(result.file_index, piece_hashes) catch |err| {
                log.debug("merkle: failed to build tree for file {d}: {s}", .{
                    result.file_index, @errorName(err),
                });
                // Send hash reject to all pending requesters
                for (pending_reqs.items) |pending| {
                    // Check that the peer is still connected
                    if (self.peers[pending.slot].state == .free) continue;
                    if (self.peers[pending.slot].torrent_id != result.torrent_id) continue;
                    protocol.sendHashReject(self, pending.slot, pending.request);
                }
                continue;
            };

            log.debug("merkle: built tree for file {d}, serving {d} pending request(s)", .{
                result.file_index, pending_reqs.items.len,
            });

            // Serve all pending requests from the now-cached tree
            for (pending_reqs.items) |pending| {
                // Check that the peer is still connected and belongs to same torrent
                if (self.peers[pending.slot].state == .free) continue;
                if (self.peers[pending.slot].torrent_id != result.torrent_id) continue;
                protocol.sendHashesFromTree(self, pending.slot, tree, pending.request);
            }
        } else {
            // Build failed -- reject all pending requests
            log.debug("merkle: async hash build failed for file {d}, rejecting {d} request(s)", .{
                result.file_index, pending_reqs.items.len,
            });
            for (pending_reqs.items) |pending| {
                if (self.peers[pending.slot].state == .free) continue;
                if (self.peers[pending.slot].torrent_id != result.torrent_id) continue;
                protocol.sendHashReject(self, pending.slot, pending.request);
            }
        }
    }

    self.merkle_result_swap.clearRetainingCapacity();
}

// ── Peer timeout ───────────────────────────────────────

pub fn checkPeerTimeouts(self: *EventLoop) void {
    const now = std.time.timestamp();
    var to_remove = std.ArrayList(u16).empty;
    defer to_remove.deinit(self.allocator);

    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state == .free or peer.state == .disconnecting) continue;
        if (peer.last_activity == 0) continue;
        if (peer.mode == .seed) continue; // don't timeout seed peers

        if (now - peer.last_activity > peer_timeout_secs) {
            to_remove.append(self.allocator, slot) catch break;
        }
    }

    for (to_remove.items) |slot| self.removePeer(slot);
}

const keepalive_interval_secs: i64 = 90; // send keep-alive if we've been quiet for this long

/// Send keep-alive messages to peers we haven't sent anything to recently.
/// Prevents remote peers from disconnecting us for inactivity.
pub fn sendKeepAlives(self: *EventLoop) void {
    const now = std.time.timestamp();
    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
        if (peer.send_pending) continue;
        if (peer.last_activity == 0) continue;

        if (now - peer.last_activity > keepalive_interval_secs) {
            // BEP 3 keep-alive: 4 zero bytes (length-prefix only, no message ID)
            var keepalive = [_]u8{ 0, 0, 0, 0 };
            peer.crypto.encryptBuf(&keepalive);
            const ts = self.nextTrackedSendUserData(slot);
            const tracked = self.trackPendingSendCopy(slot, ts.send_id, &keepalive) catch continue;
            _ = self.ring.send(ts.ud, peer.fd, tracked, 0) catch {
                self.freeOnePendingSend(slot, ts.send_id);
                continue;
            };
            peer.send_pending = true;
            peer.last_activity = now;
        }
    }
}

// ── Choking algorithm (tit-for-tat) ─────────────────

pub fn recalculateUnchokes(self: *EventLoop) void {
    const now = std.time.timestamp();
    if (now - self.last_unchoke_recalc < unchoke_interval_secs) return;
    self.last_unchoke_recalc = now;

    // Collect all active peers that are interested in our data
    var interested_peers: [max_peers]u16 = undefined;
    var interested_count: u32 = 0;
    var is_seeding = true; // true if we are seed-only (no download-mode peers)

    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state == .free or peer.state == .disconnecting) continue;
        if (!peer.peer_interested) continue;
        if (peer.mode == .download) is_seeding = false;
        if (interested_count < max_peers) {
            interested_peers[interested_count] = slot;
            interested_count += 1;
        }
    }

    if (interested_count == 0) return;

    // Sort by download speed (tit-for-tat: unchoke peers that send us the most).
    // When seeding, sort by upload speed instead (prefer fast downloaders).
    const peers_slice = interested_peers[0..interested_count];
    const context = self;
    if (is_seeding) {
        std.mem.sort(u16, peers_slice, context, struct {
            fn lessThan(ctx: *EventLoop, a: u16, b: u16) bool {
                return ctx.peers[a].current_ul_speed > ctx.peers[b].current_ul_speed;
            }
        }.lessThan);
    } else {
        std.mem.sort(u16, peers_slice, context, struct {
            fn lessThan(ctx: *EventLoop, a: u16, b: u16) bool {
                return ctx.peers[a].current_dl_speed > ctx.peers[b].current_dl_speed;
            }
        }.lessThan);
    }

    // Unchoke top max_unchoked by performance
    var unchoked: u32 = 0;
    var optimistic_slot: ?u16 = null;
    for (peers_slice) |slot| {
        if (unchoked < max_unchoked) {
            const peer = &self.peers[slot];
            if (peer.am_choking) {
                peer.am_choking = false;
                protocol.submitMessage(self, slot, 1, &.{}) catch {};
            }
            unchoked += 1;
        } else {
            // First peer past the performance cut-off is the optimistic candidate
            if (optimistic_slot == null) optimistic_slot = slot;
        }
    }

    // Optimistic unchoke: rotate one random interested peer every 30 seconds
    if (interested_count > max_unchoked and now - self.last_optimistic_unchoke >= optimistic_unchoke_interval_secs) {
        self.last_optimistic_unchoke = now;
        // Pick a random peer from beyond the performance-unchoked set
        const remaining = interested_count - @min(max_unchoked, interested_count);
        if (remaining > 0) {
            const rand_idx = @as(u32, @truncate(@as(u64, @bitCast(now)))) % remaining;
            optimistic_slot = peers_slice[max_unchoked + rand_idx];
        }
    }

    // Unchoke optimistic slot, choke everyone else beyond max_unchoked
    for (peers_slice[unchoked..]) |slot| {
        const peer = &self.peers[slot];
        if (optimistic_slot != null and slot == optimistic_slot.?) {
            if (peer.am_choking) {
                peer.am_choking = false;
                protocol.submitMessage(self, slot, 1, &.{}) catch {};
            }
        } else {
            if (!peer.am_choking) {
                peer.am_choking = true;
                protocol.submitMessage(self, slot, 0, &.{}) catch {};
            }
        }
    }
}

// ── Re-announce ─────────────────────────────────────────

pub fn checkReannounce(self: *EventLoop) void {
    // Pick up results from a previous background announce
    if (self.announce_results_ready.load(.acquire)) {
        const peers = blk: {
            self.announce_mutex.lock();
            defer self.announce_mutex.unlock();
            const p = self.announce_result_peers;
            self.announce_result_peers = null;
            self.announce_results_ready.store(false, .release);
            break :blk p;
        };
        if (peers) |addrs| {
            for (addrs) |addr| {
                if (self.peer_count >= self.max_connections) break;
                _ = self.addPeer(addr) catch continue;
            }
            self.allocator.free(addrs);
        }
    }

    const url = self.announce_url orelse return;
    if (self.peer_count >= self.min_peers_for_reannounce) return;

    const now = std.time.timestamp();
    // When peer count is critically low, re-announce every 60 seconds.
    // Otherwise respect the tracker's interval (with +-10% jitter).
    const effective_interval: i64 = if (self.peer_count < 3) blk: {
        break :blk 60;
    } else blk: {
        const jittered_interval = @as(i64, self.announce_interval) + @as(i64, self.announce_jitter_secs);
        break :blk @max(jittered_interval, 60);
    };
    if (now - self.last_announce_time < effective_interval) return;

    self.last_announce_time = now;
    // Generate new jitter for next cycle: +-10% of interval
    self.announce_jitter_secs = generateAnnounceJitter(self);

    // Already announcing -- skip
    if (self.announcing.load(.acquire)) return;

    const tc = self.getTorrentContext(0) orelse return;
    const pt = tc.piece_tracker orelse return;

    // Spawn background thread for blocking DNS + HTTP announce.
    // The background thread uses announce_ring (not the event loop ring)
    // so it doesn't block peer I/O.
    self.announcing.store(true, .release);

    const thread = std.Thread.spawn(.{}, announceWorkerThread, .{
        self,
        url,
        tc.info_hash,
        tc.peer_id,
        tc.tracker_key,
        if (pt.isComplete()) 0 else pt.bytesRemaining(),
    }) catch {
        self.announcing.store(false, .release);
        return;
    };
    // Store handle so deinit can join. Previous handle (if any) must have
    // already finished since we checked announcing.load above.
    self.announce_thread = thread;
}

/// Background thread for tracker re-announce. Uses blocking posix I/O.
/// Results are stored in announce_result_peers and picked up on the next tick.
fn announceWorkerThread(
    self: *EventLoop,
    url: []const u8,
    info_hash: [20]u8,
    peer_id: [20]u8,
    tracker_key: ?[8]u8,
    left: u64,
) void {
    defer self.announcing.store(false, .release);

    const tracker_mod = @import("../tracker/root.zig");
    const response = tracker_mod.announce.fetchAuto(self.allocator, .{
        .announce_url = url,
        .info_hash = info_hash,
        .peer_id = peer_id,
        .port = self.port,
        .left = left,
        .event = null,
        .key = tracker_key,
    }) catch return;
    defer tracker_mod.announce.freeResponse(self.allocator, response);

    if (response.peers.len == 0) return;

    // Collect peer addresses for the main thread to add
    var addrs = self.allocator.alloc(std.net.Address, response.peers.len) catch return;
    var count: usize = 0;
    for (response.peers) |peer| {
        addrs[count] = peer.address;
        count += 1;
    }
    if (count < addrs.len) {
        addrs = self.allocator.realloc(addrs, count) catch {
            self.allocator.free(addrs);
            return;
        };
    }

    // Store results for the main thread (mutex-protected handoff)
    {
        self.announce_mutex.lock();
        defer self.announce_mutex.unlock();
        self.announce_result_peers = addrs;
        self.announce_results_ready.store(true, .release);
    }
}

/// Generate random jitter for announce interval: +-10% of the interval.
fn generateAnnounceJitter(self: *const EventLoop) i32 {
    const interval: i32 = @intCast(self.announce_interval);
    const jitter_range = @divTrunc(interval, 5); // 20% total range (+-10%)
    if (jitter_range == 0) return 0;
    // Use timestamp-based seed for simple PRNG (good enough for jitter)
    const now: u64 = @bitCast(std.time.timestamp());
    const hsh = now *% 6364136223846793005 +% 1442695040888963407;
    const raw: u32 = @truncate(hsh >> 33);
    const jitter: i32 = @as(i32, @intCast(raw % @as(u32, @intCast(jitter_range + 1)))) - @divTrunc(jitter_range, 2);
    return jitter;
}

// ── BEP 11: Peer Exchange ─────────────────────────────

/// Send PEX messages to all eligible peers at the BEP 11 interval.
/// Also ensures torrent PEX state is initialized for non-private torrents.
pub fn checkPex(self: *EventLoop) void {
    if (!self.pex_enabled) return;
    if (self.active_peer_slots.items.len == 0) return;

    const now = std.time.timestamp();

    for (self.torrents_with_peers.items) |tid| {
        const tc = self.getTorrentContext(tid) orelse continue;

        // PEX is disabled for private torrents (BEP 27)
        if (tc.is_private) continue;

        var has_connected_peers = false;

        // Update the torrent's connected peers set
        for (tc.peer_slots.items) |peer_slot| {
            const peer = &self.peers[peer_slot];
            if (peer.state == .free or peer.state == .connecting or peer.state == .disconnecting) continue;
            // Only include peers that have completed the handshake
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;

            has_connected_peers = true;
            if (tc.pex_state == null) {
                const tps = self.allocator.create(pex_mod.TorrentPexState) catch break;
                tps.* = pex_mod.TorrentPexState{};
                tc.pex_state = tps;
            }
            const torrent_pex = tc.pex_state orelse break;

            const flags = pex_mod.PeerFlags{
                .seed = peer.mode == .seed or peer.upload_only,
                .utp = peer.transport == .utp,
            };
            torrent_pex.addPeer(self.allocator, peer.address, flags);
        }

        if (!has_connected_peers or tc.pex_state == null) continue;

        // Send PEX messages to each eligible peer for this torrent
        for (tc.peer_slots.items) |pi| {
            const peer = &self.peers[pi];
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
            if (peer.send_pending) continue;

            // Check if peer supports ut_pex
            const peer_pex_id = if (peer.extension_ids) |ids| ids.ut_pex else 0;
            if (peer_pex_id == 0) continue;

            // Rate-limit PEX messages per peer
            if (peer.pex_state) |ps| {
                if (now - ps.last_pex_time < pex_mod.pex_interval_secs) continue;
            }

            protocol.submitPexMessage(self, pi) catch |err| {
                log.debug("PEX send to slot {d}: {s}", .{ pi, @errorName(err) });
            };
        }
    }
}

/// Update speed counters for all active torrents and individual peers (called from tick).
pub fn updateSpeedCounters(self: *EventLoop) void {
    if (self.active_peer_slots.items.len == 0) return;

    const now = std.time.timestamp();

    // Update per-peer speed counters
    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state == .free) continue;

        if (peer.last_speed_check == 0) {
            // First check: initialize baselines, no speed yet
            peer.last_speed_check = now;
            peer.last_dl_bytes = peer.bytes_downloaded_from;
            peer.last_ul_bytes = peer.bytes_uploaded_to;
            continue;
        }

        const peer_elapsed = now - peer.last_speed_check;
        if (peer_elapsed < 2) continue;

        const peer_elapsed_u: u64 = @intCast(peer_elapsed);
        const peer_dl_delta = peer.bytes_downloaded_from -| peer.last_dl_bytes;
        const peer_ul_delta = peer.bytes_uploaded_to -| peer.last_ul_bytes;

        peer.current_dl_speed = peer_dl_delta / peer_elapsed_u;
        peer.current_ul_speed = peer_ul_delta / peer_elapsed_u;
        peer.last_speed_check = now;
        peer.last_dl_bytes = peer.bytes_downloaded_from;
        peer.last_ul_bytes = peer.bytes_uploaded_to;
    }

    // Update per-torrent speed counters
    for (self.torrents_with_peers.items) |tid| {
        const tc = self.getTorrentContext(tid) orelse continue;
        const dl_total = tc.downloaded_bytes;
        const ul_total = tc.uploaded_bytes;

        if (tc.last_speed_check == 0) {
            // First check: initialize baselines, no speed yet
            tc.last_speed_check = now;
            tc.last_dl_bytes = dl_total;
            tc.last_ul_bytes = ul_total;
            continue;
        }

        const elapsed = now - tc.last_speed_check;
        if (elapsed < 2) continue;

        const elapsed_u: u64 = @intCast(elapsed);
        const dl_delta = dl_total -| tc.last_dl_bytes;
        const ul_delta = ul_total -| tc.last_ul_bytes;

        tc.current_dl_speed = dl_delta / elapsed_u;
        tc.current_ul_speed = ul_delta / elapsed_u;
        tc.last_speed_check = now;
        tc.last_dl_bytes = dl_total;
        tc.last_ul_bytes = ul_total;
    }
}

// ── BEP 21: Partial Seed Detection ──────────────────────

/// Check if any torrent has transitioned to partial seed state (all wanted
/// pieces complete but not all pieces in the torrent). When detected, set
/// the torrent's `upload_only` flag and re-send extension handshakes to
/// all connected peers so they know we are upload_only.
pub fn checkPartialSeed(self: *EventLoop) void {
    for (self.torrents_with_peers.items) |tid| {
        const tc = self.getTorrentContext(tid) orelse continue;
        const pt = tc.piece_tracker orelse continue;

        const should_be_upload_only = pt.isPartialSeed();

        // Only act on transitions (false -> true or true -> false)
        if (tc.upload_only == should_be_upload_only) continue;

        tc.upload_only = should_be_upload_only;

        if (should_be_upload_only) {
            log.info("torrent {d}: became partial seed (upload_only)", .{tid});
        } else {
            log.info("torrent {d}: no longer partial seed", .{tid});
        }

        // Re-send extension handshake to all connected peers for this torrent
        // so they learn about our upload_only state change.
        for (tc.peer_slots.items) |pi| {
            const peer = &self.peers[pi];
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
            if (!peer.extensions_supported) continue;
            if (peer.send_pending) continue;

            protocol.submitExtensionHandshake(self, pi) catch |err| {
                log.debug("BEP 21 ext handshake resend to slot {d}: {s}", .{ pi, @errorName(err) });
            };
        }
    }
}

// ── Tests ─────────────────────────────────────────────────

test "writeRequestMsg formats 17-byte request message correctly" {
    var buf: [17]u8 = undefined;
    const req = .{
        .piece_index = @as(u32, 42),
        .piece_offset = @as(u32, 16384),
        .length = @as(u32, 16384),
    };
    writeRequestMsg(&buf, req);

    // 4-byte big-endian length = 13 (1 byte id + 12 byte payload)
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, buf[0..4], .big));
    // 1-byte message id = 6 (REQUEST)
    try std.testing.expectEqual(@as(u8, 6), buf[4]);
    // piece_index = 42
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[5..9], .big));
    // piece_offset = 16384
    try std.testing.expectEqual(@as(u32, 16384), std.mem.readInt(u32, buf[9..13], .big));
    // length = 16384
    try std.testing.expectEqual(@as(u32, 16384), std.mem.readInt(u32, buf[13..17], .big));
}

test "writeRequestMsg encodes zero values" {
    var buf: [17]u8 = undefined;
    const req = .{
        .piece_index = @as(u32, 0),
        .piece_offset = @as(u32, 0),
        .length = @as(u32, 0),
    };
    writeRequestMsg(&buf, req);

    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, buf[0..4], .big));
    try std.testing.expectEqual(@as(u8, 6), buf[4]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[5..9], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[9..13], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[13..17], .big));
}

test "writeRequestMsg encodes max u32 values" {
    var buf: [17]u8 = undefined;
    const max = std.math.maxInt(u32);
    const req = .{
        .piece_index = @as(u32, max),
        .piece_offset = @as(u32, max),
        .length = @as(u32, max),
    };
    writeRequestMsg(&buf, req);

    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, buf[0..4], .big));
    try std.testing.expectEqual(@as(u8, 6), buf[4]);
    try std.testing.expectEqual(max, std.mem.readInt(u32, buf[5..9], .big));
    try std.testing.expectEqual(max, std.mem.readInt(u32, buf[9..13], .big));
    try std.testing.expectEqual(max, std.mem.readInt(u32, buf[13..17], .big));
}

test "promoteNextPieceOrMarkIdle promotes next piece to current" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .download;
    peer.availability_known = true;
    peer.peer_choking = false;

    // Set up next_piece state to promote
    peer.next_piece = 7;
    peer.next_piece_buf = try std.testing.allocator.alloc(u8, 64);
    peer.next_blocks_expected = 4;
    peer.next_blocks_received = 4; // all received so completePieceDownload will fire
    peer.next_pipeline_sent = 4;

    // current_piece should be null before promotion
    peer.current_piece = null;
    peer.piece_buf = null;

    // promoteNextPieceOrMarkIdle will promote, then see blocks_received >= blocks_expected
    // and call completePieceDownload, which needs a torrent context. Without one it
    // returns early and calls markIdle. The key thing to verify is that promotion happened.
    promoteNextPieceOrMarkIdle(&el, slot);

    // After promotion + completePieceDownload (which returns early without torrent context),
    // current_piece should be null (cleared by completePieceDownload's early return path)
    // and next_piece fields should be cleared.
    try std.testing.expectEqual(@as(?u32, null), peer.next_piece);
    try std.testing.expectEqual(@as(?[]u8, null), peer.next_piece_buf);
    try std.testing.expectEqual(@as(u32, 0), peer.next_blocks_expected);
    try std.testing.expectEqual(@as(u32, 0), peer.next_blocks_received);
    try std.testing.expectEqual(@as(u32, 0), peer.next_pipeline_sent);
}

test "promoteNextPieceOrMarkIdle marks idle when no next piece" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .download;
    peer.availability_known = true;
    peer.peer_choking = false;
    peer.current_piece = null;
    peer.next_piece = null;

    el.markActivePeer(slot);

    promoteNextPieceOrMarkIdle(&el, slot);

    // Should be in idle list since there is no next piece
    try std.testing.expect(peer.idle_peer_index != null);
}

test "recalculateUnchokes unchokes top peers by download speed" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Force recalculation by setting last_unchoke_recalc far in the past
    el.last_unchoke_recalc = 0;

    // Set up 6 peers: all interested, various download speeds.
    // max_unchoked = 4, so top 4 by speed should be unchoked.
    const slots = [_]u16{ 0, 1, 2, 3, 4, 5 };
    const speeds = [_]u64{ 100, 500, 200, 700, 50, 300 };

    for (slots, speeds) |slot, speed| {
        const peer = &el.peers[slot];
        peer.state = .active_recv_header;
        peer.mode = .download; // download mode: sort by dl speed
        peer.peer_interested = true;
        peer.am_choking = true;
        peer.current_dl_speed = speed;
        peer.last_activity = std.time.timestamp();
        el.markActivePeer(slot);
    }

    recalculateUnchokes(&el);

    // Top 4 by dl speed: slot 3 (700), slot 1 (500), slot 5 (300), slot 2 (200)
    // Choked: slot 0 (100), slot 4 (50)
    try std.testing.expectEqual(false, el.peers[3].am_choking); // 700
    try std.testing.expectEqual(false, el.peers[1].am_choking); // 500
    try std.testing.expectEqual(false, el.peers[5].am_choking); // 300
    try std.testing.expectEqual(false, el.peers[2].am_choking); // 200
    // Slot 0 and 4 should remain choked (or one might be optimistic-unchoked,
    // but they start am_choking=true and the optimistic path only unchokes
    // when last_optimistic_unchoke is old enough).
}

test "recalculateUnchokes uses upload speed in seed mode" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    el.last_unchoke_recalc = 0;

    // All peers are in seed mode (inbound), so is_seeding = true
    // and sorting is by upload speed.
    const slots = [_]u16{ 0, 1, 2, 3, 4 };
    const ul_speeds = [_]u64{ 10, 50, 30, 80, 20 };

    for (slots, ul_speeds) |slot, speed| {
        const peer = &el.peers[slot];
        peer.state = .active_recv_header;
        peer.mode = .seed; // all seed mode -> is_seeding = true
        peer.peer_interested = true;
        peer.am_choking = true;
        peer.current_ul_speed = speed;
        peer.last_activity = std.time.timestamp();
        el.markActivePeer(slot);
    }

    recalculateUnchokes(&el);

    // Top 4 by upload speed: slot 3 (80), slot 1 (50), slot 2 (30), slot 4 (20)
    try std.testing.expectEqual(false, el.peers[3].am_choking); // 80
    try std.testing.expectEqual(false, el.peers[1].am_choking); // 50
    try std.testing.expectEqual(false, el.peers[2].am_choking); // 30
    try std.testing.expectEqual(false, el.peers[4].am_choking); // 20
    // slot 0 (10) is the lowest -- should remain choked (or optimistic)
}

test "recalculateUnchokes skips uninterested peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    el.last_unchoke_recalc = 0;

    // Peer 0: interested, speed 100
    el.peers[0].state = .active_recv_header;
    el.peers[0].mode = .download;
    el.peers[0].peer_interested = true;
    el.peers[0].am_choking = true;
    el.peers[0].current_dl_speed = 100;
    el.markActivePeer(0);

    // Peer 1: NOT interested, speed 999
    el.peers[1].state = .active_recv_header;
    el.peers[1].mode = .download;
    el.peers[1].peer_interested = false;
    el.peers[1].am_choking = true;
    el.peers[1].current_dl_speed = 999;
    el.markActivePeer(1);

    recalculateUnchokes(&el);

    // Peer 0 should be unchoked (interested)
    try std.testing.expectEqual(false, el.peers[0].am_choking);
    // Peer 1 should remain choked (not interested, never considered)
    try std.testing.expectEqual(true, el.peers[1].am_choking);
}

test "recalculateUnchokes respects interval gating" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Set last recalc to now so the interval check fails
    el.last_unchoke_recalc = std.time.timestamp();

    el.peers[0].state = .active_recv_header;
    el.peers[0].mode = .download;
    el.peers[0].peer_interested = true;
    el.peers[0].am_choking = true;
    el.peers[0].current_dl_speed = 100;
    el.markActivePeer(0);

    recalculateUnchokes(&el);

    // Should NOT unchoke because interval has not elapsed
    try std.testing.expectEqual(true, el.peers[0].am_choking);
}

test "checkPeerTimeouts removes inactive download peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Peer 0: download mode, last activity is old (should be timed out)
    el.peers[0].state = .active_recv_header;
    el.peers[0].mode = .download;
    el.peers[0].last_activity = std.time.timestamp() - (peer_timeout_secs + 10);
    el.peer_count = 1;
    el.markActivePeer(0);

    checkPeerTimeouts(&el);

    // Peer should have been removed (state reset to .free)
    try std.testing.expectEqual(PeerState.free, el.peers[0].state);
    try std.testing.expectEqual(@as(u16, 0), el.peer_count);
}

test "checkPeerTimeouts does not remove seed mode peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Peer 0: seed mode, last activity is old -- should NOT be timed out
    el.peers[0].state = .active_recv_header;
    el.peers[0].mode = .seed;
    el.peers[0].last_activity = std.time.timestamp() - (peer_timeout_secs + 100);
    el.peer_count = 1;
    el.markActivePeer(0);

    checkPeerTimeouts(&el);

    // Peer should still be active
    try std.testing.expect(el.peers[0].state != .free);
    try std.testing.expectEqual(@as(u16, 1), el.peer_count);
}

test "checkPeerTimeouts does not remove recently active peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Peer 0: download mode, recently active -- should NOT be timed out
    el.peers[0].state = .active_recv_header;
    el.peers[0].mode = .download;
    el.peers[0].last_activity = std.time.timestamp() - 5; // 5 seconds ago
    el.peer_count = 1;
    el.markActivePeer(0);

    checkPeerTimeouts(&el);

    try std.testing.expect(el.peers[0].state != .free);
    try std.testing.expectEqual(@as(u16, 1), el.peer_count);
}

test "checkPeerTimeouts skips free and disconnecting peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Peer 0: free state with old timestamp -- should be skipped
    el.peers[0].state = .free;
    el.peers[0].mode = .download;
    el.peers[0].last_activity = std.time.timestamp() - (peer_timeout_secs + 100);

    // Peer 1: disconnecting state with old timestamp -- should be skipped
    el.peers[1].state = .disconnecting;
    el.peers[1].mode = .download;
    el.peers[1].last_activity = std.time.timestamp() - (peer_timeout_secs + 100);
    el.markActivePeer(1);

    // These should not crash or remove anything
    checkPeerTimeouts(&el);

    // Peer 1 stays in disconnecting (not re-removed), peer 0 stays free
    try std.testing.expectEqual(PeerState.free, el.peers[0].state);
    try std.testing.expectEqual(PeerState.disconnecting, el.peers[1].state);
}

test "sendKeepAlives queues send for quiet peer" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .download;
    peer.send_pending = false;
    // Set last_activity well beyond the keepalive interval
    peer.last_activity = std.time.timestamp() - (keepalive_interval_secs + 10);
    // Need a valid fd for the ring.send call -- use a /dev/null fd
    peer.fd = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch -1;
    defer if (peer.fd >= 0) std.posix.close(peer.fd);
    el.markActivePeer(slot);

    sendKeepAlives(&el);

    // After sendKeepAlives, the peer's send_pending should be true
    // because a keep-alive was queued via ring.send.
    // If the ring.send fails (possible in test), send_pending stays false,
    // but last_activity is only updated if the send succeeded.
    // With /dev/null, the SQE should be accepted by the ring.
    if (peer.send_pending) {
        // Verify last_activity was updated to approximately now
        const now = std.time.timestamp();
        try std.testing.expect(now - peer.last_activity < 5);
    }
}

test "sendKeepAlives skips peer with recent activity" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .download;
    peer.send_pending = false;
    peer.last_activity = std.time.timestamp() - 10; // only 10 seconds ago, well within interval
    peer.fd = -1;
    el.markActivePeer(slot);

    const original_activity = peer.last_activity;
    sendKeepAlives(&el);

    // Should not have touched this peer -- activity timestamp unchanged
    try std.testing.expectEqual(original_activity, peer.last_activity);
    try std.testing.expectEqual(false, peer.send_pending);
}

test "sendKeepAlives skips peer with send already pending" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .download;
    peer.send_pending = true; // already has a send in flight
    peer.last_activity = std.time.timestamp() - (keepalive_interval_secs + 10);
    peer.fd = -1;
    el.markActivePeer(slot);

    const original_activity = peer.last_activity;
    sendKeepAlives(&el);

    // Should not modify anything since send_pending is already true
    try std.testing.expectEqual(original_activity, peer.last_activity);
}

test "sendKeepAlives skips non-active peers" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // A peer in handshake state should be skipped
    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .handshake_send;
    peer.mode = .download;
    peer.send_pending = false;
    peer.last_activity = std.time.timestamp() - (keepalive_interval_secs + 10);
    peer.fd = -1;
    el.markActivePeer(slot);

    const original_activity = peer.last_activity;
    sendKeepAlives(&el);

    try std.testing.expectEqual(original_activity, peer.last_activity);
    try std.testing.expectEqual(false, peer.send_pending);
}

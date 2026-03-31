const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const Sha1 = @import("../crypto/sha1.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const pex_mod = @import("../net/pex.zig");
const storage = @import("../storage/root.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const Peer = @import("event_loop.zig").Peer;
const TorrentContext = @import("event_loop.zig").TorrentContext;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const max_peers = @import("event_loop.zig").max_peers;
const protocol = @import("protocol.zig");
const MerkleCache = @import("../torrent/merkle_cache.zig").MerkleCache;
const Hasher = @import("hasher.zig").Hasher;

const pipeline_depth: u32 = 5;
const peer_timeout_secs: i64 = 60;
const unchoke_interval_secs: i64 = 30;
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
            _ = self.idle_peers.swapRemove(i);
            continue;
        }

        // Skip piece assignment when download is throttled
        if (self.isDownloadThrottled(peer.torrent_id)) {
            i += 1;
            continue;
        }

        const tc = self.getTorrentContext(peer.torrent_id) orelse {
            _ = self.idle_peers.swapRemove(i);
            continue;
        };

        // BEP 21: when we are a partial seed (upload_only), don't request pieces
        if (tc.upload_only) {
            i += 1;
            continue;
        }

        const pt = tc.piece_tracker orelse {
            _ = self.idle_peers.swapRemove(i);
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
        _ = self.idle_peers.swapRemove(i);
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
    peer.blocks_received = 0;
    peer.blocks_expected = block_count;
    peer.pipeline_sent = 0;
    peer.inflight_requests = 0;

    try tryFillPipeline(self, slot);
}

pub fn tryFillPipeline(self: *EventLoop, slot: u16) !void {
    const peer = &self.peers[slot];
    const piece_index = peer.current_piece orelse return;
    if (peer.peer_choking) return;
    if (peer.send_pending) return;

    // Skip filling pipeline when download is throttled
    if (self.isDownloadThrottled(peer.torrent_id)) return;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const sess = tc.session orelse return;
    const geometry = sess.geometry();

    // Count how many requests to send
    var to_send: u32 = 0;
    while (peer.inflight_requests + to_send < pipeline_depth and peer.pipeline_sent + to_send < peer.blocks_expected) {
        to_send += 1;
    }
    if (to_send == 0) return;

    // Build all requests into one buffer (17 bytes each: 4 len + 1 id + 12 payload)
    const request_size: usize = 17;
    const total_len = request_size * to_send;
    const send_buf = self.allocator.alloc(u8, total_len) catch return;

    var i: u32 = 0;
    while (i < to_send) : (i += 1) {
        const req = geometry.requestForBlock(piece_index, peer.pipeline_sent + i) catch {
            self.allocator.free(send_buf);
            return;
        };
        const offset = i * request_size;
        // 4-byte length prefix
        std.mem.writeInt(u32, send_buf[offset..][0..4], 13, .big); // 1 + 12
        send_buf[offset + 4] = 6; // request message id
        std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], req.piece_index, .big);
        std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], req.piece_offset, .big);
        std.mem.writeInt(u32, send_buf[offset + 13 ..][0..4], req.length, .big);
    }

    // Track for cleanup with unique send_id
    const ts = self.nextTrackedSendUserData(slot);
    self.pending_sends.append(self.allocator, .{ .buf = send_buf, .slot = slot, .send_id = ts.send_id }) catch {
        self.allocator.free(send_buf);
        return;
    };

    _ = self.ring.send(ts.ud, peer.fd, send_buf, 0) catch {
        self.allocator.free(send_buf);
        return;
    };
    peer.send_pending = true;
    peer.pipeline_sent += to_send;
    peer.inflight_requests += to_send;
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
        self.markIdle(slot);
    } else {
        // Fallback: inline verification and write (blocks event loop).
        // This path is only reached if the hasher thread pool failed to create.
        var actual: [20]u8 = undefined;
        Sha1.hash(piece_buf[0..piece_buf.len], &actual, .{});
        const valid = std.mem.eql(u8, &actual, &hash);
        if (valid) {
            // Write piece to disk via io_uring
            const plan = storage.verify.planPieceVerification(self.allocator, sess, piece_index) catch {
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
            self.pending_writes.put(self.allocator, .{
                .piece_index = piece_index,
                .torrent_id = peer.torrent_id,
            }, .{
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
                const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
                const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_write, .context = @as(u40, @intCast(peer.torrent_id)) << 32 | @as(u40, piece_index) });
                _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                    log.warn("inline disk write for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    if (self.pending_writes.getPtr(.{ .piece_index = piece_index, .torrent_id = peer.torrent_id })) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                if (self.pending_writes.getPtr(.{ .piece_index = piece_index, .torrent_id = peer.torrent_id })) |pending_w| {
                    pending_w.spans_remaining += 1;
                }
            }

            if (self.pending_writes.getPtr(.{ .piece_index = piece_index, .torrent_id = peer.torrent_id })) |pending_w| {
                if (pending_w.spans_remaining == 0) {
                    _ = self.pending_writes.remove(.{ .piece_index = piece_index, .torrent_id = peer.torrent_id });
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
            if (self.pending_writes.contains(pending_key)) {
                log.debug("skipping duplicate write for piece {d} torrent {d} (endgame)", .{
                    result.piece_index, torrent_id,
                });
                self.allocator.free(result.piece_buf);
                continue;
            }

            // Write verified piece to disk via io_uring
            const plan = storage.verify.planPieceVerification(self.allocator, sess, result.piece_index) catch {
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
            self.pending_writes.put(self.allocator, .{
                .piece_index = result.piece_index,
                .torrent_id = torrent_id,
            }, .{
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
                const block = result.piece_buf[span.piece_offset .. span.piece_offset + span.length];
                const ud = encodeUserData(.{ .slot = result.slot, .op_type = .disk_write, .context = @as(u40, @intCast(torrent_id)) << 32 | @as(u40, result.piece_index) });
                _ = self.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
                    log.warn("disk write submit for piece {d}: {s}", .{ result.piece_index, @errorName(err) });
                    if (self.pending_writes.getPtr(.{ .piece_index = result.piece_index, .torrent_id = torrent_id })) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                if (self.pending_writes.getPtr(.{ .piece_index = result.piece_index, .torrent_id = torrent_id })) |pending_w| {
                    pending_w.spans_remaining += 1;
                }
            }

            if (self.pending_writes.getPtr(.{ .piece_index = result.piece_index, .torrent_id = torrent_id })) |pending_w| {
                if (pending_w.spans_remaining == 0) {
                    _ = self.pending_writes.remove(.{ .piece_index = result.piece_index, .torrent_id = torrent_id });
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
    for (self.peers, 0..) |*peer, i| {
        if (peer.state == .free or peer.state == .disconnecting) continue;
        if (peer.last_activity == 0) continue;
        if (peer.mode == .seed) continue; // don't timeout seed peers

        if (now - peer.last_activity > peer_timeout_secs) {
            self.removePeer(@intCast(i));
        }
    }
}

// ── Choking algorithm (tit-for-tat) ─────────────────

pub fn recalculateUnchokes(self: *EventLoop) void {
    const now = std.time.timestamp();
    if (now - self.last_unchoke_recalc < unchoke_interval_secs) return;
    self.last_unchoke_recalc = now;

    // Collect active seed-mode peers that are interested
    var interested_peers: [max_peers]u16 = undefined;
    var interested_count: u32 = 0;

    for (self.peers, 0..) |*peer, i| {
        if (peer.state == .free or peer.state == .disconnecting) continue;
        if (peer.mode != .seed) continue;
        if (!peer.peer_interested) continue;
        if (interested_count < max_peers) {
            interested_peers[interested_count] = @intCast(i);
            interested_count += 1;
        }
    }

    if (interested_count == 0) return;

    // Sort by bytes_downloaded_from (peers that give us most data get unchoked first)
    // For seed-only mode, all peers upload equally, so use bytes_uploaded_to to spread
    const peers_slice = interested_peers[0..interested_count];
    const context = self;
    std.mem.sort(u16, peers_slice, context, struct {
        fn lessThan(ctx: *EventLoop, a: u16, b: u16) bool {
            return ctx.peers[a].bytes_downloaded_from > ctx.peers[b].bytes_downloaded_from;
        }
    }.lessThan);

    // Unchoke top N, choke the rest
    var unchoked: u32 = 0;
    for (peers_slice) |slot| {
        const peer = &self.peers[slot];
        if (unchoked < max_unchoked + optimistic_unchoke_slots) {
            if (peer.am_choking) {
                peer.am_choking = false;
                protocol.submitMessage(self, slot, 1, &.{}) catch |err| {
                    log.debug("unchoke send for slot {d}: {s}", .{ slot, @errorName(err) });
                }; // unchoke
            }
            unchoked += 1;
        } else {
            if (!peer.am_choking) {
                peer.am_choking = true;
                protocol.submitMessage(self, slot, 0, &.{}) catch |err| {
                    log.debug("choke send for slot {d}: {s}", .{ slot, @errorName(err) });
                }; // choke
            }
        }
    }
}

// ── Re-announce ─────────────────────────────────────────

pub fn checkReannounce(self: *EventLoop) void {
    // Pick up results from a previous background announce
    if (self.announce_results_ready.load(.acquire)) {
        if (self.announce_result_peers) |peers| {
            for (peers) |addr| {
                if (self.peer_count >= self.max_connections) break;
                _ = self.addPeer(addr) catch continue;
            }
            self.allocator.free(peers);
            self.announce_result_peers = null;
        }
        self.announce_results_ready.store(false, .release);
    }

    const url = self.announce_url orelse return;
    if (self.peer_count >= self.min_peers_for_reannounce) return;

    const now = std.time.timestamp();
    // Apply jitter to the announce interval (+-10% of interval)
    const jittered_interval = @as(i64, self.announce_interval) + @as(i64, self.announce_jitter_secs);
    const effective_interval = @max(jittered_interval, 60); // floor at 60s
    if (now - self.last_announce_time < effective_interval) return;

    self.last_announce_time = now;
    // Generate new jitter for next cycle: +-10% of interval
    self.announce_jitter_secs = generateAnnounceJitter(self);

    // Already announcing -- skip
    if (self.announcing.load(.acquire)) return;

    // Lazily create the shared announce ring (reused across announces)
    if (self.announce_ring == null) {
        const RingType = @import("ring.zig").Ring;
        self.announce_ring = RingType.init(16) catch return;
    }

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
    thread.detach();
}

/// Background thread for tracker re-announce. Uses the shared announce_ring
/// (separate from the main event loop ring) for blocking HTTP I/O.
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

    const ring = &(self.announce_ring orelse return);
    const tracker_mod = @import("../tracker/root.zig");
    const response = tracker_mod.announce.fetchAuto(self.allocator, ring, .{
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

    // Store results for the main thread (atomic handoff)
    self.announce_result_peers = addrs;
    self.announce_results_ready.store(true, .release);
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
    const now = std.time.timestamp();

    for (&self.torrents, 0..) |*slot, idx| {
        const tc = &(slot.* orelse continue);
        const tid: u8 = @intCast(idx);

        // PEX is disabled for private torrents (BEP 27)
        if (tc.is_private) continue;

        // Lazily allocate torrent PEX state
        if (tc.pex_state == null) {
            const tps = self.allocator.create(pex_mod.TorrentPexState) catch continue;
            tps.* = pex_mod.TorrentPexState{};
            tc.pex_state = tps;
        }
        const torrent_pex = tc.pex_state.?;

        // Update the torrent's connected peers set
        for (self.peers) |*peer| {
            if (peer.state == .free or peer.state == .connecting or peer.state == .disconnecting) continue;
            if (peer.torrent_id != tid) continue;
            // Only include peers that have completed the handshake
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;

            const flags = pex_mod.PeerFlags{
                .seed = peer.mode == .seed or peer.upload_only,
                .utp = peer.transport == .utp,
            };
            torrent_pex.addPeer(self.allocator, peer.address, flags);
        }

        // Send PEX messages to each eligible peer for this torrent
        for (self.peers, 0..) |*peer, pi| {
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.torrent_id != tid) continue;
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
            if (peer.send_pending) continue;

            // Check if peer supports ut_pex
            const peer_pex_id = if (peer.extension_ids) |ids| ids.ut_pex else 0;
            if (peer_pex_id == 0) continue;

            // Rate-limit PEX messages per peer
            if (peer.pex_state) |ps| {
                if (now - ps.last_pex_time < pex_mod.pex_interval_secs) continue;
            }

            protocol.submitPexMessage(self, @intCast(pi)) catch |err| {
                log.debug("PEX send to slot {d}: {s}", .{ pi, @errorName(err) });
            };
        }
    }
}

/// Update speed counters for all active torrents and individual peers (called from tick).
pub fn updateSpeedCounters(self: *EventLoop) void {
    const now = std.time.timestamp();

    // Update per-peer speed counters
    for (self.peers) |*peer| {
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
    for (&self.torrents, 0..) |*slot, idx| {
        const tc = &(slot.* orelse continue);
        const tid: u8 = @intCast(idx);

        // Sum bytes across peers for this torrent
        var dl_total: u64 = 0;
        var ul_total: u64 = 0;
        for (self.peers) |*peer| {
            if (peer.state != .free and peer.torrent_id == tid) {
                dl_total += peer.bytes_downloaded_from;
                ul_total += peer.bytes_uploaded_to;
            }
        }

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
    for (&self.torrents, 0..) |*slot, idx| {
        const tc = &(slot.* orelse continue);
        const tid: u8 = @intCast(idx);
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
        for (self.peers, 0..) |*peer, pi| {
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.torrent_id != tid) continue;
            if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
            if (!peer.extensions_supported) continue;
            if (peer.send_pending) continue;

            protocol.submitExtensionHandshake(self, @intCast(pi)) catch |err| {
                log.debug("BEP 21 ext handshake resend to slot {d}: {s}", .{ pi, @errorName(err) });
            };
        }
    }
}

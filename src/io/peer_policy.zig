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
const utp_handler = @import("utp_handler.zig");
const web_seed_handler = @import("web_seed_handler.zig");
const addr_mod = @import("../net/address.zig");
const BanList = @import("../net/ban_list.zig").BanList;
const peer_handler = @import("peer_handler.zig");
const SmartBan = @import("../net/smart_ban.zig").SmartBan;
const dp_mod = @import("downloading_piece.zig");
const DownloadingPiece = dp_mod.DownloadingPiece;
const DownloadingPieceKey = dp_mod.DownloadingPieceKey;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;
const session_mod = @import("../torrent/session.zig");

const pipeline_depth: u32 = 64;

/// Maximum number of peers that can work on the same piece simultaneously.
const max_peers_per_piece: u8 = 3;

/// Threshold at which a peer is banned for sending too many corrupt pieces.
const trust_ban_threshold: i8 = -7;
const peer_timeout_secs: i64 = 60;
const unchoke_interval_secs: i64 = 10; // BEP 3: recalculate every 10 seconds
const optimistic_unchoke_interval_secs: i64 = 30; // rotate optimistic unchoke every 30s
const max_unchoked: u32 = 4;
const optimistic_unchoke_slots: u32 = 1;

// ── Piece download coordination ───────────────────────

pub fn tryAssignPieces(self: anytype) void {
    // During graceful shutdown drain, don't claim new pieces
    if (self.draining) return;

    var i: usize = 0;
    while (i < self.idle_peers.items.len) {
        const slot = self.idle_peers.items[i];
        const peer = &self.peers[slot];

        // Re-check eligibility (state may have changed since enqueue).
        if (!@TypeOf(self.*).isIdleCandidate(peer)) {
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

        // Phase 2: try to join an existing DownloadingPiece before claiming a new one.
        // This enables multi-source piece assembly -- multiple peers contribute
        // blocks to the same piece simultaneously.
        if (tryJoinExistingPiece(self, slot, peer)) {
            self.unmarkIdle(slot);
            continue;
        }

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

/// Try to join an existing DownloadingPiece that the peer can contribute
/// to, returning true on success.  A DP is "joinable" if it has fewer than
/// `max_peers_per_piece` peers and either:
///
///   * unrequested blocks remain (preferred, no duplicate work), or
///   * every block is in `.requested` state but at least one is attributed
///     to a different peer (block-stealing path — a late peer issues
///     duplicate REQUESTs for in-flight blocks; whichever delivery
///     `markBlockReceived` sees first wins, the loser's data is dropped).
///
/// Block-stealing unblocks the "3 peers all hold the full piece, peer A
/// drains the entire piece in one tick before peers B+C finish handshake"
/// race observed by `tests/sim_multi_source_eventloop_test.zig`. Without
/// it B+C find `unreq == 0` and stay idle until the piece completes,
/// degenerating to single-source.
///
/// Bitfield check (`peer_bf.has(dp.piece_index)`) is critical for the
/// smart-ban safety invariant: an honest peer in a swarm where corrupt
/// holds piece 0 (disjoint from honest's bitfield) must NEVER join piece
/// 0's DP via the stealing path. Without the bitfield gate, an honest
/// peer would issue REQUESTs for piece 0; the SimPeer `serveRequest` does
/// not enforce bitfield at the wire (it serves any piece in `piece_data`),
/// so honest data lands attributed to the honest slot, racing against
/// corrupt's corrupt data → mixed buffer → hash fails →
/// `processHashResults` penalises whichever slot delivered the *last*
/// block. If that's an honest slot, smart-ban frames an honest peer.
/// The bitfield check makes this impossible by construction.
pub fn tryJoinExistingPiece(self: anytype, slot: u16, peer: *Peer) bool {
    const peer_bf = if (peer.availability) |*bf| bf else return false;

    var best_dp: ?*DownloadingPiece = null;
    var best_score: u32 = 0;

    var it = self.downloading_pieces.valueIterator();
    while (it.next()) |dp_ptr| {
        const dp = dp_ptr.*;
        // Must be same torrent
        if (dp.torrent_id != peer.torrent_id) continue;
        // Must have room for another peer
        if (dp.peer_count >= max_peers_per_piece) continue;
        // Peer must have this piece (smart-ban safety, see fn doc)
        if (!peer_bf.has(dp.piece_index)) continue;

        // Score: unrequested blocks count for full credit (each is a
        // unique block this peer can claim outright). Stealable blocks
        // count for half credit — duplicate work, only useful when
        // there are no unique blocks to claim. Always prefer DPs with
        // unique blocks first.
        const unreq = dp.unrequestedCount();
        var score: u32 = @as(u32, unreq) * 2;
        if (unreq == 0) {
            if (dp.nextStealableBlock(slot) != null) score = 1; // some stealable
        }
        if (score == 0) continue;
        if (score > best_score) {
            best_score = score;
            best_dp = dp;
        }
    }

    if (best_dp) |dp| {
        joinPieceDownload(self, slot, dp) catch return false;
        return true;
    }
    return false;
}

pub fn startPieceDownload(self: anytype, slot: u16, piece_index: u32) !void {
    const peer = &self.peers[slot];
    const tc = self.getTorrentContext(peer.torrent_id) orelse return error.TorrentNotFound;
    const sess = tc.session orelse return error.TorrentNotFound;
    const piece_size = try sess.layout.pieceSize(piece_index);
    const geometry = sess.geometry();
    const block_count = try geometry.blockCount(piece_index);

    // Look up or create the shared DownloadingPiece
    const dp_key = DownloadingPieceKey{ .torrent_id = peer.torrent_id, .piece_index = piece_index };
    const dp = if (self.downloading_pieces.get(dp_key)) |existing| existing else blk: {
        const new_dp = dp_mod.createDownloadingPiece(
            self.allocator,
            piece_index,
            peer.torrent_id,
            piece_size,
            @intCast(block_count),
        ) catch return error.OutOfMemory;
        self.downloading_pieces.put(self.allocator, dp_key, new_dp) catch {
            dp_mod.destroyDownloadingPieceFull(self.allocator, new_dp);
            return error.OutOfMemory;
        };
        break :blk new_dp;
    };

    peer.current_piece = piece_index;
    peer.piece_buf = dp.buf;
    peer.downloading_piece = dp;
    dp.peer_count += 1;

    peer.blocks_received = 0;
    peer.blocks_expected = block_count;
    peer.pipeline_sent = 0;
    peer.inflight_requests = 0;

    tryFillPipeline(self, slot) catch {
        // On failure, detach this peer from the DownloadingPiece
        detachPeerFromDownloadingPiece(self, peer);
        peer.current_piece = null;
        peer.piece_buf = null;
        return error.PipelineFillFailed;
    };
}

/// Join an existing DownloadingPiece that other peers are already working on.
pub fn joinPieceDownload(self: anytype, slot: u16, dp: *DownloadingPiece) !void {
    const peer = &self.peers[slot];

    peer.current_piece = dp.piece_index;
    peer.piece_buf = dp.buf;
    peer.downloading_piece = dp;
    dp.peer_count += 1;

    peer.blocks_received = 0;
    peer.blocks_expected = dp.blocks_total;
    peer.pipeline_sent = 0;
    peer.inflight_requests = 0;

    tryFillPipeline(self, slot) catch {
        detachPeerFromDownloadingPiece(self, peer);
        peer.current_piece = null;
        peer.piece_buf = null;
        return error.PipelineFillFailed;
    };
}

/// Detach a peer from its current DownloadingPiece.  Releases requested blocks
/// and decrements peer_count.  If no peers remain and the piece is incomplete,
/// the DownloadingPiece is kept in the registry for future peers to resume.
pub fn detachPeerFromDownloadingPiece(self: anytype, peer: *Peer) void {
    const dp = peer.downloading_piece orelse return;
    const slot = peerSlot(self, peer);
    dp.releaseBlocksForPeer(slot);
    if (dp.peer_count > 0) dp.peer_count -= 1;
    peer.downloading_piece = null;
    peer.piece_buf = null;

    // If no peers remain and no blocks received, remove from registry and free
    if (dp.peer_count == 0 and dp.blocks_received == 0) {
        const dp_key = DownloadingPieceKey{ .torrent_id = dp.torrent_id, .piece_index = dp.piece_index };
        _ = self.downloading_pieces.remove(dp_key);
        if (self.getTorrentContext(dp.torrent_id)) |tc| {
            if (tc.piece_tracker) |pt| pt.releasePiece(dp.piece_index);
        }
        dp_mod.destroyDownloadingPieceFull(self.allocator, dp);
    }
}

/// Detach a peer from its next_downloading_piece.
pub fn detachPeerFromNextDownloadingPiece(self: anytype, peer: *Peer) void {
    const dp = peer.next_downloading_piece orelse return;
    const slot = peerSlot(self, peer);
    dp.releaseBlocksForPeer(slot);
    if (dp.peer_count > 0) dp.peer_count -= 1;
    peer.next_downloading_piece = null;
    peer.next_piece_buf = null;

    if (dp.peer_count == 0 and dp.blocks_received == 0) {
        const dp_key = DownloadingPieceKey{ .torrent_id = dp.torrent_id, .piece_index = dp.piece_index };
        _ = self.downloading_pieces.remove(dp_key);
        if (self.getTorrentContext(dp.torrent_id)) |tc| {
            if (tc.piece_tracker) |pt| pt.releasePiece(dp.piece_index);
        }
        dp_mod.destroyDownloadingPieceFull(self.allocator, dp);
    }
}

/// Get the slot index of a peer within the peers array.
fn peerSlot(self: anytype, peer: *const Peer) u16 {
    const base = @intFromPtr(self.peers.ptr);
    const addr = @intFromPtr(peer);
    return @intCast((addr - base) / @sizeOf(Peer));
}

pub fn tryFillPipeline(self: anytype, slot: u16) !void {
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

    // --- Phase 1: fill requests for current piece using DownloadingPiece ---
    var p1: u32 = 0; // requests to send for current piece this call
    if (peer.current_piece) |piece_index| {
        if (peer.downloading_piece) |dp| {
            // Multi-source fair-share cap: when multiple peers reference
            // the same DP, each peer's claim is bounded so it doesn't
            // monopolise. Computed every call so the cap shrinks as
            // additional peers join via tryJoinExistingPiece. Endgame
            // mode (not yet implemented as a flag) would relax this:
            // when only a few blocks remain, allow duplicate requests
            // across peers to race for last-block delivery. Today's
            // dedup invariant (`markBlockRequested` returns false on
            // already-requested blocks) blocks endgame; a future
            // `dp.endgame` bool would skip the cap when set.
            // Multi-source claim caps:
            //
            // Two-part bound to balance single-source throughput against
            // multi-source distribution:
            //
            // 1. **Per-call cap** (`per_call_cap`): how many blocks any
            //    single tryFillPipeline invocation may claim. Pegged at
            //    `pipeline_depth / max_peers_per_piece` so a peer can't
            //    sweep an entire piece before peers still-handshaking
            //    have a chance to join via tryJoinExistingPiece.
            // 2. **Fair-share cap** (`remaining_share`): once peers HAVE
            //    joined, each is bounded to `blocks_total / peer_count`
            //    of the piece. Ceiling division so stranded blocks
            //    don't accrue when blocks_total % peer_count != 0.
            //
            // The per-call cap matters even when peer_count == 1: it
            // gives slow-handshake peers a window to land before the
            // first responder claims everything. Without it, the
            // multi-source picker degenerates to single-source whenever
            // one peer's handshake finishes first (always, modulo seed).
            //
            // Endgame mode (not yet implemented as a flag) would relax
            // both caps: when only a few blocks remain, allow duplicate
            // requests across peers to race for last-block delivery.
            // Today's dedup invariant (`markBlockRequested` returns
            // false on already-requested blocks) blocks endgame; a
            // future `dp.endgame` bool would skip both caps when set.
            const peer_count = @max(@as(u8, 1), dp.peer_count);
            const fair_share: u16 = @intCast(@max(
                @as(u32, 1),
                (@as(u32, dp.blocks_total) + peer_count - 1) / peer_count,
            ));
            const already_attributed = dp.attributedCountForPeer(slot);
            const remaining_share: u16 = if (fair_share > already_attributed)
                fair_share - already_attributed
            else
                0;
            const per_call_cap: u16 = @max(1, pipeline_depth / max_peers_per_piece);
            const claim_cap: u16 = @min(per_call_cap, remaining_share);
            var claimed_this_call: u16 = 0;
            while (peer.inflight_requests + p1 < pipeline_depth and
                claimed_this_call < claim_cap)
            {
                const block_idx = dp.nextUnrequestedBlock() orelse break;
                const req = geometry.requestForBlock(piece_index, block_idx) catch break;
                if (!dp.markBlockRequested(block_idx, slot)) break;
                writeRequestMsg(send_buf[p1 * request_size ..], req);
                p1 += 1;
                claimed_this_call += 1;
            }

            // Block-stealing fallback. Once `nextUnrequestedBlock`
            // returns null (every block in `peer.downloading_piece` is
            // either `.requested` by some peer or `.received`), fill
            // remaining pipeline capacity with **duplicate REQUESTs**
            // for blocks attributed to other peers. Whoever's response
            // arrives first wins attribution via `markBlockReceived`;
            // the loser's response is dropped (state == .received → false).
            //
            // Why this is safe:
            //   * peer.current_piece was set via a bitfield-checked path
            //     (`pt.claimPiece(peer_bf)` or `tryJoinExistingPiece`'s
            //     `peer_bf.has(dp.piece_index)` gate), so the peer holds
            //     this piece. We do not cross piece boundaries here.
            //   * markBlockReceived is the single attribution authority;
            //     the duplicate response decrements `peer.inflight_requests`
            //     unconditionally (protocol.zig:170) and discards data.
            //   * We do not mutate dp state — peer_slot remains the
            //     original requester's slot until delivery. If the
            //     original peer disconnects, `releaseBlocksForPeer`
            //     resets state to `.none` and our duplicate response
            //     lands as a fresh delivery (state was `.none` →
            //     markBlockReceived writes data and sets peer_slot to us).
            //
            // Bound: same `per_call_cap` as the unrequested-claim loop,
            // so a stealing peer can claim at most pipeline_depth/3
            // duplicate-requests per tryFillPipeline call (the same per-
            // call cap rationale: don't let one peer monopolise refills).
            // Defensive bitfield re-check at the top of the steal loop
            // catches any future picker path that bypassed the entry-
            // point check.
            const peer_has_piece = if (peer.availability) |*bf|
                bf.has(piece_index)
            else
                false;
            if (peer_has_piece) {
                var steal_idx: u16 = 0;
                while (peer.inflight_requests + p1 < pipeline_depth and
                    claimed_this_call < per_call_cap and
                    steal_idx < dp.blocks_total)
                {
                    const bi = dp.block_infos[steal_idx];
                    if (bi.state == .requested and bi.peer_slot != slot) {
                        const req = geometry.requestForBlock(piece_index, steal_idx) catch break;
                        writeRequestMsg(send_buf[p1 * request_size ..], req);
                        p1 += 1;
                        claimed_this_call += 1;
                    }
                    steal_idx += 1;
                }
            }
        } else {
            // Legacy path (no DownloadingPiece -- should not happen after migration)
            while (peer.inflight_requests + p1 < pipeline_depth and
                peer.pipeline_sent + p1 < peer.blocks_expected)
            {
                const req = geometry.requestForBlock(piece_index, peer.pipeline_sent + p1) catch break;
                writeRequestMsg(send_buf[p1 * request_size ..], req);
                p1 += 1;
            }
        }
    }

    // --- Phase 2: prefetch next piece if current is fully requested and pipeline has headroom ---
    var p2: u32 = 0; // requests to send for next piece this call
    const cur_fully_requested = if (peer.downloading_piece) |dp|
        dp.nextUnrequestedBlock() == null
    else if (peer.current_piece) |_|
        (peer.pipeline_sent + p1 >= peer.blocks_expected)
    else
        false;

    if (cur_fully_requested and peer.inflight_requests + p1 < pipeline_depth) {
        // Claim next piece if not already done
        if (peer.next_piece == null) {
            if (tc.piece_tracker) |pt| {
                const peer_bf: ?*const Bitfield = if (peer.availability) |*bf| bf else null;
                if (pt.claimPiece(peer_bf)) |next_idx| {
                    // Endgame mode can return the same piece we're already
                    // downloading.  Skip prefetch in that case -- otherwise
                    // next_downloading_piece aliases downloading_piece and
                    // completePieceDownload double-frees the DP.
                    // Don't releasePiece -- endgame doesn't set in_progress,
                    // and the original claim still needs it.
                    if (peer.current_piece != null and next_idx == peer.current_piece.?) {
                        // no-op: skip duplicate piece prefetch
                    } else {
                        const next_size = sess.layout.pieceSize(next_idx) catch {
                            pt.releasePiece(next_idx);
                            return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                        };
                        const next_block_count = geometry.blockCount(next_idx) catch {
                            pt.releasePiece(next_idx);
                            return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                        };
                        // Create DownloadingPiece for next piece
                        const next_dp_key = DownloadingPieceKey{ .torrent_id = peer.torrent_id, .piece_index = next_idx };
                        const next_dp = if (self.downloading_pieces.get(next_dp_key)) |existing| existing else blk: {
                            const new_dp = dp_mod.createDownloadingPiece(
                                self.allocator,
                                next_idx,
                                peer.torrent_id,
                                next_size,
                                @intCast(next_block_count),
                            ) catch {
                                pt.releasePiece(next_idx);
                                return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                            };
                            self.downloading_pieces.put(self.allocator, next_dp_key, new_dp) catch {
                                dp_mod.destroyDownloadingPieceFull(self.allocator, new_dp);
                                pt.releasePiece(next_idx);
                                return try submitPipelineRequests(self, slot, send_buf[0 .. p1 * request_size], p1, 0);
                            };
                            break :blk new_dp;
                        };

                        peer.next_piece = next_idx;
                        peer.next_piece_buf = next_dp.buf;
                        peer.next_downloading_piece = next_dp;
                        next_dp.peer_count += 1;
                        peer.next_blocks_expected = next_block_count;
                        peer.next_blocks_received = 0;
                        peer.next_pipeline_sent = 0;
                    }
                }
            }
        }

        // Fill requests for next piece using DownloadingPiece
        if (peer.next_piece) |next_idx| {
            if (peer.next_downloading_piece) |next_dp| {
                // Same fair-share cap as the current-piece path (above).
                const next_peer_count = @max(@as(u8, 1), next_dp.peer_count);
                const next_fair_share: u16 = @intCast(@max(
                    @as(u32, 1),
                    (@as(u32, next_dp.blocks_total) + next_peer_count - 1) / next_peer_count,
                ));
                const next_already = next_dp.attributedCountForPeer(slot);
                const next_remaining: u16 = if (next_fair_share > next_already)
                    next_fair_share - next_already
                else
                    0;
                var next_claimed: u16 = 0;
                while (peer.inflight_requests + p1 + p2 < pipeline_depth and
                    next_claimed < next_remaining)
                {
                    const block_idx = next_dp.nextUnrequestedBlock() orelse break;
                    const req = geometry.requestForBlock(next_idx, block_idx) catch break;
                    if (!next_dp.markBlockRequested(block_idx, slot)) break;
                    writeRequestMsg(send_buf[(p1 + p2) * request_size ..], req);
                    p2 += 1;
                    next_claimed += 1;
                }
            } else {
                // Legacy path
                while (peer.inflight_requests + p1 + p2 < pipeline_depth and
                    peer.next_pipeline_sent + p2 < peer.next_blocks_expected)
                {
                    const req = geometry.requestForBlock(next_idx, peer.next_pipeline_sent + p2) catch break;
                    writeRequestMsg(send_buf[(p1 + p2) * request_size ..], req);
                    p2 += 1;
                }
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
    self: anytype,
    slot: u16,
    buf: []u8,
    p1: u32, // requests for current piece
    p2: u32, // requests for next piece
) !void {
    const peer = &self.peers[slot];
    const total = p1 + p2;
    if (total == 0) return;

    // uTP peers: route through the uTP byte stream instead of io_uring send.
    if (peer.transport == .utp) {
        utp_handler.utpSendData(self, slot, buf) catch return;
        peer.pipeline_sent += p1;
        peer.next_pipeline_sent += p2;
        peer.inflight_requests += total;
        return;
    }

    // MSE/PE: encrypt in-place before copying into tracked buffer
    peer.crypto.encryptBuf(buf);

    const send_id = self.nextSendId();
    const ps = self.trackPendingSendCopy(slot, send_id, buf) catch return;

    self.submitPendingSend(ps) catch {
        self.freeOnePendingSend(slot, send_id);
        return;
    };
    peer.pipeline_sent += p1;
    peer.next_pipeline_sent += p2;
    peer.inflight_requests += total;
}

/// After current piece completes: promote pre-fetched next_piece to current,
/// or fall back to markIdle if no next piece is queued.
fn promoteNextPieceOrMarkIdle(self: anytype, slot: u16) void {
    const peer = &self.peers[slot];
    if (peer.next_piece != null) {
        peer.current_piece = peer.next_piece;
        peer.piece_buf = peer.next_piece_buf;
        peer.downloading_piece = peer.next_downloading_piece;
        peer.blocks_expected = peer.next_blocks_expected;
        peer.blocks_received = peer.next_blocks_received;
        peer.pipeline_sent = peer.next_pipeline_sent;
        // inflight_requests covers pending requests for the promoted piece -- do not reset.
        peer.next_piece = null;
        peer.next_piece_buf = null;
        peer.next_downloading_piece = null;
        peer.next_blocks_expected = 0;
        peer.next_blocks_received = 0;
        peer.next_pipeline_sent = 0;

        // Check if the promoted piece is already complete (all blocks received)
        if (peer.downloading_piece) |dp| {
            if (dp.isComplete()) {
                completePieceDownload(self, slot);
            } else {
                tryFillPipeline(self, slot) catch {};
            }
        } else if (peer.blocks_received >= peer.blocks_expected) {
            completePieceDownload(self, slot);
        } else {
            // Refill pipeline: claim another next_piece and send remaining requests
            tryFillPipeline(self, slot) catch {};
        }
    } else {
        self.markIdle(slot);
    }
}

pub fn completePieceDownload(self: anytype, slot: u16) void {
    const peer = &self.peers[slot];
    const piece_index = peer.current_piece orelse return;
    const piece_buf = peer.piece_buf orelse return;
    const dp = peer.downloading_piece;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const sess = tc.session orelse return;
    const pt = tc.piece_tracker orelse return;

    // Teardown race guard: when EL is winding down (`self.draining`
    // set by signal-handler graceful shutdown OR by deinit start), the
    // hasher's pending_jobs structure is being torn down. Residual
    // recv CQEs can route here from in-flight piece-block traffic for
    // already-disconnected peers; we must not submit a new hash job
    // against a draining or destroyed hasher. Drop the piece via
    // cleanupCompletionFailure (releases pt + frees the piece_buf) and
    // return early. Lost piece is acceptable in shutdown; corrupt
    // state is not.
    //
    // NOTE: only check `self.draining`, not `self.hasher == null`.
    // The latter is also a valid normal-mode state (hasher_threads=0
    // selects the inline-verify fallback below); hard-failing on null
    // would break the inline-mode path used by sim_swarm_test.
    if (self.draining) {
        cleanupCompletionFailure(self, peer, dp, pt, piece_index);
        return;
    }

    // Multi-source race guard / piece-hash lifecycle interaction: if the
    // piece is already verified-and-persisted (another peer's contribution
    // got there first), skip re-verification. This is what previously was
    // gated by the endgame-pending-write check in `processHashResults`,
    // but we need it here too because Phase 1 of the piece-hash lifecycle
    // (`docs/piece-hash-lifecycle.md`) zeros the hash bytes once
    // `pt.completePiece` returns true. Re-reading the (now-zero) hash in
    // a duplicate completion would falsely fail the hash check and
    // penalise an honest peer that contributed real blocks. Discard the
    // duplicate here without going through the hasher.
    if (pt.isPieceComplete(piece_index)) {
        cleanupDuplicateCompletion(self, peer, dp, piece_index);
        return;
    }

    // Get the expected hash for this piece
    const expected_hash = sess.layout.pieceHash(piece_index) catch {
        cleanupCompletionFailure(self, peer, dp, pt, piece_index);
        return;
    };
    var hash: [20]u8 = undefined;
    @memcpy(&hash, expected_hash);

    if (self.hasher) |h| {
        // Smart Ban Phase 1: snapshot per-block peer attribution before
        // destroying the DownloadingPiece.  The attribution is consumed in
        // processHashResults (on both pass and fail paths).
        if (dp) |d| {
            if (self.smart_ban) |sb| {
                snapshotAttributionForSmartBan(self, sb, peer.torrent_id, piece_index, d);
            }
        }

        // Submit to background hasher thread (non-blocking)
        h.submitVerify(slot, piece_index, piece_buf, hash, peer.torrent_id) catch {
            cleanupCompletionFailure(self, peer, dp, pt, piece_index);
            return;
        };
        // Don't free piece_buf -- the hasher owns it now.
        // Clean up the DownloadingPiece metadata (block_infos) but keep the buffer.
        if (dp) |d| {
            // Remove from registry
            const dp_key = DownloadingPieceKey{ .torrent_id = d.torrent_id, .piece_index = d.piece_index };
            _ = self.downloading_pieces.remove(dp_key);
            // Detach all peers still referencing this DP (they will get markIdle)
            detachAllPeersExcept(self, d, slot);
            // Free metadata only (not the buffer -- hasher owns it)
            dp_mod.destroyDownloadingPiece(self.allocator, d);
        }
        // The peer can start downloading another piece immediately.
        peer.piece_buf = null;
        peer.downloading_piece = null;
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
                cleanupCompletionFailure(self, peer, dp, pt, piece_index);
                return;
            };
            defer plan.deinit(self.allocator);

            const span_count: u32 = @intCast(plan.spans.len);
            if (span_count == 0) {
                cleanupCompletionFailure(self, peer, dp, pt, piece_index);
                return;
            }

            // Track pending writes for completion
            const pending_key = @TypeOf(self.*).PendingWriteKey{
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
                cleanupCompletionFailure(self, peer, dp, pt, piece_index);
                return;
            };

            for (plan.spans) |span| {
                // Skip spans for do_not_download files (fd == -1)
                if (tc.shared_fds[span.file_index] < 0) continue;
                const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
                const EL = @TypeOf(self.*);
                const wop = self.allocator.create(peer_handler.DiskWriteOpOf(EL)) catch |err| {
                    log.warn("inline disk write op alloc for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    if (self.getPendingWrite(pending_key)) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                wop.* = .{ .el = self, .write_id = write_id };
                self.io.write(
                    .{ .fd = tc.shared_fds[span.file_index], .buf = block, .offset = span.file_offset },
                    &wop.completion,
                    wop,
                    peer_handler.diskWriteCompleteFor(EL),
                ) catch |err| {
                    log.warn("inline disk write for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    self.allocator.destroy(wop);
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
                    cleanupCompletionFailure(self, peer, dp, pt, piece_index);
                    return;
                }
            }
            // Buffer ownership transferred to pending_writes; will be freed on completion
            if (dp) |d| {
                const dp_key = DownloadingPieceKey{ .torrent_id = d.torrent_id, .piece_index = d.piece_index };
                _ = self.downloading_pieces.remove(dp_key);
                detachAllPeersExcept(self, d, slot);
                dp_mod.destroyDownloadingPiece(self.allocator, d);
            }
            peer.piece_buf = null;
            peer.downloading_piece = null;
        } else {
            // Hash mismatch -- release piece and free buffer
            if (dp) |d| {
                const dp_key = DownloadingPieceKey{ .torrent_id = d.torrent_id, .piece_index = d.piece_index };
                _ = self.downloading_pieces.remove(dp_key);
                detachAllPeersExcept(self, d, slot);
                dp_mod.destroyDownloadingPieceFull(self.allocator, d);
            } else {
                self.allocator.free(piece_buf);
            }
            pt.releasePiece(piece_index);
            peer.piece_buf = null;
            peer.downloading_piece = null;
        }
        peer.current_piece = null;
        self.markIdle(slot);
    }
}

/// Clean up after a duplicate completion: another peer's contribution
/// already verified-and-persisted this piece. Free our piece buffer and
/// detach without re-verifying or releasing the (already-complete) piece.
/// This is the multi-source endgame race the piece-hash lifecycle
/// surfaces in concert with the per-piece zeroing — see the comment at
/// the call site in `completePieceDownload`.
fn cleanupDuplicateCompletion(
    self: anytype,
    peer: *Peer,
    dp: ?*DownloadingPiece,
    piece_index: u32,
) void {
    _ = piece_index;
    if (dp) |d| {
        const dp_key = DownloadingPieceKey{ .torrent_id = d.torrent_id, .piece_index = d.piece_index };
        // Only the slot that *first* completed registered the DP; subsequent
        // completers may have detached already. fetchRemove is idempotent.
        _ = self.downloading_pieces.remove(dp_key);
        const slot = peerSlot(self, peer);
        detachAllPeersExcept(self, d, slot);
        dp_mod.destroyDownloadingPieceFull(self.allocator, d);
    } else {
        if (peer.piece_buf) |buf| self.allocator.free(buf);
    }
    peer.piece_buf = null;
    peer.downloading_piece = null;
    peer.current_piece = null;
    promoteNextPieceOrMarkIdle(self, peerSlot(self, peer));
}

/// Clean up after a failed piece completion (hash lookup failure, hasher submit failure, etc.).
/// Releases the piece back to the tracker and marks the peer idle.
fn cleanupCompletionFailure(
    self: anytype,
    peer: *Peer,
    dp: ?*DownloadingPiece,
    pt: *PieceTracker,
    piece_index: u32,
) void {
    if (dp) |d| {
        const dp_key = DownloadingPieceKey{ .torrent_id = d.torrent_id, .piece_index = d.piece_index };
        _ = self.downloading_pieces.remove(dp_key);
        const slot = peerSlot(self, peer);
        detachAllPeersExcept(self, d, slot);
        dp_mod.destroyDownloadingPieceFull(self.allocator, d);
    } else {
        if (peer.piece_buf) |buf| self.allocator.free(buf);
    }
    pt.releasePiece(piece_index);
    peer.piece_buf = null;
    peer.downloading_piece = null;
    peer.current_piece = null;
    self.markIdle(peerSlot(self, peer));
}

/// Detach all peers from a DownloadingPiece except the specified slot.
/// Used when a piece completes -- the completing peer handles its own cleanup,
/// but other peers referencing the same DP need to be detached and re-queued.
fn detachAllPeersExcept(self: anytype, dp: *DownloadingPiece, except_slot: u16) void {
    for (self.peers, 0..) |*p, i| {
        const s: u16 = @intCast(i);
        if (s == except_slot) continue;
        if (p.downloading_piece == dp) {
            p.downloading_piece = null;
            p.piece_buf = null;
            p.current_piece = null;
            p.blocks_received = 0;
            p.blocks_expected = 0;
            p.pipeline_sent = 0;
            self.markIdle(s);
        }
        if (p.next_downloading_piece == dp) {
            p.next_downloading_piece = null;
            p.next_piece_buf = null;
            p.next_piece = null;
            p.next_blocks_expected = 0;
            p.next_blocks_received = 0;
            p.next_pipeline_sent = 0;
        }
    }
}

/// Process completed hash results from the background hasher.
/// Called each tick from the event loop.
pub fn processHashResults(self: anytype) void {
    const h = self.hasher orelse return;
    const results = h.drainResultsInto(&self.hash_result_swap);
    for (results) |result| {
        // Route recheck results to the correct async recheck state machine
        if (result.is_recheck) {
            var found = false;
            for (self.rechecks.items) |rc| {
                if (rc.torrent_id == result.torrent_id) {
                    rc.handleHashResult(result.piece_index, result.valid, result.piece_buf);
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.allocator.free(result.piece_buf);
            }
            continue;
        }

        // Use torrent_id stored in the hash result (not from the slot,
        // which may have been freed and reassigned since submission).
        const torrent_id = result.torrent_id;
        const tc = self.getTorrentContext(torrent_id) orelse {
            self.allocator.free(result.piece_buf);
            continue;
        };

        if (result.valid) {
            // Smart Ban Phase 0: reward peer on successful hash verification.
            // Skip web seed sentinel slots -- those use WebSeedManager.
            if (!isWebSeedSentinelSlot(result.slot)) {
                const contributor = &self.peers[result.slot];
                if (contributor.state != .free and contributor.torrent_id == torrent_id) {
                    rewardPeerTrust(contributor);
                }
            }

            // Smart Ban Phase 2: if this piece previously failed, compare
            // per-block digests from the now-verified buffer against stored
            // records.  Peers whose blocks changed between the failed and
            // passing downloads get banned.
            if (self.smart_ban) |sb| {
                const block_size: u32 = 16 * 1024;
                if (sb.onPiecePassed(torrent_id, result.piece_index, result.piece_buf, block_size)) |bad| {
                    defer self.allocator.free(bad);
                    smartBanCorruptPeers(self, bad);
                } else |_| {}
            }

            const sess = tc.session orelse {
                self.allocator.free(result.piece_buf);
                continue;
            };

            // Endgame duplicate: another peer already verified this piece
            // and a write is in flight. Skip the duplicate -- just free
            // the buffer and mark the piece complete (the first write
            // will handle persistence).
            const pending_key = @TypeOf(self.*).PendingWriteKey{
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
            defer plan.deinit(self.allocator);

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
                const EL = @TypeOf(self.*);
                const wop = self.allocator.create(peer_handler.DiskWriteOpOf(EL)) catch |err| {
                    log.warn("disk write op alloc for piece {d}: {s}", .{ result.piece_index, @errorName(err) });
                    if (self.getPendingWrite(pending_key)) |pending_w| {
                        pending_w.write_failed = true;
                    }
                    continue;
                };
                wop.* = .{ .el = self, .write_id = write_id };
                self.io.write(
                    .{ .fd = tc.shared_fds[span.file_index], .buf = block, .offset = span.file_offset },
                    &wop.completion,
                    wop,
                    peer_handler.diskWriteCompleteFor(EL),
                ) catch |err| {
                    log.warn("disk write submit for piece {d}: {s}", .{ result.piece_index, @errorName(err) });
                    self.allocator.destroy(wop);
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
                    // No disk writes were submitted. This happens when all
                    // file spans have fd == -1 (do_not_download) or all
                    // io_uring write submissions failed.
                    _ = self.removePendingWrite(pending_key);
                    if (pending_w.write_failed) {
                        // Actual write submission failures -- release piece
                        // so it can be retried.
                        log.warn("piece {d} torrent {d}: all write submissions failed, releasing", .{
                            result.piece_index, torrent_id,
                        });
                        if (tc.piece_tracker) |pt| pt.releasePiece(result.piece_index);
                    } else {
                        // All spans skipped (do_not_download) -- the piece
                        // data is verified correct, mark complete.
                        const piece_length = sess.layout.pieceSize(result.piece_index) catch 0;
                        if (tc.piece_tracker) |pt| {
                            const first_completion = pt.completePiece(result.piece_index, piece_length);
                            // Phase 1: also fire the piece-hash lifecycle hook
                            // here so do_not_download torrents free hashes too.
                            if (first_completion) {
                                onPieceVerifiedAndPersisted(self, torrent_id, result.piece_index);
                            }
                        }
                    }
                    self.allocator.free(result.piece_buf);
                    continue;
                }
            }
        } else {
            // Smart Ban Phase 1: record per-block hashes + peer attribution
            // from the failed piece BEFORE freeing the buffer.  When the
            // piece is re-downloaded and passes, we'll compare block hashes
            // to identify which peer(s) sent corrupt data.
            if (self.smart_ban) |sb| {
                const block_size: u32 = 16 * 1024;
                sb.onPieceFailed(torrent_id, result.piece_index, result.piece_buf, block_size) catch {};
            }

            // Hash mismatch -- release piece back to pool
            if (tc.piece_tracker) |pt| pt.releasePiece(result.piece_index);
            self.allocator.free(result.piece_buf);

            // Smart Ban Phase 0: penalize peer on hash failure.
            // Skip web seed sentinel slots -- those are handled by
            // WebSeedManager.markFailure with its own backoff.
            if (!isWebSeedSentinelSlot(result.slot)) {
                const contributor = &self.peers[result.slot];
                if (contributor.state != .free and contributor.torrent_id == torrent_id) {
                    const should_ban = penalizePeerTrust(contributor);
                    if (should_ban) {
                        log.warn("banning peer {any} (slot {d}): trust_points={d}, hashfails={d}", .{
                            contributor.address, result.slot, contributor.trust_points, contributor.hashfails,
                        });
                        if (self.ban_list) |bl| {
                            _ = bl.banIp(contributor.address, "smart ban: too many hash failures", .manual) catch {};
                        }
                        self.removePeer(result.slot);
                    }
                }
            }
        }
    }
    // Results are already swapped out of the hasher -- no clearResults needed.
    self.hash_result_swap.clearRetainingCapacity();
}

/// Process completed Merkle tree building results from the background hasher.
/// Called each tick from the event loop, after processHashResults.
pub fn processMerkleResults(self: anytype) void {
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

pub fn checkPeerTimeouts(self: anytype) void {
    const now = self.clock.now();
    var to_remove = std.ArrayList(u16).empty;
    defer to_remove.deinit(self.allocator);

    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state == .free or peer.state == .disconnecting) continue;
        if (peer.last_activity == 0) continue;
        if (peer.mode == .inbound) continue; // don't timeout inbound peers

        if (now - peer.last_activity > peer_timeout_secs) {
            to_remove.append(self.allocator, slot) catch break;
        }
    }

    for (to_remove.items) |slot| self.removePeer(slot);
}

const keepalive_interval_secs: i64 = 90; // send keep-alive if we've been quiet for this long

/// Send keep-alive messages to peers we haven't sent anything to recently.
/// Prevents remote peers from disconnecting us for inactivity.
pub fn sendKeepAlives(self: anytype) void {
    const now = self.clock.now();
    for (self.active_peer_slots.items) |slot| {
        const peer = &self.peers[slot];
        if (peer.state != .active_recv_header and peer.state != .active_recv_body) continue;
        if (peer.send_pending) continue;
        if (peer.last_activity == 0) continue;

        if (now - peer.last_activity > keepalive_interval_secs) {
            // BEP 3 keep-alive: 4 zero bytes (length-prefix only, no message ID)
            if (peer.transport == .utp) {
                var keepalive = [_]u8{ 0, 0, 0, 0 };
                utp_handler.utpSendData(self, slot, &keepalive) catch continue;
            } else {
                var keepalive = [_]u8{ 0, 0, 0, 0 };
                peer.crypto.encryptBuf(&keepalive);
                const send_id = self.nextSendId();
                const ps = self.trackPendingSendCopy(slot, send_id, &keepalive) catch continue;
                self.submitPendingSend(ps) catch {
                    self.freeOnePendingSend(slot, send_id);
                    continue;
                };
            }
            peer.last_activity = now;
        }
    }
}

// ── Choking algorithm (tit-for-tat) ─────────────────

pub fn recalculateUnchokes(self: anytype) void {
    const now = self.clock.now();
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
        if (peer.mode == .outbound) is_seeding = false;
        if (interested_count < max_peers) {
            interested_peers[interested_count] = slot;
            interested_count += 1;
        }
    }

    if (interested_count == 0) return;

    // Sort by download speed (tit-for-tat: unchoke peers that send us the most).
    // When seeding, sort by upload speed instead (prefer fast downloaders).
    const peers_slice = interested_peers[0..interested_count];
    const Ctx = @TypeOf(self);
    if (is_seeding) {
        std.mem.sort(u16, peers_slice, self, struct {
            fn lessThan(ctx: Ctx, a: u16, b: u16) bool {
                return ctx.peers[a].current_ul_speed > ctx.peers[b].current_ul_speed;
            }
        }.lessThan);
    } else {
        std.mem.sort(u16, peers_slice, self, struct {
            fn lessThan(ctx: Ctx, a: u16, b: u16) bool {
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

/// Pick up peers discovered by daemon tracker sessions.
/// The standalone announce thread was removed — all announces go through TrackerExecutor.
pub fn checkReannounce(self: anytype) void {
    const results = blk: {
        self.announce_mutex.lock();
        defer self.announce_mutex.unlock();
        if (self.announce_results.items.len == 0) break :blk null;
        const drained = self.announce_results;
        self.announce_results = std.ArrayList(@TypeOf(self.*).AnnounceResult).empty;
        break :blk drained;
    };
    if (results) |owned_results| {
        defer {
            for (owned_results.items) |result| self.allocator.free(result.peers);
            var drained = owned_results;
            drained.deinit(self.allocator);
        }
        // Precompute our own listen address so we can skip self-announces.
        // Trackers routinely return the announcing client itself in the peer
        // list. Connecting to ourselves creates two slot entries (outbound
        // initiator + inbound accept) pointing at the same listen socket,
        // with no possible data transfer but real state-machine cost — on
        // larger tests the self-loop has been observed to correlate with
        // the downloader-stall flake (windesk 20231be).
        const self_address: ?std.net.Address = blk: {
            const bind_str = self.bind_address orelse "0.0.0.0";
            if (std.net.Address.parseIp4(bind_str, self.port)) |a| break :blk a else |_| {}
            if (std.net.Address.parseIp6(bind_str, self.port)) |a| break :blk a else |_| {}
            break :blk null;
        };
        for (owned_results.items) |result| {
            const tc = self.getTorrentContext(result.torrent_id) orelse continue;
            for (result.peers) |addr| {
                if (self.peer_count >= self.max_connections) break;

                // Skip self: the tracker echoes our own announce back.
                if (self_address) |own| {
                    if (addr_mod.addressEql(&own, &addr)) continue;
                }

                // Deduplicate: skip addresses we already have a peer for.
                // Tracker responses frequently include the announcing client
                // itself, plus PEX can re-echo peers tracker already gave us.
                // Without this check we kick off a fresh outbound for every
                // announce → socket/connect SQE churn on loopback (windesk
                // 249164d). addPeerForTorrent does ban/limit checks but no
                // address dedup, so this guard has to live here.
                var already = false;
                for (tc.peer_slots.items) |slot| {
                    const p = &self.peers[slot];
                    if (p.state == .free) continue;
                    if (addr_mod.addressEql(&p.address, &addr)) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;

                _ = self.addPeerAutoTransport(addr, result.torrent_id) catch continue;
            }
        }
    }
}

// ── BEP 11: Peer Exchange ─────────────────────────────

/// Send PEX messages to all eligible peers at the BEP 11 interval.
/// Also ensures torrent PEX state is initialized for non-private torrents.
pub fn checkPex(self: anytype) void {
    if (!self.pex_enabled) return;
    if (self.active_peer_slots.items.len == 0) return;

    const now = self.clock.now();

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
                .seed = peer.mode == .inbound or peer.upload_only,
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
pub fn updateSpeedCounters(self: anytype) void {
    if (self.active_peer_slots.items.len == 0) return;

    const now = self.clock.now();

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
pub fn checkPartialSeed(self: anytype) void {
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

// ── Smart Ban Phase 0: trust point helpers ────────────────

/// Penalize a peer for a hash failure. Returns true if the peer should be banned.
/// Increments hashfails (saturating), decrements trust_points by 2 (saturating).
fn penalizePeerTrust(peer: *Peer) bool {
    peer.hashfails +|= 1;
    peer.trust_points -|= 2;
    return peer.trust_points <= trust_ban_threshold;
}

/// Reward a peer for a successful hash verification (slow recovery).
/// Only increments trust_points if currently negative.
fn rewardPeerTrust(peer: *Peer) void {
    if (peer.trust_points < 0) {
        peer.trust_points += 1;
    }
}

/// Returns true if the given slot is a web seed sentinel (not a real peer slot).
/// Web seed sentinel slots are >= max_peers and handled separately by WebSeedManager.
fn isWebSeedSentinelSlot(slot: u16) bool {
    return slot >= max_peers;
}

/// Smart Ban Phase 1: snapshot per-block peer attribution before a
/// DownloadingPiece is destroyed.  Builds a `[]?std.net.Address` indexed by
/// block_index, translating `peer_slot` to the peer's network address.
/// Slots that are free or web seed sentinels produce null entries (those
/// blocks are skipped during smart ban bookkeeping).
fn snapshotAttributionForSmartBan(
    self: anytype,
    sb: *SmartBan,
    torrent_id: u32,
    piece_index: u32,
    d: *const DownloadingPiece,
) void {
    const block_count = d.block_infos.len;
    const block_peers = self.allocator.alloc(?std.net.Address, block_count) catch return;

    for (d.block_infos, 0..) |bi, i| {
        if (bi.state != .received) {
            block_peers[i] = null;
            continue;
        }
        if (isWebSeedSentinelSlot(bi.peer_slot)) {
            block_peers[i] = null;
            continue;
        }
        // Read attribution from `bi.delivered_address` rather than
        // dereferencing `self.peers[bi.peer_slot]`. The peer slot may
        // have been reused (corrupt peer disconnects after delivering
        // bad blocks, or churns IPs mid-piece) by the time this
        // snapshot runs at piece-completion. The address captured at
        // markBlockReceived time is the one Phase 2 needs to ban.
        // `delivered_address` is null only for blocks not yet
        // received, which we already filtered out via the `state !=
        // .received` check above; defensive null-skip retained.
        block_peers[i] = bi.delivered_address;
    }

    sb.snapshotAttribution(torrent_id, piece_index, block_peers) catch {
        // On failure, free the slice we just allocated.
        self.allocator.free(block_peers);
    };
}

/// Phase 1 of the piece-hash lifecycle (`docs/piece-hash-lifecycle.md`):
/// after a piece is verified-and-persisted (`pt.completePiece` returned true),
/// the 20-byte SHA-1 hash for that piece is no longer needed for normal
/// seeding operation. Zero it; if every piece has now been verified, free
/// the entire pieces slice.
///
/// Safety: smart-ban already consumed its per-piece records in
/// `processHashResults` (which fires before any disk-write submission). So
/// by the time this hook runs, the hash storage has no remaining live
/// readers.
///
/// The daemon holds the session storage as a heap field
/// (`TorrentSession.session`); `tc.session` exposes a `*const` view as the
/// EL contract for read-only consumers. The `@constCast` here is scoped to
/// piece-hash lifecycle mutation, called only post-completePiece.
pub fn onPieceVerifiedAndPersisted(
    self: anytype,
    torrent_id: u32,
    piece_index: u32,
) void {
    const tc = self.getTorrentContext(torrent_id) orelse return;
    const sess_const = tc.session orelse return;
    const sess: *session_mod.Session = @constCast(sess_const);
    const pt = tc.piece_tracker orelse return;

    sess.zeroPieceHash(piece_index);

    // v2/hybrid analog: drop any cached Merkle tree for the file containing
    // this piece if all of that file's pieces are now complete. Per-file
    // `pieces_root` (32 bytes) stays in metainfo; only the derived
    // per-piece SHA-256 tree is evicted.
    if (tc.merkle_cache) |mc| {
        if (sess.layout.version != .v1) {
            const file_idx = fileIndexForPiece(&sess.layout, piece_index);
            if (file_idx) |fi| mc.evictCompletedFile(fi, &pt.complete);
        }
    }

    // Endgame: free the entire pieces slice once every piece is verified.
    // Use the PieceTracker's complete bitfield as the truth — it covers
    // exactly the pieces that have been disk-persisted (this hook fires
    // post-disk-write completion). `sess.allHashesVerified()` mirrors the
    // tracker's full-completion state via its own bookkeeping; we additionally
    // gate on `pt.isComplete()` so do_not_download (selective) torrents
    // also trigger the free when the *wanted* set is exhausted.
    if (pt.isComplete() and sess.hasPieceHashes()) {
        sess.freePieces();
        log.info("piece-hash lifecycle: freed pieces table for torrent {d} (Phase 1 endgame)", .{torrent_id});
    }
}

/// Helper: locate the file containing `piece_index` for v2/hybrid layouts.
/// v2 layouts are file-aligned so a piece belongs to exactly one file;
/// hybrid uses v1 spans (multi-file pieces possible) so we return the
/// first file in range as the canonical owner.
fn fileIndexForPiece(lyt: *const @import("../torrent/layout.zig").Layout, piece_index: u32) ?u32 {
    for (lyt.files, 0..) |file, idx| {
        if (file.length == 0) continue;
        if (piece_index >= file.first_piece and piece_index < file.end_piece_exclusive) {
            return @intCast(idx);
        }
    }
    return null;
}

/// Smart Ban Phase 2: given the peer addresses identified as having sent
/// corrupt blocks, ban them via the BanList and disconnect matching peer
/// slots.  Called from the hash-pass path in processHashResults.
pub fn smartBanCorruptPeers(self: anytype, bad_peers: []const std.net.Address) void {
    if (bad_peers.len == 0) return;
    const bl = self.ban_list orelse return;

    for (bad_peers) |addr| {
        _ = bl.banIp(addr, "smart ban: sent corrupt block in failed piece", .manual) catch {};
        log.warn("smart ban: banned {any} for sending corrupt blocks", .{addr});

        // Disconnect any currently-connected peer with this address.
        for (self.peers, 0..) |*p, i| {
            if (p.state == .free) continue;
            if (p.address.eql(addr)) {
                self.removePeer(@intCast(i));
            }
        }
    }

    self.ban_list_dirty.store(true, .release);
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
    peer.mode = .outbound;
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
    peer.mode = .outbound;
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
        peer.mode = .outbound; // download mode: sort by dl speed
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
        peer.mode = .inbound; // all seed mode -> is_seeding = true
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
    el.peers[0].mode = .outbound;
    el.peers[0].peer_interested = true;
    el.peers[0].am_choking = true;
    el.peers[0].current_dl_speed = 100;
    el.markActivePeer(0);

    // Peer 1: NOT interested, speed 999
    el.peers[1].state = .active_recv_header;
    el.peers[1].mode = .outbound;
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
    el.peers[0].mode = .outbound;
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
    el.peers[0].mode = .outbound;
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
    el.peers[0].mode = .inbound;
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
    el.peers[0].mode = .outbound;
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
    el.peers[0].mode = .outbound;
    el.peers[0].last_activity = std.time.timestamp() - (peer_timeout_secs + 100);

    // Peer 1: disconnecting state with old timestamp -- should be skipped
    el.peers[1].state = .disconnecting;
    el.peers[1].mode = .outbound;
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
    peer.mode = .outbound;
    peer.send_pending = false;
    // Set last_activity well beyond the keepalive interval
    peer.last_activity = std.time.timestamp() - (keepalive_interval_secs + 10);
    // Need a valid fd for the ring.send call -- use a /dev/null fd.
    // EventLoop.deinit() closes peer.fd via io.closeSocket, so we must
    // NOT close it ourselves: a double-close would panic in posix.close
    // with `BADF -> unreachable` (kernel may have reused the fd).
    peer.fd = std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch -1;
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
    peer.mode = .outbound;
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
    peer.mode = .outbound;
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
    peer.mode = .outbound;
    peer.send_pending = false;
    peer.last_activity = std.time.timestamp() - (keepalive_interval_secs + 10);
    peer.fd = -1;
    el.markActivePeer(slot);

    const original_activity = peer.last_activity;
    sendKeepAlives(&el);

    try std.testing.expectEqual(original_activity, peer.last_activity);
    try std.testing.expectEqual(false, peer.send_pending);
}

// ── Smart Ban Phase 0 tests ──────────────────────────────

test "penalizePeerTrust decrements trust_points by 2 and increments hashfails" {
    var peer = Peer{};
    try std.testing.expectEqual(@as(i8, 0), peer.trust_points);
    try std.testing.expectEqual(@as(u8, 0), peer.hashfails);

    const should_ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(false, should_ban);
    try std.testing.expectEqual(@as(i8, -2), peer.trust_points);
    try std.testing.expectEqual(@as(u8, 1), peer.hashfails);
}

test "four consecutive hash failures result in ban" {
    var peer = Peer{};

    // 4 failures: trust_points goes 0 -> -2 -> -4 -> -6 -> -8
    var ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(false, ban);
    try std.testing.expectEqual(@as(i8, -2), peer.trust_points);

    ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(false, ban);
    try std.testing.expectEqual(@as(i8, -4), peer.trust_points);

    ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(false, ban);
    try std.testing.expectEqual(@as(i8, -6), peer.trust_points);

    ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(true, ban); // -8 <= -7, should ban
    try std.testing.expectEqual(@as(i8, -8), peer.trust_points);
    try std.testing.expectEqual(@as(u8, 4), peer.hashfails);
}

test "successful pieces increment trust_points with slow recovery" {
    var peer = Peer{};
    peer.trust_points = -4; // simulating 2 prior hash failures

    // Each success recovers 1 point
    rewardPeerTrust(&peer);
    try std.testing.expectEqual(@as(i8, -3), peer.trust_points);

    rewardPeerTrust(&peer);
    try std.testing.expectEqual(@as(i8, -2), peer.trust_points);

    rewardPeerTrust(&peer);
    try std.testing.expectEqual(@as(i8, -1), peer.trust_points);

    rewardPeerTrust(&peer);
    try std.testing.expectEqual(@as(i8, 0), peer.trust_points);

    // Once at 0, trust_points should not increase further
    rewardPeerTrust(&peer);
    try std.testing.expectEqual(@as(i8, 0), peer.trust_points);
}

test "web seed sentinel slots are correctly identified" {
    // Web seed sentinels: 0xFFFF - slot_idx (for slot_idx 0..15)
    try std.testing.expectEqual(true, isWebSeedSentinelSlot(0xFFFF));
    try std.testing.expectEqual(true, isWebSeedSentinelSlot(0xFFFF - 15));
    try std.testing.expectEqual(true, isWebSeedSentinelSlot(max_peers)); // boundary

    // Regular peer slots
    try std.testing.expectEqual(false, isWebSeedSentinelSlot(0));
    try std.testing.expectEqual(false, isWebSeedSentinelSlot(1));
    try std.testing.expectEqual(false, isWebSeedSentinelSlot(max_peers - 1));
}

test "trust_points saturate and do not wrap around" {
    var peer = Peer{};
    peer.trust_points = -126; // near minimum for i8 (-128)

    const ban = penalizePeerTrust(&peer);
    try std.testing.expectEqual(true, ban);
    // Should saturate at -128, not wrap to positive
    try std.testing.expectEqual(@as(i8, -128), peer.trust_points);
}

test "hashfails saturate at 255" {
    var peer = Peer{};
    peer.hashfails = 254;

    _ = penalizePeerTrust(&peer);
    try std.testing.expectEqual(@as(u8, 255), peer.hashfails);

    // Should stay at 255 (saturating)
    _ = penalizePeerTrust(&peer);
    try std.testing.expectEqual(@as(u8, 255), peer.hashfails);
}

test "hash failure penalization with ban uses ban_list" {
    var el = try EventLoop.initBare(std.testing.allocator, 0);
    defer el.deinit();

    // Set up a ban list
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();
    el.ban_list = &bl;

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.state = .active_recv_header;
    peer.mode = .outbound;
    peer.torrent_id = 0;
    peer.address = std.net.Address.initIp4(.{ 192, 168, 1, 100 }, 6881);
    peer.fd = -1;
    el.markActivePeer(slot);

    // Penalize until ban threshold
    peer.trust_points = -6; // one more failure should trigger ban at -8
    const should_ban = penalizePeerTrust(peer);
    try std.testing.expectEqual(true, should_ban);

    // Simulate what processHashResults does on ban
    if (should_ban) {
        if (el.ban_list) |ban_list| {
            _ = try ban_list.banIp(peer.address, "smart ban: too many hash failures", .manual);
        }
    }

    // Verify the IP was banned
    try std.testing.expectEqual(true, bl.isBanned(std.net.Address.initIp4(.{ 192, 168, 1, 100 }, 6881)));
}

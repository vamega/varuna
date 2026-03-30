const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const storage = @import("../storage/root.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const decodeUserData = @import("event_loop.zig").decodeUserData;

// ── Piece upload (seed mode) ─────────────────────────

pub fn servePieceRequest(self: *EventLoop, slot: u16, payload: []const u8) void {
    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
    const block_offset = std.mem.readInt(u32, payload[4..8], .big);
    const block_length = std.mem.readInt(u32, payload[8..12], .big);

    const peer = &self.peers[slot];

    // Check upload rate limit -- drop request if throttled
    if (self.isUploadThrottled(peer.torrent_id)) return;

    const tc = self.getTorrentContext(peer.torrent_id) orelse return;
    const sess = tc.session orelse return;

    // Validate
    // Use per-torrent complete_pieces, falling back to global
    const cp = tc.complete_pieces orelse self.complete_pieces orelse return;
    if (!cp.has(piece_index)) return;
    const piece_size = sess.layout.pieceSize(piece_index) catch return;
    if (block_offset + block_length > piece_size) return;

    // If piece is cached, queue for batched send (flushed after CQE dispatch)
    if (self.cached_piece_index != null and self.cached_piece_index.? == piece_index) {
        self.queued_responses.append(self.allocator, .{
            .slot = slot,
            .piece_index = piece_index,
            .block_offset = block_offset,
            .block_length = block_length,
        }) catch |err| {
            log.warn("queue cached piece response: {s}", .{@errorName(err)});
        };
        return;
    }

    // Submit async io_uring reads for all spans (no blocking)
    const plan = storage.verify.planPieceVerification(self.allocator, sess, piece_index) catch return;
    defer storage.verify.freePiecePlan(self.allocator, plan);

    if (plan.spans.len == 0) return;

    const read_buf = self.allocator.alloc(u8, piece_size) catch return;
    const span_count: u32 = @intCast(plan.spans.len);

    self.pending_reads.append(self.allocator, .{
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .read_buf = read_buf,
        .piece_size = piece_size,
        .reads_remaining = span_count,
    }) catch {
        self.allocator.free(read_buf);
        return;
    };

    // Submit one io_uring read per span (all non-blocking)
    for (plan.spans) |span| {
        const target = read_buf[span.piece_offset .. span.piece_offset + span.length];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_read, .context = @intCast(piece_index) });
        _ = self.ring.read(ud, tc.shared_fds[span.file_index], .{ .buffer = target }, span.file_offset) catch |err| {
            log.warn("disk read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
        };
    }
}

pub fn handleSeedDiskRead(self: *EventLoop, cqe: @import("std").os.linux.io_uring_cqe) void {
    const op = decodeUserData(cqe.user_data);
    const piece_index: u32 = @intCast(op.context);
    const PendingPieceRead = EventLoop.PendingPieceRead;

    // Find the matching pending read and decrement reads_remaining
    for (self.pending_reads.items) |*pr| {
        if (pr.piece_index == piece_index and pr.slot == op.slot) {
            if (cqe.res <= 0) {
                // Read failed -- abort this pending read entirely
                pr.reads_remaining = 0;
                self.allocator.free(pr.read_buf);
                // Remove from list
                const idx = (@intFromPtr(pr) - @intFromPtr(self.pending_reads.items.ptr)) / @sizeOf(PendingPieceRead);
                _ = self.pending_reads.swapRemove(idx);
                return;
            }

            pr.reads_remaining -= 1;
            if (pr.reads_remaining == 0) {
                // All spans read -- update cache and send
                const pslot = pr.slot;
                const pi = pr.piece_index;
                const bo = pr.block_offset;
                const bl = pr.block_length;
                const buf = pr.read_buf;
                const ps = pr.piece_size;

                // Remove from pending list
                const idx = (@intFromPtr(pr) - @intFromPtr(self.pending_reads.items.ptr)) / @sizeOf(PendingPieceRead);
                _ = self.pending_reads.swapRemove(idx);

                // Update cache
                if (self.cached_piece_data) |old| self.allocator.free(old);
                self.cached_piece_data = buf;
                self.cached_piece_index = pi;
                self.cached_piece_len = ps;

                // Queue for batched send (flushed after CQE dispatch)
                self.queued_responses.append(self.allocator, .{
                    .slot = pslot,
                    .piece_index = pi,
                    .block_offset = bo,
                    .block_length = bl,
                }) catch {
                    // Fallback: send individually
                    sendPieceBlock(self, pslot, pi, bo, bl, buf);
                };
            }
            return;
        }
    }
}

/// Flush all queued piece block responses, batching by peer slot.
/// All blocks for a given peer are concatenated into one send buffer.
pub fn flushQueuedResponses(self: *EventLoop) void {
    const QueuedBlockResponse = EventLoop.QueuedBlockResponse;

    if (self.queued_responses.items.len == 0) return;
    const cached_data = self.cached_piece_data orelse {
        self.queued_responses.items.len = 0;
        return;
    };

    // Process all queued responses, grouping by slot.
    // Since most responses in a tick are for the same peer, we use a simple
    // approach: sort by slot, then batch consecutive entries.
    const items = self.queued_responses.items;

    // Sort by slot for grouping
    std.mem.sort(QueuedBlockResponse, items, {}, struct {
        fn lessThan(_: void, a: QueuedBlockResponse, b: QueuedBlockResponse) bool {
            return a.slot < b.slot;
        }
    }.lessThan);

    var i: usize = 0;
    while (i < items.len) {
        const current_slot = items[i].slot;

        // Find end of this peer's batch
        var j = i + 1;
        while (j < items.len and items[j].slot == current_slot) j += 1;
        const batch = items[i..j];

        // Calculate total send buffer size
        var total_len: usize = 0;
        for (batch) |resp| {
            total_len += 4 + 1 + 8 + @as(usize, resp.block_length); // len_prefix + msg_id + piece_index + offset + data
        }

        // Allocate single buffer for all blocks
        const send_buf = self.allocator.alloc(u8, total_len) catch {
            // Fallback: send individually
            for (batch) |resp| {
                sendPieceBlock(self, resp.slot, resp.piece_index, resp.block_offset, resp.block_length, cached_data);
            }
            i = j;
            continue;
        };

        // Pack all block responses into the buffer
        var offset: usize = 0;
        var total_uploaded: u64 = 0;
        for (batch) |resp| {
            const msg_len: u32 = 1 + 8 + resp.block_length;
            std.mem.writeInt(u32, send_buf[offset..][0..4], msg_len, .big);
            send_buf[offset + 4] = 7; // piece message id
            std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], resp.piece_index, .big);
            std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], resp.block_offset, .big);
            const data_start: usize = @intCast(resp.block_offset);
            @memcpy(send_buf[offset + 13 ..][0..resp.block_length], cached_data[data_start..][0..resp.block_length]);
            offset += 4 + 1 + 8 + @as(usize, resp.block_length);
            total_uploaded += resp.block_length;
        }

        const peer = &self.peers[current_slot];

        // Skip if peer disconnected between queueing and flushing
        if (peer.state == .free or peer.state == .disconnecting) {
            self.allocator.free(send_buf);
            i = j;
            continue;
        }

        // Consume upload tokens for rate limiting
        _ = self.consumeUploadTokens(peer.torrent_id, total_uploaded);

        peer.bytes_uploaded_to += total_uploaded;

        self.pending_sends.append(self.allocator, .{
            .buf = send_buf,
            .slot = current_slot,
        }) catch {
            self.allocator.free(send_buf);
            i = j;
            continue;
        };

        const ud = encodeUserData(.{ .slot = current_slot, .op_type = .peer_send, .context = 1 });
        _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
            // SQE submission failed -- free via the pending_sends entry
            // to avoid leaving a dangling pointer in the list.
            self.freeOnePendingSend(current_slot);
            i = j;
            continue;
        };
        peer.send_pending = true;

        i = j;
    }

    self.queued_responses.items.len = 0;
}

pub fn sendPieceBlock(self: *EventLoop, slot: u16, piece_index: u32, block_offset: u32, block_length: u32, read_buf: []u8) void {
    const peer = &self.peers[slot];

    // Check upload rate limit
    if (self.isUploadThrottled(peer.torrent_id)) return;

    const msg_len: u32 = 1 + 8 + block_length;
    const total_len: usize = 4 + @as(usize, msg_len);
    const send_buf = self.allocator.alloc(u8, total_len) catch return;

    std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
    send_buf[4] = 7;
    std.mem.writeInt(u32, send_buf[5..9], piece_index, .big);
    std.mem.writeInt(u32, send_buf[9..13], block_offset, .big);
    @memcpy(send_buf[13..total_len], read_buf[@intCast(block_offset)..][0..block_length]);

    // Consume upload tokens
    _ = self.consumeUploadTokens(peer.torrent_id, block_length);
    peer.bytes_uploaded_to += block_length;

    self.pending_sends.append(self.allocator, .{
        .buf = send_buf,
        .slot = slot,
    }) catch {
        self.allocator.free(send_buf);
        return;
    };

    const ud = encodeUserData(.{ .slot = slot, .op_type = .peer_send, .context = 1 });
    _ = self.ring.send(ud, peer.fd, send_buf, 0) catch {
        // SQE submission failed -- free via the pending_sends entry
        // (not directly) to avoid leaving a dangling pointer.
        self.freeOnePendingSend(slot);
        return;
    };
    peer.send_pending = true;
}

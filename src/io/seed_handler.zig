const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const storage = @import("../storage/root.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const decodeUserData = @import("event_loop.zig").decodeUserData;

// ── Piece upload (seed mode) ─────────────────────────

fn nextSeedReadId(self: *EventLoop) u32 {
    const read_id = self.next_seed_read_id;
    self.next_seed_read_id +%= 1;
    if (self.next_seed_read_id == 0) self.next_seed_read_id = 1;
    return read_id;
}

fn findPendingSeedReadIndex(items: []const EventLoop.PendingPieceRead, read_id: u32) ?usize {
    for (items, 0..) |pr, i| {
        if (pr.read_id == read_id) return i;
    }
    return null;
}

fn copyQueuedBlockData(
    allocator: std.mem.Allocator,
    piece_data: []const u8,
    block_offset: u32,
    block_length: u32,
) ![]u8 {
    const start: usize = @intCast(block_offset);
    const len: usize = @intCast(block_length);
    if (start + len > piece_data.len) return error.InvalidBlockRange;

    const block = try allocator.alloc(u8, len);
    @memcpy(block, piece_data[start..][0..len]);
    return block;
}

fn queuePieceBlockResponse(
    self: *EventLoop,
    slot: u16,
    piece_index: u32,
    block_offset: u32,
    block_length: u32,
    piece_data: []const u8,
) !void {
    const block_data = try copyQueuedBlockData(self.allocator, piece_data, block_offset, block_length);
    errdefer self.allocator.free(block_data);

    try self.queued_responses.append(self.allocator, .{
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .block_data = block_data,
    });
}

fn freeQueuedBatchBlocks(self: *EventLoop, batch: []const EventLoop.QueuedBlockResponse) void {
    for (batch) |resp| {
        self.allocator.free(resp.block_data);
    }
}

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
        if (self.cached_piece_data) |cached_data| {
            queuePieceBlockResponse(self, slot, piece_index, block_offset, block_length, cached_data) catch |err| {
                log.warn("queue cached piece response: {s}", .{@errorName(err)});
            };
            return;
        }
    }

    // Submit async io_uring reads for all spans (no blocking)
    const plan = storage.verify.planPieceVerification(self.allocator, sess, piece_index) catch return;
    defer storage.verify.freePiecePlan(self.allocator, plan);

    if (plan.spans.len == 0) return;

    const read_buf = self.allocator.alloc(u8, piece_size) catch return;
    const read_id = nextSeedReadId(self);

    self.pending_reads.append(self.allocator, .{
        .read_id = read_id,
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .read_buf = read_buf,
        .piece_size = piece_size,
        .reads_remaining = 0,
    }) catch {
        self.allocator.free(read_buf);
        return;
    };

    const pending_index = self.pending_reads.items.len - 1;
    var submitted_reads: u32 = 0;

    // Submit one io_uring read per span (all non-blocking)
    for (plan.spans) |span| {
        const target = read_buf[span.piece_offset .. span.piece_offset + span.length];
        const ud = encodeUserData(.{ .slot = slot, .op_type = .disk_read, .context = @intCast(read_id) });
        _ = self.ring.read(ud, tc.shared_fds[span.file_index], .{ .buffer = target }, span.file_offset) catch |err| {
            log.warn("disk read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
            continue;
        };
        submitted_reads += 1;
    }

    if (submitted_reads == 0) {
        _ = self.pending_reads.pop();
        self.allocator.free(read_buf);
        return;
    }

    self.pending_reads.items[pending_index].reads_remaining = submitted_reads;
}

pub fn handleSeedDiskRead(self: *EventLoop, cqe: @import("std").os.linux.io_uring_cqe) void {
    const op = decodeUserData(cqe.user_data);
    const read_id: u32 = @intCast(op.context);

    const idx = findPendingSeedReadIndex(self.pending_reads.items, read_id) orelse return;
    var pending = self.pending_reads.items[idx];

    if (cqe.res <= 0) {
        self.allocator.free(pending.read_buf);
        _ = self.pending_reads.swapRemove(idx);
        return;
    }

    pending.reads_remaining -= 1;
    if (pending.reads_remaining > 0) {
        self.pending_reads.items[idx] = pending;
        return;
    }

    // All spans read -- remove from pending list before queueing/sending.
    _ = self.pending_reads.swapRemove(idx);

    // Update cache
    if (self.cached_piece_data) |old| self.allocator.free(old);
    self.cached_piece_data = pending.read_buf;
    self.cached_piece_index = pending.piece_index;
    self.cached_piece_len = pending.piece_size;

    // Queue for batched send (flushed after CQE dispatch)
    queuePieceBlockResponse(
        self,
        pending.slot,
        pending.piece_index,
        pending.block_offset,
        pending.block_length,
        pending.read_buf,
    ) catch {
        // Fallback: send individually
        sendPieceBlock(self, pending.slot, pending.piece_index, pending.block_offset, pending.block_length, pending.read_buf);
    };
}

/// Flush all queued piece block responses, batching by peer slot.
/// All blocks for a given peer are concatenated into one send buffer.
pub fn flushQueuedResponses(self: *EventLoop) void {
    const QueuedBlockResponse = EventLoop.QueuedBlockResponse;

    if (self.queued_responses.items.len == 0) return;

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
        const peer = &self.peers[current_slot];

        // Skip if peer disconnected between queueing and flushing
        if (peer.state == .free or peer.state == .disconnecting) {
            freeQueuedBatchBlocks(self, batch);
            i = j;
            continue;
        }

        // Calculate total send buffer size
        var total_len: usize = 0;
        for (batch) |resp| {
            total_len += 4 + 1 + 8 + @as(usize, resp.block_length); // len_prefix + msg_id + piece_index + offset + data
        }

        // Allocate single buffer for all blocks
        const send_buf = self.allocator.alloc(u8, total_len) catch {
            // Fallback: send individually
            for (batch) |resp| {
                sendPieceBlockData(self, resp.slot, resp.piece_index, resp.block_offset, resp.block_data);
                self.allocator.free(resp.block_data);
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
            @memcpy(send_buf[offset + 13 ..][0..resp.block_length], resp.block_data);
            self.allocator.free(resp.block_data);
            offset += 4 + 1 + 8 + @as(usize, resp.block_length);
            total_uploaded += resp.block_length;
        }

        // Consume upload tokens for rate limiting
        _ = self.consumeUploadTokens(peer.torrent_id, total_uploaded);

        peer.bytes_uploaded_to += total_uploaded;

        const ts = self.nextTrackedSendUserData(current_slot);
        self.pending_sends.append(self.allocator, .{
            .buf = send_buf,
            .slot = current_slot,
            .send_id = ts.send_id,
        }) catch {
            self.allocator.free(send_buf);
            i = j;
            continue;
        };

        _ = self.ring.send(ts.ud, peer.fd, send_buf, 0) catch {
            // SQE submission failed -- free via the pending_sends entry
            // to avoid leaving a dangling pointer in the list.
            self.freeOnePendingSend(current_slot, ts.send_id);
            i = j;
            continue;
        };
        peer.send_pending = true;

        i = j;
    }

    self.queued_responses.items.len = 0;
}

pub fn sendPieceBlock(self: *EventLoop, slot: u16, piece_index: u32, block_offset: u32, block_length: u32, read_buf: []u8) void {
    const start: usize = @intCast(block_offset);
    const len: usize = @intCast(block_length);
    if (start + len > read_buf.len) return;
    sendPieceBlockData(self, slot, piece_index, block_offset, read_buf[start..][0..len]);
}

fn sendPieceBlockData(self: *EventLoop, slot: u16, piece_index: u32, block_offset: u32, block_data: []const u8) void {
    const peer = &self.peers[slot];

    // Check upload rate limit
    if (self.isUploadThrottled(peer.torrent_id)) return;

    const block_length: u32 = @intCast(block_data.len);
    const msg_len: u32 = 1 + 8 + block_length;
    const total_len: usize = 4 + @as(usize, msg_len);
    const send_buf = self.allocator.alloc(u8, total_len) catch return;

    std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
    send_buf[4] = 7;
    std.mem.writeInt(u32, send_buf[5..9], piece_index, .big);
    std.mem.writeInt(u32, send_buf[9..13], block_offset, .big);
    @memcpy(send_buf[13..total_len], block_data);

    // Consume upload tokens
    _ = self.consumeUploadTokens(peer.torrent_id, block_length);
    peer.bytes_uploaded_to += block_length;

    const ts = self.nextTrackedSendUserData(slot);
    self.pending_sends.append(self.allocator, .{
        .buf = send_buf,
        .slot = slot,
        .send_id = ts.send_id,
    }) catch {
        self.allocator.free(send_buf);
        return;
    };

    _ = self.ring.send(ts.ud, peer.fd, send_buf, 0) catch {
        // SQE submission failed -- free via the pending_sends entry
        // (not directly) to avoid leaving a dangling pointer.
        self.freeOnePendingSend(slot, ts.send_id);
        return;
    };
    peer.send_pending = true;
}

test "copyQueuedBlockData makes an independent block copy" {
    var source = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f' };
    const block = try copyQueuedBlockData(std.testing.allocator, source[0..], 2, 3);
    defer std.testing.allocator.free(block);

    source[2] = 'X';
    try std.testing.expectEqualStrings("cde", block);
}

test "findPendingSeedReadIndex matches by unique read id" {
    var dummy: [1]u8 = .{0};
    const reads = [_]EventLoop.PendingPieceRead{
        .{
            .read_id = 11,
            .slot = 3,
            .piece_index = 7,
            .block_offset = 0,
            .block_length = 16,
            .read_buf = dummy[0..0],
            .piece_size = 16,
            .reads_remaining = 1,
        },
        .{
            .read_id = 12,
            .slot = 3,
            .piece_index = 7,
            .block_offset = 16,
            .block_length = 16,
            .read_buf = dummy[0..0],
            .piece_size = 16,
            .reads_remaining = 1,
        },
    };

    try std.testing.expectEqual(@as(?usize, 0), findPendingSeedReadIndex(reads[0..], 11));
    try std.testing.expectEqual(@as(?usize, 1), findPendingSeedReadIndex(reads[0..], 12));
    try std.testing.expectEqual(@as(?usize, null), findPendingSeedReadIndex(reads[0..], 99));
}

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.event_loop);
const storage = @import("../storage/root.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const encodeUserData = @import("event_loop.zig").encodeUserData;
const decodeUserData = @import("event_loop.zig").decodeUserData;
const LayoutSpan = @import("../torrent/layout.zig").Layout.Span;
const utp_handler = @import("utp_handler.zig");

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

fn encodeSeedReadContext(read_id: u32, span_index: u8) u40 {
    return @as(u40, read_id) | (@as(u40, span_index) << 32);
}

fn decodeSeedReadContext(context: u40) struct { read_id: u32, span_index: u8 } {
    return .{
        .read_id = @truncate(context),
        .span_index = @truncate(context >> 32),
    };
}

fn queuePieceBlockResponse(
    self: *EventLoop,
    slot: u16,
    piece_index: u32,
    block_offset: u32,
    block_length: u32,
    piece_buffer: *EventLoop.PieceBuffer,
) !void {
    const start: usize = @intCast(block_offset);
    const len: usize = @intCast(block_length);
    if (start + len > piece_buffer.buf.len) return error.InvalidBlockRange;

    try self.queued_responses.append(self.allocator, .{
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .piece_buffer = piece_buffer,
    });
}

fn deferCachedPieceBuffer(self: *EventLoop, piece_buffer: *EventLoop.PieceBuffer) void {
    self.deferred_piece_buffers.append(self.allocator, .{
        .piece_buffer = piece_buffer,
    }) catch {
        // Keep the old buffer alive if we can't queue it for deferred release.
        // This avoids invalidating queued response slices before the next flush.
    };
}

fn releaseDeferredPieceBuffers(self: *EventLoop) void {
    for (self.deferred_piece_buffers.items) |piece_buf| {
        self.releasePieceBuffer(piece_buf.piece_buffer);
    }
    self.deferred_piece_buffers.clearRetainingCapacity();
}

fn createPlaintextBatchSendState(
    self: *EventLoop,
    batch: []const EventLoop.QueuedBlockResponse,
) !*EventLoop.VectoredSendState {
    const state = try self.acquireVectoredSendState(batch.len);
    const headers = state.headers;
    const iovecs = state.iovecs;
    const piece_buffers = state.piece_buffers;
    var retained: usize = 0;
    errdefer {
        for (piece_buffers[0..retained]) |piece_buffer| {
            self.releasePieceBuffer(piece_buffer);
        }
        self.vectored_send_pool.release(self.allocator, state);
    }

    for (batch, 0..) |resp, idx| {
        const header = &headers[idx];
        const block_len: usize = @intCast(resp.block_length);
        const start: usize = @intCast(resp.block_offset);
        const block_data = resp.piece_buffer.buf[start .. start + block_len];
        const msg_len: u32 = 1 + 8 + resp.block_length;

        std.mem.writeInt(u32, header[0..4], msg_len, .big);
        header[4] = 7;
        std.mem.writeInt(u32, header[5..9], resp.piece_index, .big);
        std.mem.writeInt(u32, header[9..13], resp.block_offset, .big);

        iovecs[idx * 2] = .{
            .base = @ptrCast(header),
            .len = header.len,
        };
        iovecs[idx * 2 + 1] = .{
            .base = block_data.ptr,
            .len = block_data.len,
        };

        self.retainPieceBuffer(resp.piece_buffer);
        piece_buffers[idx] = resp.piece_buffer;
        retained += 1;
    }

    state.* = .{
        .backing = state.backing,
        .backing_capacity = state.backing_capacity,
        .pool_class = state.pool_class,
        .headers = headers,
        .iovecs = iovecs,
        .msg = .{
            .name = null,
            .namelen = 0,
            .iov = iovecs.ptr,
            .iovlen = iovecs.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        },
        .piece_buffers = piece_buffers,
        .iov_index = 0,
    };
    return state;
}

fn submitPlaintextPieceBatch(self: *EventLoop, slot: u16, batch: []const EventLoop.QueuedBlockResponse) bool {
    const peer = &self.peers[slot];
    const state = createPlaintextBatchSendState(self, batch) catch return false;

    const ts = self.nextTrackedSendUserData(slot);
    self.trackPendingSendVectored(slot, ts.send_id, state) catch return false;

    _ = self.ring.sendmsg(ts.ud, peer.fd, &state.msg, 0) catch {
        self.freeOnePendingSend(slot, ts.send_id);
        return false;
    };
    peer.send_pending = true;
    return true;
}

fn submitCopiedPieceBatch(self: *EventLoop, slot: u16, batch: []const EventLoop.QueuedBlockResponse) bool {
    const peer = &self.peers[slot];

    var total_len: usize = 0;
    for (batch) |resp| {
        total_len += 4 + 1 + 8 + @as(usize, resp.block_length);
    }

    const send_buf = self.allocator.alloc(u8, total_len) catch return false;

    var offset: usize = 0;
    for (batch) |resp| {
        const msg_len: u32 = 1 + 8 + resp.block_length;
        std.mem.writeInt(u32, send_buf[offset..][0..4], msg_len, .big);
        send_buf[offset + 4] = 7;
        std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], resp.piece_index, .big);
        std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], resp.block_offset, .big);
        const start: usize = @intCast(resp.block_offset);
        const len: usize = @intCast(resp.block_length);
        @memcpy(send_buf[offset + 13 ..][0..len], resp.piece_buffer.buf[start .. start + len]);
        offset += 13 + len;
    }

    peer.crypto.encryptBuf(send_buf);

    const ts = self.nextTrackedSendUserData(slot);
    const tracked = self.trackPendingSendOwned(slot, ts.send_id, send_buf) catch {
        self.allocator.free(send_buf);
        return false;
    };

    _ = self.ring.send(ts.ud, peer.fd, tracked, 0) catch {
        self.freeOnePendingSend(slot, ts.send_id);
        return false;
    };
    peer.send_pending = true;
    return true;
}

/// Send piece block responses over uTP. Serializes each block as a framed
/// PIECE message and routes it through the uTP byte stream.
fn submitUtpPieceBatch(self: *EventLoop, slot: u16, batch: []const EventLoop.QueuedBlockResponse) bool {
    for (batch) |resp| {
        const block_len: usize = @intCast(resp.block_length);
        const start: usize = @intCast(resp.block_offset);
        const block_data = resp.piece_buffer.buf[start .. start + block_len];

        // Build PIECE message payload: index(4) + begin(4) + block data
        const payload_len = 8 + block_len;
        const send_buf = self.allocator.alloc(u8, payload_len) catch return false;
        defer self.allocator.free(send_buf);

        std.mem.writeInt(u32, send_buf[0..4], resp.piece_index, .big);
        std.mem.writeInt(u32, send_buf[4..8], resp.block_offset, .big);
        @memcpy(send_buf[8..][0..block_len], block_data);

        // Message ID 7 = piece
        utp_handler.utpSendMessage(self, slot, 7, send_buf) catch return false;
    }
    return true;
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
    // Reject unreasonably large blocks (standard is 16 KiB, cap at 128 KiB)
    if (block_length > 128 * 1024) return;
    // Use u64 arithmetic to prevent u32 overflow in offset+length check
    if (@as(u64, block_offset) + @as(u64, block_length) > piece_size) return;

    // If piece is cached, queue for batched send (flushed after CQE dispatch)
    if (self.cached_piece_index != null and self.cached_piece_index.? == piece_index) {
        if (self.cached_piece_buffer) |cached_piece| {
            queuePieceBlockResponse(self, slot, piece_index, block_offset, block_length, cached_piece) catch |err| {
                log.warn("queue cached piece response: {s}", .{@errorName(err)});
            };
            return;
        }
    }

    // Submit async io_uring reads for all spans (no blocking)
    var span_scratch: [8]LayoutSpan = undefined;
    const plan = storage.verify.planPieceVerificationWithScratch(self.allocator, sess, piece_index, span_scratch[0..]) catch return;
    defer plan.deinit(self.allocator);

    if (plan.spans.len == 0) return;

    const piece_buffer = self.createPieceBuffer(piece_size) catch return;
    const read_id = nextSeedReadId(self);

    self.pending_reads.append(self.allocator, .{
        .read_id = read_id,
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .piece_buffer = piece_buffer,
        .reads_remaining = 0,
        .submitted_span_count = 0,
    }) catch {
        self.releasePieceBuffer(piece_buffer);
        return;
    };

    const pending_index = self.pending_reads.items.len - 1;
    var submitted_reads: u32 = 0;

    // Submit one io_uring read per span (all non-blocking)
    for (plan.spans, 0..) |span, span_index| {
        const target = piece_buffer.buf[span.piece_offset .. span.piece_offset + span.length];
        const ud = encodeUserData(.{
            .slot = slot,
            .op_type = .disk_read,
            .context = encodeSeedReadContext(read_id, @intCast(span_index)),
        });
        _ = self.ring.read(ud, tc.shared_fds[span.file_index], .{ .buffer = target }, span.file_offset) catch |err| {
            log.warn("disk read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
            continue;
        };
        self.pending_reads.items[pending_index].expected_read_lengths[submitted_reads] = @intCast(span.length);
        submitted_reads += 1;
    }

    if (submitted_reads == 0) {
        _ = self.pending_reads.pop();
        self.releasePieceBuffer(piece_buffer);
        return;
    }

    self.pending_reads.items[pending_index].reads_remaining = submitted_reads;
    self.pending_reads.items[pending_index].submitted_span_count = @intCast(submitted_reads);
}

pub fn handleSeedDiskRead(self: *EventLoop, cqe: @import("std").os.linux.io_uring_cqe) void {
    const op = decodeUserData(cqe.user_data);
    const read_ctx = decodeSeedReadContext(op.context);
    const read_id = read_ctx.read_id;

    const idx = findPendingSeedReadIndex(self.pending_reads.items, read_id) orelse return;
    var pending = self.pending_reads.items[idx];
    if (read_ctx.span_index >= pending.submitted_span_count) {
        self.releasePieceBuffer(pending.piece_buffer);
        _ = self.pending_reads.swapRemove(idx);
        return;
    }

    if (cqe.res <= 0) {
        self.releasePieceBuffer(pending.piece_buffer);
        _ = self.pending_reads.swapRemove(idx);
        return;
    }

    const expected_len = pending.expected_read_lengths[read_ctx.span_index];
    const actual_len: u32 = @intCast(cqe.res);
    if (actual_len != expected_len) {
        self.releasePieceBuffer(pending.piece_buffer);
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
    if (self.cached_piece_buffer) |old| {
        deferCachedPieceBuffer(self, old);
    }
    self.cached_piece_buffer = pending.piece_buffer;
    self.cached_piece_index = pending.piece_index;

    // Queue for batched send (flushed after CQE dispatch)
    queuePieceBlockResponse(
        self,
        pending.slot,
        pending.piece_index,
        pending.block_offset,
        pending.block_length,
        pending.piece_buffer,
    ) catch {
        // Fallback: send individually
        sendPieceBlock(self, pending.slot, pending.piece_index, pending.block_offset, pending.block_length, pending.piece_buffer);
    };
}

/// Handle a CANCEL message: remove matching queued response so we don't
/// waste bandwidth sending a block the peer no longer wants.
pub fn cancelQueuedResponse(self: *EventLoop, slot: u16, payload: []const u8) void {
    const piece_index = std.mem.readInt(u32, payload[0..4], .big);
    const block_offset = std.mem.readInt(u32, payload[4..8], .big);
    const block_length = std.mem.readInt(u32, payload[8..12], .big);

    var i: usize = 0;
    while (i < self.queued_responses.items.len) {
        const r = self.queued_responses.items[i];
        if (r.slot == slot and r.piece_index == piece_index and
            r.block_offset == block_offset and r.block_length == block_length)
        {
            _ = self.queued_responses.swapRemove(i);
            // Don't increment i -- swapRemove moved the last element here
        } else {
            i += 1;
        }
    }
}

/// Flush all queued piece block responses, batching by peer slot.
/// All blocks for a given peer are concatenated into one send buffer.
pub fn flushQueuedResponses(self: *EventLoop) void {
    const QueuedBlockResponse = EventLoop.QueuedBlockResponse;

    if (self.queued_responses.items.len == 0) {
        releaseDeferredPieceBuffers(self);
        return;
    }

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
            i = j;
            continue;
        }

        var total_len: usize = 0;
        var total_uploaded: u64 = 0;
        for (batch) |resp| {
            total_len += 4 + 1 + 8 + @as(usize, resp.block_length);
            total_uploaded += resp.block_length;
        }

        var submitted = false;

        // uTP peers: route through the uTP byte stream instead of io_uring send.
        if (peer.transport == .utp) {
            submitted = submitUtpPieceBatch(self, current_slot, batch);
        } else {
            if (!peer.crypto.isEncrypted()) {
                submitted = submitPlaintextPieceBatch(self, current_slot, batch);
            }
            if (!submitted) {
                submitted = submitCopiedPieceBatch(self, current_slot, batch);
            }
        }

        if (submitted) {
            _ = self.consumeUploadTokens(peer.torrent_id, total_uploaded);
            peer.bytes_uploaded_to += total_uploaded;
            self.accountTorrentBytes(peer.torrent_id, 0, total_uploaded);
            i = j;
            continue;
        }

        for (batch) |resp| {
            sendPieceBlock(self, resp.slot, resp.piece_index, resp.block_offset, resp.block_length, resp.piece_buffer);
        }

        i = j;
    }

    self.queued_responses.items.len = 0;
    releaseDeferredPieceBuffers(self);
}

pub fn sendPieceBlock(self: *EventLoop, slot: u16, piece_index: u32, block_offset: u32, block_length: u32, piece_buffer: *EventLoop.PieceBuffer) void {
    const start: usize = @intCast(block_offset);
    const len: usize = @intCast(block_length);
    if (start + len > piece_buffer.buf.len) return;

    const peer = &self.peers[slot];

    // Check upload rate limit
    if (self.isUploadThrottled(peer.torrent_id)) return;

    const batch = [_]EventLoop.QueuedBlockResponse{.{
        .slot = slot,
        .piece_index = piece_index,
        .block_offset = block_offset,
        .block_length = block_length,
        .piece_buffer = piece_buffer,
    }};

    var submitted = false;

    // uTP peers: route through the uTP byte stream instead of io_uring send.
    if (peer.transport == .utp) {
        submitted = submitUtpPieceBatch(self, slot, batch[0..]);
    } else {
        if (!peer.crypto.isEncrypted()) {
            submitted = submitPlaintextPieceBatch(self, slot, batch[0..]);
        }
        if (!submitted) {
            submitted = submitCopiedPieceBatch(self, slot, batch[0..]);
        }
    }
    if (!submitted) return;

    _ = self.consumeUploadTokens(peer.torrent_id, block_length);
    peer.bytes_uploaded_to += block_length;
    self.accountTorrentBytes(peer.torrent_id, 0, block_length);
}

test "queuePieceBlockResponse stores block metadata without copying" {
    var el: EventLoop = undefined;
    el.allocator = std.testing.allocator;
    el.queued_responses = std.ArrayList(EventLoop.QueuedBlockResponse).empty;
    defer el.queued_responses.deinit(std.testing.allocator);

    var source = EventLoop.PieceBuffer{
        .buf = @constCast("abcdef"),
    };
    try queuePieceBlockResponse(&el, 3, 7, 2, 3, &source);

    try std.testing.expectEqual(@as(usize, 1), el.queued_responses.items.len);
    const queued = el.queued_responses.items[0];
    try std.testing.expectEqual(@as(u16, 3), queued.slot);
    try std.testing.expectEqual(@as(u32, 7), queued.piece_index);
    try std.testing.expectEqualStrings(source.buf, queued.piece_buffer.buf);
}

test "findPendingSeedReadIndex matches by unique read id" {
    var dummy: [1]u8 = .{0};
    var piece_a = EventLoop.PieceBuffer{ .buf = dummy[0..0] };
    var piece_b = EventLoop.PieceBuffer{ .buf = dummy[0..0] };
    const reads = [_]EventLoop.PendingPieceRead{
        .{
            .read_id = 11,
            .slot = 3,
            .piece_index = 7,
            .block_offset = 0,
            .block_length = 16,
            .piece_buffer = &piece_a,
            .reads_remaining = 1,
        },
        .{
            .read_id = 12,
            .slot = 3,
            .piece_index = 7,
            .block_offset = 16,
            .block_length = 16,
            .piece_buffer = &piece_b,
            .reads_remaining = 1,
        },
    };

    try std.testing.expectEqual(@as(?usize, 0), findPendingSeedReadIndex(reads[0..], 11));
    try std.testing.expectEqual(@as(?usize, 1), findPendingSeedReadIndex(reads[0..], 12));
    try std.testing.expectEqual(@as(?usize, null), findPendingSeedReadIndex(reads[0..], 99));
}

test "seed read context roundtrips read id and span index" {
    const encoded = encodeSeedReadContext(0x1234_5678, 7);
    const decoded = decodeSeedReadContext(encoded);

    try std.testing.expectEqual(@as(u32, 0x1234_5678), decoded.read_id);
    try std.testing.expectEqual(@as(u8, 7), decoded.span_index);
}

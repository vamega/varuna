const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.web_seed);

const EventLoop = @import("event_loop.zig").EventLoop;
const TorrentContext = @import("types.zig").TorrentContext;
const TorrentId = @import("types.zig").TorrentId;
const encodeUserData = @import("types.zig").encodeUserData;
const HttpExecutor = @import("http_executor.zig").HttpExecutor;
const WebSeedManager = @import("../net/web_seed.zig").WebSeedManager;
const MultiPieceRange = @import("../net/web_seed.zig").MultiPieceRange;
const Hasher = @import("hasher.zig").Hasher;
const storage = @import("../storage/root.zig");
const LayoutSpan = @import("../torrent/layout.zig").Layout.Span;
const peer_handler = @import("peer_handler.zig");

pub const max_web_seed_slots: usize = 16;

/// Tracks one in-flight web seed download that may span multiple pieces.
/// A multi-piece request uses a single HTTP Range request and a single
/// buffer. On completion, the buffer is split at piece boundaries and
/// each piece is submitted to the hasher individually.
pub const WebSeedSlot = struct {
    state: State = .free,
    seed_index: usize = 0,
    torrent_id: TorrentId = 0,
    /// First piece index in the contiguous run.
    first_piece: u32 = 0,
    /// Number of pieces in this request (>= 1).
    piece_count: u32 = 0,
    /// Total bytes across all pieces in this request.
    total_bytes: u32 = 0,
    /// Large buffer covering the entire byte range.
    buf: ?[]u8 = null,
    /// Number of file-range HTTP requests for this slot (multi-file torrents
    /// may need one request per file that the run overlaps).
    ranges_total: u8 = 0,
    ranges_completed: u8 = 0,
    ranges_failed: bool = false,
    /// Number of individual pieces submitted to the hasher.
    pieces_hashed: u32 = 0,

    pub const State = enum { free, downloading, hashing };

    fn reset(self: *WebSeedSlot) void {
        self.* = .{};
    }
};

/// Context pointer embedded in each HttpExecutor.Job to identify
/// which web seed slot and event loop a range completion belongs to.
const RangeContext = struct {
    event_loop: *EventLoop,
    slot_index: u8,
};

/// Called each tick from the event loop. Scans torrents for available
/// web seeds and unclaimed pieces, then submits batched HTTP range requests
/// covering contiguous runs of pieces (up to web_seed_max_request_bytes).
pub fn tryAssignWebSeedPieces(el: anytype) void {
    // During graceful shutdown drain, don't start new web seed requests
    if (el.draining) return;

    const he = el.http_executor orelse return;

    for (el.active_torrent_ids.items) |torrent_id| {
        const tc = el.getTorrentContext(torrent_id) orelse continue;

        // Skip torrents without web seeds
        const wsm = tc.web_seed_manager orelse continue;

        // Skip torrents that are upload-only (complete or partial seed)
        if (tc.upload_only) continue;

        const pt = tc.piece_tracker orelse continue;
        const sess = tc.session orelse continue;

        const now = el.clock.now();
        if (wsm.availableCount(now) == 0) continue;

        const max_bytes = el.web_seed_max_request_bytes;
        const piece_count_total = sess.pieceCount();

        // Try to fill free web seed slots
        for (&el.web_seed_slots) |*slot| {
            if (slot.state != .free) continue;

            // Claim a contiguous run of pieces up to max_bytes
            const first_piece = pt.claimPiece(null) orelse break;

            // Extend the run: claim adjacent pieces
            var run_count: u32 = 1;
            var run_bytes: u64 = sess.layout.pieceSize(first_piece) catch {
                pt.releasePiece(first_piece);
                continue;
            };

            while (run_bytes < max_bytes) {
                const next_piece = first_piece + run_count;
                if (next_piece >= piece_count_total) break;

                // Try to claim the next adjacent piece
                if (pt.isPieceComplete(next_piece)) break;
                // Use claimSpecificPiece to claim a specific piece index
                if (!pt.claimSpecificPiece(next_piece)) break;

                const next_size = sess.layout.pieceSize(next_piece) catch {
                    pt.releasePiece(next_piece);
                    break;
                };
                run_bytes += next_size;
                run_count += 1;
            }

            const total_bytes: u32 = @intCast(run_bytes);

            const seed_index = wsm.assignPiece(first_piece, now) orelse {
                // No available seed -- release all claimed pieces
                releaseRunPieces(pt, first_piece, run_count);
                break; // no more available seeds
            };

            const run_buf = el.allocator.alloc(u8, total_bytes) catch {
                releaseRunPieces(pt, first_piece, run_count);
                wsm.markFailure(seed_index, now);
                continue;
            };

            // Compute the multi-piece file ranges
            var ranges_buf: [16]MultiPieceRange = undefined;
            const ranges = wsm.computeMultiPieceRanges(
                first_piece,
                run_count,
                piece_count_total,
                &ranges_buf,
            ) catch {
                el.allocator.free(run_buf);
                releaseRunPieces(pt, first_piece, run_count);
                wsm.markFailure(seed_index, now);
                continue;
            };

            if (ranges.len == 0) {
                el.allocator.free(run_buf);
                releaseRunPieces(pt, first_piece, run_count);
                wsm.markFailure(seed_index, now);
                continue;
            }

            // Populate the slot
            const slot_idx = slotIndex(el, slot);
            slot.state = .downloading;
            slot.seed_index = seed_index;
            slot.torrent_id = torrent_id;
            slot.first_piece = first_piece;
            slot.piece_count = run_count;
            slot.total_bytes = total_bytes;
            slot.buf = run_buf;
            slot.ranges_total = @intCast(ranges.len);
            slot.ranges_completed = 0;
            slot.ranges_failed = false;
            slot.pieces_hashed = 0;

            // Submit one HTTP request per file range
            var submitted: u8 = 0;
            for (ranges) |range| {
                submitMultiPieceRangeRequest(el, he, wsm, slot_idx, seed_index, range, run_buf) catch {
                    slot.ranges_failed = true;
                    continue;
                };
                submitted += 1;
            }

            if (submitted == 0) {
                // All range submissions failed
                el.allocator.free(run_buf);
                releaseRunPieces(pt, first_piece, run_count);
                wsm.markFailure(seed_index, now);
                slot.reset();
                continue;
            }

            log.debug("web seed: assigned pieces {d}..{d} ({d} pieces, {d} bytes) to seed {d} ({d} ranges)", .{
                first_piece,
                first_piece + run_count - 1,
                run_count,
                total_bytes,
                seed_index,
                ranges.len,
            });
        }
    }
}

/// Release a contiguous run of claimed pieces back to the piece tracker.
fn releaseRunPieces(pt: anytype, first_piece: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        pt.releasePiece(first_piece + i);
    }
}

fn slotIndex(el: anytype, slot: *WebSeedSlot) u8 {
    const base = @intFromPtr(&el.web_seed_slots[0]);
    const ptr = @intFromPtr(slot);
    return @intCast((ptr - base) / @sizeOf(WebSeedSlot));
}

fn submitMultiPieceRangeRequest(
    el: anytype,
    he: *HttpExecutor,
    wsm: *WebSeedManager,
    slot_idx: u8,
    seed_index: usize,
    range: MultiPieceRange,
    run_buf: []u8,
) !void {
    const url = wsm.buildFileUrl(el.allocator, seed_index, range.file_index) catch |err| {
        log.warn("web seed: buildFileUrl failed: {s}", .{@errorName(err)});
        return err;
    };
    defer el.allocator.free(url);

    // Allocate a heap RangeContext so the callback can find us.
    // Freed in the completion callback.
    const ctx = el.allocator.create(RangeContext) catch return error.OutOfMemory;
    ctx.* = .{
        // RangeContext.event_loop is concrete `*EventLoop` (RealIO).
        // Web-seed path doesn't fire under simulator_mode usage; cast
        // keeps SimIO instantiations compiling.
        .event_loop = @ptrCast(@alignCast(el)),
        .slot_index = slot_idx,
    };

    var job = HttpExecutor.Job{
        .context = @ptrCast(ctx),
        .on_complete = webSeedRangeComplete,
    };

    // Set the URL (job.url is a fixed-size array)
    if (url.len > job.url.len) {
        el.allocator.destroy(ctx);
        return error.UrlTooLong;
    }
    @memcpy(job.url[0..url.len], url);
    job.url_len = @intCast(url.len);

    // Extract host from URL for the executor's per-host tracking
    if (extractHost(url)) |host| {
        if (host.len <= job.host.len) {
            @memcpy(job.host[0..host.len], host);
            job.host_len = @intCast(host.len);
        }
    }

    // Set Range header
    var range_hdr_buf: [128]u8 = undefined;
    const range_hdr = std.fmt.bufPrint(&range_hdr_buf, "Range: bytes={d}-{d}", .{
        range.range_start,
        range.range_end,
    }) catch {
        el.allocator.destroy(ctx);
        return error.RangeHeaderTooLong;
    };
    job.extra_headers[0] = HttpExecutor.ExtraHeader.set(range_hdr);

    // Set target buffer so the body is written directly into the run buffer
    job.target_buf = run_buf;
    job.target_offset = range.buf_offset;

    he.submit(job) catch |err| {
        el.allocator.destroy(ctx);
        return err;
    };
}

/// Extract hostname from a URL (http://host:port/... -> host or host:port).
fn extractHost(url: []const u8) ?[]const u8 {
    // Skip scheme
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |idx|
        url[idx + 3 ..]
    else
        url;

    // Find end of host (next '/' or end)
    const end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    if (end == 0) return null;

    // Strip userinfo if present
    const host_port = if (std.mem.indexOfScalar(u8, after_scheme[0..end], '@')) |at|
        after_scheme[at + 1 .. end]
    else
        after_scheme[0..end];

    // Strip port (host only, no :port)
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        return host_port[0..colon];
    }
    return host_port;
}

/// HttpExecutor completion callback for a single range request.
fn webSeedRangeComplete(context: *anyopaque, result: HttpExecutor.RequestResult) void {
    const ctx: *RangeContext = @ptrCast(@alignCast(context));
    const el = ctx.event_loop;
    const slot_idx = ctx.slot_index;
    el.allocator.destroy(ctx);

    if (slot_idx >= max_web_seed_slots) return;
    const slot = &el.web_seed_slots[slot_idx];
    if (slot.state != .downloading) return;

    // Check HTTP status
    if (result.err != null or (result.status != 200 and result.status != 206)) {
        log.debug("web seed: range failed for pieces {d}..{d} (status={d}, err={?})", .{
            slot.first_piece,
            slot.first_piece + slot.piece_count - 1,
            result.status,
            result.err,
        });
        slot.ranges_failed = true;

        // Classify the failure for backoff decisions
        if (result.status == 404) {
            // Disable seed permanently on 404 (file not found)
            if (el.getTorrentContext(slot.torrent_id)) |tc| {
                if (tc.web_seed_manager) |wsm| wsm.disable(slot.seed_index);
            }
        }
        // Note: status=0 with no error (stale pooled connection) is still
        // a failure -- ranges_failed stays true. The seed will be retried
        // without backoff penalty below.
    }

    slot.ranges_completed += 1;

    // Wait for all ranges to finish
    if (slot.ranges_completed < slot.ranges_total) return;

    // All ranges are done
    if (slot.ranges_failed) {
        // For stale pooled connections (status=0, no error), release pieces
        // without penalizing the seed -- the connection was just stale.
        const stale_conn = result.status == 0 and result.err == null;
        if (stale_conn) {
            // Release pieces back to pool without backoff penalty
            if (el.getTorrentContext(slot.torrent_id)) |tc| {
                if (tc.piece_tracker) |pt| {
                    var i: u32 = 0;
                    while (i < slot.piece_count) : (i += 1) {
                        pt.releasePiece(slot.first_piece + i);
                    }
                }
                // Mark seed idle (no backoff) so it can retry immediately
                if (tc.web_seed_manager) |wsm| {
                    wsm.markSuccess(slot.seed_index, 0);
                }
            }
            if (slot.buf) |buf| el.allocator.free(buf);
            slot.reset();
        } else {
            failSlot(el, slot);
        }
        return;
    }

    // Mark the seed as idle immediately so the next piece can start
    // downloading while these are being hash-verified and written.
    if (el.getTorrentContext(slot.torrent_id)) |tc| {
        if (tc.web_seed_manager) |wsm| {
            wsm.markSuccess(slot.seed_index, slot.total_bytes);
        }
    }

    // Submit each piece in the run to the hasher individually
    submitPiecesToHasher(el, slot, slotIndex(el, slot));
}

/// Split the completed multi-piece buffer at piece boundaries and submit
/// each piece to the background hasher for SHA verification.
fn submitPiecesToHasher(el: anytype, slot: *WebSeedSlot, slot_idx: u8) void {
    const tc = el.getTorrentContext(slot.torrent_id) orelse {
        failSlot(el, slot);
        return;
    };
    const sess = tc.session orelse {
        failSlot(el, slot);
        return;
    };
    const h = el.hasher orelse {
        // No hasher available -- try inline verification for each piece
        inlineVerifyMultiPiece(el, slot);
        return;
    };

    const run_buf = slot.buf orelse {
        failSlot(el, slot);
        return;
    };

    var buf_offset: u32 = 0;
    var submitted: u32 = 0;

    var i: u32 = 0;
    while (i < slot.piece_count) : (i += 1) {
        const piece_index = slot.first_piece + i;
        const piece_size = sess.layout.pieceSize(piece_index) catch {
            // Should not happen -- we validated during claim
            continue;
        };

        const expected_hash = sess.layout.pieceHash(piece_index) catch {
            continue;
        };
        var hash: [20]u8 = undefined;
        @memcpy(&hash, expected_hash);

        // Allocate a per-piece buffer and copy from the run buffer
        const piece_buf = el.allocator.alloc(u8, piece_size) catch {
            continue;
        };
        @memcpy(piece_buf, run_buf[buf_offset .. buf_offset + piece_size]);

        const sentinel_slot: u16 = @as(u16, 0xFFFF) - @as(u16, slot_idx);

        h.submitVerify(
            sentinel_slot,
            piece_index,
            piece_buf,
            hash,
            slot.torrent_id,
        ) catch {
            el.allocator.free(piece_buf);
            continue;
        };

        submitted += 1;
        buf_offset += piece_size;
    }

    slot.pieces_hashed = submitted;

    if (submitted == 0) {
        failSlot(el, slot);
        return;
    }

    log.debug("web seed: pieces {d}..{d} ({d} pieces) submitted to hasher", .{
        slot.first_piece,
        slot.first_piece + slot.piece_count - 1,
        submitted,
    });

    // Free the run buffer -- each piece was copied to its own buffer.
    // The hasher owns each per-piece buffer from here.
    el.allocator.free(run_buf);
    slot.buf = null;
    slot.state = .hashing;

    // Free the slot -- the hasher/processHashResults owns the rest of the
    // lifecycle (hash verify -> disk write -> completePiece).
    slot.reset();
}

/// Inline SHA-1 verification and disk write for multi-piece runs
/// (fallback when hasher is unavailable).
fn inlineVerifyMultiPiece(el: anytype, slot: *WebSeedSlot) void {
    const Sha1 = @import("../crypto/root.zig").Sha1;

    const tc = el.getTorrentContext(slot.torrent_id) orelse {
        failSlot(el, slot);
        return;
    };
    const sess = tc.session orelse {
        failSlot(el, slot);
        return;
    };
    const pt = tc.piece_tracker orelse {
        failSlot(el, slot);
        return;
    };
    const run_buf = slot.buf orelse {
        failSlot(el, slot);
        return;
    };

    var buf_offset: u32 = 0;
    var any_success = false;

    var i: u32 = 0;
    while (i < slot.piece_count) : (i += 1) {
        const piece_index = slot.first_piece + i;
        const piece_size = sess.layout.pieceSize(piece_index) catch continue;

        const expected_hash = sess.layout.pieceHash(piece_index) catch {
            buf_offset += piece_size;
            continue;
        };

        const piece_data = run_buf[buf_offset .. buf_offset + piece_size];

        var actual: [20]u8 = undefined;
        Sha1.hash(piece_data, &actual, .{});

        if (!std.mem.eql(u8, &actual, expected_hash)) {
            log.warn("web seed: piece {d} hash mismatch", .{piece_index});
            pt.releasePiece(piece_index);
            buf_offset += piece_size;
            continue;
        }

        // Write piece to disk via io_uring
        var span_scratch: [8]LayoutSpan = undefined;
        const plan = storage.verify.planPieceVerificationWithScratch(
            el.allocator,
            sess,
            piece_index,
            span_scratch[0..],
        ) catch {
            pt.releasePiece(piece_index);
            buf_offset += piece_size;
            continue;
        };
        defer plan.deinit(el.allocator);

        if (plan.spans.len == 0) {
            pt.releasePiece(piece_index);
            buf_offset += piece_size;
            continue;
        }

        // Allocate a per-piece buffer for the pending write
        const piece_buf = el.allocator.alloc(u8, piece_size) catch {
            pt.releasePiece(piece_index);
            buf_offset += piece_size;
            continue;
        };
        @memcpy(piece_buf, piece_data);

        const pending_key = EventLoop.PendingWriteKey{
            .piece_index = piece_index,
            .torrent_id = slot.torrent_id,
        };
        const write_id = el.createPendingWrite(pending_key, .{
            .write_id = 0,
            .piece_index = piece_index,
            .torrent_id = slot.torrent_id,
            .slot = 0,
            .buf = piece_buf,
            .spans_remaining = 0,
        }) catch {
            el.allocator.free(piece_buf);
            pt.releasePiece(piece_index);
            buf_offset += piece_size;
            continue;
        };

        for (plan.spans) |span| {
            if (tc.shared_fds[span.file_index] < 0) continue;
            const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
            const EL = @TypeOf(el.*);
            const wop = el.allocator.create(peer_handler.DiskWriteOpOf(EL)) catch |err| {
                log.warn("web seed: write op alloc for piece {d}: {s}", .{ piece_index, @errorName(err) });
                if (el.getPendingWrite(pending_key)) |pending_w| {
                    pending_w.write_failed = true;
                }
                continue;
            };
            wop.* = .{ .el = el, .write_id = write_id };
            el.io.write(
                .{ .fd = tc.shared_fds[span.file_index], .buf = block, .offset = span.file_offset },
                &wop.completion,
                wop,
                peer_handler.diskWriteCompleteFor(EL),
            ) catch |err| {
                log.warn("web seed: disk write for piece {d}: {s}", .{ piece_index, @errorName(err) });
                el.allocator.destroy(wop);
                if (el.getPendingWrite(pending_key)) |pending_w| {
                    pending_w.write_failed = true;
                }
                continue;
            };
            if (el.getPendingWrite(pending_key)) |pending_w| {
                pending_w.spans_remaining += 1;
            }
        }

        if (el.getPendingWrite(pending_key)) |pending_w| {
            if (pending_w.spans_remaining == 0) {
                _ = el.removePendingWrite(pending_key);
                pt.releasePiece(piece_index);
                el.allocator.free(piece_buf);
                buf_offset += piece_size;
                continue;
            }
        }

        any_success = true;
        buf_offset += piece_size;
    }

    // Free the run buffer
    el.allocator.free(run_buf);
    slot.buf = null;

    if (any_success) {
        if (tc.web_seed_manager) |wsm| {
            wsm.markSuccess(slot.seed_index, slot.total_bytes);
        }
    }

    slot.reset();
}

/// Release all pieces in a multi-piece slot on failure and free the slot.
fn failSlot(el: anytype, slot: *WebSeedSlot) void {
    const now = el.clock.now();

    if (el.getTorrentContext(slot.torrent_id)) |tc| {
        if (tc.piece_tracker) |pt| {
            var i: u32 = 0;
            while (i < slot.piece_count) : (i += 1) {
                pt.releasePiece(slot.first_piece + i);
            }
        }
        if (tc.web_seed_manager) |wsm| {
            wsm.markFailure(slot.seed_index, now);
        }
    }

    if (slot.buf) |buf| {
        el.allocator.free(buf);
    }

    slot.reset();
}

// ── Tests ────────────────────────────────────────────────

test "extractHost parses http url" {
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com/path/file").?);
    try std.testing.expectEqualStrings("example.com:8080", extractHost("http://example.com:8080/path/file").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/").?);
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com").?);
}

test "extractHost handles userinfo" {
    try std.testing.expectEqualStrings("example.com", extractHost("http://user:pass@example.com/path").?);
}

test "WebSeedSlot reset" {
    var slot = WebSeedSlot{
        .state = .downloading,
        .seed_index = 3,
        .torrent_id = 1,
        .first_piece = 10,
        .piece_count = 4,
        .total_bytes = 65536,
        .ranges_total = 2,
        .ranges_completed = 1,
        .ranges_failed = true,
        .pieces_hashed = 2,
    };
    slot.reset();
    try std.testing.expectEqual(WebSeedSlot.State.free, slot.state);
    try std.testing.expectEqual(@as(u32, 0), slot.first_piece);
    try std.testing.expectEqual(@as(u32, 0), slot.piece_count);
    try std.testing.expectEqual(@as(u32, 0), slot.total_bytes);
    try std.testing.expectEqual(@as(?[]u8, null), slot.buf);
    try std.testing.expectEqual(@as(u32, 0), slot.pieces_hashed);
}

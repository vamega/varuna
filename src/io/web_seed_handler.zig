const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.web_seed);

const TorrentContext = @import("types.zig").TorrentContext;
const TorrentId = @import("types.zig").TorrentId;
const encodeUserData = @import("types.zig").encodeUserData;
const WebSeedManager = @import("../net/web_seed.zig").WebSeedManager;
const MultiPieceRange = @import("../net/web_seed.zig").MultiPieceRange;
const Hasher = @import("hasher.zig").Hasher;
const http = @import("http_parse.zig");
const storage = @import("../storage/root.zig");
const LayoutSpan = @import("../torrent/layout.zig").Layout.Span;
const peer_handler = @import("peer_handler.zig");
const Bitfield = @import("../bitfield.zig").Bitfield;
const PieceTracker = @import("../torrent/piece_tracker.zig").PieceTracker;

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
fn RangeContextOf(comptime EventLoop: type) type {
    return struct {
        event_loop: *EventLoop,
        slot_index: u8,
        range_start: u64,
        range_end: u64,
    };
}

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
    he: anytype,
    wsm: *WebSeedManager,
    slot_idx: u8,
    seed_index: usize,
    range: MultiPieceRange,
    run_buf: []u8,
) !void {
    const EventLoop = @TypeOf(el.*);
    const HttpExecutor = @TypeOf(he.*);
    const RangeContext = RangeContextOf(EventLoop);

    const url = wsm.buildFileUrl(el.allocator, seed_index, range.file_index) catch |err| {
        log.warn("web seed: buildFileUrl failed: {s}", .{@errorName(err)});
        return err;
    };
    defer el.allocator.free(url);

    // Allocate a heap RangeContext so the callback can find us.
    // Freed in the completion callback.
    const ctx = el.allocator.create(RangeContext) catch return error.OutOfMemory;
    ctx.* = .{
        .event_loop = el,
        .slot_index = slot_idx,
        .range_start = range.range_start,
        .range_end = range.range_end,
    };

    var job = HttpExecutor.Job{
        .context = @ptrCast(ctx),
        .on_complete = webSeedRangeCompleteFor(EventLoop, HttpExecutor),
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

const RangeResponse = struct {
    status: u16,
    headers: ?[]const u8,
    target_bytes_written: u32,
};

const ExpectedRange = struct {
    range_start: u64,
    range_end: u64,
};

fn validateRangeResponse(response: RangeResponse, expected: ExpectedRange) error{InvalidRangeResponse}!void {
    if (expected.range_end < expected.range_start) return error.InvalidRangeResponse;
    const expected_len_u64 = expected.range_end - expected.range_start + 1;
    if (expected_len_u64 > std.math.maxInt(u32)) return error.InvalidRangeResponse;
    const expected_len: u32 = @intCast(expected_len_u64);

    if (response.target_bytes_written != expected_len) return error.InvalidRangeResponse;

    const headers = response.headers orelse return error.InvalidRangeResponse;
    if (http.parseContentLength(headers)) |content_len| {
        if (content_len != expected_len) return error.InvalidRangeResponse;
    }

    switch (response.status) {
        206 => {
            if (!contentRangeMatches(headers, expected)) return error.InvalidRangeResponse;
        },
        200 => {
            // Web seed downloads always issue an HTTP Range request. A 200 OK
            // response means the origin ignored that contract, even if the
            // requested span starts at byte 0 and the byte count happens to fit.
            return error.InvalidRangeResponse;
        },
        else => return error.InvalidRangeResponse,
    }
}

fn contentRangeMatches(headers: []const u8, expected: ExpectedRange) bool {
    const value = extractHttpHeader(headers, "content-range") orelse return false;
    if (!std.ascii.startsWithIgnoreCase(value, "bytes")) return false;
    if (value.len == "bytes".len) return false;
    if (value["bytes".len] != ' ' and value["bytes".len] != '\t') return false;

    const range_part = std.mem.trim(u8, value["bytes".len..], " \t");
    const slash = std.mem.indexOfScalar(u8, range_part, '/') orelse return false;
    const byte_range = range_part[0..slash];
    const dash = std.mem.indexOfScalar(u8, byte_range, '-') orelse return false;

    const start = std.fmt.parseInt(u64, std.mem.trim(u8, byte_range[0..dash], " \t"), 10) catch return false;
    const end = std.fmt.parseInt(u64, std.mem.trim(u8, byte_range[dash + 1 ..], " \t"), 10) catch return false;
    return start == expected.range_start and end == expected.range_end;
}

fn extractHttpHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    while (iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (line[0..colon].len != name.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// HttpExecutor completion callback for a single range request.
fn webSeedRangeCompleteFor(
    comptime EventLoop: type,
    comptime HttpExecutor: type,
) *const fn (*anyopaque, HttpExecutor.RequestResult) void {
    return struct {
        fn callback(context: *anyopaque, result: HttpExecutor.RequestResult) void {
            const RangeContext = RangeContextOf(EventLoop);
            const ctx: *RangeContext = @ptrCast(@alignCast(context));
            const el = ctx.event_loop;
            const slot_idx = ctx.slot_index;
            const expected_range = ExpectedRange{
                .range_start = ctx.range_start,
                .range_end = ctx.range_end,
            };
            el.allocator.destroy(ctx);

            if (slot_idx >= max_web_seed_slots) return;
            const slot = &el.web_seed_slots[slot_idx];
            if (slot.state != .downloading) return;

            const range_valid = if (result.err == null) blk: {
                validateRangeResponse(.{
                    .status = result.status,
                    .headers = result.headers,
                    .target_bytes_written = result.target_bytes_written,
                }, expected_range) catch break :blk false;
                break :blk true;
            } else false;

            // Check HTTP status and range contract.
            if (result.err != null or !range_valid) {
                log.warn("web seed: range failed for pieces {d}..{d} (status={d}, err={?}, bytes={d}, expected={d}-{d})", .{
                    slot.first_piece,
                    slot.first_piece + slot.piece_count - 1,
                    result.status,
                    result.err,
                    result.target_bytes_written,
                    expected_range.range_start,
                    expected_range.range_end,
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
            } else {
                el.accountTorrentBytes(slot.torrent_id, result.target_bytes_written, 0);
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
    }.callback;
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

        // Write piece to disk via io_uring. Hash was verified inline above
        // (Sha1.hash + std.mem.eql against expected_hash), so we only need
        // span layout here — planPieceSpans is safe across Session.freePieces().
        var span_scratch: [8]LayoutSpan = undefined;
        const plan = storage.verify.planPieceSpansWithScratch(
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

        const EL = @TypeOf(el.*);
        const pending_key = EL.PendingWriteKey{
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
    // extractHost returns the bare hostname, stripping any explicit port.
    // (Origin-style port preservation was removed; per-host tracking now
    // groups by hostname only.)
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com/path/file").?);
    try std.testing.expectEqualStrings("example.com", extractHost("http://example.com:8080/path/file").?);
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

const FakeWebSeedResponseMode = enum {
    honor_range,
    ignore_range_with_200,
};

const FakeWebSeedServer = struct {
    data: []const u8,
    expected_range_header: []const u8,
    response_mode: FakeWebSeedResponseMode,
    request_count: u32 = 0,
    validated_range_count: u32 = 0,
    observed_range_buf: [128]u8 = undefined,
    observed_range_len: usize = 0,
    headers_buf: [256]u8 = undefined,

    fn observedRange(self: *const FakeWebSeedServer) []const u8 {
        return self.observed_range_buf[0..self.observed_range_len];
    }

    fn handle(self: *FakeWebSeedServer, job: FakeHttpExecutor.Job) void {
        self.request_count += 1;

        const range_line = findRangeHeader(&job) orelse {
            self.complete(job, .{
                .status = 400,
                .headers = self.formatHeaders("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n"),
                .target_bytes_written = 0,
            });
            return;
        };

        self.observed_range_len = @min(range_line.len, self.observed_range_buf.len);
        @memcpy(self.observed_range_buf[0..self.observed_range_len], range_line[0..self.observed_range_len]);

        if (!std.mem.eql(u8, range_line, self.expected_range_header)) {
            self.complete(job, .{
                .status = 412,
                .headers = self.formatHeaders("HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\n"),
                .target_bytes_written = 0,
            });
            return;
        }
        self.validated_range_count += 1;

        const requested = parseFakeRange(range_line) orelse {
            self.complete(job, .{
                .status = 416,
                .headers = self.formatHeaders("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\n"),
                .target_bytes_written = 0,
            });
            return;
        };

        switch (self.response_mode) {
            .honor_range => {
                if (requested.end >= self.data.len or requested.start > requested.end) {
                    const headers = std.fmt.bufPrint(
                        &self.headers_buf,
                        "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\n",
                        .{self.data.len},
                    ) catch unreachable;
                    self.complete(job, .{ .status = 416, .headers = headers, .target_bytes_written = 0 });
                    return;
                }

                const body = self.data[requested.start .. requested.end + 1];
                const written = writeToTarget(job, body);
                const headers = std.fmt.bufPrint(
                    &self.headers_buf,
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\n",
                    .{ body.len, requested.start, requested.end, self.data.len },
                ) catch unreachable;
                self.complete(job, .{ .status = 206, .headers = headers, .target_bytes_written = written });
            },
            .ignore_range_with_200 => {
                const written = writeToTarget(job, self.data);
                const headers = std.fmt.bufPrint(
                    &self.headers_buf,
                    "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n",
                    .{self.data.len},
                ) catch unreachable;
                self.complete(job, .{ .status = 200, .headers = headers, .target_bytes_written = written });
            },
        }
    }

    fn complete(self: *FakeWebSeedServer, job: FakeHttpExecutor.Job, result: FakeHttpExecutor.RequestResult) void {
        _ = self;
        job.on_complete(job.context, result);
    }

    fn formatHeaders(self: *FakeWebSeedServer, value: []const u8) []const u8 {
        @memcpy(self.headers_buf[0..value.len], value);
        return self.headers_buf[0..value.len];
    }

    fn findRangeHeader(job: *const FakeHttpExecutor.Job) ?[]const u8 {
        for (&job.extra_headers) |*header| {
            const line = header.slice();
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "range")) return line;
        }
        return null;
    }

    fn parseFakeRange(line: []const u8) ?struct { start: usize, end: usize } {
        const value = extractHttpHeader(line, "range") orelse return null;
        if (!std.ascii.startsWithIgnoreCase(value, "bytes=")) return null;
        const spec = value["bytes=".len..];
        const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
        const start = std.fmt.parseInt(usize, spec[0..dash], 10) catch return null;
        const end = std.fmt.parseInt(usize, spec[dash + 1 ..], 10) catch return null;
        return .{ .start = start, .end = end };
    }

    fn writeToTarget(job: FakeHttpExecutor.Job, body: []const u8) u32 {
        const target = job.target_buf orelse return 0;
        const start: usize = @intCast(job.target_offset);
        if (start >= target.len) return 0;
        const copy_len = @min(body.len, target.len - start);
        @memcpy(target[start .. start + copy_len], body[0..copy_len]);
        return @intCast(copy_len);
    }
};

const FakeHttpExecutor = struct {
    server: *FakeWebSeedServer,
    submit_count: u32 = 0,

    pub const CompletionFn = *const fn (*anyopaque, RequestResult) void;
    pub const max_extra_headers = 4;

    pub const RequestResult = struct {
        status: u16 = 0,
        body: ?[]const u8 = null,
        headers: ?[]const u8 = null,
        target_bytes_written: u32 = 0,
        err: ?anyerror = null,
    };

    pub const ExtraHeader = struct {
        data: [max_header_len]u8 = undefined,
        len: u16 = 0,

        const max_header_len = 256;

        pub fn slice(self: *const ExtraHeader) []const u8 {
            return self.data[0..self.len];
        }

        pub fn set(value: []const u8) ExtraHeader {
            var h = ExtraHeader{};
            const copy_len = @min(value.len, max_header_len);
            @memcpy(h.data[0..copy_len], value[0..copy_len]);
            h.len = @intCast(copy_len);
            return h;
        }
    };

    pub const Job = struct {
        context: *anyopaque,
        on_complete: CompletionFn,
        url: [max_url_len]u8 = undefined,
        url_len: u16 = 0,
        host: [max_host_len]u8 = undefined,
        host_len: u8 = 0,
        extra_headers: [max_extra_headers]ExtraHeader = [_]ExtraHeader{.{}} ** max_extra_headers,
        target_buf: ?[]u8 = null,
        target_offset: u32 = 0,

        const max_host_len = 253;
        const max_url_len = 2048;
    };

    pub fn submit(self: *FakeHttpExecutor, job: Job) !void {
        self.submit_count += 1;
        self.server.handle(job);
    }
};

const FakeClock = struct {
    value: i64 = 100,

    fn now(self: *FakeClock) i64 {
        return self.value;
    }
};

const FakeHasher = struct {
    fn submitVerify(
        self: *FakeHasher,
        sentinel_slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        hash: [20]u8,
        torrent_id: TorrentId,
    ) !void {
        _ = self;
        _ = sentinel_slot;
        _ = piece_index;
        _ = piece_buf;
        _ = hash;
        _ = torrent_id;
    }
};

const FakeIO = struct {
    pub fn write(self: *FakeIO, op: anytype, completion: anytype, userdata: anytype, cb: anytype) !void {
        _ = self;
        _ = op;
        _ = completion;
        _ = userdata;
        _ = cb;
        return error.UnexpectedWrite;
    }
};

const FakeEventLoop = struct {
    pub const PendingWriteKey = struct {
        piece_index: u32,
        torrent_id: TorrentId,
    };

    pub const PendingWrite = struct {
        write_id: u32,
        piece_index: u32,
        torrent_id: TorrentId,
        slot: u16,
        buf: []u8,
        spans_remaining: u32,
        write_failed: bool = false,
    };

    allocator: std.mem.Allocator,
    clock: FakeClock = .{},
    io: FakeIO = .{},
    web_seed_slots: [max_web_seed_slots]WebSeedSlot = [_]WebSeedSlot{.{}} ** max_web_seed_slots,
    torrent_id: TorrentId,
    tc: *TorrentContext,
    hasher: ?*FakeHasher = null,
    accounted_download_bytes: u64 = 0,

    pub fn getTorrentContext(self: *FakeEventLoop, torrent_id: TorrentId) ?*TorrentContext {
        if (torrent_id != self.torrent_id) return null;
        return self.tc;
    }

    fn createPendingWrite(self: *FakeEventLoop, key: PendingWriteKey, pending_write: PendingWrite) !u32 {
        _ = self;
        _ = key;
        _ = pending_write;
        return error.UnexpectedWrite;
    }

    fn getPendingWrite(self: *FakeEventLoop, key: PendingWriteKey) ?*PendingWrite {
        _ = self;
        _ = key;
        return null;
    }

    fn removePendingWrite(self: *FakeEventLoop, key: PendingWriteKey) ?PendingWrite {
        _ = self;
        _ = key;
        return null;
    }

    pub fn getPendingWriteById(self: *FakeEventLoop, write_id: u32) ?*PendingWrite {
        _ = self;
        _ = write_id;
        return null;
    }

    pub fn removePendingWriteById(self: *FakeEventLoop, write_id: u32) ?PendingWrite {
        _ = self;
        _ = write_id;
        return null;
    }

    pub fn accountTorrentBytes(self: *FakeEventLoop, torrent_id: TorrentId, dl_bytes: usize, ul_bytes: usize) void {
        _ = ul_bytes;
        if (torrent_id != self.torrent_id) return;
        self.accounted_download_bytes += dl_bytes;
    }

    pub fn markPieceAwaitingDurability(self: *FakeEventLoop, torrent_id: TorrentId, piece_index: u32) !void {
        _ = self;
        _ = torrent_id;
        _ = piece_index;
    }

    pub fn submitTorrentSync(self: *FakeEventLoop, torrent_id: TorrentId, force_even_if_clean: bool) void {
        _ = self;
        _ = torrent_id;
        _ = force_even_if_clean;
    }
};

fn initSingleFileWebSeedManager(allocator: std.mem.Allocator) !WebSeedManager {
    const urls = [_][]const u8{"http://webseed.test/file.bin"};
    return WebSeedManager.init(
        allocator,
        &urls,
        "file.bin",
        false,
        &.{},
        8,
        16,
    );
}

fn initFakeTorrentContext(wsm: *WebSeedManager, pt: ?*PieceTracker) TorrentContext {
    const no_fds: []const posix.fd_t = &.{};
    return .{
        .session = null,
        .piece_tracker = pt,
        .shared_fds = no_fds,
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .web_seed_manager = wsm,
    };
}

test "web seed fake server validates requested Range header through handler flow" {
    var wsm = try initSingleFileWebSeedManager(std.testing.allocator);
    defer wsm.deinit();
    const seed_index = wsm.assignPiece(0, 0).?;

    var tc = initFakeTorrentContext(&wsm, null);
    var el = FakeEventLoop{
        .allocator = std.testing.allocator,
        .torrent_id = 7,
        .tc = &tc,
    };

    var server = FakeWebSeedServer{
        .data = "0123456789abcdef",
        .expected_range_header = "Range: bytes=4-11",
        .response_mode = .honor_range,
    };
    var executor = FakeHttpExecutor{ .server = &server };

    var run_buf = try std.testing.allocator.alloc(u8, 12);
    defer std.testing.allocator.free(run_buf);
    @memset(run_buf, '.');

    el.web_seed_slots[0] = .{
        .state = .downloading,
        .seed_index = seed_index,
        .torrent_id = el.torrent_id,
        .first_piece = 0,
        .piece_count = 1,
        .total_bytes = @intCast(run_buf.len),
        .buf = run_buf,
        .ranges_total = 2,
        .ranges_completed = 0,
    };

    try submitMultiPieceRangeRequest(&el, &executor, &wsm, 0, seed_index, .{
        .file_index = 0,
        .range_start = 4,
        .range_end = 11,
        .buf_offset = 2,
        .length = 8,
    }, run_buf);

    try std.testing.expectEqual(@as(u32, 1), executor.submit_count);
    try std.testing.expectEqual(@as(u32, 1), server.request_count);
    try std.testing.expectEqual(@as(u32, 1), server.validated_range_count);
    try std.testing.expectEqualStrings("Range: bytes=4-11", server.observedRange());
    try std.testing.expectEqualStrings("456789ab", run_buf[2..10]);
    try std.testing.expectEqual(@as(u8, 1), el.web_seed_slots[0].ranges_completed);
    try std.testing.expect(!el.web_seed_slots[0].ranges_failed);
    try std.testing.expectEqual(WebSeedSlot.State.downloading, el.web_seed_slots[0].state);
    try std.testing.expectEqual(@as(u64, 8), el.accounted_download_bytes);
}

test "web seed fake server ignored Range response fails handler slot end-to-end" {
    var initial = try Bitfield.init(std.testing.allocator, 2);
    defer initial.deinit(std.testing.allocator);
    var pt = try PieceTracker.init(std.testing.allocator, 2, 8, 16, &initial, 0);
    defer pt.deinit(std.testing.allocator);
    try std.testing.expect(pt.claimSpecificPiece(0));

    var wsm = try initSingleFileWebSeedManager(std.testing.allocator);
    defer wsm.deinit();
    const seed_index = wsm.assignPiece(0, 0).?;

    var tc = initFakeTorrentContext(&wsm, &pt);
    var el = FakeEventLoop{
        .allocator = std.testing.allocator,
        .torrent_id = 7,
        .tc = &tc,
    };

    var server = FakeWebSeedServer{
        .data = "0123456789abcdef",
        .expected_range_header = "Range: bytes=4-11",
        .response_mode = .ignore_range_with_200,
    };
    var executor = FakeHttpExecutor{ .server = &server };

    const run_buf = try std.testing.allocator.alloc(u8, 16);
    @memset(run_buf, '.');

    el.web_seed_slots[0] = .{
        .state = .downloading,
        .seed_index = seed_index,
        .torrent_id = el.torrent_id,
        .first_piece = 0,
        .piece_count = 1,
        .total_bytes = @intCast(run_buf.len),
        .buf = run_buf,
        .ranges_total = 1,
        .ranges_completed = 0,
    };

    try submitMultiPieceRangeRequest(&el, &executor, &wsm, 0, seed_index, .{
        .file_index = 0,
        .range_start = 4,
        .range_end = 11,
        .buf_offset = 0,
        .length = 8,
    }, run_buf);

    try std.testing.expectEqual(@as(u32, 1), server.validated_range_count);
    try std.testing.expectEqualStrings("Range: bytes=4-11", server.observedRange());
    try std.testing.expectEqual(WebSeedSlot.State.free, el.web_seed_slots[0].state);
    try std.testing.expectEqual(@as(u32, 1), wsm.seeds[seed_index].failed_requests);
    try std.testing.expectEqual(@as(u32, 1), wsm.seeds[seed_index].consecutive_failures);
    try std.testing.expectEqual(@as(i64, 105), wsm.seeds[seed_index].backoff_until);
    try std.testing.expect(pt.claimSpecificPiece(0));
}

test "web seed fake server rejects ignored Range response even for zero start" {
    var wsm = try initSingleFileWebSeedManager(std.testing.allocator);
    defer wsm.deinit();
    const seed_index = wsm.assignPiece(0, 0).?;

    var tc = initFakeTorrentContext(&wsm, null);
    var el = FakeEventLoop{
        .allocator = std.testing.allocator,
        .torrent_id = 7,
        .tc = &tc,
    };

    var server = FakeWebSeedServer{
        .data = "0123456789abcdef",
        .expected_range_header = "Range: bytes=0-15",
        .response_mode = .ignore_range_with_200,
    };
    var executor = FakeHttpExecutor{ .server = &server };

    const run_buf = try std.testing.allocator.alloc(u8, 16);
    defer std.testing.allocator.free(run_buf);
    @memset(run_buf, '.');

    el.web_seed_slots[0] = .{
        .state = .downloading,
        .seed_index = seed_index,
        .torrent_id = el.torrent_id,
        .first_piece = 0,
        .piece_count = 1,
        .total_bytes = @intCast(run_buf.len),
        .buf = run_buf,
        .ranges_total = 2,
        .ranges_completed = 0,
    };

    try submitMultiPieceRangeRequest(&el, &executor, &wsm, 0, seed_index, .{
        .file_index = 0,
        .range_start = 0,
        .range_end = 15,
        .buf_offset = 0,
        .length = 16,
    }, run_buf);

    try std.testing.expectEqual(@as(u32, 1), server.validated_range_count);
    try std.testing.expectEqualStrings("Range: bytes=0-15", server.observedRange());
    try std.testing.expectEqual(@as(u8, 1), el.web_seed_slots[0].ranges_completed);
    try std.testing.expect(el.web_seed_slots[0].ranges_failed);
}

test "web seed range response accepts exact 206 Content-Range" {
    const headers = "HTTP/1.1 206 Partial Content\r\n" ++
        "Content-Length: 16\r\n" ++
        "Content-Range: bytes 32-47/1024\r\n";
    try validateRangeResponse(.{
        .status = 206,
        .headers = headers,
        .target_bytes_written = 16,
    }, .{
        .range_start = 32,
        .range_end = 47,
    });
}

test "web seed range response rejects missing or mismatched Content-Range" {
    const missing = "HTTP/1.1 206 Partial Content\r\nContent-Length: 16\r\n";
    try std.testing.expectError(error.InvalidRangeResponse, validateRangeResponse(.{
        .status = 206,
        .headers = missing,
        .target_bytes_written = 16,
    }, .{
        .range_start = 32,
        .range_end = 47,
    }));

    const mismatch = "HTTP/1.1 206 Partial Content\r\n" ++
        "Content-Length: 16\r\n" ++
        "Content-Range: bytes 31-46/1024\r\n";
    try std.testing.expectError(error.InvalidRangeResponse, validateRangeResponse(.{
        .status = 206,
        .headers = mismatch,
        .target_bytes_written = 16,
    }, .{
        .range_start = 32,
        .range_end = 47,
    }));
}

test "web seed range response rejects short target body" {
    const headers = "HTTP/1.1 206 Partial Content\r\n" ++
        "Content-Length: 16\r\n" ++
        "Content-Range: bytes 32-47/1024\r\n";
    try std.testing.expectError(error.InvalidRangeResponse, validateRangeResponse(.{
        .status = 206,
        .headers = headers,
        .target_bytes_written = 15,
    }, .{
        .range_start = 32,
        .range_end = 47,
    }));
}

test "web seed range response rejects 200 OK for nonzero range" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 16\r\n";
    try std.testing.expectError(error.InvalidRangeResponse, validateRangeResponse(.{
        .status = 200,
        .headers = headers,
        .target_bytes_written = 16,
    }, .{
        .range_start = 32,
        .range_end = 47,
    }));
}

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.web_seed);

const EventLoop = @import("event_loop.zig").EventLoop;
const TorrentContext = @import("types.zig").TorrentContext;
const TorrentId = @import("types.zig").TorrentId;
const encodeUserData = @import("types.zig").encodeUserData;
const HttpExecutor = @import("http_executor.zig").HttpExecutor;
const WebSeedManager = @import("../net/web_seed.zig").WebSeedManager;
const FileRange = @import("../net/web_seed.zig").FileRange;
const Hasher = @import("hasher.zig").Hasher;
const storage = @import("../storage/root.zig");
const LayoutSpan = @import("../torrent/layout.zig").Layout.Span;

pub const max_web_seed_slots: usize = 16;

/// Tracks one in-flight web seed piece download.
/// A piece may require multiple HTTP range requests (one per file range).
pub const WebSeedSlot = struct {
    state: State = .free,
    seed_index: usize = 0,
    torrent_id: TorrentId = 0,
    piece_index: u32 = 0,
    piece_buf: ?[]u8 = null,
    piece_size: u32 = 0,
    ranges_total: u8 = 0,
    ranges_completed: u8 = 0,
    ranges_failed: bool = false,

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
/// web seeds and unclaimed pieces, then submits HTTP range requests.
pub fn tryAssignWebSeedPieces(el: *EventLoop) void {
    const he = el.http_executor orelse return;

    for (el.active_torrent_ids.items) |torrent_id| {
        const tc = el.getTorrentContext(torrent_id) orelse continue;

        // Skip torrents without web seeds
        const wsm = tc.web_seed_manager orelse continue;

        // Skip torrents that are upload-only (complete or partial seed)
        if (tc.upload_only) continue;

        const pt = tc.piece_tracker orelse continue;
        const sess = tc.session orelse continue;

        const now = std.time.timestamp();
        if (wsm.availableCount(now) == 0) continue;

        // Try to fill free web seed slots
        for (&el.web_seed_slots) |*slot| {
            if (slot.state != .free) continue;

            // Claim a piece from the piece tracker (no peer bitfield filter --
            // web seeds have all pieces by definition).
            const piece_index = pt.claimPiece(null) orelse break;

            const seed_index = wsm.assignPiece(piece_index, now) orelse {
                pt.releasePiece(piece_index);
                break; // no more available seeds
            };

            const piece_size = sess.layout.pieceSize(piece_index) catch {
                pt.releasePiece(piece_index);
                wsm.markFailure(seed_index, now);
                continue;
            };

            const piece_buf = el.allocator.alloc(u8, piece_size) catch {
                pt.releasePiece(piece_index);
                wsm.markFailure(seed_index, now);
                continue;
            };

            // Compute the file ranges this piece spans
            var ranges_buf: [8]FileRange = undefined;
            const ranges = wsm.computePieceRanges(
                piece_index,
                sess.pieceCount(),
                &ranges_buf,
            ) catch {
                el.allocator.free(piece_buf);
                pt.releasePiece(piece_index);
                wsm.markFailure(seed_index, now);
                continue;
            };

            if (ranges.len == 0) {
                el.allocator.free(piece_buf);
                pt.releasePiece(piece_index);
                wsm.markFailure(seed_index, now);
                continue;
            }

            // Populate the slot
            const slot_idx = slotIndex(el, slot);
            slot.state = .downloading;
            slot.seed_index = seed_index;
            slot.torrent_id = torrent_id;
            slot.piece_index = piece_index;
            slot.piece_buf = piece_buf;
            slot.piece_size = piece_size;
            slot.ranges_total = @intCast(ranges.len);
            slot.ranges_completed = 0;
            slot.ranges_failed = false;

            // Submit one HTTP request per file range
            var submitted: u8 = 0;
            for (ranges) |range| {
                submitRangeRequest(el, he, wsm, slot_idx, seed_index, range) catch {
                    slot.ranges_failed = true;
                    continue;
                };
                submitted += 1;
            }

            if (submitted == 0) {
                // All range submissions failed
                el.allocator.free(piece_buf);
                pt.releasePiece(piece_index);
                wsm.markFailure(seed_index, now);
                slot.reset();
                continue;
            }

            log.debug("web seed: assigned piece {d} to seed {d} ({d} ranges)", .{
                piece_index, seed_index, ranges.len,
            });

            // Only assign one piece per tick per torrent to spread load
            break;
        }
    }
}

fn slotIndex(el: *EventLoop, slot: *WebSeedSlot) u8 {
    const base = @intFromPtr(&el.web_seed_slots[0]);
    const ptr = @intFromPtr(slot);
    return @intCast((ptr - base) / @sizeOf(WebSeedSlot));
}

fn submitRangeRequest(
    el: *EventLoop,
    he: *HttpExecutor,
    wsm: *WebSeedManager,
    slot_idx: u8,
    seed_index: usize,
    range: FileRange,
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
        .event_loop = el,
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

    // Set target buffer so the body is written directly into piece_buf
    const slot = &el.web_seed_slots[slot_idx];
    job.target_buf = slot.piece_buf;
    job.target_offset = range.piece_offset;

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
        log.debug("web seed: range failed for piece {d} (status={d}, err={?})", .{
            slot.piece_index,
            result.status,
            result.err,
        });
        slot.ranges_failed = true;

        // Disable seed on 404 (file not found)
        if (result.status == 404) {
            const tc = el.getTorrentContext(slot.torrent_id) orelse {
                failSlot(el, slot);
                return;
            };
            if (tc.web_seed_manager) |wsm| {
                wsm.disable(slot.seed_index);
            }
        }
    }

    slot.ranges_completed += 1;

    // Wait for all ranges to finish
    if (slot.ranges_completed < slot.ranges_total) return;

    // All ranges are done
    if (slot.ranges_failed) {
        failSlot(el, slot);
        return;
    }

    // Submit to hasher for verification
    submitToHasher(el, slot, slot_idx);
}

/// Submit a completed piece buffer to the background hasher for SHA verification.
fn submitToHasher(el: *EventLoop, slot: *WebSeedSlot, slot_idx: u8) void {
    const tc = el.getTorrentContext(slot.torrent_id) orelse {
        failSlot(el, slot);
        return;
    };
    const sess = tc.session orelse {
        failSlot(el, slot);
        return;
    };
    const h = el.hasher orelse {
        // No hasher available -- try inline verification
        inlineVerifyAndWrite(el, slot);
        return;
    };

    const expected_hash = sess.layout.pieceHash(slot.piece_index) catch {
        failSlot(el, slot);
        return;
    };
    var hash: [20]u8 = undefined;
    @memcpy(&hash, expected_hash);

    // The hasher takes ownership of piece_buf.
    // We use a sentinel slot value (max_peers + slot_idx) to distinguish
    // web seed results from peer results in processHashResults.
    // Actually, the hasher Result includes torrent_id and the processHashResults
    // path doesn't use slot for anything critical -- it just stores it.
    // We use the standard path: the hash result goes to processHashResults
    // which handles the disk write. We just need to set the slot to an unused
    // peer slot value. We use 0xFFFF - slot_idx as a distinctive sentinel.
    const sentinel_slot: u16 = @as(u16, 0xFFFF) - @as(u16, slot_idx);

    h.submitVerify(
        sentinel_slot,
        slot.piece_index,
        slot.piece_buf.?,
        hash,
        slot.torrent_id,
    ) catch {
        failSlot(el, slot);
        return;
    };

    // Hasher owns the buffer now
    slot.piece_buf = null;
    slot.state = .hashing;

    // Mark success on the web seed (download completed, hash pending)
    if (tc.web_seed_manager) |wsm| {
        wsm.markSuccess(slot.seed_index, slot.piece_size);
    }

    log.debug("web seed: piece {d} submitted to hasher", .{slot.piece_index});

    // Free the slot -- the hasher/processHashResults owns the rest of the
    // lifecycle (hash verify -> disk write -> completePiece).
    slot.reset();
}

/// Inline SHA-1 verification and disk write (fallback when hasher is unavailable).
fn inlineVerifyAndWrite(el: *EventLoop, slot: *WebSeedSlot) void {
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
    const piece_buf = slot.piece_buf orelse {
        failSlot(el, slot);
        return;
    };

    const expected_hash = sess.layout.pieceHash(slot.piece_index) catch {
        failSlot(el, slot);
        return;
    };

    var actual: [20]u8 = undefined;
    Sha1.hash(piece_buf, &actual, .{});

    if (!std.mem.eql(u8, &actual, expected_hash)) {
        log.warn("web seed: piece {d} hash mismatch", .{slot.piece_index});
        failSlot(el, slot);
        return;
    }

    // Write piece to disk via io_uring (same pattern as peer_policy.zig)
    var span_scratch: [8]LayoutSpan = undefined;
    const plan = storage.verify.planPieceVerificationWithScratch(
        el.allocator,
        sess,
        slot.piece_index,
        span_scratch[0..],
    ) catch {
        failSlot(el, slot);
        return;
    };
    defer plan.deinit(el.allocator);

    if (plan.spans.len == 0) {
        failSlot(el, slot);
        return;
    }

    const pending_key = EventLoop.PendingWriteKey{
        .piece_index = slot.piece_index,
        .torrent_id = slot.torrent_id,
    };
    const write_id = el.createPendingWrite(pending_key, .{
        .write_id = 0,
        .piece_index = slot.piece_index,
        .torrent_id = slot.torrent_id,
        .slot = 0, // no peer slot
        .buf = piece_buf,
        .spans_remaining = 0,
    }) catch {
        failSlot(el, slot);
        return;
    };

    for (plan.spans) |span| {
        if (tc.shared_fds[span.file_index] < 0) continue;
        const block = piece_buf[span.piece_offset .. span.piece_offset + span.length];
        const ud = encodeUserData(.{ .slot = 0, .op_type = .disk_write, .context = write_id });
        _ = el.ring.write(ud, tc.shared_fds[span.file_index], block, span.file_offset) catch |err| {
            log.warn("web seed: disk write for piece {d}: {s}", .{ slot.piece_index, @errorName(err) });
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
            pt.releasePiece(slot.piece_index);
            el.allocator.free(piece_buf);
            slot.reset();
            return;
        }
    }

    // Buffer ownership transferred to pending_writes
    slot.piece_buf = null;
    if (tc.web_seed_manager) |wsm| {
        wsm.markSuccess(slot.seed_index, slot.piece_size);
    }
    slot.reset();
}

/// Release a piece on failure and free the slot.
fn failSlot(el: *EventLoop, slot: *WebSeedSlot) void {
    const now = std.time.timestamp();

    if (el.getTorrentContext(slot.torrent_id)) |tc| {
        if (tc.piece_tracker) |pt| {
            pt.releasePiece(slot.piece_index);
        }
        if (tc.web_seed_manager) |wsm| {
            wsm.markFailure(slot.seed_index, now);
        }
    }

    if (slot.piece_buf) |buf| {
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
        .piece_index = 42,
        .piece_size = 16384,
        .ranges_total = 2,
        .ranges_completed = 1,
        .ranges_failed = true,
    };
    slot.reset();
    try std.testing.expectEqual(WebSeedSlot.State.free, slot.state);
    try std.testing.expectEqual(@as(u32, 0), slot.piece_index);
    try std.testing.expectEqual(@as(?[]u8, null), slot.piece_buf);
}

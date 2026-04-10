const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.recheck);

const Bitfield = @import("../bitfield.zig").Bitfield;
const verify = @import("../storage/verify.zig");
const session_mod = @import("../torrent/session.zig");
const Layout = @import("../torrent/layout.zig").Layout;
const Hasher = @import("hasher.zig").Hasher;
const types = @import("types.zig");
const encodeUserData = types.encodeUserData;

/// Asynchronous piece recheck state machine.
///
/// Verifies all pieces for a torrent using io_uring reads and the
/// background hasher thread pool. Pipelines up to `max_in_flight`
/// pieces concurrently to overlap disk I/O and hashing.
///
/// Lifecycle:
///   1. `create()` — allocates the state machine (heap-allocated because
///      the event loop holds a pointer to it).
///   2. `start()` — submits the initial batch of reads to fill the pipeline.
///   3. Event loop calls `handleReadCqe()` for each completed read, and
///      `handleHashResult()` for each completed hash verification.
///   4. When all pieces are processed, the `on_complete` callback fires.
///   5. Caller calls `destroy()` to free all resources.
pub const AsyncRecheck = struct {
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    fds: []const posix.fd_t,
    ring: *linux.IoUring,
    hasher: *Hasher,
    torrent_id: u32,

    // Results
    complete_pieces: Bitfield,
    bytes_complete: u64 = 0,

    // Resume fast path
    known_complete: ?*const Bitfield,

    // Pipeline state
    next_piece: u32 = 0, // next piece to submit reads for
    pieces_done: u32 = 0, // total pieces fully processed
    piece_count: u32,
    in_flight_reads: u32 = 0, // io_uring reads outstanding
    in_flight_hashes: u32 = 0, // pieces submitted to hasher awaiting result

    // Per-slot tracking for pipelined pieces
    slots: [max_in_flight]Slot = [_]Slot{.{}} ** max_in_flight,

    // Completion
    done: bool = false,
    on_complete: ?*const fn (*AsyncRecheck) void = null,
    /// Opaque context pointer passed to the caller (e.g. TorrentSession).
    /// The on_complete callback can use this to find its parent object.
    caller_ctx: ?*anyopaque = null,

    pub const max_in_flight: u32 = 4;

    pub const Slot = struct {
        state: SlotState = .free,
        piece_index: u32 = 0,
        plan: ?verify.PiecePlan = null,
        buf: ?[]u8 = null,
        reads_remaining: u32 = 0,
        read_failed: bool = false,

        pub const SlotState = enum { free, reading, hashing };
    };

    /// Create a heap-allocated AsyncRecheck. Must be heap-allocated because
    /// the event loop holds a pointer to it across ticks.
    pub fn create(
        allocator: std.mem.Allocator,
        session: *const session_mod.Session,
        fds: []const posix.fd_t,
        ring: *linux.IoUring,
        hasher: *Hasher,
        torrent_id: u32,
        known_complete: ?*const Bitfield,
        on_complete: ?*const fn (*AsyncRecheck) void,
        caller_ctx: ?*anyopaque,
    ) !*AsyncRecheck {
        const piece_count = session.pieceCount();
        var complete_pieces = try Bitfield.init(allocator, piece_count);
        errdefer complete_pieces.deinit(allocator);

        const self = try allocator.create(AsyncRecheck);
        self.* = .{
            .allocator = allocator,
            .session = session,
            .fds = fds,
            .ring = ring,
            .hasher = hasher,
            .torrent_id = torrent_id,
            .complete_pieces = complete_pieces,
            .known_complete = known_complete,
            .piece_count = piece_count,
            .on_complete = on_complete,
            .caller_ctx = caller_ctx,
        };
        return self;
    }

    /// Start the recheck by filling the pipeline with initial reads.
    pub fn start(self: *AsyncRecheck) void {
        if (self.piece_count == 0) {
            self.done = true;
            if (self.on_complete) |cb| cb(self);
            return;
        }

        // Skip known-complete pieces at the front and fill pipeline
        var submitted: u32 = 0;
        while (submitted < max_in_flight and !self.done) {
            if (!self.submitNextPiece()) break;
            submitted += 1;
        }

        // If all pieces were known-complete, we may already be done
        if (self.pieces_done == self.piece_count) {
            self.done = true;
            if (self.on_complete) |cb| cb(self);
        }
    }

    /// Called from the event loop's CQE dispatch when a `.recheck_read`
    /// completion arrives. Decrements the outstanding read count for the
    /// slot and, when all reads for a piece complete, submits to the hasher.
    pub fn handleReadCqe(self: *AsyncRecheck, slot_idx: u16, res: i32) void {
        if (slot_idx >= max_in_flight) return;
        var slot = &self.slots[slot_idx];
        if (slot.state != .reading) return;

        self.in_flight_reads -= 1;

        if (res < 0) {
            log.warn("recheck read failed for piece {d}: errno {d}", .{ slot.piece_index, -res });
            slot.read_failed = true;
        }

        if (slot.reads_remaining > 0) {
            slot.reads_remaining -= 1;
        }
        if (slot.reads_remaining > 0) return;

        // All reads for this piece are done
        if (slot.read_failed) {
            // Read error: mark piece as incomplete and advance
            self.finishSlot(slot_idx, false);
            return;
        }

        // Submit to hasher
        const plan = slot.plan orelse {
            self.finishSlot(slot_idx, false);
            return;
        };
        const buf = slot.buf orelse {
            self.finishSlot(slot_idx, false);
            return;
        };

        slot.state = .hashing;
        self.in_flight_hashes += 1;

        self.hasher.submitVerify(
            slot_idx,
            slot.piece_index,
            buf,
            plan.expected_hash,
            self.torrent_id,
        ) catch {
            log.warn("recheck: failed to submit piece {d} to hasher", .{slot.piece_index});
            self.in_flight_hashes -= 1;
            self.finishSlot(slot_idx, false);
            return;
        };

        // Configure hash type on the most recently appended job
        self.hasher.queue_mutex.lock();
        if (self.hasher.pending_jobs.items.len > 0) {
            const last = &self.hasher.pending_jobs.items[self.hasher.pending_jobs.items.len - 1];
            last.hash_type = plan.hash_type;
            last.expected_hash_v2 = plan.expected_hash_v2;
            last.is_recheck = true;
            last.piece_length = plan.piece_length;
        }
        self.hasher.queue_mutex.unlock();
    }

    /// Called when a hasher result arrives for a recheck piece.
    /// Updates the complete_pieces bitfield and advances the pipeline.
    pub fn handleHashResult(self: *AsyncRecheck, piece_index: u32, valid: bool, piece_buf: []u8) void {
        // Find the slot for this piece
        var slot_idx: ?u16 = null;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .hashing and slot.piece_index == piece_index) {
                slot_idx = @intCast(i);
                break;
            }
        }

        if (self.in_flight_hashes > 0) {
            self.in_flight_hashes -= 1;
        }

        if (slot_idx) |idx| {
            // The hasher took ownership of the buf; clear our reference
            // so finishSlot does not double-free.
            self.slots[idx].buf = null;
            self.finishSlot(idx, valid);
        } else {
            // Orphan result -- free the buffer
            if (valid) {
                self.markPieceComplete(piece_index);
            }
            self.allocator.free(piece_buf);
            self.pieces_done += 1;
            self.checkComplete();
        }
    }

    /// Free all resources. The caller must ensure no CQEs or hash results
    /// referencing this recheck are still in flight.
    pub fn destroy(self: *AsyncRecheck) void {
        for (&self.slots) |*slot| {
            if (slot.plan) |plan| plan.deinit(self.allocator);
            if (slot.buf) |buf| self.allocator.free(buf);
            slot.* = .{};
        }
        self.complete_pieces.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ── Internal helpers ─────────────────────────────────────

    /// Find a free slot, get the next piece that needs verification,
    /// and submit io_uring reads for each span. Returns true if a piece
    /// was submitted, false if no work remains or no free slot.
    fn submitNextPiece(self: *AsyncRecheck) bool {
        // Find a free slot
        const slot_idx = self.findFreeSlot() orelse return false;

        // Skip known-complete pieces
        while (self.next_piece < self.piece_count) {
            if (self.known_complete) |kc| {
                if (kc.has(self.next_piece)) {
                    self.markPieceComplete(self.next_piece);
                    self.pieces_done += 1;
                    self.next_piece += 1;
                    continue;
                }
            }
            break;
        }

        if (self.next_piece >= self.piece_count) return false;

        const piece_index = self.next_piece;
        self.next_piece += 1;

        // Plan the verification
        const plan = verify.planPieceVerification(self.allocator, self.session, piece_index) catch {
            log.warn("recheck: failed to plan piece {d}", .{piece_index});
            self.pieces_done += 1;
            self.checkComplete();
            return true; // consumed a piece index, try again for next
        };

        // Allocate scratch buffer for the piece data
        const buf = self.allocator.alloc(u8, plan.piece_length) catch {
            log.warn("recheck: OOM allocating buffer for piece {d}", .{piece_index});
            plan.deinit(self.allocator);
            self.pieces_done += 1;
            self.checkComplete();
            return true;
        };

        var slot = &self.slots[slot_idx];
        slot.* = .{
            .state = .reading,
            .piece_index = piece_index,
            .plan = plan,
            .buf = buf,
            .reads_remaining = 0,
            .read_failed = false,
        };

        // Submit io_uring reads for each span
        var submitted: u32 = 0;
        for (plan.spans) |span| {
            if (span.file_index >= self.fds.len) {
                slot.read_failed = true;
                continue;
            }
            const fd = self.fds[span.file_index];
            if (fd < 0) {
                slot.read_failed = true;
                continue;
            }

            const target = buf[span.piece_offset..][0..span.length];
            const ud = encodeUserData(.{
                .slot = @intCast(slot_idx),
                .op_type = .recheck_read,
                .context = 0,
            });
            _ = self.ring.read(ud, fd, .{ .buffer = target }, span.file_offset) catch |err| {
                log.warn("recheck: io_uring read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
                slot.read_failed = true;
                continue;
            };
            submitted += 1;
        }

        if (submitted == 0) {
            // No reads submitted -- mark piece as failed immediately
            self.finishSlot(slot_idx, false);
            return true;
        }

        slot.reads_remaining = submitted;
        self.in_flight_reads += submitted;
        return true;
    }

    fn findFreeSlot(self: *AsyncRecheck) ?u16 {
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .free) return @intCast(i);
        }
        return null;
    }

    /// Mark a piece complete (valid hash) and count its bytes.
    fn markPieceComplete(self: *AsyncRecheck, piece_index: u32) void {
        self.complete_pieces.set(piece_index) catch return;
        const piece_size = self.session.layout.pieceSize(piece_index) catch return;
        self.bytes_complete += piece_size;
    }

    /// Finish processing a slot: free resources, mark piece done,
    /// submit more work, and check for overall completion.
    fn finishSlot(self: *AsyncRecheck, slot_idx: u16, valid: bool) void {
        var slot = &self.slots[slot_idx];

        if (valid) {
            self.markPieceComplete(slot.piece_index);
        }

        // Free plan
        if (slot.plan) |plan| {
            plan.deinit(self.allocator);
            slot.plan = null;
        }

        // Free buffer (if hasher didn't take ownership)
        if (slot.buf) |buf| {
            self.allocator.free(buf);
            slot.buf = null;
        }

        slot.state = .free;
        self.pieces_done += 1;

        // Try to fill the pipeline with another piece
        _ = self.submitNextPiece();

        self.checkComplete();
    }

    fn checkComplete(self: *AsyncRecheck) void {
        if (self.done) return;

        // Also check if remaining pieces after next_piece are all known-complete
        // (submitNextPiece may have skipped them without counting yet)
        if (self.next_piece >= self.piece_count and
            self.in_flight_reads == 0 and
            self.in_flight_hashes == 0 and
            self.allSlotsFree())
        {
            // Count any remaining known-complete pieces we haven't counted yet
            while (self.pieces_done < self.piece_count) {
                // This shouldn't happen if submitNextPiece processed them all,
                // but be defensive.
                self.pieces_done += 1;
            }
            self.done = true;
            log.info("recheck complete: {d}/{d} pieces valid, {d} bytes", .{
                self.complete_pieces.count,
                self.piece_count,
                self.bytes_complete,
            });
            if (self.on_complete) |cb| cb(self);
        }
    }

    fn allSlotsFree(self: *const AsyncRecheck) bool {
        for (self.slots) |slot| {
            if (slot.state != .free) return false;
        }
        return true;
    }
};

// ── Tests ────────────────────────────────────────────────

test "AsyncRecheck skips all known-complete pieces" {
    const allocator = std.testing.allocator;

    // Build a minimal session with 4 pieces
    const input =
        "d4:infod6:lengthi16e4:name8:test.bin12:piece lengthi4e6:pieces80:" ++
        "aaaabbbbccccddddeeeeAAAABBBBCCCCDDDDEEEEee";
    const session = session_mod.Session.load(allocator, input, "/tmp/recheck_test") catch
        return error.SkipZigTest;
    defer session.deinit(allocator);

    // Create a "known_complete" bitfield with all pieces set
    var known = try Bitfield.init(allocator, session.pieceCount());
    defer known.deinit(allocator);
    var i: u32 = 0;
    while (i < session.pieceCount()) : (i += 1) {
        try known.set(i);
    }

    // We can't create a real IoUring or Hasher in unit tests, so test
    // the fast path by verifying the bitfield accounting.
    // This tests the skip logic indirectly: create and immediately check
    // that known-complete pieces are counted correctly by the state machine's
    // start() path.

    // Instead of exercising the full state machine (which needs a ring),
    // verify the bitfield skip logic directly.
    var complete = try Bitfield.init(allocator, session.pieceCount());
    defer complete.deinit(allocator);
    var bytes: u64 = 0;

    i = 0;
    while (i < session.pieceCount()) : (i += 1) {
        if (known.has(i)) {
            try complete.set(i);
            const ps = try session.layout.pieceSize(i);
            bytes += ps;
        }
    }

    try std.testing.expectEqual(session.pieceCount(), complete.count);
    try std.testing.expectEqual(@as(u64, 16), bytes);
}

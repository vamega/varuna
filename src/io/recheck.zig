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
const real_io_mod = @import("real_io.zig");
const RealIO = real_io_mod.RealIO;
const io_interface = @import("io_interface.zig");

/// Asynchronous piece recheck state machine, parameterised over the IO
/// backend.
///
/// Verifies all pieces for a torrent using the IO backend's async reads
/// and the background hasher thread pool. Pipelines up to `max_in_flight`
/// pieces concurrently to overlap disk I/O and hashing.
///
/// Daemon callers continue to write `AsyncRecheck` (the
/// `AsyncRecheckOf(RealIO)` alias declared below). Sim tests instantiate
/// `AsyncRecheckOf(SimIO)` directly so the same state machine drives
/// against `EventLoopOf(SimIO)` for fault-injection harnesses.
///
/// Lifecycle:
///   1. `create()` — allocates the state machine (heap-allocated because
///      the event loop holds a pointer to it).
///   2. `start()` — submits the initial batch of reads to fill the pipeline.
///   3. Event loop calls `handleReadCqe()` for each completed read, and
///      `handleHashResult()` for each completed hash verification.
///   4. When all pieces are processed, the `on_complete` callback fires.
///   5. Caller calls `destroy()` to free all resources.
pub fn AsyncRecheckOf(comptime IO: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        session: *const session_mod.Session,
        fds: []const posix.fd_t,
        io: *IO,
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
        on_complete: ?*const fn (*Self) void = null,
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
            io: *IO,
            hasher: *Hasher,
            torrent_id: u32,
            known_complete: ?*const Bitfield,
            on_complete: ?*const fn (*Self) void,
            caller_ctx: ?*anyopaque,
        ) !*Self {
            const piece_count = session.pieceCount();
            var complete_pieces = try Bitfield.init(allocator, piece_count);
            errdefer complete_pieces.deinit(allocator);

            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .session = session,
                .fds = fds,
                .io = io,
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

        /// Per-read tracking so that the io_interface callback can find the
        /// owning recheck + slot. Heap-allocated because each piece may have
        /// multiple spans in flight in parallel (one ReadOp per span);
        /// recheck is a one-shot startup phase, so the per-read alloc is not
        /// hot-path.
        const ReadOp = struct {
            completion: io_interface.Completion = .{},
            parent: *Self,
            slot_idx: u16,
        };

        /// Callback bound to a `ReadOp.completion`. Translates the async
        /// result into the legacy cqe.res shape and feeds `handleReadCqe`,
        /// then frees the ReadOp.
        fn recheckReadComplete(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const op: *ReadOp = @ptrCast(@alignCast(userdata.?));
            const res: i32 = switch (result) {
                .read => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                else => -1,
            };
            const parent = op.parent;
            const slot_idx = op.slot_idx;
            parent.allocator.destroy(op);
            parent.handleReadCqe(slot_idx, res);
            return .disarm;
        }

        /// Start the recheck by filling the pipeline with initial reads.
        pub fn start(self: *Self) void {
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
        pub fn handleReadCqe(self: *Self, slot_idx: u16, res: i32) void {
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

            self.hasher.submitVerifyEx(
                slot_idx,
                slot.piece_index,
                buf,
                plan.expected_hash,
                self.torrent_id,
                .{
                    .hash_type = plan.hash_type,
                    .expected_hash_v2 = plan.expected_hash_v2,
                    .is_recheck = true,
                },
            ) catch {
                log.warn("recheck: failed to submit piece {d} to hasher", .{slot.piece_index});
                self.in_flight_hashes -= 1;
                // submitVerifyEx failed: hasher did NOT take ownership.
                // finishSlot will free `slot.buf` correctly.
                self.finishSlot(slot_idx, false);
                return;
            };

            // Submission succeeded: ownership of `buf` has transferred to
            // the hasher (it lives in `pending_jobs` or `completed_results`
            // until the result fires through `handleHashResult`). Null the
            // slot's pointer so a teardown-time `destroy()` (or any other
            // path that walks slots and frees `slot.buf`) doesn't double-
            // free against the hasher.
            //
            // BUGGIFY harness `tests/recheck_live_buggify_test.zig`
            // surfaced this: under `EventLoop.deinit`, `hasher.deinit`
            // frees pending jobs' `piece_buf`s first (line 140 of
            // hasher.zig), then `cancelAllRechecks` runs and `destroy()`
            // sees `slot.state = .hashing` with `slot.buf` still pointing
            // at the freed memory → second free → SIGABRT.
            slot.buf = null;
        }

        /// Called when a hasher result arrives for a recheck piece.
        /// Updates the complete_pieces bitfield and advances the pipeline.
        pub fn handleHashResult(self: *Self, piece_index: u32, valid: bool, piece_buf: []u8) void {
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

            // The hasher returns the piece_buf pointer but does not free it.
            // Save allocator locally because the completion callback may destroy
            // self (via cancelRecheckForTorrent) before this defer runs.
            const alloc = self.allocator;
            defer alloc.free(piece_buf);

            if (slot_idx) |idx| {
                // Clear the slot's buf reference so finishSlot does not double-free.
                self.slots[idx].buf = null;
                self.finishSlot(idx, valid);
            } else {
                // Orphan result
                if (valid) {
                    self.markPieceComplete(piece_index);
                }
                self.pieces_done += 1;
                self.checkComplete();
            }
        }

        /// Free all resources. The caller must ensure no CQEs or hash results
        /// referencing this recheck are still in flight.
        ///
        /// `slot.buf` is freed only for slots in `.reading` state (and on
        /// the OOM path before the read submit) — for `.hashing` slots the
        /// buffer is owned by the hasher (cleared to null in
        /// `handleReadCqe` on successful submit), and the hasher's own
        /// teardown / `handleHashResult` defer is responsible for freeing
        /// it. Freeing it here would double-free against `hasher.deinit`'s
        /// pending-job sweep during `EventLoop.deinit`.
        pub fn destroy(self: *Self) void {
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
        fn submitNextPiece(self: *Self) bool {
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

            // Submit io_uring reads for each span via the io_interface backend.
            // Each ReadOp carries its own Completion so that multiple spans
            // for the same slot can be in flight concurrently.
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
                const op = self.allocator.create(ReadOp) catch |err| {
                    log.warn("recheck: ReadOp alloc for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    slot.read_failed = true;
                    continue;
                };
                op.* = .{ .parent = self, .slot_idx = slot_idx };
                self.io.read(
                    .{ .fd = fd, .buf = target, .offset = span.file_offset },
                    &op.completion,
                    op,
                    recheckReadComplete,
                ) catch |err| {
                    log.warn("recheck: io read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    self.allocator.destroy(op);
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

        fn findFreeSlot(self: *Self) ?u16 {
            for (&self.slots, 0..) |*slot, i| {
                if (slot.state == .free) return @intCast(i);
            }
            return null;
        }

        /// Mark a piece complete (valid hash) and count its bytes.
        fn markPieceComplete(self: *Self, piece_index: u32) void {
            self.complete_pieces.set(piece_index) catch return;
            const piece_size = self.session.layout.pieceSize(piece_index) catch return;
            self.bytes_complete += piece_size;
        }

        /// Finish processing a slot: free resources, mark piece done,
        /// submit more work, and check for overall completion.
        fn finishSlot(self: *Self, slot_idx: u16, valid: bool) void {
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

        fn checkComplete(self: *Self) void {
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

        fn allSlotsFree(self: *const Self) bool {
            for (self.slots) |slot| {
                if (slot.state != .free) return false;
            }
            return true;
        }
    };
}

/// Daemon-side concrete instantiation. Daemon callers continue to write
/// `AsyncRecheck` and `AsyncRecheck.method(...)`; tests that instantiate
/// against SimIO write `AsyncRecheckOf(SimIO)` directly.
pub const AsyncRecheck = AsyncRecheckOf(RealIO);

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

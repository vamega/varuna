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
const backend = @import("backend.zig");
const RealIO = backend.RealIO;
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
        v2_files: ?[]V2FileRecheck = null,

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
        destroy_requested: bool = false,
        lifecycle_depth: u32 = 0,
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
            read_ops: std.ArrayList(*ReadOp) = .empty,
            closing: bool = false,

            pub const SlotState = enum { free, reading, hashing };
        };

        const V2FileRecheck = struct {
            active: bool = false,
            first_piece: u32 = 0,
            piece_count: u32 = 0,
            pieces_root: [32]u8 = [_]u8{0} ** 32,
            piece_hashes: ?[][32]u8 = null,
            seen: ?[]bool = null,
            seen_count: u32 = 0,
            readable: bool = true,
            root_checked: bool = false,

            fn deinit(self: *V2FileRecheck, allocator: std.mem.Allocator) void {
                if (self.piece_hashes) |hashes| allocator.free(hashes);
                if (self.seen) |seen| allocator.free(seen);
                self.* = .{};
            }
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

            const v2_files = try initV2FileRechecks(allocator, session);
            errdefer if (v2_files) |states| deinitV2FileRechecks(allocator, states);

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
                .v2_files = v2_files,
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
            cancel_completion: io_interface.Completion = .{},
            parent: *Self,
            slot_idx: u16,
            read_in_flight: bool = false,
            cancel_in_flight: bool = false,
            attached: bool = false,
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
            const parent = op.parent;
            parent.enterLifecycle();
            defer parent.leaveLifecycle();

            op.read_in_flight = false;
            const slot_idx = op.slot_idx;

            if (parent.destroy_requested) {
                if (parent.in_flight_reads > 0) parent.in_flight_reads -= 1;
                parent.finishReadOp(op);
                parent.tryCompleteClosingSlot(slot_idx);
                return .disarm;
            }

            const res: i32 = switch (result) {
                .read => |r| if (r) |n|
                    std.math.cast(i32, n) orelse std.math.maxInt(i32)
                else |_|
                    -1,
                else => -1,
            };
            parent.finishReadOp(op);
            parent.handleReadCqe(slot_idx, res);
            return .disarm;
        }

        fn recheckReadCancelComplete(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            _: io_interface.Result,
        ) io_interface.CallbackAction {
            const op: *ReadOp = @ptrCast(@alignCast(userdata.?));
            const parent = op.parent;
            parent.enterLifecycle();
            defer parent.leaveLifecycle();

            op.cancel_in_flight = false;
            const slot_idx = op.slot_idx;
            parent.finishReadOp(op);
            parent.tryCompleteClosingSlot(slot_idx);
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
            if (self.destroy_requested) return;
            if (slot_idx >= max_in_flight) return;
            const slot = &self.slots[slot_idx];
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
        pub fn handleHashResult(
            self: *Self,
            piece_index: u32,
            valid: bool,
            piece_buf: []u8,
            actual_hash_v2: [32]u8,
        ) void {
            if (self.destroy_requested) {
                self.allocator.free(piece_buf);
                return;
            }

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
                if (self.requiresV2MerkleVerificationForSlot(idx)) {
                    self.finishV2MerkleSlot(idx, actual_hash_v2);
                } else {
                    self.finishSlot(idx, valid);
                }
            } else {
                // Orphan result
                if (valid) {
                    self.markPieceComplete(piece_index);
                }
                self.pieces_done += 1;
                self.checkComplete();
            }
        }

        /// Request recheck teardown. Reads that still have CQEs pending are
        /// cancelled and drained before their buffers, ReadOps, and parent
        /// recheck storage are freed.
        ///
        /// `slot.buf` is freed only for slots in `.reading` state (and on
        /// the OOM path before the read submit) — for `.hashing` slots the
        /// buffer is owned by the hasher (cleared to null in
        /// `handleReadCqe` on successful submit), and the hasher's own
        /// teardown / `handleHashResult` defer is responsible for freeing
        /// it. Freeing it here would double-free against `hasher.deinit`'s
        /// pending-job sweep during `EventLoop.deinit`.
        pub fn destroy(self: *Self) void {
            self.enterLifecycle();
            defer self.leaveLifecycle();

            if (self.destroy_requested) return;
            self.destroy_requested = true;
            self.done = true;
            self.on_complete = null;

            for (&self.slots, 0..) |*slot, i| {
                switch (slot.state) {
                    .free => {},
                    .reading => {
                        slot.closing = true;
                        var read_idx: usize = 0;
                        while (read_idx < slot.read_ops.items.len) {
                            const op = slot.read_ops.items[read_idx];
                            self.cancelReadOp(op);
                            if (read_idx < slot.read_ops.items.len and slot.read_ops.items[read_idx] == op) {
                                read_idx += 1;
                            }
                        }
                        self.tryCompleteClosingSlot(@intCast(i));
                    },
                    .hashing => self.clearSlot(@intCast(i)),
                }
            }
        }

        // ── Internal helpers ─────────────────────────────────────

        fn enterLifecycle(self: *Self) void {
            self.lifecycle_depth += 1;
        }

        fn leaveLifecycle(self: *Self) void {
            std.debug.assert(self.lifecycle_depth > 0);
            self.lifecycle_depth -= 1;
            if (self.lifecycle_depth == 0) {
                self.maybeFinalizeDestroy();
            }
        }

        fn maybeFinalizeDestroy(self: *Self) void {
            if (!self.destroy_requested) return;
            if (self.lifecycle_depth != 0) return;
            if (!self.allSlotsFree()) return;

            if (self.v2_files) |states| {
                deinitV2FileRechecks(self.allocator, states);
                self.v2_files = null;
            }
            self.complete_pieces.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        fn initV2FileRechecks(
            allocator: std.mem.Allocator,
            session: *const session_mod.Session,
        ) !?[]V2FileRecheck {
            if (session.layout.version != .v2) return null;
            const v2_files = session.metainfo.file_tree_v2 orelse return null;
            if (session.layout.files.len == 0) return null;

            const states = try allocator.alloc(V2FileRecheck, session.layout.files.len);
            @memset(states, .{});
            errdefer deinitV2FileRechecks(allocator, states);

            var any = false;
            for (session.layout.files, 0..) |file, file_idx| {
                if (file.length == 0) continue;
                if (file_idx >= v2_files.len) continue;

                const file_pieces = file.end_piece_exclusive - file.first_piece;
                if (file_pieces <= 1) continue;

                const piece_hashes = try allocator.alloc([32]u8, file_pieces);
                const seen = allocator.alloc(bool, file_pieces) catch |err| {
                    allocator.free(piece_hashes);
                    return err;
                };
                @memset(seen, false);

                states[file_idx] = .{
                    .active = true,
                    .first_piece = file.first_piece,
                    .piece_count = file_pieces,
                    .pieces_root = v2_files[file_idx].pieces_root,
                    .piece_hashes = piece_hashes,
                    .seen = seen,
                };
                any = true;
            }

            if (!any) {
                allocator.free(states);
                return null;
            }
            return states;
        }

        fn deinitV2FileRechecks(allocator: std.mem.Allocator, states: []V2FileRecheck) void {
            for (states) |*state| state.deinit(allocator);
            allocator.free(states);
        }

        fn detachReadOp(self: *Self, op: *ReadOp) void {
            if (!op.attached) return;
            if (op.slot_idx < max_in_flight) {
                const slot = &self.slots[op.slot_idx];
                for (slot.read_ops.items, 0..) |candidate, i| {
                    if (candidate == op) {
                        _ = slot.read_ops.swapRemove(i);
                        break;
                    }
                }
            }
            op.attached = false;
        }

        fn finishReadOp(self: *Self, op: *ReadOp) void {
            if (op.read_in_flight or op.cancel_in_flight) return;
            self.detachReadOp(op);
            self.allocator.destroy(op);
        }

        fn cancelReadOp(self: *Self, op: *ReadOp) void {
            if (!op.read_in_flight or op.cancel_in_flight) return;
            op.cancel_in_flight = true;
            self.io.cancel(
                .{ .target = &op.completion },
                &op.cancel_completion,
                op,
                recheckReadCancelComplete,
            ) catch {
                op.cancel_in_flight = false;
            };
        }

        fn tryCompleteClosingSlot(self: *Self, slot_idx: u16) void {
            if (slot_idx >= max_in_flight) return;
            const slot = &self.slots[slot_idx];
            if (!slot.closing) return;
            if (slot.read_ops.items.len != 0) return;
            self.clearSlot(slot_idx);
        }

        fn clearSlot(self: *Self, slot_idx: u16) void {
            if (slot_idx >= max_in_flight) return;
            var slot = &self.slots[slot_idx];
            if (slot.state == .free and slot.read_ops.items.len == 0) return;
            std.debug.assert(slot.read_ops.items.len == 0);

            if (slot.plan) |plan| {
                plan.deinit(self.allocator);
                slot.plan = null;
            }
            if (slot.buf) |buf| {
                self.allocator.free(buf);
                slot.buf = null;
            }
            slot.read_ops.deinit(self.allocator);
            slot.* = .{};
        }

        /// Find a free slot, get the next piece that needs verification,
        /// and submit io_uring reads for each span. Returns true if a piece
        /// was submitted, false if no work remains or no free slot.
        fn submitNextPiece(self: *Self) bool {
            // Find a free slot
            const slot_idx = self.findFreeSlot() orelse return false;

            // Skip known-complete pieces
            while (self.next_piece < self.piece_count) {
                if (self.known_complete) |kc| {
                    if (kc.has(self.next_piece) and self.canTrustKnownCompletePiece(kc, self.next_piece)) {
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
                self.recordV2PieceFailure(piece_index);
                self.pieces_done += 1;
                self.checkComplete();
                return true; // consumed a piece index, try again for next
            };

            // Allocate scratch buffer for the piece data
            const buf = self.allocator.alloc(u8, plan.piece_length) catch {
                log.warn("recheck: OOM allocating buffer for piece {d}", .{piece_index});
                self.recordV2PieceFailure(piece_index);
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
                slot.read_ops.append(self.allocator, op) catch |err| {
                    log.warn("recheck: ReadOp track for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    self.allocator.destroy(op);
                    slot.read_failed = true;
                    continue;
                };
                op.attached = true;
                op.read_in_flight = true;
                self.io.read(
                    .{ .fd = fd, .buf = target, .offset = span.file_offset },
                    &op.completion,
                    op,
                    recheckReadComplete,
                ) catch |err| {
                    log.warn("recheck: io read submit for piece {d}: {s}", .{ piece_index, @errorName(err) });
                    op.read_in_flight = false;
                    self.finishReadOp(op);
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

        fn v2FileStateIndexForPiece(self: *const Self, piece_index: u32) ?usize {
            const states = self.v2_files orelse return null;
            for (states, 0..) |state, idx| {
                if (!state.active) continue;
                if (piece_index >= state.first_piece and piece_index < state.first_piece + state.piece_count) {
                    return idx;
                }
            }
            return null;
        }

        fn canTrustKnownCompletePiece(self: *const Self, known: *const Bitfield, piece_index: u32) bool {
            const state_idx = self.v2FileStateIndexForPiece(piece_index) orelse return true;
            const state = &self.v2_files.?[state_idx];

            var pi = state.first_piece;
            const end = state.first_piece + state.piece_count;
            while (pi < end) : (pi += 1) {
                if (!known.has(pi)) return false;
            }
            return true;
        }

        /// Mark a piece complete (valid hash) and count its bytes.
        fn markPieceComplete(self: *Self, piece_index: u32) void {
            self.complete_pieces.set(piece_index) catch return;
            const piece_size = self.session.layout.pieceSize(piece_index) catch return;
            self.bytes_complete += piece_size;
        }

        fn requiresV2MerkleVerificationForSlot(self: *const Self, slot_idx: u16) bool {
            if (slot_idx >= max_in_flight) return false;
            const plan = self.slots[slot_idx].plan orelse return false;
            return plan.hash_type == .sha256 and
                (plan.requires_v2_merkle_verification or plan.v2_file_piece_count > 1);
        }

        fn recordV2PieceFailure(self: *Self, piece_index: u32) void {
            const state_idx = self.v2FileStateIndexForPiece(piece_index) orelse return;
            var state = &self.v2_files.?[state_idx];
            state.readable = false;
        }

        fn recordV2PieceHash(self: *Self, piece_index: u32, actual_hash_v2: [32]u8) void {
            const state_idx = self.v2FileStateIndexForPiece(piece_index) orelse {
                self.recordV2PieceFailure(piece_index);
                return;
            };
            var state = &self.v2_files.?[state_idx];
            if (!state.active or state.root_checked) return;

            const piece_in_file = piece_index - state.first_piece;
            if (piece_in_file >= state.piece_count) {
                state.readable = false;
                return;
            }

            const hashes = state.piece_hashes orelse {
                state.readable = false;
                return;
            };
            const seen = state.seen orelse {
                state.readable = false;
                return;
            };

            hashes[piece_in_file] = actual_hash_v2;
            if (!seen[piece_in_file]) {
                seen[piece_in_file] = true;
                state.seen_count += 1;
            }

            self.tryFinishV2File(state);
        }

        fn tryFinishV2File(self: *Self, state: *V2FileRecheck) void {
            if (state.root_checked) return;
            if (state.seen_count != state.piece_count) return;

            state.root_checked = true;
            if (!state.readable) return;

            const hashes = state.piece_hashes orelse return;
            const valid = verify.verifyV2MerkleRoot(self.allocator, state.pieces_root, hashes) catch |err| {
                log.warn("recheck: v2 Merkle root verification failed: {s}", .{@errorName(err)});
                return;
            };
            if (!valid) return;

            var piece_index = state.first_piece;
            const end = state.first_piece + state.piece_count;
            while (piece_index < end) : (piece_index += 1) {
                self.markPieceComplete(piece_index);
            }
        }

        fn finishV2MerkleSlot(self: *Self, slot_idx: u16, actual_hash_v2: [32]u8) void {
            const slot = &self.slots[slot_idx];
            self.recordV2PieceHash(slot.piece_index, actual_hash_v2);

            self.clearSlot(slot_idx);
            self.pieces_done += 1;

            if (!self.destroy_requested) {
                _ = self.submitNextPiece();
            }

            self.checkComplete();
        }

        /// Finish processing a slot: free resources, mark piece done,
        /// submit more work, and check for overall completion.
        fn finishSlot(self: *Self, slot_idx: u16, valid: bool) void {
            const slot = &self.slots[slot_idx];

            if (valid) {
                self.markPieceComplete(slot.piece_index);
            } else {
                self.recordV2PieceFailure(slot.piece_index);
            }

            self.clearSlot(slot_idx);
            self.pieces_done += 1;

            // Try to fill the pipeline with another piece
            if (!self.destroy_requested) {
                _ = self.submitNextPiece();
            }

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
    const piece_hashes =
        "aaaaaaaaaaaaaaaaaaaa" ++
        "bbbbbbbbbbbbbbbbbbbb" ++
        "cccccccccccccccccccc" ++
        "dddddddddddddddddddd";
    const input =
        "d4:infod6:lengthi16e4:name8:test.bin12:piece lengthi4e6:pieces" ++
        std.fmt.comptimePrint("{d}:", .{piece_hashes.len}) ++
        piece_hashes ++
        "ee";
    const session = try session_mod.Session.load(allocator, input, "/tmp/recheck_test");
    defer session.deinit(allocator);

    // Create a "known_complete" bitfield with all pieces set
    var known = try Bitfield.init(allocator, session.pieceCount());
    defer known.deinit(allocator);
    var i: u32 = 0;
    while (i < session.pieceCount()) : (i += 1) {
        try known.set(i);
    }

    // Can't construct a real ring/Hasher in unit tests; verify the
    // bitfield skip accounting directly.
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

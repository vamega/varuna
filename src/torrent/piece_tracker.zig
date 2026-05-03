const std = @import("std");
const Bitfield = @import("../bitfield.zig").Bitfield;

/// Thread-safe coordinator for piece assignment across multiple download workers.
/// Workers call claimPiece to get exclusive ownership of a piece, completePiece
/// when done, or releasePiece if they fail mid-download.
///
/// Supports two optional modes:
/// - **Selective download**: a `wanted` bitfield masks out pieces belonging
///   exclusively to skipped files. Unwanted pieces are never claimed and do not
///   count towards completion.
/// - **Sequential download**: when `sequential` is true, `claimPiece` returns
///   the lowest-index eligible piece instead of the rarest, enabling streaming
///   playback while downloading.
pub const PieceTracker = struct {
    mutex: std.Thread.Mutex = .{},
    progress_cond: std.Thread.Condition = .{},
    complete: Bitfield,
    in_progress: Bitfield,
    /// Optional mask of pieces we actually want. null = want everything.
    wanted: ?Bitfield,
    /// Number of pieces we need (wanted.count when selective, else piece_count).
    wanted_count: u32,
    /// Cached count of pieces that are both wanted AND complete. Maintained
    /// incrementally on `complete.set()` and recomputed in `setWanted` /
    /// `swapWanted`. Reading it is O(1), so `wantedRemaining()` and
    /// `isPartialSeed()` no longer scan piece_count bits per call. Hot in
    /// the per-tick `peer_policy.checkPartialSeed` loop at high torrent
    /// counts.
    wanted_completed_count: u32 = 0,
    availability: []u16,
    piece_count: u32,
    total_size: u64,
    piece_length: u32,
    bytes_complete: u64,
    /// Lowest piece index known to be unclaimed (not complete and not in-progress).
    /// Scans in claimPiece start here instead of 0, skipping the fully-claimed prefix.
    scan_hint: u32 = 0,
    /// Tracked minimum availability among unclaimed pieces. Pieces with availability
    /// above this value cannot be the rarest, allowing early-exit when we find a match.
    min_availability: u16 = 0,
    /// When true, claimPiece uses sequential (lowest-index) selection instead of
    /// rarest-first. This allows streaming playback while downloading.
    sequential: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        piece_count: u32,
        piece_length: u32,
        total_size: u64,
        initial_complete: *const Bitfield,
        initial_bytes_complete: u64,
    ) !PieceTracker {
        var complete = try Bitfield.init(allocator, piece_count);
        errdefer complete.deinit(allocator);
        @memcpy(complete.bits, initial_complete.bits);
        complete.count = initial_complete.count;

        var in_progress = try Bitfield.init(allocator, piece_count);
        errdefer in_progress.deinit(allocator);

        const availability = try allocator.alloc(u16, piece_count);
        errdefer allocator.free(availability);
        @memset(availability, 0);

        // Advance scan_hint past any initially-complete pieces.
        var hint: u32 = 0;
        while (hint < piece_count and initial_complete.has(hint)) : (hint += 1) {}

        return .{
            .complete = complete,
            .in_progress = in_progress,
            .wanted = null,
            .wanted_count = piece_count,
            // No `wanted` mask yet, so every complete piece counts as wanted.
            .wanted_completed_count = initial_complete.count,
            .availability = availability,
            .piece_count = piece_count,
            .total_size = total_size,
            .piece_length = piece_length,
            .bytes_complete = initial_bytes_complete,
            .scan_hint = hint,
            .min_availability = 0,
        };
    }

    pub fn deinit(self: *PieceTracker, allocator: std.mem.Allocator) void {
        allocator.free(self.availability);
        self.complete.deinit(allocator);
        self.in_progress.deinit(allocator);
        if (self.wanted) |*w| w.deinit(allocator);
        self.* = undefined;
    }

    /// Set the wanted piece mask for selective download. Caller transfers
    /// ownership of the Bitfield to the PieceTracker. Passing null clears
    /// the mask (want everything).
    pub fn setWanted(self: *PieceTracker, wanted: ?Bitfield) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.wanted = wanted;
        self.wanted_count = if (wanted) |w| w.count else self.piece_count;
        self.wanted_completed_count = computeWantedCompletedCount(self);
        // Reset scan hint since the wanted set changed.
        self.scan_hint = 0;
        self.min_availability = 0;
    }

    /// Apply a recheck-derived completion state in place. Used by the
    /// live force-recheck path to avoid tearing down the PieceTracker
    /// (whose `complete` Bitfield the EventLoop holds a `*const Bitfield`
    /// pointer into via `setTorrentCompletePieces`). Reuses the existing
    /// bits storage so the EL's pointer stays valid; only the bit values
    /// change. Availability counts are preserved — peer Have/bitfield
    /// announces remain valid across a recheck.
    ///
    /// **Surgical `in_progress` preservation.** Per-piece truth table on
    /// the `(was_in_progress, now_complete)` pair:
    ///
    /// | Pre-recheck                     | Recheck result          | Action                |
    /// |---------------------------------|-------------------------|-----------------------|
    /// | `in_progress`, bitfield=0       | piece complete on disk  | drop claim, bitfield=1 (rare race) |
    /// | `in_progress`, bitfield=0       | piece incomplete        | **keep claim**, bitfield=0 (surgical) |
    /// | not `in_progress`, bitfield=1   | piece complete on disk  | no change             |
    /// | not `in_progress`, bitfield=1   | piece incomplete        | bitfield=0            |
    /// | not `in_progress`, bitfield=0   | (any)                   | follow recheck        |
    ///
    /// The "keep claim" branch is the optimization. When peer A is mid-
    /// downloading piece N with blocks 0..7 already in `dp.buf`, and the
    /// recheck correctly finds piece N incomplete-on-disk (some blocks
    /// haven't flushed yet), the prior heavy clear would zero `in_progress`
    /// and force the picker to re-claim piece N — which would discard the
    /// existing DP/buf state and have peer A re-request blocks 0..7. The
    /// surgical update keeps the in_progress bit so the picker treats N
    /// as still claimed; the existing DP keeps serving deliveries; peer A
    /// continues from where it left off.
    ///
    /// The rare race-case (`in_progress` AND `now_complete`) drops the
    /// claim — the recheck's verified bytes are already on disk, so any
    /// in-flight download for that piece is now redundant work. The
    /// existing DownloadingPiece for such a row-1 piece is left alone:
    /// when in-flight blocks finish arriving, `completePieceDownload`
    /// will hash and call `completePiece`, which returns false as a
    /// duplicate of the already-complete bit. PieceTracker can't observe
    /// the DP map directly, so it can't proactively destroy the DP.
    ///
    /// Equivalent algorithm: `new_in_progress[i] = old_in_progress[i]
    /// AND NOT new_complete[i]`.
    pub fn applyRecheckResult(
        self: *PieceTracker,
        new_complete: *const Bitfield,
        new_bytes_complete: u64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(new_complete.bits.len == self.complete.bits.len);
        std.debug.assert(self.in_progress.bits.len == self.complete.bits.len);

        // Drop in_progress claims for pieces the recheck found complete.
        // For pieces still incomplete, the existing in_progress bit is
        // preserved (the surgical optimization). Done BEFORE overwriting
        // self.complete so we read the new_complete mask directly.
        var idx: u32 = 0;
        while (idx < self.piece_count) : (idx += 1) {
            if (self.in_progress.has(idx) and new_complete.has(idx)) {
                // Rare race: piece was in-flight but the recheck found
                // verified bytes on disk. Caller must also abandon the DP.
                self.in_progress.clear(idx);
            }
            // All other rows of the truth table leave in_progress unchanged.
        }

        @memcpy(self.complete.bits, new_complete.bits);
        self.complete.count = new_complete.count;
        self.bytes_complete = new_bytes_complete;
        // Pieces preserved as in_progress sit in the picker's "claimed"
        // band; scan_hint=0 lets the next claim scan advance past them
        // and any newly-completed pieces in lock-step. min_availability
        // resets because the unclaimed/in_progress partition shifted.
        self.scan_hint = 0;
        self.min_availability = 0;
        self.wanted_completed_count = computeWantedCompletedCount(self);
    }

    /// Atomically replace the wanted mask and return the old one so the
    /// caller can free it outside the lock. This avoids requiring the
    /// PieceTracker to know the allocator.
    pub fn swapWanted(self: *PieceTracker, new_wanted: ?Bitfield) ?Bitfield {
        self.mutex.lock();
        defer self.mutex.unlock();
        const old = self.wanted;
        self.wanted = new_wanted;
        self.wanted_count = if (new_wanted) |w| w.count else self.piece_count;
        self.wanted_completed_count = computeWantedCompletedCount(self);
        self.scan_hint = 0;
        self.min_availability = 0;
        return old;
    }

    /// Enable or disable sequential download mode.
    pub fn setSequential(self: *PieceTracker, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sequential = enabled;
        // Reset hints -- sequential starts from the beginning.
        if (enabled) {
            self.scan_hint = 0;
            self.min_availability = 0;
        }
    }

    /// Report that a peer has a specific piece (from have message).
    pub fn addAvailability(self: *PieceTracker, piece_index: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (piece_index < self.piece_count) {
            self.availability[piece_index] +|= 1;
        }
    }

    /// Report a full bitfield from a peer (from bitfield message).
    pub fn addBitfieldAvailability(self: *PieceTracker, bitfield_data: *const Bitfield) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index: u32 = 0;
        while (index < self.piece_count) : (index += 1) {
            if (bitfield_data.has(index)) {
                self.availability[index] +|= 1;
            }
        }
    }

    /// Remove availability for all pieces a peer had (on disconnect).
    pub fn removeBitfieldAvailability(self: *PieceTracker, bitfield_data: *const Bitfield) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index: u32 = 0;
        while (index < self.piece_count) : (index += 1) {
            if (bitfield_data.has(index) and self.availability[index] > 0) {
                self.availability[index] -= 1;
            }
        }
    }

    /// Return true when a piece is eligible for claiming (wanted and not complete).
    fn isEligible(self: *const PieceTracker, index: u32) bool {
        if (self.complete.has(index)) return false;
        if (self.wanted) |w| {
            if (!w.has(index)) return false;
        }
        return true;
    }

    /// Claim an uncompleted, unassigned piece that the given peer has.
    ///
    /// Selection strategy depends on `sequential`:
    /// - **false** (default): rarest-first among eligible pieces.
    /// - **true**: lowest-index eligible piece the peer has.
    ///
    /// Pieces outside the `wanted` mask are never claimed.
    ///
    /// In endgame mode (all remaining wanted pieces are in-progress),
    /// allows claiming pieces already assigned to other workers.
    pub fn claimPiece(self: *PieceTracker, peer_has: ?*const Bitfield) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sequential) {
            return self.claimSequentialLocked(peer_has);
        }
        return self.claimRarestFirstLocked(peer_has);
    }

    /// Rarest-first selection (the original algorithm, extended with wanted mask).
    fn claimRarestFirstLocked(self: *PieceTracker, peer_has: ?*const Bitfield) ?u32 {
        var best_index: ?u32 = null;
        var best_availability: u16 = std.math.maxInt(u16);
        var has_unassigned = false;
        var new_hint: u32 = self.piece_count;

        var index: u32 = self.scan_hint;
        while (index < self.piece_count) : (index += 1) {
            if (!self.isEligible(index)) continue;
            if (!self.in_progress.has(index)) {
                if (index < new_hint) new_hint = index;
                has_unassigned = true;

                if (peer_has) |bf| {
                    if (!bf.has(index)) continue;
                }
                const avail = self.availability[index];
                if (avail < best_availability) {
                    best_availability = avail;
                    best_index = index;
                    if (avail <= self.min_availability) break;
                }
            }
        }

        if (best_index) |idx| {
            self.in_progress.set(idx) catch return null;
            if (idx == new_hint) {
                var next = idx + 1;
                while (next < self.piece_count and (!self.isEligible(next) or self.in_progress.has(next) or self.complete.has(next))) : (next += 1) {}
                self.scan_hint = next;
            } else {
                self.scan_hint = new_hint;
            }
            self.min_availability = best_availability;
            return idx;
        }

        if (has_unassigned) {
            self.scan_hint = new_hint;
        }

        // Endgame mode: all remaining wanted pieces are in-progress.
        if (!has_unassigned and self.wantedRemaining() > 0) {
            index = 0;
            while (index < self.piece_count) : (index += 1) {
                if (!self.isEligible(index)) continue;
                if (peer_has) |bf| {
                    if (!bf.has(index)) continue;
                }
                return index;
            }
        }

        return null;
    }

    /// Sequential selection: pick the lowest-index eligible unclaimed piece.
    fn claimSequentialLocked(self: *PieceTracker, peer_has: ?*const Bitfield) ?u32 {
        var has_unassigned = false;

        var index: u32 = self.scan_hint;
        while (index < self.piece_count) : (index += 1) {
            if (!self.isEligible(index)) continue;
            if (self.in_progress.has(index)) continue;
            has_unassigned = true;

            if (peer_has) |bf| {
                if (!bf.has(index)) continue;
            }

            self.in_progress.set(index) catch return null;
            // Advance scan_hint past this piece.
            var next = index + 1;
            while (next < self.piece_count and (!self.isEligible(next) or self.in_progress.has(next) or self.complete.has(next))) : (next += 1) {}
            self.scan_hint = next;
            return index;
        }

        // Endgame: all remaining wanted pieces are in-progress.
        if (!has_unassigned and self.wantedRemaining() > 0) {
            index = 0;
            while (index < self.piece_count) : (index += 1) {
                if (!self.isEligible(index)) continue;
                if (peer_has) |bf| {
                    if (!bf.has(index)) continue;
                }
                return index;
            }
        }

        return null;
    }

    /// Try to claim a specific piece index (for building contiguous runs).
    /// Returns true if the piece was successfully claimed, false if it is
    /// already complete, already in-progress, or not wanted.
    pub fn claimSpecificPiece(self: *PieceTracker, piece_index: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (piece_index >= self.piece_count) return false;
        if (!self.isEligible(piece_index)) return false;
        if (self.in_progress.has(piece_index)) return false;

        self.in_progress.set(piece_index) catch return false;
        return true;
    }

    /// Mark a piece as fully downloaded and verified.
    /// Returns true if this was the first completion (not a duplicate from endgame).
    pub fn completePiece(self: *PieceTracker, piece_index: u32, piece_length: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.complete.has(piece_index)) {
            return false; // Duplicate completion from endgame mode
        }
        // Clear in_progress so scan_hint and endgame detection stay correct
        self.clearInProgress(piece_index);
        self.complete.set(piece_index) catch return false;
        self.bytes_complete += piece_length;
        // Maintain wanted_completed_count incrementally (O(1) hot-path
        // replacement for the per-call piece_count scan).
        if (self.wanted) |w| {
            if (w.has(piece_index)) self.wanted_completed_count += 1;
        } else {
            self.wanted_completed_count += 1;
        }
        self.progress_cond.signal();
        return true;
    }

    /// Wait for progress (piece completion) with a timeout.
    /// Returns true if signaled, false on timeout.
    pub fn waitForProgress(self: *PieceTracker, timeout_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.progress_cond.timedWait(&self.mutex, timeout_ns) catch {};
    }

    /// Release a claimed piece back to the pool (peer disconnected or failed).
    pub fn releasePiece(self: *PieceTracker, piece_index: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearInProgress(piece_index);
        // The released piece is now unclaimed; pull scan_hint back if needed.
        if (piece_index < self.scan_hint) {
            self.scan_hint = piece_index;
        }
        // The released piece may have lower availability than current min.
        if (piece_index < self.piece_count) {
            const avail = self.availability[piece_index];
            if (avail < self.min_availability) {
                self.min_availability = avail;
            }
        }
    }

    pub fn isPieceComplete(self: *PieceTracker, piece_index: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.complete.has(piece_index);
    }

    /// Count completed pieces in the range [start, end_exclusive) under a single lock.
    /// Used by RPC handlers to compute per-file progress without per-piece locking.
    pub fn countCompleteInRange(self: *PieceTracker, start: u32, end_exclusive: u32) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: u32 = 0;
        var idx = start;
        while (idx < end_exclusive) : (idx += 1) {
            if (self.complete.has(idx)) count += 1;
        }
        return count;
    }

    /// Returns true when all *wanted* pieces are complete.
    /// With no wanted mask this is equivalent to "all pieces complete".
    pub fn isComplete(self: *PieceTracker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.wantedRemaining() == 0;
    }

    /// BEP 21: returns true when all *wanted* pieces are complete but there are
    /// pieces in the torrent we don't have (i.e., we have a selective download
    /// mask and all masked-in pieces are done, but the torrent is not fully
    /// complete). This makes us a "partial seed".
    pub fn isPartialSeed(self: *PieceTracker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Must have a wanted mask with fewer pieces than the full torrent
        const w = self.wanted orelse return false;
        if (w.count >= self.piece_count) return false;
        // All wanted pieces must be complete
        return self.wantedRemaining() == 0 and self.complete.count < self.piece_count;
    }

    pub fn completedCount(self: *PieceTracker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.complete.count;
    }

    /// Number of wanted pieces that are complete.
    pub fn wantedCompletedCount(self: *PieceTracker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.wantedCompletedCountLocked();
    }

    fn wantedCompletedCountLocked(self: *const PieceTracker) u32 {
        return self.wanted_completed_count;
    }

    /// Recompute `wanted_completed_count` from scratch by scanning every
    /// bit in the wanted ∩ complete intersection. Called only on
    /// wanted-mask transitions (`setWanted` / `swapWanted`) — never on
    /// the per-tick hot path. Caller must hold `self.mutex`.
    fn computeWantedCompletedCount(self: *const PieceTracker) u32 {
        const w = self.wanted orelse return self.complete.count;
        var count: u32 = 0;
        var i: u32 = 0;
        while (i < self.piece_count) : (i += 1) {
            if (w.has(i) and self.complete.has(i)) count += 1;
        }
        return count;
    }

    /// Number of wanted pieces still remaining (not yet complete).
    fn wantedRemaining(self: *const PieceTracker) u32 {
        return self.wanted_count - self.wantedCompletedCountLocked();
    }

    pub fn bytesRemaining(self: *PieceTracker) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_size - self.bytes_complete;
    }

    fn clearInProgress(self: *PieceTracker, piece_index: u32) void {
        self.in_progress.clear(piece_index);
    }
};

// ── Tests ─────────────────────────────────────────────────

test "claim and complete pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    const p0 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), p0);

    const p1 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), p1);

    _ = tracker.completePiece(0, 4);
    try std.testing.expectEqual(@as(u32, 1), tracker.completedCount());
    try std.testing.expect(!tracker.isComplete());

    // Piece 0 should not be claimable again
    // Next claim should skip 0 (complete) and 1 (in_progress)
    const p2 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 2), p2);
}

test "release returns piece to pool" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    const p0 = tracker.claimPiece(null).?;
    tracker.releasePiece(p0);

    // Should be claimable again
    const p0_again = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), p0_again);
}

test "claim respects peer availability" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Peer only has pieces 2 and 3
    var peer_bf = try Bitfield.init(std.testing.allocator, 4);
    defer peer_bf.deinit(std.testing.allocator);
    try peer_bf.set(2);
    try peer_bf.set(3);

    const claimed = tracker.claimPiece(&peer_bf);
    try std.testing.expectEqual(@as(?u32, 2), claimed);
}

test "skips initially complete pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);
    try bf.set(0);
    try bf.set(1);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 8);
    defer tracker.deinit(std.testing.allocator);

    const claimed = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 2), claimed);
    try std.testing.expectEqual(@as(u64, 8), tracker.bytesRemaining());
}

test "rarest-first selects piece with lowest availability" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Piece 0: available from 3 peers
    // Piece 1: available from 1 peer (rarest)
    // Piece 2: available from 5 peers
    // Piece 3: available from 2 peers
    tracker.addAvailability(0);
    tracker.addAvailability(0);
    tracker.addAvailability(0);
    tracker.addAvailability(1);
    tracker.addAvailability(2);
    tracker.addAvailability(2);
    tracker.addAvailability(2);
    tracker.addAvailability(2);
    tracker.addAvailability(2);
    tracker.addAvailability(3);
    tracker.addAvailability(3);

    // Should pick piece 1 (rarest, count=1)
    const first = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), first);

    // Next should be piece 3 (count=2)
    const second = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 3), second);

    // Next should be piece 0 (count=3)
    const third = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), third);
}

test "addBitfieldAvailability updates counts" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Peer has pieces 0, 2, 4
    var peer_bf = try Bitfield.init(std.testing.allocator, 8);
    defer peer_bf.deinit(std.testing.allocator);
    try peer_bf.set(0);
    try peer_bf.set(2);
    try peer_bf.set(4);
    tracker.addBitfieldAvailability(&peer_bf);

    try std.testing.expectEqual(@as(u16, 1), tracker.availability[0]);
    try std.testing.expectEqual(@as(u16, 0), tracker.availability[1]);
    try std.testing.expectEqual(@as(u16, 1), tracker.availability[2]);
    try std.testing.expectEqual(@as(u16, 0), tracker.availability[3]);
    try std.testing.expectEqual(@as(u16, 1), tracker.availability[4]);
}

test "endgame mode allows duplicate claims" {
    var bf = try Bitfield.init(std.testing.allocator, 3);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 3, 4, 12, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Complete pieces 0 and 1
    _ = tracker.claimPiece(null); // claim 0
    _ = tracker.completePiece(0, 4);
    _ = tracker.claimPiece(null); // claim 1
    _ = tracker.completePiece(1, 4);

    // Claim piece 2 (last one)
    const first_claim = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 2), first_claim);

    // All remaining pieces are in-progress -> endgame mode
    // Second claim should also return piece 2
    const endgame_claim = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 2), endgame_claim);

    // First completion wins
    try std.testing.expect(tracker.completePiece(2, 4));
    // Duplicate completion returns false
    try std.testing.expect(!tracker.completePiece(2, 4));
    try std.testing.expect(tracker.isComplete());
}

test "wanted mask skips unwanted pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Only want pieces 0 and 3
    var wanted = try Bitfield.init(std.testing.allocator, 4);
    try wanted.set(0);
    try wanted.set(3);
    tracker.setWanted(wanted);

    const first = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), first);

    const second = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 3), second);

    // All wanted pieces are now in-progress -> claimPiece enters endgame
    // mode and may return an already-claimed wanted piece for duplicate
    // work. Production endgame behavior; test pins the shape.
    const third = tracker.claimPiece(null);
    try std.testing.expect(third != null);
    try std.testing.expect(third.? == 0 or third.? == 3);

    // Complete both wanted pieces -> isComplete should be true
    _ = tracker.completePiece(0, 4);
    _ = tracker.completePiece(3, 4);
    try std.testing.expect(tracker.isComplete());

    // Even though pieces 1 and 2 are not complete
    try std.testing.expectEqual(@as(u32, 2), tracker.completedCount());
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());
}

test "sequential mode returns pieces in order" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    tracker.setSequential(true);

    // Add high availability for piece 0, low for piece 3
    // Sequential should still pick piece 0 first (ignores availability).
    tracker.addAvailability(0);
    tracker.addAvailability(0);
    tracker.addAvailability(0);
    tracker.addAvailability(3);

    const first = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), first);

    const second = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), second);

    const third = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 2), third);

    const fourth = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 3), fourth);
}

test "sequential mode respects wanted mask" {
    var bf = try Bitfield.init(std.testing.allocator, 6);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 6, 4, 24, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    tracker.setSequential(true);

    // Only want pieces 1, 3, 5
    var wanted = try Bitfield.init(std.testing.allocator, 6);
    try wanted.set(1);
    try wanted.set(3);
    try wanted.set(5);
    tracker.setWanted(wanted);

    const first = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), first);

    const second = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 3), second);

    const third = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 5), third);
}

test "sequential endgame allows duplicate claims" {
    var bf = try Bitfield.init(std.testing.allocator, 2);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 2, 4, 8, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    tracker.setSequential(true);

    _ = tracker.completePiece(0, 4);

    // Claim piece 1
    const first = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), first);

    // Endgame: piece 1 is in-progress, should still return it
    const endgame = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), endgame);
}

test "isComplete with wanted mask ignores unwanted pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Want only piece 0
    var wanted = try Bitfield.init(std.testing.allocator, 4);
    try wanted.set(0);
    tracker.setWanted(wanted);

    try std.testing.expect(!tracker.isComplete());

    _ = tracker.completePiece(0, 4);
    try std.testing.expect(tracker.isComplete());

    // Pieces 1, 2, 3 are not complete but also not wanted
    try std.testing.expectEqual(@as(u32, 1), tracker.completedCount());
}

// ── BEP 21: Partial Seed Tests ─────────────────────────

test "isPartialSeed returns false without wanted mask" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // No wanted mask -- even if all pieces complete, not a partial seed
    _ = tracker.completePiece(0, 4);
    _ = tracker.completePiece(1, 4);
    _ = tracker.completePiece(2, 4);
    _ = tracker.completePiece(3, 4);
    try std.testing.expect(!tracker.isPartialSeed());
}

test "isPartialSeed returns false when wanted mask covers all pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Want all 4 pieces -- full seed, not partial
    var wanted = try Bitfield.init(std.testing.allocator, 4);
    try wanted.set(0);
    try wanted.set(1);
    try wanted.set(2);
    try wanted.set(3);
    tracker.setWanted(wanted);

    _ = tracker.completePiece(0, 4);
    _ = tracker.completePiece(1, 4);
    _ = tracker.completePiece(2, 4);
    _ = tracker.completePiece(3, 4);
    try std.testing.expect(!tracker.isPartialSeed());
}

test "isPartialSeed returns true when wanted pieces complete but torrent incomplete" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Want only pieces 0 and 1 (selective download)
    var wanted = try Bitfield.init(std.testing.allocator, 4);
    try wanted.set(0);
    try wanted.set(1);
    tracker.setWanted(wanted);

    // Complete only the wanted pieces
    _ = tracker.completePiece(0, 4);
    try std.testing.expect(!tracker.isPartialSeed()); // not yet -- piece 1 still missing

    _ = tracker.completePiece(1, 4);
    try std.testing.expect(tracker.isPartialSeed()); // all wanted done, 2 & 3 missing

    // Also verify isComplete returns true (all wanted are done)
    try std.testing.expect(tracker.isComplete());
    // But total completion is only 2 of 4
    try std.testing.expectEqual(@as(u32, 2), tracker.completedCount());
}

test "isPartialSeed transitions to false when all pieces complete" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Want only pieces 0 and 1
    var wanted = try Bitfield.init(std.testing.allocator, 4);
    try wanted.set(0);
    try wanted.set(1);
    tracker.setWanted(wanted);

    _ = tracker.completePiece(0, 4);
    _ = tracker.completePiece(1, 4);
    try std.testing.expect(tracker.isPartialSeed());

    // Complete remaining pieces (e.g., user changed file priorities)
    _ = tracker.completePiece(2, 4);
    _ = tracker.completePiece(3, 4);
    // Still partial seed because wanted mask only covers 2 pieces
    // but all pieces are complete, so complete.count == piece_count
    try std.testing.expect(!tracker.isPartialSeed());
}

test "wanted_completed_count cache stays consistent across complete and setWanted" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), tracker.wantedCompletedCount());
    try std.testing.expect(!tracker.isPartialSeed());

    try std.testing.expect(tracker.completePiece(0, 4));
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());

    var wanted = try Bitfield.init(std.testing.allocator, 8);
    try wanted.set(0);
    try wanted.set(1);
    try wanted.set(2);
    tracker.setWanted(wanted);
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());

    try std.testing.expect(tracker.completePiece(1, 4));
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    try std.testing.expect(tracker.completePiece(5, 4));
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    try std.testing.expect(tracker.completePiece(2, 4));
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
    try std.testing.expect(tracker.isPartialSeed());

    var wider = try Bitfield.init(std.testing.allocator, 8);
    try wider.set(0);
    try wider.set(1);
    try wider.set(2);
    try wider.set(5);
    try wider.set(6);
    if (tracker.swapWanted(wider)) |old| {
        var old_mut = old;
        old_mut.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(u32, 4), tracker.wantedCompletedCount());
    try std.testing.expect(!tracker.isPartialSeed());
}

test "wanted_completed_count cache initialised from initial_complete" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);
    try bf.set(0);
    try bf.set(2);
    try bf.set(4);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 12);
    defer tracker.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
}

test "wanted_completed_count cache resets when wanted mask is removed" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    var wanted = try Bitfield.init(std.testing.allocator, 8);
    try wanted.set(0);
    try wanted.set(1);
    tracker.setWanted(wanted);

    try std.testing.expect(tracker.completePiece(0, 4));
    try std.testing.expect(tracker.completePiece(1, 4));
    try std.testing.expect(tracker.completePiece(5, 4));
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    if (tracker.swapWanted(null)) |old| {
        var old_mut = old;
        old_mut.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
}

// ── completePiece clears in_progress ─────────────────────

test "completePiece clears in_progress bit" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Step 1: claim a piece and verify it is marked in_progress
    const p0 = tracker.claimPiece(null).?;
    try std.testing.expectEqual(@as(u32, 0), p0);
    try std.testing.expect(tracker.in_progress.has(p0));
    try std.testing.expect(!tracker.complete.has(p0));

    // Step 2: complete the piece and verify in_progress is cleared
    const first_completion = tracker.completePiece(p0, 4);
    try std.testing.expect(first_completion);
    try std.testing.expect(tracker.complete.has(p0));
    try std.testing.expect(!tracker.in_progress.has(p0));

    // Step 3: verify cleared in_progress does not block scan_hint advancement.
    // Claim the next two pieces so that scan_hint advances past them.
    const p1 = tracker.claimPiece(null).?;
    try std.testing.expectEqual(@as(u32, 1), p1);
    _ = tracker.completePiece(p1, 4);

    const p2 = tracker.claimPiece(null).?;
    try std.testing.expectEqual(@as(u32, 2), p2);
    _ = tracker.completePiece(p2, 4);

    // Next claim must advance to piece 3, not revisit piece 0.
    const p3 = tracker.claimPiece(null).?;
    try std.testing.expectEqual(@as(u32, 3), p3);

    // Step 4: duplicate completion returns false (endgame dedup)
    try std.testing.expect(!tracker.completePiece(p0, 4));
}

test "completePiece in_progress count decrements correctly" {
    var bf = try Bitfield.init(std.testing.allocator, 4);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 4, 4, 16, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Initially no pieces in progress
    try std.testing.expectEqual(@as(u32, 0), tracker.in_progress.count);

    // Claim two pieces
    _ = tracker.claimPiece(null); // piece 0
    _ = tracker.claimPiece(null); // piece 1
    try std.testing.expectEqual(@as(u32, 2), tracker.in_progress.count);

    // Complete piece 0 -- count should drop to 1
    _ = tracker.completePiece(0, 4);
    try std.testing.expectEqual(@as(u32, 1), tracker.in_progress.count);
    try std.testing.expect(!tracker.in_progress.has(0));
    try std.testing.expect(tracker.in_progress.has(1));

    // Complete piece 1 -- count should drop to 0
    _ = tracker.completePiece(1, 4);
    try std.testing.expectEqual(@as(u32, 0), tracker.in_progress.count);
}

test "claimSpecificPiece claims adjacent pieces for contiguous runs" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 256, 2048, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Claim piece 0 normally
    const p0 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), p0);

    // Claim adjacent pieces specifically for a contiguous run
    try std.testing.expect(tracker.claimSpecificPiece(1));
    try std.testing.expect(tracker.claimSpecificPiece(2));
    try std.testing.expect(tracker.claimSpecificPiece(3));

    // All four should be in-progress
    try std.testing.expectEqual(@as(u32, 4), tracker.in_progress.count);

    // Can't claim already in-progress pieces
    try std.testing.expect(!tracker.claimSpecificPiece(0));
    try std.testing.expect(!tracker.claimSpecificPiece(1));

    // Can't claim out-of-bounds
    try std.testing.expect(!tracker.claimSpecificPiece(8));

    // Complete piece 2 and verify it can't be claimed again
    _ = tracker.completePiece(2, 256);
    try std.testing.expect(!tracker.claimSpecificPiece(2));

    // Release piece 3 and verify it can be claimed again
    tracker.releasePiece(3);
    try std.testing.expect(tracker.claimSpecificPiece(3));
}

const std = @import("std");
const Bitfield = @import("../bitfield.zig").Bitfield;

/// Thread-safe coordinator for piece assignment across multiple download workers.
/// Workers call claimPiece to get exclusive ownership of a piece, completePiece
/// when done, or releasePiece if they fail mid-download.
pub const PieceTracker = struct {
    mutex: std.Thread.Mutex = .{},
    complete: Bitfield,
    in_progress: Bitfield,
    availability: []u16,
    piece_count: u32,
    total_size: u64,
    piece_length: u32,
    bytes_complete: u64,

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

        return .{
            .complete = complete,
            .in_progress = in_progress,
            .availability = availability,
            .piece_count = piece_count,
            .total_size = total_size,
            .piece_length = piece_length,
            .bytes_complete = initial_bytes_complete,
        };
    }

    pub fn deinit(self: *PieceTracker, allocator: std.mem.Allocator) void {
        allocator.free(self.availability);
        self.complete.deinit(allocator);
        self.in_progress.deinit(allocator);
        self.* = undefined;
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
    pub fn addBitfieldAvailability(self: *PieceTracker, bitfield_data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index: u32 = 0;
        while (index < self.piece_count) : (index += 1) {
            const byte_index: usize = @intCast(index / 8);
            const bit_index: u3 = @intCast(7 - (index % 8));
            if (byte_index < bitfield_data.len and (bitfield_data[byte_index] & (@as(u8, 1) << bit_index)) != 0) {
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

    /// Claim an uncompleted, unassigned piece that the given peer has.
    /// Uses rarest-first selection: picks the eligible piece with the lowest
    /// availability count. Falls back to sequential if no availability data.
    pub fn claimPiece(self: *PieceTracker, peer_has: ?*const Bitfield) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var best_index: ?u32 = null;
        var best_availability: u16 = std.math.maxInt(u16);

        var index: u32 = 0;
        while (index < self.piece_count) : (index += 1) {
            if (self.complete.has(index)) continue;
            if (self.in_progress.has(index)) continue;
            if (peer_has) |bf| {
                if (!bf.has(index)) continue;
            }
            const avail = self.availability[index];
            if (avail < best_availability) {
                best_availability = avail;
                best_index = index;
            }
        }

        if (best_index) |idx| {
            self.in_progress.set(idx) catch return null;
            return idx;
        }
        return null;
    }

    /// Mark a piece as fully downloaded and verified.
    pub fn completePiece(self: *PieceTracker, piece_index: u32, piece_length: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.complete.set(piece_index) catch {};
        // in_progress bit doesn't need clearing since complete takes precedence in claimPiece
        self.bytes_complete += piece_length;
    }

    /// Release a claimed piece back to the pool (peer disconnected or failed).
    pub fn releasePiece(self: *PieceTracker, piece_index: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearInProgress(piece_index);
    }

    pub fn isComplete(self: *PieceTracker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.complete.count == self.piece_count;
    }

    pub fn completedCount(self: *PieceTracker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.complete.count;
    }

    pub fn bytesRemaining(self: *PieceTracker) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.total_size - self.bytes_complete;
    }

    fn clearInProgress(self: *PieceTracker, piece_index: u32) void {
        if (piece_index >= self.piece_count) return;
        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        self.in_progress.bits[byte_index] &= ~(@as(u8, 1) << bit_index);
        if (self.in_progress.count > 0) self.in_progress.count -= 1;
    }
};

test "claim and complete pieces" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    const p0 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 0), p0);

    const p1 = tracker.claimPiece(null);
    try std.testing.expectEqual(@as(?u32, 1), p1);

    tracker.completePiece(0, 4);
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

    // Peer has pieces 0, 2, 4 (bits: 10101000)
    tracker.addBitfieldAvailability(&[_]u8{0b10101000});

    try std.testing.expectEqual(@as(u16, 1), tracker.availability[0]);
    try std.testing.expectEqual(@as(u16, 0), tracker.availability[1]);
    try std.testing.expectEqual(@as(u16, 1), tracker.availability[2]);
    try std.testing.expectEqual(@as(u16, 0), tracker.availability[3]);
    try std.testing.expectEqual(@as(u16, 1), tracker.availability[4]);
}

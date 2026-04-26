//! BUGGIFY-style randomised stress test for the
//! `wanted_completed_count` cache (Task #5 fix). Per `STYLE.md`'s
//! Layered Testing Strategy, this is a layer-3 safety-under-faults
//! test: many seeds × random operation sequences, asserting the
//! cache invariant holds regardless of order.
//!
//! Invariant under test (after every mutation):
//!
//!   tracker.wantedCompletedCount() ==
//!     |{ piece i : (wanted is null OR wanted.has(i)) AND complete.has(i) }|
//!
//! That is: the cache always equals the count we'd compute from
//! scratch by intersecting the wanted and complete bitfields. The
//! incremental maintenance in `completePiece` and the recompute in
//! `setWanted` / `swapWanted` must cover every observable transition.
//!
//! Operation mix (random per step):
//!   * `completePiece(i)` — for any piece i ∈ [0, piece_count).
//!   * `setWanted(mask)` — random subset of pieces.
//!   * `swapWanted(null)` — drop the mask entirely.
//!
//! No fault injection beyond the random operation order; the goal is
//! to exhaustively explore the state space the cache claims to track.

const std = @import("std");
const varuna = @import("varuna");
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;

/// Compute the ground-truth count by direct bitfield intersection,
/// matching what `wantedCompletedCountLocked` did before the cache.
fn groundTruthWantedCompletedCount(tracker: *PieceTracker) u32 {
    tracker.mutex.lock();
    defer tracker.mutex.unlock();
    if (tracker.wanted) |w| {
        var count: u32 = 0;
        var i: u32 = 0;
        while (i < tracker.piece_count) : (i += 1) {
            if (w.has(i) and tracker.complete.has(i)) count += 1;
        }
        return count;
    }
    return tracker.complete.count;
}

fn assertCacheConsistent(tracker: *PieceTracker) !void {
    const cached = tracker.wantedCompletedCount();
    const ground = groundTruthWantedCompletedCount(tracker);
    if (cached != ground) {
        std.debug.print(
            "cache desync: cached={} ground={} complete.count={} wanted_count={}\n",
            .{ cached, ground, tracker.complete.count, tracker.wanted_count },
        );
        return error.CacheDesync;
    }
}

fn randomBitfield(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng, piece_count: u32, density: f32) !Bitfield {
    var bf = try Bitfield.init(allocator, piece_count);
    var i: u32 = 0;
    while (i < piece_count) : (i += 1) {
        if (rng.random().float(f32) < density) try bf.set(i);
    }
    return bf;
}

test "wanted_completed_count cache: 64 seeds × random op sequences" {
    const allocator = std.testing.allocator;
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        const piece_count: u32 = 32;
        var bf = try Bitfield.init(allocator, piece_count);
        defer bf.deinit(allocator);

        var tracker = try PieceTracker.init(allocator, piece_count, 4, 4 * @as(u64, piece_count), &bf, 0);
        defer tracker.deinit(allocator);

        var rng = std.Random.DefaultPrng.init(seed);
        try assertCacheConsistent(&tracker);

        var step: u32 = 0;
        while (step < 256) : (step += 1) {
            const op = rng.random().uintLessThan(u32, 16);
            if (op < 12) {
                // Most-common: complete a random piece (idempotent on
                // already-complete).
                const idx = rng.random().uintLessThan(u32, piece_count);
                _ = tracker.completePiece(idx, 4);
            } else if (op < 14) {
                // Replace the wanted mask with a random subset.
                const wanted = try randomBitfield(allocator, &rng, piece_count, 0.5);
                if (tracker.swapWanted(wanted)) |old| {
                    var old_mut = old;
                    old_mut.deinit(allocator);
                }
            } else {
                // Drop the mask.
                if (tracker.swapWanted(null)) |old| {
                    var old_mut = old;
                    old_mut.deinit(allocator);
                }
            }
            try assertCacheConsistent(&tracker);
        }

        // Drop the mask before deinit to free any active wanted bitfield.
        if (tracker.swapWanted(null)) |old| {
            var old_mut = old;
            old_mut.deinit(allocator);
        }
    }
}

test "wanted_completed_count cache: completePiece is idempotent" {
    // Cache must NOT double-increment when `completePiece` is called
    // on an already-complete piece. The function returns false in that
    // case; the cache should be unchanged.
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 8);
    defer bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(allocator);

    var wanted = try Bitfield.init(allocator, 8);
    try wanted.set(0);
    try wanted.set(1);
    tracker.setWanted(wanted);

    try std.testing.expect(tracker.completePiece(0, 4));
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());

    // Same piece again — must not re-increment the cache.
    try std.testing.expect(!tracker.completePiece(0, 4));
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());
    try assertCacheConsistent(&tracker);
}

test "wanted_completed_count cache: setWanted to subset of complete" {
    // After several pieces are complete, setting a wanted mask that
    // covers only some of them must produce the right count.
    const allocator = std.testing.allocator;
    var bf = try Bitfield.init(allocator, 16);
    defer bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, 16, 4, 64, &bf, 0);
    defer tracker.deinit(allocator);

    // Complete pieces 0, 2, 4, 6, 8 (five pieces).
    var i: u32 = 0;
    while (i < 10) : (i += 2) {
        _ = tracker.completePiece(i, 4);
    }
    try std.testing.expectEqual(@as(u32, 5), tracker.wantedCompletedCount());

    // Now want only pieces 0, 1, 2, 3 — three of the complete ones
    // are inside (0, 2 — wait, piece 1 and 3 aren't complete). So
    // wanted∩complete = {0, 2} = 2.
    var w = try Bitfield.init(allocator, 16);
    try w.set(0);
    try w.set(1);
    try w.set(2);
    try w.set(3);
    tracker.setWanted(w);
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());
    try assertCacheConsistent(&tracker);

    // Complete piece 1 (now wanted) — cache increments.
    _ = tracker.completePiece(1, 4);
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());

    // Complete piece 12 (NOT wanted) — cache stays.
    _ = tracker.completePiece(12, 4);
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
    try assertCacheConsistent(&tracker);
}

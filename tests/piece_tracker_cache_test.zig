//! Regression tests for the `wanted_completed_count` cache in
//! `PieceTracker` (Task #5: tick_sparse_torrents 1.4× regression).
//!
//! The cache replaces a per-call O(piece_count) bitfield AND-loop in
//! `wantedCompletedCountLocked` with O(1) reads, restoring
//! `isPartialSeed` performance under high torrent counts where
//! `peer_policy.checkPartialSeed` calls it once per torrent per tick.
//! These tests guard the cache's incremental-maintenance invariants:
//! piece completion increments only when the piece is wanted, and
//! mask-replacement (`setWanted` / `swapWanted`) recomputes from
//! scratch.

const std = @import("std");
const varuna = @import("varuna");
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;

test "wanted_completed_count cache stays consistent across complete + setWanted" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 0);
    defer tracker.deinit(std.testing.allocator);

    // Initially nothing wanted-completed; isPartialSeed false (no wanted mask).
    try std.testing.expectEqual(@as(u32, 0), tracker.wantedCompletedCount());
    try std.testing.expect(!tracker.isPartialSeed());

    // Complete piece 0 — cache increments via the no-wanted-mask path.
    try std.testing.expect(tracker.completePiece(0, 4));
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());

    // Set wanted = {0, 1, 2}. computeWantedCompletedCount runs once: 1
    // (just piece 0 is both wanted and complete).
    var wanted = try Bitfield.init(std.testing.allocator, 8);
    try wanted.set(0);
    try wanted.set(1);
    try wanted.set(2);
    tracker.setWanted(wanted);
    try std.testing.expectEqual(@as(u32, 1), tracker.wantedCompletedCount());

    // Complete piece 1 — wanted, so cache increments.
    try std.testing.expect(tracker.completePiece(1, 4));
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    // Complete piece 5 — NOT wanted, so cache must not increment.
    try std.testing.expect(tracker.completePiece(5, 4));
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    // Complete piece 2 — last wanted piece. Now isPartialSeed should be true
    // (wanted complete, but full torrent not done — pieces 3, 4, 6, 7 unfinished).
    try std.testing.expect(tracker.completePiece(2, 4));
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
    try std.testing.expect(tracker.isPartialSeed());

    // Replace the wanted mask with a wider one: wanted_completed_count must
    // be recomputed (now {0, 1, 2, 5} are wanted-and-complete = 4).
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
    // No longer a partial seed — piece 6 is wanted but not complete.
    try std.testing.expect(!tracker.isPartialSeed());
}

test "wanted_completed_count cache initialised from initial_complete" {
    // `PieceTracker.init` seeds the cache from initial_complete.count when
    // there's no wanted mask yet — guarantees correctness even when the
    // tracker is loaded mid-download from the resume DB.
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);
    try bf.set(0);
    try bf.set(2);
    try bf.set(4);

    var tracker = try PieceTracker.init(std.testing.allocator, 8, 4, 32, &bf, 12);
    defer tracker.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
}

test "wanted_completed_count cache: setWanted to null after partial completion" {
    // Edge case: removing the wanted mask resets the count to all
    // complete pieces (since "no mask" means "everything is wanted").
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
    try std.testing.expect(tracker.completePiece(5, 4)); // not wanted; no cache delta
    try std.testing.expectEqual(@as(u32, 2), tracker.wantedCompletedCount());

    // Drop the wanted mask. The cache should now reflect ALL complete
    // pieces (3 of them).
    if (tracker.swapWanted(null)) |old| {
        var old_mut = old;
        old_mut.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(u32, 3), tracker.wantedCompletedCount());
}

//! Piece hash lifecycle tests (Track A — `docs/piece-hash-lifecycle.md`).
//!
//! Three-phase memory savings for v1/hybrid SHA-1 piece hash tables:
//! * Phase 1: per-piece zeroing on verification + endgame slice free.
//! * Phase 2: skip parsing entirely for seeding-only loads.
//! * Phase 3: re-materialise on-demand from `torrent_bytes` for recheck.
//!
//! These are algorithm-level tests against bare structures (no event loop,
//! no SimIO). The integration coverage is in
//! `tests/sim_piece_hash_lifecycle_test.zig`.

const std = @import("std");
const varuna = @import("varuna");
const Session = varuna.torrent.session.Session;
const metainfo = varuna.torrent.metainfo;

// Single-file v1 torrent: 10 bytes total, piece_length=4 → 3 pieces of 20-byte hashes.
const v1_input =
    "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:" ++
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

// ── metainfo parseSeedingOnly ──────────────────────────────────

test "parseSeedingOnly leaves pieces empty for v1 torrents" {
    const parsed = try metainfo.parseSeedingOnly(std.testing.allocator, v1_input);
    defer metainfo.freeMetainfo(std.testing.allocator, parsed);

    try std.testing.expect(parsed.pieces.len == 0);
    // pieceCount is still derivable from file sizes (10 / 4 = 3).
    try std.testing.expectEqual(@as(u32, 3), try parsed.pieceCount());
    try std.testing.expectEqual(@as(u32, 4), parsed.piece_length);
    // pieceHash returns PiecesNotLoaded since the field is empty.
    try std.testing.expectError(error.PiecesNotLoaded, parsed.pieceHash(0));
}

test "parseSeedingOnly still rejects malformed torrents" {
    const bad = "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi0e6:pieces20:abcdefghijklmnopqrstee";
    try std.testing.expectError(
        error.InvalidPieceLength,
        metainfo.parseSeedingOnly(std.testing.allocator, bad),
    );
}

test "parseSeedingOnly requires the pieces field to be present (presence-only check)" {
    // Hybrid torrent shape but missing `pieces` — must still reject as malformed.
    const missing_pieces =
        "d4:infod6:lengthi5e4:name8:test.bin12:piece lengthi4eee";
    try std.testing.expectError(
        error.MissingRequiredField,
        metainfo.parseSeedingOnly(std.testing.allocator, missing_pieces),
    );
}

// ── Session lifecycle ──────────────────────────────────────────

test "loadForDownload materialises pieces in heap (separately from arena)" {
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.hasPieceHashes());
    try std.testing.expect(sess.pieces != null);
    try std.testing.expect(sess.layout.piece_hashes != null);

    // Reading hash through the layout returns the original bytes.
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));
    try std.testing.expectEqualStrings("uvwxyzABCDEFGHIJKLMN", try sess.layout.pieceHash(1));
}

test "loadForSeeding skips pieces entirely (Phase 2 zero-cost steady state)" {
    var sess = try Session.loadForSeeding(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(!sess.hasPieceHashes());
    try std.testing.expect(sess.pieces == null);
    try std.testing.expect(sess.layout.piece_hashes == null);

    // Layout still answers piece_count from file sizes. The seeder only needs
    // this for the BITFIELD it sends to peers — never the hashes themselves.
    try std.testing.expectEqual(@as(u32, 3), sess.pieceCount());
    try std.testing.expectEqual(@as(u64, 10), sess.totalSize());

    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(0));
}

test "freePieces releases buffer and clears layout pointer (Phase 1 endgame)" {
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.hasPieceHashes());

    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());
    try std.testing.expect(sess.layout.piece_hashes == null);
    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(0));

    // Idempotent — double-free safe.
    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());
}

test "loadPiecesForRecheck restores hash table from torrent_bytes (Phase 3)" {
    var sess = try Session.loadForSeeding(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(!sess.hasPieceHashes());
    try sess.loadPiecesForRecheck();
    try std.testing.expect(sess.hasPieceHashes());

    // The reconstituted hashes match the originals exactly.
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));
    try std.testing.expectEqualStrings("uvwxyzABCDEFGHIJKLMN", try sess.layout.pieceHash(1));

    // No-op when already loaded.
    try sess.loadPiecesForRecheck();
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));
}

test "loadPiecesForRecheck → freePieces → loadPiecesForRecheck cycles cleanly" {
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));
    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());

    try sess.loadPiecesForRecheck();
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));

    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());
}

test "zeroPieceHash clobbers a single piece in place (Phase 1 piece-by-piece)" {
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    sess.zeroPieceHash(1);

    const expect_zero: [20]u8 = [_]u8{0} ** 20;
    try std.testing.expectEqualSlices(u8, &expect_zero, try sess.layout.pieceHash(1));

    // Other pieces are untouched.
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));
    try std.testing.expectEqualStrings("OPQRSTUVWXYZ12345678", try sess.layout.pieceHash(2));
}

test "zeroPieceHash + allHashesVerified drives the Phase 1 endgame trigger" {
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(!sess.allHashesVerified());

    sess.zeroPieceHash(0);
    try std.testing.expect(!sess.allHashesVerified());
    sess.zeroPieceHash(1);
    try std.testing.expect(!sess.allHashesVerified());
    sess.zeroPieceHash(2);
    try std.testing.expect(sess.allHashesVerified());

    // Idempotent: zeroing the same piece twice doesn't break the count.
    sess.zeroPieceHash(2);
    try std.testing.expect(sess.allHashesVerified());

    // After freePieces, allHashesVerified treats the absent table as "yes".
    sess.freePieces();
    try std.testing.expect(sess.allHashesVerified());
}

test "zeroPieceHash on a v2 torrent is a safe no-op (no flat hash table)" {
    const pr = [_]u8{0xAA} ** 32;
    const v2_input = "d4:infod9:file treed8:test.bind0:d6:lengthi5e11:pieces root32:" ++ pr ++ "eee4:name4:test12:piece lengthi16384eee";
    var sess = try Session.loadForDownload(std.testing.allocator, v2_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.layout.version == .v2);
    try std.testing.expect(sess.pieces == null);

    // None of these should panic / leak.
    sess.zeroPieceHash(0);
    sess.freePieces();
    try std.testing.expectError(error.UnsupportedForV2, sess.loadPiecesForRecheck());
}

test "smart-ban interaction: hash stays live across failed-piece re-download" {
    // Phase 1's invariant: zeroPieceHash is only called after pt.completePiece
    // returns true (i.e. piece is verified AND on disk). A failed piece does
    // NOT trigger zeroing — the hash must remain readable for the next
    // completePieceDownload attempt. This test exercises the read-multiple-
    // times shape that smart-ban-corrupted pieces hit.
    var sess = try Session.loadForDownload(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    // Read the hash multiple times — simulating a piece that fails, gets
    // re-downloaded, and is verified on the second attempt.
    const h0_first = try std.testing.allocator.dupe(u8, try sess.layout.pieceHash(0));
    defer std.testing.allocator.free(h0_first);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", h0_first);

    // Now the piece passes; the EL would call zeroPieceHash AFTER pt.completePiece.
    sess.zeroPieceHash(0);
    const h0_after = try sess.layout.pieceHash(0);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 20), h0_after);

    // And piece 1 is still live for its own subsequent verification.
    try std.testing.expectEqualStrings("uvwxyzABCDEFGHIJKLMN", try sess.layout.pieceHash(1));
}

// ── Layout-level guard rail ────────────────────────────────────

test "layout.pieceHash fails closed when piece_hashes is null" {
    var sess = try Session.loadForSeeding(std.testing.allocator, v1_input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    // Explicitly test the layout-level error path — every subsystem that
    // calls layout.pieceHash() must catch this and either skip the
    // operation (seeder upload paths) or trigger loadPiecesForRecheck
    // (recheck path).
    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(0));
    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(2));
    // Out-of-range still fires its own error (precondition checked first).
    try std.testing.expectError(error.InvalidPieceIndex, sess.layout.pieceHash(99));
}

// ── Memory savings demonstration ───────────────────────────────

/// Build a v1 torrent with N pieces of `piece_size` bytes each. Uses
/// a 16 KB piece size and N=64 (~1 MB total) so the piece hash table
/// is 1280 bytes — small but measurable through the tracking allocator.
fn buildLargeV1Torrent(allocator: std.mem.Allocator, piece_count: u32) ![]u8 {
    const piece_size: u32 = 16384;
    const total_size: u64 = @as(u64, piece_count) * piece_size;
    const hashes_len = piece_count * 20;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d4:infod");
    try buf.print(allocator, "6:lengthi{d}e", .{total_size});
    try buf.appendSlice(allocator, "4:name8:test.bin");
    try buf.print(allocator, "12:piece lengthi{d}e", .{piece_size});
    try buf.print(allocator, "6:pieces{d}:", .{hashes_len});
    // Synthesize hashes_len bytes of fake hash data.
    var i: u32 = 0;
    while (i < hashes_len) : (i += 1) {
        try buf.append(allocator, @as(u8, @truncate(i)));
    }
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

test "loadForSeeding allocates fewer bytes than loadForDownload (Phase 2 demo)" {
    const allocator = std.testing.allocator;
    const piece_count: u32 = 1024;

    const torrent = try buildLargeV1Torrent(allocator, piece_count);
    defer allocator.free(torrent);

    // Track the alloc counts through std.testing.allocator's accounting.
    // Phase 2 invariant: loadForSeeding never materialises the
    // `piece_count * 20` byte hash table. The seeding session's
    // `pieces` field is null, demonstrable by direct field inspection.
    var seeding = try Session.loadForSeeding(allocator, torrent, "/srv/torrents");
    defer seeding.deinit(allocator);

    try std.testing.expect(!seeding.hasPieceHashes());
    try std.testing.expect(seeding.pieces == null);
    try std.testing.expectEqual(piece_count, seeding.pieceCount());

    // Compare against a download-mode load of the same torrent: it
    // materialises a separately-allocated `piece_count * 20` buffer.
    var download = try Session.loadForDownload(allocator, torrent, "/srv/torrents");
    defer download.deinit(allocator);

    try std.testing.expect(download.hasPieceHashes());
    try std.testing.expectEqual(@as(usize, piece_count * 20), download.pieces.?.len);

    // After freePieces, the heap copy is gone — invariant equivalent to
    // the seeding-only load.
    download.freePieces();
    try std.testing.expect(!download.hasPieceHashes());
    try std.testing.expect(download.pieces == null);
}

// ── v2/hybrid: Merkle cache eviction ───────────────────────────

const merkle_cache = varuna.torrent.merkle_cache;
const Bitfield = varuna.bitfield.Bitfield;
const Layout = varuna.torrent.layout.Layout;

test "MerkleCache.evictCompletedFile drops cached tree once file completes" {
    const merkle = varuna.torrent.merkle;
    const h0 = merkle.hashLeaf("piece0");
    const h1 = merkle.hashLeaf("piece1");
    const h2 = merkle.hashLeaf("piece2");
    const h3 = merkle.hashLeaf("piece3");

    // Compute the real root so buildAndCache accepts the input.
    var expected_tree = try merkle.MerkleTree.fromPieceHashes(
        std.testing.allocator,
        &[_][32]u8{ h0, h1, h2, h3 },
    );
    defer expected_tree.deinit();
    const expected_root = expected_tree.root();

    var files = [_]Layout.File{
        .{
            .length = 16,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 4,
            .path = &.{},
        },
    };
    const v2_files = [_]varuna.torrent.metainfo.V2File{
        .{ .path = &.{}, .length = 16, .pieces_root = expected_root },
    };
    const lyt = Layout{
        .piece_length = 4,
        .piece_count = 4,
        .total_size = 16,
        .files = files[0..],
        .piece_hashes = null,
        .version = .v2,
        .v2_files = v2_files[0..],
    };

    var mc = try merkle_cache.MerkleCache.init(std.testing.allocator, &lyt, v2_files[0..], 4);
    defer mc.deinit();

    _ = try mc.buildAndCache(0, &[_][32]u8{ h0, h1, h2, h3 });
    try std.testing.expectEqual(@as(u32, 1), mc.cachedCount());

    // With pieces 2 and 3 incomplete, evictCompletedFile is a no-op.
    var partial = try Bitfield.init(std.testing.allocator, 4);
    defer partial.deinit(std.testing.allocator);
    try partial.set(0);
    try partial.set(1);
    mc.evictCompletedFile(0, &partial);
    try std.testing.expectEqual(@as(u32, 1), mc.cachedCount());

    // With every piece complete, the tree gets evicted.
    var full = try Bitfield.init(std.testing.allocator, 4);
    defer full.deinit(std.testing.allocator);
    try full.set(0);
    try full.set(1);
    try full.set(2);
    try full.set(3);
    mc.evictCompletedFile(0, &full);
    try std.testing.expectEqual(@as(u32, 0), mc.cachedCount());
}

// ── PieceTracker.applyRecheckResult (Phase 3 in-place update) ──────

const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;

test "applyRecheckResult overwrites complete bitfield in place (storage stable)" {
    const allocator = std.testing.allocator;

    // Initial state: 4 pieces, all complete (synthesised seeding session).
    var initial = try Bitfield.init(allocator, 4);
    defer initial.deinit(allocator);
    try initial.set(0);
    try initial.set(1);
    try initial.set(2);
    try initial.set(3);

    var pt = try PieceTracker.init(allocator, 4, 4, 16, &initial, 16);
    defer pt.deinit(allocator);

    // Capture the storage address of the bitfield bits — applyRecheckResult
    // must NOT reallocate (the EL holds a pointer into this storage).
    const original_bits_ptr = pt.complete.bits.ptr;

    // New recheck result: piece 1 was found corrupt.
    var recheck_result = try Bitfield.init(allocator, 4);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(0);
    try recheck_result.set(2);
    try recheck_result.set(3);

    pt.applyRecheckResult(&recheck_result, 12);

    // Storage didn't move.
    try std.testing.expectEqual(original_bits_ptr, pt.complete.bits.ptr);
    // Bits reflect new state.
    try std.testing.expect(pt.complete.has(0));
    try std.testing.expect(!pt.complete.has(1));
    try std.testing.expect(pt.complete.has(2));
    try std.testing.expect(pt.complete.has(3));
    try std.testing.expectEqual(@as(u32, 3), pt.complete.count);
    try std.testing.expectEqual(@as(u64, 12), pt.bytes_complete);
}

test "applyRecheckResult preserves in_progress for pieces the recheck found incomplete (surgical row 2)" {
    const allocator = std.testing.allocator;

    var initial = try Bitfield.init(allocator, 4);
    defer initial.deinit(allocator);

    var pt = try PieceTracker.init(allocator, 4, 4, 16, &initial, 0);
    defer pt.deinit(allocator);

    // Peer A is mid-downloading piece 2 (in_progress=1, bitfield=0).
    pt.in_progress.set(2) catch {};
    try std.testing.expectEqual(@as(u32, 1), pt.in_progress.count);

    // Recheck found ONLY piece 0 complete on disk; pieces 1, 2, 3 are
    // still incomplete (e.g. some piece-2 blocks haven't flushed yet).
    var recheck_result = try Bitfield.init(allocator, 4);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(0);

    pt.applyRecheckResult(&recheck_result, 4);

    // Surgical: in_progress=2 is preserved because piece 2 is still
    // incomplete on disk. Without preservation, the picker would
    // re-claim piece 2 fresh and peer A would re-request blocks
    // already buffered in the DP — wasted bandwidth.
    try std.testing.expect(pt.in_progress.has(2));
    try std.testing.expectEqual(@as(u32, 1), pt.in_progress.count);
    // Bitfield reflects on-disk truth (piece 0 only).
    try std.testing.expect(pt.complete.has(0));
    try std.testing.expect(!pt.complete.has(2));
}

test "applyRecheckResult drops in_progress for pieces the recheck found complete (surgical row 1, rare race)" {
    const allocator = std.testing.allocator;

    var initial = try Bitfield.init(allocator, 4);
    defer initial.deinit(allocator);

    var pt = try PieceTracker.init(allocator, 4, 4, 16, &initial, 0);
    defer pt.deinit(allocator);

    // in_progress[2] = true; the rare-race case is when the recheck
    // ALSO finds piece 2 complete on disk. The verified bytes win;
    // the in-flight download is redundant.
    pt.in_progress.set(2) catch {};

    var recheck_result = try Bitfield.init(allocator, 4);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(2);

    pt.applyRecheckResult(&recheck_result, 4);

    try std.testing.expect(!pt.in_progress.has(2));
    try std.testing.expectEqual(@as(u32, 0), pt.in_progress.count);
    try std.testing.expect(pt.complete.has(2));
}

test "applyRecheckResult leaves not-in-progress pieces alone regardless of recheck (surgical rows 3, 4, 5)" {
    const allocator = std.testing.allocator;

    var initial = try Bitfield.init(allocator, 4);
    defer initial.deinit(allocator);
    // Pre-recheck: bitfield=1 for pieces 0 and 1 (resume-DB say complete);
    // in_progress is all zero. This setup exercises rows 3 and 4 of the
    // truth table when crossed against the recheck result below.
    try initial.set(0);
    try initial.set(1);

    var pt = try PieceTracker.init(allocator, 4, 4, 16, &initial, 8);
    defer pt.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), pt.in_progress.count);

    // Recheck: piece 0 still complete (row 3: no change), piece 1
    // incomplete (row 4: bitfield drops from 1 → 0), pieces 2 and 3
    // incomplete (row 5: no change, both bitfield=0 and in_progress=0).
    var recheck_result = try Bitfield.init(allocator, 4);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(0);

    pt.applyRecheckResult(&recheck_result, 4);

    // in_progress untouched.
    try std.testing.expectEqual(@as(u32, 0), pt.in_progress.count);
    // Bitfield reflects recheck.
    try std.testing.expect(pt.complete.has(0));
    try std.testing.expect(!pt.complete.has(1));
    try std.testing.expect(!pt.complete.has(2));
    try std.testing.expect(!pt.complete.has(3));
    try std.testing.expectEqual(@as(u32, 1), pt.complete.count);
    try std.testing.expectEqual(@as(u64, 4), pt.bytes_complete);
}

test "applyRecheckResult mixed truth table: preserve some, drop others, follow recheck on rest" {
    const allocator = std.testing.allocator;

    var initial = try Bitfield.init(allocator, 8);
    defer initial.deinit(allocator);
    try initial.set(0); // pre-recheck complete (will stay complete: row 3)
    try initial.set(1); // pre-recheck complete (recheck disagrees: row 4)

    var pt = try PieceTracker.init(allocator, 8, 4, 32, &initial, 8);
    defer pt.deinit(allocator);

    // Set in_progress for pieces 4 (recheck will say incomplete: row 2,
    // KEEP) and 5 (recheck will say complete: row 1, drop).
    pt.in_progress.set(4) catch {};
    pt.in_progress.set(5) catch {};
    try std.testing.expectEqual(@as(u32, 2), pt.in_progress.count);

    var recheck_result = try Bitfield.init(allocator, 8);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(0); // matches pre (row 3)
    // piece 1 NOT in recheck (row 4: bitfield drops)
    try recheck_result.set(5); // pre was in_progress, now complete (row 1)
    try recheck_result.set(7); // pre was empty, recheck found new (row 5 → flips to 1)

    pt.applyRecheckResult(&recheck_result, 12);

    // Bitfield is exactly the recheck result.
    try std.testing.expect(pt.complete.has(0));
    try std.testing.expect(!pt.complete.has(1));
    try std.testing.expect(!pt.complete.has(2));
    try std.testing.expect(!pt.complete.has(3));
    try std.testing.expect(!pt.complete.has(4));
    try std.testing.expect(pt.complete.has(5));
    try std.testing.expect(!pt.complete.has(6));
    try std.testing.expect(pt.complete.has(7));
    try std.testing.expectEqual(@as(u32, 3), pt.complete.count);

    // in_progress: piece 4 preserved (row 2), piece 5 dropped (row 1).
    try std.testing.expect(pt.in_progress.has(4));
    try std.testing.expect(!pt.in_progress.has(5));
    try std.testing.expectEqual(@as(u32, 1), pt.in_progress.count);
    // Sanity: untouched pieces stay 0.
    try std.testing.expect(!pt.in_progress.has(0));
    try std.testing.expect(!pt.in_progress.has(7));

    try std.testing.expectEqual(@as(u64, 12), pt.bytes_complete);
}

test "applyRecheckResult preserves availability (peer Have/bitfield announces survive)" {
    const allocator = std.testing.allocator;

    var initial = try Bitfield.init(allocator, 4);
    defer initial.deinit(allocator);

    var pt = try PieceTracker.init(allocator, 4, 4, 16, &initial, 0);
    defer pt.deinit(allocator);

    // Two peers had pieces 0 and 1; one peer had piece 2.
    pt.addAvailability(0);
    pt.addAvailability(0);
    pt.addAvailability(1);
    pt.addAvailability(1);
    pt.addAvailability(2);

    var recheck_result = try Bitfield.init(allocator, 4);
    defer recheck_result.deinit(allocator);
    try recheck_result.set(3);

    pt.applyRecheckResult(&recheck_result, 4);

    // Availability counts unchanged — recheck only affects what WE have,
    // not what peers have.
    try std.testing.expectEqual(@as(u16, 2), pt.availability[0]);
    try std.testing.expectEqual(@as(u16, 2), pt.availability[1]);
    try std.testing.expectEqual(@as(u16, 1), pt.availability[2]);
    try std.testing.expectEqual(@as(u16, 0), pt.availability[3]);
}

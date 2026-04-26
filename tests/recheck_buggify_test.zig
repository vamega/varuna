//! Recheck safety-under-randomized-inputs harness.
//!
//! A1 (`ResumeDb.replaceCompletePieces`) + A2 (`PieceTracker.applyRecheckResult`'s
//! surgical `in_progress` preservation) both fire from the post-recheck
//! callback (`onRecheckComplete` for stop+start, `onLiveRecheckComplete`
//! for live force-recheck). This file is the layered-testing-strategy
//! "safety-under-faults" layer for those two surfaces.
//!
//! ## What this harness does
//!
//! For 32 deterministic seeds, randomize the cross-product of:
//!   * pre-recheck `complete` bitfield (random subset of pieces)
//!   * pre-recheck `in_progress` bitfield (random subset, disjoint
//!     from `complete` — the normal invariant in the picker)
//!   * recheck-result bitfield (random independent subset)
//!   * piece_count (varies across [4, 256] — exercises the trailing-
//!     bit boundary at 8 and the multi-byte boundary at 16, 32, …)
//!   * info_hash (random per seed, irrelevant to assertions but
//!     varies the resume DB's per-row blob keys)
//!
//! Drive the two surfaces in the same order the production callback
//! does (`applyRecheckResult` → `replaceCompletePieces`). Assert the
//! safety invariants that must hold under any input cross-product:
//!
//!   (a) `pt.complete.bits.ptr` is stable across the rebuild (the EL
//!       holds a `*const Bitfield` pointer into this storage; reallocation
//!       would dangle it).
//!   (b) `pt.complete` matches the recheck result bit-for-bit.
//!   (c) `pt.in_progress` matches the surgical truth table bit-for-bit:
//!       `new_in_progress[i] = old_in_progress[i] AND NOT
//!       new_complete[i]`.
//!   (d) `bytes_complete` reflects the recheck.
//!   (e) Resume DB `pieces` table contains exactly the recheck-complete
//!       pieces — no stale rows from the pre-recheck state.
//!   (f) No allocation leak (testing.allocator catches).
//!   (g) Test exits cleanly (no panic, no crash).
//!
//! ## Why algorithm-level vs EL+SimIO BUGGIFY
//!
//! The canonical EL+SimIO BUGGIFY pattern
//! (`tests/sim_smart_ban_eventloop_test.zig`) drives `EventLoopOf(SimIO)`
//! with per-tick `injectRandomFault` plus per-op `FaultConfig` over 32
//! seeds, catching recovery bugs in the live wiring. With
//! `AsyncRecheck` now parameterised over its IO backend (the followup
//! refactor) and `SimIO.setFileBytes` available for caller-supplied
//! disk content, that harness shape is unblocked — see
//! `tests/recheck_test.zig` for the foundation integration tests.
//! A live-pipeline BUGGIFY wrapper around them is the next deliverable.
//!
//! This algorithm-level cross-product harness still earns its keep:
//! it exercises the post-recheck callback's two surfaces (A1 stale
//! pruning + A2 surgical in_progress preservation) under randomized
//! inputs across 32 seeds, with broader piece_count coverage than an
//! EL test can afford because no real EventLoop, hasher, or disk
//! reads are required per seed. The two layers are complementary:
//! algorithm-level is fast + broad-coverage on the data shape;
//! EL+SimIO BUGGIFY (the follow-up) catches live-wiring recovery
//! bugs the algorithm layer can't see.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const ResumeDb = varuna.storage.resume_state.ResumeDb;

const min_piece_count: u32 = 4;
const max_piece_count: u32 = 256;
const piece_size: u32 = 16384; // arbitrary; only affects bytes_complete arithmetic

/// Per-seed telemetry — surfaces coverage so the vacuous-pass guard can
/// reject seeds that happen to fall into trivial inputs (e.g. all-empty
/// pre-state + all-empty recheck → tautologically passes every check).
const SeedOutcome = struct {
    piece_count: u32,
    pre_complete_count: u32,
    pre_in_progress_count: u32,
    recheck_count: u32,
    /// Number of pieces dropped from `complete` by the recheck (exercises
    /// A1's stale-entry pruning surface).
    complete_dropped: u32,
    /// Number of pieces preserved as `in_progress` by the surgical update
    /// (exercises A2's row-2 truth-table branch).
    in_progress_preserved: u32,
    /// Number of pieces where in_progress was dropped because the recheck
    /// found verified bytes on disk (exercises A2's row-1 rare race).
    in_progress_dropped_by_race: u32,
};

fn runOneSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();

    const piece_count: u32 = min_piece_count +
        r.uintLessThan(u32, max_piece_count - min_piece_count + 1);
    const total_size: u64 = @as(u64, piece_count) * piece_size;

    // ── Resume DB: pre-recheck state ─────────────────────────
    var db = ResumeDb.open(":memory:") catch return error.SkipZigTest;
    defer db.close();

    var info_hash: [20]u8 = undefined;
    for (&info_hash) |*b| b.* = r.int(u8);

    // Random pre-complete bitfield. Mirror it into the resume DB and
    // into a bitfield used to seed the PieceTracker.
    var initial_complete = try Bitfield.init(allocator, piece_count);
    defer initial_complete.deinit(allocator);

    var pre_complete_pieces = std.ArrayList(u32).empty;
    defer pre_complete_pieces.deinit(allocator);

    var i: u32 = 0;
    while (i < piece_count) : (i += 1) {
        if (r.boolean()) {
            try initial_complete.set(i);
            try pre_complete_pieces.append(allocator, i);
        }
    }
    if (pre_complete_pieces.items.len > 0) {
        try db.markCompleteBatch(info_hash, pre_complete_pieces.items);
    }

    const initial_bytes: u64 = @as(u64, initial_complete.count) * piece_size;

    // ── PieceTracker: pre-recheck state ──────────────────────
    var pt = try PieceTracker.init(
        allocator,
        piece_count,
        piece_size,
        total_size,
        &initial_complete,
        initial_bytes,
    );
    defer pt.deinit(allocator);

    // Random in_progress (only on pieces NOT in initial_complete, so the
    // disjoint-with-complete picker invariant holds). Snapshot the bits
    // before applyRecheckResult mutates them.
    var pre_in_progress_snapshot = try allocator.alloc(bool, piece_count);
    defer allocator.free(pre_in_progress_snapshot);
    @memset(pre_in_progress_snapshot, false);

    i = 0;
    while (i < piece_count) : (i += 1) {
        if (!initial_complete.has(i) and r.boolean()) {
            pt.in_progress.set(i) catch continue;
            pre_in_progress_snapshot[i] = true;
        }
    }

    // ── Recheck "result" — random fresh bitfield ─────────────
    var recheck_result = try Bitfield.init(allocator, piece_count);
    defer recheck_result.deinit(allocator);

    i = 0;
    while (i < piece_count) : (i += 1) {
        if (r.boolean()) try recheck_result.set(i);
    }
    const recheck_bytes: u64 = @as(u64, recheck_result.count) * piece_size;

    // ── Capture invariants ───────────────────────────────────
    const original_complete_ptr = pt.complete.bits.ptr;
    const original_in_progress_ptr = pt.in_progress.bits.ptr;

    // ── Surface A2: surgical in_progress preservation ────────
    pt.applyRecheckResult(&recheck_result, recheck_bytes);

    // ── Surface A1: resume DB stale-entry pruning ────────────
    var post_complete_pieces = std.ArrayList(u32).empty;
    defer post_complete_pieces.deinit(allocator);
    i = 0;
    while (i < piece_count) : (i += 1) {
        if (recheck_result.has(i)) try post_complete_pieces.append(allocator, i);
    }
    try db.replaceCompletePieces(info_hash, post_complete_pieces.items);

    // ── (a) Storage addresses stable ─────────────────────────
    try testing.expectEqual(original_complete_ptr, pt.complete.bits.ptr);
    try testing.expectEqual(original_in_progress_ptr, pt.in_progress.bits.ptr);

    // ── (b) PieceTracker.complete matches recheck ────────────
    try testing.expect(std.mem.eql(u8, pt.complete.bits, recheck_result.bits));
    try testing.expectEqual(recheck_result.count, pt.complete.count);

    // ── (c) PieceTracker.in_progress matches the truth table ─
    var expected_in_progress_count: u32 = 0;
    var in_progress_preserved: u32 = 0;
    var in_progress_dropped_by_race: u32 = 0;
    i = 0;
    while (i < piece_count) : (i += 1) {
        const was_ip = pre_in_progress_snapshot[i];
        const now_complete = recheck_result.has(i);
        const expected = was_ip and !now_complete;
        try testing.expectEqual(expected, pt.in_progress.has(i));
        if (expected) {
            expected_in_progress_count += 1;
            in_progress_preserved += 1;
        } else if (was_ip and now_complete) {
            in_progress_dropped_by_race += 1;
        }
    }
    try testing.expectEqual(expected_in_progress_count, pt.in_progress.count);

    // ── (d) bytes_complete reflects recheck ──────────────────
    try testing.expectEqual(recheck_bytes, pt.bytes_complete);

    // ── (e) Resume DB: pieces table = recheck result exactly ─
    var verify_bf = try Bitfield.init(allocator, piece_count);
    defer verify_bf.deinit(allocator);
    const db_count = try db.loadCompletePieces(info_hash, &verify_bf);
    try testing.expectEqual(recheck_result.count, db_count);
    try testing.expect(std.mem.eql(u8, verify_bf.bits, recheck_result.bits));

    // ── Telemetry ─────────────────────────────────────────────
    var complete_dropped: u32 = 0;
    i = 0;
    while (i < piece_count) : (i += 1) {
        if (initial_complete.has(i) and !recheck_result.has(i)) complete_dropped += 1;
    }

    return .{
        .piece_count = piece_count,
        .pre_complete_count = initial_complete.count,
        .pre_in_progress_count = blk: {
            var c: u32 = 0;
            for (pre_in_progress_snapshot) |b| if (b) {
                c += 1;
            };
            break :blk c;
        },
        .recheck_count = recheck_result.count,
        .complete_dropped = complete_dropped,
        .in_progress_preserved = in_progress_preserved,
        .in_progress_dropped_by_race = in_progress_dropped_by_race,
    };
}

test "32 seeds: cross-product of pre-recheck + recheck preserves A1+A2 safety invariants" {
    // Same canonical seed list as `sim_smart_ban_eventloop_test.zig`'s
    // BUGGIFY harness so a failing seed has the same diagnostic shape
    // across the project (e.g. seed 0xDEADBEEF reproduces the same
    // input pattern modulo the harness's own RNG semantics).
    const seeds = [_]u64{
        0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE,
        0x0F0F_0F0F, 0x1234_5678, 0xABCD_EF01, 0x9876_5432,
        0x1111_1111, 0x2222_2222, 0x3333_3333, 0x4444_4444,
        0x5555_5555, 0x6666_6666, 0x7777_7777, 0x8888_8888,
        0x9999_9999, 0xAAAA_AAAA, 0xBBBB_BBBB, 0xCCCC_CCCC,
        0xDDDD_DDDD, 0xEEEE_EEEE, 0xFFFF_FFFF, 0x0123_4567,
        0x89AB_CDEF, 0xFEDC_BA98, 0x7654_3210, 0xA1B2_C3D4,
        0xE5F6_0708, 0x1A2B_3C4D, 0x5E6F_7080, 0xDEAD_DEAD,
    };

    var min_pc: u32 = std.math.maxInt(u32);
    var max_pc: u32 = 0;
    var seeds_with_preserved: u32 = 0;
    var seeds_with_race_drop: u32 = 0;
    var seeds_with_stale_pruned: u32 = 0;
    var total_complete_dropped: u32 = 0;
    var total_preserved: u32 = 0;

    for (seeds) |seed| {
        const outcome = runOneSeed(seed) catch |err| {
            std.debug.print(
                "\n  RECHECK BUGGIFY SEED 0x{x} FAILED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
        if (outcome.piece_count < min_pc) min_pc = outcome.piece_count;
        if (outcome.piece_count > max_pc) max_pc = outcome.piece_count;
        if (outcome.in_progress_preserved > 0) seeds_with_preserved += 1;
        if (outcome.in_progress_dropped_by_race > 0) seeds_with_race_drop += 1;
        if (outcome.complete_dropped > 0) seeds_with_stale_pruned += 1;
        total_complete_dropped += outcome.complete_dropped;
        total_preserved += outcome.in_progress_preserved;
    }

    std.debug.print(
        "\n  RECHECK BUGGIFY summary: {d} seeds, piece_count [{d}, {d}], A2 preserved in {d}/{d}, A2 race-dropped in {d}/{d}, A1 pruned in {d}/{d}; total {d} preserved blocks, {d} stale rows pruned\n",
        .{
            seeds.len,
            min_pc,
            max_pc,
            seeds_with_preserved,
            seeds.len,
            seeds_with_race_drop,
            seeds.len,
            seeds_with_stale_pruned,
            seeds.len,
            total_preserved,
            total_complete_dropped,
        },
    );

    // ── Vacuous-pass guards ──────────────────────────────────
    //
    // With piece_count averaging ~130 and ~50% per-piece probabilities
    // for each of (pre_complete, pre_in_progress, recheck-complete), the
    // expected per-seed coverage is essentially saturating on each
    // surface (~1 - 0.75^130 ≈ 1.0). Pin each at 28/32 for headroom
    // against future RNG-distribution tweaks; the vacuous-pass risk
    // we're guarding against is "every seed happens to exercise zero
    // of the intended branches" — at 28/32 that's vanishingly small
    // empirically.
    try testing.expect(seeds_with_preserved * 32 >= seeds.len * 28);
    try testing.expect(seeds_with_race_drop * 32 >= seeds.len * 28);
    try testing.expect(seeds_with_stale_pruned * 32 >= seeds.len * 28);
}

test "edge case: piece_count=1 single-piece torrent (boundary)" {
    // The canonical 32-seed harness ranges piece_count over [4, 256]; a
    // single-piece torrent skips the multi-piece branches in the bitfield
    // bit arithmetic and is worth pinning explicitly. Cross-product the
    // 8 (pre_c, pre_ip, recheck) combinations — though pre_c=1 ∧ pre_ip=1
    // is invalid (in_progress and complete are disjoint), so 6 valid
    // combinations.
    const Cell = struct { pre_c: bool, pre_ip: bool, recheck: bool };
    const cells = [_]Cell{
        .{ .pre_c = false, .pre_ip = false, .recheck = false },
        .{ .pre_c = false, .pre_ip = false, .recheck = true },
        .{ .pre_c = false, .pre_ip = true, .recheck = false },
        .{ .pre_c = false, .pre_ip = true, .recheck = true },
        .{ .pre_c = true, .pre_ip = false, .recheck = false },
        .{ .pre_c = true, .pre_ip = false, .recheck = true },
    };

    const allocator = testing.allocator;
    for (cells) |cell| {
        var initial_complete = try Bitfield.init(allocator, 1);
        defer initial_complete.deinit(allocator);
        if (cell.pre_c) try initial_complete.set(0);

        var pt = try PieceTracker.init(
            allocator,
            1,
            piece_size,
            piece_size,
            &initial_complete,
            if (cell.pre_c) piece_size else 0,
        );
        defer pt.deinit(allocator);

        if (cell.pre_ip) pt.in_progress.set(0) catch unreachable;

        var recheck_result = try Bitfield.init(allocator, 1);
        defer recheck_result.deinit(allocator);
        if (cell.recheck) try recheck_result.set(0);

        const original_ptr = pt.complete.bits.ptr;
        pt.applyRecheckResult(&recheck_result, if (cell.recheck) piece_size else 0);

        // Storage stable even at piece_count=1.
        try testing.expectEqual(original_ptr, pt.complete.bits.ptr);

        // Bitfield reflects recheck.
        try testing.expectEqual(cell.recheck, pt.complete.has(0));

        // in_progress per truth table.
        const expected_ip = cell.pre_ip and !cell.recheck;
        try testing.expectEqual(expected_ip, pt.in_progress.has(0));
    }
}

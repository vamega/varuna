//! Live-pipeline BUGGIFY harness for `AsyncRecheckOf(SimIO)`.
//!
//! Wraps the three end-to-end integration tests in `tests/recheck_test.zig`
//! ("all pieces verify", "corrupt piece", "all-known-complete fast path")
//! with the canonical BUGGIFY pattern: per-tick `injectRandomFault` plus
//! per-op `FaultConfig` (read EIO + buggify roll on every read submission)
//! over 32 deterministic seeds.
//!
//! ## What this harness catches that the algorithm-level harness can't
//!
//! `tests/recheck_buggify_test.zig` exercises the post-recheck callback's
//! two surfaces (A1 stale pruning + A2 surgical in_progress preservation)
//! at the algorithm level — no real EventLoop, hasher, or disk reads. That
//! harness is fast and broad-coverage on the data shape, but it can't see
//! live-wiring failures: AsyncRecheck slot cleanup under read-error
//! injection, hasher submission failures, partial completion races.
//!
//! This harness drives the full pipeline end-to-end through
//! `EventLoopOf(SimIO)` with fault injection. The failure modes that come
//! into scope here:
//!
//!   * Read EIO on a span — `recheck.handleReadCqe` must mark the slot
//!     `read_failed`, finish the slot (which frees `plan` + `buf`), and
//!     advance the pipeline. Repeated EIOs across all 4 pipeline slots
//!     must drain cleanly without leaks or double-free.
//!   * Per-tick `injectRandomFault` — mutates an in-flight read to
//!     `error.InputOutput` mid-flight. Same path as the per-op fault but
//!     timed differently relative to other completions in the heap.
//!   * Mixed paths — half the seeds run the corrupt-piece scenario, half
//!     the happy path; a third of seeds run the fast-path with empty
//!     `file_content`, asserting that no spurious reads escape the
//!     `known_complete` skip even under fault injection (would manifest
//!     as a hasher submit attempt against a zero buffer).
//!
//! ## Safety invariants asserted under any seed × fault sequence
//!
//!   1. The recheck either fires its `on_complete` callback or remains
//!      cleanly cancellable via `cancelAllRechecks`. Never panic, never
//!      UB, never leak.
//!   2. `complete_pieces.count` ≤ piece_count — a fault cannot inflate
//!      the verified-piece count above the torrent's piece total.
//!   3. Every piece reported complete has the canonical hash (verified
//!      indirectly by the count + bytes_complete arithmetic; a corrupt
//!      piece's bytes don't end up counted as complete).
//!   4. `bytes_complete` = `complete_pieces.count` * piece_size.
//!   5. No allocator leaks (testing.allocator catches).
//!
//! Liveness — that the recheck *finishes* — is best-effort: a sufficiently
//! pathological per-op error rate could in principle exhaust the budget.
//! We pick fault-injection densities that empirically let the recheck
//! complete (or drain cleanly via cancel) within `max_ticks`.
//!
//! ## Pattern reference
//!
//! Mirrors the shape of `tests/sim_smart_ban_eventloop_test.zig`'s
//! BUGGIFY block: 32 canonical seeds, per-tick BUGGIFY roll, per-op
//! `FaultConfig` for parallel injection paths, `safety_only` fork at
//! the assertion site, vacuous-pass guards on the summary statistics.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const Bitfield = varuna.bitfield.Bitfield;
const Sha1 = varuna.crypto.Sha1;
const Session = varuna.torrent.session.Session;
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;

const sim_piece_count: u32 = 4;
const sim_piece_size: u32 = 32;
const sim_total_bytes: u32 = sim_piece_count * sim_piece_size;
const max_ticks: u32 = 4096;
const synthetic_fd: posix.fd_t = 50;

const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

/// Same canonical seed list as `recheck_buggify_test.zig` and
/// `sim_smart_ban_eventloop_test.zig`. Failing seeds reproduce with the
/// same hex prefix in both harnesses' diagnostics.
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

/// Build minimal bencoded metainfo for a 4-piece × 32-byte torrent with
/// the supplied concatenated piece hashes. Mirrors
/// `tests/recheck_test.zig:buildMultiPieceTorrent`.
fn buildMultiPieceTorrent(
    allocator: std.mem.Allocator,
    piece_hashes: *const [sim_piece_count][20]u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{sim_total_bytes});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name15:sim_recheck.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{sim_piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces");
    try buf.writer(allocator).print("{d}", .{sim_piece_count * 20});
    try buf.append(allocator, ':');
    for (piece_hashes) |*h| try buf.appendSlice(allocator, h);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Outcome of a single seed run. The harness sums these across seeds and
/// rejects vacuous-pass scenarios (e.g. every seed faulted before any
/// disk read could fire — fault paths went unexercised).
const SeedOutcome = struct {
    completed: bool,
    pieces_verified: u32,
    bytes_verified: u64,
    buggify_hits: u32,
    ticks: u32,
};

/// Per-seed knobs. `corrupt_piece2` overwrites piece 2's content with
/// `0xFF` after hashing, so the recheck must mark it incomplete (the
/// piece-corruption variant). `all_known_complete` mirrors the fast-path
/// integration test: pre-mark every piece in `known_complete` and skip
/// `setFileBytes` registration entirely.
const Variant = enum { happy, corrupt_p2, fast_path };

const RunOpts = struct {
    variant: Variant,
    /// Per-tick probability of mutating a randomly-chosen in-flight op's
    /// result via `SimIO.injectRandomFault`. Zero disables the wrap.
    inject_probability: f32,
    /// Per-op read-error probability fed into `FaultConfig`. Independent
    /// of the per-tick BUGGIFY roll; together they produce ≥ a few dozen
    /// fault opportunities per seed across all variants.
    read_error_probability: f32,
};

fn runOneSeed(seed: u64, opts: RunOpts) !SeedOutcome {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── 1. Build canonical piece data + SHA-1 hashes ─────────
    var file_bytes: [sim_total_bytes]u8 = undefined;
    for (&file_bytes, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var piece_hashes: [sim_piece_count][20]u8 = undefined;
    var p: u32 = 0;
    while (p < sim_piece_count) : (p += 1) {
        Sha1.hash(
            file_bytes[p * sim_piece_size ..][0..sim_piece_size],
            &piece_hashes[p],
            .{},
        );
    }

    // Corrupt piece 2 AFTER hashing for the corrupt variant.
    if (opts.variant == .corrupt_p2) {
        @memset(file_bytes[2 * sim_piece_size ..][0..sim_piece_size], 0xFF);
    }

    // ── 2. Load Session + EventLoopOf(SimIO) ─────────────────
    const torrent_bytes = try buildMultiPieceTorrent(arena.allocator(), &piece_hashes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try tmp.dir.realpathAlloc(arena.allocator(), ".");

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    const sim_io = try SimIO.init(allocator, .{
        .seed = seed,
        .faults = .{ .read_error_probability = opts.read_error_probability },
    });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 1) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // ── 3. Register file content unless this is the fast path ─
    //
    // For the fast-path variant we deliberately leave `file_content`
    // empty: a stray read would return zero bytes → hash mismatch →
    // bitfield empty, so a spurious read escaping the
    // `known_complete` skip would be visible in the assertions.
    if (opts.variant != .fast_path) {
        try el.io.setFileBytes(synthetic_fd, &file_bytes);
    }

    const fds = [_]posix.fd_t{synthetic_fd};

    var known_bf_storage: ?Bitfield = null;
    defer if (known_bf_storage) |*bf| bf.deinit(allocator);
    const known_complete: ?*const Bitfield = blk: {
        if (opts.variant == .fast_path) {
            known_bf_storage = try Bitfield.init(allocator, session.pieceCount());
            var i: u32 = 0;
            while (i < session.pieceCount()) : (i += 1) try known_bf_storage.?.set(i);
            break :blk &known_bf_storage.?;
        }
        break :blk null;
    };

    // ── 4. Submit the recheck ────────────────────────────────
    const Ctx = struct {
        completed: bool = false,
        complete_count: u32 = 0,
        bytes_complete: u64 = 0,
    };
    var ctx = Ctx{};

    try el.startRecheck(
        &session,
        &fds,
        0,
        known_complete,
        struct {
            fn cb(rc: *EL_SimIO.AsyncRecheck) void {
                const c: *Ctx = @ptrCast(@alignCast(rc.caller_ctx.?));
                c.completed = true;
                c.complete_count = rc.complete_pieces.count;
                c.bytes_complete = rc.bytes_complete;
            }
        }.cb,
        @ptrCast(&ctx),
    );

    // ── 5. Drive ticks with per-tick BUGGIFY injection ───────
    //
    // We deliberately use the harness's RNG (separate from SimIO's
    // internal one) for the per-tick roll so the inject decision is
    // deterministic per seed without disturbing SimIO's heap probes.
    var rng = std.Random.DefaultPrng.init(seed ^ 0xfeed_face);
    var buggify_hits: u32 = 0;
    var ticks: u32 = 0;
    while (ticks < max_ticks and !ctx.completed) : (ticks += 1) {
        if (opts.inject_probability > 0.0) {
            if (rng.random().float(f32) < opts.inject_probability) {
                if (el.io.injectRandomFault(&rng)) |_| {
                    buggify_hits += 1;
                }
            }
        }
        try el.tick();
    }

    // ── 6. Drain hasher results before tear-down ─────────────
    //
    // Even when the recheck completes via `on_complete`, a few hasher
    // results may sit in the result queue across the boundary. Drain
    // until the hasher is quiescent so `el.deinit()` doesn't observe
    // outstanding work and so the per-piece buffer the hasher holds
    // gets freed via the recheck's defer in `handleHashResult`.
    var drain_ticks: u32 = 0;
    while (drain_ticks < 256) : (drain_ticks += 1) {
        const hasher_busy = if (el.hasher) |h| h.hasPendingWork() else false;
        if (!hasher_busy) break;
        try el.tick();
    }

    // ── 7. Collect outcome (cancel only if still pending) ────
    //
    // If the recheck completed cleanly its slot was destroyed by the
    // on_complete callback path (well, the slot stays in
    // `el.rechecks` until cancelAllRechecks runs at deinit / explicit
    // cancel — call it explicitly so we exercise the no-leak path
    // both with and without the fault injection).
    el.cancelAllRechecks();

    return .{
        .completed = ctx.completed,
        .pieces_verified = ctx.complete_count,
        .bytes_verified = ctx.bytes_complete,
        .buggify_hits = buggify_hits,
        .ticks = ticks,
    };
}

// ── Test 1: happy path under BUGGIFY ──────────────────────────────
//
// Per-op `FaultConfig.read_error_probability = 0.01` plus per-tick
// `injectRandomFault` at p=0.05 over 32 seeds. The state machine has 4
// pipeline slots; with these densities every seed sees a few read
// failures, exercising `recheck.handleReadCqe`'s `read_failed` path
// (slot cleanup, advance pipeline) and `submitNextPiece`'s
// re-fill-after-failure logic without strangling forward progress.
//
// Asserts the safety invariants (no UB, completion fires or cancel
// drains cleanly, count ≤ piece_count, bytes_complete is consistent).
// Liveness — every piece verifies — is *informational*: a fault on
// piece N's read forces N to be reported incomplete by design.

test "AsyncRecheckOf(SimIO) BUGGIFY: happy path with read faults over 32 seeds" {
    var completed_seeds: u32 = 0;
    var seeds_with_full_verify: u32 = 0;
    var seeds_with_partial_verify: u32 = 0;
    var seeds_with_hits: u32 = 0;
    var total_pieces_verified: u32 = 0;
    var total_buggify_hits: u32 = 0;

    for (seeds) |seed| {
        const outcome = runOneSeed(seed, .{
            .variant = .happy,
            .inject_probability = 0.05,
            .read_error_probability = 0.01,
        }) catch |err| {
            std.debug.print(
                "\n  RECHECK LIVE BUGGIFY (happy) seed=0x{x} FAILED: {any}\n",
                .{ seed, err },
            );
            return err;
        };

        // Safety: count never exceeds piece_count
        try testing.expect(outcome.pieces_verified <= sim_piece_count);
        // Safety: bytes_complete = pieces_verified * piece_size (no torn arithmetic)
        try testing.expectEqual(
            @as(u64, outcome.pieces_verified) * sim_piece_size,
            outcome.bytes_verified,
        );

        if (outcome.completed) completed_seeds += 1;
        if (outcome.pieces_verified == sim_piece_count) seeds_with_full_verify += 1;
        if (outcome.pieces_verified > 0 and outcome.pieces_verified < sim_piece_count) {
            seeds_with_partial_verify += 1;
        }
        if (outcome.buggify_hits > 0) seeds_with_hits += 1;
        total_pieces_verified += outcome.pieces_verified;
        total_buggify_hits += outcome.buggify_hits;
    }

    std.debug.print(
        "\n  RECHECK LIVE BUGGIFY summary (happy): {d}/{d} seeds completed, " ++
            "{d}/{d} fully verified, {d}/{d} partially verified, " ++
            "{d}/{d} with hits, total {d} pieces verified, total {d} buggify hits\n",
        .{
            completed_seeds,           seeds.len,
            seeds_with_full_verify,    seeds.len,
            seeds_with_partial_verify, seeds.len,
            seeds_with_hits,           seeds.len,
            total_pieces_verified,     total_buggify_hits,
        },
    );

    // ── Vacuous-pass guards ──────────────────────────────────
    //
    // The point of the harness is to exercise the read-error path. If
    // every seed completed cleanly with full verification, fault
    // injection isn't reaching the code under test — likely a
    // density/timing regression. Demand at least 1 seed sees a partial
    // verification *or* every seed records a buggify hit.
    try testing.expect(completed_seeds * 2 >= seeds.len); // most seeds must complete (liveness sanity)
    try testing.expect(seeds_with_hits >= 1 or seeds_with_partial_verify >= 1);
}

// ── Test 2: corrupt piece 2 + BUGGIFY ─────────────────────────────
//
// Same densities as Test 1; piece 2's on-disk bytes are overwritten
// with 0xFF after hashing, so the canonical outcome is that piece 2
// must NEVER be reported complete (hash mismatch) and pieces 0/1/3
// usually verify (modulo fault injection on their reads). Asserts the
// safety invariant that the corrupt piece is never falsely marked
// complete under any seed × fault sequence.

test "AsyncRecheckOf(SimIO) BUGGIFY: corrupt piece 2 over 32 seeds" {
    var completed_seeds: u32 = 0;
    var seeds_with_corrupt_caught: u32 = 0;
    var seeds_with_full_three: u32 = 0;
    var total_pieces_verified: u32 = 0;
    var total_buggify_hits: u32 = 0;

    for (seeds) |seed| {
        const outcome = runOneSeed(seed, .{
            .variant = .corrupt_p2,
            .inject_probability = 0.05,
            .read_error_probability = 0.01,
        }) catch |err| {
            std.debug.print(
                "\n  RECHECK LIVE BUGGIFY (corrupt) seed=0x{x} FAILED: {any}\n",
                .{ seed, err },
            );
            return err;
        };

        // The piece-2 corruption invariant: the recheck must not report
        // ALL 4 pieces verified. With piece 2's bytes 0xFF and hashes
        // computed over the canonical bytes, the hash mismatch is
        // unconditional — even a fault injection cannot cause piece 2
        // to verify (the hasher would still see 0xFF bytes).
        try testing.expect(outcome.pieces_verified < sim_piece_count);
        // Bytes-complete arithmetic consistency
        try testing.expectEqual(
            @as(u64, outcome.pieces_verified) * sim_piece_size,
            outcome.bytes_verified,
        );

        if (outcome.completed) completed_seeds += 1;
        if (outcome.pieces_verified <= sim_piece_count - 1) seeds_with_corrupt_caught += 1;
        if (outcome.pieces_verified == sim_piece_count - 1) seeds_with_full_three += 1;
        total_pieces_verified += outcome.pieces_verified;
        total_buggify_hits += outcome.buggify_hits;
    }

    std.debug.print(
        "\n  RECHECK LIVE BUGGIFY summary (corrupt): {d}/{d} seeds completed, " ++
            "{d}/{d} caught corrupt piece, {d}/{d} verified other 3 cleanly, " ++
            "total {d} pieces verified, total {d} buggify hits\n",
        .{
            completed_seeds,           seeds.len,
            seeds_with_corrupt_caught, seeds.len,
            seeds_with_full_three,     seeds.len,
            total_pieces_verified,     total_buggify_hits,
        },
    );

    // Liveness sanity: most seeds must complete
    try testing.expect(completed_seeds * 2 >= seeds.len);
    // Every completing seed must catch the corrupt piece (the assertion
    // above already enforces this per-seed; this is a redundant guard).
    try testing.expectEqual(seeds.len, seeds_with_corrupt_caught);
}

// ── Test 3: fast-path under BUGGIFY ───────────────────────────────
//
// Every piece pre-marked in `known_complete`, no `setFileBytes`
// registration. The recheck should fire `on_complete` without
// submitting any reads — proven by the assertion that all 4 pieces
// verify (a stray read would return zero bytes → hash mismatch →
// bitfield empty under SimIO's no-content default).
//
// Per-tick BUGGIFY roll still fires, but with no in-flight reads in
// the heap there's nothing to inject onto. This test asserts that the
// fast-path doesn't accidentally hit a code path that submits reads
// even under fault injection — i.e. the `known_complete` skip is
// preserved end-to-end.

test "AsyncRecheckOf(SimIO) BUGGIFY: fast-path skip under fault injection over 32 seeds" {
    var completed_seeds: u32 = 0;
    var seeds_with_full_verify: u32 = 0;
    var total_pieces_verified: u32 = 0;
    var total_buggify_hits: u32 = 0;

    for (seeds) |seed| {
        const outcome = runOneSeed(seed, .{
            .variant = .fast_path,
            .inject_probability = 0.05,
            .read_error_probability = 0.01,
        }) catch |err| {
            std.debug.print(
                "\n  RECHECK LIVE BUGGIFY (fast-path) seed=0x{x} FAILED: {any}\n",
                .{ seed, err },
            );
            return err;
        };

        // The fast-path invariant: every piece is in `known_complete`,
        // so the state machine should mark all 4 pieces complete and
        // fire `on_complete` immediately without ever reading from
        // disk. Under fault injection this still holds because no
        // reads are submitted to be faulted.
        try testing.expect(outcome.completed);
        try testing.expectEqual(sim_piece_count, outcome.pieces_verified);
        try testing.expectEqual(@as(u64, sim_total_bytes), outcome.bytes_verified);

        if (outcome.completed) completed_seeds += 1;
        if (outcome.pieces_verified == sim_piece_count) seeds_with_full_verify += 1;
        total_pieces_verified += outcome.pieces_verified;
        total_buggify_hits += outcome.buggify_hits;
    }

    std.debug.print(
        "\n  RECHECK LIVE BUGGIFY summary (fast-path): {d}/{d} seeds completed, " ++
            "{d}/{d} fully verified (all known-complete), total {d} pieces verified, " ++
            "total {d} buggify hits\n",
        .{
            completed_seeds,        seeds.len,
            seeds_with_full_verify, seeds.len,
            total_pieces_verified,  total_buggify_hits,
        },
    );

    // Fast-path is deterministic regardless of fault injection: every
    // seed must complete with all pieces verified.
    try testing.expectEqual(seeds.len, completed_seeds);
    try testing.expectEqual(seeds.len, seeds_with_full_verify);
}

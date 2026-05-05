//! 32-seed BUGGIFY harness for the resume-DB durability barrier
//! (production fix `aee2f09 storage: gate resume completions on
//! durability`).
//!
//! Replaces the earlier single-seed bug repro
//! (`tests/resume_durability_bug_test.zig`) which is now stale because
//! it bypassed the production gate. This harness drives the actual
//! production code path:
//!
//!   write CQE → `handleDiskWriteResult` → `markPieceAwaitingDurability`
//!     → `submitTorrentSync` → fsync CQE → `drainDurableResumePieces`
//!     → `markCompleteBatch` (resume DB)
//!
//! and fires `sim.crash()` at varied ticks across 32 deterministic
//! seeds. The strong invariant on the rebooted state:
//!
//!   **Every piece the resume DB claims complete must have its bytes
//!    present in the SimIO durable layer.**
//!
//! On the rebased branch (with the production fix in place) this must
//! pass cleanly across all 32 seeds. Any seed that surfaces a
//! divergence is a real regression find — the failure message reports
//! the seed and divergent piece for reproducibility.
//!
//! Mirrors `tests/storage_writer_live_buggify_test.zig`'s seed-loop /
//! summary aggregator shape. The end-to-end `EventLoopOf(SimIO)` wire-
//! up (sync sweeps, durability queues) follows the production fix's
//! own regression test in `tests/torrent_sync_test.zig`. The simpler
//! "don't reboot the EL — check the durable layer directly" model from
//! the harness brief is the design choice here: an actual restart
//! requires reconstructing too much daemon state for negligible extra
//! coverage; checking that DB rows are a subset of durable bytes is
//! the same invariant.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const Session = varuna.torrent.session.Session;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Bitfield = varuna.bitfield.Bitfield;
const SimResumeBackend = varuna.storage.resume_state.SimResumeBackend;
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const peer_handler = varuna.io.peer_handler;
const ifc = varuna.io.io_interface;

const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
const DiskWriteOp = peer_handler.DiskWriteOpOf(EL_SimIO);

/// Single-file v1 torrent: 5 pieces × 4 bytes = 20 bytes total. Piece
/// length 4 keeps every piece a single span (one fd, one offset, one
/// write). Piece hashes are placeholders — the test drives
/// `handleDiskWriteResult` directly so hash verification is bypassed.
/// We only care about the durability flow from write CQE through the
/// fsync sweep into the resume DB.
const piece_count: u32 = 5;
const piece_length: u32 = 4;
const total_size: u32 = piece_count * piece_length;

const torrent_5piece_single =
    "d4:infod" ++
    "6:lengthi20e" ++
    "4:name3:abc" ++
    "12:piece lengthi4e" ++
    // 5 × 20-byte placeholder hashes = 100 bytes. Hash content
    // doesn't matter — `handleDiskWriteResult` doesn't verify here.
    "6:pieces100:" ++
    "AAAAAAAAAAAAAAAAAAAA" ++
    "BBBBBBBBBBBBBBBBBBBB" ++
    "CCCCCCCCCCCCCCCCCCCC" ++
    "DDDDDDDDDDDDDDDDDDDD" ++
    "EEEEEEEEEEEEEEEEEEEE" ++
    "ee";

/// Canonical 32-seed list shared with other live BUGGIFY harnesses.
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

/// Synthetic data fd. SimIO accepts arbitrary fd values (no kernel
/// open required) — `write` autocreates a `SimFile` entry, and
/// `read` returns the union of durable+pending. Picked outside the
/// socket / synthetic ranges (`socket_fd_base = 1000`,
/// `synthetic_fd_base = 100_000`) so it doesn't collide.
const data_fd: posix.fd_t = 42;

/// Canonical piece content: piece i is 4 bytes of byte `0x10 | i`.
/// Distinct per piece so a misattribution surfaces in the diagnostic.
fn pieceBytes(piece_index: u32) [piece_length]u8 {
    return .{
        @intCast(0x10 | (piece_index & 0xff)),
        @intCast(0x20 | (piece_index & 0xff)),
        @intCast(0x30 | (piece_index & 0xff)),
        @intCast(0x40 | (piece_index & 0xff)),
    };
}

/// Crash-timing classification for the per-seed summary. The pre-tick
/// hook chooses one of these distributions so the 32-seed run reliably
/// covers all three regions of the timing surface (early / mid / late
/// relative to the fsync sweeps).
const CrashWhen = enum {
    /// No crash — happy-path control. Every piece flushed to the DB
    /// must have durable bytes (and on the rebased fix, every piece
    /// completes durably).
    none,
    /// Crash before any fsync sweep fires — proves the gate doesn't
    /// leak rows that haven't crossed the barrier.
    pre_first_sweep,
    /// Crash mid-sweep — the sweep is in flight but its CQEs haven't
    /// landed, so the snapshot's pieces are still in
    /// `pending_resume_durability` not `durable_resume_pieces`.
    mid_sweep,
    /// Crash after one or more sweeps complete — surviving DB rows
    /// must match the durable bytes.
    post_sweep,
};

/// State shared between the test driver and the SimIO `pre_tick_hook`.
/// The hook fires the crash at `crash_at_tick`; the driver consults
/// `crashed` to stop further work and just drain.
const HookState = struct {
    rng: std.Random.DefaultPrng,
    crash_when: CrashWhen,
    /// Tick at which the hook should fire `sim.crash()`. The driver
    /// increments `tick_index` on each tick boundary; once it reaches
    /// `crash_at_tick`, the hook fires once and sets `crashed`.
    crash_at_tick: u32,
    tick_index: u32 = 0,
    crashed: bool = false,
};

fn preTickCrash(sim: *SimIO, ctx: ?*anyopaque) void {
    const state: *HookState = @ptrCast(@alignCast(ctx.?));
    if (state.crashed) return;
    if (state.crash_when == .none) return;
    if (state.tick_index < state.crash_at_tick) return;
    sim.crash();
    state.crashed = true;
}

const SeedOutcome = struct {
    seed: u64,
    crash_when: CrashWhen,
    crash_at_tick: u32,
    /// Pieces that finished `handleDiskWriteResult` (queued into
    /// `pending_resume_durability`). Doesn't imply durability.
    write_completions_observed: u32,
    /// Pieces the resume DB claimed complete on post-crash load.
    db_complete: u32,
    /// Pieces with content present in the SimIO durable layer
    /// post-crash (the ground truth).
    durable_present: u32,
    /// Did the safety invariant hold? `db_complete ⊆ durable_present`.
    invariant_held: bool,
};

/// Drive one full per-seed run end-to-end through the production
/// gate. Returns the outcome for summary aggregation. On invariant
/// violation, returns the outcome with `invariant_held = false` and
/// also surfaces a diagnostic via `std.debug.print` keyed on the seed
/// and the divergent piece so the failure is debuggable.
fn runOneSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_5piece_single, target_root);
    defer session.deinit(allocator);

    // ── EventLoopOf(SimIO) + bare-bones torrent context ────────────
    //
    // `initBareWithIO` with `hasher_threads = 0` skips the hasher
    // thread pool — we drive `handleDiskWriteResult` directly so no
    // hash jobs are submitted. A SimHasher would be fine too but
    // unnecessary for this gate-focused test.
    const sim = try SimIO.init(allocator, .{ .seed = seed });
    var el = try EL_SimIO.initBareWithIO(allocator, sim, 0);
    defer el.deinit();

    var resume_pieces = try Bitfield.init(allocator, piece_count);
    defer resume_pieces.deinit(allocator);

    var pt = try PieceTracker.init(
        allocator,
        piece_count,
        piece_length,
        total_size,
        &resume_pieces,
        0,
    );
    defer pt.deinit(allocator);

    const fds = [_]posix.fd_t{data_fd};
    const tid = try el.addTorrent(&session, &pt, &fds, @as([20]u8, @splat(0)));

    // Resume DB stand-in (in-memory, no SQLite link required). Same
    // public surface as the SQLite backend — `markCompleteBatch` /
    // `loadCompletePieces` mirror what production goes through. The
    // gate is in `EventLoopOf(SimIO)`, not in the backend, so swapping
    // backends keeps the test honest.
    var db = SimResumeBackend.init(allocator, seed ^ 0xa11d_b);
    defer db.deinit();

    // ── Crash-tick draw ────────────────────────────────────────────
    //
    // Use the seeded RNG to choose `crash_when` (uniform over the four
    // variants) and the tick at which the crash fires. Tick budget is
    // calibrated so each variant lands in its intended phase: pieces
    // are written across ticks ~0..6, fsync sweeps fire at tick 4 and
    // tick 9, and the DB drain runs at tick 5 and tick 10.
    var draw_rng = std.Random.DefaultPrng.init(seed ^ 0xc0de_face);
    const draw_r = draw_rng.random();
    const variant_pick = draw_r.uintLessThan(u32, 4);
    const crash_when: CrashWhen = switch (variant_pick) {
        0 => .none,
        1 => .pre_first_sweep,
        2 => .mid_sweep,
        3 => .post_sweep,
        else => unreachable,
    };
    // Tick choice per variant. Bounds picked to land in the intended
    // phase under the driver's deterministic schedule below.
    const crash_at_tick: u32 = switch (crash_when) {
        .none => std.math.maxInt(u32),
        // Before tick 4 (the first `submitTorrentSync` call). A couple
        // of write completions have landed; the gate must keep them
        // out of the DB.
        .pre_first_sweep => 1 + draw_r.uintLessThan(u32, 3),
        // Right after `submitTorrentSync` was called at tick 4 but
        // before the fsync CQE drains at tick 4's tick-boundary
        // (SimIO schedules with 0-latency fsync — the CQE fires on
        // the same tick). To genuinely catch the sweep mid-flight we
        // queue the crash exactly at tick 4 BEFORE the tick fires
        // any CQEs. The pre-tick hook runs at the top of `tick`, so
        // a `crash_at_tick = 4` zeroes out file-pending bytes
        // *before* the in-flight fsync's `promotePending` call. The
        // sweep's CQE still fires successfully (fsync result is
        // success, not InputOutput) but the durable layer is empty
        // because pending was wiped first. The gate's
        // `durable_resume_pieces` queue still gets populated — but
        // the test driver doesn't drain past the crash point, so no
        // post-crash piece reaches the DB.
        .mid_sweep => 4,
        // After the first sweep completes (tick 5+) but before all
        // pieces are written. The pieces flushed by the first sweep
        // must be durable; pieces written after the first sweep must
        // not be in the DB if their bytes never crossed a sweep.
        .post_sweep => 5 + draw_r.uintLessThan(u32, 5),
    };

    var hook_state = HookState{
        .rng = std.Random.DefaultPrng.init(seed ^ 0xfeed_face),
        .crash_when = crash_when,
        .crash_at_tick = crash_at_tick,
    };
    el.io.pre_tick_hook = preTickCrash;
    el.io.pre_tick_ctx = @ptrCast(&hook_state);

    // ── Drive the production write → sweep → DB pipeline ───────────
    //
    // Per-piece flow (one piece per "tick" in the schedule below):
    //   1. allocate the piece's canonical 4-byte content
    //   2. createPendingWrite(piece) + io.write(...) with the
    //      production `diskWriteCompleteFor(EL)` callback
    //   3. tick the EL once: SimIO's 0-latency write CQE fires
    //      `handleDiskWriteResult` which calls
    //      `markPieceAwaitingDurability` → piece lands in
    //      `tc.pending_resume_durability`.
    //
    // At configured cadence:
    //   - call `submitTorrentSync(tid, false)` to fire the fsync
    //     sweep
    //   - tick once for the fsync CQE to drain → callback moves
    //     pieces into `tc.durable_resume_pieces`
    //   - drain via `drainDurableResumePieces` and feed
    //     `db.markCompleteBatch` (mirrors `persistNewCompletions` +
    //     `flushResume` in `TorrentSession`)
    //
    // Schedule (5 pieces, 2 sweep+drain cycles):
    //   tick 0: write piece 0
    //   tick 1: write piece 1
    //   tick 2: write piece 2
    //   tick 3: write piece 3
    //   tick 4: submitTorrentSync (sweep 1) — pieces 0..3 should
    //           drain to DB after the next tick
    //   tick 5: drain durable_resume_pieces → DB
    //   tick 6: write piece 4
    //   tick 7: (nothing — let the durable bytes settle)
    //   tick 8: (nothing)
    //   tick 9: submitTorrentSync (sweep 2)
    //   tick 10: drain durable_resume_pieces → DB
    var tick_no: u32 = 0;
    var write_completions: u32 = 0;
    while (tick_no <= 10) : (tick_no += 1) {
        hook_state.tick_index = tick_no;
        if (hook_state.crashed) break;

        // Driver step: schedule writes + sweeps + drains.
        switch (tick_no) {
            0, 1, 2, 3 => try submitPieceWrite(&el, tid, tick_no),
            4 => el.submitTorrentSync(tid, false),
            5 => try drainDbBatch(&el, tid, &db, session.metainfo.info_hash),
            6 => try submitPieceWrite(&el, tid, 4),
            9 => el.submitTorrentSync(tid, false),
            10 => try drainDbBatch(&el, tid, &db, session.metainfo.info_hash),
            else => {}, // 7, 8: idle ticks
        }

        // Tick the EL once. Pre-tick hook fires here — if the hook
        // chooses this tick, `sim.crash()` runs before any CQE for
        // this tick processes.
        el.io.tick(1) catch |err| {
            // Crash-induced errors are tolerated — file-state was
            // mutated by `crash()` between submission and CQE. The
            // outer drain at deinit cleans up.
            if (!hook_state.crashed) return err;
        };

        // Track how many writes completed (queued into
        // pending_resume_durability) BEFORE crash. Useful for the
        // diagnostic. We sample the torrent context's tracking
        // counter via the in-memory `pending_resume_durability` +
        // `durable_resume_pieces` lengths.
        if (el.getTorrentContext(tid)) |tc| {
            write_completions = @intCast(
                tc.pending_resume_durability.items.len +
                    tc.durable_resume_pieces.items.len,
            );
        }
    }

    // ── Post-crash invariant check ─────────────────────────────────
    //
    // Read the DB's claim → for each claimed piece, read its bytes
    // through SimIO at the matching offset. After `crash()`, SimIO's
    // `read` returns only the durable layer (un-fsynced pending was
    // dropped). The invariant: every DB-claimed piece must have
    // matching durable bytes. Reverse direction (durable bytes
    // present but DB doesn't claim them) is fine — daemon would
    // recheck or re-download. Only the lying direction (DB claims
    // but durable layer disagrees) is unsafe.
    var post_bf = try Bitfield.init(allocator, piece_count);
    defer post_bf.deinit(allocator);
    const db_count = try db.loadCompletePieces(session.metainfo.info_hash, &post_bf);

    var durable_present: u32 = 0;
    var invariant_held = true;
    var first_violation_piece: ?u32 = null;
    var p: u32 = 0;
    while (p < piece_count) : (p += 1) {
        const expected = pieceBytes(p);
        var actual: [piece_length]u8 = undefined;
        const n = try simReadSync(&el.io, data_fd, p * piece_length, actual[0..]);
        // Zero-fill the tail past the durable length so the comparison
        // is well-defined whether the durable layer is empty or shorter
        // than the requested span.
        if (n < actual.len) @memset(actual[n..], 0);
        const durable_match = std.mem.eql(u8, &actual, &expected);
        if (durable_match) durable_present += 1;

        if (post_bf.has(p) and !durable_match) {
            invariant_held = false;
            if (first_violation_piece == null) first_violation_piece = p;
        }
    }

    if (!invariant_held) {
        std.debug.print(
            "\n  RESUME-DB DURABILITY INVARIANT VIOLATED:\n" ++
                "    seed=0x{x} crash_when={s} crash_at_tick={d}\n" ++
                "    DB claims {d} piece(s) complete; first divergent piece={?d}\n" ++
                "    DB bitfield: ",
            .{
                seed,
                @tagName(crash_when),
                crash_at_tick,
                db_count,
                first_violation_piece,
            },
        );
        var pi: u32 = 0;
        while (pi < piece_count) : (pi += 1) {
            std.debug.print("{d}", .{@intFromBool(post_bf.has(pi))});
        }
        std.debug.print("\n", .{});
    }

    return .{
        .seed = seed,
        .crash_when = crash_when,
        .crash_at_tick = crash_at_tick,
        .write_completions_observed = write_completions,
        .db_complete = db_count,
        .durable_present = durable_present,
        .invariant_held = invariant_held,
    };
}

/// Submit a piece write through the production `diskWriteCompleteFor`
/// callback — same shape `peer_policy.processHashResults` uses. The
/// callback drives `handleDiskWriteResult` which calls
/// `markPieceAwaitingDurability` after `pt.completePiece`.
fn submitPieceWrite(el: *EL_SimIO, tid: u32, piece_index: u32) !void {
    const buf = try el.allocator.alloc(u8, piece_length);
    const bytes = pieceBytes(piece_index);
    @memcpy(buf, &bytes);

    const write_id = try el.createPendingWrite(.{
        .piece_index = piece_index,
        .torrent_id = tid,
    }, .{
        .write_id = 0,
        .piece_index = piece_index,
        .torrent_id = tid,
        .slot = 0,
        .buf = buf,
        .spans_remaining = 1,
    });

    const wop = try el.allocator.create(DiskWriteOp);
    wop.* = .{ .el = el, .write_id = write_id };

    el.io.write(
        .{
            .fd = data_fd,
            .buf = buf,
            .offset = piece_index * piece_length,
        },
        &wop.completion,
        wop,
        peer_handler.diskWriteCompleteFor(EL_SimIO),
    ) catch |err| {
        // Submit failed before the SimIO heap accepted it — clean up
        // and surface so the test fails loudly. The production-side
        // path here logs and marks the pending_w as `write_failed`,
        // but for the test we want any non-crash submit failure to
        // be visible.
        el.allocator.destroy(wop);
        _ = el.removePendingWriteById(write_id);
        el.allocator.free(buf);
        return err;
    };
}

/// Drain the durable resume queue and flush to the DB. Mirrors
/// `TorrentSession.persistNewCompletions` + `flushResume` shape.
fn drainDbBatch(
    el: *EL_SimIO,
    tid: u32,
    db: *SimResumeBackend,
    info_hash: [20]u8,
) !void {
    var batch = std.ArrayList(u32).empty;
    defer batch.deinit(testing.allocator);
    try el.drainDurableResumePieces(tid, testing.allocator, &batch);
    if (batch.items.len == 0) return;
    try db.markCompleteBatch(info_hash, batch.items);
}

/// Synchronous SimIO read helper. Matches the shape used in
/// `tests/sim_io_durability_test.zig` — submit the read, tick once,
/// extract the byte count from the result.
fn simReadSync(io: *SimIO, fd: posix.fd_t, offset: u64, buf: []u8) !usize {
    const Ctx = struct {
        n: usize = 0,
        err: ?anyerror = null,
        calls: u32 = 0,
    };
    var c = ifc.Completion{};
    var ctx = Ctx{};
    const Cb = struct {
        fn cb(
            ud: ?*anyopaque,
            _: *ifc.Completion,
            result: ifc.Result,
        ) ifc.CallbackAction {
            const cc: *Ctx = @ptrCast(@alignCast(ud.?));
            cc.calls += 1;
            switch (result) {
                .read => |r| {
                    if (r) |n| cc.n = n else |e| cc.err = e;
                },
                else => {},
            }
            return .disarm;
        }
    };
    try io.read(.{ .fd = fd, .buf = buf, .offset = offset }, &c, &ctx, Cb.cb);
    try io.tick(0);
    if (ctx.err) |e| return e;
    return ctx.n;
}

test "resume DB durability gate: 32 seeds × varied crash points" {
    var outcomes: [seeds.len]SeedOutcome = undefined;
    for (seeds, 0..) |seed, i| {
        outcomes[i] = runOneSeed(seed) catch |err| {
            std.debug.print(
                "\n  RESUME-DB DURABILITY BUGGIFY seed=0x{x} CRASHED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
    }

    // ── Aggregate summary ──────────────────────────────────────────
    var none_count: u32 = 0;
    var pre_count: u32 = 0;
    var mid_count: u32 = 0;
    var post_count: u32 = 0;
    var held: u32 = 0;
    var total_db_rows: u32 = 0;
    var total_durable: u32 = 0;
    var first_violation: ?SeedOutcome = null;
    for (outcomes) |o| {
        switch (o.crash_when) {
            .none => none_count += 1,
            .pre_first_sweep => pre_count += 1,
            .mid_sweep => mid_count += 1,
            .post_sweep => post_count += 1,
        }
        if (o.invariant_held) held += 1;
        total_db_rows += o.db_complete;
        total_durable += o.durable_present;
        if (!o.invariant_held and first_violation == null) first_violation = o;
    }

    std.debug.print(
        "\n  RESUME-DB DURABILITY BUGGIFY summary: {d}/{d} seeds held invariant\n" ++
            "    crash distribution: none={d} pre_first_sweep={d} mid_sweep={d} post_sweep={d}\n" ++
            "    aggregate: db_rows={d} durable_pieces={d}\n",
        .{
            held,
            @as(u32, seeds.len),
            none_count,
            pre_count,
            mid_count,
            post_count,
            total_db_rows,
            total_durable,
        },
    );

    // ── Vacuous-pass guards ────────────────────────────────────────
    //
    // The 32-seed loop is meaningless if every seed happens to land
    // in the same bucket. With a uniform 1-in-4 draw across 32 seeds
    // each bucket should land at least 4-5 hits on average; the
    // guard is loose (>=1 per non-`none` bucket, >=4 across all
    // crash buckets) so a freak seed-list doesn't trip it but a
    // wholesale regression to the distribution does.
    try testing.expect(none_count >= 1);
    try testing.expect(pre_count + mid_count + post_count >= 4);
    try testing.expect(pre_count >= 1);
    try testing.expect(mid_count >= 1);
    try testing.expect(post_count >= 1);

    // The actual safety assertion: every seed must have held the
    // invariant. If any seed surfaces a violation, surface it as a
    // test failure with the seed in the printed diagnostic above.
    if (first_violation) |v| {
        std.debug.print(
            "\n  HEADLINE: seed 0x{x} (crash_when={s}, tick={d}) — DB claimed " ++
                "{d} pieces complete but only {d} had durable bytes.\n" ++
                "  This is a regression in the resume-durability gate. Reproduce with the seed.\n",
            .{
                v.seed,
                @tagName(v.crash_when),
                v.crash_at_tick,
                v.db_complete,
                v.durable_present,
            },
        );
        return error.ResumeDbDurabilityGateRegression;
    }

    try testing.expectEqual(@as(u32, seeds.len), held);
}

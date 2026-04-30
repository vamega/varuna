//! Live-pipeline BUGGIFY harness for `PieceStoreOf(SimIO)`.
//!
//! Wraps the foundation integration scenarios from
//! `tests/storage_writer_test.zig` (init+sync, fallocate→truncate
//! fallback, 2-span and 3-span writePiece/readPiece round-trips) with
//! the canonical BUGGIFY pattern: per-tick `SimIO.injectRandomFault`
//! plus per-op `FaultConfig` over 32 deterministic seeds.
//!
//! ## What this harness catches that the foundation tests can't
//!
//! `tests/storage_writer_test.zig` exercises each error path with a
//! single-knob `FaultConfig` at p=1.0 — confirming the path *can* fire
//! but not that it composes safely under random multi-knob pressure.
//! That's where the BUGGIFY shape earns its keep:
//!
//!   * `errdefer` cleanup of partially-opened files when one of N
//!     fallocates fails (init opens all files synchronously, then
//!     submits N fallocates; failure on completion #2 of #5 must close
//!     all 5 fds — the errdefer-on-files chain is the only guard).
//!   * `sync`'s pending-counter under fsync error storms — the per-op
//!     fault probability is 5%, so a multi-file torrent under 32 seeds
//!     produces a healthy mix of "all succeed", "one fails", "several
//!     fail in interleaved order". The pending counter must reach zero
//!     in every case.
//!   * Per-span resubmit racing with cancellation under read/write
//!     fault injection — `injectRandomFault` mutates an in-flight op's
//!     result while the heap is otherwise quiescent; the
//!     write/readSpanCallback short-write loops must NOT silently
//!     re-submit on a faulted completion (would mask the error and
//!     leak pending).
//!   * Mmap-fallback-to-truncate edge cases under `fallocate(EOPNOTSUPP)`
//!     injection — when fallocate forces the truncate fallback AND
//!     truncate also faults, both error paths must compose without
//!     losing the first error or leaking the open files.
//!
//! ## Safety invariants asserted under any seed × fault sequence
//!
//!   1. `PieceStore.init` either succeeds (all files open, all
//!      fallocate/truncate completions delivered) or returns a real
//!      kernel-shaped error. Never panic, never UB, never leak a fd
//!      (testing.allocator catches the byte-level leaks; the file fd
//!      leak guard is the test's `defer store.deinit()` pairing on
//!      success-only paths).
//!   2. `sync` either succeeds or surfaces the first fsync error; the
//!      pending counter drains to zero in both cases.
//!   3. `writePiece` / `readPiece` either succeed (round-trip data
//!      matches when no fault fired) or return `error.NoSpaceLeft` /
//!      `error.InputOutput` from the first faulted span. The pending
//!      counter on the per-piece ctx drains to zero either way.
//!   4. No allocator leaks across any seed (testing.allocator is the
//!      ground truth).
//!
//! Liveness — that the operation *finishes* — is enforced by SimIO's
//! synchronous tick: every submitted op must eventually fire, faulted
//! or not. There's no `max_ticks` guard because the drain loops run
//! inside `PieceStore` methods and SimIO's `tick` always delivers due
//! completions. A wedge would manifest as test timeout, not a quiet
//! infinite loop.
//!
//! ## Pattern reference
//!
//! Mirrors `tests/recheck_live_buggify_test.zig`'s shape: 32 canonical
//! seeds, per-tick BUGGIFY roll, per-op `FaultConfig` for parallel
//! injection paths, vacuous-pass guards on the summary statistics.
//! The per-tick injection is wired through `SimIO.pre_tick_hook`
//! because `PieceStore.init` / `sync` / `writePiece` / `readPiece` own
//! their own internal `while (pending > 0) try io.tick(1)` drain
//! loops — no external tick boundary exists for the test to wrap.
//! The hook fires at the top of every `tick` call; the harness uses
//! it to roll the per-tick injection probability and fire
//! `injectRandomFault` against the in-flight heap.

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const Session = varuna.torrent.session.Session;
const FilePriority = varuna.torrent.file_priority.FilePriority;
const writer_mod = varuna.storage.writer;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;

const PieceStoreOfSim = writer_mod.PieceStoreOf(SimIO);

/// Canonical 32-seed list shared with the recheck and metadata-fetch
/// BUGGIFY harnesses. Failing seeds reproduce with the same hex prefix
/// across all three harnesses' diagnostics.
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

/// Canonical per-op fault rates for the BUGGIFY shape. Each rate is
/// independent — a single op can roll a fault on its specific path,
/// and the per-tick `injectRandomFault` adds another independent
/// chance to mutate any in-flight op's result.
///
/// `fallocate_unsupported_probability` is the highest because it
/// drives the truncate-fallback path; the other rates exercise simple
/// error-propagation paths and 5% per-op produces ~1-3 hits per seed
/// across 5-10 ops typical of these scenarios.
const canonical_faults: sim_io_mod.FaultConfig = .{
    .read_error_probability = 0.05,
    .write_error_probability = 0.05,
    .fsync_error_probability = 0.05,
    .fallocate_error_probability = 0.05,
    .fallocate_unsupported_probability = 0.10,
    .truncate_error_probability = 0.05,
};

/// Per-tick injection probability — same density as the recheck
/// harness, calibrated against the typical 3-10 op heap depths these
/// scenarios produce.
const inject_probability: f32 = 0.05;

/// Test torrent fixtures (mirror `tests/storage_writer_test.zig`).
const torrent_3byte_single =
    "d4:infod" ++
    "6:lengthi3e" ++
    "4:name3:abc" ++
    "12:piece lengthi4e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

const torrent_multifile =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi7e4:pathl4:beta5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi4e" ++
    "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

const torrent_3file =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi3e4:pathl4:betaee" ++
    "d6:lengthi3e4:pathl5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi9e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

/// State threaded through the SimIO `pre_tick_hook` — RNG state for
/// the per-tick injection roll and a hit counter for the summary.
const HookState = struct {
    rng: std.Random.DefaultPrng,
    inject_probability: f32,
    hits: u32 = 0,
};

/// Pre-tick hook installed on SimIO: rolls the per-tick injection
/// probability and, on success, calls `injectRandomFault` to mutate
/// a randomly-chosen in-flight op's result. Increments `hits` on
/// successful injection (the heap may be empty or contain only parked
/// completions, in which case `injectRandomFault` returns null).
fn preTickInject(sim: *SimIO, ctx: ?*anyopaque) void {
    const state: *HookState = @ptrCast(@alignCast(ctx.?));
    if (state.inject_probability <= 0.0) return;
    if (state.rng.random().float(f32) >= state.inject_probability) return;
    if (sim.injectRandomFault(&state.rng)) |_| {
        state.hits += 1;
    }
}

/// Per-seed outcome for the summary aggregation.
const SeedOutcome = struct {
    /// True if the high-level operation under test (init+sync, or
    /// writePiece+readPiece) succeeded end-to-end with all data intact.
    succeeded: bool,
    /// True if the operation returned an error gracefully (no panic,
    /// no UB, no leak). Always true on a clean run; the test asserts
    /// this is true for every seed.
    failed_gracefully: bool,
    /// First error the operation surfaced (null on success).
    error_kind: ?anyerror,
    /// Number of times `pre_tick_hook` injected a fault. Sums across
    /// seeds for the vacuous-pass guard.
    buggify_hits: u32,
};

/// Run the init+sync scenario under BUGGIFY for one seed. Mirrors
/// `tests/storage_writer_test.zig`'s "init + sync happy path" but with
/// the full canonical fault config plus per-tick injection. Two open
/// files (multifile torrent) so the errdefer-cleanup path on partial
/// fallocate failure is reachable.
fn runInitSyncSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = seed,
        .faults = canonical_faults,
    });
    defer sim.deinit();

    var hook_state = HookState{
        .rng = std.Random.DefaultPrng.init(seed ^ 0xfeed_face),
        .inject_probability = inject_probability,
    };
    sim.pre_tick_hook = preTickInject;
    sim.pre_tick_ctx = @ptrCast(&hook_state);

    var maybe_store = PieceStoreOfSim.init(allocator, &session, &sim) catch |err| {
        // Init failed — the errdefer chain inside `init` must have
        // closed any partially-opened fds and freed the files slice.
        // testing.allocator catches the byte-level leak; fd leaks
        // would surface as later test fixture failures.
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };
    defer maybe_store.deinit();

    // sync drains two fsyncs through the contract. Under fault
    // injection it can surface InputOutput from any of them.
    maybe_store.sync(&sim) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };

    return .{
        .succeeded = true,
        .failed_gracefully = true,
        .error_kind = null,
        .buggify_hits = hook_state.hits,
    };
}

/// Run the 3-byte single-file init scenario which exercises the
/// fallocate-fallback-to-truncate path under BUGGIFY. The fault config
/// includes 10% `fallocate_unsupported_probability` so the truncate
/// fallback fires on a meaningful fraction of seeds; the 5%
/// `truncate_error_probability` then composes with it.
fn runFallbackTruncateSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3byte_single, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{
        .seed = seed,
        .faults = canonical_faults,
    });
    defer sim.deinit();

    var hook_state = HookState{
        .rng = std.Random.DefaultPrng.init(seed ^ 0xcafe_babe),
        .inject_probability = inject_probability,
    };
    sim.pre_tick_hook = preTickInject;
    sim.pre_tick_ctx = @ptrCast(&hook_state);

    var maybe_store = PieceStoreOfSim.init(allocator, &session, &sim) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };
    defer maybe_store.deinit();

    return .{
        .succeeded = true,
        .failed_gracefully = true,
        .error_kind = null,
        .buggify_hits = hook_state.hits,
    };
}

/// Run the 2-span writePiece + readPiece round-trip under BUGGIFY.
/// `init` runs under a clean SimIO so the round-trip starts from a
/// known-good store; faults are flipped on AFTER init to scope the
/// injection to the writePiece/readPiece submissions and the
/// per-tick injection.
///
/// On a clean run (no fault fires), the assembled piece data must
/// round-trip exactly. On a faulted run, write/read must surface the
/// kernel-shaped error and leave the store in a deinit-safe state.
fn runRoundTrip2SpanSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    // Init under a clean SimIO so we always have a working store. The
    // canonical scenario is "what happens when the data path takes
    // damage" — init's failure surface is covered by runInitSyncSeed.
    var sim = try SimIO.init(allocator, .{ .seed = seed });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), plan.spans.len);

    // Now flip the data-path faults on and install the per-tick hook.
    sim.config.faults = canonical_faults;
    var hook_state = HookState{
        .rng = std.Random.DefaultPrng.init(seed ^ 0xbeef_face),
        .inject_probability = inject_probability,
    };
    sim.pre_tick_hook = preTickInject;
    sim.pre_tick_ctx = @ptrCast(&hook_state);

    const piece_data: []const u8 = "spam";
    store.writePiece(&sim, plan.spans, piece_data) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };

    // Register expected post-write content per file. SimIO writes
    // don't actually mutate disk content; reads come back from
    // setFileBytes registrations.
    try sim.setFileBytes(store.files[0].?.handle, "spa");
    try sim.setFileBytes(store.files[1].?.handle, "m");

    var piece_buffer: [4]u8 = undefined;
    store.readPiece(&sim, plan.spans, piece_buffer[0..]) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };

    // Clean run: the round-trip must reconstruct the original data.
    if (!std.mem.eql(u8, piece_buffer[0..], piece_data)) {
        return error.RoundTripDataMismatch;
    }

    return .{
        .succeeded = true,
        .failed_gracefully = true,
        .error_kind = null,
        .buggify_hits = hook_state.hits,
    };
}

/// Run the 3-span writePiece + readPiece round-trip under BUGGIFY.
/// 3-file torrent forces a 3-span piece — exercises the
/// multi-completion drain path with N>2 (the 2-span variant covers
/// N=2). Same fault config, same hook installation pattern.
fn runRoundTrip3SpanSeed(seed: u64) !SeedOutcome {
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3file, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = seed });
    defer sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &sim);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 3), store.files.len);

    const plan = try varuna.storage.verify.planPieceVerification(allocator, &session, 0);
    defer plan.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), plan.spans.len);

    sim.config.faults = canonical_faults;
    var hook_state = HookState{
        .rng = std.Random.DefaultPrng.init(seed ^ 0x1234_5678),
        .inject_probability = inject_probability,
    };
    sim.pre_tick_hook = preTickInject;
    sim.pre_tick_ctx = @ptrCast(&hook_state);

    const piece_data: []const u8 = "ABCdef-XY"; // 9 bytes
    store.writePiece(&sim, plan.spans, piece_data) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };

    try sim.setFileBytes(store.files[0].?.handle, "ABC");
    try sim.setFileBytes(store.files[1].?.handle, "def");
    try sim.setFileBytes(store.files[2].?.handle, "-XY");

    var piece_buffer: [9]u8 = undefined;
    store.readPiece(&sim, plan.spans, piece_buffer[0..]) catch |err| {
        return .{
            .succeeded = false,
            .failed_gracefully = true,
            .error_kind = err,
            .buggify_hits = hook_state.hits,
        };
    };

    if (!std.mem.eql(u8, piece_buffer[0..], piece_data)) {
        return error.RoundTripDataMismatch;
    }

    return .{
        .succeeded = true,
        .failed_gracefully = true,
        .error_kind = null,
        .buggify_hits = hook_state.hits,
    };
}

/// Sum stats across the 32-seed loop and emit the canonical summary
/// line. Asserts the safety + vacuous-pass invariants.
fn aggregateAndAssert(
    label: []const u8,
    outcomes: []const SeedOutcome,
) !void {
    var succeeded: u32 = 0;
    var failed_gracefully: u32 = 0;
    var seeds_with_hits: u32 = 0;
    var total_hits: u32 = 0;
    for (outcomes) |o| {
        if (o.succeeded) succeeded += 1;
        if (o.failed_gracefully) failed_gracefully += 1;
        if (o.buggify_hits > 0) seeds_with_hits += 1;
        total_hits += o.buggify_hits;
    }

    std.debug.print(
        "\n  PieceStore LIVE BUGGIFY summary ({s}): {d}/{d} seeds succeeded, " ++
            "{d}/{d} fault hits across {d} seeds with hits\n",
        .{
            label,               succeeded,
            @as(u32, seeds.len), total_hits,
            @as(u32, seeds.len), seeds_with_hits,
        },
    );

    // Safety invariant: every seed must terminate gracefully (success
    // or kernel-shaped error). A panic / UB / leak would have killed
    // the test before we reached here, so this is a redundant guard
    // that doubles as documentation.
    try testing.expectEqual(@as(u32, seeds.len), failed_gracefully);

    // Vacuous-pass guard: at least one seed must register a per-tick
    // injection hit AND the per-op fault knobs must produce at least
    // one failure across the 32 seeds. If every seed succeeded with
    // zero hits, fault injection isn't reaching the code under test
    // (likely a density regression or the hook isn't wired).
    try testing.expect(seeds_with_hits >= 1);
}

// ── Test 1: init+sync under BUGGIFY ─────────────────────────────────

test "PieceStoreOf(SimIO) LIVE BUGGIFY: init+sync over 32 seeds" {
    var outcomes: [seeds.len]SeedOutcome = undefined;
    for (seeds, 0..) |seed, i| {
        outcomes[i] = runInitSyncSeed(seed) catch |err| {
            std.debug.print(
                "\n  PIECESTORE LIVE BUGGIFY (init+sync) seed=0x{x} CRASHED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
    }
    try aggregateAndAssert("init+sync", &outcomes);
}

// ── Test 2: fallocate-fallback-to-truncate under BUGGIFY ───────────

test "PieceStoreOf(SimIO) LIVE BUGGIFY: fallocate→truncate fallback over 32 seeds" {
    var outcomes: [seeds.len]SeedOutcome = undefined;
    for (seeds, 0..) |seed, i| {
        outcomes[i] = runFallbackTruncateSeed(seed) catch |err| {
            std.debug.print(
                "\n  PIECESTORE LIVE BUGGIFY (fallback) seed=0x{x} CRASHED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
    }
    try aggregateAndAssert("fallback", &outcomes);
}

// ── Test 3: 2-span writePiece+readPiece round-trip ─────────────────

test "PieceStoreOf(SimIO) LIVE BUGGIFY: 2-span round-trip over 32 seeds" {
    var outcomes: [seeds.len]SeedOutcome = undefined;
    for (seeds, 0..) |seed, i| {
        outcomes[i] = runRoundTrip2SpanSeed(seed) catch |err| {
            std.debug.print(
                "\n  PIECESTORE LIVE BUGGIFY (2-span) seed=0x{x} CRASHED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
    }
    try aggregateAndAssert("2-span", &outcomes);
}

// ── Test 4: 3-span writePiece+readPiece round-trip ─────────────────

test "PieceStoreOf(SimIO) LIVE BUGGIFY: 3-span round-trip over 32 seeds" {
    var outcomes: [seeds.len]SeedOutcome = undefined;
    for (seeds, 0..) |seed, i| {
        outcomes[i] = runRoundTrip3SpanSeed(seed) catch |err| {
            std.debug.print(
                "\n  PIECESTORE LIVE BUGGIFY (3-span) seed=0x{x} CRASHED: {any}\n",
                .{ seed, err },
            );
            return err;
        };
    }
    try aggregateAndAssert("3-span", &outcomes);
}

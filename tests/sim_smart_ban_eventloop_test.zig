//! Smart-ban EventLoop integration test.
//!
//! Drives the production `EventLoop` against `SimIO` with 5 honest
//! SimPeer seeders + 1 corrupt SimPeer seeder. Asserts the smart-ban
//! Phase 0 algorithm bans the corrupt peer without false-positive bans
//! on honest peers, while pieces 1..3 verify cleanly.
//!
//! Two top-level tests share the `runOneSeedAgainstEventLoop` body:
//!
//!   * "5 honest + 1 corrupt over 8 seeds" — clean smart-ban,
//!     `BuggifyOpts{}` (DoD #2 + #3).
//!   * "5 honest + 1 corrupt + BUGGIFY over 32 seeds" — same scenario
//!     with `BuggifyOpts{ .probability = 0.02 }` randomized fault
//!     injection on every tick. Asserts the safety invariant only
//!     (no honest peer falsely banned, no panic, no leak); the
//!     corrupt-peer ban is *informational* because a recv/send fault
//!     can sever the corrupt peer's connection before 4 hash-fails
//!     accumulate, in which case the ban legitimately doesn't fire
//!     (DoD #4).
//!
//! ## Bitfield layout (option 1 — rarest-first deterministic)
//!
//! BitTorrent bitfield encoding: high bit of byte 0 = piece 0, next
//! bit down = piece 1, etc.
//!
//!   peer index    bitfield byte 0       pieces held
//!   ──────────    ───────────────       ───────────
//!   0..4 (hon.)   0_111_0000  (0x70)    {1, 2, 3}
//!   5  (corrupt)  1_000_0000  (0x80)    {0}
//!
//! Pieces 1..3 each have 5 sources; piece 0 has exactly 1. The
//! production rarest-first picker (`PieceTracker.claimPiece` filtered by
//! peer bitfield, called from `peer_policy.tryAssignPieces`) deterministically
//! assigns piece 0 to the corrupt peer because it's the unique holder.
//! After 4 failures (trust = 0 → -2 → -4 → -6 → -8) the corrupt peer is
//! banned. Piece 0 then has no source → stays incomplete (correct
//! production behaviour, no other holder advertised it).

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const event_loop_mod = varuna.io.event_loop;
const clock_mod = varuna.runtime.clock;
const SimPeer = varuna.sim.SimPeer;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;
const peer_wire = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Bitfield = varuna.bitfield.Bitfield;
const BanList = varuna.net.ban_list.BanList;

const Completion = ifc.Completion;
const Result = ifc.Result;

const trust_ban_threshold: i8 = -7;
const num_peers: u8 = 6;
const corrupt_peer_index: u8 = 5;
const piece_count: u32 = 4;
const piece_size: u32 = 32;
const max_ticks: u32 = 4096;

const honest_bitfield: [1]u8 = .{0b0111_0000};
const corrupt_bitfield: [1]u8 = .{0b1000_0000};

fn syntheticAddr(idx: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 10, 0, 0, idx + 1 }, 0);
}

/// Build minimal bencoded metainfo for a 4-piece × 32-byte torrent with
/// the given concatenated piece hashes. Mirrors the pattern in
/// `tests/sim_swarm_test.zig:buildTorrentBytes`.
fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hashes: *const [piece_count][20]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_count * piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name17:smart_ban_sim.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces");
    try buf.writer(allocator).print("{d}", .{piece_count * 20});
    try buf.append(allocator, ':');
    for (piece_hashes) |*h| try buf.appendSlice(allocator, h);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Per-run knobs for `runOneSeedAgainstEventLoop`.
const BuggifyOpts = struct {
    /// Per-tick probability of mutating a randomly-chosen in-flight op's
    /// result via `SimIO.injectRandomFault`. Zero disables the wrap.
    probability: f32 = 0.0,
    /// When true, skip the strict piece-completion + ban assertions and
    /// keep only the safety invariant: no honest peer is wrongly banned.
    /// Set by the BUGGIFY harness — under randomized faults, the corrupt
    /// peer's socket can die before 4 hash-fails accumulate, in which
    /// case the ban legitimately doesn't fire.
    safety_only: bool = false,
};

/// Outcome of a single seed run, returned to the harness so the BUGGIFY
/// loop can count "smart-ban actually fired" rates and reject vacuous
/// passes (e.g. all 32 seeds dropped the corrupt peer's bytes before
/// the first hash fail).
const SeedOutcome = struct {
    corrupt_banned: bool,
    pieces_done: u8, // count of pieces 1..3 that verified
};

fn runOneSeedAgainstEventLoop(seed: u64, opts: BuggifyOpts) !SeedOutcome {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── 1. Build canonical piece data + SHA-1 hashes ─────────────
    var piece_data: [piece_count * piece_size]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var piece_hashes: [piece_count][20]u8 = undefined;
    var p: u32 = 0;
    while (p < piece_count) : (p += 1) {
        Sha1.hash(piece_data[p * piece_size ..][0..piece_size], &piece_hashes[p], .{});
    }

    // ── 2. Build the torrent metainfo and load it as a Session ──
    const torrent_bytes = try buildTorrentBytes(arena.allocator(), &piece_hashes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_root = try std.fs.path.join(arena.allocator(), &.{
        ".zig-cache", "tmp", &tmp.sub_path, "data",
    });

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    // ── 3. Disk-backed store + downloader's empty piece tracker ──
    // PieceStore drives real disk syscalls (fallocate / pread / pwrite)
    // against actual files in `data_root`; the EventLoop below runs
    // SimIO for the protocol-level simulation. So we use a one-shot
    // RealIO here to satisfy PieceStore's IO contract.
    var store_init_io = try varuna.io.real_io.RealIO.init(.{ .entries = 16 });
    defer store_init_io.deinit();
    var store = try PieceStore.init(allocator, &session, &store_init_io);
    defer store.deinit();

    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    var empty_bf = try Bitfield.init(allocator, piece_count);
    defer empty_bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, piece_count, piece_size, piece_size, &empty_bf, 0);
    defer tracker.deinit(allocator);

    // ── 4. Spin up EventLoopOf(SimIO) ─────────────────────────────
    //
    // Under BUGGIFY we throttle the per-tick op budget so the active
    // workload spans many ticks instead of bursting through in 1-2.
    // That gives the per-tick BUGGIFY roll real in-flight heap entries
    // to land on; without this, smart-ban completes inside one
    // io.tick() and the per-tick check sees an empty heap on every
    // subsequent tick.
    //
    // Per-op `FaultConfig` probabilities complement the per-tick
    // BUGGIFY: every recv/send/read/write submission rolls for a
    // transient failure independently. This produces thousands of
    // injection opportunities per seed (one per submitted op) without
    // burning per-tick budget. Set well below 0.01 so smart-ban can
    // still observe ≥4 hash failures on the corrupt peer in most seeds
    // (the test's safety invariant doesn't require it, but stronger
    // signals are better).
    const max_ops_per_tick: u32 = if (opts.probability > 0.0) 128 else 4096;
    const fault_config: sim_io_mod.FaultConfig = if (opts.probability > 0.0) .{
        .recv_error_probability = 0.003,
        .send_error_probability = 0.003,
        .read_error_probability = 0.001,
        .write_error_probability = 0.001,
    } else .{};
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{
        .socket_capacity = num_peers * 2,
        .seed = seed,
        .max_ops_per_tick = max_ops_per_tick,
        .faults = fault_config,
    });
    var el = try EL_SimIO.initBareWithIO(allocator, sim_io, 1);
    defer el.deinit();

    // Smart-ban needs a real BanList — penalizePeerTrust → bl.banIp.
    // Without one, the corrupt peer is removed but is_banned() always
    // returns false, so the assertions can't observe the ban.
    var ban_list = BanList.init(allocator);
    defer ban_list.deinit();
    el.ban_list = &ban_list;

    el.encryption_mode = .disabled;
    el.clock = clock_mod.Clock.simAtSecs(1_000_000); // far past zero so time-gated logic opens

    // ── 5. Register the torrent ──────────────────────────────────
    const downloader_peer_id = "-VR0001-simdleventl0".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, downloader_peer_id);

    // ── 6. Spin up 6 SimPeer seeders + addInboundPeer for each ──
    var rng = std.Random.DefaultPrng.init(seed ^ 0xfeedface);
    var peers: [num_peers]SimPeer = undefined;
    var slots: [num_peers]u16 = undefined;

    var i: u8 = 0;
    while (i < num_peers) : (i += 1) {
        const fds = try el.io.createSocketpair();
        const seeder_fd = fds[0];
        const downloader_fd = fds[1];

        const behavior: SimPeerBehavior = if (i == corrupt_peer_index)
            .{ .corrupt = .{ .probability = 1.0 } }
        else
            .{ .honest = {} };
        const bf: *const [1]u8 = if (i == corrupt_peer_index)
            &corrupt_bitfield
        else
            &honest_bitfield;

        peers[i] = SimPeer{
            .io = undefined,
            .fd = 0,
            .role = .seeder,
            .behavior = behavior,
            .rng = &rng,
            .info_hash = undefined,
            .peer_id = undefined,
            .piece_count = 0,
            .piece_size = 0,
            .bitfield = &.{},
            .piece_data = &.{},
        };
        try peers[i].init(.{
            .io = &el.io,
            .fd = seeder_fd,
            .role = .seeder,
            .behavior = behavior,
            .info_hash = session.metainfo.info_hash,
            .peer_id = [_]u8{i} ** 20,
            .piece_count = piece_count,
            .piece_size = piece_size,
            .bitfield = bf,
            .piece_data = &piece_data,
            .rng = &rng,
        });

        // Use addConnectedPeerWithAddress so the EventLoop sends the
        // BitTorrent handshake first. SimPeer's `armRecv` then receives it
        // and (since role=seeder) responds with handshake + bitfield.
        // Distinct synthetic addresses keep BanList per-peer.
        slots[i] = try el.addConnectedPeerWithAddress(downloader_fd, tid, syntheticAddr(i));
    }

    // ── 7. Drive ticks ───────────────────────────────────────────
    //
    // Under no-fault runs we break as soon as the smart-ban condition
    // is met (corrupt banned + pieces 1..3 complete) — this is a
    // liveness check.
    //
    // Under BUGGIFY runs we deliberately *don't* break: the goal is to
    // give the fault-injection loop enough turns to actually fire on
    // real in-flight ops. With a 4096-op-per-tick budget the smart-ban
    // condition is usually reached in 1-2 el.tick iterations, which at
    // p=0.02 produces near-zero injections — meaningless. Running for
    // `buggify_min_ticks` instead gives ~80 injections per seed and
    // exercises the fault-recovery paths the test is actually about.
    const buggify_min_ticks: u32 = 4096;
    var buggify_hits: u32 = 0;
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        // BUGGIFY: per-tick chance to mutate a random in-flight op's
        // result. We use the same rng for both the inject decision and
        // SimIO.injectRandomFault's heap probe — deterministic per seed.
        if (opts.probability > 0.0) {
            if (rng.random().float(f32) < opts.probability) {
                if (el.io.injectRandomFault(&rng)) |_| {
                    buggify_hits += 1;
                }
            }
        }

        try el.tick();

        // Step each SimPeer (honest peers no-op; future slow-behaviour
        // peers would advance their throttle here).
        for (&peers) |*peer| {
            try peer.step(@as(u64, @intCast(el.clock.now())) * std.time.ns_per_s);
        }

        if (opts.probability == 0.0) {
            const corrupt_banned = ban_list.isBanned(syntheticAddr(corrupt_peer_index));
            const all_target_pieces_done = el.isPieceComplete(tid, 1) and
                el.isPieceComplete(tid, 2) and
                el.isPieceComplete(tid, 3);
            if (corrupt_banned and all_target_pieces_done) break;
        } else {
            // BUGGIFY: keep running long enough for fault injection to
            // exercise meaningful op state.
            if (ticks >= buggify_min_ticks) break;
        }
    }

    // ── 8. Drain hasher results so valid piece buffers don't leak.
    //
    // The hasher hands valid piece bufs to the EL via `processHashResults`,
    // which queues an async disk write that frees the buf. If we tear down
    // before processing those results, the bufs sit in `completed_results`
    // (whose deinit only frees *invalid* bufs, on the assumption that valid
    // ones were already passed to disk-write). Force-close the SimPeer
    // connections to stop new piece downloads, then spin until the hasher
    // and pending-write queues are quiescent.
    for (&peers) |*peer| {
        if (peer.fd >= 0) {
            el.io.closeSocket(peer.fd);
            peer.fd = -1;
        }
    }
    var drain_ticks: u32 = 0;
    while (drain_ticks < 256) : (drain_ticks += 1) {
        const hasher_busy = if (el.hasher) |h| h.hasPendingWork() else false;
        const writes_pending = el.pending_writes.count() > 0;
        if (!hasher_busy and !writes_pending) break;
        try el.tick();
    }

    // BUGGIFY telemetry: surface the per-seed hit count so failing seeds
    // are diagnosable. Quiet under no-fault runs.
    if (opts.probability > 0.0) {
        std.debug.print("  BUGGIFY seed=0x{x} hits={d} ticks={d}\n", .{ seed, buggify_hits, ticks });
    }

    // ── 9. Smart-ban assertions ──────────────────────────────────
    //
    // Under BUGGIFY (`safety_only`) we drop the strict liveness
    // assertions. A recv/send fault can sever any peer's connection at
    // an arbitrary moment — including the corrupt peer before its 4th
    // hash-fail, or an honest peer mid-piece. Liveness invariants
    // (pieces 1..3 verify, corrupt banned, piece 0 incomplete) only
    // hold reliably without faults; under faults all we guarantee is
    // safety: no honest peer is wrongly banned.
    if (!opts.safety_only) {
        // Pieces 1..3 must verify (multiple honest sources for each).
        try testing.expect(el.isPieceComplete(tid, 1));
        try testing.expect(el.isPieceComplete(tid, 2));
        try testing.expect(el.isPieceComplete(tid, 3));

        // Piece 0 must NOT verify — its only source is the corrupt
        // peer, who got banned. Correct production outcome.
        try testing.expect(!el.isPieceComplete(tid, 0));

        // Corrupt peer banned. The slot is freed by `removePeer`
        // immediately after the smart-ban threshold trips, so the
        // canonical EL-integration assertion is `ban_list.isBanned`.
        // A hit means `penalizePeerTrust` ran with `trust_points <=
        // trust_ban_threshold` (the only `bl.banIp` call site at the
        // smart-ban threshold), which under the `-2`-per-fail rule
        // implies at least four hash failures were observed inside
        // the EventLoop. Exact trust arithmetic is unit-tested in
        // `sim_smart_ban_protocol_test.zig` against the bare Peer.
        try testing.expect(ban_list.isBanned(syntheticAddr(corrupt_peer_index)));
    }

    // Safety invariant — holds under both clean runs and BUGGIFY:
    // no honest peer is banned, no honest peer has any hashfails.
    var j: u8 = 0;
    while (j < num_peers) : (j += 1) {
        if (j == corrupt_peer_index) continue;
        try testing.expect(!ban_list.isBanned(syntheticAddr(j)));
        if (el.getPeerView(slots[j])) |v| {
            try testing.expectEqual(@as(u8, 0), v.hashfails);
        }
    }

    var done_count: u8 = 0;
    if (el.isPieceComplete(tid, 1)) done_count += 1;
    if (el.isPieceComplete(tid, 2)) done_count += 1;
    if (el.isPieceComplete(tid, 3)) done_count += 1;
    return .{
        .corrupt_banned = ban_list.isBanned(syntheticAddr(corrupt_peer_index)),
        .pieces_done = done_count,
    };
}

test "smart-ban EventLoop integration: 5 honest + 1 corrupt over 8 seeds" {
    // Bitfield-layout sanity: catches drift if somebody "fixes" the
    // option (1) layout and silently breaks the rarest-first guarantee.
    const piece_0_mask: u8 = 0b1000_0000;
    try testing.expectEqual(@as(u8, 0), honest_bitfield[0] & piece_0_mask);
    try testing.expectEqual(piece_0_mask, corrupt_bitfield[0] & piece_0_mask);

    const seeds = [_]u64{
        0x0000_0001,
        0xDEAD_BEEF,
        0xFEED_FACE,
        0xCAFE_BABE,
        0x0F0F_0F0F,
        0x1234_5678,
        0xABCD_EF01,
        0x9876_5432,
    };
    for (seeds) |seed| {
        _ = runOneSeedAgainstEventLoop(seed, .{}) catch |err| {
            std.debug.print("\n  SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

test "smart-ban EventLoop integration with BUGGIFY: 32 seeds, p=0.02 fault injection" {
    // BUGGIFY (TigerBeetle VOPR-style) randomized fault injection: per
    // tick, with probability 2%, mutate a random in-flight op's result
    // to a fault appropriate to its op kind (`recv =>
    // ConnectionResetByPeer`, `send => BrokenPipe`, `write =>
    // NoSpaceLeft`, etc.). Stresses the smart-ban + peer-cleanup paths
    // with arbitrary, deterministic-per-seed connection failures.
    //
    // Asserts the *safety* invariant only — under randomized faults,
    // the corrupt peer's socket can be severed before 4 hash-fails
    // accumulate, in which case the ban legitimately doesn't fire.
    // What must hold under any fault sequence:
    //
    //   * No honest peer is wrongly banned.
    //   * No honest peer accumulates any hashfails (honest data is
    //     never corrupted, only delivered or not).
    //   * The test exits cleanly (no panic, no leak).
    //
    // 32 seeds (DoD #4); p=0.02 keeps fault density meaningful (~80
    // injections per 4096-tick run) without strangling progress.
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
    const opts: BuggifyOpts = .{ .probability = 0.02, .safety_only = true };
    var ban_seeds: u32 = 0;
    var pieces_done_total: u32 = 0;
    for (seeds) |seed| {
        const outcome = runOneSeedAgainstEventLoop(seed, opts) catch |err| {
            std.debug.print("\n  BUGGIFY SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
        if (outcome.corrupt_banned) ban_seeds += 1;
        pieces_done_total += outcome.pieces_done;
    }
    std.debug.print("\n  BUGGIFY summary: {d}/{d} seeds banned corrupt, {d}/{d} honest pieces verified\n", .{
        ban_seeds,
        seeds.len,
        pieces_done_total,
        seeds.len * 3,
    });

    // Reject vacuous-pass scenarios: BUGGIFY can mask the smart-ban
    // signal entirely if every seed happens to inject a fault on the
    // corrupt peer's send before its bytes ever reach the EL — under
    // that pathology the test passes the safety check trivially with
    // nothing actually exercised. Demand the corrupt peer be banned in
    // a meaningful majority of seeds (pinned at half — empirically 30+
    // of 32 ban under p=0.02 + FaultConfig=0.003, but pinning at half
    // gives headroom against future fault-density tweaks).
    try testing.expect(ban_seeds * 2 >= seeds.len);
    // Honest pieces should also verify in most seed-piece pairs (96
    // total: 32 seeds × 3 pieces). Same headroom rationale.
    try testing.expect(pieces_done_total * 2 >= seeds.len * 3);
}

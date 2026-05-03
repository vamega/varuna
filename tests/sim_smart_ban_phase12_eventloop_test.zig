//! Smart-ban Phase 1 + 2 — EventLoop integration test (Phase 2B).
//!
//! Layer 2 of the three-layer testing strategy described in
//! `STYLE.md > Layered Testing Strategy`. Builds on the Phase 2A
//! disconnect-based multi-source path (`sim_multi_source_eventloop_test.zig`)
//! by adding deterministic per-block corruption — exercising the
//! smart-ban Phase 1 (per-block SHA-1 attribution on hash failure)
//! and Phase 2 (ban-targeting on re-download pass) machinery in
//! `src/net/smart_ban.zig` and `src/io/peer_policy.zig`.
//!
//! ## Discriminating power vs Phase 0
//!
//! Phase 0 BUGGIFY test (in `sim_smart_ban_eventloop_test.zig`)
//! asserted: an honest peer in the *same swarm* as a corrupt peer is
//! NOT banned. The honest peers there contributed *different pieces*
//! than the corrupt peer; the smart-ban discriminator was "this peer
//! never sent a hash-failing piece, so no penalty".
//!
//! Phase 2B asserts a sharper invariant: an honest peer who
//! *contributed an honest block to the same piece a corrupt peer also
//! contributed to* is NOT banned. The smart-ban Phase 2 discriminator
//! walks per-block hashes from the failed piece and identifies which
//! peer's block(s) caused the mismatch — the honest peer's blocks
//! must be acquitted even though they were inside a piece that failed
//! verification.
//!
//! ## Scenarios
//!
//! 1. **Disconnect-rejoin: one corrupted block** — peer 0 alone
//!    delivers blocks of a piece, with one block corrupted. Peer 0
//!    disconnects mid-piece. Peers 1, 2 connect after, absorb the
//!    released blocks via `releaseBlocksForPeer` + `tryJoinExistingPiece`.
//!    Piece fails hash on first attempt (peer 0's bad data poisoned
//!    it). Re-download via peers 1+2 passes. Smart-ban Phase 2
//!    identifies peer 0 as the corruptor and bans peer 0's address.
//!    Peers 1, 2 NOT banned despite co-locating with peer 0 on the
//!    failed piece.
//!
//! 2. **Disconnect-rejoin: two-peer corruption** — peers 0 and 1
//!    each corrupt one block, deliver, disconnect. Peer 2 absorbs.
//!    After re-download, both 0 and 1 are banned; peer 2 not.
//!
//! 3. **Steady-state honest co-located peer (deferred)**:
//!    peers 0 and 1 stay connected through piece completion, share
//!    block delivery on the same piece, peer 0 corrupts one block.
//!    Hash fails on first attempt; re-download. Peer 0 banned, peer 1
//!    not banned. Tests Phase 2's discriminating power without
//!    relying on disconnect. This remains deferred until the harness
//!    can force deterministic same-piece co-contribution in that shape.
//!
//! ## Status
//!
//! Live coverage:
//!   * `runScenario` drives staged-connect ordering and per-peer
//!     corrupt_blocks config through `EventLoopOf(SimIO)`.
//!   * The disconnect-rejoin one-corrupt-block scenario is live and
//!     proves attribution survives peer-slot freeing via
//!     `BlockInfo.delivered_address`.
//!   * The remaining deferred scenarios need deterministic
//!     same-piece co-contribution from multiple corruptors or
//!     co-located honest peers, not just generic multi-source liveness.
//!
//! See `docs/multi-source-test-setup.md` for the full Phase 2B
//! scope.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const event_loop_mod = varuna.io.event_loop;
const SimPeer = varuna.sim.SimPeer;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;
const Sha1 = varuna.crypto.Sha1;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Bitfield = varuna.bitfield.Bitfield;
const BanList = varuna.net.ban_list.BanList;
const SmartBan = varuna.net.smart_ban.SmartBan;

// The remaining Phase 2B scenarios are deferred until the harness can
// force deterministic same-piece co-contribution for their shapes.
const deterministic_same_piece_contribution: bool = false;

const num_peers: u8 = 3;
const piece_count: u32 = 1;
// 256 KiB piece × 16 KiB blocks = 16 blocks per piece. Big enough
// that "deliver some blocks then disconnect" is exercisable, small
// enough that the round-trip (fail → re-download → pass) completes
// quickly within the SimIO tick budget.
const piece_size: u32 = 256 * 1024;
const block_size: u32 = 16 * 1024;
const blocks_per_piece: u32 = piece_size / block_size; // 16

const max_ticks: u32 = 4096;

fn syntheticAddr(idx: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 10, 0, 2, idx + 1 }, 0);
}

const full_bitfield: [1]u8 = .{0b1000_0000};

/// Per-peer setup for the Phase 2B scenarios.
const PeerSpec = struct {
    /// Tick at which `addConnectedPeerWithAddress` fires for this
    /// peer. Peers added at tick 0 are the eager joiners; staggered
    /// arrivals (tick > 0) model the "join after another peer
    /// disconnected" pattern. `null` means "don't add this peer".
    add_at_tick: ?u32,
    /// Tick at which the peer's `disconnect()` is called (i.e. the
    /// SimPeer-side fd close, simulating the peer leaving the swarm).
    /// `null` means "stay connected for the duration of the test".
    disconnect_at_tick: ?u32 = null,
    /// Block indices the peer corrupts when it serves them. Empty =
    /// honest peer.
    corrupt_blocks: []const u32 = &.{},
};

/// Build minimal bencoded metainfo for a 1-piece × 256 KiB torrent.
fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hash: *const [20]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name20:smartban_phase12.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces20:");
    try buf.appendSlice(allocator, piece_hash);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Build a SimPeer behavior from a PeerSpec.
fn behaviorFor(spec: PeerSpec) SimPeerBehavior {
    if (spec.corrupt_blocks.len == 0) return .{ .honest = {} };
    return .{ .corrupt_blocks = .{ .indices = spec.corrupt_blocks } };
}

const ScenarioResult = struct {
    piece_completed: bool,
    /// Per-peer ban observation, indexed by peer-spec position.
    banned: [num_peers]bool,
};

fn runScenario(seed: u64, specs: [num_peers]PeerSpec) !ScenarioResult {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── 1. Build canonical piece data + SHA-1 hash ─────────────
    var piece_data: [piece_size]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    // ── 2. Torrent metainfo + storage ──────────────────────────
    const torrent_bytes = try buildTorrentBytes(arena.allocator(), &piece_hash);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_root = try std.fs.path.join(arena.allocator(), &.{
        ".zig-cache", "tmp", &tmp.sub_path, "data",
    });

    const session = try Session.load(allocator, torrent_bytes, data_root);
    defer session.deinit(allocator);

    var store_init_io = try varuna.io.backend.initWithCapacity(allocator, 16);
    defer store_init_io.deinit();
    var store = try PieceStore.init(allocator, &session, &store_init_io);
    defer store.deinit();
    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    var empty_bf = try Bitfield.init(allocator, piece_count);
    defer empty_bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, piece_count, piece_size, piece_size, &empty_bf, 0);
    defer tracker.deinit(allocator);

    // ── 3. BanList + SmartBan, then EventLoop ──────────────────
    //
    // Declaration order matters: `defer` runs LIFO. The EL's
    // `deinit → drainRemainingCqes` can fire `processHashResults`
    // → `SmartBan.onPieceFailed` / `onPiecePassed` → `BanList.banIp`
    // for residual late CQEs. If smart_ban or ban_list is declared
    // AFTER el, their defer runs FIRST, freeing them while el.deinit
    // is still draining → UAF panic in the hashmap header() pointer
    // math. Declare ban_list and smart_ban FIRST so el.deinit
    // (which runs first because el is declared LAST) sees them
    // alive.
    //
    // Phase 0 EL test (`sim_smart_ban_eventloop_test.zig`) doesn't
    // hit this because Phase 0's `penalizePeerTrust` happens during
    // the main tick loop, not during teardown drain — but the
    // pattern is worth following uniformly in any test that wires
    // EL → BanList / SmartBan dependencies.
    var ban_list = BanList.init(allocator);
    defer ban_list.deinit();

    // SmartBan is the Phase 1+2 machinery — `snapshotAttribution`,
    // `onPieceFailed`, `onPiecePassed`. Without it, the EL only runs
    // Phase 0 (trust-points), which a disconnect-mid-piece corruptor
    // can escape (they leave before accumulating 4 failures). Phase
    // 2B's discriminating-power assertions specifically depend on
    // SmartBan being installed.
    var smart_ban = SmartBan.init(allocator);
    defer smart_ban.deinit();

    // Same `recv_latency_ns = 1ms` lockstep + `now_ns` advancement
    // pattern as the Phase 2A multi-source test. Larger
    // `recv_queue_capacity_bytes` and `pending_capacity` for the
    // round-trip workload (piece downloaded + hash-failed + re-
    // downloaded → roughly 2× the bytes of a single download).
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{
        .socket_capacity = num_peers * 2,
        .seed = seed,
        .recv_queue_capacity_bytes = 4 * 1024 * 1024,
        .pending_capacity = 8192,
        .faults = .{ .recv_latency_ns = 1_000_000 },
    });
    var el = try EL_SimIO.initBareWithIO(allocator, sim_io, 1);
    defer el.deinit();
    el.ban_list = &ban_list;
    el.smart_ban = &smart_ban;

    el.encryption_mode = .disabled;
    el.clock = varuna.runtime.Clock.simAtSecs(1_000_000);

    const downloader_peer_id = "-VR0001-sb12evloop00".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, downloader_peer_id);

    // ── 4. SimPeer setup per spec (don't connect yet) ──────────
    var rng = std.Random.DefaultPrng.init(seed ^ 0xdeadc0de);
    var peers: [num_peers]SimPeer = undefined;
    var seeder_fds: [num_peers]posix.fd_t = undefined;
    var downloader_fds: [num_peers]posix.fd_t = undefined;
    var slots: [num_peers]?u16 = .{null} ** num_peers;
    var connected: [num_peers]bool = .{false} ** num_peers;
    var disconnected: [num_peers]bool = .{false} ** num_peers;

    var i: u8 = 0;
    while (i < num_peers) : (i += 1) {
        const fds = try el.io.createSocketpair();
        seeder_fds[i] = fds[0];
        downloader_fds[i] = fds[1];

        peers[i] = SimPeer{
            .io = undefined,
            .fd = 0,
            .role = .seeder,
            .behavior = .{ .honest = {} },
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
            .fd = seeder_fds[i],
            .role = .seeder,
            .behavior = behaviorFor(specs[i]),
            .info_hash = session.metainfo.info_hash,
            .peer_id = [_]u8{i} ** 20,
            .piece_count = piece_count,
            .piece_size = piece_size,
            .bitfield = &full_bitfield,
            .piece_data = &piece_data,
            .rng = &rng,
            .block_mask = null,
        });
    }

    // ── 5. Drive ticks with staged connect/disconnect ──────────
    //
    // `posix.sched_yield()` after each tick gives the real
    // hasher OS thread CPU time even under parallel-test-runner
    // contention. Without the yield, the main loop's tight
    // iteration outpaces the hasher's SHA-1 computation and the
    // re-download → re-verify cycle that Phase 2B depends on
    // doesn't complete in time. Once `SimHasher` lands (STATUS
    // Next), the test becomes deterministic end-to-end.
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        // Trigger pending connects.
        var c: u8 = 0;
        while (c < num_peers) : (c += 1) {
            if (connected[c]) continue;
            const at = specs[c].add_at_tick orelse continue;
            if (ticks >= at) {
                slots[c] = try el.addConnectedPeerWithAddress(downloader_fds[c], tid, syntheticAddr(c));
                connected[c] = true;
            }
        }

        try el.tick();
        _ = std.os.linux.sched_yield(); // give the real hasher OS thread CPU time
        el.io.now_ns += 1_000_000;

        for (&peers) |*peer| {
            try peer.step(@as(u64, @intCast(el.clock.now())) * std.time.ns_per_s);
        }

        // Trigger pending disconnects.
        var d: u8 = 0;
        while (d < num_peers) : (d += 1) {
            if (disconnected[d] or !connected[d]) continue;
            const at = specs[d].disconnect_at_tick orelse continue;
            if (ticks >= at) {
                peers[d].disconnect();
                disconnected[d] = true;
            }
        }

        if (el.isPieceComplete(tid, 0)) break;
    }

    // ── 6. Drain phase ─────────────────────────────────────────
    //
    // Drain budget bumped from 256 → 4096 ticks to absorb the tail
    // end of in-flight piece-block recvs + hasher SHA work + the
    // re-download cycle for Phase 2B's hash-fail → re-verify path
    // when it lands close to the main-loop budget boundary.
    for (&peers, 0..) |*peer, idx| {
        if (!disconnected[idx]) peer.disconnect();
    }
    var drain_ticks: u32 = 0;
    while (drain_ticks < 4096) : (drain_ticks += 1) {
        const hasher_busy = if (el.hasher) |h| h.hasPendingWork() else false;
        const writes_pending = el.pending_writes.count() > 0;
        if (!hasher_busy and !writes_pending) break;
        try el.tick();
        _ = std.os.linux.sched_yield(); // give the real hasher OS thread CPU time
    }

    // ── 7. Collect outcomes ────────────────────────────────────
    var result: ScenarioResult = .{
        .piece_completed = el.isPieceComplete(tid, 0),
        .banned = .{ false, false, false },
    };
    var b: u8 = 0;
    while (b < num_peers) : (b += 1) {
        result.banned[b] = ban_list.isBanned(syntheticAddr(b));
    }
    return result;
}

// ── Harness smoke ──────────────────────────────────────────

test "phase 2B: scenario harness constructs three peers cleanly (smoke)" {
    // Pure smoke test: drive `runScenario` with all-honest, all-eager
    // peers and verify it builds, drives, and tears down cleanly.
    // Doesn't assert smart-ban behaviour — that's gated below.
    const specs: [num_peers]PeerSpec = .{
        .{ .add_at_tick = 0 },
        .{ .add_at_tick = 0 },
        .{ .add_at_tick = 0 },
    };
    const result = try runScenario(0xCAFE_F00D, specs);
    try testing.expect(result.piece_completed);
    // No corrupt peer in this smoke; nobody should be banned.
    for (result.banned) |b| try testing.expect(!b);
}

// ── Phase 2B scenarios ──────────────────────────────────────

test "phase 2B: disconnect-rejoin one-corrupt-block bans corruptor only" {
    // Disconnect-rejoin Phase 2B scenario:
    // - Peer 0 corrupts block 5; connects at tick 0; disconnects at
    //   tick ~30 (after delivering several blocks including block 5).
    // - Peers 1, 2 connect at tick 60 (after peer 0 disconnected).
    //   They absorb peer 0's released blocks via tryJoinExistingPiece
    //   and complete the piece with peer 0's bad data already mixed
    //   in.
    // - First piece-completion fails hash. SmartBan.onPieceFailed
    //   records per-block hashes attributed to peer 0 (for blocks
    //   peer 0 delivered) and peer 1/2 (for blocks they delivered).
    // - Crucially: peer 0's attribution survives peer 0's slot-free
    //   via the block_info.delivered_address field captured at
    //   receive time.
    // - Piece released; tryAssignPieces re-claims from peers 1, 2.
    // - Re-download passes hash. SmartBan.onPiecePassed compares per-
    //   block hashes against the records.
    // - Block 5's stored hash (peer 0's corrupt 0xcc bytes) differs
    //   from the actual block 5 hash → peer 0's address banned.
    // - Other blocks match → peers 1, 2 NOT banned.
    const specs: [num_peers]PeerSpec = .{
        .{
            .add_at_tick = 0,
            .disconnect_at_tick = 30,
            .corrupt_blocks = &.{5},
        },
        .{ .add_at_tick = 60 },
        .{ .add_at_tick = 60 },
    };
    const seeds = [_]u64{
        0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE,
        0x0F0F_0F0F, 0x1234_5678, 0xABCD_EF01, 0x9876_5432,
    };
    for (seeds) |seed| {
        const result = try runScenario(seed, specs);
        // Piece eventually verifies (re-download via 1+2 from clean
        // data, since peer 0's address was banned post-recompute).
        try testing.expect(result.piece_completed);
        // Peer 0 (corruptor) banned.
        try testing.expect(result.banned[0]);
        // Peers 1, 2 (acquitted) NOT banned despite co-locating with
        // peer 0 on the failed piece — this is the Phase 2B
        // discriminating power.
        try testing.expect(!result.banned[1]);
        try testing.expect(!result.banned[2]);
    }
}

test "phase 2B: disconnect-rejoin two-peer-corruption (deferred)" {
    // Two corruptors, one acquittee. Peers 0 and 1 each corrupt one
    // block then disconnect. Peer 2 absorbs all released blocks.
    // After re-download, peers 0 AND 1 are banned; peer 2 is not.
    //
    // Deferred until the harness can deterministically force both
    // corruptors to put their corrupted blocks on the wire before the
    // first hash failure. Otherwise the assertion can pass or fail
    // because one corruptor never actually contributed to the failed
    // piece.
    if (!deterministic_same_piece_contribution) return;

    const specs: [num_peers]PeerSpec = .{
        .{
            .add_at_tick = 0,
            .disconnect_at_tick = 30,
            .corrupt_blocks = &.{5},
        },
        .{
            .add_at_tick = 0,
            .disconnect_at_tick = 30,
            .corrupt_blocks = &.{9},
        },
        .{ .add_at_tick = 60 },
    };
    const seeds = [_]u64{ 0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE };
    for (seeds) |seed| {
        const result = try runScenario(seed, specs);
        try testing.expect(result.piece_completed);
        try testing.expect(result.banned[0]);
        try testing.expect(result.banned[1]);
        try testing.expect(!result.banned[2]);
    }
}

test "phase 2B: steady-state honest-co-located-peer (deferred)" {
    // Phase 2's archetypal discriminating-power case: peers 0 and 1
    // both stay connected through the failed piece's first
    // completion. Peer 0 corrupts block 5; peer 1 honest. After hash
    // fail and re-download, peer 0 is banned for block 5's mismatch;
    // peer 1 is NOT banned despite contributing blocks to the same
    // piece that peer 0 corrupted.
    //
    // Deferred for discriminating-power non-vacuity: peer 1 must
    // actually contribute honest blocks to the same failed piece.
    // Otherwise the "not banned" assertion only proves peer 1 was
    // absent from the per-block compare.
    if (!deterministic_same_piece_contribution) return;

    const specs: [num_peers]PeerSpec = .{
        .{
            .add_at_tick = 0,
            .corrupt_blocks = &.{5},
        },
        .{ .add_at_tick = 0 },
        .{ .add_at_tick = 0 },
    };
    const seeds = [_]u64{ 0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE };
    for (seeds) |seed| {
        const result = try runScenario(seed, specs);
        try testing.expect(result.piece_completed);
        try testing.expect(result.banned[0]);
        try testing.expect(!result.banned[1]);
        try testing.expect(!result.banned[2]);
    }
}

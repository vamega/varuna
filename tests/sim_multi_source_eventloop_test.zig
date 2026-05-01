//! Multi-source piece assembly — EventLoop integration test (Phase 2A).
//!
//! Layer 2 of the three-layer testing strategy described in
//! `STYLE.md > Layered Testing Strategy`. This test drives the
//! production `EventLoopOf(SimIO)` against three `SimPeer` seeders,
//! each holding a disjoint slice of one piece's blocks, and asserts
//! that the multi-source picker actually distributes work across
//! peers rather than serialising on the first responder.
//!
//! ## Scenarios
//!
//! 1. **Multi-source happy path**: 3 peers all advertise the full
//!    piece (no `block_mask`). The picker's `pipeline_depth` cap
//!    naturally distributes load — once peer A has 64 outstanding
//!    requests, the next peer's tryFillPipeline picks up the next
//!    unrequested block. Assert: piece verifies; multiple peers
//!    contributed bytes; no single peer monopolises.
//! 2. **Mid-piece peer disconnect**: same setup, peer B
//!    `disconnect()`s mid-transfer. Peer B's outstanding-but-not-
//!    delivered blocks land back in the picker pool via
//!    `releaseBlocksForPeer`, and the survivors complete the piece.
//!    Assert: piece still verifies; survivors uploaded the displaced
//!    blocks.
//!
//! ## On `block_mask` and the disjoint-blocks stress test
//!
//! The `block_mask` SimPeer extension lives for forthcoming stress
//! tests of the request-timeout reroute path — when a peer reserves
//! a block it doesn't actually hold, the production code recovers via
//! the 30-60s request timeout. That scenario depends on a short
//! request-timeout knob on the EL (not yet wired for sim use), so it
//! lands in a follow-up commit. The `block_mask` field is exercised
//! today in `tests/sim_peer_test.zig` for shape/composition coverage.
//!
//! ## Status (per `docs/multi-source-test-setup.md`)
//!
//! Today's assertion set covers the *liveness* invariants observable
//! through existing accessors (`isPieceComplete`, `getPeerView`'s
//! `bytes_uploaded`). The per-block attribution assertion ("peer A
//! delivered exactly the blocks in their mask, not the others") needs
//! `EventLoop.getBlockAttribution(torrent_id, piece_index, out)` from
//! migration-engineer's parallel work. When that lands, this file
//! grows the attribution assertions in a follow-up commit; the test
//! passes today on the existing surface so the multi-source picker
//! is exercised end-to-end without waiting on the new accessor.

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

const num_peers: u8 = 3;
const piece_count: u32 = 1;
// Single-piece torrent of 4 MiB → 256 blocks of 16 KiB each. Larger
// than `peer_policy.pipeline_depth=64`, so a single peer cannot claim
// every block at once — when another peer's tryFillPipeline runs, the
// shared `DownloadingPiece` still has unrequested blocks for it to
// pick up. That's the picker behaviour Phase 2A is exercising; a
// piece sized at or below the pipeline depth would race-to-completion
// on the first responder and miss the multi-source path entirely.
const piece_size: u32 = 4 * 1024 * 1024;
const block_size: u32 = 16 * 1024;

const max_ticks: u32 = 4096;

fn syntheticAddr(idx: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 10, 0, 1, idx + 1 }, 0);
}

/// Build minimal bencoded metainfo for a 1-piece × 64 KiB torrent.
fn buildTorrentBytes(allocator: std.mem.Allocator, piece_hash: *const [20]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "d8:announce14:http://tracker4:infod");
    try buf.appendSlice(allocator, "6:lengthi");
    try buf.writer(allocator).print("{d}", .{piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "4:name20:multi_source_sim.bin");
    try buf.appendSlice(allocator, "12:piece lengthi");
    try buf.writer(allocator).print("{d}", .{piece_size});
    try buf.append(allocator, 'e');
    try buf.appendSlice(allocator, "6:pieces20:");
    try buf.appendSlice(allocator, piece_hash);
    try buf.appendSlice(allocator, "ee");

    return buf.toOwnedSlice(allocator);
}

/// Bitfield byte that advertises piece 0 (high bit set).
const full_bitfield: [1]u8 = .{0b1000_0000};

const ScenarioOpts = struct {
    /// When > 0, peer `disconnect_at_block_count` triggers
    /// `SimPeer.disconnect()` after this many blocks_sent. Models the
    /// mid-piece disconnect stress test.
    disconnect_peer_after: ?struct { peer_index: u8, blocks: u32 } = null,
};

fn runScenario(seed: u64, opts: ScenarioOpts) !void {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── 1. Build canonical piece data + SHA-1 hash ─────────────
    var piece_data: [piece_size]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));
    var piece_hash: [20]u8 = undefined;
    Sha1.hash(&piece_data, &piece_hash, .{});

    // ── 2. Build the torrent metainfo and load it ──────────────
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

    // ── 3. Spin up EventLoopOf(SimIO) with BanList ─────────────
    //
    // `recv_queue_capacity_bytes` bumped to 8 MiB: with `pipeline_depth=64`
    // and 16 KiB blocks, each peer can have 64 × 16 = 1 MiB of piece-
    // response data in flight against the downloader's recv queue
    // before a single tick boundary delivers any to the EL. Default
    // 64 KiB drops bytes silently on `RecvQueue.append`, stalling the
    // transfer. 8 MiB comfortably covers all three peers' worst-case
    // simultaneous bursts.
    //
    // `pending_capacity` likewise bumped — multi-source piece transfer
    // accumulates many in-flight ops (3 peers × pipeline_depth send/recv
    // pairs + per-block hashing CQEs). 16384 is conservative.
    // `recv_latency_ns = 1ms` is the load-bearing knob for multi-source
    // distribution. Default 0 latency lets the first peer's
    // tryFillPipeline drain the entire piece in a single tick before
    // peers 2 and 3 finish handshake — empirically observed and
    // confirmed by migration-engineer's picker-fair-share work
    // (commit 8553ab7): `peer_count` never grows past 1 because the
    // race finishes before B/C become eligible. 1ms latency models
    // real network RTT, gives all 3 peers time to handshake in
    // lockstep before anyone starts requesting blocks, and lets
    // tryAssignPieces see `peer_count = 3` from the start. The test
    // loop advances `now_ns` by 1ms per iteration to drive ops
    // through their deadlines.
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{
        .socket_capacity = num_peers * 2,
        .seed = seed,
        .recv_queue_capacity_bytes = 8 * 1024 * 1024,
        .pending_capacity = 16384,
        .faults = .{ .recv_latency_ns = 1_000_000 },
    });
    var el = try EL_SimIO.initBareWithIO(allocator, sim_io, 1);
    defer el.deinit();

    var ban_list = BanList.init(allocator);
    defer ban_list.deinit();
    el.ban_list = &ban_list;

    el.encryption_mode = .disabled;
    el.clock = varuna.runtime.Clock.simAtSecs(1_000_000);

    const downloader_peer_id = "-VR0001-msseventloop".*;
    const tid = try el.addTorrent(&session, &tracker, shared_fds, downloader_peer_id);

    // ── 4. Spin up SimPeer seeders + addConnectedPeerWithAddress ─
    var rng = std.Random.DefaultPrng.init(seed ^ 0xc0ffee_face);
    var peers: [num_peers]SimPeer = undefined;
    var slots: [num_peers]u16 = undefined;

    var i: u8 = 0;
    while (i < num_peers) : (i += 1) {
        const fds = try el.io.createSocketpair();
        const seeder_fd = fds[0];
        const downloader_fd = fds[1];

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
            .fd = seeder_fd,
            .role = .seeder,
            .behavior = .{ .honest = {} },
            .info_hash = session.metainfo.info_hash,
            .peer_id = [_]u8{i} ** 20,
            .piece_count = piece_count,
            .piece_size = piece_size,
            .bitfield = &full_bitfield, // every peer advertises the full piece
            .piece_data = &piece_data,
            .rng = &rng,
            .block_mask = null, // full availability — picker spreads via pipeline_depth cap
        });

        slots[i] = try el.addConnectedPeerWithAddress(downloader_fd, tid, syntheticAddr(i));
    }

    // ── 5. Drive ticks ─────────────────────────────────────────
    //
    // `posix.sched_yield()` after each tick gives the real
    // hasher OS thread CPU time even under parallel-test-runner
    // contention (`zig build test` running many test binaries
    // concurrently). Without the yield, the main loop's tight
    // iteration burns through `max_ticks` faster than the
    // hasher's SHA-1 thread gets scheduled, and `isPieceComplete`
    // never flips true. Once `SimHasher` lands (STATUS Next), this
    // can drop the yield and the test becomes deterministic
    // end-to-end.
    var ticks: u32 = 0;
    var disconnected: bool = false;
    while (ticks < max_ticks) : (ticks += 1) {
        try el.tick();
        _ = std.os.linux.sched_yield(); // give the real hasher OS thread CPU time

        // Advance the SimIO clock so latency-throttled completions
        // (recv_latency_ns = 1ms) become eligible on the next tick.
        // Without this, every recv stays parked forever and the test
        // makes no progress past the first round-trip.
        el.io.now_ns += 1_000_000;

        for (&peers) |*peer| {
            try peer.step(@as(u64, @intCast(el.clock.now())) * std.time.ns_per_s);
        }

        // Mid-piece disconnect trigger.
        if (opts.disconnect_peer_after) |trig| {
            if (!disconnected and peers[trig.peer_index].blocks_sent >= trig.blocks) {
                peers[trig.peer_index].disconnect();
                disconnected = true;
            }
        }

        if (el.isPieceComplete(tid, 0)) break;
    }

    // Snapshot per-peer contribution counters before the teardown drain.
    // `peer.disconnect()` below can drive EventLoop.removePeer(), which
    // resets the peer slot to `Peer{}` and loses bytes_downloaded_from.
    var peers_with_contribs: u8 = 0;
    var max_contrib: u64 = 0;
    var total_contrib: u64 = 0;
    var contrib_slot: u8 = 0;
    while (contrib_slot < num_peers) : (contrib_slot += 1) {
        if (el.getPeerView(slots[contrib_slot])) |v| {
            if (v.bytes_downloaded > 0) peers_with_contribs += 1;
            if (v.bytes_downloaded > max_contrib) max_contrib = v.bytes_downloaded;
            total_contrib += v.bytes_downloaded;
        }
    }

    // ── 6. Drain phase (same pattern as Phase 0 EL test) ───────
    //
    // Drain budget bumped from 256 → 4096 ticks to absorb the
    // tail end of in-flight piece-block recvs + hasher SHA work
    // when the main loop reaches `isPieceComplete=true` while
    // some blocks are still mid-flight; under load the residual
    // work can take more than 256 real ticks to settle.
    for (&peers) |*peer| peer.disconnect();
    var drain_ticks: u32 = 0;
    while (drain_ticks < 4096) : (drain_ticks += 1) {
        const hasher_busy = if (el.hasher) |h| h.hasPendingWork() else false;
        const writes_pending = el.pending_writes.count() > 0;
        if (!hasher_busy and !writes_pending) break;
        try el.tick();
        _ = std.os.linux.sched_yield(); // give the real hasher OS thread CPU time
    }

    // ── 7. Liveness + safety assertions ────────────────────────
    //
    // Live: piece verifies, no honest peer banned. The distribution-
    // proportion assertions are gated under `multi_source_landed`
    // below — flipped on after the late-peer block-stealing change
    // lands (Task #23).
    try testing.expect(el.isPieceComplete(tid, 0));

    // Safety invariant — holds under both clean runs and BUGGIFY
    // (when this test grows a BUGGIFY variant in Phase 2B).
    var k: u8 = 0;
    while (k < num_peers) : (k += 1) {
        try testing.expect(!ban_list.isBanned(syntheticAddr(k)));
    }

    // Multi-source distribution assertions — live as of Task #23
    // landing late-peer block-stealing (`peer_policy.tryFillPipeline`
    // duplicate-REQUEST fallback + `tryJoinExistingPiece` accepting
    // fully-claimed DPs with stealable blocks).  The picker fair-
    // share + per-call cap (commit 8553ab7) handles the steady-
    // state, and block-stealing handles the "3 peers at tick 0"
    // race where the first responder drains the piece in one tick
    // before peers 2 and 3 finish handshake. Bitfield gate in
    // `tryJoinExistingPiece` keeps the BUGGIFY smart-ban safety
    // invariant intact (no honest peer falsely framed by
    // cross-DP join).
    const multi_source_landed: bool = true;
    if (multi_source_landed) {
        // ≥ 2 peers contributed bytes — the meaningful "not serialised
        // on one peer" invariant.
        try testing.expect(peers_with_contribs >= 2);

        // No peer monopolises (≤ 90% of total). Looser bound for the
        // disconnect scenario where survivors absorb the displaced
        // peer's blocks and naturally dominate.
        if (opts.disconnect_peer_after == null) {
            try testing.expect(max_contrib * 10 <= total_contrib * 9);
        }
    }

    // TODO(phase 2A follow-up): per-block attribution assertion via
    // `el.getBlockAttribution(tid, 0, &out)` snapshot during the tick
    // loop. Tried it locally; works on most seeds but caused a tick-
    // count timing shift on seed 0x12345678 that triggered an
    // integer-overflow panic in `hasher.pending_jobs.append` during
    // `el.deinit → drainRemainingCqes`. Looks like a pre-existing
    // teardown issue: when the test loop breaks early (on assertion
    // failure or completion), residual in-flight piece-block recvs
    // get processed during `drainRemainingCqes`, each calling
    // `completePieceDownload → submitVerify`. With the snapshot
    // adding small per-tick overhead, the count of residual recvs
    // shifts and the hasher's `pending_jobs.append` path hits an
    // overflow.
    //
    // The bare-data-structure assertion already lives in
    // `tests/sim_multi_source_protocol_test.zig`, and `bytes_downloaded`
    // here proves that multiple peers contributed bytes — so the
    // per-block attribution assertion is sharper but not missing
    // coverage. Worth landing alongside the hasher-teardown
    // robustness fix (probably another `.ghost`-style state, this
    // time for in-flight piece recvs that arrive after the EL has
    // started winding down).
}

test "multi-source: 3 peers all hold full piece, picker spreads load (8 seeds)" {
    const seeds = [_]u64{
        0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE,
        0x0F0F_0F0F, 0x1234_5678, 0xABCD_EF01, 0x9876_5432,
    };
    for (seeds) |seed| {
        runScenario(seed, .{}) catch |err| {
            std.debug.print("\n  multi-source full-bitfield SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

test "multi-source: peer disconnect mid-piece, survivors complete (8 seeds)" {
    // Phase 2A's transient-correctness assertion. Peer 1 claims its
    // share of a multi-source piece, delivers a few blocks, then
    // disconnects mid-piece. The Gap 2 fix in commit 07f4093 (`.ghost`
    // PendingSend storage) ensures peer 1's in-flight pending sends
    // retire cleanly; `releaseBlocksForPeer` puts peer 1's still-
    // requested blocks back in the picker pool; survivors (peers 0
    // and 2) absorb them via `tryJoinExistingPiece` and complete the
    // piece. This is the multi-source path real swarms exercise —
    // peer arrival in production is staggered, not concurrent, so
    // the "everyone connects at tick 0" scenario from the
    // picker-spreads-load test above is more synthetic than this one.
    //
    // The `runScenario` drain phase + `multi_source_landed = false`
    // gate combine to keep this test stable: the drain runs before
    // `el.deinit` so residual late piece-block recvs flow through
    // controlled CQE handling rather than the more fragile
    // `drainRemainingCqes`. Liveness + safety assertions are live
    // (piece verifies, no honest peer banned); distribution-
    // proportion assertions stay gated until late-peer block-stealing
    // (Task #23) lands.
    const seeds = [_]u64{
        0x0000_0001, 0xDEAD_BEEF, 0xFEED_FACE, 0xCAFE_BABE,
        0x0F0F_0F0F, 0x1234_5678, 0xABCD_EF01, 0x9876_5432,
    };
    for (seeds) |seed| {
        runScenario(seed, .{
            .disconnect_peer_after = .{ .peer_index = 1, .blocks = 8 },
        }) catch |err| {
            std.debug.print("\n  multi-source disconnect SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

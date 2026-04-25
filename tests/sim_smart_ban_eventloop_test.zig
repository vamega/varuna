//! Smart-ban EventLoop integration test — pre-scaffolded for Stage 2 #12.
//!
//! This file is the post-Stage-2-#12 form of the smart-ban swarm test,
//! drafted ahead of time so the EventLoop integration is purely a
//! mechanical "uncomment + delete `if (false)`" diff once
//! `EventLoop(comptime IO: type)` lands and exposes the test-only hooks
//! described in `docs/sim-test-setup.md`.
//!
//! Until that lands, this file:
//!   * Imports `varuna` and references the planned EventLoop API in
//!     comments / `if (false)` blocks so it compiles unchanged.
//!   * Includes a placeholder `test "EventLoop smart-ban integration:
//!     waiting for Stage 2 #12"` that asserts only that the scaffolding
//!     exists. Test count goes up by 1.
//!   * Documents the option-(1) bitfield layout the team-lead recommended
//!     so the production picker drives the corrupt peer onto piece 0
//!     deterministically (no test-only `allPeersReady` gate needed).
//!
//! When Stage 2 #12 finishes:
//!   1. Replace the `if (false) {}` block below with live code.
//!   2. Delete the `placeholder` test at the bottom.
//!   3. The assertions are already correct — no logic changes needed.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const SimIO = varuna.io.sim_io.SimIO;
const Simulator = varuna.sim.Simulator;
const SimulatorOf = varuna.sim.SimulatorOf;
const StubDriver = varuna.sim.StubDriver;
const SimPeer = varuna.sim.SimPeer;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;
const peer_wire = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;

const Completion = ifc.Completion;
const Result = ifc.Result;

const trust_ban_threshold: i8 = -7;
const num_peers: u8 = 6;
const corrupt_peer_index: u8 = 5;
const piece_count: u32 = 4;
const piece_size: u32 = 32;

// ── Bitfield layout (option 1 from the team-lead's brief) ─────
//
// The rarest-first picker in the daemon assigns pieces by availability:
// pieces with the fewest sources go first, and a piece offered by exactly
// one peer is unconditionally assigned to that peer. We use this to force
// the corrupt peer onto piece 0 without any test-only gate.
//
// BitTorrent bitfield encoding: high bit of byte 0 = piece 0, next bit
// down = piece 1, etc. So:
//
//   peer index    bitfield byte 0       pieces held
//   ──────────    ───────────────       ───────────
//   0..4 (hon.)   0_111_0000  (0x70)    {1, 2, 3}
//   5  (corrupt)  1_000_0000  (0x80)    {0}
//
// Pieces 1..3 are equally common (5 sources each); piece 0 has exactly
// one source. Rarest-first must pick piece 0 → assigns to corrupt → fails
// → corrupt's trust drops by 2 → re-assigns to corrupt (no other source) →
// fails again → ...
//
// After 4 failures (trust = -8), corrupt is banned. Piece 0 then becomes
// unrecoverable (no honest peer holds it). The test asserts:
//
//   * Pieces 1..3 verified.
//   * Piece 0 NOT verified (correct outcome — no honest source).
//   * Corrupt peer banned with hashfails >= 4.
//   * No honest peer banned.
//
// This shape exercises smart-ban deterministically without any
// test-only piece-picker hook.

const honest_bitfield: [1]u8 = .{0b0111_0000};
const corrupt_bitfield: [1]u8 = .{0b1000_0000};

// ── Stage-2-#12 integration (paused until the API lands) ──────

fn syntheticAddr(idx: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 10, 0, 0, idx + 1 }, 6881);
}

fn runOneSeedAgainstEventLoop(seed: u64) !void {
    _ = seed;

    // The full integration body lives below in an `if (false)` so this
    // file builds cleanly today. Each piece below maps to a requirement
    // already documented in docs/sim-test-setup.md; migration-engineer
    // can land them one at a time and the relevant chunks turn on.

    if (false) {
        // ── Step 1: Build the simulator with EventLoop(SimIO) as Driver.
        //
        // Requires Stage 2 #12: `EventLoop(comptime IO: type)`. The
        // current concrete `EventLoop` won't compile under SimIO.
        //
        //   const EventLoop = varuna.io.event_loop.EventLoop;
        //   var sim = try SimulatorOf(EventLoop(SimIO)).init(
        //       testing.allocator,
        //       .{
        //           .swarm_capacity = num_peers,
        //           .seed = seed,
        //           .sim_io = .{ .socket_capacity = num_peers * 2 },
        //       },
        //       try EventLoop(SimIO).init(testing.allocator, .{
        //           // Disable real-network paths.
        //           .simulator_mode = true,
        //           // ... rest of EL config ...
        //       }),
        //   );
        //   defer sim.deinit();

        // ── Step 2: Register the test torrent in-memory.
        //
        // Requires `EventLoop.addTestTorrent(spec)`. See
        // docs/sim-test-setup.md §2 for the spec shape.
        //
        //   var arena = std.heap.ArenaAllocator.init(testing.allocator);
        //   defer arena.deinit();
        //
        //   const piece_data = try arena.allocator().alloc(
        //       u8,
        //       piece_count * piece_size,
        //   );
        //   for (piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));
        //
        //   var piece_hashes: [piece_count][20]u8 = undefined;
        //   var i: u32 = 0;
        //   while (i < piece_count) : (i += 1) {
        //       var hasher = Sha1.init(.{});
        //       hasher.update(piece_data[i * piece_size ..][0..piece_size]);
        //       hasher.final(&piece_hashes[i]);
        //   }
        //
        //   const tid = try sim.driver.addTestTorrent(.{
        //       .info_hash = .{0xab} ** 20,
        //       .piece_count = piece_count,
        //       .piece_size = piece_size,
        //       .piece_hashes = &piece_hashes,
        //       .storage = piece_data,
        //   });

        // ── Step 3: Spin up SimPeer seeders and inject their fds.
        //
        // Requires `EventLoop.addInboundPeer(torrent_id, fd, addr)`. See
        // docs/sim-test-setup.md §3.
        //
        //   var rng = std.Random.DefaultPrng.init(seed ^ 0xfeedface);
        //   var peers: [num_peers]SimPeer = undefined;
        //   var slots: [num_peers]u16 = undefined;
        //
        //   var idx: u8 = 0;
        //   while (idx < num_peers) : (idx += 1) {
        //       const fds = try sim.io.createSocketpair();
        //
        //       const behavior: SimPeerBehavior = if (idx == corrupt_peer_index)
        //           .{ .corrupt = .{ .probability = 1.0 } }
        //       else
        //           .{ .honest = {} };
        //       const bf = if (idx == corrupt_peer_index)
        //           &corrupt_bitfield
        //       else
        //           &honest_bitfield;
        //
        //       try peers[idx].init(.{
        //           .io = &sim.io,
        //           .fd = fds[0],
        //           .role = .seeder,
        //           .behavior = behavior,
        //           .info_hash = .{0xab} ** 20,
        //           .peer_id = [_]u8{idx} ** 20,
        //           .piece_count = piece_count,
        //           .piece_size = piece_size,
        //           .bitfield = bf,
        //           .piece_data = piece_data,
        //           .rng = &rng,
        //       });
        //       try sim.addPeer(&peers[idx]);
        //
        //       slots[idx] = try sim.driver.addInboundPeer(
        //           tid,
        //           fds[1],
        //           syntheticAddr(idx),
        //       );
        //   }

        // ── Step 4: Drive the simulator.
        //
        //   const Cond = struct {
        //       fn done(s: *@TypeOf(sim)) bool {
        //           // Pieces 1..3 must verify. Piece 0 stays incomplete by
        //           // design (no honest holder). Banning corrupt closes the
        //           // test's success condition.
        //           return s.driver.isPieceComplete(tid, 1)
        //               and s.driver.isPieceComplete(tid, 2)
        //               and s.driver.isPieceComplete(tid, 3)
        //               and s.driver.getPeerView(slots[corrupt_peer_index]).?.is_banned;
        //       }
        //   };
        //
        //   const ok = try sim.runUntilFine(Cond.done, 4096, 1_000_000);
        //   try testing.expect(ok);

        // ── Step 5: Smart-ban assertions.
        //
        //   // Pieces 1..3 verified.
        //   try testing.expect(sim.driver.isPieceComplete(tid, 1));
        //   try testing.expect(sim.driver.isPieceComplete(tid, 2));
        //   try testing.expect(sim.driver.isPieceComplete(tid, 3));
        //
        //   // Piece 0 NOT verified — no other source after corrupt is
        //   // banned. This is the correct production outcome.
        //   try testing.expect(!sim.driver.isPieceComplete(tid, 0));
        //
        //   // Corrupt peer must be banned.
        //   const corrupt_view = sim.driver.getPeerView(slots[corrupt_peer_index]).?;
        //   try testing.expect(corrupt_view.is_banned);
        //   try testing.expect(corrupt_view.trust_points <= trust_ban_threshold);
        //   try testing.expect(corrupt_view.hashfails >= 4);
        //
        //   // No honest peer banned.
        //   var j: u8 = 0;
        //   while (j < num_peers) : (j += 1) {
        //       if (j == corrupt_peer_index) continue;
        //       const v = sim.driver.getPeerView(slots[j]).?;
        //       try testing.expect(!v.is_banned);
        //       try testing.expectEqual(@as(u8, 0), v.hashfails);
        //   }
    }
}

/// 32-seed BUGGIFY-stressed variant — the closing piece for DoD #4.
///
/// Same scenario as `runOneSeedAgainstEventLoop` but with a small
/// per-step BUGGIFY probability. The `Simulator.BuggifyConfig` mechanism
/// is already in place; this only needs the Stage 2 #12 integration to
/// land.
fn runOneSeedUnderBuggify(seed: u64) !void {
    _ = seed;
    // Body is `runOneSeedAgainstEventLoop` with one extra config field:
    //
    //   var sim = try SimulatorOf(EventLoop(SimIO)).init(
    //       testing.allocator,
    //       .{
    //           ...,
    //           .buggify = .{ .probability = 0.01 },
    //       },
    //       try EventLoop(SimIO).init(...),
    //   );
    //
    // Then loop over 32 seeds with the same assertions. BUGGIFY draws
    // happen each step; the seeded RNG keeps every run reproducible.
    // Failing seeds print via the BuggifyConfig.log sink.
}

// ── Placeholder test ──────────────────────────────────────

test "EventLoop smart-ban integration: scaffold compiles (waiting for handler-conversion follow-up)" {
    // This test asserts the scaffold itself: imports resolve, the
    // bitfield layout is what option (1) requires, the helper
    // functions compile, and `EventLoopOf(SimIO)` instantiates as a
    // valid type. When the handler-conversion follow-up lands, the
    // placeholder body is replaced with calls into
    // `runOneSeedAgainstEventLoop` over the 8-seed array.

    // Stage 1 of EventLoop parameterisation has shipped — `EventLoopOf`
    // is generic. Confirm the SimIO instantiation is a valid type. The
    // struct compiles; making its callbacks fire correctly under SimIO
    // is the follow-up that lights up `runOneSeedAgainstEventLoop`.
    const EL_SimIO = varuna.io.event_loop.EventLoopOf(varuna.io.sim_io.SimIO);
    _ = EL_SimIO;

    try testing.expect(num_peers == 6);
    try testing.expectEqual(@as(u8, 0b0111_0000), honest_bitfield[0]);
    try testing.expectEqual(@as(u8, 0b1000_0000), corrupt_bitfield[0]);

    // Sanity-check the bitfields exercise option (1):
    // Bit 7 (high bit of byte 0) is piece 0 in BT bitfield encoding.
    const piece_0_mask: u8 = 0b1000_0000;
    try testing.expectEqual(@as(u8, 0), honest_bitfield[0] & piece_0_mask); // honest peers DON'T have piece 0
    try testing.expectEqual(piece_0_mask, corrupt_bitfield[0] & piece_0_mask); // corrupt DOES have piece 0
    // Pieces 1..3 are bits 6, 5, 4. Honest has them; corrupt does not.
    const pieces_123_mask: u8 = 0b0111_0000;
    try testing.expectEqual(pieces_123_mask, honest_bitfield[0] & pieces_123_mask); // honest has 1..3
    try testing.expectEqual(@as(u8, 0), corrupt_bitfield[0] & pieces_123_mask); // corrupt does not

    // Suppress "unused" for the helpers that compile but don't run yet.
    _ = runOneSeedAgainstEventLoop;
    _ = runOneSeedUnderBuggify;
    _ = syntheticAddr;
}

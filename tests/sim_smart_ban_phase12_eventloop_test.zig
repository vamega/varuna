//! Smart-ban Phase 1 + 2 — EventLoop integration test (Phase 2B).
//!
//! Layer 2 + 3 of the three-layer testing strategy described in
//! `STYLE.md > Layered Testing Strategy`. Builds on the Phase 2A
//! multi-source assembly test (`sim_multi_source_eventloop_test.zig`)
//! by adding deterministic per-block corruption to one peer in a
//! multi-source piece — exercising the smart-ban Phase 1 (per-block
//! SHA-1 attribution on hash failure) and Phase 2 (ban-targeting on
//! re-download pass) machinery in `src/net/smart_ban.zig` and
//! `src/io/peer_policy.zig:smartBanCorruptPeers`.
//!
//! ## Discriminating power vs Phase 0
//!
//! Phase 0 BUGGIFY test (in `sim_smart_ban_eventloop_test.zig`)
//! asserted: an honest peer in the *same swarm* as a corrupt peer is
//! NOT banned. The honest peers there contributed *different pieces*
//! than the corrupt peer; the smart-ban discriminator was "this peer
//! never sent a hash-failing piece, so no penalty".
//!
//! Phase 2B test asserts a sharper invariant: an honest peer who
//! *contributed an honest block to the same piece a corrupt peer also
//! contributed to* is NOT banned. The smart-ban Phase 2 discriminator
//! has to walk per-block hashes from the failed piece and identify
//! which peer's block(s) caused the mismatch — the honest peer's
//! blocks must be acquitted even though they were inside a piece
//! that failed verification.
//!
//! ## Scenarios
//!
//! 1. **One corrupted block in multi-source**: peer B sends block 5
//!    corrupted; peers A and C send their blocks cleanly. Piece fails
//!    hash. After re-download, only peer B is banned.
//! 2. **Two peers each corrupt one block**: peers A and B each
//!    corrupt one of their attributed blocks; both banned, peer C
//!    not banned.
//! 3. **Safety-under-faults (BUGGIFY 32 seeds)**: scenario 1 with
//!    randomized faults. Same safety invariant: an honest peer is
//!    never banned regardless of fault sequence.
//!
//! ## Status
//!
//! This file is the Phase 2B scaffold landed alongside the Phase 2A
//! test infrastructure. The scenarios are described but the test
//! bodies are gated until migration-engineer confirms:
//! (a) the round-trip (fail → re-download → pass) drives cleanly
//!     through the existing piece-tracker re-claim mechanism, or
//!     whether the test needs an explicit two-phase driver, and
//! (b) the `getBlockAttribution` accessor lands so post-completion
//!     attribution can be asserted (rather than just the ban outcome).
//!
//! See `docs/multi-source-test-setup.md` for the full Phase 2B test
//! scope. The single placeholder test below pins the bitfield-layout
//! sanity invariant and proves the file compiles + lights up under
//! `zig build test`. Real scenarios land in a follow-up commit once
//! migration-engineer's API is in place.

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const event_loop_mod = varuna.io.event_loop;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;

test "phase 2B scaffold: SimPeer corrupt_blocks behaviour compiles" {
    // Sanity: the new `Behavior.corrupt_blocks: { indices }` variant
    // is reachable from the test harness. Catches regressions where
    // the union variant is renamed or its struct shape changes.
    const corrupt: SimPeerBehavior = .{ .corrupt_blocks = .{ .indices = &.{5} } };
    switch (corrupt) {
        .corrupt_blocks => |params| try testing.expectEqual(@as(usize, 1), params.indices.len),
        else => return error.WrongBehaviorVariant,
    }
}

test "phase 2B scaffold: EventLoopOf(SimIO) instantiates for the Phase 2B scenarios" {
    // Pin that `EventLoopOf(SimIO)` still wraps cleanly with the
    // settings the Phase 2B tests will use. Mirrors the same
    // checkpoint in `sim_smart_ban_eventloop_test.zig`'s scaffold
    // before that file's body lit up.
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(testing.allocator, .{ .socket_capacity = 8 });
    var el = try EL_SimIO.initBareWithIO(testing.allocator, sim_io, 0);
    defer el.deinit();
    _ = el.peers.len;
}

// TODO(phase 2B, after migration-engineer confirms round-trip + `getBlockAttribution`):
//
//   test "smart-ban phase 1-2: one corrupted block in multi-source (8 seeds)"
//   test "smart-ban phase 1-2: two peers each corrupt one block (8 seeds)"
//   test "smart-ban phase 1-2 BUGGIFY: 32 seeds, p=0.02 fault injection, safety-only"
//
// Per `docs/multi-source-test-setup.md`. Each test:
//
//   * Stages 3+ peers; one or more with `Behavior.corrupt_blocks`.
//   * Honest peers advertise the same piece so the EL re-claims after
//     hash-fail and the second pass exercises `SmartBan.onPiecePassed`.
//   * Asserts `ban_list.isBanned(corrupt_addr)` for each offender,
//     `!ban_list.isBanned(honest_addr)` for each acquitted peer.
//   * BUGGIFY variant adds `FaultConfig` per-op + per-tick injection
//     with the same vacuous-pass guard from
//     `sim_smart_ban_eventloop_test.zig`.

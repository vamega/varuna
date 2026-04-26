//! Multi-source piece assembly — protocol-only algorithm test (Phase 2A).
//!
//! Layer 1 of the three-layer testing strategy described in
//! `STYLE.md > Layered Testing Strategy`. This test exercises the bare
//! `DownloadingPiece` state machine that backs Phase 2A's multi-source
//! assembly: per-block attribution, multi-peer block reservation,
//! release-on-disconnect, dedup invariants. No EventLoop, no SimIO, no
//! async hashing — just the data structure under direct manipulation,
//! so any bug in `markBlockRequested` / `markBlockReceived` /
//! `releaseBlocksForPeer` / `nextUnrequestedBlock` surfaces here at
//! O(microsecond) cost.
//!
//! The integration test in `sim_multi_source_eventloop_test.zig`
//! exercises the same machinery in the production EL pipeline; the
//! BUGGIFY case in `sim_smart_ban_phase12_eventloop_test.zig` covers
//! safety under randomized faults. Read those after this one.

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const dp_mod = varuna.io.downloading_piece;
const DownloadingPiece = dp_mod.DownloadingPiece;
const BlockState = dp_mod.BlockState;

// Three peer slots — chosen so the test can keep them in mind by name
// rather than as numbers.
const slot_a: u16 = 1;
const slot_b: u16 = 2;
const slot_c: u16 = 3;

// Stub address for tests that don't care about per-peer attribution
// (the protocol-level algorithm doesn't depend on addresses; only the
// EL-side smart-ban Phase 2 path reads `BlockInfo.delivered_address`).
const test_address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

const piece_size: u32 = 16 * 4 * 1024; // 64 KiB → 4 blocks of 16 KiB
const block_count: u16 = 4;

fn makeDP(allocator: std.mem.Allocator) !*DownloadingPiece {
    return dp_mod.createDownloadingPiece(allocator, 0, 0, piece_size, block_count);
}

test "multi-source: three peers reserve disjoint blocks via nextUnrequestedBlock" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    // Each peer's tryFillPipeline-equivalent: grab next unrequested,
    // mark it requested with our slot. Three iterations (rotating through
    // the peers) should cover three of four blocks.
    const peers = [_]u16{ slot_a, slot_b, slot_c };
    for (peers) |slot| {
        const block = dp.nextUnrequestedBlock() orelse break;
        try testing.expect(dp.markBlockRequested(block, slot));
    }

    // The remaining block is still .none.
    try testing.expectEqual(@as(u16, 1), dp.unrequestedCount());

    // Each peer holds exactly one .requested block.
    try testing.expectEqual(@as(u16, 1), dp.requestedCountForPeer(slot_a));
    try testing.expectEqual(@as(u16, 1), dp.requestedCountForPeer(slot_b));
    try testing.expectEqual(@as(u16, 1), dp.requestedCountForPeer(slot_c));

    // Per-block attribution is set — this is the core Phase 2A invariant.
    var attributed_to_a: u16 = 0;
    var attributed_to_b: u16 = 0;
    var attributed_to_c: u16 = 0;
    for (dp.block_infos) |bi| {
        if (bi.state == .requested) {
            switch (bi.peer_slot) {
                slot_a => attributed_to_a += 1,
                slot_b => attributed_to_b += 1,
                slot_c => attributed_to_c += 1,
                else => return error.UnexpectedSlot,
            }
        }
    }
    try testing.expectEqual(@as(u16, 1), attributed_to_a);
    try testing.expectEqual(@as(u16, 1), attributed_to_b);
    try testing.expectEqual(@as(u16, 1), attributed_to_c);
}

test "multi-source: markBlockRequested rejects re-reservation by another peer" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    try testing.expect(dp.markBlockRequested(0, slot_a));
    // Peer B can't steal block 0 from peer A.
    try testing.expect(!dp.markBlockRequested(0, slot_b));
    // Attribution stays with A.
    try testing.expectEqual(slot_a, dp.block_infos[0].peer_slot);
}

test "multi-source: markBlockReceived records sender, not requester" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    try testing.expect(dp.markBlockRequested(0, slot_a));

    // In endgame mode (or unsolicited delivery), peer B might deliver
    // a block that peer A had reserved. The attribution updates to the
    // peer that actually sent the bytes — that's the one we'd hold
    // accountable for the data quality.
    const block_data = [_]u8{ 0x42, 0x43 };
    try testing.expect(dp.markBlockReceived(0, slot_b, test_address, 0, &block_data));
    try testing.expectEqual(slot_b, dp.block_infos[0].peer_slot);
    try testing.expectEqual(BlockState.received, dp.block_infos[0].state);
}

test "multi-source: releaseBlocksForPeer returns only that peer's requested blocks" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    try testing.expect(dp.markBlockRequested(0, slot_a));
    try testing.expect(dp.markBlockRequested(1, slot_b));
    try testing.expect(dp.markBlockRequested(2, slot_a));
    // Peer B receives block 1 — that block is now `.received`, not
    // `.requested`. release for B should NOT touch it.
    const block_data = [_]u8{0xff};
    try testing.expect(dp.markBlockReceived(1, slot_b, test_address, 16 * 1024, &block_data));

    // Peer A disconnects — release blocks 0 and 2.
    dp.releaseBlocksForPeer(slot_a);

    // Blocks 0 and 2: back to .none.
    try testing.expectEqual(BlockState.none, dp.block_infos[0].state);
    try testing.expectEqual(BlockState.none, dp.block_infos[2].state);
    // Block 1: still .received from peer B.
    try testing.expectEqual(BlockState.received, dp.block_infos[1].state);
    try testing.expectEqual(slot_b, dp.block_infos[1].peer_slot);
    // Block 3: still .none, never touched.
    try testing.expectEqual(BlockState.none, dp.block_infos[3].state);

    // Now another peer can claim the released blocks.
    try testing.expect(dp.markBlockRequested(0, slot_c));
    try testing.expectEqual(slot_c, dp.block_infos[0].peer_slot);
}

test "multi-source: markBlockReceived rejects duplicate delivery" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    const block_data = [_]u8{0xaa};
    try testing.expect(dp.markBlockRequested(0, slot_a));
    try testing.expect(dp.markBlockReceived(0, slot_a, test_address, 0, &block_data));
    // Endgame mode: peer B also delivers block 0. Should be rejected as
    // duplicate (first delivery wins; second one's bytes are discarded).
    try testing.expect(!dp.markBlockReceived(0, slot_b, test_address, 0, &block_data));
    // Attribution remains with the first sender.
    try testing.expectEqual(slot_a, dp.block_infos[0].peer_slot);
}

test "multi-source: full-piece happy path attributes every block" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    // Round-robin assignment: A=0, B=1, C=2, A=3.
    const assignments = [_]struct { slot: u16, block: u16 }{
        .{ .slot = slot_a, .block = 0 },
        .{ .slot = slot_b, .block = 1 },
        .{ .slot = slot_c, .block = 2 },
        .{ .slot = slot_a, .block = 3 },
    };
    for (assignments) |a| {
        try testing.expect(dp.markBlockRequested(a.block, a.slot));
    }

    // All received in order.
    const block_data = [_]u8{0x99};
    for (assignments) |a| {
        const offset: u32 = @as(u32, a.block) * 16 * 1024;
        try testing.expect(dp.markBlockReceived(a.block, a.slot, test_address, offset, &block_data));
    }
    try testing.expect(dp.isComplete());

    // Attribution survives completion: a Phase 2 smart-ban snapshot
    // would walk block_infos and record per-block sender addresses.
    try testing.expectEqual(slot_a, dp.block_infos[0].peer_slot);
    try testing.expectEqual(slot_b, dp.block_infos[1].peer_slot);
    try testing.expectEqual(slot_c, dp.block_infos[2].peer_slot);
    try testing.expectEqual(slot_a, dp.block_infos[3].peer_slot);
}

test "multi-source: nextUnrequestedBlock returns null when all reserved" {
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    var i: u16 = 0;
    while (i < block_count) : (i += 1) {
        try testing.expect(dp.markBlockRequested(i, slot_a));
    }
    try testing.expectEqual(@as(?u16, null), dp.nextUnrequestedBlock());
    try testing.expectEqual(@as(u16, 0), dp.unrequestedCount());
}

test "multi-source: piece-completion lifecycle preserves attribution" {
    // Models the Phase 2A end-state: piece completed by 3 peers
    // contributing different blocks. The attribution snapshot
    // (`peer_policy.snapshotAttributionForSmartBan`) walks
    // `block_infos[i].peer_slot` and produces the
    // `[]?std.net.Address` payload that `SmartBan.snapshotAttribution`
    // stores. This test confirms the snapshot input is intact.
    const allocator = testing.allocator;
    const dp = try makeDP(allocator);
    defer dp_mod.destroyDownloadingPieceFull(allocator, dp);

    const block_data = [_]u8{0x11};
    // A: blocks 0, 1
    _ = dp.markBlockRequested(0, slot_a);
    _ = dp.markBlockRequested(1, slot_a);
    _ = dp.markBlockReceived(0, slot_a, test_address, 0, &block_data);
    _ = dp.markBlockReceived(1, slot_a, test_address, 16 * 1024, &block_data);
    // B: block 2
    _ = dp.markBlockRequested(2, slot_b);
    _ = dp.markBlockReceived(2, slot_b, test_address, 32 * 1024, &block_data);
    // C: block 3
    _ = dp.markBlockRequested(3, slot_c);
    _ = dp.markBlockReceived(3, slot_c, test_address, 48 * 1024, &block_data);

    try testing.expect(dp.isComplete());

    // Walk the block_infos array — this is what
    // snapshotAttributionForSmartBan does.
    var snapshot: [block_count]u16 = undefined;
    for (dp.block_infos, 0..) |bi, idx| {
        snapshot[idx] = bi.peer_slot;
    }
    try testing.expectEqual(slot_a, snapshot[0]);
    try testing.expectEqual(slot_a, snapshot[1]);
    try testing.expectEqual(slot_b, snapshot[2]);
    try testing.expectEqual(slot_c, snapshot[3]);
}

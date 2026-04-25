//! Smart-ban EventLoop integration test.
//!
//! Drives the production `EventLoop` against `SimIO` with 5 honest
//! SimPeer seeders + 1 corrupt SimPeer seeder. Asserts the smart-ban
//! Phase 0 algorithm bans the corrupt peer (`trust_points <= -7`,
//! `hashfails >= 4`) without false-positive bans on honest peers, while
//! pieces 1..3 verify cleanly.
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
//!
//! Asserts:
//!   * Pieces 1..3 verified.
//!   * Piece 0 NOT verified (no honest source after corrupt is banned).
//!   * Corrupt peer banned with `hashfails >= 4`.
//!   * No honest peer banned and no honest peer has any hashfails.
//!
//! Loops over 8 different seeds (DoD #3).
//!
//! ## Status
//!
//! Currently the test body is gated on Task #14 (peer_policy.zig
//! parameterisation). Until that lands, `EventLoopOf(SimIO).tick()`
//! doesn't compile because `peer_policy.processHashResults` /
//! `tryAssignPieces` / etc. still take `*EventLoop` directly. Once #14
//! ships, the `if (false)` guard at the top of `runOneSeedAgainstEventLoop`
//! flips to `if (true)` and the seed loop activates.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const SimIO = varuna.io.sim_io.SimIO;
const event_loop_mod = varuna.io.event_loop;
const SimPeer = varuna.sim.SimPeer;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;
const peer_wire = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;
const Session = varuna.torrent.session.Session;
const PieceStore = varuna.storage.writer.PieceStore;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const Bitfield = varuna.bitfield.Bitfield;

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
    try buf.appendSlice(allocator, "4:name15:smart_ban_sim.bin");
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

fn runOneSeedAgainstEventLoop(seed: u64) !void {
    // GATED: re-enable the body when Task #14 (peer_policy.zig
    // parameterisation) lands. Today `EventLoopOf(SimIO).tick()` doesn't
    // compile because the per-tick scheduler family
    // (`processHashResults` / `tryAssignPieces` / `recalculateUnchokes`
    // etc.) still takes `*EventLoop` directly. Migration-engineer is
    // converting; my body below is what activates once they do.
    if (true) return;

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
    var store = try PieceStore.init(allocator, &session);
    defer store.deinit();

    const shared_fds = try store.fileHandles(allocator);
    defer allocator.free(shared_fds);

    var empty_bf = try Bitfield.init(allocator, piece_count);
    defer empty_bf.deinit(allocator);

    var tracker = try PieceTracker.init(allocator, piece_count, piece_size, piece_size, &empty_bf, 0);
    defer tracker.deinit(allocator);

    // ── 4. Spin up EventLoopOf(SimIO) ─────────────────────────────
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{
        .socket_capacity = num_peers * 2,
        .seed = seed,
    });
    var el = try EL_SimIO.initBareWithIO(allocator, sim_io, 0);
    defer el.deinit();

    el.encryption_mode = .disabled;
    el.clock = .{ .sim = 1_000_000 }; // 1 ms past zero so time-gated logic opens

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

        slots[i] = try el.addInboundPeer(tid, downloader_fd, syntheticAddr(i));
    }

    // ── 7. Drive ticks until corrupt is banned + pieces 1..3 done ──
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        try el.tick();

        // Step each SimPeer (honest peers no-op; future slow-behaviour
        // peers would advance their throttle here).
        for (&peers) |*peer| {
            try peer.step(@as(u64, @intCast(el.clock.now())) * std.time.ns_per_s);
        }

        const corrupt_banned = if (el.getPeerView(slots[corrupt_peer_index])) |v| v.is_banned else false;
        const all_target_pieces_done = el.isPieceComplete(tid, 1) and
            el.isPieceComplete(tid, 2) and
            el.isPieceComplete(tid, 3);
        if (corrupt_banned and all_target_pieces_done) break;
    }

    // ── 8. Smart-ban assertions ──────────────────────────────────

    // Pieces 1..3 must verify (multiple honest sources for each).
    try testing.expect(el.isPieceComplete(tid, 1));
    try testing.expect(el.isPieceComplete(tid, 2));
    try testing.expect(el.isPieceComplete(tid, 3));

    // Piece 0 must NOT verify — its only source is the corrupt peer,
    // who got banned. This is the correct production outcome.
    try testing.expect(!el.isPieceComplete(tid, 0));

    // Corrupt peer banned with hashfails >= 4 (4 failures × -2 = -8 ≤ -7).
    const corrupt_view = el.getPeerView(slots[corrupt_peer_index]).?;
    try testing.expect(corrupt_view.is_banned);
    try testing.expect(corrupt_view.trust_points <= trust_ban_threshold);
    try testing.expect(corrupt_view.hashfails >= 4);

    // No honest peer banned, none with hashfails.
    var j: u8 = 0;
    while (j < num_peers) : (j += 1) {
        if (j == corrupt_peer_index) continue;
        const v = el.getPeerView(slots[j]).?;
        try testing.expect(!v.is_banned);
        try testing.expectEqual(@as(u8, 0), v.hashfails);
    }
}

test "smart-ban EventLoop integration: 5 honest + 1 corrupt over 8 seeds (gated on Task #14)" {
    // Bitfield-layout sanity: catches drift if somebody "fixes" the
    // option (1) layout and silently breaks the rarest-first guarantee.
    const piece_0_mask: u8 = 0b1000_0000;
    try testing.expectEqual(@as(u8, 0), honest_bitfield[0] & piece_0_mask);
    try testing.expectEqual(piece_0_mask, corrupt_bitfield[0] & piece_0_mask);

    // EventLoopOf(SimIO) instantiates and `initBareWithIO` runs cleanly.
    // (`tick()` is gated on Task #14.)
    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    var el = try EL_SimIO.initBareWithIO(testing.allocator, sim_io, 0);
    defer el.deinit();
    _ = el.peers.len;

    // Ready-to-fire seed loop. Today `runOneSeedAgainstEventLoop` is
    // gated; once Task #14 (peer_policy.zig parameterisation) ships,
    // flip the early-return inside it and these 8 seeds activate.
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
        runOneSeedAgainstEventLoop(seed) catch |err| {
            std.debug.print("\n  SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

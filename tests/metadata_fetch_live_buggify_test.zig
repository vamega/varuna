//! Live-pipeline BUGGIFY harness for `AsyncMetadataFetchOf(SimIO)`.
//!
//! Same 32-seed shape as `tests/recheck_live_buggify_test.zig` and the
//! smart-ban EventLoop BUGGIFY test, but driving the BEP 9 metadata
//! fetch state machine instead. Per-tick `SimIO.injectRandomFault`
//! plus per-op `FaultConfig` (recv 0.005, send 0.005) over 32
//! deterministic seeds.
//!
//! ## Why this catches things the foundation tests can't
//!
//! `tests/metadata_fetch_test.zig` covers:
//!   * empty peer list → fast-finish
//!   * 100% connect fault → drain peers and finish
//!   * legacy fd → handshake send returns 0 → drain peers
//!   * happy path with one fully-scripted peer → assembler completes
//!
//! What it doesn't cover:
//!   * a peer sends valid handshakes but recv errors mid-extension-handshake
//!     (slot must release, free buffers, advance to next peer)
//!   * partial send loop runs into `BrokenPipe` mid-frame (state machine
//!     must not double-free buffers)
//!   * BUGGIFY mutates a piece-data recv result → assembler doesn't
//!     advance, fetch fails over to another peer with `assembler.reset`
//!     happening on hash-verify failure paths
//!
//! With 5 scripted peers (more than `max_slots = 3`) the state machine
//! refills slots after fault-induced failures, so the per-tick fault
//! density doesn't deterministically prevent all peers from completing.
//!
//! ## Safety invariants asserted
//!
//! For every (seed × fault sequence):
//!   * the on_complete callback fires (no hung fetch)
//!   * if `result_bytes != null`, `len == info_dict_size` (no torn copy)
//!   * if `result_bytes != null`, first/last byte match the expected
//!     info dict (the SHA-1 verify path actually ran)
//!   * `peers_attempted >= 1` (we exercised at least the connect path)
//!
//! Liveness — every seed completes with metadata — is *informational*:
//! sufficiently dense fault injection can knock out every peer before
//! any can deliver a complete piece. The summary line prints the
//! split so a regression that drops the success rate to zero (e.g.
//! a state machine that doesn't recover from any fault) is visible.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const ut_metadata = varuna.net.ut_metadata;
const ext = varuna.net.extensions;
const pw = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;
const posix = std.posix;

const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

/// Same canonical seed list as `tests/recheck_live_buggify_test.zig`
/// and `tests/sim_smart_ban_eventloop_test.zig`. Failing seeds reproduce
/// with the same hex prefix in any harness's diagnostics.
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

const max_ticks: u32 = 4096;
const num_peers: u32 = 5;
const info_dict_size: u32 = 256;

/// Build the scripted byte stream a single peer responds with.
/// Must be deterministic so all 5 peers in this harness can replay
/// the same protocol against the fetcher.
fn buildScriptedPeerResponses(
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    peer_handshake_id: [20]u8,
    info_bytes: []const u8,
) ![]u8 {
    const peer_ut_metadata_id: u8 = 2;
    const metadata_size: u32 = @intCast(info_bytes.len);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // BT handshake reply.
    try out.append(allocator, pw.protocol_length);
    try out.appendSlice(allocator, pw.protocol_string);
    var reserved = [_]u8{0} ** 8;
    reserved[ext.reserved_byte] |= ext.reserved_mask;
    try out.appendSlice(allocator, &reserved);
    try out.appendSlice(allocator, &info_hash);
    try out.appendSlice(allocator, &peer_handshake_id);

    // Extension handshake reply.
    var ext_payload_dict = std.ArrayList(u8).empty;
    defer ext_payload_dict.deinit(allocator);
    try ext_payload_dict.appendSlice(allocator, "d1:md11:ut_metadatai");
    try ext_payload_dict.writer(allocator).print("{d}", .{peer_ut_metadata_id});
    try ext_payload_dict.appendSlice(allocator, "ee13:metadata_sizei");
    try ext_payload_dict.writer(allocator).print("{d}", .{metadata_size});
    try ext_payload_dict.appendSlice(allocator, "e1:pi6881e1:v6:varunae");
    const ext_payload = ext_payload_dict.items;

    const ext_hs_msg_len: u32 = @intCast(2 + ext_payload.len);
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, ext_hs_msg_len, .big);
    try out.appendSlice(allocator, &len_be);
    try out.append(allocator, ext.msg_id);
    try out.append(allocator, ext.handshake_sub_id);
    try out.appendSlice(allocator, ext_payload);

    // ut_metadata data response (piece 0).
    const data_header = try ut_metadata.encodeData(allocator, 0, metadata_size);
    defer allocator.free(data_header);
    const data_msg_len: u32 = @intCast(2 + data_header.len + info_bytes.len);
    std.mem.writeInt(u32, &len_be, data_msg_len, .big);
    try out.appendSlice(allocator, &len_be);
    try out.append(allocator, ext.msg_id);
    try out.append(allocator, ext.local_ut_metadata_id);
    try out.appendSlice(allocator, data_header);
    try out.appendSlice(allocator, info_bytes);

    return out.toOwnedSlice(allocator);
}

const SeedOutcome = struct {
    completed: bool,
    had_metadata: bool,
    result_len: usize,
    first_byte: u8,
    last_byte: u8,
    peers_attempted: u32,
    buggify_hits: u32,
    ticks: u32,
};

fn runOneSeed(seed: u64, info_bytes: *const [info_dict_size]u8, info_hash: [20]u8) !SeedOutcome {
    const allocator = testing.allocator;
    const peer_handshake_id = [_]u8{0xCC} ** 20;

    // Build the scripted response stream once; each peer replays it
    // identically.
    var scripted_buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer scripted_buf.deinit(allocator);
    const scripted = try buildScriptedPeerResponses(
        allocator,
        info_hash,
        peer_handshake_id,
        info_bytes,
    );
    defer allocator.free(scripted);

    // SimIO with per-op fault injection. With ~3-5 ops per peer and
    // 5 peers (15-25 ops total per seed) we want a fault rate where
    // some seeds succeed unhindered and others see recovery activity.
    // 0.05 each puts the expected fault count at ~1 per seed; combined
    // with the per-tick BUGGIFY roll the harness exercises the
    // releaseSlot → tryNextPeer → connectPeer chain on most seeds.
    var sim_io = try SimIO.init(allocator, .{
        .seed = seed,
        .faults = .{
            .recv_error_probability = 0.05,
            .send_error_probability = 0.05,
        },
    });

    // Pre-allocate `num_peers` socketpairs and pre-load each fetcher-side
    // queue with the scripted response. Enqueue all 5 fetcher fds so
    // each `io.socket()` consumes one in the order peers are tried.
    var i: u32 = 0;
    while (i < num_peers) : (i += 1) {
        const pair = try sim_io.createSocketpair();
        try sim_io.enqueueSocketResult(pair[0]);
        try sim_io.pushSocketRecvBytes(pair[0], scripted);
    }

    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
        result_len: usize = 0,
        first_byte: u8 = 0,
        last_byte: u8 = 0,
        peers_attempted: u32 = 0,
    };
    var ctx = Ctx{};

    var peers_buf: [num_peers]std.net.Address = undefined;
    var p: u32 = 0;
    while (p < num_peers) : (p += 1) {
        peers_buf[p] = std.net.Address.initIp4(.{ 127, 0, 0, @intCast(p + 1) }, @intCast(6881 + p));
    }

    el.startMetadataFetch(
        info_hash,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers_buf,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
                c.peers_attempted = mf.peers_attempted;
                if (mf.result_bytes) |rb| {
                    c.result_len = rb.len;
                    if (rb.len > 0) {
                        c.first_byte = rb[0];
                        c.last_byte = rb[rb.len - 1];
                    }
                }
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };

    // Drive ticks with per-tick BUGGIFY injection. Use a separate RNG
    // so the inject decision is deterministic per seed without
    // perturbing SimIO's internal heap probes.
    var rng = std.Random.DefaultPrng.init(seed ^ 0xfeed_face);
    var buggify_hits: u32 = 0;
    var ticks: u32 = 0;
    while (ticks < max_ticks and !ctx.completed) : (ticks += 1) {
        if (rng.random().float(f32) < 0.05) {
            if (el.io.injectRandomFault(&rng)) |_| {
                buggify_hits += 1;
            }
        }
        try el.io.tick(0);
    }

    el.cancelMetadataFetch();

    return .{
        .completed = ctx.completed,
        .had_metadata = ctx.had_metadata,
        .result_len = ctx.result_len,
        .first_byte = ctx.first_byte,
        .last_byte = ctx.last_byte,
        .peers_attempted = ctx.peers_attempted,
        .buggify_hits = buggify_hits,
        .ticks = ticks,
    };
}

test "AsyncMetadataFetchOf(SimIO) BUGGIFY: happy path with recv/send faults over 32 seeds" {
    // Build the canonical info dict + hash once; reused across all seeds.
    var info_bytes: [info_dict_size]u8 = undefined;
    for (&info_bytes, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var info_hash: [20]u8 = undefined;
    Sha1.hash(&info_bytes, &info_hash, .{});

    var completed_seeds: u32 = 0;
    var seeds_with_metadata: u32 = 0;
    var seeds_with_hits: u32 = 0;
    var total_buggify_hits: u32 = 0;
    var total_peers_attempted: u32 = 0;

    for (seeds) |seed| {
        const outcome = runOneSeed(seed, &info_bytes, info_hash) catch |err| {
            std.debug.print(
                "\n  METADATA LIVE BUGGIFY seed=0x{x} FAILED: {any}\n",
                .{ seed, err },
            );
            return err;
        };

        // Safety: callback must always fire (no hung fetch).
        try testing.expect(outcome.completed);

        // Safety: at least one peer was attempted.
        try testing.expect(outcome.peers_attempted >= 1);
        try testing.expect(outcome.peers_attempted <= num_peers);

        // Safety: if metadata was delivered, the bytes are exactly
        // what the scripted peer was loaded with.
        if (outcome.had_metadata) {
            try testing.expectEqual(@as(usize, info_dict_size), outcome.result_len);
            try testing.expectEqual(info_bytes[0], outcome.first_byte);
            try testing.expectEqual(info_bytes[info_dict_size - 1], outcome.last_byte);
            seeds_with_metadata += 1;
        }

        if (outcome.completed) completed_seeds += 1;
        if (outcome.buggify_hits > 0) seeds_with_hits += 1;
        total_buggify_hits += outcome.buggify_hits;
        total_peers_attempted += outcome.peers_attempted;
    }

    std.debug.print(
        "\n  METADATA LIVE BUGGIFY summary: {d}/{d} seeds completed, " ++
            "{d}/{d} delivered metadata, {d}/{d} with buggify hits, " ++
            "total {d} buggify hits, total {d} peers attempted\n",
        .{
            completed_seeds,     seeds.len,
            seeds_with_metadata, seeds.len,
            seeds_with_hits,     seeds.len,
            total_buggify_hits,  total_peers_attempted,
        },
    );

    // Anti-vacuous-pass: at least one seed must have actually delivered
    // metadata (otherwise the test isn't exercising the success path).
    try testing.expect(seeds_with_metadata > 0);
}

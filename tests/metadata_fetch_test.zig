//! AsyncMetadataFetchOf(SimIO) integration tests.
//!
//! Drives the parameterised metadata-fetch state machine end-to-end
//! through `EventLoopOf(SimIO)`. These tests force the second
//! instantiation (`AsyncMetadataFetchOf(SimIO)`) through the
//! typechecker and exercise both error edges and the happy path:
//!
//!   * no-peer fast-fail
//!   * connect-error retry-then-finish
//!   * all-peers-fail-handshake-send (legacy fd send returns 0 bytes)
//!   * happy-path: scripted peer replies with a valid info dictionary
//!     and `verifyAndComplete` fires
//!
//! The happy-path test is enabled by the SimIO socket lifecycle
//! refactor in commit 55d4111: `connectPeer` now submits via
//! `self.io.socket()` instead of `posix.socket()`, so a SimIO
//! `enqueueSocketResult` + `pushSocketRecvBytes` pair can route the
//! fetcher to a `createSocketpair` half pre-loaded with scripted BT
//! handshake / extension handshake / ut_metadata data responses.

const std = @import("std");
const varuna = @import("varuna");
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const metadata_handler = varuna.io.metadata_handler;
const ut_metadata = varuna.net.ut_metadata;
const ext = varuna.net.extensions;
const pw = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;
const posix = std.posix;

const tick_budget: u32 = 256;

test "AsyncMetadataFetchOf(SimIO): no peers finishes immediately" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xCAFE_FEED });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
    };
    var ctx = Ctx{};

    // No peers → start() must call finish(false) synchronously.
    const peers = [_]std.net.Address{};
    try el.startMetadataFetch(
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
            }
        }.cb,
        @ptrCast(&ctx),
    );

    // The no-peer path fires the callback synchronously inside start();
    // no ticks needed. Assert the result.
    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);
    try std.testing.expect(el.metadata_fetch.?.done);

    el.cancelMetadataFetch();
    try std.testing.expect(el.metadata_fetch == null);
}

test "AsyncMetadataFetchOf(SimIO): connect-error fault drains all peers and finishes" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    // 100% connect-error probability — every `self.io.connect(...)` returns
    // error.ConnectionRefused. The state machine must release each slot
    // and try the next peer until peers are exhausted, then `finish(false)`.
    const sim_io = try SimIO.init(allocator, .{
        .seed = 0xDEAD_BEEF,
        .faults = .{ .connect_error_probability = 1.0 },
    });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
        peers_attempted: u32 = 0,
    };
    var ctx = Ctx{};

    // Five peers — more than `max_slots` (3) so we exercise the
    // connect → fail → tryNextPeer → connect refill loop.
    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
        std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 6883),
        std.net.Address.initIp4(.{ 127, 0, 0, 4 }, 6884),
        std.net.Address.initIp4(.{ 127, 0, 0, 5 }, 6885),
    };

    el.startMetadataFetch(
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
                c.peers_attempted = mf.peers_attempted;
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        // posix.socket() may fail in some sandboxes; that's not a
        // statement about AsyncMetadataFetchOf's correctness.
        if (err == error.SystemResources or err == error.PermissionDenied) {
            return error.SkipZigTest;
        }
        return err;
    };

    // Drive ticks via SimIO until the fetch completes. The connect
    // completion fires immediately (deadline 0) on the next tick.
    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);
    try std.testing.expectEqual(@as(u32, peers.len), ctx.peers_attempted);

    el.cancelMetadataFetch();
}

test "AsyncMetadataFetchOf(SimIO): legacy-fd send path causes all peers to fail" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    // No fault injection — every socket() and connect() succeeds. But
    // the fd returned by `self.io.socket()` is a synthetic SimIO fd
    // (from `synthetic_fd_base = 100_000`), which is NOT in SimIO's
    // socket pool, so `slotForFd` returns null and both `recv` and
    // `send` go through the "legacy fd: zero-byte success" path.
    // `send` returning 0 is treated as failure by the state machine
    // (`if (res <= 0) ... releaseSlot; tryNextPeer`), so each peer
    // fails after handshake send. With three peers, the state machine
    // cycles through all three slots and finishes false.
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xC0DE_C0DE });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
    };
    var ctx = Ctx{};

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
        std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 6883),
    };

    el.startMetadataFetch(
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        if (err == error.SystemResources or err == error.PermissionDenied) {
            return error.SkipZigTest;
        }
        return err;
    };

    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);

    el.cancelMetadataFetch();
}

test "AsyncMetadataFetchOf(SimIO): cancel drains parked recv before freeing fetch" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    var sim_io = try SimIO.init(allocator, .{
        .seed = 0xCACE_1A7E,
        .faults = .{
            .delayed_close_cqe_min_ticks = 1,
            .delayed_close_cqe_max_ticks = 1,
        },
        .max_ops_per_tick = 1,
    });

    const pair = try sim_io.createSocketpair();
    try sim_io.enqueueSocketResult(pair[0]);

    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
    };

    try el.startMetadataFetch(
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        null,
        null,
    );

    var ticks: u32 = 0;
    while (ticks < tick_budget) : (ticks += 1) {
        const mf = el.metadata_fetch orelse return error.UnexpectedMetadataFetchEnd;
        if (mf.slots[0].state == .handshake_recv) break;
        try el.io.tick(0);
    }
    try std.testing.expect(ticks < tick_budget);

    el.cancelMetadataFetch();
    try std.testing.expect(el.metadata_fetch == null);

    var drain_ticks: u32 = 0;
    while (drain_ticks < 4) : (drain_ticks += 1) {
        try el.io.tick(0);
    }
}

// ── Helper: build a scripted peer's response stream ──────────
//
// The metadata fetcher sees the peer as an opaque byte stream.
// Pre-build the entire response (BT handshake reply, extension
// handshake reply, ut_metadata data response) so the SimIO recv
// queue can deliver it across the fetcher's recv submissions.
//
// Returns a heap-allocated buffer the caller must free.
fn buildScriptedPeerResponses(
    allocator: std.mem.Allocator,
    info_hash: [20]u8,
    peer_handshake_id: [20]u8,
    info_bytes: []const u8,
) ![]u8 {
    const peer_ut_metadata_id: u8 = 2; // arbitrary non-zero
    const metadata_size: u32 = @intCast(info_bytes.len);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // ── BT handshake reply (68 bytes) ───────────────────────
    try out.append(allocator, pw.protocol_length);
    try out.appendSlice(allocator, pw.protocol_string);
    var reserved = @as([8]u8, @splat(0));
    reserved[ext.reserved_byte] |= ext.reserved_mask;
    try out.appendSlice(allocator, &reserved);
    try out.appendSlice(allocator, &info_hash);
    try out.appendSlice(allocator, &peer_handshake_id);

    // ── Extension handshake reply ──────────────────────────
    // The peer advertises its own ut_metadata ID and the metadata
    // size. The fetcher will send pieces requests using this ID.
    var ext_payload_buf: [256]u8 = undefined;
    var ext_payload_dict = std.ArrayList(u8).empty;
    defer ext_payload_dict.deinit(allocator);
    try ext_payload_dict.appendSlice(allocator, "d1:md11:ut_metadatai");
    var fbs = std.io.fixedBufferStream(&ext_payload_buf);
    try fbs.writer().print("{d}", .{peer_ut_metadata_id});
    try ext_payload_dict.appendSlice(allocator, fbs.getWritten());
    try ext_payload_dict.appendSlice(allocator, "ee13:metadata_sizei");
    fbs = std.io.fixedBufferStream(&ext_payload_buf);
    try fbs.writer().print("{d}", .{metadata_size});
    try ext_payload_dict.appendSlice(allocator, fbs.getWritten());
    try ext_payload_dict.appendSlice(allocator, "e1:pi6881e1:v6:varunae");
    const ext_payload = ext_payload_dict.items;

    const ext_hs_msg_len: u32 = @intCast(2 + ext_payload.len); // msg_id + sub_id + payload
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, ext_hs_msg_len, .big);
    try out.appendSlice(allocator, &len_be);
    try out.append(allocator, ext.msg_id);
    try out.append(allocator, ext.handshake_sub_id);
    try out.appendSlice(allocator, ext_payload);

    // ── ut_metadata data response (piece 0) ────────────────
    // The peer uses our advertised local_ut_metadata_id when
    // sending data TO us.
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

test "AsyncMetadataFetchOf(SimIO): happy-path scripted peer delivers verified info dict" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

    // Tiny info dictionary: the fetcher treats it as opaque bytes
    // and only verifies the SHA-1. A 256-byte payload covers the
    // single-piece path (≤ metadata_piece_size = 16 KiB).
    var info_bytes: [256]u8 = undefined;
    for (&info_bytes, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var info_hash: [20]u8 = undefined;
    Sha1.hash(&info_bytes, &info_hash, .{});

    const peer_handshake_id = @as([20]u8, @splat(0xCC));

    var sim_io = try SimIO.init(allocator, .{ .seed = 0xFADE_FACE });
    // Allocate the socketpair BEFORE moving sim_io into the EventLoop.
    // The EventLoop owns the SimIO instance after `initBareWithIO`,
    // so we hand it the prepared pair / queues via `el.io.*`.
    const pair = try sim_io.createSocketpair();
    const fetcher_fd = pair[0];

    const scripted = try buildScriptedPeerResponses(
        allocator,
        info_hash,
        peer_handshake_id,
        &info_bytes,
    );
    defer allocator.free(scripted);

    try sim_io.enqueueSocketResult(fetcher_fd);
    try sim_io.pushSocketRecvBytes(fetcher_fd, scripted);

    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
        result_len: usize = 0,
        result_first_byte: u8 = 0,
        result_last_byte: u8 = 0,
    };
    var ctx = Ctx{};

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
    };

    el.startMetadataFetch(
        info_hash,
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
                if (mf.result_bytes) |rb| {
                    c.result_len = rb.len;
                    if (rb.len > 0) {
                        c.result_first_byte = rb[0];
                        c.result_last_byte = rb[rb.len - 1];
                    }
                }
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };

    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(ctx.had_metadata);
    try std.testing.expectEqual(info_bytes.len, ctx.result_len);
    try std.testing.expectEqual(info_bytes[0], ctx.result_first_byte);
    try std.testing.expectEqual(info_bytes[info_bytes.len - 1], ctx.result_last_byte);

    el.cancelMetadataFetch();
}

test "AsyncMetadataFetchOf(SimIO): completion drains parked peers after callback destroys fetch" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

    var info_bytes: [256]u8 = undefined;
    for (&info_bytes, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var info_hash: [20]u8 = undefined;
    Sha1.hash(&info_bytes, &info_hash, .{});

    const peer_handshake_id = @as([20]u8, @splat(0xCC));
    const scripted = try buildScriptedPeerResponses(
        allocator,
        info_hash,
        peer_handshake_id,
        &info_bytes,
    );
    defer allocator.free(scripted);

    var sim_io = try SimIO.init(allocator, .{
        .seed = 0xD3F3_44ED,
        .faults = .{
            .delayed_close_cqe_min_ticks = 1,
            .delayed_close_cqe_max_ticks = 1,
        },
        .max_ops_per_tick = 1,
    });

    const fast_pair = try sim_io.createSocketpair();
    try sim_io.enqueueSocketResult(fast_pair[0]);
    try sim_io.pushSocketRecvBytes(fast_pair[0], scripted);

    const slow_pair_a = try sim_io.createSocketpair();
    try sim_io.enqueueSocketResult(slow_pair_a[0]);

    const slow_pair_b = try sim_io.createSocketpair();
    try sim_io.enqueueSocketResult(slow_pair_b[0]);

    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
        destroyed_in_callback: bool = false,
    };
    var ctx = Ctx{};

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
        std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 6883),
    };

    try el.startMetadataFetch(
        info_hash,
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
                mf.destroy();
                c.destroyed_in_callback = true;
            }
        }.cb,
        @ptrCast(&ctx),
    );

    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(ctx.had_metadata);
    try std.testing.expect(ctx.destroyed_in_callback);

    el.metadata_fetch = null;

    var drain_ticks: u32 = 0;
    while (drain_ticks < 8) : (drain_ticks += 1) {
        try el.io.tick(0);
    }
}

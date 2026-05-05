//! SimPeer protocol tests.
//!
//! These exercise the seeder-side SimPeer driven by a manual test-side
//! "downloader" that submits raw wire bytes through the partner end of a
//! SimIO socketpair. We avoid the EventLoop dependency here — those tests
//! land once Stage 2 finishes the EventLoop migration and the simulator
//! can drive a real downloader against SimPeer seeders.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const SimIO = varuna.io.sim_io.SimIO;
const SimPeer = varuna.sim.SimPeer;
const peer_wire = varuna.net.peer_wire;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Test fixtures ─────────────────────────────────────────

const RxCtx = struct {
    /// Set before priming the first recv so the callback can re-arm.
    io: ?*SimIO = null,
    fd: posix.fd_t = -1,
    completion: ?*Completion = null,
    bytes: [128 * 1024]u8 = undefined,
    received: usize = 0,
    finished: bool = false,
    err: ?anyerror = null,
};

/// Prime an auto-rearming recv on `fd` against `ctx`. Subsequent bytes
/// from the partner accumulate into `ctx.bytes`.
fn primeRecv(io: *SimIO, fd: posix.fd_t, c: *Completion, ctx: *RxCtx) !void {
    ctx.io = io;
    ctx.fd = fd;
    ctx.completion = c;
    try io.recv(.{ .fd = fd, .buf = ctx.bytes[ctx.received..] }, c, ctx, rxCallback);
}

fn rxCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const ctx: *RxCtx = @ptrCast(@alignCast(ud.?));
    switch (result) {
        .recv => |r| {
            const n = r catch |e| {
                ctx.err = e;
                ctx.finished = true;
                return .disarm;
            };
            ctx.received += n;
            if (n == 0) {
                ctx.finished = true;
                return .disarm;
            }
        },
        else => return .disarm,
    }
    // Re-arm into the unread tail.
    if (ctx.received < ctx.bytes.len and ctx.io != null and ctx.completion != null) {
        ctx.io.?.recv(
            .{ .fd = ctx.fd, .buf = ctx.bytes[ctx.received..] },
            ctx.completion.?,
            ctx,
            rxCallback,
        ) catch {
            ctx.finished = true;
        };
    }
    return .disarm; // re-armed manually above
}

const TxCtx = struct {
    sent: usize = 0,
    err: ?anyerror = null,
};

fn txCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const ctx: *TxCtx = @ptrCast(@alignCast(ud.?));
    switch (result) {
        .send => |r| {
            const n = r catch |e| {
                ctx.err = e;
                return .disarm;
            };
            ctx.sent = n;
        },
        else => {},
    }
    return .disarm;
}

/// Drive `tick` until either `cond()` returns true or `max_steps`
/// iterations elapse. Returns true if `cond` succeeded.
fn runUntil(io: *SimIO, comptime cond: fn (ctx: *RxCtx) bool, ctx: *RxCtx, max_steps: u32) !bool {
    var i: u32 = 0;
    while (i < max_steps) : (i += 1) {
        if (cond(ctx)) return true;
        try io.advance(1_000_000); // 1ms per step
    }
    return cond(ctx);
}

fn parseHandshake(bytes: []const u8) !struct { info_hash: [20]u8, peer_id: [20]u8 } {
    if (bytes.len < 68) return error.TooShort;
    if (bytes[0] != peer_wire.protocol_length) return error.BadHandshake;
    if (!std.mem.eql(u8, bytes[1..20], peer_wire.protocol_string)) return error.BadHandshake;
    var info_hash: [20]u8 = undefined;
    var peer_id: [20]u8 = undefined;
    @memcpy(&info_hash, bytes[28..48]);
    @memcpy(&peer_id, bytes[48..68]);
    return .{ .info_hash = info_hash, .peer_id = peer_id };
}

// ── Tests ─────────────────────────────────────────────────

test "SimPeer seeder responds to handshake with handshake + bitfield" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(0xfeedface);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const seeder_peer_id: [20]u8 = @splat(0x53);
    const downloader_peer_id: [20]u8 = @splat(0x44);
    const piece_count: u32 = 4;
    const piece_size: u32 = 1024;
    var bitfield: [1]u8 = .{0xf0}; // all 4 pieces present
    var piece_data: [4 * 1024]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    var seeder = SimPeer{
        .io = undefined, // filled by init
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
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .honest = {} },
        .info_hash = info_hash,
        .peer_id = seeder_peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Test side: send a downloader handshake.
    const my_handshake = peer_wire.serializeHandshake(info_hash, downloader_peer_id);
    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &my_handshake }, &tx_c, &tx_ctx, txCallback);

    // Test side: arm a recv to pick up the seeder's reply.
    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    // Drain — should see seeder.handshake (68 bytes) + bitfield message
    // (4 + 1 + 1 = 6 bytes) = 74 bytes back.
    try io.advance(0);
    try io.advance(0);
    try io.advance(0);
    try testing.expectEqual(@as(u32, 1), seeder.handshakes_received);
    // Allow a couple more ticks for the chained sends (handshake then
    // bitfield) to complete. 1 tick per send so 3 should be plenty.
    try io.advance(0);
    try io.advance(0);

    // Test side received seeder's handshake + bitfield.
    try testing.expect(rx_ctx.received >= 68);
    const hs = try parseHandshake(rx_ctx.bytes[0..rx_ctx.received]);
    try testing.expectEqualSlices(u8, &info_hash, &hs.info_hash);
    try testing.expectEqualSlices(u8, &seeder_peer_id, &hs.peer_id);

    // The bytes after the handshake should be the bitfield message:
    // [0,0,0,2][5][0xf0].
    if (rx_ctx.received >= 68 + 6) {
        const bf_msg = rx_ctx.bytes[68 .. 68 + 6];
        try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bf_msg[0..4], .big));
        try testing.expectEqual(@as(u8, 5), bf_msg[4]);
        try testing.expectEqual(@as(u8, 0xf0), bf_msg[5]);
    }
}

test "SimPeer seeder unchokes on interested" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(0xfeed);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 1;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0x80};
    var piece_data: [16]u8 = undefined;
    @memset(&piece_data, 0x42);

    var seeder = SimPeer{
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
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .honest = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Send handshake + interested in one batch.
    var combined: [68 + 5]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    // Drain — should see handshake + bitfield + unchoke.
    var i: u32 = 0;
    while (i < 10) : (i += 1) try io.advance(0);

    try testing.expectEqual(@as(u32, 1), seeder.handshakes_received);
    try testing.expectEqual(@as(u32, 1), seeder.interesteds_received);

    // Seeder responses are 68 + 5 (bitfield) + 5 (unchoke) = 78 bytes total.
    try testing.expect(rx_ctx.received >= 78);
}

test "SimPeer seeder responds to request with piece data (honest)" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(1);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 2;
    const piece_size: u32 = 32;
    var bitfield: [1]u8 = .{0xc0};
    var piece_data: [64]u8 = undefined;
    for (&piece_data, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));

    var seeder = SimPeer{
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
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .honest = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Request piece 0, offset 0, length 16.
    var combined: [68 + 5 + 17]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 });
    @memcpy(combined[73..90], &req);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    try testing.expectEqual(@as(u32, 1), seeder.requests_received);
    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);

    // Total expected: 68 (hs) + (4+1+1) (bf) + (4+1) (unchoke) + (4+1+8+16) (piece) = 108.
    try testing.expectEqual(@as(usize, 108), rx_ctx.received);

    // Verify the piece data echoes back unchanged.
    const piece_msg_start: usize = 68 + 6 + 5;
    // [length=4][id=7][piece=4][offset=4][block=16] = 29 bytes total.
    const block_start = piece_msg_start + 4 + 1 + 4 + 4;
    const block_end = block_start + 16;
    try testing.expectEqualSlices(u8, piece_data[0..16], rx_ctx.bytes[block_start..block_end]);
}

test "SimPeer wrong_data behaviour replaces block bytes with 0xaa" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(2);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xcc);
    const peer_id: [20]u8 = @splat(0x99);
    const piece_count: u32 = 1;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0x80};
    var piece_data: [16]u8 = undefined;
    for (&piece_data, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .wrong_data = {} },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .wrong_data = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    var combined: [68 + 5 + 17]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 });
    @memcpy(combined[73..90], &req);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);

    // Block bytes should all be 0xaa, NOT the original piece_data.
    const block_start: usize = 68 + 6 + 5 + 4 + 1 + 4 + 4;
    const block_end = block_start + 16;
    var got_block: [16]u8 = undefined;
    @memcpy(&got_block, rx_ctx.bytes[block_start..block_end]);
    var expected: [16]u8 = @splat(0xaa);
    try testing.expectEqualSlices(u8, &expected, &got_block);
}

test "SimPeer corrupt behaviour with probability 1.0 flips at least one bit" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(0xdeadbeef);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xcc);
    const peer_id: [20]u8 = @splat(0x99);
    const piece_count: u32 = 1;
    const piece_size: u32 = 64;
    var bitfield: [1]u8 = .{0x80};
    var piece_data: [64]u8 = undefined;
    for (&piece_data, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .corrupt = .{ .probability = 1.0 } },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .corrupt = .{ .probability = 1.0 } },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    var combined: [68 + 5 + 17]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 64 });
    @memcpy(combined[73..90], &req);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);

    // Block should differ from piece_data by at least one bit.
    const block_start: usize = 68 + 6 + 5 + 4 + 1 + 4 + 4;
    const block_end = block_start + 64;
    try testing.expect(!std.mem.eql(u8, piece_data[0..64], rx_ctx.bytes[block_start..block_end]));
}

test "SimPeer disconnect_after closes after N blocks" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(0xfacefeed);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xcc);
    const peer_id: [20]u8 = @splat(0x99);
    const piece_count: u32 = 4;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0xf0};
    var piece_data: [64]u8 = undefined;
    for (&piece_data, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .disconnect_after = .{ .blocks = 1 } },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .disconnect_after = .{ .blocks = 1 } },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Send handshake + interested + 2 requests.
    var combined: [68 + 5 + 17 + 17]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req1 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 });
    @memcpy(combined[73..90], &req1);
    const req2 = peer_wire.serializeRequest(.{ .piece_index = 1, .block_offset = 0, .length = 16 });
    @memcpy(combined[90..107], &req2);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    // Only one block should have been sent before close.
    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);

    // The auto-rearming primeRecv should have observed the connection
    // reset on the parked recv that was active when the seeder closed.
    try testing.expectEqual(@as(?anyerror, error.ConnectionResetByPeer), rx_ctx.err);
}

test "SimPeer lie_bitfield advertises all-pieces-present regardless of stored bitfield" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(7);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 4;
    const piece_size: u32 = 16;
    // Real bitfield says we only have piece 0.
    var real_bitfield: [1]u8 = .{0x80};
    var piece_data: [4 * 16]u8 = undefined;
    @memset(&piece_data, 0x42);

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .lie_bitfield = {} },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .lie_bitfield = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &real_bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    const my_handshake = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &my_handshake }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 5) : (i += 1) try io.advance(0);

    // Bitfield message starts at byte 68. Layout: [0,0,0,2][5][bf_byte].
    try testing.expect(rx_ctx.received >= 68 + 6);
    const bf_byte = rx_ctx.bytes[68 + 5];
    // Lie advertises 4 ones in the high nibble (mask trims trailing bits
    // past piece_count).
    try testing.expectEqual(@as(u8, 0xf0), bf_byte);
    // The seeder's stored bitfield is unchanged — only the wire form lies.
    try testing.expectEqual(@as(u8, 0x80), real_bitfield[0]);
}

test "SimPeer silent_after stops responding after N blocks" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(11);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 4;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0xf0};
    var piece_data: [4 * 16]u8 = undefined;
    for (&piece_data, 0..) |*b, idx| b.* = @as(u8, @intCast(idx));

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .silent_after = .{ .blocks = 2 } },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .silent_after = .{ .blocks = 2 } },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Send handshake + interested + 3 requests; the seeder should respond
    // to the first 2 and silently drop the third.
    var combined: [68 + 5 + 17 * 3]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    var off: usize = 73;
    var p: u32 = 0;
    while (p < 3) : (p += 1) {
        const req = peer_wire.serializeRequest(.{ .piece_index = p, .block_offset = 0, .length = 16 });
        @memcpy(combined[off..][0..17], &req);
        off += 17;
    }

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 30) : (i += 1) try io.advance(0);

    // Three requests received but only two block sends fired.
    try testing.expectEqual(@as(u32, 3), seeder.requests_received);
    try testing.expectEqual(@as(u32, 2), seeder.blocks_sent);
}

test "SimPeer greedy accepts requests but never sends pieces" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(13);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 4;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0xf0};
    var piece_data: [4 * 16]u8 = undefined;
    @memset(&piece_data, 0x42);

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .greedy = {} },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .greedy = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Send handshake + interested + 3 requests.
    var combined: [68 + 5 + 17 * 3]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    var off: usize = 73;
    var p: u32 = 0;
    while (p < 3) : (p += 1) {
        const req = peer_wire.serializeRequest(.{ .piece_index = p, .block_offset = 0, .length = 16 });
        @memcpy(combined[off..][0..17], &req);
        off += 17;
    }

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 30) : (i += 1) try io.advance(0);

    // The greedy peer accepted all 3 requests but never sent any blocks.
    try testing.expectEqual(@as(u32, 3), seeder.requests_received);
    try testing.expectEqual(@as(u32, 0), seeder.blocks_sent);
}

test "SimPeer slow throttles piece dispatch with delay_per_block_ns" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(17);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 2;
    const piece_size: u32 = 16;
    var bitfield: [1]u8 = .{0xc0};
    var piece_data: [2 * 16]u8 = undefined;
    @memset(&piece_data, 0x42);

    const delay_ns: u64 = 5_000_000; // 5 ms per block

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .slow = .{ .delay_per_block_ns = delay_ns } },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .slow = .{ .delay_per_block_ns = delay_ns } },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Send handshake + interested + 2 requests.
    var combined: [68 + 5 + 17 * 2]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req1 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 });
    @memcpy(combined[73..90], &req1);
    const req2 = peer_wire.serializeRequest(.{ .piece_index = 1, .block_offset = 0, .length = 16 });
    @memcpy(combined[90..107], &req2);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    // Drain at t=0. The first piece response should fire; the second
    // should be held by the throttle window (5ms not yet elapsed).
    var i: u32 = 0;
    while (i < 5) : (i += 1) try io.advance(0);
    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);

    // Cross the throttle window. seeder.step is invoked by the simulator
    // step path, but we don't have a Simulator here — call step directly
    // to release the throttle. (In a Simulator-driven test the sim does
    // this for us.)
    io.now_ns = delay_ns + 1;
    try seeder.step(io.now_ns);
    try io.advance(0);

    try testing.expectEqual(@as(u32, 2), seeder.blocks_sent);
}

test "SimPeer block_mask drops requests outside the served range" {
    // Phase 2A scaffolding: a seeder advertising piece 0 but only
    // serving block 0 should drop requests for block 1 silently.
    // Used to stage multi-source-piece scenarios where one peer holds
    // a strict subset of a piece's blocks.
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(101);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 1;
    // Piece is 32 KiB = 2 blocks of 16 KiB each.
    const piece_size: u32 = 32 * 1024;
    var bitfield: [1]u8 = .{0x80};
    var piece_data: [piece_size]u8 = undefined;
    @memset(&piece_data, 0x77);

    // Mask: block 0 served, block 1 not served.
    const block_mask = [_]bool{ true, false };

    var seeder = SimPeer{
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
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .honest = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
        .block_mask = &block_mask,
    });

    // Send handshake + interested + request for block 0 (offset 0)
    // and block 1 (offset 16 KiB).
    var combined: [68 + 5 + 17 * 2]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req0 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 * 1024 });
    @memcpy(combined[73..90], &req0);
    const req1 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 16 * 1024, .length = 16 * 1024 });
    @memcpy(combined[90..107], &req1);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    // Both requests are received by SimPeer (wire-level), but only
    // block 0 is served. Block 1 is dropped silently.
    try testing.expectEqual(@as(u32, 2), seeder.requests_received);
    try testing.expectEqual(@as(u32, 1), seeder.blocks_sent);
}

test "SimPeer corrupt_blocks garbles only the listed block index" {
    // Phase 2B scaffolding: deterministic per-block corruption. With
    // `corrupt_blocks: { indices = [1] }` and a 2-block piece, block 0
    // is sent cleanly and block 1 is sent garbled (canonical 0xcc
    // pattern). The smart-ban Phase 1 SHA-1 recompute would identify
    // the per-block hash mismatch and Phase 2 would attribute it to
    // this peer.
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(102);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    const test_fd = fds[1];

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    const piece_count: u32 = 1;
    const piece_size: u32 = 32 * 1024;
    var bitfield: [1]u8 = .{0x80};
    var piece_data: [piece_size]u8 = undefined;
    // Distinct values per block so we can tell honest from garbled.
    @memset(piece_data[0 .. 16 * 1024], 0x11);
    @memset(piece_data[16 * 1024 ..], 0x22);

    const corrupt_indices = [_]u32{1};

    var seeder = SimPeer{
        .io = undefined,
        .fd = 0,
        .role = .seeder,
        .behavior = .{ .corrupt_blocks = .{ .indices = &corrupt_indices } },
        .rng = &rng,
        .info_hash = undefined,
        .peer_id = undefined,
        .piece_count = 0,
        .piece_size = 0,
        .bitfield = &.{},
        .piece_data = &.{},
    };
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .corrupt_blocks = .{ .indices = &corrupt_indices } },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    // Request both blocks.
    var combined: [68 + 5 + 17 * 2]u8 = undefined;
    const hs = peer_wire.serializeHandshake(info_hash, @splat(0x44));
    @memcpy(combined[0..68], &hs);
    const interested_header = peer_wire.serializeHeader(2, &.{});
    @memcpy(combined[68..73], &interested_header);
    const req0 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16 * 1024 });
    @memcpy(combined[73..90], &req0);
    const req1 = peer_wire.serializeRequest(.{ .piece_index = 0, .block_offset = 16 * 1024, .length = 16 * 1024 });
    @memcpy(combined[90..107], &req1);

    var tx_c = Completion{};
    var tx_ctx = TxCtx{};
    try io.send(.{ .fd = test_fd, .buf = &combined }, &tx_c, &tx_ctx, txCallback);

    var rx_c = Completion{};
    var rx_ctx = RxCtx{};
    try primeRecv(&io, test_fd, &rx_c, &rx_ctx);

    var i: u32 = 0;
    while (i < 20) : (i += 1) try io.advance(0);

    // Both blocks were sent.
    try testing.expectEqual(@as(u32, 2), seeder.blocks_sent);

    // Walk the received bytes: handshake + bitfield + unchoke + 2 piece
    // messages. Each piece message header is 4 (length) + 1 (id) + 4
    // (piece_idx) + 4 (block_offset) = 13 bytes. Block payload follows.
    const piece_block_size: usize = 16 * 1024;
    const piece_msg_size: usize = 4 + 1 + 4 + 4 + piece_block_size;
    const first_piece_offset: usize = 68 + 6 + 5; // handshake + bitfield + unchoke
    const block0_payload_start = first_piece_offset + 4 + 1 + 4 + 4;
    const block0_payload_end = block0_payload_start + piece_block_size;
    const block1_msg_start = first_piece_offset + piece_msg_size;
    const block1_payload_start = block1_msg_start + 4 + 1 + 4 + 4;
    const block1_payload_end = block1_payload_start + piece_block_size;

    // Block 0: clean (canonical 0x11).
    try testing.expectEqual(@as(u8, 0x11), rx_ctx.bytes[block0_payload_start]);
    try testing.expectEqual(@as(u8, 0x11), rx_ctx.bytes[block0_payload_end - 1]);

    // Block 1: garbled with canonical 0xcc pattern.
    try testing.expectEqual(@as(u8, 0xcc), rx_ctx.bytes[block1_payload_start]);
    try testing.expectEqual(@as(u8, 0xcc), rx_ctx.bytes[block1_payload_end - 1]);
}

test "SimPeer disconnect closes the socketpair fd cleanly" {
    var io = try SimIO.init(testing.allocator, .{ .socket_capacity = 4 });
    defer io.deinit();

    var rng = std.Random.DefaultPrng.init(103);

    const fds = try io.createSocketpair();
    const seeder_fd = fds[0];
    _ = fds[1]; // partner fd; closeSocket on either side is enough

    const info_hash: [20]u8 = @splat(0xab);
    const peer_id: [20]u8 = @splat(0x53);
    var bitfield: [1]u8 = .{0xc0};
    var piece_data: [32]u8 = undefined;
    @memset(&piece_data, 0x42);

    var seeder = SimPeer{
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
    try seeder.init(.{
        .io = &io,
        .fd = seeder_fd,
        .role = .seeder,
        .behavior = .{ .honest = {} },
        .info_hash = info_hash,
        .peer_id = peer_id,
        .piece_count = 2,
        .piece_size = 16,
        .bitfield = &bitfield,
        .piece_data = &piece_data,
        .rng = &rng,
    });

    try testing.expect(seeder.fd >= 0);
    seeder.disconnect();
    try testing.expectEqual(@as(posix.fd_t, -1), seeder.fd);
    try testing.expectEqual(varuna.sim.sim_peer.ProtocolState.closed, seeder.state);

    // Calling disconnect again is idempotent (no double-close).
    seeder.disconnect();
    try testing.expectEqual(@as(posix.fd_t, -1), seeder.fd);
}

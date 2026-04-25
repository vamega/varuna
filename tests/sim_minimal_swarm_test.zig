//! Minimal sim swarm test — drives a single honest `SimPeer` seeder
//! against a manual test-side "downloader" inside a `Simulator`. The
//! downloader is hand-written here instead of being a real
//! `EventLoop(SimIO)` because EventLoop is still concrete (`io: RealIO`)
//! while Stage 2 #12 finishes. Once EventLoop is parameterised, this test
//! will be replaced with a real EventLoop downloader and a 4-piece
//! end-to-end transfer (the "sim_minimal_swarm_test" the task brief asks
//! for). Until then, this verifies the Simulator + SimPeer plumbing is
//! sound and that runUntilFine drives a swarm to completion.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const SimIO = varuna.io.sim_io.SimIO;
const Simulator = varuna.sim.Simulator;
const StubDriver = varuna.sim.StubDriver;
const SimPeer = varuna.sim.SimPeer;
const peer_wire = varuna.net.peer_wire;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Hand-rolled test downloader ───────────────────────────
//
// Drives the protocol from the downloader's side: send handshake, read
// seeder's handshake + bitfield, send `interested`, read `unchoke`,
// request blocks one at a time, read piece responses.

const Downloader = struct {
    io: *SimIO,
    fd: posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,

    piece_count: u32,
    piece_size: u32,
    block_size: u32,

    /// Bytes received into the staging buffer; `recv_len` tracks how much
    /// is consumed by the parser.
    recv_buf: [128 * 1024]u8 = undefined,
    recv_len: u32 = 0,

    /// Reusable single-message scratch for outgoing messages.
    send_buf: [128]u8 = undefined,
    send_in_flight: bool = false,

    /// Current request index. We pull blocks `block_size` at a time
    /// starting from piece 0 / offset 0.
    next_request_piece: u32 = 0,
    next_request_offset: u32 = 0,

    /// Bytes successfully written to `received_pieces`.
    bytes_received: u32 = 0,
    /// Buffer big enough to hold the full torrent contents.
    received_pieces: []u8,

    sent_handshake: bool = false,
    sent_interested: bool = false,
    handshake_received: bool = false,
    bitfield_received: bool = false,
    unchoke_received: bool = false,
    /// True when a request was wanted but couldn't be submitted because
    /// `send_in_flight` was true. The next `sendCallback` fire picks it up.
    deferred_request: bool = false,

    state: enum {
        await_handshake,
        active,
        done,
    } = .await_handshake,

    recv_completion: Completion = .{},
    send_completion: Completion = .{},

    pub fn init(self: *Downloader) !void {
        // Send our handshake first.
        const hs = peer_wire.serializeHandshake(self.info_hash, self.peer_id);
        @memcpy(self.send_buf[0..hs.len], &hs);
        try self.submitSend(self.send_buf[0..hs.len]);
        // Arm initial recv.
        try self.armRecv();
    }

    fn armRecv(self: *Downloader) !void {
        try self.io.recv(
            .{ .fd = self.fd, .buf = self.recv_buf[self.recv_len..] },
            &self.recv_completion,
            self,
            recvCallback,
        );
    }

    fn submitSend(self: *Downloader, buf: []const u8) !void {
        if (self.send_in_flight) return error.SendBusy;
        self.send_in_flight = true;
        try self.io.send(.{ .fd = self.fd, .buf = buf }, &self.send_completion, self, sendCallback);
    }

    fn recvCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *Downloader = @ptrCast(@alignCast(ud.?));
        const n = switch (result) {
            .recv => |r| r catch return .disarm,
            else => return .disarm,
        };
        if (n == 0) return .disarm;
        self.recv_len += @intCast(n);
        self.process() catch return .disarm;
        if (self.state == .done) return .disarm;
        self.armRecv() catch {};
        return .disarm;
    }

    fn sendCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *Downloader = @ptrCast(@alignCast(ud.?));
        self.send_in_flight = false;
        switch (result) {
            .send => |r| _ = r catch return .disarm,
            else => return .disarm,
        }
        // Only push a request if one was queued by `maybeRequestNext`
        // hitting send_in_flight. Otherwise we'd over-pipeline and
        // produce more requests than blocks.
        if (self.deferred_request) {
            self.maybeRequestNext() catch return .disarm;
        }
        return .disarm;
    }

    fn process(self: *Downloader) !void {
        if (self.state == .await_handshake) {
            if (self.recv_len < 68) return;
            // Verify protocol & info_hash; peer_id is tracked but not
            // validated for this test.
            if (!std.mem.eql(u8, self.recv_buf[1..20], peer_wire.protocol_string)) return error.BadHandshake;
            if (!std.mem.eql(u8, self.recv_buf[28..48], &self.info_hash)) return error.InfoHashMismatch;
            self.handshake_received = true;
            self.consume(68);
            self.state = .active;
        }

        while (self.state == .active and self.recv_len >= 4) {
            const length = std.mem.readInt(u32, self.recv_buf[0..4], .big);
            const total = 4 + @as(u32, length);
            if (self.recv_len < total) return;
            try self.processMessage(self.recv_buf[4..total]);
            self.consume(total);
        }
    }

    fn processMessage(self: *Downloader, payload: []const u8) !void {
        if (payload.len == 0) return; // keep-alive
        const id = payload[0];
        switch (id) {
            1 => { // unchoke — start requesting.
                self.unchoke_received = true;
                try self.maybeRequestNext();
            },
            5 => { // bitfield — respond with interested.
                self.bitfield_received = true;
                if (!self.sent_interested) {
                    const hdr = peer_wire.serializeHeader(2, &.{});
                    @memcpy(self.send_buf[0..hdr.len], &hdr);
                    try self.submitSend(self.send_buf[0..hdr.len]);
                    self.sent_interested = true;
                }
            },
            7 => { // piece response.
                if (payload.len < 9) return error.MalformedPiece;
                const piece_index = std.mem.readInt(u32, payload[1..5], .big);
                const block_offset = std.mem.readInt(u32, payload[5..9], .big);
                const block = payload[9..];
                _ = piece_index;
                _ = block_offset;
                // Just append; this test transfers in strictly sequential
                // order so ordering is implicit.
                @memcpy(
                    self.received_pieces[self.bytes_received..][0..block.len],
                    block,
                );
                self.bytes_received += @intCast(block.len);
                if (self.bytes_received == self.received_pieces.len) {
                    self.state = .done;
                } else {
                    try self.maybeRequestNext();
                }
            },
            else => {}, // ignore other messages
        }
    }

    fn maybeRequestNext(self: *Downloader) !void {
        if (self.bytes_received >= self.received_pieces.len) return;
        if (!self.unchoke_received) return;
        if (self.send_in_flight) {
            self.deferred_request = true;
            return;
        }
        self.deferred_request = false;

        const piece_remaining = self.piece_size - self.next_request_offset;
        const len = @min(self.block_size, piece_remaining);
        const req: peer_wire.Request = .{
            .piece_index = self.next_request_piece,
            .block_offset = self.next_request_offset,
            .length = len,
        };
        const bytes = peer_wire.serializeRequest(req);
        @memcpy(self.send_buf[0..bytes.len], &bytes);
        try self.submitSend(self.send_buf[0..bytes.len]);

        // Advance window.
        self.next_request_offset += len;
        if (self.next_request_offset >= self.piece_size) {
            self.next_request_piece += 1;
            self.next_request_offset = 0;
        }
    }

    fn consume(self: *Downloader, n: u32) void {
        const remaining = self.recv_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[n..self.recv_len]);
        }
        self.recv_len = remaining;
    }
};

// ── Cond functions for runUntilFine ───────────────────────

fn downloaderDone(_: *Simulator) bool {
    return ctx.downloader.state == .done;
}

const TestCtx = struct {
    downloader: *Downloader,
};
var ctx: TestCtx = undefined;

// ── Test ──────────────────────────────────────────────────

test "Simulator + honest SimPeer seeder + hand-rolled downloader transfers a 4-piece torrent" {
    var sim = try Simulator.init(testing.allocator, .{
        .swarm_capacity = 4,
        .seed = 0xDEADBEEF,
        .sim_io = .{ .socket_capacity = 4 },
    }, StubDriver{});
    defer sim.deinit();

    var rng = std.Random.DefaultPrng.init(0xfeedface);

    const fds = try sim.io.createSocketpair();
    const seeder_fd = fds[0];
    const downloader_fd = fds[1];

    const info_hash: [20]u8 = .{0xab} ** 20;
    const seeder_peer_id: [20]u8 = .{0x53} ** 20;
    const downloader_peer_id: [20]u8 = .{0x44} ** 20;
    const piece_count: u32 = 4;
    const piece_size: u32 = 1024;
    const block_size: u32 = 256;
    var bitfield: [1]u8 = .{0xf0}; // 4 pieces, all present
    var piece_data: [piece_count * piece_size]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

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
        .io = &sim.io,
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
    try sim.addPeer(&seeder);

    var downloader_buf: [piece_count * piece_size]u8 = undefined;
    var downloader = Downloader{
        .io = &sim.io,
        .fd = downloader_fd,
        .info_hash = info_hash,
        .peer_id = downloader_peer_id,
        .piece_count = piece_count,
        .piece_size = piece_size,
        .block_size = block_size,
        .received_pieces = &downloader_buf,
    };
    try downloader.init();

    ctx = .{ .downloader = &downloader };
    const ok = try sim.runUntilFine(downloaderDone, 1024, 1_000_000);
    try testing.expect(ok);
    try testing.expect(downloader.state == .done);
    try testing.expectEqual(@as(u32, piece_count * piece_size), downloader.bytes_received);

    // Bytes received must match the seeder's piece_data.
    try testing.expectEqualSlices(u8, &piece_data, &downloader_buf);

    // Bookkeeping on the seeder side.
    try testing.expectEqual(@as(u32, 1), seeder.handshakes_received);
    try testing.expectEqual(@as(u32, 1), seeder.interesteds_received);
    // 4 pieces × 4 blocks each = 16 requests.
    try testing.expectEqual(@as(u32, piece_count * (piece_size / block_size)), seeder.requests_received);
    try testing.expectEqual(@as(u32, piece_count * (piece_size / block_size)), seeder.blocks_sent);
}

//! SimPeer — scriptable BitTorrent seeder driven by SimIO completions.
//!
//! `SimPeer` plays a real BitTorrent peer (BEP 3 wire protocol) inside the
//! simulator. It registers a `recv` completion on a SimIO socket, parses
//! incoming messages out of an in-place ring buffer, and submits responses
//! back through `send`. There are no threads and no syscalls — every byte
//! the peer sends or receives flows through `SimIO`.
//!
//! Each peer carries a `Behavior` that decides how it deviates from the
//! happy path: corrupt blocks, wrong data, lie about its bitfield, drop
//! the connection after N blocks, etc. Behaviours are evaluated at the
//! point each block is rendered, so the same peer can serve some blocks
//! correctly and corrupt others.
//!
//! Roles:
//!   * `.seeder` — accepts an inbound peer's handshake, sends its own
//!     handshake + bitfield, responds to `interested` with `unchoke`,
//!     responds to `request` with the corresponding block.
//!   * `.downloader` — not yet implemented (the simulator's downloader
//!     role is played by a real `EventLoop(SimIO)` once EventLoop is
//!     parameterised over its IO backend).
//!
//! Wire-protocol parsing reuses the pure serialization helpers in
//! `src/net/peer_wire.zig` for outgoing messages, and a tiny in-place
//! parser here for incoming messages (the helpers in peer_wire.zig do
//! blocking I/O which we cannot use under SimIO).

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const ifc = @import("../io/io_interface.zig");
const sim_io_mod = @import("../io/sim_io.zig");
const peer_wire = @import("../net/peer_wire.zig");

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;
const SimIO = sim_io_mod.SimIO;

// ── Behavior ──────────────────────────────────────────────

pub const Behavior = union(enum) {
    /// Standard well-behaved seeder.
    honest: void,
    /// Drip-feed mode: after each piece response, hold off on the next
    /// dispatch for `delay_per_block_ns` of simulated time. Implemented
    /// in `step()` via a `dispatch_blocked_until_ns` checkpoint. This is
    /// a simpler model than the original `bytes_per_ns` sketch — block
    /// granularity is sufficient to stress request-pipelining and
    /// timeouts without a per-byte schedule.
    slow: struct { delay_per_block_ns: u64 },
    /// With each block, flip a single random bit with this probability.
    corrupt: struct { probability: f32 },
    /// Always send bytes that don't match the requested block.
    wrong_data: void,
    /// Stop responding after N successful block sends. The connection
    /// stays open; the peer simply doesn't dispatch further responses.
    silent_after: struct { blocks: u32 },
    /// Close the socket after N successful block sends.
    disconnect_after: struct { blocks: u32 },
    /// Advertise pieces it doesn't actually hold.
    lie_bitfield: void,
    /// Greedy peer: accept incoming requests without ever dispatching a
    /// piece response. Stresses the downloader's request-pipeline
    /// backpressure / timeout logic. The peer still completes the
    /// handshake / bitfield / unchoke flow normally so the downloader
    /// will pipeline real requests at it.
    greedy: void,
    /// Advertise an extension handshake with a `metadata_size` value far
    /// larger than the real metainfo length. Stresses BEP 9 metadata-fetch
    /// validation. This is a placeholder — the wire-level extension
    /// handshake send isn't implemented yet (the seeder doesn't initiate
    /// BEP 10), but the `metadata_size_lie` value is plumbed through so
    /// callers can stage the test.
    lie_extensions: struct { metadata_size_lie: u64 = 1 << 30 },
};

// ── Protocol state ────────────────────────────────────────

pub const ProtocolState = enum {
    /// Waiting for the peer's 68-byte handshake to arrive.
    await_handshake,
    /// Handshake exchanged; waiting for length-prefixed messages.
    active,
    /// Connection closed (locally or by partner).
    closed,
};

pub const Role = enum { seeder, downloader };

// ── SimPeer ───────────────────────────────────────────────

const recv_buf_size: usize = 32 * 1024;
const send_buf_size: usize = 128 * 1024;
const action_queue_capacity: usize = 32;

pub const SimPeer = struct {
    io: *SimIO,
    fd: posix.fd_t,
    role: Role,
    behavior: Behavior,
    rng: *std.Random.DefaultPrng,

    info_hash: [20]u8,
    peer_id: [20]u8,

    /// Seeder data store. The bitfield is the canonical "what we have"
    /// (lie_bitfield overrides what's advertised). `piece_data` is the
    /// concatenation of all pieces, indexed by `piece_index * piece_size`.
    piece_count: u32,
    piece_size: u32,
    bitfield: []const u8,
    piece_data: []const u8,

    state: ProtocolState = .await_handshake,

    recv_buf: [recv_buf_size]u8 = undefined,
    recv_len: u32 = 0,

    /// Outgoing message scratch — the currently-in-flight message lives
    /// here. SimIO's send is zero-copy semantics, but the *bytes* must
    /// outlive the schedule; storing here is the simplest lifetime answer.
    send_buf: [send_buf_size]u8 = undefined,
    send_in_flight: bool = false,

    /// Pending actions waiting for the in-flight send to drain. Sized
    /// large enough to hold the typical handshake + bitfield + a few
    /// pipelined piece responses without ever overflowing.
    actions: [action_queue_capacity]Action = undefined,
    action_head: u8 = 0,
    action_tail: u8 = 0,
    action_count: u8 = 0,

    blocks_sent: u32 = 0,

    /// `slow.delay_per_block_ns` checkpoint — the simulated time before
    /// which the next piece response must NOT dispatch. `step()` releases
    /// any blocked piece-response actions when the clock crosses this.
    /// Default 0 means "never throttled".
    dispatch_blocked_until_ns: u64 = 0,

    recv_completion: Completion = .{},
    send_completion: Completion = .{},

    /// Counter the test inspects to confirm specific events fired.
    handshakes_received: u32 = 0,
    interesteds_received: u32 = 0,
    requests_received: u32 = 0,

    pub const InitOpts = struct {
        io: *SimIO,
        fd: posix.fd_t,
        role: Role,
        behavior: Behavior,
        info_hash: [20]u8,
        peer_id: [20]u8,
        piece_count: u32,
        piece_size: u32,
        bitfield: []const u8,
        piece_data: []const u8,
        rng: *std.Random.DefaultPrng,
    };

    pub fn init(self: *SimPeer, opts: InitOpts) !void {
        assert(opts.bitfield.len * 8 >= opts.piece_count);
        assert(opts.piece_data.len == @as(usize, opts.piece_count) * opts.piece_size);
        self.* = .{
            .io = opts.io,
            .fd = opts.fd,
            .role = opts.role,
            .behavior = opts.behavior,
            .rng = opts.rng,
            .info_hash = opts.info_hash,
            .peer_id = opts.peer_id,
            .piece_count = opts.piece_count,
            .piece_size = opts.piece_size,
            .bitfield = opts.bitfield,
            .piece_data = opts.piece_data,
        };
        // Always arm a recv first so we capture the inbound handshake.
        try self.armRecv();
    }

    /// Drive any timing-dependent state forward. Today `step` is the
    /// place where `slow`-behaviour throttle windows expire — when the
    /// simulator's clock crosses `dispatch_blocked_until_ns`, the next
    /// piece response that was queued but held back gets dispatched.
    /// Behaviours that don't need timing (honest, corrupt, wrong_data,
    /// lie_bitfield, greedy) leave step as a near-no-op.
    pub fn step(self: *SimPeer, now_ns: u64) !void {
        // Released throttle: try to drain any actions that were waiting
        // for the slow-window to elapse.
        if (self.dispatch_blocked_until_ns > 0 and now_ns >= self.dispatch_blocked_until_ns) {
            self.dispatch_blocked_until_ns = 0;
            try self.pumpActions();
        }
    }

    // ── Action queue ──────────────────────────────────────

    pub const Action = union(enum) {
        handshake: void,
        bitfield: void,
        unchoke: void,
        piece_response: peer_wire.Request,
        close: void,
    };

    fn enqueueAction(self: *SimPeer, action: Action) !void {
        if (self.action_count == action_queue_capacity) return error.ActionQueueFull;
        self.actions[self.action_tail] = action;
        self.action_tail = (self.action_tail + 1) % @as(u8, action_queue_capacity);
        self.action_count += 1;
    }

    fn dequeueAction(self: *SimPeer) ?Action {
        if (self.action_count == 0) return null;
        const a = self.actions[self.action_head];
        self.action_head = (self.action_head + 1) % @as(u8, action_queue_capacity);
        self.action_count -= 1;
        return a;
    }

    /// Drain the action queue: while no send is in flight, pop the next
    /// action and dispatch it. Returns when the queue is empty, a send
    /// is in flight, or a `slow`-throttle window is open and the head of
    /// the queue is a piece response (we hold piece responses; control
    /// messages like handshake/bitfield/unchoke flow through unthrottled).
    fn pumpActions(self: *SimPeer) !void {
        while (!self.send_in_flight) {
            // Slow throttle: peek at the head — if it's a piece_response
            // and the window hasn't expired, hold. step() retries when
            // the clock crosses the deadline.
            if (self.dispatch_blocked_until_ns > 0 and self.io.now() < self.dispatch_blocked_until_ns) {
                if (self.action_count > 0 and std.meta.activeTag(self.actions[self.action_head]) == .piece_response) {
                    return;
                }
            }
            const action = self.dequeueAction() orelse return;
            try self.dispatch(action);
            // Slow: arm the throttle window for the NEXT piece response.
            switch (action) {
                .piece_response => switch (self.behavior) {
                    .slow => |params| {
                        if (self.send_in_flight) {
                            self.dispatch_blocked_until_ns = self.io.now() +| params.delay_per_block_ns;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    fn dispatch(self: *SimPeer, action: Action) !void {
        assert(!self.send_in_flight);
        switch (action) {
            .handshake => {
                const hs = peer_wire.serializeHandshake(self.info_hash, self.peer_id);
                @memcpy(self.send_buf[0..hs.len], &hs);
                try self.submitSend(self.send_buf[0..hs.len]);
            },
            .bitfield => {
                const bf = self.advertisedBitfield();
                const header = peer_wire.serializeHeader(5, bf);
                @memcpy(self.send_buf[0..header.len], &header);
                @memcpy(self.send_buf[header.len..][0..bf.len], bf);
                try self.submitSend(self.send_buf[0 .. header.len + bf.len]);
            },
            .unchoke => {
                const header = peer_wire.serializeHeader(1, &.{});
                @memcpy(self.send_buf[0..header.len], &header);
                try self.submitSend(self.send_buf[0..header.len]);
            },
            .piece_response => |req| try self.dispatchPieceResponse(req),
            .close => {
                self.io.closeSocket(self.fd);
                self.state = .closed;
            },
        }
    }

    /// Slice of the bitfield as actually advertised. `lie_bitfield`
    /// returns an all-ones bitfield instead of the true one.
    fn advertisedBitfield(self: *SimPeer) []const u8 {
        switch (self.behavior) {
            .lie_bitfield => {
                // Reuse the front of send_buf as scratch — caller copies
                // it into the framed output before submitting send. Safe
                // because dispatch sets up the header AFTER calling this.
                // To avoid that lifetime hazard, allocate a private byte
                // window at the top of send_buf instead.
                const tail_start = send_buf_size - self.bitfield.len;
                @memset(self.send_buf[tail_start..send_buf_size], 0xff);
                // Mask trailing bits past piece_count to zero — the wire
                // form requires those to be 0.
                const last_byte = @as(usize, self.piece_count) / 8;
                const last_bit = @as(usize, self.piece_count) % 8;
                if (last_bit != 0 and last_byte < self.bitfield.len) {
                    const trim_mask: u8 = @as(u8, 0xff) << @as(u3, @intCast(8 - last_bit));
                    self.send_buf[tail_start + last_byte] = trim_mask;
                    var idx: usize = last_byte + 1;
                    while (idx < self.bitfield.len) : (idx += 1) {
                        self.send_buf[tail_start + idx] = 0;
                    }
                }
                return self.send_buf[tail_start..send_buf_size];
            },
            else => return self.bitfield,
        }
    }

    fn dispatchPieceResponse(self: *SimPeer, req: peer_wire.Request) !void {
        // disconnect_after, silent_after, and greedy all gate piece
        // responses; handle them centrally before any work is done.
        switch (self.behavior) {
            .disconnect_after => |params| if (self.blocks_sent >= params.blocks) {
                self.io.closeSocket(self.fd);
                self.state = .closed;
                return;
            },
            .silent_after => |params| if (self.blocks_sent >= params.blocks) {
                // Drop the request silently — leave the action queue
                // drained. The downloader will eventually time out.
                return;
            },
            .greedy => {
                // Accept the request but never respond. Stresses the
                // downloader's request-pipeline backpressure.
                return;
            },
            else => {},
        }

        // Bounds check: if the request is out of range, skip silently.
        // (A real seeder would close the connection; for SimPeer we
        // prefer a benign response so we can stress error paths.)
        if (req.piece_index >= self.piece_count) return;
        const piece_offset: usize = @as(usize, req.piece_index) * self.piece_size;
        if (req.block_offset + req.length > self.piece_size) return;
        if (piece_offset + req.block_offset + req.length > self.piece_data.len) return;

        // Build the framed piece message into send_buf:
        //   [4-byte length][1 id=7][4 piece_idx][4 block_offset][block...].
        const header = try peer_wire.serializePieceHeader(req.piece_index, req.block_offset, req.length);
        const total = header.len + req.length;
        if (total > send_buf_size) return error.MessageTooLarge;
        @memcpy(self.send_buf[0..header.len], &header);
        const block_dst = self.send_buf[header.len .. header.len + req.length];
        const block_src = self.piece_data[piece_offset + req.block_offset ..][0..req.length];
        switch (self.behavior) {
            .wrong_data => @memset(block_dst, 0xaa),
            .corrupt => |params| {
                @memcpy(block_dst, block_src);
                if (self.rng.random().float(f32) < params.probability) {
                    // Flip one bit in the middle of the block.
                    const bit_index = self.rng.random().uintLessThan(usize, req.length * 8);
                    const byte_index = bit_index / 8;
                    const mask = @as(u8, 1) << @as(u3, @intCast(bit_index % 8));
                    block_dst[byte_index] ^= mask;
                }
            },
            else => @memcpy(block_dst, block_src),
        }
        try self.submitSend(self.send_buf[0..total]);
        self.blocks_sent += 1;
    }

    fn submitSend(self: *SimPeer, buf: []const u8) !void {
        assert(!self.send_in_flight);
        self.send_in_flight = true;
        try self.io.send(.{ .fd = self.fd, .buf = buf }, &self.send_completion, self, sendCallback);
    }

    fn armRecv(self: *SimPeer) !void {
        assert(self.recv_len < recv_buf_size);
        try self.io.recv(
            .{ .fd = self.fd, .buf = self.recv_buf[self.recv_len..] },
            &self.recv_completion,
            self,
            recvCallback,
        );
    }

    // ── Callbacks ─────────────────────────────────────────

    fn recvCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *SimPeer = @ptrCast(@alignCast(ud.?));
        const n = switch (result) {
            .recv => |r| r catch {
                self.state = .closed;
                return .disarm;
            },
            else => return .disarm,
        };
        if (n == 0) {
            self.state = .closed;
            return .disarm;
        }
        self.recv_len += @intCast(n);
        self.handleIncoming() catch {
            self.state = .closed;
            return .disarm;
        };
        if (self.state == .closed) return .disarm;

        // Re-arm into the unconsumed tail of recv_buf.
        self.armRecv() catch {
            self.state = .closed;
            return .disarm;
        };
        return .disarm; // we re-armed manually above with a fresh buf slice
    }

    fn sendCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *SimPeer = @ptrCast(@alignCast(ud.?));
        self.send_in_flight = false;
        switch (result) {
            .send => |r| _ = r catch {
                self.state = .closed;
                return .disarm;
            },
            else => return .disarm,
        }
        // Drain any further queued actions.
        self.pumpActions() catch {
            self.state = .closed;
            return .disarm;
        };
        return .disarm;
    }

    // ── Inbound message handling ──────────────────────────

    fn handleIncoming(self: *SimPeer) !void {
        // First, the handshake (68 fixed bytes).
        if (self.state == .await_handshake) {
            if (self.recv_len < 68) return;
            try self.processHandshake(self.recv_buf[0..68]);
            self.consumeRecv(68);
            self.state = .active;
        }

        // Then length-prefixed messages.
        while (self.state == .active) {
            if (self.recv_len < 4) return;
            const length = std.mem.readInt(u32, self.recv_buf[0..4], .big);
            const total = 4 + @as(u32, length);
            if (self.recv_len < total) return;
            try self.processMessage(self.recv_buf[4..total]);
            self.consumeRecv(total);
            if (self.state != .active) return;
        }
    }

    fn processHandshake(self: *SimPeer, bytes: []const u8) !void {
        assert(bytes.len == 68);
        if (bytes[0] != peer_wire.protocol_length) return error.InvalidHandshake;
        if (!std.mem.eql(u8, bytes[1..20], peer_wire.protocol_string)) return error.InvalidHandshake;
        if (!std.mem.eql(u8, bytes[28..48], &self.info_hash)) return error.InfoHashMismatch;
        // peer_id = bytes[48..68] — accepted as-is.
        self.handshakes_received += 1;

        // Seeder responds with its own handshake + bitfield.
        if (self.role == .seeder) {
            try self.enqueueAction(.handshake);
            try self.enqueueAction(.bitfield);
            try self.pumpActions();
        }
    }

    fn processMessage(self: *SimPeer, payload: []const u8) !void {
        if (payload.len == 0) return; // keep-alive
        const id = payload[0];
        const body = payload[1..];
        switch (id) {
            // 0=choke, 1=unchoke, 3=not_interested — accepted, no action.
            0, 1, 3 => {},
            2 => { // interested
                self.interesteds_received += 1;
                if (self.role == .seeder) {
                    try self.enqueueAction(.unchoke);
                    try self.pumpActions();
                }
            },
            4 => {}, // have — accepted, ignored
            5 => {}, // bitfield — accepted, ignored (we're the seeder)
            6 => { // request
                if (body.len != 12) return error.MalformedRequest;
                const req: peer_wire.Request = .{
                    .piece_index = std.mem.readInt(u32, body[0..4], .big),
                    .block_offset = std.mem.readInt(u32, body[4..8], .big),
                    .length = std.mem.readInt(u32, body[8..12], .big),
                };
                self.requests_received += 1;
                if (self.role == .seeder) {
                    try self.enqueueAction(.{ .piece_response = req });
                    try self.pumpActions();
                }
            },
            7 => {}, // piece — only relevant for downloader role
            8 => {}, // cancel — accept, drop
            else => {}, // unknown — ignore for forward compat
        }
    }

    fn consumeRecv(self: *SimPeer, n: u32) void {
        assert(n <= self.recv_len);
        const remaining = self.recv_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[n..self.recv_len]);
        }
        self.recv_len = remaining;
    }
};

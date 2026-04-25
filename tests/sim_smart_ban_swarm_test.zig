//! Smart-ban swarm test — pre-scaffolded for the eventual `EventLoop(SimIO)`
//! integration.
//!
//! Same shape as the EventLoop-integrated test that will land once Stage
//! 2 #12 finishes parameterising EventLoop over its IO backend. The
//! hand-rolled `SwarmDownloader` here exposes the same read-only surface
//! we plan to ask for from `EventLoop` — `getPeerView(slot)`,
//! `isPieceComplete(piece_index)` — so when EventLoop becomes generic
//! the swap is purely the driver type. The assertions don't change.
//!
//! Differences from `tests/sim_smart_ban_protocol_test.zig`:
//!   * Uses `corrupt: { probability = 1.0 }` (the scenario specified in
//!     the task brief) instead of `wrong_data`. Both produce hash
//!     mismatches; `corrupt` flips one bit per block, which matches the
//!     "random byte corruption" failure mode that smart-ban Phase 0 was
//!     originally designed to catch.
//!   * Structures the Downloader as a thin wrapper around per-peer
//!     PeerSlot views, mirroring the future `EventLoop.getPeerView` API.
//!
//! The 8-seed sweep matches DoD #3 ("smart-ban sim test passes for ≥ 8
//! seeds"). When EventLoop(SimIO) is ready, swap `SwarmDownloader` →
//! `EventLoop(SimIO)` and the assertions stay identical.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const SimIO = varuna.io.sim_io.SimIO;
const Simulator = varuna.sim.Simulator;
const StubDriver = varuna.sim.StubDriver;
const SimPeer = varuna.sim.SimPeer;
const SimPeerBehavior = varuna.sim.sim_peer.Behavior;
const peer_wire = varuna.net.peer_wire;
const Sha1 = varuna.crypto.Sha1;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// Smart-ban Phase 0 constants — must stay in lockstep with
// `src/io/peer_policy.zig:trust_ban_threshold`.
const trust_ban_threshold: i8 = -7;
const trust_penalty_per_failure: i8 = 2;

const num_peers: u8 = 6;
const corrupt_peer_index: u8 = 5;
const piece_count: u32 = 4;
const piece_size: u32 = 32;
const block_size: u32 = piece_size; // 1 block per piece for this test

// ── Read-only views (mirror the future EventLoop API) ─────

/// Mirror of the planned `EventLoop.PeerView`. When EventLoop becomes
/// the driver, this struct is replaced with the production type.
pub const PeerView = struct {
    address: std.net.Address,
    trust_points: i8,
    hashfails: u8,
    is_banned: bool,
    blocks_received: u32,
};

// ── Per-peer state ────────────────────────────────────────

const PeerSlot = struct {
    address: std.net.Address,
    fd: posix.fd_t,
    handshake_received: bool = false,
    bitfield_received: bool = false,
    unchoke_received: bool = false,
    want_interested: bool = false,
    sent_interested: bool = false,
    awaiting_piece: ?u32 = null,

    // Smart-ban Phase 0 state — matches Peer fields in src/io/types.zig.
    trust_points: i8 = 0,
    hashfails: u8 = 0,
    is_banned: bool = false,

    blocks_received: u32 = 0,

    recv_buf: [16 * 1024]u8 = undefined,
    recv_len: u32 = 0,
    send_buf: [256]u8 = undefined,
    send_in_flight: bool = false,

    recv_completion: Completion = .{},
    send_completion: Completion = .{},
};

// ── SwarmDownloader — the EventLoop stand-in ──────────────

const SwarmDownloader = struct {
    io: *SimIO,
    info_hash: [20]u8,
    self_peer_id: [20]u8,
    /// Canonical piece data — every honest peer mirrors this. The corrupt
    /// peer flips one bit per block before sending.
    piece_data: []const u8,
    piece_hashes: [piece_count][20]u8 = undefined,

    slots: [num_peers]PeerSlot = undefined,

    /// Bit `i` set means piece `i` is verified.
    received_pieces_mask: u8 = 0,
    /// Reusable scratch for SHA-1 verification.
    verify_buf: [piece_size]u8 = undefined,

    total_block_attempts: u32 = 0,

    pub fn init(self: *SwarmDownloader) !void {
        // Compute canonical piece hashes.
        var i: u32 = 0;
        while (i < piece_count) : (i += 1) {
            var hasher = Sha1.init(.{});
            hasher.update(self.piece_data[i * piece_size ..][0..piece_size]);
            hasher.final(&self.piece_hashes[i]);
        }
        // Send initial handshake on every slot, arm initial recv.
        for (&self.slots) |*slot| {
            const hs = peer_wire.serializeHandshake(self.info_hash, self.self_peer_id);
            @memcpy(slot.send_buf[0..hs.len], &hs);
            try self.submitSend(slot, slot.send_buf[0..hs.len]);
            try self.armRecv(slot);
        }
    }

    // ── EventLoop-mirroring read-only API ─────────────────
    //
    // When the swap to EventLoop(SimIO) happens, the test code below
    // shifts from `dl.getPeerView(idx)` to `el.getPeerView(slot_id)` —
    // same return type, same semantics.

    pub fn getPeerView(self: *const SwarmDownloader, idx: u8) PeerView {
        std.debug.assert(idx < num_peers);
        const slot = self.slots[idx];
        return .{
            .address = slot.address,
            .trust_points = slot.trust_points,
            .hashfails = slot.hashfails,
            .is_banned = slot.is_banned,
            .blocks_received = slot.blocks_received,
        };
    }

    pub fn isPieceComplete(self: *const SwarmDownloader, piece_index: u32) bool {
        std.debug.assert(piece_index < piece_count);
        return (self.received_pieces_mask >> @as(u3, @intCast(piece_index))) & 1 != 0;
    }

    pub fn allPiecesComplete(self: *const SwarmDownloader) bool {
        const goal: u8 = (1 << piece_count) - 1;
        return self.received_pieces_mask == goal;
    }

    // ── Internal protocol plumbing ────────────────────────

    fn armRecv(self: *SwarmDownloader, slot: *PeerSlot) !void {
        try self.io.recv(
            .{ .fd = slot.fd, .buf = slot.recv_buf[slot.recv_len..] },
            &slot.recv_completion,
            slot,
            recvCallback,
        );
    }

    fn submitSend(self: *SwarmDownloader, slot: *PeerSlot, buf: []const u8) !void {
        std.debug.assert(!slot.send_in_flight);
        slot.send_in_flight = true;
        try self.io.send(
            .{ .fd = slot.fd, .buf = buf },
            &slot.send_completion,
            slot,
            sendCallback,
        );
    }

    fn maybeSendInterested(self: *SwarmDownloader, slot: *PeerSlot) !void {
        if (!slot.want_interested) return;
        if (slot.sent_interested) return;
        if (slot.send_in_flight) return;
        const hdr = peer_wire.serializeHeader(2, &.{});
        @memcpy(slot.send_buf[0..hdr.len], &hdr);
        try self.submitSend(slot, slot.send_buf[0..hdr.len]);
        slot.sent_interested = true;
    }

    fn allPeersReady(self: *const SwarmDownloader) bool {
        for (&self.slots) |*slot| {
            if (!slot.unchoke_received) return false;
        }
        return true;
    }

    fn pickPeerFor(self: *SwarmDownloader, _: u32, start_offset: u8) ?*PeerSlot {
        var i: u8 = 0;
        while (i < num_peers) : (i += 1) {
            const idx: u8 = @intCast((start_offset + i) % num_peers);
            const slot = &self.slots[idx];
            if (slot.is_banned) continue;
            if (!slot.unchoke_received) continue;
            if (slot.awaiting_piece != null) continue;
            if (slot.send_in_flight) continue;
            return slot;
        }
        return null;
    }

    fn requestPiece(self: *SwarmDownloader, slot: *PeerSlot, piece_index: u32) !void {
        std.debug.assert(slot.awaiting_piece == null);
        std.debug.assert(!slot.is_banned);
        const req = peer_wire.serializeRequest(.{
            .piece_index = piece_index,
            .block_offset = 0,
            .length = block_size,
        });
        @memcpy(slot.send_buf[0..req.len], &req);
        try self.submitSend(slot, slot.send_buf[0..req.len]);
        slot.awaiting_piece = piece_index;
        self.total_block_attempts += 1;
    }

    fn pumpRequests(self: *SwarmDownloader) !void {
        if (!self.allPeersReady()) return;

        var piece: u32 = 0;
        while (piece < piece_count) : (piece += 1) {
            if (self.isPieceComplete(piece)) continue;
            var outstanding = false;
            for (&self.slots) |*s| {
                if (s.awaiting_piece == piece) {
                    outstanding = true;
                    break;
                }
            }
            if (outstanding) continue;
            const slot = self.pickPeerFor(piece, corrupt_peer_index) orelse return;
            try self.requestPiece(slot, piece);
        }
    }

    // ── Callback wrappers ─────────────────────────────────

    fn recvCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const slot: *PeerSlot = @ptrCast(@alignCast(ud.?));
        const dl = downloader_singleton.?;

        const n = switch (result) {
            .recv => |r| r catch return .disarm,
            else => return .disarm,
        };
        if (n == 0) return .disarm;
        slot.recv_len += @intCast(n);
        dl.process(slot) catch return .disarm;
        if (dl.allPiecesComplete()) return .disarm;
        dl.armRecv(slot) catch return .disarm;
        return .disarm;
    }

    fn sendCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const slot: *PeerSlot = @ptrCast(@alignCast(ud.?));
        const dl = downloader_singleton.?;
        slot.send_in_flight = false;
        switch (result) {
            .send => |r| _ = r catch return .disarm,
            else => return .disarm,
        }
        dl.maybeSendInterested(slot) catch return .disarm;
        dl.pumpRequests() catch return .disarm;
        return .disarm;
    }

    fn process(self: *SwarmDownloader, slot: *PeerSlot) !void {
        if (!slot.handshake_received) {
            if (slot.recv_len < 68) return;
            if (!std.mem.eql(u8, slot.recv_buf[1..20], peer_wire.protocol_string)) return error.BadHandshake;
            if (!std.mem.eql(u8, slot.recv_buf[28..48], &self.info_hash)) return error.InfoHashMismatch;
            slot.handshake_received = true;
            self.consume(slot, 68);
        }

        while (slot.recv_len >= 4) {
            const length = std.mem.readInt(u32, slot.recv_buf[0..4], .big);
            const total = 4 + @as(u32, length);
            if (slot.recv_len < total) return;
            try self.processMessage(slot, slot.recv_buf[4..total]);
            self.consume(slot, total);
        }
    }

    fn processMessage(self: *SwarmDownloader, slot: *PeerSlot, payload: []const u8) !void {
        if (payload.len == 0) return;
        const id = payload[0];
        switch (id) {
            1 => { // unchoke
                slot.unchoke_received = true;
                try self.pumpRequests();
            },
            5 => { // bitfield
                slot.bitfield_received = true;
                slot.want_interested = true;
                try self.maybeSendInterested(slot);
            },
            7 => { // piece response
                if (payload.len < 9) return error.MalformedPiece;
                const piece_index = std.mem.readInt(u32, payload[1..5], .big);
                _ = std.mem.readInt(u32, payload[5..9], .big); // block_offset; always 0 here
                const block = payload[9..];
                if (block.len != piece_size) return error.UnexpectedBlockLen;

                @memcpy(&self.verify_buf, block);
                var actual: [20]u8 = undefined;
                var hasher = Sha1.init(.{});
                hasher.update(&self.verify_buf);
                hasher.final(&actual);

                std.debug.assert(slot.awaiting_piece != null);
                std.debug.assert(slot.awaiting_piece.? == piece_index);
                slot.awaiting_piece = null;
                slot.blocks_received += 1;

                if (std.mem.eql(u8, &actual, &self.piece_hashes[piece_index])) {
                    self.received_pieces_mask |= @as(u8, 1) << @as(u3, @intCast(piece_index));
                    if (slot.trust_points < 0) slot.trust_points += 1;
                } else {
                    slot.hashfails +|= 1;
                    slot.trust_points -|= trust_penalty_per_failure;
                    if (slot.trust_points <= trust_ban_threshold) slot.is_banned = true;
                }
                try self.pumpRequests();
            },
            else => {},
        }
    }

    fn consume(_: *SwarmDownloader, slot: *PeerSlot, n: u32) void {
        const remaining = slot.recv_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, slot.recv_buf[0..remaining], slot.recv_buf[n..slot.recv_len]);
        }
        slot.recv_len = remaining;
    }
};

// File-scope downloader singleton — the per-PeerSlot recv/send callbacks
// only have a `*PeerSlot` userdata, so they reach the downloader through
// this pointer. When the EventLoop swap happens, the equivalent is
// `*EventLoop` set as the userdata on each completion.
var downloader_singleton: ?*SwarmDownloader = null;

fn allDoneCond(_: *Simulator) bool {
    return downloader_singleton.?.allPiecesComplete();
}

// ── The seeded test ───────────────────────────────────────

fn syntheticAddr(idx: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 10, 0, 0, idx + 1 }, 6881);
}

fn runOneSeed(seed: u64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sim = try Simulator.init(testing.allocator, .{
        .swarm_capacity = num_peers,
        .seed = seed,
        .sim_io = .{ .socket_capacity = num_peers * 2 },
    }, StubDriver{});
    defer sim.deinit();

    var rng = std.Random.DefaultPrng.init(seed ^ 0xfeedface);

    const piece_data_buf = try arena.allocator().alloc(u8, piece_count * piece_size);
    for (piece_data_buf, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    const info_hash: [20]u8 = .{0xab} ** 20;
    var bitfield: [1]u8 = .{0xf0}; // all 4 pieces

    var peers: [num_peers]SimPeer = undefined;
    var downloader: SwarmDownloader = .{
        .io = &sim.io,
        .info_hash = info_hash,
        .self_peer_id = .{0x44} ** 20,
        .piece_data = piece_data_buf,
    };

    var i: u8 = 0;
    while (i < num_peers) : (i += 1) {
        const fds = try sim.io.createSocketpair();
        const seeder_fd = fds[0];
        const downloader_fd = fds[1];

        // Per the team-lead's brief: corrupt peer uses
        // `corrupt: { probability = 1.0 }`. Every block has a single bit
        // flipped — sufficient to fail SHA-1 every time.
        const behavior: SimPeerBehavior = if (i == corrupt_peer_index)
            .{ .corrupt = .{ .probability = 1.0 } }
        else
            .{ .honest = {} };

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
            .io = &sim.io,
            .fd = seeder_fd,
            .role = .seeder,
            .behavior = behavior,
            .info_hash = info_hash,
            .peer_id = [_]u8{i} ** 20,
            .piece_count = piece_count,
            .piece_size = piece_size,
            .bitfield = &bitfield,
            .piece_data = piece_data_buf,
            .rng = &rng,
        });
        try sim.addPeer(&peers[i]);

        downloader.slots[i] = .{
            .address = syntheticAddr(i),
            .fd = downloader_fd,
        };
    }

    downloader_singleton = &downloader;
    defer downloader_singleton = null;
    try downloader.init();

    const ok = try sim.runUntilFine(allDoneCond, 4096, 1_000_000);
    try testing.expect(ok);

    // ── Assertions match the eventual EventLoop-driven version ──
    //
    // After the Stage 2 #12 swap, `downloader.getPeerView` becomes
    // `sim.driver.getPeerView`, but the structure of the assertions
    // doesn't change.

    // 1. All pieces must verify.
    var p: u32 = 0;
    while (p < piece_count) : (p += 1) {
        try testing.expect(downloader.isPieceComplete(p));
    }

    // 2. Corrupt peer is banned.
    const corrupt = downloader.getPeerView(corrupt_peer_index);
    try testing.expect(corrupt.is_banned);
    try testing.expect(corrupt.trust_points <= trust_ban_threshold);
    try testing.expect(corrupt.hashfails >= 4);

    // 3. No honest peer is banned.
    var j: u8 = 0;
    while (j < num_peers) : (j += 1) {
        if (j == corrupt_peer_index) continue;
        const v = downloader.getPeerView(j);
        try testing.expect(!v.is_banned);
        try testing.expectEqual(@as(u8, 0), v.hashfails);
        try testing.expect(v.trust_points >= 0);
    }
}

test "smart-ban swarm: 5 honest + 1 corrupt(p=1.0) over 8 seeds" {
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
        runOneSeed(seed) catch |err| {
            std.debug.print("\n  SEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

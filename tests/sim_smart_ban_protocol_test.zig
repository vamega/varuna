//! Protocol-only smart-ban regression test.
//!
//! This test runs a hand-rolled trust-points / hashfails tracker (the
//! smart-ban Phase 0 algorithm extracted from `peer_policy.zig`) against
//! a swarm of SimPeer seeders driven by a `Simulator`. The downloader
//! side is hand-rolled — we don't yet have an `EventLoop(SimIO)` to
//! drive (Stage 2 #12 is in flight). When that lands, this scenario will
//! port directly: replace the Downloader with `EventLoop(SimIO)` and
//! assert against the EventLoop's own peer-state.
//!
//! Scenario:
//!   * 4 pieces, 32 bytes each (1 block per piece for simplicity).
//!   * 6 peers: 5 honest, 1 corrupt (always returns wrong_data).
//!   * Each piece is initially requested from the corrupt peer; on hash
//!     failure, the downloader rotates to the next non-banned peer and
//!     retries the same piece.
//!
//! Smart-ban Phase 0 (matches `peer_policy.zig:penalizePeerTrust`):
//!   * `trust_points: i8`, starts at 0.
//!   * On hash failure: `trust_points -|= 2`.
//!   * Ban threshold: `trust_points <= -7`.
//!   * 4 failures (0 → -2 → -4 → -6 → -8) crosses the ban threshold.
//!
//! Assertions over ≥ 8 seeds:
//!   * All 4 pieces eventually verify (liveness).
//!   * The corrupt peer is banned (`trust_points <= -7`).
//!   * No honest peer is banned (no false positives).

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

const trust_ban_threshold: i8 = -7;

// ── Per-peer protocol harness ─────────────────────────────
//
// Each peer in the swarm has a partner socket that the downloader holds
// open. The `PeerLink` collects bytes from one peer over the partner fd
// until a full piece message arrives, then notifies the Downloader so it
// can verify and act.

const PeerLink = struct {
    peer_index: u8,
    fd: posix.fd_t,
    handshake_sent: bool = false,
    handshake_received: bool = false,
    bitfield_received: bool = false,
    unchoke_received: bool = false,
    /// Bitfield arrived but interested couldn't be sent yet (e.g. the
    /// handshake send is still in flight). Drained on the next free
    /// send slot in `maybeSendInterested`.
    want_interested: bool = false,
    sent_interested: bool = false,
    /// Set when this link is the source of an outstanding piece request.
    awaiting_piece: ?u32 = null,
    trust_points: i8 = 0,
    hashfails: u8 = 0,
    banned: bool = false,
    blocks_received: u32 = 0,

    recv_buf: [16 * 1024]u8 = undefined,
    recv_len: u32 = 0,
    send_buf: [256]u8 = undefined,
    send_in_flight: bool = false,

    recv_completion: Completion = .{},
    send_completion: Completion = .{},
};

// ── Downloader ────────────────────────────────────────────

const num_peers: u8 = 6;
const corrupt_peer_index: u8 = 5;
const piece_count: u32 = 4;
const piece_size: u32 = 32;
const block_size: u32 = piece_size; // 1 block per piece

const Downloader = struct {
    io: *SimIO,
    info_hash: [20]u8,
    peer_id: [20]u8,
    /// Canonical piece data — every honest peer has this; the corrupt
    /// peer scribbles 0xaa over it.
    piece_data: []const u8,
    /// SHA-1 of each piece (length 32 bytes per piece).
    piece_hashes: [piece_count][20]u8 = undefined,

    links: [num_peers]PeerLink = undefined,

    /// Piece i is verified when received_pieces_mask bit i is set.
    received_pieces_mask: u8 = 0,
    /// Reusable scratch for SHA-1 verification.
    verify_buf: [piece_size]u8 = undefined,

    /// Stats for assertions.
    total_block_attempts: u32 = 0,

    pub fn init(self: *Downloader) !void {
        // Compute the canonical hashes from piece_data.
        var i: u32 = 0;
        while (i < piece_count) : (i += 1) {
            var hasher = Sha1.init(.{});
            hasher.update(self.piece_data[i * piece_size ..][0..piece_size]);
            hasher.final(&self.piece_hashes[i]);
        }
        // Send handshake on every link, arm recv on every link.
        for (&self.links) |*link| {
            const hs = peer_wire.serializeHandshake(self.info_hash, self.peer_id);
            @memcpy(link.send_buf[0..hs.len], &hs);
            try self.submitSend(link, link.send_buf[0..hs.len]);
            try self.armRecv(link);
        }
    }

    fn armRecv(self: *Downloader, link: *PeerLink) !void {
        try self.io.recv(
            .{ .fd = link.fd, .buf = link.recv_buf[link.recv_len..] },
            &link.recv_completion,
            link,
            recvCallback,
        );
    }

    fn submitSend(self: *Downloader, link: *PeerLink, buf: []const u8) !void {
        std.debug.assert(!link.send_in_flight);
        link.send_in_flight = true;
        try self.io.send(
            .{ .fd = link.fd, .buf = buf },
            &link.send_completion,
            link,
            sendCallback,
        );
    }

    fn maybeSendInterested(self: *Downloader, link: *PeerLink) !void {
        if (!link.want_interested) return;
        if (link.sent_interested) return;
        if (link.send_in_flight) return;
        const hdr = peer_wire.serializeHeader(2, &.{});
        @memcpy(link.send_buf[0..hdr.len], &hdr);
        try self.submitSend(link, link.send_buf[0..hdr.len]);
        link.sent_interested = true;
    }

    /// Pick the next healthy peer for the given piece. Cycles through
    /// peers starting at `start_offset`; returns null if every peer is
    /// banned or already attempted this piece in the current round.
    fn pickPeerFor(self: *Downloader, piece_index: u32, start_offset: u8) ?*PeerLink {
        _ = piece_index;
        var i: u8 = 0;
        while (i < num_peers) : (i += 1) {
            const idx: u8 = @intCast((start_offset + i) % num_peers);
            const link = &self.links[idx];
            if (link.banned) continue;
            if (!link.unchoke_received) continue;
            if (link.awaiting_piece != null) continue;
            // Skip links whose send slot is busy — typically the
            // interested send fired by `processMessage(.bitfield)` is
            // still in flight when the unchoke arrives in the same chunk.
            // The next sendCallback re-runs pumpRequests once the slot
            // frees up.
            if (link.send_in_flight) continue;
            return link;
        }
        return null;
    }

    /// Submit a request for `piece_index` to the given link.
    fn requestPiece(self: *Downloader, link: *PeerLink, piece_index: u32) !void {
        std.debug.assert(link.awaiting_piece == null);
        std.debug.assert(!link.banned);
        const req = peer_wire.serializeRequest(.{
            .piece_index = piece_index,
            .block_offset = 0,
            .length = block_size,
        });
        @memcpy(link.send_buf[0..req.len], &req);
        try self.submitSend(link, link.send_buf[0..req.len]);
        link.awaiting_piece = piece_index;
        self.total_block_attempts += 1;
    }

    /// True when every peer has reached the post-unchoke state — at which
    /// point we can deterministically rotate piece requests through the
    /// full peer set. Without this gate, faster honest peers would race
    /// ahead and grab every piece before the corrupt peer's unchoke
    /// arrives, leaving smart-ban with nothing to detect.
    fn allPeersReady(self: *const Downloader) bool {
        for (&self.links) |*link| {
            if (!link.unchoke_received) return false;
        }
        return true;
    }

    /// Try to schedule outstanding piece work. Called after every state
    /// change that could unblock a request. Skips pieces that are already
    /// verified or in flight. Until all peers are unchoked, this is a
    /// no-op so the corrupt peer's unchoke isn't out-raced by the honest
    /// ones.
    fn pumpRequests(self: *Downloader) !void {
        if (!self.allPeersReady()) return;

        var piece: u32 = 0;
        while (piece < piece_count) : (piece += 1) {
            if ((self.received_pieces_mask >> @as(u3, @intCast(piece))) & 1 != 0) continue;
            // Already an outstanding request for this piece?
            var outstanding = false;
            for (&self.links) |*l| {
                if (l.awaiting_piece == piece) {
                    outstanding = true;
                    break;
                }
            }
            if (outstanding) continue;
            // Initial assignment policy: send the first attempt of every
            // piece at the corrupt peer so we can stress its trust line.
            // After the corrupt peer is banned, naturally rotates to the
            // next honest peer.
            const link = self.pickPeerFor(piece, corrupt_peer_index) orelse return;
            try self.requestPiece(link, piece);
        }
    }

    fn recvCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const link: *PeerLink = @ptrCast(@alignCast(ud.?));
        const downloader = downloader_singleton.?;

        const n = switch (result) {
            .recv => |r| r catch return .disarm,
            else => return .disarm,
        };
        if (n == 0) return .disarm;
        link.recv_len += @intCast(n);
        downloader.process(link) catch return .disarm;
        if (downloader.allPiecesVerified()) return .disarm;
        downloader.armRecv(link) catch return .disarm;
        return .disarm;
    }

    fn sendCallback(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const link: *PeerLink = @ptrCast(@alignCast(ud.?));
        const downloader = downloader_singleton.?;
        link.send_in_flight = false;
        switch (result) {
            .send => |r| _ = r catch return .disarm,
            else => return .disarm,
        }
        // Drain any deferred interested send first, then drive more
        // request work now that the send slot freed.
        downloader.maybeSendInterested(link) catch return .disarm;
        downloader.pumpRequests() catch return .disarm;
        return .disarm;
    }

    fn process(self: *Downloader, link: *PeerLink) !void {
        // Handshake.
        if (!link.handshake_received) {
            if (link.recv_len < 68) return;
            if (!std.mem.eql(u8, link.recv_buf[1..20], peer_wire.protocol_string)) return error.BadHandshake;
            if (!std.mem.eql(u8, link.recv_buf[28..48], &self.info_hash)) return error.InfoHashMismatch;
            link.handshake_received = true;
            self.consume(link, 68);
        }

        while (link.recv_len >= 4) {
            const length = std.mem.readInt(u32, link.recv_buf[0..4], .big);
            const total = 4 + @as(u32, length);
            if (link.recv_len < total) return;
            try self.processMessage(link, link.recv_buf[4..total]);
            self.consume(link, total);
        }
    }

    fn processMessage(self: *Downloader, link: *PeerLink, payload: []const u8) !void {
        if (payload.len == 0) return;
        const id = payload[0];
        switch (id) {
            1 => { // unchoke — start requesting
                link.unchoke_received = true;
                try self.pumpRequests();
            },
            5 => { // bitfield — respond with interested
                link.bitfield_received = true;
                link.want_interested = true;
                try self.maybeSendInterested(link);
            },
            7 => { // piece response
                if (payload.len < 9) return error.MalformedPiece;
                const piece_index = std.mem.readInt(u32, payload[1..5], .big);
                const block_offset = std.mem.readInt(u32, payload[5..9], .big);
                _ = block_offset; // 1 block per piece
                const block = payload[9..];
                if (block.len != piece_size) return error.UnexpectedBlockLen;

                // Verify SHA-1 against the canonical hash.
                @memcpy(&self.verify_buf, block);
                var actual: [20]u8 = undefined;
                var hasher = Sha1.init(.{});
                hasher.update(&self.verify_buf);
                hasher.final(&actual);

                std.debug.assert(link.awaiting_piece != null);
                std.debug.assert(link.awaiting_piece.? == piece_index);
                link.awaiting_piece = null;
                link.blocks_received += 1;

                if (std.mem.eql(u8, &actual, &self.piece_hashes[piece_index])) {
                    // Pass.
                    self.received_pieces_mask |= @as(u8, 1) << @as(u3, @intCast(piece_index));
                    if (link.trust_points < 0) link.trust_points += 1;
                } else {
                    // Fail — penalize the peer.
                    link.hashfails +|= 1;
                    link.trust_points -|= 2;
                    if (link.trust_points <= trust_ban_threshold) link.banned = true;
                }
                // Either outcome: pump for more work. On pass, the next
                // unverified piece may now be assignable; on fail, the
                // failed piece needs reassignment.
                try self.pumpRequests();
            },
            else => {}, // ignore other messages
        }
    }

    fn consume(_: *Downloader, link: *PeerLink, n: u32) void {
        const remaining = link.recv_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, link.recv_buf[0..remaining], link.recv_buf[n..link.recv_len]);
        }
        link.recv_len = remaining;
    }

    pub fn allPiecesVerified(self: *const Downloader) bool {
        const goal: u8 = (1 << piece_count) - 1;
        return self.received_pieces_mask == goal;
    }
};

// File-scope downloader pointer — recvCallback / sendCallback need access
// to it but only the `*PeerLink` pointer is plumbed through userdata.
var downloader_singleton: ?*Downloader = null;

fn allDone(_: *Simulator) bool {
    return downloader_singleton.?.allPiecesVerified();
}

// ── The actual seeded test ────────────────────────────────

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

    // Build canonical piece data.
    const piece_data_buf = try arena.allocator().alloc(u8, piece_count * piece_size);
    for (piece_data_buf, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xff));

    const info_hash: [20]u8 = .{0xab} ** 20;
    var bitfield: [1]u8 = .{0xf0}; // 4 pieces, all present

    // Spin up 6 SimPeer seeders. Indices 0..4 are honest; index 5 is
    // corrupt (always returns wrong bytes).
    var peers: [num_peers]SimPeer = undefined;
    var downloader: Downloader = .{
        .io = &sim.io,
        .info_hash = info_hash,
        .peer_id = .{0x44} ** 20,
        .piece_data = piece_data_buf,
    };

    var i: u8 = 0;
    while (i < num_peers) : (i += 1) {
        const fds = try sim.io.createSocketpair();
        const seeder_fd = fds[0];
        const downloader_fd = fds[1];

        const behavior: SimPeerBehavior = if (i == corrupt_peer_index)
            .{ .wrong_data = {} }
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

        downloader.links[i] = .{
            .peer_index = i,
            .fd = downloader_fd,
        };
    }

    downloader_singleton = &downloader;
    defer downloader_singleton = null;
    try downloader.init();

    const ok = try sim.runUntilFine(allDone, 4096, 1_000_000);
    try testing.expect(ok);

    // Every piece must have verified.
    try testing.expect(downloader.allPiecesVerified());

    // Print final state on banner-line failure to make seed bisection easy.
    if (!downloader.links[corrupt_peer_index].banned) {
        std.debug.print(
            "\n  seed=0x{x}: corrupt peer state: trust={d}, hashfails={d}, banned={}\n",
            .{
                seed,
                downloader.links[corrupt_peer_index].trust_points,
                downloader.links[corrupt_peer_index].hashfails,
                downloader.links[corrupt_peer_index].banned,
            },
        );
        std.debug.print("  total_block_attempts={d}\n", .{downloader.total_block_attempts});
        for (downloader.links, 0..) |link, idx| {
            std.debug.print(
                "  link[{d}]: trust={d}, hashfails={d}, banned={}, blocks_received={d}\n",
                .{ idx, link.trust_points, link.hashfails, link.banned, link.blocks_received },
            );
        }
    }

    // The corrupt peer must be banned.
    try testing.expect(downloader.links[corrupt_peer_index].banned);
    try testing.expect(downloader.links[corrupt_peer_index].trust_points <= trust_ban_threshold);
    try testing.expect(downloader.links[corrupt_peer_index].hashfails >= 4);

    // No honest peer should be banned and none should have hashfails.
    var j: u8 = 0;
    while (j < num_peers) : (j += 1) {
        if (j == corrupt_peer_index) continue;
        try testing.expect(!downloader.links[j].banned);
        try testing.expectEqual(@as(u8, 0), downloader.links[j].hashfails);
        try testing.expect(downloader.links[j].trust_points >= 0);
    }
}

test "smart-ban Phase 0 protocol regression: 5 honest + 1 corrupt over 8 seeds" {
    const seeds = [_]u64{
        0x0001_0000,
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
            std.debug.print("\nSEED 0x{x} FAILED: {any}\n", .{ seed, err });
            return err;
        };
    }
}

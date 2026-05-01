//! MSE simultaneous-handshake reproduction harness.
//!
//! Targets the long-standing Known Issue in STATUS.md: "MSE handshake
//! failures in mixed encryption mode" — `vc_not_found` and
//! `req1_not_found` errors observed during simultaneous inbound +
//! outbound MSE handshakes against real peers, timing-dependent and
//! disappearing under GDB. The brief was: with SimHasher, SimClock,
//! and SimRandom now closed, drive a deterministic reproduction in
//! SimIO, diagnose, fix at root.
//!
//! The harness drives **one EventLoop with two MSE handshakes in
//! flight simultaneously**: slot A is outbound (the EL plays the
//! initiator), slot B is inbound (the EL plays the responder). The
//! peer side of each handshake is driven inline by a small async-state-
//! machine helper (`PeerMseDriver`) that reads bytes off the SimIO
//! recv queue, feeds them to an `MseResponderHandshake` /
//! `MseInitiatorHandshake`, and pushes responses back. Both sides
//! draw random bytes from a single shared `runtime.Random` per side,
//! seeded by the per-iteration test seed — so DH keys, padding lengths,
//! and padding bytes are byte-deterministic across runs.
//!
//! The "simultaneous" part matters because both EL-side state machines
//! draw from `el.random`, and both peer-side drivers draw from
//! `peer_random`. The order in which the two slots' state machines
//! advance through `tick`s interleaves their random draws — so a
//! single seed produces a single fixed handshake schedule, but
//! different seeds produce different orderings (and different
//! pad-length-driven recv/send sizing). 32 seeds is the standard
//! BUGGIFY-style coverage budget.
//!
//! Outcome (see `progress-reports/2026-04-30-mse-handshake-race.md`):
//!   * 32/32 seeds complete both handshakes successfully under SimIO.
//!   * Neither `vc_not_found` nor `req1_not_found` reproduces.
//!   * The historical real-io_uring race is structurally precluded by
//!     SimIO's stricter completion lifecycle (closeSocket immediately
//!     fails the parked recv before the slot is reused; `peer.* =
//!     Peer{}` zeroes the embedded `_backend_state`, but armCompletion
//!     re-initialises it on the next submission). The defensive guards
//!     audited in this round close the equivalent gap on RealIO.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const event_loop_mod = varuna.io.event_loop;
const mse = varuna.crypto.mse;
const Random = varuna.runtime.Random;
const Hasher = varuna.io.hasher.Hasher;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);

// ── PeerMseDriver — the "remote peer" side of an MSE handshake ──

/// Drives one MSE handshake state machine against a SimIO socket. Used
/// to play the counterparty for an EventLoop-side MSE handshake.
const PeerMseDriver = struct {
    pub const Outcome = enum { in_progress, complete, failed };

    io: *SimIO,
    fd: posix.fd_t,
    role: enum { initiator, responder },

    initiator: ?*mse.MseInitiatorHandshake = null,
    responder: ?*mse.MseResponderHandshake = null,

    /// Owned by the test. Drives DH private-key generation, padding
    /// lengths, and padding bytes for *this* side of the handshake.
    /// Distinct from the EventLoop's `el.random` so the two streams
    /// don't interleave.
    random: *Random,

    recv_buf: [2048]u8 = undefined,
    /// Bytes pending dispatch to the state machine. The recv callback
    /// just appends; `pump` decides when to feed.
    recv_len: usize = 0,
    recv_in_flight: bool = false,

    send_buf: [2048]u8 = undefined,
    send_len: usize = 0,
    send_in_flight: bool = false,

    /// What slice the state machine asked us to recv into. We carry
    /// this between actions so a single recv can satisfy a multi-byte
    /// request without committing to a state-machine transition until
    /// we have all of it.
    pending_recv: ?[]u8 = null,
    pending_recv_offset: usize = 0,

    outcome: Outcome = .in_progress,
    failure: ?mse.MseError = null,

    recv_completion: Completion = .{},
    send_completion: Completion = .{},

    pub fn initInitiator(
        self: *PeerMseDriver,
        io: *SimIO,
        fd: posix.fd_t,
        random: *Random,
        info_hash: [20]u8,
        mode: mse.EncryptionMode,
        backing: *mse.MseInitiatorHandshake,
    ) !void {
        self.* = .{
            .io = io,
            .fd = fd,
            .role = .initiator,
            .random = random,
            .initiator = backing,
        };
        backing.* = mse.MseInitiatorHandshake.init(random, info_hash, mode);
        // First action is always a send (Ya + PadA).
        const action = backing.start();
        try self.applyAction(action);
    }

    pub fn initResponder(
        self: *PeerMseDriver,
        io: *SimIO,
        fd: posix.fd_t,
        random: *Random,
        known_hashes: []const [20]u8,
        mode: mse.EncryptionMode,
        backing: *mse.MseResponderHandshake,
    ) !void {
        self.* = .{
            .io = io,
            .fd = fd,
            .role = .responder,
            .random = random,
            .responder = backing,
        };
        backing.* = mse.MseResponderHandshake.init(random, known_hashes, mode);
        // First action is always a recv (Ya).
        const action = backing.start();
        try self.applyAction(action);
    }

    fn applyAction(self: *PeerMseDriver, action: mse.MseAction) !void {
        switch (action) {
            .send => |data| {
                // Copy into our send_buf so the bytes outlive the SQE.
                std.debug.assert(data.len <= self.send_buf.len);
                @memcpy(self.send_buf[0..data.len], data);
                self.send_len = data.len;
                try self.submitSend();
            },
            .recv => |buf| {
                self.pending_recv = buf;
                self.pending_recv_offset = 0;
                if (!self.recv_in_flight) {
                    try self.submitRecv();
                }
            },
            .complete => self.outcome = .complete,
            .failed => |err| {
                self.outcome = .failed;
                self.failure = err;
            },
        }
    }

    fn submitRecv(self: *PeerMseDriver) !void {
        std.debug.assert(!self.recv_in_flight);
        self.recv_in_flight = true;
        try self.io.recv(
            .{ .fd = self.fd, .buf = &self.recv_buf },
            &self.recv_completion,
            self,
            recvCb,
        );
    }

    fn submitSend(self: *PeerMseDriver) !void {
        std.debug.assert(!self.send_in_flight);
        self.send_in_flight = true;
        try self.io.send(
            .{ .fd = self.fd, .buf = self.send_buf[0..self.send_len] },
            &self.send_completion,
            self,
            sendCb,
        );
    }

    fn recvCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *PeerMseDriver = @ptrCast(@alignCast(ud.?));
        self.recv_in_flight = false;
        const n = switch (result) {
            .recv => |r| r catch {
                self.outcome = .failed;
                self.failure = .connection_closed;
                return .disarm;
            },
            else => return .disarm,
        };
        if (n == 0) {
            self.outcome = .failed;
            self.failure = .connection_closed;
            return .disarm;
        }
        self.recv_len = n;
        // Feed bytes to the state machine.
        self.feedRecv() catch |err| {
            std.log.err("PeerMseDriver feedRecv error: {s}", .{@errorName(err)});
            self.outcome = .failed;
            self.failure = .internal;
        };
        return .disarm;
    }

    fn sendCb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
        const self: *PeerMseDriver = @ptrCast(@alignCast(ud.?));
        self.send_in_flight = false;
        _ = switch (result) {
            .send => |r| r catch {
                self.outcome = .failed;
                self.failure = .connection_closed;
                return .disarm;
            },
            else => return .disarm,
        };
        // Forward send to state machine.
        const action = switch (self.role) {
            .initiator => self.initiator.?.feedSend(),
            .responder => self.responder.?.feedSend(),
        };
        self.applyAction(action) catch |err| {
            std.log.err("PeerMseDriver applyAction error: {s}", .{@errorName(err)});
            self.outcome = .failed;
            self.failure = .internal;
        };
        return .disarm;
    }

    /// Distribute received bytes to the state machine in chunks
    /// matching its recv-buffer requests. The state machine asks for
    /// `[]u8` slices via `MseAction.recv`; we feed exactly that many
    /// bytes at a time, then call `feedRecv(n)` and process the
    /// returned action.
    fn feedRecv(self: *PeerMseDriver) !void {
        var src_offset: usize = 0;
        while (src_offset < self.recv_len) {
            const dst = self.pending_recv orelse {
                // No outstanding recv-buf request; the state machine
                // is between phases. Drop the rest — shouldn't
                // happen if we're submit-recv'ing one chunk at a
                // time, but defensive.
                return;
            };
            const want = dst.len - self.pending_recv_offset;
            if (want == 0) {
                // Already filled this slice; await next action.
                return;
            }
            const take = @min(want, self.recv_len - src_offset);
            @memcpy(
                dst[self.pending_recv_offset .. self.pending_recv_offset + take],
                self.recv_buf[src_offset .. src_offset + take],
            );
            self.pending_recv_offset += take;
            src_offset += take;

            if (self.pending_recv_offset == dst.len) {
                // Buffer satisfied — feed the state machine.
                const n = self.pending_recv_offset;
                self.pending_recv = null;
                self.pending_recv_offset = 0;
                const action = switch (self.role) {
                    .initiator => self.initiator.?.feedRecv(n),
                    .responder => self.responder.?.feedRecv(n),
                };
                try self.applyAction(action);
                if (self.outcome != .in_progress) return;
            } else {
                // Need more bytes; keep going through recv_buf if any.
                continue;
            }
        }
        // If we still have an outstanding recv-buf and no in-flight
        // recv (the state machine asked for a slice we couldn't fully
        // satisfy from this chunk), arm the next recv.
        if (self.pending_recv != null and !self.recv_in_flight and self.outcome == .in_progress) {
            try self.submitRecv();
        }
    }
};

// ── Test fixture ──────────────────────────────────────────────

/// Outcome of a single seed run.
const RunResult = struct {
    out_outcome: PeerMseDriver.Outcome,
    out_failure: ?mse.MseError,
    in_outcome: PeerMseDriver.Outcome,
    in_failure: ?mse.MseError,
    el_outbound_completed: bool,
    el_inbound_completed: bool,
};

/// SimIO fault-injection knobs shared across faulted scenarios.
const FaultKnobs = struct {
    recv_error_probability: f32 = 0.0,
    send_error_probability: f32 = 0.0,
    recv_latency_ns: u64 = 0,
    send_latency_ns: u64 = 0,
};

fn runSimultaneous(seed: u64) !RunResult {
    return runSimultaneousFaults(seed, .{});
}

/// Drive one simultaneous-handshake scenario and report the outcome.
fn runSimultaneousFaults(seed: u64, knobs: FaultKnobs) !RunResult {
    const allocator = testing.allocator;

    // ── EventLoop with SimIO + SimHasher + SimRandom ───────────
    const sim_io = try SimIO.init(allocator, .{
        .seed = seed,
        .socket_capacity = 16,
        .recv_queue_capacity_bytes = 64 * 1024,
        .pending_capacity = 4096,
        .faults = .{
            .recv_error_probability = knobs.recv_error_probability,
            .send_error_probability = knobs.send_error_probability,
            .recv_latency_ns = knobs.recv_latency_ns,
            .send_latency_ns = knobs.send_latency_ns,
        },
    });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();
    el.random = Random.simRandom(seed);
    el.encryption_mode = .preferred;
    el.hasher = try Hasher.simInit(allocator, seed ^ 0xa5a5);

    // ── Torrent context (info-hash registration drives the MSE
    //    responder lookup) ─────────────────────────────────────
    var info_hash: [20]u8 = undefined;
    var hash_rng = Random.simRandom(seed ^ 0xfeed);
    hash_rng.bytes(&info_hash);
    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = info_hash,
        .peer_id = [_]u8{0xAA} ** 20,
    });

    // ── Outbound socketpair: EL is the initiator, peer is responder.
    const out_pair = try el.io.createSocketpair();
    const out_local = out_pair[0];
    const out_peer = out_pair[1];

    // ── Inbound socketpair: EL is the responder, peer is initiator.
    const in_pair = try el.io.createSocketpair();
    const in_local = in_pair[0];
    const in_peer = in_pair[1];

    // The peer side gets its own random stream so the EL and peer
    // don't interleave draws against the same RNG. Each side is
    // deterministic for a given seed.
    var peer_random_out = Random.simRandom(seed ^ 0xbeef_0001);
    var peer_random_in = Random.simRandom(seed ^ 0xbeef_0002);

    var out_initiator_backing: mse.MseInitiatorHandshake = undefined;
    _ = &out_initiator_backing;
    var out_responder_backing: mse.MseResponderHandshake = undefined;
    var in_initiator_backing: mse.MseInitiatorHandshake = undefined;

    var out_driver: PeerMseDriver = undefined;
    var in_driver: PeerMseDriver = undefined;

    // ── Wire up OUTBOUND (EL initiates, peer responds) ─────────
    //
    // Enqueue the local fd so the EL's next `io.socket()` resolves
    // to it, then call `addPeerForTorrent`. The EL submits socket()
    // → socket completes synchronously inside SimIO → handleSocketResult
    // submits connect() → connect completes synchronously →
    // handleConnectResult sees `encryption_mode = .preferred` and
    // starts the MSE initiator.
    try el.io.enqueueSocketResult(out_local);
    const out_addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);
    const out_slot = try el.addPeerForTorrent(out_addr, tid);

    // Drive the OUTBOUND peer side as a responder. The state machine
    // is allocated on the test stack; the driver borrows it.
    const known_hashes = [_][20]u8{info_hash};
    try out_driver.initResponder(
        &el.io,
        out_peer,
        &peer_random_out,
        &known_hashes,
        .preferred,
        &out_responder_backing,
    );

    // ── Wire up INBOUND (peer initiates, EL responds) ──────────
    //
    // `addInboundPeer` parks the EL slot in `.inbound_handshake_recv`
    // with a recv submitted on peer.handshake_buf. The peer's
    // initiator drives Ya + PadA into the socket; the EL detects the
    // non-BT first byte via `detectAndHandleInboundMse` and starts
    // the MSE responder. Both halves of the socketpair must be live
    // before `addInboundPeer` arms the recv (otherwise the partner
    // is closed when the recv parks).
    const in_addr = std.net.Address.initIp4(.{ 10, 0, 0, 2 }, 6881);
    const in_slot = try el.addInboundPeer(tid, in_local, in_addr);

    try in_driver.initInitiator(
        &el.io,
        in_peer,
        &peer_random_in,
        info_hash,
        .preferred,
        &in_initiator_backing,
    );

    // ── Tick until both sides resolve ─────────────────────────
    const max_ticks: u32 = 256;
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        try el.tick();
        if (out_driver.outcome != .in_progress and
            in_driver.outcome != .in_progress)
        {
            // Drive a couple of extra ticks so the EL absorbs any
            // remaining sends from the peer-side's last action and
            // clears its own state machine.
            for (0..4) |_| try el.tick();
            break;
        }
    }

    // The EL signals success by clearing peer.mse_initiator /
    // peer.mse_responder and setting peer.crypto. Inspect the slot.
    const out_peer_slot = &el.peers[out_slot];
    const in_peer_slot = &el.peers[in_slot];
    const out_completed = out_peer_slot.mse_initiator == null and
        out_peer_slot.crypto.crypto_method == mse.crypto_rc4;
    const in_completed = in_peer_slot.mse_responder == null and
        in_peer_slot.crypto.crypto_method == mse.crypto_rc4;

    return .{
        .out_outcome = out_driver.outcome,
        .out_failure = out_driver.failure,
        .in_outcome = in_driver.outcome,
        .in_failure = in_driver.failure,
        .el_outbound_completed = out_completed,
        .el_inbound_completed = in_completed,
    };
}

// ── Tests ────────────────────────────────────────────────────

test "MSE simultaneous inbound+outbound handshake completes (single seed sanity)" {
    const result = try runSimultaneous(0xdead_beef);

    if (result.out_outcome == .failed) {
        std.log.err("outbound peer-side failed: {?s}", .{
            if (result.out_failure) |f| @tagName(f) else null,
        });
    }
    if (result.in_outcome == .failed) {
        std.log.err("inbound peer-side failed: {?s}", .{
            if (result.in_failure) |f| @tagName(f) else null,
        });
    }

    try testing.expectEqual(PeerMseDriver.Outcome.complete, result.out_outcome);
    try testing.expectEqual(PeerMseDriver.Outcome.complete, result.in_outcome);
    try testing.expect(result.el_outbound_completed);
    try testing.expect(result.el_inbound_completed);
}

test "MSE removePeer during in-flight handshake — does not crash or corrupt next slot" {
    // Targets the historical Known Issue: "Timing-dependent crash in
    // `checkPeerTimeouts -> removePeer -> cleanupPeer` when both inbound
    // and outbound MSE handshakes are in flight." We force a removePeer
    // mid-handshake (simulating what checkPeerTimeouts would do on a
    // stalled outbound peer) and assert: (1) no crash, (2) the slot is
    // free afterwards, (3) re-using the slot for a fresh inbound
    // handshake completes successfully.
    const allocator = testing.allocator;

    const seeds = [_]u64{ 0x1, 0x42, 0xc0ffee, 0xfeedface, 0xdeadbeef, 0xfade_face, 0xa5a5_a5a5, 0x5555_aaaa };

    for (seeds) |seed| {
        const sim_io = try SimIO.init(allocator, .{
            .seed = seed,
            .socket_capacity = 16,
            .recv_queue_capacity_bytes = 64 * 1024,
            .pending_capacity = 4096,
        });
        var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
            if (err == error.SystemResources) return error.SkipZigTest;
            return err;
        };
        defer el.deinit();
        el.random = Random.simRandom(seed);
        el.encryption_mode = .preferred;
        el.hasher = try Hasher.simInit(allocator, seed ^ 0xa5a5);

        var info_hash: [20]u8 = undefined;
        var hash_rng = Random.simRandom(seed ^ 0xfeed);
        hash_rng.bytes(&info_hash);
        const empty_fds = [_]posix.fd_t{};
        const tid = try el.addTorrentContext(.{
            .shared_fds = empty_fds[0..],
            .info_hash = info_hash,
            .peer_id = [_]u8{0xAA} ** 20,
        });

        // Step 1: outbound MSE handshake in progress.
        const out_pair = try el.io.createSocketpair();
        try el.io.enqueueSocketResult(out_pair[0]);
        const out_addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);
        const out_slot = try el.addPeerForTorrent(out_addr, tid);

        // Drive a few ticks so the MSE state machine advances — at
        // this point peer.mse_initiator is allocated and a recv is
        // outstanding into its scan_buf / peer_public_key.
        for (0..4) |_| try el.tick();

        // The peer should be MID-HANDSHAKE: mse_initiator allocated.
        try testing.expect(el.peers[out_slot].mse_initiator != null);

        // Step 2: forcibly remove the peer (simulates checkPeerTimeouts
        // firing on a stalled MSE handshake).
        el.removePeer(out_slot);
        try testing.expectEqual(varuna.io.event_loop.PeerState.disconnecting, el.peers[out_slot].state);

        // Drive ticks so any pending CQEs (the closeSocket-fired
        // recv-error CQE) drain on the quarantined slot. The slot only
        // returns to .free after the stale CQE has fired.
        for (0..8) |_| try el.tick();
        try testing.expectEqual(varuna.io.event_loop.PeerState.free, el.peers[out_slot].state);

        // Step 3: re-use the slot for a NEW inbound MSE handshake.
        // If the historical race exists, the OLD recv CQE arriving
        // late + new MSE state allocation would cross-contaminate
        // the new state.
        const in_pair = try el.io.createSocketpair();
        const in_addr = std.net.Address.initIp4(.{ 10, 0, 0, 2 }, 6881);
        const in_slot = try el.addInboundPeer(tid, in_pair[0], in_addr);
        try testing.expectEqual(out_slot, in_slot); // slot reuse

        var peer_random_in = Random.simRandom(seed ^ 0xbeef_0002);
        var in_initiator_backing: mse.MseInitiatorHandshake = undefined;
        var in_driver: PeerMseDriver = undefined;
        try in_driver.initInitiator(
            &el.io,
            in_pair[1],
            &peer_random_in,
            info_hash,
            .preferred,
            &in_initiator_backing,
        );

        var ticks: u32 = 0;
        while (ticks < 256) : (ticks += 1) {
            try el.tick();
            if (in_driver.outcome != .in_progress) {
                for (0..4) |_| try el.tick();
                break;
            }
        }

        try testing.expectEqual(PeerMseDriver.Outcome.complete, in_driver.outcome);
        try testing.expect(el.peers[in_slot].mse_responder == null);
        try testing.expectEqual(mse.crypto_rc4, el.peers[in_slot].crypto.crypto_method);
    }
}

test "MSE removePeer with delayed close CQE quarantines slot until stale recv drains" {
    const allocator = testing.allocator;
    const seed: u64 = 0x5151_2026;

    const sim_io = try SimIO.init(allocator, .{
        .seed = seed,
        .socket_capacity = 16,
        .recv_queue_capacity_bytes = 64 * 1024,
        .pending_capacity = 4096,
        .faults = .{
            .delayed_close_cqe_min_ticks = 16,
            .delayed_close_cqe_max_ticks = 16,
        },
    });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();
    el.random = Random.simRandom(seed);
    el.encryption_mode = .preferred;
    el.hasher = try Hasher.simInit(allocator, seed ^ 0xa5a5);

    var info_hash: [20]u8 = undefined;
    var hash_rng = Random.simRandom(seed ^ 0xfeed);
    hash_rng.bytes(&info_hash);
    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = info_hash,
        .peer_id = [_]u8{0xAA} ** 20,
    });

    const out_pair = try el.io.createSocketpair();
    try el.io.enqueueSocketResult(out_pair[0]);
    const out_addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);
    const out_slot = try el.addPeerForTorrent(out_addr, tid);

    for (0..4) |_| try el.tick();
    try testing.expect(el.peers[out_slot].mse_initiator != null);

    el.removePeer(out_slot);
    try testing.expectEqual(varuna.io.event_loop.PeerState.disconnecting, el.peers[out_slot].state);

    const in_pair = try el.io.createSocketpair();
    const in_addr = std.net.Address.initIp4(.{ 10, 0, 0, 2 }, 6881);
    const in_slot = try el.addInboundPeer(tid, in_pair[0], in_addr);
    try testing.expect(in_slot != out_slot);

    var peer_random_in = Random.simRandom(seed ^ 0xbeef_0002);
    var in_initiator_backing: mse.MseInitiatorHandshake = undefined;
    var in_driver: PeerMseDriver = undefined;
    try in_driver.initInitiator(
        &el.io,
        in_pair[1],
        &peer_random_in,
        info_hash,
        .preferred,
        &in_initiator_backing,
    );

    var ticks: u32 = 0;
    while (ticks < 256) : (ticks += 1) {
        try el.tick();
        if (in_driver.outcome != .in_progress and
            el.peers[out_slot].state == .free)
        {
            for (0..4) |_| try el.tick();
            break;
        }
    }

    try testing.expectEqual(varuna.io.event_loop.PeerState.free, el.peers[out_slot].state);
    try testing.expectEqual(PeerMseDriver.Outcome.complete, in_driver.outcome);
    try testing.expect(el.peers[in_slot].mse_responder == null);
    try testing.expectEqual(mse.crypto_rc4, el.peers[in_slot].crypto.crypto_method);
}

test "MSE handshake under recv-error injection (8 seeds × 0.05 fault prob)" {
    // BUGGIFY-style fault injection: each recv has a 5% chance of
    // returning ConnectionResetByPeer. We expect SOME handshakes to
    // fail (the connection is forcibly reset) but the EL must NOT
    // crash and the MSE state machine must NOT confuse a reset with
    // a vc_not_found / req1_not_found verdict.
    const seeds = [_]u64{
        0x0,      0x1,        0xdead,     0xbeef,
        0xc0ffee, 0xfacefeed, 0xdeadbeef, 0xfadeface,
    };

    var state_corruption_seen: u32 = 0;
    var resets_seen: u32 = 0;
    var clean_runs: u32 = 0;

    for (seeds) |seed| {
        const result = try runSimultaneousFaults(seed, .{
            .recv_error_probability = 0.05,
            .recv_latency_ns = 0,
        });
        const both_complete = result.out_outcome == .complete and
            result.in_outcome == .complete and
            result.el_outbound_completed and
            result.el_inbound_completed;
        if (both_complete) {
            clean_runs += 1;
            continue;
        }
        // Failure must be a connection_closed (the reset propagated)
        // OR vc_not_found / req1_not_found from leftover bytes that
        // matched the partial-decrypt heuristic. The latter would be
        // a regression: state corruption from interleaved handshakes.
        if (result.out_failure) |f| switch (f) {
            .connection_closed => resets_seen += 1,
            .vc_not_found, .req1_not_found => {
                state_corruption_seen += 1;
                std.log.warn(
                    "seed=0x{x}: out_failure={s} — possible state corruption",
                    .{ seed, @tagName(f) },
                );
            },
            else => resets_seen += 1, // other MSE errors are valid under reset
        };
        if (result.in_failure) |f| switch (f) {
            .connection_closed => resets_seen += 1,
            .vc_not_found, .req1_not_found => {
                state_corruption_seen += 1;
                std.log.warn(
                    "seed=0x{x}: in_failure={s} — possible state corruption",
                    .{ seed, @tagName(f) },
                );
            },
            else => resets_seen += 1,
        };
    }

    std.log.warn(
        "MSE recv-fault summary: {d}/{d} clean, {d} resets observed, {d} state-corruption candidates",
        .{ clean_runs, seeds.len, resets_seen, state_corruption_seen },
    );

    // The race fix is asserted by: zero state-corruption candidates.
    // (Resets are expected; what we don't tolerate is the historical
    // vc_not_found / req1_not_found cross-handshake symptom.)
    try testing.expectEqual(@as(u32, 0), state_corruption_seen);
}

test "MSE simultaneous inbound+outbound handshake — 32 seed sweep" {
    // Spread of seeds that historically exercised different orderings
    // in BUGGIFY-style tests across this codebase. If the
    // simultaneous-handshake race can be reproduced under SimIO +
    // SimRandom + SimHasher, at least one of these seeds should hit
    // a vc_not_found / req1_not_found failure.
    const seeds = [_]u64{
        0x0,         0x1,         0xdead,      0xbeef,
        0xc0ffee,    0xfacefeed,  0xdeadbeef,  0xfadeface,
        0x12345678,  0x87654321,  0xa5a5a5a5,  0x5a5a5a5a,
        0xfeedface,  0xcafebabe,  0xb16b00b5,  0xdeadc0de,
        0x12121212,  0x34343434,  0x56565656,  0x78787878,
        0x9abc_def0, 0x0fed_cba9, 0x1111_aaaa, 0xaaaa_1111,
        0xbbbb_2222, 0x2222_bbbb, 0xcccc_3333, 0x3333_cccc,
        0xdddd_4444, 0x4444_dddd, 0xeeee_5555, 0x5555_eeee,
    };

    var failures: u32 = 0;
    var vc_not_found_count: u32 = 0;
    var req1_not_found_count: u32 = 0;
    var first_failed_seed: ?u64 = null;

    for (seeds) |seed| {
        const result = try runSimultaneous(seed);
        const ok = result.out_outcome == .complete and
            result.in_outcome == .complete and
            result.el_outbound_completed and
            result.el_inbound_completed;
        if (!ok) {
            failures += 1;
            if (first_failed_seed == null) first_failed_seed = seed;
            if (result.out_failure) |f| {
                if (f == .vc_not_found) vc_not_found_count += 1;
                if (f == .req1_not_found) req1_not_found_count += 1;
            }
            if (result.in_failure) |f| {
                if (f == .vc_not_found) vc_not_found_count += 1;
                if (f == .req1_not_found) req1_not_found_count += 1;
            }
            std.log.warn(
                "seed=0x{x} out_outcome={s} out_failure={?s} in_outcome={s} in_failure={?s} el_out_completed={} el_in_completed={}",
                .{
                    seed,
                    @tagName(result.out_outcome),
                    if (result.out_failure) |f| @tagName(f) else null,
                    @tagName(result.in_outcome),
                    if (result.in_failure) |f| @tagName(f) else null,
                    result.el_outbound_completed,
                    result.el_inbound_completed,
                },
            );
        }
    }

    std.log.warn(
        "MSE simultaneous handshake summary: {d}/{d} seeds OK, {d} vc_not_found, {d} req1_not_found",
        .{ seeds.len - failures, seeds.len, vc_not_found_count, req1_not_found_count },
    );

    try testing.expectEqual(@as(u32, 0), failures);
}

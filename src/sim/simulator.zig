//! Simulator — drives `SimIO`, a `SimSwarm`, and (eventually) an
//! `EventLoop(SimIO)` deterministically under a seeded clock.
//!
//! The simulator owns a fixed-capacity swarm of `*SimPeer` pointers, a
//! seeded `std.Random.DefaultPrng`, and a logical clock measured in
//! nanoseconds. `step(delta_ns)` advances the clock by `delta_ns`, calls
//! `step` on each swarm peer, then ticks the IO backend so any newly-due
//! completions fire.
//!
//! Step granularity: callers can either pass a fixed `step_ns` to
//! `runUntil` (coarser-grained, easier to reason about) or use
//! `runUntilFine` which jumps the clock directly to the next pending
//! deadline. The fine variant produces fewer ticks, less RNG churn, and
//! deterministic completion ordering — preferred when behaviour depends on
//! ordering (e.g. smart-ban tests that mix honest and corrupt blocks).
//!
//! Once `EventLoop` is parameterised over its IO backend (Stage 2 #12), a
//! `Simulator` configured with `attach_event_loop = true` will additionally
//! own an `EventLoop(SimIO)` and tick it inside `step`. Until then, the
//! simulator is the right shape for SimPeer ↔ SimPeer integration tests
//! (which exercise the wire protocol end-to-end without an EventLoop).

const std = @import("std");
const assert = std.debug.assert;

const sim_io_mod = @import("../io/sim_io.zig");
const sim_peer_mod = @import("sim_peer.zig");

const SimIO = sim_io_mod.SimIO;
const SimPeer = sim_peer_mod.SimPeer;

/// Sentinel deadline used by SimIO for parked entries (`accept`). When
/// scanning the heap for the next-due deadline we treat anything at or
/// above this as "no work scheduled".
const sentinel_deadline_ns: u64 = std.math.maxInt(u64) / 2;

pub const BuggifyConfig = struct {
    /// Per-step probability of injecting a fault into a randomly-chosen
    /// in-flight operation. 0.0 disables BUGGIFY entirely; values in
    /// [1e-3, 1e-1] are typical for stress-testing the smart-ban swarm.
    probability: f32 = 0.0,
    /// Optional log sink: when set, each injection writes a line of the
    /// form `"fault injected: <op>\n"` so failing seeds are diagnosable.
    /// Pass `null` (default) for silent injection.
    log: ?std.fs.File = null,
};

pub const Config = struct {
    /// Maximum number of `SimPeer` pointers the swarm can hold.
    swarm_capacity: u32 = 32,
    /// Seed for the simulator's own PRNG. Independent of `SimIO`'s seed
    /// so the swarm and the IO backend can be reseeded separately.
    seed: u64 = 0,
    /// Pass-through to SimIO.init.
    sim_io: sim_io_mod.Config = .{},
    /// BUGGIFY (TigerBeetle VOPR-style) randomized fault injection.
    buggify: BuggifyConfig = .{},
};

pub const Simulator = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    io: SimIO,
    buggify: BuggifyConfig,

    /// Logical clock in nanoseconds. Independent of `SimIO.now_ns` so the
    /// simulator can advance state machines (peer step, future EventLoop
    /// tick) on the same timeline that drives IO.
    clock_ns: u64 = 0,

    /// Counter incremented on every successful BUGGIFY injection. Tests
    /// inspect this to confirm BUGGIFY actually fired.
    buggify_hits: u32 = 0,

    /// Fixed-capacity swarm of peer pointers. Caller-owned; the simulator
    /// stores a slot but doesn't allocate the SimPeer.
    swarm: []?*SimPeer,
    swarm_len: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Simulator {
        const slots = try allocator.alloc(?*SimPeer, config.swarm_capacity);
        errdefer allocator.free(slots);
        @memset(slots, null);

        var io = try SimIO.init(allocator, config.sim_io);
        errdefer io.deinit();

        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(config.seed),
            .io = io,
            .buggify = config.buggify,
            .swarm = slots,
        };
    }

    pub fn deinit(self: *Simulator) void {
        self.io.deinit();
        self.allocator.free(self.swarm);
        self.* = undefined;
    }

    /// Add a peer to the swarm. The caller owns the peer's memory; the
    /// simulator just records the pointer so `step` can drive it.
    pub fn addPeer(self: *Simulator, peer: *SimPeer) !void {
        if (self.swarm_len == self.swarm.len) return error.SwarmCapacityExhausted;
        self.swarm[self.swarm_len] = peer;
        self.swarm_len += 1;
    }

    /// Advance the simulated clock by `delta_ns`, drive every swarm peer
    /// once, optionally inject a BUGGIFY fault, then tick the IO backend.
    pub fn step(self: *Simulator, delta_ns: u64) !void {
        self.clock_ns += delta_ns;
        // Keep SimIO's clock in lockstep so `recv_latency_ns`/timeouts
        // resolve against the same timeline.
        self.io.now_ns = self.clock_ns;

        var i: u32 = 0;
        while (i < self.swarm_len) : (i += 1) {
            if (self.swarm[i]) |peer| {
                try peer.step(self.clock_ns);
            }
        }

        // BUGGIFY: with probability `buggify.probability`, mutate a random
        // pending op's result so its callback fires with an injected
        // fault. The deadline is unchanged so heap order is preserved.
        if (self.buggify.probability > 0) {
            if (self.rng.random().float(f32) < self.buggify.probability) {
                if (self.io.injectRandomFault(&self.rng)) |hit| {
                    self.buggify_hits += 1;
                    if (self.buggify.log) |log| {
                        // One short line per injection — failing seeds
                        // can grep the log to find the trigger.
                        var name_buf: [32]u8 = undefined;
                        const tag_name = @tagName(hit.op_tag);
                        const n = @min(name_buf.len, tag_name.len);
                        @memcpy(name_buf[0..n], tag_name[0..n]);
                        const line = std.fmt.bufPrint(
                            &name_buf,
                            "fault injected: {s}\n",
                            .{tag_name},
                        ) catch return self.io.tick();
                        _ = log.write(line) catch {};
                    }
                }
            }
        }

        try self.io.tick();
    }

    /// Run `step(step_ns)` until either `cond(self) == true` or
    /// `max_steps` iterations elapse. Returns true when `cond` succeeded.
    /// Use this when the test wants explicit time pressure (e.g. modeling
    /// a 5 ms RTT).
    pub fn runUntil(
        self: *Simulator,
        comptime cond: fn (sim: *Simulator) bool,
        max_steps: u32,
        step_ns: u64,
    ) !bool {
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            if (cond(self)) return true;
            try self.step(step_ns);
        }
        return cond(self);
    }

    /// Run `step` repeatedly, jumping the clock directly to the next
    /// pending deadline each iteration. Produces minimum tick count and
    /// avoids redundant RNG churn from steps where nothing is due. If
    /// the heap is empty (no scheduled work), advances by `idle_step_ns`
    /// so the swarm peers still get to run their `step` callbacks.
    pub fn runUntilFine(
        self: *Simulator,
        comptime cond: fn (sim: *Simulator) bool,
        max_steps: u32,
        idle_step_ns: u64,
    ) !bool {
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            if (cond(self)) return true;
            const next = self.nextPendingDeadlineNs();
            if (next) |deadline| {
                if (deadline > self.clock_ns) {
                    try self.step(deadline - self.clock_ns);
                } else {
                    try self.step(0);
                }
            } else {
                try self.step(idle_step_ns);
            }
        }
        return cond(self);
    }

    /// Earliest deadline currently in the SimIO heap, or null if no
    /// schedulable work exists. Returns null for parked-recv-only states
    /// (no heap entries).
    pub fn nextPendingDeadlineNs(self: *const Simulator) ?u64 {
        if (self.io.pending_len == 0) return null;
        const d = self.io.pending[0].deadline_ns;
        // Treat the "never fires" sentinel as no work.
        if (d >= sentinel_deadline_ns) return null;
        return d;
    }
};

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;
const ifc = @import("../io/io_interface.zig");
const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

test "Simulator init / deinit cleanly with empty swarm" {
    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();
    try testing.expectEqual(@as(u32, 0), sim.swarm_len);
    try testing.expectEqual(@as(u64, 0), sim.clock_ns);
}

test "Simulator.step advances clock and ticks IO" {
    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();

    const FireCounter = struct { count: u32 = 0 };
    var ctx = FireCounter{};

    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            const c: *FireCounter = @ptrCast(@alignCast(ud.?));
            c.count += 1;
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try sim.io.timeout(.{ .ns = 1_000_000 }, &c, &ctx, cb);

    // Step well past the deadline.
    try sim.step(2_000_000);
    try testing.expectEqual(@as(u32, 1), ctx.count);
    try testing.expectEqual(@as(u64, 2_000_000), sim.clock_ns);
}

test "Simulator.runUntil stops as soon as condition holds" {
    const State = struct {
        var seen_steps: u32 = 0;
        fn cond(_: *Simulator) bool {
            seen_steps += 1;
            return seen_steps >= 3;
        }
    };

    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();

    State.seen_steps = 0;
    const ok = try sim.runUntil(State.cond, 100, 1_000_000);
    try testing.expect(ok);
    // cond fires once before the loop's first step and twice across
    // subsequent iterations.
    try testing.expect(State.seen_steps >= 3);
}

test "Simulator.runUntil hits step ceiling and returns false" {
    const State = struct {
        fn never(_: *Simulator) bool {
            return false;
        }
    };

    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();

    const ok = try sim.runUntil(State.never, 5, 1_000);
    try testing.expect(!ok);
    // 5 steps × 1_000 ns each = 5_000 ns advanced.
    try testing.expectEqual(@as(u64, 5_000), sim.clock_ns);
}

test "Simulator.runUntilFine jumps to next deadline" {
    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();

    const FireCounter = struct { count: u32 = 0 };
    var ctx = FireCounter{};

    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            const c: *FireCounter = @ptrCast(@alignCast(ud.?));
            c.count += 1;
            return .disarm;
        }
    }.cb;

    // Schedule a timeout 50 ms out.
    var c = Completion{};
    try sim.io.timeout(.{ .ns = 50_000_000 }, &c, &ctx, cb);

    const Cond = struct {
        fn done(s: *Simulator) bool {
            // Capture the firecounter via a static: sim has no userdata.
            _ = s;
            return fired_flag;
        }
        var fired_flag: bool = false;
    };
    Cond.fired_flag = false;

    // Spin via runUntilFine — should jump straight to ~50 ms in one step.
    var iter: u32 = 0;
    while (iter < 5) : (iter += 1) {
        try sim.step(0); // ensure deadline observable
        if (sim.nextPendingDeadlineNs()) |d| {
            try sim.step(d - sim.clock_ns);
        } else {
            try sim.step(1);
        }
        if (ctx.count > 0) {
            Cond.fired_flag = true;
            break;
        }
    }

    try testing.expectEqual(@as(u32, 1), ctx.count);
    try testing.expect(sim.clock_ns >= 50_000_000);
}

test "Simulator.addPeer respects swarm capacity" {
    var sim = try Simulator.init(testing.allocator, .{ .swarm_capacity = 2 });
    defer sim.deinit();

    // We don't need real peers for this — pointer values just have to be
    // distinct, addPeer never dereferences them in this test.
    var p1: SimPeer = undefined;
    var p2: SimPeer = undefined;
    var p3: SimPeer = undefined;
    try sim.addPeer(&p1);
    try sim.addPeer(&p2);
    try testing.expectError(error.SwarmCapacityExhausted, sim.addPeer(&p3));
}

test "Simulator.nextPendingDeadlineNs returns null when heap is empty" {
    var sim = try Simulator.init(testing.allocator, .{});
    defer sim.deinit();
    try testing.expectEqual(@as(?u64, null), sim.nextPendingDeadlineNs());
}

test "BUGGIFY at probability 1.0 hits every step" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 1.0 },
    });
    defer sim.deinit();

    const Counter = struct { calls: u32 = 0, errs: u32 = 0 };
    var ctx = Counter{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const c: *Counter = @ptrCast(@alignCast(ud.?));
            c.calls += 1;
            switch (result) {
                .recv => |r| _ = r catch {
                    c.errs += 1;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    // 4 recv ops on legacy (non-socket) fds — each lands in the heap
    // with `.recv = 0` by default. BUGGIFY should overwrite some/all
    // with `error.ConnectionResetByPeer`.
    var c1 = Completion{};
    var c2 = Completion{};
    var c3 = Completion{};
    var c4 = Completion{};
    var buf1: [4]u8 = undefined;
    var buf2: [4]u8 = undefined;
    var buf3: [4]u8 = undefined;
    var buf4: [4]u8 = undefined;
    try sim.io.recv(.{ .fd = 7, .buf = &buf1 }, &c1, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf2 }, &c2, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf3 }, &c3, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf4 }, &c4, &ctx, cb);

    // One step injects (probability=1.0) before the tick fires.
    try sim.step(0);
    try testing.expect(sim.buggify_hits >= 1);
    try testing.expectEqual(@as(u32, 4), ctx.calls);
    // At least one call should have observed the injected error.
    try testing.expect(ctx.errs >= 1);
}

test "BUGGIFY at probability 0.0 never injects" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 0.0 },
    });
    defer sim.deinit();

    var c = Completion{};
    var buf: [4]u8 = undefined;
    const cb = struct {
        fn cb(_: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            return .disarm;
        }
    }.cb;
    try sim.io.recv(.{ .fd = 7, .buf = &buf }, &c, null, cb);
    try sim.step(0);
    try testing.expectEqual(@as(u32, 0), sim.buggify_hits);
}

//! Simulator — drives a `SimSwarm` of `SimPeer`s, an `IoBackend` instance,
//! and a comptime-generic `Driver` deterministically under a seeded clock.
//!
//! The simulator owns a fixed-capacity swarm of `*SimPeer` pointers, a
//! seeded `std.Random.DefaultPrng`, a logical clock measured in
//! nanoseconds, and a `Driver` value. `step(delta_ns)` advances the clock
//! by `delta_ns`, calls `step` on each swarm peer, optionally injects a
//! BUGGIFY fault, calls `Driver.tick(*driver, *SimIO)`, then ticks the IO
//! backend so any newly-due completions fire.
//!
//! ## Driver — what gets ticked
//!
//! The simulator is generic over a comptime `Driver` type that exposes:
//!
//! ```zig
//! pub fn tick(self: *Driver, io: *SimIO) !void
//! ```
//!
//! For unit tests of the simulator itself (clock, BUGGIFY, runUntil
//! semantics), `StubDriver` is enough: it counts ticks and does nothing
//! else. Once Stage 2 #12 lands and EventLoop is parameterised over its IO
//! backend, the same Simulator instantiates with `Driver = EventLoop(SimIO)`
//! and the integration is purely a `Driver` swap — no API change to the
//! simulator's surface.
//!
//! ## Step granularity
//!
//! Callers can either pass a fixed `step_ns` to `runUntil` (coarser, easier
//! to reason about) or use `runUntilFine` which jumps the clock directly
//! to the next pending heap deadline. The fine variant produces fewer
//! ticks, less RNG churn, and deterministic completion ordering — preferred
//! when behaviour depends on ordering (e.g. smart-ban tests that mix
//! honest and corrupt blocks).

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

/// `StubDriver` is a no-op driver that just counts ticks. Used by unit
/// tests of the simulator's own surface (clock, BUGGIFY, runUntil) and
/// any test that doesn't need an EventLoop on the other end.
pub const StubDriver = struct {
    tick_count: u32 = 0,

    pub fn tick(self: *StubDriver, _: *SimIO) !void {
        self.tick_count += 1;
    }
};

/// Build the concrete Simulator type for a given comptime `Driver`. See
/// the module-level docs for the Driver contract.
pub fn SimulatorOf(comptime Driver: type) type {
    return struct {
        allocator: std.mem.Allocator,
        rng: std.Random.DefaultPrng,
        io: SimIO,
        driver: Driver,
        buggify: BuggifyConfig,

        /// Logical clock in nanoseconds. Independent of `SimIO.now_ns` so
        /// the simulator can advance state machines (peer step, driver
        /// tick) on the same timeline that drives IO.
        clock_ns: u64 = 0,

        /// Counter incremented on every successful BUGGIFY injection.
        /// Tests inspect this to confirm BUGGIFY actually fired.
        buggify_hits: u32 = 0,

        /// Fixed-capacity swarm of peer pointers. Caller-owned; the
        /// simulator stores a slot but doesn't allocate the SimPeer.
        swarm: []?*SimPeer,
        swarm_len: u32 = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, config: Config, driver: Driver) !Self {
            const slots = try allocator.alloc(?*SimPeer, config.swarm_capacity);
            errdefer allocator.free(slots);
            @memset(slots, null);

            var io = try SimIO.init(allocator, config.sim_io);
            errdefer io.deinit();

            return .{
                .allocator = allocator,
                .rng = std.Random.DefaultPrng.init(config.seed),
                .io = io,
                .driver = driver,
                .buggify = config.buggify,
                .swarm = slots,
            };
        }

        pub fn deinit(self: *Self) void {
            self.io.deinit();
            self.allocator.free(self.swarm);
            self.* = undefined;
        }

        /// Add a peer to the swarm. The caller owns the peer's memory;
        /// the simulator just records the pointer so `step` can drive it.
        pub fn addPeer(self: *Self, peer: *SimPeer) !void {
            if (self.swarm_len == self.swarm.len) return error.SwarmCapacityExhausted;
            self.swarm[self.swarm_len] = peer;
            self.swarm_len += 1;
        }

        /// Advance the simulated clock by `delta_ns`, drive every swarm
        /// peer once, optionally inject a BUGGIFY fault, call
        /// `Driver.tick`, then tick the IO backend.
        pub fn step(self: *Self, delta_ns: u64) !void {
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

            // BUGGIFY: with probability `buggify.probability`, mutate a
            // random pending op's result. Heap order is preserved.
            if (self.buggify.probability > 0) {
                if (self.rng.random().float(f32) < self.buggify.probability) {
                    if (self.io.injectRandomFault(&self.rng)) |hit| {
                        self.buggify_hits += 1;
                        if (self.buggify.log) |log| {
                            var line_buf: [64]u8 = undefined;
                            const line = std.fmt.bufPrint(
                                &line_buf,
                                "fault injected: {s}\n",
                                .{@tagName(hit.op_tag)},
                            ) catch return self.io.tick();
                            _ = log.write(line) catch {};
                        }
                    }
                }
            }

            try self.driver.tick(&self.io);
            try self.io.tick();
        }

        /// Run `step(step_ns)` until either `cond(self) == true` or
        /// `max_steps` iterations elapse. Returns true when `cond` succeeded.
        pub fn runUntil(
            self: *Self,
            comptime cond: fn (sim: *Self) bool,
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
        /// pending deadline each iteration. Produces minimum tick count
        /// and avoids redundant RNG churn from steps where nothing is due.
        /// If the heap has no schedulable work, advances by `idle_step_ns`
        /// so swarm peers and the driver still get a chance to run.
        pub fn runUntilFine(
            self: *Self,
            comptime cond: fn (sim: *Self) bool,
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
        /// schedulable work exists. Returns null for parked-recv-only
        /// states (no heap entries) and for the parked-accept sentinel.
        pub fn nextPendingDeadlineNs(self: *const Self) ?u64 {
            if (self.io.pending_len == 0) return null;
            const d = self.io.pending[0].deadline_ns;
            if (d >= sentinel_deadline_ns) return null;
            return d;
        }

        /// Alias for `nextPendingDeadlineNs` matching the team-lead's
        /// suggested name. Returns the next deadline so the caller can
        /// peek without stepping.
        pub fn jumpToNextDeadline(self: *const Self) ?u64 {
            return self.nextPendingDeadlineNs();
        }
    };
}

/// Default Simulator type for tests and tools that don't need a custom
/// driver. `StubDriver` ticks are no-ops; the simulator's own surface
/// (clock, BUGGIFY, peer.step, io.tick) is fully exercised.
pub const Simulator = SimulatorOf(StubDriver);

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;
const ifc = @import("../io/io_interface.zig");
const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

test "Simulator init / deinit cleanly with empty swarm" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();
    try testing.expectEqual(@as(u32, 0), sim.swarm_len);
    try testing.expectEqual(@as(u64, 0), sim.clock_ns);
}

test "Simulator.step calls Driver.tick once per step" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();

    try sim.step(1);
    try sim.step(1);
    try sim.step(1);
    try testing.expectEqual(@as(u32, 3), sim.driver.tick_count);
}

test "Simulator.step advances clock and ticks IO" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
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

    try sim.step(2_000_000);
    try testing.expectEqual(@as(u32, 1), ctx.count);
    try testing.expectEqual(@as(u64, 2_000_000), sim.clock_ns);
}

test "Simulator.runUntil hits step ceiling and returns false" {
    const State = struct {
        fn never(_: *Simulator) bool {
            return false;
        }
    };

    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();

    const ok = try sim.runUntil(State.never, 5, 1_000);
    try testing.expect(!ok);
    try testing.expectEqual(@as(u64, 5_000), sim.clock_ns);
}

test "BUGGIFY at probability 1.0 hits at least once per step" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 1.0 },
    }, StubDriver{});
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

    var c1 = Completion{};
    var c2 = Completion{};
    var buf1: [4]u8 = undefined;
    var buf2: [4]u8 = undefined;
    try sim.io.recv(.{ .fd = 7, .buf = &buf1 }, &c1, &ctx, cb);
    try sim.io.recv(.{ .fd = 7, .buf = &buf2 }, &c2, &ctx, cb);

    try sim.step(0);
    try testing.expect(sim.buggify_hits >= 1);
    try testing.expect(ctx.errs >= 1);
}

test "BUGGIFY at probability 0.0 never injects" {
    var sim = try Simulator.init(testing.allocator, .{
        .buggify = .{ .probability = 0.0 },
    }, StubDriver{});
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

test "Simulator generic — custom driver receives io pointer" {
    const RecordingDriver = struct {
        last_io: ?*SimIO = null,
        ticks: u32 = 0,

        pub fn tick(self: *@This(), io: *SimIO) !void {
            self.last_io = io;
            self.ticks += 1;
        }
    };

    var sim = try SimulatorOf(RecordingDriver).init(testing.allocator, .{}, RecordingDriver{});
    defer sim.deinit();

    try sim.step(0);
    try sim.step(0);
    try testing.expectEqual(@as(u32, 2), sim.driver.ticks);
    try testing.expectEqual(&sim.io, sim.driver.last_io.?);
}

test "Simulator.jumpToNextDeadline returns null when heap empty" {
    var sim = try Simulator.init(testing.allocator, .{}, StubDriver{});
    defer sim.deinit();
    try testing.expectEqual(@as(?u64, null), sim.jumpToNextDeadline());
}

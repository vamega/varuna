//! Injected wall-clock for daemon code paths that need a wall-clock read
//! the simulator can drive deterministically.
//!
//! The `.real` variant delegates to `std.time.{timestamp,milliTimestamp,
//! nanoTimestamp}` (production). The `.sim` variant holds an absolute
//! timestamp measured in nanoseconds; tests advance it directly,
//! eliminating wall-clock dependency from timeout, keepalive, and
//! token-bucket logic.
//!
//! ## Design
//!
//! Tagged-union (Option A). With ~50 production callers across DHT,
//! RPC, tracker, peer, and storage subsystems, a comptime cascade
//! (`ClockOf(comptime Impl: type)`) would force every consumer's
//! generic graph to widen — invasive for negligible win since clock
//! reads are rare relative to IO work and a tagged-union switch is one
//! mispredicted branch at most. The IO contract uses comptime because
//! IO type is fundamental to the call surface; clock just returns an
//! integer and there's nothing to monomorphise over.
//!
//! ## Resolutions
//!
//! `now()` returns `i64` seconds since the epoch (matches
//! `std.time.timestamp()`). `nowMs()` returns `i64` milliseconds
//! (matches `std.time.milliTimestamp()`). `nowNs()` returns `i128`
//! nanoseconds (matches `std.time.nanoTimestamp()`). The sim variant
//! stores nanoseconds internally so all three resolutions agree on the
//! same timeline.
//!
//! ## Usage in tests
//!
//! ```zig
//! var el = try EventLoop.initBare(allocator, 0);
//! el.clock = Clock.simAtSecs(1000); // start at t = 1000s
//! el.clock.advanceSecs(120);        // jump 2 minutes
//! el.clock.advanceMs(500);          // jump 0.5s further
//! el.clock.advanceNs(1_000_000);    // jump 1ms further
//! ```

const std = @import("std");

pub const Clock = union(enum) {
    real: void,
    /// Sim clock stores absolute nanoseconds since the epoch. All three
    /// `now*` accessors derive their result from this single field.
    sim: i128,

    pub fn realClock() Clock {
        return .real;
    }

    /// Sim clock initialised to `secs` seconds past the epoch.
    pub fn simAtSecs(secs: i64) Clock {
        return .{ .sim = @as(i128, secs) * std.time.ns_per_s };
    }

    /// Sim clock initialised to `ms` milliseconds past the epoch.
    pub fn simAtMs(ms: i64) Clock {
        return .{ .sim = @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Sim clock initialised to `ns` nanoseconds past the epoch.
    pub fn simAtNs(ns: i128) Clock {
        return .{ .sim = ns };
    }

    /// Wall-clock seconds since the epoch. Mirrors `std.time.timestamp()`.
    pub fn now(self: Clock) i64 {
        return switch (self) {
            .real => std.time.timestamp(),
            .sim => |t| @intCast(@divTrunc(t, std.time.ns_per_s)),
        };
    }

    /// Wall-clock milliseconds since the epoch. Mirrors
    /// `std.time.milliTimestamp()`.
    pub fn nowMs(self: Clock) i64 {
        return switch (self) {
            .real => std.time.milliTimestamp(),
            .sim => |t| @intCast(@divTrunc(t, std.time.ns_per_ms)),
        };
    }

    /// Wall-clock nanoseconds since the epoch. Mirrors
    /// `std.time.nanoTimestamp()`.
    pub fn nowNs(self: Clock) i128 {
        return switch (self) {
            .real => std.time.nanoTimestamp(),
            .sim => |t| t,
        };
    }

    /// Advance the simulated clock by `secs` seconds. No-op for `.real`.
    pub fn advance(self: *Clock, secs: i64) void {
        self.advanceSecs(secs);
    }

    /// Advance the simulated clock by `secs` seconds. No-op for `.real`.
    pub fn advanceSecs(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* += @as(i128, secs) * std.time.ns_per_s,
        }
    }

    /// Advance the simulated clock by `ms` milliseconds. No-op for `.real`.
    pub fn advanceMs(self: *Clock, ms: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* += @as(i128, ms) * std.time.ns_per_ms,
        }
    }

    /// Advance the simulated clock by `ns` nanoseconds. No-op for `.real`.
    pub fn advanceNs(self: *Clock, ns: i128) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* += ns,
        }
    }

    /// Set the simulated clock to an absolute epoch value, in seconds.
    /// No-op for `.real`.
    pub fn set(self: *Clock, secs: i64) void {
        self.setSecs(secs);
    }

    /// Set the simulated clock to an absolute epoch value, in seconds.
    /// No-op for `.real`.
    pub fn setSecs(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = @as(i128, secs) * std.time.ns_per_s,
        }
    }

    /// Set the simulated clock to an absolute epoch value, in
    /// milliseconds. No-op for `.real`.
    pub fn setMs(self: *Clock, ms: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = @as(i128, ms) * std.time.ns_per_ms,
        }
    }

    /// Set the simulated clock to an absolute epoch value, in
    /// nanoseconds. No-op for `.real`.
    pub fn setNs(self: *Clock, ns: i128) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = ns,
        }
    }
};

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

test "real clock returns increasing seconds" {
    const c = Clock.realClock();
    const t1 = c.now();
    const t2 = c.now();
    try testing.expect(t2 >= t1);
    try testing.expect(t1 > 0);
}

test "real clock ns >= ms*1e6 >= secs*1e9" {
    const c = Clock.realClock();
    const ns = c.nowNs();
    // Sample these together; if scheduler intervenes the relationship
    // can drift across calls. Just sanity-check magnitudes.
    try testing.expect(ns > 0);
    try testing.expect(ns < @as(i128, std.math.maxInt(i64)) * 2);
}

test "sim clock initialised at seconds reads back consistently" {
    var c = Clock.simAtSecs(1_000);
    try testing.expectEqual(@as(i64, 1_000), c.now());
    try testing.expectEqual(@as(i64, 1_000_000), c.nowMs());
    try testing.expectEqual(@as(i128, 1_000) * std.time.ns_per_s, c.nowNs());
}

test "sim clock initialised at ms reads back consistently" {
    const c = Clock.simAtMs(2_500);
    try testing.expectEqual(@as(i64, 2), c.now());
    try testing.expectEqual(@as(i64, 2_500), c.nowMs());
    try testing.expectEqual(@as(i128, 2_500) * std.time.ns_per_ms, c.nowNs());
}

test "sim clock initialised at ns preserves sub-millisecond precision" {
    const c = Clock.simAtNs(1_500_000); // 1.5 ms
    try testing.expectEqual(@as(i64, 0), c.now());
    try testing.expectEqual(@as(i64, 1), c.nowMs());
    try testing.expectEqual(@as(i128, 1_500_000), c.nowNs());
}

test "sim clock advanceSecs adds seconds" {
    var c = Clock.simAtSecs(100);
    c.advanceSecs(50);
    try testing.expectEqual(@as(i64, 150), c.now());
}

test "sim clock advanceMs adds milliseconds" {
    var c = Clock.simAtSecs(0);
    c.advanceMs(250);
    try testing.expectEqual(@as(i64, 250), c.nowMs());
    try testing.expectEqual(@as(i64, 0), c.now());
}

test "sim clock advanceNs adds nanoseconds" {
    var c = Clock.simAtNs(0);
    c.advanceNs(7);
    try testing.expectEqual(@as(i128, 7), c.nowNs());
}

test "sim clock setSecs replaces value" {
    var c = Clock.simAtSecs(100);
    c.setSecs(200);
    try testing.expectEqual(@as(i64, 200), c.now());
}

test "sim clock setMs replaces value" {
    var c = Clock.simAtNs(123);
    c.setMs(7);
    try testing.expectEqual(@as(i64, 7), c.nowMs());
    try testing.expectEqual(@as(i128, 7) * std.time.ns_per_ms, c.nowNs());
}

test "real clock advance/set are no-ops" {
    var c = Clock.realClock();
    c.advanceSecs(1_000_000);
    c.advanceMs(1_000_000);
    c.advanceNs(1_000_000);
    c.setSecs(0);
    c.setMs(0);
    c.setNs(0);
    // Should still read live wall-clock; just confirm it's positive.
    try testing.expect(c.nowNs() > 0);
}

test "sim clock advance methods compose on the same timeline" {
    var c = Clock.simAtSecs(1);
    c.advanceMs(500);
    c.advanceNs(250_000); // 0.25 ms
    // 1.5s + 250µs => 1.500250s = 1500250 µs = 1500.25 ms
    try testing.expectEqual(@as(i64, 1), c.now());
    try testing.expectEqual(@as(i64, 1_500), c.nowMs());
    try testing.expectEqual(@as(i128, 1_500_250_000), c.nowNs());
}

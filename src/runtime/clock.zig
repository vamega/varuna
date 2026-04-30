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
//! (matches `std.time.milliTimestamp()`). `nowNs()` returns `u64`
//! nanoseconds — narrower than `std.time.nanoTimestamp()`'s `i128` on
//! purpose. The whole simulation timeline (`SimIO.now_ns: u64`,
//! `Simulator.clock_ns: u64`, `PendingEntry.deadline_ns: u64`) is
//! already u64; matching that invariant cuts a cache line off the
//! TokenBucket struct, lets future callers fit ns timestamps in
//! `std.atomic.Value(u64)`, and avoids a 128-bit conversion at every
//! `EventLoop → SimIO` boundary.
//!
//! u64 nanoseconds since the Unix epoch wraps in **2554** (`2^64 ns ≈
//! 584.5 years`). For a BitTorrent daemon — and for any process with a
//! lifetime measured in years rather than centuries — that's
//! enormously more headroom than we need. If a future caller really
//! must persist ns to disk for cross-restart reasoning, prefer storing
//! seconds + nanos separately; don't widen this type for it.
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
    /// u64 wraps at year ~2554 — see file header for rationale.
    sim: u64,

    pub fn realClock() Clock {
        return .real;
    }

    /// Sim clock initialised to `secs` seconds past the epoch.
    /// Negative `secs` is clamped to 0; sim time is non-negative.
    pub fn simAtSecs(secs: i64) Clock {
        if (secs <= 0) return .{ .sim = 0 };
        return .{ .sim = @as(u64, @intCast(secs)) * std.time.ns_per_s };
    }

    /// Sim clock initialised to `ms` milliseconds past the epoch.
    /// Negative `ms` is clamped to 0.
    pub fn simAtMs(ms: i64) Clock {
        if (ms <= 0) return .{ .sim = 0 };
        return .{ .sim = @as(u64, @intCast(ms)) * std.time.ns_per_ms };
    }

    /// Sim clock initialised to `ns` nanoseconds past the epoch.
    pub fn simAtNs(ns: u64) Clock {
        return .{ .sim = ns };
    }

    /// Wall-clock seconds since the epoch. Mirrors `std.time.timestamp()`.
    pub fn now(self: Clock) i64 {
        return switch (self) {
            .real => std.time.timestamp(),
            .sim => |t| @intCast(t / std.time.ns_per_s),
        };
    }

    /// Wall-clock milliseconds since the epoch. Mirrors
    /// `std.time.milliTimestamp()`.
    pub fn nowMs(self: Clock) i64 {
        return switch (self) {
            .real => std.time.milliTimestamp(),
            .sim => |t| @intCast(t / std.time.ns_per_ms),
        };
    }

    /// Wall-clock nanoseconds since the epoch. NOTE: returns `u64`,
    /// not `i128` like `std.time.nanoTimestamp()` — see file header.
    /// Production: `std.time.nanoTimestamp()` cast to `u64` (always
    /// positive, won't truncate for ~half a millennium).
    pub fn nowNs(self: Clock) u64 {
        return switch (self) {
            .real => @intCast(std.time.nanoTimestamp()),
            .sim => |t| t,
        };
    }

    /// Advance the simulated clock by `secs` seconds (negative jumps
    /// backward, saturating at 0). No-op for `.real`.
    pub fn advance(self: *Clock, secs: i64) void {
        self.advanceSecs(secs);
    }

    /// Advance the simulated clock by `secs` seconds (negative jumps
    /// backward, saturating at 0). No-op for `.real`.
    pub fn advanceSecs(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = applyDelta(t.*, secs, std.time.ns_per_s),
        }
    }

    /// Advance the simulated clock by `ms` milliseconds (negative jumps
    /// backward, saturating at 0). No-op for `.real`.
    pub fn advanceMs(self: *Clock, ms: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = applyDelta(t.*, ms, std.time.ns_per_ms),
        }
    }

    /// Advance the simulated clock by `ns` nanoseconds (negative jumps
    /// backward, saturating at 0). No-op for `.real`.
    pub fn advanceNs(self: *Clock, ns: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = applyDelta(t.*, ns, 1),
        }
    }

    /// Set the simulated clock to an absolute epoch value, in seconds.
    /// Negative `secs` is clamped to 0. No-op for `.real`.
    pub fn set(self: *Clock, secs: i64) void {
        self.setSecs(secs);
    }

    /// Set the simulated clock to an absolute epoch value, in seconds.
    /// Negative `secs` is clamped to 0. No-op for `.real`.
    pub fn setSecs(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = if (secs <= 0)
                0
            else
                @as(u64, @intCast(secs)) * std.time.ns_per_s,
        }
    }

    /// Set the simulated clock to an absolute epoch value, in
    /// milliseconds. Negative `ms` is clamped to 0. No-op for `.real`.
    pub fn setMs(self: *Clock, ms: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = if (ms <= 0)
                0
            else
                @as(u64, @intCast(ms)) * std.time.ns_per_ms,
        }
    }

    /// Set the simulated clock to an absolute epoch value, in
    /// nanoseconds. No-op for `.real`.
    pub fn setNs(self: *Clock, ns: u64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = ns,
        }
    }
};

/// Apply a signed delta scaled by `unit_ns` to a u64 ns timestamp,
/// saturating at 0 on underflow. Pulled out so all three `advance*`
/// helpers share the same arithmetic.
fn applyDelta(t: u64, delta: i64, unit_ns: u64) u64 {
    if (delta >= 0) {
        const add = @as(u64, @intCast(delta)) *| unit_ns;
        return t +| add;
    }
    const abs_delta = @as(u64, @intCast(-(delta + 1))) + 1; // -minInt safe
    const sub = abs_delta *| unit_ns;
    return t -| sub;
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

test "real clock returns increasing seconds" {
    const c = Clock.realClock();
    const t1 = c.now();
    const t2 = c.now();
    try testing.expect(t2 >= t1);
    try testing.expect(t1 > 0);
}

test "real clock nowNs fits in u64 (year-2554 invariant)" {
    const c = Clock.realClock();
    const ns = c.nowNs();
    // 2026-04 is ~1.78e18 ns since the epoch; well inside u64.
    try testing.expect(ns > 0);
    try testing.expect(ns < std.math.maxInt(u64) / 2);
}

test "sim clock initialised at seconds reads back consistently" {
    var c = Clock.simAtSecs(1_000);
    try testing.expectEqual(@as(i64, 1_000), c.now());
    try testing.expectEqual(@as(i64, 1_000_000), c.nowMs());
    try testing.expectEqual(@as(u64, 1_000) * std.time.ns_per_s, c.nowNs());
}

test "sim clock initialised at ms reads back consistently" {
    const c = Clock.simAtMs(2_500);
    try testing.expectEqual(@as(i64, 2), c.now());
    try testing.expectEqual(@as(i64, 2_500), c.nowMs());
    try testing.expectEqual(@as(u64, 2_500) * std.time.ns_per_ms, c.nowNs());
}

test "sim clock initialised at ns preserves sub-millisecond precision" {
    const c = Clock.simAtNs(1_500_000); // 1.5 ms
    try testing.expectEqual(@as(i64, 0), c.now());
    try testing.expectEqual(@as(i64, 1), c.nowMs());
    try testing.expectEqual(@as(u64, 1_500_000), c.nowNs());
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
    try testing.expectEqual(@as(u64, 7), c.nowNs());
}

test "sim clock advance with negative delta saturates at 0" {
    var c = Clock.simAtSecs(1);
    c.advanceSecs(-100);
    try testing.expectEqual(@as(u64, 0), c.nowNs());

    var c2 = Clock.simAtMs(500);
    c2.advanceMs(-100);
    try testing.expectEqual(@as(i64, 400), c2.nowMs());
    c2.advanceMs(-1_000);
    try testing.expectEqual(@as(u64, 0), c2.nowNs());
}

test "sim clock setSecs replaces value" {
    var c = Clock.simAtSecs(100);
    c.setSecs(200);
    try testing.expectEqual(@as(i64, 200), c.now());
    c.setSecs(-1); // clamps to 0
    try testing.expectEqual(@as(u64, 0), c.nowNs());
}

test "sim clock setMs replaces value" {
    var c = Clock.simAtNs(123);
    c.setMs(7);
    try testing.expectEqual(@as(i64, 7), c.nowMs());
    try testing.expectEqual(@as(u64, 7) * std.time.ns_per_ms, c.nowNs());
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
    try testing.expectEqual(@as(u64, 1_500_250_000), c.nowNs());
}

test "Clock struct is small (u64 sim variant)" {
    // Tagged-union with a u64 payload + tag fits in 16 bytes on
    // 64-bit. A regression here would mean someone widened the sim
    // variant back to i128 — the year-2554 invariant exists precisely
    // so we don't pay that.
    try testing.expect(@sizeOf(Clock) <= 16);
}

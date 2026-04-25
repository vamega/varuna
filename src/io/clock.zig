const std = @import("std");

/// Injected wall-clock for the EventLoop.
///
/// The `.real` variant delegates to `std.time.timestamp()` (production).
/// The `.sim` variant holds a mutable `i64` that tests advance directly,
/// eliminating wall-clock dependency from timeout and keepalive logic.
///
/// Usage in tests:
///   var el = try EventLoop.initBare(allocator, 0);
///   el.clock = .{ .sim = 1000 }; // start at t=1000s
///   el.clock.advance(120);       // jump 2 minutes
pub const Clock = union(enum) {
    real: void,
    sim: i64,

    pub fn now(self: Clock) i64 {
        return switch (self) {
            .real => std.time.timestamp(),
            .sim => |t| t,
        };
    }

    /// Advance the simulated clock by `secs` seconds. No-op for `.real`.
    pub fn advance(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* += secs,
        }
    }

    /// Set the simulated clock to an absolute epoch value. No-op for `.real`.
    pub fn set(self: *Clock, secs: i64) void {
        switch (self.*) {
            .real => {},
            .sim => |*t| t.* = secs,
        }
    }
};

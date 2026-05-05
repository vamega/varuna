const std = @import("std");

/// LEDBAT (Low Extra Delay Background Transport) congestion control.
///
/// RFC 6817 / BEP 29: delay-based congestion control that yields to TCP
/// traffic by targeting low queuing delay (100ms). The window grows
/// additively when the measured one-way delay is below the target and
/// shrinks multiplicatively when it exceeds the target.
pub const Ledbat = struct {
    /// Current congestion window in bytes.
    cwnd: u32,

    /// Slow-start threshold. While cwnd < ssthresh we are in slow-start
    /// (exponential growth); above it we switch to congestion avoidance.
    ssthresh: u32 = max_cwnd,

    /// Minimum observed base delay (one-way propagation delay estimate)
    /// in microseconds. Reset periodically to track route changes.
    base_delay: u32 = std.math.maxInt(u32),

    /// Ring buffer of recent base-delay samples, one per minute.
    /// We keep `base_history_len` entries and use the minimum.
    base_history: [base_history_len]u32 = @as([base_history_len]u32, @splat(std.math.maxInt(u32))),
    base_history_idx: u8 = 0,

    /// Timestamp (microseconds) of the last base-delay rotation.
    last_base_rotation: u32 = 0,

    /// Current delay filter: minimum of the last `current_delay_samples`
    /// delay measurements. This smooths out jitter.
    current_delay_filter: [current_delay_samples]u32 = @as([current_delay_samples]u32, @splat(0)),
    current_delay_idx: u8 = 0,

    /// Number of bytes acked since last cwnd update (for sub-window
    /// accumulation in congestion avoidance).
    bytes_acked: u32 = 0,

    /// Number of delay samples collected so far (used to avoid acting
    /// on too few samples during startup).
    sample_count: u32 = 0,

    /// Target one-way delay in microseconds.
    target_delay_us: u32 = default_target_delay_us,

    // ── Constants ────────────────────────────────────────

    /// Default target one-way delay in microseconds (100 ms per BEP 29).
    pub const default_target_delay_us: u32 = 100_000;

    /// Minimum congestion window: one packet (MTU).
    pub const min_cwnd: u32 = mss;

    /// Maximum congestion window (1 MiB).
    pub const max_cwnd: u32 = 1024 * 1024;

    /// Number of base-delay history entries (minutes).
    const base_history_len = 10;

    /// Number of recent delay samples for the current-delay filter.
    const current_delay_samples = 8;

    /// Microseconds per minute (base-delay rotation interval).
    const base_rotation_interval: u32 = 60_000_000;

    /// Maximum segment size for window calculations.
    pub const mss: u32 = 1400;

    // ── Public API ───────────────────────────────────────

    pub fn init() Ledbat {
        return initWithTargetDelay(default_target_delay_us);
    }

    pub fn initWithTargetDelay(target_delay_us: u32) Ledbat {
        return .{
            .cwnd = mss * 2, // start with 2 segments
            .target_delay_us = target_delay_us,
        };
    }

    /// Called for every ACK received. `bytes` is the number of newly
    /// acknowledged bytes. `delay_us` is the measured one-way delay
    /// in microseconds (timestamp_difference from the packet header).
    /// `now_us` is the current microsecond clock.
    pub fn onAck(self: *Ledbat, bytes: u32, delay_us: u32, now_us: u32) void {
        if (bytes == 0) return;

        self.sample_count += 1;

        // Update base delay (minimum observed delay).
        self.updateBaseDelay(delay_us, now_us);

        // Update current delay filter.
        self.current_delay_filter[self.current_delay_idx] = delay_us;
        self.current_delay_idx = (self.current_delay_idx + 1) % current_delay_samples;

        const current_delay = self.filteredCurrentDelay();
        const base = self.filteredBaseDelay();

        // Queuing delay estimate.
        const queuing_delay: i64 = if (current_delay > base)
            @as(i64, current_delay) - @as(i64, base)
        else
            0;

        // Off-target: positive means delay is below target (speed up),
        // negative means above target (slow down).
        const target_delay_us = @max(self.target_delay_us, 1);
        const off_target: i64 = @as(i64, target_delay_us) - queuing_delay;

        if (self.cwnd < self.ssthresh) {
            // Slow start: double cwnd per RTT (like TCP).
            self.cwnd = @min(self.cwnd +| bytes, max_cwnd);
            // Exit slow start if we exceed the target delay.
            if (queuing_delay > target_delay_us) {
                self.ssthresh = self.cwnd;
            }
        } else {
            // Congestion avoidance: LEDBAT linear increase/decrease.
            // gain = off_target / target_delay * bytes_acked / cwnd * mss
            self.bytes_acked +|= bytes;

            if (self.bytes_acked >= self.cwnd and self.cwnd > 0) {
                const window_factor: i64 = @divTrunc(@as(i64, self.bytes_acked) * @as(i64, mss), @as(i64, self.cwnd));
                const delay_factor: i64 = @divTrunc(off_target * @as(i64, mss), @as(i64, target_delay_us));
                const gain = @divTrunc(window_factor * delay_factor, @as(i64, mss));

                if (gain > 0) {
                    self.cwnd = @min(self.cwnd +| @as(u32, @intCast(gain)), max_cwnd);
                } else if (gain < 0) {
                    const decrease: u32 = @intCast(@min(-gain, @as(i64, self.cwnd - min_cwnd)));
                    self.cwnd = @max(self.cwnd - decrease, min_cwnd);
                }

                self.bytes_acked = 0;
            }
        }

        self.cwnd = @max(self.cwnd, min_cwnd);
    }

    /// Called when a packet loss is detected (timeout or triple dup ACK).
    pub fn onLoss(self: *Ledbat) void {
        // Halve the window (standard response to loss).
        self.ssthresh = @max(self.cwnd / 2, min_cwnd);
        self.cwnd = @max(self.cwnd / 2, min_cwnd);
    }

    /// Called on RTO timeout: collapse to minimum window.
    pub fn onTimeout(self: *Ledbat) void {
        self.ssthresh = @max(self.cwnd / 2, min_cwnd);
        self.cwnd = min_cwnd;
    }

    /// Returns the current congestion window in bytes.
    pub fn window(self: *const Ledbat) u32 {
        return self.cwnd;
    }

    // ── Internal ─────────────────────────────────────────

    fn updateBaseDelay(self: *Ledbat, delay_us: u32, now_us: u32) void {
        if (delay_us < self.base_delay) {
            self.base_delay = delay_us;
        }

        // Also update the current history slot.
        if (delay_us < self.base_history[self.base_history_idx]) {
            self.base_history[self.base_history_idx] = delay_us;
        }

        // Rotate history every minute.
        const elapsed = now_us -% self.last_base_rotation;
        if (elapsed >= base_rotation_interval) {
            self.last_base_rotation = now_us;
            self.base_history_idx = (self.base_history_idx + 1) % base_history_len;
            self.base_history[self.base_history_idx] = delay_us;

            // Recompute base delay from history.
            self.base_delay = std.math.maxInt(u32);
            for (self.base_history) |entry| {
                if (entry < self.base_delay) self.base_delay = entry;
            }
        }
    }

    fn filteredBaseDelay(self: *const Ledbat) u32 {
        return self.base_delay;
    }

    fn filteredCurrentDelay(self: *const Ledbat) u32 {
        var min_val: u32 = std.math.maxInt(u32);
        for (self.current_delay_filter) |d| {
            if (d > 0 and d < min_val) min_val = d;
        }
        // If no valid samples yet, return 0.
        return if (min_val == std.math.maxInt(u32)) 0 else min_val;
    }
};

// ── Tests ─────────────────────────────────────────────────

test "ledbat init has reasonable defaults" {
    const cc = Ledbat.init();
    try std.testing.expect(cc.cwnd >= Ledbat.min_cwnd);
    try std.testing.expect(cc.cwnd <= Ledbat.max_cwnd);
}

test "ledbat window grows in slow start with low delay" {
    var cc = Ledbat.init();
    const initial = cc.cwnd;

    // Simulate ACKs with very low delay (well below target).
    cc.onAck(1400, 10_000, 1_000_000);
    cc.onAck(1400, 10_000, 1_001_000);
    cc.onAck(1400, 10_000, 1_002_000);

    try std.testing.expect(cc.cwnd > initial);
}

test "ledbat window shrinks when delay exceeds target" {
    var cc = Ledbat.init();
    // Pump up the window in slow start first.
    for (0..20) |i| {
        cc.onAck(1400, 5_000, @intCast(1_000_000 + i * 1000));
    }

    const before = cc.cwnd;
    // Now set ssthresh low to enter congestion avoidance.
    cc.ssthresh = cc.cwnd;

    // Feed delay samples well above target (200ms queuing delay).
    // Need to accumulate enough bytes_acked to trigger an update.
    for (0..50) |i| {
        cc.onAck(1400, 300_000, @intCast(2_000_000 + i * 1000));
    }

    try std.testing.expect(cc.cwnd < before);
}

test "ledbat onLoss halves window" {
    var cc = Ledbat.init();
    cc.cwnd = 20_000;

    cc.onLoss();
    try std.testing.expectEqual(@as(u32, 10_000), cc.cwnd);
}

test "ledbat onTimeout collapses to minimum" {
    var cc = Ledbat.init();
    cc.cwnd = 50_000;

    cc.onTimeout();
    try std.testing.expectEqual(Ledbat.min_cwnd, cc.cwnd);
}

test "ledbat window never goes below minimum" {
    var cc = Ledbat.init();
    cc.cwnd = Ledbat.min_cwnd;

    cc.onLoss();
    try std.testing.expect(cc.cwnd >= Ledbat.min_cwnd);

    cc.onTimeout();
    try std.testing.expect(cc.cwnd >= Ledbat.min_cwnd);
}

test "ledbat base delay tracks minimum" {
    var cc = Ledbat.init();
    cc.onAck(100, 50_000, 1_000_000);
    try std.testing.expectEqual(@as(u32, 50_000), cc.base_delay);

    cc.onAck(100, 30_000, 1_001_000);
    try std.testing.expectEqual(@as(u32, 30_000), cc.base_delay);

    // Higher delay should not change the base.
    cc.onAck(100, 80_000, 1_002_000);
    try std.testing.expectEqual(@as(u32, 30_000), cc.base_delay);
}

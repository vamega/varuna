const std = @import("std");

/// Token bucket rate limiter for bandwidth throttling.
///
/// Fills at `rate` bytes per second. Each consume() call removes tokens.
/// When the bucket is empty, consume() returns the number of nanoseconds
/// the caller should wait before retrying. A rate of 0 means unlimited.
///
/// Thread-safety: NOT thread-safe. Each bucket should be accessed from
/// a single thread (the event loop thread).
///
/// Time injection: callers pass an absolute nanosecond timestamp into
/// every operation that reads the clock. The bucket itself never calls
/// `std.time.nanoTimestamp()` so it's deterministic under sim time.
/// `refillAt`/`consumeAt`/`availableAt`/`delayNsAt` accept the timestamp
/// directly; the legacy `consume`/`available`/`delayNs` shims are gone
/// (always pass `now_ns` from `EventLoop.clock.nowNs()`).
///
/// Time width: `now_ns` is `u64` to match `SimIO.now_ns: u64` and the
/// `runtime.Clock` abstraction. u64 nanoseconds-since-epoch wraps in
/// year ~2554 — see `src/runtime/clock.zig` for rationale.
pub const TokenBucket = struct {
    /// Maximum tokens (burst size). Equals `rate` (1 second of burst).
    capacity: u64,

    /// Current token count.
    tokens: u64,

    /// Fill rate in bytes per second. 0 = unlimited.
    rate: u64,

    /// Timestamp of last refill, in absolute u64 nanoseconds. `null`
    /// means "uninitialised" — first refill seeds it from the
    /// caller-supplied `now_ns` without crediting elapsed time.
    /// Optional sentinel (vs the previous `== 0` magic value) so a sim
    /// test anchored at `t = 0` doesn't accidentally re-seed every
    /// refill.
    last_refill_ns: ?u64,

    /// Comptime-friendly init that defers timestamp seeding to first use.
    pub fn init(rate: u64) TokenBucket {
        return initComptime(rate);
    }

    /// Comptime-friendly init that defers timestamp to first use.
    pub fn initComptime(rate: u64) TokenBucket {
        return .{
            .capacity = if (rate == 0) std.math.maxInt(u64) else rate,
            .tokens = if (rate == 0) std.math.maxInt(u64) else rate,
            .rate = rate,
            .last_refill_ns = null,
        };
    }

    /// Set a new rate (bytes/sec). 0 = unlimited.
    /// Resets the bucket to full capacity at the new rate.
    pub fn setRate(self: *TokenBucket, rate: u64, now_ns: u64) void {
        self.rate = rate;
        self.capacity = if (rate == 0) std.math.maxInt(u64) else rate;
        self.tokens = self.capacity;
        self.last_refill_ns = now_ns;
    }

    /// Refill tokens based on elapsed time, using the caller-supplied
    /// absolute u64 nanosecond timestamp.
    pub fn refillAt(self: *TokenBucket, now_ns: u64) void {
        if (self.rate == 0) return; // unlimited

        const last = self.last_refill_ns orelse {
            // First call after lazy init -- just seed the timestamp,
            // bucket is already full.
            self.last_refill_ns = now_ns;
            return;
        };
        if (now_ns <= last) return; // clock didn't advance (or went backward)

        const elapsed_ns: u64 = now_ns - last;

        // tokens_to_add = rate * elapsed_ns / 1e9
        const add: u128 = @as(u128, self.rate) * @as(u128, elapsed_ns) / std.time.ns_per_s;
        if (add == 0) return;

        const add_clamped: u64 = @intCast(@min(add, self.capacity));
        self.tokens = @min(self.tokens +| add_clamped, self.capacity);
        self.last_refill_ns = now_ns;
    }

    /// Try to consume `amount` tokens at `now_ns`.
    pub fn consumeAt(self: *TokenBucket, amount: u64, now_ns: u64) u64 {
        if (self.rate == 0) return amount; // unlimited

        self.refillAt(now_ns);

        if (self.tokens == 0) return 0;

        const consumed = @min(amount, self.tokens);
        self.tokens -= consumed;
        return consumed;
    }

    /// Check how many bytes can be consumed at `now_ns`.
    pub fn availableAt(self: *TokenBucket, now_ns: u64) u64 {
        if (self.rate == 0) return std.math.maxInt(u64);

        self.refillAt(now_ns);
        return self.tokens;
    }

    /// Return the delay in nanoseconds (relative to `now_ns`) until
    /// `amount` tokens would be available.
    pub fn delayNsAt(self: *TokenBucket, amount: u64, now_ns: u64) u64 {
        if (self.rate == 0) return 0;

        self.refillAt(now_ns);

        if (self.tokens >= amount) return 0;

        const deficit = amount - self.tokens;
        // delay = deficit / rate * 1e9
        return @intCast(@as(u128, deficit) * std.time.ns_per_s / @as(u128, self.rate));
    }

    /// Returns true if the rate limiter is active (rate > 0).
    pub fn isActive(self: *const TokenBucket) bool {
        return self.rate > 0;
    }
};

/// Pair of token buckets for download and upload rate limiting.
pub const RateLimiter = struct {
    download: TokenBucket,
    upload: TokenBucket,

    pub fn init(dl_rate: u64, ul_rate: u64) RateLimiter {
        return initComptime(dl_rate, ul_rate);
    }

    /// Comptime-friendly init that defers timestamp to first use.
    pub fn initComptime(dl_rate: u64, ul_rate: u64) RateLimiter {
        return .{
            .download = TokenBucket.initComptime(dl_rate),
            .upload = TokenBucket.initComptime(ul_rate),
        };
    }

    /// Set download rate limit (bytes/sec). 0 = unlimited.
    pub fn setDownloadRate(self: *RateLimiter, rate: u64, now_ns: u64) void {
        self.download.setRate(rate, now_ns);
    }

    /// Set upload rate limit (bytes/sec). 0 = unlimited.
    pub fn setUploadRate(self: *RateLimiter, rate: u64, now_ns: u64) void {
        self.upload.setRate(rate, now_ns);
    }

    /// Returns true if any rate limiting is active.
    pub fn isActive(self: *const RateLimiter) bool {
        return self.download.isActive() or self.upload.isActive();
    }
};

// ── Tests ─────────────────────────────────────────────────

test "unlimited bucket always allows full consume" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(@as(u64, 1000), bucket.consumeAt(1000, 0));
    try std.testing.expectEqual(@as(u64, 999999), bucket.consumeAt(999999, 0));
    try std.testing.expect(!bucket.isActive());
}

test "bucket starts full" {
    const bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 1024), bucket.tokens);
    try std.testing.expectEqual(@as(u64, 1024), bucket.capacity);
    try std.testing.expect(bucket.isActive());
}

test "consume reduces tokens" {
    var bucket = TokenBucket.init(1024);
    const consumed = bucket.consumeAt(512, 1);
    try std.testing.expectEqual(@as(u64, 512), consumed);
    try std.testing.expectEqual(@as(u64, 512), bucket.tokens);
}

test "consume returns zero when empty" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consumeAt(1024, 1); // drain
    const consumed = bucket.consumeAt(100, 1);
    try std.testing.expectEqual(@as(u64, 0), consumed);
}

test "partial consume when not enough tokens" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consumeAt(900, 1);
    const consumed = bucket.consumeAt(200, 1);
    try std.testing.expectEqual(@as(u64, 124), consumed);
}

test "setRate resets bucket" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consumeAt(1024, 1);
    bucket.setRate(2048, 2);
    try std.testing.expectEqual(@as(u64, 2048), bucket.rate);
    try std.testing.expectEqual(@as(u64, 2048), bucket.capacity);
    try std.testing.expectEqual(@as(u64, 2048), bucket.tokens);
}

test "setRate to zero makes unlimited" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consumeAt(1024, 1);
    bucket.setRate(0, 2);
    try std.testing.expect(!bucket.isActive());
    try std.testing.expectEqual(@as(u64, 500), bucket.consumeAt(500, 3));
}

test "delayNs returns zero for unlimited" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(@as(u64, 0), bucket.delayNsAt(1000, 0));
}

test "delayNs returns zero when tokens available" {
    var bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 0), bucket.delayNsAt(512, 0));
}

test "delayNs calculates wait time for empty bucket" {
    var bucket = TokenBucket.init(1000);
    _ = bucket.consumeAt(1000, 0); // drain completely
    // Need 500 tokens at 1000/s = 0.5s = 500_000_000 ns. With sim time
    // at the same instant as the consume, no refill happens.
    const delay = bucket.delayNsAt(500, 0);
    try std.testing.expectEqual(@as(u64, 500_000_000), delay);
}

test "RateLimiter init and isActive" {
    const rl = RateLimiter.init(0, 0);
    try std.testing.expect(!rl.isActive());

    const rl2 = RateLimiter.init(1024, 0);
    try std.testing.expect(rl2.isActive());

    const rl3 = RateLimiter.init(0, 2048);
    try std.testing.expect(rl3.isActive());
}

test "RateLimiter setDownloadRate and setUploadRate" {
    var rl = RateLimiter.init(0, 0);
    try std.testing.expect(!rl.isActive());

    rl.setDownloadRate(1024, 0);
    try std.testing.expect(rl.isActive());
    try std.testing.expectEqual(@as(u64, 1024), rl.download.rate);

    rl.setUploadRate(2048, 0);
    try std.testing.expectEqual(@as(u64, 2048), rl.upload.rate);
}

test "available returns current tokens" {
    var bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 1024), bucket.availableAt(0));
    _ = bucket.consumeAt(300, 0);
    try std.testing.expectEqual(@as(u64, 724), bucket.availableAt(0));
}

test "available returns max for unlimited" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(std.math.maxInt(u64), bucket.availableAt(0));
}

test "refill credits elapsed time deterministically" {
    // Anchored at t=0 — `last_refill_ns: ?u64` makes this safe (the
    // earlier `== 0` sentinel would have re-seeded on every call).
    var bucket = TokenBucket.init(1_000); // 1000 bytes/sec
    _ = bucket.consumeAt(1_000, 0); // drain (also seeds last_refill_ns=0)
    try std.testing.expectEqual(@as(u64, 0), bucket.tokens);

    // After 250 ms we should get 250 tokens.
    bucket.refillAt(250 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 250), bucket.tokens);

    // After another 750 ms (1s total) we should be back to capacity.
    bucket.refillAt(1 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 1_000), bucket.tokens);
}

test "refill clock-going-backward is a no-op" {
    var bucket = TokenBucket.init(1_000);
    _ = bucket.consumeAt(1_000, 1_000_000_000); // drain at t=1s
    bucket.refillAt(500_000_000); // pretend now < last_refill: must not credit
    try std.testing.expectEqual(@as(u64, 0), bucket.tokens);
}

test "refill across the t=0 anchor seeds rather than crediting" {
    // Catches the sentinel-zero regression: starting at t=0 must NOT
    // credit a half-millennium of tokens.
    var bucket = TokenBucket.init(1_000);
    _ = bucket.consumeAt(1_000, 0); // drain at t=0; seeds last_refill_ns
    try std.testing.expectEqual(@as(u64, 0), bucket.tokens);

    // Same instant — no credit.
    bucket.refillAt(0);
    try std.testing.expectEqual(@as(u64, 0), bucket.tokens);

    // 100 ms later — 100 tokens.
    bucket.refillAt(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 100), bucket.tokens);
}

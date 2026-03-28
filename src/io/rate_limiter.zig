const std = @import("std");

/// Token bucket rate limiter for bandwidth throttling.
///
/// Fills at `rate` bytes per second. Each consume() call removes tokens.
/// When the bucket is empty, consume() returns the number of nanoseconds
/// the caller should wait before retrying. A rate of 0 means unlimited.
///
/// Thread-safety: NOT thread-safe. Each bucket should be accessed from
/// a single thread (the event loop thread).
pub const TokenBucket = struct {
    /// Maximum tokens (burst size). Equals `rate` (1 second of burst).
    capacity: u64,

    /// Current token count.
    tokens: u64,

    /// Fill rate in bytes per second. 0 = unlimited.
    rate: u64,

    /// Timestamp of last refill (nanoseconds, monotonic clock).
    last_refill_ns: i128,

    /// Create a token bucket with the given rate (bytes/sec).
    /// A rate of 0 means unlimited (consume always succeeds).
    pub fn init(rate: u64) TokenBucket {
        return initWithTimestamp(rate, std.time.nanoTimestamp());
    }

    /// Comptime-friendly init that defers timestamp to first use.
    pub fn initComptime(rate: u64) TokenBucket {
        return initWithTimestamp(rate, 0);
    }

    fn initWithTimestamp(rate: u64, ts: i128) TokenBucket {
        return .{
            .capacity = if (rate == 0) std.math.maxInt(u64) else rate,
            .tokens = if (rate == 0) std.math.maxInt(u64) else rate,
            .rate = rate,
            .last_refill_ns = ts,
        };
    }

    /// Set a new rate (bytes/sec). 0 = unlimited.
    /// Resets the bucket to full capacity at the new rate.
    pub fn setRate(self: *TokenBucket, rate: u64) void {
        self.rate = rate;
        self.capacity = if (rate == 0) std.math.maxInt(u64) else rate;
        self.tokens = self.capacity;
        self.last_refill_ns = std.time.nanoTimestamp();
    }

    /// Refill tokens based on elapsed time.
    pub fn refill(self: *TokenBucket) void {
        if (self.rate == 0) return; // unlimited

        const now = std.time.nanoTimestamp();
        if (self.last_refill_ns == 0) {
            // First call after comptime init -- just set timestamp, bucket is already full
            self.last_refill_ns = now;
            return;
        }
        const elapsed_ns = now - self.last_refill_ns;
        if (elapsed_ns <= 0) return;

        // tokens_to_add = rate * elapsed_ns / 1e9
        const elapsed_u: u128 = @intCast(elapsed_ns);
        const add: u128 = @as(u128, self.rate) * elapsed_u / std.time.ns_per_s;
        if (add == 0) return;

        const add_clamped: u64 = @intCast(@min(add, self.capacity));
        self.tokens = @min(self.tokens +| add_clamped, self.capacity);
        self.last_refill_ns = now;
    }

    /// Try to consume `amount` tokens.
    /// Returns the number of bytes actually consumed (may be less than requested
    /// if the bucket doesn't have enough, but always at least 1 if there are any
    /// tokens). Returns 0 if no tokens are available.
    pub fn consume(self: *TokenBucket, amount: u64) u64 {
        if (self.rate == 0) return amount; // unlimited

        self.refill();

        if (self.tokens == 0) return 0;

        const consumed = @min(amount, self.tokens);
        self.tokens -= consumed;
        return consumed;
    }

    /// Check how many bytes can be consumed right now without actually consuming.
    pub fn available(self: *TokenBucket) u64 {
        if (self.rate == 0) return std.math.maxInt(u64);

        self.refill();
        return self.tokens;
    }

    /// Return the delay in nanoseconds until `amount` tokens would be available.
    /// Returns 0 if tokens are already available or rate is unlimited.
    pub fn delayNs(self: *TokenBucket, amount: u64) u64 {
        if (self.rate == 0) return 0;

        self.refill();

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
        return .{
            .download = TokenBucket.init(dl_rate),
            .upload = TokenBucket.init(ul_rate),
        };
    }

    /// Comptime-friendly init that defers timestamp to first use.
    pub fn initComptime(dl_rate: u64, ul_rate: u64) RateLimiter {
        return .{
            .download = TokenBucket.initComptime(dl_rate),
            .upload = TokenBucket.initComptime(ul_rate),
        };
    }

    /// Set download rate limit (bytes/sec). 0 = unlimited.
    pub fn setDownloadRate(self: *RateLimiter, rate: u64) void {
        self.download.setRate(rate);
    }

    /// Set upload rate limit (bytes/sec). 0 = unlimited.
    pub fn setUploadRate(self: *RateLimiter, rate: u64) void {
        self.upload.setRate(rate);
    }

    /// Returns true if any rate limiting is active.
    pub fn isActive(self: *const RateLimiter) bool {
        return self.download.isActive() or self.upload.isActive();
    }
};

// ── Tests ─────────────────────────────────────────────────

test "unlimited bucket always allows full consume" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(@as(u64, 1000), bucket.consume(1000));
    try std.testing.expectEqual(@as(u64, 999999), bucket.consume(999999));
    try std.testing.expect(!bucket.isActive());
}

test "bucket starts full" {
    var bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 1024), bucket.tokens);
    try std.testing.expectEqual(@as(u64, 1024), bucket.capacity);
    try std.testing.expect(bucket.isActive());
}

test "consume reduces tokens" {
    var bucket = TokenBucket.init(1024);
    const consumed = bucket.consume(512);
    try std.testing.expectEqual(@as(u64, 512), consumed);
    try std.testing.expectEqual(@as(u64, 512), bucket.tokens);
}

test "consume returns zero when empty" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consume(1024); // drain
    const consumed = bucket.consume(100);
    try std.testing.expectEqual(@as(u64, 0), consumed);
}

test "partial consume when not enough tokens" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consume(900);
    const consumed = bucket.consume(200);
    try std.testing.expectEqual(@as(u64, 124), consumed);
}

test "setRate resets bucket" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consume(1024);
    bucket.setRate(2048);
    try std.testing.expectEqual(@as(u64, 2048), bucket.rate);
    try std.testing.expectEqual(@as(u64, 2048), bucket.capacity);
    try std.testing.expectEqual(@as(u64, 2048), bucket.tokens);
}

test "setRate to zero makes unlimited" {
    var bucket = TokenBucket.init(1024);
    _ = bucket.consume(1024);
    bucket.setRate(0);
    try std.testing.expect(!bucket.isActive());
    try std.testing.expectEqual(@as(u64, 500), bucket.consume(500));
}

test "delayNs returns zero for unlimited" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(@as(u64, 0), bucket.delayNs(1000));
}

test "delayNs returns zero when tokens available" {
    var bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 0), bucket.delayNs(512));
}

test "delayNs calculates wait time for empty bucket" {
    var bucket = TokenBucket.init(1000);
    _ = bucket.consume(1000); // drain completely
    // Need 500 tokens at 1000/s = 0.5s = 500_000_000 ns
    const delay = bucket.delayNs(500);
    // Allow some tolerance for refill that may have happened
    try std.testing.expect(delay > 0);
    try std.testing.expect(delay <= 500_000_000);
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

    rl.setDownloadRate(1024);
    try std.testing.expect(rl.isActive());
    try std.testing.expectEqual(@as(u64, 1024), rl.download.rate);

    rl.setUploadRate(2048);
    try std.testing.expectEqual(@as(u64, 2048), rl.upload.rate);
}

test "available returns current tokens" {
    var bucket = TokenBucket.init(1024);
    try std.testing.expectEqual(@as(u64, 1024), bucket.available());
    _ = bucket.consume(300);
    try std.testing.expectEqual(@as(u64, 724), bucket.available());
}

test "available returns max for unlimited" {
    var bucket = TokenBucket.init(0);
    try std.testing.expectEqual(std.math.maxInt(u64), bucket.available());
}

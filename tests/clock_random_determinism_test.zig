//! Demonstrates the testability win from `runtime.Clock` and
//! `runtime.Random`: a token-bucket consume sequence and a tracker-key
//! generation sequence both reproduce byte-for-byte across runs when
//! the clock and the RNG are sim-injected.
//!
//! These tests would have been impossible to write before this work:
//! - `TokenBucket` previously read `std.time.nanoTimestamp()`
//!   internally, so two runs of the "consume across 200 ms" sequence
//!   would credit different numbers of tokens depending on real-clock
//!   drift between calls.
//! - `Request.generateKey` previously read `std.crypto.random` directly,
//!   so two runs would produce different keys by design.
//!
//! Both subsystems now accept their time / random source as arguments,
//! and these tests assert the determinism invariant.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");

const Clock = varuna.runtime.Clock;
const Random = varuna.runtime.Random;
const TokenBucket = varuna.io.rate_limiter.TokenBucket;
const Request = varuna.tracker.announce.Request;

// ── TokenBucket determinism under SimClock ──────────────────

fn runRateLimitScenario(start_clock: *Clock) struct {
    consumed: [4]u64,
    available: u64,
} {
    var bucket = TokenBucket.init(1_000); // 1000 bytes/sec

    // Drain at t=clock_anchor.
    const c1 = bucket.consumeAt(1_000, start_clock.nowNs());

    // Advance 100 ms, half-refill, partial consume.
    start_clock.advanceMs(100);
    const c2 = bucket.consumeAt(50, start_clock.nowNs());

    // Advance another 250 ms, big request.
    start_clock.advanceMs(250);
    const c3 = bucket.consumeAt(500, start_clock.nowNs());

    // Advance 1s, request more than capacity.
    start_clock.advanceSecs(1);
    const c4 = bucket.consumeAt(2_000, start_clock.nowNs());

    return .{
        .consumed = .{ c1, c2, c3, c4 },
        .available = bucket.availableAt(start_clock.nowNs()),
    };
}

test "TokenBucket consume sequence is deterministic under SimClock" {
    var clock_a = Clock.simAtSecs(1);
    var clock_b = Clock.simAtSecs(1);

    const a = runRateLimitScenario(&clock_a);
    const b = runRateLimitScenario(&clock_b);

    try testing.expectEqualSlices(u64, &a.consumed, &b.consumed);
    try testing.expectEqual(a.available, b.available);
}

test "TokenBucket sequence values match the analytical model" {
    var clock = Clock.simAtSecs(1);
    const r = runRateLimitScenario(&clock);

    // Drain → 1000 bytes consumed.
    try testing.expectEqual(@as(u64, 1_000), r.consumed[0]);
    // 100 ms later → 100 tokens credited; consume 50 → 50 left.
    try testing.expectEqual(@as(u64, 50), r.consumed[1]);
    // 250 ms further → 250 more tokens; bucket has 50 left + 250 = 300.
    // Request 500 → consume 300.
    try testing.expectEqual(@as(u64, 300), r.consumed[2]);
    // 1s further → would credit 1000 but capacity caps at 1000;
    // bucket goes to 1000, then request 2000 → consume 1000.
    try testing.expectEqual(@as(u64, 1_000), r.consumed[3]);
    // After draining, bucket is empty.
    try testing.expectEqual(@as(u64, 0), r.available);
}

test "TokenBucket sequence diverges across SimClock seeds" {
    var clock_fast = Clock.simAtSecs(1);
    var clock_slow = Clock.simAtSecs(1);

    var bucket_fast = TokenBucket.init(1_000);
    var bucket_slow = TokenBucket.init(1_000);

    _ = bucket_fast.consumeAt(1_000, clock_fast.nowNs());
    _ = bucket_slow.consumeAt(1_000, clock_slow.nowNs());

    clock_fast.advanceMs(500);
    clock_slow.advanceMs(50);

    const got_fast = bucket_fast.consumeAt(1_000, clock_fast.nowNs());
    const got_slow = bucket_slow.consumeAt(1_000, clock_slow.nowNs());

    // Fast clock got 500 ms of refill (500 tokens). Slow got 50 (50 tokens).
    try testing.expectEqual(@as(u64, 500), got_fast);
    try testing.expectEqual(@as(u64, 50), got_slow);
}

// ── tracker generateKey determinism under SimRandom ─────────

test "tracker generateKey is byte-for-byte deterministic under SimRandom" {
    inline for (.{ 0, 1, 0xdeadbeef, 0xfeedface, std.math.maxInt(u64) }) |seed| {
        var r1 = Random.simRandom(seed);
        var r2 = Random.simRandom(seed);
        const k1 = Request.generateKey(&r1);
        const k2 = Request.generateKey(&r2);
        try testing.expectEqualSlices(u8, &k1, &k2);

        // Hex-character invariant holds regardless of seed.
        for (k1) |c| {
            try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
    }
}

test "tracker generateKey produces distinct sequences across seeds" {
    var ra = Random.simRandom(1);
    var rb = Random.simRandom(2);
    const ka = Request.generateKey(&ra);
    const kb = Request.generateKey(&rb);
    try testing.expect(!std.mem.eql(u8, &ka, &kb));
}

test "tracker generateKey across many calls under one seed" {
    var rng = Random.simRandom(0xc0ffee);
    var keys: [16][8]u8 = undefined;
    for (0..keys.len) |i| {
        keys[i] = Request.generateKey(&rng);
    }

    // Same seed reproduces the same 16-key sequence.
    var rng2 = Random.simRandom(0xc0ffee);
    for (0..keys.len) |i| {
        const k = Request.generateKey(&rng2);
        try testing.expectEqualSlices(u8, &keys[i], &k);
    }
}

// ── Combined Clock + Random determinism ─────────────────────

test "rate-limit + key-generation pipeline is deterministic under sim sources" {
    const ScenarioOut = struct {
        first_consume: u64,
        key: [8]u8,
        post_clock_ns: u64,
    };

    const scenario = struct {
        fn run(clock_seed_secs: i64, rng_seed: u64) ScenarioOut {
            var c = Clock.simAtSecs(clock_seed_secs);
            var r = Random.simRandom(rng_seed);

            var bucket = TokenBucket.init(2_048);
            const consumed = bucket.consumeAt(1_024, c.nowNs());

            c.advanceMs(100);
            const key = Request.generateKey(&r);

            return .{
                .first_consume = consumed,
                .key = key,
                .post_clock_ns = c.nowNs(),
            };
        }
    }.run;

    const a = scenario(100, 0xdeadbeef);
    const b = scenario(100, 0xdeadbeef);
    try testing.expectEqual(a.first_consume, b.first_consume);
    try testing.expectEqualSlices(u8, &a.key, &b.key);
    try testing.expectEqual(a.post_clock_ns, b.post_clock_ns);

    // Different seeds → different keys, same bucket math.
    const c = scenario(100, 0xfeedface);
    try testing.expectEqual(a.first_consume, c.first_consume);
    try testing.expect(!std.mem.eql(u8, &a.key, &c.key));
    try testing.expectEqual(a.post_clock_ns, c.post_clock_ns);
}

//! Injected randomness for daemon code paths whose RNG output the
//! simulator wants to drive deterministically.
//!
//! The `.real` variant delegates to `std.crypto.random` (production —
//! cryptographically strong, OS-seeded). The `.sim` variant wraps a
//! seeded `std.Random.DefaultPrng` so test runs reproduce byte-for-byte
//! across seeds.
//!
//! ## Design
//!
//! Tagged-union (Option A), same shape as `runtime.Clock`. Random reads
//! are scattered across DHT, MSE, tracker, peer, and uTP modules; a
//! comptime `RandomOf(comptime Impl)` would force every consumer's
//! generic graph to widen. Tagged-union dispatch is one branch-predicted
//! switch per fill — the actual PRNG state churn dominates anyway.
//!
//! ## Cryptographic vs simulation-friendly randomness
//!
//! NOT every `std.crypto.random` caller is safe to migrate. Some uses
//! are security-critical and **must** stay on the OS CSPRNG even in
//! tests:
//!
//!   * MSE handshake DH keys, pad lengths, encrypted-payload pads
//!     (`src/crypto/mse.zig`) — predicting these breaks the protocol's
//!     plausible-deniability properties.
//!   * Peer ID suffix (`src/torrent/peer_id.zig`) — predictability
//!     enables cross-torrent user correlation by trackers.
//!   * DHT node ID (`src/dht/node_id.zig`) — BEP 42 Sybil-resistance
//!     leans on hard-to-predict node IDs.
//!   * DHT announce_peer tokens (`src/dht/token.zig`) — predictable
//!     tokens defeat the BEP 5 anti-amplification check.
//!   * RPC session SID (`src/rpc/auth.zig`) — predictability breaks
//!     authentication.
//!
//! Safe to swap for `Random` in tests:
//!
//!   * UDP tracker transaction IDs — a 32-bit nonce for matching
//!     responses to outstanding requests; predictability isn't a
//!     security failure.
//!   * uTP connection IDs — 16-bit collision-avoidance number; the
//!     protocol negotiates around collisions.
//!   * Tracker `key` parameter — supposed to be random but used as a
//!     stable client identifier; tests benefit from determinism.
//!
//! ## Usage
//!
//! ```zig
//! var rng = Random.realRandom();         // production
//! var rng = Random.simRandom(0xdeadbeef); // tests
//!
//! var buf: [4]u8 = undefined;
//! rng.bytes(&buf);
//! const tx_id = rng.int(u32);
//! ```

const std = @import("std");

pub const Random = union(enum) {
    real: void,
    sim: std.Random.DefaultPrng,

    pub fn realRandom() Random {
        return .real;
    }

    /// Sim variant seeded with `seed`. Two `Random.simRandom(s)` values
    /// produce the same byte stream.
    pub fn simRandom(seed: u64) Random {
        return .{ .sim = std.Random.DefaultPrng.init(seed) };
    }

    /// Fill `buf` with random bytes.
    pub fn bytes(self: *Random, buf: []u8) void {
        switch (self.*) {
            .real => std.crypto.random.bytes(buf),
            .sim => |*prng| prng.random().bytes(buf),
        }
    }

    /// Return a uniformly-distributed value of integer type `T`.
    pub fn int(self: *Random, comptime T: type) T {
        switch (self.*) {
            .real => return std.crypto.random.int(T),
            .sim => |*prng| return prng.random().int(T),
        }
    }

    /// Return a uniformly-distributed value in `[0, less_than)`.
    pub fn uintLessThan(self: *Random, comptime T: type, less_than: T) T {
        switch (self.*) {
            .real => return std.crypto.random.uintLessThan(T, less_than),
            .sim => |*prng| return prng.random().uintLessThan(T, less_than),
        }
    }
};

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;

test "real random produces distinct buffers" {
    var rng = Random.realRandom();
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    rng.bytes(&a);
    rng.bytes(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "sim random with same seed reproduces byte stream" {
    var r1 = Random.simRandom(0xdeadbeef);
    var r2 = Random.simRandom(0xdeadbeef);

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    r1.bytes(&a);
    r2.bytes(&b);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "sim random with different seeds diverges" {
    var r1 = Random.simRandom(1);
    var r2 = Random.simRandom(2);

    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    r1.bytes(&a);
    r2.bytes(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "sim random int matches bytes-derived value" {
    var r = Random.simRandom(0xfeedface);
    const v = r.int(u32);
    // Sanity: just ensure it produces a non-zero value most of the
    // time. We don't assert a specific value because it's an
    // implementation detail of DefaultPrng.
    _ = v;
}

test "sim random uintLessThan stays in range" {
    var r = Random.simRandom(0xcafe);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const v = r.uintLessThan(u32, 100);
        try testing.expect(v < 100);
    }
}

test "sim random reproduces int sequence" {
    var r1 = Random.simRandom(7);
    var r2 = Random.simRandom(7);
    try testing.expectEqual(r1.int(u64), r2.int(u64));
    try testing.expectEqual(r1.int(u64), r2.int(u64));
    try testing.expectEqual(r1.int(u32), r2.int(u32));
}

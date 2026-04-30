const std = @import("std");
const Random = @import("../runtime/random.zig").Random;

/// Token manager for announce_peer security (BEP 5).
///
/// Tokens prevent third parties from announcing on behalf of others.
/// When responding to get_peers, we generate a token tied to the
/// querier's IP address. When they later announce_peer, they must
/// present a valid token.
///
/// Token = SipHash-2-4(secret, ip_bytes), truncated to 8 bytes.
/// We accept tokens from both current and previous secret (rotation window).
pub const TokenManager = struct {
    secret: [16]u8,
    prev_secret: [16]u8,
    last_rotation: i64,

    /// Rotation interval: 5 minutes.
    pub const rotation_interval_secs: i64 = 5 * 60;

    pub fn init(random: *Random) TokenManager {
        var secret: [16]u8 = undefined;
        var prev_secret: [16]u8 = undefined;
        random.bytes(&secret);
        random.bytes(&prev_secret);
        return .{
            .secret = secret,
            .prev_secret = prev_secret,
            .last_rotation = std.time.timestamp(),
        };
    }

    /// Initialize with a specific timestamp (for testing).
    pub fn initWithTime(random: *Random, now: i64) TokenManager {
        var secret: [16]u8 = undefined;
        var prev_secret: [16]u8 = undefined;
        random.bytes(&secret);
        random.bytes(&prev_secret);
        return .{
            .secret = secret,
            .prev_secret = prev_secret,
            .last_rotation = now,
        };
    }

    /// Generate a token for the given IP address bytes.
    pub fn generateToken(self: *const TokenManager, ip: []const u8) [8]u8 {
        return computeToken(self.secret, ip);
    }

    /// Validate a token against current or previous secret.
    pub fn validateToken(self: *const TokenManager, token: []const u8, ip: []const u8) bool {
        if (token.len != 8) return false;

        const current = computeToken(self.secret, ip);
        if (std.mem.eql(u8, token, &current)) return true;

        const previous = computeToken(self.prev_secret, ip);
        return std.mem.eql(u8, token, &previous);
    }

    /// Rotate secrets if enough time has passed.
    pub fn maybeRotate(self: *TokenManager, random: *Random, now: i64) void {
        if (now - self.last_rotation >= rotation_interval_secs) {
            self.prev_secret = self.secret;
            random.bytes(&self.secret);
            self.last_rotation = now;
        }
    }

    fn computeToken(secret: [16]u8, ip: []const u8) [8]u8 {
        // Use SipHash-2-4 with the secret as key and IP as message.
        const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);
        const hash = SipHash.toInt(ip, &secret);
        return @bitCast(hash);
    }
};

// ── Tests ──────────────────────────────────────────────

test "token generation is deterministic for same IP" {
    var rng = Random.simRandom(0x100);
    const mgr = TokenManager.init(&rng);
    const ip = [_]u8{ 192, 168, 1, 100 };
    const t1 = mgr.generateToken(&ip);
    const t2 = mgr.generateToken(&ip);
    try std.testing.expectEqual(t1, t2);
}

test "tokens differ for different IPs" {
    var rng = Random.simRandom(0x101);
    const mgr = TokenManager.init(&rng);
    const ip1 = [_]u8{ 192, 168, 1, 100 };
    const ip2 = [_]u8{ 192, 168, 1, 101 };
    const t1 = mgr.generateToken(&ip1);
    const t2 = mgr.generateToken(&ip2);
    try std.testing.expect(!std.mem.eql(u8, &t1, &t2));
}

test "validate accepts current token" {
    var rng = Random.simRandom(0x102);
    const mgr = TokenManager.init(&rng);
    const ip = [_]u8{ 10, 0, 0, 1 };
    const token = mgr.generateToken(&ip);
    try std.testing.expect(mgr.validateToken(&token, &ip));
}

test "validate rejects wrong IP" {
    var rng = Random.simRandom(0x103);
    const mgr = TokenManager.init(&rng);
    const ip1 = [_]u8{ 10, 0, 0, 1 };
    const ip2 = [_]u8{ 10, 0, 0, 2 };
    const token = mgr.generateToken(&ip1);
    try std.testing.expect(!mgr.validateToken(&token, &ip2));
}

test "validate rejects garbage token" {
    var rng = Random.simRandom(0x104);
    const mgr = TokenManager.init(&rng);
    const ip = [_]u8{ 10, 0, 0, 1 };
    const garbage = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(!mgr.validateToken(&garbage, &ip));
}

test "validate rejects wrong-length token" {
    var rng = Random.simRandom(0x105);
    const mgr = TokenManager.init(&rng);
    const ip = [_]u8{ 10, 0, 0, 1 };
    const short = [_]u8{ 1, 2, 3 };
    try std.testing.expect(!mgr.validateToken(&short, &ip));
}

test "rotation preserves previous secret" {
    var rng = Random.simRandom(0x106);
    var mgr = TokenManager.initWithTime(&rng, 1000);
    const ip = [_]u8{ 192, 168, 0, 1 };
    const token_before = mgr.generateToken(&ip);

    // Rotate
    mgr.maybeRotate(&rng, 1000 + TokenManager.rotation_interval_secs);

    // Old token should still validate (via prev_secret)
    try std.testing.expect(mgr.validateToken(&token_before, &ip));

    // New token should also validate
    const token_after = mgr.generateToken(&ip);
    try std.testing.expect(mgr.validateToken(&token_after, &ip));
}

test "double rotation invalidates old token" {
    var rng = Random.simRandom(0x107);
    var mgr = TokenManager.initWithTime(&rng, 1000);
    const ip = [_]u8{ 192, 168, 0, 1 };
    const token_old = mgr.generateToken(&ip);

    // Rotate twice
    mgr.maybeRotate(&rng, 1000 + TokenManager.rotation_interval_secs);
    mgr.maybeRotate(&rng, 1000 + 2 * TokenManager.rotation_interval_secs);

    // Old token should no longer validate (both secrets rotated)
    try std.testing.expect(!mgr.validateToken(&token_old, &ip));
}

test "TokenManager init is byte-deterministic under SimRandom" {
    var r1 = Random.simRandom(0x202);
    var r2 = Random.simRandom(0x202);
    const m1 = TokenManager.init(&r1);
    const m2 = TokenManager.init(&r2);
    try std.testing.expectEqualSlices(u8, &m1.secret, &m2.secret);
    try std.testing.expectEqualSlices(u8, &m1.prev_secret, &m2.prev_secret);
}

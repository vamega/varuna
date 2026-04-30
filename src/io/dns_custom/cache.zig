//! Bounded TTL cache for DNS lookup results.
//!
//! Mirrors the cache shape in `dns_threadpool.zig`
//! (`StringHashMapUnmanaged(CacheEntry)`, `max_entries=64`, evict-by-
//! earliest-expiry-on-insert) but with two refinements taken from the
//! design doc:
//!
//! 1. **Per-record TTL** — every entry carries the authoritative TTL
//!    from the response, clamped into `TtlBounds.[floor_s, cap_s]`.
//!    Replaces the threadpool backend's fixed `cap_s` lifetime
//!    (which it has to use because `getaddrinfo` doesn't expose
//!    TTL).
//! 2. **Negative caching** — `NXDOMAIN` and `SERVFAIL` answers are
//!    cached for `floor_s` so a misconfigured tracker URL doesn't
//!    pummel the resolver on every announce.
//!
//! Pure data structure — no I/O, allocator-driven. Safe against
//! repeated puts (updates in place; no duplicate keys).

const std = @import("std");

const TtlBoundsType = @import("../dns.zig").TtlBounds;

pub const Cache = struct {
    map: Map,
    capacity: u16,

    const Map = std.StringHashMapUnmanaged(Entry);

    pub const default_capacity: u16 = 64;

    pub const Entry = union(enum) {
        positive: Positive,
        negative: Negative,

        pub fn expiresAt(self: Entry) i64 {
            return switch (self) {
                .positive => |p| p.expires_at,
                .negative => |n| n.expires_at,
            };
        }
    };

    pub const Positive = struct {
        address: std.net.Address,
        expires_at: i64,
    };

    pub const Negative = struct {
        /// Why we're caching the failure: NXDOMAIN, SERVFAIL, or
        /// resolver-side "no answer" / "all servers timed out".
        reason: NegReason,
        expires_at: i64,
    };

    pub const NegReason = enum { nx_domain, server_failure, no_answer };

    pub fn init(capacity: u16) Cache {
        return .{ .map = .{}, .capacity = capacity };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var iter = self.map.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.map.deinit(allocator);
    }

    /// Look up `host`. Returns `null` if no fresh entry exists; an
    /// expired entry is treated as "missing" and *not* removed (lazy
    /// eviction — `put` reclaims at capacity).
    pub fn get(self: *const Cache, host: []const u8, now: i64) ?Entry {
        const e = self.map.get(host) orelse return null;
        if (e.expiresAt() <= now) return null;
        return e;
    }

    /// Insert or update. The TTL is clamped into `bounds` before the
    /// expiry timestamp is computed.
    pub fn putPositive(
        self: *Cache,
        allocator: std.mem.Allocator,
        host: []const u8,
        address: std.net.Address,
        answer_ttl_s: u32,
        bounds: TtlBoundsType,
        now: i64,
    ) std.mem.Allocator.Error!void {
        const ttl = bounds.clamp(answer_ttl_s);
        const expires_at = now + @as(i64, ttl);
        try self.put(allocator, host, .{ .positive = .{
            .address = address,
            .expires_at = expires_at,
        } });
    }

    /// Cache a negative result (NXDOMAIN / SERVFAIL / no-answer).
    /// Negative entries always live for the floor (`bounds.floor_s`)
    /// — short-bounded so we don't pin a wrong "doesn't exist"
    /// outcome forever.
    pub fn putNegative(
        self: *Cache,
        allocator: std.mem.Allocator,
        host: []const u8,
        reason: NegReason,
        bounds: TtlBoundsType,
        now: i64,
    ) std.mem.Allocator.Error!void {
        const expires_at = now + @as(i64, bounds.floor_s);
        try self.put(allocator, host, .{ .negative = .{
            .reason = reason,
            .expires_at = expires_at,
        } });
    }

    fn put(
        self: *Cache,
        allocator: std.mem.Allocator,
        host: []const u8,
        entry: Entry,
    ) std.mem.Allocator.Error!void {
        if (self.map.getPtr(host)) |slot| {
            slot.* = entry;
            return;
        }
        if (self.map.count() >= self.capacity) {
            self.evictOldest(allocator);
        }
        const owned = try allocator.dupe(u8, host);
        errdefer allocator.free(owned);
        try self.map.put(allocator, owned, entry);
    }

    pub fn invalidate(self: *Cache, allocator: std.mem.Allocator, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| allocator.free(kv.key);
    }

    pub fn clearAll(self: *Cache, allocator: std.mem.Allocator) void {
        var iter = self.map.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        self.map.clearRetainingCapacity();
    }

    pub fn count(self: *const Cache) u32 {
        return self.map.count();
    }

    /// Sweep expired entries. O(N); call lazily (e.g. on resolver
    /// tick) to bound stale memory.
    pub fn sweepExpired(self: *Cache, allocator: std.mem.Allocator, now: i64) usize {
        var removed: usize = 0;
        var to_remove: [Cache.scratch_cap]usize = undefined;
        var to_remove_keys: [Cache.scratch_cap][]const u8 = undefined;
        var n: usize = 0;

        var iter = self.map.iterator();
        while (iter.next()) |kv| {
            if (n >= to_remove.len) break;
            if (kv.value_ptr.expiresAt() <= now) {
                to_remove[n] = removed;
                to_remove_keys[n] = kv.key_ptr.*;
                n += 1;
            }
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.map.fetchRemove(to_remove_keys[i])) |kv| {
                allocator.free(kv.key);
                removed += 1;
            }
        }
        return removed;
    }

    const scratch_cap: usize = 16;

    fn evictOldest(self: *Cache, allocator: std.mem.Allocator) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);
        var iter = self.map.iterator();
        while (iter.next()) |kv| {
            const exp = kv.value_ptr.expiresAt();
            if (exp < oldest_time) {
                oldest_time = exp;
                oldest_key = kv.key_ptr.*;
            }
        }
        if (oldest_key) |k| {
            if (self.map.fetchRemove(k)) |kv| allocator.free(kv.key);
        }
    }
};

// ── Tests ────────────────────────────────────────────────

const testing = std.testing;
const TtlBounds = TtlBoundsType;

test "Cache.get returns null on cold miss" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    try testing.expect(c.get("x.test", 0) == null);
}

test "Cache.putPositive then get returns positive entry within TTL" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr, 600, TtlBounds.default, 1000);

    const got = c.get("a.test", 1500);
    try testing.expect(got != null);
    switch (got.?) {
        .positive => |p| try testing.expectEqual(@as(i64, 1600), p.expires_at),
        .negative => return error.UnexpectedNegative,
    }
}

test "Cache TTL is clamped to bounds.cap" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    // answer_ttl 86400 (1 day) clamped to default cap 3600
    try c.putPositive(testing.allocator, "a.test", addr, 86400, TtlBounds.default, 1000);
    const got = c.get("a.test", 1000).?;
    switch (got) {
        .positive => |p| try testing.expectEqual(@as(i64, 1000 + 3600), p.expires_at),
        .negative => return error.UnexpectedNegative,
    }
}

test "Cache TTL is clamped to bounds.floor" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    // answer_ttl 0 (server returning 0 during a migration) clamped to floor 30
    try c.putPositive(testing.allocator, "a.test", addr, 0, TtlBounds.default, 1000);
    const got = c.get("a.test", 1000).?;
    switch (got) {
        .positive => |p| try testing.expectEqual(@as(i64, 1030), p.expires_at),
        .negative => return error.UnexpectedNegative,
    }
}

test "Cache.get returns null on expired entry" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr, 60, TtlBounds.default, 1000);
    // bounds floor is 30, so TTL=60 is honored. Expires at 1060.
    try testing.expect(c.get("a.test", 1059) != null);
    try testing.expect(c.get("a.test", 1060) == null);
    try testing.expect(c.get("a.test", 9999) == null);
}

test "Cache.putNegative caches NXDOMAIN for floor seconds" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    try c.putNegative(testing.allocator, "nx.test", .nx_domain, TtlBounds.default, 1000);
    const got = c.get("nx.test", 1029).?;
    switch (got) {
        .negative => |n| {
            try testing.expectEqual(Cache.NegReason.nx_domain, n.reason);
            try testing.expectEqual(@as(i64, 1030), n.expires_at);
        },
        .positive => return error.UnexpectedPositive,
    }
    try testing.expect(c.get("nx.test", 1030) == null);
}

test "Cache.put updates existing entry without duplication" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr1, 60, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "a.test", addr2, 60, TtlBounds.default, 2000);
    try testing.expectEqual(@as(u32, 1), c.count());
    const got = c.get("a.test", 2000).?;
    switch (got) {
        .positive => |p| try testing.expectEqual(@as(i64, 2060), p.expires_at),
        .negative => return error.UnexpectedNegative,
    }
}

test "Cache.put evicts oldest at capacity" {
    var c = Cache.init(4);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);

    try c.putPositive(testing.allocator, "a.test", addr, 30, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "b.test", addr, 60, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "c.test", addr, 90, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "d.test", addr, 120, TtlBounds.default, 1000);
    try testing.expectEqual(@as(u32, 4), c.count());

    // Insert overflow — should evict "a.test" (earliest expiry).
    try c.putPositive(testing.allocator, "e.test", addr, 9999, TtlBounds.default, 1000);
    try testing.expectEqual(@as(u32, 4), c.count());
    try testing.expect(c.get("a.test", 1000) == null);
    try testing.expect(c.get("e.test", 1000) != null);
}

test "Cache.invalidate removes entry" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr, 60, TtlBounds.default, 1000);
    try testing.expectEqual(@as(u32, 1), c.count());
    c.invalidate(testing.allocator, "a.test");
    try testing.expectEqual(@as(u32, 0), c.count());
}

test "Cache.clearAll empties cache" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr, 60, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "b.test", addr, 60, TtlBounds.default, 1000);
    try testing.expectEqual(@as(u32, 2), c.count());
    c.clearAll(testing.allocator);
    try testing.expectEqual(@as(u32, 0), c.count());
}

test "Cache.sweepExpired drops expired entries" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "a.test", addr, 30, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "b.test", addr, 60, TtlBounds.default, 1000);
    try c.putPositive(testing.allocator, "c.test", addr, 9000, TtlBounds.default, 1000);
    try testing.expectEqual(@as(u32, 3), c.count());
    // At t=1100 a (expires 1030) and b (expires 1060) are gone; c (1000+3600 from cap-clamping = 4600) remains.
    const removed = c.sweepExpired(testing.allocator, 1100);
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(u32, 1), c.count());
    try testing.expect(c.get("c.test", 1100) != null);
}

test "Cache: positive then negative replaces entry kind" {
    var c = Cache.init(Cache.default_capacity);
    defer c.deinit(testing.allocator);
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 0);
    try c.putPositive(testing.allocator, "x.test", addr, 60, TtlBounds.default, 1000);
    try c.putNegative(testing.allocator, "x.test", .nx_domain, TtlBounds.default, 2000);
    try testing.expectEqual(@as(u32, 1), c.count());
    const got = c.get("x.test", 2000).?;
    switch (got) {
        .negative => |n| try testing.expectEqual(Cache.NegReason.nx_domain, n.reason),
        .positive => return error.UnexpectedPositive,
    }
}

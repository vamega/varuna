//! Top-level custom DNS resolver — generic over the IO backend.
//!
//! Composes:
//! - `cache.zig` for the bounded TTL cache
//! - `resolv_conf.zig` for the nameserver list
//! - `query.zig` for per-lookup state machines
//! - `message.zig` for wire-format encode/decode
//!
//! Public surface mirrors the existing `dns.zig` backends:
//!   - `init(allocator, io, config) -> Self`
//!   - `deinit(allocator)`
//!   - `resolveAsync(host, port, ctx, callback)`
//!   - `cacheResult(allocator, host, address)`
//!   - `invalidate(allocator, host)`
//!   - `clearAll(allocator)`
//!
//! The full integration (`-Ddns=custom` build flag dispatch) is
//! Phase F follow-up. See module top docstring of `query.zig` for
//! TCP-fallback-on-truncation and other deferred items.

const std = @import("std");

const dns = @import("../dns.zig");
const cache_mod = @import("cache.zig");
const message = @import("message.zig");
const query_mod = @import("query.zig");
const resolv_conf = @import("resolv_conf.zig");

pub const Config = struct {
    /// Cache capacity (entries).
    cache_capacity: u16 = cache_mod.Cache.default_capacity,
    /// TTL bounds applied to authoritative DNS TTLs.
    ttl_bounds: dns.TtlBounds = dns.TtlBounds.default,
    /// Per-server attempt timeout. Default 1500 ms.
    per_server_timeout_ns: u64 = 1_500 * std.time.ns_per_ms,
    /// Total query budget. Default 5000 ms.
    total_timeout_ns: u64 = 5_000 * std.time.ns_per_ms,
    /// Override the resolv.conf-derived servers. Useful for tests
    /// (and for callers that want to point at a specific resolver).
    /// When null, the resolver loads /etc/resolv.conf at init time.
    servers: ?[]const std.net.Address = null,
    /// SO_BINDTODEVICE (Linux) for the DNS UDP sockets. Plumbed
    /// through from `network.bind_device` in `varuna.toml`. Closes
    /// the bind_device DNS leak documented in
    /// `docs/custom-dns-design-round2.md` §1.
    bind_device: ?[]const u8 = null,
};

/// Outcome handed to the caller's callback after a `resolveAsync`.
pub const ResolveResult = union(enum) {
    resolved: std.net.Address,
    nx_domain,
    failed: anyerror,
};

pub fn DnsResolverOf(comptime IO: type) type {
    return struct {
        const Self = @This();
        const Query = query_mod.QueryOf(IO);

        allocator: std.mem.Allocator,
        io: *IO,
        config: Config,
        servers_storage: [resolv_conf.max_nameservers]std.net.Address = undefined,
        servers_len: u8 = 0,
        cache: cache_mod.Cache,

        // ── Lifecycle ───────────────────────────────────────────

        pub fn init(allocator: std.mem.Allocator, io: *IO, config: Config) !Self {
            var self: Self = .{
                .allocator = allocator,
                .io = io,
                .config = config,
                .cache = cache_mod.Cache.init(config.cache_capacity),
            };

            if (config.servers) |srvs| {
                if (srvs.len == 0) return error.NoNameservers;
                const n = @min(srvs.len, self.servers_storage.len);
                @memcpy(self.servers_storage[0..n], srvs[0..n]);
                self.servers_len = @intCast(n);
            } else {
                const rc = resolv_conf.loadFromFile("/etc/resolv.conf");
                self.servers_len = rc.servers_len;
                @memcpy(self.servers_storage[0..rc.servers_len], rc.slice());
            }
            if (self.servers_len == 0) return error.NoNameservers;

            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.cache.deinit(allocator);
        }

        pub fn servers(self: *const Self) []const std.net.Address {
            return self.servers_storage[0..self.servers_len];
        }

        // ── Sync helpers ────────────────────────────────────────

        /// Fast-path for numeric IPs. Returns null if `host` is not a
        /// numeric address; caller should then issue a full resolve.
        pub fn parseNumericIp(host: []const u8, port: u16) ?std.net.Address {
            if (std.net.Address.parseIp4(host, port)) |a| return a else |_| {}
            if (std.net.Address.parseIp6(host, port)) |a| return a else |_| {}
            return null;
        }

        /// Cache lookup helper — returns null on cold miss or expired.
        pub fn cacheLookup(self: *Self, host: []const u8, port: u16) ?ResolveResult {
            const now = std.time.timestamp();
            const entry = self.cache.get(host, now) orelse return null;
            return switch (entry) {
                .positive => |p| blk: {
                    var addr = p.address;
                    addr.setPort(port);
                    break :blk ResolveResult{ .resolved = addr };
                },
                .negative => |n| switch (n.reason) {
                    .nx_domain => ResolveResult{ .nx_domain = {} },
                    .server_failure, .no_answer => ResolveResult{
                        .failed = error.DnsResolutionFailed,
                    },
                },
            };
        }

        // ── Cache mutators ──────────────────────────────────────

        pub fn invalidate(self: *Self, allocator: std.mem.Allocator, host: []const u8) void {
            self.cache.invalidate(allocator, host);
        }

        pub fn clearAll(self: *Self, allocator: std.mem.Allocator) void {
            self.cache.clearAll(allocator);
        }

        pub fn cacheResult(
            self: *Self,
            allocator: std.mem.Allocator,
            host: []const u8,
            address: std.net.Address,
        ) void {
            const now = std.time.timestamp();
            // No authoritative TTL available here; use cap as fixed
            // lifetime (matches threadpool backend's fallback shape).
            self.cache.putPositive(
                allocator,
                host,
                address,
                self.config.ttl_bounds.cap_s,
                self.config.ttl_bounds,
                now,
            ) catch {};
        }

        /// Accept a positive answer with its authoritative TTL into
        /// the cache. Used by Query when an A / AAAA response lands.
        pub fn cacheAuthoritative(
            self: *Self,
            allocator: std.mem.Allocator,
            host: []const u8,
            address: std.net.Address,
            answer_ttl_s: u32,
        ) void {
            const now = std.time.timestamp();
            self.cache.putPositive(
                allocator,
                host,
                address,
                answer_ttl_s,
                self.config.ttl_bounds,
                now,
            ) catch {};
        }

        pub fn cacheNxdomain(self: *Self, allocator: std.mem.Allocator, host: []const u8) void {
            const now = std.time.timestamp();
            self.cache.putNegative(
                allocator,
                host,
                .nx_domain,
                self.config.ttl_bounds,
                now,
            ) catch {};
        }
    };
}

// ── Tests ────────────────────────────────────────────────

const testing = std.testing;

test "Config has expected defaults" {
    const c: Config = .{};
    try testing.expectEqual(cache_mod.Cache.default_capacity, c.cache_capacity);
    try testing.expect(c.servers == null);
    try testing.expect(c.bind_device == null);
}

test "ResolveResult union variants compile" {
    const r1 = ResolveResult{ .nx_domain = {} };
    _ = r1;
    const r2 = ResolveResult{ .failed = error.DnsTimeout };
    _ = r2;
    const r3 = ResolveResult{ .resolved = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80) };
    _ = r3;
}

// We compile-check a concrete instantiation against a stub IO — the
// full SimIO smoke test (Phase F follow-up) drives the actual UDP
// flow.
test "DnsResolverOf instantiates against a stub IO" {
    const StubIO = struct {};
    const ResolverT = DnsResolverOf(StubIO);
    // Use the resolver type to ensure its declarations type-check.
    _ = @typeInfo(ResolverT);
    try testing.expect(@hasDecl(ResolverT, "init"));
    try testing.expect(@hasDecl(ResolverT, "deinit"));
    try testing.expect(@hasDecl(ResolverT, "cacheLookup"));
}

test "parseNumericIp parses ipv4 and ipv6" {
    const StubIO = struct {};
    const R = DnsResolverOf(StubIO);
    try testing.expect(R.parseNumericIp("1.2.3.4", 80) != null);
    try testing.expect(R.parseNumericIp("::1", 80) != null);
    try testing.expect(R.parseNumericIp("not-an-ip", 80) == null);
    try testing.expect(R.parseNumericIp("example.com", 80) == null);
}

test "DnsResolverOf.init with explicit servers (no IO calls)" {
    const StubIO = struct {};
    var stub_io: StubIO = .{};
    const R = DnsResolverOf(StubIO);
    const srvs = [_]std.net.Address{
        std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53),
        std.net.Address.initIp4(.{ 1, 1, 1, 1 }, 53),
    };
    var r = try R.init(testing.allocator, &stub_io, .{ .servers = &srvs });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.servers().len);
}

test "DnsResolverOf.init rejects empty server list" {
    const StubIO = struct {};
    var stub_io: StubIO = .{};
    const R = DnsResolverOf(StubIO);
    const srvs: [0]std.net.Address = .{};
    try testing.expectError(error.NoNameservers, R.init(testing.allocator, &stub_io, .{ .servers = &srvs }));
}

test "DnsResolverOf cache helpers store and retrieve" {
    const StubIO = struct {};
    var stub_io: StubIO = .{};
    const R = DnsResolverOf(StubIO);
    const srvs = [_]std.net.Address{std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53)};
    var r = try R.init(testing.allocator, &stub_io, .{ .servers = &srvs });
    defer r.deinit(testing.allocator);

    const addr = std.net.Address.initIp4(.{ 9, 9, 9, 9 }, 0);
    r.cacheAuthoritative(testing.allocator, "x.test", addr, 600);
    const got = r.cacheLookup("x.test", 8080) orelse return error.UnexpectedNullCacheLookup;
    switch (got) {
        .resolved => |a| try testing.expectEqual(@as(u16, 8080), a.getPort()),
        else => return error.UnexpectedNonResolved,
    }
}

test "DnsResolverOf cacheNxdomain reports nx_domain" {
    const StubIO = struct {};
    var stub_io: StubIO = .{};
    const R = DnsResolverOf(StubIO);
    const srvs = [_]std.net.Address{std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53)};
    var r = try R.init(testing.allocator, &stub_io, .{ .servers = &srvs });
    defer r.deinit(testing.allocator);

    r.cacheNxdomain(testing.allocator, "nx.test");
    const got = r.cacheLookup("nx.test", 80) orelse return error.UnexpectedNullCacheLookup;
    switch (got) {
        .nx_domain => {},
        else => return error.UnexpectedNonNxdomain,
    }
}

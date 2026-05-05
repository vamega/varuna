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
//! The full daemon integration (`HttpExecutor` / `UdpTrackerExecutor`
//! using this callback API under `-Ddns=custom`) is a follow-up. See
//! module top docstring of `query.zig` for TCP-fallback-on-truncation
//! and other deferred items.

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
    /// `docs/custom-dns-design-round2.md` §1 for direct callers of
    /// this resolver. The daemon leak closes when tracker/web-seed
    /// executors are wired to this API.
    bind_device: ?[]const u8 = null,
    /// Deterministic transaction id override for tests. Production
    /// callers leave this null so every DNS query gets a fresh random
    /// txid.
    test_txid_override: ?u16 = null,
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
        const max_host_len = 253;

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

        // ── Async resolution ────────────────────────────────────

        pub const AsyncResult = union(enum) {
            resolved: std.net.Address,
            nx_domain,
            failed: anyerror,
            pending: *ResolveJob,
        };

        pub const ResolveJob = struct {
            allocator: std.mem.Allocator,
            resolver: *Self,
            query: ?*Query = null,
            retired_queries: [message.max_cname_hops + 4]?*Query =
                @as([(message.max_cname_hops + 4)]?*Query, @splat(null)),
            retired_queries_len: u8 = 0,
            callback: *const fn (?*anyopaque, *@This(), ResolveResult) void,
            caller_ctx: ?*anyopaque,
            host_buf: [max_host_len]u8 = undefined,
            host_len: u8 = 0,
            port: u16 = 0,
            qtype: message.RrType = .a,
            cname_hops: u8 = 0,
            completed: bool = false,

            pub fn destroy(self: *ResolveJob) void {
                if (self.query) |q| {
                    q.destroy();
                    self.query = null;
                }
                for (self.retired_queries[0..self.retired_queries_len]) |maybe_q| {
                    if (maybe_q) |q| q.destroy();
                }
                self.retired_queries_len = 0;
                self.allocator.destroy(self);
            }

            fn hostSlice(self: *const ResolveJob) []const u8 {
                return self.host_buf[0..self.host_len];
            }

            fn start(self: *ResolveJob, qtype: message.RrType) !void {
                self.qtype = qtype;
                const q = try Query.create(self.allocator, self.resolver.io);
                self.query = q;
                errdefer {
                    q.destroy();
                    self.query = null;
                }

                try q.start(.{
                    .host = self.hostSlice(),
                    .qtype = qtype,
                    .servers = self.resolver.servers(),
                    .per_server_timeout_ns = self.resolver.config.per_server_timeout_ns,
                    .total_timeout_ns = self.resolver.config.total_timeout_ns,
                    .bind_device = self.resolver.config.bind_device,
                    .txid = self.resolver.nextTxid(),
                }, self, onQueryComplete);
            }

            fn restartWithHost(self: *ResolveJob, host: []const u8, qtype: message.RrType) !void {
                if (host.len > self.host_buf.len) return error.HostNameTooLong;
                @memcpy(self.host_buf[0..host.len], host);
                self.host_len = @intCast(host.len);
                try self.start(qtype);
            }

            fn onQueryComplete(
                ud: ?*anyopaque,
                query: *Query,
                result: query_mod.QueryResult,
            ) void {
                const self: *ResolveJob = @ptrCast(@alignCast(ud.?));
                if (self.query == query) {
                    self.query = null;
                }
                self.retireQuery(query);

                switch (result) {
                    .answers => |answers| {
                        self.handleAnswers(answers);
                    },
                    .nx_domain => {
                        self.resolver.cacheNxdomain(self.allocator, self.hostSlice());
                        self.deliver(.{ .nx_domain = {} });
                    },
                    .failed => |err| {
                        if (self.qtype == .a) {
                            self.start(.aaaa) catch |start_err| {
                                self.deliver(.{ .failed = start_err });
                            };
                        } else {
                            self.deliver(.{ .failed = err });
                        }
                    },
                    .cname => |target| {
                        if (self.cname_hops >= message.max_cname_hops) {
                            self.deliver(.{ .failed = error.CnameTooDeep });
                            return;
                        }
                        self.cname_hops += 1;
                        self.restartWithHost(target.slice(), self.qtype) catch |err| {
                            self.deliver(.{ .failed = err });
                        };
                    },
                }
            }

            fn handleAnswers(self: *ResolveJob, answers: query_mod.Answers) void {
                if (answers.list.len == 0) {
                    self.deliver(.{ .failed = error.DnsNoAnswer });
                    return;
                }

                const first = answers.list[0];
                var addr = switch (first.family) {
                    .v4 => std.net.Address.initIp4(first.bytes[0..4].*, self.port),
                    .v6 => std.net.Address.initIp6(first.bytes[0..16].*, self.port, 0, 0),
                };
                addr.setPort(self.port);

                self.resolver.cacheAuthoritative(
                    self.allocator,
                    self.hostSlice(),
                    addr,
                    answers.min_ttl_s,
                );
                self.deliver(.{ .resolved = addr });
            }

            fn deliver(self: *ResolveJob, result: ResolveResult) void {
                if (self.completed) return;
                self.completed = true;
                self.callback(self.caller_ctx, self, result);
            }

            fn retireQuery(self: *ResolveJob, query: *Query) void {
                if (self.retired_queries_len < self.retired_queries.len) {
                    self.retired_queries[self.retired_queries_len] = query;
                    self.retired_queries_len += 1;
                } else {
                    // Should be unreachable with max_cname_hops plus A/AAAA
                    // fallback, but leaking is safer than freeing while cancel
                    // completions may still reference the query's fields.
                    std.log.scoped(.dns_custom).warn(
                        "dns: ResolveJob retired query storage exhausted; leaking completed query",
                        .{},
                    );
                }
            }
        };

        pub const ResolveCallback = *const fn (
            ?*anyopaque,
            *ResolveJob,
            ResolveResult,
        ) void;

        /// Start a custom DNS lookup through the IO contract. Numeric
        /// addresses and fresh cache hits return immediately; hostname
        /// misses return a pending job whose callback fires on the IO
        /// backend's completion path. Callers destroy the returned job
        /// after its callback has fired.
        pub fn resolveAsync(
            self: *Self,
            host: []const u8,
            port: u16,
            caller_ctx: ?*anyopaque,
            callback: ResolveCallback,
        ) !AsyncResult {
            if (parseNumericIp(host, port)) |addr| return .{ .resolved = addr };
            if (self.cacheLookup(host, port)) |cached| return switch (cached) {
                .resolved => |addr| AsyncResult{ .resolved = addr },
                .nx_domain => AsyncResult{ .nx_domain = {} },
                .failed => |err| AsyncResult{ .failed = err },
            };
            if (host.len == 0 or host.len > max_host_len) return error.HostNameTooLong;

            const job = try self.allocator.create(ResolveJob);
            errdefer self.allocator.destroy(job);
            job.* = .{
                .allocator = self.allocator,
                .resolver = self,
                .callback = callback,
                .caller_ctx = caller_ctx,
                .port = port,
            };
            @memcpy(job.host_buf[0..host.len], host);
            job.host_len = @intCast(host.len);

            try job.start(.a);
            return .{ .pending = job };
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

        fn nextTxid(self: *Self) u16 {
            return self.config.test_txid_override orelse std.crypto.random.int(u16);
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
    try testing.expect(c.test_txid_override == null);
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

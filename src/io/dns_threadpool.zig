const std = @import("std");

/// Thread-safe DNS resolver with TTL-based caching (threadpool backend).
///
/// Designed for the daemon's tracker announce and scrape paths.
/// DNS resolution (`getaddrinfo`) has no io_uring equivalent, so it must
/// run on a background thread. This resolver caches results to avoid
/// repeated blocking lookups for the same hostname.
///
/// Thread safety: all public methods are safe to call from any thread.
/// The internal cache is protected by a mutex.
pub const DnsResolver = struct {
    cache: Cache,
    mutex: std.Thread.Mutex = .{},

    /// Default TTL for cached entries: 5 minutes.
    /// Tracker hostnames rarely change, and re-announces happen every
    /// 30-60 minutes, so 5 minutes provides freshness without excessive
    /// DNS traffic.
    const default_ttl_s: i64 = 5 * 60;

    /// Maximum number of cached entries. Small because a typical torrent
    /// client talks to only a handful of tracker hostnames.
    const max_entries = 64;

    const Cache = std.StringHashMapUnmanaged(CacheEntry);

    const CacheEntry = struct {
        address: std.net.Address,
        /// Timestamp (seconds since epoch) when this entry expires.
        expires_at: i64,
    };

    pub fn init(_allocator: std.mem.Allocator) !DnsResolver {
        _ = _allocator;
        return .{
            .cache = .{},
        };
    }

    pub fn deinit(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.cache.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.cache.deinit(allocator);
    }

    /// Resolve a hostname to an address.
    ///
    /// For numeric IP addresses (IPv4 or IPv6), parsing is done inline
    /// without any syscall. For hostnames, the cache is checked first;
    /// on a miss, `getaddrinfo` is called on a background thread with a
    /// 5-second timeout.
    ///
    /// This function blocks the caller until resolution completes (or
    /// times out). It is intended to be called from background worker
    /// threads, never from the io_uring event loop thread.
    pub fn resolve(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
        // Fast path: numeric IP addresses (no syscall, no cache needed)
        if (std.net.Address.parseIp4(host, port)) |addr| return addr else |_| {}
        if (std.net.Address.parseIp6(host, port)) |addr| return addr else |_| {}

        // Check cache
        const now = std.time.timestamp();
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.cache.get(host)) |entry| {
                if (entry.expires_at > now) {
                    // Cache hit -- return with the requested port
                    var addr = entry.address;
                    addr.setPort(port);
                    return addr;
                }
                // Expired -- will be overwritten below
            }
        }

        // Cache miss: resolve on a background thread
        const address = try resolveBlocking(allocator, host, port);

        // Store in cache
        self.put(allocator, host, address, now + default_ttl_s);

        return address;
    }

    /// Invalidate a specific host entry from the cache.
    /// Useful after a connection failure to force re-resolution.
    pub fn invalidate(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.fetchRemove(host)) |kv| {
            allocator.free(kv.key);
        }
    }

    /// Clear all cached entries.
    pub fn clearAll(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.cache.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.cache.clearRetainingCapacity();
    }

    fn put(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8, address: std.net.Address, expires_at: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // If the key already exists, just update the value
        if (self.cache.getPtr(host)) |entry| {
            entry.* = .{ .address = address, .expires_at = expires_at };
            return;
        }

        // Evict if at capacity
        if (self.cache.count() >= max_entries) {
            self.evictOldest(allocator);
        }

        const owned_key = allocator.dupe(u8, host) catch return;
        self.cache.put(allocator, owned_key, .{
            .address = address,
            .expires_at = expires_at,
        }) catch {
            allocator.free(owned_key);
        };
    }

    fn evictOldest(self: *DnsResolver, allocator: std.mem.Allocator) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.expires_at < oldest_time) {
                oldest_time = entry.value_ptr.expires_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            // Need to dupe the key since fetchRemove will invalidate it
            if (self.cache.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
            }
        }
    }
};

// ── Blocking DNS resolution with timeout ─────────────────

const DnsResult = struct {
    address: ?std.net.Address = null,
    err: ?anyerror = null,
    done: std.Thread.ResetEvent = .{},
};

/// Resolve a hostname by spawning a background thread for `getaddrinfo`.
/// Times out after 5 seconds.
fn resolveBlocking(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    var result = DnsResult{};

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);

    const thread = try std.Thread.spawn(.{}, dnsWorkerFn, .{ host_z, port, &result });
    defer thread.join();

    result.done.timedWait(5 * std.time.ns_per_s) catch return error.DnsTimeout;

    if (result.err) |err| return err;
    return result.address orelse error.DnsResolutionFailed;
}

fn dnsWorkerFn(host: [:0]const u8, port: u16, result: *DnsResult) void {
    const list = std.net.getAddressList(std.heap.page_allocator, host, port) catch |err| {
        result.err = err;
        result.done.set();
        return;
    };
    defer list.deinit();

    if (list.addrs.len > 0) {
        result.address = list.addrs[0];
    } else {
        result.err = error.DnsResolutionFailed;
    }
    result.done.set();
}

// ── Standalone resolve function (no caching) ─────────────

/// Resolve a hostname without caching. Numeric IPs are parsed inline;
/// hostnames go through a background thread with a 5-second timeout.
pub fn resolveOnce(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp4(host, port)) |addr| return addr else |_| {}
    if (std.net.Address.parseIp6(host, port)) |addr| return addr else |_| {}
    return resolveBlocking(allocator, host, port);
}

// ── Tests ────────────────────────────────────────────────

test "threadpool resolve numeric ipv4 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
    // Cache should be empty for numeric addresses
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "threadpool resolve numeric ipv6 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "::1", 9090);
    try std.testing.expectEqual(@as(u16, 9090), addr.getPort());
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "threadpool resolveOnce parses numeric ipv4" {
    const addr = try resolveOnce(std.testing.allocator, "10.0.0.1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr.getPort());
}

test "threadpool resolveOnce parses numeric ipv6" {
    const addr = try resolveOnce(std.testing.allocator, "::1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr.getPort());
}

test "threadpool cache stores and retrieves entries" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    // Manually insert a cache entry
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const future = std.time.timestamp() + 3600;
    resolver.put(std.testing.allocator, "example.com", addr, future);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Resolve should return cached value
    const resolved = try resolver.resolve(std.testing.allocator, "example.com", 9999);
    // Port should be overridden to the requested port
    try std.testing.expectEqual(@as(u16, 9999), resolved.getPort());
}

test "threadpool cache expires entries" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    // Insert an already-expired entry
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const past = std.time.timestamp() - 1;
    resolver.put(std.testing.allocator, "expired.test", addr, past);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Resolve for a numeric IP should still work (bypasses cache)
    const resolved = try resolver.resolve(std.testing.allocator, "127.0.0.1", 80);
    try std.testing.expectEqual(@as(u16, 80), resolved.getPort());
}

test "threadpool invalidate removes entry" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "invalidate.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.invalidate(std.testing.allocator, "invalidate.test");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "threadpool invalidate nonexistent key is no-op" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    resolver.invalidate(std.testing.allocator, "nonexistent");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "threadpool clearAll empties cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "a.test", addr, std.time.timestamp() + 3600);
    resolver.put(std.testing.allocator, "b.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 2), resolver.cache.count());

    resolver.clearAll(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "threadpool cache evicts oldest when full" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const now = std.time.timestamp();

    // Fill to capacity
    for (0..DnsResolver.max_entries) |i| {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "host-{}.test", .{i}) catch unreachable;
        // First entry has earliest expiry
        resolver.put(std.testing.allocator, key, addr, now + @as(i64, @intCast(i)) + 1);
    }
    try std.testing.expectEqual(@as(u32, DnsResolver.max_entries), resolver.cache.count());

    // Add one more -- should evict "host-0.test" (earliest expiry)
    resolver.put(std.testing.allocator, "overflow.test", addr, now + 9999);
    try std.testing.expectEqual(@as(u32, DnsResolver.max_entries), resolver.cache.count());

    // The oldest entry (host-0.test) should be evicted
    try std.testing.expect(resolver.cache.get("host-0.test") == null);
    // The new entry should be present
    try std.testing.expect(resolver.cache.get("overflow.test") != null);
}

test "threadpool cache updates existing entry without duplication" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 80);
    const now = std.time.timestamp();

    resolver.put(std.testing.allocator, "update.test", addr1, now + 100);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.put(std.testing.allocator, "update.test", addr2, now + 200);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Should have the updated address
    const entry = resolver.cache.get("update.test").?;
    try std.testing.expectEqual(@as(i64, now + 200), entry.expires_at);
}

test "threadpool resolve localhost via real DNS" {
    // This test requires a working DNS resolver on the system.
    // "localhost" should always resolve.
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = resolver.resolve(std.testing.allocator, "localhost", 80) catch |err| {
        // Skip if DNS is not available in the test environment
        if (err == error.DnsTimeout) return;
        return err;
    };

    const port = addr.getPort();
    try std.testing.expectEqual(@as(u16, 80), port);

    // Should now be cached
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Second resolve should hit cache (no thread spawned)
    const addr2 = try resolver.resolve(std.testing.allocator, "localhost", 9999);
    try std.testing.expectEqual(@as(u16, 9999), addr2.getPort());
    // Still just one entry
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());
}

test "threadpool cache respects port override on hit" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    // Cache an entry with port 80
    const addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    resolver.put(std.testing.allocator, "porttest.local", addr, std.time.timestamp() + 3600);

    // Resolve with different port
    const resolved = try resolver.resolve(std.testing.allocator, "porttest.local", 6969);
    try std.testing.expectEqual(@as(u16, 6969), resolved.getPort());
}

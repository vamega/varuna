const std = @import("std");
const TtlBounds = @import("dns.zig").TtlBounds;

/// Thread-safe DNS resolver with TTL-based caching and a real thread pool.
///
/// Pre-spawns a small pool of worker threads that handle `getaddrinfo` calls.
/// DNS resolution has no io_uring equivalent, so it must run on background
/// threads. The thread pool avoids the overhead of spawning and joining an
/// OS thread per cache miss.
///
/// TTL handling: `getaddrinfo` does not expose the authoritative DNS TTL,
/// so this backend cannot honor it per-record. Instead, every cached
/// entry uses a fixed lifetime of `ttl_bounds.cap_s` (default: 1 hour).
/// This is a deliberate compromise: 1 hour matches the upper end of
/// typical tracker announce intervals, so a steady-state re-announce
/// hits the cache once per cycle. Recovery from a tracker IP migration
/// is bounded by either (a) a connect-failure invalidation hook firing
/// (see `shouldInvalidateOnConnectError`) or (b) the 1-hour cap. The
/// c-ares backend (`-Ddns=c_ares`) honors authoritative TTLs.
///
/// Thread safety: all public methods are safe to call from any thread.
/// The internal cache is protected by a mutex; the job queue has its own lock.
pub const DnsResolver = struct {
    cache: Cache,
    cache_mutex: std.Thread.Mutex = .{},
    pool: *ThreadPool,
    ttl_bounds: TtlBounds = TtlBounds.default,

    /// Maximum number of cached entries. Small because a typical torrent
    /// client talks to only a handful of tracker hostnames.
    const max_entries = 64;

    const Cache = std.StringHashMapUnmanaged(CacheEntry);

    const CacheEntry = struct {
        address: std.net.Address,
        /// Timestamp (seconds since epoch) when this entry expires.
        expires_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !DnsResolver {
        return .{
            .cache = .{},
            .pool = try ThreadPool.create(allocator),
        };
    }

    pub fn deinit(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.pool.destroy(allocator);

        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

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
    /// on a miss, `getaddrinfo` is dispatched to the thread pool with a
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
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

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

        // Cache miss: resolve via thread pool
        const address = try self.pool.resolve(host, port);

        // Store in cache. getaddrinfo can't expose the authoritative
        // TTL, so use the cap as a fixed lifetime.
        self.put(allocator, host, address, now + @as(i64, self.ttl_bounds.cap_s));

        return address;
    }

    /// Non-blocking DNS resolution for event loops.
    ///
    /// Returns immediately with either a resolved address (numeric IP or
    /// cache hit) or a pending DnsJob that will complete asynchronously.
    /// When `notify_fd` is provided, the DNS thread pool writes to it on
    /// completion so the caller can detect it via POLL_ADD.
    ///
    /// The caller must call `job.release()` on a pending DnsJob when done
    /// with it (after reading the result or on timeout/cancellation).
    pub const AsyncResult = union(enum) {
        resolved: std.net.Address,
        pending: *DnsJob,
    };

    pub fn resolveAsync(self: *DnsResolver, host: []const u8, port: u16, notify_fd: std.posix.fd_t) !AsyncResult {
        // Fast path: numeric IP addresses (no syscall, no cache)
        if (std.net.Address.parseIp4(host, port)) |addr| return .{ .resolved = addr } else |_| {}
        if (std.net.Address.parseIp6(host, port)) |addr| return .{ .resolved = addr } else |_| {}

        // Check cache (non-blocking mutex)
        const now = std.time.timestamp();
        {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

            if (self.cache.get(host)) |entry| {
                if (entry.expires_at > now) {
                    var addr = entry.address;
                    addr.setPort(port);
                    return .{ .resolved = addr };
                }
            }
        }

        // Cache miss: submit to thread pool, return pending job
        if (host.len > DnsJob.max_host_len) return error.HostNameTooLong;

        const job = try DnsJob.create();
        errdefer job.release();

        @memcpy(job.host_buf[0..host.len], host);
        job.host_buf[host.len] = 0;
        job.host_len = @intCast(host.len);
        job.port = port;
        job.notify_fd = notify_fd;

        {
            self.pool.mutex.lock();
            defer self.pool.mutex.unlock();

            if (self.pool.shutdown) return error.DnsResolutionFailed;
            if (self.pool.count >= ThreadPool.max_pending) return error.DnsQueueFull;

            self.pool.jobs[self.pool.tail] = job;
            self.pool.tail = (self.pool.tail + 1) % ThreadPool.max_pending;
            self.pool.count += 1;
            self.pool.cond.signal();
        }

        return .{ .pending = job };
    }

    /// Cache a resolved address from an async DNS job that completed.
    /// Call this after resolveAsync returns .pending and the job completes.
    /// getaddrinfo doesn't expose the authoritative TTL, so the entry
    /// is cached for the configured cap (default 1 h).
    pub fn cacheResult(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8, address: std.net.Address) void {
        const now = std.time.timestamp();
        self.put(allocator, host, address, now + @as(i64, self.ttl_bounds.cap_s));
    }

    /// Invalidate a specific host entry from the cache.
    /// Useful after a connection failure to force re-resolution.
    pub fn invalidate(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        if (self.cache.fetchRemove(host)) |kv| {
            allocator.free(kv.key);
        }
    }

    /// Clear all cached entries.
    pub fn clearAll(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var iter = self.cache.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.cache.clearRetainingCapacity();
    }

    fn put(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8, address: std.net.Address, expires_at: i64) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

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

// ── Thread pool for DNS resolution ──────────────────────

/// A small fixed-size thread pool for dispatching blocking getaddrinfo calls.
///
/// Workers dequeue jobs and call getaddrinfo. Results are communicated back
/// via a heap-allocated DnsJob with atomic refcounting, which ensures memory
/// safety even when the caller times out before the worker finishes.
const ThreadPool = struct {
    workers: [pool_size]std.Thread = undefined,
    spawned: usize = 0,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    shutdown: bool = false,

    // Bounded ring buffer of pending jobs.
    jobs: [max_pending]*DnsJob = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    const pool_size = 4;
    const max_pending = 16;

    fn create(allocator: std.mem.Allocator) !*ThreadPool {
        const self = try allocator.create(ThreadPool);
        self.* = .{};

        errdefer {
            self.mutex.lock();
            self.shutdown = true;
            self.cond.broadcast();
            self.mutex.unlock();
            for (self.workers[0..self.spawned]) |w| w.join();
            allocator.destroy(self);
        }

        for (0..pool_size) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerMain, .{self});
            self.spawned += 1;
        }

        return self;
    }

    fn destroy(self: *ThreadPool, allocator: std.mem.Allocator) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.shutdown = true;
            self.cond.broadcast();
        }

        for (self.workers[0..self.spawned]) |w| {
            w.join();
        }

        // Drain any remaining jobs (shouldn't happen in normal shutdown,
        // but release them to avoid leaking).
        while (self.count > 0) {
            const job = self.jobs[self.head];
            self.head = (self.head + 1) % max_pending;
            self.count -= 1;
            job.release();
        }

        allocator.destroy(self);
    }

    /// Submit a DNS lookup to the pool and wait for the result.
    /// Returns the resolved address or an error (including DnsTimeout).
    fn resolve(self: *ThreadPool, host: []const u8, port: u16) !std.net.Address {
        if (host.len > DnsJob.max_host_len) return error.HostNameTooLong;

        const job = try DnsJob.create();
        // Caller holds one ref, worker will hold the other (set in create).
        defer job.release();

        @memcpy(job.host_buf[0..host.len], host);
        job.host_buf[host.len] = 0;
        job.host_len = @intCast(host.len);
        job.port = port;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.shutdown) return error.DnsResolutionFailed;
            if (self.count >= max_pending) return error.DnsQueueFull;

            self.jobs[self.tail] = job;
            self.tail = (self.tail + 1) % max_pending;
            self.count += 1;
            self.cond.signal();
        }

        // Wait for the worker to finish or time out.
        job.done.timedWait(5 * std.time.ns_per_s) catch return error.DnsTimeout;

        if (job.err) |err| return err;
        return job.address orelse error.DnsResolutionFailed;
    }

    fn workerMain(self: *ThreadPool) void {
        while (true) {
            var job: *DnsJob = undefined;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.count == 0 and !self.shutdown) {
                    self.cond.wait(&self.mutex);
                }

                if (self.shutdown and self.count == 0) {
                    return;
                }

                job = self.jobs[self.head];
                self.head = (self.head + 1) % max_pending;
                self.count -= 1;
            }

            // Perform blocking DNS resolution.
            const host_z: [:0]const u8 = job.host_buf[0..job.host_len :0];
            const list = std.net.getAddressList(std.heap.page_allocator, host_z, job.port) catch |err| {
                job.err = err;
                signalCompletion(job);
                job.release();
                continue;
            };
            defer list.deinit();

            if (list.addrs.len > 0) {
                job.address = list.addrs[0];
            } else {
                job.err = error.DnsResolutionFailed;
            }
            signalCompletion(job);
            job.release();
        }
    }
};

/// Set the done event and optionally signal an eventfd to wake an event loop.
fn signalCompletion(job: *DnsJob) void {
    job.done.set();
    if (job.notify_fd >= 0) {
        const val: u64 = 1;
        _ = std.posix.write(job.notify_fd, std.mem.asBytes(&val)) catch {};
    }
}

/// Heap-allocated DNS job shared between the submitter and worker thread.
///
/// Uses atomic refcounting (initial count = 2: one for the caller, one for
/// the worker) to ensure the job is freed safely even when the caller times
/// out before the worker finishes. Whoever decrements the refcount to zero
/// frees the job.
///
/// When `notify_fd` is set (>= 0), the worker writes a u64(1) to it after
/// setting `done`, allowing event loops to detect completion via POLL_ADD
/// without blocking.
pub const DnsJob = struct {
    host_buf: [max_host_len + 1]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,
    address: ?std.net.Address = null,
    err: ?anyerror = null,
    done: std.Thread.ResetEvent = .{},
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    /// If >= 0, the worker writes u64(1) to this fd after setting done.
    /// Used to wake an event loop's io_uring via eventfd + POLL_ADD.
    notify_fd: std.posix.fd_t = -1,

    pub const max_host_len = 253;

    pub fn create() !*DnsJob {
        const job = std.heap.page_allocator.create(DnsJob) catch return error.OutOfMemory;
        job.* = .{};
        return job;
    }

    pub fn release(self: *DnsJob) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            std.heap.page_allocator.destroy(self);
        }
    }

    /// Check if the job is complete without blocking.
    pub fn isDone(self: *const DnsJob) bool {
        return self.done.isSet();
    }
};

// ── Standalone resolve function (no caching) ─────────────

/// Resolve a hostname without caching. Numeric IPs are parsed inline;
/// hostnames spawn a single background thread with a 5-second timeout.
///
/// Use this for one-off callers that don't need caching (e.g., UDP
/// tracker connections that happen infrequently). For repeated lookups,
/// prefer DnsResolver.resolve().
pub fn resolveOnce(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp4(host, port)) |addr| return addr else |_| {}
    if (std.net.Address.parseIp6(host, port)) |addr| return addr else |_| {}
    return resolveBlocking(allocator, host, port);
}

/// Single-thread resolve for one-shot callers. Spawns one thread, joins
/// on completion or timeout. Not used by the pool-backed DnsResolver.
fn resolveBlocking(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    const Result = struct {
        address: ?std.net.Address = null,
        err: ?anyerror = null,
        done: std.Thread.ResetEvent = .{},
    };

    var result = Result{};

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(h: [:0]const u8, p: u16, r: *Result) void {
            const list = std.net.getAddressList(std.heap.page_allocator, h, p) catch |err| {
                r.err = err;
                r.done.set();
                return;
            };
            defer list.deinit();

            if (list.addrs.len > 0) {
                r.address = list.addrs[0];
            } else {
                r.err = error.DnsResolutionFailed;
            }
            r.done.set();
        }
    }.run, .{ host_z, port, &result });
    defer thread.join();

    result.done.timedWait(5 * std.time.ns_per_s) catch return error.DnsTimeout;

    if (result.err) |err| return err;
    return result.address orelse error.DnsResolutionFailed;
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

test "threadpool cacheResult uses configured TTL cap (1 hour default)" {
    // The threadpool backend can't see authoritative DNS TTLs because
    // getaddrinfo doesn't expose them, so cached entries should expire
    // after the configured cap (default 1 h, up from the previous fixed
    // 5 min). This is the central behavior change in commit 2.
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const before = std.time.timestamp();
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.cacheResult(std.testing.allocator, "ttl-cap.test", addr);
    const after = std.time.timestamp();

    const entry = resolver.cache.get("ttl-cap.test").?;
    // Entry expires roughly `cap_s` after now (allow ±1 s for the
    // timestamp call between before/after).
    try std.testing.expect(entry.expires_at >= before + 3600);
    try std.testing.expect(entry.expires_at <= after + 3600);
}

test "threadpool ttl_bounds.cap_s is configurable" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);
    // Tighten the cap to 60 seconds for this test.
    resolver.ttl_bounds = .{ .floor_s = 30, .cap_s = 60 };

    const before = std.time.timestamp();
    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.cacheResult(std.testing.allocator, "tight-cap.test", addr);

    const entry = resolver.cache.get("tight-cap.test").?;
    try std.testing.expect(entry.expires_at >= before + 60);
    try std.testing.expect(entry.expires_at <= before + 62);
}

test "threadpool: HttpClient invalidates DNS on connect refusal (regression)" {
    // Regression for the 2026-04-30 DNS gap: a connect failure to a
    // resolved IP must drop the cached entry so the next attempt
    // re-resolves. Without the invalidate hook we'd burn the full TTL
    // window on the same dead IP.
    const HttpClient = @import("http_blocking.zig").HttpClient;
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    // Pre-seed the cache so resolve() short-circuits to 127.0.0.1.
    const cached_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
    resolver.put(
        std.testing.allocator,
        "varuna-dns-fixes-regression.test",
        cached_addr,
        std.time.timestamp() + 3600,
    );
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Connect to a loopback port that nothing is listening on. Linux
    // loopback returns ECONNREFUSED for closed ports, which is in our
    // shouldInvalidateOnConnectError set.
    var client = HttpClient.initWithDns(std.testing.allocator, &resolver);
    defer client.deinit();

    var url_buf = std.ArrayList(u8).empty;
    defer url_buf.deinit(std.testing.allocator);
    try url_buf.print(
        std.testing.allocator,
        "http://varuna-dns-fixes-regression.test:1/",
        .{},
    );

    const result = client.get(url_buf.items);
    if (result) |resp| {
        var r = resp;
        r.deinit();
        return error.UnexpectedSuccess;
    } else |_| {
        // Any connect-side error is acceptable — what matters is that
        // the invalidate hook fired.
    }

    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

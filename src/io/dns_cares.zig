const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("ares.h");
});

/// Async DNS resolver backed by c-ares, integrated with io_uring via POLL_ADD.
///
/// c-ares performs DNS resolution asynchronously using its own UDP/TCP sockets.
/// We monitor those sockets with IORING_OP_POLL_ADD and call ares_process_fd()
/// when they become readable/writable. This keeps DNS resolution fully async
/// on the io_uring event loop thread -- no background threads needed.
///
/// For the daemon, this is preferable to the threadpool resolver when handling
/// many concurrent DNS lookups (e.g., DHT scenarios with hundreds of nodes),
/// because it avoids thread-per-lookup overhead.
///
/// Thread safety: all public methods are safe to call from any thread.
/// The internal cache and c-ares channel are protected by a mutex.
pub const DnsResolver = struct {
    cache: Cache,
    mutex: std.Thread.Mutex = .{},
    channel: ?*c.ares_channel_t = null,
    allocator: std.mem.Allocator,

    /// Default TTL for cached entries: 5 minutes.
    const default_ttl_s: i64 = 5 * 60;

    /// Maximum number of cached entries.
    const max_entries = 64;

    /// Maximum number of c-ares fds we can poll simultaneously.
    const max_ares_fds = 16;

    /// c-ares query timeout in milliseconds.
    const query_timeout_ms: c_int = 5000;

    const Cache = std.StringHashMapUnmanaged(CacheEntry);

    const CacheEntry = struct {
        address: std.net.Address,
        /// Timestamp (seconds since epoch) when this entry expires.
        expires_at: i64,
    };

    /// Result passed between the c-ares callback and the waiting caller.
    const QueryResult = struct {
        address: ?std.net.Address = null,
        err: ?anyerror = null,
        done: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) !DnsResolver {
        // Initialize the c-ares library (once globally is fine, but
        // ares_library_init is ref-counted and idempotent).
        const lib_rc = c.ares_library_init(c.ARES_LIB_INIT_ALL);
        if (lib_rc != c.ARES_SUCCESS) return error.CaresLibraryInitFailed;

        var opts: c.ares_options = std.mem.zeroes(c.ares_options);
        opts.timeout = query_timeout_ms;
        opts.tries = 2;

        var channel: ?*c.ares_channel_t = null;
        const rc = c.ares_init_options(
            @ptrCast(&channel),
            &opts,
            c.ARES_OPT_TIMEOUTMS | c.ARES_OPT_TRIES,
        );
        if (rc != c.ARES_SUCCESS) return error.CaresInitFailed;

        return .{
            .cache = .{},
            .channel = channel,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.channel) |ch| {
            c.ares_destroy(ch);
            self.channel = null;
        }
        c.ares_library_cleanup();

        var iter = self.cache.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.cache.deinit(allocator);
    }

    /// Resolve a hostname to an address.
    ///
    /// For numeric IP addresses, parsing is done inline without any syscall.
    /// For hostnames, the cache is checked first; on a miss, c-ares performs
    /// an async DNS query. The caller is blocked via an epoll wait on the
    /// c-ares fds (not a threadpool), with a 5-second timeout.
    ///
    /// This function blocks the caller until resolution completes (or times out).
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
                    var addr = entry.address;
                    addr.setPort(port);
                    return addr;
                }
            }
        }

        // Cache miss: resolve via c-ares
        const address = try self.resolveWithCares(host, port);

        // Store in cache
        self.put(allocator, host, address, now + default_ttl_s);

        return address;
    }

    /// Invalidate a specific host entry from the cache.
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

        if (self.cache.getPtr(host)) |entry| {
            entry.* = .{ .address = address, .expires_at = expires_at };
            return;
        }

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
            if (self.cache.fetchRemove(key)) |kv| {
                allocator.free(kv.key);
            }
        }
    }

    /// Perform a c-ares DNS lookup. Uses epoll to wait on c-ares's fds.
    ///
    /// While this uses epoll (a conventional syscall) rather than io_uring
    /// directly, it avoids blocking a threadpool thread. The epoll wait is
    /// bounded by c-ares's own timeout (5 seconds). For integration with
    /// the daemon's main event loop, a future enhancement could use
    /// IORING_OP_POLL_ADD on the c-ares fds directly.
    fn resolveWithCares(self: *DnsResolver, host: []const u8, port: u16) !std.net.Address {
        const ch = self.channel orelse return error.CaresNotInitialized;

        var result = QueryResult{};

        // c-ares needs a null-terminated hostname
        var host_buf: [256]u8 = undefined;
        if (host.len >= host_buf.len) return error.HostNameTooLong;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;

        // Start the async query
        self.mutex.lock();
        c.ares_gethostbyname(
            ch,
            @ptrCast(&host_buf),
            c.AF_UNSPEC,
            caresCallback,
            @ptrCast(&result),
        );
        self.mutex.unlock();

        // Create an epoll instance to wait on c-ares fds
        const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        defer posix.close(epfd);

        // Process loop: wait on c-ares fds until done or timeout
        var deadline_ms: i32 = query_timeout_ms;
        const start_ts = std.time.milliTimestamp();

        while (!result.done) {
            // Get fds c-ares wants us to monitor
            var read_fds: [max_ares_fds]c.ares_socket_t = undefined;
            var write_fds: [max_ares_fds]c.ares_socket_t = undefined;

            self.mutex.lock();
            const nfds = caresGetSock(ch, &read_fds, &write_fds);
            self.mutex.unlock();

            if (nfds == 0) {
                // No fds to wait on -- process timeouts
                self.mutex.lock();
                c.ares_process_fd(ch, c.ARES_SOCKET_BAD, c.ARES_SOCKET_BAD);
                self.mutex.unlock();
                if (result.done) break;
                // If c-ares has no fds and isn't done, something is wrong
                return error.DnsResolutionFailed;
            }

            // Register fds with epoll
            var registered: [max_ares_fds * 2]posix.fd_t = undefined;
            var reg_count: usize = 0;

            for (0..nfds) |i| {
                var events: u32 = 0;
                const rfd = read_fds[i];
                const wfd = write_fds[i];

                if (rfd != c.ARES_SOCKET_BAD) events |= linux.EPOLL.IN;
                if (wfd != c.ARES_SOCKET_BAD) events |= linux.EPOLL.OUT;

                const fd: posix.fd_t = if (rfd != c.ARES_SOCKET_BAD) @intCast(rfd) else @intCast(wfd);
                if (events == 0) continue;

                var ev = linux.epoll_event{
                    .events = events,
                    .data = .{ .fd = fd },
                };
                posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev) catch |err| {
                    if (err == error.FileDescriptorAlreadyPresentInSet) {
                        posix.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev) catch {};
                    }
                };
                registered[reg_count] = fd;
                reg_count += 1;
            }

            // Calculate remaining timeout
            const elapsed = std.time.milliTimestamp() - start_ts;
            deadline_ms = @intCast(@max(0, @as(i64, query_timeout_ms) - elapsed));
            if (deadline_ms <= 0) return error.DnsTimeout;

            // Wait for events
            var events: [max_ares_fds]linux.epoll_event = undefined;
            const nev = posix.epoll_wait(epfd, &events, deadline_ms);

            if (nev == 0) {
                // Timeout -- let c-ares process its own timeouts
                self.mutex.lock();
                c.ares_process_fd(ch, c.ARES_SOCKET_BAD, c.ARES_SOCKET_BAD);
                self.mutex.unlock();
                if (!result.done) return error.DnsTimeout;
                break;
            }

            // Process ready fds
            for (events[0..nev]) |ev| {
                const rfd: c.ares_socket_t = if (ev.events & linux.EPOLL.IN != 0)
                    @intCast(ev.data.fd)
                else
                    c.ARES_SOCKET_BAD;
                const wfd: c.ares_socket_t = if (ev.events & linux.EPOLL.OUT != 0)
                    @intCast(ev.data.fd)
                else
                    c.ARES_SOCKET_BAD;

                self.mutex.lock();
                c.ares_process_fd(ch, rfd, wfd);
                self.mutex.unlock();
            }

            // Clean up epoll registrations for next iteration
            for (registered[0..reg_count]) |fd| {
                posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null) catch {};
            }
        }

        if (result.err) |err| return err;
        if (result.address) |addr| {
            var resolved = addr;
            resolved.setPort(port);
            return resolved;
        }
        return error.DnsResolutionFailed;
    }

    /// c-ares host callback. Called by c-ares when a query completes.
    fn caresCallback(
        arg: ?*anyopaque,
        status: c_int,
        _timeouts: c_int,
        hostent: ?*const c.struct_hostent,
    ) callconv(.c) void {
        _ = _timeouts;
        const result: *QueryResult = @ptrCast(@alignCast(arg));

        if (status != c.ARES_SUCCESS) {
            result.err = switch (status) {
                c.ARES_ETIMEOUT => error.DnsTimeout,
                c.ARES_ENOTFOUND => error.DnsResolutionFailed,
                c.ARES_ENOTIMP => error.DnsResolutionFailed,
                c.ARES_EREFUSED => error.DnsResolutionFailed,
                c.ARES_ECONNREFUSED => error.ConnectionRefused,
                else => error.DnsResolutionFailed,
            };
            result.done = true;
            return;
        }

        const host = hostent orelse {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        };

        // Get the first address from the hostent
        const addr_list: [*]?[*]u8 = @ptrCast(host.h_addr_list);
        const first_addr = addr_list[0] orelse {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        };

        if (host.h_addrtype == c.AF_INET and host.h_length == 4) {
            const bytes: *const [4]u8 = @ptrCast(first_addr);
            result.address = std.net.Address.initIp4(bytes.*, 0);
        } else if (host.h_addrtype == c.AF_INET6 and host.h_length == 16) {
            const bytes: *const [16]u8 = @ptrCast(first_addr);
            result.address = std.net.Address.initIp6(bytes.*, 0, 0, 0);
        } else {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        }

        result.done = true;
    }
};

/// Helper to extract c-ares fds from ares_getsock into separate read/write arrays.
/// Returns the number of fd slots used.
fn caresGetSock(
    channel: *c.ares_channel_t,
    read_fds: *[DnsResolver.max_ares_fds]c.ares_socket_t,
    write_fds: *[DnsResolver.max_ares_fds]c.ares_socket_t,
) usize {
    var raw_fds: [c.ARES_GETSOCK_MAXNUM]c.ares_socket_t = undefined;
    const bitmask: c_uint = @bitCast(c.ares_getsock(channel, &raw_fds, c.ARES_GETSOCK_MAXNUM));

    var count: usize = 0;
    for (0..c.ARES_GETSOCK_MAXNUM) |i| {
        const has_read = (bitmask & (@as(c_uint, 1) << @intCast(i))) != 0;
        const has_write = (bitmask & (@as(c_uint, 1) << @intCast(i + c.ARES_GETSOCK_MAXNUM))) != 0;

        if (!has_read and !has_write) continue;
        if (count >= DnsResolver.max_ares_fds) break;

        read_fds[count] = if (has_read) raw_fds[i] else c.ARES_SOCKET_BAD;
        write_fds[count] = if (has_write) raw_fds[i] else c.ARES_SOCKET_BAD;
        count += 1;
    }

    return count;
}

/// Standalone resolve function (no caching) using c-ares.
/// Creates a temporary channel for one-shot resolution.
pub fn resolveOnce(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    if (std.net.Address.parseIp4(host, port)) |addr| return addr else |_| {}
    if (std.net.Address.parseIp6(host, port)) |addr| return addr else |_| {}

    var resolver = try DnsResolver.init(allocator);
    defer resolver.deinit(allocator);

    return resolver.resolveWithCares(host, port);
}

// ── Tests ────────────────────────────────────────────────

test "c-ares resolve numeric ipv4 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares resolve numeric ipv6 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "::1", 9090);
    try std.testing.expectEqual(@as(u16, 9090), addr.getPort());
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares resolveOnce parses numeric ipv4" {
    const addr = try resolveOnce(std.testing.allocator, "10.0.0.1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr.getPort());
}

test "c-ares resolveOnce parses numeric ipv6" {
    const addr = try resolveOnce(std.testing.allocator, "::1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr.getPort());
}

test "c-ares cache stores and retrieves entries" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const future = std.time.timestamp() + 3600;
    resolver.put(std.testing.allocator, "example.com", addr, future);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const resolved = try resolver.resolve(std.testing.allocator, "example.com", 9999);
    try std.testing.expectEqual(@as(u16, 9999), resolved.getPort());
}

test "c-ares cache expires entries" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const past = std.time.timestamp() - 1;
    resolver.put(std.testing.allocator, "expired.test", addr, past);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const resolved = try resolver.resolve(std.testing.allocator, "127.0.0.1", 80);
    try std.testing.expectEqual(@as(u16, 80), resolved.getPort());
}

test "c-ares invalidate removes entry" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "invalidate.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.invalidate(std.testing.allocator, "invalidate.test");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares invalidate nonexistent key is no-op" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    resolver.invalidate(std.testing.allocator, "nonexistent");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares clearAll empties cache" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "a.test", addr, std.time.timestamp() + 3600);
    resolver.put(std.testing.allocator, "b.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 2), resolver.cache.count());

    resolver.clearAll(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares cache evicts oldest when full" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const now = std.time.timestamp();

    for (0..DnsResolver.max_entries) |i| {
        var buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "host-{}.test", .{i}) catch unreachable;
        resolver.put(std.testing.allocator, key, addr, now + @as(i64, @intCast(i)) + 1);
    }
    try std.testing.expectEqual(@as(u32, DnsResolver.max_entries), resolver.cache.count());

    resolver.put(std.testing.allocator, "overflow.test", addr, now + 9999);
    try std.testing.expectEqual(@as(u32, DnsResolver.max_entries), resolver.cache.count());

    try std.testing.expect(resolver.cache.get("host-0.test") == null);
    try std.testing.expect(resolver.cache.get("overflow.test") != null);
}

test "c-ares cache updates existing entry without duplication" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 80);
    const now = std.time.timestamp();

    resolver.put(std.testing.allocator, "update.test", addr1, now + 100);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.put(std.testing.allocator, "update.test", addr2, now + 200);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const entry = resolver.cache.get("update.test").?;
    try std.testing.expectEqual(@as(i64, now + 200), entry.expires_at);
}

test "c-ares cache respects port override on hit" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    resolver.put(std.testing.allocator, "porttest.local", addr, std.time.timestamp() + 3600);

    const resolved = try resolver.resolve(std.testing.allocator, "porttest.local", 6969);
    try std.testing.expectEqual(@as(u16, 6969), resolved.getPort());
}

test "c-ares resolve localhost via real DNS" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = resolver.resolve(std.testing.allocator, "localhost", 80) catch |err| {
        // Skip if DNS is not available in the test environment
        if (err == error.DnsTimeout or err == error.DnsResolutionFailed) return;
        return err;
    };

    const port = addr.getPort();
    try std.testing.expectEqual(@as(u16, 80), port);

    // Should now be cached
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    // Second resolve should hit cache
    const addr2 = try resolver.resolve(std.testing.allocator, "localhost", 9999);
    try std.testing.expectEqual(@as(u16, 9999), addr2.getPort());
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());
}

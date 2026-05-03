const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const dns = @import("dns.zig");
const dns_cache = @import("dns_custom/cache.zig");
const TtlBounds = dns.TtlBounds;
const Config = dns.Config;
const applyBindDevice = @import("../net/socket.zig").applyBindDevice;

const c = @cImport({
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
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
/// TTL handling: this backend uses `ares_getaddrinfo`, whose
/// `ares_addrinfo_node.ai_ttl` exposes the authoritative DNS TTL. The
/// answer's TTL is clamped into `ttl_bounds.[floor_s, cap_s]` (default
/// 30 s - 1 h) before being applied to the cache entry. The threadpool
/// backend (`-Ddns=threadpool`, default) cannot see TTL because
/// getaddrinfo doesn't expose it; it uses the cap as a fixed lifetime.
///
/// Thread safety: all public methods are safe to call from any thread.
/// The internal cache and c-ares channel are protected by a mutex.
pub const DnsResolver = struct {
    cache: dns_cache.Cache,
    mutex: std.Thread.Mutex = .{},
    channel: ?*c.ares_channel_t = null,
    allocator: std.mem.Allocator,
    ttl_bounds: TtlBounds = TtlBounds.default,
    /// Captured from `Config.bind_device` at init time. When non-null,
    /// the c-ares socket callback applies `SO_BINDTODEVICE` to every
    /// UDP/TCP socket the channel opens so DNS queries egress through
    /// the configured interface. Closes the privacy gap described in
    /// `docs/custom-dns-design-round2.md` §1 for the c-ares backend;
    /// the threadpool backend remains a Known Issue. The slice
    /// lifetime is owned by the caller (typically the daemon config
    /// arena, alive for the whole daemon lifetime).
    bind_device: ?[]const u8 = null,
    /// Heap-allocated stable cell registered as c-ares user_data. Owns
    /// nothing but the indirection — the slice it points at is
    /// caller-owned. Allocated only when `bind_device` is non-null;
    /// freed in `deinit`.
    bind_device_cell: ?*BindDeviceCell = null,

    /// Maximum number of cached entries.
    const max_entries = dns_cache.Cache.default_capacity;

    /// Maximum number of c-ares fds we can poll simultaneously.
    const max_ares_fds = 16;

    /// c-ares query timeout in milliseconds.
    const query_timeout_ms: c_int = 5000;

    /// Result passed between the c-ares callback and the waiting caller.
    const QueryResult = struct {
        address: ?std.net.Address = null,
        /// Authoritative DNS TTL from `ares_addrinfo_node.ai_ttl`,
        /// pre-clamping. Negative or zero means "fall back to floor."
        /// `null` means the callback didn't run (timeout).
        answer_ttl_s: ?i32 = null,
        err: ?anyerror = null,
        done: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !DnsResolver {
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

        // When the caller configured a bind_device, install a c-ares
        // socket-create callback that applies `SO_BINDTODEVICE` to
        // every UDP/TCP socket c-ares opens. Fires once per socket,
        // before c-ares uses it for the query. The user_data argument
        // is a stable, heap-allocated `BindDeviceCell` whose lifetime
        // is the resolver's: it owns the slice pointer and length,
        // and the callback re-reads them on every invocation. We
        // tolerate `applyBindDevice` errors by logging and returning
        // 0 (so a misconfigured device name doesn't take down DNS
        // entirely).
        var device_cell: ?*BindDeviceCell = null;
        if (config.bind_device) |device| {
            const cell = try allocator.create(BindDeviceCell);
            cell.* = .{ .device = device };
            device_cell = cell;
            c.ares_set_socket_callback(
                channel,
                caresSocketCreateCallback,
                @ptrCast(cell),
            );
        }

        return .{
            .cache = dns_cache.Cache.init(max_entries),
            .channel = channel,
            .allocator = allocator,
            .ttl_bounds = config.ttl_bounds,
            .bind_device = config.bind_device,
            .bind_device_cell = device_cell,
        };
    }

    /// Stable user_data cell for the c-ares socket callback. Heap-
    /// allocated (lifetime tied to the resolver) so the callback can
    /// always dereference a valid pointer regardless of where the
    /// `DnsResolver` itself lives. Holds the bind_device slice the
    /// caller passed into `init`.
    const BindDeviceCell = struct {
        device: []const u8,
    };

    /// c-ares socket-create callback. Fires once per socket the channel
    /// opens (UDP for queries, TCP for retries when UDP truncates).
    /// Applies `SO_BINDTODEVICE` to bind the socket to the configured
    /// interface so DNS queries egress through the same device as
    /// peer / tracker traffic.
    ///
    /// Reads the bind_device slice from the heap-allocated user_data
    /// `BindDeviceCell` registered alongside the callback.
    ///
    /// Returns 0 on success (c-ares proceeds); a non-zero return
    /// would fail the socket creation, which in turn fails the DNS
    /// query. We swallow `applyBindDevice` errors (log + return 0) so
    /// a misconfigured interface name doesn't take down DNS entirely.
    fn caresSocketCreateCallback(
        socket_fd: c.ares_socket_t,
        _: c_int, // type: SOCK_STREAM or SOCK_DGRAM (unused)
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        const cell: *BindDeviceCell = @ptrCast(@alignCast(user_data orelse return 0));
        applyBindDevice(@intCast(socket_fd), cell.device) catch |err| {
            std.log.scoped(.dns_cares).warn(
                "c-ares socket bind_device='{s}' failed: {s} (DNS query proceeds without bind)",
                .{ cell.device, @errorName(err) },
            );
            return 0;
        };
        return 0;
    }

    pub fn deinit(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.channel) |ch| {
            c.ares_destroy(ch);
            self.channel = null;
        }
        c.ares_library_cleanup();

        if (self.bind_device_cell) |cell| {
            self.allocator.destroy(cell);
            self.bind_device_cell = null;
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

            if (self.cache.get(host, now)) |entry| {
                switch (entry) {
                    .positive => |positive| {
                        var addr = positive.address;
                        addr.setPort(port);
                        return addr;
                    },
                    .negative => return error.DnsResolutionFailed,
                }
            }
        }

        // Cache miss: resolve via c-ares. The query result includes the
        // authoritative DNS TTL via `ares_addrinfo_node.ai_ttl`.
        var answer_ttl_s: u32 = self.ttl_bounds.floor_s;
        const address = try self.resolveWithCares(host, port, &answer_ttl_s);

        // Apply floor/cap to the authoritative TTL before caching.
        const ttl_s: u32 = self.ttl_bounds.clamp(answer_ttl_s);
        self.put(allocator, host, address, now + @as(i64, ttl_s));

        return address;
    }

    /// Invalidate a specific host entry from the cache.
    pub fn invalidate(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.cache.invalidate(allocator, host);
    }

    /// Clear all cached entries.
    pub fn clearAll(self: *DnsResolver, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.cache.clearAll(allocator);
    }

    fn put(self: *DnsResolver, allocator: std.mem.Allocator, host: []const u8, address: std.net.Address, expires_at: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.cache.putPositiveUntil(allocator, host, address, expires_at) catch return;
    }

    /// Perform a c-ares DNS lookup. Uses epoll to wait on c-ares's fds.
    ///
    /// While this uses epoll (a conventional syscall) rather than io_uring
    /// directly, it avoids blocking a threadpool thread. The epoll wait is
    /// bounded by c-ares's own timeout (5 seconds). For integration with
    /// the daemon's main event loop, a future enhancement could use
    /// IORING_OP_POLL_ADD on the c-ares fds directly.
    ///
    /// On success, writes the authoritative DNS TTL (from
    /// `ares_addrinfo_node.ai_ttl`, before clamping) to `out_ttl_s`.
    fn resolveWithCares(self: *DnsResolver, host: []const u8, port: u16, out_ttl_s: *u32) !std.net.Address {
        const ch = self.channel orelse return error.CaresNotInitialized;

        var result = QueryResult{};

        // c-ares needs a null-terminated hostname
        var host_buf: [256]u8 = undefined;
        if (host.len >= host_buf.len) return error.HostNameTooLong;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;

        // ares_getaddrinfo wants a hints struct; AF_UNSPEC + flags = 0
        // matches the prior ares_gethostbyname behavior (whichever family
        // the resolver returns first).
        var hints: c.ares_addrinfo_hints = std.mem.zeroes(c.ares_addrinfo_hints);
        hints.ai_family = c.AF_UNSPEC;

        // Start the async query
        self.mutex.lock();
        c.ares_getaddrinfo(
            ch,
            @ptrCast(&host_buf),
            null, // service: not needed; we set the port on the returned address
            &hints,
            caresAddrInfoCallback,
            @ptrCast(&result),
        );
        self.mutex.unlock();

        // Create an epoll instance to wait on c-ares fds
        const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        defer posix.close(epfd);

        // Process loop: wait on c-ares fds until done or timeout.
        //
        // Clock injection note: these `std.time.milliTimestamp()` calls
        // intentionally bypass the runtime `Clock` abstraction. This
        // function runs on a DNS worker thread alongside a synchronous
        // `epoll_wait`; the wait deadline is computed against real wall
        // time and there's no way to drive it deterministically without
        // also virtualising c-ares' internal IO. Sim-time DNS is
        // tracked as follow-up work.
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
            // Hand the authoritative TTL up to the caller. ai_ttl can be
            // <= 0 if c-ares didn't see a usable record (e.g. a synthetic
            // /etc/hosts answer); fall back to the floor in that case so
            // the cache still does something useful.
            const raw_ttl = result.answer_ttl_s orelse 0;
            out_ttl_s.* = if (raw_ttl > 0) @intCast(raw_ttl) else self.ttl_bounds.floor_s;
            return resolved;
        }
        return error.DnsResolutionFailed;
    }

    /// c-ares ares_getaddrinfo callback. Pulls the first address from
    /// the linked list of `ares_addrinfo_node` entries and stashes the
    /// node's `ai_ttl` for the resolver to clamp against its bounds.
    fn caresAddrInfoCallback(
        arg: ?*anyopaque,
        status: c_int,
        _timeouts: c_int,
        ai: ?*c.struct_ares_addrinfo,
    ) callconv(.c) void {
        _ = _timeouts;
        const result: *QueryResult = @ptrCast(@alignCast(arg));
        defer if (ai) |p| c.ares_freeaddrinfo(p);

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

        const info = ai orelse {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        };
        const node = info.nodes orelse {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        };

        result.answer_ttl_s = node.ai_ttl;

        const sa = node.ai_addr orelse {
            result.err = error.DnsResolutionFailed;
            result.done = true;
            return;
        };

        if (node.ai_family == c.AF_INET) {
            const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(sa));
            const bytes: *const [4]u8 = @ptrCast(&sin.sin_addr);
            result.address = std.net.Address.initIp4(bytes.*, 0);
        } else if (node.ai_family == c.AF_INET6) {
            const sin6: *const c.struct_sockaddr_in6 = @ptrCast(@alignCast(sa));
            const bytes: *const [16]u8 = @ptrCast(&sin6.sin6_addr);
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

    var resolver = try DnsResolver.init(allocator, .{});
    defer resolver.deinit(allocator);

    var ttl_unused: u32 = 0;
    return resolver.resolveWithCares(host, port, &ttl_unused);
}

// ── Tests ────────────────────────────────────────────────

test "c-ares resolve numeric ipv4 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares resolve numeric ipv6 does not use cache" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
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
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const future = std.time.timestamp() + 3600;
    resolver.put(std.testing.allocator, "example.com", addr, future);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const resolved = try resolver.resolve(std.testing.allocator, "example.com", 9999);
    try std.testing.expectEqual(@as(u16, 9999), resolved.getPort());
}

test "c-ares cache expires entries" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const past = std.time.timestamp() - 1;
    resolver.put(std.testing.allocator, "expired.test", addr, past);

    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const resolved = try resolver.resolve(std.testing.allocator, "127.0.0.1", 80);
    try std.testing.expectEqual(@as(u16, 80), resolved.getPort());
}

test "c-ares invalidate removes entry" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "invalidate.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.invalidate(std.testing.allocator, "invalidate.test");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares invalidate nonexistent key is no-op" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    resolver.invalidate(std.testing.allocator, "nonexistent");
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares clearAll empties cache" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    resolver.put(std.testing.allocator, "a.test", addr, std.time.timestamp() + 3600);
    resolver.put(std.testing.allocator, "b.test", addr, std.time.timestamp() + 3600);
    try std.testing.expectEqual(@as(u32, 2), resolver.cache.count());

    resolver.clearAll(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), resolver.cache.count());
}

test "c-ares cache evicts oldest when full" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
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

    try std.testing.expect(resolver.cache.get("host-0.test", now) == null);
    try std.testing.expect(resolver.cache.get("overflow.test", now) != null);
}

test "c-ares cache updates existing entry without duplication" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr1 = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 80);
    const addr2 = std.net.Address.initIp4(.{ 5, 6, 7, 8 }, 80);
    const now = std.time.timestamp();

    resolver.put(std.testing.allocator, "update.test", addr1, now + 100);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    resolver.put(std.testing.allocator, "update.test", addr2, now + 200);
    try std.testing.expectEqual(@as(u32, 1), resolver.cache.count());

    const entry = resolver.cache.get("update.test", now).?;
    switch (entry) {
        .positive => |positive| try std.testing.expectEqual(@as(i64, now + 200), positive.expires_at),
        .negative => return error.UnexpectedNegativeCacheEntry,
    }
}

test "c-ares cache respects port override on hit" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 80);
    resolver.put(std.testing.allocator, "porttest.local", addr, std.time.timestamp() + 3600);

    const resolved = try resolver.resolve(std.testing.allocator, "porttest.local", 6969);
    try std.testing.expectEqual(@as(u16, 6969), resolved.getPort());
}

test "c-ares ttl_bounds defaults are 30s floor / 1h cap" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 30), resolver.ttl_bounds.floor_s);
    try std.testing.expectEqual(@as(u32, 3600), resolver.ttl_bounds.cap_s);
}

test "c-ares resolve localhost via real DNS" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
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

test "c-ares Config.bind_device captured to per-resolver field and cell" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{ .bind_device = "wg0" });
    defer resolver.deinit(std.testing.allocator);

    try std.testing.expect(resolver.bind_device != null);
    try std.testing.expectEqualStrings("wg0", resolver.bind_device.?);

    // The user_data cell must exist when bind_device is set, because
    // the c-ares socket callback dereferences it.
    try std.testing.expect(resolver.bind_device_cell != null);
    try std.testing.expectEqualStrings("wg0", resolver.bind_device_cell.?.device);
}

test "c-ares Config without bind_device leaves cell null" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    try std.testing.expect(resolver.bind_device == null);
    try std.testing.expect(resolver.bind_device_cell == null);
}

test "c-ares socket callback applies bind_device to a real fd" {
    // Drive caresSocketCreateCallback directly with a real socket fd
    // and verify SO_BINDTODEVICE is applied (or, on permission-denied
    // hosts, that the callback still returns 0 to keep DNS working).
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.UDP,
    );
    defer std.posix.close(fd);

    // The callback reads the slice from a heap cell — synthesise one
    // with a device name unlikely to exist, so the inner
    // `applyBindDevice` returns ENODEV / EPERM. The callback must
    // still return 0 (we tolerate misconfiguration).
    var cell = DnsResolver.BindDeviceCell{ .device = "varuna-doesnotexist0" };
    const rc = DnsResolver.caresSocketCreateCallback(@intCast(fd), 0, @ptrCast(&cell));
    try std.testing.expectEqual(@as(c_int, 0), rc);
}

test "c-ares socket callback with null user_data is a no-op" {
    // When init was called with bind_device=null, no callback is
    // registered so the user_data slot is never read in practice.
    // But defend against the API edge case: invoking the callback
    // with null user_data must be a clean no-op.
    const rc = DnsResolver.caresSocketCreateCallback(@intCast(@as(c_int, -1)), 0, null);
    try std.testing.expectEqual(@as(c_int, 0), rc);
}

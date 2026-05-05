const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ring_mod = @import("ring.zig");
const dns_mod = @import("dns.zig");
const ThreadpoolDnsJob = @import("../io/dns_threadpool.zig").DnsJob;
const http = @import("http_parse.zig");
const TlsStream = @import("tls.zig").TlsStream;
const build_options = @import("build_options");

const io_interface = @import("io_interface.zig");
const backend = @import("backend.zig");
const RealIO = backend.RealIO;

const log = std.log.scoped(.http_executor);

/// Generic async multiplexed HTTP(S) client over io_uring.
///
/// Runs on the main event loop's shared ring. Multiple HTTP(S) requests
/// are multiplexed concurrently via request state machines. Nothing blocks
/// the ring thread -- DNS is offloaded to the thread pool (signaled back
/// via eventfd), HTTPS uses BoringSSL's non-blocking BIO pairs, and all
/// network I/O goes through io_uring SQEs.
///
/// Compared to TrackerExecutor, this supports:
/// - Custom extra headers (e.g. Range for web seed downloads)
/// - Response headers returned in the result
/// - Optional target buffer for zero-copy body writes
///
/// Daemon callers continue to write `HttpExecutor` (the
/// `HttpExecutorOf(RealIO)` alias declared below). Sim tests instantiate
/// `HttpExecutorOf(SimIO)` directly so the same state machine drives
/// against `EventLoopOf(SimIO)`.
pub fn HttpExecutorOf(comptime IO: type) type {
    return struct {
        const Self = @This();
        const use_custom_dns = build_options.dns_backend == .custom;
        const CustomDnsResolver = dns_mod.dns_custom.resolver.DnsResolverOf(IO);
        const DnsResolver = if (use_custom_dns) CustomDnsResolver else dns_mod.DnsResolver;
        const DnsJob = if (use_custom_dns) CustomDnsResolver.ResolveJob else ThreadpoolDnsJob;
        const RetiredDnsJobs = if (use_custom_dns) std.ArrayList(*DnsJob) else void;

        allocator: std.mem.Allocator,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        destroying: bool = false,

        io: *IO,
        dns_event_fd: posix.fd_t,
        /// Completion for the persistent `io.poll(POLL_IN)` against
        /// `dns_event_fd`. Re-armed indefinitely so DNS completions on
        /// background threads are observable on the event-loop thread.
        dns_poll_completion: io_interface.Completion = .{},

        // Thread-safe job queue (producer: any thread, consumer: ring thread).
        queue_mutex: std.Thread.Mutex = .{},
        pending_jobs: std.ArrayList(Job),

        // Request slots (ring-thread only, no synchronization needed).
        slots: []RequestSlot,
        free_slot_count: u16,

        // Concurrency tracking (ring-thread only).
        host_active: std.StringHashMapUnmanaged(u16) = .{},
        active_count: u16 = 0,
        max_concurrent: u16,
        max_per_host: u16,

        dns_resolver: DnsResolver,
        retired_dns_jobs: RetiredDnsJobs,
        custom_dns_pending: usize = 0,
        custom_destroy_completion: io_interface.Completion = .{},
        pool: ConnectionPool = .{},

        // Periodic timeout tracking.
        timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },

        // Deferred jobs that couldn't start due to concurrency limits.
        deferred_jobs: std.ArrayList(Job),

        const cqe_batch_size = 32;
        const request_timeout_s: i64 = 30;
        const connect_deadline_ns: u64 = 10 * std.time.ns_per_s;

        pub const CompletionFn = *const fn (context: *anyopaque, result: RequestResult) void;

        pub const max_host_len = 253;
        pub const max_url_len = 2048;
        pub const max_method_len = 16;
        pub const max_content_type_len = 128;
        pub const max_cookie_len = 512;
        pub const max_header_len = 256;
        pub const max_extra_headers = 4;

        pub const RequestResult = struct {
            status: u16 = 0,
            body: ?[]const u8 = null,
            headers: ?[]const u8 = null,
            /// When the job had a target_buf, this is how many body bytes were
            /// written into that buffer (starting at target_offset).
            target_bytes_written: u32 = 0,
            err: ?anyerror = null,
        };

        pub const Job = struct {
            context: *anyopaque,
            on_complete: CompletionFn,
            url: [max_url_len]u8 = undefined,
            url_len: u16 = 0,
            host: [max_host_len]u8 = undefined,
            host_len: u8 = 0,
            method: [max_method_len]u8 = @as([max_method_len]u8, @splat(0)),
            method_len: u8 = 0,
            body: []const u8 = "",
            content_type: [max_content_type_len]u8 = @as([max_content_type_len]u8, @splat(0)),
            content_type_len: u8 = 0,
            cookie: [max_cookie_len]u8 = @as([max_cookie_len]u8, @splat(0)),
            cookie_len: u16 = 0,

            /// Extra HTTP headers to include in the request.
            /// Each entry is a pre-formatted header line WITHOUT trailing \r\n.
            /// Unused entries must be zero-length.
            extra_headers: [max_extra_headers]ExtraHeader = @as([max_extra_headers]ExtraHeader, @splat(.{})),

            /// When set, response body bytes are written directly into this
            /// buffer instead of being accumulated in recv_buf. Critical for
            /// web seed piece downloads (avoids extra copy).
            target_buf: ?[]u8 = null,
            target_offset: u32 = 0,

            pub fn urlSlice(self: *const Job) []const u8 {
                return self.url[0..self.url_len];
            }

            pub fn hostSlice(self: *const Job) []const u8 {
                return self.host[0..self.host_len];
            }

            pub fn methodSlice(self: *const Job) []const u8 {
                return if (self.method_len == 0) "GET" else self.method[0..self.method_len];
            }

            pub fn contentTypeSlice(self: *const Job) ?[]const u8 {
                return if (self.content_type_len == 0) null else self.content_type[0..self.content_type_len];
            }

            pub fn cookieSlice(self: *const Job) ?[]const u8 {
                return if (self.cookie_len == 0) null else self.cookie[0..self.cookie_len];
            }

            pub fn setMethodOn(self: *Job, value: []const u8) void {
                const copy_len = @min(value.len, max_method_len);
                @memcpy(self.method[0..copy_len], value[0..copy_len]);
                self.method_len = @intCast(copy_len);
            }

            pub fn setContentType(self: *Job, value: []const u8) void {
                const copy_len = @min(value.len, max_content_type_len);
                @memcpy(self.content_type[0..copy_len], value[0..copy_len]);
                self.content_type_len = @intCast(copy_len);
            }

            pub fn setCookie(self: *Job, value: []const u8) void {
                const copy_len = @min(value.len, max_cookie_len);
                @memcpy(self.cookie[0..copy_len], value[0..copy_len]);
                self.cookie_len = @intCast(copy_len);
            }
        };

        pub const ExtraHeader = struct {
            data: [max_header_len]u8 = undefined,
            len: u16 = 0,

            pub fn slice(self: *const ExtraHeader) []const u8 {
                return self.data[0..self.len];
            }

            pub fn set(value: []const u8) ExtraHeader {
                var h = ExtraHeader{};
                const copy_len = @min(value.len, max_header_len);
                @memcpy(h.data[0..copy_len], value[0..copy_len]);
                h.len = @intCast(copy_len);
                return h;
            }
        };

        pub const Config = struct {
            max_concurrent: u16 = 8,
            max_per_host: u16 = 3,
            /// Optional `SO_BINDTODEVICE` interface name applied to DNS
            /// sockets created by the underlying `DnsResolver` (c-ares
            /// backend only — the threadpool backend stores it but cannot
            /// apply it; see `src/io/dns_threadpool.zig`). The slice
            /// lifetime must outlive the executor.
            bind_device: ?[]const u8 = null,
            /// Custom-DNS-only resolver override used by deterministic tests.
            /// Production callers leave this null to read `/etc/resolv.conf`.
            dns_servers: ?[]const std.net.Address = null,
            /// Custom-DNS-only deterministic transaction-id override for tests.
            dns_test_txid_override: ?u16 = null,
        };

        const CustomDnsContext = struct {
            allocator: std.mem.Allocator,
            executor: ?*Self,
            slot_idx: u16,
            generation: u32,
        };

        const RequestSlot = struct {
            state: State = .free,
            fd: posix.fd_t = -1,
            job: Job = undefined,
            parsed: http.ParsedUrl = undefined,
            address: std.net.Address = undefined,
            dns_job: ?*DnsJob = null,
            dns_ctx: ?*CustomDnsContext = null,
            generation: u32 = 0,
            tls_stream: ?TlsStream = null,
            send_buf: std.ArrayList(u8) = std.ArrayList(u8).empty,
            send_offset: usize = 0,
            recv_buf: std.ArrayList(u8) = std.ArrayList(u8).empty,
            recv_tmp: [8192]u8 = undefined,
            tls_send_buf: [16384]u8 = undefined,
            tls_send_len: usize = 0,
            tls_send_offset: usize = 0,
            tls_handshake_bytes_sent: usize = 0,
            tls_handshake_bytes_received: usize = 0,
            deadline: i64 = 0,
            pooled: bool = false,
            /// Tracks how many body bytes have been written into target_buf.
            target_written: u32 = 0,
            /// Whether headers have been fully received (body start found).
            headers_done: bool = false,
            /// Caller-owned completion used for socket / connect / send / recv.
            /// Only one io op is in flight per slot at a time, so a single
            /// completion is sufficient.
            completion: io_interface.Completion = .{},

            const State = enum {
                free,
                dns_resolving,
                connecting,
                tls_handshaking,
                sending,
                receiving,
            };

            fn reset(self: *RequestSlot, allocator: std.mem.Allocator) void {
                if (comptime use_custom_dns) {
                    self.dns_job = null;
                    self.dns_ctx = null;
                } else {
                    if (self.dns_job) |job| {
                        job.release();
                        self.dns_job = null;
                    }
                }
                if (self.tls_stream) |*tls| {
                    tls.deinit();
                    self.tls_stream = null;
                }
                self.send_buf.deinit(allocator);
                self.send_buf = std.ArrayList(u8).empty;
                self.send_offset = 0;
                self.recv_buf.deinit(allocator);
                self.recv_buf = std.ArrayList(u8).empty;
                self.tls_send_len = 0;
                self.tls_send_offset = 0;
                self.tls_handshake_bytes_sent = 0;
                self.tls_handshake_bytes_received = 0;
                self.fd = -1;
                self.state = .free;
                self.generation +%= 1;
                self.pooled = false;
                self.target_written = 0;
                self.headers_done = false;
            }
        };

        const ConnectionPool = struct {
            const max_pooled = 16;
            const max_age_s: i64 = 60;

            entries: [max_pooled]Entry = @as([max_pooled]Entry, @splat(.{})),

            const Entry = struct {
                host: [253]u8 = undefined,
                host_len: u8 = 0,
                port: u16 = 0,
                is_https: bool = false,
                fd: posix.fd_t = -1,
                tls_stream: ?TlsStream = null,
                stored_at: i64 = 0,
            };

            const PooledConnection = struct {
                fd: posix.fd_t,
                tls_stream: ?TlsStream = null,
            };

            fn dropEntry(e: *Entry) void {
                if (e.fd >= 0) {
                    posix.close(e.fd);
                    e.fd = -1;
                }
                if (e.tls_stream) |*tls| {
                    tls.deinit();
                    e.tls_stream = null;
                }
                e.host_len = 0;
            }

            fn get(self: *ConnectionPool, host_str: []const u8, port: u16, is_https: bool, now: i64) ?PooledConnection {
                for (&self.entries) |*e| {
                    if (e.fd < 0) continue;
                    if (now - e.stored_at > max_age_s) {
                        dropEntry(e);
                        continue;
                    }
                    if (e.port == port and e.is_https == is_https and e.host_len == host_str.len and
                        std.mem.eql(u8, e.host[0..e.host_len], host_str))
                    {
                        const fd = e.fd;
                        const tls_stream = e.tls_stream;
                        e.fd = -1;
                        e.tls_stream = null;
                        e.host_len = 0;
                        return .{ .fd = fd, .tls_stream = tls_stream };
                    }
                }
                return null;
            }

            fn put(self: *ConnectionPool, host_str: []const u8, port: u16, is_https: bool, fd: posix.fd_t, tls_stream: ?TlsStream, now: i64) void {
                // Find empty slot or evict oldest
                var oldest_idx: usize = 0;
                var oldest_time: i64 = std.math.maxInt(i64);
                for (&self.entries, 0..) |e, i| {
                    if (e.fd < 0) {
                        self.storeAt(i, host_str, port, is_https, fd, tls_stream, now);
                        return;
                    }
                    if (e.stored_at < oldest_time) {
                        oldest_time = e.stored_at;
                        oldest_idx = i;
                    }
                }
                dropEntry(&self.entries[oldest_idx]);
                self.storeAt(oldest_idx, host_str, port, is_https, fd, tls_stream, now);
            }

            fn storeAt(self: *ConnectionPool, idx: usize, host_str: []const u8, port: u16, is_https: bool, fd: posix.fd_t, tls_stream: ?TlsStream, now: i64) void {
                var e = &self.entries[idx];
                e.fd = fd;
                e.port = port;
                e.is_https = is_https;
                e.tls_stream = tls_stream;
                e.stored_at = now;
                e.host_len = @intCast(host_str.len);
                @memcpy(e.host[0..host_str.len], host_str);
            }

            fn closeAll(self: *ConnectionPool) void {
                for (&self.entries) |*e| {
                    dropEntry(e);
                }
            }
        };

        // ── Public API ───────────────────────────────────────────

        pub fn create(allocator: std.mem.Allocator, io: *IO, config: Config) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const dns_event_fd = if (use_custom_dns)
                -1
            else
                try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
            errdefer if (dns_event_fd >= 0) posix.close(dns_event_fd);

            self.* = .{
                .allocator = allocator,
                .io = io,
                .dns_event_fd = dns_event_fd,
                .pending_jobs = std.ArrayList(Job).empty,
                .deferred_jobs = std.ArrayList(Job).empty,
                .max_concurrent = config.max_concurrent,
                .max_per_host = config.max_per_host,
                .dns_resolver = try initDnsResolver(allocator, io, config),
                .retired_dns_jobs = if (use_custom_dns) std.ArrayList(*DnsJob).empty else {},
                .slots = undefined,
                .free_slot_count = config.max_concurrent,
            };
            errdefer self.dns_resolver.deinit(allocator);

            self.slots = try allocator.alloc(RequestSlot, config.max_concurrent);
            errdefer allocator.free(self.slots);
            for (self.slots) |*slot| slot.* = .{};

            // Register DNS eventfd poll on the io_interface ring for the
            // threadpool-compatible public resolver facade. Custom DNS
            // completions arrive directly through ResolveJob callbacks.
            if (!use_custom_dns) self.submitDnsPoll();

            return self;
        }

        fn initDnsResolver(allocator: std.mem.Allocator, io: *IO, config: Config) !DnsResolver {
            if (comptime use_custom_dns) {
                return DnsResolver.init(allocator, io, .{
                    .servers = config.dns_servers,
                    .bind_device = config.bind_device,
                    .test_txid_override = config.dns_test_txid_override,
                });
            }
            return DnsResolver.init(allocator, .{ .bind_device = config.bind_device });
        }

        pub fn destroy(self: *Self) void {
            self.running.store(false, .release);
            if (comptime use_custom_dns) {
                self.destroying = true;
                if (self.custom_dns_pending > 0) {
                    return;
                }
            }

            self.finishDestroy();
        }

        fn finishDestroy(self: *Self) void {
            std.debug.assert(!use_custom_dns or self.custom_dns_pending == 0);

            // Clean up in-flight slots.
            for (self.slots) |*slot| {
                if (slot.state != .free) {
                    if (slot.fd >= 0) posix.close(slot.fd);
                    self.detachDnsJob(slot, true);
                    slot.reset(self.allocator);
                }
            }
            self.allocator.free(self.slots);

            self.pool.closeAll();

            var iter = self.host_active.keyIterator();
            while (iter.next()) |key| self.allocator.free(key.*);
            self.host_active.deinit(self.allocator);

            // Ring is shared, not owned
            if (self.dns_event_fd >= 0) posix.close(self.dns_event_fd);
            self.dns_resolver.deinit(self.allocator);
            self.reapRetiredDnsJobs();
            if (comptime use_custom_dns) self.retired_dns_jobs.deinit(self.allocator);
            self.pending_jobs.deinit(self.allocator);
            self.deferred_jobs.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        fn scheduleCustomDestroyReap(self: *Self) void {
            if (comptime !use_custom_dns) return;
            self.io.timeout(
                .{ .ns = 0 },
                &self.custom_destroy_completion,
                self,
                customDestroyReapComplete,
            ) catch {
                self.reapRetiredDnsJobs();
                self.finishDestroy();
            };
        }

        fn customDestroyReapComplete(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            _: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            self.reapRetiredDnsJobs();
            self.finishDestroy();
            return .disarm;
        }

        /// Submit an HTTP(S) GET request. Thread-safe.
        /// The callback is invoked on the ring thread when the response is ready.
        pub fn submit(self: *Self, job: Job) !void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (!self.running.load(.acquire)) return error.ExecutorStopped;
            try self.pending_jobs.append(self.allocator, job);
            // No wake_fd needed -- the main event loop ticks regularly and
            // calls tick() which drains the job queue.
        }

        // ── Tick (called from event loop) ────────────────────────

        /// Process pending jobs, check timeouts, and start deferred requests.
        /// Called from the main event loop's tick(). DNS completions come via
        /// CQEs on the shared ring (dns_event_fd polled with POLL_ADD).
        pub fn tick(self: *Self) void {
            self.reapRetiredDnsJobs();
            self.drainJobQueue();
            self.startDeferredJobs();
            self.checkTimeouts();
        }

        fn submitDnsPoll(self: *Self) void {
            if (comptime use_custom_dns) return;
            self.io.poll(
                .{ .fd = self.dns_event_fd, .events = linux.POLL.IN },
                &self.dns_poll_completion,
                self,
                dnsPollComplete,
            ) catch {};
        }

        /// Callback bound to `dns_poll_completion`. Drains the eventfd
        /// counter, processes any newly-resolved DNS jobs, and re-arms.
        fn dnsPollComplete(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            _: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            var buf: [8]u8 = undefined;
            _ = posix.read(self.dns_event_fd, &buf) catch {};
            self.processDnsCompletions();
            return .rearm;
        }

        /// Recover the slot index for a callback firing on `slot.completion`.
        fn slotIdxFor(self: *const Self, slot: *const RequestSlot) u16 {
            const offset = @intFromPtr(slot) - @intFromPtr(self.slots.ptr);
            return @intCast(offset / @sizeOf(RequestSlot));
        }

        // ── Job queue draining ───────────────────────────────────

        fn drainJobQueue(self: *Self) void {
            self.queue_mutex.lock();
            var jobs = self.pending_jobs;
            self.pending_jobs = std.ArrayList(Job).empty;
            self.queue_mutex.unlock();

            defer jobs.deinit(self.allocator);

            for (jobs.items) |job| {
                if (!self.tryStartJob(job)) {
                    self.deferred_jobs.append(self.allocator, job) catch {};
                }
            }
        }

        fn startDeferredJobs(self: *Self) void {
            var i: usize = 0;
            while (i < self.deferred_jobs.items.len) {
                if (self.tryStartJob(self.deferred_jobs.items[i])) {
                    _ = self.deferred_jobs.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        fn tryStartJob(self: *Self, job: Job) bool {
            if (self.active_count >= self.max_concurrent) return false;

            const slot_idx = self.claimSlot() orelse return false;
            const slot = &self.slots[slot_idx];

            // Copy job into slot FIRST so slices reference stable memory.
            slot.job = job;
            slot.deadline = std.time.timestamp() + request_timeout_s;

            const host = slot.job.hostSlice();
            const current = self.host_active.get(host) orelse 0;
            if (current >= self.max_per_host) {
                slot.state = .free;
                self.free_slot_count += 1;
                return false;
            }

            slot.parsed = http.parseUrl(slot.job.urlSlice()) catch {
                self.completeSlot(slot_idx, .{ .err = error.InvalidUrl });
                return true;
            };

            self.active_count += 1;
            self.incrementHostActive(host);

            // Check connection pool first.
            const now = std.time.timestamp();
            if (self.pool.get(host, slot.parsed.port, slot.parsed.is_https, now)) |pooled| {
                slot.fd = pooled.fd;
                slot.pooled = true;
                if (slot.parsed.is_https) {
                    slot.tls_stream = pooled.tls_stream orelse {
                        posix.close(slot.fd);
                        slot.fd = -1;
                        slot.pooled = false;
                        self.startConnect(slot, slot_idx);
                        return true;
                    };
                    self.buildAndSendTlsRequest(slot, slot_idx);
                    return true;
                } else {
                    self.buildAndSendRequest(slot, slot_idx);
                    return true;
                }
            }

            // Resolve DNS (async).
            if (comptime use_custom_dns) {
                self.startCustomDnsResolve(slot, slot_idx, host);
            } else {
                const result = self.dns_resolver.resolveAsync(
                    host,
                    slot.parsed.port,
                    self.dns_event_fd,
                ) catch {
                    self.completeSlot(slot_idx, .{ .err = error.DnsResolutionFailed });
                    return true;
                };

                switch (result) {
                    .resolved => |addr| {
                        slot.address = addr;
                        self.startConnect(slot, slot_idx);
                    },
                    .pending => |dns_job| {
                        slot.dns_job = dns_job;
                        slot.state = .dns_resolving;
                    },
                }
            }

            return true;
        }

        // ── DNS completion ───────────────────────────────────────

        fn startCustomDnsResolve(self: *Self, slot: *RequestSlot, slot_idx: u16, host: []const u8) void {
            const ctx = self.allocator.create(CustomDnsContext) catch {
                self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
                return;
            };
            ctx.* = .{
                .allocator = self.allocator,
                .executor = self,
                .slot_idx = slot_idx,
                .generation = slot.generation,
            };

            const result = self.dns_resolver.resolveAsync(
                host,
                slot.parsed.port,
                ctx,
                customDnsComplete,
            ) catch {
                self.allocator.destroy(ctx);
                self.completeSlot(slot_idx, .{ .err = error.DnsResolutionFailed });
                return;
            };

            switch (result) {
                .resolved => |addr| {
                    self.allocator.destroy(ctx);
                    slot.address = addr;
                    self.startConnect(slot, slot_idx);
                },
                .nx_domain => {
                    self.allocator.destroy(ctx);
                    self.completeSlot(slot_idx, .{ .err = error.DnsResolutionFailed });
                },
                .failed => |err| {
                    self.allocator.destroy(ctx);
                    self.completeSlot(slot_idx, .{ .err = err });
                },
                .pending => |dns_job| {
                    self.custom_dns_pending += 1;
                    slot.dns_job = dns_job;
                    slot.dns_ctx = ctx;
                    slot.state = .dns_resolving;
                },
            }
        }

        fn customDnsComplete(
            userdata: ?*anyopaque,
            dns_job: *DnsJob,
            result: dns_mod.dns_custom.resolver.ResolveResult,
        ) void {
            const ctx: *CustomDnsContext = @ptrCast(@alignCast(userdata.?));
            const maybe_self = ctx.executor;
            if (maybe_self == null) {
                // Executor teardown can abandon in-flight DNS. Full query
                // cancellation is still a custom-DNS follow-up; leaking the
                // completed job is safer than freeing query-owned completions
                // while an IO backend may still deliver cancel CQEs.
                ctx.allocator.destroy(ctx);
                return;
            }

            const self = maybe_self.?;
            defer self.allocator.destroy(ctx);
            defer self.retireCompletedDnsJob(dns_job);

            if (ctx.slot_idx >= self.slots.len) return;
            const slot = &self.slots[ctx.slot_idx];
            if (self.custom_dns_pending > 0) self.custom_dns_pending -= 1;
            if (slot.state != .dns_resolving or
                slot.generation != ctx.generation or
                slot.dns_job != dns_job)
            {
                if (self.destroying and self.custom_dns_pending == 0) {
                    self.scheduleCustomDestroyReap();
                }
                return;
            }

            slot.dns_job = null;
            slot.dns_ctx = null;

            if (self.destroying) {
                if (self.custom_dns_pending == 0) {
                    self.scheduleCustomDestroyReap();
                }
                return;
            }

            switch (result) {
                .resolved => |addr| {
                    slot.address = addr;
                    self.startConnect(slot, ctx.slot_idx);
                },
                .nx_domain => self.completeSlot(ctx.slot_idx, .{ .err = error.DnsResolutionFailed }),
                .failed => |err| self.completeSlot(ctx.slot_idx, .{ .err = err }),
            }
        }

        fn processDnsCompletions(self: *Self) void {
            if (comptime use_custom_dns) return;
            for (self.slots, 0..) |*slot, i| {
                if (slot.state != .dns_resolving) continue;
                const dns_job = slot.dns_job orelse continue;
                if (!dns_job.isDone()) continue;

                // DNS completed -- read result.
                if (dns_job.err) |err| {
                    self.completeSlot(@intCast(i), .{ .err = err });
                    continue;
                }

                if (dns_job.address) |addr| {
                    slot.address = addr;
                    // Cache the result.
                    self.dns_resolver.cacheResult(
                        self.allocator,
                        slot.job.hostSlice(),
                        addr,
                    );
                    // Release the DNS job.
                    dns_job.release();
                    slot.dns_job = null;
                    self.startConnect(slot, @intCast(i));
                } else {
                    self.completeSlot(@intCast(i), .{ .err = error.DnsResolutionFailed });
                }
            }
        }

        fn detachDnsJob(self: *Self, slot: *RequestSlot, destroying_executor: bool) void {
            if (comptime use_custom_dns) {
                if (slot.dns_ctx) |ctx| {
                    if (destroying_executor) ctx.executor = null;
                    slot.dns_ctx = null;
                }
                slot.dns_job = null;
            } else {
                if (slot.dns_job) |dns_job| {
                    dns_job.release();
                    slot.dns_job = null;
                }
            }
            _ = self;
        }

        fn retireCompletedDnsJob(self: *Self, dns_job: *DnsJob) void {
            if (comptime use_custom_dns) {
                self.retired_dns_jobs.append(self.allocator, dns_job) catch {
                    std.log.scoped(.http_executor).warn(
                        "custom DNS retired-job queue OOM; leaking completed DNS job",
                        .{},
                    );
                };
            } else {}
        }

        fn reapRetiredDnsJobs(self: *Self) void {
            if (comptime use_custom_dns) {
                for (self.retired_dns_jobs.items) |dns_job| dns_job.destroy();
                self.retired_dns_jobs.clearRetainingCapacity();
            }
        }

        // ── Connect ──────────────────────────────────────────────

        fn startConnect(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            const family: u32 = slot.address.any.family;
            slot.state = .connecting;
            // Submit async socket creation -- httpSocketComplete will chain the connect.
            self.io.socket(
                .{ .domain = family, .sock_type = posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, .protocol = posix.IPPROTO.TCP },
                &slot.completion,
                self,
                httpSocketComplete,
            ) catch {
                self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
                return;
            };
        }

        /// Callback for the async socket creation. Stores the new fd on the
        /// slot and chains the deadline-bounded connect.
        fn httpSocketComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("completion", completion);
            const slot_idx = self.slotIdxFor(slot);
            if (slot.state != .connecting) return .disarm;

            const fd = switch (result) {
                .socket => |r| r catch {
                    self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
                    return .disarm;
                },
                else => return .disarm,
            };
            slot.fd = fd;

            self.io.connect(
                .{ .fd = fd, .addr = slot.address, .deadline_ns = connect_deadline_ns },
                &slot.completion,
                self,
                httpConnectComplete,
            ) catch {
                posix.close(fd);
                slot.fd = -1;
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
            return .disarm;
        }

        /// Callback for the deadline-bounded connect. On success, advances
        /// to TLS or plain-text request build.
        fn httpConnectComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("completion", completion);
            const slot_idx = self.slotIdxFor(slot);
            if (slot.state != .connecting) return .disarm;

            switch (result) {
                .connect => |r| r catch |err| {
                    // The resolved IP appears wrong/dead. Drop the cache entry
                    // so the next attempt re-resolves through DNS instead of
                    // burning the full TTL window on the same broken IP. See
                    // dns.shouldInvalidateOnConnectError for the variant
                    // classification.
                    if (dns_mod.shouldInvalidateOnConnectError(err)) {
                        self.dns_resolver.invalidate(self.allocator, slot.job.hostSlice());
                    }
                    self.completeSlot(slot_idx, .{ .err = err });
                    return .disarm;
                },
                else => return .disarm,
            }

            if (slot.parsed.is_https) {
                self.startTlsHandshake(slot, slot_idx);
            } else {
                self.buildAndSendRequest(slot, slot_idx);
            }
            return .disarm;
        }

        // ── TLS handshake (async via BIO pairs) ──────────────────

        fn startTlsHandshake(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            if (build_options.tls_backend == .none) {
                self.completeSlot(slot_idx, .{ .err = error.HttpsNotSupported });
                return;
            }

            slot.tls_stream = TlsStream.init(self.allocator, slot.job.hostSlice()) catch {
                self.completeSlot(slot_idx, .{ .err = error.TlsInitFailed });
                return;
            };
            slot.state = .tls_handshaking;
            self.advanceTlsHandshake(slot, slot_idx);
        }

        fn advanceTlsHandshake(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            var tls = &(slot.tls_stream orelse return);

            const result = tls.doHandshake() catch |err| {
                self.completeSlot(slot_idx, .{ .err = err });
                return;
            };

            switch (result) {
                .complete => {
                    self.buildAndSendTlsRequest(slot, slot_idx);
                },
                .want_write => {
                    self.flushTlsPendingSend(slot, slot_idx);
                },
                .want_read => {
                    self.flushTlsPendingSend(slot, slot_idx);
                },
            }
        }

        fn buildAndSendTlsRequest(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            var tls = &(slot.tls_stream orelse {
                self.completeSlot(slot_idx, .{ .err = error.TlsWriteFailed });
                return;
            });
            self.buildRequest(slot) catch {
                self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
                return;
            };
            // Encrypt the request.
            _ = tls.writePlaintext(slot.send_buf.items) catch {
                self.completeSlot(slot_idx, .{ .err = error.TlsWriteFailed });
                return;
            };
            slot.state = .sending;
            // Extract ciphertext to send.
            self.flushTlsPendingSend(slot, slot_idx);
        }

        fn flushTlsPendingSend(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            if (slot.tls_send_offset < slot.tls_send_len) {
                self.submitTlsSend(slot, slot_idx);
                return;
            }

            var tls = &(slot.tls_stream orelse return);
            const n = tls.pendingSend(&slot.tls_send_buf) catch {
                self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                return;
            };
            if (n == 0) {
                // Nothing to send -- need more data from peer.
                self.io.recv(
                    .{ .fd = slot.fd, .buf = &slot.recv_tmp },
                    &slot.completion,
                    self,
                    httpRecvComplete,
                ) catch {
                    self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
                };
                return;
            }
            slot.tls_send_len = n;
            slot.tls_send_offset = 0;
            self.submitTlsSend(slot, slot_idx);
        }

        fn submitTlsSend(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            self.io.send(
                .{ .fd = slot.fd, .buf = slot.tls_send_buf[slot.tls_send_offset..slot.tls_send_len] },
                &slot.completion,
                self,
                httpSendComplete,
            ) catch {
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
        }

        fn buildRequest(self: *Self, slot: *RequestSlot) !void {
            const parsed = slot.parsed;
            slot.send_buf.clearRetainingCapacity();

            var header_storage: [max_extra_headers]http.Header = undefined;
            var header_count: usize = 0;
            for (&slot.job.extra_headers) |*hdr| {
                if (hdr.len == 0) continue;
                const line = hdr.slice();
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                header_storage[header_count] = .{
                    .name = std.mem.trim(u8, line[0..colon], " "),
                    .value = std.mem.trim(u8, line[colon + 1 ..], " "),
                };
                header_count += 1;
                if (header_count == header_storage.len) {
                    break;
                }
            }

            try http.appendRequest(self.allocator, &slot.send_buf, .{
                .method = slot.job.methodSlice(),
                .host = slot.job.hostSlice(),
                .path = parsed.path,
                .body = slot.job.body,
                .content_type = slot.job.contentTypeSlice(),
                .cookie = slot.job.cookieSlice(),
                .extra_headers = header_storage[0..header_count],
                .connection = "keep-alive",
                .user_agent = "varuna/0.1",
            });
        }

        fn buildAndSendRequest(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            self.buildRequest(slot) catch {
                self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
                return;
            };
            if (slot.send_buf.items.len == 0) {
                self.completeSlot(slot_idx, .{ .err = error.InvalidUrl });
                return;
            }
            slot.send_offset = 0;
            slot.state = .sending;
            self.submitSend(slot, slot_idx);
        }

        fn submitSend(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            const remaining = slot.send_buf.items[slot.send_offset..];
            self.io.send(
                .{ .fd = slot.fd, .buf = remaining },
                &slot.completion,
                self,
                httpSendComplete,
            ) catch {
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
        }

        fn httpSendComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("completion", completion);
            const slot_idx = self.slotIdxFor(slot);
            const n = switch (result) {
                .send => |r| r catch |err| {
                    // If pooled connection was stale, retry with fresh connect.
                    if (slot.pooled and slot.state == .sending and slot.send_offset == 0) {
                        posix.close(slot.fd);
                        slot.fd = -1;
                        slot.pooled = false;
                        if (slot.tls_stream) |*tls| {
                            tls.deinit();
                            slot.tls_stream = null;
                        }
                        slot.tls_send_len = 0;
                        slot.tls_send_offset = 0;
                        self.startConnect(slot, slot_idx);
                        return .disarm;
                    }
                    self.completeSlot(slot_idx, .{ .err = err });
                    return .disarm;
                },
                else => return .disarm,
            };
            if (n == 0) {
                self.completeSlot(slot_idx, .{ .err = error.ConnectionClosed });
                return .disarm;
            }

            if (slot.parsed.is_https and slot.state == .tls_handshaking) {
                slot.tls_handshake_bytes_sent += n;
            }

            if (slot.parsed.is_https and slot.tls_stream != null and slot.tls_send_len > 0) {
                slot.tls_send_offset += @min(n, slot.tls_send_len - slot.tls_send_offset);
                if (slot.tls_send_offset < slot.tls_send_len) {
                    self.submitTlsSend(slot, slot_idx);
                    return .disarm;
                }
                slot.tls_send_len = 0;
                slot.tls_send_offset = 0;
            }

            if (slot.state == .tls_handshaking) {
                var tls = &(slot.tls_stream orelse return .disarm);
                const pending = tls.pendingSend(&slot.tls_send_buf) catch {
                    self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                    return .disarm;
                };
                if (pending > 0) {
                    slot.tls_send_len = pending;
                    slot.tls_send_offset = 0;
                    self.submitTlsSend(slot, slot_idx);
                    return .disarm;
                }
                self.advanceTlsHandshake(slot, slot_idx);
                return .disarm;
            }

            if (slot.parsed.is_https and slot.tls_stream != null) {
                var tls = &(slot.tls_stream orelse return .disarm);
                const pending = tls.pendingSend(&slot.tls_send_buf) catch {
                    self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                    return .disarm;
                };
                if (pending > 0) {
                    slot.tls_send_len = pending;
                    slot.tls_send_offset = 0;
                    self.submitTlsSend(slot, slot_idx);
                    return .disarm;
                }
                slot.state = .receiving;
                self.submitRecv(slot, slot_idx);
                return .disarm;
            }

            slot.send_offset += n;
            if (slot.send_offset < slot.send_buf.items.len) {
                self.submitSend(slot, slot_idx);
                return .disarm;
            }
            slot.state = .receiving;
            self.submitRecv(slot, slot_idx);
            return .disarm;
        }

        // ── HTTP response receiving ──────────────────────────────

        fn submitRecv(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            self.io.recv(
                .{ .fd = slot.fd, .buf = &slot.recv_tmp },
                &slot.completion,
                self,
                httpRecvComplete,
            ) catch {
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
        }

        fn httpRecvComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("completion", completion);
            const slot_idx = self.slotIdxFor(slot);
            const n = switch (result) {
                .recv => |r| r catch |err| {
                    self.completeSlot(slot_idx, .{ .err = err });
                    return .disarm;
                },
                else => return .disarm,
            };
            handleRecvBytes(self, slot, slot_idx, n);
            return .disarm;
        }

        fn handleRecvBytes(self: *Self, slot: *RequestSlot, slot_idx: u16, n_in: usize) void {
            const n: usize = n_in;

            // During TLS handshake, feed received ciphertext to BoringSSL.
            if (slot.state == .tls_handshaking) {
                if (n == 0) {
                    self.completeSlot(slot_idx, .{ .err = error.TlsHandshakeFailed });
                    return;
                }
                slot.tls_handshake_bytes_received += n;
                var tls = &(slot.tls_stream orelse return);
                tls.feedRecv(slot.recv_tmp[0..n]) catch {
                    self.completeSlot(slot_idx, .{ .err = error.TlsHandshakeFailed });
                    return;
                };
                self.advanceTlsHandshake(slot, slot_idx);
                return;
            }

            // HTTPS receiving: decrypt.
            if (slot.parsed.is_https and slot.tls_stream != null) {
                if (n == 0) {
                    self.tryCompleteResponse(slot, true);
                    return;
                }
                var tls = &(slot.tls_stream orelse return);
                tls.feedRecv(slot.recv_tmp[0..n]) catch {
                    self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                    return;
                };
                // Read all available plaintext.
                var plaintext_buf: [8192]u8 = undefined;
                while (true) {
                    const pn = tls.readPlaintext(&plaintext_buf) catch {
                        self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                        return;
                    };
                    if (pn == 0) break;
                    self.appendRecvData(slot, plaintext_buf[0..pn]) catch {
                        self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
                        return;
                    };
                }
                if (self.isResponseComplete(slot)) {
                    self.finishResponse(slot, slot_idx);
                } else {
                    self.submitRecv(slot, slot_idx);
                }
                return;
            }

            // Plain HTTP receiving.
            if (n == 0) {
                self.tryCompleteResponse(slot, true);
                return;
            }

            self.appendRecvData(slot, slot.recv_tmp[0..n]) catch {
                self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
                return;
            };

            if (self.isResponseComplete(slot)) {
                self.finishResponse(slot, slot_idx);
            } else {
                self.submitRecv(slot, slot_idx);
            }
        }

        /// Append received data, routing body bytes to target_buf when set.
        fn appendRecvData(self: *Self, slot: *RequestSlot, data: []const u8) !void {
            if (slot.job.target_buf == null) {
                // No target buffer -- accumulate everything in recv_buf as before.
                try slot.recv_buf.appendSlice(self.allocator, data);
                return;
            }

            if (!slot.headers_done) {
                // Haven't found the end of headers yet -- accumulate in recv_buf.
                try slot.recv_buf.appendSlice(self.allocator, data);

                // Check if headers are now complete.
                if (http.findBodyStart(slot.recv_buf.items)) |body_start| {
                    slot.headers_done = true;
                    // Any body bytes already in recv_buf need to go to target_buf.
                    const body_bytes = slot.recv_buf.items[body_start..];
                    if (body_bytes.len > 0) {
                        self.writeToTargetBuf(slot, body_bytes);
                    }
                    // Trim recv_buf to just the headers (keep for finishResponse).
                    slot.recv_buf.shrinkRetainingCapacity(body_start);
                }
            } else {
                // Headers done -- write body bytes directly to target buffer.
                self.writeToTargetBuf(slot, data);
            }
        }

        /// Write body bytes into the job's target buffer.
        fn writeToTargetBuf(_: *Self, slot: *RequestSlot, data: []const u8) void {
            const target = slot.job.target_buf orelse return;
            const offset = slot.job.target_offset + slot.target_written;
            const available = if (offset < target.len) target.len - offset else 0;
            const copy_len = @min(data.len, available);
            if (copy_len > 0) {
                @memcpy(target[offset..][0..copy_len], data[0..copy_len]);
                slot.target_written += @intCast(copy_len);
            }
        }

        fn isResponseComplete(self: *Self, slot: *RequestSlot) bool {
            _ = self;
            const data = slot.recv_buf.items;
            const body_start = http.findBodyStart(data) orelse return false;

            if (slot.job.target_buf != null) {
                // With target_buf: headers are in recv_buf, body is in target_buf.
                // Content-Length check uses target_written.
                if (http.parseContentLength(data[0..body_start])) |cl| {
                    return slot.target_written >= cl;
                }
                return false;
            }

            // Without target_buf: everything is in recv_buf.
            if (http.parseContentLength(data[0..body_start])) |cl| {
                return data.len >= body_start + cl;
            }
            // No Content-Length -- check for Connection: close pattern (wait for EOF).
            return false;
        }

        fn tryCompleteResponse(self: *Self, slot: *RequestSlot, eof: bool) void {
            const slot_idx = self.slotIndex(slot);
            if (eof or self.isResponseComplete(slot)) {
                self.finishResponse(slot, slot_idx);
            } else {
                self.completeSlot(slot_idx, .{ .err = error.UnexpectedEndOfStream });
            }
        }

        fn finishResponse(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            const data = slot.recv_buf.items;
            const status = http.parseStatusCode(data) orelse 0;
            const body_start = http.findBodyStart(data);

            var result = RequestResult{
                .status = status,
                .target_bytes_written = slot.target_written,
            };

            // Extract headers.
            if (body_start) |bs| {
                result.headers = if (bs > 0) data[0..bs] else null;
            }

            if (slot.job.target_buf != null) {
                // Body was written directly to target_buf; no body slice in result.
                result.body = null;
            } else {
                // Body is in recv_buf after headers.
                result.body = if (body_start) |bs|
                    if (bs < data.len) data[bs..] else null
                else
                    null;
            }

            // Check if connection is reusable BEFORE completing (which frees the slot).
            const reusable = if (body_start) |bs|
                !http.parseConnectionClose(data[0..bs]) and
                    http.parseContentLength(data[0..bs]) != null
            else
                false;

            // Return connection (and, for HTTPS, the established TLS stream)
            // to the pool before completing the slot.
            if (reusable and slot.fd >= 0) {
                const tls_stream = if (slot.parsed.is_https) blk: {
                    const tls = slot.tls_stream orelse break :blk null;
                    slot.tls_stream = null;
                    break :blk tls;
                } else null;
                self.pool.put(
                    slot.job.hostSlice(),
                    slot.parsed.port,
                    slot.parsed.is_https,
                    slot.fd,
                    tls_stream,
                    std.time.timestamp(),
                );
                slot.fd = -1; // Prevent close in completeSlot.
            }

            self.completeSlot(slot_idx, result);
        }

        // ── Timeout checking ─────────────────────────────────────

        fn checkTimeouts(self: *Self) void {
            const now = std.time.timestamp();
            for (self.slots, 0..) |*slot, i| {
                if (slot.state == .free) continue;
                if (now >= slot.deadline) {
                    log.warn("request timed out (state={s}, host={s}, url={s}, addr={f}, tls_sent={d}, tls_recv={d})", .{
                        @tagName(slot.state),
                        slot.job.hostSlice(),
                        slot.job.urlSlice(),
                        slot.address,
                        slot.tls_handshake_bytes_sent,
                        slot.tls_handshake_bytes_received,
                    });
                    self.completeSlot(@intCast(i), .{ .err = error.RequestTimedOut });
                }
            }
        }

        // ── Slot management ──────────────────────────────────────

        fn claimSlot(self: *Self) ?u16 {
            for (self.slots, 0..) |*slot, i| {
                if (slot.state == .free) return @intCast(i);
            }
            return null;
        }

        fn slotIndex(self: *Self, slot: *RequestSlot) u16 {
            const base = @intFromPtr(self.slots.ptr);
            const ptr = @intFromPtr(slot);
            return @intCast((ptr - base) / @sizeOf(RequestSlot));
        }

        fn completeSlot(self: *Self, slot_idx: u16, result: RequestResult) void {
            const slot = &self.slots[slot_idx];
            if (slot.state == .free) return;

            const host = slot.job.hostSlice();
            const job = slot.job;

            // Copy the body before reset, because result.body references
            // slot.recv_buf which reset() frees.
            var owned_body: ?[]u8 = null;
            defer if (owned_body) |b| self.allocator.free(b);
            var owned_headers: ?[]u8 = null;
            defer if (owned_headers) |h| self.allocator.free(h);
            var result_copy = result;
            if (result.body) |body| {
                owned_body = self.allocator.dupe(u8, body) catch null;
                result_copy.body = owned_body;
            }
            if (result.headers) |hdrs| {
                owned_headers = self.allocator.dupe(u8, hdrs) catch null;
                result_copy.headers = owned_headers;
            }

            // Close fd if not returned to pool.
            if (slot.fd >= 0) {
                posix.close(slot.fd);
            }
            self.detachDnsJob(slot, false);
            slot.reset(self.allocator);

            self.active_count -= 1;
            self.decrementHostActive(host);

            // Invoke callback with the owned copy.
            job.on_complete(job.context, result_copy);
        }

        fn incrementHostActive(self: *Self, host: []const u8) void {
            if (self.host_active.getPtr(host)) |count| {
                count.* += 1;
            } else {
                const owned = self.allocator.dupe(u8, host) catch return;
                self.host_active.put(self.allocator, owned, 1) catch {
                    self.allocator.free(owned);
                };
            }
        }

        fn decrementHostActive(self: *Self, host: []const u8) void {
            if (self.host_active.getPtr(host)) |count| {
                count.* -= 1;
                if (count.* == 0) {
                    if (self.host_active.fetchRemove(host)) |kv| {
                        self.allocator.free(kv.key);
                    }
                }
            }
        }

        // ── Tests ────────────────────────────────────────────────

        test "connect failure invalidates cached DNS entry" {
            if (comptime use_custom_dns) return error.SkipZigTest;

            const allocator = std.testing.allocator;
            const host = "varuna-dns-fixes-regression.test";

            var slots = try allocator.alloc(RequestSlot, 1);
            defer allocator.free(slots);
            slots[0] = .{};

            var self = Self{
                .allocator = allocator,
                .io = undefined,
                .dns_event_fd = -1,
                .pending_jobs = std.ArrayList(Job).empty,
                .slots = slots,
                .free_slot_count = 0,
                .max_concurrent = 1,
                .max_per_host = 1,
                .dns_resolver = try DnsResolver.init(allocator, .{}),
                .retired_dns_jobs = {},
                .deferred_jobs = std.ArrayList(Job).empty,
            };
            defer {
                var iter = self.host_active.keyIterator();
                while (iter.next()) |key| allocator.free(key.*);
                self.host_active.deinit(allocator);
                self.dns_resolver.deinit(allocator);
                self.pending_jobs.deinit(allocator);
                self.deferred_jobs.deinit(allocator);
            }

            const cached_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 80);
            self.dns_resolver.cacheResult(allocator, host, cached_addr);
            try std.testing.expectEqual(@as(u32, 1), self.dns_resolver.cache.count());

            const CallbackState = struct {
                called: bool = false,
                err: ?anyerror = null,

                fn complete(ctx: *anyopaque, result: RequestResult) void {
                    const state: *@This() = @ptrCast(@alignCast(ctx));
                    state.called = true;
                    state.err = result.err;
                }
            };

            var callback_state = CallbackState{};
            self.active_count = 1;
            self.incrementHostActive(host);

            slots[0].state = .connecting;
            slots[0].job = .{
                .context = &callback_state,
                .on_complete = CallbackState.complete,
                .host_len = @intCast(host.len),
            };
            @memcpy(slots[0].job.host[0..host.len], host);

            const action = httpConnectComplete(
                &self,
                &slots[0].completion,
                .{ .connect = error.ConnectionRefused },
            );

            try std.testing.expectEqual(io_interface.CallbackAction.disarm, action);
            try std.testing.expect(callback_state.called);
            try std.testing.expectEqual(error.ConnectionRefused, callback_state.err.?);
            try std.testing.expectEqual(@as(u32, 0), self.dns_resolver.cache.count());
        }

        test "target_buf receives correct body data for multi-piece range" {
            // Simulate an HTTP 206 response being received in chunks and
            // verify that the body bytes end up at the correct position in
            // target_buf (the multi-piece web seed download path).
            const Sha1 = @import("../crypto/root.zig").Sha1;
            const allocator = std.testing.allocator;

            // Simulate a 4-piece file (256KB pieces = 1MB total)
            const piece_length: u32 = 262144;
            const piece_count: u32 = 4;
            const total_bytes: u32 = piece_length * piece_count;

            // Create known file content (deterministic pattern)
            const file_data = try allocator.alloc(u8, total_bytes);
            defer allocator.free(file_data);
            for (file_data, 0..) |*b, i| {
                b.* = @truncate(i *% 251 +% 71);
            }

            // Compute expected SHA-1 for each piece
            var expected_hashes: [piece_count][20]u8 = undefined;
            for (0..piece_count) |i| {
                const start = i * piece_length;
                const end = start + piece_length;
                Sha1.hash(file_data[start..end], &expected_hashes[i], .{});
            }

            // Allocate the target buffer (like run_buf in the web seed handler)
            const target_buf = try allocator.alloc(u8, total_bytes);
            defer allocator.free(target_buf);
            @memset(target_buf, 0);

            // Build a fake HTTP 206 response
            const headers = "HTTP/1.1 206 Partial Content\r\n" ++
                "Content-Type: application/octet-stream\r\n" ++
                "Content-Length: 1048576\r\n" ++
                "Content-Range: bytes 0-1048575/1048576\r\n" ++
                "\r\n";

            // Create a minimal HttpExecutor (only allocator field is used)
            var he: Self = undefined;
            he.allocator = allocator;

            // Create a request slot with target_buf configured
            var slot = RequestSlot{};
            slot.job = Job{
                .context = undefined,
                .on_complete = undefined,
                .target_buf = target_buf,
                .target_offset = 0,
            };

            // Simulate receiving data in chunks, like io_uring recv would deliver.
            // First chunk: all headers + first part of body.
            const first_chunk_size = 8192;
            var full_response = try allocator.alloc(u8, headers.len + total_bytes);
            defer allocator.free(full_response);
            @memcpy(full_response[0..headers.len], headers);
            @memcpy(full_response[headers.len..], file_data);

            // Feed the response in 8KB chunks (simulating recv_tmp[0..n])
            var offset: usize = 0;
            while (offset < full_response.len) {
                const chunk_end = @min(offset + first_chunk_size, full_response.len);
                const chunk = full_response[offset..chunk_end];
                try he.appendRecvData(&slot, chunk);
                offset = chunk_end;
            }

            // Verify headers_done was set
            try std.testing.expect(slot.headers_done);

            // Verify all body bytes were written
            try std.testing.expectEqual(total_bytes, slot.target_written);

            // Split the buffer at piece boundaries and verify SHA-1 hashes
            var mismatches: u32 = 0;
            for (0..piece_count) |i| {
                const start = i * piece_length;
                const end = start + piece_length;
                const piece_data = target_buf[start..end];

                var actual_hash: [20]u8 = undefined;
                Sha1.hash(piece_data, &actual_hash, .{});

                if (!std.mem.eql(u8, &actual_hash, &expected_hashes[i])) {
                    mismatches += 1;
                }
            }

            // This is the key assertion: all pieces should hash correctly.
            // The bug causes ALL pieces to fail hash verification.
            try std.testing.expectEqual(@as(u32, 0), mismatches);

            // Clean up recv_buf
            slot.recv_buf.deinit(allocator);
        }

        test "target_buf with non-zero offset writes at correct position" {
            // Tests the multi-file scenario where buf_offset > 0 for subsequent ranges.
            const allocator = std.testing.allocator;

            const target_buf = try allocator.alloc(u8, 4096);
            defer allocator.free(target_buf);
            @memset(target_buf, 0);

            // Second range writes to offset 1024 within the target buffer.
            const headers = "HTTP/1.1 206 Partial Content\r\n" ++
                "Content-Length: 1024\r\n" ++
                "\r\n";

            var body: [1024]u8 = undefined;
            for (&body, 0..) |*b, i| {
                b.* = @truncate(i ^ 0xAB);
            }

            var he: Self = undefined;
            he.allocator = allocator;

            var slot = RequestSlot{};
            slot.job = Job{
                .context = undefined,
                .on_complete = undefined,
                .target_buf = target_buf,
                .target_offset = 1024,
            };

            // Feed response in one chunk
            var full_response = try allocator.alloc(u8, headers.len + body.len);
            defer allocator.free(full_response);
            @memcpy(full_response[0..headers.len], headers);
            @memcpy(full_response[headers.len..], &body);

            try he.appendRecvData(&slot, full_response);

            try std.testing.expect(slot.headers_done);
            try std.testing.expectEqual(@as(u32, 1024), slot.target_written);

            // Verify data was written at the correct offset
            // Bytes 0-1023 should be untouched (still 0)
            for (target_buf[0..1024]) |b| {
                try std.testing.expectEqual(@as(u8, 0), b);
            }
            // Bytes 1024-2047 should have the body data
            try std.testing.expect(std.mem.eql(u8, target_buf[1024..2048], &body));
            // Bytes 2048-4095 should be untouched
            for (target_buf[2048..4096]) |b| {
                try std.testing.expectEqual(@as(u8, 0), b);
            }

            slot.recv_buf.deinit(allocator);
        }
    };
}

/// Daemon-side alias: the `RealIO` instantiation of the HTTP executor.
/// Sim tests instantiate `HttpExecutorOf(SimIO)` directly; production code
/// references this alias unchanged.
pub const HttpExecutor = HttpExecutorOf(RealIO);

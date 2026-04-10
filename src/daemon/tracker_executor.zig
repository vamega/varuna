const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ring_mod = @import("../io/ring.zig");
const DnsResolver = @import("../io/dns.zig").DnsResolver;
const DnsJob = @import("../io/dns_threadpool.zig").DnsJob;
const http = @import("../io/http.zig");
const TlsStream = @import("../io/tls.zig").TlsStream;
const build_options = @import("build_options");

// Reuse the event loop's user data encoding.
const event_loop = @import("../io/event_loop.zig");
const encodeUserData = event_loop.encodeUserData;
const decodeUserData = event_loop.decodeUserData;
const OpType = event_loop.OpType;

const log = std.log.scoped(.tracker_executor);

/// Async multiplexed tracker executor.
///
/// Runs a single background thread with its own io_uring ring. Multiple
/// HTTP(S) tracker requests are multiplexed concurrently on that ring
/// via request state machines. Nothing blocks the ring thread — DNS is
/// offloaded to the thread pool (signaled back via eventfd), HTTPS uses
/// BoringSSL's non-blocking BIO pairs, and all network I/O goes through
/// io_uring SQEs.
pub const TrackerExecutor = struct {
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    ring: *linux.IoUring,
    dns_event_fd: posix.fd_t,

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
    pool: ConnectionPool = .{},

    // Periodic timeout tracking.
    timeout_ts: linux.kernel_timespec = .{ .sec = 2, .nsec = 0 },

    // Deferred jobs that couldn't start due to concurrency limits.
    deferred_jobs: std.ArrayList(Job),

    const sentinel_wake: u16 = 0xFFFF;
    const sentinel_dns: u16 = 0xFFFE;
    const sentinel_timeout: u16 = 0xFFFD;
    const cqe_batch_size = 32;
    const request_timeout_s: i64 = 30;

    pub const CompletionFn = *const fn (context: *anyopaque, result: RequestResult) void;

    pub const RequestResult = struct {
        status: u16 = 0,
        body: ?[]const u8 = null,
        err: ?anyerror = null,
    };

    pub const Job = struct {
        context: *anyopaque,
        on_complete: CompletionFn,
        url: [max_url_len]u8 = undefined,
        url_len: u16 = 0,
        host: [max_host_len]u8 = undefined,
        host_len: u8 = 0,

        const max_host_len = 253;
        const max_url_len = 2048;

        fn urlSlice(self: *const Job) []const u8 {
            return self.url[0..self.url_len];
        }

        fn hostSlice(self: *const Job) []const u8 {
            return self.host[0..self.host_len];
        }
    };

    pub const Config = struct {
        max_concurrent: u16 = 8,
        max_per_host: u16 = 3,
    };

    const RequestSlot = struct {
        state: State = .free,
        fd: posix.fd_t = -1,
        job: Job = undefined,
        parsed: http.ParsedUrl = undefined,
        address: std.net.Address = undefined,
        dns_job: ?*DnsJob = null,
        tls_stream: ?TlsStream = null,
        send_buf: std.ArrayList(u8) = std.ArrayList(u8).empty,
        send_offset: usize = 0,
        recv_buf: std.ArrayList(u8) = std.ArrayList(u8).empty,
        recv_tmp: [8192]u8 = undefined,
        tls_send_buf: [16384]u8 = undefined,
        deadline: i64 = 0,
        pooled: bool = false,

        const State = enum {
            free,
            dns_resolving,
            connecting,
            tls_handshaking,
            sending,
            receiving,
        };

        fn reset(self: *RequestSlot, allocator: std.mem.Allocator) void {
            if (self.dns_job) |job| {
                job.release();
                self.dns_job = null;
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
            self.fd = -1;
            self.state = .free;
            self.pooled = false;
        }
    };

    const ConnectionPool = struct {
        const max_pooled = 16;
        const max_age_s: i64 = 60;

        entries: [max_pooled]Entry = [_]Entry{.{}} ** max_pooled,

        const Entry = struct {
            host: [253]u8 = undefined,
            host_len: u8 = 0,
            port: u16 = 0,
            fd: posix.fd_t = -1,
            stored_at: i64 = 0,
        };

        fn get(self: *ConnectionPool, host_str: []const u8, port: u16, now: i64) ?posix.fd_t {
            for (&self.entries) |*e| {
                if (e.fd < 0) continue;
                if (now - e.stored_at > max_age_s) {
                    posix.close(e.fd);
                    e.fd = -1;
                    continue;
                }
                if (e.port == port and e.host_len == host_str.len and
                    std.mem.eql(u8, e.host[0..e.host_len], host_str))
                {
                    const fd = e.fd;
                    e.fd = -1;
                    return fd;
                }
            }
            return null;
        }

        fn put(self: *ConnectionPool, host_str: []const u8, port: u16, fd: posix.fd_t, now: i64) void {
            // Find empty slot or evict oldest
            var oldest_idx: usize = 0;
            var oldest_time: i64 = std.math.maxInt(i64);
            for (&self.entries, 0..) |e, i| {
                if (e.fd < 0) {
                    self.storeAt(i, host_str, port, fd, now);
                    return;
                }
                if (e.stored_at < oldest_time) {
                    oldest_time = e.stored_at;
                    oldest_idx = i;
                }
            }
            posix.close(self.entries[oldest_idx].fd);
            self.storeAt(oldest_idx, host_str, port, fd, now);
        }

        fn storeAt(self: *ConnectionPool, idx: usize, host_str: []const u8, port: u16, fd: posix.fd_t, now: i64) void {
            var e = &self.entries[idx];
            e.fd = fd;
            e.port = port;
            e.stored_at = now;
            e.host_len = @intCast(host_str.len);
            @memcpy(e.host[0..host_str.len], host_str);
        }

        fn closeAll(self: *ConnectionPool) void {
            for (&self.entries) |*e| {
                if (e.fd >= 0) {
                    posix.close(e.fd);
                    e.fd = -1;
                }
            }
        }
    };

    // ── Public API ───────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator, ring: *linux.IoUring, config: Config) !*TrackerExecutor {
        const self = try allocator.create(TrackerExecutor);
        errdefer allocator.destroy(self);

        const dns_event_fd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(dns_event_fd);

        self.* = .{
            .allocator = allocator,
            .ring = ring,
            .dns_event_fd = dns_event_fd,
            .pending_jobs = std.ArrayList(Job).empty,
            .deferred_jobs = std.ArrayList(Job).empty,
            .max_concurrent = config.max_concurrent,
            .max_per_host = config.max_per_host,
            .dns_resolver = try DnsResolver.init(allocator),
            .slots = undefined,
            .free_slot_count = config.max_concurrent,
        };
        errdefer self.dns_resolver.deinit(allocator);

        self.slots = try allocator.alloc(RequestSlot, config.max_concurrent);
        errdefer allocator.free(self.slots);
        for (self.slots) |*slot| slot.* = .{};

        // Register DNS eventfd poll on the shared ring
        self.submitDnsPoll();

        return self;
    }

    pub fn destroy(self: *TrackerExecutor) void {
        self.running.store(false, .release);

        // Clean up in-flight slots.
        for (self.slots) |*slot| {
            if (slot.state != .free) {
                if (slot.fd >= 0) posix.close(slot.fd);
                slot.reset(self.allocator);
            }
        }
        self.allocator.free(self.slots);

        self.pool.closeAll();

        var iter = self.host_active.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.host_active.deinit(self.allocator);

        // Ring is shared, not owned
        posix.close(self.dns_event_fd);
        self.dns_resolver.deinit(self.allocator);
        self.pending_jobs.deinit(self.allocator);
        self.deferred_jobs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Submit a tracker HTTP(S) GET request. Thread-safe.
    /// The callback is invoked on the ring thread when the response is ready.
    pub fn submit(self: *TrackerExecutor, job: Job) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (!self.running.load(.acquire)) return error.ExecutorStopped;
        try self.pending_jobs.append(self.allocator, job);
        // No wake_fd needed — the main event loop ticks regularly and
        // calls tick() which drains the job queue.
    }

    // ── Tick (called from event loop) ────────────────────────

    /// Process pending jobs, check timeouts, and start deferred requests.
    /// Called from the main event loop's tick(). DNS completions come via
    /// CQEs on the shared ring (dns_event_fd polled with POLL_ADD).
    pub fn tick(self: *TrackerExecutor) void {
        self.drainJobQueue();
        self.startDeferredJobs();
        self.checkTimeouts();
    }

    fn submitDnsPoll(self: *TrackerExecutor) void {
        const ud = encodeUserData(.{ .slot = sentinel_dns, .op_type = .http_connect, .context = 0 });
        _ = self.ring.poll_add(ud, self.dns_event_fd, linux.POLL.IN) catch {};
    }

    /// Dispatch a CQE from the shared event loop. Called by EventLoop.dispatch().
    pub fn dispatchCqe(self: *TrackerExecutor, cqe: linux.io_uring_cqe) void {
        const op = decodeUserData(cqe.user_data);

        // Sentinel: DNS eventfd
        if (op.slot == sentinel_dns) {
            var buf: [8]u8 = undefined;
            _ = posix.read(self.dns_event_fd, &buf) catch {};
            self.submitDnsPoll();
            self.processDnsCompletions();
            return;
        }

        if (op.slot >= self.slots.len) return;
        const slot = &self.slots[op.slot];

        switch (op.op_type) {
            .http_connect => self.handleConnect(slot, op.slot, cqe),
            .http_send => self.handleSend(slot, op.slot, cqe),
            .http_recv => self.handleRecv(slot, op.slot, cqe),
            else => {},
        }
    }

    // ── Job queue draining ───────────────────────────────────

    fn drainJobQueue(self: *TrackerExecutor) void {
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

    fn startDeferredJobs(self: *TrackerExecutor) void {
        var i: usize = 0;
        while (i < self.deferred_jobs.items.len) {
            if (self.tryStartJob(self.deferred_jobs.items[i])) {
                _ = self.deferred_jobs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn tryStartJob(self: *TrackerExecutor, job: Job) bool {
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
        if (!slot.parsed.is_https) {
            if (self.pool.get(host, slot.parsed.port, now)) |fd| {
                slot.fd = fd;
                slot.pooled = true;
                self.buildAndSendRequest(slot, slot_idx);
                return true;
            }
        }

        // Resolve DNS (async).
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

        return true;
    }

    // ── DNS completion ───────────────────────────────────────

    fn processDnsCompletions(self: *TrackerExecutor) void {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state != .dns_resolving) continue;
            const dns_job = slot.dns_job orelse continue;
            if (!dns_job.isDone()) continue;

            // DNS completed — read result.
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

    // ── Connect ──────────────────────────────────────────────

    fn startConnect(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const family: u32 = slot.address.any.family;
        const fd = posix.socket(family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP) catch {
            self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
            return;
        };
        slot.fd = fd;

        const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_connect, .context = 0 });
        const sqe = self.ring.connect(ud, fd, &slot.address.any, slot.address.getOsSockLen()) catch {
            posix.close(fd);
            slot.fd = -1;
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            return;
        };
        // Link a timeout to the connect.
        sqe.flags |= linux.IOSQE_IO_LINK;
        const ts = linux.kernel_timespec{ .sec = 10, .nsec = 0 };
        _ = self.ring.link_timeout(ud + 1, &ts, 0) catch {};

        slot.state = .connecting;
    }

    fn handleConnect(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        // We may get the link_timeout CQE too — ignore it if slot is no longer connecting.
        if (slot.state != .connecting) return;

        const e = cqe.err();
        if (e != .SUCCESS) {
            // Drain the linked timeout CQE.
            if (e == .CANCELED) {
                self.completeSlot(slot_idx, .{ .err = error.ConnectionTimedOut });
            } else {
                self.completeSlot(slot_idx, .{ .err = blk: {
                    ring_mod.checkCqe(cqe) catch |err| break :blk err;
                    break :blk null;
                } });
            }
            return;
        }

        if (slot.parsed.is_https) {
            self.startTlsHandshake(slot, slot_idx);
        } else {
            self.buildAndSendRequest(slot, slot_idx);
        }
    }

    // ── TLS handshake (async via BIO pairs) ──────────────────

    fn startTlsHandshake(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        if (build_options.tls_backend != .boringssl) {
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

    fn advanceTlsHandshake(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        var tls = &(slot.tls_stream orelse return);

        const result = tls.doHandshake() catch {
            self.completeSlot(slot_idx, .{ .err = error.TlsHandshakeFailed });
            return;
        };

        switch (result) {
            .complete => {
                self.buildRequest(slot);
                // Encrypt the request.
                _ = tls.writePlaintext(slot.send_buf.items) catch {
                    self.completeSlot(slot_idx, .{ .err = error.TlsWriteFailed });
                    return;
                };
                // Extract ciphertext to send.
                self.flushTlsPendingSend(slot, slot_idx);
            },
            .want_write => {
                self.flushTlsPendingSend(slot, slot_idx);
            },
            .want_read => {
                const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_recv, .context = 0 });
                _ = self.ring.recv(ud, slot.fd, .{ .buffer = &slot.recv_tmp }, 0) catch {
                    self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
                };
            },
        }
    }

    fn flushTlsPendingSend(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        var tls = &(slot.tls_stream orelse return);
        const n = tls.pendingSend(&slot.tls_send_buf) catch {
            self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
            return;
        };
        if (n == 0) {
            // Nothing to send — need more data from peer.
            const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_recv, .context = 0 });
            _ = self.ring.recv(ud, slot.fd, .{ .buffer = &slot.recv_tmp }, 0) catch {
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
            return;
        }
        const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_send, .context = 0 });
        _ = self.ring.send(ud, slot.fd, slot.tls_send_buf[0..n], 0) catch {
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
        };
    }


    fn buildRequest(self: *TrackerExecutor, slot: *RequestSlot) void {
        const parsed = slot.parsed;
        slot.send_buf.clearRetainingCapacity();
        const items = &slot.send_buf;
        const alloc = self.allocator;
        items.appendSlice(alloc, "GET ") catch return;
        items.appendSlice(alloc, parsed.path) catch return;
        items.appendSlice(alloc, " HTTP/1.1\r\nHost: ") catch return;
        items.appendSlice(alloc, slot.job.hostSlice()) catch return;
        items.appendSlice(alloc, "\r\nConnection: keep-alive\r\nUser-Agent: varuna/0.1\r\n\r\n") catch return;
    }

    fn buildAndSendRequest(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        self.buildRequest(slot);
        if (slot.send_buf.items.len == 0) {
            self.completeSlot(slot_idx, .{ .err = error.InvalidUrl });
            return;
        }
        slot.send_offset = 0;
        slot.state = .sending;
        self.submitSend(slot, slot_idx);
    }

    fn submitSend(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const remaining = slot.send_buf.items[slot.send_offset..];
        const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_send, .context = 0 });
        _ = self.ring.send(ud, slot.fd, remaining, 0) catch {
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
        };
    }

    fn handleSend(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        const e = cqe.err();
        if (e != .SUCCESS) {
            // If pooled connection was stale, retry with fresh connect.
            if (slot.pooled and slot.state == .sending and slot.send_offset == 0) {
                posix.close(slot.fd);
                slot.fd = -1;
                slot.pooled = false;
                self.startConnect(slot, slot_idx);
                return;
            }
            self.completeSlot(slot_idx, .{ .err = blk: {
                ring_mod.checkCqe(cqe) catch |err| break :blk err;
                break :blk null;
            } });
            return;
        }

        const n: usize = @intCast(cqe.res);
        if (n == 0) {
            self.completeSlot(slot_idx, .{ .err = error.ConnectionClosed });
            return;
        }

        if (slot.state == .tls_handshaking) {
            // TLS handshake send completed — continue handshake.
            self.advanceTlsHandshake(slot, slot_idx);
            return;
        }

        if (slot.parsed.is_https and slot.tls_stream != null) {
            // Encrypted send completed — check if more ciphertext to flush.
            var tls = &(slot.tls_stream orelse return);
            const pending = tls.pendingSend(&slot.tls_send_buf) catch {
                self.completeSlot(slot_idx, .{ .err = error.TlsReadFailed });
                return;
            };
            if (pending > 0) {
                const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_send, .context = 0 });
                _ = self.ring.send(ud, slot.fd, slot.tls_send_buf[0..pending], 0) catch {
                    self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
                };
                return;
            }
            // All ciphertext sent — start receiving.
            slot.state = .receiving;
            self.submitRecv(slot, slot_idx);
            return;
        }

        // Plain HTTP: track partial sends.
        slot.send_offset += n;
        if (slot.send_offset < slot.send_buf.items.len) {
            self.submitSend(slot, slot_idx);
            return;
        }

        // All sent — start receiving.
        slot.state = .receiving;
        self.submitRecv(slot, slot_idx);
    }

    // ── HTTP response receiving ──────────────────────────────

    fn submitRecv(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const ud = encodeUserData(.{ .slot = slot_idx, .op_type = .http_recv, .context = 0 });
        _ = self.ring.recv(ud, slot.fd, .{ .buffer = &slot.recv_tmp }, 0) catch {
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
        };
    }

    fn handleRecv(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        const e = cqe.err();
        if (e != .SUCCESS) {
            self.completeSlot(slot_idx, .{ .err = blk: {
                ring_mod.checkCqe(cqe) catch |err| break :blk err;
                break :blk null;
            } });
            return;
        }

        const n: usize = @intCast(cqe.res);

        // During TLS handshake, feed received ciphertext to BoringSSL.
        if (slot.state == .tls_handshaking) {
            if (n == 0) {
                self.completeSlot(slot_idx, .{ .err = error.TlsHandshakeFailed });
                return;
            }
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
                slot.recv_buf.appendSlice(self.allocator, plaintext_buf[0..pn]) catch {
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

        slot.recv_buf.appendSlice(self.allocator, slot.recv_tmp[0..n]) catch {
            self.completeSlot(slot_idx, .{ .err = error.OutOfMemory });
            return;
        };

        if (self.isResponseComplete(slot)) {
            self.finishResponse(slot, slot_idx);
        } else {
            self.submitRecv(slot, slot_idx);
        }
    }

    fn isResponseComplete(_: *TrackerExecutor, slot: *RequestSlot) bool {
        const data = slot.recv_buf.items;
        const body_start = http.findBodyStart(data) orelse return false;
        if (http.parseContentLength(data[0..body_start])) |cl| {
            return data.len >= body_start + cl;
        }
        // No Content-Length — check for Connection: close pattern (wait for EOF).
        return false;
    }

    fn tryCompleteResponse(self: *TrackerExecutor, slot: *RequestSlot, eof: bool) void {
        const slot_idx = self.slotIndex(slot);
        if (eof or self.isResponseComplete(slot)) {
            self.finishResponse(slot, slot_idx);
        } else {
            self.completeSlot(slot_idx, .{ .err = error.UnexpectedEndOfStream });
        }
    }

    fn finishResponse(self: *TrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const data = slot.recv_buf.items;
        const status = http.parseStatusCode(data) orelse 0;
        const body_start = http.findBodyStart(data);

        const body = if (body_start) |bs|
            if (bs < data.len) data[bs..] else null
        else
            null;

        // Check if connection is reusable BEFORE completing (which frees the slot).
        const reusable = if (body_start) |bs|
            !http.parseConnectionClose(data[0..bs]) and
                http.parseContentLength(data[0..bs]) != null
        else
            false;

        // Return connection to pool before completing the slot.
        if (reusable and !slot.parsed.is_https and slot.fd >= 0) {
            self.pool.put(
                slot.job.hostSlice(),
                slot.parsed.port,
                slot.fd,
                std.time.timestamp(),
            );
            slot.fd = -1; // Prevent close in completeSlot.
        }

        self.completeSlot(slot_idx, .{ .status = status, .body = body });
    }

    // ── Timeout checking ─────────────────────────────────────

    fn checkTimeouts(self: *TrackerExecutor) void {
        const now = std.time.timestamp();
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .free) continue;
            if (now >= slot.deadline) {
                self.completeSlot(@intCast(i), .{ .err = error.RequestTimedOut });
            }
        }
    }

    // ── Slot management ──────────────────────────────────────

    fn claimSlot(self: *TrackerExecutor) ?u16 {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .free) return @intCast(i);
        }
        return null;
    }

    fn slotIndex(self: *TrackerExecutor, slot: *RequestSlot) u16 {
        const base = @intFromPtr(self.slots.ptr);
        const ptr = @intFromPtr(slot);
        return @intCast((ptr - base) / @sizeOf(RequestSlot));
    }

    fn completeSlot(self: *TrackerExecutor, slot_idx: u16, result: RequestResult) void {
        const slot = &self.slots[slot_idx];
        if (slot.state == .free) return;

        const host = slot.job.hostSlice();
        const job = slot.job;

        // Copy the body before reset, because result.body references
        // slot.recv_buf which reset() frees.
        var owned_body: ?[]u8 = null;
        defer if (owned_body) |b| self.allocator.free(b);
        var result_copy = result;
        if (result.body) |body| {
            owned_body = self.allocator.dupe(u8, body) catch null;
            result_copy.body = owned_body;
        }

        // Close fd if not returned to pool.
        if (slot.fd >= 0) {
            posix.close(slot.fd);
        }
        slot.reset(self.allocator);

        self.active_count -= 1;
        self.decrementHostActive(host);

        // Invoke callback with the owned copy.
        job.on_complete(job.context, result_copy);
    }

    fn incrementHostActive(self: *TrackerExecutor, host: []const u8) void {
        if (self.host_active.getPtr(host)) |count| {
            count.* += 1;
        } else {
            const owned = self.allocator.dupe(u8, host) catch return;
            self.host_active.put(self.allocator, owned, 1) catch {
                self.allocator.free(owned);
            };
        }
    }

    fn decrementHostActive(self: *TrackerExecutor, host: []const u8) void {
        if (self.host_active.getPtr(host)) |count| {
            count.* -= 1;
            if (count.* == 0) {
                if (self.host_active.fetchRemove(host)) |kv| {
                    self.allocator.free(kv.key);
                }
            }
        }
    }
};

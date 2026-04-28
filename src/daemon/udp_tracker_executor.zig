const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const udp = @import("../tracker/udp.zig");
const dns_mod = @import("../io/dns.zig");
const DnsResolver = dns_mod.DnsResolver;
const DnsJob = @import("../io/dns_threadpool.zig").DnsJob;

const io_interface = @import("../io/io_interface.zig");
const backend = @import("../io/backend.zig");
const RealIO = backend.RealIO;

const log = std.log.scoped(.udp_tracker_executor);

/// Async io_uring-based UDP tracker executor (BEP 15).
///
/// Multiplexes multiple UDP tracker requests on a single io_uring ring.
/// Each request goes through the BEP 15 state machine:
///   idle -> dns_resolving -> connecting -> announcing/scraping -> done
///
/// Connection IDs are cached per tracker host with a 2-minute TTL.
/// Retransmissions use BEP 15 exponential backoff (15 * 2^n seconds).
///
/// Runs on the event loop thread. DNS is offloaded to background threads
/// (via DnsResolver). All network I/O uses IORING_OP_SENDMSG / RECVMSG.
pub const UdpTrackerExecutor = struct {
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    io: *RealIO,
    dns_event_fd: posix.fd_t,
    dns_poll_completion: io_interface.Completion = .{},

    // Thread-safe job queue (producer: any thread, consumer: ring thread).
    queue_mutex: std.Thread.Mutex = .{},
    pending_jobs: std.ArrayList(Job),

    // Request slots (ring-thread only).
    slots: []RequestSlot,
    max_slots: u16,

    // Connection ID cache (BEP 15: valid for ~2 minutes).
    conn_cache: udp.ConnectionCache = .{},

    dns_resolver: DnsResolver,

    const max_response_size: usize = udp.max_response_size;

    pub const CompletionFn = *const fn (context: *anyopaque, result: RequestResult) void;

    pub const RequestResult = struct {
        body: ?[]const u8 = null,
        body_len: usize = 0,
        err: ?anyerror = null,
    };

    pub const JobKind = enum {
        announce,
        scrape,
    };

    pub const Job = struct {
        context: *anyopaque,
        on_complete: CompletionFn,
        kind: JobKind = .announce,
        host: [max_host_len]u8 = undefined,
        host_len: u8 = 0,
        port: u16 = 0,

        // Announce fields
        info_hash: [20]u8 = undefined,
        peer_id: [20]u8 = undefined,
        downloaded: u64 = 0,
        left: u64 = 0,
        uploaded: u64 = 0,
        event: udp.UdpEvent = .none,
        key: u32 = 0,
        num_want: i32 = -1,
        listen_port: u16 = 0,

        const max_host_len = 253;

        pub fn hostSlice(self: *const Job) []const u8 {
            return self.host[0..self.host_len];
        }
    };

    pub const Config = struct {
        max_slots: u16 = 8,
    };

    const RequestSlot = struct {
        state: State = .free,
        fd: posix.fd_t = -1,
        job: Job = undefined,
        address: std.net.Address = undefined,
        dns_job: ?*DnsJob = null,

        // Transaction IDs for connect and announce/scrape phases
        connect_txid: u32 = 0,
        request_txid: u32 = 0,
        connection_id: u64 = 0,

        // Retransmission tracking
        attempt: u32 = 0,
        last_send_time: i64 = 0,

        // Send/recv buffers (persistent, owned by slot)
        send_buf: [98]u8 = undefined, // max packet size (announce request)
        send_len: usize = 0,
        recv_buf: [max_response_size]u8 = undefined,
        recv_len: usize = 0,

        // msghdr structures for io_uring sendmsg/recvmsg
        send_iov: [1]posix.iovec_const = undefined,
        send_msg: posix.msghdr_const = undefined,
        send_addr: std.net.Address = undefined,

        recv_iov: [1]posix.iovec = undefined,
        recv_msg: posix.msghdr = undefined,
        recv_addr: std.net.Address = undefined,

        // Deadline for the overall request
        deadline: i64 = 0,

        /// Caller-owned completion for the slot's in-flight io op.
        /// One op at a time per slot (socket → send → recv loop).
        completion: io_interface.Completion = .{},

        const State = enum {
            free,
            dns_resolving,
            connecting, // BEP 15 connect handshake
            announcing, // BEP 15 announce
            scraping, // BEP 15 scrape
        };

        fn reset(self: *RequestSlot) void {
            if (self.dns_job) |job| {
                job.release();
                self.dns_job = null;
            }
            if (self.fd >= 0) {
                posix.close(self.fd);
                self.fd = -1;
            }
            self.state = .free;
            self.attempt = 0;
        }
    };

    // ── Public API ───────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator, io: *RealIO, config: Config) !*UdpTrackerExecutor {
        const self = try allocator.create(UdpTrackerExecutor);
        errdefer allocator.destroy(self);

        const dns_event_fd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(dns_event_fd);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .dns_event_fd = dns_event_fd,
            .pending_jobs = std.ArrayList(Job).empty,
            .max_slots = config.max_slots,
            .dns_resolver = try DnsResolver.init(allocator),
            .slots = undefined,
        };
        errdefer self.dns_resolver.deinit(allocator);

        self.slots = try allocator.alloc(RequestSlot, config.max_slots);
        errdefer allocator.free(self.slots);
        for (self.slots) |*slot| slot.* = .{};

        // Register DNS eventfd poll on the shared ring
        self.submitDnsPoll();

        return self;
    }

    pub fn destroy(self: *UdpTrackerExecutor) void {
        self.running.store(false, .release);

        for (self.slots) |*slot| {
            if (slot.state != .free) {
                slot.reset();
            }
        }
        self.allocator.free(self.slots);

        posix.close(self.dns_event_fd);
        self.dns_resolver.deinit(self.allocator);
        self.pending_jobs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Submit a UDP tracker request. Thread-safe.
    pub fn submit(self: *UdpTrackerExecutor, job: Job) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (!self.running.load(.acquire)) return error.ExecutorStopped;
        try self.pending_jobs.append(self.allocator, job);
    }

    // ── Tick (called from event loop) ────────────────────────

    pub fn tick(self: *UdpTrackerExecutor) void {
        self.drainJobQueue();
        self.checkTimeoutsAndRetransmit();
    }

    fn submitDnsPoll(self: *UdpTrackerExecutor) void {
        self.io.poll(
            .{ .fd = self.dns_event_fd, .events = linux.POLL.IN },
            &self.dns_poll_completion,
            self,
            udpDnsPollComplete,
        ) catch {};
    }

    fn udpDnsPollComplete(
        userdata: ?*anyopaque,
        _: *io_interface.Completion,
        _: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *UdpTrackerExecutor = @ptrCast(@alignCast(userdata.?));
        var buf: [8]u8 = undefined;
        _ = posix.read(self.dns_event_fd, &buf) catch {};
        self.processDnsCompletions();
        return .rearm;
    }

    fn slotIdxFor(self: *const UdpTrackerExecutor, slot: *const RequestSlot) u16 {
        const offset = @intFromPtr(slot) - @intFromPtr(self.slots.ptr);
        return @intCast(offset / @sizeOf(RequestSlot));
    }

    fn udpSocketComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *UdpTrackerExecutor = @ptrCast(@alignCast(userdata.?));
        const slot: *RequestSlot = @fieldParentPtr("completion", completion);
        const slot_idx = self.slotIdxFor(slot);
        const fake_cqe = makeFakeCqe(switch (result) {
            .socket => |r| if (r) |fd| @intCast(fd) else |_| -1,
            else => -1,
        });
        self.handleSocketCreated(slot, slot_idx, fake_cqe);
        return .disarm;
    }

    fn udpSendComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *UdpTrackerExecutor = @ptrCast(@alignCast(userdata.?));
        const slot: *RequestSlot = @fieldParentPtr("completion", completion);
        const slot_idx = self.slotIdxFor(slot);
        const fake_cqe = makeFakeCqe(switch (result) {
            .sendmsg => |r| if (r) |n|
                std.math.cast(i32, n) orelse std.math.maxInt(i32)
            else |_|
                -1,
            else => -1,
        });
        self.handleSend(slot, slot_idx, fake_cqe);
        return .disarm;
    }

    fn udpRecvComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *UdpTrackerExecutor = @ptrCast(@alignCast(userdata.?));
        const slot: *RequestSlot = @fieldParentPtr("completion", completion);
        const slot_idx = self.slotIdxFor(slot);
        const fake_cqe = makeFakeCqe(switch (result) {
            .recvmsg => |r| if (r) |n|
                std.math.cast(i32, n) orelse std.math.maxInt(i32)
            else |_|
                -1,
            else => -1,
        });
        self.handleRecv(slot, slot_idx, fake_cqe);
        return .disarm;
    }

    /// Build a synthetic `linux.io_uring_cqe` so the existing handle*
    /// bodies (which still read `cqe.res`) can stay unchanged.
    fn makeFakeCqe(res: i32) linux.io_uring_cqe {
        return .{ .user_data = 0, .res = res, .flags = 0 };
    }

    // ── Job queue draining ───────────────────────────────────

    fn drainJobQueue(self: *UdpTrackerExecutor) void {
        self.queue_mutex.lock();
        var jobs = self.pending_jobs;
        self.pending_jobs = std.ArrayList(Job).empty;
        self.queue_mutex.unlock();

        defer jobs.deinit(self.allocator);

        for (jobs.items) |job| {
            self.tryStartJob(job);
        }
    }

    fn tryStartJob(self: *UdpTrackerExecutor, job: Job) void {
        const slot_idx = self.claimSlot() orelse {
            // No free slots -- complete with error immediately
            job.on_complete(job.context, .{ .err = error.TooManyRequests });
            return;
        };
        const slot = &self.slots[slot_idx];

        slot.job = job;
        slot.deadline = std.time.timestamp() + 120; // 2 minute overall deadline
        slot.attempt = 0;

        // Resolve DNS (async)
        const host = job.hostSlice();
        const result = self.dns_resolver.resolveAsync(
            host,
            job.port,
            self.dns_event_fd,
        ) catch {
            self.completeSlot(slot_idx, .{ .err = error.DnsResolutionFailed });
            return;
        };

        switch (result) {
            .resolved => |addr| {
                slot.address = addr;
                self.startUdpRequest(slot, slot_idx);
            },
            .pending => |dns_job| {
                slot.dns_job = dns_job;
                slot.state = .dns_resolving;
            },
        }
    }

    // ── DNS completion ───────────────────────────────────────

    fn processDnsCompletions(self: *UdpTrackerExecutor) void {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state != .dns_resolving) continue;
            const dns_job = slot.dns_job orelse continue;
            if (!dns_job.isDone()) continue;

            if (dns_job.err) |err| {
                self.completeSlot(@intCast(i), .{ .err = err });
                continue;
            }

            if (dns_job.address) |addr| {
                slot.address = addr;
                self.dns_resolver.cacheResult(
                    self.allocator,
                    slot.job.hostSlice(),
                    addr,
                );
                dns_job.release();
                slot.dns_job = null;
                self.startUdpRequest(slot, @intCast(i));
            } else {
                self.completeSlot(@intCast(i), .{ .err = error.DnsResolutionFailed });
            }
        }
    }

    // ── UDP request flow ─────────────────────────────────────

    fn startUdpRequest(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        // Submit async socket creation via io_interface — udpSocketComplete
        // will set the destination and start the BEP 15 flow.
        const family: u32 = slot.address.any.family;
        self.io.socket(
            .{ .domain = family, .sock_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, .protocol = posix.IPPROTO.UDP },
            &slot.completion,
            self,
            udpSocketComplete,
        ) catch {
            self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
            return;
        };
        slot.state = .connecting;
    }

    /// Handle async UDP socket creation CQE — set destination and start BEP 15 flow.
    fn handleSocketCreated(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
            return;
        }

        const fd: posix.fd_t = @intCast(cqe.res);
        slot.fd = fd;

        // Connect the UDP socket so we can use send/recv instead of sendto/recvfrom.
        // UDP connect just sets the destination address — no network I/O, always instant.
        posix.connect(fd, &slot.address.any, slot.address.getOsSockLen()) catch {
            self.completeSlot(slot_idx, .{ .err = error.ConnectionRefused });
            return;
        };

        // Check connection ID cache
        if (self.conn_cache.get(slot.job.hostSlice(), slot.job.port)) |conn_id| {
            slot.connection_id = conn_id;
            switch (slot.job.kind) {
                .announce => self.startAnnounce(slot, slot_idx),
                .scrape => self.startScrape(slot, slot_idx),
            }
        } else {
            self.startConnect(slot, slot_idx);
        }
    }

    fn startConnect(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        slot.state = .connecting;
        slot.connect_txid = udp.generateTransactionId();
        slot.last_send_time = std.time.timestamp();

        const pkt = udp.ConnectRequest{ .transaction_id = slot.connect_txid };
        const encoded = pkt.encode();
        @memcpy(slot.send_buf[0..16], &encoded);
        slot.send_len = 16;

        self.submitSendmsg(slot, slot_idx);
        self.submitRecvmsg(slot, slot_idx);
    }

    fn startAnnounce(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        slot.state = .announcing;
        slot.request_txid = udp.generateTransactionId();
        slot.last_send_time = std.time.timestamp();

        const req = udp.AnnounceRequest{
            .connection_id = slot.connection_id,
            .transaction_id = slot.request_txid,
            .info_hash = slot.job.info_hash,
            .peer_id = slot.job.peer_id,
            .downloaded = slot.job.downloaded,
            .left = slot.job.left,
            .uploaded = slot.job.uploaded,
            .event = slot.job.event,
            .ip = 0,
            .key = slot.job.key,
            .num_want = slot.job.num_want,
            .port = slot.job.listen_port,
        };
        const encoded = req.encode();
        @memcpy(slot.send_buf[0..98], &encoded);
        slot.send_len = 98;

        self.submitSendmsg(slot, slot_idx);
        self.submitRecvmsg(slot, slot_idx);
    }

    fn startScrape(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        slot.state = .scraping;
        slot.request_txid = udp.generateTransactionId();
        slot.last_send_time = std.time.timestamp();

        const encoded = udp.ScrapeRequest.encodeSingle(
            slot.connection_id,
            slot.request_txid,
            slot.job.info_hash,
        );
        @memcpy(slot.send_buf[0..36], &encoded);
        slot.send_len = 36;

        self.submitSendmsg(slot, slot_idx);
        self.submitRecvmsg(slot, slot_idx);
    }

    // ── io_uring sendmsg/recvmsg ─────────────────────────────

    fn submitSendmsg(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        slot.send_addr = slot.address;
        slot.send_iov[0] = .{
            .base = @ptrCast(&slot.send_buf),
            .len = slot.send_len,
        };
        slot.send_msg = .{
            .name = @ptrCast(&slot.send_addr),
            .namelen = slot.send_addr.getOsSockLen(),
            .iov = @ptrCast(&slot.send_iov),
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        self.io.sendmsg(
            .{ .fd = slot.fd, .msg = &slot.send_msg },
            &slot.completion,
            self,
            udpSendComplete,
        ) catch {
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
        };
    }

    fn submitRecvmsg(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        slot.recv_addr = std.mem.zeroes(std.net.Address);
        slot.recv_iov[0] = .{
            .base = @ptrCast(&slot.recv_buf),
            .len = slot.recv_buf.len,
        };
        slot.recv_msg = .{
            .name = @ptrCast(&slot.recv_addr),
            .namelen = @sizeOf(std.net.Address),
            .iov = &slot.recv_iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        self.io.recvmsg(
            .{ .fd = slot.fd, .msg = &slot.recv_msg },
            &slot.completion,
            self,
            udpRecvComplete,
        ) catch {
            self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
        };
    }

    // ── CQE handlers ─────────────────────────────────────────

    fn handleSend(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        _ = self;
        _ = slot;
        _ = slot_idx;
        // For UDP, send completion just means the datagram was queued.
        // Errors are rare but possible.
        if (cqe.res < 0) {
            log.debug("UDP tracker sendmsg failed: errno={d}", .{-cqe.res});
            // Don't complete yet -- the retransmission timer will handle it
        }
    }

    fn handleRecv(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
        if (cqe.res < 0) {
            // Recv failed -- could be a timeout or connection error
            log.debug("UDP tracker recvmsg failed: errno={d}", .{-cqe.res});
            // Let the timeout handler deal with retransmission
            return;
        }

        const n: usize = @intCast(cqe.res);
        if (n < 8) {
            // Too short for any valid response
            self.submitRecvmsg(slot, slot_idx);
            return;
        }

        slot.recv_len = n;

        // Check for error response
        if (udp.isErrorResponse(slot.recv_buf[0..n])) {
            const msg = udp.parseErrorMessage(slot.recv_buf[0..n]);
            if (msg) |m| log.warn("UDP tracker error from {s}:{d}: {s}", .{ slot.job.hostSlice(), slot.job.port, m });

            // If we were using a cached connection ID for announce/scrape,
            // the ID may be stale. Invalidate and retry with fresh connect.
            if (slot.state == .announcing or slot.state == .scraping) {
                self.conn_cache.invalidate(slot.job.hostSlice(), slot.job.port);
                slot.attempt = 0;
                self.startConnect(slot, slot_idx);
                return;
            }
            self.completeSlot(slot_idx, .{ .err = error.TrackerError });
            return;
        }

        switch (slot.state) {
            .connecting => self.handleConnectResponse(slot, slot_idx),
            .announcing => self.handleAnnounceResponse(slot, slot_idx),
            .scraping => self.handleScrapeResponse(slot, slot_idx),
            else => {},
        }
    }

    fn handleConnectResponse(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const resp = udp.ConnectResponse.decode(slot.recv_buf[0..slot.recv_len]) catch {
            // Invalid response -- wait for retransmission
            self.submitRecvmsg(slot, slot_idx);
            return;
        };

        if (resp.transaction_id != slot.connect_txid) {
            // Stale response from a previous request -- ignore
            self.submitRecvmsg(slot, slot_idx);
            return;
        }

        // Cache the connection ID
        slot.connection_id = resp.connection_id;
        self.conn_cache.put(slot.job.hostSlice(), slot.job.port, resp.connection_id);

        // Proceed to announce or scrape
        slot.attempt = 0;
        switch (slot.job.kind) {
            .announce => self.startAnnounce(slot, slot_idx),
            .scrape => self.startScrape(slot, slot_idx),
        }
    }

    fn handleAnnounceResponse(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const resp = udp.AnnounceResponse.decode(slot.recv_buf[0..slot.recv_len]) catch {
            self.submitRecvmsg(slot, slot_idx);
            return;
        };

        if (resp.transaction_id != slot.request_txid) {
            self.submitRecvmsg(slot, slot_idx);
            return;
        }

        // Deliver the raw response body to the caller
        self.completeSlot(slot_idx, .{
            .body = slot.recv_buf[0..slot.recv_len],
            .body_len = slot.recv_len,
        });
    }

    fn handleScrapeResponse(self: *UdpTrackerExecutor, slot: *RequestSlot, slot_idx: u16) void {
        const header = udp.ScrapeResponse.decodeHeader(slot.recv_buf[0..slot.recv_len]) catch {
            self.submitRecvmsg(slot, slot_idx);
            return;
        };

        if (header.transaction_id != slot.request_txid) {
            self.submitRecvmsg(slot, slot_idx);
            return;
        }

        self.completeSlot(slot_idx, .{
            .body = slot.recv_buf[0..slot.recv_len],
            .body_len = slot.recv_len,
        });
    }

    // ── Timeout and retransmission ───────────────────────────

    fn checkTimeoutsAndRetransmit(self: *UdpTrackerExecutor) void {
        const now = std.time.timestamp();
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .free or slot.state == .dns_resolving) continue;

            // Check overall deadline
            if (now >= slot.deadline) {
                // Tracker did not respond within the overall deadline:
                // BEP 15 has no separate "connect error" surface, so the
                // analog of TCP's ConnectionTimedOut is "we sent
                // datagrams to the resolved IP and nothing came back."
                // Drop the cache entry so the next announce re-resolves.
                self.dns_resolver.invalidate(self.allocator, slot.job.hostSlice());
                self.completeSlot(@intCast(i), .{ .err = error.TrackerTimeout });
                continue;
            }

            // Check retransmission timeout
            const timeout_secs: i64 = @intCast(udp.retransmitTimeout(slot.attempt));
            if (now - slot.last_send_time >= timeout_secs) {
                slot.attempt += 1;
                if (slot.attempt > udp.max_retries) {
                    // Same rationale as the deadline branch above: full
                    // BEP 15 exponential backoff exhausted with no
                    // response — the IP looks dead.
                    self.dns_resolver.invalidate(self.allocator, slot.job.hostSlice());
                    self.completeSlot(@intCast(i), .{ .err = error.TrackerTimeout });
                    continue;
                }

                // Retransmit
                slot.last_send_time = now;
                log.debug("UDP tracker retransmit attempt {d} for {s}:{d}", .{
                    slot.attempt, slot.job.hostSlice(), slot.job.port,
                });
                self.submitSendmsg(slot, @intCast(i));
            }
        }
    }

    // ── Slot management ──────────────────────────────────────

    fn claimSlot(self: *UdpTrackerExecutor) ?u16 {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .free) return @intCast(i);
        }
        return null;
    }

    fn completeSlot(self: *UdpTrackerExecutor, slot_idx: u16, result: RequestResult) void {
        const slot = &self.slots[slot_idx];
        if (slot.state == .free) return;

        const job = slot.job;
        slot.reset();

        // Invoke callback
        job.on_complete(job.context, result);
    }
};

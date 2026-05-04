const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const udp = @import("udp.zig");
const dns_mod = @import("../io/dns.zig");
const ThreadpoolDnsJob = @import("../io/dns_threadpool.zig").DnsJob;
const Random = @import("../runtime/random.zig").Random;
const build_options = @import("build_options");

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
///
/// Daemon callers continue to write `UdpTrackerExecutor` (the
/// `UdpTrackerExecutorOf(RealIO)` alias declared below). Sim tests
/// instantiate `UdpTrackerExecutorOf(SimIO)` directly so the same state
/// machine drives against `EventLoopOf(SimIO)`.
pub fn UdpTrackerExecutorOf(comptime IO: type) type {
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
        /// Daemon-wide CSPRNG. Borrowed (not owned) — typically points
        /// into the shared `EventLoop.random`. Drives transaction-id
        /// generation. Same source for production and sim.
        random: *Random,
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
        retired_dns_jobs: RetiredDnsJobs,
        custom_dns_pending: usize = 0,
        custom_destroy_completion: io_interface.Completion = .{},

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
            address: std.net.Address = undefined,
            dns_job: ?*DnsJob = null,
            dns_ctx: ?*CustomDnsContext = null,
            generation: u32 = 0,

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

            recv_iov: [1]posix.iovec = undefined,
            recv_msg: posix.msghdr = undefined,
            recv_addr: std.net.Address = undefined,

            // Deadline for the overall request
            deadline: i64 = 0,

            socket_completion: io_interface.Completion = .{},
            connect_completion: io_interface.Completion = .{},
            send_completion: io_interface.Completion = .{},
            recv_completion: io_interface.Completion = .{},

            socket_in_flight: bool = false,
            connect_in_flight: bool = false,
            send_in_flight: bool = false,
            recv_in_flight: bool = false,
            closing: bool = false,
            completed: bool = false,

            const State = enum {
                free,
                dns_resolving,
                connecting, // BEP 15 connect handshake
                announcing, // BEP 15 announce
                scraping, // BEP 15 scrape
            };

            fn reset(self: *RequestSlot) void {
                if (comptime use_custom_dns) {
                    self.dns_job = null;
                    self.dns_ctx = null;
                } else {
                    if (self.dns_job) |job| {
                        job.release();
                        self.dns_job = null;
                    }
                }
                const next_generation = self.generation +% 1;
                self.* = .{};
                self.generation = next_generation;
            }
        };

        // ── Public API ───────────────────────────────────────────

        pub fn create(allocator: std.mem.Allocator, io: *IO, random: *Random, config: Config) !*Self {
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
                .random = random,
                .dns_event_fd = dns_event_fd,
                .pending_jobs = std.ArrayList(Job).empty,
                .max_slots = config.max_slots,
                .dns_resolver = try initDnsResolver(allocator, io, config),
                .retired_dns_jobs = if (use_custom_dns) std.ArrayList(*DnsJob).empty else {},
                .slots = undefined,
            };
            errdefer self.dns_resolver.deinit(allocator);

            self.slots = try allocator.alloc(RequestSlot, config.max_slots);
            errdefer allocator.free(self.slots);
            for (self.slots) |*slot| slot.* = .{};

            // Register DNS eventfd poll for the threadpool-compatible facade.
            // Custom DNS resolves through IO-backed callbacks directly.
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

            for (self.slots) |*slot| {
                if (slot.state != .free) {
                    if (slot.fd >= 0) {
                        const fd = slot.fd;
                        slot.fd = -1;
                        self.io.closeSocket(fd);
                    }
                    self.detachDnsJob(slot, true);
                    slot.reset();
                }
            }
            self.allocator.free(self.slots);

            if (self.dns_event_fd >= 0) posix.close(self.dns_event_fd);
            self.dns_resolver.deinit(self.allocator);
            self.reapRetiredDnsJobs();
            if (comptime use_custom_dns) self.retired_dns_jobs.deinit(self.allocator);
            self.pending_jobs.deinit(self.allocator);
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

        /// Submit a UDP tracker request. Thread-safe.
        pub fn submit(self: *Self, job: Job) !void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (!self.running.load(.acquire)) return error.ExecutorStopped;
            try self.pending_jobs.append(self.allocator, job);
        }

        // ── Tick (called from event loop) ────────────────────────

        pub fn tick(self: *Self) void {
            self.reapRetiredDnsJobs();
            self.drainJobQueue();
            self.checkTimeoutsAndRetransmit();
        }

        fn submitDnsPoll(self: *Self) void {
            if (comptime use_custom_dns) return;
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
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            var buf: [8]u8 = undefined;
            _ = posix.read(self.dns_event_fd, &buf) catch {};
            self.processDnsCompletions();
            return .rearm;
        }

        fn slotIdxFor(self: *const Self, slot: *const RequestSlot) u16 {
            const offset = @intFromPtr(slot) - @intFromPtr(self.slots.ptr);
            return @intCast(offset / @sizeOf(RequestSlot));
        }

        fn udpSocketComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("socket_completion", completion);
            slot.socket_in_flight = false;
            const slot_idx = self.slotIdxFor(slot);
            if (slot.closing or slot.completed or slot.state == .free) {
                self.tryResetSlot(slot_idx);
                return .disarm;
            }
            const fake_cqe = makeFakeCqe(switch (result) {
                .socket => |r| if (r) |fd| @intCast(fd) else |_| -1,
                else => -1,
            });
            self.handleSocketCreated(slot, slot_idx, fake_cqe);
            return .disarm;
        }

        fn udpConnectComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("connect_completion", completion);
            slot.connect_in_flight = false;
            const slot_idx = self.slotIdxFor(slot);
            if (slot.closing or slot.completed or slot.state == .free) {
                self.tryResetSlot(slot_idx);
                return .disarm;
            }
            const ok = switch (result) {
                .connect => |r| if (r) |_| true else |_| false,
                else => false,
            };
            if (!ok) {
                self.completeSlot(slot_idx, .{ .err = error.ConnectionRefused });
                return .disarm;
            }
            self.handleSocketConnected(slot, slot_idx);
            return .disarm;
        }

        fn udpSendComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("send_completion", completion);
            slot.send_in_flight = false;
            const slot_idx = self.slotIdxFor(slot);
            if (slot.closing or slot.completed or slot.state == .free) {
                self.tryResetSlot(slot_idx);
                return .disarm;
            }
            const send_result: anyerror!usize = switch (result) {
                .sendmsg => |r| r,
                else => error.UnexpectedCompletion,
            };
            self.handleSend(slot, slot_idx, send_result);
            return .disarm;
        }

        fn udpRecvComplete(
            userdata: ?*anyopaque,
            completion: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const slot: *RequestSlot = @fieldParentPtr("recv_completion", completion);
            slot.recv_in_flight = false;
            const slot_idx = self.slotIdxFor(slot);
            if (slot.closing or slot.completed or slot.state == .free) {
                self.tryResetSlot(slot_idx);
                return .disarm;
            }
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

        fn drainJobQueue(self: *Self) void {
            self.queue_mutex.lock();
            var jobs = self.pending_jobs;
            self.pending_jobs = std.ArrayList(Job).empty;
            self.queue_mutex.unlock();

            defer jobs.deinit(self.allocator);

            for (jobs.items) |job| {
                self.tryStartJob(job);
            }
        }

        fn tryStartJob(self: *Self, job: Job) void {
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
            if (comptime use_custom_dns) {
                self.startCustomDnsResolve(slot, slot_idx, host);
            } else {
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
                slot.job.port,
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
                    self.startUdpRequest(slot, slot_idx);
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
                    self.startUdpRequest(slot, ctx.slot_idx);
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
                    std.log.scoped(.udp_tracker_executor).warn(
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

        // ── UDP request flow ─────────────────────────────────────

        fn startUdpRequest(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            // Submit async socket creation via io_interface — udpSocketComplete
            // will set the destination and start the BEP 15 flow.
            const family: u32 = slot.address.any.family;
            slot.state = .connecting;
            slot.socket_in_flight = true;
            self.io.socket(
                .{ .domain = family, .sock_type = posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, .protocol = posix.IPPROTO.UDP },
                &slot.socket_completion,
                self,
                udpSocketComplete,
            ) catch {
                slot.socket_in_flight = false;
                self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
                return;
            };
        }

        /// Handle async UDP socket creation CQE — set destination and start BEP 15 flow.
        fn handleSocketCreated(self: *Self, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
            if (cqe.res < 0) {
                self.completeSlot(slot_idx, .{ .err = error.SocketCreateFailed });
                return;
            }

            const fd: posix.fd_t = @intCast(cqe.res);
            slot.fd = fd;

            // UDP connect just sets the destination address, but route it through
            // the IO contract so alternate backends and SimIO see the same shape.
            slot.connect_in_flight = true;
            self.io.connect(
                .{ .fd = fd, .addr = slot.address },
                &slot.connect_completion,
                self,
                udpConnectComplete,
            ) catch {
                slot.connect_in_flight = false;
                self.completeSlot(slot_idx, .{ .err = error.ConnectionRefused });
                return;
            };
        }

        fn handleSocketConnected(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
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

        fn startConnect(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            slot.state = .connecting;
            slot.connect_txid = udp.generateTransactionId(self.random);
            slot.last_send_time = std.time.timestamp();

            const pkt = udp.ConnectRequest{ .transaction_id = slot.connect_txid };
            const encoded = pkt.encode();
            @memcpy(slot.send_buf[0..16], &encoded);
            slot.send_len = 16;

            self.submitSendmsg(slot, slot_idx);
            self.submitRecvmsg(slot, slot_idx);
        }

        fn startAnnounce(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            slot.state = .announcing;
            slot.request_txid = udp.generateTransactionId(self.random);
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

        fn startScrape(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            slot.state = .scraping;
            slot.request_txid = udp.generateTransactionId(self.random);
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

        fn submitSendmsg(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            if (slot.send_in_flight or slot.closing or slot.completed) return;
            slot.send_iov[0] = .{
                .base = @ptrCast(&slot.send_buf),
                .len = slot.send_len,
            };
            slot.send_msg = .{
                .name = null,
                .namelen = 0,
                .iov = @ptrCast(&slot.send_iov),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };

            slot.send_in_flight = true;
            self.io.sendmsg(
                .{ .fd = slot.fd, .msg = &slot.send_msg },
                &slot.send_completion,
                self,
                udpSendComplete,
            ) catch {
                slot.send_in_flight = false;
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
        }

        fn submitRecvmsg(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
            if (slot.recv_in_flight or slot.closing or slot.completed) return;
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

            slot.recv_in_flight = true;
            self.io.recvmsg(
                .{ .fd = slot.fd, .msg = &slot.recv_msg },
                &slot.recv_completion,
                self,
                udpRecvComplete,
            ) catch {
                slot.recv_in_flight = false;
                self.completeSlot(slot_idx, .{ .err = error.SubmitFailed });
            };
        }

        // ── CQE handlers ─────────────────────────────────────────

        fn handleSend(self: *Self, slot: *RequestSlot, slot_idx: u16, send_result: anyerror!usize) void {
            _ = self;
            _ = slot;
            _ = slot_idx;
            // For UDP, send completion just means the datagram was queued.
            // Errors are rare but possible.
            _ = send_result catch |err| {
                log.debug("UDP tracker sendmsg failed: {s}", .{@errorName(err)});
                // Don't complete yet -- the retransmission timer will handle it
                return;
            };
        }

        fn handleRecv(self: *Self, slot: *RequestSlot, slot_idx: u16, cqe: linux.io_uring_cqe) void {
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

        fn handleConnectResponse(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
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

        fn handleAnnounceResponse(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
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

        fn handleScrapeResponse(self: *Self, slot: *RequestSlot, slot_idx: u16) void {
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

        fn checkTimeoutsAndRetransmit(self: *Self) void {
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

        fn claimSlot(self: *Self) ?u16 {
            for (self.slots, 0..) |*slot, i| {
                if (slot.state == .free) return @intCast(i);
            }
            return null;
        }

        fn completeSlot(self: *Self, slot_idx: u16, result: RequestResult) void {
            const slot = &self.slots[slot_idx];
            if (slot.state == .free or slot.completed) return;

            const job = slot.job;
            slot.completed = true;
            slot.closing = true;

            if (comptime !use_custom_dns) {
                if (slot.dns_job) |dns_job| {
                    dns_job.release();
                    slot.dns_job = null;
                }
            }
            self.detachDnsJob(slot, false);
            if (slot.fd >= 0) {
                const fd = slot.fd;
                slot.fd = -1;
                self.io.closeSocket(fd);
            }

            // Invoke callback
            job.on_complete(job.context, result);

            self.tryResetSlot(slot_idx);
        }

        fn tryResetSlot(self: *Self, slot_idx: u16) void {
            const slot = &self.slots[slot_idx];
            if (!slot.closing and !slot.completed) return;
            if (slot.socket_in_flight or
                slot.connect_in_flight or
                slot.send_in_flight or
                slot.recv_in_flight)
            {
                return;
            }
            slot.reset();
        }
    };
}

/// Daemon-side alias: the `RealIO` instantiation of the UDP tracker
/// executor. Sim tests instantiate `UdpTrackerExecutorOf(SimIO)` directly;
/// production code references this alias unchanged.
pub const UdpTrackerExecutor = UdpTrackerExecutorOf(RealIO);

test "UdpTrackerExecutor uses independent send and recv completions" {
    const sim_io_mod = @import("../io/sim_io.zig");
    const SimIO = sim_io_mod.SimIO;
    const Executor = UdpTrackerExecutorOf(SimIO);

    const allocator = std.testing.allocator;
    var io = try SimIO.init(allocator, .{ .seed = 0x715 });
    defer io.deinit();

    var random = Random.simRandom(0x715);
    var slots = [_]Executor.RequestSlot{.{}} ** 1;
    var executor = Executor{
        .allocator = allocator,
        .io = &io,
        .random = &random,
        .dns_event_fd = -1,
        .pending_jobs = .empty,
        .slots = slots[0..],
        .max_slots = 1,
        .dns_resolver = try Executor.initDnsResolver(allocator, &io, .{}),
        .retired_dns_jobs = if (Executor.use_custom_dns) std.ArrayList(*Executor.DnsJob).empty else {},
    };
    defer {
        executor.dns_resolver.deinit(allocator);
        executor.reapRetiredDnsJobs();
        if (Executor.use_custom_dns) executor.retired_dns_jobs.deinit(allocator);
    }

    const Ctx = struct {
        completed: bool = false,
        err: ?anyerror = null,

        fn onComplete(context: *anyopaque, result: Executor.RequestResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.completed = true;
            self.err = result.err;
        }
    };
    var ctx = Ctx{};

    var job = Executor.Job{
        .context = @ptrCast(&ctx),
        .on_complete = Ctx.onComplete,
        .port = 6969,
    };
    const host = "127.0.0.1";
    @memcpy(job.host[0..host.len], host);
    job.host_len = host.len;

    const slot = &executor.slots[0];
    slot.* = .{
        .state = .connecting,
        .fd = -1,
        .job = job,
        .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6969),
    };

    executor.startConnect(slot, 0);

    try std.testing.expect(!ctx.completed);
    try std.testing.expect(slot.send_in_flight);
    try std.testing.expect(slot.recv_in_flight);
    try std.testing.expect(slot.send_msg.name == null);
    try std.testing.expectEqual(@as(posix.socklen_t, 0), slot.send_msg.namelen);

    slot.closing = true;
    slot.completed = true;
    try io.tick(0);
}

//! Per-query state machine for the custom DNS resolver.
//!
//! Generic over the IO backend (`RealIO`, `EpollIO`, `KqueueIO`,
//! `SimIO`) — every primitive used here (`socket`, `connect`,
//! `send`, `recv`, `timeout`, `cancel`) is in
//! `io_interface.zig` and is implemented by all four backends.
//!
//! Lifecycle:
//!   1. `start(host, qtype, callback)` — encodes the query and submits
//!      `socket()` for a fresh UDP fd (per-query source-port
//!      randomization comes from the kernel's ephemeral allocation).
//!   2. On socket CQE: optionally `applyBindDevice(fd)` (Linux), then
//!      submit `connect()` to the current server.
//!   3. On connect CQE: submit `send()` of the encoded query and
//!      `recv()` for the response, plus a `timeout()` that races
//!      against the recv.
//!   4. On recv CQE: parse the response, verify txid + question
//!      match, extract A/AAAA addresses. CNAME chain following is
//!      handled by the caller (resolver) by re-issuing a fresh query
//!      against the chain target.
//!   5. On timeout CQE: cancel the recv, advance to the next server.
//!
//! Defenses (mirrors KRPC hardening, see message.zig):
//!   - txid match before accepting the response (drop on mismatch
//!     and re-arm recv).
//!   - question section match (cache-poisoning defense; lives in
//!     message.extractAnswers).
//!   - per-server attempt timeout, total-budget enforcement.
//!
//! The TCP-fallback path (truncated UDP responses, TC=1) is **not**
//! implemented in this version — when TC=1 we treat it as a
//! per-server failure and try the next server. BitTorrent's tracker
//! / web-seed lookups almost never exceed 512 bytes after CNAME
//! follow, so this is acceptable for v1. Phase F follow-up.

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.dns_custom);

const message = @import("message.zig");
const io_interface = @import("../io_interface.zig");
const applyBindDevice = @import("../../net/socket.zig").applyBindDevice;

/// Caller-supplied configuration for a single Query.
pub const QueryParams = struct {
    /// Lowercased FQDN being looked up. Caller-owned; must outlive
    /// the query.
    host: []const u8,
    /// Record type to ask for. `.a` or `.aaaa` — others are
    /// rejected.
    qtype: message.RrType,
    /// resolv.conf-derived list of nameservers, port = 53. The
    /// query iterates through them on per-server timeout / SERVFAIL.
    /// Must be non-empty; must outlive the query.
    servers: []const std.net.Address,
    /// Per-server attempt timeout (ns). Default 1500 ms.
    per_server_timeout_ns: u64 = 1_500 * std.time.ns_per_ms,
    /// Total query budget across all servers (ns). Default 5000 ms.
    total_timeout_ns: u64 = 5_000 * std.time.ns_per_ms,
    /// Optional SO_BINDTODEVICE name (Linux). When set, applied to the
    /// query UDP socket after socket() returns. Mirrors what peer /
    /// tracker / RPC sockets do today and closes the bind_device DNS
    /// leak documented in `docs/custom-dns-design-round2.md` §1.
    bind_device: ?[]const u8 = null,
    /// 16-bit transaction ID. Caller picks; randomized per query for
    /// poisoning defense (`std.crypto.random.intRangeAtMost(u16, 0,
    /// 0xFFFF)`).
    txid: u16,
};

/// Result delivered to the caller's callback.
pub const QueryResult = union(enum) {
    /// Resolved successfully. `addresses` slice points into the
    /// Query's internal storage; callers must copy out before the
    /// callback returns (or before the next start).
    answers: Answers,
    /// Authoritative "doesn't exist" (NXDOMAIN). Cache negatively.
    nx_domain,
    /// All servers failed (timeout, SERVFAIL, malformed responses).
    /// `last_err` is the most recent specific error encountered for
    /// logging; the caller treats this as "DNS resolution failed".
    failed: anyerror,
    /// CNAME chain target needs follow-up. The caller (resolver)
    /// issues a fresh query against `target`.
    cname: message.NameBuffer,
};

pub const Answers = struct {
    list: []const message.ExtractedAddress,
    /// Lowest TTL across the answer set, used for cache insertion.
    min_ttl_s: u32,
};

/// Generic-over-IO single-shot DNS query.
///
/// Heap-allocate via `create()`; the resolver pool keeps the Query
/// alive across CQE callbacks. `destroy()` releases all resources
/// (including the UDP socket if still open).
pub fn QueryOf(comptime IO: type) type {
    return struct {
        const Self = @This();

        // ── Lifecycle / dependencies ─────────────────────────────
        allocator: std.mem.Allocator,
        io: *IO,

        // ── Per-query parameters ─────────────────────────────────
        params: QueryParams,
        /// Index into `params.servers` for the current attempt.
        server_idx: u8 = 0,

        // ── IO state ─────────────────────────────────────────────
        socket_fd: posix.fd_t = -1,
        /// Encoded query bytes (header + question), filled in `start`.
        send_buf: [256]u8 = undefined,
        send_len: usize = 0,
        /// Recv buffer sized to UDP max + a generous EDNS payload.
        recv_buf: [4096]u8 = undefined,
        recv_len: usize = 0,
        /// Most recent specific error, surfaced in `.failed`.
        last_err: anyerror = error.DnsResolutionFailed,

        // ── Completion slots ─────────────────────────────────────
        /// One completion drives socket → connect → send → recv in
        /// sequence (each callback re-arms the next op on the same
        /// completion).
        op_completion: io_interface.Completion = .{},
        /// Separate completion for the per-server timeout, races
        /// against `op_completion` while in recv state.
        timeout_completion: io_interface.Completion = .{},
        /// Total-budget timeout, raced against the whole flow.
        total_timeout_completion: io_interface.Completion = .{},

        state: State = .idle,
        timeout_in_flight: bool = false,
        total_timeout_in_flight: bool = false,
        op_in_flight: bool = false,

        // ── Caller hookup ────────────────────────────────────────
        on_complete: ?*const fn (?*anyopaque, *Self, QueryResult) void = null,
        caller_ctx: ?*anyopaque = null,

        // ── Decoded answer storage ───────────────────────────────
        answers_storage: [8]message.ExtractedAddress = undefined,
        answers_len: u8 = 0,

        pub const State = enum {
            idle,
            opening_socket,
            connecting,
            sending,
            receiving,
            done,
        };

        pub fn create(allocator: std.mem.Allocator, io: *IO) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .io = io, .params = undefined };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.closeSocket();
            self.allocator.destroy(self);
        }

        /// Start a query. The Query takes ownership of the parameters
        /// (the `host` slice and `servers` slice must stay alive for
        /// the lifetime of the query, but they are not duped).
        pub fn start(
            self: *Self,
            params: QueryParams,
            caller_ctx: ?*anyopaque,
            on_complete: *const fn (?*anyopaque, *Self, QueryResult) void,
        ) !void {
            std.debug.assert(self.state == .idle or self.state == .done);
            std.debug.assert(params.servers.len > 0);

            self.params = params;
            self.caller_ctx = caller_ctx;
            self.on_complete = on_complete;
            self.server_idx = 0;
            self.last_err = error.DnsResolutionFailed;
            self.answers_len = 0;
            self.send_len = try message.encodeQuery(
                &self.send_buf,
                params.txid,
                params.host,
                params.qtype,
            );

            // Arm the total-budget timeout.
            try self.io.timeout(
                .{ .ns = params.total_timeout_ns },
                &self.total_timeout_completion,
                self,
                onTotalTimeout,
            );
            self.total_timeout_in_flight = true;

            // Begin: open socket for the first server.
            try self.openSocket();
        }

        // ── State transitions ────────────────────────────────────

        fn openSocket(self: *Self) !void {
            const server = self.params.servers[self.server_idx];
            const family: u32 = server.any.family;
            const sock_type: u32 =
                posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
            self.state = .opening_socket;
            try self.io.socket(
                .{ .domain = family, .sock_type = sock_type, .protocol = posix.IPPROTO.UDP },
                &self.op_completion,
                self,
                onSocket,
            );
            self.op_in_flight = true;
        }

        fn submitConnect(self: *Self) !void {
            const server = self.params.servers[self.server_idx];
            self.state = .connecting;
            try self.io.connect(
                .{ .fd = self.socket_fd, .addr = server },
                &self.op_completion,
                self,
                onConnect,
            );
            self.op_in_flight = true;
        }

        fn submitSend(self: *Self) !void {
            self.state = .sending;
            try self.io.send(
                .{ .fd = self.socket_fd, .buf = self.send_buf[0..self.send_len] },
                &self.op_completion,
                self,
                onSend,
            );
            self.op_in_flight = true;
        }

        fn submitRecv(self: *Self) !void {
            self.state = .receiving;
            try self.io.recv(
                .{ .fd = self.socket_fd, .buf = &self.recv_buf },
                &self.op_completion,
                self,
                onRecv,
            );
            self.op_in_flight = true;

            // Arm per-server timeout.
            try self.io.timeout(
                .{ .ns = self.params.per_server_timeout_ns },
                &self.timeout_completion,
                self,
                onPerServerTimeout,
            );
            self.timeout_in_flight = true;
        }

        // ── CQE handlers ─────────────────────────────────────────

        fn onSocket(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.op_in_flight = false;
            switch (result) {
                .socket => |r| {
                    if (r) |fd| {
                        self.socket_fd = fd;
                        if (self.params.bind_device) |dev| {
                            applyBindDevice(fd, dev) catch |err| {
                                // Log but don't fail — match peer-handler behavior
                                // (continue without binding when CAP_NET_RAW is missing).
                                log.warn("dns: applyBindDevice({s}) failed: {t}", .{ dev, err });
                            };
                        }
                        self.submitConnect() catch |err| {
                            self.last_err = err;
                            self.advanceServerOrFail();
                        };
                    } else |err| {
                        self.last_err = err;
                        self.advanceServerOrFail();
                    }
                },
                else => {
                    self.last_err = error.UnexpectedResult;
                    self.advanceServerOrFail();
                },
            }
            return .disarm;
        }

        fn onConnect(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.op_in_flight = false;
            switch (result) {
                .connect => |r| {
                    if (r) |_| {
                        self.submitSend() catch |err| {
                            self.last_err = err;
                            self.advanceServerOrFail();
                        };
                    } else |err| {
                        self.last_err = err;
                        self.advanceServerOrFail();
                    }
                },
                else => {
                    self.last_err = error.UnexpectedResult;
                    self.advanceServerOrFail();
                },
            }
            return .disarm;
        }

        fn onSend(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.op_in_flight = false;
            switch (result) {
                .send => |r| {
                    if (r) |n| {
                        if (n != self.send_len) {
                            self.last_err = error.ShortWrite;
                            self.advanceServerOrFail();
                            return .disarm;
                        }
                        self.submitRecv() catch |err| {
                            self.last_err = err;
                            self.advanceServerOrFail();
                        };
                    } else |err| {
                        self.last_err = err;
                        self.advanceServerOrFail();
                    }
                },
                else => {
                    self.last_err = error.UnexpectedResult;
                    self.advanceServerOrFail();
                },
            }
            return .disarm;
        }

        fn onRecv(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.op_in_flight = false;
            // Cancel the per-server timeout — the recv beat it.
            self.cancelPerServerTimeout();

            switch (result) {
                .recv => |r| {
                    if (r) |n| {
                        self.recv_len = n;
                        self.processResponse();
                    } else |err| {
                        self.last_err = err;
                        self.advanceServerOrFail();
                    }
                },
                else => {
                    self.last_err = error.UnexpectedResult;
                    self.advanceServerOrFail();
                },
            }
            return .disarm;
        }

        fn onPerServerTimeout(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.timeout_in_flight = false;
            switch (result) {
                .timeout => {
                    if (self.state == .receiving and self.op_in_flight) {
                        // Cancel the recv to free the socket.
                        self.cancelOp();
                        self.last_err = error.DnsTimeout;
                        // We'll advance after the recv's cancel CQE fires
                        // (which delivers as recv returning OperationCanceled).
                    }
                },
                else => {},
            }
            return .disarm;
        }

        fn onTotalTimeout(
            ud: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            self.total_timeout_in_flight = false;
            switch (result) {
                .timeout => {
                    self.last_err = error.DnsTimeout;
                    self.fail(error.DnsTimeout);
                },
                else => {},
            }
            return .disarm;
        }

        // ── Response processing ──────────────────────────────────

        fn processResponse(self: *Self) void {
            // Decode header to check txid first (cheap, tells us if
            // this is even our packet).
            const hdr = message.Header.decode(self.recv_buf[0..self.recv_len]) catch {
                self.last_err = error.MalformedDnsMessage;
                // Drop and re-arm recv; an off-path attacker may have
                // sent garbage. The per-server timeout will eventually
                // close us out if the legit response never arrives.
                self.rearmRecv();
                return;
            };
            if (hdr.txid != self.params.txid) {
                // Wrong txid — drop silently and re-arm.
                self.rearmRecv();
                return;
            }
            // Truncated UDP response: try the next server. (TCP
            // fallback is a follow-up; see module top docstring.)
            if (hdr.flags.tc) {
                self.last_err = error.DnsResponseTruncated;
                self.advanceServerOrFail();
                return;
            }

            // Server-side rcode handling.
            switch (hdr.flags.rcode) {
                .nx_domain => {
                    self.deliver(.nx_domain);
                    return;
                },
                .server_failure, .refused, .not_implemented, .format_error => {
                    self.last_err = error.DnsServerError;
                    self.advanceServerOrFail();
                    return;
                },
                else => {},
            }

            const extracted = message.extractAnswers(
                self.recv_buf[0..self.recv_len],
                self.params.host,
                self.params.qtype,
            ) catch {
                self.last_err = error.MalformedDnsMessage;
                self.rearmRecv();
                return;
            };

            // CNAME-only response → ask caller to re-issue.
            if (extracted.cname_target) |target| {
                self.deliver(.{ .cname = target });
                return;
            }

            if (extracted.addresses_len == 0) {
                self.last_err = error.DnsNoAnswer;
                self.advanceServerOrFail();
                return;
            }

            // Copy answers + lowest TTL into our storage and surface.
            var min_ttl: u32 = std.math.maxInt(u32);
            for (0..extracted.addresses_len) |i| {
                self.answers_storage[i] = extracted.addresses[i];
                if (extracted.addresses[i].ttl < min_ttl) min_ttl = extracted.addresses[i].ttl;
            }
            self.answers_len = extracted.addresses_len;
            self.deliver(.{ .answers = .{
                .list = self.answers_storage[0..self.answers_len],
                .min_ttl_s = min_ttl,
            } });
        }

        fn rearmRecv(self: *Self) void {
            // We came out of recv normally; the per-server timeout was
            // already cancelled in onRecv. Re-arm both.
            self.submitRecv() catch |err| {
                self.last_err = err;
                self.advanceServerOrFail();
            };
        }

        fn advanceServerOrFail(self: *Self) void {
            self.closeSocket();
            self.server_idx += 1;
            if (self.server_idx >= self.params.servers.len) {
                self.fail(self.last_err);
                return;
            }
            self.openSocket() catch |err| {
                self.last_err = err;
                self.fail(err);
            };
        }

        fn fail(self: *Self, err: anyerror) void {
            self.deliver(.{ .failed = err });
        }

        fn deliver(self: *Self, result: QueryResult) void {
            if (self.state == .done) return; // already delivered (e.g. total timeout raced).
            self.state = .done;
            self.cancelPerServerTimeout();
            self.cancelTotalTimeout();
            self.cancelOp();
            self.closeSocket();
            if (self.on_complete) |cb| {
                cb(self.caller_ctx, self, result);
            }
        }

        // ── Op-cancel helpers ────────────────────────────────────

        fn cancelOp(self: *Self) void {
            if (!self.op_in_flight) return;
            // Best-effort cancel; if the op already completed concurrently
            // the cancel returns OperationNotFound, which is fine.
            self.io.cancel(
                .{ .target = &self.op_completion },
                &self.op_completion, // some backends overload onto target's completion
                self,
                noopCancel,
            ) catch {};
        }

        fn cancelPerServerTimeout(self: *Self) void {
            if (!self.timeout_in_flight) return;
            self.io.cancel(
                .{ .target = &self.timeout_completion },
                &self.timeout_completion,
                self,
                noopCancel,
            ) catch {};
        }

        fn cancelTotalTimeout(self: *Self) void {
            if (!self.total_timeout_in_flight) return;
            self.io.cancel(
                .{ .target = &self.total_timeout_completion },
                &self.total_timeout_completion,
                self,
                noopCancel,
            ) catch {};
        }

        fn closeSocket(self: *Self) void {
            if (self.socket_fd >= 0) {
                std.posix.close(self.socket_fd);
                self.socket_fd = -1;
            }
        }

        fn noopCancel(
            _: ?*anyopaque,
            _: *io_interface.Completion,
            _: io_interface.Result,
        ) io_interface.CallbackAction {
            return .disarm;
        }
    };
}

// ── Tests ────────────────────────────────────────────────

test "QueryParams encodes a query packet" {
    // Smoke check that QueryParams + encodeQuery line up — full
    // SimIO round-trip lives in resolver.zig + a sim test (Phase F
    // follow-up).
    const params = QueryParams{
        .host = "example.com",
        .qtype = .a,
        .servers = &[_]std.net.Address{
            std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53),
        },
        .txid = 0x4242,
    };
    var buf: [256]u8 = undefined;
    const n = try message.encodeQuery(&buf, params.txid, params.host, params.qtype);
    try std.testing.expect(n > message.header_size);
    try std.testing.expectEqual(@as(u8, 0x42), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x42), buf[1]);
}

test "QueryResult union variants compile" {
    const r1 = QueryResult{ .nx_domain = {} };
    _ = r1;
    const r2 = QueryResult{ .failed = error.DnsTimeout };
    _ = r2;
}

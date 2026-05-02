//! Custom DNS library — Phase F end-to-end integration test.
//!
//! Drives `QueryOf(IO)` through a complete A query → response cycle
//! against a scripted in-process DNS server. The IO contract is
//! satisfied by a tiny `ScriptedIo` test wrapper. It gives the tests
//! deterministic DNS responses and operation ordering without standing
//! up the full simulator. `ScriptedIo` allocates real `AF_UNIX`
//! `SOCK_DGRAM` fds on `socket()` so the same close path is harmless
//! while the recv path is fully scripted.
//!
//! The scenarios cover the happy path and resolver hardening:
//!   1. **A query → A response with the question section echoed**:
//!      verifies the parser accepts a well-formed answer, txid match,
//!      question-section verification, and surfaces the resolved
//!      `192.0.2.42` to the caller's callback.
//!   2. **bind_device sequencing**: verifies SO_BINDTODEVICE is routed
//!      through the IO `setsockopt` contract before DNS connect/send.
//!   3. **resolver-level async lookup**: verifies `DnsResolverOf(IO)`
//!      owns the query, resolves an A record, and populates its TTL cache.
//!   4. **A query → NXDOMAIN response**: verifies the parser surfaces
//!      `.nx_domain` to the caller, exercising the negative-answer
//!      delivery path.
//!
//! See `progress-reports/2026-04-30-dns-phase-f.md` and the module
//! docstring of `src/io/dns_custom/query.zig` for the surrounding
//! context.

const std = @import("std");
const posix = std.posix;
const testing = std.testing;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const dns = varuna.io.dns;
const dns_custom = dns.dns_custom;

const Completion = ifc.Completion;
const Result = ifc.Result;
const Callback = ifc.Callback;
const CallbackAction = ifc.CallbackAction;

// ── ScriptedIo: minimal IO contract for end-to-end Query ────
//
// Implements the public method set of the IO contract that
// `QueryOf(IO)` requires: `socket`, `connect`, `send`, `recv`,
// `timeout`, `cancel`. Submission methods enqueue a `(completion,
// result)` pair into one of two queues:
//
//   - `pending`: socket / connect / send / recv / cancel results.
//     `tick()` drains this FIFO synchronously, firing callbacks in
//     submission order.
//   - `timers`: `timeout()` results. Held back by default so
//     pre-armed timeouts don't outrace the real recv result that
//     fires after socket → connect → send → recv. A test that wants
//     to fire timers calls `fireTimers()`.
//
// `socket()` allocates a real OS `AF_UNIX` `SOCK_DGRAM` fd so
// `query.zig`'s `posix.close(socket_fd)` on deliver is harmless.
// `recv()` consumes scripted bytes from `scripted_recv` (FIFO of
// byte slices); the test pre-populates it before starting the query.

const ScriptedIo = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Pending) = .empty,
    timers: std.ArrayList(Pending) = .empty,
    scripted_recv: std.ArrayList([]const u8) = .empty,
    operation_log: std.ArrayList(OperationKind) = .empty,
    /// Real OS fds we've allocated; closed in `deinit` if the caller
    /// didn't already close them (the Query is supposed to).
    open_fds: std.ArrayList(posix.fd_t) = .empty,
    last_setsockopt_level: u32 = 0,
    last_setsockopt_optname: u32 = 0,
    last_setsockopt_value: [16]u8 = undefined,
    last_setsockopt_value_len: u8 = 0,
    /// If non-null, the next `socket()` op returns this error instead
    /// of allocating an fd. Lets a future test exercise the
    /// per-server fallback path.
    next_socket_err: ?anyerror = null,

    const OperationKind = enum {
        socket,
        setsockopt,
        connect,
        send,
        sendmsg,
        recv,
        recvmsg,
        timeout,
        cancel,
        close_socket,
    };

    const Pending = struct {
        completion: *Completion,
        result: Result,
        /// Marked when a `cancel()` op has rerouted the target's
        /// pending result to `error.OperationCanceled`. Any subsequent
        /// real result for that completion is dropped to avoid double
        /// delivery.
        cancelled: bool = false,
    };

    fn init(allocator: std.mem.Allocator) ScriptedIo {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ScriptedIo) void {
        // Note: we deliberately do NOT close `open_fds` here.
        // `query.zig`'s `closeSocket()` on deliver / advanceServerOrFail
        // / fail already calls `posix.close(socket_fd)`, and a second
        // close on the same fd would `unreachable` in `posix.close()`
        // on `EBADF`. If a test path failed before reaching deliver,
        // fds leak for the lifetime of the test process — acceptable.
        self.open_fds.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.timers.deinit(self.allocator);
        self.scripted_recv.deinit(self.allocator);
        self.operation_log.deinit(self.allocator);
    }

    fn record(self: *ScriptedIo, kind: OperationKind) !void {
        try self.operation_log.append(self.allocator, kind);
    }

    fn firstOperationIndex(self: *const ScriptedIo, kind: OperationKind) ?usize {
        for (self.operation_log.items, 0..) |op, i| {
            if (op == kind) return i;
        }
        return null;
    }

    fn operationCount(self: *const ScriptedIo, kind: OperationKind) usize {
        var count: usize = 0;
        for (self.operation_log.items) |op| {
            if (op == kind) count += 1;
        }
        return count;
    }

    /// Push scripted bytes that the next `recv()` will consume. Test
    /// code pre-populates this before starting the Query.
    fn pushRecv(self: *ScriptedIo, bytes: []const u8) !void {
        try self.scripted_recv.append(self.allocator, bytes);
    }

    /// Drain the non-timer FIFO, firing callbacks until it's empty
    /// or `max_iters` is reached (guard against runaway re-arming).
    fn tick(self: *ScriptedIo, max_iters: u32) !void {
        var iters: u32 = 0;
        while (self.pending.items.len > 0 and iters < max_iters) : (iters += 1) {
            const head = self.pending.orderedRemove(0);
            const c = head.completion;
            const callback = c.callback orelse continue;
            _ = callback(c.userdata, c, head.result);
        }
    }

    /// Fire every armed timer (used by tests that want to drive the
    /// timeout path explicitly). Most happy-path tests never call
    /// this; they reach `deliver()` first and `cancelPerServerTimeout
    /// / cancelTotalTimeout` rewrite the timer entries' results to
    /// `error.OperationCanceled` — which the timeout callbacks
    /// ignore.
    fn fireTimers(self: *ScriptedIo, max_iters: u32) !void {
        var iters: u32 = 0;
        while (self.timers.items.len > 0 and iters < max_iters) : (iters += 1) {
            const head = self.timers.orderedRemove(0);
            const c = head.completion;
            const callback = c.callback orelse continue;
            _ = callback(c.userdata, c, head.result);
        }
    }

    // ── IO contract: submission methods ────────────────────

    pub fn socket(self: *ScriptedIo, op: ifc.SocketOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = op; // family / sock_type / protocol ignored by ScriptedIo
        try self.record(.socket);
        c.userdata = ud;
        c.callback = cb;

        if (self.next_socket_err) |err| {
            self.next_socket_err = null;
            try self.pending.append(self.allocator, .{
                .completion = c,
                .result = .{ .socket = err },
            });
            return;
        }

        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);
        try self.open_fds.append(self.allocator, fd);
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .socket = fd },
        });
    }

    pub fn setsockopt(self: *ScriptedIo, op: ifc.SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.record(.setsockopt);
        c.userdata = ud;
        c.callback = cb;

        self.last_setsockopt_level = op.level;
        self.last_setsockopt_optname = op.optname;
        self.last_setsockopt_value_len = @intCast(@min(op.optval.len, self.last_setsockopt_value.len));
        @memcpy(
            self.last_setsockopt_value[0..self.last_setsockopt_value_len],
            op.optval[0..self.last_setsockopt_value_len],
        );

        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .setsockopt = {} },
        });
    }

    pub fn connect(self: *ScriptedIo, op: ifc.ConnectOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = op;
        try self.record(.connect);
        c.userdata = ud;
        c.callback = cb;
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .connect = {} },
        });
    }

    pub fn send(self: *ScriptedIo, op: ifc.SendOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.record(.send);
        c.userdata = ud;
        c.callback = cb;
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .send = op.buf.len },
        });
    }

    pub fn recv(self: *ScriptedIo, op: ifc.RecvOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.record(.recv);
        c.userdata = ud;
        c.callback = cb;

        if (self.scripted_recv.items.len == 0) {
            // No scripted bytes — schedule a connection-reset error so
            // the query advances to the next server (or fails).
            try self.pending.append(self.allocator, .{
                .completion = c,
                .result = .{ .recv = error.ConnectionResetByPeer },
            });
            return;
        }

        const bytes = self.scripted_recv.orderedRemove(0);
        const want = @min(op.buf.len, bytes.len);
        @memcpy(op.buf[0..want], bytes[0..want]);
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .recv = want },
        });
    }

    pub fn sendmsg(self: *ScriptedIo, op: ifc.SendmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.record(.sendmsg);
        c.userdata = ud;
        c.callback = cb;

        var sent: usize = 0;
        for (op.msg.iov[0..op.msg.iovlen]) |iov| sent += iov.len;
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .sendmsg = sent },
        });
    }

    pub fn recvmsg(self: *ScriptedIo, op: ifc.RecvmsgOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = op;
        try self.record(.recvmsg);
        c.userdata = ud;
        c.callback = cb;
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .recvmsg = error.ConnectionResetByPeer },
        });
    }

    pub fn timeout(self: *ScriptedIo, op: ifc.TimeoutOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        _ = op;
        try self.record(.timeout);
        c.userdata = ud;
        c.callback = cb;
        // Park on the dedicated timer queue. `tick()` ignores timer
        // entries; tests that want to fire timers call `fireTimers()`.
        // The Query cancels timers on deliver() — `cancel()` rewrites
        // the matching timer entry's result to OperationCanceled.
        try self.timers.append(self.allocator, .{
            .completion = c,
            .result = .{ .timeout = {} },
        });
    }

    pub fn cancel(self: *ScriptedIo, op: ifc.CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void {
        try self.record(.cancel);
        c.userdata = ud;
        c.callback = cb;

        // Rewrite any pending or timer entry for the target completion
        // to a canceled result. The Query's cancel-self completion
        // fires with a no-op `cancel` result via the non-timer FIFO.
        rewriteCanceled(self.pending.items, op.target);
        rewriteCanceled(self.timers.items, op.target);
        try self.pending.append(self.allocator, .{
            .completion = c,
            .result = .{ .cancel = {} },
        });
    }

    fn rewriteCanceled(items: []Pending, target: *Completion) void {
        for (items) |*pending| {
            if (pending.completion == target and !pending.cancelled) {
                pending.cancelled = true;
                pending.result = switch (pending.result) {
                    .recv => Result{ .recv = error.OperationCanceled },
                    .send => Result{ .send = error.OperationCanceled },
                    .connect => Result{ .connect = error.OperationCanceled },
                    .socket => Result{ .socket = error.OperationCanceled },
                    .timeout => Result{ .timeout = error.OperationCanceled },
                    else => pending.result,
                };
            }
        }
    }

    pub fn closeSocket(self: *ScriptedIo, fd: posix.fd_t) void {
        self.record(.close_socket) catch {};
        posix.close(fd);
    }
};

const ScriptedResolver = dns_custom.resolver.DnsResolverOf(ScriptedIo);

// ── DNS response builders ───────────────────────────────────

/// Build an A response message: header + question (echoed) +
/// single A answer pointing at `addr_v4`. Returns the byte count
/// written into `out`.
fn buildAResponse(
    out: []u8,
    txid: u16,
    name: []const u8,
    addr_v4: [4]u8,
    ttl: u32,
) !usize {
    const message = dns_custom.message;

    // Header: response, no error, recursion available, qdcount=1, ancount=1.
    const hdr: message.Header = .{
        .txid = txid,
        .flags = .{ .qr = true, .rd = true, .ra = true, .rcode = .no_error },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    if (out.len < message.header_size) return error.NoSpaceLeft;
    try hdr.encode(out[0..message.header_size]);
    var n: usize = message.header_size;

    // Question section: name + qtype=A + qclass=IN.
    n += try message.encodeQuestion(out[n..], name, .a);

    // Answer: name (re-encoded, no compression — the parser handles
    // both compressed and uncompressed forms), type=A, class=IN, ttl,
    // rdlength=4, rdata=addr_v4.
    const name_n = try message.encodeName(out[n..], name);
    const ans_start = n + name_n;
    if (ans_start + 10 + 4 > out.len) return error.NoSpaceLeft;
    std.mem.writeInt(u16, out[ans_start..][0..2], @intFromEnum(message.RrType.a), .big);
    std.mem.writeInt(u16, out[ans_start + 2 ..][0..2], @intFromEnum(message.RrClass.in), .big);
    std.mem.writeInt(u32, out[ans_start + 4 ..][0..4], ttl, .big);
    std.mem.writeInt(u16, out[ans_start + 8 ..][0..2], 4, .big);
    @memcpy(out[ans_start + 10 ..][0..4], &addr_v4);
    n = ans_start + 14;

    return n;
}

/// Build an NXDOMAIN response: header (rcode=nx_domain) + question
/// echoed, no answers.
fn buildNxDomainResponse(
    out: []u8,
    txid: u16,
    name: []const u8,
) !usize {
    const message = dns_custom.message;

    const hdr: message.Header = .{
        .txid = txid,
        .flags = .{ .qr = true, .rd = true, .ra = true, .rcode = .nx_domain },
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    if (out.len < message.header_size) return error.NoSpaceLeft;
    try hdr.encode(out[0..message.header_size]);
    var n: usize = message.header_size;

    n += try message.encodeQuestion(out[n..], name, .a);
    return n;
}

// ── Test harness ────────────────────────────────────────────

/// Captures the QueryResult delivered to the caller's callback so
/// the test can assert on it after `tick()` drains the FIFO.
const Capture = struct {
    delivered: bool = false,
    result: ?dns_custom.query.QueryResult = null,
    /// Owned copy of the resolved address (the slice in the
    /// QueryResult points into Query.answers_storage which becomes
    /// invalid once the Query is destroyed).
    resolved_addr: ?std.net.Address = null,
};

const ResolverCapture = struct {
    delivered: bool = false,
    result: ?dns_custom.resolver.ResolveResult = null,
    resolved_addr: ?std.net.Address = null,
};

fn captureCallback(
    ud: ?*anyopaque,
    _: *dns_custom.query.QueryOf(ScriptedIo),
    result: dns_custom.query.QueryResult,
) void {
    const cap: *Capture = @ptrCast(@alignCast(ud.?));
    cap.delivered = true;
    cap.result = result;
    if (result == .answers) {
        const a = result.answers.list[0];
        cap.resolved_addr = if (a.family == .v4)
            std.net.Address.initIp4(a.bytes[0..4].*, 80)
        else
            std.net.Address.initIp6(a.bytes[0..16].*, 80, 0, 0);
    }
}

fn resolverCaptureCallback(
    ud: ?*anyopaque,
    _: *ScriptedResolver.ResolveJob,
    result: dns_custom.resolver.ResolveResult,
) void {
    const cap: *ResolverCapture = @ptrCast(@alignCast(ud.?));
    cap.delivered = true;
    cap.result = result;
    if (result == .resolved) {
        cap.resolved_addr = result.resolved;
    }
}

// ── Tests ───────────────────────────────────────────────────

test "DnsResolverOf instantiates against ScriptedIo" {
    // Compile-check that the new library types resolve and link
    // correctly through the `dns.dns_custom` re-export under the
    // current `-Ddns=` selection (any backend — the re-export is
    // unconditional).
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const ResolverT = dns_custom.resolver.DnsResolverOf(ScriptedIo);
    const srvs = [_]std.net.Address{
        std.net.Address.initIp4(.{ 198, 51, 100, 1 }, 53),
    };
    var r = try ResolverT.init(testing.allocator, &io, .{ .servers = &srvs });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.servers().len);
}

test "QueryOf(ScriptedIo): A query resolves to expected address" {
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    // Pre-build the A response packet for the txid the Query will use.
    const txid: u16 = 0xABCD;
    const host = "test.varuna.local";
    const expected_v4 = [4]u8{ 192, 0, 2, 42 };
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, expected_v4, 600);
    try io.pushRecv(resp_buf[0..resp_len]);

    // Build the Query; servers=[8.8.8.8:53] is just an address tag —
    // the ScriptedIo doesn't actually route to it.
    const QueryT = dns_custom.query.QueryOf(ScriptedIo);
    var query = try QueryT.create(testing.allocator, &io);
    defer query.destroy();

    const servers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53),
    };
    var capture = Capture{};
    try query.start(.{
        .host = host,
        .qtype = .a,
        .servers = &servers,
        .txid = txid,
    }, &capture, captureCallback);

    // Drive the FIFO. socket → connect → send → recv → process →
    // deliver, plus a few cancels and timeout entries to drain.
    try io.tick(64);

    try testing.expect(capture.delivered);
    try testing.expect(capture.result != null);
    switch (capture.result.?) {
        .answers => |a| {
            try testing.expectEqual(@as(u8, 1), a.list.len);
            try testing.expectEqual(@as(u32, 600), a.min_ttl_s);
            const got = a.list[0];
            try testing.expectEqual(@as(u8, 4), got.bytes_len);
            try testing.expectEqualSlices(u8, &expected_v4, got.bytes[0..4]);
        },
        else => return error.UnexpectedResultVariant,
    }
}

test "QueryOf(ScriptedIo): bind_device is applied through IO before DNS connect" {
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const txid: u16 = 0xB1D0;
    const host = "bound.varuna.local";
    const expected_v4 = [4]u8{ 203, 0, 113, 7 };
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, expected_v4, 300);
    try io.pushRecv(resp_buf[0..resp_len]);

    const QueryT = dns_custom.query.QueryOf(ScriptedIo);
    var query = try QueryT.create(testing.allocator, &io);
    defer query.destroy();

    const servers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53),
    };
    var capture = Capture{};
    try query.start(.{
        .host = host,
        .qtype = .a,
        .servers = &servers,
        .bind_device = "wg0",
        .txid = txid,
    }, &capture, captureCallback);

    try io.tick(64);

    try testing.expect(capture.delivered);
    const setsockopt_idx = io.firstOperationIndex(.setsockopt) orelse return error.MissingBindDeviceSetsockopt;
    const connect_idx = io.firstOperationIndex(.connect) orelse return error.MissingDnsConnect;
    try testing.expect(setsockopt_idx < connect_idx);
    try testing.expectEqual(std.posix.SOL.SOCKET, io.last_setsockopt_level);
    try testing.expectEqual(std.posix.SO.BINDTODEVICE, io.last_setsockopt_optname);
    try testing.expectEqualSlices(u8, "wg0\x00", io.last_setsockopt_value[0..io.last_setsockopt_value_len]);
}

test "QueryOf(ScriptedIo): NXDOMAIN delivers .nx_domain to caller" {
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const txid: u16 = 0xCAFE;
    const host = "nope.varuna.local";
    var resp_buf: [256]u8 = undefined;
    const resp_len = try buildNxDomainResponse(&resp_buf, txid, host);
    try io.pushRecv(resp_buf[0..resp_len]);

    const QueryT = dns_custom.query.QueryOf(ScriptedIo);
    var query = try QueryT.create(testing.allocator, &io);
    defer query.destroy();

    const servers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 1, 1, 1, 1 }, 53),
    };
    var capture = Capture{};
    try query.start(.{
        .host = host,
        .qtype = .a,
        .servers = &servers,
        .txid = txid,
    }, &capture, captureCallback);

    try io.tick(64);

    try testing.expect(capture.delivered);
    try testing.expect(capture.result != null);
    switch (capture.result.?) {
        .nx_domain => {},
        else => return error.UnexpectedResultVariant,
    }
}

test "DnsResolverOf.resolveAsync: A query resolves and caches answer" {
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const host = "resolver.varuna.local";
    const expected_v4 = [4]u8{ 198, 51, 100, 44 };
    var resp_buf: [512]u8 = undefined;
    // The resolver owns txid selection; tests can override it for deterministic packets.
    const txid: u16 = 0x4444;
    const resp_len = try buildAResponse(&resp_buf, txid, host, expected_v4, 120);
    try io.pushRecv(resp_buf[0..resp_len]);

    const servers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 9, 9, 9, 9 }, 53),
    };
    var resolver = try ScriptedResolver.init(testing.allocator, &io, .{
        .servers = &servers,
        .test_txid_override = txid,
    });
    defer resolver.deinit(testing.allocator);

    var capture = ResolverCapture{};
    const start = try resolver.resolveAsync(host, 8080, &capture, resolverCaptureCallback);
    const job = switch (start) {
        .pending => |pending| pending,
        .resolved => return error.UnexpectedImmediateResolve,
        .nx_domain, .failed => return error.UnexpectedImmediateResolveFailure,
    };
    defer job.destroy();

    try io.tick(128);

    try testing.expect(capture.delivered);
    const resolved = capture.resolved_addr orelse return error.MissingResolvedAddress;
    try testing.expectEqual(@as(u16, 8080), resolved.getPort());
    try testing.expectEqualSlices(u8, &expected_v4, std.mem.asBytes(&resolved.in.sa.addr));

    const cached = resolver.cacheLookup(host, 9090) orelse return error.MissingResolverCacheEntry;
    switch (cached) {
        .resolved => |addr| try testing.expectEqual(@as(u16, 9090), addr.getPort()),
        else => return error.UnexpectedNonResolved,
    }
}

test "HttpExecutorOf custom DNS consumes resolver callback path" {
    if (comptime dns.backend_tag != .custom) return error.SkipZigTest;

    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const host = "http-executor.varuna.local";
    const expected_v4 = [4]u8{ 198, 51, 100, 55 };
    const txid: u16 = 0x4854;
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, expected_v4, 180);
    try io.pushRecv(resp_buf[0..resp_len]);

    const HttpExecutor = varuna.io.http_executor.HttpExecutorOf(ScriptedIo);
    var executor = try HttpExecutor.create(testing.allocator, &io, .{
        .max_concurrent = 1,
        .max_per_host = 1,
        .dns_servers = &.{std.net.Address.initIp4(.{ 9, 9, 9, 9 }, 53)},
        .dns_test_txid_override = txid,
    });
    defer executor.destroy();

    const CallbackState = struct {
        called: bool = false,
        err: ?anyerror = null,

        fn complete(ctx: *anyopaque, result: HttpExecutor.RequestResult) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            self.err = result.err;
        }
    };
    var callback_state = CallbackState{};

    var job = HttpExecutor.Job{
        .context = &callback_state,
        .on_complete = CallbackState.complete,
    };
    const url = "http://http-executor.varuna.local/announce";
    @memcpy(job.url[0..url.len], url);
    job.url_len = url.len;
    @memcpy(job.host[0..host.len], host);
    job.host_len = host.len;

    try executor.submit(job);
    executor.tick();
    try io.tick(128);

    try testing.expect(io.firstOperationIndex(.send) != null);
    try testing.expect(io.firstOperationIndex(.recv) != null);
    try testing.expectEqual(@as(usize, 0), io.operationCount(.sendmsg));
    try testing.expectEqual(@as(usize, 2), io.operationCount(.socket));
}

test "UdpTrackerExecutorOf custom DNS consumes resolver callback path" {
    if (comptime dns.backend_tag != .custom) return error.SkipZigTest;

    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const host = "udp-executor.varuna.local";
    const expected_v4 = [4]u8{ 203, 0, 113, 88 };
    const txid: u16 = 0x5544;
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, expected_v4, 180);
    try io.pushRecv(resp_buf[0..resp_len]);

    const UdpExecutor = varuna.tracker.udp_executor.UdpTrackerExecutorOf(ScriptedIo);
    var random = varuna.runtime.random.Random.simRandom(0x5544);
    var executor = try UdpExecutor.create(testing.allocator, &io, &random, .{
        .max_slots = 1,
        .dns_servers = &.{std.net.Address.initIp4(.{ 1, 1, 1, 1 }, 53)},
        .dns_test_txid_override = txid,
    });
    defer executor.destroy();

    const CallbackState = struct {
        called: bool = false,
        err: ?anyerror = null,

        fn complete(ctx: *anyopaque, result: UdpExecutor.RequestResult) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            self.err = result.err;
        }
    };
    var callback_state = CallbackState{};

    var job = UdpExecutor.Job{
        .context = &callback_state,
        .on_complete = CallbackState.complete,
        .port = 6969,
    };
    @memcpy(job.host[0..host.len], host);
    job.host_len = host.len;

    try executor.submit(job);
    executor.tick();
    try io.tick(128);

    try testing.expect(io.firstOperationIndex(.send) != null);
    try testing.expect(io.firstOperationIndex(.recv) != null);
    try testing.expect(io.firstOperationIndex(.sendmsg) != null);
    try testing.expect(io.firstOperationIndex(.recvmsg) != null);
    try testing.expectEqual(@as(usize, 2), io.operationCount(.socket));
}

test "HttpExecutorOf custom DNS destroy while pending DNS is safe" {
    if (comptime dns.backend_tag != .custom) return error.SkipZigTest;

    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const host = "http-destroy-pending.varuna.local";
    const txid: u16 = 0x4844;
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, .{ 198, 51, 100, 77 }, 180);
    try io.pushRecv(resp_buf[0..resp_len]);

    const HttpExecutor = varuna.io.http_executor.HttpExecutorOf(ScriptedIo);
    var executor = try HttpExecutor.create(testing.allocator, &io, .{
        .max_concurrent = 1,
        .max_per_host = 1,
        .dns_servers = &.{std.net.Address.initIp4(.{ 9, 9, 9, 9 }, 53)},
        .dns_test_txid_override = txid,
    });

    const CallbackState = struct {
        called: bool = false,

        fn complete(ctx: *anyopaque, _: HttpExecutor.RequestResult) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var callback_state = CallbackState{};

    var job = HttpExecutor.Job{
        .context = &callback_state,
        .on_complete = CallbackState.complete,
    };
    const url = "http://http-destroy-pending.varuna.local/announce";
    @memcpy(job.url[0..url.len], url);
    job.url_len = url.len;
    @memcpy(job.host[0..host.len], host);
    job.host_len = host.len;

    try executor.submit(job);
    executor.tick();
    executor.destroy();

    try io.tick(128);
    try io.fireTimers(128);
    try testing.expect(!callback_state.called);
}

test "UdpTrackerExecutorOf custom DNS destroy while pending DNS is safe" {
    if (comptime dns.backend_tag != .custom) return error.SkipZigTest;

    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const host = "udp-destroy-pending.varuna.local";
    const txid: u16 = 0x5545;
    var resp_buf: [512]u8 = undefined;
    const resp_len = try buildAResponse(&resp_buf, txid, host, .{ 203, 0, 113, 99 }, 180);
    try io.pushRecv(resp_buf[0..resp_len]);

    const UdpExecutor = varuna.tracker.udp_executor.UdpTrackerExecutorOf(ScriptedIo);
    var random = varuna.runtime.random.Random.simRandom(0x5545);
    var executor = try UdpExecutor.create(testing.allocator, &io, &random, .{
        .max_slots = 1,
        .dns_servers = &.{std.net.Address.initIp4(.{ 1, 1, 1, 1 }, 53)},
        .dns_test_txid_override = txid,
    });

    const CallbackState = struct {
        called: bool = false,

        fn complete(ctx: *anyopaque, _: UdpExecutor.RequestResult) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var callback_state = CallbackState{};

    var job = UdpExecutor.Job{
        .context = &callback_state,
        .on_complete = CallbackState.complete,
        .port = 6969,
    };
    @memcpy(job.host[0..host.len], host);
    job.host_len = host.len;

    try executor.submit(job);
    executor.tick();
    executor.destroy();

    try io.tick(128);
    try io.fireTimers(128);
    try testing.expect(!callback_state.called);
}

test "QueryOf(ScriptedIo): wrong-txid response is dropped (re-arms recv)" {
    // Off-path attacker scenario: a response with a txid that
    // doesn't match the query's is silently dropped and recv is
    // re-armed. Without a follow-up valid response the query will
    // eventually fail (no scripted recv → ConnectionResetByPeer →
    // advance servers → all servers exhausted → .failed).
    var io = ScriptedIo.init(testing.allocator);
    defer io.deinit();

    const correct_txid: u16 = 0x1111;
    const wrong_txid: u16 = 0x2222;
    const host = "spoof.varuna.local";

    // Push one wrong-txid response, then nothing else (so the
    // re-armed recv fails with ConnectionResetByPeer).
    var resp_buf: [256]u8 = undefined;
    const resp_len = try buildAResponse(
        &resp_buf,
        wrong_txid,
        host,
        .{ 6, 6, 6, 6 },
        600,
    );
    try io.pushRecv(resp_buf[0..resp_len]);

    const QueryT = dns_custom.query.QueryOf(ScriptedIo);
    var query = try QueryT.create(testing.allocator, &io);
    defer query.destroy();

    const servers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 8, 8, 4, 4 }, 53),
    };
    var capture = Capture{};
    try query.start(.{
        .host = host,
        .qtype = .a,
        .servers = &servers,
        .txid = correct_txid,
    }, &capture, captureCallback);

    try io.tick(128);

    try testing.expect(capture.delivered);
    try testing.expect(capture.result != null);
    switch (capture.result.?) {
        .failed => {},
        // .answers would mean the spoofed response was accepted —
        // that's the bug the txid match defends against.
        else => return error.UnexpectedResultVariant,
    }
}

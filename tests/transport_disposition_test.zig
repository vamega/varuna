const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const config_mod = varuna.config;
const TransportDisposition = config_mod.TransportDisposition;
const EventLoop = varuna.io.event_loop.EventLoop;
const event_loop_mod = varuna.io.event_loop;
const Transport = varuna.io.event_loop.Transport;
const Clock = varuna.io.Clock;
const SimIO = varuna.io.sim_io.SimIO;
const UtpManager = varuna.net.utp_manager.UtpManager;
const handlers_mod = varuna.rpc.handlers;
const server_mod = varuna.rpc.server;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const utp_handler = varuna.io.utp_handler;

fn activePeerCountByTransport(el: anytype, transport: Transport) u16 {
    var count: u16 = 0;
    for (el.peers) |peer| {
        if (peer.state != .free and peer.transport == transport) count += 1;
    }
    return count;
}

// ── Test 1: TCP-only mode rejects outbound uTP ───────────────
//
// When the disposition is tcp_only, selectTransport() must never
// return .utp regardless of the internal counter state.

test "tcp_only disposition never selects utp for outbound" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_only;

    for (0..100) |_| {
        try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    }
}

// ── Test 2: uTP-only mode rejects outbound TCP ──────────────
//
// When the disposition is utp_only, selectTransport() must always
// return .utp.

test "utp_only disposition never selects tcp for outbound" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.transport_disposition = TransportDisposition.utp_only;

    for (0..100) |_| {
        try std.testing.expectEqual(Transport.utp, el.selectTransport());
    }
}

// ── Test 3: Asymmetric configuration ─────────────────────────
//
// Test with outgoing_tcp=true, outgoing_utp=false, incoming_tcp=false,
// incoming_utp=true. The selectTransport() function should only return
// TCP for outbound, while the disposition flags are independently correct.

test "asymmetric disposition: outgoing tcp only, incoming utp only" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.transport_disposition = .{
        .outgoing_tcp = true,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = true,
    };

    // Outbound should always be TCP since outgoing_utp is disabled
    for (0..50) |_| {
        try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    }

    // Verify the inbound flags are set correctly
    try std.testing.expect(!el.transport_disposition.incoming_tcp);
    try std.testing.expect(el.transport_disposition.incoming_utp);

    // canConnectOutbound should be true (outgoing_tcp is enabled)
    try std.testing.expect(el.transport_disposition.canConnectOutbound());
    // canAcceptInbound should be true (incoming_utp is enabled)
    try std.testing.expect(el.transport_disposition.canAcceptInbound());
}

test "asymmetric disposition: outgoing utp only, incoming tcp only" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.transport_disposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = true,
        .incoming_tcp = true,
        .incoming_utp = false,
    };

    // Outbound should always be uTP since outgoing_tcp is disabled
    for (0..50) |_| {
        try std.testing.expectEqual(Transport.utp, el.selectTransport());
    }

    // Verify the inbound flags
    try std.testing.expect(el.transport_disposition.incoming_tcp);
    try std.testing.expect(!el.transport_disposition.incoming_utp);
}

test "disposition with no outgoing falls back to tcp" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Incoming-only disposition: no outgoing transport at all
    el.transport_disposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = false,
        .incoming_tcp = true,
        .incoming_utp = true,
    };

    // selectTransport falls back to TCP as a safe default
    for (0..10) |_| {
        try std.testing.expectEqual(Transport.tcp, el.selectTransport());
    }

    try std.testing.expect(!el.transport_disposition.canConnectOutbound());
    try std.testing.expect(el.transport_disposition.canAcceptInbound());
}

test "utp_only auto transport does not fall back to tcp when utp setup is unavailable" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const fake_udp_fd = posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    el.udp_fd = fake_udp_fd;
    el.utp_manager = null;
    el.transport_disposition = TransportDisposition.utp_only;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x42} ** 20,
        .peer_id = "-VR0001-test00000001".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6881);

    try std.testing.expectError(error.NoUtpManager, el.addPeerAutoTransport(addr, tid));
    try std.testing.expectEqual(@as(u32, 0), el.peer_count);
}

test "tcp_and_utp auto transport starts with tcp" {
    const EL = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(std.testing.allocator, .{ .seed = 0x7470 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const fake_udp_fd = posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    el.udp_fd = fake_udp_fd;
    const mgr = try std.testing.allocator.create(UtpManager);
    mgr.* = UtpManager.init(std.testing.allocator);
    el.utp_manager = mgr;
    el.clock = Clock.simAtMs(1000);
    el.transport_disposition = TransportDisposition.tcp_and_utp;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x55} ** 20,
        .peer_id = "-VR0001-test00000002".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6882);

    const slot = try el.addPeerAutoTransport(addr, tid);
    try std.testing.expectEqual(Transport.tcp, el.peers[slot].transport);
    try std.testing.expectEqual(@as(u16, 0), activePeerCountByTransport(&el, .utp));
    try std.testing.expectEqual(@as(u16, 1), activePeerCountByTransport(&el, .tcp));
}

test "silent utp connect falls back to tcp after connect timeout" {
    const EL = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(std.testing.allocator, .{ .seed = 0x7471 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const fake_udp_fd = posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    el.udp_fd = fake_udp_fd;
    const mgr = try std.testing.allocator.create(UtpManager);
    mgr.* = UtpManager.init(std.testing.allocator);
    el.utp_manager = mgr;
    el.clock = Clock.simAtMs(1000);
    el.transport_disposition = TransportDisposition.tcp_and_utp;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x56} ** 20,
        .peer_id = "-VR0001-test00000003".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6883);

    _ = try el.addUtpPeer(addr, tid);
    try std.testing.expectEqual(@as(u16, 1), activePeerCountByTransport(&el, .utp));

    el.clock.advanceMs(3000);
    utp_handler.utpTick(&el);

    try std.testing.expectEqual(@as(u16, 0), activePeerCountByTransport(&el, .utp));
    try std.testing.expectEqual(@as(u16, 1), activePeerCountByTransport(&el, .tcp));
}

test "utp connect fallback is not starved by frequent ticks" {
    const EL = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(std.testing.allocator, .{ .seed = 0x7472 });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    const fake_udp_fd = posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    ) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    el.udp_fd = fake_udp_fd;
    const mgr = try std.testing.allocator.create(UtpManager);
    mgr.* = UtpManager.init(std.testing.allocator);
    el.utp_manager = mgr;
    el.clock = Clock.simAtMs(1000);
    el.transport_disposition = TransportDisposition.tcp_and_utp;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x57} ** 20,
        .peer_id = "-VR0001-test00000004".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6884);

    _ = try el.addUtpPeer(addr, tid);

    el.clock.advanceMs(1000);
    utp_handler.utpTick(&el);
    try std.testing.expectEqual(@as(u16, 1), activePeerCountByTransport(&el, .utp));

    for (0..20) |_| {
        el.clock.advanceMs(100);
        utp_handler.utpTick(&el);
    }

    try std.testing.expectEqual(@as(u16, 0), activePeerCountByTransport(&el, .utp));
    try std.testing.expectEqual(@as(u16, 1), activePeerCountByTransport(&el, .tcp));
}

test "outbound tcp peer connect carries a deadline" {
    const EL = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(std.testing.allocator, .{
        .seed = 0x7473,
        .max_ops_per_tick = 1,
    });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_only;
    el.peer_connect_timeout_ns = 3 * std.time.ns_per_s;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x58} ** 20,
        .peer_id = "-VR0001-test00000005".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6885);

    const slot = try el.addPeerForTorrent(addr, tid);
    try el.io.tick(1);

    switch (el.peers[slot].connect_completion.op) {
        .connect => |op| try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), op.deadline_ns.?),
        else => try std.testing.expect(false),
    }
}

test "outbound tcp peer connect uses configured deadline" {
    const EL = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(std.testing.allocator, .{
        .seed = 0x7474,
        .max_ops_per_tick = 1,
    });
    var el = try EL.initBareWithIO(std.testing.allocator, sim_io, 0);
    defer el.deinit();

    el.transport_disposition = TransportDisposition.tcp_only;
    el.peer_connect_timeout_ns = 1250 * std.time.ns_per_ms;

    const empty_fds = [_]posix.fd_t{};
    const tid = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0x59} ** 20,
        .peer_id = "-VR0001-test00000006".*,
    });
    const addr = try std.net.Address.parseIp4("127.0.0.1", 6886);

    const slot = try el.addPeerForTorrent(addr, tid);
    try el.io.tick(1);

    switch (el.peers[slot].connect_completion.op) {
        .connect => |op| try std.testing.expectEqual(@as(u64, 1250 * std.time.ns_per_ms), op.deadline_ns.?),
        else => try std.testing.expect(false),
    }
}

// ── Test 4: Runtime toggle via API ───────────────────────────
//
// Start with default (all transports), change to tcp_only via the
// setPreferences endpoint, and verify the change via getPreferences.

const TestCtx = struct {
    handler: handlers_mod.ApiHandler,
    sm: *SessionManager,
    sid: [32]u8,

    fn init() !TestCtx {
        const sm = try std.testing.allocator.create(SessionManager);
        sm.* = SessionManager.init(std.testing.allocator);
        sm.default_save_path = "/tmp/test-downloads";

        // Create a bare event loop for the handler to modify.
        const el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
            sm.deinit();
            std.testing.allocator.destroy(sm);
            return err;
        };
        const el_ptr = try std.testing.allocator.create(EventLoop);
        el_ptr.* = el;
        el_ptr.port = 0; // ephemeral port to avoid AddressInUse in tests
        sm.shared_event_loop = el_ptr;

        var handler = handlers_mod.ApiHandler{
            .session_manager = sm,
            .sync_state = .{ .allocator = std.testing.allocator },
            .peer_sync_state = .{ .allocator = std.testing.allocator },
        };
        const sid = handler.session_store.createSession(&el_ptr.random);
        return .{ .handler = handler, .sm = sm, .sid = sid };
    }

    fn deinit(self: *TestCtx) void {
        if (self.sm.shared_event_loop) |el| {
            el.deinit();
            std.testing.allocator.destroy(el);
        }
        self.sm.deinit();
        std.testing.allocator.destroy(self.sm);
    }

    fn handle(self: *TestCtx, method: []const u8, path: []const u8, body: []const u8) server_mod.Response {
        return self.handler.handle(std.testing.allocator, .{
            .method = method,
            .path = path,
            .body = body,
            .cookie_sid = &self.sid,
        });
    }
};

test "runtime toggle via API: change from all to tcp_only using form params" {
    var ctx = TestCtx.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer ctx.deinit();

    const el = ctx.sm.shared_event_loop.?;

    // Verify initial state: all transports enabled
    try std.testing.expect(el.transport_disposition.outgoing_tcp);
    try std.testing.expect(el.transport_disposition.outgoing_utp);
    try std.testing.expect(el.transport_disposition.incoming_tcp);
    try std.testing.expect(el.transport_disposition.incoming_utp);

    // Set to tcp_only via transport_disposition bitfield (5 = tcp_only)
    const resp = ctx.handle("POST", "/api/v2/app/setPreferences", "transport_disposition=5");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // Verify the event loop's disposition was updated
    try std.testing.expect(el.transport_disposition.outgoing_tcp);
    try std.testing.expect(!el.transport_disposition.outgoing_utp);
    try std.testing.expect(el.transport_disposition.incoming_tcp);
    try std.testing.expect(!el.transport_disposition.incoming_utp);
    try std.testing.expectEqual(@as(u8, 5), el.transport_disposition.toBitfield());
}

test "runtime toggle via API: change from all to tcp_only using JSON body" {
    var ctx = TestCtx.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer ctx.deinit();

    const el = ctx.sm.shared_event_loop.?;

    // Set to tcp_only using the JSON API: disable both uTP directions
    const body = "{\"outgoing_utp\":false,\"incoming_utp\":false}";
    const resp = ctx.handle("POST", "/api/v2/app/setPreferences", "json=" ++ body);
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // outgoing_tcp and incoming_tcp should remain true (unchanged)
    try std.testing.expect(el.transport_disposition.outgoing_tcp);
    try std.testing.expect(el.transport_disposition.incoming_tcp);
    // uTP should be disabled
    try std.testing.expect(!el.transport_disposition.outgoing_utp);
    try std.testing.expect(!el.transport_disposition.incoming_utp);
}

test "runtime toggle via API: granular flags override legacy enable_utp" {
    var ctx = TestCtx.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer ctx.deinit();

    const el = ctx.sm.shared_event_loop.?;

    // Send both enable_utp=false AND a granular flag: granular should win
    const resp = ctx.handle("POST", "/api/v2/app/setPreferences", "enable_utp=false&outgoing_utp=true");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // outgoing_utp should be true (granular flag took precedence)
    try std.testing.expect(el.transport_disposition.outgoing_utp);
}

test "runtime toggle via API: legacy enable_utp=false sets tcp_only" {
    var ctx = TestCtx.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer ctx.deinit();

    const el = ctx.sm.shared_event_loop.?;

    // Set enable_utp=false with no granular fields
    const resp = ctx.handle("POST", "/api/v2/app/setPreferences", "enable_utp=false");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    try std.testing.expect(el.transport_disposition.outgoing_tcp);
    try std.testing.expect(!el.transport_disposition.outgoing_utp);
    try std.testing.expect(el.transport_disposition.incoming_tcp);
    try std.testing.expect(!el.transport_disposition.incoming_utp);
}

test "runtime toggle via API: getPreferences reflects transport fields" {
    var ctx = TestCtx.init() catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer ctx.deinit();

    const el = ctx.sm.shared_event_loop.?;

    // Set asymmetric disposition
    el.transport_disposition = .{
        .outgoing_tcp = true,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = true,
    };

    // Read preferences back
    const resp = ctx.handle("GET", "/api/v2/app/preferences", "");
    defer if (resp.owned_body) |b| std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // The response body is JSON; verify the transport fields are present
    const body = resp.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"outgoing_tcp\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"outgoing_utp\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"incoming_tcp\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"incoming_utp\":true") != null);
    // Bitfield for {outgoing_tcp=true, outgoing_utp=false, incoming_tcp=false, incoming_utp=true} = 0b1001 = 9
    try std.testing.expect(std.mem.indexOf(u8, body, "\"transport_disposition\":9") != null);
}

// ── Test 5: Listener lifecycle ───────────────────────────────
//
// Verify that reconcileListeners() correctly starts and stops
// TCP and UDP listeners based on transport_disposition flags.

test "listener lifecycle: incoming_tcp=false means no TCP listen socket" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Start with incoming TCP disabled
    el.transport_disposition = .{
        .outgoing_tcp = true,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = false,
    };
    el.port = 0; // any port

    // listen_fd should be -1 by default (no listener started)
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);

    // reconcileListeners should NOT start TCP listener
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);
}

test "listener lifecycle: enable incoming_tcp starts TCP listener via reconcile" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    // Use a high port to avoid conflicts
    el.port = 0; // kernel-assigned ephemeral port

    // Start without TCP listener
    el.transport_disposition.incoming_tcp = false;
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);

    // Now enable incoming TCP and reconcile
    el.transport_disposition.incoming_tcp = true;
    el.reconcileListeners();

    // listen_fd should be a valid fd (>= 0)
    try std.testing.expect(el.listen_fd >= 0);
}

test "listener lifecycle: disable incoming_tcp stops TCP listener via reconcile" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.port = 0;

    // Start TCP listener
    el.transport_disposition.incoming_tcp = true;
    el.reconcileListeners();
    try std.testing.expect(el.listen_fd >= 0);
    const old_fd = el.listen_fd;
    _ = old_fd;

    // Disable and reconcile -- should close the socket
    el.transport_disposition.incoming_tcp = false;
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);
}

test "listener lifecycle: incoming_utp=false means no UDP listen socket" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.transport_disposition = .{
        .outgoing_tcp = true,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = false,
    };

    // No DHT engine, no incoming uTP -- UDP socket should stay closed
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);
}

test "listener lifecycle: enable incoming_utp starts UDP listener via reconcile" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.port = 0;

    // Start without uTP
    el.transport_disposition.incoming_utp = false;
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);

    // Enable incoming uTP
    el.transport_disposition.incoming_utp = true;
    el.reconcileListeners();

    // UDP socket should be open, and utp_manager should be initialized
    try std.testing.expect(el.udp_fd >= 0);
    try std.testing.expect(el.utp_manager != null);
}

test "listener lifecycle: disable incoming_utp stops UDP listener via reconcile" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.port = 0;

    // Start UDP listener
    el.transport_disposition.incoming_utp = true;
    el.reconcileListeners();
    try std.testing.expect(el.udp_fd >= 0);
    try std.testing.expect(el.utp_manager != null);

    // Disable and reconcile
    el.transport_disposition.incoming_utp = false;
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);
    try std.testing.expect(el.utp_manager == null);
}

test "listener lifecycle: TCP and UDP toggled together" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.port = 0;

    // Start with everything disabled
    el.transport_disposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = false,
    };
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);

    // Enable both at once
    el.transport_disposition.incoming_tcp = true;
    el.transport_disposition.incoming_utp = true;
    el.reconcileListeners();
    try std.testing.expect(el.listen_fd >= 0);
    try std.testing.expect(el.udp_fd >= 0);

    // Disable both at once
    el.transport_disposition.incoming_tcp = false;
    el.transport_disposition.incoming_utp = false;
    el.reconcileListeners();
    try std.testing.expectEqual(@as(i32, -1), el.listen_fd);
    try std.testing.expectEqual(@as(i32, -1), el.udp_fd);
}

test "listener lifecycle: reconcile is idempotent" {
    var el = EventLoop.initBare(std.testing.allocator, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    el.port = 0;

    // Start TCP listener
    el.transport_disposition.incoming_tcp = true;
    el.transport_disposition.incoming_utp = false;
    el.reconcileListeners();
    const tcp_fd = el.listen_fd;
    try std.testing.expect(tcp_fd >= 0);

    // Calling reconcile again should not change the fd (already started)
    el.reconcileListeners();
    try std.testing.expectEqual(tcp_fd, el.listen_fd);
}

// ── Test 6: Config file parsing ──────────────────────────────
//
// Verify TOML config files produce the correct TransportDisposition.

test "config file: transport = all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "transport-all.toml",
        .data = "[network]\ntransport = \"all\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "transport-all.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
    try std.testing.expectEqual(@as(u8, 15), disp.toBitfield());
}

test "config file: transport = tcp_only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "transport-tcp.toml",
        .data = "[network]\ntransport = \"tcp_only\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "transport-tcp.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(!disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
    try std.testing.expectEqual(@as(u8, 5), disp.toBitfield());
}

test "config file: transport = utp_only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "transport-utp.toml",
        .data = "[network]\ntransport = \"utp_only\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "transport-utp.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(!disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(!disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
    try std.testing.expectEqual(@as(u8, 10), disp.toBitfield());
}

test "config file: transport as array of flags (asymmetric)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "transport-flags.toml",
        .data = "[network]\ntransport = [\"tcp_inbound\", \"utp_outbound\"]\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "transport-flags.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(!disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
}

test "config file: enable_utp = false (legacy)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "legacy-utp.toml",
        .data = "[network]\nenable_utp = false\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "legacy-utp.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    // enable_utp=false should resolve to tcp_only
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(!disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
}

test "config file: transport overrides enable_utp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    // transport = "utp_only" should take precedence over enable_utp = false
    try tmp.dir.writeFile(.{
        .sub_path = "override.toml",
        .data = "[network]\nenable_utp = false\ntransport = \"utp_only\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "override.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(!disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(!disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
}

test "config file: transport array with all four flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = std.fs.cwd().openDir(".", .{}) catch return error.SkipZigTest;
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "all-flags.toml",
        .data = "[network]\ntransport = [\"tcp_inbound\", \"tcp_outbound\", \"utp_inbound\", \"utp_outbound\"]\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try config_mod.load(std.testing.allocator, "all-flags.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
    try std.testing.expectEqual(@as(u8, 15), disp.toBitfield());
}

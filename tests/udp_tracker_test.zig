const std = @import("std");
const varuna = @import("varuna");
const udp = varuna.tracker.udp;

// ── UDP Tracker Integration Tests (BEP 15) ──────────────────
//
// These tests create real UDP socket pairs (loopback) and run the
// full BEP 15 protocol exchange: connect -> announce, connect -> scrape.
// A mock server thread responds to client requests.

/// Create a UDP socket bound to a loopback port.
fn createBoundUdpSocket(port: u16) !std.posix.fd_t {
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        std.posix.IPPROTO.UDP,
    );
    errdefer std.posix.close(fd);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// Get the actual bound port of a socket.
fn getBoundPort(fd: std.posix.fd_t) !u16 {
    var addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    try std.posix.getsockname(fd, @ptrCast(&addr), &addrlen);
    const addr_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr));
    return std.mem.bigToNative(u16, addr_in.port);
}

/// Mock UDP tracker server: handles connect and announce requests.
fn mockTrackerServer(server_fd: std.posix.fd_t, ready: *std.atomic.Value(bool)) void {
    ready.store(true, .release);

    var client_addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    var buf: [256]u8 = undefined;

    // Set a receive timeout so we don't block forever
    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(server_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Handle up to 4 messages (connect + announce + possible scrape + extra)
    for (0..4) |_| {
        addrlen = @sizeOf(std.posix.sockaddr.storage);
        const n = std.posix.recvfrom(server_fd, &buf, 0, @ptrCast(&client_addr), &addrlen) catch break;
        if (n < 12) continue;

        const action = std.mem.readInt(u32, buf[8..12], .big);
        const transaction_id = std.mem.readInt(u32, buf[12..16], .big);

        if (action == 0) {
            // Connect request
            var resp: [16]u8 = undefined;
            std.mem.writeInt(u32, resp[0..4], 0, .big); // action = connect
            std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
            std.mem.writeInt(u64, resp[8..16], 0xDEADBEEFCAFEBABE, .big); // connection_id
            _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
        } else if (action == 1 and n >= 16) {
            // Announce request
            var resp: [26]u8 = undefined;
            std.mem.writeInt(u32, resp[0..4], 1, .big); // action = announce
            std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
            std.mem.writeInt(u32, resp[8..12], 1800, .big); // interval
            std.mem.writeInt(u32, resp[12..16], 3, .big); // leechers
            std.mem.writeInt(u32, resp[16..20], 7, .big); // seeders
            // 1 peer: 10.0.0.1:51413
            resp[20] = 10;
            resp[21] = 0;
            resp[22] = 0;
            resp[23] = 1;
            std.mem.writeInt(u16, resp[24..26], 51413, .big);
            _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
        } else if (action == 2 and n >= 16) {
            // Scrape request
            var resp: [20]u8 = undefined;
            std.mem.writeInt(u32, resp[0..4], 2, .big); // action = scrape
            std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
            std.mem.writeInt(u32, resp[8..12], 42, .big); // seeders
            std.mem.writeInt(u32, resp[12..16], 100, .big); // completed
            std.mem.writeInt(u32, resp[16..20], 5, .big); // leechers
            _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
        }
    }
}

test "full UDP connect then announce over real sockets" {
    // Create a mock tracker server
    const server_fd = try createBoundUdpSocket(0);
    defer std.posix.close(server_fd);
    const port = try getBoundPort(server_fd);

    // Start mock server thread
    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, mockTrackerServer, .{ server_fd, &ready });

    // Wait for server to be ready
    while (!ready.load(.acquire)) {}

    // Build the announce URL
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "udp://127.0.0.1:{d}/announce", .{port}) catch unreachable;

    // Perform the UDP announce
    const response = try udp.fetchViaUdp(std.testing.allocator, .{
        .announce_url = url,
        .info_hash = [_]u8{0xAA} ** 20,
        .peer_id = [_]u8{0xBB} ** 20,
        .port = 6881,
        .left = 1024 * 1024,
        .event = .started,
    });
    defer std.testing.allocator.free(response.peers);

    // Verify the response
    try std.testing.expectEqual(@as(u32, 1800), response.interval);
    try std.testing.expectEqual(@as(usize, 1), response.peers.len);
    try std.testing.expectEqual(@as(u16, 51413), response.peers[0].address.getPort());
    try std.testing.expectEqual(@as(?u32, 7), response.complete);
    try std.testing.expectEqual(@as(?u32, 3), response.incomplete);

    thread.join();
}

test "full UDP connect then scrape over real sockets" {
    // Clear the global connection cache from any previous tests
    udp.resetGlobalCache();

    const server_fd = try createBoundUdpSocket(0);
    defer std.posix.close(server_fd);
    const port = try getBoundPort(server_fd);

    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, mockTrackerServer, .{ server_fd, &ready });

    while (!ready.load(.acquire)) {}

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "udp://127.0.0.1:{d}/announce", .{port}) catch unreachable;

    const result = try udp.scrapeViaUdp(std.testing.allocator, url, [_]u8{0xCC} ** 20);

    try std.testing.expectEqual(@as(u32, 42), result.complete);
    try std.testing.expectEqual(@as(u32, 5), result.incomplete);
    try std.testing.expectEqual(@as(u32, 100), result.downloaded);

    thread.join();
}

/// Mock server that sends an error response.
fn mockErrorServer(server_fd: std.posix.fd_t, ready: *std.atomic.Value(bool)) void {
    ready.store(true, .release);

    var client_addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    var buf: [256]u8 = undefined;

    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(server_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    for (0..4) |_| {
        addrlen = @sizeOf(std.posix.sockaddr.storage);
        const n = std.posix.recvfrom(server_fd, &buf, 0, @ptrCast(&client_addr), &addrlen) catch break;
        if (n < 12) continue;

        const transaction_id = std.mem.readInt(u32, buf[12..16], .big);

        // Always respond with error
        const error_msg = "tracker unavailable";
        var resp: [8 + error_msg.len]u8 = undefined;
        std.mem.writeInt(u32, resp[0..4], 3, .big); // action = error
        std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
        @memcpy(resp[8..], error_msg);
        _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
    }
}

test "error response from tracker" {
    udp.resetGlobalCache();
    const server_fd = try createBoundUdpSocket(0);
    defer std.posix.close(server_fd);
    const port = try getBoundPort(server_fd);

    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, mockErrorServer, .{ server_fd, &ready });

    while (!ready.load(.acquire)) {}

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "udp://127.0.0.1:{d}/announce", .{port}) catch unreachable;

    const result = udp.fetchViaUdp(std.testing.allocator, .{
        .announce_url = url,
        .info_hash = [_]u8{0xAA} ** 20,
        .peer_id = [_]u8{0xBB} ** 20,
        .port = 6881,
        .left = 1024,
    });

    // Should get a TrackerError or TrackerTimeout
    try std.testing.expect(result == error.TrackerError or result == error.TrackerTimeout);

    thread.join();
}

/// Mock server that responds to connect then second announce with connection ID reuse.
fn mockServerWithConnectionReuse(server_fd: std.posix.fd_t, ready: *std.atomic.Value(bool)) void {
    ready.store(true, .release);

    var client_addr: std.posix.sockaddr.storage = undefined;
    var addrlen: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    var buf: [256]u8 = undefined;

    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(server_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    const conn_id: u64 = 0xAAAABBBBCCCCDDDD;

    for (0..6) |_| {
        addrlen = @sizeOf(std.posix.sockaddr.storage);
        const n = std.posix.recvfrom(server_fd, &buf, 0, @ptrCast(&client_addr), &addrlen) catch break;
        if (n < 12) continue;

        const action = std.mem.readInt(u32, buf[8..12], .big);
        const transaction_id = std.mem.readInt(u32, buf[12..16], .big);

        if (action == 0) {
            // Connect
            var resp: [16]u8 = undefined;
            std.mem.writeInt(u32, resp[0..4], 0, .big);
            std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
            std.mem.writeInt(u64, resp[8..16], conn_id, .big);
            _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
        } else if (action == 1 and n >= 16) {
            // Verify the connection ID is correct
            const req_conn_id = std.mem.readInt(u64, buf[0..8], .big);
            if (req_conn_id != conn_id) {
                // Send error
                const error_msg = "invalid connection id";
                var resp: [8 + error_msg.len]u8 = undefined;
                std.mem.writeInt(u32, resp[0..4], 3, .big);
                std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
                @memcpy(resp[8..], error_msg);
                _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
            } else {
                var resp: [20]u8 = undefined;
                std.mem.writeInt(u32, resp[0..4], 1, .big);
                std.mem.writeInt(u32, resp[4..8], transaction_id, .big);
                std.mem.writeInt(u32, resp[8..12], 900, .big);
                std.mem.writeInt(u32, resp[12..16], 0, .big);
                std.mem.writeInt(u32, resp[16..20], 1, .big);
                _ = std.posix.sendto(server_fd, &resp, 0, @ptrCast(&client_addr), addrlen) catch {};
            }
        }
    }
}

test "connection ID reuse across announces" {
    udp.resetGlobalCache();
    const server_fd = try createBoundUdpSocket(0);
    defer std.posix.close(server_fd);
    const port = try getBoundPort(server_fd);

    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, mockServerWithConnectionReuse, .{ server_fd, &ready });

    while (!ready.load(.acquire)) {}

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "udp://127.0.0.1:{d}/announce", .{port}) catch unreachable;

    // First announce: connect + announce
    const resp1 = try udp.fetchViaUdp(std.testing.allocator, .{
        .announce_url = url,
        .info_hash = [_]u8{0xDD} ** 20,
        .peer_id = [_]u8{0xEE} ** 20,
        .port = 6881,
        .left = 0,
        .event = .started,
    });
    defer std.testing.allocator.free(resp1.peers);
    try std.testing.expectEqual(@as(u32, 900), resp1.interval);

    // Second announce: should reuse cached connection ID (no connect needed)
    const resp2 = try udp.fetchViaUdp(std.testing.allocator, .{
        .announce_url = url,
        .info_hash = [_]u8{0xDD} ** 20,
        .peer_id = [_]u8{0xEE} ** 20,
        .port = 6881,
        .left = 0,
        .event = null,
    });
    defer std.testing.allocator.free(resp2.peers);
    try std.testing.expectEqual(@as(u32, 900), resp2.interval);

    thread.join();
}

// ── Packet encoding/decoding unit tests ──────────────────

test "connect request is exactly 16 bytes with correct protocol ID" {
    const req = udp.ConnectRequest{ .transaction_id = 0xCAFE };
    const buf = req.encode();
    try std.testing.expectEqual(@as(usize, 16), buf.len);
    try std.testing.expectEqual(udp.protocol_id, std.mem.readInt(u64, buf[0..8], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[8..12], .big));
}

test "announce request roundtrip" {
    const req = udp.AnnounceRequest{
        .connection_id = 0x1234,
        .transaction_id = 0x5678,
        .info_hash = [_]u8{1} ** 20,
        .peer_id = [_]u8{2} ** 20,
        .downloaded = 1000,
        .left = 2000,
        .uploaded = 500,
        .event = .completed,
        .ip = 0,
        .key = 42,
        .num_want = 100,
        .port = 51413,
    };
    const buf = req.encode();
    const decoded = try udp.AnnounceRequest.decode(&buf);
    try std.testing.expectEqual(req.connection_id, decoded.connection_id);
    try std.testing.expectEqual(req.event, decoded.event);
    try std.testing.expectEqual(req.port, decoded.port);
    try std.testing.expectEqual(req.num_want, decoded.num_want);
}

test "scrape single hash request is 36 bytes" {
    const buf = udp.ScrapeRequest.encodeSingle(0xAABB, 0xCCDD, [_]u8{0xFF} ** 20);
    try std.testing.expectEqual(@as(usize, 36), buf.len);
    try std.testing.expectEqual(@as(u32, @intFromEnum(udp.Action.scrape)), std.mem.readInt(u32, buf[8..12], .big));
}

test "retransmit timeouts follow BEP 15 spec" {
    // BEP 15: 15 * 2^n seconds, capped at max_retries=4
    try std.testing.expectEqual(@as(u64, 15), udp.retransmitTimeout(0));
    try std.testing.expectEqual(@as(u64, 30), udp.retransmitTimeout(1));
    try std.testing.expectEqual(@as(u64, 60), udp.retransmitTimeout(2));
    try std.testing.expectEqual(@as(u64, 120), udp.retransmitTimeout(3));
    try std.testing.expectEqual(@as(u64, 240), udp.retransmitTimeout(4)); // max
    try std.testing.expectEqual(@as(u64, 240), udp.retransmitTimeout(20)); // clamped
}

test "connection cache TTL expiry" {
    var cache = udp.ConnectionCache{};
    // Put with a fake timestamp by directly setting obtained_at
    cache.put("tracker.test", 6969, 0x1234);

    // Manually expire by setting obtained_at far in the past
    for (&cache.entries) |*e| {
        if (e.valid and e.port == 6969) {
            e.obtained_at -= udp.connection_id_ttl_secs + 1;
            break;
        }
    }

    // Should be expired now
    try std.testing.expect(cache.get("tracker.test", 6969) == null);
}

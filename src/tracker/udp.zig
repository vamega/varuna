const std = @import("std");
const posix = std.posix;
const Ring = @import("../io/ring.zig").Ring;
const announce_mod = @import("announce.zig");

/// UDP tracker protocol (BEP 15).
/// All I/O via io_uring sendmsg/recvmsg.
const protocol_id: u64 = 0x41727101980; // magic constant
const action_connect: u32 = 0;
const action_announce: u32 = 1;

pub fn fetchViaUdp(
    allocator: std.mem.Allocator,
    ring: *Ring,
    request: announce_mod.Request,
) !announce_mod.Response {
    const parsed = parseUdpUrl(request.announce_url) orelse return error.InvalidTrackerUrl;

    // Resolve address
    const address = try resolveAddress(allocator, parsed.host, parsed.port);

    // Create UDP socket
    const fd = try ring.socket(
        address.any.family,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    );
    defer posix.close(fd);

    // Set a receive timeout so we don't block forever on lost packets (BEP 15).
    // Initial timeout is 15 seconds per BEP 15 specification.
    const timeout = posix.timeval{ .sec = 15, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Connect the UDP socket (allows send/recv instead of sendto/recvfrom)
    try ring.connect(fd, &address.any, address.getOsSockLen());

    // Step 1: Connect
    const transaction_id = generateTransactionId();
    var connect_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, connect_buf[0..8], protocol_id, .big);
    std.mem.writeInt(u32, connect_buf[8..12], action_connect, .big);
    std.mem.writeInt(u32, connect_buf[12..16], transaction_id, .big);

    // BEP 15: retry with exponential backoff (15 * 2^n seconds, n=0..3)
    var connection_id: u64 = undefined;
    var connect_ok = false;
    for (0..4) |attempt| {
        // Update timeout: 15 * 2^attempt seconds
        const timeout_secs: i64 = 15 * (@as(i64, 1) << @intCast(attempt));
        const to = posix.timeval{ .sec = timeout_secs, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&to)) catch {};

        ring.send_all(fd, &connect_buf) catch continue;

        var connect_resp: [16]u8 = undefined;
        const connect_n = ring.recv(fd, &connect_resp) catch continue;
        if (connect_n < 16) continue;

        const resp_action = std.mem.readInt(u32, connect_resp[0..4], .big);
        const resp_txid = std.mem.readInt(u32, connect_resp[4..8], .big);
        if (resp_action != action_connect) continue;
        if (resp_txid != transaction_id) continue;

        connection_id = std.mem.readInt(u64, connect_resp[8..16], .big);
        connect_ok = true;
        break;
    }
    if (!connect_ok) return error.TrackerTimeout;

    // Step 2: Announce
    const announce_txid = generateTransactionId();
    var announce_buf: [98]u8 = undefined;
    std.mem.writeInt(u64, announce_buf[0..8], connection_id, .big);
    std.mem.writeInt(u32, announce_buf[8..12], action_announce, .big);
    std.mem.writeInt(u32, announce_buf[12..16], announce_txid, .big);
    @memcpy(announce_buf[16..36], request.info_hash[0..]);
    @memcpy(announce_buf[36..56], request.peer_id[0..]);
    std.mem.writeInt(u64, announce_buf[56..64], request.downloaded, .big);
    std.mem.writeInt(u64, announce_buf[64..72], request.left, .big);
    std.mem.writeInt(u64, announce_buf[72..80], request.uploaded, .big);
    std.mem.writeInt(u32, announce_buf[80..84], eventToInt(request.event), .big);
    std.mem.writeInt(u32, announce_buf[84..88], 0, .big); // IP (0 = default)
    // Use session key if provided, otherwise generate a random one
    const key_value: u32 = if (request.key) |k| std.mem.readInt(u32, k[0..4], .big) else generateTransactionId();
    std.mem.writeInt(u32, announce_buf[88..92], key_value, .big); // key
    const numwant_i32: i32 = @intCast(@min(request.numwant, std.math.maxInt(i32)));
    std.mem.writeInt(i32, announce_buf[92..96], numwant_i32, .big); // numwant
    std.mem.writeInt(u16, announce_buf[96..98], request.port, .big);

    // BEP 15: retry announce with exponential backoff
    var resp_buf: [4096]u8 = undefined;
    var resp_n: usize = 0;
    var announce_ok = false;
    for (0..4) |attempt| {
        const timeout_secs: i64 = 15 * (@as(i64, 1) << @intCast(attempt));
        const to = posix.timeval{ .sec = timeout_secs, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&to)) catch {};

        ring.send_all(fd, &announce_buf) catch continue;
        resp_n = ring.recv(fd, &resp_buf) catch continue;
        if (resp_n >= 20) {
            announce_ok = true;
            break;
        }
    }
    if (!announce_ok) return error.TrackerTimeout;
    if (resp_n < 20) return error.InvalidTrackerResponse;

    const ann_action = std.mem.readInt(u32, resp_buf[0..4], .big);
    const ann_txid = std.mem.readInt(u32, resp_buf[4..8], .big);
    if (ann_action != action_announce) return error.InvalidTrackerResponse;
    if (ann_txid != announce_txid) return error.TransactionIdMismatch;

    const interval = std.mem.readInt(u32, resp_buf[8..12], .big);
    const leechers = std.mem.readInt(u32, resp_buf[12..16], .big);
    const seeders = std.mem.readInt(u32, resp_buf[16..20], .big);
    _ = leechers;
    _ = seeders;

    // Parse compact peers (6 bytes each: 4 IP + 2 port)
    const peers_data = resp_buf[20..resp_n];
    if (peers_data.len % 6 != 0) return error.InvalidTrackerResponse;

    const peer_count = peers_data.len / 6;
    const peers = try allocator.alloc(announce_mod.Peer, peer_count);
    errdefer allocator.free(peers);

    for (peers, 0..) |*peer, i| {
        const chunk = peers_data[i * 6 ..][0..6];
        const port = std.mem.readInt(u16, chunk[4..6], .big);
        peer.* = .{
            .address = std.net.Address.initIp4(.{ chunk[0], chunk[1], chunk[2], chunk[3] }, port),
        };
    }

    return .{
        .interval = interval,
        .peers = peers,
    };
}

const ParsedUdpUrl = struct {
    host: []const u8,
    port: u16,
};

pub fn parseUdpUrl(url: []const u8) ?ParsedUdpUrl {
    const after_scheme = if (std.mem.startsWith(u8, url, "udp://"))
        url[6..]
    else
        return null;

    const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const host_port = after_scheme[0..path_start];

    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null;
        return .{ .host = host_port[0..colon], .port = port };
    }

    return .{ .host = host_port, .port = 80 };
}

pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    return @import("../io/dns.zig").resolveOnce(allocator, host, port);
}

fn eventToInt(event: ?announce_mod.Request.Event) u32 {
    const ev = event orelse return 0; // none
    return switch (ev) {
        .completed => 1,
        .started => 2,
        .stopped => 3,
    };
}

fn generateTransactionId() u32 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

// ── Tests ─────────────────────────────────────────────────

test "parse udp tracker url" {
    const parsed = parseUdpUrl("udp://tracker.example.com:6969/announce").?;
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
}

test "parse udp url without path" {
    const parsed = parseUdpUrl("udp://tracker.example.com:1337").?;
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 1337), parsed.port);
}

test "reject non-udp url" {
    try std.testing.expect(parseUdpUrl("http://tracker.example.com:6969") == null);
}

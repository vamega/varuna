const std = @import("std");
const varuna = @import("varuna");
const udp = varuna.tracker.udp;

// ── UDP Tracker Packet Encoding/Decoding Tests ───────────

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

const std = @import("std");
const varuna = @import("varuna");
const announce = varuna.tracker.announce;
const ext = varuna.net.extensions;
const Bitfield = varuna.bitfield.Bitfield;

// ── Private tracker simulation tests ─────────────────────────
//
// These tests verify that the daemon correctly handles private tracker
// requirements: required announce fields (compact=1, numwant, key),
// private flag enforcement (no PEX, no DHT), tracker error responses,
// and stopped events on shutdown.

// ── Required announce fields ────────────────────────────────

test "announce URL includes compact=1" {
    const url = try buildTestUrl(.{});
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "compact=1") != null);
}

test "announce URL includes numwant" {
    const url = try buildTestUrl(.{});
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "numwant=50") != null);
}

test "announce URL includes custom numwant" {
    const url = try buildTestUrl(.{ .numwant = 200 });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "numwant=200") != null);
}

test "announce URL includes key when provided" {
    const url = try buildTestUrl(.{ .key = "abcd1234".* });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "key=abcd1234") != null);
}

test "announce URL omits key when not provided" {
    const url = try buildTestUrl(.{ .key = null });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "key=") == null);
}

test "announce URL includes info_hash percent-encoded" {
    const url = try buildTestUrl(.{ .info_hash = [_]u8{ 0x00, 0xFF } ++ ([_]u8{0xAB} ** 18) });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%00%FF") != null);
}

test "announce URL includes peer_id" {
    const url = try buildTestUrl(.{ .peer_id = "-VR0001-012345678901".* });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "peer_id=-VR0001-012345678901") != null);
}

test "announce URL includes port" {
    const url = try buildTestUrl(.{ .port = 51413 });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "port=51413") != null);
}

test "announce URL includes uploaded and downloaded" {
    const url = try buildTestUrl(.{ .uploaded = 12345, .downloaded = 67890 });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "uploaded=12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "downloaded=67890") != null);
}

test "announce URL includes left" {
    const url = try buildTestUrl(.{ .left = 999999 });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "left=999999") != null);
}

// ── Event parameter ─────────────────────────────────────────

test "announce URL includes event=started" {
    const url = try buildTestUrl(.{ .event = .started });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=started") != null);
}

test "announce URL includes event=completed" {
    const url = try buildTestUrl(.{ .event = .completed });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=completed") != null);
}

test "announce URL includes event=stopped on shutdown" {
    const url = try buildTestUrl(.{ .event = .stopped });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=stopped") != null);
}

test "announce URL omits event when null (regular re-announce)" {
    const url = try buildTestUrl(.{ .event = null });
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=") == null);
}

// ── Per-session tracker key ─────────────────────────────────

test "generateKey produces 8 hex characters" {
    const key = announce.Request.generateKey();
    try std.testing.expectEqual(@as(usize, 8), key.len);
    for (key) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "generateKey produces different keys on each call" {
    const key1 = announce.Request.generateKey();
    const key2 = announce.Request.generateKey();
    // While theoretically they could be equal (1/2^32), it's astronomically unlikely
    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));
}

// ── Private flag enforcement (no PEX, no DHT) ──────────────

test "private torrent extension handshake omits ut_pex" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, true);
    defer std.testing.allocator.free(payload);

    var result = try ext.decodeExtensionHandshake(std.testing.allocator, payload);
    defer ext.freeDecoded(std.testing.allocator, &result);

    // ut_metadata should still be present (needed for magnet links)
    try std.testing.expect(result.handshake.extensions.ut_metadata != 0);
    // ut_pex MUST be 0 for private torrents (BEP 27)
    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_pex);
}

test "public torrent extension handshake includes ut_pex" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, false);
    defer std.testing.allocator.free(payload);

    var result = try ext.decodeExtensionHandshake(std.testing.allocator, payload);
    defer ext.freeDecoded(std.testing.allocator, &result);

    try std.testing.expect(result.handshake.extensions.ut_pex != 0);
}

// ── Tracker error responses ─────────────────────────────────

test "tracker failure reason returns error" {
    try std.testing.expectError(
        error.TrackerFailure,
        announce.parseResponse(std.testing.allocator, "d14:failure reason11:not allowede"),
    );
}

test "tracker failure with empty reason returns error" {
    try std.testing.expectError(
        error.TrackerFailure,
        announce.parseResponse(std.testing.allocator, "d14:failure reason0:e"),
    );
}

test "tracker response with missing peers field returns error" {
    try std.testing.expectError(
        error.MissingRequiredField,
        announce.parseResponse(std.testing.allocator, "d8:intervali30ee"),
    );
}

test "tracker response with invalid peers format returns error" {
    // peers as integer (not string or list)
    try std.testing.expectError(
        error.InvalidPeersField,
        announce.parseResponse(std.testing.allocator, "d8:intervali30e5:peersi42ee"),
    );
}

test "tracker response with odd-length compact peers returns error" {
    // compact peers must be multiple of 6 bytes
    try std.testing.expectError(
        error.InvalidPeersField,
        announce.parseResponse(std.testing.allocator, "d8:intervali30e5:peers5:ABCDEe"),
    );
}

test "tracker response with non-dict root returns error" {
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        announce.parseResponse(std.testing.allocator, "li1ee"),
    );
}

test "tracker response with negative interval returns error" {
    try std.testing.expectError(
        error.NegativeInteger,
        announce.parseResponse(std.testing.allocator, "d8:intervali-1e5:peers0:e"),
    );
}

test "tracker response with valid warning message is parsed" {
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d8:intervali30e5:peers0:15:warning message9:slow downe",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(u32, 30), response.interval);
    if (response.warning_message) |msg| {
        try std.testing.expectEqualStrings("slow down", msg);
    }
}

test "tracker response with empty peers list is valid" {
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d8:intervali60e5:peers0:e",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(usize, 0), response.peers.len);
    try std.testing.expectEqual(@as(u32, 60), response.interval);
}

test "tracker response without interval defaults to 1800" {
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d5:peers0:e",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(u32, 1800), response.interval);
}

test "tracker response with complete and incomplete counts" {
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d8:completei10e10:incompletei5e8:intervali30e5:peers0:e",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(?u32, 10), response.complete);
    try std.testing.expectEqual(@as(?u32, 5), response.incomplete);
}

// ── Compact peer parsing ────────────────────────────────────

test "compact peers parse correctly" {
    // 127.0.0.1:6881 = 0x7f000001 0x1ae1
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d8:intervali30e5:peers6:\x7f\x00\x00\x01\x1a\xe1e",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(usize, 1), response.peers.len);
    try std.testing.expectEqual(@as(u16, 6881), response.peers[0].address.getPort());
}

test "multiple compact peers parse correctly" {
    // Two peers: 127.0.0.1:6881 and 10.0.0.1:8080
    const response = try announce.parseResponse(
        std.testing.allocator,
        "d8:intervali30e5:peers12:\x7f\x00\x00\x01\x1a\xe1\x0a\x00\x00\x01\x1f\x90e",
    );
    defer announce.freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(usize, 2), response.peers.len);
    try std.testing.expectEqual(@as(u16, 6881), response.peers[0].address.getPort());
    try std.testing.expectEqual(@as(u16, 8080), response.peers[1].address.getPort());
}

// ── Helper ──────────────────────────────────────────────────

const BuildTestUrlOptions = struct {
    info_hash: [20]u8 = [_]u8{0} ** 20,
    peer_id: [20]u8 = "ABCDEFGHIJKLMNOPQRST".*,
    port: u16 = 6881,
    uploaded: u64 = 0,
    downloaded: u64 = 0,
    left: u64 = 42,
    event: ?announce.Request.Event = .started,
    key: ?[8]u8 = "test1234".*,
    numwant: u32 = 50,
};

fn buildTestUrl(opts: BuildTestUrlOptions) ![]u8 {
    return announce.buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = opts.info_hash,
        .peer_id = opts.peer_id,
        .port = opts.port,
        .uploaded = opts.uploaded,
        .downloaded = opts.downloaded,
        .left = opts.left,
        .event = opts.event,
        .key = opts.key,
        .numwant = opts.numwant,
    });
}

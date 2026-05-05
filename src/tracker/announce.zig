const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const types = @import("types.zig");

pub const Request = types.Request;
pub const Peer = types.Peer;
pub const Response = types.Response;

pub fn freeResponse(allocator: std.mem.Allocator, response: Response) void {
    allocator.free(response.peers);
}

pub fn buildUrl(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, request.announce_url);
    try url.append(allocator, if (std.mem.indexOfScalar(u8, request.announce_url, '?') == null) '?' else '&');

    try appendQueryParam(allocator, &url, "info_hash", request.info_hash[0..]);
    try appendQueryParam(allocator, &url, "peer_id", request.peer_id[0..]);
    try appendQueryInt(allocator, &url, "port", request.port);
    try appendQueryInt(allocator, &url, "uploaded", request.uploaded);
    try appendQueryInt(allocator, &url, "downloaded", request.downloaded);
    try appendQueryInt(allocator, &url, "left", request.left);
    try appendQueryInt(allocator, &url, "compact", 1);
    if (request.event) |event| {
        try appendQueryParam(allocator, &url, "event", @tagName(event));
    }
    if (request.key) |key| {
        try appendQueryParam(allocator, &url, "key", &key);
    }
    try appendQueryInt(allocator, &url, "numwant", request.numwant);

    // BEP 52: for hybrid torrents, include the truncated v2 info-hash as a
    // second info_hash parameter so v2-aware trackers can match both swarms.
    if (request.info_hash_v2) |v2_hash| {
        try appendQueryParam(allocator, &url, "info_hash", v2_hash[0..20]);
    }

    return url.toOwnedSlice(allocator);
}

pub fn parseResponse(allocator: std.mem.Allocator, input: []const u8) !Response {
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const dict = try expectDict(root);
    if (bencode.dictGet(dict, "failure reason")) |_| {
        return error.TrackerFailure;
    }

    var peers = try parsePeers(allocator, try getRequired(dict, "peers"));
    errdefer allocator.free(peers);

    // Merge IPv6 compact peers (BEP 7) if present
    if (bencode.dictGet(dict, "peers6")) |peers6_value| {
        const peers6 = try types.parseCompactPeers6(allocator, try expectBytes(peers6_value));
        defer allocator.free(peers6);
        if (peers6.len > 0) {
            const merged = try allocator.alloc(Peer, peers.len + peers6.len);
            @memcpy(merged[0..peers.len], peers);
            @memcpy(merged[peers.len..], peers6);
            allocator.free(peers);
            peers = merged;
        }
    }

    return .{
        .interval = if (bencode.dictGet(dict, "interval")) |value| try expectU32(value) else 1800,
        .peers = peers,
        .complete = if (bencode.dictGet(dict, "complete")) |value| try expectU32(value) else null,
        .incomplete = if (bencode.dictGet(dict, "incomplete")) |value| try expectU32(value) else null,
        .warning_message = if (bencode.dictGet(dict, "warning message")) |v| try expectBytes(v) else null,
    };
}

fn parsePeers(allocator: std.mem.Allocator, value: bencode.Value) ![]Peer {
    return switch (value) {
        .bytes => |bytes| types.parseCompactPeers(allocator, bytes),
        .list => |list| parsePeerList(allocator, list),
        else => error.InvalidPeersField,
    };
}

fn parsePeerList(allocator: std.mem.Allocator, values: []const bencode.Value) ![]Peer {
    var peers = try allocator.alloc(Peer, values.len);
    errdefer allocator.free(peers);

    for (values, 0..) |value, index| {
        const dict = try expectDict(value);
        const ip = try expectBytes(try getRequired(dict, "ip"));
        const port = try expectU16(try getRequired(dict, "port"));

        peers[index] = .{
            .address = try std.net.Address.parseIp(ip, port),
        };
    }

    return peers;
}

fn appendQueryParam(
    allocator: std.mem.Allocator,
    url: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
) !void {
    if (url.items[url.items.len - 1] != '?' and url.items[url.items.len - 1] != '&') {
        try url.append(allocator, '&');
    }

    try url.appendSlice(allocator, key);
    try url.append(allocator, '=');
    try types.appendPercentEncoded(allocator, url, value);
}

fn appendQueryInt(
    allocator: std.mem.Allocator,
    url: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
) !void {
    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try appendQueryParam(allocator, url, key, rendered);
}

fn getRequired(dict: []const bencode.Value.Entry, key: []const u8) !bencode.Value {
    return bencode.dictGet(dict, key) orelse error.MissingRequiredField;
}

const BencodeTypeError = error{
    UnexpectedBencodeType,
    NegativeInteger,
    IntegerOverflow,
};

fn expectDict(value: bencode.Value) BencodeTypeError![]const bencode.Value.Entry {
    return switch (value) {
        .dict => |dict| dict,
        else => error.UnexpectedBencodeType,
    };
}

fn expectBytes(value: bencode.Value) BencodeTypeError![]const u8 {
    return switch (value) {
        .bytes => |bytes| bytes,
        else => error.UnexpectedBencodeType,
    };
}

fn expectU16(value: bencode.Value) BencodeTypeError!u16 {
    return std.math.cast(u16, try expectU64(value)) orelse error.IntegerOverflow;
}

fn expectU32(value: bencode.Value) BencodeTypeError!u32 {
    return std.math.cast(u32, try expectU64(value)) orelse error.IntegerOverflow;
}

fn expectU64(value: bencode.Value) BencodeTypeError!u64 {
    return switch (value) {
        .integer => |integer| {
            if (integer < 0) return error.NegativeInteger;
            return @intCast(integer);
        },
        else => error.UnexpectedBencodeType,
    };
}

test "build announce url percent encodes binary fields" {
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = [_]u8{ 0x00, 0xff } ++ @as([18]u8, @splat(1)),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 42,
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%00%FF") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "peer_id=ABCDEFGHIJKLMNOPQRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "compact=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=started") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "numwant=200") != null);
}

test "build url includes key when provided" {
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = @as([20]u8, @splat(0)),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 100,
        .key = "abcd1234".*,
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "key=abcd1234") != null);
}

test "build url omits key when not provided" {
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = @as([20]u8, @splat(0)),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 100,
        .event = null,
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "key=") == null);
    // Also verify event is omitted when null
    try std.testing.expect(std.mem.indexOf(u8, url, "event=") == null);
}

test "generate key produces 8 hex characters" {
    var rng = @import("../runtime/random.zig").Random.realRandom();
    const key = Request.generateKey(&rng);
    try std.testing.expectEqual(@as(usize, 8), key.len);
    for (key) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "parse compact tracker response" {
    const response = try parseResponse(
        std.testing.allocator,
        "d8:completei1e10:incompletei0e8:intervali30e5:peers6:\x7f\x00\x00\x01\x1a\xe1e",
    );
    defer freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(u32, 30), response.interval);
    try std.testing.expectEqual(@as(usize, 1), response.peers.len);
    try std.testing.expectEqual(@as(u16, 6881), response.peers[0].address.getPort());
}

test "parse dictionary tracker peers" {
    const response = try parseResponse(
        std.testing.allocator,
        "d8:intervali60e5:peersld2:ip9:127.0.0.14:porti7000eeee",
    );
    defer freeResponse(std.testing.allocator, response);

    try std.testing.expectEqual(@as(usize, 1), response.peers.len);
    try std.testing.expectEqual(@as(u16, 7000), response.peers[0].address.getPort());
}

test "reject non-dictionary tracker response" {
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parseResponse(std.testing.allocator, "li1ee"),
    );
}

test "reject non-integer interval in tracker response" {
    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parseResponse(std.testing.allocator, "d8:interval3:foo5:peers0:e"),
    );
}

// ── Fuzz and edge case tests ─────────────────────────────

test "fuzz tracker announce response parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            const response = parseResponse(std.testing.allocator, input) catch return;
            freeResponse(std.testing.allocator, response);
        }
    }.run, .{
        .corpus = &.{
            // Valid compact response
            "d8:completei1e10:incompletei0e8:intervali30e5:peers6:\x7f\x00\x00\x01\x1a\xe1e",
            // Valid dictionary peer response
            "d8:intervali60e5:peersld2:ip9:127.0.0.14:porti7000eeee",
            // Empty peers
            "d8:intervali10e5:peers0:e",
            // Failure reason
            "d14:failure reason6:deniede",
            // Non-dict
            "li1ee",
            // Empty dict
            "de",
            // Invalid bencode
            "",
            "i",
            "d",
            // Compact peers with IPv6 (peers6 key)
            "d8:intervali30e5:peers0:6:peers618:\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x1a\xe1e",
            // Missing interval (should default)
            "d5:peers0:e",
            // Negative interval
            "d8:intervali-1e5:peers0:e",
        },
    });
}

test "announce parser edge cases: single byte inputs" {
    var buf: [1]u8 = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        buf[0] = @intCast(byte);
        const result = parseResponse(std.testing.allocator, &buf);
        if (result) |response| {
            freeResponse(std.testing.allocator, response);
        } else |_| {}
    }
}

test "announce parser handles truncated compact response" {
    const valid = "d8:completei1e10:incompletei0e8:intervali30e5:peers6:\x7f\x00\x00\x01\x1a\xe1e";
    for (0..valid.len) |i| {
        const result = parseResponse(std.testing.allocator, valid[0..i]);
        if (result) |response| {
            freeResponse(std.testing.allocator, response);
        } else |_| {}
    }
}

test "build url includes v2 info_hash when provided" {
    var v2_hash: [32]u8 = undefined;
    for (&v2_hash, 0..) |*b, i| b.* = @intCast(i);
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = @as([20]u8, @splat(0xAA)),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 100,
        .info_hash_v2 = v2_hash,
    });
    defer std.testing.allocator.free(url);

    // The URL should contain two info_hash parameters
    // First: the v1 hash (all 0xAA)
    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%AA%AA") != null);
    // Second: the truncated v2 hash (first 20 bytes of 0x00..0x13)
    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%00%01%02") != null);
}

test "build url omits v2 info_hash when not provided" {
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = @as([20]u8, @splat(0)),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 100,
    });
    defer std.testing.allocator.free(url);

    // Count info_hash occurrences -- should be exactly 1
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, url, idx, "info_hash=")) |pos| {
        count += 1;
        idx = pos + 10;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "announce parser handles odd-length compact peers" {
    // Compact peers must be multiple of 6; odd lengths should error
    try std.testing.expectError(
        error.InvalidPeersField,
        parseResponse(std.testing.allocator, "d8:intervali30e5:peers5:ABCDEe"),
    );
}

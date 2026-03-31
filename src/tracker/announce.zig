const std = @import("std");
const bencode = @import("../torrent/bencode.zig");

pub const Request = struct {
    announce_url: []const u8,
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64 = 0,
    downloaded: u64 = 0,
    left: u64,
    event: ?Event = .started,
    key: ?[8]u8 = null,
    numwant: u32 = 50,

    pub const Event = enum {
        started,
        completed,
        stopped,
    };

    /// Generate a random 8-character hex key for tracker authentication.
    /// This should be called once per session and reused across announces.
    pub fn generateKey() [8]u8 {
        const hex = "0123456789abcdef";
        var buf: [8]u8 = undefined;
        var random_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        for (random_bytes, 0..) |byte, i| {
            buf[i] = hex[byte & 0x0f];
        }
        return buf;
    }
};

pub const Peer = struct {
    address: std.net.Address,
};

pub const Response = struct {
    interval: u32,
    peers: []Peer,
    complete: ?u32 = null,
    incomplete: ?u32 = null,
    warning_message: ?[]const u8 = null,
};

pub fn fetch(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    request: Request,
) !Response {
    const url = try buildUrl(allocator, request);
    defer allocator.free(url);

    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) {
        return error.UnexpectedTrackerStatus;
    }

    return parseResponse(allocator, body.writer.buffer[0..body.writer.end]);
}

/// Fetch tracker announce, auto-selecting HTTP or UDP based on URL scheme.
/// All I/O goes through io_uring.
pub fn fetchAuto(
    allocator: std.mem.Allocator,
    ring: *@import("../io/ring.zig").Ring,
    request: Request,
) !Response {
    if (std.mem.startsWith(u8, request.announce_url, "udp://")) {
        return @import("udp.zig").fetchViaUdp(allocator, ring, request);
    }
    return fetchViaRing(allocator, ring, request);
}

/// Fetch tracker announce using our io_uring-based HTTP client.
/// This replaces the std.http.Client path -- all I/O goes through io_uring.
pub fn fetchViaRing(
    allocator: std.mem.Allocator,
    ring: *@import("../io/ring.zig").Ring,
    request: Request,
) !Response {
    const url = try buildUrl(allocator, request);
    defer allocator.free(url);

    var http_client = @import("../io/http.zig").HttpClient.init(allocator, ring);
    var http_response = try http_client.get(url);
    defer http_response.deinit();

    if (http_response.status != 200) {
        return error.UnexpectedTrackerStatus;
    }

    return parseResponse(allocator, http_response.body);
}

pub fn freeResponse(allocator: std.mem.Allocator, response: Response) void {
    allocator.free(response.peers);
}

pub fn buildUrl(allocator: std.mem.Allocator, request: Request) ![]u8 {
    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, request.announce_url);
    try url.append(allocator, if (std.mem.indexOfScalar(u8, request.announce_url, '?') == null) '?' else '&');

    try appendQueryBytes(allocator, &url, "info_hash", request.info_hash[0..]);
    try appendQueryBytes(allocator, &url, "peer_id", request.peer_id[0..]);
    try appendQueryInt(allocator, &url, "port", request.port);
    try appendQueryInt(allocator, &url, "uploaded", request.uploaded);
    try appendQueryInt(allocator, &url, "downloaded", request.downloaded);
    try appendQueryInt(allocator, &url, "left", request.left);
    try appendQueryInt(allocator, &url, "compact", 1);
    if (request.event) |event| {
        try appendQueryString(allocator, &url, "event", @tagName(event));
    }
    if (request.key) |key| {
        try appendQueryString(allocator, &url, "key", &key);
    }
    try appendQueryInt(allocator, &url, "numwant", request.numwant);

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
        const peers6 = try parseCompactPeers6(allocator, try expectBytes(peers6_value));
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
        .interval = if (bencode.dictGet(dict, "interval")) |value| try expectPositiveU32(value) else 1800,
        .peers = peers,
        .complete = if (bencode.dictGet(dict, "complete")) |value| try expectPositiveU32(value) else null,
        .incomplete = if (bencode.dictGet(dict, "incomplete")) |value| try expectPositiveU32(value) else null,
        .warning_message = if (bencode.dictGet(dict, "warning message")) |v| try expectBytes(v) else null,
    };
}

fn parsePeers(allocator: std.mem.Allocator, value: bencode.Value) ![]Peer {
    return switch (value) {
        .bytes => |bytes| parseCompactPeers(allocator, bytes),
        .list => |list| parsePeerList(allocator, list),
        else => error.InvalidPeersField,
    };
}

fn parseCompactPeers6(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 18 != 0) {
        return error.InvalidPeersField;
    }

    const count = bytes.len / 18;
    const peers = try allocator.alloc(Peer, count);
    errdefer allocator.free(peers);

    for (peers, 0..) |*peer, index| {
        const chunk = bytes[index * 18 ..][0..18];
        const port = std.mem.readInt(u16, chunk[16..18], .big);
        peer.* = .{
            .address = std.net.Address.initIp6(chunk[0..16].*, port, 0, 0),
        };
    }

    return peers;
}

fn parseCompactPeers(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 6 != 0) {
        return error.InvalidPeersField;
    }

    const count = bytes.len / 6;
    const peers = try allocator.alloc(Peer, count);
    errdefer allocator.free(peers);

    for (peers, 0..) |*peer, index| {
        const chunk = bytes[index * 6 ..][0..6];
        const port = std.mem.readInt(u16, chunk[4..6], .big);
        peer.* = .{
            .address = std.net.Address.initIp4(.{ chunk[0], chunk[1], chunk[2], chunk[3] }, port),
        };
    }

    return peers;
}

fn parsePeerList(allocator: std.mem.Allocator, values: []const bencode.Value) ![]Peer {
    var peers = try allocator.alloc(Peer, values.len);
    errdefer allocator.free(peers);

    for (values, 0..) |value, index| {
        const dict = try expectDict(value);
        const ip = try expectBytes(try getRequired(dict, "ip"));
        const port = try expectPositiveU16(try getRequired(dict, "port"));

        peers[index] = .{
            .address = try std.net.Address.parseIp(ip, port),
        };
    }

    return peers;
}

fn appendQueryBytes(
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
    try appendPercentEncoded(allocator, url, value);
}

fn appendQueryInt(
    allocator: std.mem.Allocator,
    url: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
) !void {
    var buffer: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, "{}", .{value});
    try appendQueryString(allocator, url, key, rendered);
}

fn appendQueryString(
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
    try appendPercentEncoded(allocator, url, value);
}

fn appendPercentEncoded(
    allocator: std.mem.Allocator,
    url: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    const hex = "0123456789ABCDEF";

    for (bytes) |byte| {
        if (isUnreserved(byte)) {
            try url.append(allocator, byte);
        } else {
            try url.append(allocator, '%');
            try url.append(allocator, hex[byte >> 4]);
            try url.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
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

fn expectPositiveU16(value: bencode.Value) BencodeTypeError!u16 {
    return std.math.cast(u16, try expectPositiveU64(value)) orelse error.IntegerOverflow;
}

fn expectPositiveU32(value: bencode.Value) BencodeTypeError!u32 {
    return std.math.cast(u32, try expectPositiveU64(value)) orelse error.IntegerOverflow;
}

fn expectPositiveU64(value: bencode.Value) BencodeTypeError!u64 {
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
        .info_hash = [_]u8{ 0x00, 0xff } ++ ([_]u8{1} ** 18),
        .peer_id = "ABCDEFGHIJKLMNOPQRST".*,
        .port = 6881,
        .left = 42,
    });
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "info_hash=%00%FF") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "peer_id=ABCDEFGHIJKLMNOPQRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "compact=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "event=started") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "numwant=50") != null);
}

test "build url includes key when provided" {
    const url = try buildUrl(std.testing.allocator, .{
        .announce_url = "http://tracker.example/announce",
        .info_hash = [_]u8{0} ** 20,
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
        .info_hash = [_]u8{0} ** 20,
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
    const key = Request.generateKey();
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

test "announce parser handles odd-length compact peers" {
    // Compact peers must be multiple of 6; odd lengths should error
    try std.testing.expectError(
        error.InvalidPeersField,
        parseResponse(std.testing.allocator, "d8:intervali30e5:peers5:ABCDEe"),
    );
}

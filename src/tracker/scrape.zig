const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const Ring = @import("../io/ring.zig").Ring;
const udp_mod = @import("udp.zig");

/// Tracker scrape result: swarm statistics for a single info_hash.
pub const ScrapeResult = struct {
    /// Number of seeders (peers with complete copy).
    complete: u32 = 0,
    /// Number of leechers (peers downloading).
    incomplete: u32 = 0,
    /// Total number of completed downloads (snatches).
    downloaded: u32 = 0,
};

/// Derive the scrape URL from an announce URL by replacing the last
/// occurrence of "announce" in the path with "scrape".
/// Returns null if the announce URL does not contain "announce" in
/// the expected position (after the last '/').
pub fn deriveScrapeUrl(allocator: std.mem.Allocator, announce_url: []const u8) !?[]u8 {
    // Find the last occurrence of "/announce" in the URL.
    // Per BEP 48 / convention, only the path component after the last '/'
    // that starts with "announce" is replaced.
    const needle = "announce";
    const last_slash = std.mem.lastIndexOfScalar(u8, announce_url, '/') orelse return null;

    const after_slash = announce_url[last_slash + 1 ..];
    if (!std.mem.startsWith(u8, after_slash, needle)) return null;

    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, announce_url[0 .. last_slash + 1]);
    try url.appendSlice(allocator, "scrape");
    try url.appendSlice(allocator, after_slash[needle.len..]);

    return @as(?[]u8, try url.toOwnedSlice(allocator));
}

/// Build the full scrape request URL with the info_hash query parameter.
fn buildScrapeUrl(allocator: std.mem.Allocator, announce_url: []const u8, info_hash: [20]u8) ![]u8 {
    const base = try deriveScrapeUrl(allocator, announce_url) orelse return error.ScrapeNotSupported;
    defer allocator.free(base);

    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, base);
    try url.append(allocator, if (std.mem.indexOfScalar(u8, base, '?') == null) '?' else '&');
    try url.appendSlice(allocator, "info_hash=");
    try appendPercentEncoded(allocator, &url, info_hash[0..]);

    return url.toOwnedSlice(allocator);
}

/// Perform an HTTP scrape request via the io_uring-based HTTP client.
pub fn scrapeHttp(
    allocator: std.mem.Allocator,
    ring: *Ring,
    announce_url: []const u8,
    info_hash: [20]u8,
) !ScrapeResult {
    return scrapeHttpWithDns(allocator, ring, null, announce_url, info_hash);
}

/// Perform an HTTP scrape with an optional shared DNS cache.
pub fn scrapeHttpWithDns(
    allocator: std.mem.Allocator,
    ring: *Ring,
    dns_resolver: ?*@import("../io/dns.zig").DnsResolver,
    announce_url: []const u8,
    info_hash: [20]u8,
) !ScrapeResult {
    const url = try buildScrapeUrl(allocator, announce_url, info_hash);
    defer allocator.free(url);

    const http_mod = @import("../io/http.zig");
    var http_client = if (dns_resolver) |r|
        http_mod.HttpClient.initWithDns(allocator, ring, r)
    else
        http_mod.HttpClient.init(allocator, ring);
    var http_response = try http_client.get(url);
    defer http_response.deinit();

    if (http_response.status != 200) {
        return error.UnexpectedTrackerStatus;
    }

    return parseScrapeResponse(allocator, http_response.body, info_hash);
}

/// Perform a UDP scrape request (BEP 15, action=2) via io_uring.
pub fn scrapeUdp(
    allocator: std.mem.Allocator,
    ring: *Ring,
    announce_url: []const u8,
    info_hash: [20]u8,
) !ScrapeResult {
    const posix = std.posix;
    const parsed = udp_mod.parseUdpUrl(announce_url) orelse return error.InvalidTrackerUrl;

    const address = try udp_mod.resolveAddress(allocator, parsed.host, parsed.port);

    const fd = try ring.socket(
        address.any.family,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    );
    defer posix.close(fd);

    try ring.connect(fd, &address.any, address.getOsSockLen());

    // Step 1: UDP connect handshake
    const protocol_id: u64 = 0x41727101980;
    const action_connect: u32 = 0;
    const action_scrape: u32 = 2;

    const transaction_id = generateTransactionId();
    var connect_buf: [16]u8 = undefined;
    std.mem.writeInt(u64, connect_buf[0..8], protocol_id, .big);
    std.mem.writeInt(u32, connect_buf[8..12], action_connect, .big);
    std.mem.writeInt(u32, connect_buf[12..16], transaction_id, .big);

    try ring.send_all(fd, &connect_buf);

    var connect_resp: [16]u8 = undefined;
    const connect_n = try ring.recv(fd, &connect_resp);
    if (connect_n < 16) return error.InvalidTrackerResponse;

    const resp_action = std.mem.readInt(u32, connect_resp[0..4], .big);
    const resp_txid = std.mem.readInt(u32, connect_resp[4..8], .big);
    if (resp_action != action_connect) return error.InvalidTrackerResponse;
    if (resp_txid != transaction_id) return error.TransactionIdMismatch;

    const connection_id = std.mem.readInt(u64, connect_resp[8..16], .big);

    // Step 2: Scrape request (8 + 4 + 4 + 20 = 36 bytes for single hash)
    const scrape_txid = generateTransactionId();
    var scrape_buf: [36]u8 = undefined;
    std.mem.writeInt(u64, scrape_buf[0..8], connection_id, .big);
    std.mem.writeInt(u32, scrape_buf[8..12], action_scrape, .big);
    std.mem.writeInt(u32, scrape_buf[12..16], scrape_txid, .big);
    @memcpy(scrape_buf[16..36], info_hash[0..]);

    try ring.send_all(fd, &scrape_buf);

    // Receive scrape response: 8 header + 12 per hash = 20 bytes minimum
    var resp_buf: [128]u8 = undefined;
    const resp_n = try ring.recv(fd, &resp_buf);
    if (resp_n < 20) return error.InvalidTrackerResponse;

    const scrape_resp_action = std.mem.readInt(u32, resp_buf[0..4], .big);
    const scrape_resp_txid = std.mem.readInt(u32, resp_buf[4..8], .big);
    if (scrape_resp_action != action_scrape) return error.InvalidTrackerResponse;
    if (scrape_resp_txid != scrape_txid) return error.TransactionIdMismatch;

    // Parse first (and only) hash result: seeders(4) + completed(4) + leechers(4)
    const seeders = std.mem.readInt(u32, resp_buf[8..12], .big);
    const completed = std.mem.readInt(u32, resp_buf[12..16], .big);
    const leechers = std.mem.readInt(u32, resp_buf[16..20], .big);

    return .{
        .complete = seeders,
        .incomplete = leechers,
        .downloaded = completed,
    };
}

/// Scrape a tracker, auto-selecting HTTP or UDP based on the announce URL scheme.
pub fn scrapeAuto(
    allocator: std.mem.Allocator,
    ring: *Ring,
    announce_url: []const u8,
    info_hash: [20]u8,
) !ScrapeResult {
    return scrapeAutoWithDns(allocator, ring, null, announce_url, info_hash);
}

/// Scrape a tracker with an optional shared DNS cache.
pub fn scrapeAutoWithDns(
    allocator: std.mem.Allocator,
    ring: *Ring,
    dns_resolver: ?*@import("../io/dns.zig").DnsResolver,
    announce_url: []const u8,
    info_hash: [20]u8,
) !ScrapeResult {
    if (std.mem.startsWith(u8, announce_url, "udp://")) {
        return scrapeUdp(allocator, ring, announce_url, info_hash);
    }
    return scrapeHttpWithDns(allocator, ring, dns_resolver, announce_url, info_hash);
}

// ── Response parsing ─────────────────────────────────────

fn parseScrapeResponse(allocator: std.mem.Allocator, input: []const u8, info_hash: [20]u8) !ScrapeResult {
    const root = try bencode.parse(allocator, input);
    defer bencode.freeValue(allocator, root);

    const outer_dict = switch (root) {
        .dict => |d| d,
        else => return error.UnexpectedBencodeType,
    };

    // Optional failure reason
    if (bencode.dictGet(outer_dict, "failure reason") != null) {
        return error.TrackerFailure;
    }

    const files_value = bencode.dictGet(outer_dict, "files") orelse return error.MissingRequiredField;
    const files_dict = switch (files_value) {
        .dict => |d| d,
        else => return error.UnexpectedBencodeType,
    };

    // Look up our info_hash in the files dict.
    // The key is the raw 20-byte info_hash.
    for (files_dict) |entry| {
        if (entry.key.len == 20 and std.mem.eql(u8, entry.key, info_hash[0..])) {
            const stats_dict = switch (entry.value) {
                .dict => |d| d,
                else => return error.UnexpectedBencodeType,
            };

            return .{
                .complete = if (bencode.dictGet(stats_dict, "complete")) |v| expectU32(v) catch 0 else 0,
                .incomplete = if (bencode.dictGet(stats_dict, "incomplete")) |v| expectU32(v) catch 0 else 0,
                .downloaded = if (bencode.dictGet(stats_dict, "downloaded")) |v| expectU32(v) catch 0 else 0,
            };
        }
    }

    // Info hash not found in response -- return zeros rather than error
    return .{};
}

fn expectU32(value: bencode.Value) !u32 {
    return switch (value) {
        .integer => |i| {
            if (i < 0) return error.NegativeInteger;
            return std.math.cast(u32, i) orelse error.IntegerOverflow;
        },
        else => error.UnexpectedBencodeType,
    };
}

// ── Helpers ──────────────────────────────────────────────

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

fn generateTransactionId() u32 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

// ── Tests ────────────────────────────────────────────────

test "derive scrape url from announce url" {
    const alloc = std.testing.allocator;

    {
        const result = (try deriveScrapeUrl(alloc, "http://tracker.example/announce")).?;
        defer alloc.free(result);
        try std.testing.expectEqualStrings("http://tracker.example/scrape", result);
    }

    {
        const result = (try deriveScrapeUrl(alloc, "http://tracker.example/x/announce")).?;
        defer alloc.free(result);
        try std.testing.expectEqualStrings("http://tracker.example/x/scrape", result);
    }

    {
        const result = (try deriveScrapeUrl(alloc, "http://tracker.example/announce?passkey=abc")).?;
        defer alloc.free(result);
        try std.testing.expectEqualStrings("http://tracker.example/scrape?passkey=abc", result);
    }

    {
        const result = (try deriveScrapeUrl(alloc, "http://tracker.example/announce.php")).?;
        defer alloc.free(result);
        try std.testing.expectEqualStrings("http://tracker.example/scrape.php", result);
    }
}

test "derive scrape url returns null for non-announce url" {
    const alloc = std.testing.allocator;

    try std.testing.expect((try deriveScrapeUrl(alloc, "http://tracker.example/tracker")) == null);
    try std.testing.expect((try deriveScrapeUrl(alloc, "http://tracker.example/")) == null);
}

test "build scrape url with info hash" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{ 0x00, 0xff } ++ ([_]u8{0x41} ** 18);

    const url = try buildScrapeUrl(alloc, "http://tracker.example/announce", info_hash);
    defer alloc.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "http://tracker.example/scrape?info_hash="));
    try std.testing.expect(std.mem.indexOf(u8, url, "%00%FF") != null);
}

test "build scrape url fails for non-announce url" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0} ** 20;

    try std.testing.expectError(
        error.ScrapeNotSupported,
        buildScrapeUrl(alloc, "http://tracker.example/tracker", info_hash),
    );
}

test "parse http scrape response" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0xAB} ** 20;

    // Build bencoded response: d5:filesd20:<info_hash>d8:completei10e10:incompletei5e10:downloadedi100eeee
    var response_buf = std.ArrayList(u8).empty;
    defer response_buf.deinit(alloc);

    try response_buf.appendSlice(alloc, "d5:filesd20:");
    try response_buf.appendSlice(alloc, info_hash[0..]);
    try response_buf.appendSlice(alloc, "d8:completei10e10:incompletei5e10:downloadedi100eeee");

    const result = try parseScrapeResponse(alloc, response_buf.items, info_hash);
    try std.testing.expectEqual(@as(u32, 10), result.complete);
    try std.testing.expectEqual(@as(u32, 5), result.incomplete);
    try std.testing.expectEqual(@as(u32, 100), result.downloaded);
}

test "parse scrape response with unknown hash returns zeros" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0xAB} ** 20;
    const other_hash = [_]u8{0xCD} ** 20;

    var response_buf = std.ArrayList(u8).empty;
    defer response_buf.deinit(alloc);

    try response_buf.appendSlice(alloc, "d5:filesd20:");
    try response_buf.appendSlice(alloc, other_hash[0..]);
    try response_buf.appendSlice(alloc, "d8:completei1e10:incompletei2e10:downloadedi3eeee");

    const result = try parseScrapeResponse(alloc, response_buf.items, info_hash);
    try std.testing.expectEqual(@as(u32, 0), result.complete);
    try std.testing.expectEqual(@as(u32, 0), result.incomplete);
    try std.testing.expectEqual(@as(u32, 0), result.downloaded);
}

test "parse scrape response rejects failure reason" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0} ** 20;

    try std.testing.expectError(
        error.TrackerFailure,
        parseScrapeResponse(alloc, "d14:failure reason7:deniede", info_hash),
    );
}

test "parse scrape response rejects non-dict" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0} ** 20;

    try std.testing.expectError(
        error.UnexpectedBencodeType,
        parseScrapeResponse(alloc, "li42ee", info_hash),
    );
}

// ── Fuzz and edge case tests ─────────────────────────────

test "fuzz tracker scrape response parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            const info_hash = [_]u8{0xAB} ** 20;
            const result = parseScrapeResponse(std.testing.allocator, input, info_hash) catch return;
            // Result is a value struct, no deallocation needed
            _ = result;
        }
    }.run, .{
        .corpus = &.{
            // Valid scrape response (info_hash key is raw bytes -- hard to embed,
            // so use simpler corpus entries that exercise different paths)
            "de",
            "d5:filesdee",
            "d14:failure reason6:deniede",
            // Non-dict
            "li42ee",
            "i0e",
            "4:spam",
            // Invalid bencode
            "",
            "d",
            "d5:files",
            // files not a dict
            "d5:filesi42ee",
            // Nested dict with wrong types
            "d5:filesd20:ABCDEFGHIJKLMNOPQRSTi42eee",
        },
    });
}

test "scrape parser edge cases: single byte inputs" {
    const info_hash = [_]u8{0} ** 20;
    var buf: [1]u8 = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        buf[0] = @intCast(byte);
        _ = parseScrapeResponse(std.testing.allocator, &buf, info_hash) catch continue;
    }
}

test "scrape parser handles truncated valid response" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0xAB} ** 20;

    // Build a valid response
    var response_buf = std.ArrayList(u8).empty;
    defer response_buf.deinit(alloc);

    try response_buf.appendSlice(alloc, "d5:filesd20:");
    try response_buf.appendSlice(alloc, info_hash[0..]);
    try response_buf.appendSlice(alloc, "d8:completei10e10:incompletei5e10:downloadedi100eeee");

    // Feed progressively longer prefixes
    for (0..response_buf.items.len) |i| {
        _ = parseScrapeResponse(alloc, response_buf.items[0..i], info_hash) catch continue;
    }
}

test "scrape parser handles missing files key" {
    const alloc = std.testing.allocator;
    const info_hash = [_]u8{0} ** 20;

    try std.testing.expectError(
        error.MissingRequiredField,
        parseScrapeResponse(alloc, "d3:foo3:bare", info_hash),
    );
}

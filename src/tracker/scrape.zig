const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const types = @import("types.zig");

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
pub fn buildScrapeUrl(allocator: std.mem.Allocator, announce_url: []const u8, info_hash: [20]u8) ![]u8 {
    const base = try deriveScrapeUrl(allocator, announce_url) orelse return error.ScrapeNotSupported;
    defer allocator.free(base);

    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);

    try url.appendSlice(allocator, base);
    try url.append(allocator, if (std.mem.indexOfScalar(u8, base, '?') == null) '?' else '&');
    try url.appendSlice(allocator, "info_hash=");
    try types.appendPercentEncoded(allocator, &url, info_hash[0..]);

    return url.toOwnedSlice(allocator);
}

// ── Response parsing ─────────────────────────────────────

pub fn parseScrapeResponse(allocator: std.mem.Allocator, input: []const u8, info_hash: [20]u8) !ScrapeResult {
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

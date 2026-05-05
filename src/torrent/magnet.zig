const std = @import("std");

/// Parsed magnet link per BEP 9.
///
/// A magnet URI has the form:
///   magnet:?xt=urn:btih:<info-hash>&dn=<display-name>&tr=<tracker-url>&...
///
/// The info-hash may be 40 hex characters (SHA-1) or 32 base32 characters.
pub const MagnetUri = struct {
    /// 20-byte SHA-1 info hash.
    info_hash: [20]u8,
    /// Display name (percent-decoded). Null if not present.
    display_name: ?[]const u8,
    /// Tracker URLs (percent-decoded). Empty if none present.
    trackers: []const []const u8,

    pub fn deinit(self: MagnetUri, allocator: std.mem.Allocator) void {
        if (self.display_name) |dn| allocator.free(dn);
        for (self.trackers) |tr| allocator.free(tr);
        allocator.free(self.trackers);
    }
};

pub const ParseError = error{
    InvalidMagnetPrefix,
    MissingInfoHash,
    InvalidInfoHashLength,
    InvalidHexCharacter,
    InvalidBase32Character,
    OutOfMemory,
};

/// Parse a magnet URI string into a MagnetUri.
pub fn parse(allocator: std.mem.Allocator, uri: []const u8) ParseError!MagnetUri {
    // Must start with "magnet:?"
    if (!std.mem.startsWith(u8, uri, "magnet:?")) {
        return error.InvalidMagnetPrefix;
    }

    const params = uri["magnet:?".len..];

    var info_hash: ?[20]u8 = null;
    var display_name: ?[]const u8 = null;
    var trackers = std.ArrayList([]const u8).empty;
    errdefer {
        for (trackers.items) |tr| allocator.free(tr);
        trackers.deinit(allocator);
        if (display_name) |dn| allocator.free(dn);
    }

    var param_iter = std.mem.splitScalar(u8, params, '&');
    while (param_iter.next()) |param| {
        if (param.len == 0) continue;

        const eq_pos = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq_pos];
        const value = param[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "xt")) {
            // xt=urn:btih:<hash>
            const prefix = "urn:btih:";
            if (std.mem.startsWith(u8, value, prefix)) {
                const hash_str = value[prefix.len..];
                info_hash = try parseInfoHash(hash_str);
            }
        } else if (std.mem.eql(u8, key, "dn")) {
            if (display_name) |old| allocator.free(old);
            display_name = try percentDecode(allocator, value);
        } else if (std.mem.eql(u8, key, "tr")) {
            const decoded = try percentDecode(allocator, value);
            try trackers.append(allocator, decoded);
        }
    }

    if (info_hash == null) {
        return error.MissingInfoHash;
    }

    return .{
        .info_hash = info_hash.?,
        .display_name = display_name,
        .trackers = try trackers.toOwnedSlice(allocator),
    };
}

/// Parse info hash from hex (40 chars) or base32 (32 chars).
fn parseInfoHash(hash_str: []const u8) ParseError![20]u8 {
    if (hash_str.len == 40) {
        return hexDecode(hash_str);
    } else if (hash_str.len == 32) {
        return base32Decode(hash_str);
    } else {
        return error.InvalidInfoHashLength;
    }
}

/// Decode a 40-character hex string into 20 bytes.
fn hexDecode(hex: []const u8) ParseError![20]u8 {
    var result: [20]u8 = undefined;
    for (0..20) |i| {
        const hi = hexVal(hex[i * 2]) orelse return error.InvalidHexCharacter;
        const lo = hexVal(hex[i * 2 + 1]) orelse return error.InvalidHexCharacter;
        result[i] = (hi << 4) | lo;
    }
    return result;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decode a 32-character base32 string (RFC 4648, no padding) into 20 bytes.
fn base32Decode(input: []const u8) ParseError![20]u8 {
    var result: [20]u8 = undefined;
    var bits: u32 = 0;
    var bit_count: u5 = 0;
    var out_idx: usize = 0;

    for (input) |c| {
        const val: u32 = base32Val(c) orelse return error.InvalidBase32Character;
        bits = (bits << 5) | val;
        bit_count += 5;
        if (bit_count >= 8) {
            bit_count -= 8;
            if (out_idx >= 20) return error.InvalidInfoHashLength;
            result[out_idx] = @intCast((bits >> bit_count) & 0xFF);
            out_idx += 1;
        }
    }

    if (out_idx != 20) return error.InvalidInfoHashLength;
    return result;
}

fn base32Val(c: u8) ?u5 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a'),
        '2'...'7' => @intCast(c - '2' + 26),
        else => null,
    };
}

/// Percent-decode a URI component. Replaces '+' with space.
fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ParseError![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = hexVal(input[i + 2]) orelse {
                try result.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Build a hex string from a 20-byte info hash.
pub fn infoHashToHex(hash: [20]u8) [40]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

// ── Tests ────────────────────────────────────────────────

test "parse basic magnet URI with hex info hash" {
    const uri = "magnet:?xt=urn:btih:aabbccddeeaabbccddeeaabbccddeeaabbccddee&dn=Test+Torrent&tr=http%3A%2F%2Ftracker.example.com%2Fannounce";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    const expected_hash = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    try std.testing.expectEqual(expected_hash, result.info_hash);
    try std.testing.expectEqualStrings("Test Torrent", result.display_name.?);
    try std.testing.expectEqual(@as(usize, 1), result.trackers.len);
    try std.testing.expectEqualStrings("http://tracker.example.com/announce", result.trackers[0]);
}

test "parse magnet URI with multiple trackers" {
    const uri = "magnet:?xt=urn:btih:0102030405060708091011121314151617181920&tr=http%3A%2F%2Fone.com&tr=udp%3A%2F%2Ftwo.com%3A6969";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.trackers.len);
    try std.testing.expectEqualStrings("http://one.com", result.trackers[0]);
    try std.testing.expectEqualStrings("udp://two.com:6969", result.trackers[1]);
    try std.testing.expect(result.display_name == null);
}

test "parse magnet URI with uppercase hex" {
    const uri = "magnet:?xt=urn:btih:AABBCCDDEEAABBCCDDEEAABBCCDDEEAABBCCDDEE";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    const expected_hash = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    try std.testing.expectEqual(expected_hash, result.info_hash);
}

test "parse magnet URI with base32 info hash" {
    // "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" in base32 = 20 zero bytes... no.
    // Let's use a known value: hex "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    // (SHA-1 of empty string)
    // In base32: 3I42H3S6NNFQ2MSVX7XZKYAYSCX4BQ4J (but let's compute manually)
    // Actually, just test that base32 decoding of 32 chars produces 20 bytes.
    // AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA -> all zeros is wrong, AA = 0,0 -> 00000 00000 = 0x00, 0x0...
    // 32 base32 chars = 32*5 = 160 bits = 20 bytes. All A's = all zeros.
    const uri = "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    const expected_hash = @as([20]u8, @splat(0));
    try std.testing.expectEqual(expected_hash, result.info_hash);
}

test "reject invalid magnet prefix" {
    try std.testing.expectError(error.InvalidMagnetPrefix, parse(std.testing.allocator, "http://example.com"));
    try std.testing.expectError(error.InvalidMagnetPrefix, parse(std.testing.allocator, "magnet:xt=foo"));
}

test "reject missing info hash" {
    try std.testing.expectError(error.MissingInfoHash, parse(std.testing.allocator, "magnet:?dn=test"));
}

test "reject invalid hex characters" {
    // Must be exactly 40 chars (160-bit info-hash) to reach the hex
    // validation step; shorter/longer inputs hit InvalidInfoHashLength first.
    try std.testing.expectError(error.InvalidHexCharacter, parse(std.testing.allocator, "magnet:?xt=urn:btih:zzbccddeeff00112233445566778899aabbccdde"));
}

test "reject wrong length info hash" {
    try std.testing.expectError(error.InvalidInfoHashLength, parse(std.testing.allocator, "magnet:?xt=urn:btih:aabb"));
}

test "percent decode handles edge cases" {
    const decoded = try percentDecode(std.testing.allocator, "hello%20world%21");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world!", decoded);
}

test "percent decode handles malformed sequences" {
    // Incomplete percent sequence: treat '%' as literal
    const decoded = try percentDecode(std.testing.allocator, "hello%2");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello%2", decoded);
}

test "infoHashToHex round trips" {
    const hash = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const hex = infoHashToHex(hash);
    try std.testing.expectEqualStrings("deadbeef00112233445566778899aabbccddeeff", &hex);
}

test "parse magnet with no trackers" {
    const uri = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=NoTrackers";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.trackers.len);
    try std.testing.expectEqualStrings("NoTrackers", result.display_name.?);
}

test "parse magnet with empty parameters" {
    const uri = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&&dn=&&tr=";
    const result = try parse(std.testing.allocator, uri);
    defer result.deinit(std.testing.allocator);

    // Empty dn should give empty string, empty tr should give empty string
    try std.testing.expectEqualStrings("", result.display_name.?);
}

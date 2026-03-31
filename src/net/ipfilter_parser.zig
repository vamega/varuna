const std = @import("std");
const BanList = @import("ban_list.zig").BanList;
const log = std.log.scoped(.ipfilter_parser);

/// Result from parsing an IP filter file.
pub const ParseResult = struct {
    imported: usize,
    errors: usize,
};

/// Supported file formats.
pub const Format = enum {
    auto,
    dat, // eMule DAT format
    p2p, // P2P plaintext format
    cidr, // one CIDR per line (Varuna extension)
};

/// Parse an IP filter file and add all rules to the ban list.
/// Clears existing ipfilter-sourced entries first (atomic replace).
/// Returns the number of rules imported and parse errors.
pub fn parseFile(ban_list: *BanList, data: []const u8, format: Format) ParseResult {
    // Clear existing ipfilter entries before import
    ban_list.clearSource(.ipfilter);

    const detected_format = if (format == .auto) detectFormat(data) else format;

    return switch (detected_format) {
        .dat => parseDat(ban_list, data),
        .p2p => parseP2p(ban_list, data),
        .cidr => parseCidrFormat(ban_list, data),
        .auto => parseDat(ban_list, data), // fallback
    };
}

/// Detect the format of an IP filter file by examining the first non-comment line.
fn detectFormat(data: []const u8) Format {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        // DAT format: contains " - " and ","
        if (std.mem.indexOf(u8, trimmed, " - ") != null and std.mem.indexOfScalar(u8, trimmed, ',') != null) {
            return .dat;
        }

        // P2P format: description:startIP-endIP (has a colon followed by what looks like an IP)
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
            // Make sure there's content after the colon and it contains a dash
            const after_colon = trimmed[colon_pos + 1 ..];
            if (std.mem.indexOfScalar(u8, after_colon, '-') != null) {
                // Check if the part after colon starts with a digit (IP address)
                const after_trimmed = std.mem.trimLeft(u8, after_colon, " ");
                if (after_trimmed.len > 0 and std.ascii.isDigit(after_trimmed[0])) {
                    return .p2p;
                }
            }
        }

        // CIDR format: contains /
        if (std.mem.indexOfScalar(u8, trimmed, '/') != null) {
            return .cidr;
        }

        // Default to DAT
        return .dat;
    }
    return .dat;
}

/// Parse eMule DAT format.
/// Format: `startIP - endIP , access_level , description`
/// Lines with access level > 127 are NOT blocked (same as qBittorrent).
fn parseDat(ban_list: *BanList, data: []const u8) ParseResult {
    var imported: usize = 0;
    var errors: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        if (parseDatLine(trimmed)) |entry| {
            if (entry.access_level > 127) continue; // not blocked

            switch (entry.range) {
                .v4 => |r| {
                    ban_list.banRangeV4(r.start, r.end, .ipfilter) catch {
                        errors += 1;
                        continue;
                    };
                },
                .v6 => |r| {
                    ban_list.banRangeV6(r.start, r.end, .ipfilter) catch {
                        errors += 1;
                        continue;
                    };
                },
            }
            imported += 1;
        } else {
            errors += 1;
        }
    }

    return .{ .imported = imported, .errors = errors };
}

const DatEntry = struct {
    range: BanList.CidrRange,
    access_level: u32,
};

fn parseDatLine(line: []const u8) ?DatEntry {
    // Format: startIP - endIP , access , description
    // The spaces around - and , may vary

    // Split by comma to get: "startIP - endIP", "access", "description"
    var comma_iter = std.mem.splitScalar(u8, line, ',');
    const range_part = std.mem.trim(u8, comma_iter.next() orelse return null, " \t");
    const access_part = std.mem.trim(u8, comma_iter.next() orelse return null, " \t");

    // Parse access level
    const access_level = std.fmt.parseInt(u32, access_part, 10) catch return null;

    // Parse range: "startIP - endIP"
    const range = BanList.parseRange(range_part) orelse return null;

    return .{ .range = range, .access_level = access_level };
}

/// Parse P2P plaintext format.
/// Format: `description:startIP-endIP`
fn parseP2p(ban_list: *BanList, data: []const u8) ParseResult {
    var imported: usize = 0;
    var errors: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        if (parseP2pLine(trimmed)) |range| {
            switch (range) {
                .v4 => |r| {
                    ban_list.banRangeV4(r.start, r.end, .ipfilter) catch {
                        errors += 1;
                        continue;
                    };
                },
                .v6 => |r| {
                    ban_list.banRangeV6(r.start, r.end, .ipfilter) catch {
                        errors += 1;
                        continue;
                    };
                },
            }
            imported += 1;
        } else {
            errors += 1;
        }
    }

    return .{ .imported = imported, .errors = errors };
}

fn parseP2pLine(line: []const u8) ?BanList.CidrRange {
    // Format: description:startIP-endIP
    // Find the last colon (description may contain colons for IPv6)
    const colon_pos = std.mem.lastIndexOfScalar(u8, line, ':') orelse return null;
    const range_str = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
    return BanList.parseRange(range_str);
}

/// Parse CIDR format (one CIDR per line).
fn parseCidrFormat(ban_list: *BanList, data: []const u8) ParseResult {
    var imported: usize = 0;
    var errors: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        ban_list.banCidr(trimmed, .ipfilter) catch {
            errors += 1;
            continue;
        };
        imported += 1;
    }

    return .{ .imported = imported, .errors = errors };
}

// ── Tests ─────────────────────────────────────────────────

test "parses eMule DAT format" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\# Comment line
        \\001.009.096.105 - 001.009.096.105 , 000 , Some Organization
        \\010.000.000.000 - 010.255.255.255 , 100 , Private Range
    ;

    const result = parseFile(&bl, data, .dat);
    try std.testing.expectEqual(@as(usize, 2), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.errors);

    const addr = std.net.Address.parseIp4("1.9.96.105", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr));

    const addr2 = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr2));
}

test "access level above 127 is not blocked" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\001.002.003.004 - 001.002.003.004 , 000 , Blocked
        \\002.003.004.005 - 002.003.004.005 , 200 , Allowed
    ;

    const result = parseFile(&bl, data, .dat);
    try std.testing.expectEqual(@as(usize, 1), result.imported);

    const blocked = std.net.Address.parseIp4("1.2.3.4", 0) catch unreachable;
    const allowed = std.net.Address.parseIp4("2.3.4.5", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(blocked));
    try std.testing.expect(!bl.isBanned(allowed));
}

test "parses P2P plaintext format" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\Some Organization:1.9.96.105-1.9.96.105
        \\Another Org:10.0.0.0-10.255.255.255
    ;

    const result = parseFile(&bl, data, .p2p);
    try std.testing.expectEqual(@as(usize, 2), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.errors);

    const addr = std.net.Address.parseIp4("1.9.96.105", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr));
}

test "parses CIDR format" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\# Comment line
        \\10.0.0.0/8
        \\192.168.0.0/16
    ;

    const result = parseFile(&bl, data, .cidr);
    try std.testing.expectEqual(@as(usize, 2), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.errors);

    const addr = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr));

    const addr2 = std.net.Address.parseIp4("192.168.1.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr2));
}

test "auto-detects DAT format" {
    const data = "001.002.003.004 - 001.002.003.004 , 000 , Test\n";
    try std.testing.expectEqual(Format.dat, detectFormat(data));
}

test "auto-detects P2P format" {
    const data = "Test Org:1.2.3.4-5.6.7.8\n";
    try std.testing.expectEqual(Format.p2p, detectFormat(data));
}

test "auto-detects CIDR format" {
    const data = "10.0.0.0/8\n";
    try std.testing.expectEqual(Format.cidr, detectFormat(data));
}

test "skips comment lines" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\# This is a comment
        \\// This is also a comment
        \\
        \\10.0.0.0/8
    ;

    const result = parseFile(&bl, data, .cidr);
    try std.testing.expectEqual(@as(usize, 1), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.errors);
}

test "handles malformed lines gracefully" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const data =
        \\this is not valid
        \\10.0.0.0/8
        \\also garbage
    ;

    const result = parseFile(&bl, data, .cidr);
    try std.testing.expectEqual(@as(usize, 1), result.imported);
    try std.testing.expectEqual(@as(usize, 2), result.errors);
}

test "handles empty file" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const result = parseFile(&bl, "", .auto);
    try std.testing.expectEqual(@as(usize, 0), result.imported);
    try std.testing.expectEqual(@as(usize, 0), result.errors);
}

test "clearSource before reimport" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    // First import
    const data1 = "10.0.0.0/8\n";
    _ = parseFile(&bl, data1, .cidr);

    const addr = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr));

    // Second import (different data) -- should replace
    const data2 = "192.168.0.0/16\n";
    _ = parseFile(&bl, data2, .cidr);

    // Old range should be gone
    try std.testing.expect(!bl.isBanned(addr));

    // New range should be present
    const addr2 = std.net.Address.parseIp4("192.168.1.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(addr2));
}

const std = @import("std");

/// Parse a 20-byte BitTorrent peer ID into a human-readable client name.
///
/// Supports Azureus-style (`-XX1234-`) and Shadow-style (`X1234---`) formats.
/// Returns a descriptive string like "qBittorrent 4.6.1" or "Unknown" for
/// unrecognized peer IDs.
///
/// Caller owns the returned slice (allocated from `allocator`).
pub fn peerIdToClientName(allocator: std.mem.Allocator, peer_id: *const [20]u8) ![]const u8 {
    // Azureus-style: -XX1234-xxxxxxxxxxxx
    if (peer_id[0] == '-' and peer_id[7] == '-') {
        const code = peer_id[1..3];
        const ver = peer_id[3..7];

        const name = azureusClientName(code);
        if (name.len > 0) {
            return formatAzureusVersion(allocator, name, ver);
        }
    }

    // Shadow-style: first byte is the client letter, followed by version digits
    if (isShadowStyle(peer_id)) {
        const name = shadowClientName(peer_id[0]);
        if (name.len > 0) {
            return formatShadowVersion(allocator, name, peer_id[1..6]);
        }
    }

    // Mainline BitTorrent: M1-2-3--xxxxxxxxxxxx
    if (peer_id[0] == 'M' and peer_id[2] == '-' and peer_id[4] == '-') {
        return std.fmt.allocPrint(allocator, "Mainline {c}.{c}.{c}", .{
            peer_id[1], peer_id[3], peer_id[5],
        });
    }

    // Unknown: show hex prefix for debugging
    const hex = std.fmt.bytesToHex(peer_id[0..8].*, .lower);
    return std.fmt.allocPrint(allocator, "Unknown ({s})", .{hex});
}

/// Map Azureus-style 2-letter client codes to client names.
fn azureusClientName(code: *const [2]u8) []const u8 {
    return switch ((@as(u16, code[0]) << 8) | @as(u16, code[1])) {
        cc('q', 'B') => "qBittorrent",
        cc('T', 'R') => "Transmission",
        cc('D', 'E') => "Deluge",
        cc('U', 'T') => "\xc2\xb5Torrent", // µTorrent (UTF-8)
        cc('l', 't') => "libtorrent",
        cc('L', 'T') => "libtorrent",
        cc('R', 'T') => "rtorrent",
        cc('V', 'R') => "Varuna",
        cc('A', 'Z') => "Vuze",
        cc('B', 'T') => "BitTorrent",
        cc('B', 'F') => "BitFlu",
        cc('K', 'T') => "KTorrent",
        cc('A', 'R') => "Arctic",
        cc('A', 'X') => "BitPump",
        cc('B', 'C') => "BitComet",
        cc('B', 'E') => "BitTorrent SDK",
        cc('B', 'G') => "BTG",
        cc('B', 'R') => "BitRocket",
        cc('B', 'S') => "BTSlave",
        cc('B', 'X') => "BittorrentX",
        cc('C', 'D') => "Enhanced CTorrent",
        cc('C', 'T') => "CTorrent",
        cc('D', 'L') => "Deluge",
        cc('E', 'B') => "EBit",
        cc('F', 'C') => "FileCroc",
        cc('F', 'T') => "FoxTorrent",
        cc('G', 'S') => "GSTorrent",
        cc('H', 'L') => "Halite",
        cc('H', 'N') => "Hydranode",
        cc('L', 'P') => "Lphant",
        cc('M', 'O') => "MonoTorrent",
        cc('M', 'P') => "MooPolice",
        cc('M', 'T') => "MoonlightTorrent",
        cc('O', 'T') => "OmegaTorrent",
        cc('P', 'D') => "Pando",
        cc('S', 'B') => "Swiftbit",
        cc('S', 'N') => "ShareNET",
        cc('S', 'S') => "SwarmScope",
        cc('S', 'T') => "SymTorrent",
        cc('T', 'N') => "TorrentDotNET",
        cc('T', 'S') => "Torrentstorm",
        cc('T', 'T') => "TuoTu",
        cc('U', 'L') => "uLeecher!",
        cc('U', 'M') => "\xc2\xb5Torrent Mac",
        cc('U', 'W') => "\xc2\xb5Torrent Web",
        cc('W', 'D') => "WebTorrent Desktop",
        cc('W', 'T') => "BitLet",
        cc('W', 'W') => "WebTorrent",
        cc('X', 'L') => "Xunlei",
        cc('X', 'T') => "XanTorrent",
        cc('Z', 'T') => "ZipTorrent",
        cc('7', 'T') => "aTorrent",
        cc('F', 'W') => "FrostWire",
        cc('L', 'W') => "LimeWire",
        cc('B', 'N') => "Baidu Netdisk",
        cc('F', 'L') => "Flud",
        cc('P', 'B') => "PBTorrent",
        cc('P', 'I') => "PicoTorrent",
        cc('T', 'L') => "Tribler",
        cc('T', 'B') => "Torch",
        else => "",
    };
}

fn cc(a: u8, b: u8) u16 {
    return (@as(u16, a) << 8) | @as(u16, b);
}

/// Format an Azureus-style version string.
/// Version bytes are typically ASCII digits: "4610" -> "4.6.1.0" (skip trailing zeros).
fn formatAzureusVersion(allocator: std.mem.Allocator, name: []const u8, ver: *const [4]u8) ![]const u8 {
    // Find significant version digits (trim trailing '0' but keep at least major)
    var len: usize = 4;
    while (len > 1 and ver[len - 1] == '0') len -= 1;

    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    for (ver[0..len], 0..) |c, i| {
        if (i > 0) {
            buf[pos] = '.';
            pos += 1;
        }
        buf[pos] = c;
        pos += 1;
    }

    return std.fmt.allocPrint(allocator, "{s} {s}", .{ name, buf[0..pos] });
}

/// Check if a peer ID looks like Shadow-style encoding.
fn isShadowStyle(peer_id: *const [20]u8) bool {
    if (!std.ascii.isAlphabetic(peer_id[0])) return false;
    // Shadow-style has version digits in positions 1-5, rest is random
    for (peer_id[1..6]) |c| {
        if (!std.ascii.isDigit(c) and c != '-') return false;
    }
    // Must have at least position 6+ be padding
    return peer_id[6] == '-' or peer_id[6] == 0;
}

/// Map Shadow-style first-byte client codes to client names.
fn shadowClientName(code: u8) []const u8 {
    return switch (code) {
        'A' => "ABC",
        'O' => "Osprey Permaseed",
        'Q' => "BTQueue",
        'R' => "Tribler",
        'S' => "Shadow",
        'T' => "BitTornado",
        'U' => "UPnP NAT Bit Torrent",
        else => "",
    };
}

/// Format a Shadow-style version string.
fn formatShadowVersion(allocator: std.mem.Allocator, name: []const u8, ver: *const [5]u8) ![]const u8 {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    for (ver, 0..) |c, i| {
        if (c == '-' or c == 0) break;
        if (i > 0) {
            buf[pos] = '.';
            pos += 1;
        }
        buf[pos] = c;
        pos += 1;
    }
    if (pos == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ name, buf[0..pos] });
}

// ── Tests ──────────────────────────────────────────────────────

test "azureus-style qBittorrent" {
    const id: [20]u8 = "-qB4610-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("qBittorrent 4.6.1", name);
}

test "azureus-style Transmission" {
    const id: [20]u8 = "-TR4040-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Transmission 4.0.4", name);
}

test "azureus-style Deluge" {
    const id: [20]u8 = "-DE2160-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Deluge 2.1.6", name);
}

test "azureus-style libtorrent" {
    const id: [20]u8 = "-lt0D70-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("libtorrent 0.D.7", name);
}

test "azureus-style Varuna" {
    const id: [20]u8 = "-VR0100-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Varuna 0.1", name);
}

test "azureus-style Vuze" {
    const id: [20]u8 = "-AZ5760-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Vuze 5.7.6", name);
}

test "azureus-style version all zeros" {
    const id: [20]u8 = "-qB0000-xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("qBittorrent 0", name);
}

test "unknown peer id shows hex prefix" {
    const id: [20]u8 = "!!unknown-peer-id!!!".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "Unknown ("));
}

test "all-zero peer id" {
    const id: [20]u8 = [_]u8{0} ** 20;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "Unknown ("));
}

test "mainline BitTorrent style" {
    const id: [20]u8 = "M5-3-7--xxxxxxxxxxxx".*;
    const name = try peerIdToClientName(std.testing.allocator, &id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Mainline 5.3.7", name);
}

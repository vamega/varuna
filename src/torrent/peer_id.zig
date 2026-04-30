const std = @import("std");
const Random = @import("../runtime/random.zig").Random;
const log = std.log.scoped(.peer_id);

pub const prefix = "-VR0001-";

/// Supported client identities for peer ID masquerading.
pub const ClientId = enum {
    varuna,
    qbittorrent,
    rtorrent,
    utorrent,
    deluge,
    transmission,
};

/// Result of parsing a masquerade string.
pub const MasqueradeResult = struct {
    client: ClientId,
    prefix: [8]u8,
};

pub const GenerateError = error{UnsupportedMasquerade};

/// Generate a 20-byte peer ID. If `masquerade` is non-null, use the masqueraded
/// client prefix; otherwise use Varuna's default prefix.
/// Returns error.UnsupportedMasquerade if the masquerade_as value names an
/// unrecognized client — the daemon should refuse to start in this case.
///
/// `random` is the daemon-wide CSPRNG (`runtime.Random`). Tests inject a
/// seeded sim variant for byte-deterministic peer IDs; production uses
/// the OS-seeded ChaCha8 instance held on the event loop.
pub fn generate(random: *Random, masquerade: ?[]const u8) GenerateError![20]u8 {
    const effective_prefix: [8]u8 = if (masquerade) |spec|
        (parseMasquerade(spec) orelse return error.UnsupportedMasquerade).prefix
    else
        prefix.*;
    return generateWithPrefix(random, effective_prefix);
}

/// Generate a peer ID with a given 8-byte prefix and 12 random alphanumeric bytes.
fn generateWithPrefix(random: *Random, pfx: [8]u8) [20]u8 {
    var value: [20]u8 = undefined;
    @memcpy(value[0..8], &pfx);

    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    var random_bytes: [12]u8 = undefined;
    random.bytes(&random_bytes);

    for (random_bytes, 0..) |byte, index| {
        value[8 + index] = alphabet[byte % alphabet.len];
    }

    return value;
}

/// Parse a masquerade specification string like "qBittorrent 5.1.4" into a
/// client identity and 8-byte Azureus-style peer ID prefix.
///
/// Returns null for unrecognized client names.
pub fn parseMasquerade(spec: []const u8) ?MasqueradeResult {
    // Split on first space: "clientName version"
    const space_idx = std.mem.indexOfScalar(u8, spec, ' ') orelse return null;
    if (space_idx + 1 >= spec.len) return null;

    const client_name = spec[0..space_idx];
    const version_str = spec[space_idx + 1 ..];

    // Parse version numbers (up to 4 components, default 0)
    var version: [4]u8 = .{ 0, 0, 0, 0 };
    var vi: usize = 0;
    var it = std.mem.splitScalar(u8, version_str, '.');
    while (it.next()) |part| {
        if (vi >= 4) break;
        version[vi] = std.fmt.parseInt(u8, part, 10) catch return null;
        vi += 1;
    }
    if (vi == 0) return null;

    // Match client name (case-insensitive)
    if (eqlIgnoreCase(client_name, "qBittorrent")) {
        return .{
            .client = .qbittorrent,
            .prefix = azureusPrefix("qB", version),
        };
    }

    if (eqlIgnoreCase(client_name, "rTorrent")) {
        // rTorrent uses libtorrent-rakshasa's peer ID: -ltXYZW-
        // Version encoding: major as digit, minor as char (0-9 for 0-9, A=10, B=11, ...G=16, etc.)
        // patch and build as digits. e.g. 0.16 -> -lt0G60-
        return .{
            .client = .rtorrent,
            .prefix = rtorrentPrefix(version),
        };
    }

    if (eqlIgnoreCase(client_name, "uTorrent") or
        std.mem.eql(u8, client_name, "\xc2\xb5Torrent") or // UTF-8 µ
        std.mem.eql(u8, client_name, "\xb5Torrent")) // Latin-1 µ
    {
        return .{
            .client = .utorrent,
            .prefix = azureusPrefix("UT", version),
        };
    }

    if (eqlIgnoreCase(client_name, "Deluge")) {
        return .{
            .client = .deluge,
            .prefix = azureusPrefix("DE", version),
        };
    }

    if (eqlIgnoreCase(client_name, "Transmission")) {
        return .{
            .client = .transmission,
            .prefix = azureusPrefix("TR", version),
        };
    }

    return null;
}

/// Build a standard Azureus-style prefix: -CCXYZW- where CC is client code
/// and XYZW are version digits.
fn azureusPrefix(client_code: *const [2]u8, version: [4]u8) [8]u8 {
    var result: [8]u8 = undefined;
    result[0] = '-';
    result[1] = client_code[0];
    result[2] = client_code[1];
    result[3] = '0' + version[0];
    result[4] = '0' + version[1];
    result[5] = '0' + version[2];
    result[6] = '0' + version[3];
    result[7] = '-';
    return result;
}

/// Build rTorrent/libtorrent-rakshasa prefix: -ltXYZW-
/// Major as digit char, minor as hex-extended char (0-9, A=10, B=11, ...),
/// patch as digit char, build as digit char.
fn rtorrentPrefix(version: [4]u8) [8]u8 {
    var result: [8]u8 = undefined;
    result[0] = '-';
    result[1] = 'l';
    result[2] = 't';
    result[3] = encodeHexExtended(version[0]);
    result[4] = encodeHexExtended(version[1]);
    result[5] = encodeHexExtended(version[2]);
    result[6] = encodeHexExtended(version[3]);
    result[7] = '-';
    return result;
}

/// Encode a version component as a hex-extended character:
/// 0-9 -> '0'-'9', 10 -> 'A', 11 -> 'B', ... 16 -> 'G', etc.
fn encodeHexExtended(val: u8) u8 {
    if (val <= 9) return '0' + val;
    return 'A' + (val - 10);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "default peer id keeps the Varuna prefix" {
    var rng = Random.simRandom(0x1);
    const value = try generate(&rng, null);

    try std.testing.expectEqual(@as(usize, 20), value.len);
    try std.testing.expectEqualStrings(prefix, value[0..prefix.len]);
}

test "qBittorrent 5.1.4 masquerade prefix" {
    var rng = Random.simRandom(0x2);
    const value = try generate(&rng, "qBittorrent 5.1.4");
    try std.testing.expectEqualStrings("-qB5140-", value[0..8]);
    try std.testing.expectEqual(@as(usize, 20), value.len);
}

test "qBittorrent 4.6.2.1 masquerade prefix" {
    const result = parseMasquerade("qBittorrent 4.6.2.1").?;
    try std.testing.expectEqual(ClientId.qbittorrent, result.client);
    try std.testing.expectEqualStrings("-qB4621-", &result.prefix);
}

test "rTorrent 0.16 masquerade prefix" {
    var rng = Random.simRandom(0x3);
    const value = try generate(&rng, "rTorrent 0.16");
    // 0.16 -> -lt0G00- (0=0, G=16, 0=0, 0=0)
    try std.testing.expectEqualStrings("-lt0G00-", value[0..8]);
}

test "rTorrent 0.16.6 masquerade prefix" {
    const result = parseMasquerade("rTorrent 0.16.6").?;
    try std.testing.expectEqual(ClientId.rtorrent, result.client);
    try std.testing.expectEqualStrings("-lt0G60-", &result.prefix);
}

test "rTorrent 0.13.8 masquerade prefix" {
    const result = parseMasquerade("rTorrent 0.13.8").?;
    try std.testing.expectEqual(ClientId.rtorrent, result.client);
    try std.testing.expectEqualStrings("-lt0D80-", &result.prefix);
}

test "uTorrent 3.5.6 masquerade prefix" {
    var rng = Random.simRandom(0x4);
    const value = try generate(&rng, "uTorrent 3.5.6");
    try std.testing.expectEqualStrings("-UT3560-", value[0..8]);
}

test "uTorrent 3.5.6.0 masquerade prefix with four components" {
    const result = parseMasquerade("uTorrent 3.5.6.0").?;
    try std.testing.expectEqual(ClientId.utorrent, result.client);
    try std.testing.expectEqualStrings("-UT3560-", &result.prefix);
}

test "Deluge 2.1.1 masquerade prefix" {
    var rng = Random.simRandom(0x5);
    const value = try generate(&rng, "Deluge 2.1.1");
    try std.testing.expectEqualStrings("-DE2110-", value[0..8]);
}

test "Deluge 2.1.1.0 masquerade prefix with four components" {
    const result = parseMasquerade("Deluge 2.1.1.0").?;
    try std.testing.expectEqual(ClientId.deluge, result.client);
    try std.testing.expectEqualStrings("-DE2110-", &result.prefix);
}

test "Transmission 4.0.6 masquerade prefix" {
    var rng = Random.simRandom(0x6);
    const value = try generate(&rng, "Transmission 4.0.6");
    try std.testing.expectEqualStrings("-TR4060-", value[0..8]);
}

test "Transmission 4.0.6.0 masquerade prefix with four components" {
    const result = parseMasquerade("Transmission 4.0.6.0").?;
    try std.testing.expectEqual(ClientId.transmission, result.client);
    try std.testing.expectEqualStrings("-TR4060-", &result.prefix);
}

test "unsupported client returns null from parseMasquerade" {
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade("Vuze 5.7.7.0"));
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade("UnknownClient 1.0"));
}

test "unsupported client returns error" {
    var rng = Random.simRandom(0x7);
    try std.testing.expectError(error.UnsupportedMasquerade, generate(&rng, "Vuze 5.7.7.0"));
    try std.testing.expectError(error.UnsupportedMasquerade, generate(&rng, "UnknownClient 1.0"));
}

test "malformed spec returns null" {
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade("qBittorrent"));
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade(""));
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade("qBittorrent abc"));
    try std.testing.expectEqual(@as(?MasqueradeResult, null), parseMasquerade("qBittorrent "));
}

test "case insensitive client name matching" {
    const r1 = parseMasquerade("QBITTORRENT 5.1.4").?;
    try std.testing.expectEqual(ClientId.qbittorrent, r1.client);

    const r2 = parseMasquerade("transmission 4.0.6").?;
    try std.testing.expectEqual(ClientId.transmission, r2.client);

    const r3 = parseMasquerade("DELUGE 2.1.1").?;
    try std.testing.expectEqual(ClientId.deluge, r3.client);
}

test "random suffix is alphanumeric and 12 bytes" {
    var rng = Random.simRandom(0x8);
    const value = try generate(&rng, "qBittorrent 5.1.4");
    for (value[8..]) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c));
    }
}

test "peer id suffix is byte-deterministic under SimRandom" {
    var r1 = Random.simRandom(0xfeedbeef);
    var r2 = Random.simRandom(0xfeedbeef);
    const id1 = try generate(&r1, null);
    const id2 = try generate(&r2, null);
    try std.testing.expectEqualSlices(u8, &id1, &id2);
}

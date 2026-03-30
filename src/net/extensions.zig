const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");

/// BEP 10 Extension Protocol constants and utilities.
///
/// The extension protocol uses reserved bit 20 (byte 5, bit 4) in the
/// BitTorrent handshake to signal support.  After the standard handshake,
/// peers exchange an extension handshake (message ID 20, sub-ID 0) that
/// carries a bencoded dictionary advertising supported extensions and
/// their locally-assigned message IDs.

// ── Constants ────────────────────────────────────────────────

/// Byte index within the 8-byte reserved field where the extension bit lives.
pub const reserved_byte: usize = 5;

/// Bit mask to set/test within reserved[5].
pub const reserved_mask: u8 = 0x10;

/// Standard BitTorrent message ID used for all extension messages.
pub const msg_id: u8 = 20;

/// Sub-message ID for the extension handshake itself.
pub const handshake_sub_id: u8 = 0;

/// Well-known extension names.
pub const ext_ut_metadata = "ut_metadata";
pub const ext_ut_pex = "ut_pex";

/// Client version string advertised in extension handshakes.
pub const client_version = "varuna";

// ── Extension ID map ─────────────────────────────────────────

/// Locally-assigned extension IDs we advertise to peers.
pub const local_ut_metadata_id: u8 = 1;
pub const local_ut_pex_id: u8 = 2;

/// Mapping of extension name -> message ID as learned from a peer's
/// extension handshake.  IDs are 0 when the peer does not support
/// that extension.
pub const ExtensionIds = struct {
    ut_metadata: u8 = 0,
    ut_pex: u8 = 0,
};

// ── Extension handshake ──────────────────────────────────────

/// Parsed representation of a BEP 10 extension handshake payload.
pub const ExtensionHandshake = struct {
    extensions: ExtensionIds = .{},
    /// Peer's listen port (0 if not provided).
    port: u16 = 0,
    /// Client identification string.
    client: []const u8 = "",
    /// Size of the info dictionary (for ut_metadata / BEP 9).
    metadata_size: u32 = 0,
};

/// Check whether a peer's reserved bytes indicate BEP 10 support.
pub fn supportsExtensions(reserved: [8]u8) bool {
    return (reserved[reserved_byte] & reserved_mask) != 0;
}

/// Set the BEP 10 extension bit in a reserved byte array (in-place).
pub fn setExtensionBit(reserved: *[8]u8) void {
    reserved[reserved_byte] |= reserved_mask;
}

/// Encode our extension handshake payload (the data after the 6-byte
/// message header: 4-byte length + msg_id 20 + sub_id 0).
///
/// When `is_private` is true, ut_pex is omitted from the extension map
/// because BEP 27 forbids peer exchange for private torrents.
///
/// The returned slice is allocated with `allocator` and must be freed
/// by the caller.
pub fn encodeExtensionHandshake(allocator: std.mem.Allocator, listen_port: u16, is_private: bool) ![]u8 {
    // Build the "m" dictionary entries: extension name -> our local ID.
    // For private torrents, don't advertise ut_pex (BEP 27).
    const m_count: usize = if (is_private) 1 else 2;
    var m_entries = try allocator.alloc(bencode.Value.Entry, m_count);
    defer allocator.free(m_entries);

    // Keys must be in sorted order for canonical bencode (ut_metadata < ut_pex).
    m_entries[0] = .{ .key = ext_ut_metadata, .value = .{ .integer = local_ut_metadata_id } };
    if (!is_private) {
        m_entries[1] = .{ .key = ext_ut_pex, .value = .{ .integer = local_ut_pex_id } };
    }

    // Top-level dictionary entries.  Bencode dictionaries should have
    // keys in sorted order: "m" < "p" < "v".
    var entries = try allocator.alloc(bencode.Value.Entry, 3);
    defer allocator.free(entries);

    entries[0] = .{ .key = "m", .value = .{ .dict = m_entries } };
    entries[1] = .{ .key = "p", .value = .{ .integer = @as(i64, listen_port) } };
    entries[2] = .{ .key = "v", .value = .{ .bytes = client_version } };

    return bencode_encode.encode(allocator, .{ .dict = entries });
}

/// Decode a peer's extension handshake payload (the bencoded dictionary
/// after the sub-ID byte).
///
/// The returned struct references no heap memory beyond what the caller
/// already holds in `data`; no allocations are made for the result
/// itself, but the bencode parser allocates internally and the caller
/// must free with `freeDecoded`.
pub fn decodeExtensionHandshake(allocator: std.mem.Allocator, data: []const u8) !DecodeResult {
    const root = try bencode.parse(allocator, data);

    const dict = switch (root) {
        .dict => |d| d,
        else => {
            bencode.freeValue(allocator, root);
            return error.InvalidExtensionHandshake;
        },
    };

    var result = ExtensionHandshake{};

    // Parse "m" dictionary
    if (bencode.dictGet(dict, "m")) |m_val| {
        switch (m_val) {
            .dict => |m_dict| {
                if (bencode.dictGet(m_dict, ext_ut_metadata)) |v| {
                    if (v == .integer and v.integer >= 0 and v.integer <= 255) {
                        result.extensions.ut_metadata = @intCast(v.integer);
                    }
                }
                if (bencode.dictGet(m_dict, ext_ut_pex)) |v| {
                    if (v == .integer and v.integer >= 0 and v.integer <= 255) {
                        result.extensions.ut_pex = @intCast(v.integer);
                    }
                }
            },
            else => {},
        }
    }

    // Parse "p" (port)
    if (bencode.dictGet(dict, "p")) |v| {
        if (v == .integer and v.integer >= 0 and v.integer <= 65535) {
            result.port = @intCast(v.integer);
        }
    }

    // Parse "v" (client version)
    if (bencode.dictGet(dict, "v")) |v| {
        if (v == .bytes) {
            result.client = v.bytes;
        }
    }

    // Parse "metadata_size"
    if (bencode.dictGet(dict, "metadata_size")) |v| {
        if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
            result.metadata_size = @intCast(v.integer);
        }
    }

    return .{ .handshake = result, .root = root };
}

/// Result of decoding an extension handshake.  Holds ownership of the
/// parsed bencode tree so that string slices in `handshake` remain valid.
pub const DecodeResult = struct {
    handshake: ExtensionHandshake,
    root: bencode.Value,
};

pub fn freeDecoded(allocator: std.mem.Allocator, result: *DecodeResult) void {
    bencode.freeValue(allocator, result.root);
    result.* = undefined;
}

/// Serialize a complete extension message frame ready for the wire:
///   4-byte length (big-endian) | msg_id=20 | sub_id | payload
///
/// `sub_id` is 0 for the extension handshake, or the peer's extension
/// ID for a specific extension message.
///
/// Caller owns the returned slice.
pub fn serializeExtensionMessage(allocator: std.mem.Allocator, sub_id: u8, payload: []const u8) ![]u8 {
    const total_payload = 1 + 1 + payload.len; // msg_id + sub_id + payload
    const frame_len: u32 = @intCast(total_payload);
    const buf = try allocator.alloc(u8, 4 + total_payload);
    std.mem.writeInt(u32, buf[0..4], frame_len, .big);
    buf[4] = msg_id;
    buf[5] = sub_id;
    if (payload.len > 0) {
        @memcpy(buf[6..], payload);
    }
    return buf;
}

// ── Tests ────────────────────────────────────────────────────

test "supportsExtensions detects BEP 10 bit" {
    var reserved = [_]u8{0} ** 8;
    try std.testing.expect(!supportsExtensions(reserved));

    reserved[5] = 0x10;
    try std.testing.expect(supportsExtensions(reserved));

    // Other bits in byte 5 should not affect the check
    reserved[5] = 0xFF;
    try std.testing.expect(supportsExtensions(reserved));

    reserved[5] = 0xEF; // bit 4 cleared
    try std.testing.expect(!supportsExtensions(reserved));
}

test "setExtensionBit sets only the correct bit" {
    var reserved = [_]u8{0} ** 8;
    setExtensionBit(&reserved);
    try std.testing.expectEqual(@as(u8, 0x10), reserved[5]);

    // Verify it doesn't clobber other bits
    reserved[5] = 0x01;
    setExtensionBit(&reserved);
    try std.testing.expectEqual(@as(u8, 0x11), reserved[5]);
}

test "encode extension handshake produces valid bencode" {
    const payload = try encodeExtensionHandshake(std.testing.allocator, 6881, false);
    defer std.testing.allocator.free(payload);

    // Parse it back to verify it's valid bencode
    const parsed = try bencode.parse(std.testing.allocator, payload);
    defer bencode.freeValue(std.testing.allocator, parsed);

    // Verify structure
    const dict = parsed.dict;

    // Check "m" sub-dictionary
    const m_val = bencode.dictGet(dict, "m").?;
    const m_dict = m_val.dict;
    const ut_meta = bencode.dictGet(m_dict, ext_ut_metadata).?;
    try std.testing.expectEqual(@as(i64, local_ut_metadata_id), ut_meta.integer);
    const ut_pex_val = bencode.dictGet(m_dict, ext_ut_pex).?;
    try std.testing.expectEqual(@as(i64, local_ut_pex_id), ut_pex_val.integer);

    // Check "p"
    const port_val = bencode.dictGet(dict, "p").?;
    try std.testing.expectEqual(@as(i64, 6881), port_val.integer);

    // Check "v"
    const version_val = bencode.dictGet(dict, "v").?;
    try std.testing.expectEqualStrings(client_version, version_val.bytes);
}

test "decode extension handshake roundtrip" {
    const payload = try encodeExtensionHandshake(std.testing.allocator, 6881, false);
    defer std.testing.allocator.free(payload);

    var result = try decodeExtensionHandshake(std.testing.allocator, payload);
    defer freeDecoded(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u8, local_ut_metadata_id), result.handshake.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, local_ut_pex_id), result.handshake.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 6881), result.handshake.port);
    try std.testing.expectEqualStrings(client_version, result.handshake.client);
}

test "decode extension handshake with metadata_size" {
    // Hand-craft a bencode dict with metadata_size
    const input = "d1:md11:ut_metadatai3ee13:metadata_sizei12345e1:pi9999e1:v7:delugexe";
    var result = try decodeExtensionHandshake(std.testing.allocator, input);
    defer freeDecoded(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u8, 3), result.handshake.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 9999), result.handshake.port);
    try std.testing.expectEqualStrings("delugex", result.handshake.client);
    try std.testing.expectEqual(@as(u32, 12345), result.handshake.metadata_size);
}

test "decode extension handshake with empty m dict" {
    const input = "d1:mdee";
    var result = try decodeExtensionHandshake(std.testing.allocator, input);
    defer freeDecoded(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_pex);
}

test "decode extension handshake with minimal dict" {
    const input = "de";
    var result = try decodeExtensionHandshake(std.testing.allocator, input);
    defer freeDecoded(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u16, 0), result.handshake.port);
}

test "decode rejects non-dict input" {
    try std.testing.expectError(
        error.InvalidExtensionHandshake,
        decodeExtensionHandshake(std.testing.allocator, "i42e"),
    );
}

test "serializeExtensionMessage frames correctly" {
    const payload = "hello";
    const frame = try serializeExtensionMessage(std.testing.allocator, 0, payload);
    defer std.testing.allocator.free(frame);

    // Length: 1 (msg_id) + 1 (sub_id) + 5 (payload) = 7
    const frame_len = std.mem.readInt(u32, frame[0..4], .big);
    try std.testing.expectEqual(@as(u32, 7), frame_len);
    try std.testing.expectEqual(@as(u8, 20), frame[4]); // msg_id
    try std.testing.expectEqual(@as(u8, 0), frame[5]); // sub_id
    try std.testing.expectEqualStrings("hello", frame[6..11]);
}

test "private torrent extension handshake omits ut_pex" {
    const payload = try encodeExtensionHandshake(std.testing.allocator, 6881, true);
    defer std.testing.allocator.free(payload);

    var result = try decodeExtensionHandshake(std.testing.allocator, payload);
    defer freeDecoded(std.testing.allocator, &result);

    // ut_metadata should still be advertised
    try std.testing.expectEqual(@as(u8, local_ut_metadata_id), result.handshake.extensions.ut_metadata);
    // ut_pex must NOT be advertised for private torrents (BEP 27)
    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 6881), result.handshake.port);
}

test "serializeExtensionMessage with empty payload" {
    const frame = try serializeExtensionMessage(std.testing.allocator, 3, &.{});
    defer std.testing.allocator.free(frame);

    const frame_len = std.mem.readInt(u32, frame[0..4], .big);
    try std.testing.expectEqual(@as(u32, 2), frame_len); // msg_id + sub_id only
    try std.testing.expectEqual(@as(u8, 20), frame[4]);
    try std.testing.expectEqual(@as(u8, 3), frame[5]);
}

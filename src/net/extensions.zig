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
    /// BEP 21: peer is a partial seed (upload_only). When true, the peer has
    /// some pieces and is willing to upload but is not interested in downloading.
    upload_only: bool = false,
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
/// When `metadata_size` is non-zero, it is included in the handshake
/// so peers know the size of our info dictionary (BEP 9).
///
/// The returned slice is allocated with `allocator` and must be freed
/// by the caller.
pub fn encodeExtensionHandshake(allocator: std.mem.Allocator, listen_port: u16, is_private: bool) ![]u8 {
    return encodeExtensionHandshakeWithMetadata(allocator, listen_port, is_private, 0);
}

/// Encode extension handshake with optional metadata_size (BEP 9) and upload_only (BEP 21).
pub fn encodeExtensionHandshakeWithMetadata(allocator: std.mem.Allocator, listen_port: u16, is_private: bool, metadata_size: u32) ![]u8 {
    return encodeExtensionHandshakeFull(allocator, listen_port, is_private, metadata_size, false);
}

/// Encode extension handshake with all optional fields.
/// When `upload_only` is true, the handshake includes `upload_only: 1` (BEP 21).
pub fn encodeExtensionHandshakeFull(allocator: std.mem.Allocator, listen_port: u16, is_private: bool, metadata_size: u32, upload_only: bool) ![]u8 {
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
    // keys in sorted order: "m" < "metadata_size" < "p" < "upload_only" < "v".
    var entry_count: usize = 3; // m, p, v (always present)
    if (metadata_size > 0) entry_count += 1;
    if (upload_only) entry_count += 1;
    var entries = try allocator.alloc(bencode.Value.Entry, entry_count);
    defer allocator.free(entries);

    var idx: usize = 0;
    entries[idx] = .{ .key = "m", .value = .{ .dict = m_entries } };
    idx += 1;
    if (metadata_size > 0) {
        entries[idx] = .{ .key = "metadata_size", .value = .{ .integer = @as(i64, metadata_size) } };
        idx += 1;
    }
    entries[idx] = .{ .key = "p", .value = .{ .integer = @as(i64, listen_port) } };
    idx += 1;
    if (upload_only) {
        entries[idx] = .{ .key = "upload_only", .value = .{ .integer = 1 } };
        idx += 1;
    }
    entries[idx] = .{ .key = "v", .value = .{ .bytes = client_version } };

    return bencode_encode.encode(allocator, .{ .dict = entries });
}

/// Decode a peer's extension handshake payload (the bencoded dictionary
/// after the sub-ID byte).
///
/// The returned struct references no heap memory beyond what the caller
/// already holds in `data`; no allocations are made for the result.
pub fn decodeExtensionHandshake(data: []const u8) !ExtensionHandshake {
    var parser = Parser{ .input = data };
    try parser.expectByte('d');

    var result = ExtensionHandshake{};

    while (true) {
        const next = parser.peek() orelse return error.InvalidExtensionHandshake;
        if (next == 'e') {
            parser.index += 1;
            break;
        }

        const key = try parser.parseBytes();
        if (std.mem.eql(u8, key, "m")) {
            try parseExtensionMap(&parser, &result.extensions);
        } else if (std.mem.eql(u8, key, "p")) {
            const port = try parser.parseInteger();
            if (port >= 0 and port <= 65535) {
                result.port = @intCast(port);
            }
        } else if (std.mem.eql(u8, key, "v")) {
            result.client = try parser.parseBytes();
        } else if (std.mem.eql(u8, key, "metadata_size")) {
            const metadata_size = try parser.parseInteger();
            if (metadata_size >= 0 and metadata_size <= std.math.maxInt(u32)) {
                result.metadata_size = @intCast(metadata_size);
            }
        } else if (std.mem.eql(u8, key, "upload_only")) {
            result.upload_only = (try parser.parseInteger()) != 0;
        } else {
            try parser.skipValue();
        }
    }

    if (!parser.isAtEnd()) return error.InvalidExtensionHandshake;
    return result;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.input.len) return null;
        return self.input[self.index];
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.index == self.input.len;
    }

    fn expectByte(self: *Parser, byte: u8) !void {
        if (self.peek() != byte) return error.InvalidExtensionHandshake;
        self.index += 1;
    }

    fn parseBytes(self: *Parser) ![]const u8 {
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == ':') break;
            if (!std.ascii.isDigit(byte)) return error.InvalidExtensionHandshake;
            self.index += 1;
        }
        if (self.peek() != ':') return error.InvalidExtensionHandshake;

        const len_slice = self.input[start..self.index];
        if (len_slice.len == 0) return error.InvalidExtensionHandshake;

        self.index += 1;
        const len = std.fmt.parseUnsigned(usize, len_slice, 10) catch return error.InvalidExtensionHandshake;
        const end = self.index + len;
        if (end > self.input.len) return error.InvalidExtensionHandshake;

        defer self.index = end;
        return self.input[self.index..end];
    }

    fn parseInteger(self: *Parser) !i64 {
        try self.expectByte('i');
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == 'e') break;
            self.index += 1;
        }
        if (self.peek() != 'e') return error.InvalidExtensionHandshake;

        const digits = self.input[start..self.index];
        if (digits.len == 0) return error.InvalidExtensionHandshake;

        self.index += 1;
        return std.fmt.parseInt(i64, digits, 10) catch error.InvalidExtensionHandshake;
    }

    fn skipValue(self: *Parser) !void {
        const next = self.peek() orelse return error.InvalidExtensionHandshake;
        switch (next) {
            'i' => _ = try self.parseInteger(),
            'l' => {
                self.index += 1;
                while (true) {
                    const item = self.peek() orelse return error.InvalidExtensionHandshake;
                    if (item == 'e') {
                        self.index += 1;
                        return;
                    }
                    try self.skipValue();
                }
            },
            'd' => {
                self.index += 1;
                while (true) {
                    const item = self.peek() orelse return error.InvalidExtensionHandshake;
                    if (item == 'e') {
                        self.index += 1;
                        return;
                    }
                    _ = try self.parseBytes();
                    try self.skipValue();
                }
            },
            '0'...'9' => _ = try self.parseBytes(),
            else => return error.InvalidExtensionHandshake,
        }
    }
};

fn parseExtensionMap(parser: *Parser, ids: *ExtensionIds) !void {
    try parser.expectByte('d');
    while (true) {
        const next = parser.peek() orelse return error.InvalidExtensionHandshake;
        if (next == 'e') {
            parser.index += 1;
            return;
        }

        const key = try parser.parseBytes();
        const value = try parser.parseInteger();
        if (value < 0 or value > 255) continue;

        if (std.mem.eql(u8, key, ext_ut_metadata)) {
            ids.ut_metadata = @intCast(value);
        } else if (std.mem.eql(u8, key, ext_ut_pex)) {
            ids.ut_pex = @intCast(value);
        }
    }
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

    const result = try decodeExtensionHandshake(payload);

    try std.testing.expectEqual(@as(u8, local_ut_metadata_id), result.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, local_ut_pex_id), result.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 6881), result.port);
    try std.testing.expectEqualStrings(client_version, result.client);
}

test "decode extension handshake with metadata_size" {
    // Hand-craft a bencode dict with metadata_size
    const input = "d1:md11:ut_metadatai3ee13:metadata_sizei12345e1:pi9999e1:v7:delugexe";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expectEqual(@as(u8, 3), result.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 9999), result.port);
    try std.testing.expectEqualStrings("delugex", result.client);
    try std.testing.expectEqual(@as(u32, 12345), result.metadata_size);
}

test "decode extension handshake with empty m dict" {
    const input = "d1:mdee";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_pex);
}

test "decode extension handshake with minimal dict" {
    const input = "de";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expectEqual(@as(u16, 0), result.port);
}

test "decode rejects non-dict input" {
    try std.testing.expectError(
        error.InvalidExtensionHandshake,
        decodeExtensionHandshake("i42e"),
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

    const result = try decodeExtensionHandshake(payload);

    // ut_metadata should still be advertised
    try std.testing.expectEqual(@as(u8, local_ut_metadata_id), result.extensions.ut_metadata);
    // ut_pex must NOT be advertised for private torrents (BEP 27)
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_pex);
    try std.testing.expectEqual(@as(u16, 6881), result.port);
}

test "serializeExtensionMessage with empty payload" {
    const frame = try serializeExtensionMessage(std.testing.allocator, 3, &.{});
    defer std.testing.allocator.free(frame);

    const frame_len = std.mem.readInt(u32, frame[0..4], .big);
    try std.testing.expectEqual(@as(u32, 2), frame_len); // msg_id + sub_id only
    try std.testing.expectEqual(@as(u8, 20), frame[4]);
    try std.testing.expectEqual(@as(u8, 3), frame[5]);
}

// ── Fuzz and edge case tests ─────────────────────────────

test "fuzz BEP 10 extension handshake decoder" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            _ = decodeExtensionHandshake(input) catch return;
        }
    }.run, .{
        .corpus = &.{
            // Valid minimal dict
            "de",
            // Valid with m dict
            "d1:md11:ut_metadatai1eee",
            // Valid with all fields
            "d1:md11:ut_metadatai3e6:ut_pexi2ee13:metadata_sizei12345e1:pi9999e1:v7:delugexe",
            // Empty m dict
            "d1:mdee",
            // Non-dict (should error)
            "i42e",
            "le",
            "4:spam",
            // Invalid bencode
            "",
            "d",
            "d1:m",
            // Negative extension IDs (should be ignored)
            "d1:md11:ut_metadatai-1eee",
            // Overflow extension ID
            "d1:md11:ut_metadatai999eee",
            // Wrong type for m
            "d1:m4:teste",
            // Wrong type for port
            "d1:p4:teste",
            // Wrong type for version
            "d1:vi42ee",
        },
    });
}

test "extension handshake decoder edge cases: single byte inputs" {
    var buf: [1]u8 = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        buf[0] = @intCast(byte);
        _ = decodeExtensionHandshake(&buf) catch continue;
    }
}

test "extension handshake decoder handles truncated valid input" {
    const valid = "d1:md11:ut_metadatai3e6:ut_pexi2ee13:metadata_sizei12345e1:pi9999e1:v7:delugexe";
    for (0..valid.len) |i| {
        _ = decodeExtensionHandshake(valid[0..i]) catch continue;
    }
}

// ── BEP 21: upload_only / partial seed tests ────────────

test "decode extension handshake with upload_only=1" {
    const input = "d1:md11:ut_metadatai1ee1:pi6881e11:upload_onlyi1e1:v6:varunae";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expect(result.upload_only);
    try std.testing.expectEqual(@as(u8, 1), result.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u16, 6881), result.port);
}

test "decode extension handshake with upload_only=0" {
    const input = "d1:md11:ut_metadatai1ee11:upload_onlyi0ee";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expect(!result.upload_only);
}

test "decode extension handshake without upload_only defaults to false" {
    const input = "d1:md11:ut_metadatai1ee1:pi6881ee";
    const result = try decodeExtensionHandshake(input);

    try std.testing.expect(!result.upload_only);
}

test "encode extension handshake with upload_only" {
    const payload = try encodeExtensionHandshakeFull(std.testing.allocator, 6881, false, 0, true);
    defer std.testing.allocator.free(payload);

    const result = try decodeExtensionHandshake(payload);

    try std.testing.expect(result.upload_only);
    try std.testing.expectEqual(@as(u16, 6881), result.port);
}

test "encode extension handshake without upload_only omits key" {
    const payload = try encodeExtensionHandshakeFull(std.testing.allocator, 6881, false, 0, false);
    defer std.testing.allocator.free(payload);

    // The bencoded output should not contain "upload_only"
    try std.testing.expect(std.mem.indexOf(u8, payload, "upload_only") == null);

    const result = try decodeExtensionHandshake(payload);

    try std.testing.expect(!result.upload_only);
}

test "encode extension handshake with upload_only and metadata_size" {
    const payload = try encodeExtensionHandshakeFull(std.testing.allocator, 6881, false, 42000, true);
    defer std.testing.allocator.free(payload);

    const result = try decodeExtensionHandshake(payload);

    try std.testing.expect(result.upload_only);
    try std.testing.expectEqual(@as(u32, 42000), result.metadata_size);
    try std.testing.expectEqual(@as(u16, 6881), result.port);
}

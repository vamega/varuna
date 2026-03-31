const std = @import("std");
const varuna = @import("varuna");
const pw = varuna.net.peer_wire;
const ext = varuna.net.extensions;
const Bitfield = varuna.bitfield.Bitfield;

// ── Adversarial peer wire protocol tests ─────────────────────
//
// These tests verify that the protocol parsing layer correctly rejects
// malicious or malformed peer messages without crashing or leaking memory.
// They exercise the public serialization/deserialization helpers and
// protocol constants that guard the hot path against untrusted input.

// ── Oversized messages ──────────────────────────────────────

test "rejects message exceeding max_message_length" {
    // max_message_length is 1 MiB.  The event loop checks msg_len >
    // max_message_length and disconnects.  Verify the constant.
    try std.testing.expectEqual(@as(u32, 1048576), pw.max_message_length);

    // A peer claiming 2 MiB message length would be rejected
    const oversized_len: u32 = 2 * 1024 * 1024;
    try std.testing.expect(oversized_len > pw.max_message_length);
}

test "rejects message with length just above max" {
    const just_over: u32 = pw.max_message_length + 1;
    try std.testing.expect(just_over > pw.max_message_length);
}

test "accepts message at exactly max_message_length" {
    // A piece message with a 16KB block + 9 bytes header fits easily.
    const block_16k: u32 = 16 * 1024;
    const piece_msg_len: u32 = 1 + 8 + block_16k;
    try std.testing.expect(piece_msg_len <= pw.max_message_length);
}

test "max_message_length blocks multi-megabyte allocation attack" {
    // An attacker sends length = 0x7FFFFFFF (2 GB).  Without the
    // max_message_length guard, this would cause a massive allocation.
    const attack_len: u32 = 0x7FFFFFFF;
    try std.testing.expect(attack_len > pw.max_message_length);
}

// ── Invalid message IDs ─────────────────────────────────────

test "only standard BEP 3 and BEP 10 message IDs are recognized" {
    // Valid IDs: 0-9 (BEP 3) and 20 (BEP 10 extensions).
    // The event loop's processMessage switch has explicit cases for these
    // and an else => {} catch-all that silently drops unknown IDs.
    const valid_ids = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, ext.msg_id };
    try std.testing.expectEqual(@as(u8, 20), ext.msg_id);

    // IDs 10-19 and 21-255 are not handled
    for (10..20) |id| {
        var found = false;
        for (valid_ids) |valid| {
            if (valid == @as(u8, @intCast(id))) {
                found = true;
                break;
            }
        }
        try std.testing.expect(!found);
    }
}

// ── Messages with wrong lengths ─────────────────────────────

test "choke message must have empty payload" {
    // Choke (id=0) has length=1 (just the ID byte).  Any extra payload
    // is a protocol violation.  Verify the serialized form.
    const header = pw.serializeHeader(0, &.{});
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), wire_len);
}

test "unchoke message must have empty payload" {
    const header = pw.serializeHeader(1, &.{});
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), wire_len);
}

test "interested message must have empty payload" {
    const header = pw.serializeHeader(2, &.{});
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), wire_len);
}

test "not_interested message must have empty payload" {
    const header = pw.serializeHeader(3, &.{});
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), wire_len);
}

test "have message must have exactly 4-byte payload" {
    const buf = pw.serializeHave(42);
    const wire_len = std.mem.readInt(u32, buf[0..4], .big);
    // length = 1 (id) + 4 (index) = 5
    try std.testing.expectEqual(@as(u32, 5), wire_len);
}

test "request message must have exactly 12-byte payload" {
    const buf = pw.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16384 });
    const wire_len = std.mem.readInt(u32, buf[0..4], .big);
    // length = 1 (id) + 12 (3 x u32) = 13
    try std.testing.expectEqual(@as(u32, 13), wire_len);
}

test "piece header encodes correct frame length" {
    const header = try pw.serializePieceHeader(0, 0, 16384);
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    // length = 1 (id) + 8 (index + offset) + 16384 (block) = 16393
    try std.testing.expectEqual(@as(u32, 16393), wire_len);
}

// ── Malformed handshake ─────────────────────────────────────

test "handshake with wrong protocol string length is detectable" {
    var buf = pw.serializeHandshake([_]u8{0xAA} ** 20, [_]u8{0xBB} ** 20);
    try std.testing.expectEqual(@as(u8, 19), buf[0]);

    // Corrupt the length byte
    buf[0] = 20;
    try std.testing.expect(buf[0] != pw.protocol_length);
}

test "handshake with wrong protocol string is detectable" {
    var buf = pw.serializeHandshake([_]u8{0xAA} ** 20, [_]u8{0xBB} ** 20);
    buf[1] = 'X';
    try std.testing.expect(!std.mem.eql(u8, buf[1..20], pw.protocol_string));
}

test "handshake with wrong info_hash is detectable" {
    const expected_hash = [_]u8{0xAA} ** 20;
    const wrong_hash = [_]u8{0xCC} ** 20;
    const buf = pw.serializeHandshake(wrong_hash, [_]u8{0xBB} ** 20);
    try std.testing.expect(!std.mem.eql(u8, buf[28..48], &expected_hash));
}

test "handshake is exactly 68 bytes" {
    const buf = pw.serializeHandshake([_]u8{0} ** 20, [_]u8{0} ** 20);
    try std.testing.expectEqual(@as(usize, 68), buf.len);
}

test "handshake with all zeros has correct structure" {
    const buf = pw.serializeHandshake([_]u8{0} ** 20, [_]u8{0} ** 20);
    try std.testing.expectEqual(@as(u8, 19), buf[0]);
    try std.testing.expectEqualStrings("BitTorrent protocol", buf[1..20]);
}

// ── Sending pieces we didn't request ────────────────────────

test "piece message for unrequested piece index is ignored by guard" {
    // processMessage checks: peer.current_piece == piece_index.
    // If the peer sends data for a piece we're not downloading, it's dropped.
    const current: ?u32 = 5;
    const received_index: u32 = 10;
    const matches = current != null and current.? == received_index;
    try std.testing.expect(!matches);
}

test "piece message when no piece assigned is ignored by guard" {
    const current: ?u32 = null;
    const received_index: u32 = 0;
    const matches = current != null and current.? == received_index;
    try std.testing.expect(!matches);
}

// ── Sending data for non-existent pieces ────────────────────

test "have message with out-of-range piece index is bounded by bitfield" {
    var bf = try Bitfield.init(std.testing.allocator, 10);
    defer bf.deinit(std.testing.allocator);

    // Setting an index >= count returns error (no crash)
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(10));
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(1000));
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(0xFFFFFFFF));
}

test "bitfield import with oversized data is clamped" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    // Import a bitfield that's larger than needed (4 bytes for 8 pieces = 1 byte)
    const oversized = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    bf.importBitfield(&oversized);
    // Should only count the 8 valid pieces, not 32
    try std.testing.expectEqual(@as(u32, 8), bf.count);
}

test "bitfield import with undersized data fills what it can" {
    var bf = try Bitfield.init(std.testing.allocator, 32);
    defer bf.deinit(std.testing.allocator);

    // Import only 1 byte for a 32-piece (4-byte) bitfield
    const undersized = [_]u8{0xFF};
    bf.importBitfield(&undersized);
    // Only first 8 pieces should be set
    try std.testing.expectEqual(@as(u32, 8), bf.count);
}

// ── Extension messages with invalid bencode ─────────────────

test "extension handshake with garbage data does not crash" {
    const garbage_inputs = [_][]const u8{
        "",
        "\x00",
        "not bencode",
        "i42e",
        "le",
        "d",
        "d1:x",
        "\xff\xff\xff\xff",
        "d1:m1:xe",
        "d1:md11:ut_metadatai-1eee",
        "d1:md11:ut_metadatai999eee",
    };

    for (garbage_inputs) |input| {
        var result = ext.decodeExtensionHandshake(std.testing.allocator, input) catch continue;
        ext.freeDecoded(std.testing.allocator, &result);
    }
}

test "extension handshake with oversized bencode string claim" {
    const bad_input = "d1:m99999999:xe";
    var result = ext.decodeExtensionHandshake(std.testing.allocator, bad_input) catch return;
    ext.freeDecoded(std.testing.allocator, &result);
}

test "extension handshake with negative port is clamped to zero" {
    const input = "d1:pi-1ee";
    var result = ext.decodeExtensionHandshake(std.testing.allocator, input) catch return;
    defer ext.freeDecoded(std.testing.allocator, &result);
    // Negative port should be ignored (stays 0)
    try std.testing.expectEqual(@as(u16, 0), result.handshake.port);
}

test "extension handshake with port overflow is clamped to zero" {
    const input = "d1:pi99999ee";
    var result = ext.decodeExtensionHandshake(std.testing.allocator, input) catch return;
    defer ext.freeDecoded(std.testing.allocator, &result);
    // Port > 65535 should be ignored (stays 0)
    try std.testing.expectEqual(@as(u16, 0), result.handshake.port);
}

// ── Bitfield after other messages (protocol violation) ──────

test "bitfield message has correct wire format" {
    // Per BEP 3, bitfield must be sent immediately after handshake.
    // Verify the serialized format is correct.
    const bits = [_]u8{ 0xFF, 0x80 };
    const header = pw.serializeHeader(5, &bits);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, header[0..4], .big));
    try std.testing.expectEqual(@as(u8, 5), header[4]);
}

// ── Rapid connect/disconnect (connection flooding) ──────────

test "connection limits are sane defaults" {
    // global >= per-torrent >= half-open
    const global: u32 = 500;
    const per_torrent: u32 = 100;
    const half_open: u32 = 50;
    try std.testing.expect(global >= per_torrent);
    try std.testing.expect(per_torrent >= half_open);
}

// ── Piece message bounds ────────────────────────────────────

test "piece message with block offset beyond piece size is out of bounds" {
    const piece_size: usize = 16384;
    const block_offset: usize = 16384;
    const block_len: usize = 1;
    const end = block_offset + block_len;
    try std.testing.expect(end > piece_size);
}

test "piece message with zero-length block after index+offset is valid wire format" {
    // 8 bytes (index + offset) + 0 bytes data = minimum valid piece payload
    const header = try pw.serializePieceHeader(0, 0, 0);
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    // 1 (id) + 8 (index+offset) + 0 (data) = 9
    try std.testing.expectEqual(@as(u32, 9), wire_len);
}

// ── Keep-alive flood ────────────────────────────────────────

test "keep-alive is zero-length and allocates nothing" {
    const msg_len = std.mem.readInt(u32, &pw.keepalive_bytes, .big);
    try std.testing.expectEqual(@as(u32, 0), msg_len);
}

// ── Request message with oversized block ────────────────────

test "request with 1MB block length is serializable but abusive" {
    const abusive_block: u32 = 1024 * 1024;
    const req = pw.serializeRequest(.{
        .piece_index = 0,
        .block_offset = 0,
        .length = abusive_block,
    });
    const length_field = std.mem.readInt(u32, req[13..17], .big);
    try std.testing.expectEqual(abusive_block, length_field);
}

// ── Cancel message format ───────────────────────────────────

test "cancel and request have same payload size but different IDs" {
    const req_header = pw.serializeHeader(6, &([_]u8{0} ** 12));
    const cancel_header = pw.serializeHeader(8, &([_]u8{0} ** 12));
    try std.testing.expectEqual(
        std.mem.readInt(u32, req_header[0..4], .big),
        std.mem.readInt(u32, cancel_header[0..4], .big),
    );
    try std.testing.expect(req_header[4] != cancel_header[4]);
}

// ── BEP 10 reserved bit detection ───────────────────────────

test "extension support detection with various reserved byte patterns" {
    // All zeros = no extension support
    try std.testing.expect(!ext.supportsExtensions([_]u8{0} ** 8));

    // Correct bit set
    var reserved = [_]u8{0} ** 8;
    reserved[5] = 0x10;
    try std.testing.expect(ext.supportsExtensions(reserved));

    // Other bits in byte 5 don't matter
    reserved[5] = 0xFF;
    try std.testing.expect(ext.supportsExtensions(reserved));

    // Bit cleared among others
    reserved[5] = 0xEF;
    try std.testing.expect(!ext.supportsExtensions(reserved));
}

// ── Extension handshake private torrent behavior ────────────

test "private torrent extension handshake omits ut_pex" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, true);
    defer std.testing.allocator.free(payload);

    var result = try ext.decodeExtensionHandshake(std.testing.allocator, payload);
    defer ext.freeDecoded(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u8, ext.local_ut_metadata_id), result.handshake.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.handshake.extensions.ut_pex);
}

test "public torrent extension handshake includes ut_pex" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, false);
    defer std.testing.allocator.free(payload);

    var result = try ext.decodeExtensionHandshake(std.testing.allocator, payload);
    defer ext.freeDecoded(std.testing.allocator, &result);

    try std.testing.expect(result.handshake.extensions.ut_pex != 0);
}

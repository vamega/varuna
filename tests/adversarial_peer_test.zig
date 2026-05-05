const std = @import("std");
const varuna = @import("varuna");
const pw = varuna.net.peer_wire;
const ext = varuna.net.extensions;
const bencode = varuna.torrent.bencode;
const krpc = varuna.dht.krpc;
const Bitfield = varuna.bitfield.Bitfield;

// ── Adversarial peer wire protocol tests ─────────────────────
//
// These tests verify that the protocol parsing layer correctly rejects
// malicious or malformed peer messages without crashing or leaking memory.
// They exercise real parsing functions (bencode.parse, ext.decodeExtensionHandshake,
// krpc.parse) with adversarial input.  Where peer_wire functions do I/O via
// io_uring (readMessageAlloc), we test the constants, serialization, and
// the higher-level parsers that consume the payload bytes.

// ═══════════════════════════════════════════════════════════════
// 1. Peer wire protocol: message framing and serialization
// ═══════════════════════════════════════════════════════════════

// ── Oversized message guard ────────────────────────────────

test "max_message_length is 1 MiB" {
    // readMessageAlloc checks `length > max_message_length` and returns
    // error.MessageTooLarge.  This constant must stay at 1 MiB.
    try std.testing.expectEqual(@as(u32, 1048576), pw.max_message_length);
}

// ── Handshake format ───────────────────────────────────────

test "handshake is exactly 68 bytes with correct structure" {
    const buf = pw.serializeHandshake(@as([20]u8, @splat(0xAA)), @as([20]u8, @splat(0xBB)));
    try std.testing.expectEqual(@as(usize, 68), buf.len);
    try std.testing.expectEqual(@as(u8, 19), buf[0]);
    try std.testing.expectEqualStrings("BitTorrent protocol", buf[1..20]);
}

test "handshake with wrong protocol length byte is detectable" {
    var buf = pw.serializeHandshake(@as([20]u8, @splat(0xAA)), @as([20]u8, @splat(0xBB)));
    buf[0] = 20;
    try std.testing.expect(buf[0] != pw.protocol_length);
}

test "handshake with corrupted protocol string is detectable" {
    var buf = pw.serializeHandshake(@as([20]u8, @splat(0xAA)), @as([20]u8, @splat(0xBB)));
    buf[1] = 'X';
    try std.testing.expect(!std.mem.eql(u8, buf[1..20], pw.protocol_string));
}

test "handshake sets BEP 10 extension bit" {
    const buf = pw.serializeHandshake(@as([20]u8, @splat(0)), @as([20]u8, @splat(0)));
    // reserved bytes are at offset 20..28, BEP 10 bit is byte 5 mask 0x10
    try std.testing.expect((buf[20 + ext.reserved_byte] & ext.reserved_mask) != 0);
}

// ── Serialized message lengths ─────────────────────────────

test "choke/unchoke/interested/not_interested serialize to length=1" {
    const ids = [_]u8{ 0, 1, 2, 3 };
    for (ids) |id| {
        const header = pw.serializeHeader(id, &.{});
        const wire_len = std.mem.readInt(u32, header[0..4], .big);
        try std.testing.expectEqual(@as(u32, 1), wire_len);
    }
}

test "have message serializes to length=5" {
    const buf = pw.serializeHave(42);
    const wire_len = std.mem.readInt(u32, buf[0..4], .big);
    try std.testing.expectEqual(@as(u32, 5), wire_len);
    try std.testing.expectEqual(@as(u8, 4), buf[4]); // msg id
}

test "request message serializes to length=13" {
    const buf = pw.serializeRequest(.{ .piece_index = 0, .block_offset = 0, .length = 16384 });
    const wire_len = std.mem.readInt(u32, buf[0..4], .big);
    try std.testing.expectEqual(@as(u32, 13), wire_len);
    try std.testing.expectEqual(@as(u8, 6), buf[4]); // msg id
}

test "piece header encodes correct frame length" {
    const header = try pw.serializePieceHeader(0, 0, 16384);
    const wire_len = std.mem.readInt(u32, header[0..4], .big);
    // 1 (id) + 8 (index + offset) + 16384 (block) = 16393
    try std.testing.expectEqual(@as(u32, 16393), wire_len);
}

// ── Request with oversized block length (> 128KB) ──────────

test "request with block_length > 128KB encodes but is abusive" {
    // BEP 3 allows 16KB blocks; 128KB is a common upper limit.
    // The wire serializer does not reject this -- the event loop must.
    const abusive_block: u32 = 256 * 1024;
    const req = pw.serializeRequest(.{
        .piece_index = 0,
        .block_offset = 0,
        .length = abusive_block,
    });
    const length_field = std.mem.readInt(u32, req[13..17], .big);
    try std.testing.expectEqual(abusive_block, length_field);
    try std.testing.expect(abusive_block > 128 * 1024);
}

// ── Keep-alive ─────────────────────────────────────────────

test "keep-alive is zero-length message" {
    const msg_len = std.mem.readInt(u32, &pw.keepalive_bytes, .big);
    try std.testing.expectEqual(@as(u32, 0), msg_len);
}

// ── Cancel vs request ──────────────────────────────────────

test "cancel and request have same payload size but different IDs" {
    const req_header = pw.serializeHeader(6, &(@as([12]u8, @splat(0))));
    const cancel_header = pw.serializeHeader(8, &(@as([12]u8, @splat(0))));
    try std.testing.expectEqual(
        std.mem.readInt(u32, req_header[0..4], .big),
        std.mem.readInt(u32, cancel_header[0..4], .big),
    );
    try std.testing.expect(req_header[4] != cancel_header[4]);
}

// ═══════════════════════════════════════════════════════════════
// 2. Bitfield bounds checking
// ═══════════════════════════════════════════════════════════════

test "bitfield.set rejects out-of-range piece indices" {
    var bf = try Bitfield.init(std.testing.allocator, 10);
    defer bf.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidPieceIndex, bf.set(10));
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(1000));
    try std.testing.expectError(error.InvalidPieceIndex, bf.set(0xFFFFFFFF));
}

test "bitfield import with oversized data clamps to piece_count" {
    var bf = try Bitfield.init(std.testing.allocator, 8);
    defer bf.deinit(std.testing.allocator);

    const oversized = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    bf.importBitfield(&oversized);
    try std.testing.expectEqual(@as(u32, 8), bf.count);
}

test "bitfield import with undersized data fills partial" {
    var bf = try Bitfield.init(std.testing.allocator, 32);
    defer bf.deinit(std.testing.allocator);

    const undersized = [_]u8{0xFF};
    bf.importBitfield(&undersized);
    try std.testing.expectEqual(@as(u32, 8), bf.count);
}

test "bitfield import with empty data sets nothing" {
    var bf = try Bitfield.init(std.testing.allocator, 16);
    defer bf.deinit(std.testing.allocator);

    bf.importBitfield(&.{});
    try std.testing.expectEqual(@as(u32, 0), bf.count);
}

// ═══════════════════════════════════════════════════════════════
// 3. Extension handshake decoding (real parser, adversarial input)
// ═══════════════════════════════════════════════════════════════

test "extension handshake rejects empty input" {
    const result = ext.decodeExtensionHandshake("");
    try std.testing.expectError(error.InvalidExtensionHandshake, result);
}

test "extension handshake rejects non-dict input" {
    // Integer, list, byte string -- all invalid as extension handshake
    const bad_inputs = [_][]const u8{ "i42e", "le", "4:spam" };
    for (bad_inputs) |input| {
        const result = ext.decodeExtensionHandshake(input);
        try std.testing.expectError(error.InvalidExtensionHandshake, result);
    }
}

test "extension handshake rejects truncated dict" {
    // dict that opens but never closes
    const result = ext.decodeExtensionHandshake("d");
    try std.testing.expectError(error.InvalidExtensionHandshake, result);
}

test "extension handshake rejects truncated key" {
    // dict with a key whose length exceeds remaining data
    const result = ext.decodeExtensionHandshake("d99:");
    try std.testing.expectError(error.InvalidExtensionHandshake, result);
}

test "extension handshake rejects garbage bytes" {
    const garbage_inputs = [_][]const u8{
        "\x00",
        "not bencode",
        "\xff\xff\xff\xff",
        "d\xff",
    };
    for (garbage_inputs) |input| {
        const result = ext.decodeExtensionHandshake(input);
        try std.testing.expect(std.meta.isError(result));
    }
}

test "extension handshake rejects trailing data after dict" {
    // Valid dict followed by extra bytes
    const result = ext.decodeExtensionHandshake("deextra");
    try std.testing.expectError(error.InvalidExtensionHandshake, result);
}

test "extension handshake rejects oversized bencode string claim" {
    // Key claims 99999999 bytes but the input is tiny
    const result = ext.decodeExtensionHandshake("d99999999:xe");
    try std.testing.expectError(error.InvalidExtensionHandshake, result);
}

test "extension handshake with negative port yields port=0" {
    const input = "d1:pi-1ee";
    const result = ext.decodeExtensionHandshake(input) catch {
        // Parser might reject this; that's fine
        return;
    };
    try std.testing.expectEqual(@as(u16, 0), result.port);
}

test "extension handshake with port overflow yields port=0" {
    const input = "d1:pi99999ee";
    const result = ext.decodeExtensionHandshake(input) catch {
        return;
    };
    try std.testing.expectEqual(@as(u16, 0), result.port);
}

test "extension handshake parses valid minimal dict" {
    const result = try ext.decodeExtensionHandshake("de");
    try std.testing.expectEqual(@as(u16, 0), result.port);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_metadata);
}

test "extension handshake with wrong value types for known keys" {
    // "m" should be a dict but we give it an integer
    const result1 = ext.decodeExtensionHandshake("d1:mi42ee");
    try std.testing.expect(std.meta.isError(result1));

    // "p" should be an integer but we give it a string
    const result2 = ext.decodeExtensionHandshake("d1:p3:fooe");
    try std.testing.expect(std.meta.isError(result2));

    // "v" should be a string but we give it an integer
    const result3 = ext.decodeExtensionHandshake("d1:vi42ee");
    try std.testing.expect(std.meta.isError(result3));
}

test "extension handshake with nested extension map entries" {
    // Valid extension map with metadata ID
    const input = "d1:md11:ut_metadatai3eee";
    const result = try ext.decodeExtensionHandshake(input);
    try std.testing.expectEqual(@as(u8, 3), result.extensions.ut_metadata);
}

test "extension handshake with negative extension ID is ignored" {
    // Negative IDs are out of range for u8, should be silently skipped
    const input = "d1:md11:ut_metadatai-1eee";
    const result = try ext.decodeExtensionHandshake(input);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_metadata);
}

test "extension handshake with extension ID > 255 is ignored" {
    const input = "d1:md11:ut_metadatai999eee";
    const result = try ext.decodeExtensionHandshake(input);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_metadata);
}

test "extension encode/decode roundtrip preserves fields" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, false);
    defer std.testing.allocator.free(payload);

    const result = try ext.decodeExtensionHandshake(payload);

    try std.testing.expectEqual(@as(u16, 6881), result.port);
    try std.testing.expectEqual(@as(u8, ext.local_ut_metadata_id), result.extensions.ut_metadata);
    try std.testing.expect(result.extensions.ut_pex != 0);
}

test "private torrent extension handshake omits ut_pex" {
    const payload = try ext.encodeExtensionHandshake(std.testing.allocator, 6881, true);
    defer std.testing.allocator.free(payload);

    const result = try ext.decodeExtensionHandshake(payload);

    try std.testing.expectEqual(@as(u8, ext.local_ut_metadata_id), result.extensions.ut_metadata);
    try std.testing.expectEqual(@as(u8, 0), result.extensions.ut_pex);
}

// ── BEP 10 reserved bit detection ──────────────────────────

test "extension support detection with various reserved byte patterns" {
    try std.testing.expect(!ext.supportsExtensions(@as([8]u8, @splat(0))));

    var reserved = @as([8]u8, @splat(0));
    reserved[5] = 0x10;
    try std.testing.expect(ext.supportsExtensions(reserved));

    reserved[5] = 0xFF;
    try std.testing.expect(ext.supportsExtensions(reserved));

    reserved[5] = 0xEF;
    try std.testing.expect(!ext.supportsExtensions(reserved));
}

// ═══════════════════════════════════════════════════════════════
// 4. Bencode parser (real parser, adversarial input)
// ═══════════════════════════════════════════════════════════════

test "bencode rejects empty input" {
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, ""));
}

test "bencode rejects invalid prefix bytes" {
    try std.testing.expectError(error.InvalidPrefix, bencode.parse(std.testing.allocator, "x"));
    try std.testing.expectError(error.InvalidPrefix, bencode.parse(std.testing.allocator, "\xff"));
    try std.testing.expectError(error.InvalidPrefix, bencode.parse(std.testing.allocator, "\x00"));
}

test "bencode rejects trailing data" {
    try std.testing.expectError(error.TrailingData, bencode.parse(std.testing.allocator, "i1ei2e"));
    try std.testing.expectError(error.TrailingData, bencode.parse(std.testing.allocator, "i42eextra"));
}

test "bencode rejects truncated integer" {
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "i"));
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "i42"));
}

test "bencode rejects empty integer body" {
    try std.testing.expectError(error.InvalidInteger, bencode.parse(std.testing.allocator, "ie"));
}

test "bencode rejects integer overflow" {
    // i64 max is 9223372036854775807; one more should overflow
    try std.testing.expectError(
        error.Overflow,
        bencode.parse(std.testing.allocator, "i99999999999999999999e"),
    );
}

test "bencode accepts negative integers" {
    const value = try bencode.parse(std.testing.allocator, "i-42e");
    defer bencode.freeValue(std.testing.allocator, value);
    try std.testing.expectEqual(@as(i64, -42), value.integer);
}

test "bencode rejects byte string with length exceeding input" {
    // Claims 999 bytes but input is tiny
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        bencode.parse(std.testing.allocator, "999:abc"),
    );
}

test "bencode rejects byte string with no colon" {
    try std.testing.expectError(
        error.UnexpectedEndOfStream,
        bencode.parse(std.testing.allocator, "5"),
    );
}

test "bencode rejects byte string with non-digit in length prefix" {
    // "1a2:..." -- starts with a digit but has non-digit 'a' in the length
    try std.testing.expectError(
        error.InvalidByteStringLength,
        bencode.parse(std.testing.allocator, "1a2:def"),
    );
}

test "bencode rejects non-digit start as invalid prefix" {
    // 'a' is not a valid bencode prefix (not 'i', 'l', 'd', or digit)
    try std.testing.expectError(
        error.InvalidPrefix,
        bencode.parse(std.testing.allocator, "abc:def"),
    );
}

test "bencode rejects truncated list" {
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "l"));
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "li1e"));
}

test "bencode rejects truncated dict" {
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "d"));
    // Key present but no value
    try std.testing.expectError(error.UnexpectedEndOfStream, bencode.parse(std.testing.allocator, "d1:a"));
}

test "bencode rejects deeply nested lists beyond max_nesting_depth" {
    // max_nesting_depth is 64; build 65 nested lists "lll...l" + "eee...e"
    const depth = 65;
    var buf: [depth * 2]u8 = undefined;
    @memset(buf[0..depth], 'l');
    @memset(buf[depth..], 'e');

    const result = bencode.parse(std.testing.allocator, &buf);
    try std.testing.expectError(error.NestingTooDeep, result);
}

test "bencode rejects deeply nested dicts beyond max_nesting_depth" {
    // Each nesting level: "d1:a" (4 bytes key), innermost "de", then closing 'e's
    const depth = 65;
    const prefix_len = depth * 4;
    const total_len = prefix_len + 2 + depth; // +2 for innermost "de", +depth for closing 'e's
    var buf = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(buf);

    for (0..depth) |i| {
        buf[i * 4 + 0] = 'd';
        buf[i * 4 + 1] = '1';
        buf[i * 4 + 2] = ':';
        buf[i * 4 + 3] = 'a';
    }
    buf[prefix_len] = 'd';
    buf[prefix_len + 1] = 'e';
    @memset(buf[prefix_len + 2 ..], 'e');

    const result = bencode.parse(std.testing.allocator, buf);
    try std.testing.expectError(error.NestingTooDeep, result);
}

test "bencode accepts nesting at exactly max depth (64 levels)" {
    // 64 nested lists with proper closing should parse (depth check is >=64, triggers at 65th)
    const depth = 64;
    var buf: [depth * 2]u8 = undefined;
    @memset(buf[0..depth], 'l');
    @memset(buf[depth..], 'e');

    const value = try bencode.parse(std.testing.allocator, &buf);
    bencode.freeValue(std.testing.allocator, value);
}

test "bencode handles all single-byte inputs without panic" {
    var buf: [1]u8 = undefined;
    for (0..256) |b| {
        buf[0] = @intCast(b);
        if (bencode.parse(std.testing.allocator, &buf)) |value| {
            bencode.freeValue(std.testing.allocator, value);
        } else |_| {}
    }
}

test "bencode parses valid complex structure" {
    const input = "d3:cow3:moo4:spamli1ei2eee";
    const value = try bencode.parse(std.testing.allocator, input);
    defer bencode.freeValue(std.testing.allocator, value);

    try std.testing.expectEqual(@as(usize, 2), value.dict.len);
    try std.testing.expectEqualStrings("cow", value.dict[0].key);
    try std.testing.expectEqualStrings("moo", value.dict[0].value.bytes);
}

test "bencode rejects negative string length attempt" {
    // "-5:hello" -- '-' is not a digit, so the byte string parser rejects it
    const result = bencode.parse(std.testing.allocator, "-5:hello");
    try std.testing.expect(std.meta.isError(result));
}

test "bencode rejects zero-length prefix for byte string" {
    // ":hello" -- no length digits before colon
    const result = bencode.parse(std.testing.allocator, ":hello");
    try std.testing.expect(std.meta.isError(result));
}

// ═══════════════════════════════════════════════════════════════
// 5. KRPC message parsing (real parser, adversarial input)
// ═══════════════════════════════════════════════════════════════

test "krpc rejects empty input" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse(""));
}

test "krpc rejects non-dict input" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("i42e"));
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("le"));
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("4:spam"));
}

test "krpc rejects single byte" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d"));
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("x"));
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("\x00"));
}

test "krpc rejects dict missing required 't' (transaction ID)" {
    // Valid dict with "y" but no "t"
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:y1:qe"));
}

test "krpc rejects dict missing required 'y' (message type)" {
    // Valid dict with "t" but no "y"
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aae"));
}

test "krpc rejects query missing 'q' (method)" {
    // Has "t" and "y"="q" but no "q" key
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aa1:y1:qe"));
}

test "krpc rejects query missing 'a' (args dict)" {
    // Has "t", "y"="q", "q"="ping" but no "a" dict
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:q4:ping1:t2:aa1:y1:qe"));
}

test "krpc rejects unknown method" {
    // Method "badmethod" is not a valid KRPC method
    const data = "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaae1:q9:badmethod1:t2:aa1:y1:qe";
    try std.testing.expectError(error.InvalidKrpc, krpc.parse(data));
}

test "krpc rejects unknown message type" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aa1:y1:xe"));
}

test "krpc rejects multi-char message type" {
    // "y" value must be exactly 1 byte
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aa1:y2:qqe"));
}

test "krpc rejects query with wrong-length node ID" {
    // Node ID must be exactly 20 bytes; give 10
    const data = "d1:ad2:id10:aaaaaaaaaae1:q4:ping1:t2:aa1:y1:qe";
    try std.testing.expectError(error.InvalidKrpc, krpc.parse(data));
}

test "krpc rejects find_node with wrong-length target" {
    // target must be 20 bytes; give 5
    const node_id_20 = "aaaaaaaaaaaaaaaaaaaa";
    const data = "d1:ad2:id20:" ++ node_id_20 ++ "6:target5:xxxxxe1:q9:find_node1:t2:aa1:y1:qe";
    try std.testing.expectError(error.InvalidKrpc, krpc.parse(data));
}

test "krpc rejects response missing 'r' dict" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aa1:y1:re"));
}

test "krpc rejects error response missing 'e' list" {
    try std.testing.expectError(error.InvalidKrpc, krpc.parse("d1:t2:aa1:y1:ee"));
}

test "krpc rejects garbage bytes" {
    const garbage_inputs = [_][]const u8{
        "\xff\xff\xff\xff",
        "d\xff",
        "d1:t\xff",
        "\x00\x00\x00\x00",
    };
    for (garbage_inputs) |input| {
        const result = krpc.parse(input);
        try std.testing.expect(std.meta.isError(result));
    }
}

test "krpc parses valid ping query" {
    var buf: [512]u8 = undefined;
    var our_id: varuna.dht.NodeId = undefined;
    @memset(&our_id, 0xAA);

    const len = try krpc.encodePingQuery(&buf, 0x1234, our_id);
    const msg = try krpc.parse(buf[0..len]);

    switch (msg) {
        .query => |q| {
            try std.testing.expectEqual(krpc.Method.ping, q.method);
            try std.testing.expectEqual(our_id, q.sender_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "krpc parses valid error response" {
    var buf: [512]u8 = undefined;
    const len = try krpc.encodeError(&buf, "zz", 201, "Generic Error");
    const msg = try krpc.parse(buf[0..len]);

    switch (msg) {
        .@"error" => |e| {
            try std.testing.expectEqual(@as(u32, 201), e.code);
            try std.testing.expectEqualStrings("Generic Error", e.message);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "krpc rejects response with wrong-length node ID" {
    // Build a response with a 10-byte ID instead of 20
    const data = "d1:rd2:id10:aaaaaaaaaae1:t2:aa1:y1:re";
    try std.testing.expectError(error.InvalidKrpc, krpc.parse(data));
}

test "krpc rejects truncated bencode in body" {
    // "a" value is a truncated dict -- opens with 'd' but no content or close
    const data = "d1:ad1:q4:ping1:t2:aa1:y1:qe";
    const result = krpc.parse(data);
    try std.testing.expect(std.meta.isError(result));
}

test "krpc handles all single-byte inputs without panic" {
    var buf: [1]u8 = undefined;
    for (0..256) |b| {
        buf[0] = @intCast(b);
        _ = krpc.parse(&buf) catch continue;
    }
}

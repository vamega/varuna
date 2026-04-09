const std = @import("std");
const posix = std.posix;
const extensions = @import("extensions.zig");

pub fn sendAll(fd: posix.fd_t, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const n = try posix.write(fd, buf[sent..]);
        sent += n;
    }
}

pub fn recvExact(fd: posix.fd_t, buf: []u8) !void {
    var received: usize = 0;
    while (received < buf.len) {
        const n = try posix.read(fd, buf[received..]);
        if (n == 0) return error.EndOfStream;
        received += n;
    }
}

pub const protocol_string = "BitTorrent protocol";
pub const protocol_length: u8 = protocol_string.len;
pub const max_message_length: u32 = 1 * 1024 * 1024;

/// BEP 10 extension message ID.
pub const msg_extension: u8 = extensions.msg_id;

pub const Request = struct {
    piece_index: u32,
    block_offset: u32,
    length: u32,
};

/// payload is the owned allocation; block is payload[8..] (the piece data without header).
/// Only payload should be freed.
pub const Piece = struct {
    piece_index: u32,
    block_offset: u32,
    block: []u8,
    payload: []u8,
};

pub const Handshake = struct {
    reserved: [8]u8,
    info_hash: [20]u8,
    peer_id: [20]u8,
};

pub const InboundMessage = union(enum) {
    keep_alive,
    choke,
    unchoke,
    interested,
    not_interested,
    have: u32,
    bitfield: []u8,
    request: Request,
    piece: Piece,
    cancel: Request,
    port: u16,
};

/// BEP 52: reserved byte/bit for v2 protocol support.
/// Bit 0x10 in reserved[7] signals that this client supports BitTorrent v2.
pub const v2_reserved_byte: usize = 7;
pub const v2_reserved_mask: u8 = 0x10;

/// Check whether a peer's reserved bytes indicate BEP 52 (v2) support.
pub fn supportsV2(reserved: [8]u8) bool {
    return (reserved[v2_reserved_byte] & v2_reserved_mask) != 0;
}

pub fn serializeHandshake(info_hash: [20]u8, peer_id: [20]u8) [68]u8 {
    return serializeHandshakeV2(info_hash, peer_id, false);
}

/// Serialize a BitTorrent handshake with optional v2 (BEP 52) support flag.
/// When `is_v2` is true, sets the v2 capability bit in the reserved bytes.
pub fn serializeHandshakeV2(info_hash: [20]u8, peer_id: [20]u8, is_v2: bool) [68]u8 {
    var buffer: [68]u8 = undefined;
    buffer[0] = protocol_length;
    @memcpy(buffer[1 .. 1 + protocol_string.len], protocol_string);
    @memset(buffer[20..28], 0);
    // BEP 10: advertise extension protocol support
    buffer[20 + extensions.reserved_byte] |= extensions.reserved_mask;
    // BEP 52: advertise v2 protocol support
    if (is_v2) {
        buffer[20 + v2_reserved_byte] |= v2_reserved_mask;
    }
    @memcpy(buffer[28..48], info_hash[0..]);
    @memcpy(buffer[48..68], peer_id[0..]);
    return buffer;
}

pub fn writeHandshake(
    fd: posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,
) !void {
    var buffer = serializeHandshake(info_hash, peer_id);
    try sendAll(fd, &buffer);
}

pub fn readHandshake(fd: posix.fd_t) !Handshake {
    var length_buffer: [1]u8 = undefined;
    try recvExact(fd, &length_buffer);
    if (length_buffer[0] != protocol_length) {
        return error.InvalidHandshakeProtocol;
    }

    var buffer: [67]u8 = undefined;
    try recvExact(fd, &buffer);

    if (!std.mem.eql(u8, buffer[0..protocol_string.len], protocol_string)) {
        return error.InvalidHandshakeProtocol;
    }

    var reserved: [8]u8 = undefined;
    var info_hash: [20]u8 = undefined;
    var peer_id: [20]u8 = undefined;
    @memcpy(reserved[0..], buffer[19..27]);
    @memcpy(info_hash[0..], buffer[27..47]);
    @memcpy(peer_id[0..], buffer[47..67]);

    return .{
        .reserved = reserved,
        .info_hash = info_hash,
        .peer_id = peer_id,
    };
}

pub fn readMessageAlloc(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
) !InboundMessage {
    var length_buffer: [4]u8 = undefined;
    try recvExact(fd, &length_buffer);
    const length = std.mem.readInt(u32, &length_buffer, .big);
    if (length == 0) {
        return .keep_alive;
    }
    if (length > max_message_length) {
        return error.MessageTooLarge;
    }

    var id_buffer: [1]u8 = undefined;
    try recvExact(fd, &id_buffer);
    const id = id_buffer[0];
    const payload_length = length - 1;

    return switch (id) {
        0 => expectEmptyPayload(payload_length, .choke),
        1 => expectEmptyPayload(payload_length, .unchoke),
        2 => expectEmptyPayload(payload_length, .interested),
        3 => expectEmptyPayload(payload_length, .not_interested),
        4 => .{ .have = try readU32Payload(fd, payload_length) },
        5 => .{ .bitfield = try readAllocatedPayload(allocator, fd, payload_length) },
        6 => .{ .request = try readRequest(fd, payload_length) },
        7 => .{ .piece = try readPiece(allocator, fd, payload_length) },
        8 => .{ .cancel = try readRequest(fd, payload_length) },
        9 => .{ .port = try readU16Payload(fd, payload_length) },
        else => {
            try discardPayload(fd, payload_length);
            return error.UnsupportedPeerMessage;
        },
    };
}

pub fn freeMessage(allocator: std.mem.Allocator, message: InboundMessage) void {
    switch (message) {
        .bitfield => |bitfield| allocator.free(bitfield),
        .piece => |piece| allocator.free(piece.payload),
        else => {},
    }
}

pub const keepalive_bytes = [_]u8{ 0, 0, 0, 0 };

pub fn serializeHeader(id: u8, payload: []const u8) [5]u8 {
    const payload_with_id = std.math.cast(u32, payload.len + 1) orelse unreachable;
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], payload_with_id, .big);
    header[4] = id;
    return header;
}

pub fn serializeHave(piece_index: u32) [9]u8 {
    var buf: [9]u8 = undefined;
    const header = serializeHeader(4, buf[5..9]);
    @memcpy(buf[0..5], &header);
    std.mem.writeInt(u32, buf[5..9], piece_index, .big);
    return buf;
}

pub fn serializeRequest(request: Request) [17]u8 {
    var buf: [17]u8 = undefined;
    const header = serializeHeader(6, buf[5..17]);
    @memcpy(buf[0..5], &header);
    std.mem.writeInt(u32, buf[5..9], request.piece_index, .big);
    std.mem.writeInt(u32, buf[9..13], request.block_offset, .big);
    std.mem.writeInt(u32, buf[13..17], request.length, .big);
    return buf;
}

pub fn serializePieceHeader(piece_index: u32, block_offset: u32, block_len: usize) ![13]u8 {
    const payload_length = 1 + 8 + block_len;
    const frame_length = std.math.cast(u32, payload_length) orelse return error.MessageTooLarge;

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], frame_length, .big);
    header[4] = 7;
    std.mem.writeInt(u32, header[5..9], piece_index, .big);
    std.mem.writeInt(u32, header[9..13], block_offset, .big);
    return header;
}

pub fn writeKeepAlive(fd: posix.fd_t) !void {
    try sendAll(fd, &keepalive_bytes);
}

pub fn writeInterested(fd: posix.fd_t) !void {
    try writeMessageWithPayload(fd, 2, &.{});
}

pub fn writeNotInterested(fd: posix.fd_t) !void {
    try writeMessageWithPayload(fd, 3, &.{});
}

pub fn writeUnchoke(fd: posix.fd_t) !void {
    try writeMessageWithPayload(fd, 1, &.{});
}

pub fn writeBitfield(fd: posix.fd_t, bitfield: []const u8) !void {
    try writeMessageWithPayload(fd, 5, bitfield);
}

pub fn writeHave(fd: posix.fd_t, piece_index: u32) !void {
    var buf = serializeHave(piece_index);
    try sendAll(fd, &buf);
}

pub fn writeRequest(fd: posix.fd_t, request: Request) !void {
    var buf = serializeRequest(request);
    try sendAll(fd, &buf);
}

pub fn writePiece(
    fd: posix.fd_t,
    piece_index: u32,
    block_offset: u32,
    block: []const u8,
) !void {
    var header = try serializePieceHeader(piece_index, block_offset, block.len);
    try sendAll(fd, &header);
    try sendAll(fd, block);
}

fn expectEmptyPayload(payload_length: u32, message: InboundMessage) !InboundMessage {
    if (payload_length != 0) {
        return error.InvalidMessageLength;
    }
    return message;
}

fn readRequest(fd: posix.fd_t, payload_length: u32) !Request {
    if (payload_length != 12) {
        return error.InvalidMessageLength;
    }

    var payload: [12]u8 = undefined;
    try recvExact(fd, &payload);
    return .{
        .piece_index = std.mem.readInt(u32, payload[0..4], .big),
        .block_offset = std.mem.readInt(u32, payload[4..8], .big),
        .length = std.mem.readInt(u32, payload[8..12], .big),
    };
}

fn readPiece(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_length: u32,
) !Piece {
    if (payload_length < 8) {
        return error.InvalidMessageLength;
    }

    const payload = try readAllocatedPayload(allocator, fd, payload_length);
    errdefer allocator.free(payload);

    return .{
        .piece_index = std.mem.readInt(u32, payload[0..4], .big),
        .block_offset = std.mem.readInt(u32, payload[4..8], .big),
        .block = payload[8..],
        .payload = payload,
    };
}

fn readU32Payload(fd: posix.fd_t, payload_length: u32) !u32 {
    if (payload_length != 4) {
        return error.InvalidMessageLength;
    }

    var payload: [4]u8 = undefined;
    try recvExact(fd, &payload);
    return std.mem.readInt(u32, &payload, .big);
}

fn readU16Payload(fd: posix.fd_t, payload_length: u32) !u16 {
    if (payload_length != 2) {
        return error.InvalidMessageLength;
    }

    var payload: [2]u8 = undefined;
    try recvExact(fd, &payload);
    return std.mem.readInt(u16, &payload, .big);
}

fn readAllocatedPayload(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    payload_length: u32,
) ![]u8 {
    const payload = try allocator.alloc(u8, payload_length);
    errdefer allocator.free(payload);
    try recvExact(fd, payload);
    return payload;
}

fn discardPayload(fd: posix.fd_t, payload_length: u32) !void {
    var remaining = payload_length;
    var buffer: [256]u8 = undefined;

    while (remaining > 0) {
        const chunk_length = @min(buffer.len, remaining);
        try recvExact(fd, buffer[0..chunk_length]);
        remaining -= @intCast(chunk_length);
    }
}

fn writeMessageWithPayload(
    fd: posix.fd_t,
    id: u8,
    payload: []const u8,
) !void {
    var header = serializeHeader(id, payload);
    try sendAll(fd, &header);
    try sendAll(fd, payload);
}

// ── Tests ────────────────────────────────────────────────────

test "handshake serialization roundtrip" {
    const info_hash = [_]u8{0xAA} ** 20;
    const peer_id = [_]u8{0xBB} ** 20;
    const buf = serializeHandshake(info_hash, peer_id);

    // byte 0: protocol string length
    try std.testing.expectEqual(@as(u8, 19), buf[0]);
    // bytes 1..20: protocol string
    try std.testing.expectEqualStrings("BitTorrent protocol", buf[1..20]);
    // bytes 20..28: reserved (BEP 10 extension bit set at byte 5)
    var expected_reserved = [_]u8{0} ** 8;
    expected_reserved[extensions.reserved_byte] = extensions.reserved_mask;
    try std.testing.expectEqualSlices(u8, &expected_reserved, buf[20..28]);
    // bytes 28..48: info_hash
    try std.testing.expectEqualSlices(u8, &info_hash, buf[28..48]);
    // bytes 48..68: peer_id
    try std.testing.expectEqualSlices(u8, &peer_id, buf[48..68]);
    // total length
    try std.testing.expectEqual(@as(usize, 68), buf.len);
}

test "handshake preserves distinct info_hash and peer_id" {
    var info_hash: [20]u8 = undefined;
    var peer_id: [20]u8 = undefined;
    for (0..20) |i| {
        info_hash[i] = @intCast(i);
        peer_id[i] = @intCast(i + 100);
    }
    const buf = serializeHandshake(info_hash, peer_id);
    try std.testing.expectEqualSlices(u8, &info_hash, buf[28..48]);
    try std.testing.expectEqualSlices(u8, &peer_id, buf[48..68]);
}

test "keepalive is four zero bytes" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &keepalive_bytes);
}

test "serializeHeader choke id=0" {
    const header = serializeHeader(0, &.{});
    // length = 1 (id only, no payload), big-endian
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0 }, &header);
}

test "serializeHeader unchoke id=1" {
    const header = serializeHeader(1, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 1 }, &header);
}

test "serializeHeader interested id=2" {
    const header = serializeHeader(2, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 2 }, &header);
}

test "serializeHeader not_interested id=3" {
    const header = serializeHeader(3, &.{});
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 3 }, &header);
}

test "serializeHeader bitfield id=5 with payload" {
    const bits = [_]u8{ 0xFF, 0x80 };
    const header = serializeHeader(5, &bits);
    // length = 1 (id) + 2 (payload) = 3
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 3, 5 }, &header);
}

test "serializeHave encodes piece_index big-endian" {
    const buf = serializeHave(42);
    // length=5 (1 id + 4 index), id=4, index=42
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 5, 4, 0, 0, 0, 42 }, &buf);
}

test "serializeHave with large piece_index" {
    const buf = serializeHave(0x01020304);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 5, 4, 0x01, 0x02, 0x03, 0x04 }, &buf);
}

test "serializeHave piece_index zero" {
    const buf = serializeHave(0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 5, 4, 0, 0, 0, 0 }, &buf);
}

test "serializeRequest encodes three u32 fields" {
    const buf = serializeRequest(.{
        .piece_index = 1,
        .block_offset = 16384,
        .length = 16384,
    });
    // length = 1 + 12 = 13
    var expected: [17]u8 = undefined;
    std.mem.writeInt(u32, expected[0..4], 13, .big);
    expected[4] = 6;
    std.mem.writeInt(u32, expected[5..9], 1, .big);
    std.mem.writeInt(u32, expected[9..13], 16384, .big);
    std.mem.writeInt(u32, expected[13..17], 16384, .big);
    try std.testing.expectEqualSlices(u8, &expected, &buf);
}

test "serializeRequest with zero values" {
    const buf = serializeRequest(.{
        .piece_index = 0,
        .block_offset = 0,
        .length = 0,
    });
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0, 0, 13, 6,
        0, 0, 0, 0,  0,
        0, 0, 0, 0,  0,
        0, 0,
    }, &buf);
}

test "serializePieceHeader encodes frame correctly" {
    const header = try serializePieceHeader(7, 0, 1024);
    // frame_length = 1 (id) + 8 (index+offset) + 1024 (block) = 1033
    var expected: [13]u8 = undefined;
    std.mem.writeInt(u32, expected[0..4], 1033, .big);
    expected[4] = 7;
    std.mem.writeInt(u32, expected[5..9], 7, .big);
    std.mem.writeInt(u32, expected[9..13], 0, .big);
    try std.testing.expectEqualSlices(u8, &expected, &header);
}

test "serializePieceHeader with standard block size" {
    // standard 16 KiB block
    const header = try serializePieceHeader(0, 0, 16384);
    const frame_len = std.mem.readInt(u32, header[0..4], .big);
    // 1 + 8 + 16384 = 16393
    try std.testing.expectEqual(@as(u32, 16393), frame_len);
    try std.testing.expectEqual(@as(u8, 7), header[4]);
}

test "serializePieceHeader with zero-length block" {
    const header = try serializePieceHeader(0, 0, 0);
    const frame_len = std.mem.readInt(u32, header[0..4], .big);
    // 1 + 8 + 0 = 9
    try std.testing.expectEqual(@as(u32, 9), frame_len);
}

test "expectEmptyPayload accepts zero length" {
    const msg = try expectEmptyPayload(0, .choke);
    try std.testing.expectEqual(InboundMessage.choke, msg);
}

test "expectEmptyPayload rejects nonzero length" {
    try std.testing.expectError(error.InvalidMessageLength, expectEmptyPayload(1, .choke));
    try std.testing.expectError(error.InvalidMessageLength, expectEmptyPayload(100, .unchoke));
}

test "protocol constants are correct" {
    try std.testing.expectEqual(@as(u8, 19), protocol_length);
    try std.testing.expectEqual(@as(usize, 19), protocol_string.len);
    try std.testing.expectEqualStrings("BitTorrent protocol", protocol_string);
}

test "max_message_length is 1 MiB" {
    try std.testing.expectEqual(@as(u32, 1048576), max_message_length);
}

// ── BEP 52 v2 handshake tests ────────────────────────────

test "serializeHandshakeV2 sets v2 reserved bit when is_v2 is true" {
    const info_hash = [_]u8{0xAA} ** 20;
    const peer_id = [_]u8{0xBB} ** 20;
    const buf = serializeHandshakeV2(info_hash, peer_id, true);

    // BEP 10 extension bit should be set
    var expected_reserved = [_]u8{0} ** 8;
    expected_reserved[extensions.reserved_byte] = extensions.reserved_mask;
    // BEP 52 v2 bit should be set
    expected_reserved[v2_reserved_byte] |= v2_reserved_mask;
    try std.testing.expectEqualSlices(u8, &expected_reserved, buf[20..28]);

    // info_hash and peer_id should be correct
    try std.testing.expectEqualSlices(u8, &info_hash, buf[28..48]);
    try std.testing.expectEqualSlices(u8, &peer_id, buf[48..68]);
}

test "serializeHandshakeV2 does not set v2 bit when is_v2 is false" {
    const info_hash = [_]u8{0xCC} ** 20;
    const peer_id = [_]u8{0xDD} ** 20;
    const buf = serializeHandshakeV2(info_hash, peer_id, false);

    // BEP 52 v2 bit should NOT be set
    try std.testing.expect((buf[20 + v2_reserved_byte] & v2_reserved_mask) == 0);

    // BEP 10 extension bit should still be set
    try std.testing.expect((buf[20 + extensions.reserved_byte] & extensions.reserved_mask) != 0);
}

test "supportsV2 detects v2 capability from reserved bytes" {
    var reserved = [_]u8{0} ** 8;
    try std.testing.expect(!supportsV2(reserved));

    reserved[v2_reserved_byte] = v2_reserved_mask;
    try std.testing.expect(supportsV2(reserved));

    // Other bits in the same byte should not interfere
    reserved[v2_reserved_byte] = 0xFF;
    try std.testing.expect(supportsV2(reserved));

    reserved[v2_reserved_byte] = 0x0F; // all bits except v2
    try std.testing.expect(!supportsV2(reserved));
}

test "serializeHandshake is compatible with serializeHandshakeV2 false" {
    const info_hash = [_]u8{0x11} ** 20;
    const peer_id = [_]u8{0x22} ** 20;
    const v1_buf = serializeHandshake(info_hash, peer_id);
    const v2_buf = serializeHandshakeV2(info_hash, peer_id, false);
    try std.testing.expectEqualSlices(u8, &v1_buf, &v2_buf);
}

test "v2 reserved byte and mask are correct per BEP 52" {
    // BEP 52 specifies bit 0x10 in reserved byte 7
    try std.testing.expectEqual(@as(usize, 7), v2_reserved_byte);
    try std.testing.expectEqual(@as(u8, 0x10), v2_reserved_mask);
}

const std = @import("std");
const posix = std.posix;
const Ring = @import("../io/ring.zig").Ring;

pub const protocol_string = "BitTorrent protocol";
pub const protocol_length: u8 = protocol_string.len;
pub const max_message_length: u32 = 1 * 1024 * 1024;

pub const Request = struct {
    piece_index: u32,
    block_offset: u32,
    length: u32,
};

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

pub fn writeHandshake(
    ring: *Ring,
    fd: posix.fd_t,
    info_hash: [20]u8,
    peer_id: [20]u8,
) !void {
    var buffer: [68]u8 = undefined;
    buffer[0] = protocol_length;
    @memcpy(buffer[1 .. 1 + protocol_string.len], protocol_string);
    @memset(buffer[20..28], 0);
    @memcpy(buffer[28..48], info_hash[0..]);
    @memcpy(buffer[48..68], peer_id[0..]);
    try ring.send_all(fd, &buffer);
}

pub fn readHandshake(ring: *Ring, fd: posix.fd_t) !Handshake {
    var length_buffer: [1]u8 = undefined;
    try ring.recv_exact(fd, &length_buffer);
    if (length_buffer[0] != protocol_length) {
        return error.InvalidHandshakeProtocol;
    }

    var buffer: [67]u8 = undefined;
    try ring.recv_exact(fd, &buffer);

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
    ring: *Ring,
    fd: posix.fd_t,
) !InboundMessage {
    var length_buffer: [4]u8 = undefined;
    try ring.recv_exact(fd, &length_buffer);
    const length = std.mem.readInt(u32, &length_buffer, .big);
    if (length == 0) {
        return .keep_alive;
    }
    if (length > max_message_length) {
        return error.MessageTooLarge;
    }

    var id_buffer: [1]u8 = undefined;
    try ring.recv_exact(fd, &id_buffer);
    const id = id_buffer[0];
    const payload_length = length - 1;

    return switch (id) {
        0 => expectEmptyPayload(payload_length, .choke),
        1 => expectEmptyPayload(payload_length, .unchoke),
        2 => expectEmptyPayload(payload_length, .interested),
        3 => expectEmptyPayload(payload_length, .not_interested),
        4 => .{ .have = try readU32Payload(ring, fd, payload_length) },
        5 => .{ .bitfield = try readAllocatedPayload(allocator, ring, fd, payload_length) },
        6 => .{ .request = try readRequest(ring, fd, payload_length) },
        7 => .{ .piece = try readPiece(allocator, ring, fd, payload_length) },
        8 => .{ .cancel = try readRequest(ring, fd, payload_length) },
        9 => .{ .port = try readU16Payload(ring, fd, payload_length) },
        else => {
            try discardPayload(ring, fd, payload_length);
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

pub fn writeKeepAlive(ring: *Ring, fd: posix.fd_t) !void {
    const header = [_]u8{ 0, 0, 0, 0 };
    try ring.send_all(fd, &header);
}

pub fn writeInterested(ring: *Ring, fd: posix.fd_t) !void {
    try writeMessageWithPayload(ring, fd, 2, &.{});
}

pub fn writeNotInterested(ring: *Ring, fd: posix.fd_t) !void {
    try writeMessageWithPayload(ring, fd, 3, &.{});
}

pub fn writeUnchoke(ring: *Ring, fd: posix.fd_t) !void {
    try writeMessageWithPayload(ring, fd, 1, &.{});
}

pub fn writeBitfield(ring: *Ring, fd: posix.fd_t, bitfield: []const u8) !void {
    try writeMessageWithPayload(ring, fd, 5, bitfield);
}

pub fn writeHave(ring: *Ring, fd: posix.fd_t, piece_index: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, piece_index, .big);
    try writeMessageWithPayload(ring, fd, 4, &payload);
}

pub fn writeRequest(ring: *Ring, fd: posix.fd_t, request: Request) !void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], request.piece_index, .big);
    std.mem.writeInt(u32, payload[4..8], request.block_offset, .big);
    std.mem.writeInt(u32, payload[8..12], request.length, .big);
    try writeMessageWithPayload(ring, fd, 6, &payload);
}

pub fn writePiece(
    ring: *Ring,
    fd: posix.fd_t,
    piece_index: u32,
    block_offset: u32,
    block: []const u8,
) !void {
    const payload_length = 1 + 8 + block.len;
    const frame_length = std.math.cast(u32, payload_length) orelse return error.MessageTooLarge;

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], frame_length, .big);
    header[4] = 7;
    std.mem.writeInt(u32, header[5..9], piece_index, .big);
    std.mem.writeInt(u32, header[9..13], block_offset, .big);

    try ring.send_all(fd, &header);
    try ring.send_all(fd, block);
}

fn expectEmptyPayload(payload_length: u32, message: InboundMessage) !InboundMessage {
    if (payload_length != 0) {
        return error.InvalidMessageLength;
    }
    return message;
}

fn readRequest(ring: *Ring, fd: posix.fd_t, payload_length: u32) !Request {
    if (payload_length != 12) {
        return error.InvalidMessageLength;
    }

    var payload: [12]u8 = undefined;
    try ring.recv_exact(fd, &payload);
    return .{
        .piece_index = std.mem.readInt(u32, payload[0..4], .big),
        .block_offset = std.mem.readInt(u32, payload[4..8], .big),
        .length = std.mem.readInt(u32, payload[8..12], .big),
    };
}

fn readPiece(
    allocator: std.mem.Allocator,
    ring: *Ring,
    fd: posix.fd_t,
    payload_length: u32,
) !Piece {
    if (payload_length < 8) {
        return error.InvalidMessageLength;
    }

    const payload = try readAllocatedPayload(allocator, ring, fd, payload_length);
    errdefer allocator.free(payload);

    return .{
        .piece_index = std.mem.readInt(u32, payload[0..4], .big),
        .block_offset = std.mem.readInt(u32, payload[4..8], .big),
        .block = payload[8..],
        .payload = payload,
    };
}

fn readU32Payload(ring: *Ring, fd: posix.fd_t, payload_length: u32) !u32 {
    if (payload_length != 4) {
        return error.InvalidMessageLength;
    }

    var payload: [4]u8 = undefined;
    try ring.recv_exact(fd, &payload);
    return std.mem.readInt(u32, &payload, .big);
}

fn readU16Payload(ring: *Ring, fd: posix.fd_t, payload_length: u32) !u16 {
    if (payload_length != 2) {
        return error.InvalidMessageLength;
    }

    var payload: [2]u8 = undefined;
    try ring.recv_exact(fd, &payload);
    return std.mem.readInt(u16, &payload, .big);
}

fn readAllocatedPayload(
    allocator: std.mem.Allocator,
    ring: *Ring,
    fd: posix.fd_t,
    payload_length: u32,
) ![]u8 {
    const payload = try allocator.alloc(u8, payload_length);
    errdefer allocator.free(payload);
    try ring.recv_exact(fd, payload);
    return payload;
}

fn discardPayload(ring: *Ring, fd: posix.fd_t, payload_length: u32) !void {
    var remaining = payload_length;
    var buffer: [256]u8 = undefined;

    while (remaining > 0) {
        const chunk_length = @min(buffer.len, remaining);
        try ring.recv_exact(fd, buffer[0..chunk_length]);
        remaining -= @intCast(chunk_length);
    }
}

fn writeMessageWithPayload(
    ring: *Ring,
    fd: posix.fd_t,
    id: u8,
    payload: []const u8,
) !void {
    const payload_with_id = std.math.cast(u32, payload.len + 1) orelse return error.MessageTooLarge;
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], payload_with_id, .big);
    header[4] = id;

    try ring.send_all(fd, &header);
    try ring.send_all(fd, payload);
}

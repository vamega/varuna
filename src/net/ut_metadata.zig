const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");
const Sha1 = @import("../crypto/sha1.zig");

/// BEP 9: Extension for Peers to Send Metadata Files (ut_metadata).
///
/// Metadata is transferred in 16 KiB pieces. Each piece is requested
/// individually and the complete metadata is verified against the
/// info-hash before use.

// ── Constants ────────────────────────────────────────────────

/// Size of each metadata piece (16 KiB), per BEP 9.
pub const metadata_piece_size: u32 = 16384;

/// Maximum metadata size we will accept (10 MiB).
/// This guards against malicious peers advertising absurd sizes.
pub const max_metadata_size: u32 = 10 * 1024 * 1024;

/// Message types defined by BEP 9.
pub const MsgType = enum(u8) {
    request = 0,
    data = 1,
    reject = 2,
};

// ── Wire message encoding ───────────────────────────────────

/// Encode a ut_metadata request message.
/// Returns the bencoded payload (without the extension message framing).
pub fn encodeRequest(allocator: std.mem.Allocator, piece: u32) ![]u8 {
    var entries = try allocator.alloc(bencode.Value.Entry, 2);
    defer allocator.free(entries);

    // Keys must be sorted: "msg_type" < "piece"
    entries[0] = .{ .key = "msg_type", .value = .{ .integer = @intFromEnum(MsgType.request) } };
    entries[1] = .{ .key = "piece", .value = .{ .integer = @as(i64, piece) } };

    return bencode_encode.encode(allocator, .{ .dict = entries });
}

/// Encode a ut_metadata data message (header only, without the piece data appended).
/// The caller must append the raw piece data after this bencoded header.
pub fn encodeData(allocator: std.mem.Allocator, piece: u32, total_size: u32) ![]u8 {
    var entries = try allocator.alloc(bencode.Value.Entry, 3);
    defer allocator.free(entries);

    // Keys sorted: "msg_type" < "piece" < "total_size"
    entries[0] = .{ .key = "msg_type", .value = .{ .integer = @intFromEnum(MsgType.data) } };
    entries[1] = .{ .key = "piece", .value = .{ .integer = @as(i64, piece) } };
    entries[2] = .{ .key = "total_size", .value = .{ .integer = @as(i64, total_size) } };

    return bencode_encode.encode(allocator, .{ .dict = entries });
}

/// Encode a ut_metadata reject message.
pub fn encodeReject(allocator: std.mem.Allocator, piece: u32) ![]u8 {
    var entries = try allocator.alloc(bencode.Value.Entry, 2);
    defer allocator.free(entries);

    entries[0] = .{ .key = "msg_type", .value = .{ .integer = @intFromEnum(MsgType.reject) } };
    entries[1] = .{ .key = "piece", .value = .{ .integer = @as(i64, piece) } };

    return bencode_encode.encode(allocator, .{ .dict = entries });
}

// ── Wire message decoding ───────────────────────────────────

/// Decoded ut_metadata message header.
pub const MetadataMessage = struct {
    msg_type: MsgType,
    piece: u32,
    total_size: u32 = 0, // only present in data messages
    /// For data messages, offset into the original payload where the
    /// raw piece data begins (after the bencoded header).
    data_offset: usize = 0,
};

pub const DecodeError = error{
    InvalidMessage,
    UnexpectedBencodeType,
    InvalidMsgType,
    MissingPieceField,
    OutOfMemory,
    // Bencode parse errors
    TrailingData,
    UnexpectedEndOfStream,
    InvalidPrefix,
    InvalidInteger,
    InvalidByteStringLength,
    InvalidCharacter,
    UnexpectedByte,
    Overflow,
};

/// Decode a ut_metadata message from the extension payload.
///
/// For data messages, the payload contains a bencoded dictionary followed
/// by raw piece data. We find the dictionary boundary by parsing and
/// measuring the encoded size, then return the data_offset.
pub fn decode(allocator: std.mem.Allocator, payload: []const u8) DecodeError!MetadataMessage {
    _ = allocator;
    // BEP 9 data messages have a bencoded dict followed by raw bytes.
    // We need to find where the dict ends. Parse it, and the dict
    // boundary is determined by the bencoded structure.
    const dict_end = findDictEnd(payload) orelse return error.InvalidMessage;
    var parser = Parser{ .input = payload[0..dict_end] };
    try parser.expectByte('d');

    var msg_type: ?MsgType = null;
    var piece: ?u32 = null;
    var total_size: u32 = 0;

    while (true) {
        const next = parser.peek() orelse return error.InvalidMessage;
        if (next == 'e') {
            parser.index += 1;
            break;
        }

        const key = try parser.parseBytes();
        if (std.mem.eql(u8, key, "msg_type")) {
            const value = try parser.parseInteger();
            if (value < 0 or value > 2) return error.InvalidMsgType;
            msg_type = @enumFromInt(@as(u8, @intCast(value)));
        } else if (std.mem.eql(u8, key, "piece")) {
            const value = try parser.parseInteger();
            if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidMessage;
            piece = @intCast(value);
        } else if (std.mem.eql(u8, key, "total_size")) {
            const value = try parser.parseInteger();
            if (value > 0 and value <= std.math.maxInt(u32)) {
                total_size = @intCast(value);
            }
        } else {
            try parser.skipValue();
        }
    }

    if (!parser.isAtEnd()) return error.InvalidMessage;

    var result = MetadataMessage{
        .msg_type = msg_type orelse return error.InvalidMessage,
        .piece = piece orelse return error.MissingPieceField,
    };

    if (result.msg_type == .data) {
        result.total_size = total_size;
        result.data_offset = dict_end;
    }

    return result;
}

/// Find the end of a bencoded dictionary at the start of `data`.
/// Returns null if the data does not start with a valid dict.
fn findDictEnd(data: []const u8) ?usize {
    if (data.len == 0 or data[0] != 'd') return null;
    var idx: usize = 1;

    while (idx < data.len) {
        if (data[idx] == 'e') return idx + 1;

        // Skip key (byte string)
        idx = skipByteString(data, idx) orelse return null;
        // Skip value
        idx = skipBencodeValue(data, idx) orelse return null;
    }
    return null;
}

fn skipBencodeValue(data: []const u8, start: usize) ?usize {
    if (start >= data.len) return null;
    return switch (data[start]) {
        'i' => {
            // Integer: i<digits>e
            var idx = start + 1;
            while (idx < data.len) : (idx += 1) {
                if (data[idx] == 'e') return idx + 1;
            }
            return null;
        },
        'l' => {
            // List
            var idx = start + 1;
            while (idx < data.len) {
                if (data[idx] == 'e') return idx + 1;
                idx = skipBencodeValue(data, idx) orelse return null;
            }
            return null;
        },
        'd' => {
            // Dict
            var idx = start + 1;
            while (idx < data.len) {
                if (data[idx] == 'e') return idx + 1;
                idx = skipByteString(data, idx) orelse return null;
                idx = skipBencodeValue(data, idx) orelse return null;
            }
            return null;
        },
        '0'...'9' => skipByteString(data, start),
        else => null,
    };
}

fn skipByteString(data: []const u8, start: usize) ?usize {
    var idx = start;
    while (idx < data.len and data[idx] >= '0' and data[idx] <= '9') : (idx += 1) {}
    if (idx >= data.len or data[idx] != ':') return null;
    const len_str = data[start..idx];
    const length = std.fmt.parseUnsigned(usize, len_str, 10) catch return null;
    idx += 1;
    const end = idx + length;
    if (end > data.len) return null;
    return end;
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

    fn expectByte(self: *Parser, byte: u8) DecodeError!void {
        if (self.peek() != byte) return error.InvalidMessage;
        self.index += 1;
    }

    fn parseBytes(self: *Parser) DecodeError![]const u8 {
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == ':') break;
            if (!std.ascii.isDigit(byte)) return error.InvalidMessage;
            self.index += 1;
        }
        if (self.peek() != ':') return error.InvalidMessage;

        const len_slice = self.input[start..self.index];
        if (len_slice.len == 0) return error.InvalidMessage;

        self.index += 1;
        const len = std.fmt.parseUnsigned(usize, len_slice, 10) catch return error.InvalidMessage;
        const end = self.index + len;
        if (end > self.input.len) return error.InvalidMessage;

        defer self.index = end;
        return self.input[self.index..end];
    }

    fn parseInteger(self: *Parser) DecodeError!i64 {
        try self.expectByte('i');
        const start = self.index;
        while (self.peek()) |byte| {
            if (byte == 'e') break;
            self.index += 1;
        }
        if (self.peek() != 'e') return error.InvalidMessage;

        const digits = self.input[start..self.index];
        if (digits.len == 0) return error.InvalidMessage;

        self.index += 1;
        return std.fmt.parseInt(i64, digits, 10) catch error.InvalidMessage;
    }

    fn skipValue(self: *Parser) DecodeError!void {
        const next = self.peek() orelse return error.InvalidMessage;
        switch (next) {
            'i' => _ = try self.parseInteger(),
            'l' => {
                self.index += 1;
                while (true) {
                    const item = self.peek() orelse return error.InvalidMessage;
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
                    const item = self.peek() orelse return error.InvalidMessage;
                    if (item == 'e') {
                        self.index += 1;
                        return;
                    }
                    _ = try self.parseBytes();
                    try self.skipValue();
                }
            },
            '0'...'9' => _ = try self.parseBytes(),
            else => return error.InvalidMessage,
        }
    }
};

// ── Metadata assembler ──────────────────────────────────────

/// Collects metadata pieces, verifies the assembled result against
/// an expected info-hash, and produces the raw info dictionary bytes.
pub const MetadataAssembler = struct {
    allocator: std.mem.Allocator,
    expected_hash: [20]u8,
    total_size: u32 = 0,
    piece_count: u32 = 0,
    buffer: ?[]u8 = null,
    received: ?[]bool = null,
    pieces_received: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, expected_hash: [20]u8) MetadataAssembler {
        return .{
            .allocator = allocator,
            .expected_hash = expected_hash,
        };
    }

    pub fn deinit(self: *MetadataAssembler) void {
        if (self.buffer) |buf| self.allocator.free(buf);
        if (self.received) |r| self.allocator.free(r);
        self.* = undefined;
    }

    /// Set the total metadata size (learned from peer's extension handshake
    /// or from a data message). Returns error if the size is invalid or
    /// was already set to a different value.
    pub fn setSize(self: *MetadataAssembler, total_size: u32) !void {
        if (total_size == 0 or total_size > max_metadata_size) return error.InvalidMetadataSize;
        if (self.total_size != 0) {
            // Already set -- must be consistent
            if (self.total_size != total_size) return error.MetadataSizeMismatch;
            return;
        }

        self.total_size = total_size;
        self.piece_count = (total_size + metadata_piece_size - 1) / metadata_piece_size;
        self.buffer = try self.allocator.alloc(u8, total_size);
        self.received = try self.allocator.alloc(bool, self.piece_count);
        @memset(self.received.?, false);
    }

    /// How many pieces do we need?
    pub fn totalPieces(self: *const MetadataAssembler) u32 {
        return self.piece_count;
    }

    /// Is the metadata completely received?
    pub fn isComplete(self: *const MetadataAssembler) bool {
        return self.total_size != 0 and self.pieces_received == self.piece_count;
    }

    /// Process a received data piece. Returns true if the metadata is
    /// now complete.
    pub fn addPiece(self: *MetadataAssembler, piece: u32, data: []const u8) !bool {
        if (self.total_size == 0) return error.SizeNotSet;
        if (piece >= self.piece_count) return error.InvalidPieceIndex;

        const received = self.received orelse return error.SizeNotSet;
        if (received[piece]) return false; // duplicate, ignore

        const buf = self.buffer orelse return error.SizeNotSet;

        // Validate piece data length
        const offset = @as(usize, piece) * metadata_piece_size;
        const expected_len = if (piece == self.piece_count - 1)
            self.total_size - @as(u32, @intCast(offset))
        else
            metadata_piece_size;

        if (data.len != expected_len) return error.InvalidPieceDataLength;

        @memcpy(buf[offset .. offset + data.len], data);
        received[piece] = true;
        self.pieces_received += 1;

        return self.isComplete();
    }

    /// Return the index of the next unreceived piece, or null if all received.
    pub fn nextNeeded(self: *const MetadataAssembler) ?u32 {
        const received = self.received orelse return null;
        for (received, 0..) |got, i| {
            if (!got) return @intCast(i);
        }
        return null;
    }

    /// Verify the assembled metadata against the expected info-hash.
    /// Returns the raw info dictionary bytes on success.
    pub fn verify(self: *const MetadataAssembler) ![]const u8 {
        if (!self.isComplete()) return error.MetadataIncomplete;

        const buf = self.buffer orelse return error.MetadataIncomplete;

        var digest: [20]u8 = undefined;
        Sha1.hash(buf[0..self.total_size], &digest, .{});

        if (!std.mem.eql(u8, &digest, &self.expected_hash)) {
            return error.InfoHashMismatch;
        }

        return buf[0..self.total_size];
    }

    /// Reset the assembler to try again (e.g., after a hash mismatch).
    pub fn reset(self: *MetadataAssembler) void {
        if (self.received) |r| @memset(r, false);
        self.pieces_received = 0;
    }
};

// ── Tests ────────────────────────────────────────────────

test "encode and decode request message" {
    const payload = try encodeRequest(std.testing.allocator, 3);
    defer std.testing.allocator.free(payload);

    const msg = try decode(std.testing.allocator, payload);
    try std.testing.expectEqual(MsgType.request, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 3), msg.piece);
}

test "encode and decode reject message" {
    const payload = try encodeReject(std.testing.allocator, 5);
    defer std.testing.allocator.free(payload);

    const msg = try decode(std.testing.allocator, payload);
    try std.testing.expectEqual(MsgType.reject, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 5), msg.piece);
}

test "encode and decode data message with trailing data" {
    const header = try encodeData(std.testing.allocator, 0, 100);
    defer std.testing.allocator.free(header);

    // Simulate wire format: header + raw piece data
    const piece_data = "hello world metadata piece";
    var full = std.ArrayList(u8).empty;
    defer full.deinit(std.testing.allocator);
    try full.appendSlice(std.testing.allocator, header);
    try full.appendSlice(std.testing.allocator, piece_data);

    const msg = try decode(std.testing.allocator, full.items);
    try std.testing.expectEqual(MsgType.data, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 0), msg.piece);
    try std.testing.expectEqual(@as(u32, 100), msg.total_size);
    try std.testing.expectEqualStrings(piece_data, full.items[msg.data_offset..]);
}

test "metadata assembler: single piece torrent" {
    // Create a known info dict and compute its hash
    const info_dict = "d4:name8:test.bin6:lengthi5e12:piece lengthi16384e6:pieces20:aabbccddeeff00112233e";
    var expected_hash: [20]u8 = undefined;
    Sha1.hash(info_dict, &expected_hash, .{});

    var assembler = MetadataAssembler.init(std.testing.allocator, expected_hash);
    defer assembler.deinit();

    try assembler.setSize(@intCast(info_dict.len));
    try std.testing.expectEqual(@as(u32, 1), assembler.totalPieces());
    try std.testing.expect(!assembler.isComplete());

    const complete = try assembler.addPiece(0, info_dict);
    try std.testing.expect(complete);
    try std.testing.expect(assembler.isComplete());

    // Verify should succeed
    const verified = try assembler.verify();
    try std.testing.expectEqualStrings(info_dict, verified);
}

test "metadata assembler: hash mismatch" {
    const wrong_hash = [_]u8{0xFF} ** 20;
    var assembler = MetadataAssembler.init(std.testing.allocator, wrong_hash);
    defer assembler.deinit();

    const data = "d4:name4:teste";
    try assembler.setSize(@intCast(data.len));
    _ = try assembler.addPiece(0, data);

    try std.testing.expectError(error.InfoHashMismatch, assembler.verify());
}

test "metadata assembler: multi-piece assembly" {
    // Create data larger than one piece (16 KiB)
    const size: u32 = metadata_piece_size + 100;
    const data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');

    var expected_hash: [20]u8 = undefined;
    Sha1.hash(data, &expected_hash, .{});

    var assembler = MetadataAssembler.init(std.testing.allocator, expected_hash);
    defer assembler.deinit();

    try assembler.setSize(size);
    try std.testing.expectEqual(@as(u32, 2), assembler.totalPieces());

    // Add first piece
    const complete1 = try assembler.addPiece(0, data[0..metadata_piece_size]);
    try std.testing.expect(!complete1);
    try std.testing.expectEqual(@as(u32, 1), assembler.nextNeeded().?);

    // Add second piece
    const complete2 = try assembler.addPiece(1, data[metadata_piece_size..size]);
    try std.testing.expect(complete2);

    const verified = try assembler.verify();
    try std.testing.expectEqual(@as(usize, size), verified.len);
}

test "metadata assembler: duplicate piece ignored" {
    const data = "d4:name4:teste";
    var hash: [20]u8 = undefined;
    Sha1.hash(data, &hash, .{});

    var assembler = MetadataAssembler.init(std.testing.allocator, hash);
    defer assembler.deinit();

    try assembler.setSize(@intCast(data.len));
    const first = try assembler.addPiece(0, data);
    try std.testing.expect(first);

    // Duplicate should return false (not error)
    const dup = try assembler.addPiece(0, data);
    try std.testing.expect(!dup);
}

test "metadata assembler: reject oversized metadata" {
    var assembler = MetadataAssembler.init(std.testing.allocator, [_]u8{0} ** 20);
    defer assembler.deinit();

    try std.testing.expectError(error.InvalidMetadataSize, assembler.setSize(max_metadata_size + 1));
}

test "metadata assembler: reject zero size" {
    var assembler = MetadataAssembler.init(std.testing.allocator, [_]u8{0} ** 20);
    defer assembler.deinit();

    try std.testing.expectError(error.InvalidMetadataSize, assembler.setSize(0));
}

test "metadata assembler: reset and retry" {
    const data = "d4:name4:teste";
    var hash: [20]u8 = undefined;
    Sha1.hash(data, &hash, .{});

    var assembler = MetadataAssembler.init(std.testing.allocator, hash);
    defer assembler.deinit();

    try assembler.setSize(@intCast(data.len));
    _ = try assembler.addPiece(0, data);
    try std.testing.expect(assembler.isComplete());

    assembler.reset();
    try std.testing.expect(!assembler.isComplete());
    try std.testing.expectEqual(@as(u32, 0), assembler.nextNeeded().?);

    // Re-add
    _ = try assembler.addPiece(0, data);
    try std.testing.expect(assembler.isComplete());
}

test "decode rejects invalid msg_type" {
    const payload = "d8:msg_typei99e5:piecei0ee";
    try std.testing.expectError(error.InvalidMsgType, decode(std.testing.allocator, payload));
}

test "decode rejects missing piece field" {
    const payload = "d8:msg_typei0ee";
    try std.testing.expectError(error.MissingPieceField, decode(std.testing.allocator, payload));
}

test "findDictEnd basic cases" {
    try std.testing.expectEqual(@as(?usize, 2), findDictEnd("de"));
    try std.testing.expectEqual(@as(?usize, 12), findDictEnd("d1:ai1ee"));
    try std.testing.expect(findDictEnd("") == null);
    try std.testing.expect(findDictEnd("le") == null);

    // Dict followed by extra data (simulates data message)
    const input = "d8:msg_typei1e5:piecei0e10:total_sizei100eeHELLO";
    const end = findDictEnd(input);
    try std.testing.expect(end != null);
    try std.testing.expectEqualStrings("HELLO", input[end.?..]);
}

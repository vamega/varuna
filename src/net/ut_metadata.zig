const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");
const Sha1 = @import("../crypto/root.zig").Sha1;

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
/// by raw piece data. The dict boundary is measured by skipping the
/// leading dict via the hardened `bencode_scanner.BencodeScanner`, whose
/// length-prefix scan is digit-capped and recursion is depth-bounded.
/// Both guards are critical: this entry point handles attacker-controlled
/// extension payloads up to `peer_wire.max_message_length` (1 MiB), so
/// the prior hand-rolled `findDictEnd`/`skipByteString` pair (which used
/// the unsafe `i + len` form) was production-reachable for every
/// connected peer.
pub fn decode(allocator: std.mem.Allocator, payload: []const u8) DecodeError!MetadataMessage {
    _ = allocator;

    // First pass: skip the leading bencoded dict to find the trailing
    // raw-data boundary. The hardened scanner refuses adversarial
    // length prefixes (>20 digits) and bounds recursion depth at 64.
    var probe = Scanner.init(payload);
    probe.skipValue() catch return error.InvalidMessage;
    const dict_end = probe.pos;

    // Second pass: extract the fields we care about from the dict
    // body. We re-init a scanner over `payload[0..dict_end]` so the
    // `isAtEnd()` check below pins "no junk between the closing 'e'
    // and the trailing piece data".
    var scanner = Scanner.init(payload[0..dict_end]);
    try scanner.expectByte('d');

    var msg_type: ?MsgType = null;
    var piece: ?u32 = null;
    var total_size: u32 = 0;

    while (true) {
        const next = scanner.peek() orelse return error.InvalidMessage;
        if (next == 'e') {
            scanner.pos += 1;
            break;
        }

        const key = try scanner.parseBytes();
        if (std.mem.eql(u8, key, "msg_type")) {
            const value = try scanner.parseInteger();
            if (value < 0 or value > 2) return error.InvalidMsgType;
            msg_type = @enumFromInt(@as(u8, @intCast(value)));
        } else if (std.mem.eql(u8, key, "piece")) {
            const value = try scanner.parseInteger();
            if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidMessage;
            piece = @intCast(value);
        } else if (std.mem.eql(u8, key, "total_size")) {
            const value = try scanner.parseInteger();
            if (value > 0 and value <= std.math.maxInt(u32)) {
                total_size = @intCast(value);
            }
        } else {
            try scanner.skipValue();
        }
    }

    if (!scanner.isAtEnd()) return error.InvalidMessage;

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

const Scanner = @import("bencode_scanner.zig").BencodeScanner(error{InvalidMessage});

/// Allocator vtable that panics on every operation. Used as a sentinel
/// for `MetadataAssembler.initShared`, where the assembler holds an
/// `Allocator` field for layout uniformity but must never call into it
/// (storage is externally owned). Hitting one of these panics is a
/// real-bug signal: a code path silently routed through the owning
/// allocator instead of the shared buffer.
fn sharedAllocPanic(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    @panic("MetadataAssembler.initShared: alloc not allowed; storage is caller-owned");
}
fn sharedResizePanic(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    @panic("MetadataAssembler.initShared: resize not allowed; storage is caller-owned");
}
fn sharedRemapPanic(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    @panic("MetadataAssembler.initShared: remap not allowed; storage is caller-owned");
}
fn sharedFreePanic(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
    @panic("MetadataAssembler.initShared: free not allowed; storage is caller-owned");
}
const noop_alloc_vtable: std.mem.Allocator.VTable = .{
    .alloc = sharedAllocPanic,
    .resize = sharedResizePanic,
    .remap = sharedRemapPanic,
    .free = sharedFreePanic,
};

// ── Metadata assembler ──────────────────────────────────────

/// Maximum number of metadata pieces, given `max_metadata_size` and
/// the fixed 16 KiB BEP 9 piece size. Used to size the pre-allocated
/// `received` array on the EventLoop's shared metadata-fetch slot.
pub const max_piece_count: u32 =
    (max_metadata_size + metadata_piece_size - 1) / metadata_piece_size;

/// Collects metadata pieces, verifies the assembled result against
/// an expected info-hash, and produces the raw info dictionary bytes.
///
/// Two ownership models for the assembly storage:
///   * `init` — assembler owns its allocator, allocates `buffer` and
///     `received` lazily on `setSize` and frees them on `deinit`. Used
///     by tests and the async metadata fetch state machine.
///   * `initShared` — the caller passes in pre-allocated `buffer` and
///     `received` slices sized to the BEP 9 worst case. The assembler
///     uses prefixes of those slices and never frees them. Used by the
///     daemon's `AsyncMetadataFetch`, where the EventLoop owns one
///     16-MiB-class fetch slot shared across all torrents (BEP 9
///     guarantees at most one in-flight metadata fetch per torrent;
///     the EventLoop further serialises across torrents).
pub const MetadataAssembler = struct {
    allocator: std.mem.Allocator,
    expected_hash: [20]u8,
    total_size: u32 = 0,
    piece_count: u32 = 0,
    buffer: ?[]u8 = null,
    received: ?[]bool = null,
    pieces_received: u32 = 0,
    /// When false, `buffer` and `received` were provided by the caller
    /// and will not be freed in `deinit`. The assembler still uses
    /// `buffer[0..total_size]` and `received[0..piece_count]` once
    /// `setSize` runs; the underlying slices may be longer.
    owns_storage: bool = true,
    /// Capacity of the externally-provided `buffer`, in bytes. Only
    /// meaningful when `owns_storage` is false.
    shared_buf_capacity: u32 = 0,
    /// Capacity of the externally-provided `received`, in entries.
    /// Only meaningful when `owns_storage` is false.
    shared_received_capacity: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, expected_hash: [20]u8) MetadataAssembler {
        return .{
            .allocator = allocator,
            .expected_hash = expected_hash,
        };
    }

    /// Construct an assembler that uses an externally-owned buffer and
    /// `received` array. Typical use: the daemon's EventLoop owns one
    /// pre-allocated `[max_metadata_size]u8` and `[max_piece_count]bool`,
    /// passed in for every fetch.
    pub fn initShared(
        expected_hash: [20]u8,
        buffer: []u8,
        received: []bool,
    ) MetadataAssembler {
        // The assembler is BEP-9-stateless until `setSize` runs; the
        // shared storage is reset there and on `reset()` between fetches.
        std.debug.assert(buffer.len >= 1);
        std.debug.assert(received.len >= 1);
        return .{
            // Allocator is unused on the initShared path -- assertions
            // guard against any accidental free.
            .allocator = std.mem.Allocator{
                .ptr = undefined,
                .vtable = &noop_alloc_vtable,
            },
            .expected_hash = expected_hash,
            .owns_storage = false,
            .shared_buf_capacity = std.math.cast(u32, buffer.len) orelse std.math.maxInt(u32),
            .shared_received_capacity = std.math.cast(u32, received.len) orelse std.math.maxInt(u32),
            .buffer = buffer,
            .received = received,
        };
    }

    pub fn deinit(self: *MetadataAssembler) void {
        if (self.owns_storage) {
            if (self.buffer) |buf| self.allocator.free(buf);
            if (self.received) |r| self.allocator.free(r);
        }
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

        const piece_count = (total_size + metadata_piece_size - 1) / metadata_piece_size;

        if (self.owns_storage) {
            self.buffer = try self.allocator.alloc(u8, total_size);
            self.received = try self.allocator.alloc(bool, piece_count);
            @memset(self.received.?, false);
        } else {
            // Shared path: the caller pre-allocated worst-case storage.
            // Reject sizes that won't fit (defends against a future change
            // to `max_metadata_size` outpacing the EventLoop's buffer).
            if (total_size > self.shared_buf_capacity) return error.InvalidMetadataSize;
            if (piece_count > self.shared_received_capacity) return error.InvalidMetadataSize;
            // Zero only the prefix we'll actually consult. The fetch may
            // run again on another torrent without the EventLoop having
            // to memset the whole worst-case array.
            @memset(self.received.?[0..piece_count], false);
        }

        self.total_size = total_size;
        self.piece_count = piece_count;
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
        // Iterate only the active prefix; the shared path may have a
        // longer `received` slice than the current fetch needs.
        const active = received[0..self.piece_count];
        for (active, 0..) |got, i| {
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

    /// Reset the assembler to try again (e.g., after a hash mismatch on
    /// the same fetch, where total_size and piece_count remain valid).
    pub fn reset(self: *MetadataAssembler) void {
        if (self.received) |r| {
            // Only clear the active prefix to keep the shared-path reset
            // O(piece_count) rather than O(max_piece_count).
            const n: usize = if (self.piece_count > 0) self.piece_count else r.len;
            @memset(r[0..n], false);
        }
        self.pieces_received = 0;
    }

    /// Reset the assembler for a brand-new fetch on shared storage.
    /// Clears `total_size`/`piece_count` so the next `setSize` call is
    /// accepted as the first one for a new info-hash. Only valid on
    /// `initShared` assemblers.
    pub fn resetForNewFetch(self: *MetadataAssembler, expected_hash: [20]u8) void {
        std.debug.assert(!self.owns_storage);
        if (self.received) |r| {
            const n: usize = if (self.piece_count > 0) self.piece_count else 0;
            if (n > 0) @memset(r[0..n], false);
        }
        self.pieces_received = 0;
        self.total_size = 0;
        self.piece_count = 0;
        self.expected_hash = expected_hash;
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
    const wrong_hash = @as([20]u8, @splat(0xFF));
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
    var assembler = MetadataAssembler.init(std.testing.allocator, @as([20]u8, @splat(0)));
    defer assembler.deinit();

    try std.testing.expectError(error.InvalidMetadataSize, assembler.setSize(max_metadata_size + 1));
}

test "metadata assembler: reject zero size" {
    var assembler = MetadataAssembler.init(std.testing.allocator, @as([20]u8, @splat(0)));
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

test "decode data message records correct data_offset" {
    // The previous `findDictEnd` test pinned the dict-boundary detector
    // directly. The detector is now folded into `decode` via the hardened
    // bencode scanner, so we assert the same invariant through the
    // public surface: `data_offset` must point at the trailing raw piece
    // bytes immediately after the dict's closing `e`.
    const input = "d8:msg_typei1e5:piecei0e10:total_sizei100eeHELLO";
    const msg = try decode(std.testing.allocator, input);
    try std.testing.expectEqual(MsgType.data, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 0), msg.piece);
    try std.testing.expectEqual(@as(u32, 100), msg.total_size);
    try std.testing.expectEqualStrings("HELLO", input[msg.data_offset..]);
}

test "decode rejects pathological length-prefix overflow" {
    // Adversarial peer: a bencoded dict with a key whose declared
    // length is `maxInt(u64)`. Pre-hardening, `findDictEnd` ->
    // `skipByteString` computed `idx + length` directly and panicked
    // with "integer overflow" in safe builds. The hardened scanner
    // rejects the >20-digit prefix instead.
    const adversarial = "d18446744073709551615:ABCD";
    try std.testing.expectError(
        error.InvalidMessage,
        decode(std.testing.allocator, adversarial),
    );
}

test "decode rejects deeply-nested adversarial bencode" {
    // Adversarial peer: a payload that's just `l`'s. Pre-hardening,
    // `skipBencodeValue` recursed once per `l` byte. With a 1 MiB
    // BEP 10 message ceiling, a malicious peer could blow the native
    // call stack. The hardened scanner caps recursion at 64.
    var buf: [1024]u8 = undefined;
    @memset(&buf, 'l');
    try std.testing.expectError(
        error.InvalidMessage,
        decode(std.testing.allocator, &buf),
    );
}

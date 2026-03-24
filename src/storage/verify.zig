const std = @import("std");
const torrent = @import("../torrent/root.zig");
const writer = @import("writer.zig");

pub const PieceSet = struct {
    bits: []u8,
    piece_count: u32,
    count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, piece_count: u32) !PieceSet {
        const bits = try allocator.alloc(u8, byteCount(piece_count));
        @memset(bits, 0);
        return .{
            .bits = bits,
            .piece_count = piece_count,
        };
    }

    pub fn deinit(self: *PieceSet, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
        self.* = undefined;
    }

    pub fn has(self: PieceSet, piece_index: u32) bool {
        if (piece_index >= self.piece_count) return false;

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        return (self.bits[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    pub fn set(self: *PieceSet, piece_index: u32) !void {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }
        if (self.has(piece_index)) {
            return;
        }

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        self.bits[byte_index] |= @as(u8, 1) << bit_index;
        self.count += 1;
    }

    fn byteCount(piece_count: u32) usize {
        return @intCast((piece_count + 7) / 8);
    }
};

pub const RecheckState = struct {
    complete_pieces: PieceSet,
    bytes_complete: u64,

    pub fn deinit(self: *RecheckState, allocator: std.mem.Allocator) void {
        self.complete_pieces.deinit(allocator);
        self.* = undefined;
    }
};

pub const PiecePlan = struct {
    piece_index: u32,
    piece_length: u32,
    expected_hash: [20]u8,
    spans: []torrent.layout.Layout.Span,
};

pub fn planPieceVerification(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    piece_index: u32,
) !PiecePlan {
    const span_count = try session.layout.pieceSpanCount(piece_index);
    const spans = try allocator.alloc(torrent.layout.Layout.Span, span_count);
    errdefer allocator.free(spans);

    const mapped = try session.layout.mapPiece(piece_index, spans);
    const piece_hash = try session.layout.pieceHash(piece_index);

    var expected_hash: [20]u8 = undefined;
    @memcpy(expected_hash[0..], piece_hash);

    return .{
        .piece_index = piece_index,
        .piece_length = try session.layout.pieceSize(piece_index),
        .expected_hash = expected_hash,
        .spans = mapped,
    };
}

pub fn freePiecePlan(allocator: std.mem.Allocator, plan: PiecePlan) void {
    allocator.free(plan.spans);
}

pub fn verifyPieceBuffer(plan: PiecePlan, piece_data: []const u8) !bool {
    if (piece_data.len != plan.piece_length) {
        return error.InvalidPieceDataLength;
    }

    var actual: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(piece_data, &actual, .{});
    return std.mem.eql(u8, actual[0..], plan.expected_hash[0..]);
}

pub fn recheckExistingData(
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    store: *writer.PieceStore,
) !RecheckState {
    var complete_pieces = try PieceSet.init(allocator, session.pieceCount());
    errdefer complete_pieces.deinit(allocator);

    const scratch = try allocator.alloc(u8, session.layout.piece_length);
    defer allocator.free(scratch);

    var bytes_complete: u64 = 0;
    var piece_index: u32 = 0;
    while (piece_index < session.pieceCount()) : (piece_index += 1) {
        const plan = try planPieceVerification(allocator, session, piece_index);
        defer freePiecePlan(allocator, plan);

        const piece_data = scratch[0..plan.piece_length];
        try store.readPiece(plan.spans, piece_data);
        if (try verifyPieceBuffer(plan, piece_data)) {
            try complete_pieces.set(piece_index);
            bytes_complete += plan.piece_length;
        }
    }

    return .{
        .complete_pieces = complete_pieces,
        .bytes_complete = bytes_complete,
    };
}

test "plan verification for multi file piece" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

    const loaded = try torrent.session.Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    const plan = try planPieceVerification(std.testing.allocator, &loaded, 0);
    defer freePiecePlan(std.testing.allocator, plan);

    try std.testing.expectEqual(@as(u32, 0), plan.piece_index);
    try std.testing.expectEqual(@as(u32, 4), plan.piece_length);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", plan.expected_hash[0..]);
    try std.testing.expectEqual(@as(usize, 2), plan.spans.len);
    try std.testing.expectEqual(@as(u32, 3), plan.spans[0].length);
    try std.testing.expectEqual(@as(u32, 1), plan.spans[1].length);
}

test "verify piece buffer against expected hash" {
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("spam", &hash, .{});

    const plan = PiecePlan{
        .piece_index = 0,
        .piece_length = 4,
        .expected_hash = hash,
        .spans = &.{},
    };

    try std.testing.expect(try verifyPieceBuffer(plan, "spam"));
    try std.testing.expect(!(try verifyPieceBuffer(plan, "eggs")));
    try std.testing.expectError(error.InvalidPieceDataLength, verifyPieceBuffer(plan, "sp"));
}

test "recheck existing on-disk pieces" {
    var hash0: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("spam", &hash0, .{});

    var hash1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("eggs", &hash1, .{});

    const hashes = hash0 ++ hash1;
    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        "d4:infod6:lengthi8e4:name8:test.bin12:piece lengthi4e6:pieces40:{s}ee",
        .{hashes},
    );
    defer std.testing.allocator.free(input);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var store = try writer.PieceStore.init(std.testing.allocator, &session);
    defer store.deinit();

    const piece0 = try planPieceVerification(std.testing.allocator, &session, 0);
    defer freePiecePlan(std.testing.allocator, piece0);
    try store.writePiece(piece0.spans, "spam");

    var state = try recheckExistingData(std.testing.allocator, &session, &store);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(state.complete_pieces.has(0));
    try std.testing.expect(!state.complete_pieces.has(1));
    try std.testing.expectEqual(@as(u32, 1), state.complete_pieces.count);
    try std.testing.expectEqual(@as(u64, 4), state.bytes_complete);
}

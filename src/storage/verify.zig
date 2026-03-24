const std = @import("std");
const torrent = @import("../torrent/root.zig");

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

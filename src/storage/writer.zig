const std = @import("std");
const torrent = @import("../torrent/root.zig");

pub const PieceStore = struct {
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    files: []std.fs.File,

    pub fn init(
        allocator: std.mem.Allocator,
        session: *const torrent.session.Session,
    ) !PieceStore {
        const files = try allocator.alloc(std.fs.File, session.manifest.files.len);
        errdefer allocator.free(files);

        for (session.manifest.files, 0..) |file_entry, index| {
            if (std.fs.path.dirname(file_entry.full_path)) |dirname| {
                try std.fs.cwd().makePath(dirname);
            }

            const file = try std.fs.cwd().createFile(file_entry.full_path, .{
                .read = true,
                .truncate = false,
            });
            errdefer file.close();

            try file.setEndPos(file_entry.length);
            files[index] = file;
        }

        return .{
            .allocator = allocator,
            .session = session,
            .files = files,
        };
    }

    pub fn deinit(self: *PieceStore) void {
        for (self.files) |file| {
            file.close();
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }

    pub fn writePiece(
        self: *PieceStore,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []const u8,
    ) !void {
        for (spans) |span| {
            const file = self.files[span.file_index];
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            try file.pwriteAll(block, span.file_offset);
        }
    }

    pub fn readPiece(
        self: *PieceStore,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []u8,
    ) !void {
        for (spans) |span| {
            const file = self.files[span.file_index];
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            const read_count = try file.preadAll(block, span.file_offset);
            if (read_count != block.len) {
                return error.UnexpectedEndOfFile;
            }
        }
    }

    pub fn sync(self: *PieceStore) !void {
        for (self.files) |file| {
            try file.sync();
        }
    }
};

test "write piece data across multiple files" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    var store = try PieceStore.init(std.testing.allocator, &session);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer @import("verify.zig").freePiecePlan(std.testing.allocator, plan);

    try store.writePiece(plan.spans, "spam");
    try store.sync();

    const first = try tmp.dir.readFileAlloc(std.testing.allocator, "download/root/alpha", 16);
    defer std.testing.allocator.free(first);
    const second = try tmp.dir.readFileAlloc(std.testing.allocator, "download/root/beta/gamma", 16);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("spa", first);
    try std.testing.expectEqualStrings("m", second[0..1]);
}

test "read piece data across multiple files" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    var store = try PieceStore.init(std.testing.allocator, &session);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer @import("verify.zig").freePiecePlan(std.testing.allocator, plan);

    try store.writePiece(plan.spans, "spam");

    var piece_buffer: [4]u8 = undefined;
    try store.readPiece(plan.spans, piece_buffer[0..]);

    try std.testing.expectEqualStrings("spam", &piece_buffer);
}

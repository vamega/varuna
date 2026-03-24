const std = @import("std");
const blocks = @import("blocks.zig");
const layout = @import("layout.zig");
const metainfo = @import("metainfo.zig");
const manifest = @import("../storage/manifest.zig");

pub const Session = struct {
    torrent_bytes: []const u8,
    metainfo: metainfo.Metainfo,
    layout: layout.Layout,
    manifest: manifest.Manifest,
    block_size: u32 = blocks.default_block_size,

    pub fn load(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        target_root: []const u8,
    ) !Session {
        const owned_torrent_bytes = try allocator.dupe(u8, torrent_bytes);
        errdefer allocator.free(owned_torrent_bytes);

        const parsed = try metainfo.parse(allocator, owned_torrent_bytes);
        errdefer metainfo.freeMetainfo(allocator, parsed);

        const built_layout = try layout.build(allocator, &parsed);
        errdefer layout.freeLayout(allocator, built_layout);

        const built_manifest = try manifest.build(allocator, target_root, parsed, built_layout);
        errdefer manifest.freeManifest(allocator, built_manifest);

        return .{
            .torrent_bytes = owned_torrent_bytes,
            .metainfo = parsed,
            .layout = built_layout,
            .manifest = built_manifest,
        };
    }

    pub fn deinit(self: Session, allocator: std.mem.Allocator) void {
        manifest.freeManifest(allocator, self.manifest);
        layout.freeLayout(allocator, self.layout);
        metainfo.freeMetainfo(allocator, self.metainfo);
        allocator.free(self.torrent_bytes);
    }

    pub fn geometry(self: *const Session) blocks.Geometry {
        return .{
            .layout = &self.layout,
            .block_size = self.block_size,
        };
    }

    pub fn fileCount(self: Session) usize {
        return self.manifest.files.len;
    }

    pub fn pieceCount(self: Session) u32 {
        return self.layout.piece_count;
    }

    pub fn totalSize(self: Session) u64 {
        return self.layout.total_size;
    }
};

test "load single file torrent session" {
    const input =
        "d8:announce14:http://tracker" ++ "4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const loaded = try Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), loaded.fileCount());
    try std.testing.expectEqual(@as(u32, 3), loaded.pieceCount());
    try std.testing.expectEqual(@as(u64, 10), loaded.totalSize());
    try std.testing.expectEqualStrings("/srv/torrents/test.bin", loaded.manifest.files[0].full_path);

    const geometry = loaded.geometry();
    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(2));
    try std.testing.expectEqual(@as(u32, 2), try geometry.blockSize(2, 0));
}

test "load multi file torrent session" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

    const loaded = try Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.fileCount());
    try std.testing.expectEqualStrings("root/alpha", loaded.manifest.files[0].relative_path);
    try std.testing.expectEqualStrings("/srv/torrents/root/beta/gamma", loaded.manifest.files[1].full_path);

    var spans: [2]layout.Layout.Span = undefined;
    const mapped = try loaded.layout.mapPiece(0, spans[0..]);
    try std.testing.expectEqual(@as(usize, 2), mapped.len);
    try std.testing.expectEqual(@as(u32, 3), mapped[0].length);
    try std.testing.expectEqual(@as(u32, 1), mapped[1].length);
}

test "session owns torrent bytes after load" {
    const torrent_bytes = try std.testing.allocator.dupe(
        u8,
        "d4:infod6:lengthi4e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee",
    );
    defer std.testing.allocator.free(torrent_bytes);

    const loaded = try Session.load(std.testing.allocator, torrent_bytes, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    @memset(torrent_bytes, 'x');
    try std.testing.expectEqualStrings("test.bin", loaded.metainfo.name);
}

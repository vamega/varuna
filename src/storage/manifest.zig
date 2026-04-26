const std = @import("std");
const metainfo = @import("../torrent/metainfo.zig");
const torrent_layout = @import("../torrent/layout.zig");

pub const Manifest = struct {
    root: []const u8,
    files: []File,

    pub const File = struct {
        length: u64,
        relative_path: []const u8,
        full_path: []const u8,
        offset: u64,
    };
};

pub fn build(
    allocator: std.mem.Allocator,
    target_root: []const u8,
    info: metainfo.Metainfo,
    layout: torrent_layout.Layout,
) !Manifest {
    if (layout.files.len != info.files.len) {
        return error.LayoutFileCountMismatch;
    }

    const root_copy = try allocator.dupe(u8, target_root);
    errdefer allocator.free(root_copy);

    const files = try allocator.alloc(Manifest.File, layout.files.len);
    // Track how many entries are validly initialized so the errdefer
    // doesn't iterate uninitialized memory (which crashes with signal 6
    // when `if (file.relative_path.len != 0)` reads undefined bytes —
    // production bug surfaced by the path-traversal test once it was
    // wired into `zig build test`. See Task #9 progress report.)
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| {
            allocator.free(file.relative_path);
            allocator.free(file.full_path);
        }
        allocator.free(files);
    }

    for (layout.files, info.files, 0..) |layout_file, info_file, index| {
        const relative_path = if (info.isMultiFile()) blk: {
            const path = try layout.renderRelativePath(allocator, info.name, @intCast(index));
            errdefer allocator.free(path);
            try validatePath(path);
            break :blk path;
        } else try joinValidatedPathWithoutRoot(allocator, info_file.path);
        errdefer allocator.free(relative_path);

        const full_path = try std.fs.path.join(allocator, &.{ target_root, relative_path });
        errdefer allocator.free(full_path);

        files[index] = .{
            .length = layout_file.length,
            .relative_path = relative_path,
            .full_path = full_path,
            .offset = layout_file.torrent_offset,
        };
        initialized = index + 1;
    }

    return .{
        .root = root_copy,
        .files = files,
    };
}

pub fn freeManifest(allocator: std.mem.Allocator, manifest: Manifest) void {
    allocator.free(manifest.root);
    for (manifest.files) |file| {
        allocator.free(file.relative_path);
        allocator.free(file.full_path);
    }
    allocator.free(manifest.files);
}

fn validatePath(path: []const u8) !void {
    var iterator = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (iterator.next()) |component| {
        try validateComponent(component);
    }
}

fn joinValidatedPathWithoutRoot(
    allocator: std.mem.Allocator,
    components: []const []const u8,
) ![]const u8 {
    if (components.len == 0) {
        return error.InvalidPathComponent;
    }

    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);

    for (components, 0..) |component, index| {
        try validateComponent(component);
        if (index != 0) {
            try path.append(allocator, std.fs.path.sep);
        }
        try path.appendSlice(allocator, component);
    }

    return path.toOwnedSlice(allocator);
}

fn validateComponent(component: []const u8) !void {
    if (component.len == 0) {
        return error.InvalidPathComponent;
    }

    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
        return error.InvalidPathComponent;
    }

    if (std.fs.path.isAbsolute(component)) {
        return error.InvalidPathComponent;
    }

    if (std.mem.indexOfScalar(u8, component, 0) != null) {
        return error.InvalidPathComponent;
    }

    if (std.mem.indexOfScalar(u8, component, std.fs.path.sep) != null) {
        return error.InvalidPathComponent;
    }
}

test "build manifest for single file torrent" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try torrent_layout.build(std.testing.allocator, &info);
    defer torrent_layout.freeLayout(std.testing.allocator, layout);

    const manifest = try build(std.testing.allocator, "/srv/torrents", info, layout);
    defer freeManifest(std.testing.allocator, manifest);

    try std.testing.expectEqualStrings("/srv/torrents", manifest.root);
    try std.testing.expectEqual(@as(usize, 1), manifest.files.len);
    try std.testing.expectEqualStrings("test.bin", manifest.files[0].relative_path);
    try std.testing.expectEqualStrings("/srv/torrents/test.bin", manifest.files[0].full_path);
    try std.testing.expectEqual(@as(u64, 0), manifest.files[0].offset);
}

test "build manifest for multi file torrent" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try torrent_layout.build(std.testing.allocator, &info);
    defer torrent_layout.freeLayout(std.testing.allocator, layout);

    const manifest = try build(std.testing.allocator, "/srv/torrents", info, layout);
    defer freeManifest(std.testing.allocator, manifest);

    try std.testing.expectEqual(@as(usize, 2), manifest.files.len);
    try std.testing.expectEqualStrings("root/alpha", manifest.files[0].relative_path);
    try std.testing.expectEqualStrings("root/beta/gamma", manifest.files[1].relative_path);
    try std.testing.expectEqualStrings("/srv/torrents/root/beta/gamma", manifest.files[1].full_path);
}

test "reject path traversal components in torrent paths" {
    const input =
        "d4:infod5:filesld6:lengthi1e4:pathl2:..1:xeee4:name4:root12:piece lengthi1e6:pieces20:abcdefghijklmnopqrstee";

    const info = try metainfo.parse(std.testing.allocator, input);
    defer metainfo.freeMetainfo(std.testing.allocator, info);

    const layout = try torrent_layout.build(std.testing.allocator, &info);
    defer torrent_layout.freeLayout(std.testing.allocator, layout);

    try std.testing.expectError(error.InvalidPathComponent, build(std.testing.allocator, "/srv/torrents", info, layout));
}

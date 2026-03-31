/// qBittorrent API compatibility layer.
///
/// Maps Varuna internal types and values to the qBittorrent v2 API format
/// expected by WebUI clients such as qui (autobrr/qui) and Flood.
const std = @import("std");
const TorrentState = @import("../daemon/torrent_session.zig").State;

/// Map Varuna's internal torrent state to qBittorrent-compatible state strings.
/// qui and Flood read these values to determine torrent status, icon, and label.
///
/// qBittorrent state reference (from qui's torrent-state-utils.ts):
///   downloading, metaDL, allocating, stalledDL, queuedDL, checkingDL, forcedDL,
///   uploading, stalledUP, queuedUP, checkingUP, forcedUP,
///   pausedDL, pausedUP, stoppedDL, stoppedUP,
///   error, missingFiles, checkingResumeData, moving
pub fn torrentStateString(state: TorrentState, progress: f64) []const u8 {
    return switch (state) {
        .downloading => if (progress >= 1.0) "uploading" else "downloading",
        .seeding => "uploading",
        .paused => if (progress >= 1.0) "pausedUP" else "pausedDL",
        .stopped => if (progress >= 1.0) "stoppedUP" else "stoppedDL",
        .checking => if (progress >= 1.0) "checkingUP" else "checkingDL",
        .metadata_fetching => "metaDL",
        .@"error" => "error",
    };
}

/// Build content_path: save_path/torrent_name.
/// For single-file torrents this is the full file path; for multi-file
/// torrents this is the directory path (torrent name is the directory name).
pub fn buildContentPath(allocator: std.mem.Allocator, save_path: []const u8, name: []const u8) ![]const u8 {
    if (name.len == 0) return try allocator.dupe(u8, save_path);

    const needs_sep = save_path.len > 0 and save_path[save_path.len - 1] != '/';
    const sep: []const u8 = if (needs_sep) "/" else "";

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ save_path, sep, name });
}

/// Build a magnet URI from info-hash hex, display name, and primary tracker URL.
pub fn buildMagnetUri(allocator: std.mem.Allocator, info_hash_hex: []const u8, name: []const u8, tracker: []const u8) ![]const u8 {
    var uri = std.ArrayList(u8).empty;
    errdefer uri.deinit(allocator);

    try uri.appendSlice(allocator, "magnet:?xt=urn:btih:");
    try uri.appendSlice(allocator, info_hash_hex);

    if (name.len > 0) {
        try uri.appendSlice(allocator, "&dn=");
        try percentEncode(allocator, &uri, name);
    }

    if (tracker.len > 0) {
        try uri.appendSlice(allocator, "&tr=");
        try percentEncode(allocator, &uri, tracker);
    }

    return uri.toOwnedSlice(allocator);
}

/// Percent-encode a string for use in a magnet URI.
pub fn percentEncode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else {
            try buf.print(allocator, "%{X:0>2}", .{c});
        }
    }
}

// ── Tests ─────────────────────────────────────────────────

test "downloading state maps correctly" {
    try std.testing.expectEqualStrings("downloading", torrentStateString(.downloading, 0.5));
    try std.testing.expectEqualStrings("uploading", torrentStateString(.downloading, 1.0));
}

test "seeding always maps to uploading" {
    try std.testing.expectEqualStrings("uploading", torrentStateString(.seeding, 1.0));
    try std.testing.expectEqualStrings("uploading", torrentStateString(.seeding, 0.5));
}

test "paused maps based on progress" {
    try std.testing.expectEqualStrings("pausedDL", torrentStateString(.paused, 0.5));
    try std.testing.expectEqualStrings("pausedUP", torrentStateString(.paused, 1.0));
}

test "stopped maps based on progress" {
    try std.testing.expectEqualStrings("stoppedDL", torrentStateString(.stopped, 0.0));
    try std.testing.expectEqualStrings("stoppedUP", torrentStateString(.stopped, 1.0));
}

test "checking maps based on progress" {
    try std.testing.expectEqualStrings("checkingDL", torrentStateString(.checking, 0.3));
    try std.testing.expectEqualStrings("checkingUP", torrentStateString(.checking, 1.0));
}

test "error state maps to error" {
    try std.testing.expectEqualStrings("error", torrentStateString(.@"error", 0.0));
}

test "buildContentPath joins save_path and name" {
    const allocator = std.testing.allocator;
    const path = try buildContentPath(allocator, "/downloads", "my_torrent");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/downloads/my_torrent", path);
}

test "buildContentPath handles trailing slash" {
    const allocator = std.testing.allocator;
    const path = try buildContentPath(allocator, "/downloads/", "my_torrent");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/downloads/my_torrent", path);
}

test "buildContentPath returns save_path when name is empty" {
    const allocator = std.testing.allocator;
    const path = try buildContentPath(allocator, "/downloads", "");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/downloads", path);
}

test "buildMagnetUri generates valid magnet link" {
    const allocator = std.testing.allocator;
    const hash_hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const uri = try buildMagnetUri(allocator, hash_hex, "Test File", "http://tracker.example.com/announce");
    defer allocator.free(uri);

    try std.testing.expect(std.mem.startsWith(u8, uri, "magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709"));
    try std.testing.expect(std.mem.indexOf(u8, uri, "&dn=Test%20File") != null);
    try std.testing.expect(std.mem.indexOf(u8, uri, "&tr=http%3A%2F%2Ftracker.example.com%2Fannounce") != null);
}

test "buildMagnetUri without tracker" {
    const allocator = std.testing.allocator;
    const hash_hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
    const uri = try buildMagnetUri(allocator, hash_hex, "Test", "");
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:da39a3ee5e6b4b0d3255bfef95601890afd80709&dn=Test", uri);
}

test "percentEncode encodes special characters" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try percentEncode(allocator, &buf, "hello world/foo:bar");
    try std.testing.expectEqualStrings("hello%20world%2Ffoo%3Abar", buf.items);
}

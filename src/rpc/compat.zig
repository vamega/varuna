/// qBittorrent API compatibility layer.
///
/// Maps Varuna internal types and values to the qBittorrent v2 API format
/// expected by WebUI clients such as qui (autobrr/qui) and Flood.
const std = @import("std");
const TorrentState = @import("../daemon/torrent_session.zig").State;
const TorrentStats = @import("../daemon/torrent_session.zig").Stats;
const json_mod = @import("json.zig");

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
        .queued => if (progress >= 1.0) "queuedUP" else "queuedDL",
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

/// Format a BEP 52 v2 info-hash (32-byte SHA-256) as a 64-character lowercase
/// hex string. Returns "" if the hash is null (pure v1 torrent).
pub fn formatInfoHashV2(v2: ?[32]u8) [64]u8 {
    if (v2) |hash| {
        return std.fmt.bytesToHex(hash, .lower);
    }
    return [_]u8{'0'} ** 64; // should not be used when null
}

/// Serialize a torrent stats object as a JSON object. Used by both
/// the /torrents/info endpoint (handlers.zig) and /sync/maindata (sync.zig).
///
/// When `include_partial_seed` is true, the "partial_seed" field is included
/// in the output (required by /torrents/info but not by /sync/maindata).
pub fn serializeTorrentJson(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentStats, include_partial_seed: bool) !void {
    const esc = json_mod.jsonSafe;
    const qbt_state = torrentStateString(stat.state, stat.progress);
    const now = std.time.timestamp();
    const time_active: i64 = now - stat.added_on;
    const amount_left: u64 = if (stat.total_size > stat.bytes_downloaded) stat.total_size - stat.bytes_downloaded else 0;
    const completion_on: i64 = if (stat.progress >= 1.0) stat.added_on else -1;

    // Build content_path and magnet_uri
    const content_path = buildContentPath(allocator, stat.save_path, stat.name) catch stat.save_path;
    defer if (content_path.ptr != stat.save_path.ptr) allocator.free(content_path);

    const magnet_uri = buildMagnetUri(allocator, &stat.info_hash_hex, stat.name, stat.tracker) catch "";
    defer if (magnet_uri.len > 0) allocator.free(magnet_uri);

    const v2_hex = if (stat.info_hash_v2 != null) formatInfoHashV2(stat.info_hash_v2) else [_]u8{0} ** 64;
    const v2_str: []const u8 = if (stat.info_hash_v2 != null) &v2_hex else "";

    // Split into two print calls to stay under the 32-argument limit.
    try json.print(
        allocator,
        "{{\"name\":\"{f}\",\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"{s}\",\"state\":\"{s}\",\"size\":{},\"total_size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":{},\"num_leechs\":{},\"num_complete\":{},\"num_incomplete\":{},\"added_on\":{},\"completion_on\":{},\"save_path\":\"{f}\",\"content_path\":\"{f}\",\"download_path\":\"\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{s},\"private\":{s}",
        .{
            esc(stat.name),
            stat.info_hash_hex,
            stat.info_hash_hex,
            v2_str,
            qbt_state,
            stat.total_size,
            stat.total_size,
            stat.progress,
            stat.download_speed,
            stat.upload_speed,
            stat.scrape_complete,
            stat.peers_connected,
            stat.scrape_complete,
            stat.scrape_incomplete,
            stat.added_on,
            completion_on,
            esc(stat.save_path),
            esc(content_path),
            stat.pieces_have,
            stat.pieces_total,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            @as([]const u8, if (stat.sequential_download) "true" else "false"),
            @as([]const u8, if (stat.is_private) "true" else "false"),
        },
    );

    if (include_partial_seed) {
        try json.print(
            allocator,
            ",\"f_l_piece_prio\":false,\"force_start\":false,\"super_seeding\":{s},\"partial_seed\":{s},\"auto_tmm\":false,\"category\":\"{f}\",\"tags\":\"{f}\",\"tracker\":\"{f}\",\"trackers_count\":{},\"amount_left\":{},\"completed\":{},\"downloaded\":{},\"downloaded_session\":{},\"uploaded\":{},\"uploaded_session\":{},\"time_active\":{},\"seeding_time\":{},\"last_activity\":{},\"seen_complete\":-1,\"priority\":{},\"availability\":-1,\"max_ratio\":-1,\"max_seeding_time\":-1,\"ratio_limit\":{d:.4},\"seeding_time_limit\":{},\"popularity\":0,\"magnet_uri\":\"{f}\",\"reannounce\":0}}",
            .{
                @as([]const u8, if (stat.super_seeding) "true" else "false"),
                @as([]const u8, if (stat.partial_seed) "true" else "false"),
                esc(stat.category),
                esc(stat.tags),
                esc(stat.tracker),
                stat.trackers_count,
                amount_left,
                stat.bytes_downloaded,
                stat.bytes_downloaded,
                stat.bytes_downloaded,
                stat.bytes_uploaded,
                stat.bytes_uploaded,
                time_active,
                stat.seeding_time,
                now,
                stat.queue_position,
                stat.ratio_limit,
                stat.seeding_time_limit,
                esc(magnet_uri),
            },
        );
    } else {
        try json.print(
            allocator,
            ",\"f_l_piece_prio\":false,\"force_start\":false,\"super_seeding\":{s},\"auto_tmm\":false,\"category\":\"{f}\",\"tags\":\"{f}\",\"tracker\":\"{f}\",\"trackers_count\":{},\"amount_left\":{},\"completed\":{},\"downloaded\":{},\"downloaded_session\":{},\"uploaded\":{},\"uploaded_session\":{},\"time_active\":{},\"seeding_time\":{},\"last_activity\":{},\"seen_complete\":-1,\"priority\":{},\"availability\":-1,\"max_ratio\":-1,\"max_seeding_time\":-1,\"ratio_limit\":{d:.4},\"seeding_time_limit\":{},\"popularity\":0,\"magnet_uri\":\"{f}\",\"reannounce\":0}}",
            .{
                @as([]const u8, if (stat.super_seeding) "true" else "false"),
                esc(stat.category),
                esc(stat.tags),
                esc(stat.tracker),
                stat.trackers_count,
                amount_left,
                stat.bytes_downloaded,
                stat.bytes_downloaded,
                stat.bytes_downloaded,
                stat.bytes_uploaded,
                stat.bytes_uploaded,
                time_active,
                stat.seeding_time,
                now,
                stat.queue_position,
                stat.ratio_limit,
                stat.seeding_time_limit,
                esc(magnet_uri),
            },
        );
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

test "queued maps based on progress" {
    try std.testing.expectEqualStrings("queuedDL", torrentStateString(.queued, 0.3));
    try std.testing.expectEqualStrings("queuedUP", torrentStateString(.queued, 1.0));
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

test "formatInfoHashV2 returns 64-char hex for non-null hash" {
    var hash: [32]u8 = undefined;
    // Set hash to 0x00..0x1f for a known pattern
    for (&hash, 0..) |*b, i| {
        b.* = @intCast(i);
    }
    const hex = formatInfoHashV2(hash);
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", &hex);
}

test "formatInfoHashV2 returns zeros for null hash" {
    const hex = formatInfoHashV2(null);
    try std.testing.expectEqualStrings("0" ** 64, &hex);
}

test "percentEncode encodes special characters" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try percentEncode(allocator, &buf, "hello world/foo:bar");
    try std.testing.expectEqualStrings("hello%20world%2Ffoo%3Abar", buf.items);
}

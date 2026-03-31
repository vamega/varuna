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

const std = @import("std");

/// Metadata fetch progress, suitable for API exposure.
pub const FetchProgress = struct {
    /// Current state of the metadata fetch.
    state: FetchState = .idle,
    /// Total metadata size in bytes (0 if not yet known).
    metadata_size: u32 = 0,
    /// Number of metadata pieces received so far.
    pieces_received: u32 = 0,
    /// Total number of metadata pieces needed.
    pieces_total: u32 = 0,
    /// Number of peers attempted so far.
    peers_attempted: u32 = 0,
    /// Number of peers that support ut_metadata.
    peers_with_metadata: u32 = 0,
    /// Number of peers currently connected for metadata.
    peers_active: u32 = 0,
    /// Human-readable error message if state is .failed.
    error_message: ?[]const u8 = null,
    /// Elapsed time in seconds since fetch started.
    elapsed_secs: i64 = 0,
};

pub const FetchState = enum {
    idle,
    announcing,
    connecting,
    downloading,
    completed,
    failed,
};

test "FetchProgress default values" {
    const progress = FetchProgress{};
    try std.testing.expectEqual(FetchState.idle, progress.state);
    try std.testing.expectEqual(@as(u32, 0), progress.metadata_size);
    try std.testing.expectEqual(@as(u32, 0), progress.pieces_received);
    try std.testing.expectEqual(@as(u32, 0), progress.pieces_total);
    try std.testing.expectEqual(@as(u32, 0), progress.peers_attempted);
}

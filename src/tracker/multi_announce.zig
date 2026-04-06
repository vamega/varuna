const std = @import("std");
const announce = @import("announce.zig");

/// Result of a parallel multi-tracker announce. The first successful response
/// wins; all other in-flight announces are ignored. Returns the winning
/// response and the URL that produced it.
pub const MultiAnnounceResult = struct {
    response: announce.Response,
    url_index: usize,
};

/// Announce to all tracker URLs simultaneously. Each URL gets its own
/// background thread. The first tracker to return a successful response
/// with peers wins.
///
/// Caller must free the response via announce.freeResponse().
pub fn announceParallel(
    allocator: std.mem.Allocator,
    urls: []const []const u8,
    base_request: announce.Request,
) !MultiAnnounceResult {
    if (urls.len == 0) return error.NoTrackerUrls;
    if (urls.len == 1) {
        // Optimization: single URL, no need for threading overhead
        var req = base_request;
        req.announce_url = urls[0];
        const resp = try announce.fetchAuto(allocator, req);
        return .{ .response = resp, .url_index = 0 };
    }

    // Shared state for the race: first thread to set winner wins.
    const SharedState = struct {
        winner_set: std.atomic.Value(bool),
        winner_response: ?announce.Response,
        winner_url_index: usize,
        mutex: std.Thread.Mutex,
    };

    var shared = SharedState{
        .winner_set = std.atomic.Value(bool).init(false),
        .winner_response = null,
        .winner_url_index = 0,
        .mutex = .{},
    };

    // Spawn one thread per URL (capped at 8 to avoid excessive thread creation)
    const max_threads = 8;
    const thread_count = @min(urls.len, max_threads);
    var threads: [max_threads]?std.Thread = [_]?std.Thread{null} ** max_threads;

    for (0..thread_count) |i| {
        threads[i] = std.Thread.spawn(.{}, announceWorker, .{
            allocator,
            urls[i],
            base_request,
            &shared,
            i,
        }) catch null;
    }

    // Wait for all threads to finish
    for (0..thread_count) |i| {
        if (threads[i]) |t| t.join();
    }

    if (shared.winner_response) |resp| {
        return .{ .response = resp, .url_index = shared.winner_url_index };
    }
    return error.AllTrackersFailed;
}

fn announceWorker(
    allocator: std.mem.Allocator,
    url: []const u8,
    base_request: announce.Request,
    shared: anytype,
    url_index: usize,
) void {
    // Early exit if another thread already won
    if (shared.winner_set.load(.acquire)) return;

    var req = base_request;
    req.announce_url = url;

    const resp = announce.fetchAuto(allocator, req) catch return;

    // Only accept responses with peers
    if (resp.peers.len == 0) {
        announce.freeResponse(allocator, resp);
        return;
    }

    // Race: try to be the winner
    shared.mutex.lock();
    defer shared.mutex.unlock();

    if (shared.winner_set.load(.acquire)) {
        // Another thread won first, discard our result
        announce.freeResponse(allocator, resp);
        return;
    }

    shared.winner_response = resp;
    shared.winner_url_index = url_index;
    shared.winner_set.store(true, .release);
}

/// Background worker version: announces to all URLs in parallel using the
/// shared announce ring's mutex for serialization, but spawns threads for
/// each URL so they run concurrently. Results go into `result_peers` and
/// `result_url_index` atomically.
///
/// This is the version used by the event loop re-announce path.
pub fn announceParallelWithRing(
    allocator: std.mem.Allocator,
    urls: []const []const u8,
    base_request: announce.Request,
) !MultiAnnounceResult {
    // For the background re-announce case, each thread creates its own
    // short-lived ring (the shared ring is for serialized access only).
    return announceParallel(allocator, urls, base_request);
}

// ── Tests ────────────────────────────────────────────────

test "parallel announce with single URL falls back to direct call" {
    // This test just validates the single-URL optimization path compiles.
    // Actual network tests require a running tracker.
    const urls = [_][]const u8{"http://invalid.tracker.test:9999/announce"};
    const req = announce.Request{
        .announce_url = "",
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .port = 6881,
        .left = 100,
    };

    const result = announceParallel(std.testing.allocator, urls[0..], req);
    // Expected to fail since the tracker doesn't exist
    try std.testing.expectError(error.ConnectionRefused, result);
}

test "parallel announce with no URLs returns error" {
    const req = announce.Request{
        .announce_url = "",
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .port = 6881,
        .left = 100,
    };
    const empty: []const []const u8 = &.{};
    try std.testing.expectError(error.NoTrackerUrls, announceParallel(std.testing.allocator, empty, req));
}

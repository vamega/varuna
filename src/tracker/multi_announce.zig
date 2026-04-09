const std = @import("std");
const announce = @import("announce.zig");

/// Result of a parallel multi-tracker announce. The first successful response
/// wins; all other in-flight announces are ignored. Returns the winning
/// response and the URL that produced it.
pub const MultiAnnounceResult = struct {
    response: announce.Response,
    url_index: usize,
};

const SharedState = struct {
    winner_set: std.atomic.Value(bool),
    winner_response: ?announce.Response,
    winner_url_index: usize,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    completed_count: usize,
    expected_count: usize,
};

const CleanupState = struct {
    allocator: std.mem.Allocator,
    shared: *SharedState,
    threads: []?std.Thread,
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

    const page_allocator = std.heap.page_allocator;

    const shared = try page_allocator.create(SharedState);
    shared.* = .{
        .winner_set = std.atomic.Value(bool).init(false),
        .winner_response = null,
        .winner_url_index = 0,
        .mutex = .{},
        .cond = .{},
        .completed_count = 0,
        .expected_count = urls.len,
    };
    errdefer page_allocator.destroy(shared);

    const threads = try page_allocator.alloc(?std.Thread, urls.len);
    errdefer page_allocator.free(threads);
    @memset(threads, null);

    var started_count: usize = 0;
    errdefer {
        for (threads[0..started_count]) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }
    }

    for (urls, 0..) |url, i| {
        threads[i] = std.Thread.spawn(.{}, announceWorker, .{
            page_allocator,
            url,
            base_request,
            shared,
            i,
        }) catch null;
        if (threads[i] != null) {
            started_count += 1;
        } else {
            shared.mutex.lock();
            shared.completed_count += 1;
            shared.cond.broadcast();
            shared.mutex.unlock();
        }
    }

    shared.mutex.lock();
    defer shared.mutex.unlock();
    while (!shared.winner_set.load(.acquire) and shared.completed_count < shared.expected_count) {
        shared.cond.wait(&shared.mutex);
    }

    const winner_response = shared.winner_response;
    const winner_url_index = shared.winner_url_index;
    shared.winner_response = null;

    const cleanup = try page_allocator.create(CleanupState);
    cleanup.* = .{
        .allocator = page_allocator,
        .shared = shared,
        .threads = threads,
    };
    errdefer page_allocator.destroy(cleanup);

    const cleanup_thread = try std.Thread.spawn(.{}, cleanupWorkers, .{cleanup});
    cleanup_thread.detach();

    if (winner_response) |resp| {
        const peers = try allocator.dupe(announce.Peer, resp.peers);
        defer announce.freeResponse(page_allocator, resp);
        return .{
            .response = .{
                .interval = resp.interval,
                .peers = peers,
                .complete = resp.complete,
                .incomplete = resp.incomplete,
                .warning_message = resp.warning_message,
            },
            .url_index = winner_url_index,
        };
    }
    return error.AllTrackersFailed;
}

fn cleanupWorkers(state: *CleanupState) void {
    for (state.threads) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }
    state.allocator.free(state.threads);
    if (state.shared.winner_response) |resp| {
        announce.freeResponse(state.allocator, resp);
    }
    state.allocator.destroy(state.shared);
    state.allocator.destroy(state);
}

fn announceWorker(
    allocator: std.mem.Allocator,
    url: []const u8,
    base_request: announce.Request,
    shared: anytype,
    url_index: usize,
) void {
    defer {
        shared.mutex.lock();
        shared.completed_count += 1;
        shared.cond.broadcast();
        shared.mutex.unlock();
    }

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
    shared.cond.broadcast();
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

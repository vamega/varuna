const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Sha1 = @import("../crypto/sha1.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HashType = @import("../storage/verify.zig").HashType;

const default_thread_count = 4;

/// Threadpool-based piece hasher for parallel SHA-1 verification.
/// The event loop submits pieces; the pool processes them concurrently;
/// results are collected via drainResults().
pub const Hasher = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Job queue: event loop pushes, worker threads pop
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    pending_jobs: std.ArrayList(Job),

    // Result queue: worker threads push, event loop pops
    result_mutex: std.Thread.Mutex = .{},
    completed_results: std.ArrayList(Result),

    // eventfd for waking the event loop when results are ready
    event_fd: posix.fd_t = -1,

    // Count of jobs currently being processed by worker threads
    // (dequeued from pending_jobs but not yet added to completed_results).
    in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub const Job = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        piece_length: u32,
        expected_hash: [20]u8,
        expected_hash_v2: [32]u8 = [_]u8{0} ** 32,
        hash_type: HashType = .sha1,
        torrent_id: u8,
    };

    pub const Result = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        valid: bool,
        torrent_id: u8,
    };

    /// Create a heap-allocated Hasher. Must be heap-allocated because
    /// worker threads hold pointers to it.
    pub fn create(allocator: std.mem.Allocator, thread_count: ?u32) !*Hasher {
        const count = thread_count orelse default_thread_count;
        const efd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(efd);

        const self = try allocator.create(Hasher);
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, count),
            .pending_jobs = std.ArrayList(Job).empty,
            .completed_results = std.ArrayList(Result).empty,
            .event_fd = efd,
        };

        var spawned: usize = 0;
        errdefer {
            self.running.store(false, .release);
            self.queue_cond.broadcast();
            for (self.threads[0..spawned]) |t| t.join();
            allocator.free(self.threads);
            allocator.destroy(self);
        }

        for (self.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerFn, .{self});
            spawned += 1;
        }

        return self;
    }

    // Keep init as a convenience that returns the struct (for tests only)
    pub fn init(allocator: std.mem.Allocator, thread_count: ?u32) !Hasher {
        _ = thread_count;
        _ = allocator;
        return error.UseCreateInstead;
    }

    pub fn deinit(self: *Hasher) void {
        self.running.store(false, .release);
        self.queue_cond.broadcast();

        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);

        for (self.pending_jobs.items) |job| {
            self.allocator.free(job.piece_buf);
        }
        self.pending_jobs.deinit(self.allocator);

        for (self.completed_results.items) |result| {
            if (!result.valid) self.allocator.free(result.piece_buf);
        }
        self.completed_results.deinit(self.allocator);

        if (self.event_fd >= 0) posix.close(self.event_fd);
    }

    /// Submit a piece for background SHA-1 verification.
    /// Called from the event loop thread. Does not block.
    pub fn submitVerify(
        self: *Hasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u8,
    ) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.pending_jobs.append(self.allocator, .{
            .slot = slot,
            .piece_index = piece_index,
            .piece_buf = piece_buf,
            .piece_length = @intCast(piece_buf.len),
            .expected_hash = expected_hash,
            .torrent_id = torrent_id,
        });
        self.queue_cond.signal();
    }

    /// Atomically drain completed results into a caller-owned buffer.
    /// Called from the event loop thread. The returned slice is valid until
    /// the next call to drainResultsInto (which reuses the swap buffer).
    /// This avoids the TOCTOU race of the old drainResults+clearResults pair.
    pub fn drainResultsInto(self: *Hasher, swap_buf: *std.ArrayList(Result)) []const Result {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        // Consume the eventfd counter
        if (self.event_fd >= 0) {
            var buf: [8]u8 = undefined;
            _ = posix.read(self.event_fd, &buf) catch {};
        }

        // Swap: caller gets the completed results, hasher gets the (empty) swap buffer.
        // This is O(1) and lock-free for the caller's processing loop.
        const tmp = self.completed_results;
        self.completed_results = swap_buf.*;
        swap_buf.* = tmp;

        return swap_buf.items;
    }

    /// Returns true if there are pending jobs, in-flight hashes, or unread results.
    /// Called from the event loop thread to decide whether draining is complete.
    pub fn hasPendingWork(self: *Hasher) bool {
        if (self.in_flight.load(.acquire) > 0) return true;
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (self.pending_jobs.items.len > 0) return true;
        }
        {
            self.result_mutex.lock();
            defer self.result_mutex.unlock();
            if (self.completed_results.items.len > 0) return true;
        }
        return false;
    }

    pub fn getEventFd(self: *Hasher) posix.fd_t {
        return self.event_fd;
    }

    pub fn threadCount(self: *const Hasher) usize {
        return self.threads.len;
    }

    fn workerFn(self: *Hasher) void {
        while (self.running.load(.acquire)) {
            // Wait for a job
            self.queue_mutex.lock();
            while (self.pending_jobs.items.len == 0 and self.running.load(.acquire)) {
                // Use long timeout to minimize futex contention when idle.
                // submitVerify signals the condvar when a job is available.
                self.queue_cond.timedWait(&self.queue_mutex, 1 * std.time.ns_per_s) catch {};
            }

            if (self.pending_jobs.items.len == 0) {
                self.queue_mutex.unlock();
                continue;
            }

            const job = self.pending_jobs.orderedRemove(0);
            _ = self.in_flight.fetchAdd(1, .acq_rel);
            self.queue_mutex.unlock();

            // Hash the piece (CPU-intensive, runs in parallel across pool)
            const valid = switch (job.hash_type) {
                .sha256 => blk: {
                    var actual_v2: [32]u8 = undefined;
                    Sha256.hash(job.piece_buf[0..job.piece_length], &actual_v2, .{});
                    break :blk std.mem.eql(u8, actual_v2[0..], job.expected_hash_v2[0..]);
                },
                .sha1 => blk: {
                    var actual: [20]u8 = undefined;
                    Sha1.hash(job.piece_buf[0..job.piece_length], &actual, .{});
                    break :blk std.mem.eql(u8, actual[0..], job.expected_hash[0..]);
                },
            };

            // Push result
            self.result_mutex.lock();
            self.completed_results.append(self.allocator, .{
                .slot = job.slot,
                .piece_index = job.piece_index,
                .piece_buf = job.piece_buf,
                .valid = valid,
                .torrent_id = job.torrent_id,
            }) catch {
                // OOM: free the piece buffer to avoid leaking it. The piece
                // will appear stuck in-progress; the peer timeout mechanism
                // will eventually reclaim it, but at least we don't leak memory.
                self.allocator.free(job.piece_buf);
                std.log.err("hasher: OOM appending result for piece {d}, buffer freed", .{job.piece_index});
                self.result_mutex.unlock();
                _ = self.in_flight.fetchSub(1, .acq_rel);
                continue;
            };
            self.result_mutex.unlock();
            _ = self.in_flight.fetchSub(1, .acq_rel);

            // Wake the event loop
            if (self.event_fd >= 0) {
                const val: u64 = 1;
                _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch {};
            }
        }
    }
};

test "hasher pool verifies pieces correctly" {
    var hasher = Hasher.create(std.testing.allocator, 2) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        std.testing.allocator.destroy(hasher);
    }

    // Submit a valid piece
    const data1 = try std.testing.allocator.alloc(u8, 4);
    @memcpy(data1, "spam");
    var expected1: [20]u8 = undefined;
    Sha1.hash("spam", &expected1, .{});
    try hasher.submitVerify(0, 0, data1, expected1, 0);

    // Submit an invalid piece
    const data2 = try std.testing.allocator.alloc(u8, 4);
    @memcpy(data2, "eggs");
    var expected2: [20]u8 = undefined;
    Sha1.hash("spam", &expected2, .{}); // wrong hash for "eggs"
    try hasher.submitVerify(1, 1, data2, expected2, 0);

    // Wait for results using the swap-based API
    var swap_buf = std.ArrayList(Hasher.Result).empty;
    defer swap_buf.deinit(std.testing.allocator);

    var attempts: u32 = 0;
    var valid_count: u32 = 0;
    var invalid_count: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const results = hasher.drainResultsInto(&swap_buf);
        for (results) |r| {
            if (r.valid) {
                valid_count += 1;
                std.testing.allocator.free(r.piece_buf);
            } else {
                invalid_count += 1;
                std.testing.allocator.free(r.piece_buf);
            }
        }
        swap_buf.clearRetainingCapacity();
        if (valid_count + invalid_count >= 2) break;
    }
    try std.testing.expectEqual(@as(u32, 1), valid_count);
    try std.testing.expectEqual(@as(u32, 1), invalid_count);
}

test "hasher pool thread count" {
    var hasher = Hasher.create(std.testing.allocator, 8) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        std.testing.allocator.destroy(hasher);
    }

    try std.testing.expectEqual(@as(usize, 8), hasher.threadCount());
}

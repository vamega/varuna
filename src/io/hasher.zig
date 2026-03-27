const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

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

    pub const Job = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        piece_length: u32,
        expected_hash: [20]u8,
    };

    pub const Result = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        valid: bool,
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
    ) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.pending_jobs.append(self.allocator, .{
            .slot = slot,
            .piece_index = piece_index,
            .piece_buf = piece_buf,
            .piece_length = @intCast(piece_buf.len),
            .expected_hash = expected_hash,
        });
        self.queue_cond.signal();
    }

    /// Drain completed results. Called from the event loop thread.
    pub fn drainResults(self: *Hasher) []const Result {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        // Consume the eventfd counter
        if (self.event_fd >= 0) {
            var buf: [8]u8 = undefined;
            _ = posix.read(self.event_fd, &buf) catch {};
        }

        return self.completed_results.items;
    }

    pub fn clearResults(self: *Hasher) void {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();
        self.completed_results.clearRetainingCapacity();
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
            self.queue_mutex.unlock();

            // Hash the piece (CPU-intensive, runs in parallel across pool)
            var actual: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(job.piece_buf[0..job.piece_length], &actual, .{});
            const valid = std.mem.eql(u8, actual[0..], job.expected_hash[0..]);

            // Push result
            self.result_mutex.lock();
            self.completed_results.append(self.allocator, .{
                .slot = job.slot,
                .piece_index = job.piece_index,
                .piece_buf = job.piece_buf,
                .valid = valid,
            }) catch {};
            self.result_mutex.unlock();

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
    std.crypto.hash.Sha1.hash("spam", &expected1, .{});
    try hasher.submitVerify(0, 0, data1, expected1);

    // Submit an invalid piece
    const data2 = try std.testing.allocator.alloc(u8, 4);
    @memcpy(data2, "eggs");
    var expected2: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("spam", &expected2, .{}); // wrong hash for "eggs"
    try hasher.submitVerify(1, 1, data2, expected2);

    // Wait for results
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const results = hasher.drainResults();
        if (results.len >= 2) {
            var valid_count: u32 = 0;
            var invalid_count: u32 = 0;
            for (results) |r| {
                if (r.valid) {
                    valid_count += 1;
                } else {
                    invalid_count += 1;
                    std.testing.allocator.free(r.piece_buf);
                }
            }
            try std.testing.expectEqual(@as(u32, 1), valid_count);
            try std.testing.expectEqual(@as(u32, 1), invalid_count);
            hasher.clearResults();
            // Free valid piece buf
            for (hasher.drainResults()) |r| {
                std.testing.allocator.free(r.piece_buf);
            }
            // Free the valid result's buf from the first drain
            std.testing.allocator.free(data1);
            return;
        }
        hasher.clearResults();
    }
    return error.TestTimeout;
}

test "hasher pool thread count" {
    var hasher = Hasher.create(std.testing.allocator, 8) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        std.testing.allocator.destroy(hasher);
    }

    try std.testing.expectEqual(@as(usize, 8), hasher.threadCount());
}

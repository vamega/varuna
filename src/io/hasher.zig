const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const crypto = @import("../crypto/root.zig");
const Sha1 = crypto.Sha1;
const Sha256 = crypto.Sha256;
const HashType = @import("../storage/verify.zig").HashType;
const Layout = @import("../torrent/layout.zig").Layout;

const default_thread_count = 4;

/// Threadpool-based piece hasher for parallel SHA-1 verification.
/// The event loop submits pieces; the pool processes them concurrently;
/// results are collected via drainResults().
///
/// Also handles Merkle tree building jobs for BEP 52: reading piece data
/// from disk and computing SHA-256 hashes for an entire file's piece range.
/// These run on the same worker threads and deliver results through a
/// separate queue (drainMerkleResultsInto).
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

    // Merkle tree building: separate queues to avoid conflating with piece verify
    merkle_jobs: std.ArrayList(MerkleJob),
    merkle_results: std.ArrayList(MerkleResult),

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
        torrent_id: u32,
    };

    pub const Result = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        valid: bool,
        torrent_id: u32,
    };

    /// A job to build SHA-256 piece hashes for an entire file (BEP 52 Merkle tree).
    /// The worker thread reads piece data from disk via pread and computes hashes.
    /// The layout and shared_fds pointers are valid for the lifetime of the torrent.
    pub const MerkleJob = struct {
        torrent_id: u32,
        file_index: u32,
        first_piece: u32,
        piece_count: u32,
        layout: *const Layout,
        shared_fds: []const posix.fd_t,
    };

    /// Result of a Merkle tree building job. On success, `piece_hashes` is an
    /// allocated slice of SHA-256 hashes (one per piece) that the event loop
    /// must free after building and caching the Merkle tree.
    pub const MerkleResult = struct {
        torrent_id: u32,
        file_index: u32,
        piece_hashes: ?[][32]u8,
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
            .merkle_jobs = std.ArrayList(MerkleJob).empty,
            .merkle_results = std.ArrayList(MerkleResult).empty,
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

        // Clean up Merkle job/result queues
        self.merkle_jobs.deinit(self.allocator);
        for (self.merkle_results.items) |result| {
            if (result.piece_hashes) |hashes| {
                self.allocator.free(hashes);
            }
        }
        self.merkle_results.deinit(self.allocator);

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
        torrent_id: u32,
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

    /// Submit a Merkle tree building job (BEP 52). The worker thread reads
    /// piece data from disk and computes SHA-256 hashes for the file's pieces.
    /// Called from the event loop thread. Does not block.
    pub fn submitMerkleJob(
        self: *Hasher,
        torrent_id: u32,
        file_index: u32,
        first_piece: u32,
        piece_count: u32,
        layout: *const Layout,
        shared_fds: []const posix.fd_t,
    ) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.merkle_jobs.append(self.allocator, .{
            .torrent_id = torrent_id,
            .file_index = file_index,
            .first_piece = first_piece,
            .piece_count = piece_count,
            .layout = layout,
            .shared_fds = shared_fds,
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

    /// Atomically drain completed Merkle tree building results.
    /// Called from the event loop thread. Works like drainResultsInto.
    pub fn drainMerkleResultsInto(self: *Hasher, swap_buf: *std.ArrayList(MerkleResult)) []const MerkleResult {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        const tmp = self.merkle_results;
        self.merkle_results = swap_buf.*;
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
            if (self.merkle_jobs.items.len > 0) return true;
        }
        {
            self.result_mutex.lock();
            defer self.result_mutex.unlock();
            if (self.completed_results.items.len > 0) return true;
            if (self.merkle_results.items.len > 0) return true;
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
            // Wait for any job (piece verify or Merkle)
            self.queue_mutex.lock();
            while (self.pending_jobs.items.len == 0 and
                self.merkle_jobs.items.len == 0 and
                self.running.load(.acquire))
            {
                self.queue_cond.timedWait(&self.queue_mutex, 1 * std.time.ns_per_s) catch {};
            }

            // Try Merkle job first (less frequent, higher value per job)
            if (self.merkle_jobs.items.len > 0) {
                const mjob = self.merkle_jobs.orderedRemove(0);
                _ = self.in_flight.fetchAdd(1, .acq_rel);
                self.queue_mutex.unlock();

                self.processMerkleJob(mjob);

                _ = self.in_flight.fetchSub(1, .acq_rel);
                if (self.event_fd >= 0) {
                    const val: u64 = 1;
                    _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch {};
                }
                continue;
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

    /// Process a Merkle tree building job: read piece data from disk and
    /// compute SHA-256 hashes for every piece in the file's range.
    /// Runs on a worker thread -- disk I/O via pread is acceptable here
    /// (not on the event loop thread).
    fn processMerkleJob(self: *Hasher, job: MerkleJob) void {
        const hashes = self.allocator.alloc([32]u8, job.piece_count) catch {
            self.pushMerkleResult(.{
                .torrent_id = job.torrent_id,
                .file_index = job.file_index,
                .piece_hashes = null,
            });
            return;
        };

        var success = true;
        for (0..job.piece_count) |i| {
            const global_piece = job.first_piece + @as(u32, @intCast(i));
            const piece_size = job.layout.pieceSize(global_piece) catch {
                success = false;
                break;
            };

            const buf = self.allocator.alloc(u8, piece_size) catch {
                success = false;
                break;
            };
            defer self.allocator.free(buf);

            // v2 pieces are file-aligned: always exactly 1 span
            var span_buf: [8]Layout.Span = undefined;
            const spans = job.layout.mapPiece(global_piece, &span_buf) catch {
                success = false;
                break;
            };

            var total_read: usize = 0;
            for (spans) |span| {
                if (span.file_index >= job.shared_fds.len) {
                    success = false;
                    break;
                }
                const fd = job.shared_fds[span.file_index];
                if (fd < 0) {
                    success = false;
                    break;
                }

                const dest = buf[span.piece_offset..][0..span.length];
                const n = posix.pread(fd, dest, span.file_offset) catch {
                    success = false;
                    break;
                };
                if (n != span.length) {
                    success = false;
                    break;
                }
                total_read += n;
            }

            if (!success) break;
            if (total_read != piece_size) {
                success = false;
                break;
            }

            Sha256.hash(buf, &hashes[i], .{});
        }

        if (!success) {
            self.allocator.free(hashes);
            self.pushMerkleResult(.{
                .torrent_id = job.torrent_id,
                .file_index = job.file_index,
                .piece_hashes = null,
            });
            return;
        }

        self.pushMerkleResult(.{
            .torrent_id = job.torrent_id,
            .file_index = job.file_index,
            .piece_hashes = hashes,
        });
    }

    /// Push a Merkle result onto the result queue (called from worker thread).
    fn pushMerkleResult(self: *Hasher, result: MerkleResult) void {
        self.result_mutex.lock();
        self.merkle_results.append(self.allocator, result) catch {
            // OOM: free hashes if present
            if (result.piece_hashes) |h| self.allocator.free(h);
            std.log.err("hasher: OOM appending merkle result for file {d}", .{result.file_index});
            self.result_mutex.unlock();
            return;
        };
        self.result_mutex.unlock();
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

test "merkle job hashes file pieces from disk" {
    const allocator = std.testing.allocator;

    var hasher = Hasher.create(allocator, 2) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    // Create a temp file with 2 pieces of known data
    const piece_len: u32 = 64;
    const piece0_data = "A" ** piece_len;
    const piece1_data = "B" ** piece_len;

    const tmp_path = "/tmp/varuna_merkle_test";
    const file = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch
        return error.SkipZigTest;
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    _ = file.write(piece0_data) catch return error.SkipZigTest;
    _ = file.write(piece1_data) catch return error.SkipZigTest;
    const fd = file.handle;
    defer file.close();

    // Build a minimal v2 layout for 1 file, 2 pieces
    const metainfo_mod = @import("../torrent/metainfo.zig");
    var files = [_]Layout.File{
        .{
            .length = piece_len * 2,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 2,
            .path = &.{},
            .v2_piece_offset = 0,
        },
    };
    var v2_files = [_]metainfo_mod.V2File{
        .{ .path = &.{}, .length = piece_len * 2, .pieces_root = [_]u8{0} ** 32 },
    };
    var layout = Layout{
        .piece_length = piece_len,
        .piece_count = 2,
        .total_size = piece_len * 2,
        .files = &files,
        .piece_hashes = "",
        .version = .v2,
        .v2_files = &v2_files,
    };

    const shared_fds = [_]posix.fd_t{fd};

    // Submit a Merkle job
    try hasher.submitMerkleJob(0, 0, 0, 2, &layout, &shared_fds);

    // Wait for results
    var swap_buf = std.ArrayList(Hasher.MerkleResult).empty;
    defer swap_buf.deinit(allocator);

    var attempts: u32 = 0;
    var got_result = false;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const results = hasher.drainMerkleResultsInto(&swap_buf);
        if (results.len > 0) {
            try std.testing.expectEqual(@as(usize, 1), results.len);
            const result = results[0];
            try std.testing.expectEqual(@as(u32, 0), result.torrent_id);
            try std.testing.expectEqual(@as(u32, 0), result.file_index);
            try std.testing.expect(result.piece_hashes != null);

            const hashes = result.piece_hashes.?;
            defer allocator.free(hashes);
            try std.testing.expectEqual(@as(usize, 2), hashes.len);

            // Verify the hashes match SHA-256 of the piece data
            var expected0: [32]u8 = undefined;
            Sha256.hash(piece0_data, &expected0, .{});
            try std.testing.expectEqual(expected0, hashes[0]);

            var expected1: [32]u8 = undefined;
            Sha256.hash(piece1_data, &expected1, .{});
            try std.testing.expectEqual(expected1, hashes[1]);

            got_result = true;
            break;
        }
        swap_buf.clearRetainingCapacity();
    }
    try std.testing.expect(got_result);
}

test "merkle job returns null hashes on bad fd" {
    const allocator = std.testing.allocator;

    var hasher = Hasher.create(allocator, 1) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    const metainfo_mod = @import("../torrent/metainfo.zig");
    var files = [_]Layout.File{
        .{
            .length = 64,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 1,
            .path = &.{},
            .v2_piece_offset = 0,
        },
    };
    var v2_files = [_]metainfo_mod.V2File{
        .{ .path = &.{}, .length = 64, .pieces_root = [_]u8{0} ** 32 },
    };
    var layout = Layout{
        .piece_length = 64,
        .piece_count = 1,
        .total_size = 64,
        .files = &files,
        .piece_hashes = "",
        .version = .v2,
        .v2_files = &v2_files,
    };

    // Use an invalid fd
    const shared_fds = [_]posix.fd_t{-1};
    try hasher.submitMerkleJob(0, 0, 0, 1, &layout, &shared_fds);

    var swap_buf = std.ArrayList(Hasher.MerkleResult).empty;
    defer swap_buf.deinit(allocator);

    var attempts: u32 = 0;
    var got_result = false;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        const results = hasher.drainMerkleResultsInto(&swap_buf);
        if (results.len > 0) {
            try std.testing.expectEqual(@as(usize, 1), results.len);
            // Should fail with null piece_hashes due to bad fd
            try std.testing.expect(results[0].piece_hashes == null);
            got_result = true;
            break;
        }
        swap_buf.clearRetainingCapacity();
    }
    try std.testing.expect(got_result);
}

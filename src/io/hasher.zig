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
///
/// **Production hasher.** Sim tests should use `SimHasher` (added in a
/// follow-up commit) wrapped by the tagged-union `Hasher` variant; this
/// `RealHasher` struct retains the historical thread-pool semantics for
/// the daemon path.
pub const RealHasher = struct {
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
        is_recheck: bool = false,
    };

    pub const Result = struct {
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        valid: bool,
        torrent_id: u32,
        is_recheck: bool = false,
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

    /// Create a heap-allocated RealHasher. Must be heap-allocated because
    /// worker threads hold pointers to it.
    ///
    /// `thread_count == 0` selects the **inline mode**: no worker threads
    /// are spawned, and `submitVerify` / `submitMerkleJob` process the
    /// job synchronously on the calling thread before returning. This is
    /// for sim tests that want deterministic step-driven hash results.
    pub fn create(allocator: std.mem.Allocator, thread_count: ?u32) !*RealHasher {
        const count = thread_count orelse default_thread_count;
        const efd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(efd);

        const self = try allocator.create(RealHasher);
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

    /// Whether this RealHasher runs in inline mode (no worker threads).
    inline fn isInline(self: *const RealHasher) bool {
        return self.threads.len == 0;
    }

    pub fn deinit(self: *RealHasher) void {
        self.running.store(false, .release);
        self.queue_cond.broadcast();

        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);

        for (self.pending_jobs.items) |job| {
            self.allocator.free(job.piece_buf);
        }
        self.pending_jobs.deinit(self.allocator);

        // Defensive: free EVERY piece_buf in completed_results, not
        // just the invalid ones. In the production path,
        // peer_policy.processHashResults drains valid results into
        // pending_writes (and that loop frees the bufs after the disk
        // write fires). But on shutdown — tests calling deinit directly,
        // graceful drains that timed out, crash paths — completed_results
        // may still hold valid bufs the EL never got around to processing.
        // Without this defensive free, those bufs leak (EventLoop.deinit
        // destroys the RealHasher before its own drain phase can run).
        // Losing the verified data on disk is acceptable in shutdown;
        // leaking the buffer is not.
        for (self.completed_results.items) |result| {
            self.allocator.free(result.piece_buf);
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

    pub const VerifyOptions = struct {
        hash_type: HashType = .sha1,
        expected_hash_v2: [32]u8 = [_]u8{0} ** 32,
        is_recheck: bool = false,
    };

    /// Submit a piece for background SHA verification.
    /// Called from the event loop thread. Does not block.
    pub fn submitVerify(
        self: *RealHasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
    ) !void {
        return self.submitVerifyEx(slot, piece_index, piece_buf, expected_hash, torrent_id, .{});
    }

    /// Submit a piece for verification with extended options (hash type, recheck flag).
    pub fn submitVerifyEx(
        self: *RealHasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
        opts: VerifyOptions,
    ) !void {
        const job = Job{
            .slot = slot,
            .piece_index = piece_index,
            .piece_buf = piece_buf,
            .piece_length = @intCast(piece_buf.len),
            .expected_hash = expected_hash,
            .expected_hash_v2 = opts.expected_hash_v2,
            .hash_type = opts.hash_type,
            .torrent_id = torrent_id,
            .is_recheck = opts.is_recheck,
        };

        if (self.isInline()) {
            // Process synchronously on the caller's thread and push the
            // result directly. Sim tests drain via `drainResultsInto`
            // on the next tick.
            const valid = computeValid(job);
            self.result_mutex.lock();
            defer self.result_mutex.unlock();
            try self.completed_results.append(self.allocator, .{
                .slot = job.slot,
                .piece_index = job.piece_index,
                .piece_buf = job.piece_buf,
                .valid = valid,
                .torrent_id = job.torrent_id,
                .is_recheck = job.is_recheck,
            });
            return;
        }

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.pending_jobs.append(self.allocator, job);
        self.queue_cond.signal();
    }

    fn computeValid(job: Job) bool {
        return switch (job.hash_type) {
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
    }

    /// Submit a Merkle tree building job (BEP 52). The worker thread reads
    /// piece data from disk and computes SHA-256 hashes for the file's pieces.
    /// Called from the event loop thread. Does not block.
    pub fn submitMerkleJob(
        self: *RealHasher,
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
    pub fn drainResultsInto(self: *RealHasher, swap_buf: *std.ArrayList(Result)) []const Result {
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
    pub fn drainMerkleResultsInto(self: *RealHasher, swap_buf: *std.ArrayList(MerkleResult)) []const MerkleResult {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        const tmp = self.merkle_results;
        self.merkle_results = swap_buf.*;
        swap_buf.* = tmp;

        return swap_buf.items;
    }

    /// Returns true if there are pending jobs, in-flight hashes, or unread results.
    /// Called from the event loop thread to decide whether draining is complete.
    pub fn hasPendingWork(self: *RealHasher) bool {
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

    pub fn getEventFd(self: *RealHasher) posix.fd_t {
        return self.event_fd;
    }

    pub fn threadCount(self: *const RealHasher) usize {
        return self.threads.len;
    }

    fn workerFn(self: *RealHasher) void {
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
            const valid = computeValid(job);

            // Push result
            self.result_mutex.lock();
            self.completed_results.append(self.allocator, .{
                .slot = job.slot,
                .piece_index = job.piece_index,
                .piece_buf = job.piece_buf,
                .valid = valid,
                .torrent_id = job.torrent_id,
                .is_recheck = job.is_recheck,
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
    fn processMerkleJob(self: *RealHasher, job: MerkleJob) void {
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
    fn pushMerkleResult(self: *RealHasher, result: MerkleResult) void {
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

/// Deterministic, single-threaded hasher for simulation tests.
///
/// Mirrors `RealHasher`'s public surface (`submitVerify`,
/// `submitVerifyEx`, `submitMerkleJob`, `drainResultsInto`,
/// `drainMerkleResultsInto`, `hasPendingWork`, `getEventFd`,
/// `threadCount`, `deinit`) so the tagged-union `Hasher` (next commit)
/// can dispatch on the active variant without consumers caring which
/// backend they hold.
///
/// ## Design
///
/// Submissions hash synchronously on the caller (event-loop) thread and
/// push the result onto an internal queue. The next call to
/// `drainResultsInto` returns the queued results — the same shape as
/// the real hasher, just without the worker-thread hop.  Sim tests
/// already invoke `peer_policy.processHashResults` (which calls
/// `drainResultsInto`) on every event-loop tick, so a result submitted
/// during tick N is visible during tick N+1's drain — close enough to
/// the real hasher's "best-case" latency to match the production
/// timing model.
///
/// ## Why not spawn real threads in tests
///
/// The single-daemon-deterministic simulation model
/// (`SimulatorOf(EventLoopOf(SimIO))`) cannot sequence work that
/// happens on background OS threads. SimHasher closes the last
/// thread-spawn nondeterminism boundary after SimClock + SimRandom
/// landed — every byte that comes out of a sim test now derives
/// deterministically from the seed.
///
/// ## Fault injection
///
/// `FaultConfig.merkle_pread_fault_prob` lets tests simulate pread
/// failures during Merkle tree building. Verification jobs can also be
/// delayed by drain ticks, so tests can force late hash completions
/// after other simulated I/O events have advanced. The knobs are
/// consulted by a caller-supplied seeded `runtime.Random`-style PRNG
/// so two test runs with the same seed produce the same fault sequence.
const DelayedVerifyResult = struct {
    ready_drain_tick: u64,
    result: RealHasher.Result,
};

pub const SimHasher = struct {
    allocator: std.mem.Allocator,

    /// Pending verification results — drained by the EL on the next
    /// tick via `drainResultsInto`. Submitted synchronously, so this
    /// list grows during a single tick and shrinks at the next drain.
    completed_results: std.ArrayList(RealHasher.Result),

    /// Verification results intentionally held back for fault-injection
    /// scenarios. They promote to `completed_results` once the drain
    /// tick reaches `ready_drain_tick`.
    delayed_results: std.ArrayList(DelayedVerifyResult),

    /// Pending Merkle results — same lifecycle as `completed_results`,
    /// drained via `drainMerkleResultsInto`.
    merkle_results: std.ArrayList(RealHasher.MerkleResult),

    /// Fault-injection configuration. Defaults to no faults.
    faults: FaultConfig = .{},

    /// Seeded PRNG used to roll fault-injection probabilities. Mirrors
    /// `runtime.Random`'s `.sim` variant so two test runs with the
    /// same seed produce the same fault sequence. Caller seeds via
    /// `init` or `setSeed` before running the test.
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    /// Logical drain tick for delayed verification results. Incremented
    /// once per `drainResultsInto` call.
    drain_tick: u64 = 0,

    pub const FaultConfig = struct {
        /// Probability ([0.0, 1.0]) that a given pread call inside a
        /// Merkle build job is treated as failed. The job returns
        /// `piece_hashes = null` in the result, mirroring the real
        /// hasher's behaviour when a pread fails. 0 disables.
        merkle_pread_fault_prob: f32 = 0.0,

        /// Inclusive min/max drain-tick delay for verification
        /// completions. With the defaults, verify results are available
        /// on the next drain exactly as before.
        verify_result_delay_ticks_min: u32 = 0,
        verify_result_delay_ticks_max: u32 = 0,
    };

    /// Initialise a heap-allocated SimHasher. Heap allocation matches
    /// the production hasher's lifecycle (callers store `?*Hasher`)
    /// and lets `deinit` mirror the production destruction shape
    /// (caller calls `destroy` on the allocator after `deinit`).
    pub fn create(allocator: std.mem.Allocator, seed: u64) !*SimHasher {
        const self = try allocator.create(SimHasher);
        self.* = .{
            .allocator = allocator,
            .completed_results = .empty,
            .delayed_results = .empty,
            .merkle_results = .empty,
            .rng = std.Random.DefaultPrng.init(seed),
        };
        return self;
    }

    pub fn deinit(self: *SimHasher) void {
        // Mirror RealHasher's defensive cleanup: free EVERY
        // outstanding piece_buf in case shutdown beat the EL drain.
        for (self.completed_results.items) |result| {
            self.allocator.free(result.piece_buf);
        }
        self.completed_results.deinit(self.allocator);

        for (self.delayed_results.items) |delayed| {
            self.allocator.free(delayed.result.piece_buf);
        }
        self.delayed_results.deinit(self.allocator);

        for (self.merkle_results.items) |result| {
            if (result.piece_hashes) |hashes| {
                self.allocator.free(hashes);
            }
        }
        self.merkle_results.deinit(self.allocator);
    }

    /// Replace the fault-injection PRNG seed. Tests that share a
    /// SimHasher across scenarios call this between runs to reset the
    /// fault sequence.
    pub fn setSeed(self: *SimHasher, seed: u64) void {
        self.rng = std.Random.DefaultPrng.init(seed);
    }

    /// Replace the fault-injection configuration. No-op effect on
    /// already-queued results.
    pub fn setFaults(self: *SimHasher, faults: FaultConfig) void {
        self.faults = faults;
    }

    pub fn submitVerify(
        self: *SimHasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
    ) !void {
        return self.submitVerifyEx(slot, piece_index, piece_buf, expected_hash, torrent_id, .{});
    }

    pub fn submitVerifyEx(
        self: *SimHasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
        opts: RealHasher.VerifyOptions,
    ) !void {
        const job = RealHasher.Job{
            .slot = slot,
            .piece_index = piece_index,
            .piece_buf = piece_buf,
            .piece_length = @intCast(piece_buf.len),
            .expected_hash = expected_hash,
            .expected_hash_v2 = opts.expected_hash_v2,
            .hash_type = opts.hash_type,
            .torrent_id = torrent_id,
            .is_recheck = opts.is_recheck,
        };
        const valid = RealHasher.computeValid(job);
        const result = RealHasher.Result{
            .slot = slot,
            .piece_index = piece_index,
            .piece_buf = piece_buf,
            .valid = valid,
            .torrent_id = torrent_id,
            .is_recheck = opts.is_recheck,
        };

        const delay_ticks = self.verifyResultDelayTicks();
        if (delay_ticks == 0) {
            try self.completed_results.append(self.allocator, result);
        } else {
            try self.delayed_results.append(self.allocator, .{
                .ready_drain_tick = self.drain_tick + delay_ticks,
                .result = result,
            });
        }
    }

    pub fn submitMerkleJob(
        self: *SimHasher,
        torrent_id: u32,
        file_index: u32,
        first_piece: u32,
        piece_count: u32,
        layout: *const Layout,
        shared_fds: []const posix.fd_t,
    ) !void {
        const job = RealHasher.MerkleJob{
            .torrent_id = torrent_id,
            .file_index = file_index,
            .first_piece = first_piece,
            .piece_count = piece_count,
            .layout = layout,
            .shared_fds = shared_fds,
        };
        // Run the same body the real worker runs, just on the caller's
        // thread. The fault knob is consulted before each pread.
        const result = self.processMerkleJob(job);
        try self.merkle_results.append(self.allocator, result);
    }

    fn processMerkleJob(self: *SimHasher, job: RealHasher.MerkleJob) RealHasher.MerkleResult {
        const hashes = self.allocator.alloc([32]u8, job.piece_count) catch {
            return .{
                .torrent_id = job.torrent_id,
                .file_index = job.file_index,
                .piece_hashes = null,
            };
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

            var span_buf: [8]Layout.Span = undefined;
            const spans = job.layout.mapPiece(global_piece, &span_buf) catch {
                success = false;
                break;
            };

            var total_read: usize = 0;
            var span_failed = false;
            for (spans) |span| {
                if (span.file_index >= job.shared_fds.len) {
                    span_failed = true;
                    break;
                }
                const fd = job.shared_fds[span.file_index];
                if (fd < 0) {
                    span_failed = true;
                    break;
                }

                if (self.shouldInjectMerklePreadFault()) {
                    span_failed = true;
                    break;
                }

                const dest = buf[span.piece_offset..][0..span.length];
                const n = posix.pread(fd, dest, span.file_offset) catch {
                    span_failed = true;
                    break;
                };
                if (n != span.length) {
                    span_failed = true;
                    break;
                }
                total_read += n;
            }

            if (span_failed) {
                success = false;
                break;
            }
            if (total_read != piece_size) {
                success = false;
                break;
            }

            Sha256.hash(buf, &hashes[i], .{});
        }

        if (!success) {
            self.allocator.free(hashes);
            return .{
                .torrent_id = job.torrent_id,
                .file_index = job.file_index,
                .piece_hashes = null,
            };
        }

        return .{
            .torrent_id = job.torrent_id,
            .file_index = job.file_index,
            .piece_hashes = hashes,
        };
    }

    fn shouldInjectMerklePreadFault(self: *SimHasher) bool {
        if (self.faults.merkle_pread_fault_prob <= 0.0) return false;
        const roll = self.rng.random().float(f32);
        return roll < self.faults.merkle_pread_fault_prob;
    }

    fn verifyResultDelayTicks(self: *SimHasher) u32 {
        const min = self.faults.verify_result_delay_ticks_min;
        const max = self.faults.verify_result_delay_ticks_max;
        if (max <= min) return min;
        const span = max - min;
        return min + self.rng.random().uintLessThan(u32, span + 1);
    }

    fn promoteReadyVerifyResults(self: *SimHasher) void {
        self.drain_tick += 1;

        var i: usize = 0;
        while (i < self.delayed_results.items.len) {
            if (self.delayed_results.items[i].ready_drain_tick <= self.drain_tick) {
                const delayed = self.delayed_results.orderedRemove(i);
                self.completed_results.append(self.allocator, delayed.result) catch unreachable;
            } else {
                i += 1;
            }
        }
    }

    pub fn drainResultsInto(
        self: *SimHasher,
        swap_buf: *std.ArrayList(RealHasher.Result),
    ) []const RealHasher.Result {
        self.promoteReadyVerifyResults();
        const tmp = self.completed_results;
        self.completed_results = swap_buf.*;
        swap_buf.* = tmp;
        return swap_buf.items;
    }

    pub fn drainMerkleResultsInto(
        self: *SimHasher,
        swap_buf: *std.ArrayList(RealHasher.MerkleResult),
    ) []const RealHasher.MerkleResult {
        const tmp = self.merkle_results;
        self.merkle_results = swap_buf.*;
        swap_buf.* = tmp;
        return swap_buf.items;
    }

    pub fn hasPendingWork(self: *SimHasher) bool {
        return self.completed_results.items.len > 0 or
            self.delayed_results.items.len > 0 or
            self.merkle_results.items.len > 0;
    }

    /// Sim hasher has no eventfd — return the conventional "no fd"
    /// sentinel.  Callers that wire eventfd into io_uring (the daemon
    /// path) should not be invoking this on a sim hasher; the
    /// tagged-union `Hasher` will route around it.
    pub fn getEventFd(_: *SimHasher) posix.fd_t {
        return -1;
    }

    /// Sim hasher spawns no threads. Returned for parity with
    /// `RealHasher.threadCount` so callers can probe the active backend.
    pub fn threadCount(_: *const SimHasher) usize {
        return 0;
    }
};

/// Tagged-union dispatcher over `RealHasher` (production thread pool)
/// and `SimHasher` (deterministic single-threaded compute for sim
/// tests). Mirrors `runtime.Clock` / `runtime.Random`'s tagged-union
/// shape (Real / Sim variants under one type; consumers stay on the
/// alias and the simulator drives everything off a seed).
///
/// ## Why pointers in the variants
///
/// `RealHasher` workers hold a pointer to their parent struct, so the
/// parent's address must be stable for the lifetime of the pool. A
/// tagged union of values would put `RealHasher` inline inside the
/// Hasher allocation — moving a `Hasher` value (an assignment, a
/// return-by-value, even a defensive `var local = h.*`) would relocate
/// the workers' parent. Pointers in each variant sidestep that
/// entirely: the inner struct keeps the address it was created at,
/// the union just discriminates between pool kinds. SimHasher carries
/// the pointer for symmetry — the dispatch layer treats both backends
/// the same.
pub const Hasher = union(enum) {
    real: *RealHasher,
    sim: *SimHasher,

    // ── Type re-exports ────────────────────────────────────
    // Consumers continue to write `Hasher.Result` / `Hasher.MerkleResult`
    // / `Hasher.VerifyOptions`; both backends share the same record
    // shapes so we just hoist them up to the union.
    pub const Result = RealHasher.Result;
    pub const MerkleResult = RealHasher.MerkleResult;
    pub const Job = RealHasher.Job;
    pub const MerkleJob = RealHasher.MerkleJob;
    pub const VerifyOptions = RealHasher.VerifyOptions;

    // ── Lifecycle ──────────────────────────────────────────

    /// Heap-allocate a Hasher backed by the production thread pool.
    /// Match RealHasher.create's existing semantics — caller frees the
    /// outer `*Hasher` with `allocator.destroy` after `deinit`.
    pub fn realInit(allocator: std.mem.Allocator, thread_count: u32) !*Hasher {
        const inner = try RealHasher.create(allocator, thread_count);
        errdefer {
            inner.deinit();
            allocator.destroy(inner);
        }
        const self = try allocator.create(Hasher);
        self.* = .{ .real = inner };
        return self;
    }

    /// Heap-allocate a Hasher backed by the deterministic sim hasher.
    /// `seed` drives the fault-injection PRNG — use the same seed your
    /// sim test driver uses everywhere else for reproducibility.
    pub fn simInit(allocator: std.mem.Allocator, seed: u64) !*Hasher {
        const inner = try SimHasher.create(allocator, seed);
        errdefer {
            inner.deinit();
            allocator.destroy(inner);
        }
        const self = try allocator.create(Hasher);
        self.* = .{ .sim = inner };
        return self;
    }

    /// Tear down the active variant and its inner allocation. The
    /// caller must call `allocator.destroy(self)` after this returns
    /// to free the outer union itself — same shape as the previous
    /// `RealHasher.deinit + destroy` pattern.
    pub fn deinit(self: *Hasher) void {
        switch (self.*) {
            .real => |h| {
                const a = h.allocator;
                h.deinit();
                a.destroy(h);
            },
            .sim => |h| {
                const a = h.allocator;
                h.deinit();
                a.destroy(h);
            },
        }
    }

    // ── Inner-pointer escape hatches ───────────────────────

    /// Return the production hasher pointer if this Hasher is `.real`,
    /// otherwise null. Reserved for sites that need production-only
    /// APIs (e.g. eventfd integration with io_uring); the sim backend
    /// never has an eventfd to register.
    pub fn realInner(self: *Hasher) ?*RealHasher {
        return switch (self.*) {
            .real => |h| h,
            .sim => null,
        };
    }

    /// Return the sim hasher pointer if this Hasher is `.sim`,
    /// otherwise null. Sim tests use this to reach `setFaults` /
    /// `setSeed` without pattern-matching the union themselves.
    pub fn simInner(self: *Hasher) ?*SimHasher {
        return switch (self.*) {
            .real => null,
            .sim => |h| h,
        };
    }

    // ── Submission ─────────────────────────────────────────

    pub fn submitVerify(
        self: *Hasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
    ) !void {
        switch (self.*) {
            .real => |h| return h.submitVerify(slot, piece_index, piece_buf, expected_hash, torrent_id),
            .sim => |h| return h.submitVerify(slot, piece_index, piece_buf, expected_hash, torrent_id),
        }
    }

    pub fn submitVerifyEx(
        self: *Hasher,
        slot: u16,
        piece_index: u32,
        piece_buf: []u8,
        expected_hash: [20]u8,
        torrent_id: u32,
        opts: VerifyOptions,
    ) !void {
        switch (self.*) {
            .real => |h| return h.submitVerifyEx(slot, piece_index, piece_buf, expected_hash, torrent_id, opts),
            .sim => |h| return h.submitVerifyEx(slot, piece_index, piece_buf, expected_hash, torrent_id, opts),
        }
    }

    pub fn submitMerkleJob(
        self: *Hasher,
        torrent_id: u32,
        file_index: u32,
        first_piece: u32,
        piece_count: u32,
        layout: *const Layout,
        shared_fds: []const posix.fd_t,
    ) !void {
        switch (self.*) {
            .real => |h| return h.submitMerkleJob(torrent_id, file_index, first_piece, piece_count, layout, shared_fds),
            .sim => |h| return h.submitMerkleJob(torrent_id, file_index, first_piece, piece_count, layout, shared_fds),
        }
    }

    // ── Drain ──────────────────────────────────────────────

    pub fn drainResultsInto(self: *Hasher, swap_buf: *std.ArrayList(Result)) []const Result {
        switch (self.*) {
            .real => |h| return h.drainResultsInto(swap_buf),
            .sim => |h| return h.drainResultsInto(swap_buf),
        }
    }

    pub fn drainMerkleResultsInto(self: *Hasher, swap_buf: *std.ArrayList(MerkleResult)) []const MerkleResult {
        switch (self.*) {
            .real => |h| return h.drainMerkleResultsInto(swap_buf),
            .sim => |h| return h.drainMerkleResultsInto(swap_buf),
        }
    }

    // ── Probes ─────────────────────────────────────────────

    pub fn hasPendingWork(self: *Hasher) bool {
        switch (self.*) {
            .real => |h| return h.hasPendingWork(),
            .sim => |h| return h.hasPendingWork(),
        }
    }

    pub fn getEventFd(self: *Hasher) posix.fd_t {
        switch (self.*) {
            .real => |h| return h.getEventFd(),
            .sim => |h| return h.getEventFd(),
        }
    }

    pub fn threadCount(self: *const Hasher) usize {
        switch (self.*) {
            .real => |h| return h.threadCount(),
            .sim => |h| return h.threadCount(),
        }
    }
};

test "hasher pool verifies pieces correctly" {
    var hasher = RealHasher.create(std.testing.allocator, 2) catch return error.SkipZigTest;
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
    var swap_buf = std.ArrayList(RealHasher.Result).empty;
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
    var hasher = RealHasher.create(std.testing.allocator, 8) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        std.testing.allocator.destroy(hasher);
    }

    try std.testing.expectEqual(@as(usize, 8), hasher.threadCount());
}

test "merkle job hashes file pieces from disk" {
    const allocator = std.testing.allocator;

    var hasher = RealHasher.create(allocator, 2) catch return error.SkipZigTest;
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    // Create a temp file with 2 pieces of known data, in a tmpDir so
    // parallel test runs (and stale leftovers in /tmp) don't collide.
    const piece_len: u32 = 64;
    const piece0_data = "A" ** piece_len;
    const piece1_data = "B" ** piece_len;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Read access is required because the merkle worker reads back via
    // pread on the same fd. Default createFile opens write-only, which
    // returned error.NotOpenForReading from the worker.
    const file = tmp_dir.dir.createFile("merkle_test", .{ .truncate = true, .read = true }) catch
        return error.SkipZigTest;
    defer file.close();
    file.writeAll(piece0_data) catch return error.SkipZigTest;
    file.writeAll(piece1_data) catch return error.SkipZigTest;
    const fd = file.handle;

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
    var swap_buf = std.ArrayList(RealHasher.MerkleResult).empty;
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

    var hasher = RealHasher.create(allocator, 1) catch return error.SkipZigTest;
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

    var swap_buf = std.ArrayList(RealHasher.MerkleResult).empty;
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

// ── SimHasher tests ─────────────────────────────────────────

test "SimHasher: same input produces same valid/invalid verdict (determinism)" {
    const allocator = std.testing.allocator;

    inline for ([_]u64{ 0, 0xdeadbeef, 0xfeedface }) |seed| {
        var hasher = try SimHasher.create(allocator, seed);
        defer {
            hasher.deinit();
            allocator.destroy(hasher);
        }

        // Submit a piece whose data hashes to the expected value
        const data1 = try allocator.alloc(u8, 4);
        @memcpy(data1, "spam");
        var expected1: [20]u8 = undefined;
        Sha1.hash("spam", &expected1, .{});
        try hasher.submitVerify(0, 0, data1, expected1, 0);

        // And a piece whose data does NOT hash to the expected value
        const data2 = try allocator.alloc(u8, 4);
        @memcpy(data2, "eggs");
        var expected2: [20]u8 = undefined;
        Sha1.hash("spam", &expected2, .{}); // wrong hash for "eggs"
        try hasher.submitVerify(1, 1, data2, expected2, 0);

        // Drain — should fire immediately because submit is synchronous
        var swap_buf = std.ArrayList(RealHasher.Result).empty;
        defer swap_buf.deinit(allocator);
        const results = hasher.drainResultsInto(&swap_buf);
        try std.testing.expectEqual(@as(usize, 2), results.len);

        // Order is deterministic: submit order is preserved (no
        // worker-thread interleave to randomise it).
        try std.testing.expectEqual(@as(u32, 0), results[0].piece_index);
        try std.testing.expect(results[0].valid);
        allocator.free(results[0].piece_buf);

        try std.testing.expectEqual(@as(u32, 1), results[1].piece_index);
        try std.testing.expect(!results[1].valid);
        allocator.free(results[1].piece_buf);
    }
}

test "SimHasher: spawns no real threads" {
    const allocator = std.testing.allocator;

    // Sanity: SimHasher's create path must not call std.Thread.spawn.
    // We can't easily intercept Thread.spawn, but we can assert the
    // public-surface invariants: threadCount == 0 and getEventFd() returns -1.
    var hasher = try SimHasher.create(allocator, 0);
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    try std.testing.expectEqual(@as(usize, 0), hasher.threadCount());
    try std.testing.expectEqual(@as(posix.fd_t, -1), hasher.getEventFd());
}

test "SimHasher: results visible on next drain (queue lifecycle)" {
    const allocator = std.testing.allocator;

    var hasher = try SimHasher.create(allocator, 1);
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    var swap_buf = std.ArrayList(RealHasher.Result).empty;
    defer swap_buf.deinit(allocator);

    // Pre-submit: drain returns nothing.
    {
        const results = hasher.drainResultsInto(&swap_buf);
        try std.testing.expectEqual(@as(usize, 0), results.len);
    }
    swap_buf.clearRetainingCapacity();

    // Submit one piece — hasPendingWork should be true.
    const data = try allocator.alloc(u8, 4);
    @memcpy(data, "spam");
    var expected: [20]u8 = undefined;
    Sha1.hash("spam", &expected, .{});
    try hasher.submitVerify(0, 0, data, expected, 0);

    try std.testing.expect(hasher.hasPendingWork());

    // Drain — result is visible, queue empties.
    {
        const results = hasher.drainResultsInto(&swap_buf);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expect(results[0].valid);
        allocator.free(results[0].piece_buf);
    }
    swap_buf.clearRetainingCapacity();
    try std.testing.expect(!hasher.hasPendingWork());
}

test "SimHasher: verify results can be delayed by drain ticks" {
    const allocator = std.testing.allocator;

    var hasher = try SimHasher.create(allocator, 1);
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }
    hasher.setFaults(.{
        .verify_result_delay_ticks_min = 2,
        .verify_result_delay_ticks_max = 2,
    });

    var swap_buf = std.ArrayList(RealHasher.Result).empty;
    defer swap_buf.deinit(allocator);

    const data = try allocator.alloc(u8, 4);
    @memcpy(data, "spam");
    var expected: [20]u8 = undefined;
    Sha1.hash("spam", &expected, .{});
    try hasher.submitVerify(0, 0, data, expected, 0);

    try std.testing.expect(hasher.hasPendingWork());

    {
        const results = hasher.drainResultsInto(&swap_buf);
        try std.testing.expectEqual(@as(usize, 0), results.len);
    }
    swap_buf.clearRetainingCapacity();
    try std.testing.expect(hasher.hasPendingWork());

    {
        const results = hasher.drainResultsInto(&swap_buf);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expect(results[0].valid);
        allocator.free(results[0].piece_buf);
    }
    swap_buf.clearRetainingCapacity();
    try std.testing.expect(!hasher.hasPendingWork());
}

test "SimHasher: deinit defensively frees outstanding piece bufs" {
    // Mirrors the production hasher's defensive deinit (regression for
    // the leak that motivated event_loop_health_test's third test).
    // testing.allocator panics on leaks; without the cleanup this would
    // leak the piece_buf submitted but never drained.
    var hasher = try SimHasher.create(std.testing.allocator, 0);

    const data = try std.testing.allocator.alloc(u8, 4);
    @memcpy(data, "spam");
    var expected: [20]u8 = undefined;
    Sha1.hash("spam", &expected, .{});
    try hasher.submitVerify(0, 0, data, expected, 0);

    // Skip drain — deinit must free `data` itself.
    hasher.deinit();
    std.testing.allocator.destroy(hasher);
}

test "SimHasher: merkle build hashes file pieces synchronously" {
    const allocator = std.testing.allocator;

    var hasher = try SimHasher.create(allocator, 0);
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    // Reuse the same fixture shape as the RealHasher merkle test: 1
    // file, 2 pieces, written to a tmpDir-backed file.
    const piece_len: u32 = 64;
    const piece0_data = "A" ** piece_len;
    const piece1_data = "B" ** piece_len;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile(
        "sim_merkle_test",
        .{ .truncate = true, .read = true },
    ) catch return error.SkipZigTest;
    defer file.close();
    file.writeAll(piece0_data) catch return error.SkipZigTest;
    file.writeAll(piece1_data) catch return error.SkipZigTest;
    const fd = file.handle;

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
    try hasher.submitMerkleJob(0, 0, 0, 2, &layout, &shared_fds);

    var swap_buf = std.ArrayList(RealHasher.MerkleResult).empty;
    defer swap_buf.deinit(allocator);

    // Submit is synchronous — drain immediately fires the result.
    const results = hasher.drainMerkleResultsInto(&swap_buf);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const result = results[0];
    try std.testing.expect(result.piece_hashes != null);

    const hashes = result.piece_hashes.?;
    defer allocator.free(hashes);
    try std.testing.expectEqual(@as(usize, 2), hashes.len);

    var expected0: [32]u8 = undefined;
    Sha256.hash(piece0_data, &expected0, .{});
    try std.testing.expectEqual(expected0, hashes[0]);

    var expected1: [32]u8 = undefined;
    Sha256.hash(piece1_data, &expected1, .{});
    try std.testing.expectEqual(expected1, hashes[1]);
}

test "SimHasher: merkle pread fault knob fails the job" {
    const allocator = std.testing.allocator;

    var hasher = try SimHasher.create(allocator, 0);
    defer {
        hasher.deinit();
        allocator.destroy(hasher);
    }

    // Pin fault probability to 1.0 so EVERY pread is treated as failed.
    hasher.setFaults(.{ .merkle_pread_fault_prob = 1.0 });

    const piece_len: u32 = 64;
    const piece0_data = "A" ** piece_len;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = tmp_dir.dir.createFile(
        "sim_merkle_fault_test",
        .{ .truncate = true, .read = true },
    ) catch return error.SkipZigTest;
    defer file.close();
    file.writeAll(piece0_data) catch return error.SkipZigTest;

    const metainfo_mod = @import("../torrent/metainfo.zig");
    var files = [_]Layout.File{
        .{
            .length = piece_len,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 1,
            .path = &.{},
            .v2_piece_offset = 0,
        },
    };
    var v2_files = [_]metainfo_mod.V2File{
        .{ .path = &.{}, .length = piece_len, .pieces_root = [_]u8{0} ** 32 },
    };
    var layout = Layout{
        .piece_length = piece_len,
        .piece_count = 1,
        .total_size = piece_len,
        .files = &files,
        .piece_hashes = "",
        .version = .v2,
        .v2_files = &v2_files,
    };

    const shared_fds = [_]posix.fd_t{file.handle};
    try hasher.submitMerkleJob(0, 0, 0, 1, &layout, &shared_fds);

    var swap_buf = std.ArrayList(RealHasher.MerkleResult).empty;
    defer swap_buf.deinit(allocator);
    const results = hasher.drainMerkleResultsInto(&swap_buf);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    // Forced fault → null piece_hashes (mirrors the real hasher's
    // bad-fd path).
    try std.testing.expect(results[0].piece_hashes == null);
}

test "SimHasher: same seed produces same fault sequence" {
    const allocator = std.testing.allocator;

    // Set fault prob to 0.5 and roll many trials with two SimHashers
    // sharing a seed; their roll sequences must match byte-for-byte.
    var h1 = try SimHasher.create(allocator, 0xfeedface);
    defer {
        h1.deinit();
        allocator.destroy(h1);
    }
    h1.setFaults(.{ .merkle_pread_fault_prob = 0.5 });

    var h2 = try SimHasher.create(allocator, 0xfeedface);
    defer {
        h2.deinit();
        allocator.destroy(h2);
    }
    h2.setFaults(.{ .merkle_pread_fault_prob = 0.5 });

    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        try std.testing.expectEqual(
            h1.shouldInjectMerklePreadFault(),
            h2.shouldInjectMerklePreadFault(),
        );
    }
}

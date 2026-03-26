const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const storage = @import("../storage/root.zig");
const session_mod = @import("../torrent/session.zig");

/// Async piece hasher that runs on a background thread.
/// The event loop submits pieces for verification; the hasher thread
/// computes SHA-1 and writes results to an eventfd that the event loop
/// polls via io_uring.
pub const Hasher = struct {
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    thread: ?std.Thread = null,
    running: bool = true,

    // Job queue: event loop pushes, hasher thread pops
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    pending_jobs: std.ArrayList(Job) = std.ArrayList(Job).empty,

    // Result queue: hasher thread pushes, event loop pops
    result_mutex: std.Thread.Mutex = .{},
    completed_results: std.ArrayList(Result) = std.ArrayList(Result).empty,

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

    pub fn init(allocator: std.mem.Allocator, session: *const session_mod.Session) !Hasher {
        // Create eventfd for signaling the event loop
        const efd = try std.posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);

        var self = Hasher{
            .allocator = allocator,
            .session = session,
            .event_fd = efd,
        };

        self.thread = try std.Thread.spawn(.{}, workerLoop, .{&self});
        return self;
    }

    pub fn deinit(self: *Hasher) void {
        // Signal thread to stop
        self.queue_mutex.lock();
        self.running = false;
        self.queue_cond.signal();
        self.queue_mutex.unlock();

        if (self.thread) |t| t.join();

        // Clean up remaining jobs
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
    /// Returns a slice of results (caller should process and then call clearResults).
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

    /// Return the eventfd for the event loop to poll via io_uring.
    pub fn getEventFd(self: *Hasher) posix.fd_t {
        return self.event_fd;
    }

    fn workerLoop(self: *Hasher) void {
        while (true) {
            // Wait for a job
            self.queue_mutex.lock();
            while (self.pending_jobs.items.len == 0 and self.running) {
                self.queue_cond.timedWait(&self.queue_mutex, 100 * std.time.ns_per_ms) catch {};
            }

            if (!self.running and self.pending_jobs.items.len == 0) {
                self.queue_mutex.unlock();
                return;
            }

            // Pop a job
            const job = self.pending_jobs.orderedRemove(0);
            self.queue_mutex.unlock();

            // Hash the piece
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

            // Wake the event loop via eventfd
            if (self.event_fd >= 0) {
                const val: u64 = 1;
                _ = posix.write(self.event_fd, std.mem.asBytes(&val)) catch {};
            }
        }
    }
};

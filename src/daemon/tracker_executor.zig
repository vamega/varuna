const std = @import("std");
const Ring = @import("../io/ring.zig").Ring;
const DnsResolver = @import("../io/dns.zig").DnsResolver;
const HttpClient = @import("../io/http.zig").HttpClient;

/// Shared tracker executor for daemon-side announces and scrapes.
/// A single worker owns the ring, DNS cache, and keep-alive HTTP client so
/// torrents do not each lazily create their own tracker I/O resources.
pub const TrackerExecutor = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    pending_jobs: std.ArrayList(Job),

    ring: Ring,
    dns_resolver: DnsResolver,
    http_client: HttpClient,

    pub const JobFn = *const fn (context: *anyopaque, ring: *Ring, http_client: *HttpClient) void;

    pub const Job = struct {
        context: *anyopaque,
        run: JobFn,
    };

    pub fn create(allocator: std.mem.Allocator) !*TrackerExecutor {
        const self = try allocator.create(TrackerExecutor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .pending_jobs = std.ArrayList(Job).empty,
            .ring = try Ring.init(64),
            .dns_resolver = try DnsResolver.init(allocator),
            .http_client = undefined,
        };
        errdefer self.ring.deinit();
        errdefer self.dns_resolver.deinit(allocator);

        self.http_client = HttpClient.initPersistentWithDns(allocator, &self.ring, &self.dns_resolver);
        errdefer self.http_client.deinit();

        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    pub fn destroy(self: *TrackerExecutor) void {
        self.queue_mutex.lock();
        self.running.store(false, .release);
        self.queue_cond.signal();
        self.queue_mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.http_client.deinit();
        self.dns_resolver.deinit(self.allocator);
        self.ring.deinit();
        self.pending_jobs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *TrackerExecutor, context: *anyopaque, run: JobFn) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (!self.running.load(.acquire)) return error.ExecutorStopped;
        try self.pending_jobs.append(self.allocator, .{
            .context = context,
            .run = run,
        });
        self.queue_cond.signal();
    }

    fn workerMain(self: *TrackerExecutor) void {
        while (true) {
            self.queue_mutex.lock();
            while (self.pending_jobs.items.len == 0 and self.running.load(.acquire)) {
                self.queue_cond.wait(&self.queue_mutex);
            }

            if (self.pending_jobs.items.len == 0 and !self.running.load(.acquire)) {
                self.queue_mutex.unlock();
                return;
            }

            const job = self.pending_jobs.orderedRemove(0);
            self.queue_mutex.unlock();

            job.run(job.context, &self.ring, &self.http_client);
        }
    }
};

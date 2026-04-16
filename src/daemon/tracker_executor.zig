const std = @import("std");
const linux = std.os.linux;
pub const HttpExecutor = @import("../io/http_executor.zig").HttpExecutor;

const log = std.log.scoped(.tracker_executor);

/// Thin wrapper around HttpExecutor for tracker announces.
///
/// Preserves the original TrackerExecutor API so that TorrentSession and
/// other callers continue to work unchanged.  All state-machine, DNS,
/// TLS, connection pool, and slot management logic now lives in
/// `src/io/http_executor.zig`.
pub const TrackerExecutor = struct {
    allocator: std.mem.Allocator,
    http: *HttpExecutor,

    // Re-export HttpExecutor types so existing callers compile unchanged.
    pub const CompletionFn = HttpExecutor.CompletionFn;
    pub const RequestResult = HttpExecutor.RequestResult;

    pub const Job = struct {
        context: *anyopaque,
        on_complete: CompletionFn,
        url: [max_url_len]u8 = undefined,
        url_len: u16 = 0,
        host: [max_host_len]u8 = undefined,
        host_len: u8 = 0,

        const max_host_len = 253;
        const max_url_len = 2048;

        pub fn urlSlice(self: *const Job) []const u8 {
            return self.url[0..self.url_len];
        }

        pub fn hostSlice(self: *const Job) []const u8 {
            return self.host[0..self.host_len];
        }
    };

    pub const Config = struct {
        max_concurrent: u16 = 8,
        max_per_host: u16 = 3,
    };

    // ── Public API ───────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator, ring: *linux.IoUring, config: Config) !*TrackerExecutor {
        const self = try allocator.create(TrackerExecutor);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .http = try HttpExecutor.create(allocator, ring, .{
                .max_concurrent = config.max_concurrent,
                .max_per_host = config.max_per_host,
            }),
        };

        return self;
    }

    pub fn destroy(self: *TrackerExecutor) void {
        self.http.destroy();
        self.allocator.destroy(self);
    }

    /// Submit a tracker HTTP(S) GET request. Thread-safe.
    /// Converts TrackerExecutor.Job to HttpExecutor.Job and delegates.
    pub fn submit(self: *TrackerExecutor, job: Job) !void {
        var http_job = HttpExecutor.Job{
            .context = job.context,
            .on_complete = job.on_complete,
            .url_len = job.url_len,
            .host_len = job.host_len,
        };
        @memcpy(http_job.url[0..job.url_len], job.url[0..job.url_len]);
        @memcpy(http_job.host[0..job.host_len], job.host[0..job.host_len]);
        try self.http.submit(http_job);
    }

    /// Process pending jobs, check timeouts, and start deferred requests.
    /// Called from the main event loop's tick().
    pub fn tick(self: *TrackerExecutor) void {
        self.http.tick();
    }

    /// Dispatch a CQE from the shared event loop.
    pub fn dispatchCqe(self: *TrackerExecutor, cqe: linux.io_uring_cqe) void {
        self.http.dispatchCqe(cqe);
    }
};

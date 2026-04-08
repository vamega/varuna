/// Background I/O thread for varuna-tui.
///
/// Runs synchronous HTTP requests via std.http.Client on a dedicated thread,
/// communicating results back to the main (UI) thread via a thread-safe queue.
/// A libxev Async handle is signaled when results are ready, so the main loop
/// can pick them up without polling or blocking.
const std = @import("std");
const xev = @import("xev");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

/// A request the main thread asks the I/O thread to execute.
pub const Request = union(enum) {
    /// Poll the daemon for current state (torrents, transfer info, etc.)
    poll: PollRequest,
    /// Execute a fire-and-forget action (add, remove, pause, resume, etc.)
    action: ActionRequest,
    /// Shut down the I/O thread.
    shutdown,
};

pub const PollRequest = struct {
    /// Which view we are in determines what extra data to fetch.
    mode: ViewMode,
    /// Hash of the selected torrent (for detail view fetches).
    selected_hash: [64]u8 = undefined,
    selected_hash_len: usize = 0,
    /// Whether preferences have already been loaded.
    prefs_loaded: bool = false,
};

pub const ViewMode = enum {
    main,
    detail,
    preferences,
    other,
};

pub const ActionRequest = struct {
    kind: ActionKind,
    data: [4096]u8 = undefined,
    data_len: usize = 0,
    hash: [64]u8 = undefined,
    hash_len: usize = 0,
    delete_files: bool = false,
};

pub const ActionKind = enum {
    add_torrent,
    remove_torrent,
    pause_torrent,
    resume_torrent,
    set_preferences,
    login,
};

/// Thread-safe MPSC queue for passing requests to and results from the I/O thread.
/// Uses a mutex + condition variable for the request queue (main -> I/O),
/// and a mutex for the result queue (I/O -> main).
pub fn ThreadSafeQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            value: T,
            next: ?*Node = null,
        };

        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        head: ?*Node = null,
        tail: ?*Node = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            // Drain any remaining nodes.
            while (self.popNoLock()) |node| {
                self.allocator.destroy(node);
            }
        }

        /// Push a value and signal any waiting consumer.
        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .value = value };

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.condition.signal();
        }

        /// Pop a value, returning null if empty. Non-blocking.
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node = self.popNoLock() orelse return null;
            const value = node.value;
            self.allocator.destroy(node);
            return value;
        }

        /// Block until a value is available and return it.
        pub fn popWait(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head == null) {
                self.condition.wait(&self.mutex);
            }

            const node = self.popNoLock().?;
            const value = node.value;
            self.allocator.destroy(node);
            return value;
        }

        fn popNoLock(self: *Self) ?*Node {
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == null) {
                self.tail = null;
            }
            return node;
        }
    };
}

/// The background I/O worker. Owns an ApiClient and processes requests
/// from the main thread, posting results back via a result queue and
/// signaling a libxev Async handle.
pub const IoThread = struct {
    allocator: Allocator,
    api_client: api.ApiClient,
    request_queue: *ThreadSafeQueue(Request),
    result_queue: *ThreadSafeQueue(api.PollResult),
    async_handle: xev.Async,
    thread: ?std.Thread = null,

    pub fn init(
        allocator: Allocator,
        base_url: []const u8,
        request_queue: *ThreadSafeQueue(Request),
        result_queue: *ThreadSafeQueue(api.PollResult),
        async_handle: xev.Async,
    ) IoThread {
        return .{
            .allocator = allocator,
            .api_client = api.ApiClient.init(allocator, base_url),
            .request_queue = request_queue,
            .result_queue = result_queue,
            .async_handle = async_handle,
        };
    }

    pub fn deinit(self: *IoThread) void {
        self.api_client.deinit();
    }

    /// Start the I/O thread.
    pub fn start(self: *IoThread) !void {
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    /// Signal the I/O thread to stop and wait for it.
    pub fn stop(self: *IoThread) void {
        // Push a shutdown sentinel.
        self.request_queue.push(.shutdown) catch {};
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn workerLoop(self: *IoThread) void {
        while (true) {
            const request = self.request_queue.popWait();
            switch (request) {
                .shutdown => return,
                .poll => |poll_req| self.handlePoll(poll_req),
                .action => |action_req| self.handleAction(action_req),
            }
        }
    }

    fn handlePoll(self: *IoThread, req: PollRequest) void {
        const allocator = self.allocator;
        var result = api.PollResult{};

        // Fetch torrent list.
        if (self.api_client.fetchTorrents(allocator)) |torrents| {
            result.torrents = torrents;
            result.connected = true;
        } else |err| {
            if (err == api.ApiError.AuthRequired) {
                result.auth_required = true;
            } else if (err == api.ApiError.ConnectionRefused) {
                result.connected = false;
                result.error_msg = "Connection refused";
            }
        }

        // Fetch transfer stats.
        if (self.api_client.fetchTransferInfo(allocator)) |transfer| {
            result.transfer = transfer;
        } else |_| {}

        // If in detail view, fetch detail data.
        if (req.mode == .detail and req.selected_hash_len > 0) {
            const hash = req.selected_hash[0..req.selected_hash_len];
            if (self.api_client.fetchProperties(allocator, hash)) |props| {
                result.properties = props;
            } else |_| {}

            if (self.api_client.fetchTrackers(allocator, hash)) |trackers| {
                result.trackers = trackers;
            } else |_| {}

            if (self.api_client.fetchFiles(allocator, hash)) |files| {
                result.files = files;
            } else |_| {}
        }

        // If in preferences view, fetch prefs.
        if (req.mode == .preferences and !req.prefs_loaded) {
            if (self.api_client.fetchPreferences(allocator)) |prefs| {
                result.preferences = prefs;
            } else |_| {}
        }

        // Post result and wake the main loop.
        self.result_queue.push(result) catch return;
        self.async_handle.notify() catch {};
    }

    fn handleAction(self: *IoThread, req: ActionRequest) void {
        const allocator = self.allocator;

        switch (req.kind) {
            .add_torrent => {
                const data = req.data[0..req.data_len];
                self.api_client.addTorrent(allocator, data) catch {};
            },
            .remove_torrent => {
                const hash = req.hash[0..req.hash_len];
                self.api_client.removeTorrent(allocator, hash, req.delete_files) catch {};
            },
            .pause_torrent => {
                const hash = req.hash[0..req.hash_len];
                self.api_client.pauseTorrent(allocator, hash) catch {};
            },
            .resume_torrent => {
                const hash = req.hash[0..req.hash_len];
                self.api_client.resumeTorrent(allocator, hash) catch {};
            },
            .set_preferences => {
                const data = req.data[0..req.data_len];
                self.api_client.setPreferences(allocator, data) catch {};
            },
            .login => {
                // Login data is formatted as "username\x00password"
                const data = req.data[0..req.data_len];
                if (std.mem.indexOfScalar(u8, data, 0)) |sep| {
                    const user = data[0..sep];
                    const pass = data[sep + 1 ..];
                    var result = api.PollResult{};
                    if (self.api_client.login(user, pass)) |success| {
                        if (success) {
                            result.connected = true;
                        } else {
                            result.error_msg = "Invalid credentials";
                            result.auth_required = true;
                        }
                    } else |_| {
                        result.error_msg = "Login failed - connection error";
                        result.auth_required = true;
                    }
                    self.result_queue.push(result) catch return;
                    self.async_handle.notify() catch {};
                    return;
                }
            },
        }

        // After any action, trigger an immediate poll to refresh UI.
        self.handlePoll(.{
            .mode = .main,
            .prefs_loaded = false,
        });
    }
};

//! Async data-file move job — backs the new
//! `POST /api/v2/varuna/torrents/move` endpoint and replaces the
//! synchronous `setLocation` path that used to block the RPC handler
//! thread for the duration of a multi-GB cross-filesystem copy.
//!
//! ## Event-loop production path
//!
//! Production moves are manifest-scoped and run as an event-loop state
//! machine through the IO contract (`mkdirat`, `renameat`, `openat`,
//! `copy_file_range`, `fsync`, `unlinkat`). This keeps daemon relocation
//! out of ad hoc blocking filesystem threads and lets the main loop
//! schedule move progress alongside peer, tracker, RPC, and recheck I/O.
//!
//! The legacy `start()` worker-thread path remains for source-side tests
//! that exercise the old whole-root mover directly. `SessionManager`
//! starts real daemon jobs with `startOnEventLoop`.
//!
//! ## State machine
//!
//!   created → running → succeeded
//!                    ↘  failed
//!                    ↘  canceled
//!
//! Transitions are one-shot and `compareAndSwap`-driven; once a job
//! reaches a terminal state it stays there until `destroy`. Cancel
//! requests flip an atomic flag — the event-loop mover observes it between
//! files and between copy chunks.
//!
//! ## Same-FS fast path and copy fallback
//!
//! Manifest-scoped jobs first try `renameat` for each file. Same-fs moves
//! complete with one namespace operation per file; cross-fs `EXDEV`
//! falls back to `openat` + chunked `copy_file_range` + destination fsync
//! + source unlink. After either route, source and destination parent
//! directories are fsynced so completed moves survive crashes.
//!
//! ## Progress accounting
//!
//! `total_bytes` is computed during a one-shot pre-scan; `bytes_copied`
//! advances as `copy_file_range` returns positive byte counts. The
//! same-FS rename path sets both to the same value at completion (the
//! "we moved zero bytes through userspace, but conceptually all of it
//! moved" interpretation). Files-counter analogous.
//!
//! ## Scheduling policy
//!
//! `SessionManager.tickMoveJobs` gives each active event-loop job one
//! `tickOnEventLoop` call per daemon loop pass. A job tick consumes at
//! most one completed IO result and submits at most one follow-up IO op;
//! it never drains a full copy by itself. This keeps concurrent moves
//! fair without adding a global relocation scheduler yet.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;
const ifc = @import("../io/io_interface.zig");

// ── Public types ──────────────────────────────────────────

pub const JobId = u64;

pub const State = enum(u8) {
    /// Created but worker thread has not started yet.
    created = 0,
    /// Worker thread running.
    running = 1,
    /// Worker thread exited; data successfully moved.
    succeeded = 2,
    /// Worker thread exited with an error.
    failed = 3,
    /// Cancellation observed; worker stopped at the next file boundary.
    canceled = 4,
};

pub const Progress = struct {
    state: State,
    bytes_copied: u64,
    total_bytes: u64,
    files_done: u32,
    total_files: u32,
    /// True when the same-fs rename fast path was used. In that case
    /// `bytes_copied` jumps to `total_bytes` in one tick (no userspace
    /// data movement happens).
    used_rename: bool,
    /// Owning copy of any error message; null when state != .failed.
    /// Caller must not free; lifetime tied to the job.
    error_message: ?[]const u8,
};

/// Optional one-shot completion callback. Fires from the worker thread
/// once the job exits its terminal state. The callback **must not**
/// block, must not call back into the job's `requestCancel`, and must
/// be safe to invoke from a non-EL thread.
pub const CompletionCallback = *const fn (
    ctx: ?*anyopaque,
    id: JobId,
    state: State,
) void;

// ── MoveJob ───────────────────────────────────────────────

pub const MoveJob = struct {
    const SpawnThreadFn = *const fn (*MoveJob) anyerror!std.Thread;
    const FsyncFn = *const fn (posix.fd_t) anyerror!void;
    const at_fdcwd: posix.fd_t = if (builtin.target.os.tag == .linux)
        linux.AT.FDCWD
    else
        -100;

    const Runner = enum {
        none,
        thread,
        event_loop,
    };

    const EventStage = enum {
        idle,
        mkdir_next,
        rename_file,
        open_src,
        open_dst,
        copy_file_range,
        fsync_dst_file,
        close_src_file,
        close_dst_file,
        unlink_src_file,
        open_fsync_dir,
        fsync_dir,
        close_dir,
        cleanup_src_file,
        cleanup_dst_file,
        cleanup_dir,
        finish_file,
        done,
    };

    const DirectorySyncKind = enum {
        dst_parent,
        src_parent,
    };

    pub const File = struct {
        relative_path: []const u8,
        length: u64,
    };

    const OwnedFile = struct {
        relative_path: []u8,
        length: u64,
    };

    id: JobId,
    allocator: std.mem.Allocator,

    /// Owned copies of source and destination root directories. Both
    /// MUST be absolute (the SessionManager validates this on submit).
    src_root: []u8,
    dst_root: []u8,
    files: []OwnedFile = &.{},

    // ── Atomic progress (any thread can read) ─────────────
    bytes_copied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    files_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    total_files: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    state_atomic: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.created)),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    used_rename: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // ── Error storage (lazy; only populated on failure) ───
    error_mutex: std.Thread.Mutex = .{},
    error_message: ?[]u8 = null,

    // ── Worker thread ─────────────────────────────────────
    thread: ?std.Thread = null,
    runner: Runner = .none,

    // ── Event-loop move state ─────────────────────────────
    io_completion: ifc.Completion = .{},
    io_pending: bool = false,
    io_result: ?ifc.Result = null,
    event_stage: EventStage = .idle,
    current_file_index: usize = 0,
    mkdir_paths: [][:0]u8 = &.{},
    mkdir_index: usize = 0,
    src_path_z: ?[:0]u8 = null,
    dst_path_z: ?[:0]u8 = null,
    src_parent_z: ?[:0]u8 = null,
    dst_parent_z: ?[:0]u8 = null,
    src_fd: posix.fd_t = -1,
    dst_fd: posix.fd_t = -1,
    dir_fd: posix.fd_t = -1,
    copy_offset: u64 = 0,
    pending_dir_sync: DirectorySyncKind = .dst_parent,
    cleanup_terminal: State = .failed,

    // ── Optional completion callback ──────────────────────
    completion_ctx: ?*anyopaque = null,
    completion_cb: ?CompletionCallback = null,

    /// Allocate a new MoveJob. The job is in state `.created` and is
    /// not running — call `start()` to spawn the worker thread.
    pub fn create(
        allocator: std.mem.Allocator,
        id: JobId,
        src_root: []const u8,
        dst_root: []const u8,
    ) !*MoveJob {
        const self = try allocator.create(MoveJob);
        errdefer allocator.destroy(self);

        const owned_src = try allocator.dupe(u8, src_root);
        errdefer allocator.free(owned_src);
        const owned_dst = try allocator.dupe(u8, dst_root);
        errdefer allocator.free(owned_dst);

        self.* = .{
            .id = id,
            .allocator = allocator,
            .src_root = owned_src,
            .dst_root = owned_dst,
        };
        return self;
    }

    /// Allocate a manifest-scoped move job. Only the listed relative paths
    /// are relocated; sibling files under `src_root` are left alone.
    pub fn createForFiles(
        allocator: std.mem.Allocator,
        id: JobId,
        src_root: []const u8,
        dst_root: []const u8,
        files: []const File,
    ) !*MoveJob {
        const self = try create(allocator, id, src_root, dst_root);
        errdefer self.destroy();

        const owned_files = try allocator.alloc(OwnedFile, files.len);
        errdefer allocator.free(owned_files);

        var initialized: usize = 0;
        errdefer {
            for (owned_files[0..initialized]) |file| allocator.free(file.relative_path);
        }

        for (files, 0..) |file, index| {
            if (std.fs.path.isAbsolute(file.relative_path)) return error.InvalidMovePath;
            var parts = std.mem.splitScalar(u8, file.relative_path, std.fs.path.sep);
            while (parts.next()) |part| {
                if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
                    return error.InvalidMovePath;
                }
            }
            owned_files[index] = .{
                .relative_path = try allocator.dupe(u8, file.relative_path),
                .length = file.length,
            };
            initialized = index + 1;
        }

        self.files = owned_files;
        return self;
    }

    /// Free the job. Safe to call after `state` is terminal; if the
    /// worker thread is still running, this joins it first.
    pub fn destroy(self: *MoveJob) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.freeEventLoopFileState();
        self.allocator.free(self.src_root);
        self.allocator.free(self.dst_root);
        for (self.files) |file| self.allocator.free(file.relative_path);
        if (self.files.len > 0) self.allocator.free(self.files);
        if (self.error_message) |m| self.allocator.free(m);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Spawn the worker thread. Returns `error.AlreadyStarted` if the
    /// job has already been started.
    pub fn start(
        self: *MoveJob,
        completion_ctx: ?*anyopaque,
        completion_cb: ?CompletionCallback,
    ) !void {
        try self.startWithSpawner(completion_ctx, completion_cb, spawnWorkerThread);
    }

    fn startWithSpawner(
        self: *MoveJob,
        completion_ctx: ?*anyopaque,
        completion_cb: ?CompletionCallback,
        spawn_thread: SpawnThreadFn,
    ) !void {
        const prev = self.state_atomic.cmpxchgStrong(
            @intFromEnum(State.created),
            @intFromEnum(State.running),
            .acq_rel,
            .acquire,
        );
        if (prev != null) return error.AlreadyStarted;

        self.completion_ctx = completion_ctx;
        self.completion_cb = completion_cb;
        const thread = spawn_thread(self) catch |err| {
            self.completion_ctx = null;
            self.completion_cb = null;
            self.state_atomic.store(@intFromEnum(State.created), .release);
            return err;
        };
        self.thread = thread;
        self.runner = .thread;
    }

    /// Start a manifest-scoped job on the caller's event loop. The caller
    /// must periodically call `tickOnEventLoop` until the job reaches a
    /// terminal state.
    pub fn startOnEventLoop(
        self: *MoveJob,
        completion_ctx: ?*anyopaque,
        completion_cb: ?CompletionCallback,
    ) !void {
        if (self.files.len == 0) return error.ManifestRequiredForEventLoopMove;
        const prev = self.state_atomic.cmpxchgStrong(
            @intFromEnum(State.created),
            @intFromEnum(State.running),
            .acq_rel,
            .acquire,
        );
        if (prev != null) return error.AlreadyStarted;

        self.completion_ctx = completion_ctx;
        self.completion_cb = completion_cb;
        self.runner = .event_loop;
        self.event_stage = .mkdir_next;
        self.total_files.store(@intCast(self.files.len), .release);
        var total_bytes: u64 = 0;
        for (self.files) |file| total_bytes += file.length;
        self.total_bytes.store(total_bytes, .release);
    }

    pub fn isEventLoopRunning(self: *MoveJob) bool {
        return self.runner == .event_loop and self.progress().state == .running;
    }

    pub fn hasPendingEventLoopIo(self: *MoveJob) bool {
        return self.runner == .event_loop and self.io_pending;
    }

    pub fn tickOnEventLoop(self: *MoveJob, io: anytype) void {
        if (self.runner != .event_loop) return;
        if (self.progress().state != .running) return;
        self.tickOnEventLoopInternal(io) catch |err| self.failEventLoop(io, err);
    }

    fn tickOnEventLoopInternal(self: *MoveJob, io: anytype) !void {
        if (self.io_result) |result| {
            self.io_result = null;
            try self.handleEventLoopResult(result);
        }
        if (self.progress().state != .running or self.io_pending) return;

        if (self.event_stage == .mkdir_next and self.src_path_z == null) {
            try self.prepareCurrentEventLoopFile();
        }

        if (self.progress().state != .running or self.io_pending) return;

        switch (self.event_stage) {
            .idle => {},
            .mkdir_next => try self.submitMkdir(io),
            .rename_file => try self.submitRename(io),
            .open_src => try self.submitOpenSource(io),
            .open_dst => try self.submitOpenDestination(io),
            .copy_file_range => try self.submitCopyFileRange(io),
            .fsync_dst_file => try self.submitFsyncDestinationFile(io),
            .close_src_file => try self.submitCloseSourceFile(io),
            .close_dst_file => try self.submitCloseDestinationFile(io),
            .unlink_src_file => try self.submitUnlinkSource(io),
            .open_fsync_dir => try self.submitOpenDirectoryForFsync(io),
            .fsync_dir => try self.submitFsyncDirectory(io),
            .close_dir => try self.submitCloseDirectory(io),
            .cleanup_src_file, .cleanup_dst_file, .cleanup_dir => try self.submitNextCleanupClose(io),
            .finish_file => try self.finishCurrentEventLoopFile(),
            .done => self.completeEventLoop(.succeeded),
        }
    }

    fn prepareCurrentEventLoopFile(self: *MoveJob) !void {
        self.freeEventLoopFileState();

        if (self.cancel_requested.load(.acquire)) {
            self.completeEventLoop(.canceled);
            return;
        }

        if (self.current_file_index >= self.files.len) {
            self.event_stage = .done;
            self.completeEventLoop(.succeeded);
            return;
        }

        const file = self.files[self.current_file_index];
        self.src_path_z = try joinPathZ(self.allocator, self.src_root, file.relative_path);
        errdefer {
            if (self.src_path_z) |path| self.allocator.free(path);
            self.src_path_z = null;
        }
        self.dst_path_z = try joinPathZ(self.allocator, self.dst_root, file.relative_path);
        errdefer {
            if (self.dst_path_z) |path| self.allocator.free(path);
            self.dst_path_z = null;
        }

        const src_parent = std.fs.path.dirname(self.src_path_z.?[0..self.src_path_z.?.len]) orelse self.src_root;
        self.src_parent_z = try self.allocator.dupeZ(u8, src_parent);
        errdefer {
            if (self.src_parent_z) |path| self.allocator.free(path);
            self.src_parent_z = null;
        }
        const dst_parent = std.fs.path.dirname(self.dst_path_z.?[0..self.dst_path_z.?.len]) orelse self.dst_root;
        self.dst_parent_z = try self.allocator.dupeZ(u8, dst_parent);
        errdefer {
            if (self.dst_parent_z) |path| self.allocator.free(path);
            self.dst_parent_z = null;
        }

        self.mkdir_paths = try buildDirectoryPrefixes(self.allocator, dst_parent);
        self.mkdir_index = 0;
        self.copy_offset = 0;
        self.event_stage = .mkdir_next;
    }

    fn handleEventLoopResult(self: *MoveJob, result: ifc.Result) !void {
        switch (self.event_stage) {
            .mkdir_next => {
                switch (result) {
                    .mkdirat => |r| r catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    },
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.mkdir_index += 1;
                if (self.mkdir_index >= self.mkdir_paths.len) {
                    self.event_stage = .rename_file;
                }
            },
            .rename_file => {
                switch (result) {
                    .renameat => |r| r catch |err| switch (err) {
                        error.RenameAcrossMountPoints, error.OperationNotSupported => {
                            self.event_stage = .open_src;
                            return;
                        },
                        else => return err,
                    },
                    else => return error.UnexpectedMoveJobCompletion,
                }
                const file = self.files[self.current_file_index];
                _ = self.bytes_copied.fetchAdd(file.length, .acq_rel);
                self.used_rename.store(true, .release);
                self.pending_dir_sync = .dst_parent;
                self.event_stage = .open_fsync_dir;
            },
            .open_src => {
                switch (result) {
                    .openat => |r| self.src_fd = try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .open_dst;
            },
            .open_dst => {
                switch (result) {
                    .openat => |r| self.dst_fd = try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .copy_file_range;
            },
            .copy_file_range => {
                const n = switch (result) {
                    .copy_file_range => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                if (n == 0) return error.UnexpectedEndOfFile;
                self.copy_offset += n;
                _ = self.bytes_copied.fetchAdd(n, .acq_rel);
                const file = self.files[self.current_file_index];
                if (self.copy_offset >= file.length) {
                    self.event_stage = .fsync_dst_file;
                }
            },
            .fsync_dst_file => {
                switch (result) {
                    .fsync => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .close_src_file;
            },
            .close_src_file => {
                const r = switch (result) {
                    .close => |r| r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                self.src_fd = -1;
                try r;
                self.event_stage = .close_dst_file;
            },
            .close_dst_file => {
                const r = switch (result) {
                    .close => |r| r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                self.dst_fd = -1;
                try r;
                self.event_stage = .unlink_src_file;
            },
            .unlink_src_file => {
                switch (result) {
                    .unlinkat => |r| r catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    },
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.pending_dir_sync = .dst_parent;
                self.event_stage = .open_fsync_dir;
            },
            .open_fsync_dir => {
                switch (result) {
                    .openat => |r| self.dir_fd = try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .fsync_dir;
            },
            .fsync_dir => {
                switch (result) {
                    .fsync => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .close_dir;
            },
            .close_dir => {
                const r = switch (result) {
                    .close => |r| r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                self.dir_fd = -1;
                try r;
                switch (self.pending_dir_sync) {
                    .dst_parent => {
                        self.pending_dir_sync = .src_parent;
                        self.event_stage = .open_fsync_dir;
                    },
                    .src_parent => self.event_stage = .finish_file,
                }
            },
            .cleanup_src_file, .cleanup_dst_file, .cleanup_dir => {
                const r = switch (result) {
                    .close => |r| r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                switch (self.event_stage) {
                    .cleanup_src_file => self.src_fd = -1,
                    .cleanup_dst_file => self.dst_fd = -1,
                    .cleanup_dir => self.dir_fd = -1,
                    else => unreachable,
                }
                r catch |err| {
                    self.recordErrorIfNone(err);
                    self.cleanup_terminal = .failed;
                };
                self.event_stage = switch (self.event_stage) {
                    .cleanup_src_file => .cleanup_dst_file,
                    .cleanup_dst_file => .cleanup_dir,
                    .cleanup_dir => .done,
                    else => unreachable,
                };
                if (self.event_stage == .done) {
                    self.completeEventLoop(self.cleanup_terminal);
                }
            },
            else => return error.UnexpectedMoveJobCompletion,
        }
    }

    fn submitMkdir(self: *MoveJob, io: anytype) !void {
        if (self.mkdir_index >= self.mkdir_paths.len) {
            self.event_stage = .rename_file;
            return;
        }
        const path = self.mkdir_paths[self.mkdir_index];
        self.io_pending = true;
        io.mkdirat(.{
            .dir_fd = at_fdcwd,
            .path = path,
            .mode = 0o755,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitRename(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.renameat(.{
            .old_dir_fd = at_fdcwd,
            .old_path = self.src_path_z.?,
            .new_dir_fd = at_fdcwd,
            .new_path = self.dst_path_z.?,
            .flags = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenSource(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = self.src_path_z.?,
            .flags = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
            .mode = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenDestination(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = self.dst_path_z.?,
            .flags = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
            .mode = 0o644,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCopyFileRange(self: *MoveJob, io: anytype) !void {
        if (self.cancel_requested.load(.acquire)) {
            self.beginEventLoopCleanup(io, .canceled);
            return;
        }
        const file = self.files[self.current_file_index];
        if (self.copy_offset >= file.length) {
            self.event_stage = .fsync_dst_file;
            return;
        }
        const remaining = file.length - self.copy_offset;
        const chunk: usize = @intCast(@min(remaining, 4 * 1024 * 1024));
        self.io_pending = true;
        io.copy_file_range(.{
            .in_fd = self.src_fd,
            .in_offset = self.copy_offset,
            .out_fd = self.dst_fd,
            .out_offset = self.copy_offset,
            .len = chunk,
            .flags = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFsyncDestinationFile(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.fsync(.{
            .fd = self.dst_fd,
            .datasync = false,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCloseSourceFile(self: *MoveJob, io: anytype) !void {
        if (self.src_fd < 0) {
            self.event_stage = .close_dst_file;
            return;
        }
        try self.submitCloseFd(io, self.src_fd);
    }

    fn submitCloseDestinationFile(self: *MoveJob, io: anytype) !void {
        if (self.dst_fd < 0) {
            self.event_stage = .unlink_src_file;
            return;
        }
        try self.submitCloseFd(io, self.dst_fd);
    }

    fn submitUnlinkSource(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.unlinkat(.{
            .dir_fd = at_fdcwd,
            .path = self.src_path_z.?,
            .flags = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenDirectoryForFsync(self: *MoveJob, io: anytype) !void {
        const path = switch (self.pending_dir_sync) {
            .dst_parent => self.dst_parent_z.?,
            .src_parent => self.src_parent_z.?,
        };
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = path,
            .flags = .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
            .mode = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFsyncDirectory(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.fsync(.{
            .fd = self.dir_fd,
            .datasync = false,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCloseDirectory(self: *MoveJob, io: anytype) !void {
        if (self.dir_fd < 0) {
            self.event_stage = switch (self.pending_dir_sync) {
                .dst_parent => blk: {
                    self.pending_dir_sync = .src_parent;
                    break :blk .open_fsync_dir;
                },
                .src_parent => .finish_file,
            };
            return;
        }
        try self.submitCloseFd(io, self.dir_fd);
    }

    fn submitCloseFd(self: *MoveJob, io: anytype, fd: posix.fd_t) !void {
        self.io_pending = true;
        io.close(.{
            .fd = fd,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitNextCleanupClose(self: *MoveJob, io: anytype) !void {
        while (true) {
            switch (self.event_stage) {
                .cleanup_src_file => {
                    if (self.src_fd >= 0) return self.submitCloseFd(io, self.src_fd);
                    self.event_stage = .cleanup_dst_file;
                },
                .cleanup_dst_file => {
                    if (self.dst_fd >= 0) return self.submitCloseFd(io, self.dst_fd);
                    self.event_stage = .cleanup_dir;
                },
                .cleanup_dir => {
                    if (self.dir_fd >= 0) return self.submitCloseFd(io, self.dir_fd);
                    self.completeEventLoop(self.cleanup_terminal);
                    return;
                },
                else => unreachable,
            }
        }
    }

    fn finishCurrentEventLoopFile(self: *MoveJob) !void {
        _ = self.files_done.fetchAdd(1, .acq_rel);
        self.current_file_index += 1;
        self.freeEventLoopFileState();
        if (self.cancel_requested.load(.acquire)) {
            self.completeEventLoop(.canceled);
            return;
        }
        self.event_stage = .mkdir_next;
    }

    fn completeEventLoop(self: *MoveJob, terminal: State) void {
        self.freeEventLoopFileState();
        self.event_stage = .done;
        self.state_atomic.store(@intFromEnum(terminal), .release);
        if (self.completion_cb) |cb| cb(self.completion_ctx, self.id, terminal);
    }

    fn failEventLoop(self: *MoveJob, io: anytype, err: anyerror) void {
        self.recordError(err);
        self.beginEventLoopCleanup(io, .failed);
    }

    fn beginEventLoopCleanup(self: *MoveJob, io: anytype, terminal: State) void {
        self.cleanup_terminal = terminal;
        self.event_stage = .cleanup_src_file;
        self.submitNextCleanupClose(io) catch |err| {
            self.recordErrorIfNone(err);
            self.src_fd = -1;
            self.dst_fd = -1;
            self.dir_fd = -1;
            self.completeEventLoop(.failed);
        };
    }

    fn freeEventLoopFileState(self: *MoveJob) void {
        assert(self.src_fd < 0);
        assert(self.dst_fd < 0);
        assert(self.dir_fd < 0);
        for (self.mkdir_paths) |path| self.allocator.free(path);
        if (self.mkdir_paths.len > 0) self.allocator.free(self.mkdir_paths);
        self.mkdir_paths = &.{};
        self.mkdir_index = 0;
        if (self.src_path_z) |path| self.allocator.free(path);
        if (self.dst_path_z) |path| self.allocator.free(path);
        if (self.src_parent_z) |path| self.allocator.free(path);
        if (self.dst_parent_z) |path| self.allocator.free(path);
        self.src_path_z = null;
        self.dst_path_z = null;
        self.src_parent_z = null;
        self.dst_parent_z = null;
        self.copy_offset = 0;
    }

    fn eventLoopCallback(
        userdata: ?*anyopaque,
        _: *ifc.Completion,
        result: ifc.Result,
    ) ifc.CallbackAction {
        const self: *MoveJob = @ptrCast(@alignCast(userdata.?));
        self.io_pending = false;
        self.io_result = result;
        return .disarm;
    }

    /// Request cancellation. Idempotent. The worker observes this between
    /// files and after each `copy_file_range` chunk. Does NOT join — the
    /// caller polls `progress()` for the final state.
    pub fn requestCancel(self: *MoveJob) void {
        self.cancel_requested.store(true, .release);
    }

    /// Snapshot the job's current progress. Race-free: every field is
    /// atomic, the state enum is a single-byte atomic, and the error
    /// message — when present — is read under the error mutex.
    pub fn progress(self: *MoveJob) Progress {
        const state_byte = self.state_atomic.load(.acquire);
        const state: State = @enumFromInt(state_byte);
        var msg: ?[]const u8 = null;
        if (state == .failed) {
            self.error_mutex.lock();
            defer self.error_mutex.unlock();
            msg = self.error_message;
        }
        return .{
            .state = state,
            .bytes_copied = self.bytes_copied.load(.acquire),
            .total_bytes = self.total_bytes.load(.acquire),
            .files_done = self.files_done.load(.acquire),
            .total_files = self.total_files.load(.acquire),
            .used_rename = self.used_rename.load(.acquire),
            .error_message = msg,
        };
    }

    /// Block until the worker thread exits. After this returns, `state`
    /// is terminal.
    pub fn join(self: *MoveJob) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Worker entry point. Runs the move and updates state atomically.
    fn workerEntry(self: *MoveJob) void {
        const final_state = self.runMove() catch |err| blk: {
            self.recordError(err);
            break :blk State.failed;
        };
        // If the worker observed a cancel and stopped, prefer the
        // canceled state even if some files had moved.
        const observed_cancel = self.cancel_requested.load(.acquire);
        const terminal: State = if (observed_cancel and final_state != .succeeded)
            .canceled
        else
            final_state;

        self.state_atomic.store(@intFromEnum(terminal), .release);
        if (self.completion_cb) |cb| cb(self.completion_ctx, self.id, terminal);
    }

    fn runMove(self: *MoveJob) !State {
        // Pre-scan: count files and total bytes. This is also the
        // point where a non-existent src_root surfaces as
        // `error.SourceNotFound`.
        try self.scanSource();

        if (self.files.len > 0) {
            try makeDirAbsoluteIdempotent(self.dst_root);
            try self.moveListedFiles();
            if (self.cancel_requested.load(.acquire)) return .canceled;
            return .succeeded;
        }

        // Same-fs detection: stat src and the parent of dst (dst may not
        // exist yet). Matching `dev` ⇒ rename is safe.
        if (try self.detectSameFs()) {
            try self.doRenameMove();
            self.used_rename.store(true, .release);
            // Same-fs rename moved everything atomically; mirror the
            // accounting so callers see 100% progress.
            const total = self.total_bytes.load(.acquire);
            self.bytes_copied.store(total, .release);
            const total_files = self.total_files.load(.acquire);
            self.files_done.store(total_files, .release);
            return .succeeded;
        }

        // Cross-fs: ensure dst exists, recursively copy files via
        // copy_file_range, delete source files as we go, rmdir
        // source subdirectories on the way out.
        try makeDirAbsoluteIdempotent(self.dst_root);
        try self.copyTree(self.src_root, self.dst_root);

        if (self.cancel_requested.load(.acquire)) return .canceled;

        // Best-effort rmdir of source root (it may have stragglers we
        // failed to remove; surface those as an error rather than
        // silently leaving them).
        std.fs.deleteDirAbsolute(self.src_root) catch |err| switch (err) {
            error.FileNotFound => {},
            // If src_root has files we couldn't unlink, surface that.
            else => return err,
        };
        return .succeeded;
    }

    fn recordError(self: *MoveJob, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        if (self.error_message) |m| self.allocator.free(m);
        self.error_message = std.fmt.allocPrint(
            self.allocator,
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }

    fn recordErrorIfNone(self: *MoveJob, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        if (self.error_message != null) return;
        self.error_message = std.fmt.allocPrint(
            self.allocator,
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }

    // ── Pre-scan ──────────────────────────────────────────

    fn scanSource(self: *MoveJob) !void {
        var total_bytes: u64 = 0;
        var total_files: u32 = 0;
        if (self.files.len > 0) {
            for (self.files) |file| {
                total_bytes += file.length;
                total_files += 1;
            }
        } else {
            try scanDir(self.src_root, &total_bytes, &total_files);
        }
        self.total_bytes.store(total_bytes, .release);
        self.total_files.store(total_files, .release);
    }

    fn scanDir(path: []const u8, total_bytes: *u64, total_files: *u32) !void {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.SourceNotFound,
            else => return err,
        };
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    var sub_buf: [4096]u8 = undefined;
                    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ path, entry.name });
                    try scanDir(sub, total_bytes, total_files);
                },
                .file => {
                    const stat = dir.statFile(entry.name) catch continue;
                    total_bytes.* += stat.size;
                    total_files.* += 1;
                },
                else => {}, // symlinks, fifos, etc. — ignore (qBittorrent semantics)
            }
        }
    }

    // ── Same-FS detection ─────────────────────────────────

    fn detectSameFs(self: *MoveJob) !bool {
        // `std.fs.File.Stat` doesn't expose `dev`; reach into the
        // platform's raw stat via `posix.fstatat`. The helper returns
        // null if either side can't be stat'd, in which case we
        // conservatively treat the move as cross-fs.
        const same = try sameFs(self.src_root, self.dst_root);
        return same orelse false;
    }

    // ── Same-FS rename ────────────────────────────────────

    fn doRenameMove(self: *MoveJob) !void {
        // First make sure the dst's parent exists; renameat fails with
        // ENOENT if any component of new_path is missing.
        if (std.fs.path.dirname(self.dst_root)) |parent| {
            makeDirAbsoluteIdempotent(parent) catch {};
        }
        // The kernel handles every entry under src in one syscall.
        try posix.rename(self.src_root, self.dst_root);
    }

    // ── Cross-FS recursive copy ───────────────────────────

    fn moveListedFiles(self: *MoveJob) !void {
        for (self.files) |file| {
            if (self.cancel_requested.load(.acquire)) return;

            const src_path = try std.fs.path.join(self.allocator, &.{ self.src_root, file.relative_path });
            defer self.allocator.free(src_path);
            const dst_path = try std.fs.path.join(self.allocator, &.{ self.dst_root, file.relative_path });
            defer self.allocator.free(dst_path);

            if (std.fs.path.dirname(dst_path)) |parent| {
                try makePathAbsoluteIdempotent(parent);
            }

            try self.copyOneFile(src_path, dst_path);
        }
    }

    fn copyTree(self: *MoveJob, src_dir: []const u8, dst_dir: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(src_dir, .{ .iterate = true });
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (self.cancel_requested.load(.acquire)) return;

            var src_path_buf: [4096]u8 = undefined;
            var dst_path_buf: [4096]u8 = undefined;
            const src_path = try std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ src_dir, entry.name });
            const dst_path = try std.fmt.bufPrint(&dst_path_buf, "{s}/{s}", .{ dst_dir, entry.name });

            switch (entry.kind) {
                .directory => {
                    try makeDirAbsoluteIdempotent(dst_path);
                    try self.copyTree(src_path, dst_path);
                    if (self.cancel_requested.load(.acquire)) return;
                    std.fs.deleteDirAbsolute(src_path) catch {};
                },
                .file => try self.copyOneFile(src_path, dst_path),
                else => {},
            }
        }
    }

    fn copyOneFile(self: *MoveJob, src_path: []const u8, dst_path: []const u8) !void {
        try self.copyOneFileWithFsync(src_path, dst_path, fsyncFd);
    }

    fn copyOneFileWithFsync(
        self: *MoveJob,
        src_path: []const u8,
        dst_path: []const u8,
        fsync_fn: FsyncFn,
    ) !void {
        // Open both files. We pass NOFOLLOW on the source to refuse
        // following symlinks (matches qBittorrent's safety stance —
        // we wouldn't want a hostile symlink in the data dir to make
        // us copy /etc/shadow).
        const src_fd = try posix.open(src_path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
        defer posix.close(src_fd);

        // O_CREAT | O_TRUNC | O_EXCL mode would fail if dst already
        // exists. We accept overwrite semantics (qBittorrent does the
        // same). Use TRUNC to avoid leaving stale data past a
        // shorter-than-old write.
        const dst_fd = try posix.open(
            dst_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
            0o644,
        );
        defer posix.close(dst_fd);

        // Get the source file size for chunked transfer.
        const src_stat = try posix.fstat(src_fd);
        const total: u64 = @intCast(src_stat.size);
        var copied: u64 = 0;

        while (copied < total) {
            if (self.cancel_requested.load(.acquire)) return;

            const want = total - copied;
            // Cap a single transfer to keep cancellation responsive
            // (the kernel may otherwise loop internally for an entire
            // multi-GB file). 32 MiB matches the chunk size used by
            // tools like `coreutils cp`.
            const chunk: usize = @intCast(@min(want, 32 * 1024 * 1024));

            const n = try copyChunk(src_fd, copied, dst_fd, copied, chunk);
            if (n == 0) break; // EOF — file shorter than fstat reported

            copied += n;
            _ = self.bytes_copied.fetchAdd(n, .acq_rel);
        }

        // fsync the destination so a crash doesn't leave a half-written
        // file. We skip fsync on cancel since the file is incomplete
        // and will be cleaned up by the user's retry.
        if (!self.cancel_requested.load(.acquire)) {
            try fsync_fn(dst_fd);
        }

        if (!self.cancel_requested.load(.acquire) and copied == total) {
            posix.unlink(src_path) catch {};
            _ = self.files_done.fetchAdd(1, .acq_rel);
        }
    }

    fn spawnWorkerThread(self: *MoveJob) !std.Thread {
        return try std.Thread.spawn(.{}, workerEntry, .{self});
    }

    fn fsyncFd(fd: posix.fd_t) !void {
        try posix.fsync(fd);
    }
};

// ── Helpers ───────────────────────────────────────────────

/// Same-fs detection using the platform's `dev_t`. Returns null if
/// either path can't be stat'd (e.g. dst doesn't exist *and* its parent
/// doesn't either — caller treats that as "not safe to rename").
fn sameFs(src: []const u8, dst: []const u8) !?bool {
    if (comptime builtin.target.os.tag == .linux) {
        const src_stat = posix.fstatat(linux.AT.FDCWD, src, 0) catch return null;

        // Try dst first; fall back to dst's parent.
        const dst_stat = posix.fstatat(linux.AT.FDCWD, dst, 0) catch dst_blk: {
            const parent = std.fs.path.dirname(dst) orelse return null;
            break :dst_blk posix.fstatat(linux.AT.FDCWD, parent, 0) catch return null;
        };
        return src_stat.dev == dst_stat.dev;
    }
    // Non-Linux: we don't have the same `Stat.dev` shape easily;
    // skip the fast path. Cross-fs copy still works.
    return null;
}

/// `mkdir(path)` that ignores `PathAlreadyExists`. Mirrors the helper
/// the old `moveDataFiles` used inline.
fn makeDirAbsoluteIdempotent(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        // The caller passed an absolute path we constructed via
        // bufPrint(parent, name); a missing parent indicates dst_root
        // points outside any existing filesystem hierarchy. Surface
        // that explicitly.
        error.FileNotFound => return error.DestinationParentMissing,
        else => return err,
    };
}

fn makePathAbsoluteIdempotent(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => return error.DestinationParentMissing,
        else => return err,
    };
}

fn joinPathZ(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![:0]u8 {
    const joined = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(joined);
    return try allocator.dupeZ(u8, joined);
}

fn buildDirectoryPrefixes(allocator: std.mem.Allocator, directory_path: []const u8) ![][:0]u8 {
    var paths = std.ArrayListUnmanaged([:0]u8){};
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if (directory_path.len == 0) return &.{};

    var cursor: usize = if (directory_path[0] == std.fs.path.sep) 1 else 0;
    while (cursor < directory_path.len) : (cursor += 1) {
        if (directory_path[cursor] == std.fs.path.sep) {
            if (cursor > 0) {
                try paths.append(allocator, try allocator.dupeZ(u8, directory_path[0..cursor]));
            }
        }
    }
    try paths.append(allocator, try allocator.dupeZ(u8, directory_path));
    return try paths.toOwnedSlice(allocator);
}

/// Copy one chunk from src_fd@in_off to dst_fd@out_off. Uses
/// `posix.copy_file_range`, which on Linux ≥5.3 transparently handles
/// cross-fs copies (kernel falls back to its internal read/write loop
/// when an off-cpu reflink isn't possible) and on other platforms
/// emulates via pread/pwrite. Varuna's floor is 6.6 ⇒ this always
/// reaches the in-kernel fast path on Linux.
fn copyChunk(src_fd: posix.fd_t, in_off: u64, dst_fd: posix.fd_t, out_off: u64, len: usize) !usize {
    return try posix.copy_file_range(src_fd, in_off, dst_fd, out_off, len, 0);
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;
const RealIO = @import("../io/real_io.zig").RealIO;
const SimIO = @import("../io/sim_io.zig").SimIO;
const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

fn expectEventuallyState(job: *MoveJob, want: State, timeout_ms: u32) !void {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        if (job.progress().state == want) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.TimedOutWaitingForJobState;
}

fn expectEventLoopEventuallyState(job: *MoveJob, io: *RealIO, want: State, timeout_ms: u32) !void {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        job.tickOnEventLoop(io);
        if (job.progress().state == want) return;
        if (job.io_pending) {
            try io.tick(1);
        } else {
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
    }
    return error.TimedOutWaitingForJobState;
}

fn expectSimEventLoopEventuallyState(job: *MoveJob, io: *SimIO, want: State, max_ticks: u32) !void {
    var ticks: u32 = 0;
    while (ticks < max_ticks) : (ticks += 1) {
        job.tickOnEventLoop(io);
        if (job.progress().state == want) return;
        try io.tick(0);
    }
    return error.TimedOutWaitingForJobState;
}

const SimCtx = struct {
    calls: u32 = 0,
    result: ?Result = null,
};

fn simCallback(userdata: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
    const ctx: *SimCtx = @ptrCast(@alignCast(userdata.?));
    ctx.calls += 1;
    ctx.result = result;
    return .disarm;
}

fn simMkdir(io: *SimIO, path: [:0]const u8) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.mkdirat(.{ .dir_fd = MoveJob.at_fdcwd, .path = path, .mode = 0o755 }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .mkdirat => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simOpen(io: *SimIO, path: [:0]const u8, flags: posix.O, mode: posix.mode_t) !posix.fd_t {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.openat(.{ .dir_fd = MoveJob.at_fdcwd, .path = path, .flags = flags, .mode = mode }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .openat => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simWrite(io: *SimIO, fd: posix.fd_t, offset: u64, bytes: []const u8) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.write(.{ .fd = fd, .buf = bytes, .offset = offset }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.result.?) {
        .write => |r| try testing.expectEqual(bytes.len, try r),
        else => return error.UnexpectedMoveJobCompletion,
    }
}

fn simRead(io: *SimIO, fd: posix.fd_t, offset: u64, buf: []u8) !usize {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.read(.{ .fd = fd, .buf = buf, .offset = offset }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .read => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simFsync(io: *SimIO, fd: posix.fd_t) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.fsync(.{ .fd = fd, .datasync = false }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .fsync => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simClose(io: *SimIO, fd: posix.fd_t) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.close(.{ .fd = fd }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .close => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simSeedFile(io: *SimIO, path: [:0]const u8, bytes: []const u8) !void {
    const fd = try simOpen(io, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try simWrite(io, fd, 0, bytes);
    try simFsync(io, fd);
    try simClose(io, fd);
}

fn simReadPath(io: *SimIO, path: [:0]const u8, buf: []u8) !usize {
    const fd = try simOpen(io, path, .{ .ACCMODE = .RDONLY }, 0);
    const n = try simRead(io, fd, 0, buf);
    try simClose(io, fd);
    return n;
}

const CountingIO = struct {
    submitted: u32 = 0,
    mkdirat_submitted: u32 = 0,

    fn arm(self: *CountingIO, c: *Completion, op: ifc.Operation, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.submitted += 1;
        c.arm(op, ud, cb);
    }

    pub fn mkdirat(self: *CountingIO, op: ifc.MkdirAtOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.mkdirat_submitted += 1;
        try self.arm(c, .{ .mkdirat = op }, ud, cb);
    }

    pub fn renameat(self: *CountingIO, op: ifc.RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .renameat = op }, ud, cb);
    }

    pub fn openat(self: *CountingIO, op: ifc.OpenAtOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .openat = op }, ud, cb);
    }

    pub fn copy_file_range(self: *CountingIO, op: ifc.CopyFileRangeOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .copy_file_range = op }, ud, cb);
    }

    pub fn fsync(self: *CountingIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .fsync = op }, ud, cb);
    }

    pub fn unlinkat(self: *CountingIO, op: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .unlinkat = op }, ud, cb);
    }

    pub fn close(self: *CountingIO, op: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .close = op }, ud, cb);
    }

    pub fn closeSocket(_: *CountingIO, _: posix.fd_t) void {}
};

test "MoveJob: same-fs rename moves a single file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Stage src/foo and pick an absolute path; renameat doesn't work
    // through CWD-relative paths if CWD changes between scan and move.
    try tmp.dir.makeDir("src");
    const src_dir = try tmp.dir.openDir("src", .{});
    defer @constCast(&src_dir).close();
    {
        const f = try src_dir.createFile("foo.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }

    var path_buf: [4096]u8 = undefined;
    const realpath_buf = try std.fs.realpath(".", &path_buf);
    _ = realpath_buf;

    var src_path_buf: [4096]u8 = undefined;
    var dst_path_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_path_buf);
    // dst doesn't exist yet — use its parent's realpath.
    const tmp_root = try tmp.dir.realpath(".", &dst_path_buf);
    const dst_abs_owned = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs_owned);

    var job = try MoveJob.create(testing.allocator, 1, src_abs, dst_abs_owned);
    defer job.destroy();

    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);

    const p = job.progress();
    try testing.expectEqual(@as(u32, 1), p.total_files);
    try testing.expectEqual(@as(u32, 1), p.files_done);
    try testing.expectEqual(@as(u64, 5), p.total_bytes);
    try testing.expectEqual(@as(u64, 5), p.bytes_copied);
    try testing.expect(p.used_rename); // same-fs ⇒ rename path

    // Verify dst exists with content; src is gone.
    const moved = try tmp.dir.openFile("dst/foo.txt", .{});
    defer @constCast(&moved).close();
    var read_buf: [16]u8 = undefined;
    const n = try moved.readAll(&read_buf);
    try testing.expectEqualStrings("hello", read_buf[0..n]);

    try testing.expectError(error.FileNotFound, tmp.dir.openFile("src/foo.txt", .{}));
}

test "MoveJob: same-fs rename moves a directory tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/sub");
    {
        const f = try tmp.dir.createFile("src/a.bin", .{});
        defer f.close();
        try f.writeAll("aaa");
    }
    {
        const f = try tmp.dir.createFile("src/sub/b.bin", .{});
        defer f.close();
        try f.writeAll("bbbbb");
    }

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var job = try MoveJob.create(testing.allocator, 2, src_abs, dst_abs);
    defer job.destroy();
    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);

    const p = job.progress();
    try testing.expectEqual(@as(u32, 2), p.total_files);
    try testing.expectEqual(@as(u32, 2), p.files_done);
    try testing.expectEqual(@as(u64, 8), p.total_bytes);

    const a = try tmp.dir.openFile("dst/a.bin", .{});
    defer @constCast(&a).close();
    const b = try tmp.dir.openFile("dst/sub/b.bin", .{});
    defer @constCast(&b).close();
}

test "MoveJob: progress snapshot is observable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("src");
    {
        const f = try tmp.dir.createFile("src/x.bin", .{});
        defer f.close();
        try f.writeAll("xxxxxxxxxxxxxxxx"); // 16 bytes
    }

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var job = try MoveJob.create(testing.allocator, 3, src_abs, dst_abs);
    defer job.destroy();

    // Pre-start: state is created.
    try testing.expectEqual(State.created, job.progress().state);

    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);

    const p = job.progress();
    try testing.expectEqual(State.succeeded, p.state);
    try testing.expectEqual(@as(u64, 16), p.total_bytes);
    try testing.expectEqual(@as(u64, 16), p.bytes_copied);
}

test "MoveJob: missing source surfaces SourceNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [4096]u8 = undefined;
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const src_abs = try std.fmt.allocPrint(testing.allocator, "{s}/nope", .{tmp_root});
    defer testing.allocator.free(src_abs);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var job = try MoveJob.create(testing.allocator, 4, src_abs, dst_abs);
    defer job.destroy();
    try job.start(null, null);
    try expectEventuallyState(job, .failed, 5000);

    const p = job.progress();
    try testing.expectEqual(State.failed, p.state);
    try testing.expect(p.error_message != null);
}

test "MoveJob: requestCancel before start has no effect on a fresh job" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var job = try MoveJob.create(testing.allocator, 5, src_abs, dst_abs);
    defer job.destroy();
    job.requestCancel();
    // Without a start() call, state stays `.created`.
    try testing.expectEqual(State.created, job.progress().state);
}

test "MoveJob: spawn failure restores created state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    const Hooks = struct {
        fn failSpawn(_: *MoveJob) anyerror!std.Thread {
            return error.TestSpawnFailed;
        }
    };

    var job = try MoveJob.create(testing.allocator, 6, src_abs, dst_abs);
    defer job.destroy();

    try testing.expectError(error.TestSpawnFailed, job.startWithSpawner(null, null, Hooks.failSpawn));
    try testing.expectEqual(State.created, job.progress().state);

    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);
}

test "MoveJob: fsync failure keeps source file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dst");
    {
        const f = try tmp.dir.createFile("src/leaf.txt", .{});
        defer f.close();
        try f.writeAll("payload");
    }

    var src_dir_buf: [4096]u8 = undefined;
    var dst_dir_buf: [4096]u8 = undefined;
    var src_file_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_dir_buf);
    const dst_abs = try tmp.dir.realpath("dst", &dst_dir_buf);
    const src_file_abs = try tmp.dir.realpath("src/leaf.txt", &src_file_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_file_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst/leaf.txt", .{tmp_root});
    defer testing.allocator.free(dst_file_abs);

    const Hooks = struct {
        fn failFsync(_: posix.fd_t) anyerror!void {
            return error.TestFsyncFailure;
        }
    };

    var job = try MoveJob.create(testing.allocator, 7, src_abs, dst_abs);
    defer job.destroy();

    try testing.expectError(error.TestFsyncFailure, job.copyOneFileWithFsync(src_file_abs, dst_file_abs, Hooks.failFsync));
    const source = try tmp.dir.openFile("src/leaf.txt", .{});
    defer @constCast(&source).close();
    var read_buf: [16]u8 = undefined;
    const n = try source.readAll(&read_buf);
    try testing.expectEqualStrings("payload", read_buf[0..n]);
    try testing.expectEqual(@as(u32, 0), job.files_done.load(.acquire));
}

test "MoveJob: source files are unlinked after rename succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");
    {
        const f = try tmp.dir.createFile("src/leaf.txt", .{});
        defer f.close();
        try f.writeAll("payload");
    }

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var job = try MoveJob.create(testing.allocator, 6, src_abs, dst_abs);
    defer job.destroy();
    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);

    // Source dir is gone after a same-fs rename.
    try testing.expectError(error.FileNotFound, tmp.dir.openDir("src", .{}));
    // Destination has the file.
    const f = try tmp.dir.openFile("dst/leaf.txt", .{});
    defer @constCast(&f).close();
}

test "MoveJob: completion callback fires with terminal state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    const Box = struct {
        var fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        var observed_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
        fn cb(_: ?*anyopaque, _: JobId, state: State) void {
            _ = fired.fetchAdd(1, .acq_rel);
            observed_state.store(@intFromEnum(state), .release);
        }
    };
    Box.fired.store(0, .release);
    Box.observed_state.store(0, .release);

    var job = try MoveJob.create(testing.allocator, 7, src_abs, dst_abs);
    defer job.destroy();
    try job.start(null, Box.cb);
    try expectEventuallyState(job, .succeeded, 5000);

    // Wait for the callback to fire (it runs slightly after the
    // worker thread sets the terminal state).
    var attempts: u32 = 0;
    while (Box.fired.load(.acquire) == 0 and attempts < 200) : (attempts += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 1), Box.fired.load(.acquire));
    try testing.expectEqual(@intFromEnum(State.succeeded), Box.observed_state.load(.acquire));
}

test "MoveJob: manifest-scoped move leaves unrelated siblings in source root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/torrent/sub");
    {
        const f = try tmp.dir.createFile("src/torrent/sub/piece.bin", .{});
        defer f.close();
        try f.writeAll("payload");
    }
    {
        const f = try tmp.dir.createFile("src/unrelated.bin", .{});
        defer f.close();
        try f.writeAll("keep");
    }

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/sub/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 8, src_abs, dst_abs, &files);
    defer job.destroy();

    try job.start(null, null);
    try expectEventuallyState(job, .succeeded, 5000);

    const moved = try tmp.dir.openFile("dst/torrent/sub/piece.bin", .{});
    defer @constCast(&moved).close();
    var moved_buf: [16]u8 = undefined;
    const moved_n = try moved.readAll(&moved_buf);
    try testing.expectEqualStrings("payload", moved_buf[0..moved_n]);

    const sibling = try tmp.dir.openFile("src/unrelated.bin", .{});
    defer @constCast(&sibling).close();
    var sibling_buf: [16]u8 = undefined;
    const sibling_n = try sibling.readAll(&sibling_buf);
    try testing.expectEqualStrings("keep", sibling_buf[0..sibling_n]);

    try testing.expectError(error.FileNotFound, tmp.dir.openFile("src/torrent/sub/piece.bin", .{}));
}

test "MoveJob: event-loop manifest move relocates one file without sibling damage" {
    var io = RealIO.init(.{ .entries = 32 }) catch return error.SkipZigTest;
    defer io.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/torrent/sub");
    {
        const f = try tmp.dir.createFile("src/torrent/sub/piece.bin", .{});
        defer f.close();
        try f.writeAll("payload");
    }
    {
        const f = try tmp.dir.createFile("src/unrelated.bin", .{});
        defer f.close();
        try f.writeAll("keep");
    }

    var src_buf: [4096]u8 = undefined;
    var root_buf: [4096]u8 = undefined;
    const src_abs = try tmp.dir.realpath("src", &src_buf);
    const tmp_root = try tmp.dir.realpath(".", &root_buf);
    const dst_abs = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{tmp_root});
    defer testing.allocator.free(dst_abs);

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/sub/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 9, src_abs, dst_abs, &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectEventLoopEventuallyState(job, &io, .succeeded, 5000);

    const p = job.progress();
    try testing.expectEqual(State.succeeded, p.state);
    try testing.expectEqual(@as(u32, 1), p.files_done);
    try testing.expectEqual(@as(u64, 7), p.bytes_copied);

    const moved = try tmp.dir.openFile("dst/torrent/sub/piece.bin", .{});
    defer @constCast(&moved).close();
    var moved_buf: [16]u8 = undefined;
    const moved_n = try moved.readAll(&moved_buf);
    try testing.expectEqualStrings("payload", moved_buf[0..moved_n]);

    const sibling = try tmp.dir.openFile("src/unrelated.bin", .{});
    defer @constCast(&sibling).close();
    var sibling_buf: [16]u8 = undefined;
    const sibling_n = try sibling.readAll(&sibling_buf);
    try testing.expectEqualStrings("keep", sibling_buf[0..sibling_n]);

    try testing.expectError(error.FileNotFound, tmp.dir.openFile("src/torrent/sub/piece.bin", .{}));
}

test "MoveJob: event-loop EXDEV fallback copies bytes and fsyncs destination in SimIO" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{ .renameat_exdev_probability = 1.0 },
    });
    defer io.deinit();

    try simMkdir(&io, "/src");
    try simMkdir(&io, "/src/torrent");
    try simSeedFile(&io, "/src/torrent/piece.bin", "payload");

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 10, "/src", "/dst", &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectSimEventLoopEventuallyState(job, &io, .succeeded, 200);

    const p = job.progress();
    try testing.expectEqual(State.succeeded, p.state);
    try testing.expectEqual(@as(u64, 7), p.bytes_copied);
    try testing.expectEqual(@as(u32, 1), p.files_done);
    try testing.expect(!p.used_rename);

    io.crash();

    var dst_buf: [16]u8 = undefined;
    const dst_n = try simReadPath(&io, "/dst/torrent/piece.bin", &dst_buf);
    try testing.expectEqualStrings("payload", dst_buf[0..dst_n]);
    try testing.expectError(error.FileNotFound, simOpen(&io, "/src/torrent/piece.bin", .{ .ACCMODE = .RDONLY }, 0));
}

test "MoveJob: event-loop copy fallback keeps source when destination fsync fails" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{ .renameat_exdev_probability = 1.0 },
    });
    defer io.deinit();

    try simMkdir(&io, "/src");
    try simMkdir(&io, "/src/torrent");
    try simSeedFile(&io, "/src/torrent/piece.bin", "payload");
    io.config.faults.fsync_error_probability = 1.0;

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 11, "/src", "/dst", &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectSimEventLoopEventuallyState(job, &io, .failed, 200);

    const p = job.progress();
    try testing.expectEqual(State.failed, p.state);
    try testing.expectEqualStrings("InputOutput", p.error_message.?);
    try testing.expectEqual(@as(u32, 0), p.files_done);

    var src_buf: [16]u8 = undefined;
    const src_n = try simReadPath(&io, "/src/torrent/piece.bin", &src_buf);
    try testing.expectEqualStrings("payload", src_buf[0..src_n]);
}

test "MoveJob: event-loop copy fallback keeps source when file close fails" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{ .renameat_exdev_probability = 1.0 },
    });
    defer io.deinit();

    try simMkdir(&io, "/src");
    try simMkdir(&io, "/src/torrent");
    try simSeedFile(&io, "/src/torrent/piece.bin", "payload");
    io.config.faults.close_error_probability = 1.0;

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 12, "/src", "/dst", &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectSimEventLoopEventuallyState(job, &io, .failed, 200);

    const p = job.progress();
    try testing.expectEqual(State.failed, p.state);
    try testing.expectEqualStrings("InputOutput", p.error_message.?);
    try testing.expectEqual(@as(u32, 0), p.files_done);

    io.config.faults.close_error_probability = 0.0;
    var src_buf: [16]u8 = undefined;
    const src_n = try simReadPath(&io, "/src/torrent/piece.bin", &src_buf);
    try testing.expectEqualStrings("payload", src_buf[0..src_n]);
}

test "MoveJob: scheduler policy submits one operation per active job tick" {
    var files_a = [_]MoveJob.File{.{ .relative_path = "a.bin", .length = 1 }};
    var files_b = [_]MoveJob.File{.{ .relative_path = "b.bin", .length = 1 }};

    var job_a = try MoveJob.createForFiles(testing.allocator, 13, "/src-a", "/dst-a", &files_a);
    defer job_a.destroy();
    var job_b = try MoveJob.createForFiles(testing.allocator, 14, "/src-b", "/dst-b", &files_b);
    defer job_b.destroy();

    try job_a.startOnEventLoop(null, null);
    try job_b.startOnEventLoop(null, null);

    var io = CountingIO{};
    job_a.tickOnEventLoop(&io);
    job_b.tickOnEventLoop(&io);

    try testing.expectEqual(@as(u32, 2), io.submitted);
    try testing.expectEqual(@as(u32, 2), io.mkdirat_submitted);

    job_a.tickOnEventLoop(&io);
    job_b.tickOnEventLoop(&io);
    try testing.expectEqual(@as(u32, 2), io.submitted);
}

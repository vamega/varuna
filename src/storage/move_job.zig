//! Async data-file move job — backs the new
//! `POST /api/v2/varuna/torrents/move` endpoint and replaces the
//! synchronous `setLocation` path that used to block the RPC handler
//! thread for the duration of a multi-GB cross-filesystem copy.
//!
//! ## Event-loop production path
//!
//! Production moves are manifest-scoped and run as an event-loop state
//! machine through the IO contract (`mkdirat`, `renameat`, `openat`,
//! `copy_file_chunk`, `fchown`, `fchmod`, `fsync`, `unlinkat`). This keeps daemon relocation
//! out of ad hoc blocking filesystem threads and lets the main loop
//! schedule move progress alongside peer, tracker, RPC, and recheck I/O.
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
//! falls back to `openat` + semantic copy chunks + destination metadata
//! preservation + destination fsync + source unlink. After either route, source and destination parent
//! directories are fsynced so completed moves survive crashes.
//!
//! ## Progress accounting
//!
//! `total_bytes` is computed during a one-shot pre-scan; `bytes_copied`
//! advances as `copy_file_chunk` returns positive byte counts. The
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

const copy_chunk_bytes: u64 = 4 * 1024 * 1024;
const metadata_mode_mask: u32 = 0o7777;

// ── Public types ──────────────────────────────────────────

pub const JobId = u64;

pub const State = enum(u8) {
    /// Created but event-loop state machine has not started yet.
    created = 0,
    /// Event-loop state machine running.
    running = 1,
    /// Data successfully moved.
    succeeded = 2,
    /// Move failed with an error.
    failed = 3,
    /// Cancellation observed.
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

test "MoveJob: exposes only event-loop start API" {
    try std.testing.expect(!@hasDecl(MoveJob, "start"));
    try std.testing.expect(!@hasDecl(MoveJob, "startWithSpawner"));
}

/// Optional one-shot completion callback. Fires from the event-loop tick
/// once the job exits its terminal state. The callback **must not**
/// block, must not call back into the job's `requestCancel`, and must
/// be safe to invoke from the event-loop thread.
pub const CompletionCallback = *const fn (
    ctx: ?*anyopaque,
    id: JobId,
    state: State,
) void;

// ── MoveJob ───────────────────────────────────────────────

pub const MoveJob = struct {
    const at_fdcwd: posix.fd_t = if (builtin.target.os.tag == .linux)
        linux.AT.FDCWD
    else
        -100;

    const Runner = enum {
        none,
        event_loop,
    };

    const EventStage = enum {
        idle,
        mkdir_next,
        rename_file,
        stat_src_file,
        open_copy_session,
        open_src,
        open_dst,
        copy_chunk,
        fchown_dst_file,
        fchmod_dst_file,
        fsync_dst_file,
        close_src_file,
        close_dst_file,
        unlink_src_file,
        open_fsync_dir,
        fsync_dir,
        close_dir,
        stat_dir_metadata,
        open_dir_metadata,
        fchown_dir_metadata,
        fchmod_dir_metadata,
        close_dir_metadata,
        close_copy_session,
        cleanup_copy_session,
        cleanup_src_file,
        cleanup_dst_file,
        cleanup_dst_path,
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

    const DirMetadataEntry = struct {
        relative_path: []u8,
        src_path_z: ?[:0]u8 = null,
        dst_path_z: ?[:0]u8 = null,
        stat: linux.Statx = std.mem.zeroes(linux.Statx),
        fd: posix.fd_t = -1,
    };

    id: JobId,
    allocator: std.mem.Allocator,

    /// Owned copies of source and destination root directories. Both
    /// MUST be absolute (the SessionManager validates this on submit).
    src_root: []u8,
    dst_root: []u8,
    files: []OwnedFile = &.{},

    // ── Atomic progress (pollable from RPC / manager code) ─
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

    runner: Runner = .none,

    // ── Event-loop move state ─────────────────────────────
    io_completion: ifc.Completion = .{},
    io_pending: bool = false,
    io_result: ?ifc.Result = null,
    event_stage: EventStage = .idle,
    current_file_index: usize = 0,
    mkdir_paths: [][:0]u8 = &.{},
    mkdir_index: usize = 0,
    dir_metadata: []DirMetadataEntry = &.{},
    dir_metadata_index: usize = 0,
    src_path_z: ?[:0]u8 = null,
    dst_path_z: ?[:0]u8 = null,
    src_parent_z: ?[:0]u8 = null,
    dst_parent_z: ?[:0]u8 = null,
    src_fd: posix.fd_t = -1,
    dst_fd: posix.fd_t = -1,
    dir_fd: posix.fd_t = -1,
    copy_session: ifc.CopyFileSession = .{},
    copy_session_open: bool = false,
    src_file_stat: linux.Statx = std.mem.zeroes(linux.Statx),
    copy_offset: u64 = 0,
    dst_partial_created: bool = false,
    pending_dir_sync: DirectorySyncKind = .dst_parent,
    cleanup_terminal: State = .failed,

    // ── Optional completion callback ──────────────────────
    completion_ctx: ?*anyopaque = null,
    completion_cb: ?CompletionCallback = null,

    /// Allocate a new MoveJob. The job is in state `.created` and is
    /// not running — call `startOnEventLoop` before ticking it.
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
    /// event-loop state machine is still running, callers must drain or
    /// cancel it before destroying the job.
    pub fn destroy(self: *MoveJob) void {
        self.freeEventLoopFileState();
        self.allocator.free(self.src_root);
        self.allocator.free(self.dst_root);
        for (self.files) |file| self.allocator.free(file.relative_path);
        if (self.files.len > 0) self.allocator.free(self.files);
        self.freeDirMetadataEntries();
        if (self.error_message) |m| self.allocator.free(m);
        const allocator = self.allocator;
        allocator.destroy(self);
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
        const dir_metadata = try buildDirMetadataEntries(self.allocator, self.files);
        errdefer freeDirMetadataSlice(self.allocator, dir_metadata);

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
        self.dir_metadata = dir_metadata;
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
            .stat_src_file => try self.submitStatSourceFile(io),
            .open_copy_session => try self.submitOpenCopySession(io),
            .open_src => try self.submitOpenSource(io),
            .open_dst => try self.submitOpenDestination(io),
            .copy_chunk => try self.submitCopyChunk(io),
            .fchown_dst_file => try self.submitFchownDestinationFile(io),
            .fchmod_dst_file => try self.submitFchmodDestinationFile(io),
            .fsync_dst_file => try self.submitFsyncDestinationFile(io),
            .close_src_file => try self.submitCloseSourceFile(io),
            .close_dst_file => try self.submitCloseDestinationFile(io),
            .unlink_src_file => try self.submitUnlinkSource(io),
            .open_fsync_dir => try self.submitOpenDirectoryForFsync(io),
            .fsync_dir => try self.submitFsyncDirectory(io),
            .close_dir => try self.submitCloseDirectory(io),
            .stat_dir_metadata => try self.submitStatDirectoryMetadata(io),
            .open_dir_metadata => try self.submitOpenDirectoryMetadata(io),
            .fchown_dir_metadata => try self.submitFchownDirectoryMetadata(io),
            .fchmod_dir_metadata => try self.submitFchmodDirectoryMetadata(io),
            .close_dir_metadata => try self.submitCloseDirectoryMetadata(io),
            .close_copy_session => try self.submitCloseCopySession(io, .done),
            .cleanup_copy_session, .cleanup_src_file, .cleanup_dst_file, .cleanup_dst_path, .cleanup_dir => try self.submitNextCleanupClose(io),
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
            self.freeEventLoopFileState();
            if (self.dir_metadata.len > 0) {
                self.dir_metadata_index = 0;
                self.event_stage = .stat_dir_metadata;
            } else if (self.copy_session_open) {
                self.event_stage = .close_copy_session;
            } else {
                self.event_stage = .done;
                self.completeEventLoop(.succeeded);
            }
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
        self.src_file_stat = std.mem.zeroes(linux.Statx);
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
                            self.event_stage = .stat_src_file;
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
            .stat_src_file => {
                switch (result) {
                    .statx => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = if (self.copy_session_open) .open_src else .open_copy_session;
            },
            .open_copy_session => {
                switch (result) {
                    .open_copy_file_session => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.copy_session_open = true;
                self.event_stage = .open_src;
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
                self.dst_partial_created = true;
                self.event_stage = .copy_chunk;
            },
            .copy_chunk => {
                const n = switch (result) {
                    .copy_file_chunk => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                if (n == 0) return error.UnexpectedEndOfFile;
                self.copy_offset += n;
                _ = self.bytes_copied.fetchAdd(n, .acq_rel);
                const file = self.files[self.current_file_index];
                if (self.copy_offset > file.length) return error.UnexpectedMoveJobCompletion;
                if (self.copy_offset >= file.length) {
                    self.event_stage = .fchown_dst_file;
                } else {
                    self.event_stage = .copy_chunk;
                }
            },
            .fchown_dst_file => {
                switch (result) {
                    .fchown => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .fchmod_dst_file;
            },
            .fchmod_dst_file => {
                switch (result) {
                    .fchmod => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .fsync_dst_file;
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
                self.dst_partial_created = false;
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
            .stat_dir_metadata => {
                switch (result) {
                    .statx => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .open_dir_metadata;
            },
            .open_dir_metadata => {
                switch (result) {
                    .openat => |r| self.currentDirMetadata().fd = try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .fchown_dir_metadata;
            },
            .fchown_dir_metadata => {
                switch (result) {
                    .fchown => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .fchmod_dir_metadata;
            },
            .fchmod_dir_metadata => {
                switch (result) {
                    .fchmod => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.event_stage = .close_dir_metadata;
            },
            .close_dir_metadata => {
                const r = switch (result) {
                    .close => |r| r,
                    else => return error.UnexpectedMoveJobCompletion,
                };
                self.currentDirMetadata().fd = -1;
                try r;
                self.dir_metadata_index += 1;
                if (self.dir_metadata_index >= self.dir_metadata.len) {
                    self.freeDirMetadataRuntimePaths();
                    self.event_stage = if (self.copy_session_open) .close_copy_session else .done;
                } else {
                    self.event_stage = .stat_dir_metadata;
                }
            },
            .close_copy_session => {
                switch (result) {
                    .close_copy_file_session => |r| try r,
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.copy_session_open = false;
                self.event_stage = .done;
            },
            .cleanup_copy_session => {
                switch (result) {
                    .close_copy_file_session => |r| r catch |err| {
                        self.recordErrorIfNone(err);
                        self.cleanup_terminal = .failed;
                    },
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.copy_session_open = false;
                self.event_stage = .cleanup_src_file;
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
                    .cleanup_dst_file => .cleanup_dst_path,
                    .cleanup_dir => .done,
                    else => unreachable,
                };
                if (self.event_stage == .done) {
                    self.completeEventLoop(self.cleanup_terminal);
                }
            },
            .cleanup_dst_path => {
                switch (result) {
                    .unlinkat => |r| r catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => {
                            self.recordErrorIfNone(err);
                            self.cleanup_terminal = .failed;
                        },
                    },
                    else => return error.UnexpectedMoveJobCompletion,
                }
                self.dst_partial_created = false;
                self.event_stage = .cleanup_dir;
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

    fn submitStatSourceFile(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.statx(.{
            .dir_fd = at_fdcwd,
            .path = self.src_path_z.?,
            .flags = linux.AT.SYMLINK_NOFOLLOW,
            .mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_UID | linux.STATX_GID,
            .buf = &self.src_file_stat,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenCopySession(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.open_copy_file_session(.{
            .session = &self.copy_session,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenDestination(self: *MoveJob, io: anytype) !void {
        const mode: posix.mode_t = @intCast(self.src_file_stat.mode & metadata_mode_mask);
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = self.dst_path_z.?,
            .flags = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
            .mode = mode,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCopyChunk(self: *MoveJob, io: anytype) !void {
        if (self.cancel_requested.load(.acquire)) {
            self.beginEventLoopCleanup(io, .canceled);
            return;
        }
        const file = self.files[self.current_file_index];
        if (self.copy_offset >= file.length) {
            self.event_stage = .fchown_dst_file;
            return;
        }
        const remaining = file.length - self.copy_offset;
        const chunk: usize = @intCast(@min(remaining, copy_chunk_bytes));
        // Cross-filesystem moves cannot use the same-filesystem reflink
        // wins that make copy_file_range attractive. Stay on io_uring's
        // native splice-backed copy session for now; reconsider
        // copy_file_range on a backend threadpool only if profiling gives
        // a concrete reason.
        self.io_pending = true;
        io.copy_file_chunk(.{
            .session = &self.copy_session,
            .src_fd = self.src_fd,
            .src_offset = self.copy_offset,
            .dst_fd = self.dst_fd,
            .dst_offset = self.copy_offset,
            .len = chunk,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFchownDestinationFile(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.fchown(.{
            .fd = self.dst_fd,
            .uid = self.src_file_stat.uid,
            .gid = self.src_file_stat.gid,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFchmodDestinationFile(self: *MoveJob, io: anytype) !void {
        self.io_pending = true;
        io.fchmod(.{
            .fd = self.dst_fd,
            .mode = @intCast(self.src_file_stat.mode & metadata_mode_mask),
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

    fn submitStatDirectoryMetadata(self: *MoveJob, io: anytype) !void {
        if (self.dir_metadata_index >= self.dir_metadata.len) {
            self.event_stage = if (self.copy_session_open) .close_copy_session else .done;
            return;
        }
        const entry = self.currentDirMetadata();
        if (entry.src_path_z == null) {
            entry.src_path_z = try joinPathZ(self.allocator, self.src_root, entry.relative_path);
            errdefer {
                if (entry.src_path_z) |path| self.allocator.free(path);
                entry.src_path_z = null;
            }
            entry.dst_path_z = try joinPathZ(self.allocator, self.dst_root, entry.relative_path);
        }
        self.io_pending = true;
        io.statx(.{
            .dir_fd = at_fdcwd,
            .path = entry.src_path_z.?,
            .flags = linux.AT.SYMLINK_NOFOLLOW,
            .mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_UID | linux.STATX_GID,
            .buf = &entry.stat,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitOpenDirectoryMetadata(self: *MoveJob, io: anytype) !void {
        const entry = self.currentDirMetadata();
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = entry.dst_path_z.?,
            .flags = .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
            .mode = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFchownDirectoryMetadata(self: *MoveJob, io: anytype) !void {
        const entry = self.currentDirMetadata();
        self.io_pending = true;
        io.fchown(.{
            .fd = entry.fd,
            .uid = entry.stat.uid,
            .gid = entry.stat.gid,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitFchmodDirectoryMetadata(self: *MoveJob, io: anytype) !void {
        const entry = self.currentDirMetadata();
        self.io_pending = true;
        io.fchmod(.{
            .fd = entry.fd,
            .mode = @intCast(entry.stat.mode & metadata_mode_mask),
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCloseDirectoryMetadata(self: *MoveJob, io: anytype) !void {
        const entry = self.currentDirMetadata();
        if (entry.fd < 0) {
            self.dir_metadata_index += 1;
            self.event_stage = .stat_dir_metadata;
            return;
        }
        self.io_pending = true;
        io.close(.{
            .fd = entry.fd,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCloseCopySession(self: *MoveJob, io: anytype, next: EventStage) !void {
        _ = next;
        if (!self.copy_session_open) {
            self.event_stage = .done;
            return;
        }
        self.io_pending = true;
        io.close_copy_file_session(.{
            .session = &self.copy_session,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
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
                .cleanup_copy_session => {
                    if (self.copy_session_open) {
                        self.io_pending = true;
                        io.close_copy_file_session(.{
                            .session = &self.copy_session,
                        }, &self.io_completion, self, eventLoopCallback) catch |err| {
                            self.io_pending = false;
                            return err;
                        };
                        return;
                    }
                    self.event_stage = .cleanup_src_file;
                },
                .cleanup_src_file => {
                    if (self.src_fd >= 0) return self.submitCloseFd(io, self.src_fd);
                    self.event_stage = .cleanup_dst_file;
                },
                .cleanup_dst_file => {
                    if (self.dst_fd >= 0) return self.submitCloseFd(io, self.dst_fd);
                    self.event_stage = .cleanup_dst_path;
                },
                .cleanup_dst_path => {
                    if (self.dst_partial_created) {
                        self.io_pending = true;
                        io.unlinkat(.{
                            .dir_fd = at_fdcwd,
                            .path = self.dst_path_z.?,
                            .flags = 0,
                        }, &self.io_completion, self, eventLoopCallback) catch |err| {
                            self.io_pending = false;
                            return err;
                        };
                        return;
                    }
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
        self.takeOpenDirMetadataFdForCleanup();
        self.event_stage = .cleanup_copy_session;
        self.submitNextCleanupClose(io) catch |err| {
            self.recordErrorIfNone(err);
            self.copy_session_open = false;
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
        self.dst_partial_created = false;
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

    /// Request cancellation. Idempotent. The event-loop state machine
    /// observes this between files and after each copy chunk.
    /// The caller polls `progress()` for the final state.
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

    fn currentDirMetadata(self: *MoveJob) *DirMetadataEntry {
        assert(self.dir_metadata_index < self.dir_metadata.len);
        return &self.dir_metadata[self.dir_metadata_index];
    }

    fn takeOpenDirMetadataFdForCleanup(self: *MoveJob) void {
        if (self.dir_fd >= 0) return;
        for (self.dir_metadata) |*entry| {
            if (entry.fd >= 0) {
                self.dir_fd = entry.fd;
                entry.fd = -1;
                return;
            }
        }
    }

    fn freeDirMetadataRuntimePaths(self: *MoveJob) void {
        for (self.dir_metadata) |*entry| {
            if (entry.src_path_z) |path| self.allocator.free(path);
            if (entry.dst_path_z) |path| self.allocator.free(path);
            entry.src_path_z = null;
            entry.dst_path_z = null;
        }
    }

    fn freeDirMetadataEntries(self: *MoveJob) void {
        freeDirMetadataSlice(self.allocator, self.dir_metadata);
        self.dir_metadata = &.{};
        self.dir_metadata_index = 0;
    }
};

// ── Helpers ───────────────────────────────────────────────

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

fn buildDirMetadataEntries(allocator: std.mem.Allocator, files: []const MoveJob.OwnedFile) ![]MoveJob.DirMetadataEntry {
    var entries = std.ArrayListUnmanaged(MoveJob.DirMetadataEntry){};
    errdefer freeDirMetadataSlice(allocator, entries.items);

    for (files) |file| {
        const parent = std.fs.path.dirname(file.relative_path) orelse continue;
        if (parent.len == 0) continue;

        var cursor: usize = 0;
        while (cursor < parent.len) : (cursor += 1) {
            if (parent[cursor] == std.fs.path.sep) {
                if (cursor > 0) try appendDirMetadataEntry(allocator, &entries, parent[0..cursor]);
            }
        }
        try appendDirMetadataEntry(allocator, &entries, parent);
    }

    std.sort.heap(MoveJob.DirMetadataEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: MoveJob.DirMetadataEntry, b: MoveJob.DirMetadataEntry) bool {
            return pathDepth(a.relative_path) > pathDepth(b.relative_path);
        }
    }.lessThan);

    return try entries.toOwnedSlice(allocator);
}

fn appendDirMetadataEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(MoveJob.DirMetadataEntry),
    relative_path: []const u8,
) !void {
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.relative_path, relative_path)) return;
    }
    try entries.append(allocator, .{
        .relative_path = try allocator.dupe(u8, relative_path),
    });
}

fn pathDepth(path: []const u8) usize {
    if (path.len == 0) return 0;
    var depth: usize = 1;
    for (path) |ch| {
        if (ch == std.fs.path.sep) depth += 1;
    }
    return depth;
}

fn freeDirMetadataSlice(allocator: std.mem.Allocator, entries: []MoveJob.DirMetadataEntry) void {
    for (entries) |*entry| {
        allocator.free(entry.relative_path);
        if (entry.src_path_z) |path| allocator.free(path);
        if (entry.dst_path_z) |path| allocator.free(path);
    }
    if (entries.len > 0) allocator.free(entries);
}

// ── Tests ─────────────────────────────────────────────────

const testing = std.testing;
const RealIO = @import("../io/real_io.zig").RealIO;
const SimIO = @import("../io/sim_io.zig").SimIO;
const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

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

fn simFchmod(io: *SimIO, fd: posix.fd_t, mode: posix.mode_t) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.fchmod(.{ .fd = fd, .mode = mode }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .fchmod => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simFchown(io: *SimIO, fd: posix.fd_t, uid: u32, gid: u32) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.fchown(.{ .fd = fd, .uid = uid, .gid = gid }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .fchown => |r| try r,
        else => error.UnexpectedMoveJobCompletion,
    };
}

fn simSetMetadata(io: *SimIO, path: [:0]const u8, flags: posix.O, uid: u32, gid: u32, mode: posix.mode_t) !void {
    const fd = try simOpen(io, path, flags, 0);
    try simFchown(io, fd, uid, gid);
    try simFchmod(io, fd, mode);
    try simClose(io, fd);
}

fn simStatPath(io: *SimIO, path: [:0]const u8) !linux.Statx {
    var stat_buf: linux.Statx = undefined;
    var c = Completion{};
    var ctx = SimCtx{};
    try io.statx(.{
        .dir_fd = MoveJob.at_fdcwd,
        .path = path,
        .flags = linux.AT.SYMLINK_NOFOLLOW,
        .mask = linux.STATX_BASIC_STATS,
        .buf = &stat_buf,
    }, &c, &ctx, simCallback);
    try io.tick(0);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.result.?) {
        .statx => |r| try r,
        else => return error.UnexpectedMoveJobCompletion,
    }
    return stat_buf;
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
    open_copy_file_session_submitted: u32 = 0,
    copy_file_chunk_submitted: u32 = 0,
    close_copy_file_session_submitted: u32 = 0,
    fchown_submitted: u32 = 0,
    fchmod_submitted: u32 = 0,
    close_submitted: u32 = 0,
    last_close_fd: posix.fd_t = -1,

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

    pub fn statx(self: *CountingIO, op: ifc.StatxOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        op.buf.* = std.mem.zeroes(linux.Statx);
        op.buf.mode = linux.S.IFREG | 0o640;
        op.buf.uid = 1000;
        op.buf.gid = 1001;
        try self.arm(c, .{ .statx = op }, ud, cb);
    }

    pub fn open_copy_file_session(self: *CountingIO, op: ifc.OpenCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.open_copy_file_session_submitted += 1;
        try self.arm(c, .{ .open_copy_file_session = op }, ud, cb);
    }

    pub fn copy_file_chunk(self: *CountingIO, op: ifc.CopyFileChunkOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.copy_file_chunk_submitted += 1;
        try self.arm(c, .{ .copy_file_chunk = op }, ud, cb);
    }

    pub fn close_copy_file_session(self: *CountingIO, op: ifc.CloseCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.close_copy_file_session_submitted += 1;
        try self.arm(c, .{ .close_copy_file_session = op }, ud, cb);
    }

    pub fn fchown(self: *CountingIO, op: ifc.FchownOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.fchown_submitted += 1;
        try self.arm(c, .{ .fchown = op }, ud, cb);
    }

    pub fn fchmod(self: *CountingIO, op: ifc.FchmodOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.fchmod_submitted += 1;
        try self.arm(c, .{ .fchmod = op }, ud, cb);
    }

    pub fn fsync(self: *CountingIO, op: ifc.FsyncOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .fsync = op }, ud, cb);
    }

    pub fn unlinkat(self: *CountingIO, op: ifc.UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        try self.arm(c, .{ .unlinkat = op }, ud, cb);
    }

    pub fn close(self: *CountingIO, op: ifc.CloseOp, c: *Completion, ud: ?*anyopaque, cb: ifc.Callback) !void {
        self.close_submitted += 1;
        self.last_close_fd = op.fd;
        try self.arm(c, .{ .close = op }, ud, cb);
    }

    pub fn closeSocket(_: *CountingIO, _: posix.fd_t) void {}
};

test "MoveJob: EXDEV fallback submits semantic copy session and chunk op" {
    var files = [_]MoveJob.File{.{ .relative_path = "piece.bin", .length = 7 }};
    var job = try MoveJob.createForFiles(testing.allocator, 15, "/src", "/dst", &files);
    defer {
        job.io_pending = false;
        job.src_fd = -1;
        job.dst_fd = -1;
        job.destroy();
    }
    try job.startOnEventLoop(null, null);

    var io = CountingIO{};
    job.tickOnEventLoop(&io);
    try testing.expectEqual(@as(u32, 1), io.mkdirat_submitted);

    job.io_pending = false;
    job.io_result = .{ .mkdirat = {} };
    job.tickOnEventLoop(&io);

    job.io_pending = false;
    job.io_result = .{ .renameat = error.RenameAcrossMountPoints };
    job.tickOnEventLoop(&io);

    job.io_pending = false;
    job.io_result = .{ .statx = {} };
    job.tickOnEventLoop(&io);

    job.io_pending = false;
    job.io_result = .{ .open_copy_file_session = {} };
    job.tickOnEventLoop(&io);

    job.io_pending = false;
    job.io_result = .{ .openat = @as(posix.fd_t, 10) };
    job.tickOnEventLoop(&io);

    job.io_pending = false;
    job.io_result = .{ .openat = @as(posix.fd_t, 11) };
    job.tickOnEventLoop(&io);

    try testing.expectEqual(@as(u32, 1), io.open_copy_file_session_submitted);
    try testing.expectEqual(@as(u32, 1), io.copy_file_chunk_submitted);
}

test "MoveJob: requestCancel before event-loop start has no effect on a fresh job" {
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
    // Without startOnEventLoop, state stays `.created`.
    try testing.expectEqual(State.created, job.progress().state);
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

test "MoveJob: event-loop EXDEV copy fallback copies bytes and fsyncs destination in SimIO" {
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

test "MoveJob: EXDEV fallback preserves ownership and permission metadata in SimIO" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{ .renameat_exdev_probability = 1.0 },
    });
    defer io.deinit();

    try simMkdir(&io, "/src");
    try simMkdir(&io, "/src/torrent");
    try simSetMetadata(&io, "/src/torrent", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 2000, 2001, 0o2750);
    try simSeedFile(&io, "/src/torrent/piece.bin", "payload");
    try simSetMetadata(&io, "/src/torrent/piece.bin", .{ .ACCMODE = .RDONLY }, 1000, 1001, 0o4750);

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 16, "/src", "/dst", &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectSimEventLoopEventuallyState(job, &io, .succeeded, 200);

    const file_stat = try simStatPath(&io, "/dst/torrent/piece.bin");
    try testing.expectEqual(@as(u32, 1000), file_stat.uid);
    try testing.expectEqual(@as(u32, 1001), file_stat.gid);
    try testing.expectEqual(@as(u16, 0o4750), @as(u16, @intCast(file_stat.mode & 0o7777)));

    const dir_stat = try simStatPath(&io, "/dst/torrent");
    try testing.expectEqual(@as(u32, 2000), dir_stat.uid);
    try testing.expectEqual(@as(u32, 2001), dir_stat.gid);
    try testing.expectEqual(@as(u16, 0o2750), @as(u16, @intCast(dir_stat.mode & 0o7777)));
}

test "MoveJob: cleanup closes open directory metadata fd on failure" {
    var files = [_]MoveJob.File{.{ .relative_path = "torrent/piece.bin", .length = 7 }};
    var job = try MoveJob.createForFiles(testing.allocator, 17, "/src", "/dst", &files);
    defer {
        job.io_pending = false;
        job.dir_fd = -1;
        if (job.dir_metadata.len > 0) job.dir_metadata[0].fd = -1;
        job.destroy();
    }
    try job.startOnEventLoop(null, null);
    try testing.expect(job.dir_metadata.len > 0);
    job.dir_metadata[0].fd = 23;
    job.event_stage = .fchown_dir_metadata;

    var io = CountingIO{};
    job.failEventLoop(&io, error.InputOutput);

    try testing.expect(job.io_pending);
    try testing.expectEqual(@as(u32, 1), io.close_submitted);
    try testing.expectEqual(@as(posix.fd_t, 23), io.last_close_fd);
}

test "MoveJob: event-loop copy fallback removes destination when copy fails" {
    var io = try SimIO.init(testing.allocator, .{
        .faults = .{
            .renameat_exdev_probability = 1.0,
            .copy_file_chunk_error_probability = 1.0,
        },
    });
    defer io.deinit();

    try simMkdir(&io, "/src");
    try simMkdir(&io, "/src/torrent");
    try simSeedFile(&io, "/src/torrent/piece.bin", "payload");

    var files = [_]MoveJob.File{.{
        .relative_path = "torrent/piece.bin",
        .length = 7,
    }};
    var job = try MoveJob.createForFiles(testing.allocator, 18, "/src", "/dst", &files);
    defer job.destroy();

    try job.startOnEventLoop(null, null);
    try expectSimEventLoopEventuallyState(job, &io, .failed, 200);

    var src_buf: [16]u8 = undefined;
    const src_n = try simReadPath(&io, "/src/torrent/piece.bin", &src_buf);
    try testing.expectEqualStrings("payload", src_buf[0..src_n]);
    try testing.expectError(error.FileNotFound, simOpen(&io, "/dst/torrent/piece.bin", .{ .ACCMODE = .RDONLY }, 0));
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

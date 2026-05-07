//! Async data-file delete job for qBittorrent-compatible
//! `POST /api/v2/torrents/delete` with `deleteFiles=true`.
//!
//! The job is manifest-scoped for file deletion, then recursively prunes empty
//! torrent directories through the IO contract. It deliberately preserves the
//! old best-effort delete semantics: missing files, non-empty directories, and
//! other cleanup failures are recorded for logging but do not stop the job from
//! attempting the remaining paths.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const ifc = @import("../io/io_interface.zig");

pub const JobId = u64;

pub const State = enum(u8) {
    created = 0,
    running = 1,
    succeeded = 2,
    failed = 3,
    canceled = 4,
};

pub const Progress = struct {
    state: State,
    files_done: u32,
    total_files: u32,
    dirs_removed: u32,
    errors_seen: u32,
    error_message: ?[]const u8,
};

pub const CompletionCallback = *const fn (
    ctx: ?*anyopaque,
    id: JobId,
    state: State,
) void;

const OwnedPath = struct {
    relative_path: []u8,
};

pub const DeleteJob = struct {
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
        unlink_file,
        prepare_cleanup_root,
        open_dir,
        read_dir,
        close_dir,
        remove_dir,
        done,
    };

    const DirFramePhase = enum {
        open_dir,
        read_dir,
        close_dir,
        remove_dir,
    };

    pub const File = struct {
        relative_path: []const u8,
    };

    const OwnedFile = struct {
        relative_path: []u8,
    };

    const DirFrame = struct {
        path: [:0]u8,
        fd: posix.fd_t = -1,
        phase: DirFramePhase = .open_dir,
        has_entries: bool = false,
        parent_index: ?usize = null,
    };

    id: JobId,
    allocator: std.mem.Allocator,
    root: []u8,
    files: []OwnedFile = &.{},
    cleanup_roots: []OwnedPath = &.{},

    files_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    total_files: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    dirs_removed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    errors_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    state_atomic: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.created)),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    error_mutex: std.Thread.Mutex = .{},
    error_message: ?[]u8 = null,

    runner: Runner = .none,
    io_completion: ifc.Completion = .{},
    io_pending: bool = false,
    io_result: ?ifc.Result = null,
    event_stage: EventStage = .idle,
    current_file_index: usize = 0,
    cleanup_root_index: usize = 0,
    current_path_z: ?[:0]u8 = null,
    dir_frames: std.ArrayList(DirFrame) = std.ArrayList(DirFrame).empty,
    dir_buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined,
    completion_ctx: ?*anyopaque = null,
    completion_cb: ?CompletionCallback = null,

    pub fn createForFiles(
        allocator: std.mem.Allocator,
        id: JobId,
        root: []const u8,
        files: []const File,
    ) !*DeleteJob {
        if (!std.fs.path.isAbsolute(root)) return error.RootPathNotAbsolute;

        const self = try allocator.create(DeleteJob);
        errdefer allocator.destroy(self);

        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);

        const owned_files = try allocator.alloc(OwnedFile, files.len);
        errdefer allocator.free(owned_files);
        var initialized_files: usize = 0;
        errdefer {
            for (owned_files[0..initialized_files]) |file| allocator.free(file.relative_path);
        }

        var cleanup_roots = std.ArrayList(OwnedPath).empty;
        errdefer freeOwnedPathList(allocator, &cleanup_roots);

        for (files, 0..) |file, index| {
            try validateRelativePath(file.relative_path);
            owned_files[index] = .{
                .relative_path = try allocator.dupe(u8, file.relative_path),
            };
            initialized_files = index + 1;

            if (firstComponentIfDirectoryPath(file.relative_path)) |root_component| {
                try appendUniqueOwnedPath(allocator, &cleanup_roots, root_component);
            }
        }

        self.* = .{
            .id = id,
            .allocator = allocator,
            .root = owned_root,
            .files = owned_files,
            .cleanup_roots = try cleanup_roots.toOwnedSlice(allocator),
        };
        return self;
    }

    pub fn destroy(self: *DeleteJob) void {
        self.freeCurrentPath();
        self.freeDirFrames();
        self.allocator.free(self.root);
        for (self.files) |file| self.allocator.free(file.relative_path);
        if (self.files.len > 0) self.allocator.free(self.files);
        for (self.cleanup_roots) |path| self.allocator.free(path.relative_path);
        if (self.cleanup_roots.len > 0) self.allocator.free(self.cleanup_roots);
        if (self.error_message) |message| self.allocator.free(message);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn startOnEventLoop(
        self: *DeleteJob,
        completion_ctx: ?*anyopaque,
        completion_cb: ?CompletionCallback,
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
        self.runner = .event_loop;
        self.event_stage = .unlink_file;
        self.total_files.store(@intCast(self.files.len), .release);
    }

    pub fn requestCancel(self: *DeleteJob) void {
        self.cancel_requested.store(true, .release);
    }

    pub fn isEventLoopRunning(self: *DeleteJob) bool {
        return self.runner == .event_loop and self.progress().state == .running;
    }

    pub fn hasPendingEventLoopIo(self: *DeleteJob) bool {
        return self.runner == .event_loop and self.io_pending;
    }

    pub fn tickOnEventLoop(self: *DeleteJob, io: anytype) void {
        if (self.runner != .event_loop) return;
        if (self.progress().state != .running) return;
        self.tickOnEventLoopInternal(io) catch |err| self.failEventLoop(err);
    }

    fn tickOnEventLoopInternal(self: *DeleteJob, io: anytype) !void {
        if (self.io_result) |result| {
            self.io_result = null;
            try self.handleEventLoopResult(result);
        }
        if (self.progress().state != .running or self.io_pending) return;

        if (self.cancel_requested.load(.acquire)) {
            self.completeEventLoop(.canceled);
            return;
        }

        switch (self.event_stage) {
            .idle => {},
            .unlink_file => try self.submitUnlinkFile(io),
            .prepare_cleanup_root => try self.prepareCleanupRoot(),
            .open_dir => try self.submitOpenDir(io),
            .read_dir => try self.submitReadDir(io),
            .close_dir => try self.submitCloseDir(io),
            .remove_dir => try self.submitRemoveDir(io),
            .done => self.completeEventLoop(.succeeded),
        }
    }

    fn handleEventLoopResult(self: *DeleteJob, result: ifc.Result) !void {
        switch (self.event_stage) {
            .unlink_file => {
                switch (result) {
                    .unlinkat => |r| r catch |err| self.recordBestEffortError(err),
                    else => return error.UnexpectedDeleteJobCompletion,
                }
                self.freeCurrentPath();
                self.current_file_index += 1;
                _ = self.files_done.fetchAdd(1, .acq_rel);
                if (self.current_file_index >= self.files.len) {
                    self.event_stage = .prepare_cleanup_root;
                }
            },
            .open_dir => {
                switch (result) {
                    .openat => |r| {
                        const fd = r catch |err| switch (err) {
                            error.FileNotFound, error.NotDir => {
                                self.finishCurrentFrame(true);
                                return;
                            },
                            else => {
                                self.recordBestEffortError(err);
                                self.finishCurrentFrame(false);
                                return;
                            },
                        };
                        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
                        self.dir_frames.items[idx].fd = fd;
                        self.dir_frames.items[idx].phase = .read_dir;
                        self.event_stage = .read_dir;
                    },
                    else => return error.UnexpectedDeleteJobCompletion,
                }
            },
            .read_dir => {
                const bytes = switch (result) {
                    .getdents => |r| r catch |err| {
                        self.recordBestEffortError(err);
                        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
                        self.dir_frames.items[idx].phase = .close_dir;
                        self.event_stage = .close_dir;
                        return;
                    },
                    else => return error.UnexpectedDeleteJobCompletion,
                };
                if (bytes == 0) {
                    const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
                    self.dir_frames.items[idx].phase = .close_dir;
                    self.event_stage = .close_dir;
                    return;
                }
                try self.parseDirentsAndPushChildren(bytes);
                self.event_stage = self.currentFrameStage();
            },
            .close_dir => {
                switch (result) {
                    .close => |r| r catch |err| self.recordBestEffortError(err),
                    else => return error.UnexpectedDeleteJobCompletion,
                }
                const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
                self.dir_frames.items[idx].fd = -1;
                if (self.dir_frames.items[idx].has_entries) {
                    self.finishCurrentFrame(false);
                } else {
                    self.dir_frames.items[idx].phase = .remove_dir;
                    self.event_stage = .remove_dir;
                }
            },
            .remove_dir => {
                var removed = false;
                switch (result) {
                    .unlinkat => |r| {
                        r catch |err| switch (err) {
                            error.FileNotFound => {
                                removed = true;
                                self.finishCurrentFrame(removed);
                                return;
                            },
                            error.DirNotEmpty, error.NotDir => {
                                removed = false;
                                self.finishCurrentFrame(removed);
                                return;
                            },
                            else => {
                                self.recordBestEffortError(err);
                                removed = false;
                                self.finishCurrentFrame(removed);
                                return;
                            },
                        };
                        removed = true;
                    },
                    else => return error.UnexpectedDeleteJobCompletion,
                }
                if (removed) _ = self.dirs_removed.fetchAdd(1, .acq_rel);
                self.finishCurrentFrame(removed);
            },
            else => return error.UnexpectedDeleteJobCompletion,
        }
    }

    fn submitUnlinkFile(self: *DeleteJob, io: anytype) !void {
        if (self.current_file_index >= self.files.len) {
            self.event_stage = .prepare_cleanup_root;
            return;
        }
        if (self.current_path_z == null) {
            self.current_path_z = try joinPathZ(self.allocator, self.root, self.files[self.current_file_index].relative_path);
        }
        self.io_pending = true;
        io.unlinkat(.{
            .dir_fd = at_fdcwd,
            .path = self.current_path_z.?,
            .flags = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn prepareCleanupRoot(self: *DeleteJob) !void {
        if (self.cleanup_root_index >= self.cleanup_roots.len) {
            self.event_stage = .done;
            self.completeEventLoop(.succeeded);
            return;
        }
        const path = try joinPathZ(self.allocator, self.root, self.cleanup_roots[self.cleanup_root_index].relative_path);
        errdefer self.allocator.free(path);
        try self.dir_frames.append(self.allocator, .{ .path = path });
        self.event_stage = .open_dir;
    }

    fn submitOpenDir(self: *DeleteJob, io: anytype) !void {
        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
        self.io_pending = true;
        io.openat(.{
            .dir_fd = at_fdcwd,
            .path = self.dir_frames.items[idx].path,
            .flags = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
            .mode = 0,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitReadDir(self: *DeleteJob, io: anytype) !void {
        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
        self.io_pending = true;
        io.getdents(.{
            .fd = self.dir_frames.items[idx].fd,
            .buf = self.dir_buf[0..],
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitCloseDir(self: *DeleteJob, io: anytype) !void {
        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
        self.io_pending = true;
        io.close(.{ .fd = self.dir_frames.items[idx].fd }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn submitRemoveDir(self: *DeleteJob, io: anytype) !void {
        const idx = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
        self.io_pending = true;
        io.unlinkat(.{
            .dir_fd = at_fdcwd,
            .path = self.dir_frames.items[idx].path,
            .flags = posix.AT.REMOVEDIR,
        }, &self.io_completion, self, eventLoopCallback) catch |err| {
            self.io_pending = false;
            return err;
        };
    }

    fn parseDirentsAndPushChildren(self: *DeleteJob, bytes: usize) !void {
        const parent_index = self.currentFrameIndex() orelse return error.UnexpectedDeleteJobCompletion;
        self.dir_frames.items[parent_index].phase = .read_dir;

        var offset: usize = 0;
        while (offset < bytes) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&self.dir_buf[offset]);
            if (entry.reclen == 0 or offset + entry.reclen > bytes) return error.InvalidDirent;
            defer offset += entry.reclen;

            const name = ifc.direntName(entry);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            if (entry.type == linux.DT.DIR) {
                const child_path = try joinPathZ(self.allocator, self.dir_frames.items[parent_index].path, name);
                errdefer self.allocator.free(child_path);
                try self.dir_frames.append(self.allocator, .{
                    .path = child_path,
                    .parent_index = parent_index,
                });
            } else {
                self.dir_frames.items[parent_index].has_entries = true;
            }
        }
    }

    fn finishCurrentFrame(self: *DeleteJob, removed: bool) void {
        const frame = self.dir_frames.pop().?;
        if (frame.fd >= 0) {
            self.recordBestEffortError(error.DirectoryFdLeaked);
        }
        if (frame.parent_index) |parent_index| {
            if (!removed and parent_index < self.dir_frames.items.len) {
                self.dir_frames.items[parent_index].has_entries = true;
            }
        } else {
            self.cleanup_root_index += 1;
        }
        self.allocator.free(frame.path);
        self.event_stage = self.currentFrameStage();
    }

    fn currentFrameIndex(self: *DeleteJob) ?usize {
        if (self.dir_frames.items.len == 0) return null;
        return self.dir_frames.items.len - 1;
    }

    fn currentFrameStage(self: *DeleteJob) EventStage {
        if (self.dir_frames.items.len == 0) return .prepare_cleanup_root;
        return switch (self.dir_frames.items[self.dir_frames.items.len - 1].phase) {
            .open_dir => .open_dir,
            .read_dir => .read_dir,
            .close_dir => .close_dir,
            .remove_dir => .remove_dir,
        };
    }

    fn completeEventLoop(self: *DeleteJob, terminal: State) void {
        self.freeCurrentPath();
        self.freeDirFrames();
        self.event_stage = .done;
        self.state_atomic.store(@intFromEnum(terminal), .release);
        if (self.completion_cb) |cb| cb(self.completion_ctx, self.id, terminal);
    }

    fn failEventLoop(self: *DeleteJob, err: anyerror) void {
        self.recordErrorIfNone(err);
        self.completeEventLoop(.failed);
    }

    fn eventLoopCallback(
        userdata: ?*anyopaque,
        _: *ifc.Completion,
        result: ifc.Result,
    ) ifc.CallbackAction {
        const self: *DeleteJob = @ptrCast(@alignCast(userdata.?));
        self.io_pending = false;
        self.io_result = result;
        return .disarm;
    }

    pub fn progress(self: *DeleteJob) Progress {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        return .{
            .state = @enumFromInt(self.state_atomic.load(.acquire)),
            .files_done = self.files_done.load(.acquire),
            .total_files = self.total_files.load(.acquire),
            .dirs_removed = self.dirs_removed.load(.acquire),
            .errors_seen = self.errors_seen.load(.acquire),
            .error_message = self.error_message,
        };
    }

    fn recordBestEffortError(self: *DeleteJob, err: anyerror) void {
        _ = self.errors_seen.fetchAdd(1, .acq_rel);
        self.recordErrorIfNone(err);
    }

    fn recordErrorIfNone(self: *DeleteJob, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        if (self.error_message != null) return;
        self.error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
    }

    fn freeCurrentPath(self: *DeleteJob) void {
        if (self.current_path_z) |path| self.allocator.free(path);
        self.current_path_z = null;
    }

    fn freeDirFrames(self: *DeleteJob) void {
        for (self.dir_frames.items) |frame| {
            if (frame.fd >= 0) {
                self.recordBestEffortError(error.DirectoryFdLeaked);
            }
            self.allocator.free(frame.path);
        }
        self.dir_frames.deinit(self.allocator);
        self.dir_frames = std.ArrayList(DirFrame).empty;
    }
};

fn validateRelativePath(relative_path: []const u8) !void {
    if (relative_path.len == 0 or std.fs.path.isAbsolute(relative_path)) return error.InvalidDeletePath;
    var parts = std.mem.splitScalar(u8, relative_path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidDeletePath;
        }
    }
}

fn firstComponentIfDirectoryPath(relative_path: []const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, relative_path, std.fs.path.sep) orelse return null;
    if (idx == 0) return null;
    return relative_path[0..idx];
}

fn appendUniqueOwnedPath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList(OwnedPath),
    relative_path: []const u8,
) !void {
    for (paths.items) |entry| {
        if (std.mem.eql(u8, entry.relative_path, relative_path)) return;
    }
    try paths.append(allocator, .{ .relative_path = try allocator.dupe(u8, relative_path) });
}

fn freeOwnedPathList(allocator: std.mem.Allocator, paths: *std.ArrayList(OwnedPath)) void {
    for (paths.items) |entry| allocator.free(entry.relative_path);
    paths.deinit(allocator);
}

fn joinPathZ(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![:0]u8 {
    const joined = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(joined);
    return allocator.dupeZ(u8, joined);
}

test "DeleteJob: event-loop deletes manifest files and prunes empty dirs without sibling damage" {
    const testing = std.testing;

    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    try simMkdir(&io, "/downloads");
    try simMkdir(&io, "/downloads/root");
    try simMkdir(&io, "/downloads/root/sub");
    try simMkdir(&io, "/downloads/root/empty");
    try simSeedFile(&io, "/downloads/root/sub/piece.bin", "piece-data");
    try simSeedFile(&io, "/downloads/root/keep.dat", "keep");

    var files = [_]DeleteJob.File{.{ .relative_path = "root/sub/piece.bin" }};
    const job = try DeleteJob.createForFiles(testing.allocator, 1, "/downloads", &files);
    defer job.destroy();
    try job.startOnEventLoop(null, null);

    try expectSimEventLoopEventuallyState(job, &io, .succeeded, 128);

    try simExpectMissing(&io, "/downloads/root/sub/piece.bin");
    try simExpectMissing(&io, "/downloads/root/sub");
    try simExpectMissing(&io, "/downloads/root/empty");
    try simExpectExists(&io, "/downloads/root");
    try simExpectExists(&io, "/downloads/root/keep.dat");
}

test "DeleteJob: single-file delete keeps save root" {
    const testing = std.testing;

    var io = try SimIO.init(testing.allocator, .{});
    defer io.deinit();

    try simMkdir(&io, "/downloads");
    try simSeedFile(&io, "/downloads/piece.bin", "piece-data");

    var files = [_]DeleteJob.File{.{ .relative_path = "piece.bin" }};
    const job = try DeleteJob.createForFiles(testing.allocator, 2, "/downloads", &files);
    defer job.destroy();
    try job.startOnEventLoop(null, null);

    try expectSimEventLoopEventuallyState(job, &io, .succeeded, 64);

    try simExpectMissing(&io, "/downloads/piece.bin");
    try simExpectExists(&io, "/downloads");
}

const SimIO = @import("../io/sim_io.zig").SimIO;
const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

fn expectSimEventLoopEventuallyState(job: *DeleteJob, io: *SimIO, want: State, max_ticks: u32) !void {
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
    try io.mkdirat(.{ .dir_fd = DeleteJob.at_fdcwd, .path = path, .mode = 0o755 }, &c, &ctx, simCallback);
    try io.tick(0);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .mkdirat => |r| try r,
        else => error.UnexpectedDeleteJobCompletion,
    };
}

fn simSeedFile(io: *SimIO, path: [:0]const u8, bytes: []const u8) !void {
    const fd = try simOpen(io, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer simClose(io, fd) catch {};
    try io.setFileBytes(fd, bytes);
}

fn simOpen(io: *SimIO, path: [:0]const u8, flags: posix.O, mode: posix.mode_t) !posix.fd_t {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.openat(.{ .dir_fd = DeleteJob.at_fdcwd, .path = path, .flags = flags, .mode = mode }, &c, &ctx, simCallback);
    try io.tick(0);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .openat => |r| try r,
        else => error.UnexpectedDeleteJobCompletion,
    };
}

fn simClose(io: *SimIO, fd: posix.fd_t) !void {
    var c = Completion{};
    var ctx = SimCtx{};
    try io.close(.{ .fd = fd }, &c, &ctx, simCallback);
    try io.tick(0);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    return switch (ctx.result.?) {
        .close => |r| try r,
        else => error.UnexpectedDeleteJobCompletion,
    };
}

fn simExpectExists(io: *SimIO, path: [:0]const u8) !void {
    var stat_buf: linux.Statx = undefined;
    var c = Completion{};
    var ctx = SimCtx{};
    try io.statx(.{
        .dir_fd = DeleteJob.at_fdcwd,
        .path = path,
        .flags = linux.AT.SYMLINK_NOFOLLOW,
        .mask = linux.STATX_BASIC_STATS,
        .buf = &stat_buf,
    }, &c, &ctx, simCallback);
    try io.tick(0);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.result.?) {
        .statx => |r| try r,
        else => return error.UnexpectedDeleteJobCompletion,
    }
}

fn simExpectMissing(io: *SimIO, path: [:0]const u8) !void {
    var stat_buf: linux.Statx = undefined;
    var c = Completion{};
    var ctx = SimCtx{};
    try io.statx(.{
        .dir_fd = DeleteJob.at_fdcwd,
        .path = path,
        .flags = linux.AT.SYMLINK_NOFOLLOW,
        .mask = linux.STATX_BASIC_STATS,
        .buf = &stat_buf,
    }, &c, &ctx, simCallback);
    try io.tick(0);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    switch (ctx.result.?) {
        .statx => |r| try std.testing.expectError(error.FileNotFound, r),
        else => return error.UnexpectedDeleteJobCompletion,
    }
}

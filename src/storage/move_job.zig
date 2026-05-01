//! Async data-file move job — backs the new
//! `POST /api/v2/varuna/torrents/move` endpoint and replaces the
//! synchronous `setLocation` path that used to block the RPC handler
//! thread for the duration of a multi-GB cross-filesystem copy.
//!
//! ## Why a dedicated thread
//!
//! Recursive directory walks combine many "boring" syscalls (opendir,
//! readdir, openat, fstatat, mkdirat, unlinkat, rmdir) with the actual
//! data-transfer work (`copy_file_range`). Encoding every one of those
//! through the async IO contract would multiply both LOC and the
//! state-machine surface area without any throughput benefit — the
//! whole job is bounded by disk I/O, not by CPU or by the EL's
//! scheduling latency.
//!
//! AGENTS.md sanctions a worker-thread for "one-time file creation,
//! directory setup" — a setLocation move is the prototypical example.
//! The MoveJob runs entirely on its own `std.Thread`, never touches the
//! event loop, never blocks the RPC handler, and exposes its progress
//! through atomics so concurrent `GET /move/{id}` polls are race-free.
//!
//! ## State machine
//!
//!   created → running → succeeded
//!                    ↘  failed
//!                    ↘  canceled
//!
//! Transitions are one-shot and `compareAndSwap`-driven; once a job
//! reaches a terminal state it stays there until `destroy`. Cancel
//! requests flip an atomic flag — the worker checks it between files
//! (the granularity is "one file at a time", not "one chunk at a time",
//! which is fine for typical torrent file sizes).
//!
//! ## Same-FS fast path
//!
//! `posix.fstatat` on both src and dst returns each path's `dev`. If
//! they match, the worker uses `renameat(AT_FDCWD, src, AT_FDCWD, dst)`
//! which is constant-time on every modern Linux filesystem. Cross-FS
//! falls through to a recursive walk + `copy_file_range` + unlink loop.
//!
//! ## Progress accounting
//!
//! `total_bytes` is computed during a one-shot pre-scan; `bytes_copied`
//! advances as `copy_file_range` returns positive byte counts. The
//! same-FS rename path sets both to the same value at completion (the
//! "we moved zero bytes through userspace, but conceptually all of it
//! moved" interpretation). Files-counter analogous.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;

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

    id: JobId,
    allocator: std.mem.Allocator,

    /// Owned copies of source and destination root directories. Both
    /// MUST be absolute (the SessionManager validates this on submit).
    src_root: []u8,
    dst_root: []u8,

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

    /// Free the job. Safe to call after `state` is terminal; if the
    /// worker thread is still running, this joins it first.
    pub fn destroy(self: *MoveJob) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.allocator.free(self.src_root);
        self.allocator.free(self.dst_root);
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

    // ── Pre-scan ──────────────────────────────────────────

    fn scanSource(self: *MoveJob) !void {
        var total_bytes: u64 = 0;
        var total_files: u32 = 0;
        try scanDir(self.src_root, &total_bytes, &total_files);
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

fn expectEventuallyState(job: *MoveJob, want: State, timeout_ms: u32) !void {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 5) {
        if (job.progress().state == want) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.TimedOutWaitingForJobState;
}

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

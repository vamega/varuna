const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const torrent = @import("../torrent/root.zig");
const FilePriority = torrent.file_priority.FilePriority;
const real_io = @import("../io/real_io.zig");
const RealIO = real_io.RealIO;
const io_interface = @import("../io/io_interface.zig");

/// Piece storage state machine, parameterised over the IO backend.
///
/// Daemon callers continue to write `PieceStore` (the
/// `PieceStoreOf(RealIO)` alias declared below). Sim tests instantiate
/// `PieceStoreOf(SimIO)` directly so the same init / sync paths drive
/// against `EventLoopOf(SimIO)` for fault-injection harnesses.
///
/// `init` and `sync` route their disk syscalls through `self.io`:
///   * `init` submits one `fallocate` per non-skipped file and drains
///     the ring with `io.tick(1)` until every completion lands. This
///     is the one-time pre-allocation per torrent — AGENTS.md flags
///     it as an "allowed exception" but routing through the contract
///     is what makes ENOSPC / EIO injection possible from BUGGIFY.
///   * `sync` submits one `fsync(datasync=true)` per open file, same
///     drain pattern. Replaces the previous `posix.fdatasync` loop.
///
/// `writePiece` and `readPiece` still use blocking `posix.pread` /
/// `posix.pwrite` — their migration to async IO contract calls is a
/// separate (larger) refactor tracked in STATUS.md.
pub fn PieceStoreOf(comptime IO: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        session: *const torrent.session.Session,
        io: *IO,
        /// File handles indexed by file_index.  A null entry means the file was
        /// skipped (do_not_download) and has not been created yet.
        files: []?std.fs.File,

        pub fn init(
            allocator: std.mem.Allocator,
            session: *const torrent.session.Session,
            io: *IO,
        ) !Self {
            return initWithPriorities(allocator, session, io, null);
        }

        /// Initialise with optional per-file priorities. Files marked
        /// `do_not_download` are not pre-allocated or opened.
        pub fn initWithPriorities(
            allocator: std.mem.Allocator,
            session: *const torrent.session.Session,
            io: *IO,
            file_priorities: ?[]const FilePriority,
        ) !Self {
            const files = try allocator.alloc(?std.fs.File, session.manifest.files.len);
            errdefer allocator.free(files);

            // Track which files we successfully created so errdefer cleanup
            // closes them all (vs. leaking on a partial-init failure).
            for (files) |*slot| slot.* = null;
            errdefer for (files) |maybe_file| {
                if (maybe_file) |f| f.close();
            };

            // Phase 1: open every file (or skip if priority says so).
            for (session.manifest.files, 0..) |file_entry, index| {
                if (file_priorities) |fp| {
                    if (index < fp.len and fp[index] == .do_not_download) {
                        files[index] = null;
                        continue;
                    }
                }

                if (std.fs.path.dirname(file_entry.full_path)) |dirname| {
                    try std.fs.cwd().makePath(dirname);
                }

                const file = try std.fs.cwd().createFile(file_entry.full_path, .{
                    .read = true,
                    .truncate = false,
                });
                files[index] = file;
            }

            // Phase 2: pre-allocate disk space via async fallocate. One
            // submission per open file; drain the ring until every
            // completion lands. Falls back to ftruncate per-file on
            // EOPNOTSUPP / NoSpaceLeft? No — we only fall back on
            // OperationNotSupported (the historical filesystem-portability
            // case); other errors are real and should propagate.
            try preallocateAll(allocator, io, files, session.manifest.files);

            return .{
                .allocator = allocator,
                .session = session,
                .io = io,
                .files = files,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.files) |maybe_file| {
                if (maybe_file) |file| file.close();
            }
            self.allocator.free(self.files);
            self.* = undefined;
        }

        /// Ensure a file that was previously skipped is now open and allocated.
        /// Called lazily when a piece spanning a newly-wanted file needs writing.
        pub fn ensureFileOpen(self: *Self, file_index: usize) !std.fs.File {
            if (self.files[file_index]) |f| return f;

            const file_entry = self.session.manifest.files[file_index];
            if (std.fs.path.dirname(file_entry.full_path)) |dirname| {
                try std.fs.cwd().makePath(dirname);
            }

            const file = try std.fs.cwd().createFile(file_entry.full_path, .{
                .read = true,
                .truncate = false,
            });
            errdefer file.close();

            try preallocateOne(self.io, file, file_entry.length);
            self.files[file_index] = file;
            return file;
        }

        pub fn writePiece(
            self: *Self,
            spans: []const torrent.layout.Layout.Span,
            piece_data: []const u8,
        ) !void {
            for (spans) |span| {
                const file = try self.ensureFileOpen(span.file_index);
                const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
                try pwriteAll(file.handle, block, span.file_offset);
            }
        }

        pub fn readPiece(
            self: *Self,
            spans: []const torrent.layout.Layout.Span,
            piece_data: []u8,
        ) !void {
            for (spans) |span| {
                const file = self.files[span.file_index] orelse return error.FileNotOpen;
                const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
                const read_count = try preadAll(file.handle, block, span.file_offset);
                if (read_count != block.len) {
                    return error.UnexpectedEndOfFile;
                }
            }
        }

        /// Flush all open files via async `io.fsync` (datasync). Submits one
        /// fsync op per open file through `self.io` and blocks the calling
        /// thread on `io.tick` until every fsync completes. Daemon callers
        /// run this from the event-loop thread.
        ///
        /// Replaces the previous synchronous `posix.fdatasync` loop. The
        /// async path lets the event loop interleave other CQEs (e.g. a
        /// peer recv) while the kernel walks the file's metadata.
        pub fn sync(self: *Self) !void {
            var open_count: usize = 0;
            for (self.files) |maybe_file| if (maybe_file != null) {
                open_count += 1;
            };
            if (open_count == 0) return;

            const completions = try self.allocator.alignedAlloc(
                io_interface.Completion,
                .of(io_interface.Completion),
                open_count,
            );
            defer self.allocator.free(completions);
            @memset(completions, .{});

            var ctx = SyncContext{ .pending = open_count };

            var i: usize = 0;
            for (self.files) |maybe_file| {
                if (maybe_file) |file| {
                    try self.io.fsync(
                        .{ .fd = file.handle, .datasync = true },
                        &completions[i],
                        &ctx,
                        syncCompleteCallback,
                    );
                    i += 1;
                }
            }

            while (ctx.pending > 0) try self.io.tick(1);
            if (ctx.first_error) |err| return err;
        }

        /// Return the raw fd_t values for sharing with other threads.
        /// The PieceStore retains ownership; callers must not close these.
        /// Skipped files get fd -1.
        pub fn fileHandles(self: *const Self, allocator: std.mem.Allocator) ![]posix.fd_t {
            const fds = try allocator.alloc(posix.fd_t, self.files.len);
            for (self.files, 0..) |maybe_file, i| {
                fds[i] = if (maybe_file) |file| file.handle else -1;
            }
            return fds;
        }
    };
}

/// Daemon-side concrete instantiation. Daemon callers continue to write
/// `PieceStore` and `PieceStore.method(...)`; tests that instantiate
/// against SimIO write `PieceStoreOf(SimIO)` directly.
pub const PieceStore = PieceStoreOf(RealIO);

/// Lightweight piece I/O using pre-opened file descriptors.
/// Does not own the fds -- the originating PieceStore must outlive this.
pub const PieceIO = struct {
    fds: []const posix.fd_t,

    pub fn writePiece(
        self: *PieceIO,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []const u8,
    ) !void {
        for (spans) |span| {
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            try pwriteAll(self.fds[span.file_index], block, span.file_offset);
        }
    }

    pub fn readPiece(
        self: *PieceIO,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []u8,
    ) !void {
        for (spans) |span| {
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            const read_count = try preadAll(self.fds[span.file_index], block, span.file_offset);
            if (read_count != block.len) {
                return error.UnexpectedEndOfFile;
            }
        }
    }
};

/// Write all bytes via blocking pwrite, looping on short writes.
fn pwriteAll(fd: posix.fd_t, buf: []const u8, offset: u64) !void {
    var written: usize = 0;
    while (written < buf.len) {
        const n = try posix.pwrite(fd, buf[written..], offset + written);
        if (n == 0) return error.UnexpectedEndOfFile;
        written += n;
    }
}

/// Read all bytes via blocking pread, looping on short reads.
/// Returns the total number of bytes read.
fn preadAll(fd: posix.fd_t, buf: []u8, offset: u64) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try posix.pread(fd, buf[total..], offset + total);
        if (n == 0) break; // EOF
        total += n;
    }
    return total;
}

/// Per-fallocate completion ticket: tracks pending count + first error,
/// shared across the batch by &PreallocCtx in `userdata`. The fallback
/// to `setEndPos` only fires when the kernel reports the filesystem
/// can't do fallocate at all (EOPNOTSUPP); other errors propagate.
const PreallocCtx = struct {
    pending: usize,
    first_error: ?anyerror = null,
    /// Per-file file handle, captured so the fallback path knows which
    /// fd to ftruncate when fallocate returns OperationNotSupported.
    /// Same length and ordering as `lengths`.
    files: []const ?std.fs.File,
    /// Per-file lengths, parallel to `files`.
    lengths: []const u64,
    /// Overall flag set if any completion took the fallback path; lets
    /// the caller log "n files fell back to ftruncate" if desired (we
    /// currently just consume it silently).
    fallback_count: usize = 0,
};

const PreallocSlot = struct {
    ctx: *PreallocCtx,
    file_index: usize,
};

fn preallocCallback(
    userdata: ?*anyopaque,
    _: *io_interface.Completion,
    result: io_interface.Result,
) io_interface.CallbackAction {
    const slot: *PreallocSlot = @ptrCast(@alignCast(userdata.?));
    const ctx = slot.ctx;
    std.debug.assert(ctx.pending > 0);
    ctx.pending -= 1;
    switch (result) {
        .fallocate => |r| _ = r catch |err| {
            // OperationNotSupported is the historical filesystem-portability
            // case (tmpfs <5.10, FAT32, certain FUSE FSes) — fall back to
            // ftruncate. Other errors (NoSpaceLeft, IoError, …) propagate.
            if (err == error.OperationNotSupported) {
                if (ctx.files[slot.file_index]) |file| {
                    file.setEndPos(ctx.lengths[slot.file_index]) catch |trunc_err| {
                        if (ctx.first_error == null) ctx.first_error = trunc_err;
                        return .disarm;
                    };
                    ctx.fallback_count += 1;
                    return .disarm;
                }
                if (ctx.first_error == null) ctx.first_error = error.FileNotOpen;
            } else {
                if (ctx.first_error == null) ctx.first_error = err;
            }
        },
        else => unreachable,
    }
    return .disarm;
}

/// Submit one fallocate per open file in `files` and drain the ring.
/// Files at indices marked `do_not_download` (null entries) are skipped.
fn preallocateAll(
    allocator: std.mem.Allocator,
    io: anytype,
    files: []const ?std.fs.File,
    file_entries: []const @import("manifest.zig").Manifest.File,
) !void {
    var open_count: usize = 0;
    for (files) |maybe_file| if (maybe_file != null) {
        open_count += 1;
    };
    if (open_count == 0) return;

    const completions = try allocator.alignedAlloc(
        io_interface.Completion,
        .of(io_interface.Completion),
        open_count,
    );
    defer allocator.free(completions);
    @memset(completions, .{});

    const slots = try allocator.alloc(PreallocSlot, open_count);
    defer allocator.free(slots);

    const lengths = try allocator.alloc(u64, files.len);
    defer allocator.free(lengths);
    for (file_entries, 0..) |fe, i| lengths[i] = fe.length;

    var ctx = PreallocCtx{
        .pending = open_count,
        .files = files,
        .lengths = lengths,
    };

    var i: usize = 0;
    for (files, 0..) |maybe_file, file_index| {
        const file = maybe_file orelse continue;
        slots[i] = .{ .ctx = &ctx, .file_index = file_index };
        try io.fallocate(
            .{
                .fd = file.handle,
                .mode = 0,
                .offset = 0,
                .len = file_entries[file_index].length,
            },
            &completions[i],
            &slots[i],
            preallocCallback,
        );
        i += 1;
    }

    while (ctx.pending > 0) try io.tick(1);
    if (ctx.first_error) |err| return err;
}

/// Submit a single fallocate and wait for it. Used by `ensureFileOpen`
/// for late-opened files (the lazy `do_not_download → normal` path).
fn preallocateOne(io: anytype, file: std.fs.File, length: u64) !void {
    var c = io_interface.Completion{};
    var ctx = OneShotCtx{ .pending = 1 };
    try io.fallocate(
        .{ .fd = file.handle, .mode = 0, .offset = 0, .len = length },
        &c,
        &ctx,
        oneShotPreallocCallback,
    );
    while (ctx.pending > 0) try io.tick(1);
    if (ctx.fallback) {
        // Filesystem doesn't support fallocate — fall back to ftruncate.
        try file.setEndPos(length);
    }
    if (ctx.err) |err| return err;
}

const OneShotCtx = struct {
    pending: usize,
    err: ?anyerror = null,
    fallback: bool = false,
};

fn oneShotPreallocCallback(
    userdata: ?*anyopaque,
    _: *io_interface.Completion,
    result: io_interface.Result,
) io_interface.CallbackAction {
    const ctx: *OneShotCtx = @ptrCast(@alignCast(userdata.?));
    std.debug.assert(ctx.pending > 0);
    ctx.pending -= 1;
    switch (result) {
        .fallocate => |r| _ = r catch |err| {
            if (err == error.OperationNotSupported) {
                ctx.fallback = true;
            } else {
                ctx.err = err;
            }
        },
        else => unreachable,
    }
    return .disarm;
}

/// Tracking state for a multi-file `PieceStore.sync` that's blocking on
/// async fsync completions. Updated from the io_interface callback fired
/// by every fsync CQE; the caller polls `pending` and surfaces
/// `first_error` once all completions have landed.
const SyncContext = struct {
    pending: usize,
    first_error: ?anyerror = null,
};

fn syncCompleteCallback(
    userdata: ?*anyopaque,
    _: *io_interface.Completion,
    result: io_interface.Result,
) io_interface.CallbackAction {
    const ctx: *SyncContext = @ptrCast(@alignCast(userdata.?));
    std.debug.assert(ctx.pending > 0);
    ctx.pending -= 1;
    switch (result) {
        .fsync => |r| _ = r catch |err| {
            if (ctx.first_error == null) ctx.first_error = err;
        },
        else => unreachable,
    }
    return .disarm;
}

test "write piece data across multiple files" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var io = real_io.RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
    defer io.deinit();

    var store = try PieceStore.init(std.testing.allocator, &session, &io);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer plan.deinit(std.testing.allocator);

    try store.writePiece(plan.spans, "spam");
    try store.sync();

    const first = try tmp.dir.readFileAlloc(std.testing.allocator, "download/root/alpha", 16);
    defer std.testing.allocator.free(first);
    const second = try tmp.dir.readFileAlloc(std.testing.allocator, "download/root/beta/gamma", 16);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("spa", first);
    try std.testing.expectEqualStrings("m", second[0..1]);
}

test "read piece data across multiple files" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var io = real_io.RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
    defer io.deinit();

    var store = try PieceStore.init(std.testing.allocator, &session, &io);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer plan.deinit(std.testing.allocator);

    try store.writePiece(plan.spans, "spam");

    var piece_buffer: [4]u8 = undefined;
    try store.readPiece(plan.spans, piece_buffer[0..]);

    try std.testing.expectEqualStrings("spam", &piece_buffer);
}

test "skip file with do_not_download priority" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var io = real_io.RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
    defer io.deinit();

    // Skip the first file (alpha)
    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var store = try PieceStore.initWithPriorities(std.testing.allocator, &session, &io, priorities[0..]);
    defer store.deinit();

    // First file should not be opened
    try std.testing.expect(store.files[0] == null);
    // Second file should be opened
    try std.testing.expect(store.files[1] != null);
}

test "ensureFileOpen creates skipped file on demand" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "download",
    });
    defer std.testing.allocator.free(target_root);

    const session = try torrent.session.Session.load(std.testing.allocator, input, target_root);
    defer session.deinit(std.testing.allocator);

    var io = real_io.RealIO.init(.{ .entries = 16 }) catch return error.SkipZigTest;
    defer io.deinit();

    // Skip the first file
    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var store = try PieceStore.initWithPriorities(std.testing.allocator, &session, &io, priorities[0..]);
    defer store.deinit();

    try std.testing.expect(store.files[0] == null);

    // Now open it on demand
    const file = try store.ensureFileOpen(0);
    try std.testing.expect(file.handle >= 0);
    try std.testing.expect(store.files[0] != null);
}

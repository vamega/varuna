const std = @import("std");
const posix = std.posix;
const torrent = @import("../torrent/root.zig");
const Ring = @import("../io/ring.zig").Ring;
const FilePriority = torrent.file_priority.FilePriority;

pub const PieceStore = struct {
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    /// File handles indexed by file_index.  A null entry means the file was
    /// skipped (do_not_download) and has not been created yet.
    files: []?std.fs.File,
    ring: *Ring,

    pub fn init(
        allocator: std.mem.Allocator,
        session: *const torrent.session.Session,
        ring: *Ring,
    ) !PieceStore {
        return initWithPriorities(allocator, session, ring, null);
    }

    /// Initialise with optional per-file priorities. Files marked
    /// `do_not_download` are not pre-allocated or opened.
    pub fn initWithPriorities(
        allocator: std.mem.Allocator,
        session: *const torrent.session.Session,
        ring: *Ring,
        file_priorities: ?[]const FilePriority,
    ) !PieceStore {
        const files = try allocator.alloc(?std.fs.File, session.manifest.files.len);
        errdefer allocator.free(files);

        for (session.manifest.files, 0..) |file_entry, index| {
            // Skip file creation when priority says do_not_download.
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
            errdefer file.close();

            // Pre-allocate disk space to avoid fragmentation and late "disk full" errors.
            // fallocate extends the file without zeroing, which is fast.
            // Fall back to ftruncate if fallocate is not supported (e.g., some filesystems).
            ring.fallocate(file.handle, 0, file_entry.length) catch {
                try file.setEndPos(file_entry.length);
            };
            files[index] = file;
        }

        return .{
            .allocator = allocator,
            .session = session,
            .files = files,
            .ring = ring,
        };
    }

    pub fn deinit(self: *PieceStore) void {
        for (self.files) |maybe_file| {
            if (maybe_file) |file| file.close();
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }

    /// Ensure a file that was previously skipped is now open and allocated.
    /// Called lazily when a piece spanning a newly-wanted file needs writing.
    pub fn ensureFileOpen(self: *PieceStore, file_index: usize) !std.fs.File {
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

        self.ring.fallocate(file.handle, 0, file_entry.length) catch {
            try file.setEndPos(file_entry.length);
        };
        self.files[file_index] = file;
        return file;
    }

    pub fn writePiece(
        self: *PieceStore,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []const u8,
    ) !void {
        for (spans) |span| {
            const file = try self.ensureFileOpen(span.file_index);
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            try self.ring.pwrite_all(file.handle, block, span.file_offset);
        }
    }

    pub fn readPiece(
        self: *PieceStore,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []u8,
    ) !void {
        for (spans) |span| {
            const file = self.files[span.file_index] orelse return error.FileNotOpen;
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            const read_count = try self.ring.pread_all(file.handle, block, span.file_offset);
            if (read_count != block.len) {
                return error.UnexpectedEndOfFile;
            }
        }
    }

    pub fn sync(self: *PieceStore) !void {
        for (self.files) |maybe_file| {
            if (maybe_file) |file| {
                try self.ring.fdatasync(file.handle);
            }
        }
    }

    /// Return the raw fd_t values for sharing with other threads.
    /// The PieceStore retains ownership; callers must not close these.
    /// Skipped files get fd -1.
    pub fn fileHandles(self: *const PieceStore, allocator: std.mem.Allocator) ![]posix.fd_t {
        const fds = try allocator.alloc(posix.fd_t, self.files.len);
        for (self.files, 0..) |maybe_file, i| {
            fds[i] = if (maybe_file) |file| file.handle else -1;
        }
        return fds;
    }
};

/// Lightweight piece I/O using pre-opened file descriptors and a Ring.
/// Does not own the fds -- the originating PieceStore must outlive this.
pub const PieceIO = struct {
    fds: []const posix.fd_t,
    ring: *Ring,

    pub fn writePiece(
        self: *PieceIO,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []const u8,
    ) !void {
        for (spans) |span| {
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            try self.ring.pwrite_all(self.fds[span.file_index], block, span.file_offset);
        }
    }

    pub fn readPiece(
        self: *PieceIO,
        spans: []const torrent.layout.Layout.Span,
        piece_data: []u8,
    ) !void {
        for (spans) |span| {
            const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
            const read_count = try self.ring.pread_all(self.fds[span.file_index], block, span.file_offset);
            if (read_count != block.len) {
                return error.UnexpectedEndOfFile;
            }
        }
    }
};

test "write piece data across multiple files" {
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    var store = try PieceStore.init(std.testing.allocator, &session, &ring);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer @import("verify.zig").freePiecePlan(std.testing.allocator, plan);

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
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    var store = try PieceStore.init(std.testing.allocator, &session, &ring);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer @import("verify.zig").freePiecePlan(std.testing.allocator, plan);

    try store.writePiece(plan.spans, "spam");

    var piece_buffer: [4]u8 = undefined;
    try store.readPiece(plan.spans, piece_buffer[0..]);

    try std.testing.expectEqualStrings("spam", &piece_buffer);
}

test "skip file with do_not_download priority" {
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    // Skip the first file (alpha)
    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var store = try PieceStore.initWithPriorities(std.testing.allocator, &session, &ring, priorities[0..]);
    defer store.deinit();

    // First file should not be opened
    try std.testing.expect(store.files[0] == null);
    // Second file should be opened
    try std.testing.expect(store.files[1] != null);
}

test "ensureFileOpen creates skipped file on demand" {
    var ring = Ring.init(16) catch return error.SkipZigTest;
    defer ring.deinit();

    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678eee";

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

    // Skip the first file
    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var store = try PieceStore.initWithPriorities(std.testing.allocator, &session, &ring, priorities[0..]);
    defer store.deinit();

    try std.testing.expect(store.files[0] == null);

    // Now open it on demand
    const file = try store.ensureFileOpen(0);
    try std.testing.expect(file.handle >= 0);
    try std.testing.expect(store.files[0] != null);
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const torrent = @import("../torrent/root.zig");
const FilePriority = torrent.file_priority.FilePriority;
const backend = @import("../io/backend.zig");
const RealIO = backend.RealIO;
const io_interface = @import("../io/io_interface.zig");

/// Piece storage state machine, parameterised over the IO backend.
///
/// Daemon callers continue to write `PieceStore` (the
/// `PieceStoreOf(RealIO)` alias declared below). Sim tests instantiate
/// `PieceStoreOf(SimIO)` directly so the same init / sync paths drive
/// against `EventLoopOf(SimIO)` for fault-injection harnesses.
///
/// All disk syscalls route through an `IO` passed in per call:
///   * `init` takes `io` and submits one `fallocate` per non-skipped
///     file, draining the ring with `io.tick(1)` until every
///     completion lands. The store does NOT retain the pointer; `io`
///     only needs to outlive the `init` call. This is the one-time
///     pre-allocation per torrent — AGENTS.md flags it as an "allowed
///     exception" but routing through the contract is what makes
///     ENOSPC / EIO injection possible from BUGGIFY.
///   * `sync` takes `io` and submits one `fsync(datasync=true)` per
///     open file, same drain pattern. Replaces the previous
///     `posix.fdatasync` loop. Daemon flushes go through the
///     EL-level sync sweep on `EventLoop.submitTorrentSync` instead;
///     this method is reached only from tests today.
///   * `writePiece` takes `io` and submits one `io.write` per span
///     (one span per file the piece touches) and drains until every
///     completion lands. The callback handles short writes by re-
///     submitting the remainder.
///   * `readPiece` takes `io` and submits one `io.read` per span with
///     the same drain pattern; short reads are looped, and a 0-byte
///     completion before the span is satisfied surfaces as
///     `error.UnexpectedEndOfFile`.
///
/// `PieceStore` does not retain an `IO` pointer between calls. The
/// previous `io: *IO` field was a footgun: the daemon constructs the
/// store in a background worker against a one-shot `init_io` that
/// went out of scope when the worker function returned, leaving any
/// later `store.io.*` access dangling. The hot path (peer_policy
/// submits its own `self.io.write` calls per span using the shared
/// fds from `PieceStore.fileHandles(...)`) was never affected, but
/// the field was a UAF waiting to happen for `sync` / `writePiece` /
/// `readPiece`. Removing the field eliminates the latent bug; every
/// caller that needs an op already owns the `IO` they constructed
/// the store with (CLI verify, tests, recheck), so passing it back
/// in is uniformly local.
///
/// Note: the daemon's hot piece-write path (peer wire → disk) does
/// NOT go through `PieceStore.writePiece` — `peer_policy` submits
/// its own `self.io.write` calls per span using the shared fds from
/// `PieceStore.fileHandles(...)`. `writePiece`/`readPiece` are
/// reached only from the `varuna verify` CLI command
/// (`recheckExistingData`) and tests that drive the store directly.
/// Both contexts spin up their own io ring and block on `io.tick`
/// until our completions land, so the "submit + drain" shape is the
/// correct semantic.
pub fn PieceStoreOf(comptime IO: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        session: *const torrent.session.Session,
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
        ///
        /// `io` is used only for the one-time `fallocate` pass during
        /// init; the returned `Self` does not retain the pointer.
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
        ///
        /// `io` is used only for the one-time `fallocate` against the
        /// newly-opened file; the store does not retain the pointer.
        pub fn ensureFileOpen(self: *Self, io: *IO, file_index: usize) !std.fs.File {
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

            try preallocateOne(io, file, file_entry.length);
            self.files[file_index] = file;
            return file;
        }

        /// Tracking state shared across the spans of a single
        /// `writePiece` / `readPiece` call. Updated by each span's
        /// completion callback; the caller polls `pending` and surfaces
        /// `first_error` once all completions have landed.
        const PieceIoCtx = struct {
            pending: usize,
            first_error: ?anyerror = null,
        };

        /// Per-span tracking for an in-flight `writePiece`. Heap-located
        /// inside the caller's `states` slice so each span carries its
        /// own `Completion` and the (possibly shrinking) `remaining` /
        /// `offset` pair the short-write loop advances. Carries `io`
        /// directly so the short-write re-submit path doesn't need to
        /// reach back through the store (which no longer keeps an `IO`
        /// pointer).
        const WriteSpanState = struct {
            io: *IO,
            ctx: *PieceIoCtx,
            fd: posix.fd_t,
            /// Buffer remaining to write; advances on short writes.
            remaining: []const u8,
            /// File offset for the next chunk; advances on short writes.
            offset: u64,
            completion: io_interface.Completion = .{},
        };

        /// Per-span tracking for an in-flight `readPiece`. Same shape
        /// as `WriteSpanState` but with a mutable destination slice.
        const ReadSpanState = struct {
            io: *IO,
            ctx: *PieceIoCtx,
            fd: posix.fd_t,
            /// Destination remaining to fill; shrinks on short reads.
            remaining: []u8,
            /// File offset for the next chunk; advances on short reads.
            offset: u64,
            completion: io_interface.Completion = .{},
        };

        fn writeSpanCallback(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const state: *WriteSpanState = @ptrCast(@alignCast(userdata.?));
            const ctx = state.ctx;
            switch (result) {
                .write => |r| {
                    if (r) |n| {
                        if (n == 0) {
                            // No progress and no error — treat as
                            // unexpected end-of-file, matching the
                            // pre-refactor `pwriteAll` semantics.
                            if (ctx.first_error == null) ctx.first_error = error.UnexpectedEndOfFile;
                            ctx.pending -= 1;
                            return .disarm;
                        }
                        if (n >= state.remaining.len) {
                            // Span fully written.
                            ctx.pending -= 1;
                            return .disarm;
                        }
                        // Short write — re-submit the remainder. The
                        // backend has already cleared `in_flight` on
                        // the completion before invoking the callback,
                        // so `armCompletion` re-arms cleanly.
                        state.remaining = state.remaining[n..];
                        state.offset += n;
                        state.io.write(
                            .{ .fd = state.fd, .buf = state.remaining, .offset = state.offset },
                            &state.completion,
                            state,
                            writeSpanCallback,
                        ) catch |err| {
                            if (ctx.first_error == null) ctx.first_error = err;
                            ctx.pending -= 1;
                            return .disarm;
                        };
                        // We re-submitted: must NOT return .rearm (would
                        // double-arm the completion). Backend now owns
                        // it again until the next CQE.
                        return .disarm;
                    } else |err| {
                        if (ctx.first_error == null) ctx.first_error = err;
                        ctx.pending -= 1;
                        return .disarm;
                    }
                },
                else => unreachable,
            }
        }

        fn readSpanCallback(
            userdata: ?*anyopaque,
            _: *io_interface.Completion,
            result: io_interface.Result,
        ) io_interface.CallbackAction {
            const state: *ReadSpanState = @ptrCast(@alignCast(userdata.?));
            const ctx = state.ctx;
            switch (result) {
                .read => |r| {
                    if (r) |n| {
                        if (n == 0) {
                            // Premature EOF — file shorter than the span
                            // requested. Matches the pre-refactor
                            // `preadAll`-loop + length-check behaviour
                            // that returned `error.UnexpectedEndOfFile`.
                            if (ctx.first_error == null) ctx.first_error = error.UnexpectedEndOfFile;
                            ctx.pending -= 1;
                            return .disarm;
                        }
                        if (n >= state.remaining.len) {
                            ctx.pending -= 1;
                            return .disarm;
                        }
                        // Short read — re-submit for the remainder.
                        state.remaining = state.remaining[n..];
                        state.offset += n;
                        state.io.read(
                            .{ .fd = state.fd, .buf = state.remaining, .offset = state.offset },
                            &state.completion,
                            state,
                            readSpanCallback,
                        ) catch |err| {
                            if (ctx.first_error == null) ctx.first_error = err;
                            ctx.pending -= 1;
                            return .disarm;
                        };
                        return .disarm;
                    } else |err| {
                        if (ctx.first_error == null) ctx.first_error = err;
                        ctx.pending -= 1;
                        return .disarm;
                    }
                },
                else => unreachable,
            }
        }

        /// Write a piece to disk via async `io.write`. Submits one write
        /// per span (one per file the piece touches) and blocks the
        /// calling thread on `io.tick` until every completion lands.
        /// Replaces the pre-2026-04-28 synchronous `pwriteAll` loop.
        ///
        /// Daemon hot path: peer wire → disk does NOT call this — see
        /// `peer_policy.zig`'s direct `self.io.write` calls. Used by
        /// the `varuna verify` CLI seed-file fixture, the recheck
        /// integration tests, and the inline RealIO round-trip tests
        /// below.
        pub fn writePiece(
            self: *Self,
            io: *IO,
            spans: []const torrent.layout.Layout.Span,
            piece_data: []const u8,
        ) !void {
            if (spans.len == 0) return;

            // Phase 1: ensure every span's file is open. `ensureFileOpen`
            // may submit its own fallocate (and tick the ring); doing it
            // up front keeps the per-span states stable for phase 3.
            for (spans) |span| {
                _ = try self.ensureFileOpen(io, span.file_index);
            }

            // Phase 2: allocate per-span tracking state. Heap-allocated
            // because each `WriteSpanState` carries its own `Completion`
            // and the backend may write `_backend_state` until the
            // callback fires.
            const states = try self.allocator.alloc(WriteSpanState, spans.len);
            defer self.allocator.free(states);
            var ctx = PieceIoCtx{ .pending = spans.len };
            for (spans, 0..) |span, i| {
                const file = self.files[span.file_index].?;
                const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
                states[i] = .{
                    .io = io,
                    .ctx = &ctx,
                    .fd = file.handle,
                    .remaining = block,
                    .offset = span.file_offset,
                    .completion = .{},
                };
            }

            // Phase 3: submit, then drain. Submission failures bubble
            // up directly; if any submit succeeded earlier we'd leak
            // pending counters — but `io.write` only fails before
            // arming the completion, so `pending` doesn't include the
            // failing submit. We need to fix `ctx.pending` in that
            // case before returning.
            var submitted: usize = 0;
            for (states) |*state| {
                io.write(
                    .{ .fd = state.fd, .buf = state.remaining, .offset = state.offset },
                    &state.completion,
                    state,
                    writeSpanCallback,
                ) catch |err| {
                    // Adjust pending to match what we actually submitted
                    // so the drain loop terminates cleanly.
                    ctx.pending -= (spans.len - submitted);
                    while (ctx.pending > 0) try io.tick(1);
                    if (ctx.first_error) |first| return first;
                    return err;
                };
                submitted += 1;
            }

            while (ctx.pending > 0) try io.tick(1);
            if (ctx.first_error) |err| return err;
        }

        /// Read a piece from disk via async `io.read`. Submits one read
        /// per span and blocks on `io.tick` until every completion
        /// lands. Short reads are looped just like `preadAll` did; a
        /// 0-byte completion before the span is satisfied surfaces as
        /// `error.UnexpectedEndOfFile`.
        ///
        /// Used by the `varuna verify` CLI command via
        /// `recheckExistingData` / `recheckV2`, and by tests that drive
        /// the store directly. Not on the daemon hot path.
        pub fn readPiece(
            self: *Self,
            io: *IO,
            spans: []const torrent.layout.Layout.Span,
            piece_data: []u8,
        ) !void {
            if (spans.len == 0) return;

            const states = try self.allocator.alloc(ReadSpanState, spans.len);
            defer self.allocator.free(states);
            var ctx = PieceIoCtx{ .pending = spans.len };
            for (spans, 0..) |span, i| {
                const file = self.files[span.file_index] orelse return error.FileNotOpen;
                const block = piece_data[span.piece_offset .. span.piece_offset + span.length];
                states[i] = .{
                    .io = io,
                    .ctx = &ctx,
                    .fd = file.handle,
                    .remaining = block,
                    .offset = span.file_offset,
                    .completion = .{},
                };
            }

            var submitted: usize = 0;
            for (states) |*state| {
                io.read(
                    .{ .fd = state.fd, .buf = state.remaining, .offset = state.offset },
                    &state.completion,
                    state,
                    readSpanCallback,
                ) catch |err| {
                    ctx.pending -= (spans.len - submitted);
                    while (ctx.pending > 0) try io.tick(1);
                    if (ctx.first_error) |first| return first;
                    return err;
                };
                submitted += 1;
            }

            while (ctx.pending > 0) try io.tick(1);
            if (ctx.first_error) |err| return err;
        }

        /// Flush all open files via async `io.fsync` (datasync). Submits
        /// one fsync op per open file through the supplied `io` and
        /// blocks the calling thread on `io.tick` until every fsync
        /// completes.
        ///
        /// Replaces the previous synchronous `posix.fdatasync` loop. The
        /// async path lets the event loop interleave other CQEs (e.g. a
        /// peer recv) while the kernel walks the file's metadata.
        ///
        /// Daemon flushes go through the EL-level sync sweep on
        /// `EventLoop.submitTorrentSync` instead, which keeps the fsync
        /// fan-out on the long-lived loop's `IO`. This method is reached
        /// from CLI verify and tests today.
        pub fn sync(self: *Self, io: *IO) !void {
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
                    try io.fsync(
                        .{ .fd = file.handle, .datasync = true },
                        &completions[i],
                        &ctx,
                        syncCompleteCallback,
                    );
                    i += 1;
                }
            }

            while (ctx.pending > 0) try io.tick(1);
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

/// Per-fallocate completion ticket: tracks pending count + first error,
/// shared across the batch by &PreallocCtx in `userdata`. The fallback
/// to `io.truncate` only fires when the kernel reports the filesystem
/// can't do fallocate at all (EOPNOTSUPP); other errors propagate.
const PreallocCtx = struct {
    pending: usize,
    first_error: ?anyerror = null,
    /// Same length and ordering as `lengths`. Indexed by `slot.file_index`
    /// so `slot.needs_truncate` decisions don't need to walk the slots
    /// array.
    files: []const ?std.fs.File,
    /// Per-file lengths, parallel to `files`.
    lengths: []const u64,
    /// Overall flag set if any completion took the fallback path; lets
    /// the caller log "n files fell back to truncate" if desired (we
    /// currently just consume it silently).
    fallback_count: usize = 0,
};

const PreallocSlot = struct {
    ctx: *PreallocCtx,
    file_index: usize,
    /// Set by the fallocate callback when the kernel returned
    /// `error.OperationNotSupported`. The caller then submits an
    /// `io.truncate` against `file_index` in a second drain pass.
    needs_truncate: bool = false,
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
            // truncate. Other errors (NoSpaceLeft, IoError, …) propagate.
            // The actual truncate is submitted by the caller after the
            // fallocate drain completes — we just record the need here.
            if (err == error.OperationNotSupported) {
                if (ctx.files[slot.file_index] != null) {
                    slot.needs_truncate = true;
                    ctx.fallback_count += 1;
                } else if (ctx.first_error == null) {
                    ctx.first_error = error.FileNotOpen;
                }
            } else {
                if (ctx.first_error == null) ctx.first_error = err;
            }
        },
        else => unreachable,
    }
    return .disarm;
}

/// Per-truncate completion ticket. The fallback truncate phase
/// re-uses the slot's pre-allocation completion and the same drain
/// pattern, but tracks pending separately from the fallocate ctx.
const TruncateCtx = struct {
    pending: usize,
    first_error: ?anyerror = null,
};

fn truncateCallback(
    userdata: ?*anyopaque,
    _: *io_interface.Completion,
    result: io_interface.Result,
) io_interface.CallbackAction {
    const ctx: *TruncateCtx = @ptrCast(@alignCast(userdata.?));
    std.debug.assert(ctx.pending > 0);
    ctx.pending -= 1;
    switch (result) {
        .truncate => |r| _ = r catch |err| {
            if (ctx.first_error == null) ctx.first_error = err;
        },
        else => unreachable,
    }
    return .disarm;
}

/// Submit one fallocate per open file in `files` and drain the ring.
/// Files at indices marked `do_not_download` (null entries) are skipped.
/// On filesystems where fallocate returns `error.OperationNotSupported`
/// (tmpfs <5.10, FAT32, certain FUSE FSes), a second drain pass
/// submits `io.truncate` per affected file so each file is still
/// extended to its torrent-declared length.
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

    // Fallback phase: any slot whose fallocate completed with
    // `error.OperationNotSupported` now needs an `io.truncate`. Submit
    // them all and drain. Re-uses the per-slot completions that just
    // disarmed during the fallocate drain.
    if (ctx.fallback_count > 0) {
        var t_ctx = TruncateCtx{ .pending = ctx.fallback_count };
        var slot_idx: usize = 0;
        for (slots) |*slot| {
            if (slot.needs_truncate) {
                const file = ctx.files[slot.file_index].?;
                try io.truncate(
                    .{ .fd = file.handle, .length = ctx.lengths[slot.file_index] },
                    &completions[slot_idx],
                    &t_ctx,
                    truncateCallback,
                );
            }
            slot_idx += 1;
        }
        while (t_ctx.pending > 0) try io.tick(1);
        if (t_ctx.first_error) |err| return err;
    }
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
        // Filesystem doesn't support fallocate — fall back to truncate.
        // Reuse the same completion (the fallocate already disarmed it).
        var t_ctx = TruncateCtx{ .pending = 1 };
        try io.truncate(
            .{ .fd = file.handle, .length = length },
            &c,
            &t_ctx,
            truncateCallback,
        );
        while (t_ctx.pending > 0) try io.tick(1);
        if (t_ctx.first_error) |err| return err;
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

    var io = backend.initOneshot(std.testing.allocator) catch return error.SkipZigTest;
    defer io.deinit();

    var store = try PieceStore.init(std.testing.allocator, &session, &io);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer plan.deinit(std.testing.allocator);

    try store.writePiece(&io, plan.spans, "spam");
    try store.sync(&io);

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

    var io = backend.initOneshot(std.testing.allocator) catch return error.SkipZigTest;
    defer io.deinit();

    var store = try PieceStore.init(std.testing.allocator, &session, &io);
    defer store.deinit();

    const plan = try @import("verify.zig").planPieceVerification(std.testing.allocator, &session, 0);
    defer plan.deinit(std.testing.allocator);

    try store.writePiece(&io, plan.spans, "spam");

    var piece_buffer: [4]u8 = undefined;
    try store.readPiece(&io, plan.spans, piece_buffer[0..]);

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

    var io = backend.initOneshot(std.testing.allocator) catch return error.SkipZigTest;
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

    var io = backend.initOneshot(std.testing.allocator) catch return error.SkipZigTest;
    defer io.deinit();

    // Skip the first file
    const priorities = [_]FilePriority{ .do_not_download, .normal };
    var store = try PieceStore.initWithPriorities(std.testing.allocator, &session, &io, priorities[0..]);
    defer store.deinit();

    try std.testing.expect(store.files[0] == null);

    // Now open it on demand
    const file = try store.ensureFileOpen(&io, 0);
    try std.testing.expect(file.handle >= 0);
    try std.testing.expect(store.files[0] != null);
}

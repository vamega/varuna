//! Backend parity test — proves RealIO and SimIO satisfy the same
//! `io_interface` contract by running identical test bodies against both.
//!
//! The test bodies are written generic over the comptime IO type. Each
//! body submits a sequence of operations and asserts the observed
//! callbacks match expectations. If a backend's method signature drifts
//! from the contract, this file fails to compile — making the contract
//! enforceable at the build, not just a doc-comment promise.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const testing = std.testing;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const RealIO = varuna.io.real_io.RealIO;
const SimIO = varuna.io.sim_io.SimIO;

const Completion = ifc.Completion;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;

// ── Compile-time interface check ──────────────────────────
//
// Forces both backends to expose the same set of submission methods. A
// missing or renamed method fails to compile here, before any test runs.

fn requireBackendMethods(comptime IO: type) void {
    comptime {
        const required = [_][]const u8{
            "init",     "deinit",   "tick",
            "recv",     "send",     "recvmsg",
            "sendmsg",  "read",     "write",
            "fsync",    "openat",   "mkdirat",
            "renameat", "unlinkat", "statx",
            "getdents", "socket",   "connect",
            "accept",   "timeout",  "poll",
            "cancel",
        };
        for (required) |name| {
            if (!@hasDecl(IO, name)) {
                @compileError(@typeName(IO) ++ " is missing required method: " ++ name);
            }
        }
    }
}

comptime {
    requireBackendMethods(RealIO);
    requireBackendMethods(SimIO);
}

// ── Shared test bodies ────────────────────────────────────

const Counter = struct {
    fires: u32 = 0,
    last_result: ?Result = null,
};

fn counterCallback(
    userdata: ?*anyopaque,
    _: *Completion,
    result: Result,
) CallbackAction {
    const c: *Counter = @ptrCast(@alignCast(userdata.?));
    c.fires += 1;
    c.last_result = result;
    return .disarm;
}

/// Submit a single timeout, drain it, expect exactly one call.
/// Generic over the IO backend.
fn runTimeoutOnce(
    comptime IO: type,
    io: *IO,
    drain_fn: fn (io: *IO) anyerror!void,
) !void {
    var c = Completion{};
    var counter = Counter{};
    try io.timeout(.{ .ns = 1_000_000 }, &c, &counter, counterCallback);
    try drain_fn(io);
    try testing.expectEqual(@as(u32, 1), counter.fires);
    switch (counter.last_result.?) {
        .timeout => |r| try r,
        else => try testing.expect(false),
    }
}

/// Submit a cancel against an unsubmitted target, drain, expect
/// OperationNotFound. Generic over the IO backend.
fn runCancelOfNothing(
    comptime IO: type,
    io: *IO,
    drain_fn: fn (io: *IO) anyerror!void,
) !void {
    var unsubmitted = Completion{};
    var canceller = Completion{};
    var counter = Counter{};
    try io.cancel(.{ .target = &unsubmitted }, &canceller, &counter, counterCallback);
    try drain_fn(io);
    try testing.expectEqual(@as(u32, 1), counter.fires);
    switch (counter.last_result.?) {
        .cancel => |r| try testing.expectError(error.OperationNotFound, r),
        else => try testing.expect(false),
    }
}

fn runDirectoryOpsRoundTrip(
    comptime IO: type,
    io: *IO,
    root_fd: posix.fd_t,
    drain_fn: fn (io: *IO) anyerror!void,
) !void {
    {
        var c = Completion{};
        var counter = Counter{};
        try io.mkdirat(.{ .dir_fd = root_fd, .path = "stage", .mode = 0o755 }, &c, &counter, counterCallback);
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .mkdirat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.openat(
            .{
                .dir_fd = root_fd,
                .path = "stage/file.tmp",
                .flags = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                .mode = 0o644,
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        const fd = switch (counter.last_result.?) {
            .openat => |r| try r,
            else => return error.UnexpectedResult,
        };
        io.closeSocket(fd);
    }

    {
        var st: linux.Statx = undefined;
        var c = Completion{};
        var counter = Counter{};
        try io.statx(
            .{
                .dir_fd = root_fd,
                .path = "stage/file.tmp",
                .flags = linux.AT.SYMLINK_NOFOLLOW,
                .mask = linux.STATX_TYPE | linux.STATX_SIZE,
                .buf = &st,
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .statx => |r| try r,
            else => try testing.expect(false),
        }
        try testing.expect(st.mask & linux.STATX_TYPE != 0);
        try testing.expect(st.mask & linux.STATX_SIZE != 0);
        try testing.expectEqual(@as(u64, 0), st.size);
        try testing.expect((st.mode & linux.S.IFMT) == linux.S.IFREG);
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.renameat(
            .{
                .old_dir_fd = root_fd,
                .old_path = "stage/file.tmp",
                .new_dir_fd = root_fd,
                .new_path = "stage/file.dat",
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .renameat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.openat(
            .{
                .dir_fd = root_fd,
                .path = "stage/file.dat",
                .flags = .{ .ACCMODE = .RDONLY },
                .mode = 0,
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        const fd = switch (counter.last_result.?) {
            .openat => |r| try r,
            else => return error.UnexpectedResult,
        };
        io.closeSocket(fd);
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.openat(
            .{
                .dir_fd = root_fd,
                .path = "stage",
                .flags = .{ .ACCMODE = .RDONLY, .DIRECTORY = true },
                .mode = 0,
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        const dir_fd = switch (counter.last_result.?) {
            .openat => |r| try r,
            else => return error.UnexpectedResult,
        };
        defer io.closeSocket(dir_fd);

        var dir_buf: [512]u8 align(@alignOf(linux.dirent64)) = undefined;
        var dents = Completion{};
        var dents_counter = Counter{};
        try io.getdents(.{ .fd = dir_fd, .buf = &dir_buf }, &dents, &dents_counter, counterCallback);
        if (dents_counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), dents_counter.fires);
        const bytes = switch (dents_counter.last_result.?) {
            .getdents => |r| try r,
            else => return error.UnexpectedResult,
        };
        try testing.expect(bytes > 0);

        var saw_file = false;
        var offset: usize = 0;
        while (offset < bytes) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&dir_buf[offset]);
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (std.mem.eql(u8, name, "file.dat")) {
                saw_file = true;
                try testing.expectEqual(linux.DT.REG, entry.type);
            }
            offset += entry.reclen;
        }
        try testing.expect(saw_file);
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.unlinkat(.{ .dir_fd = root_fd, .path = "stage/file.dat" }, &c, &counter, counterCallback);
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .unlinkat => |r| try r,
            else => try testing.expect(false),
        }
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.openat(
            .{
                .dir_fd = root_fd,
                .path = "stage/file.dat",
                .flags = .{ .ACCMODE = .RDONLY },
                .mode = 0,
            },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .openat => |r| try testing.expectError(error.FileNotFound, r),
            else => try testing.expect(false),
        }
    }

    {
        var c = Completion{};
        var counter = Counter{};
        try io.unlinkat(
            .{ .dir_fd = root_fd, .path = "stage", .flags = posix.AT.REMOVEDIR },
            &c,
            &counter,
            counterCallback,
        );
        if (counter.fires == 0) try drain_fn(io);
        try testing.expectEqual(@as(u32, 1), counter.fires);
        switch (counter.last_result.?) {
            .unlinkat => |r| try r,
            else => try testing.expect(false),
        }
    }
}

// ── Drain helpers per backend ─────────────────────────────

fn drainReal(io: *RealIO) !void {
    try io.tick(1);
}

fn drainSim(io: *SimIO) !void {
    try io.advance(2_000_000); // past any 1ms deadline
}

// ── Tests ─────────────────────────────────────────────────

test "RealIO and SimIO both deliver a single timeout" {
    // SimIO branch — runs unconditionally.
    {
        var io = try SimIO.init(testing.allocator, .{});
        defer io.deinit();
        try runTimeoutOnce(SimIO, &io, drainSim);
    }

    // RealIO branch — skip if io_uring is unavailable.
    {
        var io = RealIO.init(.{ .entries = 16 }) catch return;
        defer io.deinit();
        try runTimeoutOnce(RealIO, &io, drainReal);
    }
}

test "RealIO and SimIO both report OperationNotFound for stray cancels" {
    {
        var io = try SimIO.init(testing.allocator, .{});
        defer io.deinit();
        try runCancelOfNothing(SimIO, &io, drainSim);
    }

    {
        var io = RealIO.init(.{ .entries = 16 }) catch return;
        defer io.deinit();
        try runCancelOfNothing(RealIO, &io, drainReal);
    }
}

test "RealIO and SimIO both perform fd-relative directory ops" {
    {
        var io = try SimIO.init(testing.allocator, .{});
        defer io.deinit();
        try runDirectoryOpsRoundTrip(SimIO, &io, posix.AT.FDCWD, drainSim);
    }

    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var io = RealIO.init(.{ .entries = 16 }) catch return;
        defer io.deinit();
        try runDirectoryOpsRoundTrip(RealIO, &io, tmp.dir.fd, drainReal);
    }
}

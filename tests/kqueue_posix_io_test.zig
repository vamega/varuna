//! KqueuePosixIO bridge tests — varuna_mod side.
//!
//! These tests link against the full `varuna_mod` and pull KqueuePosixIO in
//! via `varuna.io.kqueue_posix_io`. They do not run under `-Dio=kqueue_posix`
//! on a macOS target (the daemon graph hard-references RealIO and won't
//! cross-compile). The standalone `zig build test-kqueue-posix-io` step
//! handles cross-compile validation.
//!
//! Use this file for tests that legitimately want to share fixtures or
//! types with the rest of varuna's test corpus. Backend-specific
//! mock-style tests live inline in `src/io/kqueue_posix_io.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const kqueue_posix_io = varuna.io.kqueue_posix_io;

const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;
const KqueuePosixIO = kqueue_posix_io.KqueuePosixIO;

const is_kqueue_platform = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

test "KqueuePosixIO bridge: KqueueState size + alignment fits the contract budget" {
    try testing.expect(@sizeOf(kqueue_posix_io.KqueueState) <= ifc.backend_state_size);
    try testing.expect(@alignOf(kqueue_posix_io.KqueueState) <= ifc.backend_state_align);
}

test "KqueuePosixIO bridge: init / deinit (kqueue platforms only)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueuePosixIO.init(testing.allocator, .{});
    defer io.deinit();
    try testing.expect(io.kq >= 0);
}

test "KqueuePosixIO bridge: fsync round-trips through PosixFilePool (kqueue platforms only)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueuePosixIO.init(testing.allocator, .{});
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("kqueue_fsync", .{ .read = true, .truncate = true });
    defer file.close();
    try file.writeAll("ok");

    const Box = struct {
        called: u32 = 0,
        err: ?anyerror = null,
    };
    var box = Box{};
    const cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            b.called += 1;
            switch (result) {
                .fsync => |r| if (r) |_| {} else |err| {
                    b.err = err;
                },
                else => {},
            }
            return .disarm;
        }
    }.cb;

    var c = Completion{};
    try io.fsync(.{ .fd = file.handle, .datasync = true }, &c, &box, cb);

    var attempts: u32 = 0;
    while (box.called == 0 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(u32, 1), box.called);
    try testing.expectEqual(@as(?anyerror, null), box.err);
}

test "KqueuePosixIO bridge: write-then-read round-trip (kqueue platforms only)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueuePosixIO.init(testing.allocator, .{});
    defer io.deinit();
    io.bindWakeup();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("kqueue_rw", .{ .read = true, .truncate = true });
    defer file.close();

    const Box = struct {
        write_n: ?usize = null,
        read_n: ?usize = null,
        read_buf: [16]u8 = undefined,
        done: u32 = 0,
    };
    var box = Box{};

    const write_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            switch (result) {
                .write => |r| b.write_n = r catch null,
                else => {},
            }
            b.done += 1;
            return .disarm;
        }
    }.cb;
    const read_cb = struct {
        fn cb(ud: ?*anyopaque, _: *Completion, result: Result) CallbackAction {
            const b: *Box = @ptrCast(@alignCast(ud.?));
            switch (result) {
                .read => |r| b.read_n = r catch null,
                else => {},
            }
            b.done += 1;
            return .disarm;
        }
    }.cb;

    var write_c = Completion{};
    try io.write(.{ .fd = file.handle, .buf = "varuna", .offset = 0 }, &write_c, &box, write_cb);
    var attempts: u32 = 0;
    while (box.done < 1 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(usize, 6), box.write_n.?);

    var read_c = Completion{};
    try io.read(.{ .fd = file.handle, .buf = &box.read_buf, .offset = 0 }, &read_c, &box, read_cb);
    attempts = 0;
    while (box.done < 2 and attempts < 200) : (attempts += 1) try io.tick(1);
    try testing.expectEqual(@as(usize, 6), box.read_n.?);
    try testing.expectEqualStrings("varuna", box.read_buf[0..6]);
}

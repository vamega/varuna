//! KqueueIO bridge tests — varuna_mod side.
//!
//! These tests link against the full `varuna_mod` and pull KqueueIO in
//! via `varuna.io.kqueue_io`. They do not run under `-Dio=kqueue` on a
//! macOS target (the daemon graph hard-references RealIO and won't
//! cross-compile). The standalone `zig build test-kqueue-io` step
//! handles cross-compile validation.
//!
//! Use this file for tests that legitimately want to share fixtures or
//! types with the rest of varuna's test corpus. Backend-specific
//! mock-style tests live inline in `src/io/kqueue_io.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const kqueue_io = varuna.io.kqueue_io;

const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;
const KqueueIO = kqueue_io.KqueueIO;

const is_kqueue_platform = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

test "KqueueIO bridge: KqueueState size + alignment fits the contract budget" {
    try testing.expect(@sizeOf(kqueue_io.KqueueState) <= ifc.backend_state_size);
    try testing.expect(@alignOf(kqueue_io.KqueueState) <= ifc.backend_state_align);
}

test "KqueueIO bridge: init / deinit (kqueue platforms only)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueueIO.init(testing.allocator, .{});
    defer io.deinit();
    try testing.expect(io.kq >= 0);
}

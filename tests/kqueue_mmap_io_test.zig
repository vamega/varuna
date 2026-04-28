//! KqueueMmapIO bridge tests — varuna_mod side.
//!
//! These tests link against the full `varuna_mod` and pull KqueueMmapIO in
//! via `varuna.io.kqueue_mmap_io`. They do not run under `-Dio=kqueue_mmap`
//! on a macOS target (the daemon graph hard-references RealIO and won't
//! cross-compile). The standalone `zig build test-kqueue-mmap-io` step
//! handles cross-compile validation.
//!
//! Use this file for tests that legitimately want to share fixtures or
//! types with the rest of varuna's test corpus. Backend-specific
//! mock-style tests live inline in `src/io/kqueue_mmap_io.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;

const varuna = @import("varuna");
const ifc = varuna.io.io_interface;
const kqueue_mmap_io = varuna.io.kqueue_mmap_io;

const Completion = ifc.Completion;
const Operation = ifc.Operation;
const Result = ifc.Result;
const CallbackAction = ifc.CallbackAction;
const KqueueMmapIO = kqueue_mmap_io.KqueueMmapIO;

const is_kqueue_platform = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

test "KqueueMmapIO bridge: KqueueState size + alignment fits the contract budget" {
    try testing.expect(@sizeOf(kqueue_mmap_io.KqueueState) <= ifc.backend_state_size);
    try testing.expect(@alignOf(kqueue_mmap_io.KqueueState) <= ifc.backend_state_align);
}

test "KqueueMmapIO bridge: init / deinit (kqueue platforms only)" {
    if (comptime !is_kqueue_platform) return error.SkipZigTest;
    var io = try KqueueMmapIO.init(testing.allocator, .{});
    defer io.deinit();
    try testing.expect(io.kq >= 0);
}

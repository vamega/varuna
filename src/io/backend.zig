//! IO backend comptime selector.
//!
//! Resolves the daemon's `RealIO` alias to either the io_uring backend
//! (`real_io.RealIO`, default) or the epoll fallback backend
//! (`epoll_io.EpollIO`) based on the `-Dio=` build flag.
//!
//! The kqueue slot is reserved for the parallel kqueue-io-engineer's
//! macOS developer backend; once their `kqueue_io.zig` lands, add a third
//! `else if (build_options.io_backend == .kqueue) kqueue_io.KqueueIO` arm.
//!
//! Today's daemon callers (`src/storage/writer.zig`,
//! `src/io/recheck.zig`, `src/rpc/server.zig`, `src/app.zig`,
//! `src/perf/workloads.zig`, `src/storage/verify.zig`) still
//! `@import("real_io.zig").RealIO` directly. They keep working because
//! that's still the production path. To rewire a caller onto the
//! comptime-selected backend, change its import to
//! `@import("backend.zig").RealIO`. That migration is a follow-up tracked
//! in `progress-reports/2026-04-29-epoll-io-mvp.md` — the MVP doesn't
//! implement the file ops the daemon needs, so wiring it through would
//! produce a daemon that runs but couldn't do storage I/O.
//!
//! Both backends provide:
//!
//!   pub const RealIO/EpollIO = struct { ... }
//!   pub fn init(...) !@This();
//!   pub fn deinit(self: *@This()) void;
//!   pub fn tick(self: *@This(), wait_at_least: u32) !void;
//!   pub fn closeSocket(self: *@This(), fd: posix.fd_t) void;
//!   ... submission methods ...
//!
//! Because the public submission methods all accept the same op shapes
//! (defined in `io_interface.zig`) and the `Completion` struct is shared,
//! the backends are interchangeable from the caller's perspective.

const build_options = @import("build_options");
const real_io_mod = @import("real_io.zig");
const epoll_io_mod = @import("epoll_io.zig");

/// The daemon's selected primary IO backend. Aliased through this name so
/// callers can transparently switch between io_uring and epoll based on
/// `-Dio=`. Note: `init` signatures differ between backends — RealIO takes
/// a `Config{ .entries = ..., .flags = ... }`; EpollIO takes
/// `(allocator, Config{ .max_completions = ... })`. Callers that want to
/// switch dynamically need to handle this at the call site (or use
/// `init_default` below).
pub const RealIO = switch (build_options.io_backend) {
    .io_uring => real_io_mod.RealIO,
    .epoll => epoll_io_mod.EpollIO,
};

/// Re-exports for direct callers who want to spell out the chosen backend.
pub const IoUringBackend = real_io_mod.RealIO;
pub const EpollBackend = epoll_io_mod.EpollIO;

/// Build-time identity of the selected backend. Useful for runtime
/// logging and conditional code paths (e.g. "skip the file-op test under
/// EpollIO until the file-op pool lands").
pub const selected: SelectedBackend = switch (build_options.io_backend) {
    .io_uring => .io_uring,
    .epoll => .epoll,
};

pub const SelectedBackend = enum {
    io_uring,
    epoll,
    // kqueue, // reserved for parallel macOS engineer
};

test "backend selector resolves to a real type" {
    const std = @import("std");
    // Sanity check: the selected type has the contract methods.
    try std.testing.expect(@hasDecl(RealIO, "init"));
    try std.testing.expect(@hasDecl(RealIO, "deinit"));
    try std.testing.expect(@hasDecl(RealIO, "tick"));
    try std.testing.expect(@hasDecl(RealIO, "closeSocket"));
    try std.testing.expect(@hasDecl(RealIO, "recv"));
    try std.testing.expect(@hasDecl(RealIO, "send"));
}

//! IO backend comptime selector.
//!
//! Resolves the daemon's `RealIO` alias to one of six backends based on the
//! `-Dio=` build flag:
//!
//!   * `io_uring` (default, Linux): production io_uring proactor
//!     (`real_io.RealIO`).
//!   * `epoll_posix`: Linux epoll readiness + POSIX `pread`/`pwrite` file
//!     ops offloaded to a thread pool (`epoll_posix_io.EpollPosixIO`).
//!   * `epoll_mmap`: Linux epoll readiness + mmap-backed file I/O
//!     (`epoll_mmap_io.EpollMmapIO`).
//!   * `kqueue_posix`: macOS / BSD kqueue readiness + POSIX file ops
//!     (`kqueue_posix_io.KqueuePosixIO` — STUB until the kqueue engineer
//!     replaces it via the rename of `kqueue_io.zig`).
//!   * `kqueue_mmap`: macOS / BSD kqueue readiness + mmap-backed file I/O
//!     (`kqueue_mmap_io.KqueueMmapIO` — STUB until the kqueue engineer
//!     creates the real implementation).
//!   * `sim`: in-process `SimIO` simulator (`sim_io.SimIO`). Resolves
//!     `RealIO` to `SimIO` so test builds can drop the simulator into
//!     code that's currently hard-wired to io_uring's `RealIO`.
//!
//! ## File-I/O strategy as a separate axis
//!
//! Each readiness backend is paired with a file-I/O strategy because the two
//! axes have independent tradeoffs:
//!
//!   * POSIX (`pread`/`pwrite` on a thread pool): predictable, mirrors
//!     io_uring semantics, copies through syscall buffers.
//!   * mmap (`memcpy` + `msync`): zero-copy, OS pagecache implicit; page
//!     faults can stall the calling thread.
//!
//! Splitting these into separate backends keeps each one's invariants clear
//! — a profiling regression in one strategy doesn't hide a regression in the
//! other.
//!
//! ## Today's daemon callers
//!
//! Today's daemon callers (`src/storage/writer.zig`, `src/io/recheck.zig`,
//! `src/rpc/server.zig`, `src/app.zig`, `src/perf/workloads.zig`,
//! `src/storage/verify.zig`) still `@import("real_io.zig").RealIO`
//! directly. They keep working because that's still the production path.
//! To rewire a caller onto the comptime-selected backend, change its import
//! to `@import("backend.zig").RealIO`. That migration is a follow-up — the
//! non-`io_uring` backends are MVPs that don't yet implement every op the
//! daemon exercises, so wiring them through would produce a daemon that
//! runs but couldn't do real work.
//!
//! All backends provide the contract surface in `io_interface.zig`:
//!
//!   pub const T = struct { ... }
//!   pub fn init(...) !@This();
//!   pub fn deinit(self: *@This()) void;
//!   pub fn tick(self: *@This(), wait_at_least: u32) !void;
//!   pub fn closeSocket(self: *@This(), fd: posix.fd_t) void;
//!   ... submission methods ...
//!
//! Note: `init` signatures differ. RealIO takes `Config{ .entries, .flags }`.
//! The readiness backends and SimIO take `(allocator, Config)`. Callers that
//! want to switch backends dynamically need to handle this at the call site.

const build_options = @import("build_options");
const real_io_mod = @import("real_io.zig");
const epoll_posix_io_mod = @import("epoll_posix_io.zig");
const epoll_mmap_io_mod = @import("epoll_mmap_io.zig");
const kqueue_posix_io_mod = @import("kqueue_posix_io.zig");
const kqueue_mmap_io_mod = @import("kqueue_mmap_io.zig");
const sim_io_mod = @import("sim_io.zig");

/// The daemon's selected primary IO backend. Aliased through this name so
/// callers can transparently switch between the six backends based on
/// `-Dio=`. Note: `init` signatures differ between backends — see the file
/// header for the breakdown.
pub const RealIO = switch (build_options.io_backend) {
    .io_uring => real_io_mod.RealIO,
    .epoll_posix => epoll_posix_io_mod.EpollPosixIO,
    .epoll_mmap => epoll_mmap_io_mod.EpollMmapIO,
    .kqueue_posix => kqueue_posix_io_mod.KqueuePosixIO,
    .kqueue_mmap => kqueue_mmap_io_mod.KqueueMmapIO,
    .sim => sim_io_mod.SimIO,
};

/// Re-exports for direct callers who want to spell out the chosen backend.
pub const IoUringBackend = real_io_mod.RealIO;
pub const EpollPosixBackend = epoll_posix_io_mod.EpollPosixIO;
pub const EpollMmapBackend = epoll_mmap_io_mod.EpollMmapIO;
pub const KqueuePosixBackend = kqueue_posix_io_mod.KqueuePosixIO;
pub const KqueueMmapBackend = kqueue_mmap_io_mod.KqueueMmapIO;
pub const SimBackend = sim_io_mod.SimIO;

/// Build-time identity of the selected backend. Useful for runtime
/// logging and conditional code paths (e.g. "skip the file-op test under
/// EpollPosixIO until the file-op pool lands").
pub const selected: SelectedBackend = switch (build_options.io_backend) {
    .io_uring => .io_uring,
    .epoll_posix => .epoll_posix,
    .epoll_mmap => .epoll_mmap,
    .kqueue_posix => .kqueue_posix,
    .kqueue_mmap => .kqueue_mmap,
    .sim => .sim,
};

pub const SelectedBackend = enum {
    io_uring,
    epoll_posix,
    epoll_mmap,
    kqueue_posix,
    kqueue_mmap,
    sim,
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

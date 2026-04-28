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
//! ## Daemon callers
//!
//! Daemon callers (`src/storage/writer.zig`, `src/io/event_loop.zig`,
//! `src/io/recheck.zig`, `src/io/metadata_handler.zig`,
//! `src/io/http_executor.zig`, `src/rpc/server.zig`,
//! `src/daemon/tracker_executor.zig`, `src/daemon/udp_tracker_executor.zig`,
//! `src/daemon/torrent_session.zig`) reach the chosen backend through
//! the `RealIO` alias here. Standalone CLI tools (`src/app.zig`,
//! `src/storage/verify.zig`) and benchmarks (`src/perf/workloads.zig`)
//! still hard-import `real_io.zig` per the AGENTS.md exemption — those
//! are out-of-scope for the io_uring policy.
//!
//! Sites that need a one-shot ring (e.g. `PieceStore.init`'s per-torrent
//! fallocate drain) call `initOneshot(allocator)` instead of branching
//! on the build flag at every call site, since each backend's `init`
//! signature differs.
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

const std = @import("std");
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

/// Construct a small, short-lived instance of the selected backend.
///
/// Daemon code paths that need a one-shot ring (e.g. `PieceStore.init`'s
/// per-torrent fallocate drain in `torrent_session.zig`) and tests that
/// stand up an IO instance for a single-purpose probe both call this
/// helper instead of branching on the build flag at every call site. The
/// `init` signatures across the six backends are not uniform — RealIO
/// takes only `Config{ .entries, .flags }`, the readiness backends take
/// `(allocator, Config)` with backend-specific Config fields — so a
/// helper is the only way to keep callers backend-agnostic.
///
/// Sizing: each branch picks a small capacity (16 ring entries / 16
/// timer slots) appropriate for one-shot init work. Hot daemon I/O does
/// NOT route through this helper — it goes through the long-lived
/// `EventLoopOf(IO)` ring sized at startup.
///
/// `.sim` is a `@compileError` deliberately. The daemon binary does not
/// run under `-Dio=sim` (sim is for tests, not production), and tests
/// that want a SimIO construct it directly with their own seeded fault
/// config. There's no sensible default `SimIO.init` shape we could pick
/// here that would match what tests actually want.
pub fn initOneshot(allocator: std.mem.Allocator) !RealIO {
    return switch (selected) {
        .io_uring => RealIO.init(.{ .entries = 16 }),
        .epoll_posix => RealIO.init(allocator, .{ .max_completions = 16, .file_pool_workers = 4 }),
        .epoll_mmap => RealIO.init(allocator, .{ .max_completions = 16 }),
        .kqueue_posix => RealIO.init(allocator, .{ .timer_capacity = 16, .file_pool_workers = 4 }),
        .kqueue_mmap => RealIO.init(allocator, .{ .timer_capacity = 16 }),
        .sim => @compileError("backend.initOneshot is not available under -Dio=sim; sim instances are caller-constructed for tests"),
    };
}

test "backend selector resolves to a real type" {
    // Sanity check: the selected type has the contract methods.
    try std.testing.expect(@hasDecl(RealIO, "init"));
    try std.testing.expect(@hasDecl(RealIO, "deinit"));
    try std.testing.expect(@hasDecl(RealIO, "tick"));
    try std.testing.expect(@hasDecl(RealIO, "closeSocket"));
    try std.testing.expect(@hasDecl(RealIO, "recv"));
    try std.testing.expect(@hasDecl(RealIO, "send"));
}

test "initOneshot succeeds under default backend" {
    // Under the default `-Dio=io_uring` build, the helper must hand back
    // a working RealIO. Other backends are exercised through the full
    // daemon build under their respective `-Dio=` flags.
    if (selected != .io_uring) return;
    var io = try initOneshot(std.testing.allocator);
    defer io.deinit();
    try std.testing.expect(@hasDecl(@TypeOf(io), "tick"));
}

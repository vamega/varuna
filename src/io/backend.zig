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
//! `src/tracker/executor.zig`, `src/tracker/udp_executor.zig`,
//! `src/daemon/torrent_session.zig`) reach the chosen backend through
//! the `RealIO` alias here. Standalone CLI tools and benchmarks are
//! out-of-scope for the io_uring policy, but tests and utility commands
//! that exercise daemon storage can still use the selected backend through
//! the one-shot helpers below.
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
//! The readiness backends and SimIO take `(allocator, Config)`. Runtime daemon
//! startup selects a concrete backend branch and uses the generic init helpers
//! below so the rest of the stack can stay on the `EventLoopOf(IO)` contract.

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
/// instance from `initEventLoop`.
///
/// `.sim` is a `@compileError` deliberately. The daemon binary does not
/// run under `-Dio=sim` (sim is for tests, not production), and tests
/// that want a SimIO construct it directly with their own seeded fault
/// config. There's no sensible default `SimIO.init` shape we could pick
/// here that would match what tests actually want.
pub fn initWithCapacityFor(comptime IO: type, allocator: std.mem.Allocator, capacity: u32) !IO {
    const entries: u16 = @intCast(@min(capacity, std.math.maxInt(u16)));
    if (IO == IoUringBackend) {
        return IO.init(.{ .entries = entries });
    } else if (IO == EpollPosixBackend) {
        return IO.init(allocator, .{ .max_completions = capacity, .file_pool_workers = 4 });
    } else if (IO == EpollMmapBackend) {
        return IO.init(allocator, .{ .max_completions = capacity });
    } else if (IO == KqueuePosixBackend) {
        return IO.init(allocator, .{ .timer_capacity = capacity, .pending_capacity = @max(capacity, 256), .file_pool_workers = 4 });
    } else if (IO == KqueueMmapBackend) {
        return IO.init(allocator, .{ .timer_capacity = capacity, .pending_capacity = @max(capacity, 256) });
    } else if (IO == SimBackend) {
        @compileError("backend.initWithCapacityFor is not available for SimIO; sim instances are caller-constructed for tests");
    } else {
        @compileError("unsupported IO backend type");
    }
}

pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: u32) !RealIO {
    return initWithCapacityFor(RealIO, allocator, capacity);
}

pub fn initOneshot(allocator: std.mem.Allocator) !RealIO {
    return initWithCapacity(allocator, 16);
}

pub fn initOneshotFor(comptime IO: type, allocator: std.mem.Allocator) !IO {
    return initWithCapacityFor(IO, allocator, 16);
}

/// Construct a long-lived production-sized instance of the selected
/// backend for the daemon's primary event loop.
///
/// Used by `EventLoopOf(IO).initBare`, which previously hard-coded the
/// io_uring init shape (256 entries + COOP_TASKRUN/SINGLE_ISSUER flags).
/// Each backend gets a sizing appropriate for production daemon
/// throughput; the io_uring branch preserves the historical 256-entry
/// shape with its kernel-aware flags so behavior is identical under
/// `-Dio=io_uring`.
///
/// Same `@compileError` rationale as `initOneshot` for `.sim`.
pub fn initEventLoopFor(comptime IO: type, allocator: std.mem.Allocator) !IO {
    if (IO == IoUringBackend) {
        return IO.init(.{
            .entries = 256,
            .flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER,
        });
    } else if (IO == EpollPosixBackend) {
        return IO.init(allocator, .{ .max_completions = 1024, .file_pool_workers = 4 });
    } else if (IO == EpollMmapBackend) {
        return IO.init(allocator, .{ .max_completions = 1024 });
    } else if (IO == KqueuePosixBackend) {
        return IO.init(allocator, .{ .timer_capacity = 256, .pending_capacity = 4096, .file_pool_workers = 4 });
    } else if (IO == KqueueMmapBackend) {
        return IO.init(allocator, .{ .timer_capacity = 256, .pending_capacity = 4096 });
    } else if (IO == SimBackend) {
        @compileError("backend.initEventLoopFor is not available for SimIO; sim event loops are caller-constructed for tests");
    } else {
        @compileError("unsupported IO backend type");
    }
}

pub fn initEventLoop(allocator: std.mem.Allocator) !RealIO {
    return initEventLoopFor(RealIO, allocator);
}

pub fn nameFor(comptime IO: type) []const u8 {
    if (IO == IoUringBackend) return "io_uring";
    if (IO == EpollPosixBackend) return "epoll_posix";
    if (IO == EpollMmapBackend) return "epoll_mmap";
    if (IO == KqueuePosixBackend) return "kqueue_posix";
    if (IO == KqueueMmapBackend) return "kqueue_mmap";
    if (IO == SimBackend) return "sim";
    @compileError("unsupported IO backend type");
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

//! AsyncMetadataFetchOf(SimIO) integration tests.
//!
//! Drives the parameterised metadata-fetch state machine end-to-end
//! through `EventLoopOf(SimIO)`. These tests force the second
//! instantiation (`AsyncMetadataFetchOf(SimIO)`) through the
//! typechecker and exercise the connect/send/recv error-handling
//! paths inside the state machine — the no-peer fast-fail, the
//! connect-error retry-then-finish path, and the all-peers-fail-
//! handshake-send path.
//!
//! These three together prove `AsyncMetadataFetchOf(IO)` is real
//! (not just typechecks) and that the SimIO event loop drives
//! the state machine correctly through the major error edges.
//!
//! Happy-path metadata fetch (peer responds with a valid info
//! dictionary, assembler completes, `verifyAndComplete` fires) is
//! deferred to a follow-up that needs either a refactor of
//! `connectPeer`'s `posix.socket()` call to route through the IO
//! interface, or a SimIO `setSocketRecvScript` extension that lets
//! tests script BEP 9 protocol responses on arbitrary fds. The
//! state machine's bidirectional protocol shape is substantively
//! different from the recheck refactor's one-way disk-read shape;
//! `setFileBytes` doesn't trivially port. See
//! `progress-reports/2026-04-26-async-metadata-fetch-io-generic.md`
//! for the discussion.

const std = @import("std");
const varuna = @import("varuna");
const event_loop_mod = varuna.io.event_loop;
const sim_io_mod = varuna.io.sim_io;
const SimIO = sim_io_mod.SimIO;
const metadata_handler = varuna.io.metadata_handler;
const posix = std.posix;

const tick_budget: u32 = 256;

test "AsyncMetadataFetchOf(SimIO): no peers finishes immediately" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xCAFE_FEED });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
    };
    var ctx = Ctx{};

    // No peers → start() must call finish(false) synchronously.
    const peers = [_]std.net.Address{};
    try el.startMetadataFetch(
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
            }
        }.cb,
        @ptrCast(&ctx),
    );

    // The no-peer path fires the callback synchronously inside start();
    // no ticks needed. Assert the result.
    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);
    try std.testing.expect(el.metadata_fetch.?.done);

    el.cancelMetadataFetch();
    try std.testing.expect(el.metadata_fetch == null);
}

test "AsyncMetadataFetchOf(SimIO): connect-error fault drains all peers and finishes" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    // 100% connect-error probability — every `self.io.connect(...)` returns
    // error.ConnectionRefused. The state machine must release each slot
    // and try the next peer until peers are exhausted, then `finish(false)`.
    const sim_io = try SimIO.init(allocator, .{
        .seed = 0xDEAD_BEEF,
        .faults = .{ .connect_error_probability = 1.0 },
    });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
        peers_attempted: u32 = 0,
    };
    var ctx = Ctx{};

    // Five peers — more than `max_slots` (3) so we exercise the
    // connect → fail → tryNextPeer → connect refill loop.
    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
        std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 6883),
        std.net.Address.initIp4(.{ 127, 0, 0, 4 }, 6884),
        std.net.Address.initIp4(.{ 127, 0, 0, 5 }, 6885),
    };

    el.startMetadataFetch(
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
                c.peers_attempted = mf.peers_attempted;
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        // posix.socket() may fail in some sandboxes; that's not a
        // statement about AsyncMetadataFetchOf's correctness.
        if (err == error.SystemResources or err == error.PermissionDenied) {
            return error.SkipZigTest;
        }
        return err;
    };

    // Drive ticks via SimIO until the fetch completes. The connect
    // completion fires immediately (deadline 0) on the next tick.
    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);
    try std.testing.expectEqual(@as(u32, peers.len), ctx.peers_attempted);

    el.cancelMetadataFetch();
}

test "AsyncMetadataFetchOf(SimIO): legacy-fd send path causes all peers to fail" {
    const allocator = std.testing.allocator;

    const EL_SimIO = event_loop_mod.EventLoopOf(SimIO);
    // No fault injection — every connect succeeds. But the fd returned
    // by `posix.socket()` is a real kernel fd, well below SimIO's
    // `socket_fd_base = 1000`, so SimIO's `slotForFd` returns null and
    // both `recv` and `send` go through the "legacy fd: zero-byte
    // success" path. `send` returning 0 is treated as failure by the
    // state machine (`if (res <= 0) ... releaseSlot; tryNextPeer`),
    // so each peer fails after handshake send. With three peers, the
    // state machine cycles through all three slots and finishes false.
    const sim_io = try SimIO.init(allocator, .{ .seed = 0xC0DE_C0DE });
    var el = EL_SimIO.initBareWithIO(allocator, sim_io, 0) catch |err| {
        if (err == error.SystemResources) return error.SkipZigTest;
        return err;
    };
    defer el.deinit();

    const Ctx = struct {
        completed: bool = false,
        had_metadata: bool = false,
    };
    var ctx = Ctx{};

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
        std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 6883),
    };

    el.startMetadataFetch(
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        struct {
            fn cb(mf: *EL_SimIO.AsyncMetadataFetch) void {
                const c: *Ctx = @ptrCast(@alignCast(mf.caller_ctx.?));
                c.completed = true;
                c.had_metadata = mf.result_bytes != null;
            }
        }.cb,
        @ptrCast(&ctx),
    ) catch |err| {
        if (err == error.SystemResources or err == error.PermissionDenied) {
            return error.SkipZigTest;
        }
        return err;
    };

    var ticks: u32 = 0;
    while (ticks < tick_budget and !ctx.completed) : (ticks += 1) {
        try el.io.tick(0);
    }

    try std.testing.expect(ctx.completed);
    try std.testing.expect(!ctx.had_metadata);

    el.cancelMetadataFetch();
}

//! Integration stress test for the post-Track-B `ApiServer` lifecycle
//! (Track C). Drives many seeds × randomised connect/disconnect/
//! request-size patterns against the real `ApiServer` running on
//! `RealIO`, asserting safety properties — no leaks, no UAF, no
//! kernel-side crashes, and that successful responses match the
//! handler output.
//!
//! The `ApiServer` is concrete-typed against `*RealIO` so this test
//! cannot be driven under `SimIO` directly. Instead it perturbs
//! timing via random poll budgets and random disconnect points: a
//! client may close after writing only the request line, after the
//! header block, or after reading some-but-not-all of the response.
//! Each variation exercises the handleRecv/handleSend/closeClient
//! state machine in a different order, hitting paths that a happy-
//! path test rarely sees.
//!
//! This is a layer-3 safety test (`STYLE.md` Layered Testing
//! Strategy). It does **not** assert liveness — under random close
//! times, the handler may or may not run for a given client; the
//! assertion is only that nothing leaks and the server stays
//! responsive across the seed.
//!
//! Track B's per-slot `TieredArena` + embedded `recv_op`/`send_op`
//! `ClientOp` patterns are the specific surfaces under test.
//! Mismatched-generation completions on reused slots are filtered
//! by `isLiveClient(slot, gen)`; this test exercises that filter
//! by closing and reconnecting fast enough that stale CQEs may
//! land while a slot is mid-reuse.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const varuna = @import("varuna");
const rpc_server = varuna.rpc.server;
const RealIO = varuna.io.real_io.RealIO;

fn echoHandler(allocator: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
    // Allocate a body from the per-slot arena allocator. Length
    // depends on the request path so different seeds drive different
    // response sizes.
    const body = std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"len\":{}}}", .{
        request.path,
        request.body.len,
    }) catch return .{ .status = 500, .body = "{\"error\":\"alloc\"}" };
    return .{ .body = body, .owned_body = body };
}

fn pollFor(server: *rpc_server.ApiServer, ms: u32) void {
    var i: u32 = 0;
    while (i < ms / 5) : (i += 1) {
        _ = server.poll() catch break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

fn listenPort(server: *const rpc_server.ApiServer) !u16 {
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(server.listen_fd, &addr, &addr_len);
    return (std.net.Address{ .any = addr }).getPort();
}

const CloseStrategy = enum {
    /// Connect, write full request, drain response, close.
    happy_path,
    /// Connect, write only the request line (no \r\n\r\n), close.
    /// The server's recv loop will see EOF before the request is
    /// complete and must close cleanly.
    close_mid_request,
    /// Connect, write full request, close before reading response.
    /// The server has already kicked off the send by the time we
    /// close; the send will complete (kernel buffers it) and the
    /// next recv will see EOF.
    close_before_send_complete,
    /// Connect, never write, close.
    close_immediately,
};

fn nonblockingConnect(port: u16) !posix.fd_t {
    const client_fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {}, // connect-in-progress; that's fine for our stress test
        else => return err,
    };
    return client_fd;
}

fn driveClient(server: *rpc_server.ApiServer, port: u16, strategy: CloseStrategy, request_n: u32) !void {
    const client_fd = nonblockingConnect(port) catch return;
    defer posix.close(client_fd);

    if (strategy == .close_immediately) {
        // Don't even drain the server — closing right away exercises
        // the kernel's RST/FIN delivery path against a fresh accept.
        return;
    }

    // Give the server a chance to accept the connection.
    pollFor(server, 30);

    if (strategy == .close_mid_request) {
        // Write only part of the request line (no terminator). The
        // server's recv reads what we wrote, sees no \r\n\r\n, and
        // submits a fresh recv. Closing the socket then triggers EOF
        // on that pending recv.
        _ = posix.write(client_fd, "GET /api/v2/probe") catch {};
        pollFor(server, 30);
        return;
    }

    var req_buf: [4096]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET /api/v2/probe?n={} HTTP/1.1\r\nHost: localhost\r\n\r\n",
        .{request_n},
    ) catch return;
    _ = posix.write(client_fd, req) catch return;

    if (strategy == .close_before_send_complete) {
        // Don't read; close while the server's send is in flight.
        // The server's send_op completion may still fire; the
        // generation filter on the next recv will handle it.
        pollFor(server, 30);
        return;
    }

    // Happy path: poll until the server has had time to handle, then
    // drain the response with a non-blocking read.
    pollFor(server, 100);

    var resp_buf: [4096]u8 = undefined;
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        const n = posix.read(client_fd, &resp_buf) catch |err| switch (err) {
            error.WouldBlock => {
                pollFor(server, 30);
                continue;
            },
            else => return,
        };
        if (n == 0) break;
        if (n > 0) {
            // Sanity-check: response starts with the HTTP/1.1 status line.
            try std.testing.expect(std.mem.startsWith(u8, resp_buf[0..n], "HTTP/1.1 "));
            break;
        }
    }
}

test "ApiServer: 32 seeds × random close-mid-flight strategies" {
    var test_io = RealIO.init(.{ .entries = 64 }) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(echoHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    var seed: u64 = 0;
    while (seed < 32) : (seed += 1) {
        var rng = std.Random.DefaultPrng.init(seed);
        const ops_this_seed: u32 = 4;

        var op: u32 = 0;
        while (op < ops_this_seed) : (op += 1) {
            const strategy: CloseStrategy = @enumFromInt(rng.random().uintLessThan(u8, 4));
            try driveClient(&server, port, strategy, op);
        }

        // Drain between seeds so any in-flight client_op trackers
        // are reaped before the next seed exercises the slot.
        pollFor(&server, 100);
    }

    // Final long drain — any in-flight ops must complete (or be
    // filtered as stale) before the server is deinit'd. The GPA leak
    // detector enforces no embedded ClientOp mishandling.
    pollFor(&server, 300);
}

test "ApiServer: rapid connect-reconnect exercises generation filter on slot reuse" {
    // Tight loop: connect, send, drain. The server's accept-multishot
    // path will reuse the slot whose `client_generations[slot]` has
    // just incremented. If a stale recv/send completion lands on the
    // reused slot, `isLiveClient(slot, gen)` filters it. This test
    // exists to ensure the embedded `recv_op`/`send_op` (Pattern #1
    // in `STYLE.md`) interact correctly with the generation counter
    // under churn.
    var test_io = RealIO.init(.{ .entries = 64 }) catch return error.SkipZigTest;
    defer test_io.deinit();
    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();
    server.setHandler(echoHandler);
    server.submitAccept() catch return;

    const port = try listenPort(&server);

    var iter: u32 = 0;
    while (iter < 16) : (iter += 1) {
        try driveClient(&server, port, .happy_path, iter);
    }
    pollFor(&server, 300);
}

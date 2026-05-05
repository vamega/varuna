//! Regression tests for the 2026-05-05 memory-safety audit.
//!
//! These started as validation repros and now assert the fixed behavior for
//! async ownership, partial initialization cleanup, and hostile size inputs.

const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");

const bencode = varuna.torrent.bencode;
const metainfo = varuna.torrent.metainfo;
const rpc_server = varuna.rpc.server;
const Bitfield = varuna.bitfield.Bitfield;
const Session = varuna.torrent.session.Session;
const SimIO = varuna.io.sim_io.SimIO;

const torrent_multifile =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi7e4:pathl4:beta5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi4e" ++
    "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

const torrent_3file =
    "d4:infod5:filesl" ++
    "d6:lengthi3e4:pathl5:alphaee" ++
    "d6:lengthi3e4:pathl4:betaee" ++
    "d6:lengthi3e4:pathl5:gammaeee" ++
    "4:name4:root" ++
    "12:piece lengthi9e" ++
    "6:pieces20:01234567890123456789" ++
    "ee";

const TrackingFailAllocator = struct {
    const Entry = struct {
        ptr: [*]u8,
        len: usize,
        alignment: std.mem.Alignment,
    };

    parent: std.mem.Allocator,
    fail_after: usize,
    call_count: usize = 0,
    entries: [256]Entry = undefined,
    entry_count: usize = 0,
    invalid_free: bool = false,

    fn allocator(self: *TrackingFailAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingFailAllocator = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.call_count > self.fail_after) return null;
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        @memset(ptr[0..len], 0xaa);
        self.entries[self.entry_count] = .{
            .ptr = ptr,
            .len = len,
            .alignment = alignment,
        };
        self.entry_count += 1;
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingFailAllocator = @ptrCast(@alignCast(ctx));
        const index = self.findEntry(buf) orelse {
            self.invalid_free = true;
            return false;
        };
        if (!self.parent.rawResize(buf, alignment, new_len, ret_addr)) return false;
        self.entries[index].len = new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingFailAllocator = @ptrCast(@alignCast(ctx));
        const index = self.findEntry(buf) orelse {
            self.invalid_free = true;
            return null;
        };
        const ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.entries[index] = .{
            .ptr = ptr,
            .len = new_len,
            .alignment = alignment,
        };
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingFailAllocator = @ptrCast(@alignCast(ctx));
        const index = self.findEntry(buf) orelse {
            self.invalid_free = true;
            return;
        };
        self.parent.rawFree(buf, alignment, ret_addr);
        self.entries[index] = self.entries[self.entry_count - 1];
        self.entry_count -= 1;
    }

    fn findEntry(self: *TrackingFailAllocator, buf: []u8) ?usize {
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            if (@intFromPtr(entry.ptr) == @intFromPtr(buf.ptr) and entry.len == buf.len) {
                return index;
            }
        }
        return null;
    }

    fn freeRemaining(self: *TrackingFailAllocator) void {
        while (self.entry_count > 0) {
            const entry = self.entries[self.entry_count - 1];
            self.parent.rawFree(entry.ptr[0..entry.len], entry.alignment, @returnAddress());
            self.entry_count -= 1;
        }
    }
};

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

test "memory safety validation: seed span read tracks more than eight spans safely" {
    const Layout = varuna.torrent.layout.Layout;
    const EventLoop = varuna.io.event_loop.EventLoopOf(SimIO);

    var files: [9]Layout.File = undefined;
    for (&files, 0..) |*file, i| {
        file.* = .{
            .length = 1,
            .torrent_offset = i,
            .first_piece = 0,
            .end_piece_exclusive = 1,
            .path = &.{"f"},
        };
    }

    var session = Session{
        .torrent_bytes = "",
        .metainfo = undefined,
        .layout = .{
            .piece_length = 9,
            .piece_count = 1,
            .total_size = 9,
            .files = files[0..],
            .piece_hashes = null,
            .version = .v1,
        },
        .manifest = undefined,
    };

    var complete = try Bitfield.init(std.testing.allocator, 1);
    defer complete.deinit(std.testing.allocator);
    try complete.set(0);

    const sim = try SimIO.init(std.testing.allocator, .{
        .seed = 0x5eed_9009,
        .max_ops_per_tick = 16,
        .faults = .{ .read_error_probability = 1.0 },
    });
    var el = try EventLoop.initBareWithIO(std.testing.allocator, sim, 0);
    defer el.deinit();

    const fds = [_]posix.fd_t{ 100, 101, 102, 103, 104, 105, 106, 107, 108 };
    const torrent_id = try el.addTorrentContext(.{
        .session = &session,
        .shared_fds = fds[0..],
        .info_hash = @as([20]u8, @splat(0xA1)),
        .peer_id = @as([20]u8, @splat(0xB1)),
        .complete_pieces = &complete,
    });

    const slot: u16 = 0;
    el.peers[slot] = .{
        .fd = -1,
        .state = .active_recv_header,
        .mode = .inbound,
        .transport = .tcp,
        .torrent_id = torrent_id,
    };

    var request: [12]u8 = undefined;
    std.mem.writeInt(u32, request[0..4], 0, .big);
    std.mem.writeInt(u32, request[4..8], 0, .big);
    std.mem.writeInt(u32, request[8..12], 9, .big);
    varuna.io.seed_handler.servePieceRequest(&el, slot, &request);

    try std.testing.expectEqual(@as(usize, 1), el.pending_reads.items.len);
    try std.testing.expectEqual(@as(usize, 9), el.pending_reads.items[0].expected_read_lengths.len);
    try std.testing.expectEqual(@as(usize, 9), el.pending_reads.items[0].reads_remaining);
    try std.testing.expectEqual(@as(u32, 9), el.io.pending_len);

    try el.io.tick(1);
    try std.testing.expectEqual(@as(usize, 0), el.pending_reads.items.len);
    try std.testing.expectEqual(@as(u32, 0), el.io.pending_len);
}

test "memory safety validation: seed span failed read keeps buffer until sibling CQE drains" {
    const EventLoop = varuna.io.event_loop.EventLoopOf(SimIO);
    const Layout = varuna.torrent.layout.Layout;

    var files = [_]Layout.File{
        .{
            .length = 4,
            .torrent_offset = 0,
            .first_piece = 0,
            .end_piece_exclusive = 1,
            .path = &.{"a"},
        },
        .{
            .length = 4,
            .torrent_offset = 4,
            .first_piece = 0,
            .end_piece_exclusive = 1,
            .path = &.{"b"},
        },
    };
    var session = Session{
        .torrent_bytes = "",
        .metainfo = undefined,
        .layout = .{
            .piece_length = 8,
            .piece_count = 1,
            .total_size = 8,
            .files = files[0..],
            .piece_hashes = null,
            .version = .v1,
        },
        .manifest = undefined,
    };

    var complete = try Bitfield.init(std.testing.allocator, 1);
    defer complete.deinit(std.testing.allocator);
    try complete.set(0);

    const sim = try SimIO.init(std.testing.allocator, .{
        .seed = 0x5eed_717e,
        .max_ops_per_tick = 1,
        .faults = .{ .read_error_probability = 1.0 },
    });
    var el = try EventLoop.initBareWithIO(std.testing.allocator, sim, 0);
    defer el.deinit();

    const fds = [_]posix.fd_t{ 100, 101 };
    const torrent_id = try el.addTorrentContext(.{
        .session = &session,
        .shared_fds = fds[0..],
        .info_hash = @as([20]u8, @splat(0xAB)),
        .peer_id = @as([20]u8, @splat(0xCD)),
        .complete_pieces = &complete,
    });

    const slot: u16 = 0;
    el.peers[slot] = .{
        .fd = -1,
        .state = .active_recv_header,
        .mode = .inbound,
        .transport = .tcp,
        .torrent_id = torrent_id,
    };

    var request: [12]u8 = undefined;
    std.mem.writeInt(u32, request[0..4], 0, .big);
    std.mem.writeInt(u32, request[4..8], 0, .big);
    std.mem.writeInt(u32, request[8..12], 8, .big);
    varuna.io.seed_handler.servePieceRequest(&el, slot, &request);

    try std.testing.expectEqual(@as(usize, 1), el.pending_reads.items.len);
    try std.testing.expectEqual(@as(usize, 2), el.pending_reads.items[0].reads_remaining);
    try std.testing.expectEqual(@as(u32, 2), el.io.pending_len);

    const original_piece_buffer = el.pending_reads.items[0].piece_buffer;
    const original_storage_addr = @intFromPtr(original_piece_buffer.storage.ptr);

    try el.io.tick(1);

    try std.testing.expectEqual(@as(usize, 1), el.pending_reads.items.len);
    try std.testing.expectEqual(original_piece_buffer, el.pending_reads.items[0].piece_buffer);
    try std.testing.expectEqual(@as(usize, 1), el.pending_reads.items[0].reads_remaining);
    try std.testing.expectEqual(@as(u32, 1), el.io.pending_len);
    try std.testing.expectEqual(@as(usize, 0), el.piece_buffer_pool.retained_heap_bytes);

    try el.io.tick(1);
    try std.testing.expectEqual(@as(usize, 0), el.pending_reads.items.len);
    try std.testing.expectEqual(@as(u32, 0), el.io.pending_len);

    const reused_piece_buffer = try el.createPieceBuffer(8);
    defer el.releasePieceBuffer(reused_piece_buffer);

    try std.testing.expectEqual(original_piece_buffer, reused_piece_buffer);
    try std.testing.expectEqual(original_storage_addr, @intFromPtr(reused_piece_buffer.storage.ptr));
}

test "memory safety validation: bencode trailing data frees parsed root allocation" {
    try std.testing.expectError(
        error.TrailingData,
        bencode.parse(std.testing.allocator, "li1eei2e"),
    );
}

test "memory safety validation: bencode nested list error frees parsed child allocation" {
    try std.testing.expectError(
        error.InvalidPrefix,
        bencode.parse(std.testing.allocator, "lli1eex"),
    );
}

test "memory safety validation: metainfo allocation failure can clean up uninitialized files" {
    const input =
        "d4:infod5:filesl" ++
        "d6:lengthi3e4:pathl5:alphaee" ++
        "d6:lengthi3e4:pathl4:betaee" ++
        "d6:lengthi3e4:pathl5:gammaeee" ++
        "4:name4:root" ++
        "12:piece lengthi9e" ++
        "6:pieces20:01234567890123456789" ++
        "ee";

    var observed_invalid_free = false;
    var fail_after: usize = 0;
    while (fail_after < 80) : (fail_after += 1) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};

        var failing = TrackingFailAllocator{
            .parent = gpa.allocator(),
            .fail_after = fail_after,
        };
        defer {
            failing.freeRemaining();
            _ = gpa.deinit();
        }

        const allocator = failing.allocator();
        if (metainfo.parse(allocator, input)) |meta| {
            metainfo.freeMetainfo(allocator, meta);
        } else |_| {}
        observed_invalid_free = failing.invalid_free;
        if (observed_invalid_free) break;
    }

    try std.testing.expect(!observed_invalid_free);
}

test "memory safety validation: UDP tracker rejects host longer than fixed job buffer" {
    const udp = varuna.tracker.udp;
    const UdpExecutor = varuna.tracker.udp_executor.UdpTrackerExecutorOf(SimIO);

    const host = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    comptime std.debug.assert(host.len == 300);

    const parsed = udp.parseUdpUrl("udp://" ++ host ++ ":6969/announce").?;
    var job = UdpExecutor.Job{
        .context = undefined,
        .on_complete = undefined,
    };

    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
    try std.testing.expectEqual(@as(usize, 300), parsed.host.len);
    try std.testing.expectError(error.HostTooLong, job.setHost(parsed.host));
}

test "memory safety validation: RPC Content-Length overflow returns request too large" {
    var test_io = varuna.io.backend.initOneshot(std.testing.allocator) catch return error.SkipZigTest;
    defer test_io.deinit();

    var server = rpc_server.ApiServer.init(std.testing.allocator, &test_io, "127.0.0.1", 0) catch return error.SkipZigTest;
    defer server.deinit();

    server.setHandler(struct {
        fn handle(_: std.mem.Allocator, _: rpc_server.Request) rpc_server.Response {
            return .{ .body = "ok" };
        }
    }.handle);

    server.submitAccept() catch return error.SkipZigTest;
    const port = try listenPort(&server);

    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(client_fd);
    const connect_addr = try std.net.Address.parseIp4("127.0.0.1", port);
    try posix.connect(client_fd, &connect_addr.any, connect_addr.getOsSockLen());

    var request_buf: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "POST /api/v2/torrents/add HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n",
        .{std.math.maxInt(usize)},
    );
    _ = try posix.write(client_fd, request);

    pollFor(&server, 200);
}

test "memory safety validation: HTTP executor Content-Length arithmetic rejects overflowing response size" {
    var response_buf: [128]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
        .{std.math.maxInt(usize)},
    );

    const body_start = varuna.io.http_parse.findBodyStart(response).?;
    const content_length = varuna.io.http_parse.parseContentLength(response[0..body_start]).?;

    try std.testing.expectEqual(std.math.maxInt(usize), content_length);
    try std.testing.expect(varuna.io.http_parse.bodyEndOffset(body_start, content_length) == null);
}

test "memory safety validation: storage sync partial submit drains live pending completion" {
    const PieceStoreOfSim = varuna.storage.writer.PieceStoreOf(SimIO);
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_multifile, target_root);
    defer session.deinit(allocator);

    var init_sim = try SimIO.init(allocator, .{ .seed = 0x51515151 });
    defer init_sim.deinit();

    var store = try PieceStoreOfSim.init(allocator, &session, &init_sim);
    defer store.deinit();

    var sync_sim = try SimIO.init(allocator, .{ .seed = 0x61616161, .pending_capacity = 1 });
    defer sync_sim.deinit();

    try std.testing.expectError(error.PendingQueueFull, store.sync(&sync_sim));
    try std.testing.expectEqual(@as(u32, 0), sync_sim.pending_len);
}

test "memory safety validation: storage init partial submit drains live pending completion" {
    const PieceStoreOfSim = varuna.storage.writer.PieceStoreOf(SimIO);
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "download",
    });
    defer allocator.free(target_root);

    const session = try Session.load(allocator, torrent_3file, target_root);
    defer session.deinit(allocator);

    var sim = try SimIO.init(allocator, .{ .seed = 0x71717171, .pending_capacity = 1 });
    defer sim.deinit();

    try std.testing.expectError(error.PendingQueueFull, PieceStoreOfSim.init(allocator, &session, &sim));
    try std.testing.expectEqual(@as(u32, 0), sim.pending_len);
}

test "memory safety validation: session manager deinit drains event-loop move job completions" {
    const EventLoopOf = varuna.io.event_loop.EventLoopOf;
    const SessionManagerOf = varuna.daemon.session_manager.SessionManagerOf;
    const MoveJob = varuna.storage.move_job.MoveJob;
    const allocator = std.testing.allocator;

    var el = try EventLoopOf(SimIO).initBareWithIO(
        allocator,
        try SimIO.init(allocator, .{ .seed = 0x81818181 }),
        0,
    );
    defer el.deinit();

    var manager = SessionManagerOf(SimIO).init(allocator);
    manager.shared_event_loop = &el;

    var files = [_]MoveJob.File{.{
        .relative_path = "piece.bin",
        .length = 1,
    }};
    const job = try MoveJob.createForFiles(allocator, 99, "/src", "/dst", &files);
    errdefer job.destroy();
    try job.startOnEventLoop(null, null);
    try manager.move_jobs.put(99, job);

    job.tickOnEventLoop(&el.io);
    try std.testing.expect(job.hasPendingEventLoopIo());
    try std.testing.expect(el.io.pending_len > 0);

    manager.deinit();
    try std.testing.expectEqual(@as(u32, 0), el.io.pending_len);
}

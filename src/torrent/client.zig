const std = @import("std");
const peer_wire = @import("../net/peer_wire.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const session_mod = @import("session.zig");
const Ring = @import("../io/ring.zig").Ring;

pub const DownloadOptions = struct {
    peer_id: [20]u8,
    port: u16 = 6881,
    max_peers: u32 = 5,
    status_writer: ?*std.Io.Writer = null,
};

pub const SeedOptions = struct {
    peer_id: [20]u8,
    port: u16 = 6881,
    max_peers: u32 = 5,
    status_writer: ?*std.Io.Writer = null,
};

pub const DownloadResult = struct {
    info_hash: [20]u8,
    peer: ?tracker.announce.Peer,
    piece_count: u32,
    bytes_downloaded: u64,
    bytes_reused: u64,
    bytes_complete: u64,
};

pub const SeedResult = struct {
    info_hash: [20]u8,
    piece_count: u32,
    bytes_seeded: u64,
    bytes_complete: u64,
    peer: ?std.net.Address,
};

pub fn seed(
    allocator: std.mem.Allocator,
    torrent_bytes: []const u8,
    target_root: []const u8,
    options: SeedOptions,
) !SeedResult {
    var ring = try Ring.init(16);
    defer ring.deinit();

    const session = try session_mod.Session.load(allocator, torrent_bytes, target_root);
    defer session.deinit(allocator);

    var store = try storage.writer.PieceStore.init(allocator, &session, &ring);
    defer store.deinit();

    var recheck = try storage.verify.recheckExistingData(allocator, &session, &store);
    defer recheck.deinit(allocator);

    const bytes_left = session.totalSize() - recheck.bytes_complete;
    try logStatus(
        options.status_writer,
        "seed torrent: {s}, pieces={}, complete={} bytes, left={} bytes\n",
        .{ session.metainfo.name, session.pieceCount(), recheck.bytes_complete, bytes_left },
    );

    if (bytes_left != 0) {
        return error.IncompleteSeedData;
    }

    var server = try std.net.Address.initIp4(.{ 0, 0, 0, 0 }, options.port).listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    try logStatus(options.status_writer, "listening for peers on port {}\n", .{options.port});

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const announce_url = session.metainfo.announce orelse return error.MissingAnnounceUrl;
    const announce_response = try tracker.announce.fetch(allocator, &http_client, .{
        .announce_url = announce_url,
        .info_hash = session.metainfo.info_hash,
        .peer_id = options.peer_id,
        .port = options.port,
        .left = 0,
    });
    defer tracker.announce.freeResponse(allocator, announce_response);

    try logStatus(options.status_writer, "seed announce accepted, peers={}\n", .{announce_response.peers.len});

    const transport = @import("../net/transport.zig");
    const seed_worker_mod = @import("seed_worker.zig");

    var workers = std.ArrayList(seed_worker_mod.SeedWorkerContext).empty;
    defer workers.deinit(allocator);
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);

    // Accept loop: accept up to max_peers connections
    var accepted: u32 = 0;
    while (accepted < options.max_peers) {
        const accept_result = transport.tcpAccept(&ring, server.stream.handle) catch break;

        try logStatus(options.status_writer, "incoming peer: {f}\n", .{accept_result.address});

        const worker_index = workers.items.len;
        try workers.append(allocator, .{
            .allocator = allocator,
            .session = &session,
            .complete_pieces = &recheck.complete_pieces,
            .fd = accept_result.fd,
            .peer_id = options.peer_id,
        });

        const thread = std.Thread.spawn(
            .{},
            seed_worker_mod.SeedWorkerContext.run,
            .{&workers.items[worker_index]},
        ) catch {
            std.posix.close(accept_result.fd);
            continue;
        };
        try threads.append(allocator, thread);
        accepted += 1;
    }

    // Join all seed workers
    for (threads.items) |thread| {
        thread.join();
    }

    var total_seeded: u64 = 0;
    for (workers.items) |worker| {
        total_seeded += worker.bytes_seeded;
    }

    sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .stopped, 0);
    try logStatus(options.status_writer, "seed complete: {s}\n", .{session.metainfo.name});

    return .{
        .info_hash = session.metainfo.info_hash,
        .piece_count = session.pieceCount(),
        .bytes_seeded = total_seeded,
        .bytes_complete = recheck.bytes_complete,
        .peer = null,
    };
}

pub fn download(
    allocator: std.mem.Allocator,
    torrent_bytes: []const u8,
    target_root: []const u8,
    options: DownloadOptions,
) !DownloadResult {
    var ring = try Ring.init(16);
    defer ring.deinit();

    const session = try session_mod.Session.load(allocator, torrent_bytes, target_root);
    defer session.deinit(allocator);

    var store = try storage.writer.PieceStore.init(allocator, &session, &ring);
    defer store.deinit();

    var recheck = try storage.verify.recheckExistingData(allocator, &session, &store);
    defer recheck.deinit(allocator);

    const bytes_left = session.totalSize() - recheck.bytes_complete;
    try logStatus(
        options.status_writer,
        "torrent: {s}, pieces={}, reused={} bytes, left={} bytes\n",
        .{ session.metainfo.name, session.pieceCount(), recheck.bytes_complete, bytes_left },
    );

    if (bytes_left == 0) {
        try logStatus(options.status_writer, "already complete: {s}\n", .{session.metainfo.name});
        return .{
            .info_hash = session.metainfo.info_hash,
            .peer = null,
            .piece_count = session.pieceCount(),
            .bytes_downloaded = 0,
            .bytes_reused = recheck.bytes_complete,
            .bytes_complete = session.totalSize(),
        };
    }

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    const announce_url = session.metainfo.announce orelse return error.MissingAnnounceUrl;
    const announce_response = try tracker.announce.fetch(allocator, &http_client, .{
        .announce_url = announce_url,
        .info_hash = session.metainfo.info_hash,
        .peer_id = options.peer_id,
        .port = options.port,
        .left = bytes_left,
    });
    defer tracker.announce.freeResponse(allocator, announce_response);

    if (announce_response.peers.len == 0) {
        return error.NoPeersAvailable;
    }
    try logStatus(options.status_writer, "peers={}\n", .{announce_response.peers.len});

    const peer_worker = @import("peer_worker.zig");
    const PieceTracker = @import("piece_tracker.zig").PieceTracker;

    var piece_tracker = try PieceTracker.init(
        allocator,
        session.pieceCount(),
        session.layout.piece_length,
        session.totalSize(),
        &recheck.complete_pieces,
        recheck.bytes_complete,
    );
    defer piece_tracker.deinit(allocator);

    // Track connected peer addresses to avoid duplicates across re-announces
    var known_peers = std.ArrayList(std.net.Address).empty;
    defer known_peers.deinit(allocator);

    var workers = std.ArrayList(peer_worker.WorkerContext).empty;
    defer workers.deinit(allocator);
    var threads = std.ArrayList(std.Thread).empty;
    defer threads.deinit(allocator);

    const announce_interval: u32 = announce_response.interval;

    // Spawn initial workers
    try spawnWorkersForPeers(
        allocator,
        &workers,
        &threads,
        &known_peers,
        announce_response.peers,
        options,
        &session,
        &piece_tracker,
    );

    if (threads.items.len == 0) {
        sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .stopped, 0);
        return error.NoReachablePeers;
    }

    // Progress + re-announce loop
    var last_announce = std.time.milliTimestamp();
    var last_reported_count: u32 = piece_tracker.completedCount();

    while (!piece_tracker.isComplete()) {
        std.Thread.sleep(2 * std.time.ns_per_s);

        if (piece_tracker.isComplete()) break;

        // Report progress if pieces changed
        const current_count = piece_tracker.completedCount();
        if (current_count != last_reported_count) {
            const pct = (current_count * 100) / session.pieceCount();
            try logStatus(
                options.status_writer,
                "progress: {}/{} pieces ({}%), peers={}\n",
                .{ current_count, session.pieceCount(), pct, known_peers.items.len },
            );
            last_reported_count = current_count;
        }

        // Re-announce on interval
        const now = std.time.milliTimestamp();
        const elapsed_ms = now - last_announce;
        if (elapsed_ms >= @as(i64, announce_interval) * 1000 and known_peers.items.len < options.max_peers) {
            last_announce = now;
            const re_response = tracker.announce.fetch(allocator, &http_client, .{
                .announce_url = announce_url,
                .info_hash = session.metainfo.info_hash,
                .peer_id = options.peer_id,
                .port = options.port,
                .left = piece_tracker.bytesRemaining(),
                .event = null,
            }) catch continue;
            defer tracker.announce.freeResponse(allocator, re_response);

            try spawnWorkersForPeers(
                allocator,
                &workers,
                &threads,
                &known_peers,
                re_response.peers,
                options,
                &session,
                &piece_tracker,
            );
        }
    }

    // Join all workers
    for (threads.items) |thread| {
        thread.join();
    }

    // Aggregate results
    var total_downloaded: u64 = 0;
    for (workers.items) |worker| {
        total_downloaded += worker.bytes_downloaded;
    }

    // Sync files
    store.sync() catch {};

    if (piece_tracker.isComplete()) {
        sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .completed, total_downloaded);
        try logStatus(options.status_writer, "complete: {s}\n", .{session.metainfo.name});
        return .{
            .info_hash = session.metainfo.info_hash,
            .peer = if (known_peers.items.len > 0) .{ .address = known_peers.items[0] } else null,
            .piece_count = session.pieceCount(),
            .bytes_downloaded = total_downloaded,
            .bytes_reused = recheck.bytes_complete,
            .bytes_complete = session.totalSize(),
        };
    }

    sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .stopped, 0);
    return error.NoReachablePeers;
}

fn spawnWorkersForPeers(
    allocator: std.mem.Allocator,
    workers: *std.ArrayList(@import("peer_worker.zig").WorkerContext),
    threads: *std.ArrayList(std.Thread),
    known_peers: *std.ArrayList(std.net.Address),
    peers: []const tracker.announce.Peer,
    options: DownloadOptions,
    session: *const session_mod.Session,
    piece_tracker: *@import("piece_tracker.zig").PieceTracker,
) !void {
    for (peers) |peer| {
        if (isSelfPeer(peer.address, options.port)) continue;
        if (known_peers.items.len >= options.max_peers) break;

        // Check if we already know this peer
        var already_known = false;
        for (known_peers.items) |known| {
            if (addressesEqual(known, peer.address)) {
                already_known = true;
                break;
            }
        }
        if (already_known) continue;

        try known_peers.append(allocator, peer.address);

        const worker_index = workers.items.len;
        try workers.append(allocator, .{
            .allocator = allocator,
            .session = session,
            .tracker = piece_tracker,
            .peer_address = peer.address,
            .peer_id = options.peer_id,
        });

        const thread = std.Thread.spawn(
            .{},
            @import("peer_worker.zig").WorkerContext.run,
            .{&workers.items[worker_index]},
        ) catch continue;
        try threads.append(allocator, thread);
    }
}

fn sendTrackerEvent(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    announce_url: []const u8,
    session: *const session_mod.Session,
    options: anytype,
    event: tracker.announce.Request.Event,
    downloaded: u64,
) void {
    const left: u64 = if (event == .completed) 0 else session.totalSize();
    const response = tracker.announce.fetch(allocator, http_client, .{
        .announce_url = announce_url,
        .info_hash = session.metainfo.info_hash,
        .peer_id = options.peer_id,
        .port = options.port,
        .downloaded = downloaded,
        .left = left,
        .event = event,
    }) catch return;
    tracker.announce.freeResponse(allocator, response);
}

fn addressesEqual(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    if (a.getPort() != b.getPort()) return false;
    return switch (a.any.family) {
        std.posix.AF.INET => a.in.sa.addr == b.in.sa.addr,
        std.posix.AF.INET6 => std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr),
        else => false,
    };
}

fn isSelfPeer(address: std.net.Address, own_port: u16) bool {
    if (address.getPort() != own_port) return false;
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const ip = address.in.sa.addr;
            const localhost = comptime std.mem.nativeToBig(u32, 0x7f000001);
            break :blk (ip == localhost) or (ip == 0);
        },
        else => false,
    };
}

fn logStatus(writer: ?*std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    if (writer) |output| {
        try output.print(format, args);
        try output.flush();
    }
}

const FakeTrackerContext = struct {
    server: std.net.Server,
    response_body: []const u8,
    expected_requests: u32 = 1,

    fn run(self: *FakeTrackerContext) void {
        self.handleRequests() catch |err| @panic(@errorName(err));
    }

    fn handleRequests(self: *FakeTrackerContext) !void {
        defer self.server.deinit();

        var served: u32 = 0;
        while (served < self.expected_requests) : (served += 1) {
            const connection = try self.server.accept();
            defer connection.stream.close();

            var request_buffer: [4096]u8 = undefined;
            const request = try readHttpHead(connection.stream, &request_buffer);
            try std.testing.expect(std.mem.startsWith(u8, request, "GET /announce?"));
            try std.testing.expect(std.mem.indexOf(u8, request, "compact=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, request, "peer_id=") != null);
            try std.testing.expect(std.mem.indexOf(u8, request, "info_hash=") != null);
            try writeHttpOk(connection.stream, self.response_body);
        }
    }
};

const SwarmTrackerContext = struct {
    server: std.net.Server,
    download_response_body: []const u8,
    expected_download_left: u64,
    expected_requests: u32 = 4,
    requests_served: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn run(self: *SwarmTrackerContext) void {
        self.handleMany() catch |err| @panic(@errorName(err));
    }

    fn handleMany(self: *SwarmTrackerContext) !void {
        defer self.server.deinit();

        var request_index: u32 = 0;
        while (request_index < self.expected_requests) : (request_index += 1) {
            const connection = try self.server.accept();
            defer connection.stream.close();

            var request_buffer: [4096]u8 = undefined;
            const request = try readHttpHead(connection.stream, &request_buffer);
            try std.testing.expect(std.mem.startsWith(u8, request, "GET /announce?"));

            const response_body = if (std.mem.indexOf(u8, request, "event=started") != null and
                std.mem.indexOf(u8, request, "left=0") != null)
            blk: {
                break :blk "d8:intervali30e5:peers0:e";
            } else if (std.mem.indexOf(u8, request, "event=started") != null) blk: {
                break :blk self.download_response_body;
            } else blk: {
                break :blk "d8:intervali30e5:peers0:e";
            };

            _ = self.requests_served.fetchAdd(1, .seq_cst);
            try writeHttpOk(connection.stream, response_body);
        }
    }
};

const FakePeerContext = struct {
    server: std.net.Server,
    info_hash: [20]u8,
    peer_id: [20]u8,
    payload: []const u8,
    piece_length: u32,
    expected_requests: u32,

    fn run(self: *FakePeerContext) void {
        self.handleOne() catch |err| @panic(@errorName(err));
    }

    fn handleOne(self: *FakePeerContext) !void {
        defer self.server.deinit();

        var ring = try Ring.init(16);
        defer ring.deinit();

        const connection = try self.server.accept();
        const peer_fd = connection.stream.handle;
        defer connection.stream.close();

        const handshake = try peer_wire.readHandshake(&ring, peer_fd);
        try std.testing.expectEqualDeep(self.info_hash, handshake.info_hash);

        try peer_wire.writeHandshake(&ring, peer_fd, self.info_hash, self.peer_id);

        const interested = try peer_wire.readMessageAlloc(std.testing.allocator, &ring, peer_fd);
        defer peer_wire.freeMessage(std.testing.allocator, interested);
        try std.testing.expectEqual(peer_wire.InboundMessage.interested, interested);

        const bitfield = [_]u8{0b1110_0000};
        try peer_wire.writeBitfield(&ring, peer_fd, &bitfield);
        try peer_wire.writeUnchoke(&ring, peer_fd);

        var requests_served: u32 = 0;
        while (requests_served < self.expected_requests) {
            const message = try peer_wire.readMessageAlloc(std.testing.allocator, &ring, peer_fd);
            defer peer_wire.freeMessage(std.testing.allocator, message);

            switch (message) {
                .request => |request| {
                    const piece_start: usize = @intCast(request.piece_index * self.piece_length);
                    const piece_end = @min(piece_start + @as(usize, self.piece_length), self.payload.len);
                    const piece_data = self.payload[piece_start..piece_end];
                    const block_start: usize = @intCast(request.block_offset);
                    const block_end = block_start + @as(usize, @intCast(request.length));
                    try std.testing.expect(block_end <= piece_data.len);

                    try peer_wire.writePiece(
                        &ring,
                        peer_fd,
                        request.piece_index,
                        request.block_offset,
                        piece_data[block_start..block_end],
                    );
                    requests_served += 1;
                },
                else => return error.UnexpectedPeerMessage,
            }
        }
    }
};

const SeedThreadContext = struct {
    torrent_bytes: []const u8,
    target_root: []const u8,
    port: u16,
    result: ?SeedResult = null,
    err: ?anyerror = null,

    fn run(self: *SeedThreadContext) void {
        self.result = seed(std.heap.page_allocator, self.torrent_bytes, self.target_root, .{
            .peer_id = "SEEDER-PEER-ID-00001".*,
            .port = self.port,
            .max_peers = 1,
        }) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn readHttpHead(stream: std.net.Stream, buffer: []u8) ![]u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const read_count = try stream.read(buffer[used..]);
        if (read_count == 0) return error.EndOfStream;
        used += read_count;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |index| {
            return buffer[0 .. index + 4];
        }
    }

    return error.HttpHeadersOversize;
}

fn writeHttpOk(stream: std.net.Stream, body: []const u8) !void {
    var head = std.ArrayList(u8).empty;
    defer head.deinit(std.testing.allocator);
    try head.print(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        .{body.len},
    );

    try stream.writeAll(head.items);
    try stream.writeAll(body);
}

fn buildTrackerBody(
    allocator: std.mem.Allocator,
    peer_port: u16,
) ![]u8 {
    const peer_bytes = [_]u8{ 127, 0, 0, 1 } ++ std.mem.toBytes(std.mem.nativeToBig(u16, peer_port));

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "d8:intervali30e5:peers6:");
    try body.appendSlice(allocator, &peer_bytes);
    try body.append(allocator, 'e');

    return body.toOwnedSlice(allocator);
}

fn buildSingleFileTorrent(
    allocator: std.mem.Allocator,
    announce_url: []const u8,
    name: []const u8,
    payload: []const u8,
    piece_length: u32,
) ![]u8 {
    const piece_hashes = try buildPieceHashes(allocator, payload, piece_length);
    defer allocator.free(piece_hashes);

    var torrent_bytes = std.ArrayList(u8).empty;
    defer torrent_bytes.deinit(allocator);

    try torrent_bytes.print(allocator, "d8:announce{}:", .{announce_url.len});
    try torrent_bytes.appendSlice(allocator, announce_url);
    try torrent_bytes.print(allocator, "4:infod6:lengthi{}e4:name{}:", .{ payload.len, name.len });
    try torrent_bytes.appendSlice(allocator, name);
    try torrent_bytes.print(allocator, "12:piece lengthi{}e6:pieces{}:", .{ piece_length, piece_hashes.len });
    try torrent_bytes.appendSlice(allocator, piece_hashes);
    try torrent_bytes.appendSlice(allocator, "ee");

    return torrent_bytes.toOwnedSlice(allocator);
}

fn buildPieceHashes(
    allocator: std.mem.Allocator,
    payload: []const u8,
    piece_length: u32,
) ![]u8 {
    const piece_count = computePieceCount(payload.len, piece_length);
    const hashes = try allocator.alloc(u8, piece_count * 20);
    errdefer allocator.free(hashes);

    var piece_index: usize = 0;
    while (piece_index < piece_count) : (piece_index += 1) {
        const start = piece_index * @as(usize, piece_length);
        const end = @min(start + @as(usize, piece_length), payload.len);

        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(payload[start..end], &digest, .{});
        @memcpy(hashes[piece_index * 20 ..][0..20], &digest);
    }

    return hashes;
}

fn computePieceCount(total_size: usize, piece_length: u32) u32 {
    return @intCast((total_size + @as(usize, piece_length) - 1) / @as(usize, piece_length));
}

fn waitForTrackerRequests(requests_served: *std.atomic.Value(u32), count: u32) !void {
    const deadline = std.time.milliTimestamp() + 5_000;
    while (requests_served.load(.seq_cst) < count) {
        if (std.time.milliTimestamp() >= deadline) {
            return error.TestTimeout;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

test "download torrent from local tracker and peer" {
    const allocator = std.testing.allocator;
    const payload = "hello world";
    const piece_length: u32 = 4;
    const peer_id = "ABCDEFGHIJKLMNOPQRST".*;

    var peer_context = FakePeerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .info_hash = undefined,
        .peer_id = "-FAKE00-PEERID123456".*,
        .payload = payload,
        .piece_length = piece_length,
        .expected_requests = computePieceCount(payload.len, piece_length),
    };
    const peer_thread = try std.Thread.spawn(.{}, FakePeerContext.run, .{&peer_context});
    defer peer_thread.join();

    const tracker_body = try buildTrackerBody(allocator, peer_context.server.listen_address.getPort());
    defer allocator.free(tracker_body);

    var tracker_context = FakeTrackerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .response_body = tracker_body,
        .expected_requests = 2,
    };
    const tracker_thread = try std.Thread.spawn(.{}, FakeTrackerContext.run, .{&tracker_context});
    defer tracker_thread.join();

    var announce_url_storage = std.ArrayList(u8).empty;
    defer announce_url_storage.deinit(allocator);
    try announce_url_storage.print(allocator, "http://127.0.0.1:{}/announce", .{tracker_context.server.listen_address.getPort()});

    const torrent_bytes = try buildSingleFileTorrent(
        allocator,
        announce_url_storage.items,
        "fixture.bin",
        payload,
        piece_length,
    );
    defer allocator.free(torrent_bytes);

    peer_context.info_hash = try @import("info_hash.zig").compute(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "download",
    });
    defer allocator.free(target_root);

    const result = try download(allocator, torrent_bytes, target_root, .{
        .peer_id = peer_id,
    });

    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_downloaded);
    try std.testing.expectEqual(@as(u64, 0), result.bytes_reused);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_complete);
    try std.testing.expect(result.peer != null);
    const written = try tmp.dir.readFileAlloc(allocator, "download/fixture.bin", 64);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(payload, written);
}

test "resume download reuses verified pieces on disk" {
    const allocator = std.testing.allocator;
    const payload = "hello world";
    const piece_length: u32 = 4;
    const peer_id = "ABCDEFGHIJKLMNOPQRST".*;

    var peer_context = FakePeerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .info_hash = undefined,
        .peer_id = "-FAKE00-PEERID123456".*,
        .payload = payload,
        .piece_length = piece_length,
        .expected_requests = computePieceCount(payload.len, piece_length) - 1,
    };
    const peer_thread = try std.Thread.spawn(.{}, FakePeerContext.run, .{&peer_context});
    defer peer_thread.join();

    const tracker_body = try buildTrackerBody(allocator, peer_context.server.listen_address.getPort());
    defer allocator.free(tracker_body);

    var tracker_context = FakeTrackerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .response_body = tracker_body,
        .expected_requests = 2,
    };
    const tracker_thread = try std.Thread.spawn(.{}, FakeTrackerContext.run, .{&tracker_context});
    defer tracker_thread.join();

    var announce_url_storage = std.ArrayList(u8).empty;
    defer announce_url_storage.deinit(allocator);
    try announce_url_storage.print(allocator, "http://127.0.0.1:{}/announce", .{tracker_context.server.listen_address.getPort()});

    const torrent_bytes = try buildSingleFileTorrent(
        allocator,
        announce_url_storage.items,
        "fixture.bin",
        payload,
        piece_length,
    );
    defer allocator.free(torrent_bytes);

    peer_context.info_hash = try @import("info_hash.zig").compute(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "download",
    });
    defer allocator.free(target_root);

    try tmp.dir.makePath("download");
    {
        const file = try tmp.dir.createFile("download/fixture.bin", .{ .read = true, .truncate = true });
        defer file.close();
        try file.writeAll(payload[0..4]);
        try file.setEndPos(payload.len);
    }

    const result = try download(allocator, torrent_bytes, target_root, .{
        .peer_id = peer_id,
    });

    try std.testing.expectEqual(@as(u64, payload.len - 4), result.bytes_downloaded);
    try std.testing.expectEqual(@as(u64, 4), result.bytes_reused);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_complete);
    const written = try tmp.dir.readFileAlloc(allocator, "download/fixture.bin", 64);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(payload, written);
}

test "already complete torrent skips tracker and peer work" {
    const allocator = std.testing.allocator;
    const payload = "hello world";
    const piece_length: u32 = 4;
    const peer_id = "ABCDEFGHIJKLMNOPQRST".*;

    const torrent_bytes = try buildSingleFileTorrent(
        allocator,
        "http://127.0.0.1:1/announce",
        "fixture.bin",
        payload,
        piece_length,
    );
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "download",
    });
    defer allocator.free(target_root);

    try tmp.dir.makePath("download");
    {
        const file = try tmp.dir.createFile("download/fixture.bin", .{ .read = true, .truncate = true });
        defer file.close();
        try file.writeAll(payload);
    }

    const result = try download(allocator, torrent_bytes, target_root, .{
        .peer_id = peer_id,
    });

    try std.testing.expect(result.peer == null);
    try std.testing.expectEqual(@as(u64, 0), result.bytes_downloaded);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_reused);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_complete);
}

test "seed and download between two varuna instances through a tracker" {
    const allocator = std.testing.allocator;
    const payload = "hello world";
    const piece_length: u32 = 4;

    const seed_port: u16 = 6881;
    const download_port: u16 = 6882;

    const tracker_response = try buildTrackerBody(allocator, seed_port);
    defer allocator.free(tracker_response);

    var tracker_context = SwarmTrackerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .download_response_body = tracker_response,
        .expected_download_left = payload.len,
    };
    const tracker_thread = try std.Thread.spawn(.{}, SwarmTrackerContext.run, .{&tracker_context});
    var tracker_joined = false;
    defer if (!tracker_joined) tracker_thread.join();

    var announce_url_storage = std.ArrayList(u8).empty;
    defer announce_url_storage.deinit(allocator);
    try announce_url_storage.print(allocator, "http://127.0.0.1:{}/announce", .{tracker_context.server.listen_address.getPort()});

    const torrent_bytes = try buildSingleFileTorrent(
        allocator,
        announce_url_storage.items,
        "fixture.bin",
        payload,
        piece_length,
    );
    defer allocator.free(torrent_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const seed_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "seed",
    });
    defer allocator.free(seed_root);

    const download_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "download",
    });
    defer allocator.free(download_root);

    try tmp.dir.makePath("seed");
    {
        const file = try tmp.dir.createFile("seed/fixture.bin", .{ .read = true, .truncate = true });
        defer file.close();
        try file.writeAll(payload);
    }

    var seed_context = SeedThreadContext{
        .torrent_bytes = torrent_bytes,
        .target_root = seed_root,
        .port = seed_port,
    };
    const seed_thread = try std.Thread.spawn(.{}, SeedThreadContext.run, .{&seed_context});
    var seed_joined = false;
    defer if (!seed_joined) seed_thread.join();

    try waitForTrackerRequests(&tracker_context.requests_served, 1);

    const result = try download(allocator, torrent_bytes, download_root, .{
        .peer_id = "DOWNLOADER-PEER-0001".*,
        .port = download_port,
    });

    seed_thread.join();
    seed_joined = true;
    try std.testing.expect(seed_context.err == null);
    try std.testing.expect(seed_context.result != null);

    try tracker_thread.join();
    tracker_joined = true;

    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_downloaded);
    try std.testing.expectEqual(@as(u64, 0), result.bytes_reused);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_complete);
    try std.testing.expectEqual(@as(u64, payload.len), seed_context.result.?.bytes_seeded);
    try std.testing.expectEqual(@as(u64, payload.len), seed_context.result.?.bytes_complete);

    const written = try tmp.dir.readFileAlloc(allocator, "download/fixture.bin", 64);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(payload, written);
}

const PartialFakePeerContext = struct {
    server: std.net.Server,
    info_hash: [20]u8,
    peer_id: [20]u8,
    payload: []const u8,
    piece_length: u32,
    bitfield_bytes: []const u8,
    expected_requests: u32,

    fn run(self: *PartialFakePeerContext) void {
        self.handleOne() catch |err| @panic(@errorName(err));
    }

    fn handleOne(self: *PartialFakePeerContext) !void {
        defer self.server.deinit();

        var ring = try Ring.init(16);
        defer ring.deinit();

        const connection = try self.server.accept();
        const peer_fd = connection.stream.handle;
        defer connection.stream.close();

        const handshake = try peer_wire.readHandshake(&ring, peer_fd);
        try std.testing.expectEqualDeep(self.info_hash, handshake.info_hash);

        try peer_wire.writeHandshake(&ring, peer_fd, self.info_hash, self.peer_id);
        try peer_wire.writeBitfield(&ring, peer_fd, self.bitfield_bytes);
        try peer_wire.writeUnchoke(&ring, peer_fd);

        var requests_served: u32 = 0;
        while (requests_served < self.expected_requests) {
            const message = try peer_wire.readMessageAlloc(std.testing.allocator, &ring, peer_fd);
            defer peer_wire.freeMessage(std.testing.allocator, message);

            switch (message) {
                .request => |request| {
                    const piece_start: usize = @intCast(request.piece_index * self.piece_length);
                    const piece_end = @min(piece_start + @as(usize, self.piece_length), self.payload.len);
                    const piece_data = self.payload[piece_start..piece_end];
                    const block_start: usize = @intCast(request.block_offset);
                    const block_end = block_start + @as(usize, @intCast(request.length));

                    try peer_wire.writePiece(
                        &ring,
                        peer_fd,
                        request.piece_index,
                        request.block_offset,
                        piece_data[block_start..block_end],
                    );
                    requests_served += 1;
                },
                else => {},
            }
        }
    }
};

fn buildTwoTrackerBody(
    allocator: std.mem.Allocator,
    peer1_port: u16,
    peer2_port: u16,
) ![]u8 {
    const peer1_bytes = [_]u8{ 127, 0, 0, 1 } ++ std.mem.toBytes(std.mem.nativeToBig(u16, peer1_port));
    const peer2_bytes = [_]u8{ 127, 0, 0, 1 } ++ std.mem.toBytes(std.mem.nativeToBig(u16, peer2_port));

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "d8:intervali30e5:peers12:");
    try body.appendSlice(allocator, &peer1_bytes);
    try body.appendSlice(allocator, &peer2_bytes);
    try body.append(allocator, 'e');

    return body.toOwnedSlice(allocator);
}

test "download from two peers with disjoint pieces" {
    const allocator = std.testing.allocator;
    const payload = "hello world!";
    const piece_length: u32 = 4;

    const bitfield1 = [_]u8{0b1010_0000};
    const bitfield2 = [_]u8{0b0100_0000};

    var peer1_context = PartialFakePeerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .info_hash = undefined,
        .peer_id = "-FAKE01-PEER1D123456".*,
        .payload = payload,
        .piece_length = piece_length,
        .bitfield_bytes = &bitfield1,
        .expected_requests = 2,
    };
    var peer2_context = PartialFakePeerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .info_hash = undefined,
        .peer_id = "-FAKE02-PEER2D123456".*,
        .payload = payload,
        .piece_length = piece_length,
        .bitfield_bytes = &bitfield2,
        .expected_requests = 1,
    };

    const peer1_thread = try std.Thread.spawn(.{}, PartialFakePeerContext.run, .{&peer1_context});
    defer peer1_thread.join();
    const peer2_thread = try std.Thread.spawn(.{}, PartialFakePeerContext.run, .{&peer2_context});
    defer peer2_thread.join();

    const tracker_body = try buildTwoTrackerBody(
        allocator,
        peer1_context.server.listen_address.getPort(),
        peer2_context.server.listen_address.getPort(),
    );
    defer allocator.free(tracker_body);

    var tracker_context = FakeTrackerContext{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{ .reuse_address = true }),
        .response_body = tracker_body,
        .expected_requests = 2,
    };
    const tracker_thread = try std.Thread.spawn(.{}, FakeTrackerContext.run, .{&tracker_context});
    defer tracker_thread.join();

    var announce_url_storage = std.ArrayList(u8).empty;
    defer announce_url_storage.deinit(allocator);
    try announce_url_storage.print(allocator, "http://127.0.0.1:{}/announce", .{tracker_context.server.listen_address.getPort()});

    const torrent_bytes = try buildSingleFileTorrent(
        allocator,
        announce_url_storage.items,
        "fixture.bin",
        payload,
        piece_length,
    );
    defer allocator.free(torrent_bytes);

    peer1_context.info_hash = try @import("info_hash.zig").compute(torrent_bytes);
    peer2_context.info_hash = peer1_context.info_hash;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const target_root = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "download",
    });
    defer allocator.free(target_root);

    const result = try download(allocator, torrent_bytes, target_root, .{
        .peer_id = "MULTI-PEER-DL-000001".*,
        .max_peers = 2,
    });

    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_downloaded);
    try std.testing.expectEqual(@as(u64, payload.len), result.bytes_complete);
    const written_mp = try tmp.dir.readFileAlloc(allocator, "download/fixture.bin", 64);
    defer allocator.free(written_mp);
    try std.testing.expectEqualStrings(payload, written_mp);
}

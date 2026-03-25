const std = @import("std");
const blocks_mod = @import("blocks.zig");
const peer_wire = @import("../net/peer_wire.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const session_mod = @import("session.zig");
const Ring = @import("../io/ring.zig").Ring;

const pipeline_depth: u32 = 5;

const RequestPipeline = struct {
    entries: [pipeline_depth]blocks_mod.Geometry.Request = undefined,
    len: u32 = 0,

    fn push(self: *RequestPipeline, request: blocks_mod.Geometry.Request) void {
        std.debug.assert(self.len < pipeline_depth);
        self.entries[self.len] = request;
        self.len += 1;
    }

    fn matchAndRemove(self: *RequestPipeline, piece_index: u32, block_offset: u32) bool {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (entry.piece_index == piece_index and entry.piece_offset == block_offset) {
                // Swap-remove
                self.len -= 1;
                if (i < self.len) {
                    self.entries[i] = self.entries[self.len];
                }
                return true;
            }
        }
        return false;
    }
};

pub const DownloadOptions = struct {
    peer_id: [20]u8,
    port: u16 = 6881,
    status_writer: ?*std.Io.Writer = null,
};

pub const SeedOptions = struct {
    peer_id: [20]u8,
    port: u16 = 6881,
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
    const accept_result = try transport.tcpAccept(&ring, server.stream.handle);
    defer std.posix.close(accept_result.fd);

    try logStatus(options.status_writer, "incoming peer: {f}\n", .{accept_result.address});

    const bytes_seeded = try seedPeer(
        allocator,
        &session,
        &store,
        &recheck.complete_pieces,
        &ring,
        accept_result.fd,
        options.peer_id,
    );

    sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .stopped, 0);
    try logStatus(options.status_writer, "seed complete: {s}\n", .{session.metainfo.name});

    return .{
        .info_hash = session.metainfo.info_hash,
        .piece_count = session.pieceCount(),
        .bytes_seeded = bytes_seeded,
        .bytes_complete = recheck.bytes_complete,
        .peer = accept_result.address,
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

    var last_error: ?anyerror = null;
    for (announce_response.peers) |peer| {
        if (isSelfPeer(peer.address, options.port)) {
            try logStatus(options.status_writer, "skipping self-peer: {f}\n", .{peer.address});
            continue;
        }
        try logStatus(options.status_writer, "peer: {f}\n", .{peer.address});

        const bytes_downloaded = downloadFromPeer(
            allocator,
            &session,
            &store,
            &recheck.complete_pieces,
            peer,
            &ring,
            options,
        ) catch |err| {
            last_error = err;
            try logStatus(options.status_writer, "peer failed: {s}\n", .{@errorName(err)});
            continue;
        };

        sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .completed, bytes_downloaded);
        try logStatus(options.status_writer, "complete: {s}\n", .{session.metainfo.name});
        return .{
            .info_hash = session.metainfo.info_hash,
            .peer = peer,
            .piece_count = session.pieceCount(),
            .bytes_downloaded = bytes_downloaded,
            .bytes_reused = recheck.bytes_complete,
            .bytes_complete = session.totalSize(),
        };
    }

    sendTrackerEvent(allocator, &http_client, announce_url, &session, options, .stopped, 0);
    return last_error orelse error.NoReachablePeers;
}

fn downloadFromPeer(
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    store: *storage.writer.PieceStore,
    complete_pieces: *storage.verify.PieceSet,
    peer: tracker.announce.Peer,
    ring: *Ring,
    options: DownloadOptions,
) !u64 {
    const transport = @import("../net/transport.zig");
    const fd = try transport.tcpConnect(ring, peer.address);
    defer std.posix.close(fd);

    try peer_wire.writeHandshake(ring, fd, session.metainfo.info_hash, options.peer_id);
    const remote_handshake = try peer_wire.readHandshake(ring, fd);
    if (!std.mem.eql(u8, remote_handshake.info_hash[0..], session.metainfo.info_hash[0..])) {
        return error.WrongTorrentPeer;
    }

    try peer_wire.writeInterested(ring, fd);

    var availability = try PieceAvailability.init(allocator, session.pieceCount());
    defer availability.deinit(allocator);

    var peer_choking = true;
    const geometry = session.geometry();
    var next_scan_index: u32 = 0;
    var bytes_downloaded: u64 = 0;

    while (complete_pieces.count < session.pieceCount()) {
        const piece_index = while (true) {
            if (!peer_choking) {
                if (findNextDownloadablePiece(complete_pieces.*, availability, next_scan_index, session.pieceCount())) |candidate| {
                    break candidate;
                }
                if (availability.known) {
                    return error.PeerMissingNeededPieces;
                }
            }

            const message = try peer_wire.readMessageAlloc(allocator, ring, fd);
            defer peer_wire.freeMessage(allocator, message);
            try applyControlMessage(&availability, &peer_choking, message);
        };
        next_scan_index = piece_index + 1;

        if (complete_pieces.has(piece_index)) {
            continue;
        }

        while (true) {
            if (!peer_choking) {
                if (!availability.known or availability.has(piece_index)) break;
                return error.PeerMissingNeededPieces;
            }

            const message = try peer_wire.readMessageAlloc(allocator, ring, fd);
            defer peer_wire.freeMessage(allocator, message);
            try applyControlMessage(&availability, &peer_choking, message);
        }

        const plan = try storage.verify.planPieceVerification(allocator, session, piece_index);
        defer storage.verify.freePiecePlan(allocator, plan);

        const piece_buffer = try allocator.alloc(u8, @intCast(plan.piece_length));
        defer allocator.free(piece_buffer);

        const block_count = try geometry.blockCount(piece_index);
        var next_to_send: u32 = 0;
        var blocks_received: u32 = 0;
        var pipeline: RequestPipeline = .{};

        // Fill initial pipeline
        while (next_to_send < block_count and pipeline.len < pipeline_depth) {
            const req = try geometry.requestForBlock(piece_index, next_to_send);
            try peer_wire.writeRequest(ring, fd, .{
                .piece_index = req.piece_index,
                .block_offset = req.piece_offset,
                .length = req.length,
            });
            pipeline.push(req);
            next_to_send += 1;
        }

        // Drain pipeline, refilling as responses arrive
        while (blocks_received < block_count) {
            const message = try peer_wire.readMessageAlloc(allocator, ring, fd);
            defer peer_wire.freeMessage(allocator, message);

            switch (message) {
                .piece => |piece| {
                    if (!pipeline.matchAndRemove(piece.piece_index, piece.block_offset)) {
                        return error.UnexpectedPieceBlock;
                    }

                    const start: usize = @intCast(piece.block_offset);
                    const end: usize = start + piece.block.len;
                    if (end > plan.piece_length) return error.UnexpectedPieceBlock;
                    @memcpy(piece_buffer[start..end], piece.block);
                    blocks_received += 1;

                    // Refill pipeline
                    if (next_to_send < block_count and !peer_choking) {
                        const req = try geometry.requestForBlock(piece_index, next_to_send);
                        try peer_wire.writeRequest(ring, fd, .{
                            .piece_index = req.piece_index,
                            .block_offset = req.piece_offset,
                            .length = req.length,
                        });
                        pipeline.push(req);
                        next_to_send += 1;
                    }
                },
                .choke => {
                    peer_choking = true;
                    // Peer discards queued requests on choke per BEP 3
                    pipeline = .{};
                    // Wait for unchoke, then re-send from where we left off
                    next_to_send = blocks_received;
                },
                .unchoke => {
                    peer_choking = false;
                    // Re-fill pipeline after unchoke
                    while (next_to_send < block_count and pipeline.len < pipeline_depth) {
                        const req = try geometry.requestForBlock(piece_index, next_to_send);
                        try peer_wire.writeRequest(ring, fd, .{
                            .piece_index = req.piece_index,
                            .block_offset = req.piece_offset,
                            .length = req.length,
                        });
                        pipeline.push(req);
                        next_to_send += 1;
                    }
                },
                else => try applyControlMessage(&availability, &peer_choking, message),
            }
        }

        if (!try storage.verify.verifyPieceBuffer(plan, piece_buffer)) {
            return error.PieceHashMismatch;
        }

        try store.writePiece(plan.spans, piece_buffer);
        try complete_pieces.set(piece_index);
        bytes_downloaded += plan.piece_length;
        try logStatus(
            options.status_writer,
            "piece {}/{}\n",
            .{ complete_pieces.count, session.pieceCount() },
        );
    }

    try store.sync();
    return bytes_downloaded;
}

fn seedPeer(
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    store: *storage.writer.PieceStore,
    complete_pieces: *const storage.verify.PieceSet,
    ring: *Ring,
    fd: std.posix.fd_t,
    peer_id: [20]u8,
) !u64 {
    const remote_handshake = try peer_wire.readHandshake(ring, fd);
    if (!std.mem.eql(u8, remote_handshake.info_hash[0..], session.metainfo.info_hash[0..])) {
        return error.WrongTorrentPeer;
    }

    try peer_wire.writeHandshake(ring, fd, session.metainfo.info_hash, peer_id);
    try peer_wire.writeBitfield(ring, fd, complete_pieces.bits);

    const piece_buffer = try allocator.alloc(u8, session.layout.piece_length);
    defer allocator.free(piece_buffer);

    var peer_unchoked = false;
    var cached_piece_index: ?u32 = null;
    var cached_piece_length: usize = 0;
    var bytes_seeded: u64 = 0;

    while (true) {
        const message = peer_wire.readMessageAlloc(allocator, ring, fd) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer peer_wire.freeMessage(allocator, message);

        switch (message) {
            .keep_alive, .not_interested, .have, .bitfield, .cancel, .port, .choke, .unchoke => {},
            .interested => {
                if (!peer_unchoked) {
                    try peer_wire.writeUnchoke(ring, fd);
                    peer_unchoked = true;
                }
            },
            .request => |request| {
                if (!peer_unchoked) {
                    return error.PeerRequestedWhileChoked;
                }
                if (!complete_pieces.has(request.piece_index)) {
                    return error.RequestedMissingPiece;
                }

                if (cached_piece_index == null or cached_piece_index.? != request.piece_index) {
                    const plan = try storage.verify.planPieceVerification(allocator, session, request.piece_index);
                    defer storage.verify.freePiecePlan(allocator, plan);

                    try store.readPiece(plan.spans, piece_buffer[0..plan.piece_length]);
                    cached_piece_index = request.piece_index;
                    cached_piece_length = plan.piece_length;
                }

                const block_start: usize = @intCast(request.block_offset);
                const block_end = block_start + @as(usize, @intCast(request.length));
                if (block_end < block_start or block_end > cached_piece_length) {
                    return error.InvalidRequestRange;
                }

                try peer_wire.writePiece(
                    ring,
                    fd,
                    request.piece_index,
                    request.block_offset,
                    piece_buffer[block_start..block_end],
                );
                bytes_seeded += request.length;
            },
            .piece => return error.UnexpectedPieceBlock,
        }
    }

    return bytes_seeded;
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

fn applyControlMessage(
    availability: *PieceAvailability,
    peer_choking: *bool,
    message: peer_wire.InboundMessage,
) !void {
    switch (message) {
        .keep_alive, .interested, .not_interested, .request, .cancel, .port => {},
        .choke => peer_choking.* = true,
        .unchoke => peer_choking.* = false,
        .have => |piece_index| try availability.set(piece_index),
        .bitfield => |bitfield| availability.importBitfield(bitfield),
        .piece => return error.UnexpectedPieceBlock,
    }
}

const Bitfield = @import("../bitfield.zig").Bitfield;

const PieceAvailability = struct {
    inner: Bitfield,
    known: bool = false,

    fn init(allocator: std.mem.Allocator, piece_count: u32) !PieceAvailability {
        return .{
            .inner = try Bitfield.init(allocator, piece_count),
        };
    }

    fn deinit(self: *PieceAvailability, allocator: std.mem.Allocator) void {
        self.inner.deinit(allocator);
        self.* = undefined;
    }

    fn importBitfield(self: *PieceAvailability, bitfield_data: []const u8) void {
        self.inner.importBitfield(bitfield_data);
        self.known = true;
    }

    fn set(self: *PieceAvailability, piece_index: u32) !void {
        try self.inner.set(piece_index);
        self.known = true;
    }

    fn has(self: PieceAvailability, piece_index: u32) bool {
        if (!self.known) return true;
        return self.inner.has(piece_index);
    }
};

fn findNextDownloadablePiece(
    complete_pieces: storage.verify.PieceSet,
    availability: PieceAvailability,
    start_index: u32,
    piece_count: u32,
) ?u32 {
    var scanned: u32 = 0;
    while (scanned < piece_count) : (scanned += 1) {
        const piece_index = (start_index + scanned) % piece_count;
        if (complete_pieces.has(piece_index)) continue;
        if (!availability.known or availability.has(piece_index)) {
            return piece_index;
        }
    }

    return null;
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

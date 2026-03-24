const std = @import("std");
const peer_wire = @import("../net/peer_wire.zig");
const storage = @import("../storage/root.zig");
const tracker = @import("../tracker/root.zig");
const session_mod = @import("session.zig");

pub const DownloadOptions = struct {
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

pub fn download(
    allocator: std.mem.Allocator,
    torrent_bytes: []const u8,
    target_root: []const u8,
    options: DownloadOptions,
) !DownloadResult {
    const session = try session_mod.Session.load(allocator, torrent_bytes, target_root);
    defer session.deinit(allocator);

    var store = try storage.writer.PieceStore.init(allocator, &session);
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
        try logStatus(options.status_writer, "peer: {f}\n", .{peer.address});

        const bytes_downloaded = downloadFromPeer(
            allocator,
            &session,
            &store,
            &recheck.complete_pieces,
            peer,
            options,
        ) catch |err| {
            last_error = err;
            try logStatus(options.status_writer, "peer failed: {s}\n", .{@errorName(err)});
            continue;
        };

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

    return last_error orelse error.NoReachablePeers;
}

fn downloadFromPeer(
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    store: *storage.writer.PieceStore,
    complete_pieces: *storage.verify.PieceSet,
    peer: tracker.announce.Peer,
    options: DownloadOptions,
) !u64 {
    const stream = try std.net.tcpConnectToAddress(peer.address);
    defer stream.close();

    try peer_wire.writeHandshake(stream, session.metainfo.info_hash, options.peer_id);
    const remote_handshake = try peer_wire.readHandshake(stream);
    if (!std.mem.eql(u8, remote_handshake.info_hash[0..], session.metainfo.info_hash[0..])) {
        return error.WrongTorrentPeer;
    }

    try peer_wire.writeInterested(stream);

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

            const message = try peer_wire.readMessageAlloc(allocator, stream);
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

            const message = try peer_wire.readMessageAlloc(allocator, stream);
            defer peer_wire.freeMessage(allocator, message);
            try applyControlMessage(&availability, &peer_choking, message);
        }

        const plan = try storage.verify.planPieceVerification(allocator, session, piece_index);
        defer storage.verify.freePiecePlan(allocator, plan);

        const piece_buffer = try allocator.alloc(u8, @intCast(plan.piece_length));
        defer allocator.free(piece_buffer);

        var block_index: u32 = 0;
        const block_count = try geometry.blockCount(piece_index);
        while (block_index < block_count) : (block_index += 1) {
            const block_request = try geometry.requestForBlock(piece_index, block_index);
            try peer_wire.writeRequest(stream, .{
                .piece_index = block_request.piece_index,
                .block_offset = block_request.piece_offset,
                .length = block_request.length,
            });

            var received = false;
            while (!received) {
                const message = try peer_wire.readMessageAlloc(allocator, stream);
                defer peer_wire.freeMessage(allocator, message);

                switch (message) {
                    .piece => |piece| {
                        if (piece.piece_index != block_request.piece_index or
                            piece.block_offset != block_request.piece_offset or
                            piece.block.len != block_request.length)
                        {
                            return error.UnexpectedPieceBlock;
                        }

                        const start: usize = @intCast(block_request.piece_offset);
                        const end: usize = start + @as(usize, @intCast(block_request.length));
                        @memcpy(piece_buffer[start..end], piece.block);
                        received = true;
                    },
                    else => try applyControlMessage(&availability, &peer_choking, message),
                }
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

const PieceAvailability = struct {
    bits: []u8,
    piece_count: u32,
    known: bool = false,

    fn init(allocator: std.mem.Allocator, piece_count: u32) !PieceAvailability {
        const bits = try allocator.alloc(u8, bitfieldByteCount(piece_count));
        @memset(bits, 0);
        return .{
            .bits = bits,
            .piece_count = piece_count,
        };
    }

    fn deinit(self: *PieceAvailability, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
        self.* = undefined;
    }

    fn importBitfield(self: *PieceAvailability, bitfield: []const u8) void {
        @memset(self.bits, 0);
        const copy_length = @min(self.bits.len, bitfield.len);
        @memcpy(self.bits[0..copy_length], bitfield[0..copy_length]);
        self.known = true;
    }

    fn set(self: *PieceAvailability, piece_index: u32) !void {
        if (piece_index >= self.piece_count) {
            return error.InvalidPieceIndex;
        }

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        self.bits[byte_index] |= @as(u8, 1) << bit_index;
        self.known = true;
    }

    fn has(self: PieceAvailability, piece_index: u32) bool {
        if (!self.known) return true;
        if (piece_index >= self.piece_count) return false;

        const byte_index: usize = @intCast(piece_index / 8);
        const bit_index: u3 = @intCast(7 - (piece_index % 8));
        return (self.bits[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }
};

fn bitfieldByteCount(piece_count: u32) usize {
    return @intCast((piece_count + 7) / 8);
}

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

    fn run(self: *FakeTrackerContext) void {
        self.handleOne() catch |err| @panic(@errorName(err));
    }

    fn handleOne(self: *FakeTrackerContext) !void {
        defer self.server.deinit();

        const connection = try self.server.accept();
        defer connection.stream.close();

        var request_buffer: [4096]u8 = undefined;
        const request = try readHttpHead(connection.stream, &request_buffer);
        try std.testing.expect(std.mem.startsWith(u8, request, "GET /announce?"));
        try std.testing.expect(std.mem.indexOf(u8, request, "compact=1") != null);
        try std.testing.expect(std.mem.indexOf(u8, request, "peer_id=") != null);
        try std.testing.expect(std.mem.indexOf(u8, request, "info_hash=") != null);

        var head = std.ArrayList(u8).empty;
        defer head.deinit(std.testing.allocator);
        try head.print(std.testing.allocator,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            .{self.response_body.len},
        );

        try connection.stream.writeAll(head.items);
        try connection.stream.writeAll(self.response_body);
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

        const connection = try self.server.accept();
        defer connection.stream.close();

        const handshake = try peer_wire.readHandshake(connection.stream);
        try std.testing.expectEqualDeep(self.info_hash, handshake.info_hash);

        try peer_wire.writeHandshake(connection.stream, self.info_hash, self.peer_id);

        const interested = try peer_wire.readMessageAlloc(std.testing.allocator, connection.stream);
        defer peer_wire.freeMessage(std.testing.allocator, interested);
        try std.testing.expectEqual(peer_wire.InboundMessage.interested, interested);

        const bitfield = [_]u8{0b1110_0000};
        try peer_wire.writeBitfield(connection.stream, &bitfield);
        try peer_wire.writeUnchoke(connection.stream);

        var requests_served: u32 = 0;
        while (requests_served < self.expected_requests) {
            const message = try peer_wire.readMessageAlloc(std.testing.allocator, connection.stream);
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
                        connection.stream,
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

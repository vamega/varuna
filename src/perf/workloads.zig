const std = @import("std");
const varuna = @import("varuna");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const Stats = @import("counting_allocator.zig").Stats;

const blocks = varuna.torrent.blocks;
const rpc_server = varuna.rpc.server;
const sync_mod = varuna.rpc.sync;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;

pub const Config = struct {
    iterations: usize = 1_000,
    scale: usize = 1,
    peers: usize = varuna.io.event_loop.max_peers,
    torrents: usize = 64,
};

pub const Result = struct {
    scenario: []const u8,
    iterations: usize,
    elapsed_ns: u64,
    checksum: u64,
    allocator: Stats,
};

pub const Scenario = enum {
    peer_scan,
    request_batch,
    seed_batch,
    http_response,
    extension_decode,
    ut_metadata_decode,
    session_load,
    sync_delta,

    pub fn parse(name: []const u8) ?Scenario {
        inline for (std.meta.fields(Scenario)) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                return @field(Scenario, field.name);
            }
        }
        return null;
    }
};

pub fn run(
    scenario: Scenario,
    alloc_counter: *CountingAllocator,
    config: Config,
) !Result {
    const allocator = alloc_counter.allocator();
    const iterations = @max(config.iterations, 1);

    return switch (scenario) {
        .peer_scan => runPeerScan(allocator, alloc_counter, iterations, config),
        .request_batch => runRequestBatch(allocator, alloc_counter, iterations, config),
        .seed_batch => runSeedBatch(allocator, alloc_counter, iterations, config),
        .http_response => runHttpResponse(allocator, alloc_counter, iterations, config),
        .extension_decode => runExtensionDecode(allocator, alloc_counter, iterations),
        .ut_metadata_decode => runUtMetadataDecode(allocator, alloc_counter, iterations),
        .session_load => runSessionLoad(allocator, alloc_counter, iterations),
        .sync_delta => runSyncDelta(allocator, alloc_counter, iterations, config),
    };
}

fn makeResult(
    scenario: []const u8,
    iterations: usize,
    timer: *std.time.Timer,
    checksum: u64,
    alloc_counter: *CountingAllocator,
) Result {
    return .{
        .scenario = scenario,
        .iterations = iterations,
        .elapsed_ns = timer.read(),
        .checksum = checksum,
        .allocator = alloc_counter.stats,
    };
}

fn runPeerScan(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    const Peer = varuna.io.event_loop.Peer;
    const max_peers = @min(config.peers, varuna.io.event_loop.max_peers);
    const active_stride = @max(config.scale, 1);
    const peers = try allocator.alloc(Peer, max_peers);
    defer allocator.free(peers);
    var active_slots = std.ArrayList(u16).empty;
    defer active_slots.deinit(allocator);

    @memset(peers, Peer{});
    for (peers, 0..) |*peer, idx| {
        if (active_stride > 1 and idx % active_stride != 0) continue;
        peer.state = if (idx % 7 == 0) .disconnecting else .active_recv_header;
        peer.mode = if (idx % 3 == 0) .seed else .download;
        peer.torrent_id = @intCast(idx % @max(config.torrents, 1));
        peer.peer_interested = (idx & 1) == 0;
        peer.am_choking = (idx & 3) == 0;
        peer.send_pending = (idx & 7) == 0;
        peer.last_activity = std.time.timestamp() - @as(i64, @intCast(idx % 90));
        peer.bytes_downloaded_from = idx *% 4096;
        peer.bytes_uploaded_to = idx *% 2048;
        peer.current_dl_speed = idx *% 13;
        peer.current_ul_speed = idx *% 7;
        try active_slots.append(allocator, @intCast(idx));
    }

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    var interested_slots: [varuna.io.event_loop.max_peers]u16 = undefined;

    for (0..iterations) |_| {
        var timeout_count: u32 = 0;
        for (active_slots.items) |slot| {
            const peer = &peers[slot];
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.mode == .seed) continue;
            if (peer.last_activity != 0 and (std.time.timestamp() - peer.last_activity) > 60) {
                timeout_count += 1;
            }
        }

        var interested_count: usize = 0;
        for (active_slots.items) |idx| {
            const peer = &peers[idx];
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.mode != .seed) continue;
            if (!peer.peer_interested) continue;
            interested_slots[interested_count] = idx;
            interested_count += 1;
        }

        std.mem.sort(u16, interested_slots[0..interested_count], peers, struct {
            fn lessThan(ctx: []Peer, a: u16, b: u16) bool {
                return ctx[a].bytes_downloaded_from > ctx[b].bytes_downloaded_from;
            }
        }.lessThan);

        var dl_total: u64 = 0;
        var ul_total: u64 = 0;
        for (active_slots.items) |slot| {
            const peer = &peers[slot];
            if (peer.state == .free) continue;
            if (peer.torrent_id != 0) continue;
            dl_total += peer.bytes_downloaded_from;
            ul_total += peer.bytes_uploaded_to;
        }

        checksum +%= timeout_count;
        checksum +%= interested_count;
        checksum +%= dl_total;
        checksum +%= ul_total;
    }

    return makeResult("peer_scan", iterations, &timer, checksum, alloc_counter);
}

fn runRequestBatch(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    _ = allocator;
    _ = config;
    const request_count = 5;
    const piece_size = 5 * blocks.default_block_size;

    var dummy_layout = varuna.torrent.layout.Layout{
        .piece_length = piece_size,
        .piece_count = 1,
        .total_size = piece_size,
        .files = &.{},
        .piece_hashes = &.{},
    };
    const geometry = blocks.Geometry{ .layout = &dummy_layout };

    var requests: [request_count]blocks.Geometry.Request = undefined;
    for (&requests, 0..) |*request, idx| {
        request.* = try geometry.requestForBlock(0, @intCast(idx));
    }

    const request_size = 17;
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        var send_buf: [request_size * request_count]u8 = undefined;

        for (requests, 0..) |request, idx| {
            const offset = idx * request_size;
            std.mem.writeInt(u32, send_buf[offset..][0..4], 13, .big);
            send_buf[offset + 4] = 6;
            std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], request.piece_index, .big);
            std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], request.piece_offset, .big);
            std.mem.writeInt(u32, send_buf[offset + 13 ..][0..4], request.length, .big);
        }

        checksum +%= std.hash.Wyhash.hash(0, send_buf[0..]);
    }

    return makeResult("request_batch", iterations, &timer, checksum, alloc_counter);
}

fn runSeedBatch(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    _ = config;
    const block_count = 8;
    const block_len = 16 * 1024;
    const piece_len = block_count * block_len;
    const piece_data = try allocator.alloc(u8, piece_len);
    defer allocator.free(piece_data);
    for (piece_data, 0..) |*byte, idx| byte.* = @truncate(idx *% 17 +% 11);

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        var total_len: usize = 0;

        for (0..block_count) |idx| {
            _ = idx;
            total_len += 13 + block_len;
        }

        const send_buf = try allocator.alloc(u8, total_len);
        defer allocator.free(send_buf);

        var offset: usize = 0;
        for (0..block_count) |idx| {
            const msg_len: u32 = 1 + 8 + block_len;
            std.mem.writeInt(u32, send_buf[offset..][0..4], msg_len, .big);
            send_buf[offset + 4] = 7;
            std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], 0, .big);
            std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], @intCast(idx * block_len), .big);
            const start = idx * block_len;
            @memcpy(send_buf[offset + 13 ..][0..block_len], piece_data[start .. start + block_len]);
            offset += 13 + block_len;
        }

        checksum +%= std.hash.Wyhash.hash(0, send_buf);
    }

    return makeResult("seed_batch", iterations, &timer, checksum, alloc_counter);
}

fn runHttpResponse(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    const body_len = 8 * 1024 * @max(config.scale, 1);
    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    for (body, 0..) |*byte, idx| byte.* = @truncate(idx *% 29 +% 3);

    const response = rpc_server.Response{
        .status = 200,
        .content_type = "application/json",
        .body = body,
        .extra_headers = "X-Benchmark: 1\r\n",
    };

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        var header = std.ArrayList(u8).empty;
        defer header.deinit(allocator);

        try header.print(allocator, "HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nConnection: close\r\n", .{
            response.status,
            "OK",
            response.content_type,
            response.body.len,
        });
        if (response.extra_headers) |headers| {
            try header.appendSlice(allocator, headers);
        }
        try header.appendSlice(allocator, "\r\n");

        const owned = try header.toOwnedSlice(allocator);
        defer allocator.free(owned);
        checksum +%= std.hash.Wyhash.hash(0, owned);
        checksum +%= std.hash.Wyhash.hash(0, response.body);
    }

    return makeResult("http_response", iterations, &timer, checksum, alloc_counter);
}

fn runExtensionDecode(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
) !Result {
    const payload = try varuna.net.extensions.encodeExtensionHandshakeFull(allocator, 6881, false, 262_144, true);
    defer allocator.free(payload);

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        var decoded = try varuna.net.extensions.decodeExtensionHandshake(allocator, payload);
        checksum +%= decoded.handshake.extensions.ut_metadata;
        checksum +%= decoded.handshake.extensions.ut_pex;
        checksum +%= decoded.handshake.port;
        checksum +%= decoded.handshake.metadata_size;
        checksum +%= @intFromBool(decoded.handshake.upload_only);
        varuna.net.extensions.freeDecoded(allocator, &decoded);
    }

    return makeResult("extension_decode", iterations, &timer, checksum, alloc_counter);
}

fn runUtMetadataDecode(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
) !Result {
    const header = try varuna.net.ut_metadata.encodeData(allocator, 3, 65_536);
    defer allocator.free(header);

    const piece_data = "abcdefghijklmnopqrstuvwxyz012345";
    const payload = try allocator.alloc(u8, header.len + piece_data.len);
    defer allocator.free(payload);
    @memcpy(payload[0..header.len], header);
    @memcpy(payload[header.len..], piece_data);

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        const msg = try varuna.net.ut_metadata.decode(allocator, payload);
        checksum +%= @intFromEnum(msg.msg_type);
        checksum +%= msg.piece;
        checksum +%= msg.total_size;
        checksum +%= msg.data_offset;
    }

    return makeResult("ut_metadata_decode", iterations, &timer, checksum, alloc_counter);
}

fn runSessionLoad(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
) !Result {
    const torrent_bytes = try makeTorrentBytes(allocator, 0);
    defer allocator.free(torrent_bytes);

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        const session = try varuna.torrent.session.Session.load(allocator, torrent_bytes, "/tmp/varuna-bench");
        checksum +%= session.pieceCount();
        checksum +%= session.layout.total_size;
        session.deinit(allocator);
    }

    return makeResult("session_load", iterations, &timer, checksum, alloc_counter);
}

fn runSyncDelta(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var manager = SessionManager.init(allocator);
    defer manager.deinit();

    const torrent_count = @max(config.torrents, 1);
    try manager.category_store.create("bench", "/tmp/bench");
    try manager.tag_store.create("fast");

    for (0..torrent_count) |idx| {
        const torrent_bytes = try makeTorrentBytes(allocator, idx);
        defer allocator.free(torrent_bytes);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        session.* = try TorrentSession.create(allocator, torrent_bytes, "/tmp/varuna-bench", null);
        errdefer session.deinit();

        if ((idx & 1) == 0) {
            session.category = try allocator.dupe(u8, "bench");
        }
        if ((idx & 3) == 0) {
            try session.tags.append(allocator, try allocator.dupe(u8, "fast"));
            session.rebuildTagsString();
        }
        session.state = if ((idx & 1) == 0) .downloading else .paused;

        manager.mutex.lock();
        manager.sessions.put(&session.info_hash_hex, session) catch |err| {
            manager.mutex.unlock();
            return err;
        };
        manager.mutex.unlock();
    }

    var sync_state = sync_mod.SyncState.init(allocator);
    defer sync_state.deinit();

    const warm_body = try sync_state.computeDelta(&manager, allocator, 0);
    defer allocator.free(warm_body);
    const request_rid = sync_state.current_rid;

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |idx| {
        if (idx % 8 == 0) {
            manager.mutex.lock();
            defer manager.mutex.unlock();
            var iter = manager.sessions.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.*.state = if (entry.value_ptr.*.state == .downloading) .paused else .downloading;
            }
        }

        const body = try sync_state.computeDelta(&manager, allocator, request_rid);
        checksum +%= std.hash.Wyhash.hash(0, body);
        allocator.free(body);
    }

    return makeResult("sync_delta", iterations, &timer, checksum, alloc_counter);
}

fn makeTorrentBytes(allocator: std.mem.Allocator, seed: usize) ![]u8 {
    const file_len: u64 = 16 * 1024;
    const name = try std.fmt.allocPrint(allocator, "bench-{d}.bin", .{seed});
    defer allocator.free(name);

    var pieces: [20]u8 = undefined;
    for (&pieces, 0..) |*byte, idx| {
        byte.* = @truncate((seed *% 31) +% idx +% 1);
    }

    return std.fmt.allocPrint(
        allocator,
        "d4:infod6:lengthi{}e4:name{}:{s}12:piece lengthi16384e6:pieces20:{s}ee",
        .{
            file_len,
            name.len,
            name,
            pieces,
        },
    );
}

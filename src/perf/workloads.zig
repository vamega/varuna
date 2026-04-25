const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const varuna = @import("varuna");
const CountingAllocator = @import("counting_allocator.zig").CountingAllocator;
const Stats = @import("counting_allocator.zig").Stats;

const blocks = varuna.torrent.blocks;
const Bitfield = varuna.bitfield.Bitfield;
const EventLoop = varuna.io.event_loop.EventLoop;
const Peer = varuna.io.event_loop.Peer;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;
const rpc_server = varuna.rpc.server;
const sync_mod = varuna.rpc.sync;
const event_loop_mod = varuna.io.event_loop;
const peer_handler = varuna.io.peer_handler;
const http_mod = varuna.io.http_blocking;
const IoUring = linux.IoUring;
const mse_mod = varuna.crypto.mse;
const tracker_announce = varuna.tracker.announce;
const SessionManager = varuna.daemon.session_manager.SessionManager;
const TrackerExecutor = varuna.daemon.tracker_executor.TrackerExecutor;
const RealIO = varuna.io.real_io.RealIO;
const TorrentSession = varuna.daemon.torrent_session.TorrentSession;
const peer_policy = varuna.io.peer_policy;
const pex_mod = varuna.net.pex;
const seed_handler = varuna.io.seed_handler;
const utp_handler = varuna.io.utp_handler;

pub const Config = struct {
    iterations: usize = 1_000,
    scale: usize = 1,
    peers: usize = varuna.io.event_loop.max_peers,
    torrents: usize = 64,
    clients: usize = 1,
    body_bytes: usize = 0,
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
    peer_accept_burst,
    request_batch,
    piece_buffer_cycle,
    seed_batch,
    seed_plaintext_burst,
    seed_send_copy_burst,
    seed_sendmsg_burst,
    seed_splice_burst,
    http_response,
    api_get_burst,
    api_get_seq,
    api_upload_burst,
    tracker_http_fresh,
    tracker_http_reuse_potential,
    tracker_announce_fresh,
    tracker_announce_executor,
    extension_decode,
    ut_metadata_decode,
    mse_responder_prep,
    session_load,
    sync_delta,
    sync_stats_live,
    tick_sparse_torrents,
    peer_churn,
    utp_outbound_burst,

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
        .peer_accept_burst => runPeerAcceptBurst(allocator, alloc_counter, iterations, config),
        .request_batch => runRequestBatch(allocator, alloc_counter, iterations, config),
        .piece_buffer_cycle => runPieceBufferCycle(allocator, alloc_counter, iterations, config),
        .seed_batch => runSeedBatch(allocator, alloc_counter, iterations, config),
        .seed_plaintext_burst => runSeedPlaintextBurst(allocator, alloc_counter, iterations, config),
        .seed_send_copy_burst => runSeedSendCopyBurst(allocator, alloc_counter, iterations, config),
        .seed_sendmsg_burst => runSeedSendmsgBurst(allocator, alloc_counter, iterations, config),
        .seed_splice_burst => runSeedSpliceBurst(allocator, alloc_counter, iterations, config),
        .http_response => runHttpResponse(allocator, alloc_counter, iterations, config),
        .api_get_burst => runApiBurst(allocator, alloc_counter, iterations, config, .get),
        .api_get_seq => runApiSequentialGet(allocator, alloc_counter, iterations, config),
        .api_upload_burst => runApiBurst(allocator, alloc_counter, iterations, config, .upload),
        .tracker_http_fresh => runTrackerHttpSeries(allocator, alloc_counter, iterations, .fresh),
        .tracker_http_reuse_potential => runTrackerHttpSeries(allocator, alloc_counter, iterations, .reuse_potential),
        .tracker_announce_fresh => runTrackerAnnounceFresh(allocator, alloc_counter, iterations),
        .tracker_announce_executor => runTrackerAnnounceExecutor(allocator, alloc_counter, iterations),
        .extension_decode => runExtensionDecode(allocator, alloc_counter, iterations),
        .ut_metadata_decode => runUtMetadataDecode(allocator, alloc_counter, iterations),
        .mse_responder_prep => runMseResponderPrep(allocator, alloc_counter, iterations, config),
        .session_load => runSessionLoad(allocator, alloc_counter, iterations),
        .sync_delta => runSyncDelta(allocator, alloc_counter, iterations, config),
        .sync_stats_live => runSyncStatsLive(allocator, alloc_counter, iterations, config),
        .tick_sparse_torrents => runTickSparseTorrents(allocator, alloc_counter, iterations, config),
        .peer_churn => runPeerChurn(allocator, alloc_counter, iterations, config),
        .utp_outbound_burst => runUtpOutboundBurst(allocator, alloc_counter, iterations, config),
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
        peer.mode = if (idx % 3 == 0) .inbound else .outbound;
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
            if (peer.mode == .inbound) continue;
            if (peer.last_activity != 0 and (std.time.timestamp() - peer.last_activity) > 60) {
                timeout_count += 1;
            }
        }

        var interested_count: usize = 0;
        for (active_slots.items) |idx| {
            const peer = &peers[idx];
            if (peer.state == .free or peer.state == .disconnecting) continue;
            if (peer.mode != .inbound) continue;
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

const PeerConnectWork = struct {
    address: std.net.Address,
    connects: usize,
    remaining_workers: *std.atomic.Value(usize),
    checksum: u64 = 0,
};

fn runPeerAcceptBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var event_loop = try event_loop_mod.EventLoop.initBare(allocator, 0);
    defer event_loop.deinit();
    event_loop.max_connections = @intCast(@max(iterations + config.clients * 4, 512));

    const listen_fd = try createLoopbackListener();
    try event_loop.ensureAccepting(listen_fd);
    const port = try getListenPort(listen_fd);
    const address = try std.net.Address.parseIp4("127.0.0.1", port);

    const worker_count = @max(@min(config.clients, 32), 1);
    const workers = try allocator.alloc(PeerConnectWork, worker_count);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var remaining_workers = std.atomic.Value(usize).init(worker_count);

    const base_connects = iterations / worker_count;
    var remainder = iterations % worker_count;
    for (workers) |*worker| {
        worker.* = .{
            .address = address,
            .connects = base_connects + @intFromBool(remainder > 0),
            .remaining_workers = &remaining_workers,
        };
        if (remainder > 0) remainder -= 1;
    }

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();

    for (threads, workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, peerConnectWorker, .{worker});
    }

    // Accept CQEs land on `event_loop.io` (multishot accept on the new
    // io_interface ring) after Stage 2 #12; the workload no longer drains
    // them via the legacy ring's CQE switch. We treat `iterations` as the
    // expected accept count and rely on the workers' `remaining_workers`
    // and `event_loop.peer_count` for termination instead.
    const accepted: usize = iterations;
    const recv_eof: usize = 0;
    var idle_ticks: usize = 0;
    var cqes: [64]linux.io_uring_cqe = undefined;

    while (event_loop.peer_count != 0 or remaining_workers.load(.acquire) != 0) {
        try event_loop.submitTimeout(1 * std.time.ns_per_ms);
        // Drain io_interface completions (accept + peer recv) before the
        // legacy ring's blocking wait so the listener can pick up
        // connections without latency.
        event_loop.io.tick(0) catch {};
        _ = try event_loop.ring.submit_and_wait(1);

        const count = try event_loop.ring.copy_cqes(&cqes, 0);
        if (count == 0) {
            idle_ticks += 1;
        } else {
            idle_ticks = 0;
        }

        for (cqes[0..count]) |cqe| {
            const op = event_loop_mod.decodeUserData(cqe.user_data);
            switch (op.op_type) {
                .peer_send => peer_handler.handleSend(&event_loop, op.slot, cqe),
                .timeout => {
                    event_loop.timeout_pending = false;
                },
                else => {},
            }
        }

        _ = event_loop.ring.submit() catch {};
        event_loop.io.tick(0) catch {};

        if (idle_ticks > 20_000) return error.BenchmarkTimeout;
    }

    var checksum: u64 = accepted;
    // recv_eof is preserved as part of the checksum signature for the
    // historic benchmark output; it stays at 0 now that recv CQEs are
    // dispatched via `Peer.recv_completion` callbacks rather than this
    // explicit ring drain.
    checksum +%= recv_eof;
    for (threads, workers) |*thread, *worker| {
        thread.join();
        checksum +%= worker.checksum;
    }

    return makeResult("peer_accept_burst", iterations, &timer, checksum, alloc_counter);
}

fn peerConnectWorker(work: *PeerConnectWork) void {
    defer _ = work.remaining_workers.fetchSub(1, .acq_rel);

    var checksum: u64 = 0;
    for (0..work.connects) |_| {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch |err| {
            std.debug.panic("peer benchmark socket failed: {}", .{err});
        };

        posix.connect(fd, &work.address.any, work.address.getOsSockLen()) catch |err| {
            posix.close(fd);
            std.debug.panic("peer benchmark connect failed: {}", .{err});
        };
        checksum +%= @intCast(fd);
        posix.close(fd);
    }

    work.checksum = checksum;
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

fn runPieceBufferCycle(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    _ = config;
    var event_loop = try EventLoop.initBare(allocator, 0);
    defer event_loop.deinit();

    const sizes = [_]usize{
        16 * 1024,
        64 * 1024,
        256 * 1024,
        1024 * 1024,
        4 * 1024 * 1024,
    };

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        for (sizes, 0..) |size, idx| {
            const piece_buffer = try event_loop.createPieceBuffer(size);
            piece_buffer.buf[0] = @truncate(iter +% idx);
            piece_buffer.buf[piece_buffer.buf.len - 1] = @truncate((iter *% 17) +% idx);
            checksum +%= piece_buffer.buf[0];
            checksum +%= piece_buffer.buf[piece_buffer.buf.len - 1];
            checksum +%= piece_buffer.buf.len;
            event_loop.releasePieceBuffer(piece_buffer);
        }
    }

    return makeResult("piece_buffer_cycle", iterations, &timer, checksum, alloc_counter);
}

fn runSeedPlaintextBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var event_loop = try EventLoop.initBare(allocator, 0);
    defer event_loop.deinit();

    const fds = try createStreamSocketPair();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const block_count = @max(config.scale, 8);
    const block_len = 16 * 1024;
    const piece_len = block_count * block_len;
    const total_len = block_count * (13 + block_len);

    const piece_buffer = try event_loop.createPieceBuffer(piece_len);
    defer event_loop.releasePieceBuffer(piece_buffer);
    for (piece_buffer.buf, 0..) |*byte, idx| byte.* = @truncate(idx *% 29 +% 7);

    const recv_buf = try allocator.alloc(u8, total_len);
    defer allocator.free(recv_buf);

    event_loop.peers[0] = .{
        .fd = fds[0],
        .state = .active_recv_header,
        .mode = .inbound,
        .torrent_id = 0,
        .crypto = mse_mod.PeerCrypto.plaintext,
    };
    event_loop.peer_count = 1;
    event_loop.markActivePeer(0);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        for (0..block_count) |idx| {
            try event_loop.queued_responses.append(allocator, .{
                .slot = 0,
                .piece_index = @intCast(iter & 0xffff),
                .block_offset = @intCast(idx * block_len),
                .block_length = block_len,
                .piece_buffer = piece_buffer,
            });
        }

        seed_handler.flushQueuedResponses(&event_loop);
        try drainPeerSendCompletions(&event_loop, 0);
        try readExact(fds[1], recv_buf);
        checksum +%= std.hash.Wyhash.hash(0, recv_buf);
    }

    return makeResult("seed_plaintext_burst", iterations, &timer, checksum, alloc_counter);
}

fn runSeedSendCopyBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var ring = try IoUring.init(64, 0);
    defer ring.deinit();

    const pair = try createLoopbackTcpPair();
    defer posix.close(pair.listen_fd);
    defer posix.close(pair.sender_fd);
    defer posix.close(pair.receiver_fd);

    const block_count = @max(config.scale, 8);
    const block_len = 16 * 1024;
    const piece_len = block_count * block_len;
    const total_len = block_count * (13 + block_len);

    const piece_data = try allocator.alloc(u8, piece_len);
    defer allocator.free(piece_data);
    for (piece_data, 0..) |*byte, idx| byte.* = @truncate(idx *% 17 +% 11);

    const recv_buf = try allocator.alloc(u8, total_len);
    defer allocator.free(recv_buf);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        const send_buf = try allocator.alloc(u8, total_len);
        defer allocator.free(send_buf);

        var offset: usize = 0;
        for (0..block_count) |idx| {
            const msg_len: u32 = 1 + 8 + block_len;
            std.mem.writeInt(u32, send_buf[offset..][0..4], msg_len, .big);
            send_buf[offset + 4] = 7;
            std.mem.writeInt(u32, send_buf[offset + 5 ..][0..4], @intCast(iter & 0xffff), .big);
            std.mem.writeInt(u32, send_buf[offset + 9 ..][0..4], @intCast(idx * block_len), .big);
            @memcpy(send_buf[offset + 13 ..][0..block_len], piece_data[idx * block_len ..][0..block_len]);
            offset += 13 + block_len;
        }

        _ = try ring.send(1, pair.sender_fd, send_buf, 0);
        _ = try ring.submit_and_wait(1);
        const cqe = try ring.copy_cqe();
        if (cqe.res < 0) return error.SeedCopySendFailed;
        if (@as(usize, @intCast(cqe.res)) != total_len) return error.PartialSeedCopySend;

        try readExact(pair.receiver_fd, recv_buf);
        checksum +%= std.hash.Wyhash.hash(0, recv_buf);
    }

    return makeResult("seed_send_copy_burst", iterations, &timer, checksum, alloc_counter);
}

fn runSeedSendmsgBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var ring = try IoUring.init(64, 0);
    defer ring.deinit();

    const pair = try createLoopbackTcpPair();
    defer posix.close(pair.listen_fd);
    defer posix.close(pair.sender_fd);
    defer posix.close(pair.receiver_fd);

    const block_count = @max(config.scale, 8);
    const block_len = 16 * 1024;
    const piece_len = block_count * block_len;
    const total_len = block_count * (13 + block_len);

    const piece_data = try allocator.alloc(u8, piece_len);
    defer allocator.free(piece_data);
    for (piece_data, 0..) |*byte, idx| byte.* = @truncate(idx *% 19 +% 5);

    const recv_buf = try allocator.alloc(u8, total_len);
    defer allocator.free(recv_buf);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        const headers = try allocator.alloc([13]u8, block_count);
        defer allocator.free(headers);
        const iovecs = try allocator.alloc(posix.iovec_const, block_count * 2);
        defer allocator.free(iovecs);

        for (0..block_count) |idx| {
            const msg_len: u32 = 1 + 8 + block_len;
            std.mem.writeInt(u32, headers[idx][0..4], msg_len, .big);
            headers[idx][4] = 7;
            std.mem.writeInt(u32, headers[idx][5..9], @intCast(iter & 0xffff), .big);
            std.mem.writeInt(u32, headers[idx][9..13], @intCast(idx * block_len), .big);

            iovecs[idx * 2] = .{
                .base = @ptrCast(&headers[idx]),
                .len = headers[idx].len,
            };
            iovecs[idx * 2 + 1] = .{
                .base = @ptrCast(piece_data.ptr + idx * block_len),
                .len = block_len,
            };
        }

        var msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = iovecs.ptr,
            .iovlen = iovecs.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        _ = try ring.sendmsg(1, pair.sender_fd, &msg, 0);
        _ = try ring.submit_and_wait(1);
        const cqe = try ring.copy_cqe();
        if (cqe.res < 0) return error.SendmsgFailed;
        if (@as(usize, @intCast(cqe.res)) != total_len) return error.PartialSeedSendmsg;

        try readExact(pair.receiver_fd, recv_buf);
        checksum +%= std.hash.Wyhash.hash(0, recv_buf);
    }

    return makeResult("seed_sendmsg_burst", iterations, &timer, checksum, alloc_counter);
}

fn runSeedSpliceBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var ring = try IoUring.init(64, 0);
    defer ring.deinit();

    const pair = try createLoopbackTcpPair();
    defer posix.close(pair.listen_fd);
    defer posix.close(pair.sender_fd);
    defer posix.close(pair.receiver_fd);

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const block_count = @max(config.scale, 8);
    const block_len = 16 * 1024;
    const piece_len = block_count * block_len;
    const total_len = block_count * (13 + block_len);

    const piece_data = try allocator.alloc(u8, piece_len);
    defer allocator.free(piece_data);
    for (piece_data, 0..) |*byte, idx| byte.* = @truncate(idx *% 23 +% 9);

    var temp = try createTempSeedFile(piece_data);
    defer {
        temp.dir.close();
        temp.dir.deleteFile(temp.name) catch {};
        std.heap.page_allocator.free(temp.name);
    }
    defer temp.file.close();

    const recv_buf = try allocator.alloc(u8, total_len);
    defer allocator.free(recv_buf);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        for (0..block_count) |idx| {
            var header: [13]u8 = undefined;
            const msg_len: u32 = 1 + 8 + block_len;
            std.mem.writeInt(u32, header[0..4], msg_len, .big);
            header[4] = 7;
            std.mem.writeInt(u32, header[5..9], @intCast(iter & 0xffff), .big);
            std.mem.writeInt(u32, header[9..13], @intCast(idx * block_len), .big);

            _ = try ring.send(10, pair.sender_fd, header[0..], 0);
            _ = try ring.submit_and_wait(1);
            const header_cqe = try ring.copy_cqe();
            if (header_cqe.res < 0) return error.SpliceHeaderSendFailed;
            if (header_cqe.res != header.len) return error.PartialSpliceHeader;

            const file_offset = idx * block_len;
            _ = try ring.splice(11, temp.file.handle, file_offset, pipe_fds[1], std.math.maxInt(u64), block_len);
            _ = try ring.submit_and_wait(1);
            const in_cqe = try ring.copy_cqe();
            if (in_cqe.res < 0) return error.SpliceFileToPipeFailed;
            if (in_cqe.res != block_len) return error.PartialSpliceFileToPipe;

            _ = try ring.splice(12, pipe_fds[0], std.math.maxInt(u64), pair.sender_fd, std.math.maxInt(u64), block_len);
            _ = try ring.submit_and_wait(1);
            const out_cqe = try ring.copy_cqe();
            if (out_cqe.res < 0) return error.SplicePipeToSocketFailed;
            if (out_cqe.res != block_len) return error.PartialSplicePipeToSocket;
        }

        try readExact(pair.receiver_fd, recv_buf);
        checksum +%= std.hash.Wyhash.hash(0, recv_buf);
    }

    return makeResult("seed_splice_burst", iterations, &timer, checksum, alloc_counter);
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
        const header_len = rpc_server.responseHeaderLength(response, false);
        var header_inline: [rpc_server.response_header_inline_size]u8 = undefined;
        const header = if (header_len <= header_inline.len)
            try rpc_server.writeResponseHeader(header_inline[0..header_len], response, false)
        else blk: {
            const owned = try allocator.alloc(u8, header_len);
            defer allocator.free(owned);
            break :blk try rpc_server.writeResponseHeader(owned, response, false);
        };
        checksum +%= std.hash.Wyhash.hash(0, header);
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
        const decoded = try varuna.net.extensions.decodeExtensionHandshake(payload);
        checksum +%= decoded.extensions.ut_metadata;
        checksum +%= decoded.extensions.ut_pex;
        checksum +%= decoded.port;
        checksum +%= decoded.metadata_size;
        checksum +%= @intFromBool(decoded.upload_only);
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

const ApiBurstMode = enum {
    get,
    upload,
};

const ApiClientWork = struct {
    address: std.net.Address,
    requests: usize,
    body: []const u8,
    mode: ApiBurstMode,
    checksum: u64 = 0,
};

fn runApiBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
    mode: ApiBurstMode,
) !Result {
    var bench_io = try RealIO.init(.{ .entries = 64 });
    defer bench_io.deinit();
    var server = try rpc_server.ApiServer.init(allocator, &bench_io, "127.0.0.1", 0);
    defer server.deinit();

    server.setHandler(struct {
        fn handle(_: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
            _ = request;
            return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"ok\":true}",
            };
        }
    }.handle);

    const port = try getListenPort(server.listen_fd);
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    const client_threads = @max(@min(config.clients, 32), 1);
    const upload_body_len = if (mode == .upload) blk: {
        if (config.body_bytes != 0) break :blk config.body_bytes;
        break :blk 64 * 1024 * @max(config.scale, 1);
    } else 0;

    var upload_body: []u8 = &.{};
    if (upload_body_len > 0) {
        upload_body = try std.heap.page_allocator.alloc(u8, upload_body_len);
        for (upload_body, 0..) |*byte, idx| byte.* = @truncate(idx *% 31 +% 7);
    }
    defer if (upload_body_len > 0) std.heap.page_allocator.free(upload_body);

    const workers = try allocator.alloc(ApiClientWork, client_threads);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, client_threads);
    defer allocator.free(threads);

    const base_requests = iterations / client_threads;
    var remainder = iterations % client_threads;
    for (workers) |*worker| {
        worker.* = .{
            .address = address,
            .requests = base_requests + @intFromBool(remainder > 0),
            .body = upload_body,
            .mode = mode,
        };
        if (remainder > 0) remainder -= 1;
    }

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(api_server: *rpc_server.ApiServer) void {
            api_server.run() catch |err| std.debug.panic("api server benchmark thread failed: {}", .{err});
        }
    }.run, .{&server});
    defer {
        server.stop();
        wakeApiServer(address) catch {};
        server_thread.join();
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    alloc_counter.stats = .{};

    var timer = try std.time.Timer.start();
    for (threads, workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, apiClientWorker, .{worker});
    }

    var checksum: u64 = 0;
    for (threads, workers) |*thread, *worker| {
        thread.join();
        checksum +%= worker.checksum;
    }

    return makeResult(
        if (mode == .get) "api_get_burst" else "api_upload_burst",
        iterations,
        &timer,
        checksum,
        alloc_counter,
    );
}

const ApiSequentialWork = struct {
    address: std.net.Address,
    requests: usize,
    checksum: u64 = 0,
};

fn runApiSequentialGet(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var bench_io = try RealIO.init(.{ .entries = 64 });
    defer bench_io.deinit();
    var server = try rpc_server.ApiServer.init(allocator, &bench_io, "127.0.0.1", 0);
    defer server.deinit();

    server.setHandler(struct {
        fn handle(_: std.mem.Allocator, request: rpc_server.Request) rpc_server.Response {
            _ = request;
            return .{
                .status = 200,
                .content_type = "application/json",
                .body = "{\"ok\":true}",
            };
        }
    }.handle);

    const port = try getListenPort(server.listen_fd);
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    const client_threads = @max(@min(config.clients, 32), 1);

    const workers = try allocator.alloc(ApiSequentialWork, client_threads);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, client_threads);
    defer allocator.free(threads);

    const base_requests = iterations / client_threads;
    var remainder = iterations % client_threads;
    for (workers) |*worker| {
        worker.* = .{
            .address = address,
            .requests = base_requests + @intFromBool(remainder > 0),
        };
        if (remainder > 0) remainder -= 1;
    }

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(api_server: *rpc_server.ApiServer) void {
            api_server.run() catch |err| std.debug.panic("api sequential benchmark server failed: {}", .{err});
        }
    }.run, .{&server});
    defer {
        server.stop();
        wakeApiServer(address) catch {};
        server_thread.join();
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    alloc_counter.stats = .{};

    var timer = try std.time.Timer.start();
    for (threads, workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, apiSequentialClientWorker, .{worker});
    }

    var checksum: u64 = 0;
    for (threads, workers) |*thread, *worker| {
        thread.join();
        checksum +%= worker.checksum;
    }

    return makeResult("api_get_seq", iterations, &timer, checksum, alloc_counter);
}

fn apiClientWorker(work: *ApiClientWork) void {
    var response_buf: [4096]u8 = undefined;
    var header_buf: [256]u8 = undefined;
    var checksum: u64 = 0;

    for (0..work.requests) |_| {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch |err| {
            std.debug.panic("api benchmark client socket failed: {}", .{err});
        };
        defer posix.close(fd);

        posix.connect(fd, &work.address.any, work.address.getOsSockLen()) catch |err| {
            std.debug.panic("api benchmark client connect failed: {}", .{err});
        };

        switch (work.mode) {
            .get => writeAll(fd, "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") catch |err| {
                std.debug.panic("api benchmark GET write failed: {}", .{err});
            },
            .upload => {
                const header = std.fmt.bufPrint(
                    &header_buf,
                    "POST /api/v2/torrents/add HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    .{work.body.len},
                ) catch |err| {
                    std.debug.panic("api benchmark header build failed: {}", .{err});
                };
                writeAll(fd, header) catch |err| {
                    std.debug.panic("api benchmark upload header write failed: {}", .{err});
                };
                writeAll(fd, work.body) catch |err| {
                    std.debug.panic("api benchmark upload body write failed: {}", .{err});
                };
            },
        }

        const n = readUntilClose(fd, &response_buf) catch |err| {
            std.debug.panic("api benchmark response read failed: {}", .{err});
        };
        checksum +%= std.hash.Wyhash.hash(0, response_buf[0..n]);
    }

    work.checksum = checksum;
}

fn apiSequentialClientWorker(work: *ApiSequentialWork) void {
    var response_buf: [4096]u8 = undefined;
    var checksum: u64 = 0;
    var fd: posix.fd_t = -1;
    defer if (fd >= 0) posix.close(fd);

    const request_bytes = "GET /api/v2/app/webapiVersion HTTP/1.1\r\nHost: localhost\r\n\r\n";

    for (0..work.requests) |_| {
        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            if (fd < 0) {
                fd = connectLoopback(work.address) catch |err| {
                    std.debug.panic("api sequential benchmark connect failed: {}", .{err});
                };
            }

            writeAll(fd, request_bytes) catch |err| {
                if (fd >= 0) {
                    posix.close(fd);
                    fd = -1;
                }
                if (isRetryableSocketError(err) and attempts < 2) continue;
                std.debug.panic("api sequential benchmark write failed: {}", .{err});
            };

            const n = readOneHttpResponse(fd, &response_buf) catch |err| {
                if (fd >= 0) {
                    posix.close(fd);
                    fd = -1;
                }
                if ((isRetryableSocketError(err) or err == error.UnexpectedEndOfStream) and attempts < 2) continue;
                std.debug.panic("api sequential benchmark read failed: {}", .{err});
            };
            checksum +%= std.hash.Wyhash.hash(0, response_buf[0..n]);
            break;
        }
    }

    work.checksum = checksum;
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        written += try posix.write(fd, data[written..]);
    }
}

fn connectLoopback(address: std.net.Address) !posix.fd_t {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn readOneHttpResponse(fd: posix.fd_t, buffer: []u8) !usize {
    var total: usize = 0;
    var body_start: ?usize = null;
    var content_length: ?usize = null;

    while (total < buffer.len) {
        const n = try posix.read(fd, buffer[total..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        total += n;

        if (body_start == null) {
            if (http_mod.findBodyStart(buffer[0..total])) |start| {
                body_start = start;
                content_length = http_mod.parseContentLength(buffer[0..start]);
                if (content_length == null) return error.MissingContentLength;
            }
        }

        if (body_start) |start| {
            const expected = start + (content_length orelse return error.MissingContentLength);
            if (total >= expected) return expected;
        }
    }

    return error.ResponseTooLarge;
}

fn isRetryableSocketError(err: anyerror) bool {
    return err == error.BrokenPipe or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionAborted or
        err == error.NotOpenForWriting;
}

const TrackerHttpMode = enum {
    fresh,
    reuse_potential,
};

const TrackerServerState = struct {
    listen_fd: posix.fd_t,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

fn runTrackerHttpSeries(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    mode: TrackerHttpMode,
) !Result {
    const listen_fd = try createLoopbackListener();
    defer posix.close(listen_fd);

    const port = try getListenPort(listen_fd);
    var server_state = TrackerServerState{ .listen_fd = listen_fd };
    const server_thread = try std.Thread.spawn(.{}, trackerServerWorker, .{&server_state});
    defer {
        server_state.running.store(false, .release);
        wakeTrackerServer(port) catch {};
        server_thread.join();
    }

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{}/announce?info_hash=abc", .{port});
    defer allocator.free(url);

    std.Thread.sleep(10 * std.time.ns_per_ms);
    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    switch (mode) {
        .fresh => {
            var client = http_mod.HttpClient.init(allocator);
            for (0..iterations) |_| {
                var response = try client.get(url);
                checksum +%= response.status;
                checksum +%= std.hash.Wyhash.hash(0, response.body);
                response.deinit();
            }
        },
        .reuse_potential => {
            const address = try std.net.Address.parseIp4("127.0.0.1", port);
            const fd = try connectLoopback(address);
            defer posix.close(fd);

            const request = "GET /announce?info_hash=abc HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
            var response_buf: [4096]u8 = undefined;
            for (0..iterations) |_| {
                try writeAll(fd, request);
                const n = try readOneHttpResponse(fd, &response_buf);
                checksum +%= std.hash.Wyhash.hash(0, response_buf[0..n]);
            }
        },
    }

    return makeResult(
        if (mode == .fresh) "tracker_http_fresh" else "tracker_http_reuse_potential",
        iterations,
        &timer,
        checksum,
        alloc_counter,
    );
}

fn makeTrackerAnnounceRequest(allocator: std.mem.Allocator, port: u16) !tracker_announce.Request {
    return .{
        .announce_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{}/announce?info_hash=abc", .{port}),
        .info_hash = [_]u8{1} ** 20,
        .peer_id = [_]u8{2} ** 20,
        .port = 6881,
        .left = 0,
        .event = null,
    };
}

fn runTrackerAnnounceFresh(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
) !Result {
    const listen_fd = try createLoopbackListener();
    defer posix.close(listen_fd);

    const port = try getListenPort(listen_fd);
    var server_state = TrackerServerState{ .listen_fd = listen_fd };
    const server_thread = try std.Thread.spawn(.{}, trackerServerWorker, .{&server_state});
    defer {
        server_state.running.store(false, .release);
        wakeTrackerServer(port) catch {};
        server_thread.join();
    }

    const request = try makeTrackerAnnounceRequest(allocator, port);
    defer allocator.free(request.announce_url);

    std.Thread.sleep(10 * std.time.ns_per_ms);
    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        const response = try tracker_announce.fetchAuto(allocator, request);
        defer tracker_announce.freeResponse(allocator, response);
        checksum +%= response.interval;
        checksum +%= response.peers.len;
    }

    return makeResult("tracker_announce_fresh", iterations, &timer, checksum, alloc_counter);
}

const TrackerExecutorBenchState = struct {
    allocator: std.mem.Allocator,
    request: tracker_announce.Request,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    completed: usize = 0,
    failures: usize = 0,
    checksum: u64 = 0,
};

fn runTrackerAnnounceExecutor(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
) !Result {
    const listen_fd = try createLoopbackListener();
    defer posix.close(listen_fd);

    const port = try getListenPort(listen_fd);
    var server_state = TrackerServerState{ .listen_fd = listen_fd };
    const server_thread = try std.Thread.spawn(.{}, trackerServerWorker, .{&server_state});
    defer {
        server_state.running.store(false, .release);
        wakeTrackerServer(port) catch {};
        server_thread.join();
    }

    var perf_io = try RealIO.init(.{ .entries = 32 });
    defer perf_io.deinit();
    const executor = try TrackerExecutor.create(allocator, &perf_io, .{});
    defer executor.destroy();

    std.Thread.sleep(10 * std.time.ns_per_ms);

    var state = TrackerExecutorBenchState{
        .allocator = allocator,
        .request = try makeTrackerAnnounceRequest(allocator, port),
    };
    defer allocator.free(state.request.announce_url);

    const url = try tracker_announce.buildUrl(allocator, state.request);
    defer allocator.free(url);
    const parsed = try http_mod.parseUrl(url);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var job = TrackerExecutor.Job{
            .context = @ptrCast(&state),
            .on_complete = trackerExecutorBenchCallback,
            .url_len = @intCast(url.len),
            .host_len = @intCast(parsed.host.len),
        };
        @memcpy(job.url[0..url.len], url);
        @memcpy(job.host[0..parsed.host.len], parsed.host);
        try executor.submit(job);
    }

    state.mutex.lock();
    while (state.completed < iterations) {
        state.cond.wait(&state.mutex);
    }
    const checksum = state.checksum +% state.failures;
    state.mutex.unlock();

    return makeResult("tracker_announce_executor", iterations, &timer, checksum, alloc_counter);
}

fn trackerExecutorBenchCallback(context: *anyopaque, result: TrackerExecutor.RequestResult) void {
    const state: *TrackerExecutorBenchState = @ptrCast(@alignCast(context));

    if (result.body) |body| {
        if (tracker_announce.parseResponse(state.allocator, body)) |response| {
            defer tracker_announce.freeResponse(state.allocator, response);

            state.mutex.lock();
            state.completed += 1;
            state.checksum +%= response.interval;
            state.checksum +%= response.peers.len;
            state.cond.signal();
            state.mutex.unlock();
            return;
        } else |_| {}
    }

    state.mutex.lock();
    state.completed += 1;
    state.failures += 1;
    state.cond.signal();
    state.mutex.unlock();
}

fn createLoopbackListener() !posix.fd_t {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.TCP,
    );
    errdefer posix.close(fd);

    const enable: u32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try posix.bind(fd, &address.any, address.getOsSockLen());
    try posix.listen(fd, 4096);
    return fd;
}

fn readUntilClose(fd: posix.fd_t, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try posix.read(fd, buffer[total..]);
        if (n == 0) return total;
        total += n;
    }
    return error.ResponseTooLarge;
}

fn readExact(fd: posix.fd_t, buffer: []u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try posix.read(fd, buffer[total..]);
        if (n == 0) return error.UnexpectedEof;
        total += n;
    }
}

fn createStreamSocketPair() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SocketPairFailed;
    return fds;
}

fn createLoopbackTcpPair() !struct { sender_fd: posix.fd_t, receiver_fd: posix.fd_t, listen_fd: posix.fd_t } {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(listen_fd);

    const enable: u32 = 1;
    try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try posix.bind(listen_fd, &address.any, address.getOsSockLen());
    try posix.listen(listen_fd, 16);

    const port = try getListenPort(listen_fd);
    const remote = try std.net.Address.parseIp4("127.0.0.1", port);

    const receiver_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(receiver_fd);
    try posix.connect(receiver_fd, &remote.any, remote.getOsSockLen());

    var raw_addr: posix.sockaddr = undefined;
    var raw_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    const sender_fd = try posix.accept(listen_fd, &raw_addr, &raw_len, posix.SOCK.CLOEXEC);
    errdefer posix.close(sender_fd);

    var sock_buf: c_int = 1 << 20;
    posix.setsockopt(sender_fd, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&sock_buf)) catch {};
    posix.setsockopt(receiver_fd, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&sock_buf)) catch {};

    return .{
        .sender_fd = sender_fd,
        .receiver_fd = receiver_fd,
        .listen_fd = listen_fd,
    };
}

fn createTempSeedFile(bytes: []const u8) !struct {
    dir: std.fs.Dir,
    file: std.fs.File,
    name: []u8,
} {
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
    errdefer tmp_dir.close();

    const name = try std.fmt.allocPrint(std.heap.page_allocator, "varuna-seed-perf-{}-{}.bin", .{
        std.time.nanoTimestamp(),
        bytes.len,
    });
    errdefer std.heap.page_allocator.free(name);

    const file = try tmp_dir.createFile(name, .{ .read = true, .truncate = true });
    errdefer {
        tmp_dir.deleteFile(name) catch {};
        file.close();
    }
    try file.writeAll(bytes);

    return .{
        .dir = tmp_dir,
        .file = file,
        .name = name,
    };
}

fn getListenPort(fd: posix.fd_t) !u16 {
    var addr: posix.sockaddr = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(fd, &addr, &addr_len);
    return (std.net.Address{ .any = addr }).getPort();
}

fn wakeApiServer(address: std.net.Address) !void {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    posix.connect(fd, &address.any, address.getOsSockLen()) catch {};
}

fn drainPeerSendCompletions(event_loop: *EventLoop, slot: u16) !void {
    var cqes: [8]linux.io_uring_cqe = undefined;
    while (event_loop.peers[slot].send_pending or event_loop.pending_sends.items.len != 0) {
        _ = try event_loop.ring.submit_and_wait(1);
        const count = try event_loop.ring.copy_cqes(&cqes, 0);
        for (cqes[0..count]) |cqe| {
            const op = event_loop_mod.decodeUserData(cqe.user_data);
            if (op.op_type == .peer_send) {
                peer_handler.handleSend(event_loop, op.slot, cqe);
            }
        }
    }
}

fn createLoopbackUdpReceiver() !struct { fd: posix.fd_t, address: std.net.Address } {
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    );
    errdefer posix.close(fd);

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try posix.bind(fd, &address.any, address.getOsSockLen());

    var raw_addr: posix.sockaddr = undefined;
    var raw_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try posix.getsockname(fd, &raw_addr, &raw_len);

    return .{
        .fd = fd,
        .address = .{ .any = raw_addr },
    };
}

fn drainUtpSendCompletions(event_loop: *EventLoop) !void {
    // uTP send CQEs land on the io_interface ring after Stage 2 #12;
    // tick(1) drains them through the utpSendComplete callback.
    try event_loop.io.tick(1);
}

fn drainUdpReceiver(fd: posix.fd_t, buffer: []u8) !u64 {
    var checksum: u64 = 0;
    while (true) {
        const n = posix.recv(fd, buffer, posix.MSG.DONTWAIT) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (n == 0) break;
        checksum +%= std.hash.Wyhash.hash(0, buffer[0..n]);
    }
    return checksum;
}

fn trackerServerWorker(state: *TrackerServerState) void {
    var request_buf: [4096]u8 = undefined;
    var response_buf: [256]u8 = undefined;
    const body = "d8:intervali1800e5:peers0:e";

    while (state.running.load(.acquire)) {
        var addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const fd = posix.accept(state.listen_fd, &addr, &addr_len, posix.SOCK.CLOEXEC) catch {
            continue;
        };

        while (state.running.load(.acquire)) {
            const req_len = readOneHttpRequest(fd, &request_buf) catch break;
            const request = request_buf[0..req_len];
            const keep_alive = std.mem.indexOf(u8, request, "Connection: keep-alive") != null;
            const response = std.fmt.bufPrint(
                &response_buf,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: {s}\r\n\r\n{s}",
                .{ body.len, if (keep_alive) "keep-alive" else "close", body },
            ) catch break;
            writeAll(fd, response) catch break;
            if (!keep_alive) break;
        }

        posix.close(fd);
    }
}

fn readOneHttpRequest(fd: posix.fd_t, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try posix.read(fd, buffer[total..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        total += n;
        if (std.mem.indexOf(u8, buffer[0..total], "\r\n\r\n")) |end| {
            return end + 4;
        }
    }
    return error.RequestTooLarge;
}

fn wakeTrackerServer(port: u16) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    defer posix.close(fd);
    posix.connect(fd, &address.any, address.getOsSockLen()) catch {};
}

fn runMseResponderPrep(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    const hash_count = @max(config.torrents, 1);
    const source_hashes = try allocator.alloc([20]u8, hash_count);
    defer allocator.free(source_hashes);
    var lookup = std.AutoHashMap([20]u8, [20]u8).init(allocator);
    defer lookup.deinit();

    for (source_hashes, 0..) |*hash, idx| {
        for (hash, 0..) |*byte, byte_idx| {
            byte.* = @truncate((idx *% 17) +% (byte_idx *% 13) +% 11);
        }
        std.mem.writeInt(u64, hash[0..8], idx, .little);
        try lookup.put(mse_mod.hashReq2ForInfoHash(hash.*), hash.*);
    }

    const target_hash = source_hashes[hash_count / 2];
    const target_req2 = mse_mod.hashReq2ForInfoHash(target_hash);

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        const matched = mse_mod.matchKnownHashLookup(&lookup, target_req2) orelse return error.MatchFailed;
        checksum +%= std.hash.Wyhash.hash(0, &matched);
    }

    return makeResult("mse_responder_prep", iterations, &timer, checksum, alloc_counter);
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
            var iter = manager.sessions.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.*.state = if (entry.value_ptr.*.state == .downloading) .paused else .downloading;
            }
            manager.mutex.unlock();
        }

        const body = try sync_state.computeDelta(&manager, allocator, request_rid);
        checksum +%= std.hash.Wyhash.hash(0, body);
        allocator.free(body);
    }

    return makeResult("sync_delta", iterations, &timer, checksum, alloc_counter);
}

fn runSyncStatsLive(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var event_loop = try EventLoop.initBare(allocator, 0);
    defer event_loop.deinit();

    var manager = SessionManager.init(allocator);
    defer manager.deinit();
    manager.shared_event_loop = &event_loop;

    const torrent_count = @max(config.torrents, 1);
    const active_stride = @max(config.scale, 1);
    const peer_count = @max(config.peers, 1);
    const empty_fds = [_]std.posix.fd_t{};
    const active_torrent_budget = @max(torrent_count / active_stride, 1);

    try manager.category_store.create("bench", "/tmp/bench");
    try manager.tag_store.create("fast");

    var active_peer_count: usize = 0;

    for (0..torrent_count) |idx| {
        const torrent_bytes = try makeTorrentBytes(allocator, idx);
        defer allocator.free(torrent_bytes);

        const session = try allocator.create(TorrentSession);
        errdefer allocator.destroy(session);
        session.* = try TorrentSession.create(allocator, torrent_bytes, "/tmp/varuna-bench", null);
        errdefer session.deinit();
        session.shared_event_loop = &event_loop;

        if ((idx & 1) == 0) {
            session.category = try allocator.dupe(u8, "bench");
        }
        if ((idx & 3) == 0) {
            try session.tags.append(allocator, try allocator.dupe(u8, "fast"));
            session.rebuildTagsString();
        }
        session.state = if ((idx & 1) == 0) .seeding else .paused;

        manager.mutex.lock();
        manager.sessions.put(&session.info_hash_hex, session) catch |err| {
            manager.mutex.unlock();
            return err;
        };
        manager.mutex.unlock();

        const torrent_id = try event_loop.addTorrentContext(.{
            .shared_fds = empty_fds[0..],
            .info_hash = session.info_hash,
            .peer_id = session.peer_id,
            .session = null,
        });
        session.torrent_id_in_shared = torrent_id;

        if (idx % active_stride != 0) continue;

        const peers_this_torrent = @max(@divTrunc(peer_count, active_torrent_budget), 1);
        for (0..peers_this_torrent) |_| {
            if (active_peer_count >= event_loop.peers.len) break;
            const slot: u16 = @intCast(active_peer_count);
            const peer = &event_loop.peers[slot];
            peer.* = .{
                .state = .active_recv_header,
                .mode = .inbound,
                .torrent_id = torrent_id,
                .availability_known = true,
                .peer_choking = false,
                .extensions_supported = false,
                .bytes_downloaded_from = @as(u64, active_peer_count) * 1024,
                .bytes_uploaded_to = @as(u64, active_peer_count) * 512,
            };
            event_loop.active_peer_slots.append(allocator, slot) catch unreachable;
            event_loop.attachPeerToTorrent(torrent_id, slot);
            event_loop.accountTorrentBytes(torrent_id, peer.bytes_downloaded_from, peer.bytes_uploaded_to);
            active_peer_count += 1;
        }
    }

    const warm_stats = try manager.getAllStats(allocator);
    defer allocator.free(warm_stats);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |idx| {
        if (idx % 8 == 0) {
            manager.mutex.lock();
            var iter = manager.sessions.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.*.state = if (entry.value_ptr.*.state == .seeding) .paused else .seeding;
            }
            manager.mutex.unlock();
        }

        const stats = try manager.getAllStats(allocator);
        for (stats) |stat| {
            checksum +%= stat.bytes_downloaded;
            checksum +%= stat.bytes_uploaded;
            checksum +%= stat.peers_connected;
            checksum +%= stat.download_speed;
            checksum +%= stat.upload_speed;
        }
        allocator.free(stats);
    }

    return makeResult("sync_stats_live", iterations, &timer, checksum, alloc_counter);
}

fn runTickSparseTorrents(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    const empty_fds = [_]std.posix.fd_t{};
    const torrent_count = @max(config.torrents, 1);
    const active_stride = @max(config.scale, 1);
    const peer_count = @max(config.peers, 1);

    var complete = try Bitfield.init(allocator, 64);
    defer complete.deinit(allocator);
    for (0..32) |idx| complete.set(@intCast(idx)) catch {};

    var wanted = try Bitfield.init(allocator, 64);
    for (0..32) |idx| wanted.set(@intCast(idx)) catch {};

    var tracker = try PieceTracker.init(allocator, 64, 16 * 1024, 64 * 16 * 1024, &complete, 32 * 16 * 1024);
    defer tracker.deinit(allocator);
    tracker.setWanted(wanted);

    var seed: u32 = 1;
    var active_torrents: usize = 0;

    for (0..torrent_count) |idx| {
        var info_hash = [_]u8{0} ** 20;
        var peer_id = [_]u8{0} ** 20;
        std.mem.writeInt(u32, info_hash[0..4], @intCast(idx), .big);
        std.mem.writeInt(u32, peer_id[0..4], seed, .big);
        seed +%= 1;

        const torrent_id = try el.addTorrentContext(.{
            .shared_fds = empty_fds[0..],
            .info_hash = info_hash,
            .peer_id = peer_id,
            .piece_tracker = &tracker,
        });

        const tc = el.getTorrentContext(torrent_id).?;
        tc.upload_only = true;
        if (idx % active_stride == 0) {
            active_torrents += 1;
            tc.is_private = false;
            tc.pex_state = try allocator.create(pex_mod.TorrentPexState);
            tc.pex_state.?.* = .{};
        }
    }

    var active_peer_count: usize = 0;
    const active_torrent_limit = @min(active_torrents, torrent_count);

    for (0..active_torrent_limit) |tidx| {
        const torrent_id: varuna.io.event_loop.TorrentId = @intCast(tidx * active_stride);
        const peers_this_torrent = @max(@divTrunc(peer_count, active_torrent_limit), 1);

        for (0..peers_this_torrent) |_| {
            if (active_peer_count >= el.peers.len) break;
            const slot: u16 = @intCast(active_peer_count);
            const peer = &el.peers[slot];
            peer.* = .{
                .state = .active_recv_header,
                .mode = .inbound,
                .torrent_id = torrent_id,
                .availability_known = true,
                .peer_choking = false,
                .extensions_supported = false,
                .bytes_downloaded_from = @as(u64, active_peer_count) * 1024,
                .bytes_uploaded_to = @as(u64, active_peer_count) * 512,
            };
            el.active_peer_slots.append(allocator, slot) catch unreachable;
            el.attachPeerToTorrent(torrent_id, slot);
            active_peer_count += 1;
        }
    }

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |_| {
        peer_policy.checkPex(&el);
        peer_policy.checkPartialSeed(&el);
        checksum +%= el.active_torrent_ids.items.len;
        checksum +%= el.active_peer_slots.items.len;
    }

    return makeResult("tick_sparse_torrents", iterations, &timer, checksum, alloc_counter);
}

fn runPeerChurn(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var el = try EventLoop.initBare(allocator, 0);
    defer el.deinit();

    const peer_count = @min(@max(config.peers, 1), el.peers.len);
    const churn_count = @max(config.scale, 1);

    var idle_slots = try std.ArrayList(u16).initCapacity(allocator, peer_count);
    defer idle_slots.deinit(allocator);

    for (0..peer_count) |idx| {
        const slot: u16 = @intCast(idx);
        const peer = &el.peers[slot];
        peer.* = .{
            .state = .active_recv_header,
            .availability_known = true,
            .peer_choking = false,
            .torrent_id = 0,
        };
        idle_slots.appendAssumeCapacity(slot);
        el.markActivePeer(slot);
        el.markIdle(slot);
    }

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        const base = (iter * churn_count) % peer_count;
        for (0..churn_count) |step| {
            const slot = idle_slots.items[(base + step) % peer_count];
            el.unmarkIdle(slot);
            el.markIdle(slot);
            el.unmarkActivePeer(slot);
            el.markActivePeer(slot);
            checksum +%= slot;
        }
    }

    return makeResult("peer_churn", iterations, &timer, checksum, alloc_counter);
}

fn runUtpOutboundBurst(
    allocator: std.mem.Allocator,
    alloc_counter: *CountingAllocator,
    iterations: usize,
    config: Config,
) !Result {
    var event_loop = try EventLoop.initBare(allocator, 0);
    defer event_loop.deinit();

    const sender_fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
        posix.IPPROTO.UDP,
    );
    defer posix.close(sender_fd);

    const receiver = try createLoopbackUdpReceiver();
    defer posix.close(receiver.fd);

    event_loop.udp_fd = sender_fd;

    const packets_per_iter = @max(config.scale, 64);
    const payload_len = 1200;
    var payload: [payload_len]u8 = undefined;
    const recv_buf = try allocator.alloc(u8, payload_len);
    defer allocator.free(recv_buf);

    alloc_counter.stats = .{};
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;

    for (0..iterations) |iter| {
        for (0..packets_per_iter) |packet_idx| {
            for (&payload, 0..) |*byte, byte_idx| {
                byte.* = @truncate(iter +% packet_idx +% byte_idx);
            }
            utp_handler.utpSendPacket(&event_loop, &payload, receiver.address);
        }

        while (event_loop.utp_send_pending or event_loop.utp_send_queue.items.len != 0) {
            try drainUtpSendCompletions(&event_loop);
            checksum +%= try drainUdpReceiver(receiver.fd, recv_buf);
        }
        checksum +%= try drainUdpReceiver(receiver.fd, recv_buf);
    }

    return makeResult("utp_outbound_burst", iterations, &timer, checksum, alloc_counter);
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

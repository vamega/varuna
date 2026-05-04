const std = @import("std");
const Shell = @import("shell.zig");

const default_torrents = [_]TorrentSource{
    .{
        .name = "proxmox-backup-server-4.2-1",
        .source = "https://distrowatch.com/dwres/torrents/proxmox-backup-server_4.2-1.iso.torrent",
    },
    .{
        .name = "ubuntu-26.04-desktop",
        .source = "https://distrowatch.com/dwres/torrents/ubuntu-26.04-desktop-amd64.iso.torrent",
    },
    .{
        .name = "deepin-desktop-community-25.1.0",
        .source = "https://distrowatch.com/dwres/torrents/deepin-desktop-community-25.1.0-amd64.iso.torrent",
    },
};

const TorrentSource = struct {
    name: []const u8,
    source: []const u8,
};

const DaemonPorts = struct {
    peer: u16,
    api: u16,
};

const SwarmConfig = struct {
    backend: []const u8 = "io_uring",
    runtime_backend: []const u8 = "io_uring",
    transport: []const u8 = "tcp_and_utp",
    payload_bytes: u64 = 0,
    timeout_seconds: u64 = 60,
    work_dir: ?[]const u8 = null,
    port_base: u16 = 26000,
    skip_build: bool = false,
    zig_exe: []const u8 = "zig",
    build_extra_args: []const []const u8 = &.{},
};

const SwarmResult = struct {
    status: []const u8,
    work_dir: []const u8,
    elapsed_seconds: f64,
    transfer_seconds: f64,
    payload_bytes: u64,
};

const RealConfig = struct {
    transport: []const u8 = "tcp_and_utp",
    backend: []const u8 = "io_uring",
    runtime_backend: []const u8 = "io_uring",
    duration_seconds: u64 = 600,
    out_dir: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    api_port: u16 = 18080,
    peer_port: u16 = 16881,
    zig_exe: []const u8 = "zig",
    skip_build: bool = false,
    build_extra_args: []const []const u8 = &.{},
    torrents: []const TorrentSource = &default_torrents,
};

const TorrentSnapshot = struct {
    hash: []const u8 = "",
    name: []const u8 = "",
    progress: f64 = 0,
    downloaded: u64 = 0,
    total_size: u64 = 0,
    dl_speed: u64 = 0,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa_state.deinit();
        if (status != .ok) std.debug.panic("leaked memory in varuna-automation", .{});
    }
    const allocator = gpa_state.allocator();

    var shell = try Shell.init(allocator);
    defer shell.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "swarm")) {
        const config = try parseSwarmConfig(&shell, args[2..]);
        defer allocator.free(config.build_extra_args);
        const result = try runSwarm(&shell, config);
        std.debug.print(
            "swarm {s}: backend={s} payload_bytes={} transfer_seconds={d:.3} work_dir={s}\n",
            .{ result.status, config.runtime_backend, result.payload_bytes, result.transfer_seconds, result.work_dir },
        );
    } else if (std.mem.eql(u8, args[1], "backend-swarm")) {
        try runBackendSwarmMatrix(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "real-torrents")) {
        try runRealTorrents(&shell, args[2..]);
    } else {
        std.debug.print("unknown automation command: {s}\n", .{args[1]});
        printUsage();
        return error.InvalidArgument;
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: varuna-automation <command> [options]
        \\
        \\commands:
        \\  swarm          run one local tracker/seeder/downloader transfer
        \\  backend-swarm  run the local swarm transfer across IO backends
        \\  real-torrents  run a real-public-torrent Varuna performance sample
        \\
        \\real-torrents useful options:
        \\  --duration <seconds>      default 600
        \\  --torrent <name=url|path> add one torrent source; defaults to Proxmox, Ubuntu 26, Deepin
        \\  --transport <mode>        tcp_and_utp, tcp_only, or utp_only
        \\  --out-dir <path>          default perf/output/real-torrents-<timestamp>
        \\
    , .{});
}

fn parseSwarmConfig(shell: *Shell, args: []const []const u8) !SwarmConfig {
    var config = SwarmConfig{
        .backend = shell.envString("IO_BACKEND", "io_uring"),
        .runtime_backend = shell.envString("RUNTIME_IO_BACKEND", shell.envString("IO_BACKEND", "io_uring")),
        .transport = shell.envString("TRANSPORT_MODE", "tcp_and_utp"),
        .payload_bytes = try shell.envInt(u64, "PAYLOAD_BYTES", 0),
        .timeout_seconds = try shell.envInt(u64, "TIMEOUT", 60),
        .work_dir = shell.envOpt("WORK_DIR"),
        .port_base = try shell.envInt(u16, "PORT_BASE", 26000),
        .skip_build = std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1"),
        .zig_exe = shell.envString("ZIG_EXE", "zig"),
        .build_extra_args = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", "")),
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            i += 1;
            config.backend = args[i];
            config.runtime_backend = args[i];
        } else if (std.mem.eql(u8, args[i], "--runtime-backend")) {
            i += 1;
            config.runtime_backend = args[i];
        } else if (std.mem.eql(u8, args[i], "--transport")) {
            i += 1;
            config.transport = args[i];
        } else if (std.mem.eql(u8, args[i], "--payload-bytes")) {
            i += 1;
            config.payload_bytes = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            config.timeout_seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--work-dir")) {
            i += 1;
            config.work_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--port-base")) {
            i += 1;
            config.port_base = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--skip-build")) {
            config.skip_build = true;
        } else if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            config.zig_exe = args[i];
        } else {
            std.debug.print("unknown swarm option: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    try validateTransport(config.transport);
    return config;
}

fn runBackendSwarmMatrix(shell: *Shell, args: []const []const u8) !void {
    var mode = shell.envString("SWARM_MATRIX_MODE", "test");
    var backends_raw = shell.envString("BACKENDS", "io_uring epoll_posix epoll_mmap");
    var runs = try shell.envInt(u32, "RUNS", 1);
    var payload_bytes = try shell.envInt(u64, "PAYLOAD_BYTES", if (std.mem.eql(u8, mode, "perf")) 16 * 1024 * 1024 else 1024 * 1024);
    var timeout_seconds = try shell.envInt(u64, "TIMEOUT", if (std.mem.eql(u8, mode, "perf")) 180 else 90);
    var port_base = try shell.envInt(u16, "PORT_BASE", 26000);
    var out_dir = shell.envOpt("OUT_DIR");
    var zig_exe = shell.envString("ZIG_EXE", "zig");

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--mode")) {
            i += 1;
            mode = args[i];
        } else if (std.mem.eql(u8, args[i], "--backends")) {
            i += 1;
            backends_raw = args[i];
        } else if (std.mem.eql(u8, args[i], "--runs")) {
            i += 1;
            runs = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--payload-bytes")) {
            i += 1;
            payload_bytes = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            timeout_seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--out-dir")) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--port-base")) {
            i += 1;
            port_base = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            zig_exe = args[i];
        } else {
            std.debug.print("unknown backend-swarm option: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    if (!std.mem.eql(u8, mode, "test") and !std.mem.eql(u8, mode, "perf")) return error.InvalidArgument;
    if (runs == 0) return error.InvalidArgument;
    if (std.mem.eql(u8, mode, "test") and runs != 1) return error.InvalidArgument;

    const backends = try splitWords(shell.allocator, backends_raw);
    defer shell.allocator.free(backends);
    if (backends.len == 0) return error.InvalidArgument;

    const dir = out_dir orelse try shell.fmt(
        "perf/output/{s}-{d}",
        .{ if (std.mem.eql(u8, mode, "perf")) "backend-swarm-perf" else "backend-swarm", std.time.timestamp() },
    );
    try shell.makePath(dir);
    const summary_path = try shell.path(&.{ dir, "summary.tsv" });

    if (std.mem.eql(u8, mode, "perf")) {
        try shell.writeFile(summary_path, "run\tbackend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\tthroughput_mib_s\twork_dir\n");
    } else {
        try shell.writeFile(summary_path, "backend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\twork_dir\n");
    }

    var matrix_index: u16 = 0;
    var run: u32 = 1;
    while (run <= runs) : (run += 1) {
        for (backends) |backend| {
            const work_parent = if (std.mem.eql(u8, mode, "perf"))
                try shell.path(&.{ dir, try shell.fmt("run-{d}", .{run}), backend })
            else
                try shell.path(&.{ dir, backend });
            try shell.makePath(work_parent);
            const work_dir = try shell.path(&.{ work_parent, "work" });
            const current_port_base = port_base + @as(u16, @intCast(matrix_index * 10));
            matrix_index += 1;

            const config = SwarmConfig{
                .backend = backend,
                .runtime_backend = backend,
                .payload_bytes = payload_bytes,
                .timeout_seconds = timeout_seconds,
                .work_dir = work_dir,
                .port_base = current_port_base,
                .skip_build = false,
                .zig_exe = zig_exe,
                .build_extra_args = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", "")),
            };
            defer shell.allocator.free(config.build_extra_args);

            const result = try runSwarm(shell, config);
            const throughput = if (result.transfer_seconds > 0)
                @as(f64, @floatFromInt(result.payload_bytes)) / 1048576.0 / result.transfer_seconds
            else
                0;

            const line = if (std.mem.eql(u8, mode, "perf"))
                try shell.fmt("{d}\t{s}\t{s}\t{d:.3}\t{d:.3}\t{d}\t{d:.3}\t{s}\n", .{
                    run,
                    backend,
                    result.status,
                    result.elapsed_seconds,
                    result.transfer_seconds,
                    result.payload_bytes,
                    throughput,
                    result.work_dir,
                })
            else
                try shell.fmt("{s}\t{s}\t{d:.3}\t{d:.3}\t{d}\t{s}\n", .{
                    backend,
                    result.status,
                    result.elapsed_seconds,
                    result.transfer_seconds,
                    result.payload_bytes,
                    result.work_dir,
                });
            try shell.appendFile(summary_path, line);
        }
    }

    const summary = try std.fs.cwd().readFileAlloc(shell.allocator, summary_path, 1024 * 1024);
    defer shell.allocator.free(summary);
    std.debug.print("{s}", .{summary});
}

fn runSwarm(shell: *Shell, config: SwarmConfig) !SwarmResult {
    const start_seconds = Shell.nowSeconds();
    if (!config.skip_build) try buildForBackend(shell, config.zig_exe, config.backend, config.build_extra_args);

    const work_dir = config.work_dir orelse try shell.createTempDir("varuna-swarm");
    try shell.makePath(work_dir);
    const seed_root = try shell.path(&.{ work_dir, "seed-root" });
    const download_root = try shell.path(&.{ work_dir, "download-root" });
    const tracker_dir = try shell.path(&.{ work_dir, "tracker" });
    const seed_daemon_dir = try shell.path(&.{ work_dir, "seed-daemon" });
    const download_daemon_dir = try shell.path(&.{ work_dir, "download-daemon" });
    try shell.makePath(seed_root);
    try shell.makePath(download_root);
    try shell.makePath(tracker_dir);
    try shell.makePath(seed_daemon_dir);
    try shell.makePath(download_daemon_dir);

    const payload_path = try shell.path(&.{ seed_root, "fixture.bin" });
    const torrent_path = try shell.path(&.{ work_dir, "fixture.torrent" });
    const payload_size = try createPayload(payload_path, config.payload_bytes);

    const tracker_port = config.port_base;
    const seed_ports = DaemonPorts{ .peer = config.port_base + 1, .api = config.port_base + 2 };
    const download_ports = DaemonPorts{ .peer = config.port_base + 3, .api = config.port_base + 4 };

    const tracker_url = try shell.fmt("http://127.0.0.1:{d}/announce", .{tracker_port});
    try shell.exec(&.{
        try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }),
        "create",
        "-a",
        tracker_url,
        "-o",
        torrent_path,
        payload_path,
    }, .{});

    const inspect = try shell.execCapture(&.{
        try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }),
        "inspect",
        torrent_path,
    }, .{});
    defer inspect.deinit(shell.allocator);
    const info_hash = try parseInfoHash(shell, inspect.stdout);

    const tracker_conf = try writeTrackerConfig(shell, tracker_dir, tracker_port, info_hash);
    var tracker = try shell.spawnLogged(
        &.{ "opentracker", "-f", tracker_conf },
        tracker_dir,
        try shell.path(&.{ tracker_dir, "stdout.log" }),
        try shell.path(&.{ tracker_dir, "stderr.log" }),
    );
    defer tracker.stop();
    try shell.waitForTcp("127.0.0.1", tracker_port, 10_000);

    try writeDaemonConfig(shell, seed_daemon_dir, seed_root, config.runtime_backend, config.transport, seed_ports, false);
    try writeDaemonConfig(shell, download_daemon_dir, download_root, config.runtime_backend, config.transport, download_ports, false);

    var seed_daemon = try startDaemon(shell, seed_daemon_dir, "seed");
    defer seed_daemon.stop();
    try shell.waitForTcp("127.0.0.1", seed_ports.api, 20_000);
    const seed_sid = try apiLogin(shell, seed_ports.api);
    const encoded_seed_root = try urlEncode(shell, seed_root);
    try apiPostTorrent(shell, seed_ports.api, seed_sid, torrent_path, encoded_seed_root);
    try apiPostForm(shell, seed_ports.api, seed_sid, "/api/v2/torrents/recheck", try shell.fmt("hashes={s}", .{info_hash}));
    try waitForFirstTorrentComplete(shell, seed_ports.api, seed_sid, 30);

    var download_daemon = try startDaemon(shell, download_daemon_dir, "download");
    defer download_daemon.stop();
    try shell.waitForTcp("127.0.0.1", download_ports.api, 20_000);
    const download_sid = try apiLogin(shell, download_ports.api);
    const encoded_download_root = try urlEncode(shell, download_root);
    try apiPostTorrent(shell, download_ports.api, download_sid, torrent_path, encoded_download_root);

    const transfer_start = Shell.nowSeconds();
    var completed = false;
    var progress: f64 = 0;
    const deadline = std.time.timestamp() + @as(i64, @intCast(config.timeout_seconds));
    while (std.time.timestamp() < deadline) {
        const snapshots = try apiTorrentSnapshots(shell, download_ports.api, download_sid);
        defer freeSnapshots(shell.allocator, snapshots);
        if (snapshots.len > 0) {
            progress = snapshots[0].progress;
            if (progress >= 1.0) {
                completed = true;
                break;
            }
        }
        std.Thread.sleep(std.time.ns_per_s);
    }

    if (!completed) {
        std.debug.print("download timed out after {d}s at progress {d:.4}; work_dir={s}\n", .{
            config.timeout_seconds,
            progress,
            work_dir,
        });
        return error.Timeout;
    }

    const transfer_seconds = Shell.nowSeconds() - transfer_start;
    try shell.exec(&.{ "cmp", payload_path, try shell.path(&.{ download_root, "fixture.bin" }) }, .{});

    return .{
        .status = "pass",
        .work_dir = work_dir,
        .elapsed_seconds = Shell.nowSeconds() - start_seconds,
        .transfer_seconds = transfer_seconds,
        .payload_bytes = payload_size,
    };
}

fn waitForFirstTorrentComplete(shell: *Shell, port: u16, sid: []const u8, timeout_seconds: u64) !void {
    const deadline = std.time.timestamp() + @as(i64, @intCast(timeout_seconds));
    var progress: f64 = 0;
    while (std.time.timestamp() < deadline) {
        const snapshots = try apiTorrentSnapshots(shell, port, sid);
        defer freeSnapshots(shell.allocator, snapshots);
        if (snapshots.len > 0) {
            progress = snapshots[0].progress;
            if (progress >= 1.0) return;
        }
        std.Thread.sleep(std.time.ns_per_s);
    }
    std.debug.print("timed out waiting for seeder to become complete (progress={d:.4})\n", .{progress});
    return error.Timeout;
}

fn runRealTorrents(shell: *Shell, args: []const []const u8) !void {
    var config = RealConfig{
        .transport = shell.envString("TRANSPORT_MODE", "tcp_and_utp"),
        .backend = shell.envString("IO_BACKEND", "io_uring"),
        .runtime_backend = shell.envString("RUNTIME_IO_BACKEND", shell.envString("IO_BACKEND", "io_uring")),
        .duration_seconds = try shell.envInt(u64, "DURATION", 600),
        .out_dir = shell.envOpt("OUT_DIR"),
        .data_dir = shell.envOpt("DATA_DIR"),
        .api_port = try shell.envInt(u16, "API_PORT", 18080),
        .peer_port = try shell.envInt(u16, "PEER_PORT", 16881),
        .zig_exe = shell.envString("ZIG_EXE", "zig"),
        .skip_build = std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1"),
        .build_extra_args = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", "")),
    };
    defer shell.allocator.free(config.build_extra_args);

    var torrents = std.ArrayList(TorrentSource).empty;
    defer torrents.deinit(shell.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--duration")) {
            i += 1;
            config.duration_seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--transport")) {
            i += 1;
            config.transport = args[i];
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            i += 1;
            config.backend = args[i];
            config.runtime_backend = args[i];
        } else if (std.mem.eql(u8, args[i], "--runtime-backend")) {
            i += 1;
            config.runtime_backend = args[i];
        } else if (std.mem.eql(u8, args[i], "--out-dir")) {
            i += 1;
            config.out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--data-dir")) {
            i += 1;
            config.data_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--api-port")) {
            i += 1;
            config.api_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--peer-port")) {
            i += 1;
            config.peer_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--torrent")) {
            i += 1;
            try torrents.append(shell.allocator, try parseTorrentSource(shell, args[i]));
        } else if (std.mem.eql(u8, args[i], "--skip-build")) {
            config.skip_build = true;
        } else if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            config.zig_exe = args[i];
        } else {
            std.debug.print("unknown real-torrents option: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }
    try validateTransport(config.transport);
    if (torrents.items.len > 0) config.torrents = torrents.items;

    if (!config.skip_build) try buildForBackend(shell, config.zig_exe, config.backend, config.build_extra_args);

    const out_dir = config.out_dir orelse try shell.fmt("perf/output/real-torrents-{d}", .{std.time.timestamp()});
    const data_dir = config.data_dir orelse try shell.path(&.{ out_dir, "data" });
    const daemon_dir = try shell.path(&.{ out_dir, "daemon" });
    const torrent_dir = try shell.path(&.{ out_dir, "torrents" });
    try shell.makePath(out_dir);
    try shell.makePath(data_dir);
    try shell.makePath(daemon_dir);
    try shell.makePath(torrent_dir);

    const samples_path = try shell.path(&.{ out_dir, "samples.tsv" });
    const summary_path = try shell.path(&.{ out_dir, "summary.tsv" });
    try shell.writeFile(samples_path, "elapsed_seconds\thash\tname\tprogress\tdownloaded\tsize\tdl_speed\n");
    try shell.writeFile(summary_path, "hash\tname\tprogress\tdownloaded\tsize\telapsed_seconds\tavg_mib_s\n");

    try writeDaemonConfig(
        shell,
        daemon_dir,
        data_dir,
        config.runtime_backend,
        config.transport,
        .{ .peer = config.peer_port, .api = config.api_port },
        true,
    );

    var daemon = try startDaemon(shell, daemon_dir, "real-torrents");
    defer daemon.stop();
    try shell.waitForTcp("127.0.0.1", config.api_port, 20_000);
    const sid = try apiLogin(shell, config.api_port);
    const encoded_data_dir = try urlEncode(shell, data_dir);

    for (config.torrents) |torrent| {
        const torrent_path = try materializeTorrent(shell, torrent_dir, torrent);
        try apiPostTorrent(shell, config.api_port, sid, torrent_path, encoded_data_dir);
    }

    const start = Shell.nowSeconds();
    var final_snapshots: []TorrentSnapshot = &.{};
    defer freeSnapshots(shell.allocator, final_snapshots);
    while (Shell.nowSeconds() - start < @as(f64, @floatFromInt(config.duration_seconds))) {
        freeSnapshots(shell.allocator, final_snapshots);
        final_snapshots = try apiTorrentSnapshots(shell, config.api_port, sid);
        const elapsed = Shell.nowSeconds() - start;
        for (final_snapshots) |snapshot| {
            const line = try shell.fmt("{d:.3}\t{s}\t{s}\t{d:.6}\t{d}\t{d}\t{d}\n", .{
                elapsed,
                snapshot.hash,
                snapshot.name,
                snapshot.progress,
                snapshot.downloaded,
                snapshot.total_size,
                snapshot.dl_speed,
            });
            try shell.appendFile(samples_path, line);
        }
        if (allComplete(final_snapshots, config.torrents.len)) break;
        std.Thread.sleep(std.time.ns_per_s);
    }

    const elapsed = Shell.nowSeconds() - start;
    for (final_snapshots) |snapshot| {
        const avg = if (elapsed > 0) @as(f64, @floatFromInt(snapshot.downloaded)) / 1048576.0 / elapsed else 0;
        const line = try shell.fmt("{s}\t{s}\t{d:.6}\t{d}\t{d}\t{d:.3}\t{d:.3}\n", .{
            snapshot.hash,
            snapshot.name,
            snapshot.progress,
            snapshot.downloaded,
            snapshot.total_size,
            elapsed,
            avg,
        });
        try shell.appendFile(summary_path, line);
    }

    std.debug.print("real torrent run output: {s}\n", .{out_dir});
    const summary = try std.fs.cwd().readFileAlloc(shell.allocator, summary_path, 1024 * 1024);
    defer shell.allocator.free(summary);
    std.debug.print("{s}", .{summary});
}

fn buildForBackend(shell: *Shell, zig_exe: []const u8, backend: []const u8, extra_args: []const []const u8) !void {
    if (std.mem.eql(u8, backend, "io_uring")) {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(shell.allocator);
        try argv.appendSlice(shell.allocator, &.{ zig_exe, "build" });
        try argv.appendSlice(shell.allocator, extra_args);
        try shell.exec(argv.items, .{ .cwd = shell.root });
        return;
    }

    try buildForBackend(shell, zig_exe, "io_uring", extra_args);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(shell.allocator);
    try argv.appendSlice(shell.allocator, &.{ zig_exe, "build", try shell.fmt("-Dio={s}", .{backend}) });
    try argv.appendSlice(shell.allocator, extra_args);
    try shell.exec(argv.items, .{ .cwd = shell.root });
}

fn createPayload(path: []const u8, payload_bytes: u64) !u64 {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
    defer file.close();

    if (payload_bytes == 0) {
        const data = "hello from varuna swarm automation\n";
        try file.writeAll(data);
        return data.len;
    }

    try file.setEndPos(payload_bytes);
    const piece_length = autoPieceLength(payload_bytes);
    var offset: u64 = 0;
    const marker = [_]u8{1};
    while (offset < payload_bytes) : (offset += piece_length) {
        try file.pwriteAll(&marker, offset);
    }
    return payload_bytes;
}

fn autoPieceLength(total_size: u64) u64 {
    if (total_size == 0) return 256 * 1024;
    const target_pieces = 1500;
    const ideal = total_size / target_pieces;
    var piece_length: u64 = 16 * 1024;
    while (piece_length < 16 * 1024 * 1024 and piece_length < ideal) {
        piece_length *= 2;
    }
    return piece_length;
}

fn writeTrackerConfig(shell: *Shell, tracker_dir: []const u8, port: u16, info_hash: []const u8) ![]const u8 {
    const whitelist_path = try shell.path(&.{ tracker_dir, "whitelist.txt" });
    const config_path = try shell.path(&.{ tracker_dir, "opentracker.conf" });
    try shell.writeFile(whitelist_path, try shell.fmt("{s}\n", .{info_hash}));
    try shell.writeFile(config_path, try shell.fmt(
        \\listen.tcp 127.0.0.1:{d}
        \\tracker.rootdir {s}
        \\access.whitelist {s}
        \\
    , .{ port, tracker_dir, whitelist_path }));
    return config_path;
}

fn writeDaemonConfig(
    shell: *Shell,
    daemon_dir: []const u8,
    data_dir: []const u8,
    backend: []const u8,
    transport: []const u8,
    ports: DaemonPorts,
    public_mode: bool,
) !void {
    const config_path = try shell.path(&.{ daemon_dir, "varuna.toml" });
    try shell.writeFile(config_path, try shell.fmt(
        \\[daemon]
        \\io_backend = "{s}"
        \\api_port = {d}
        \\api_bind = "127.0.0.1"
        \\api_username = "admin"
        \\api_password = "adminadmin"
        \\
        \\[storage]
        \\data_dir = "{s}"
        \\resume_db = "{s}/resume.db"
        \\
        \\[network]
        \\port_min = {d}
        \\port_max = {d}
        \\dht = {s}
        \\pex = {s}
        \\disable_trackers = false
        \\encryption = "preferred"
        \\transport = "{s}"
        \\
    , .{
        backend,
        ports.api,
        data_dir,
        daemon_dir,
        ports.peer,
        ports.peer,
        if (public_mode) "true" else "false",
        if (public_mode) "true" else "false",
        transport,
    }));
}

fn startDaemon(shell: *Shell, daemon_dir: []const u8, label: []const u8) !Shell.ManagedProcess {
    return try shell.spawnLogged(
        &.{try shell.path(&.{ shell.root, "zig-out/bin/varuna" })},
        daemon_dir,
        try shell.path(&.{ daemon_dir, try shell.fmt("{s}.stdout.log", .{label}) }),
        try shell.path(&.{ daemon_dir, try shell.fmt("{s}.stderr.log", .{label}) }),
    );
}

fn parseInfoHash(shell: *Shell, inspect_output: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, inspect_output, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "info_hash=")) {
            return try shell.fmt("{s}", .{line["info_hash=".len..]});
        }
    }
    return error.MissingInfoHash;
}

fn apiLogin(shell: *Shell, port: u16) ![]const u8 {
    const url = try shell.fmt("http://127.0.0.1:{d}/api/v2/auth/login", .{port});
    const result = try shell.execCapture(&.{ "curl", "-s", "-c", "-", url, "-d", "username=admin&password=adminadmin" }, .{});
    defer result.deinit(shell.allocator);
    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "SID")) |_| {
            var fields = std.mem.tokenizeAny(u8, line, " \t\r\n");
            var last: ?[]const u8 = null;
            while (fields.next()) |field| last = field;
            if (last) |sid| return try shell.fmt("{s}", .{sid});
        }
    }
    return error.LoginFailed;
}

fn apiPostTorrent(shell: *Shell, port: u16, sid: []const u8, torrent_path: []const u8, encoded_save_path: []const u8) !void {
    const url = try shell.fmt("http://127.0.0.1:{d}/api/v2/torrents/add?savepath={s}", .{ port, encoded_save_path });
    const cookie = try shell.fmt("SID={s}", .{sid});
    const data_arg = try shell.fmt("@{s}", .{torrent_path});
    try shell.exec(&.{ "curl", "-s", "-b", cookie, url, "--data-binary", data_arg }, .{});
}

fn apiPostForm(shell: *Shell, port: u16, sid: []const u8, path: []const u8, body: []const u8) !void {
    const url = try shell.fmt("http://127.0.0.1:{d}{s}", .{ port, path });
    const cookie = try shell.fmt("SID={s}", .{sid});
    try shell.exec(&.{ "curl", "-s", "-b", cookie, url, "-d", body }, .{});
}

fn apiTorrentSnapshots(shell: *Shell, port: u16, sid: []const u8) ![]TorrentSnapshot {
    const url = try shell.fmt("http://127.0.0.1:{d}/api/v2/torrents/info", .{port});
    const cookie = try shell.fmt("SID={s}", .{sid});
    const result = try shell.execCapture(&.{ "curl", "-s", "-b", cookie, url }, .{});
    defer result.deinit(shell.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, shell.allocator, result.stdout, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.UnexpectedJson;

    const items = parsed.value.array.items;
    const snapshots = try shell.allocator.alloc(TorrentSnapshot, items.len);
    errdefer shell.allocator.free(snapshots);

    for (items, 0..) |item, idx| {
        var snapshot = TorrentSnapshot{};
        if (item == .object) {
            const object = item.object;
            snapshot.hash = try dupeJsonString(shell.allocator, object.get("hash"));
            snapshot.name = try dupeJsonString(shell.allocator, object.get("name"));
            snapshot.progress = jsonFloat(object.get("progress"));
            snapshot.downloaded = jsonU64(object.get("downloaded"));
            snapshot.total_size = jsonU64(object.get("size"));
            snapshot.dl_speed = jsonU64(object.get("dlspeed"));
        }
        snapshots[idx] = snapshot;
    }
    return snapshots;
}

fn dupeJsonString(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    if (value) |v| {
        if (v == .string) return try allocator.dupe(u8, v.string);
    }
    return "";
}

fn jsonFloat(value: ?std.json.Value) f64 {
    const v = value orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn jsonU64(value: ?std.json.Value) u64 {
    const v = value orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

fn materializeTorrent(shell: *Shell, torrent_dir: []const u8, source: TorrentSource) ![]const u8 {
    if (std.mem.startsWith(u8, source.source, "http://") or std.mem.startsWith(u8, source.source, "https://")) {
        const path = try shell.path(&.{ torrent_dir, try shell.fmt("{s}.torrent", .{source.name}) });
        try shell.exec(&.{ "curl", "-fsSL", "-o", path, source.source }, .{ .max_output_bytes = 1024 * 1024 });
        return path;
    }
    return source.source;
}

fn parseTorrentSource(shell: *Shell, raw: []const u8) !TorrentSource {
    if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
        return .{
            .name = try shell.fmt("{s}", .{raw[0..eq]}),
            .source = try shell.fmt("{s}", .{raw[eq + 1 ..]}),
        };
    }
    return .{
        .name = try shell.fmt("{s}", .{std.fs.path.stem(std.fs.path.basename(raw))}),
        .source = raw,
    };
}

fn allComplete(snapshots: []const TorrentSnapshot, expected_count: usize) bool {
    if (snapshots.len < expected_count) return false;
    for (snapshots) |snapshot| {
        if (snapshot.progress < 1.0) return false;
    }
    return true;
}

fn freeSnapshots(allocator: std.mem.Allocator, snapshots: []TorrentSnapshot) void {
    if (snapshots.len == 0) return;
    for (snapshots) |snapshot| {
        if (snapshot.hash.len > 0) allocator.free(snapshot.hash);
        if (snapshot.name.len > 0) allocator.free(snapshot.name);
    }
    allocator.free(snapshots);
}

fn splitWords(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (it.next()) |word| try list.append(allocator, word);
    return try list.toOwnedSlice(allocator);
}

fn validateTransport(transport: []const u8) !void {
    if (std.mem.eql(u8, transport, "tcp_and_utp") or
        std.mem.eql(u8, transport, "tcp_only") or
        std.mem.eql(u8, transport, "utp_only"))
    {
        return;
    }
    return error.InvalidTransport;
}

fn urlEncode(shell: *Shell, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(shell.arena.allocator());
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try out.append(shell.arena.allocator(), c);
        } else {
            try out.print(shell.arena.allocator(), "%{X:0>2}", .{c});
        }
    }
    return try out.toOwnedSlice(shell.arena.allocator());
}

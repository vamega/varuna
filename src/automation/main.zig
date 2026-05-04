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

const SwarmPorts = struct {
    tracker: u16,
    seed_peer: u16,
    seed_api: u16,
    download_peer: u16,
    download_api: u16,
};

const SwarmConfig = struct {
    backend: []const u8 = "io_uring",
    runtime_backend: []const u8 = "io_uring",
    transport: []const u8 = "tcp_and_utp",
    payload_bytes: u64 = 0,
    piece_length: ?u64 = null,
    timeout_seconds: u64 = 60,
    work_dir: ?[]const u8 = null,
    port_base: u16 = 26000,
    ports: SwarmPorts = deriveSwarmPorts(26000),
    skip_build: bool = false,
    strace_dir: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    build_extra_args: []const []const u8 = &.{},
};

const SwarmResult = struct {
    status: []const u8,
    work_dir: []const u8,
    elapsed_seconds: f64,
    transfer_seconds: f64,
    payload_bytes: u64,
    tracker_log: []const u8,
    seed_log: []const u8,
    download_log: []const u8,
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

const DockerConformanceConfig = struct {
    timeout_seconds: u64 = 180,
    poll_interval_seconds: u64 = 3,
    compose_file: ?[]const u8 = null,
    skip_build: bool = false,
    zig_exe: []const u8 = "zig",
};

const ConformanceReport = struct {
    shell: *Shell,
    tests: std.ArrayList([]const u8) = .empty,
    pass_count: usize = 0,
    fail_count: usize = 0,

    fn deinit(self: *ConformanceReport) void {
        self.tests.deinit(self.shell.allocator);
    }

    fn pass(self: *ConformanceReport, label: []const u8) !void {
        std.debug.print("[conformance] PASS: {s}\n", .{label});
        self.pass_count += 1;
        try self.tests.append(self.shell.allocator, try self.shell.fmt("PASS: {s}", .{label}));
    }

    fn fail(self: *ConformanceReport, label: []const u8) !void {
        std.debug.print("[conformance] FAIL: {s}\n", .{label});
        self.fail_count += 1;
        try self.tests.append(self.shell.allocator, try self.shell.fmt("FAIL: {s}", .{label}));
    }
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
            \\swarm demo succeeded
            \\backend: {s}
            \\transport_mode: {s}
            \\payload_bytes: {d}
            \\transfer_seconds: {d:.3}
            \\work dir: {s}
            \\tracker log: {s}
            \\seed log: {s}
            \\download log: {s}
            \\
        , .{
            config.runtime_backend,
            config.transport,
            result.payload_bytes,
            result.transfer_seconds,
            result.work_dir,
            result.tracker_log,
            result.seed_log,
            result.download_log,
        });
    } else if (std.mem.eql(u8, args[1], "backend-swarm")) {
        try runBackendSwarmMatrix(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "real-torrents")) {
        try runRealTorrents(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "tracker")) {
        try runTrackerCommand(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "setup-worktree")) {
        try runSetupWorktree(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "validate-strace")) {
        try runValidateStrace(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "large-transfer")) {
        try runLargeTransfer(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "daemon-swarm")) {
        try runDaemonSwarm(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "daemon-seed")) {
        try runDaemonSeed(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "web-seed")) {
        try runWebSeed(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "selective-download")) {
        try runSelectiveDownload(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "e2e-downloads")) {
        try runE2eDownloads(&shell, args[2..]);
    } else if (std.mem.eql(u8, args[1], "docker-conformance")) {
        try runDockerConformance(&shell, args[2..]);
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
        \\  tracker        run opentracker with an optional whitelist
        \\  setup-worktree prepare a git worktree for Varuna development
        \\  validate-strace validate strace -c output against daemon IO policy
        \\  large-transfer run daemon transfer stress cases
        \\  daemon-swarm   run tools-seeder to daemon-downloader smoke test
        \\  daemon-seed    verify daemon can serve after completing a download
        \\  web-seed       run the BEP 19 web seed integration scenarios
        \\  selective-download run selective file priority integration scenario
        \\  e2e-downloads  run public-torrent daemon e2e checks
        \\  docker-conformance run Docker qBittorrent cross-client tests
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
    const port_base = try shell.envInt(u16, "PORT_BASE", 26000);
    var config = SwarmConfig{
        .backend = shell.envString("IO_BACKEND", "io_uring"),
        .runtime_backend = shell.envString("RUNTIME_IO_BACKEND", shell.envString("IO_BACKEND", "io_uring")),
        .transport = normalizeTransport(shell.envString("TRANSPORT_MODE", "tcp_and_utp")),
        .payload_bytes = try shell.envInt(u64, "PAYLOAD_BYTES", 0),
        .piece_length = if (shell.envOpt("PIECE_LENGTH")) |raw| try std.fmt.parseInt(u64, raw, 10) else null,
        .timeout_seconds = try shell.envInt(u64, "TIMEOUT", 60),
        .work_dir = shell.envOpt("WORK_DIR"),
        .port_base = port_base,
        .ports = .{
            .tracker = try shell.envInt(u16, "TRACKER_PORT", port_base),
            .seed_peer = try shell.envInt(u16, "SEED_PORT", port_base + 1),
            .seed_api = try shell.envInt(u16, "SEED_API_PORT", port_base + 2),
            .download_peer = try shell.envInt(u16, "DOWNLOAD_PORT", port_base + 3),
            .download_api = try shell.envInt(u16, "DOWNLOAD_API_PORT", port_base + 4),
        },
        .skip_build = std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1"),
        .strace_dir = shell.envOpt("VARUNA_STRACE_DIR"),
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
            config.transport = normalizeTransport(args[i]);
        } else if (std.mem.eql(u8, args[i], "--payload-bytes")) {
            i += 1;
            config.payload_bytes = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--piece-length")) {
            i += 1;
            config.piece_length = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            config.timeout_seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--work-dir")) {
            i += 1;
            config.work_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--port-base")) {
            i += 1;
            config.port_base = try std.fmt.parseInt(u16, args[i], 10);
            config.ports = deriveSwarmPorts(config.port_base);
        } else if (std.mem.eql(u8, args[i], "--tracker-port")) {
            i += 1;
            config.ports.tracker = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--seed-port")) {
            i += 1;
            config.ports.seed_peer = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--seed-api-port")) {
            i += 1;
            config.ports.seed_api = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--download-port")) {
            i += 1;
            config.ports.download_peer = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--download-api-port")) {
            i += 1;
            config.ports.download_api = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--skip-build")) {
            config.skip_build = true;
        } else if (std.mem.eql(u8, args[i], "--strace-dir")) {
            i += 1;
            config.strace_dir = args[i];
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
        try shell.writeFile(summary_path, "run\tbackend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\tthroughput_mib_s\twork_dir\tlog\n");
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
            const run_log = try shell.path(&.{ work_parent, "run.log" });
            const current_port_base = port_base + @as(u16, @intCast(matrix_index * 10));
            matrix_index += 1;

            const config = SwarmConfig{
                .backend = backend,
                .runtime_backend = backend,
                .payload_bytes = payload_bytes,
                .timeout_seconds = timeout_seconds,
                .work_dir = work_dir,
                .port_base = current_port_base,
                .ports = deriveSwarmPorts(current_port_base),
                .skip_build = false,
                .zig_exe = zig_exe,
                .build_extra_args = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", "")),
            };
            defer shell.allocator.free(config.build_extra_args);

            try shell.writeFile(run_log, try shell.fmt(
                "backend={s}\nwork_dir={s}\nport_base={d}\n",
                .{ backend, work_dir, current_port_base },
            ));
            const result = try runSwarm(shell, config);
            try shell.appendFile(run_log, try shell.fmt(
                "status={s}\nelapsed_seconds={d:.3}\ntransfer_seconds={d:.3}\npayload_bytes={d}\ntracker_log={s}\nseed_log={s}\ndownload_log={s}\n",
                .{
                    result.status,
                    result.elapsed_seconds,
                    result.transfer_seconds,
                    result.payload_bytes,
                    result.tracker_log,
                    result.seed_log,
                    result.download_log,
                },
            ));
            const throughput = if (result.transfer_seconds > 0)
                @as(f64, @floatFromInt(result.payload_bytes)) / 1048576.0 / result.transfer_seconds
            else
                0;

            const line = if (std.mem.eql(u8, mode, "perf"))
                try shell.fmt("{d}\t{s}\t{s}\t{d:.3}\t{d:.3}\t{d}\t{d:.3}\t{s}\t{s}\n", .{
                    run,
                    backend,
                    result.status,
                    result.elapsed_seconds,
                    result.transfer_seconds,
                    result.payload_bytes,
                    throughput,
                    result.work_dir,
                    run_log,
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

    const tracker_port = config.ports.tracker;
    const seed_ports = DaemonPorts{ .peer = config.ports.seed_peer, .api = config.ports.seed_api };
    const download_ports = DaemonPorts{ .peer = config.ports.download_peer, .api = config.ports.download_api };

    const tracker_url = try shell.fmt("http://127.0.0.1:{d}/announce", .{tracker_port});
    try createTorrent(shell, payload_path, torrent_path, tracker_url, null, config.piece_length);

    const inspect = try shell.execCapture(&.{
        try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }),
        "inspect",
        torrent_path,
    }, .{});
    defer inspect.deinit(shell.allocator);
    const info_hash = try parseInfoHash(shell, inspect.stdout);

    const tracker_conf = try writeTrackerConfig(shell, tracker_dir, "127.0.0.1", tracker_port, &.{info_hash});
    const tracker_argv = try opentrackerArgv(shell, tracker_conf);
    var tracker = try shell.spawnLogged(
        tracker_argv,
        tracker_dir,
        try shell.path(&.{ tracker_dir, "stdout.log" }),
        try shell.path(&.{ tracker_dir, "stderr.log" }),
    );
    defer tracker.stop();
    try shell.waitForTcp("127.0.0.1", tracker_port, 10_000);

    try writeDaemonConfig(shell, seed_daemon_dir, seed_root, config.runtime_backend, config.transport, seed_ports, false);
    try writeDaemonConfig(shell, download_daemon_dir, download_root, config.runtime_backend, config.transport, download_ports, false);

    var seed_daemon = try startDaemon(shell, seed_daemon_dir, "seed", config.strace_dir);
    defer seed_daemon.stop();
    try shell.waitForTcp("127.0.0.1", seed_ports.api, 20_000);
    const seed_sid = try apiLogin(shell, seed_ports.api);
    const encoded_seed_root = try urlEncode(shell, seed_root);
    try apiPostTorrent(shell, seed_ports.api, seed_sid, torrent_path, encoded_seed_root);
    try apiPostForm(shell, seed_ports.api, seed_sid, "/api/v2/torrents/recheck", try shell.fmt("hashes={s}", .{info_hash}));
    try waitForFirstTorrentComplete(shell, seed_ports.api, seed_sid, 30);

    var download_daemon = try startDaemon(shell, download_daemon_dir, "download", config.strace_dir);
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
        try printTail(try shell.path(&.{ seed_daemon_dir, "seed.stderr.log" }), 20);
        try printTail(try shell.path(&.{ download_daemon_dir, "download.stderr.log" }), 20);
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
        .tracker_log = try shell.path(&.{ tracker_dir, "stderr.log" }),
        .seed_log = try shell.path(&.{ seed_daemon_dir, "seed.stderr.log" }),
        .download_log = try shell.path(&.{ download_daemon_dir, "download.stderr.log" }),
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

    var daemon = try startDaemon(shell, daemon_dir, "real-torrents", null);
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

fn createTorrent(
    shell: *Shell,
    input_path: []const u8,
    output_path: []const u8,
    tracker_url: []const u8,
    web_seed_url: ?[]const u8,
    piece_length: ?u64,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(shell.allocator);
    try argv.appendSlice(shell.allocator, &.{
        try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }),
        "create",
        "-a",
        tracker_url,
    });
    if (web_seed_url) |url| {
        try argv.appendSlice(shell.allocator, &.{ "-w", url });
    }
    if (piece_length) |len| {
        try argv.appendSlice(shell.allocator, &.{ "-l", try shell.fmt("{d}", .{len}) });
    }
    try argv.appendSlice(shell.allocator, &.{ "-o", output_path, input_path });
    try shell.exec(argv.items, .{});
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

fn writeTrackerConfig(
    shell: *Shell,
    tracker_dir: []const u8,
    host: []const u8,
    port: u16,
    info_hashes: []const []const u8,
) ![]const u8 {
    const whitelist_path = try shell.path(&.{ tracker_dir, "whitelist.txt" });
    const config_path = try shell.path(&.{ tracker_dir, "opentracker.conf" });
    var whitelist = std.ArrayList(u8).empty;
    defer whitelist.deinit(shell.allocator);
    for (info_hashes) |info_hash| {
        try whitelist.writer(shell.allocator).print("{s}\n", .{info_hash});
    }
    try shell.writeFile(whitelist_path, whitelist.items);
    const whitelist_line = if (info_hashes.len > 0)
        try shell.fmt("access.whitelist {s}\n", .{whitelist_path})
    else
        "";
    try shell.writeFile(config_path, try shell.fmt(
        \\listen.tcp {s}:{d}
        \\tracker.rootdir {s}
        \\{s}
        \\
    , .{ host, port, tracker_dir, whitelist_line }));
    return config_path;
}

fn opentrackerArgv(shell: *Shell, config_path: []const u8) ![]const []const u8 {
    const vendored_bin = try shell.path(&.{ shell.root, ".tools/opentracker/usr/bin/opentracker" });
    if (shell.fileExists(vendored_bin)) {
        const lib_path = try shell.path(&.{ shell.root, ".tools/opentracker/usr/lib" });
        const ld = if (shell.envOpt("LD_LIBRARY_PATH")) |existing|
            try shell.fmt("LD_LIBRARY_PATH={s}:{s}", .{ lib_path, existing })
        else
            try shell.fmt("LD_LIBRARY_PATH={s}", .{lib_path});
        return try shell.arena.allocator().dupe([]const u8, &.{ "env", ld, vendored_bin, "-f", config_path });
    }

    if (try findExecutable(shell, "opentracker")) |bin| {
        return try shell.arena.allocator().dupe([]const u8, &.{ bin, "-f", config_path });
    }

    try maybeStageDebianPackage(shell, "libowfat0t64");
    try maybeStageDebianPackage(shell, "opentracker");
    if (shell.fileExists(vendored_bin)) {
        const lib_path = try shell.path(&.{ shell.root, ".tools/opentracker/usr/lib" });
        const ld = if (shell.envOpt("LD_LIBRARY_PATH")) |existing|
            try shell.fmt("LD_LIBRARY_PATH={s}:{s}", .{ lib_path, existing })
        else
            try shell.fmt("LD_LIBRARY_PATH={s}", .{lib_path});
        return try shell.arena.allocator().dupe([]const u8, &.{ "env", ld, vendored_bin, "-f", config_path });
    }

    std.debug.print("opentracker not found; install via nix shell nixpkgs#opentracker or apt\n", .{});
    return error.MissingOpentracker;
}

fn maybeStageDebianPackage(shell: *Shell, package: []const u8) !void {
    if ((try findExecutable(shell, "apt-get")) == null or (try findExecutable(shell, "dpkg-deb")) == null) return;

    const tools_dir = try shell.path(&.{ shell.root, ".tools/opentracker" });
    const marker = try shell.path(&.{ tools_dir, try shell.fmt(".{s}.ready", .{package}) });
    if (shell.fileExists(marker)) return;

    try shell.makePath(tools_dir);
    const tmp = try shell.createTempDir("varuna-opentracker-deb");
    defer shell.removeTree(tmp);

    shell.exec(&.{ "apt-get", "download", package }, .{ .cwd = tmp }) catch return;

    var dir = try std.fs.cwd().openDir(tmp, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".deb")) continue;
        try shell.exec(&.{ "dpkg-deb", "-x", try shell.path(&.{ tmp, entry.name }), tools_dir }, .{});
    }
    try shell.writeFile(marker, "ready\n");
}

fn findExecutable(shell: *Shell, name: []const u8) !?[]const u8 {
    const path_env = shell.envOpt("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try shell.path(&.{ dir, name });
        std.fs.cwd().access(candidate, .{}) catch continue;
        return candidate;
    }
    return null;
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

fn startDaemon(shell: *Shell, daemon_dir: []const u8, label: []const u8, strace_dir: ?[]const u8) !Shell.ManagedProcess {
    const varuna_path = try shell.path(&.{ shell.root, "zig-out/bin/varuna" });
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(shell.allocator);
    if (strace_dir) |dir| {
        try shell.makePath(dir);
        try argv.appendSlice(shell.allocator, &.{
            "strace",
            "-f",
            "-qq",
            "-yy",
            "-e",
            "trace=io_uring_setup,io_uring_enter,io_uring_register,epoll_pwait,read,write,pread64,pwrite64,recvfrom,sendto,recvmsg,sendmsg,connect,accept4,futex",
            "-o",
            try shell.path(&.{ dir, try shell.fmt("{s}.trace", .{label}) }),
            varuna_path,
        });
    } else {
        try argv.append(shell.allocator, varuna_path);
    }

    return try shell.spawnLogged(
        argv.items,
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
    return try apiLoginHostRequired(shell, "127.0.0.1", port, "admin", "adminadmin");
}

fn apiLoginHostRequired(shell: *Shell, host: []const u8, port: u16, username: []const u8, password: []const u8) ![]const u8 {
    return (try apiLoginHost(shell, host, port, username, password)) orelse error.LoginFailed;
}

fn apiLoginHost(shell: *Shell, host: []const u8, port: u16, username: []const u8, password: []const u8) !?[]const u8 {
    const url = try shell.fmt("http://{s}:{d}/api/v2/auth/login", .{ host, port });
    const username_arg = try shell.fmt("username={s}", .{username});
    const password_arg = try shell.fmt("password={s}", .{password});
    const result = try shell.execCapture(&.{ "curl", "-s", "-c", "-", url, "--data-urlencode", username_arg, "--data-urlencode", password_arg }, .{});
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
    return null;
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

fn deriveSwarmPorts(port_base: u16) SwarmPorts {
    return .{
        .tracker = port_base,
        .seed_peer = port_base + 1,
        .seed_api = port_base + 2,
        .download_peer = port_base + 3,
        .download_api = port_base + 4,
    };
}

fn normalizeTransport(transport: []const u8) []const u8 {
    if (transport.len == 0 or std.mem.eql(u8, transport, "all")) return "tcp_and_utp";
    return transport;
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

fn printTail(path: []const u8, line_count: usize) !void {
    const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(bytes);

    var start: usize = bytes.len;
    var lines: usize = 0;
    while (start > 0 and lines < line_count) {
        start -= 1;
        if (bytes[start] == '\n') lines += 1;
    }
    if (start < bytes.len and bytes[start] == '\n') start += 1;
    std.debug.print("--- tail {s} ---\n{s}\n", .{ path, bytes[start..] });
}

fn runTrackerCommand(shell: *Shell, args: []const []const u8) !void {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 6969;
    var hashes = std.ArrayList([]const u8).empty;
    defer hashes.deinit(shell.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host")) {
            i += 1;
            host = args[i];
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--whitelist-hash")) {
            i += 1;
            try hashes.append(shell.allocator, args[i]);
        } else {
            std.debug.print("unexpected tracker argument: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    const runtime_dir = try shell.path(&.{ shell.root, ".tools/opentracker/runtime" });
    try shell.makePath(runtime_dir);
    const config_path = try writeTrackerConfig(shell, runtime_dir, host, port, hashes.items);
    const argv = try opentrackerArgv(shell, config_path);
    std.debug.print("HTTP tracker: http://{s}:{d}/announce\n", .{ host, port });
    if (hashes.items.len > 0) {
        std.debug.print("whitelist hashes: {d}\n", .{hashes.items.len});
    } else {
        std.debug.print("warning: no whitelist hashes configured; this opentracker build may reject announces\n", .{});
    }
    try shell.exec(argv, .{ .cwd = runtime_dir });
}

fn runSetupWorktree(shell: *Shell, args: []const []const u8) !void {
    if (args.len != 1) {
        std.debug.print("usage: varuna-automation setup-worktree <worktree-path>\n", .{});
        return error.InvalidArgument;
    }

    const worktree_abs = try std.fs.cwd().realpathAlloc(shell.arena.allocator(), args[0]);
    if (std.mem.eql(u8, worktree_abs, shell.root)) return error.RefusingMainCheckout;

    try shell.exec(&.{ "git", "submodule", "update", "--init", "--depth", "1", "vendor/boringssl", "vendor/c-ares" }, .{ .cwd = worktree_abs });

    const ref_path = try shell.path(&.{ worktree_abs, "reference-codebases" });
    if (pathExists(ref_path) and !isSymlink(ref_path)) shell.removeTree(ref_path);
    if (!isSymlink(ref_path)) try std.fs.cwd().symLink(try shell.path(&.{ shell.root, "reference-codebases" }), ref_path, .{});

    try shell.makePath(try shell.path(&.{ shell.root, ".zig-cache" }));
    const cache_path = try shell.path(&.{ worktree_abs, ".zig-cache" });
    if (isSymlink(cache_path)) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.cwd().readLink(cache_path, &buf) catch "";
        if (!std.mem.eql(u8, target, try shell.path(&.{ shell.root, ".zig-cache" }))) {
            try std.fs.cwd().deleteFile(cache_path);
        }
    } else if (pathExists(cache_path)) {
        shell.removeTree(cache_path);
    }
    if (!isSymlink(cache_path)) try std.fs.cwd().symLink(try shell.path(&.{ shell.root, ".zig-cache" }), cache_path, .{});

    const ls = try shell.execCapture(&.{ "git", "ls-files", "-s", "reference-codebases" }, .{ .cwd = worktree_abs });
    defer ls.deinit(shell.allocator);
    var gitlinks = std.ArrayList([]const u8).empty;
    defer gitlinks.deinit(shell.allocator);
    var lines = std.mem.splitScalar(u8, ls.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "160000 ")) continue;
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
            try gitlinks.append(shell.allocator, line[tab + 1 ..]);
        }
    }
    if (gitlinks.items.len > 0) {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(shell.allocator);
        try argv.appendSlice(shell.allocator, &.{ "git", "update-index", "--skip-worktree", "--" });
        try argv.appendSlice(shell.allocator, gitlinks.items);
        try shell.exec(argv.items, .{ .cwd = worktree_abs });
    }

    const exclude = try shell.execCapture(&.{ "git", "rev-parse", "--git-path", "info/exclude" }, .{ .cwd = worktree_abs });
    defer exclude.deinit(shell.allocator);
    const exclude_path = std.mem.trim(u8, exclude.stdout, " \t\r\n");
    try ensureParentDir(shell, exclude_path);
    try ensureFileContainsLine(shell, exclude_path, "/reference-codebases");
    try ensureFileContainsLine(shell, exclude_path, "/.zig-cache");

    std.debug.print("worktree ready: {s}\n", .{worktree_abs});
}

fn runValidateStrace(_: *Shell, args: []const []const u8) !void {
    if (args.len != 1) {
        std.debug.print("Usage: varuna-automation validate-strace <strace-summary-file>\n", .{});
        return error.InvalidArgument;
    }
    const bytes = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, args[0], 16 * 1024 * 1024);
    defer std.heap.page_allocator.free(bytes);

    const forbidden = [_][]const u8{ "connect", "send", "sendto", "sendmsg", "recv", "recvfrom", "recvmsg", "accept", "accept4" };
    var violations: usize = 0;
    var syscall_count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or std.mem.startsWith(u8, line, "%") or std.mem.startsWith(u8, line, "-") or std.mem.endsWith(u8, line, " total")) continue;
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        var fields: [8][]const u8 = undefined;
        var count: usize = 0;
        while (toks.next()) |tok| {
            if (count < fields.len) fields[count] = tok;
            count += 1;
        }
        if (count == 0) continue;
        const syscall = fields[@min(count, fields.len) - 1];
        syscall_count += 1;
        for (forbidden) |bad| {
            if (std.mem.eql(u8, syscall, bad)) {
                violations += 1;
                const calls = if (count >= 4) fields[3] else "?";
                std.debug.print("  - {s} ({s} calls)\n", .{ syscall, calls });
            }
        }
    }

    std.debug.print("=== io_uring Policy Validation ===\n\nStrace file: {s}\nSyscalls found: {d}\n\n", .{ args[0], syscall_count });
    if (violations == 0) {
        std.debug.print("PASS: No forbidden direct I/O syscalls detected.\n", .{});
    } else {
        std.debug.print("FAIL: Found {d} forbidden syscall(s) that should use io_uring.\n", .{violations});
        return error.IoPolicyViolation;
    }
}

fn runLargeTransfer(shell: *Shell, args: []const []const u8) !void {
    const skip_build = argsContain(args, "--skip-build") or std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1");
    if (!skip_build) {
        const extra = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", ""));
        defer shell.allocator.free(extra);
        try buildForBackend(shell, shell.envString("ZIG_EXE", "zig"), "io_uring", extra);
    }
    const work_dir = shell.envOpt("WORK_DIR") orelse try shell.createTempDir("varuna-stress");
    try shell.makePath(work_dir);
    const port_base = try shell.envInt(u16, "PORT_BASE", 40000);
    const timeout = try shell.envInt(u64, "TIMEOUT", 45);
    const tests = [_]struct { bytes: u64, piece: u64, label: []const u8 }{
        .{ .bytes = 1 * 1024 * 1024, .piece = 16 * 1024, .label = "1MB/16KB" },
        .{ .bytes = 1 * 1024 * 1024, .piece = 64 * 1024, .label = "1MB/64KB" },
        .{ .bytes = 5 * 1024 * 1024, .piece = 64 * 1024, .label = "5MB/64KB" },
        .{ .bytes = 5 * 1024 * 1024, .piece = 256 * 1024, .label = "5MB/256KB" },
    };

    var pass: usize = 0;
    for (tests, 0..) |case, idx| {
        std.debug.print("--- large-transfer {s} ---\n", .{case.label});
        const config = SwarmConfig{
            .payload_bytes = case.bytes,
            .piece_length = case.piece,
            .timeout_seconds = timeout,
            .work_dir = try shell.path(&.{ work_dir, try shell.fmt("case-{d}", .{idx + 1}) }),
            .port_base = @intCast(port_base + idx * 100),
            .ports = deriveSwarmPorts(@intCast(port_base + idx * 100)),
            .skip_build = true,
            .zig_exe = shell.envString("ZIG_EXE", "zig"),
            .build_extra_args = &.{},
        };
        _ = try runSwarm(shell, config);
        pass += 1;
    }
    std.debug.print("large-transfer passed: {d}/{d}; work dir: {s}\n", .{ pass, tests.len, work_dir });
}

fn runDaemonSwarm(shell: *Shell, args: []const []const u8) !void {
    var config = try parseSwarmConfig(shell, args);
    defer shell.allocator.free(config.build_extra_args);
    config.payload_bytes = if (config.payload_bytes == 0) 100 * 1024 else config.payload_bytes;
    config.timeout_seconds = if (config.timeout_seconds == 60) 30 else config.timeout_seconds;
    const result = try runSwarm(shell, config);
    std.debug.print("daemon swarm demo succeeded\nwork dir: {s}\ntracker log: {s}\nseed log: {s}\ndownload log: {s}\n", .{ result.work_dir, result.tracker_log, result.seed_log, result.download_log });
}

fn runDaemonSeed(shell: *Shell, args: []const []const u8) !void {
    const skip_build = argsContain(args, "--skip-build") or std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1");
    if (!skip_build) {
        const extra = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", ""));
        defer shell.allocator.free(extra);
        try buildForBackend(shell, shell.envString("ZIG_EXE", "zig"), "io_uring", extra);
    }
    const work_dir = shell.envOpt("WORK_DIR") orelse try shell.createTempDir("varuna-daemon-seed");
    try shell.makePath(work_dir);
    const tracker_port = try shell.envInt(u16, "TRACKER_PORT", 7090);
    const seed_port = try shell.envInt(u16, "SEED_PORT", 7091);
    const api_port = try shell.envInt(u16, "API_PORT", 8080);
    const daemon_peer_port = try shell.envInt(u16, "DAEMON_PEER_PORT", 7093);
    const dl2_port = try shell.envInt(u16, "DL2_PORT", 7094);
    const dl2_api_port = try shell.envInt(u16, "DL2_API_PORT", 7095);

    const seed_root = try shell.path(&.{ work_dir, "seed-root" });
    const daemon_download = try shell.path(&.{ work_dir, "daemon-download" });
    const dl2_root = try shell.path(&.{ work_dir, "dl2-root" });
    const seed_daemon_dir = try shell.path(&.{ work_dir, "seed-daemon" });
    const daemon_dir = try shell.path(&.{ work_dir, "daemon" });
    const dl2_daemon_dir = try shell.path(&.{ work_dir, "dl2-daemon" });
    try shell.makePath(seed_root);
    try shell.makePath(daemon_download);
    try shell.makePath(dl2_root);
    try shell.makePath(seed_daemon_dir);
    try shell.makePath(daemon_dir);
    try shell.makePath(dl2_daemon_dir);
    const payload = try shell.path(&.{ seed_root, "payload.bin" });
    try createPatternFile(payload, 50 * 1024);
    const torrent = try shell.path(&.{ work_dir, "test.torrent" });
    const tracker_url = try shell.fmt("http://127.0.0.1:{d}/announce", .{tracker_port});
    try createTorrent(shell, payload, torrent, tracker_url, null, null);
    const info_hash = try torrentInfoHash(shell, torrent);

    const tracker_dir = try shell.path(&.{ work_dir, "tracker" });
    try shell.makePath(tracker_dir);
    const tracker_conf = try writeTrackerConfig(shell, tracker_dir, "127.0.0.1", tracker_port, &.{info_hash});
    var tracker = try shell.spawnLogged(try opentrackerArgv(shell, tracker_conf), tracker_dir, try shell.path(&.{ tracker_dir, "stdout.log" }), try shell.path(&.{ tracker_dir, "stderr.log" }));
    defer tracker.stop();
    try shell.waitForTcp("127.0.0.1", tracker_port, 10_000);

    try writeDaemonConfig(shell, seed_daemon_dir, seed_root, "io_uring", "tcp_and_utp", .{ .peer = seed_port, .api = seed_port + 1 }, false);
    var seed_daemon = try startDaemon(shell, seed_daemon_dir, "seed", null);
    defer seed_daemon.stop();
    try shell.waitForTcp("127.0.0.1", seed_port + 1, 20_000);
    const seed_sid = try apiLogin(shell, seed_port + 1);
    try apiPostTorrent(shell, seed_port + 1, seed_sid, torrent, try urlEncode(shell, seed_root));
    try apiPostForm(shell, seed_port + 1, seed_sid, "/api/v2/torrents/recheck", try shell.fmt("hashes={s}", .{info_hash}));
    try waitForFirstTorrentComplete(shell, seed_port + 1, seed_sid, 30);

    try writeDaemonConfig(shell, daemon_dir, daemon_download, "io_uring", "tcp_and_utp", .{ .peer = daemon_peer_port, .api = api_port }, false);
    var daemon = try startDaemon(shell, daemon_dir, "daemon", null);
    defer daemon.stop();
    try shell.waitForTcp("127.0.0.1", api_port, 20_000);
    const sid = try apiLogin(shell, api_port);
    try apiPostTorrent(shell, api_port, sid, torrent, try urlEncode(shell, daemon_download));
    try waitForFirstTorrentComplete(shell, api_port, sid, 30);
    try shell.exec(&.{ "cmp", payload, try shell.path(&.{ daemon_download, "payload.bin" }) }, .{});

    seed_daemon.stop();
    try writeDaemonConfig(shell, dl2_daemon_dir, dl2_root, "io_uring", "tcp_and_utp", .{ .peer = dl2_port, .api = dl2_api_port }, false);
    var dl2 = try startDaemon(shell, dl2_daemon_dir, "dl2", null);
    defer dl2.stop();
    try shell.waitForTcp("127.0.0.1", dl2_api_port, 20_000);
    const dl2_sid = try apiLogin(shell, dl2_api_port);
    try apiPostTorrent(shell, dl2_api_port, dl2_sid, torrent, try urlEncode(shell, dl2_root));
    try waitForFirstTorrentComplete(shell, dl2_api_port, dl2_sid, 30);
    try shell.exec(&.{ "cmp", payload, try shell.path(&.{ dl2_root, "payload.bin" }) }, .{});
    std.debug.print("daemon seeding test PASSED\nwork dir: {s}\n", .{work_dir});
}

fn runWebSeed(shell: *Shell, args: []const []const u8) !void {
    const skip_build = argsContain(args, "--skip-build") or std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1");
    if (!skip_build) {
        const extra = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", ""));
        defer shell.allocator.free(extra);
        try buildForBackend(shell, shell.envString("ZIG_EXE", "zig"), "io_uring", extra);
    }

    const work_dir = shell.envOpt("WORK_DIR") orelse try shell.createTempDir("varuna-webseed");
    try shell.makePath(work_dir);
    const tracker_port = try shell.envInt(u16, "TRACKER_PORT", 7969);
    const web_seed_port = try shell.envInt(u16, "WEB_SEED_PORT", 7888);
    const api_port = try shell.envInt(u16, "API_PORT", 7082);
    const peer_port = try shell.envInt(u16, "PEER_PORT", 7882);

    const seed_files = try shell.path(&.{ work_dir, "seed-files" });
    const download_root = try shell.path(&.{ work_dir, "download-root" });
    const daemon_dir = try shell.path(&.{ work_dir, "daemon" });
    try shell.makePath(seed_files);
    try shell.makePath(download_root);
    try shell.makePath(daemon_dir);

    var web_seed = try shell.spawnLogged(
        &.{ "python3", try shell.path(&.{ shell.root, "scripts/web_seed_server.py" }), "--port", try shell.fmt("{d}", .{web_seed_port}), "--dir", seed_files, "--bind", "127.0.0.1" },
        shell.root,
        try shell.path(&.{ work_dir, "web-seed.log" }),
        try shell.path(&.{ work_dir, "web-seed.err" }),
    );
    defer web_seed.stop();
    try shell.waitForTcp("127.0.0.1", web_seed_port, 10_000);

    try shell.writeFile(try shell.path(&.{ daemon_dir, "varuna.toml" }), try shell.fmt(
        \\[daemon]
        \\api_port = {d}
        \\api_bind = "127.0.0.1"
        \\api_username = "admin"
        \\api_password = "adminadmin"
        \\
        \\[storage]
        \\data_dir = "{s}"
        \\resume_db = ":memory:"
        \\
        \\[network]
        \\port_min = {d}
        \\port_max = {d}
        \\dht = false
        \\pex = false
        \\encryption = "disabled"
        \\transport = "tcp_only"
        \\web_seed_max_request_bytes = 4194304
        \\
    , .{ api_port, download_root, peer_port, peer_port }));
    var daemon = try startDaemon(shell, daemon_dir, "web-seed", null);
    defer daemon.stop();
    try shell.waitForTcp("127.0.0.1", api_port, 20_000);
    const sid = try apiLogin(shell, api_port);

    const scenarios = [_]struct { name: []const u8, bytes: u64, max_request: u64 }{
        .{ .name = "scenario1.bin", .bytes = 1 * 1024 * 1024, .max_request = 8 * 1024 * 1024 },
        .{ .name = "scenario2.bin", .bytes = 4 * 1024 * 1024, .max_request = 1 * 1024 * 1024 },
        .{ .name = "scenario3.bin", .bytes = 8 * 1024 * 1024, .max_request = 512 * 1024 },
    };
    const tracker_url = try shell.fmt("http://127.0.0.1:{d}/announce", .{tracker_port});

    for (scenarios) |scenario| {
        try clearDir(download_root);
        const payload = try shell.path(&.{ seed_files, scenario.name });
        try createPatternFile(payload, scenario.bytes);
        const torrent = try shell.path(&.{ work_dir, try shell.fmt("{s}.torrent", .{std.fs.path.stem(scenario.name)}) });
        const web_seed_url = try shell.fmt("http://127.0.0.1:{d}/{s}", .{ web_seed_port, scenario.name });
        try createTorrent(shell, payload, torrent, tracker_url, web_seed_url, 262144);
        const info_hash = try torrentInfoHash(shell, torrent);
        const tracker_dir = try shell.path(&.{ work_dir, try shell.fmt("tracker-{s}", .{std.fs.path.stem(scenario.name)}) });
        try shell.makePath(tracker_dir);
        const tracker_conf = try writeTrackerConfig(shell, tracker_dir, "127.0.0.1", tracker_port, &.{info_hash});
        var tracker = try shell.spawnLogged(try opentrackerArgv(shell, tracker_conf), tracker_dir, try shell.path(&.{ tracker_dir, "stdout.log" }), try shell.path(&.{ tracker_dir, "stderr.log" }));
        defer tracker.stop();
        try shell.waitForTcp("127.0.0.1", tracker_port, 10_000);

        try apiPostForm(shell, api_port, sid, "/api/v2/app/setPreferences", try shell.fmt("json={{\"web_seed_max_request_bytes\":{d}}}", .{scenario.max_request}));
        shell.exec(&.{ "curl", "-s", try shell.fmt("http://127.0.0.1:{d}/_reset", .{web_seed_port}) }, .{}) catch {};
        try apiPostTorrent(shell, api_port, sid, torrent, try urlEncode(shell, download_root));
        try waitForFirstTorrentComplete(shell, api_port, sid, 120);
        try shell.exec(&.{ "cmp", payload, try shell.path(&.{ download_root, scenario.name }) }, .{});
        tracker.stop();
        try deleteAllTorrents(shell, api_port, sid);
    }
    std.debug.print("web seed scenarios PASSED\nwork dir: {s}\n", .{work_dir});
}

fn runSelectiveDownload(shell: *Shell, args: []const []const u8) !void {
    const skip_build = argsContain(args, "--skip-build") or std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1");
    if (!skip_build) {
        const extra = try splitWords(shell.allocator, shell.envString("ZIG_BUILD_EXTRA_ARGS", ""));
        defer shell.allocator.free(extra);
        try buildForBackend(shell, shell.envString("ZIG_EXE", "zig"), "io_uring", extra);
    }

    const work_dir = shell.envOpt("WORK_DIR") orelse try shell.createTempDir("varuna-selective");
    const tracker_port = try shell.envInt(u16, "TRACKER_PORT", 40100);
    const seed_port = try shell.envInt(u16, "SEED_PORT", 40101);
    const seed_api_port = try shell.envInt(u16, "SEED_API_PORT", 40104);
    const api_port = try shell.envInt(u16, "DAEMON_API_PORT", 40102);
    const peer_port = try shell.envInt(u16, "DAEMON_PEER_PORT", 40103);
    const payload_dir = try shell.path(&.{ work_dir, "seed-root/multitest" });
    const seed_daemon_dir = try shell.path(&.{ work_dir, "seed-daemon" });
    const daemon_dir = try shell.path(&.{ work_dir, "daemon" });
    const download_root = try shell.path(&.{ work_dir, "download-root" });
    try shell.makePath(payload_dir);
    try shell.makePath(seed_daemon_dir);
    try shell.makePath(daemon_dir);
    try shell.makePath(download_root);
    try createPatternFile(try shell.path(&.{ payload_dir, "file_small.bin" }), 50 * 1024);
    try createPatternFile(try shell.path(&.{ payload_dir, "file_medium.bin" }), 100 * 1024);
    try createPatternFile(try shell.path(&.{ payload_dir, "file_large.bin" }), 200 * 1024);

    const torrent = try shell.path(&.{ work_dir, "multitest.torrent" });
    const tracker_url = try shell.fmt("http://127.0.0.1:{d}/announce", .{tracker_port});
    try createTorrent(shell, payload_dir, torrent, tracker_url, null, 16384);
    const info_hash = try torrentInfoHash(shell, torrent);

    const tracker_dir = try shell.path(&.{ work_dir, "tracker" });
    try shell.makePath(tracker_dir);
    const tracker_conf = try writeTrackerConfig(shell, tracker_dir, "127.0.0.1", tracker_port, &.{info_hash});
    var tracker = try shell.spawnLogged(try opentrackerArgv(shell, tracker_conf), tracker_dir, try shell.path(&.{ tracker_dir, "stdout.log" }), try shell.path(&.{ tracker_dir, "stderr.log" }));
    defer tracker.stop();
    try shell.waitForTcp("127.0.0.1", tracker_port, 10_000);

    try writeDaemonConfig(shell, seed_daemon_dir, try shell.path(&.{ work_dir, "seed-root" }), "io_uring", "tcp_and_utp", .{ .peer = seed_port, .api = seed_api_port }, false);
    var seed_daemon = try startDaemon(shell, seed_daemon_dir, "seed", null);
    defer seed_daemon.stop();
    try shell.waitForTcp("127.0.0.1", seed_api_port, 20_000);
    const seed_sid = try apiLogin(shell, seed_api_port);
    try apiPostTorrent(shell, seed_api_port, seed_sid, torrent, try urlEncode(shell, try shell.path(&.{ work_dir, "seed-root" })));
    try apiPostForm(shell, seed_api_port, seed_sid, "/api/v2/torrents/recheck", try shell.fmt("hashes={s}", .{info_hash}));
    try waitForFirstTorrentComplete(shell, seed_api_port, seed_sid, 30);

    try writeDaemonConfig(shell, daemon_dir, download_root, "io_uring", "tcp_and_utp", .{ .peer = peer_port, .api = api_port }, false);
    var daemon = try startDaemon(shell, daemon_dir, "selective", null);
    defer daemon.stop();
    try shell.waitForTcp("127.0.0.1", api_port, 20_000);
    const sid = try apiLogin(shell, api_port);
    try apiPostTorrent(shell, api_port, sid, torrent, try urlEncode(shell, download_root));
    try apiPostForm(shell, api_port, sid, "/api/v2/torrents/filePrio", try shell.fmt("hash={s}&id=0|2&priority=0", .{info_hash}));
    const torrent_name = try torrentName(shell, torrent);
    try waitForFileEqual(
        try shell.path(&.{ payload_dir, "file_medium.bin" }),
        try shell.path(&.{ download_root, torrent_name, "file_medium.bin" }),
        120,
    );
    std.debug.print("selective file download test PASSED\nwork dir: {s}\n", .{work_dir});
}

fn runE2eDownloads(shell: *Shell, args: []const []const u8) !void {
    var filtered = std.ArrayList([]const u8).empty;
    defer filtered.deinit(shell.allocator);
    var skip_build = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--skip-build")) {
            skip_build = true;
        } else {
            try filtered.append(shell.allocator, arg);
        }
    }

    var real_args = std.ArrayList([]const u8).empty;
    defer real_args.deinit(shell.allocator);
    try real_args.appendSlice(shell.allocator, &.{ "--duration", shell.envString("DURATION", "600") });
    if (skip_build) try real_args.append(shell.allocator, "--skip-build");
    if (filtered.items.len >= 1 and std.mem.eql(u8, filtered.items[0], "single")) {
        if (filtered.items.len < 2) return error.InvalidArgument;
        try real_args.appendSlice(shell.allocator, &.{ "--torrent", filtered.items[1] });
    } else if (filtered.items.len >= 1 and std.mem.eql(u8, filtered.items[0], "multi")) {
        for (filtered.items[1..]) |path| try real_args.appendSlice(shell.allocator, &.{ "--torrent", path });
    } else if (filtered.items.len >= 1 and std.mem.eql(u8, filtered.items[0], "quick")) {
        try real_args.appendSlice(shell.allocator, &.{ "--torrent", try shell.path(&.{ shell.root, "testdata/torrents/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent" }) });
    } else {
        try real_args.appendSlice(shell.allocator, &.{
            "--torrent", try shell.path(&.{ shell.root, "testdata/torrents/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent" }),
            "--torrent", try shell.path(&.{ shell.root, "testdata/torrents/kali-linux-installer.torrent" }),
            "--torrent", try shell.path(&.{ shell.root, "testdata/torrents/debian-13.4.0-amd64-netinst.iso.torrent" }),
        });
    }
    try runRealTorrents(shell, real_args.items);
}

fn parseDockerConformanceConfig(shell: *Shell, args: []const []const u8) !DockerConformanceConfig {
    var config = DockerConformanceConfig{
        .timeout_seconds = try shell.envInt(u64, "TIMEOUT", 180),
        .compose_file = shell.envOpt("COMPOSE_FILE"),
        .skip_build = std.mem.eql(u8, shell.envString("SKIP_BUILD", "0"), "1"),
        .zig_exe = shell.envString("ZIG_EXE", "zig"),
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--timeout")) {
            i += 1;
            config.timeout_seconds = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--compose-file")) {
            i += 1;
            config.compose_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--skip-build")) {
            config.skip_build = true;
        } else if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            config.zig_exe = args[i];
        } else {
            std.debug.print("unknown docker-conformance option: {s}\n", .{args[i]});
            return error.InvalidArgument;
        }
    }

    return config;
}

fn runDockerConformance(shell: *Shell, args: []const []const u8) !void {
    const config = try parseDockerConformanceConfig(shell, args);
    const compose_file = config.compose_file orelse try shell.path(&.{ shell.root, "test/docker/docker-compose.yml" });
    var report = ConformanceReport{ .shell = shell };
    defer report.deinit();

    if (!config.skip_build) {
        std.debug.print("[conformance] building varuna\n", .{});
        try shell.exec(&.{ config.zig_exe, "build" }, .{});
    }

    std.debug.print("[conformance] starting Docker Compose services\n", .{});
    try shell.exec(&.{ "docker", "compose", "-f", compose_file, "build" }, .{});
    try shell.exec(&.{ "docker", "compose", "-f", compose_file, "up", "-d" }, .{});
    defer dockerComposeDown(shell, compose_file);

    try waitForComposeHealth(shell, compose_file, config.poll_interval_seconds);

    const torrent_file = try shell.fmt("/tmp/conformance-{d}.torrent", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(torrent_file) catch {};
    try shell.exec(&.{ "docker", "compose", "-f", compose_file, "cp", "setup:/shared/torrents/testfile.torrent", torrent_file }, .{});
    std.debug.print("[conformance] extracted torrent file to {s}\n", .{torrent_file});

    std.debug.print("[conformance] === Test A: qBittorrent -> varuna ===\n", .{});
    const qbt_seed_sid = qbtLogin(shell, compose_file, "127.0.0.1", 8080, "qbittorrent-seed") catch null;
    if (qbt_seed_sid) |sid| {
        try apiPostTorrentMultipart(shell, "127.0.0.1", 8080, sid, torrent_file, "/downloads");
        std.debug.print("[conformance] torrent added to qBittorrent seeder\n", .{});
        std.Thread.sleep(5 * std.time.ns_per_s);

        const varuna_dl_sid = apiLoginHostRequired(shell, "127.0.0.1", 8081, "admin", "adminadmin") catch null;
        if (varuna_dl_sid) |varuna_sid| {
            try apiPostTorrentMultipart(shell, "127.0.0.1", 8081, varuna_sid, torrent_file, "/data");
            std.debug.print("[conformance] torrent added to varuna downloader\n", .{});
            if (try waitForApiCompletion(shell, "varuna-download", 8081, varuna_sid, config.timeout_seconds, config.poll_interval_seconds)) {
                const orig_hash = try composeSha256(shell, compose_file, "qbittorrent-seed", "/downloads/testfile.bin");
                const dl_hash = try composeSha256(shell, compose_file, "varuna-download", "/data/testfile.bin");
                if (std.mem.eql(u8, orig_hash, dl_hash)) {
                    try report.pass("qBittorrent->varuna transfer + integrity");
                } else {
                    try report.fail(try shell.fmt("qBittorrent->varuna integrity (orig={s}, dl={s})", .{ orig_hash, dl_hash }));
                }
            } else {
                try report.fail("qBittorrent->varuna transfer timed out");
            }
        } else {
            try report.fail("varuna downloader login");
        }
    } else {
        try report.fail("qBittorrent seeder login");
    }

    std.debug.print("[conformance] === Test B: varuna -> qBittorrent ===\n", .{});
    const varuna_seed_sid = apiLoginHostRequired(shell, "127.0.0.1", 8082, "admin", "adminadmin") catch null;
    if (varuna_seed_sid) |sid| {
        try apiPostTorrentMultipart(shell, "127.0.0.1", 8082, sid, torrent_file, "/data");
        std.debug.print("[conformance] torrent added to varuna seeder\n", .{});
        std.Thread.sleep(5 * std.time.ns_per_s);

        const qbt_dl_sid = qbtLogin(shell, compose_file, "127.0.0.1", 8083, "qbittorrent-download") catch null;
        if (qbt_dl_sid) |qbt_sid| {
            try apiPostTorrentMultipart(shell, "127.0.0.1", 8083, qbt_sid, torrent_file, "/downloads");
            std.debug.print("[conformance] torrent added to qBittorrent downloader\n", .{});
            if (try waitForApiCompletion(shell, "qbittorrent-download", 8083, qbt_sid, config.timeout_seconds, config.poll_interval_seconds)) {
                const orig_hash = try composeSha256(shell, compose_file, "varuna-seed", "/data/testfile.bin");
                const dl_hash = try composeSha256(shell, compose_file, "qbittorrent-download", "/downloads/testfile.bin");
                if (std.mem.eql(u8, orig_hash, dl_hash)) {
                    try report.pass("varuna->qBittorrent transfer + integrity");
                } else {
                    try report.fail(try shell.fmt("varuna->qBittorrent integrity (orig={s}, dl={s})", .{ orig_hash, dl_hash }));
                }
            } else {
                try report.fail("varuna->qBittorrent transfer timed out");
            }
        } else {
            try report.fail("qBittorrent downloader login");
        }
    } else {
        try report.fail("varuna seeder login");
    }

    std.debug.print(
        \\[conformance]
        \\[conformance] ========================================
        \\[conformance]   Conformance Test Results
        \\[conformance] ========================================
        \\
    , .{});
    for (report.tests.items) |test_result| std.debug.print("[conformance]   {s}\n", .{test_result});
    std.debug.print(
        \\[conformance] ----------------------------------------
        \\[conformance]   Total: {d}  Pass: {d}  Fail: {d}
        \\[conformance] ========================================
        \\
    , .{ report.pass_count + report.fail_count, report.pass_count, report.fail_count });

    if (report.fail_count > 0) {
        dumpComposeLogs(shell, compose_file, "50");
        return error.CommandFailed;
    }

    std.debug.print("[conformance] all conformance tests passed\n", .{});
}

fn dockerComposeDown(shell: *Shell, compose_file: []const u8) void {
    std.debug.print("[conformance] cleaning up containers\n", .{});
    shell.exec(&.{ "docker", "compose", "-f", compose_file, "down", "-v", "--remove-orphans" }, .{}) catch {};
}

fn waitForComposeHealth(shell: *Shell, compose_file: []const u8, poll_interval_seconds: u64) !void {
    const services = [_][]const u8{ "qbittorrent-seed", "varuna-download", "varuna-seed", "qbittorrent-download" };
    const timeout_seconds: i64 = 120;
    const deadline = std.time.timestamp() + timeout_seconds;
    std.debug.print("[conformance] waiting for services to become healthy\n", .{});
    while (std.time.timestamp() < deadline) {
        var all_healthy = true;
        for (services) |service| {
            if (!try composeServiceHealthy(shell, compose_file, service)) {
                all_healthy = false;
                break;
            }
        }
        if (all_healthy) {
            std.debug.print("[conformance] all services healthy\n", .{});
            return;
        }
        std.Thread.sleep(poll_interval_seconds * std.time.ns_per_s);
    }

    std.debug.print("[conformance] services did not become healthy within {d}s\n", .{timeout_seconds});
    shell.exec(&.{ "docker", "compose", "-f", compose_file, "ps" }, .{}) catch {};
    dumpComposeLogs(shell, compose_file, "30");
    return error.Timeout;
}

fn composeServiceHealthy(shell: *Shell, compose_file: []const u8, service: []const u8) !bool {
    const result = shell.execCapture(&.{ "docker", "compose", "-f", compose_file, "ps", "--format", "json", service }, .{ .max_output_bytes = 1024 * 1024 }) catch return false;
    defer result.deinit(shell.allocator);
    return std.mem.indexOf(u8, result.stdout, "\"Health\":\"healthy\"") != null or
        std.mem.indexOf(u8, result.stdout, "\"Health\": \"healthy\"") != null;
}

fn qbtLogin(shell: *Shell, compose_file: []const u8, host: []const u8, port: u16, container_name: []const u8) ![]const u8 {
    if (try apiLoginHost(shell, host, port, "admin", "adminadmin")) |sid| return sid;

    const logs = try shell.execCapture(&.{ "docker", "compose", "-f", compose_file, "logs", container_name }, .{ .max_output_bytes = 8 * 1024 * 1024 });
    defer logs.deinit(shell.allocator);
    const temporary_password = parseQbtTemporaryPassword(shell, logs.stdout) orelse return error.LoginFailed;
    if (try apiLoginHost(shell, host, port, "admin", temporary_password)) |sid| return sid;
    return error.LoginFailed;
}

fn parseQbtTemporaryPassword(shell: *Shell, logs: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, logs, '\n');
    while (lines.next()) |line| {
        const password_pos = std.mem.indexOf(u8, line, "temporary password") orelse continue;
        const after_phrase = line[password_pos..];
        const colon_pos = std.mem.indexOfScalar(u8, after_phrase, ':') orelse continue;
        const tail = std.mem.trim(u8, after_phrase[colon_pos + 1 ..], " \t\r\n");
        var fields = std.mem.tokenizeAny(u8, tail, " \t\r\n");
        if (fields.next()) |password| found = password;
    }
    if (found) |password| return shell.fmt("{s}", .{password}) catch null;
    return null;
}

fn apiPostTorrentMultipart(shell: *Shell, host: []const u8, port: u16, sid: []const u8, torrent_path: []const u8, save_path: []const u8) !void {
    const url = try shell.fmt("http://{s}:{d}/api/v2/torrents/add", .{ host, port });
    const cookie = try shell.fmt("SID={s}", .{sid});
    const torrent_form = try shell.fmt("torrents=@{s}", .{torrent_path});
    const save_form = try shell.fmt("savepath={s}", .{save_path});
    try shell.exec(&.{ "curl", "-s", "-b", cookie, url, "-F", torrent_form, "-F", save_form }, .{});
}

fn waitForApiCompletion(shell: *Shell, label: []const u8, port: u16, sid: []const u8, timeout_seconds: u64, poll_interval_seconds: u64) !bool {
    const deadline = std.time.timestamp() + @as(i64, @intCast(timeout_seconds));
    std.debug.print("[conformance] waiting for {s} to complete (timeout: {d}s)\n", .{ label, timeout_seconds });
    var last_progress: f64 = -1;
    while (std.time.timestamp() < deadline) {
        const snapshots = apiTorrentSnapshots(shell, port, sid) catch {
            std.Thread.sleep(poll_interval_seconds * std.time.ns_per_s);
            continue;
        };
        defer freeSnapshots(shell.allocator, snapshots);
        if (snapshots.len > 0) {
            last_progress = snapshots[0].progress;
            if (snapshots[0].progress >= 1.0) {
                std.debug.print("[conformance] {s} complete (progress={d:.3})\n", .{ label, snapshots[0].progress });
                return true;
            }
        }
        std.Thread.sleep(poll_interval_seconds * std.time.ns_per_s);
    }
    if (last_progress >= 0) {
        std.debug.print("[conformance] {s} timed out after {d}s (progress={d:.3})\n", .{ label, timeout_seconds, last_progress });
    } else {
        std.debug.print("[conformance] {s} timed out after {d}s (progress=unknown)\n", .{ label, timeout_seconds });
    }
    return false;
}

fn composeSha256(shell: *Shell, compose_file: []const u8, service: []const u8, path: []const u8) ![]const u8 {
    const result = try shell.execCapture(&.{ "docker", "compose", "-f", compose_file, "exec", "-T", service, "sha256sum", path }, .{ .max_output_bytes = 1024 * 1024 });
    defer result.deinit(shell.allocator);
    var fields = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    return try shell.fmt("{s}", .{fields.next() orelse return error.UnexpectedOutput});
}

fn dumpComposeLogs(shell: *Shell, compose_file: []const u8, tail: []const u8) void {
    const result = shell.execCapture(&.{ "docker", "compose", "-f", compose_file, "logs", "--tail", tail }, .{ .max_output_bytes = 16 * 1024 * 1024 }) catch return;
    defer result.deinit(shell.allocator);
    if (result.stdout.len > 0) std.debug.print("{s}\n", .{result.stdout});
    if (result.stderr.len > 0) std.debug.print("{s}\n", .{result.stderr});
}

fn createPatternFile(path: []const u8, bytes: u64) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [8192]u8 = undefined;
    var seed: u8 = 17;
    var remaining = bytes;
    while (remaining > 0) {
        for (&buf) |*b| {
            seed = seed *% 131 +% 29;
            b.* = seed;
        }
        const n: usize = @intCast(@min(remaining, buf.len));
        try file.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn torrentInfoHash(shell: *Shell, torrent_path: []const u8) ![]const u8 {
    const inspect = try shell.execCapture(&.{ try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }), "inspect", torrent_path }, .{});
    defer inspect.deinit(shell.allocator);
    return try parseInfoHash(shell, inspect.stdout);
}

fn torrentName(shell: *Shell, torrent_path: []const u8) ![]const u8 {
    const inspect = try shell.execCapture(&.{ try shell.path(&.{ shell.root, "zig-out/bin/varuna-tools" }), "inspect", torrent_path }, .{});
    defer inspect.deinit(shell.allocator);
    var it = std.mem.splitScalar(u8, inspect.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "name=")) return try shell.fmt("{s}", .{line["name=".len..]});
    }
    return error.MissingTorrentName;
}

fn waitForFileText(path: []const u8, needle: []const u8, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        const bytes = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer std.heap.page_allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn waitForFileEqual(expected_path: []const u8, actual_path: []const u8, timeout_seconds: u64) !void {
    const expected = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, expected_path, 64 * 1024 * 1024);
    defer std.heap.page_allocator.free(expected);
    const deadline = std.time.timestamp() + @as(i64, @intCast(timeout_seconds));
    while (std.time.timestamp() < deadline) {
        const actual = std.fs.cwd().readFileAlloc(std.heap.page_allocator, actual_path, 64 * 1024 * 1024) catch {
            std.Thread.sleep(std.time.ns_per_s);
            continue;
        };
        defer std.heap.page_allocator.free(actual);
        if (std.mem.eql(u8, expected, actual)) return;
        std.Thread.sleep(std.time.ns_per_s);
    }
    return error.Timeout;
}

fn deleteAllTorrents(shell: *Shell, port: u16, sid: []const u8) !void {
    const snapshots = try apiTorrentSnapshots(shell, port, sid);
    defer freeSnapshots(shell.allocator, snapshots);
    for (snapshots) |snapshot| {
        try apiPostForm(shell, port, sid, "/api/v2/torrents/delete", try shell.fmt("hashes={s}&deleteFiles=true", .{snapshot.hash}));
    }
}

fn clearDir(path: []const u8) !void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        try dir.deleteTree(entry.name);
    }
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.cwd().readLink(path, &buf) catch return false;
    return true;
}

fn ensureParentDir(shell: *Shell, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try shell.makePath(parent);
}

fn ensureFileContainsLine(shell: *Shell, path: []const u8, line: []const u8) !void {
    const existing_or_empty = std.fs.cwd().readFileAlloc(shell.allocator, path, 1024 * 1024) catch null;
    defer if (existing_or_empty) |existing| shell.allocator.free(existing);
    if (existing_or_empty) |existing| {
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |existing_line| {
            if (std.mem.eql(u8, std.mem.trim(u8, existing_line, "\r"), line)) return;
        }
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(try shell.fmt("\n# varuna-automation setup-worktree\n{s}\n", .{line}));
}

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
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

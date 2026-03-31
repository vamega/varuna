const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    varuna.io.signal.installHandlers();
    const cfg = varuna.config.loadDefault(allocator);

    // Check for --help
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.print("varuna: BitTorrent daemon with io_uring and qBittorrent-compatible API\n\n", .{});
            try stdout.print("usage: varuna [--help]\n\n", .{});
            try stdout.print("Config: varuna.toml or ~/.config/varuna/config.toml\n", .{});
            try stdout.print("API: http://{s}:{}\n\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
            try stdout.print("Use varuna-ctl to control the daemon.\n", .{});
            try stdout.print("Use varuna-tools for standalone operations.\n", .{});
            try stdout.flush();
            return;
        }
    }

    // Banner
    try stdout.print("varuna daemon starting\n", .{});
    try varuna.app.writeStartupBanner(stdout);
    try stdout.flush();

    // Shared event loop for all torrents (single-threaded I/O)
    var shared_el = varuna.io.event_loop.EventLoop.initBare(allocator, cfg.performance.hasher_threads) catch |err| {
        try stdout.print("failed to create event loop: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return err;
    };
    defer shared_el.deinit();

    // Resolve resume DB path (config override or default XDG location)
    var resume_db_buf: [1024]u8 = undefined;
    const resume_db_path: ?[*:0]const u8 = blk: {
        if (cfg.storage.resume_db) |p| {
            const z = std.fmt.bufPrintZ(&resume_db_buf, "{s}", .{p}) catch break :blk null;
            _ = z;
            break :blk @ptrCast(&resume_db_buf);
        }
        // Default: ~/.local/share/varuna/resume.db
        const home = std.posix.getenv("HOME") orelse break :blk null;
        const z = std.fmt.bufPrintZ(&resume_db_buf, "{s}/.local/share/varuna/resume.db", .{home}) catch break :blk null;
        _ = z;
        // Ensure parent directory exists (e.g. ~/.local/share/varuna/)
        const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(&resume_db_buf)));
        const dir_end = std.mem.lastIndexOfScalar(u8, path_str, '/') orelse break :blk null;
        std.fs.makeDirAbsolute(resume_db_buf[0..dir_end]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => break :blk null,
        };
        break :blk @ptrCast(&resume_db_buf);
    };

    // Apply bind configuration to event loop for outbound peer sockets
    shared_el.bind_device = cfg.network.bind_device;
    shared_el.bind_address = cfg.network.bind_address;

    // Apply connection limits from config
    shared_el.max_connections = cfg.network.max_connections;
    shared_el.max_peers_per_torrent = cfg.network.max_peers_per_torrent;
    shared_el.max_half_open = cfg.network.max_half_open;

    // Apply global speed limits from config
    if (cfg.network.dl_limit > 0) shared_el.setGlobalDlLimit(cfg.network.dl_limit);
    if (cfg.network.ul_limit > 0) shared_el.setGlobalUlLimit(cfg.network.ul_limit);

    // Session manager
    var session_manager = varuna.daemon.session_manager.SessionManager.init(allocator);
    session_manager.shared_event_loop = &shared_el;
    session_manager.port = cfg.network.port_min;
    session_manager.max_peers = cfg.network.max_peers;
    session_manager.hasher_threads = cfg.performance.hasher_threads;
    session_manager.resume_db_path = resume_db_path;
    if (cfg.storage.data_dir) |dir| session_manager.default_save_path = dir;
    // Load persisted categories and tags from the resume DB
    session_manager.loadCategoriesAndTags();
    defer session_manager.deinit();

    // API handler
    var api_handler = varuna.rpc.handlers.ApiHandler{
        .session_manager = &session_manager,
        .sync_state = varuna.rpc.sync.SyncState.init(allocator),
        .api_username = cfg.daemon.api_username,
        .api_password = cfg.daemon.api_password,
    };
    defer api_handler.sync_state.deinit();

    // HTTP API server (all I/O via io_uring)
    // Check for systemd socket activation first
    const systemd_fds = varuna.daemon.systemd.listenFds();
    var socket_activated = false;
    var api_server = if (systemd_fds) |fds| blk: {
        // Use the first inherited fd as the API listen socket.
        // If systemd passes multiple sockets, the first one on api_port
        // is preferred; otherwise just use fd 3.
        var api_fd = fds[0];
        for (fds) |fd| {
            if (varuna.daemon.systemd.isListenSocketOnPort(fd, cfg.daemon.api_port)) {
                api_fd = fd;
                break;
            }
        }
        socket_activated = true;
        break :blk varuna.rpc.server.ApiServer.initWithFd(allocator, api_fd) catch |err| {
            try stdout.print("failed to init API server with socket activation: {s}\n", .{@errorName(err)});
            try stdout.flush();
            return err;
        };
    } else varuna.rpc.server.ApiServer.initWithDevice(allocator, cfg.daemon.api_bind, cfg.daemon.api_port, cfg.network.bind_device) catch |err| {
        try stdout.print("failed to start API server: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return err;
    };
    defer api_server.deinit();

    // Set handler via a closure-like wrapper
    // Since we can't capture api_handler in a fn pointer, we use a global
    api_handler_global = &api_handler;
    api_server.setHandler(globalApiHandler);

    if (socket_activated) {
        try stdout.print("api: socket-activated (fd inherited from systemd)\n", .{});
    } else {
        try stdout.print("api: http://{s}:{}\n", .{ cfg.daemon.api_bind, cfg.daemon.api_port });
    }
    try stdout.print("ready (Ctrl-C to stop)\n", .{});
    try stdout.flush();

    varuna.daemon.systemd.notifyReady();

    // Submit initial accept
    api_server.submitAccept() catch {};

    // Submit timeout for shared event loop
    shared_el.submitTimeout(100 * std.time.ns_per_ms) catch {};

    // Listen socket for accepting inbound peer connections (created once, shared across torrents)
    // If systemd provided multiple fds, try to use a second one as the peer listen socket.
    var listen_fd: std.posix.fd_t = -1;
    var peer_socket_activated = false;
    if (systemd_fds) |fds| {
        if (fds.len > 1) {
            // Second fd is the peer listen socket
            for (fds[1..]) |fd| {
                listen_fd = fd;
                peer_socket_activated = true;
                break;
            }
        }
    }
    defer if (listen_fd >= 0 and !peer_socket_activated) std.posix.close(listen_fd);

    // Main loop: tick shared event loop + poll API server
    var resume_tick_counter: u32 = 0;
    while (!varuna.io.signal.isShutdownRequested()) {
        // Poll API server (non-blocking)
        _ = api_server.poll() catch {};

        // Check if any sessions need to be integrated into the event loop
        // (background recheck thread completed, peers ready)
        // Skip if already at global connection limit
        {
            session_manager.mutex.lock();
            var iter = session_manager.sessions.iterator();
            while (iter.next()) |entry| {
                const sess = entry.value_ptr.*;
                if (sess.pending_peers != null) {
                    if (shared_el.peer_count < shared_el.max_connections) {
                        _ = sess.integrateIntoEventLoop();
                    }
                }
            }
            session_manager.mutex.unlock();
        }

        // Check if any sessions need seed mode setup (completed download or 100% recheck)
        {
            session_manager.mutex.lock();
            var iter = session_manager.sessions.iterator();
            while (iter.next()) |entry| {
                const sess = entry.value_ptr.*;

                // Check for download-to-seed transition
                _ = sess.checkSeedTransition();

                // Set up seed mode if flagged by background thread or transition
                if (sess.pending_seed_setup) {
                    if (sess.integrateSeedIntoEventLoop()) {
                        // Create listen socket once for the first seeding torrent
                        if (listen_fd < 0) {
                            if (createListenSocket(cfg.network)) |result| {
                                listen_fd = result.fd;
                                // Update the port used for tracker announces to the actual bound port
                                session_manager.port = result.port;
                                shared_el.ensureAccepting(listen_fd) catch {};
                            } else |_| {}
                        }
                    }
                }
            }
            session_manager.mutex.unlock();
        }

        // Periodically persist completed pieces to resume DB (~every 5s at 100ms tick)
        // and trigger tracker scrapes for swarm health stats.
        resume_tick_counter +%= 1;
        if (resume_tick_counter % 50 == 0) {
            session_manager.mutex.lock();
            var iter = session_manager.sessions.iterator();
            while (iter.next()) |entry| {
                const sess = entry.value_ptr.*;
                if (sess.state == .downloading or sess.state == .seeding) {
                    sess.persistNewCompletions();
                    sess.flushResume();
                    sess.maybeScrape();
                }
            }
            session_manager.mutex.unlock();
        }

        // Tick shared event loop (non-blocking poll)
        if (shared_el.peer_count > 0 or shared_el.listen_fd >= 0) {
            // Has active peers or accepting connections -- use tick which calls submit_and_wait
            shared_el.submitTimeout(100 * std.time.ns_per_ms) catch {};
            shared_el.tick() catch {};
        } else {
            // No active peers -- just sleep to avoid busy-spinning
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    varuna.daemon.systemd.notifyStopping();
    try stdout.print("\nshutting down...\n", .{});
    try stdout.flush();
}

/// Create a non-blocking listen socket for accepting inbound peer connections.
/// Tries each port in [port_min, port_max] until one succeeds.
/// Returns the fd and the actual bound port.
/// Uses standard socket creation (one-time setup, not on the hot path --
/// io_uring handles the accept calls).
fn createListenSocket(
    net_cfg: varuna.config.Config.Network,
) !struct { fd: std.posix.fd_t, port: u16 } {
    const socket_util = varuna.net.socket;

    if (net_cfg.port_min > net_cfg.port_max) return error.InvalidPortRange;

    var port = net_cfg.port_min;
    while (port <= net_cfg.port_max) : (port += 1) {
        const bind_addr_str = net_cfg.bind_address orelse "0.0.0.0";
        const addr = std.net.Address.parseIp4(bind_addr_str, port) catch
            std.net.Address.parseIp6(bind_addr_str, port) catch
            return error.InvalidBindAddress;

        const fd = std.posix.socket(
            addr.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.TCP,
        ) catch continue;
        errdefer std.posix.close(fd);

        // Allow address reuse
        const one: u32 = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};

        // Apply SO_BINDTODEVICE if configured
        if (net_cfg.bind_device) |device| {
            socket_util.applyBindDevice(fd, device) catch |err| {
                std.posix.close(fd);
                return err;
            };
        }

        std.posix.bind(fd, &addr.any, addr.getOsSockLen()) catch {
            std.posix.close(fd);
            continue;
        };
        std.posix.listen(fd, 128) catch {
            std.posix.close(fd);
            continue;
        };
        return .{ .fd = fd, .port = port };
    }
    return error.AddressInUse;
}

// Global state for handler dispatch (Zig fn pointers can't capture state)
var api_handler_global: ?*varuna.rpc.handlers.ApiHandler = null;

fn globalApiHandler(allocator: std.mem.Allocator, request: varuna.rpc.server.Request) varuna.rpc.server.Response {
    if (api_handler_global) |handler| {
        return handler.handle(allocator, request);
    }
    return .{ .status = 500, .body = "{\"error\":\"handler not initialized\"}" };
}

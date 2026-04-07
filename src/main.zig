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
    var loaded_cfg = varuna.config.loadDefault(allocator);
    defer loaded_cfg.deinit();
    const cfg = loaded_cfg.value;

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

    // Apply MSE/PE encryption mode from config
    shared_el.encryption_mode = varuna.config.parseEncryptionMode(cfg.network.encryption);

    // Apply connection limits from config
    shared_el.max_connections = cfg.network.max_connections;
    shared_el.max_peers_per_torrent = cfg.network.max_peers_per_torrent;
    shared_el.max_half_open = cfg.network.max_half_open;

    // Apply global speed limits from config
    if (cfg.network.dl_limit > 0) shared_el.setGlobalDlLimit(cfg.network.dl_limit);
    if (cfg.network.ul_limit > 0) shared_el.setGlobalUlLimit(cfg.network.ul_limit);

    // Initialize the reusable piece cache. A zero size means the default 64 MB.
    shared_el.initHugePageCache(cfg.performance.piece_cache_size);

    // Initialize DHT engine (BEP 5). Runs on the shared UDP socket alongside uTP.
    // DhtEngine.create() heap-allocates and initializes via explicit field assignment
    // to avoid placing the ~900 KB struct on main()'s stack.
    shared_el.port = cfg.network.port_min;
    shared_el.pex_enabled = cfg.network.pex;
    shared_el.utp_enabled = cfg.network.enable_utp;

    // Initialize DHT persistence — separate DB file so it can be blown away
    // independently from torrent resume state.
    var dht_persist: ?varuna.dht.persistence.DhtPersistence = null;
    defer if (dht_persist) |*dp| dp.deinit();

    const sqlite = @import("varuna").storage.sqlite3;
    var dht_db: ?*sqlite.Db = null;
    {
        // DHT DB lives alongside the resume DB: ~/.local/share/varuna/dht.db
        var dht_db_buf: [1024]u8 = undefined;
        const dht_db_path: ?[*:0]const u8 = blk: {
            const home = std.posix.getenv("HOME") orelse break :blk null;
            const z = std.fmt.bufPrintZ(&dht_db_buf, "{s}/.local/share/varuna/dht.db", .{home}) catch break :blk null;
            _ = z;
            std.fs.makeDirAbsolute(dht_db_buf[0 .. std.mem.lastIndexOfScalar(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&dht_db_buf))), '/') orelse 0]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => break :blk null,
            };
            break :blk @ptrCast(&dht_db_buf);
        };
        if (dht_db_path) |db_path| {
            const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_FULLMUTEX;
            if (sqlite.sqlite3_open_v2(db_path, &dht_db, flags, null) != sqlite.SQLITE_OK) {
                if (dht_db) |d| _ = sqlite.sqlite3_close(d);
                dht_db = null;
            }
            // DHT data is ephemeral — trade durability for speed.
            if (dht_db) |d| {
                _ = sqlite.sqlite3_exec(d, "PRAGMA synchronous = OFF", null, null, null);
                _ = sqlite.sqlite3_exec(d, "PRAGMA journal_mode = MEMORY", null, null, null);
            }
        }
    }
    defer {
        if (dht_db) |d| _ = sqlite.sqlite3_close(d);
    }

    if (dht_db) |db| {
        if (varuna.dht.persistence.DhtPersistence.init(db)) |dp| {
            dht_persist = dp;
        } else |_| {}
    }

    const dht_node_id: [20]u8 = blk: {
        if (dht_persist) |*dp| {
            if (dp.loadNodeId() catch null) |saved_id| {
                break :blk saved_id;
            }
        }
        break :blk varuna.dht.node_id.generate();
    };

    const dht_engine: ?*varuna.dht.DhtEngine = if (cfg.network.dht) blk: {
        const engine = varuna.dht.DhtEngine.create(allocator, dht_node_id) catch |err| {
            try stdout.print("warning: failed to create DHT engine: {s}\n", .{@errorName(err)});
            try stdout.flush();
            break :blk null;
        };

        // Load persisted routing table nodes — skip slow bootstrap if we have enough
        if (dht_persist) |*dp| {
            if (dp.loadNodes(allocator)) |saved_nodes| {
                defer allocator.free(saved_nodes);
                engine.loadPersistedNodes(saved_nodes);
                if (saved_nodes.len > 0) {
                    try stdout.print("dht: loaded {d} persisted nodes\n", .{saved_nodes.len});
                    try stdout.flush();
                }
            } else |_| {}
        }

        break :blk engine;
    } else null;
    defer if (dht_engine) |engine| {
        // Save routing table on shutdown for fast restart
        if (dht_persist) |*dp| {
            if (engine.exportNodes(allocator)) |nodes| {
                defer allocator.free(nodes);
                std.log.info("dht: saving {d} nodes to DB", .{nodes.len});
                dp.saveNodes(nodes) catch |err| {
                    std.log.err("dht: failed to save nodes: {s}", .{@errorName(err)});
                };
                dp.saveNodeId(engine.own_id) catch |err| {
                    std.log.err("dht: failed to save node ID: {s}", .{@errorName(err)});
                };
            } else |err| {
                std.log.err("dht: failed to export nodes: {s}", .{@errorName(err)});
            }
        } else {
            std.log.warn("dht: no persistence DB, nodes not saved", .{});
        }
        engine.deinit();
        allocator.destroy(engine);
    };

    // Wire the DHT engine into the shared event loop before starting the UDP socket.
    if (dht_engine) |engine| {
        shared_el.dht_engine = engine;
    }

    // Start the shared UDP socket (used by both DHT and uTP). This must happen
    // before the event loop so that DHT bootstrap pings can be submitted and
    // inbound uTP connections can be accepted immediately when enable_utp is true.
    if (cfg.network.dht or cfg.network.enable_utp) {
        shared_el.startUtpListener() catch |err| {
            try stdout.print("warning: failed to start UDP listener: {s}\n", .{@errorName(err)});
            try stdout.flush();
            shared_el.dht_engine = null; // Disable DHT if UDP socket failed
            if (cfg.network.enable_utp) {
                shared_el.utp_enabled = false; // Disable uTP if UDP socket failed
            }
        };
    }

    // Resolve bootstrap node hostnames (blocking DNS, after UDP socket is ready).
    // Skip if we loaded enough persisted nodes (table already warm).
    const need_bootstrap = if (dht_engine) |e| e.table.nodeCount() < 8 else false;
    const bootstrap_addrs = if (need_bootstrap)
        (varuna.dht.bootstrap.resolveBootstrapNodes(allocator) catch &.{})
    else
        &.{};
    defer if (bootstrap_addrs.len > 0) allocator.free(bootstrap_addrs);
    if (dht_engine) |engine| {
        if (shared_el.dht_engine != null and bootstrap_addrs.len > 0) {
            engine.addBootstrapNodes(bootstrap_addrs);
        }
    }

    // Session manager
    var session_manager = varuna.daemon.session_manager.SessionManager.init(allocator);
    session_manager.shared_event_loop = &shared_el;
    session_manager.port = cfg.network.port_min;
    session_manager.max_peers = cfg.network.max_peers;
    session_manager.hasher_threads = cfg.performance.hasher_threads;
    session_manager.resume_db_path = resume_db_path;
    session_manager.masquerade_as = cfg.network.masquerade_as;
    session_manager.disable_trackers = cfg.network.disable_trackers;
    if (cfg.storage.data_dir) |dir| session_manager.default_save_path = dir;
    // Apply queue config from TOML
    session_manager.queue_manager.config = .{
        .enabled = cfg.daemon.queueing_enabled,
        .max_active_downloads = cfg.daemon.max_active_downloads,
        .max_active_uploads = cfg.daemon.max_active_uploads,
        .max_active_torrents = cfg.daemon.max_active_torrents,
    };

    // Apply share ratio / seeding time limits from config
    session_manager.max_ratio_enabled = cfg.daemon.max_ratio_enabled;
    session_manager.max_ratio = cfg.daemon.max_ratio;
    session_manager.max_ratio_act = cfg.daemon.max_ratio_act;
    session_manager.max_seeding_time_enabled = cfg.daemon.max_seeding_time_enabled;
    session_manager.max_seeding_time = cfg.daemon.max_seeding_time;
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
        break :blk varuna.rpc.server.ApiServer.initWithFd(allocator, &shared_el.ring, api_fd) catch |err| {
            try stdout.print("failed to init API server with socket activation: {s}\n", .{@errorName(err)});
            try stdout.flush();
            return err;
        };
    } else varuna.rpc.server.ApiServer.initWithDevice(allocator, &shared_el.ring, cfg.daemon.api_bind, cfg.daemon.api_port, cfg.network.bind_device) catch |err| {
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

    // Wire API server into event loop for CQE dispatch
    shared_el.api_server = &api_server;

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

    // Main loop: tick shared event loop (API CQEs dispatched via shared ring)
    var resume_tick_counter: u32 = 0;
    while (!varuna.io.signal.isShutdownRequested()) {

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
                // Start DHT search immediately — don't wait for tracker to finish.
                // The tracker may take minutes (UDP timeouts), but DHT can find
                // peers in parallel once bootstrapped.
                if (!sess.is_private and !sess.dht_registered) {
                    if (shared_el.dht_engine) |engine| {
                        engine.requestPeers(sess.info_hash);
                        sess.dht_registered = true;
                        std.log.info("DHT: registered {x} for peer search", .{sess.info_hash[0..4].*});
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

        // Periodically run queue enforcement (~every 5s at 100ms tick).
        // This catches state transitions (download->seed) that free up slots.
        resume_tick_counter +%= 1;
        if (resume_tick_counter % 50 == 0) {
            session_manager.runQueueEnforcement();
        }

        // Periodically persist completed pieces to resume DB (~every 5s at 100ms tick)
        // and trigger tracker scrapes for swarm health stats.
        if (resume_tick_counter % 50 == 0) {
            session_manager.mutex.lock();
            var iter = session_manager.sessions.iterator();
            while (iter.next()) |entry| {
                const sess = entry.value_ptr.*;
                if (sess.state == .downloading or sess.state == .seeding) {
                    sess.persistNewCompletions();
                    sess.flushResume();
                    sess.maybeScrape();
                    // Persist completion_on if it was set but not yet saved
                    if (sess.completion_on > 0) {
                        session_manager.persistCompletionOn(
                            sess.info_hash,
                            sess.ratio_limit,
                            sess.seeding_time_limit,
                            sess.completion_on,
                        );
                    }
                }
            }
            session_manager.mutex.unlock();
        }

        // Check share ratio / seeding time limits (~every 30s at 100ms tick)
        if (resume_tick_counter % 300 == 150) {
            _ = session_manager.checkShareLimits();
        }

        // Tick shared event loop (non-blocking poll).
        // Also tick when the DHT/uTP UDP socket is open so DHT bootstrap
        // messages and incoming datagrams are processed even without TCP peers.
        if (shared_el.peer_count > 0 or shared_el.listen_fd >= 0 or shared_el.udp_fd >= 0) {
            // Has active I/O -- use tick which calls submit_and_wait
            shared_el.submitTimeout(100 * std.time.ns_per_ms) catch {};
            shared_el.tick() catch {};
        } else {
            // No active I/O -- just sleep to avoid busy-spinning
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

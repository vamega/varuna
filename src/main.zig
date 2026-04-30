const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    // Install SEGV handler to get a stack trace instead of silent crash
    std.debug.attachSegfaultHandler();

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Check for --help
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const cfg = varuna.config.Config{};
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

    // Install fallback signal handler (for pre-event-loop startup errors).
    // The signalfd installed below replaces this for the main event loop.
    varuna.io.signal.installHandlers();
    var loaded_cfg = try varuna.config.loadDefault(allocator);
    defer loaded_cfg.deinit();
    const cfg = loaded_cfg.value;

    var startup_arena = std.heap.ArenaAllocator.init(allocator);
    defer startup_arena.deinit();
    const startup_summary = try varuna.runtime.probe.detectCurrent(startup_arena.allocator());

    // Banner
    try stdout.print("varuna daemon starting\n", .{});
    try varuna.app.writeStartupBannerForSummary(stdout, startup_summary);
    varuna.runtime.probe.ensureSupported(startup_summary) catch |err| {
        switch (err) {
            error.UnsupportedKernel => {
                try stdout.print(
                    "startup blocked: kernel {s} is below the supported minimum {}.{}\n",
                    .{
                        startup_summary.release,
                        varuna.runtime.requirements.minimum_supported.major,
                        varuna.runtime.requirements.minimum_supported.minor,
                    },
                );
            },
            error.IoUringUnavailable => {
                try stdout.print("startup blocked: io_uring is unavailable on this host\n", .{});
            },
            else => return err,
        }
        try stdout.flush();
        return err;
    };
    try stdout.flush();

    // Shared event loop for all torrents (single-threaded I/O).
    // Heap-allocated because EventLoop is very large (peers array, torrent
    // contexts, etc.) and would overflow the stack alongside the GPA state.
    const shared_el_heap = allocator.create(varuna.io.event_loop.EventLoop) catch |err| {
        try stdout.print("failed to allocate event loop: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return err;
    };
    shared_el_heap.* = varuna.io.event_loop.EventLoop.initBare(allocator, cfg.performance.hasher_threads) catch |err| {
        try stdout.print("failed to create event loop: {s}\n", .{@errorName(err)});
        try stdout.flush();
        allocator.destroy(shared_el_heap);
        return err;
    };
    const shared_el = shared_el_heap;
    defer {
        shared_el.deinit();
        allocator.destroy(shared_el_heap);
    }

    // Install signalfd for graceful shutdown via io_uring. SIGINT/SIGTERM
    // produce a POLL_ADD CQE that breaks submit_and_wait immediately.
    shared_el.installSignalFd() catch |err| {
        try stdout.print("warning: signalfd setup failed ({s}), falling back to signal handler\n", .{@errorName(err)});
        try stdout.flush();
    };

    // Resolve resume DB path (config override or default XDG location)
    var resume_db_buf: [1024]u8 = undefined;
    const resume_db_path = resolveDbPath(&resume_db_buf, cfg.storage.resume_db, "resume.db");

    // Apply bind configuration to event loop for outbound peer sockets
    shared_el.bind_device = cfg.network.bind_device;
    shared_el.bind_address = cfg.network.bind_address;

    // Apply MSE/PE encryption mode from config
    shared_el.encryption_mode = try varuna.config.parseEncryptionMode(cfg.network.encryption);

    // Apply connection limits from config
    shared_el.max_connections = cfg.network.max_connections;
    shared_el.max_peers_per_torrent = cfg.network.max_peers_per_torrent;
    shared_el.max_half_open = cfg.network.max_half_open;

    // Apply graceful shutdown timeout from config
    shared_el.shutdown_timeout = cfg.daemon.shutdown_timeout;

    // Apply global speed limits from config
    if (cfg.network.dl_limit > 0) shared_el.setGlobalDlLimit(cfg.network.dl_limit);
    if (cfg.network.ul_limit > 0) shared_el.setGlobalUlLimit(cfg.network.ul_limit);

    // Apply web seed batching limit from config
    shared_el.web_seed_max_request_bytes = cfg.network.web_seed_max_request_bytes;

    // Initialize the reusable piece cache. A zero size means the default 64 MB.
    shared_el.initHugePageCache(cfg.performance.piece_cache_size);

    // Initialize DHT engine (BEP 5), persistence DB, and bootstrap nodes.
    shared_el.port = cfg.network.port_min;
    shared_el.pex_enabled = cfg.network.pex;
    const transport_disp = cfg.network.resolveTransportDisposition();
    shared_el.transport_disposition = transport_disp;

    var dht_state = try initDht(allocator, shared_el, cfg, stdout);
    defer dht_state.deinit(allocator);

    // Start the shared UDP socket (used by both DHT and uTP). This must happen
    // before the event loop so that DHT bootstrap pings can be submitted and
    // inbound uTP connections can be accepted immediately when uTP is enabled.
    const utp_needed = transport_disp.toEnableUtp();
    if (cfg.network.dht or utp_needed) {
        shared_el.startUtpListener() catch |err| {
            try stdout.print("warning: failed to start UDP listener: {s}\n", .{@errorName(err)});
            try stdout.flush();
            shared_el.dht_engine = null; // Disable DHT if UDP socket failed
            if (utp_needed) {
                // Disable uTP directions if UDP socket failed
                shared_el.transport_disposition.outgoing_utp = false;
                shared_el.transport_disposition.incoming_utp = false;
            }
        };
    }

    // Resolve bootstrap node hostnames (blocking DNS, after UDP socket is ready).
    // Skip if we loaded enough persisted nodes (table already warm).
    const need_bootstrap = if (dht_state.engine) |e| e.table.nodeCount() < 8 else false;
    const bootstrap_addrs = if (need_bootstrap)
        (varuna.dht.bootstrap.resolveBootstrapNodes(allocator) catch &.{})
    else
        &.{};
    defer if (bootstrap_addrs.len > 0) allocator.free(bootstrap_addrs);
    if (dht_state.engine) |engine| {
        if (shared_el.dht_engine != null and bootstrap_addrs.len > 0) {
            engine.addBootstrapNodes(bootstrap_addrs);
        }
    }

    // Session manager
    var session_manager = initSessionManager(allocator, shared_el, cfg, resume_db_path);
    defer session_manager.deinit();

    // API handler
    var api_handler = varuna.rpc.handlers.ApiHandler{
        .session_manager = &session_manager,
        .sync_state = varuna.rpc.sync.SyncState.init(allocator),
        .peer_sync_state = varuna.rpc.sync.PeerSyncState.init(allocator),
        .api_username = cfg.daemon.api_username,
        .api_password = cfg.daemon.api_password,
    };
    defer api_handler.sync_state.deinit();
    defer api_handler.peer_sync_state.deinit();

    // HTTP API server (all I/O via io_uring)
    const systemd_fds = varuna.daemon.systemd.listenFds();
    var socket_activated = false;
    var api_server = try initApiServer(allocator, shared_el, cfg, systemd_fds, stdout, &socket_activated);
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

    // Start the periodic torrent-durability sync sweep. Every
    // `sync_timer_interval_ms` (30 s by default), every torrent with
    // un-fsync'd writes gets one fsync per open file. Closes the gap
    // where the OS pagecache controlled durability — see
    // `docs/mmap-durability-audit.md` §R6.
    shared_el.startPeriodicSync();

    // Listen socket for accepting inbound peer connections (created once, shared across torrents).
    // Created at startup so both downloading and seeding torrents can receive inbound connections.
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
    if (listen_fd < 0 and transport_disp.incoming_tcp) {
        shared_el.startTcpListener() catch |err| {
            try stdout.print("warning: failed to start TCP listener: {s}\n", .{@errorName(err)});
            try stdout.flush();
            shared_el.transport_disposition.incoming_tcp = false;
        };
        if (shared_el.listen_fd >= 0) {
            listen_fd = shared_el.listen_fd;
        }
    }
    defer if (listen_fd >= 0 and !peer_socket_activated) std.posix.close(listen_fd);

    // Main loop: tick shared event loop (API CQEs dispatched via shared ring)
    var resume_tick_counter: u32 = 0;
    var drain_announced = false; // track whether we've sent stopped announces
    while (!varuna.io.signal.isShutdownRequested()) {
        const is_draining = shared_el.draining;

        // On first drain tick, send stopped announces to all trackers and
        // persist state so we leave the swarm promptly.
        if (is_draining and !drain_announced) {
            drain_announced = true;
            varuna.daemon.systemd.notifyStopping();
            try stdout.print("\ndraining in-flight transfers...\n", .{});
            try stdout.flush();
            session_manager.mutex.lock();
            var drain_iter = session_manager.sessions.iterator();
            while (drain_iter.next()) |entry| {
                const sess = entry.value_ptr.*;
                if (sess.state == .downloading or sess.state == .seeding) {
                    sess.scheduleStoppedAnnounce();
                    sess.persistNewCompletions();
                    sess.flushResume();
                }
            }
            session_manager.mutex.unlock();
        }

        // Skip new work when draining — only keep ticking the event loop
        // to let in-flight transfers complete.
        if (!is_draining) {
            // Check if any sessions need event loop integration:
            // 1. Sessions in .checking with background_init_done -> start async recheck
            // 2. Sessions with pending_peers -> register torrent and add peers
            {
                session_manager.mutex.lock();
                var iter = session_manager.sessions.iterator();
                while (iter.next()) |entry| {
                    const sess = entry.value_ptr.*;
                    // Phase 1: background init done, start async recheck on event loop
                    if (sess.background_init_done.load(.acquire) and sess.state == .checking) {
                        _ = sess.integrateIntoEventLoop();
                    }
                    // Phase 2: recheck done, register torrent and add peers
                    if (sess.pending_peers != null) {
                        if (shared_el.peer_count < shared_el.max_connections) {
                            _ = sess.addPeersToEventLoop();
                        }
                    }
                    // Start DHT search immediately -- don't wait for tracker to finish.
                    // The tracker may take minutes (UDP timeouts), but DHT can find
                    // peers in parallel once bootstrapped.
                    if (!sess.is_private and !sess.dht_registered) {
                        if (shared_el.dht_engine) |engine| {
                            // BEP 52: for hybrid torrents, also search by the
                            // truncated v2 info-hash (first 20 bytes) so we
                            // discover v2-only peers via the DHT.
                            const v2_truncated: ?[20]u8 = if (sess.info_hash_v2) |full_v2| blk: {
                                var t: [20]u8 = undefined;
                                @memcpy(&t, full_v2[0..20]);
                                break :blk t;
                            } else null;
                            engine.requestPeers(sess.info_hash, v2_truncated);
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
                            if (listen_fd < 0 and shared_el.transport_disposition.incoming_tcp) {
                                shared_el.startTcpListener() catch {};
                                if (shared_el.listen_fd >= 0) {
                                    listen_fd = shared_el.listen_fd;
                                }
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
        }

        // Tick shared event loop (non-blocking poll).
        // Also tick when the DHT/uTP UDP socket is open so DHT bootstrap
        // messages and incoming datagrams are processed even without TCP peers.
        // Always tick during drain so the drain timeout and completion checks run.
        const has_io = is_draining or shared_el.peer_count > 0 or shared_el.listen_fd >= 0 or shared_el.udp_fd >= 0 or shared_el.rechecks.items.len > 0 or shared_el.metadata_fetch != null or shared_el.timer_pending;
        if (has_io) {
            shared_el.submitTimeout(100 * std.time.ns_per_ms) catch {};
            shared_el.tick() catch {};
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // Final state persistence before exit
    {
        session_manager.mutex.lock();
        var final_iter = session_manager.sessions.iterator();
        while (final_iter.next()) |entry| {
            const sess = entry.value_ptr.*;
            if (sess.state == .downloading or sess.state == .seeding) {
                sess.persistNewCompletions();
                sess.flushResume();
            }
        }
        session_manager.mutex.unlock();
    }

    if (!drain_announced) {
        varuna.daemon.systemd.notifyStopping();
    }
    try stdout.print("\nshutting down...\n", .{});
    try stdout.flush();
}

// ── Initialization helpers ──────────────────────────────────

const sqlite = varuna.storage.sqlite3;

/// Resolve a database path from an explicit config value or the default XDG
/// data directory (~/.local/share/varuna/<filename>). Returns a sentinel-
/// terminated pointer into `buf`, or null if the path cannot be determined.
fn resolveDbPath(buf: *[1024]u8, config_path: ?[]const u8, filename: []const u8) ?[*:0]const u8 {
    if (config_path) |p| {
        const z = std.fmt.bufPrintZ(buf, "{s}", .{p}) catch return null;
        _ = z;
        // SQLite supports ":memory:" as a special path for in-memory databases.
        // Skip directory creation for it.
        if (std.mem.eql(u8, p, ":memory:")) return @ptrCast(buf);
        return @ptrCast(buf);
    }
    // Default: ~/.local/share/varuna/<filename>
    const home = std.posix.getenv("HOME") orelse return null;
    const z = std.fmt.bufPrintZ(buf, "{s}/.local/share/varuna/{s}", .{ home, filename }) catch return null;
    _ = z;
    // Ensure parent directory exists (e.g. ~/.local/share/varuna/)
    const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(buf)));
    const dir_end = std.mem.lastIndexOfScalar(u8, path_str, '/') orelse return null;
    std.fs.makeDirAbsolute(buf[0..dir_end]) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    return @ptrCast(buf);
}

/// Bundled DHT state: persistence DB, persistence layer, and engine.
/// Returned by `initDht` so that `main()` can defer a single `deinit` call.
const DhtState = struct {
    persist: ?varuna.dht.persistence.DhtPersistence = null,
    db: ?*sqlite.Db = null,
    engine: ?*varuna.dht.DhtEngine = null,

    fn deinit(self: *DhtState, allocator: std.mem.Allocator) void {
        // Save routing table on shutdown for fast restart
        if (self.engine) |engine| {
            if (self.persist) |*dp| {
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
        }
        if (self.persist) |*dp| dp.deinit();
        if (self.db) |d| _ = sqlite.sqlite3_close(d);
    }
};

/// Create the DHT persistence database, load persisted state, and create the
/// DHT engine. Wires the engine into `shared_el.dht_engine` on success.
fn initDht(
    allocator: std.mem.Allocator,
    shared_el: *varuna.io.event_loop.EventLoop,
    cfg: varuna.config.Config,
    stdout: *std.Io.Writer,
) !DhtState {
    var state = DhtState{};
    errdefer state.deinit(allocator);

    // Open DHT DB — separate file so it can be blown away independently
    // from torrent resume state.
    {
        var dht_db_buf: [1024]u8 = undefined;
        const dht_db_path = resolveDbPath(&dht_db_buf, null, "dht.db");
        if (dht_db_path) |db_path| {
            const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_FULLMUTEX;
            if (sqlite.sqlite3_open_v2(db_path, &state.db, flags, null) != sqlite.SQLITE_OK) {
                if (state.db) |d| _ = sqlite.sqlite3_close(d);
                state.db = null;
            }
            // DHT data is ephemeral — trade durability for speed.
            if (state.db) |d| {
                _ = sqlite.sqlite3_exec(d, "PRAGMA synchronous = OFF", null, null, null);
                _ = sqlite.sqlite3_exec(d, "PRAGMA journal_mode = MEMORY", null, null, null);
            }
        }
    }

    if (state.db) |db| {
        if (varuna.dht.persistence.DhtPersistence.init(db)) |dp| {
            state.persist = dp;
        } else |_| {}
    }

    const dht_node_id: [20]u8 = blk: {
        if (state.persist) |*dp| {
            if (dp.loadNodeId() catch null) |saved_id| {
                break :blk saved_id;
            }
        }
        break :blk varuna.dht.node_id.generateRandom();
    };

    if (cfg.network.dht) {
        const engine = varuna.dht.DhtEngine.create(allocator, dht_node_id) catch |err| {
            try stdout.print("warning: failed to create DHT engine: {s}\n", .{@errorName(err)});
            try stdout.flush();
            return state;
        };
        state.engine = engine;

        // Load persisted routing table nodes — skip slow bootstrap if we have enough
        if (state.persist) |*dp| {
            if (dp.loadNodes(allocator)) |saved_nodes| {
                defer allocator.free(saved_nodes);
                engine.loadPersistedNodes(saved_nodes);
                if (saved_nodes.len > 0) {
                    try stdout.print("dht: loaded {d} persisted nodes\n", .{saved_nodes.len});
                    try stdout.flush();
                }
            } else |_| {}
        }

        // Wire the DHT engine into the shared event loop before starting the UDP socket.
        shared_el.dht_engine = engine;
    }

    return state;
}

/// Create and configure a SessionManager from the loaded config.
fn initSessionManager(
    allocator: std.mem.Allocator,
    shared_el: *varuna.io.event_loop.EventLoop,
    cfg: varuna.config.Config,
    resume_db_path: ?[*:0]const u8,
) varuna.daemon.session_manager.SessionManager {
    var sm = varuna.daemon.session_manager.SessionManager.init(allocator);
    sm.shared_event_loop = shared_el;
    sm.port = cfg.network.port_min;
    sm.max_peers = cfg.network.max_peers;
    sm.hasher_threads = cfg.performance.hasher_threads;
    sm.resume_db_path = resume_db_path;
    sm.masquerade_as = cfg.network.masquerade_as;
    sm.disable_trackers = cfg.network.disable_trackers;
    // Borrow the daemon-lifetime bind_device slice from the config
    // arena. The HTTP and UDP tracker executors created lazily via
    // `ensureTrackerExecutor` / `ensureUdpTrackerExecutor` forward
    // this into their `DnsResolver`, so DNS queries egress through
    // the configured interface alongside peer / tracker / RPC
    // traffic. The c-ares DNS backend honors it via a socket
    // callback; the threadpool backend stores it but cannot apply
    // it (see `src/io/dns_threadpool.zig` "Known limitation").
    sm.bind_device = cfg.network.bind_device;
    if (cfg.storage.data_dir) |dir| sm.default_save_path = dir;
    // Apply queue config from TOML
    sm.queue_manager.config = .{
        .enabled = cfg.daemon.queueing_enabled,
        .max_active_downloads = cfg.daemon.max_active_downloads,
        .max_active_uploads = cfg.daemon.max_active_uploads,
        .max_active_torrents = cfg.daemon.max_active_torrents,
    };

    // Apply share ratio / seeding time limits from config
    sm.max_ratio_enabled = cfg.daemon.max_ratio_enabled;
    sm.max_ratio = cfg.daemon.max_ratio;
    sm.max_ratio_act = cfg.daemon.max_ratio_act;
    sm.max_seeding_time_enabled = cfg.daemon.max_seeding_time_enabled;
    sm.max_seeding_time = cfg.daemon.max_seeding_time;
    // Load persisted categories and tags from the resume DB
    sm.loadCategoriesAndTags();
    return sm;
}

/// Create the HTTP API server, using systemd socket activation if available,
/// otherwise binding to the configured address and port.
fn initApiServer(
    allocator: std.mem.Allocator,
    shared_el: *varuna.io.event_loop.EventLoop,
    cfg: varuna.config.Config,
    systemd_fds: ?[]const std.posix.fd_t,
    stdout: *std.Io.Writer,
    socket_activated: *bool,
) !varuna.rpc.server.ApiServer {
    if (systemd_fds) |fds| {
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
        socket_activated.* = true;
        return varuna.rpc.server.ApiServer.initWithFd(allocator, &shared_el.io, api_fd) catch |err| {
            try stdout.print("failed to init API server with socket activation: {s}\n", .{@errorName(err)});
            try stdout.flush();
            return err;
        };
    } else {
        socket_activated.* = false;
        return varuna.rpc.server.ApiServer.initWithDevice(allocator, &shared_el.io, cfg.daemon.api_bind, cfg.daemon.api_port, cfg.network.bind_device) catch |err| {
            try stdout.print("failed to start API server: {s}\n", .{@errorName(err)});
            try stdout.flush();
            return err;
        };
    }
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

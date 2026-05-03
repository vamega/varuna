const std = @import("std");
const builtin = @import("builtin");
const boringssl = @import("build/boringssl.zig");
const cares = @import("build/cares.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_mode = b.option(
        enum { system, bundled },
        "sqlite",
        "SQLite linking strategy: 'system' links libsqlite3, 'bundled' compiles the amalgamation from vendor/sqlite/",
    ) orelse .system;

    const dns_backend = b.option(
        DnsBackend,
        "dns",
        "DNS resolver backend: 'threadpool' uses getaddrinfo on background threads (default), 'c-ares' uses the c-ares async DNS library, 'custom' uses the in-tree Zig-native resolver under src/io/dns_custom/",
    ) orelse .threadpool;

    // ── IO backend selection ──────────────────────────────────
    //
    // Picks the kernel IO primitive (readiness layer) AND the file-I/O
    // strategy for the daemon's event loop. The two are independent axes:
    // for each readiness backend we have a POSIX (`pread`/`pwrite` on a
    // thread pool) and an mmap (memcpy + msync) variant, plus the in-process
    // SimIO simulator promoted to a top-level option for test builds.
    //
    // - `io_uring` (default on Linux ≥5.10): production proactor via
    //   `src/io/real_io.zig`.
    // - `epoll_posix`: Linux epoll readiness + POSIX file ops via
    //   `src/io/epoll_posix_io.zig`. Sockets + timers + cancel implemented;
    //   file ops require the worker thread pool follow-up.
    // - `epoll_mmap`: Linux epoll readiness + mmap-backed file I/O via
    //   `src/io/epoll_mmap_io.zig`. Scaffold today (see commit 2 of the
    //   bifurcation work for the full implementation).
    // - `kqueue_posix` / `kqueue_mmap`: macOS / BSD analogues, owned by the
    //   parallel kqueue-bifurcation engineer. Stubs land on this branch so
    //   the 6-way backend selector compiles; the engineer replaces them.
    // - `sim`: in-process SimIO simulator. Resolves `RealIO` to `SimIO` for
    //   tests that exercise the comptime selector itself.
    //
    // Daemon callers reach the chosen backend through `src/io/backend.zig`.
    // After the daemon-rewire on 2026-04-28, the daemon binary now compiles
    // under all five production backends — the previous gating that produced
    // only the IO module + tests under non-io_uring flags is gone. Only
    // `-Dio=sim` still skips the daemon install, since the simulator is for
    // tests and isn't a meaningful production target.
    const io_backend = b.option(
        IoBackend,
        "io",
        "IO backend: 'io_uring' (Linux, default; full daemon), 'epoll_posix' (Linux readiness + POSIX file ops thread pool), 'epoll_mmap' (Linux readiness + mmap file I/O), 'kqueue_posix' / 'kqueue_mmap' (macOS/BSD), 'sim' (in-process SimIO for test builds — daemon install skipped). All non-sim backends produce a working daemon binary backed by the chosen IO implementation.",
    ) orelse .io_uring;

    const cares_mode = b.option(
        enum { system, bundled },
        "cares",
        "c-ares linking strategy (only used when -Ddns=c-ares): 'system' links the system libcares, 'bundled' compiles from vendor/c-ares/",
    ) orelse .bundled;

    const tls_backend = b.option(
        TlsBackend,
        "tls",
        "TLS backend: 'boringssl' links vendored BoringSSL for HTTPS tracker support (default), 'none' disables TLS",
    ) orelse .boringssl;

    const crypto_backend = b.option(
        CryptoBackend,
        "crypto",
        "Cryptographic algorithm backend: 'varuna' uses our SHA-1 with hardware acceleration (default), 'stdlib' uses Zig std.crypto, 'boringssl' uses vendored BoringSSL",
    ) orelse .varuna;

    // Validate: -Dcrypto=boringssl requires -Dtls=boringssl (BoringSSL must be linked)
    if (crypto_backend == .boringssl and tls_backend != .boringssl) {
        @panic("-Dcrypto=boringssl requires -Dtls=boringssl (BoringSSL is not linked when -Dtls=none)");
    }

    // ── Build options module (dns backend + tls backend + crypto backend + io backend) ─
    const build_options = b.addOptions();
    build_options.addOption(DnsBackend, "dns_backend", dns_backend);
    build_options.addOption(TlsBackend, "tls_backend", tls_backend);
    build_options.addOption(CryptoBackend, "crypto_backend", crypto_backend);
    build_options.addOption(IoBackend, "io_backend", io_backend);

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    const zigzag_mod = zigzag_dep.module("zigzag");

    // ── Shared library module ─────────────────────────────
    const varuna_mod = b.addModule("varuna", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    switch (sqlite_mode) {
        .system => {
            varuna_mod.addLibraryPath(b.path("lib"));
            varuna_mod.linkSystemLibrary("sqlite3", .{});
        },
        .bundled => {
            varuna_mod.addCSourceFile(.{
                .file = b.path("vendor/sqlite/sqlite3.c"),
                .flags = &.{
                    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
                    "-DSQLITE_DQS=0",
                    "-DSQLITE_THREADSAFE=1",
                    "-DSQLITE_DEFAULT_MEMSTATUS=0",
                    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
                    "-DSQLITE_OMIT_DEPRECATED",
                    "-DSQLITE_OMIT_AUTOINIT",
                },
            });
            varuna_mod.addIncludePath(b.path("vendor/sqlite"));
        },
    }

    // ── c-ares linking (when dns=c-ares) ────────────────────
    if (dns_backend == .c_ares) {
        switch (cares_mode) {
            .system => {
                varuna_mod.linkSystemLibrary("cares", .{});
            },
            .bundled => {
                const cares_lib = cares.create(b, target, optimize);
                varuna_mod.linkLibrary(cares_lib.lib);
                varuna_mod.addIncludePath(cares_lib.include_path);
            },
        }
    }

    // ── BoringSSL linking (when tls=boringssl) ──────────────
    if (tls_backend == .boringssl) {
        const boringssl_libs = boringssl.create(
            b,
            b.path("vendor/boringssl"),
            target,
            optimize,
        );
        // Link all three BoringSSL libraries into the varuna module
        varuna_mod.linkLibrary(boringssl_libs.bcm);
        varuna_mod.linkLibrary(boringssl_libs.crypto);
        varuna_mod.linkLibrary(boringssl_libs.ssl);
        varuna_mod.addIncludePath(boringssl_libs.include_path);
    }

    const varuna_import = [_]std.Build.Module.Import{
        .{ .name = "varuna", .module = varuna_mod },
    };

    const tui_mod = b.addModule("varuna_tui", .{
        .root_source_file = b.path("src/tui/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zigzag", .module = zigzag_mod },
        },
    });

    const tui_import = [_]std.Build.Module.Import{
        .{ .name = "varuna_tui", .module = tui_mod },
    };

    // The daemon (varuna) and the thin RPC client (varuna-ctl) now route
    // through `src/io/backend.zig`, which dispatches on `-Dio=`. They
    // build under Linux-targeting production backends (`io_uring`,
    // `epoll_posix`, `epoll_mmap`). The kqueue variants compile the IO
    // module + tests for cross-compile validation but the daemon source
    // still has Linux-specific deps (IoUring imports, SQLite, etc.) that
    // need a separate macOS-port round before the daemon binary can build
    // under kqueue. `-Dio=sim` always skips — the daemon doesn't
    // meaningfully run against the in-process simulator (sim is for tests).
    const build_daemon = target.result.os.tag == .linux and
        (io_backend == .io_uring or io_backend == .epoll_posix or io_backend == .epoll_mmap);

    // varuna-tools and varuna-perf are CLI / benchmark binaries that
    // stay hard-coded to io_uring (`src/app.zig`, `src/storage/verify.zig`,
    // `src/perf/workloads.zig`). AGENTS.md exempts them from the io_uring
    // policy — they're allowed std-lib I/O and are not on the hot daemon
    // path. They build only under `-Dio=io_uring` to preserve that
    // exemption boundary; rewiring them would force backend cascades into
    // code that has no production motivation to abstract over IO backends.
    const build_companion_tools = io_backend == .io_uring;

    // ── varuna (daemon) ───────────────────────────────────
    const daemon_exe = b.addExecutable(.{
        .name = "varuna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    // DhtEngine + EventLoop on main()'s stack together exceed the default 8 MB stack.
    // DHT routing table (160 buckets × 8 nodes × ~144 bytes = ~182 KB), 16 concurrent
    // Lookup tables (each with 256-peer buffer = ~42 KB, total ~672 KB), and 256
    // pending queries (~42 KB) = ~896 KB for DhtEngine alone.  Combined with other
    // stack frames (getaddrinfo in glibc can use 1-4 MB), 8 MB is insufficient.
    daemon_exe.stack_size = 32 * 1024 * 1024; // 32 MB
    if (build_daemon) b.installArtifact(daemon_exe);

    // ── varuna-ctl (CLI client) ───────────────────────────
    const ctl_exe = b.addExecutable(.{
        .name = "varuna-ctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ctl/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    if (build_daemon) b.installArtifact(ctl_exe);

    // ── varuna-tui (mock terminal UI client) ───────────────────
    const tui_exe = b.addExecutable(.{
        .name = "varuna-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &tui_import,
        }),
    });
    const install_tui = b.addInstallArtifact(tui_exe, .{});
    if (build_daemon) b.getInstallStep().dependOn(&install_tui.step);

    const build_tui_step = b.step("build-tui", "Build the mock varuna-tui binary");
    build_tui_step.dependOn(&install_tui.step);

    const run_tui_step = b.step("run-tui", "Run the mock varuna-tui binary");
    const run_tui_cmd = b.addRunArtifact(tui_exe);
    if (b.args) |args| run_tui_cmd.addArgs(args);
    run_tui_step.dependOn(&run_tui_cmd.step);

    // ── varuna-tools (standalone utilities) ────────────────
    const tools_exe = b.addExecutable(.{
        .name = "varuna-tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    if (build_companion_tools) b.installArtifact(tools_exe);

    // ── Run targets ───────────────────────────────────────
    // The `run` step is only meaningful when the daemon is built.
    if (build_daemon) {
        const run_step = b.step("run", "Run the varuna daemon");
        const run_cmd = b.addRunArtifact(daemon_exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // ── Tests ─────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = varuna_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const daemon_tests = b.addTest(.{ .root_module = daemon_exe.root_module });
    const run_daemon_tests = b.addRunArtifact(daemon_tests);

    const test_step = b.step("test", "Run the full test suite");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_daemon_tests.step);

    const tui_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tui_render_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &tui_import,
        }),
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);
    const test_tui_step = b.step("test-tui", "Run focused varuna-tui render/model tests");
    test_tui_step.dependOn(&run_tui_tests.step);
    test_step.dependOn(&run_tui_tests.step);

    const move_job_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{"MoveJob:"},
    });
    const run_move_job_tests = b.addRunArtifact(move_job_tests);
    const test_move_job_step = b.step("test-move-job", "Run focused MoveJob relocation tests");
    test_move_job_step.dependOn(&run_move_job_tests.step);

    const dht_source_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{"DHT"},
    });
    const run_dht_source_tests = b.addRunArtifact(dht_source_tests);
    const test_dht_step = b.step("test-dht", "Run focused DHT source tests");
    test_dht_step.dependOn(&run_dht_source_tests.step);

    const rpc_parser_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{"RPC parser"},
    });
    const run_rpc_parser_tests = b.addRunArtifact(rpc_parser_tests);
    const test_rpc_parser_step = b.step("test-rpc-parser", "Run focused RPC parser compatibility tests");
    test_rpc_parser_step.dependOn(&run_rpc_parser_tests.step);

    const web_seed_source_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{"web seed"},
    });
    const run_web_seed_source_tests = b.addRunArtifact(web_seed_source_tests);
    const test_web_seed_source_step = b.step("test-web-seed", "Run focused web seed source tests");
    test_web_seed_source_step.dependOn(&run_web_seed_source_tests.step);

    // ── Hardening tests (adversarial peer, private tracker) ─
    const adversarial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/adversarial_peer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_adversarial_tests = b.addRunArtifact(adversarial_tests);
    test_step.dependOn(&run_adversarial_tests.step);

    // Regression tests for commit 3af560a (large-20m-64k stall): protocol
    // handlers misusing peer.mode as the swarm role. Deterministic — drives
    // processMessage directly with constructed bodies, no network.
    const peer_mode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/peer_mode_regression_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_peer_mode_tests = b.addRunArtifact(peer_mode_tests);
    test_step.dependOn(&run_peer_mode_tests.step);
    const test_peer_mode_step = b.step("test-peer-mode-regression", "Run peer mode protocol regression tests");
    test_peer_mode_step.dependOn(&run_peer_mode_tests.step);

    const peer_policy_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{ "detachAllPeersExcept", "checkReannounce" },
    });
    const run_peer_policy_tests = b.addRunArtifact(peer_policy_tests);
    const test_peer_policy_step = b.step("test-peer-policy", "Run peer policy ownership and scheduling tests");
    test_peer_policy_step.dependOn(&run_peer_policy_tests.step);

    const peer_unchoke_tests = b.addTest(.{
        .root_module = varuna_mod,
        .filters = &.{"recalculateUnchokes"},
    });
    const run_peer_unchoke_tests = b.addRunArtifact(peer_unchoke_tests);
    const test_peer_unchoke_step = b.step("test-peer-unchoke", "Run peer unchoke scheduling tests");
    test_peer_unchoke_step.dependOn(&run_peer_unchoke_tests.step);

    const private_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/private_tracker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_private_tracker_tests = b.addRunArtifact(private_tracker_tests);
    test_step.dependOn(&run_private_tracker_tests.step);

    const private_torrent_dht_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/private_torrent_dht_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_private_torrent_dht_tests = b.addRunArtifact(private_torrent_dht_tests);
    test_step.dependOn(&run_private_torrent_dht_tests.step);

    const clock_random_determinism_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/clock_random_determinism_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_clock_random_determinism_tests = b.addRunArtifact(clock_random_determinism_tests);
    test_step.dependOn(&run_clock_random_determinism_tests.step);

    const csprng_determinism_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/csprng_determinism_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_csprng_determinism_tests = b.addRunArtifact(csprng_determinism_tests);
    test_step.dependOn(&run_csprng_determinism_tests.step);

    const sim_mse_handshake_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_mse_handshake_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_mse_handshake_tests = b.addRunArtifact(sim_mse_handshake_tests);
    test_step.dependOn(&run_sim_mse_handshake_tests.step);

    const udp_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/udp_tracker_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_udp_tracker_tests = b.addRunArtifact(udp_tracker_tests);
    test_step.dependOn(&run_udp_tracker_tests.step);

    const torrent_session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/torrent_session_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_torrent_session_tests = b.addRunArtifact(torrent_session_tests);

    const test_torrent_session_step = b.step("test-torrent-session", "Run the focused TorrentSession test binary");
    test_torrent_session_step.dependOn(&run_torrent_session_tests.step);
    // Intentionally NOT wired into the main `test` step: known-issue
    // intermittent Zig cache/toolchain failure (`manifest_create
    // Unexpected`) — see STATUS.md "Known Issues". Run via
    // `zig build test-torrent-session` for focused iteration. Re-evaluate
    // wiring once the cache issue resolves upstream.

    // ── Piece hash lifecycle tests (Track A — docs/piece-hash-lifecycle.md) ──
    const piece_hash_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/piece_hash_lifecycle_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_piece_hash_lifecycle_tests = b.addRunArtifact(piece_hash_lifecycle_tests);
    test_step.dependOn(&run_piece_hash_lifecycle_tests.step);
    const test_piece_hash_step = b.step(
        "test-piece-hash-lifecycle",
        "Run piece hash lifecycle tests (loadForSeeding/freePieces/loadPiecesForRecheck)",
    );
    test_piece_hash_step.dependOn(&run_piece_hash_lifecycle_tests.step);

    // ── Custom DNS library — Phase F integration tests ───────
    //
    // Drives `QueryOf(ScriptedIo)` end-to-end against scripted DNS
    // server responses. See the test file's module docstring for the
    // ScriptedIo design rationale (real `AF_UNIX` `SOCK_DGRAM` fds so
    // `query.zig`'s `posix.close` on deliver doesn't EBADF).
    const dns_custom_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dns_custom_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_dns_custom_integration_tests = b.addRunArtifact(dns_custom_integration_tests);
    const test_dns_custom_integration_step = b.step(
        "test-dns-custom",
        "Run Phase F end-to-end integration tests for the custom DNS library",
    );
    test_dns_custom_integration_step.dependOn(&run_dns_custom_integration_tests.step);
    test_step.dependOn(&run_dns_custom_integration_tests.step);

    // ── SO_BINDTODEVICE tests ────────────────────────────────
    const bind_device_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bind_device_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_bind_device_tests = b.addRunArtifact(bind_device_tests);
    const test_bind_device_step = b.step("test-bind-device", "Run SO_BINDTODEVICE socket option tests");
    test_bind_device_step.dependOn(&run_bind_device_tests.step);
    test_step.dependOn(&run_bind_device_tests.step);

    // ── Safety tests (compile-time + runtime regression guards) ─
    const safety_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/safety_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_safety_tests = b.addRunArtifact(safety_tests);
    const test_safety_step = b.step("test-safety", "Run compile-time and runtime safety regression tests");
    test_safety_step.dependOn(&run_safety_tests.step);
    test_step.dependOn(&run_safety_tests.step);

    // ── IO backend parity tests (RealIO vs SimIO) ─────────
    const io_parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io_backend_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_io_parity = b.addRunArtifact(io_parity_tests);
    const test_io_parity_step = b.step("test-io-parity", "Run IO backend parity tests (RealIO vs SimIO)");
    test_io_parity_step.dependOn(&run_io_parity.step);
    test_step.dependOn(&run_io_parity.step);

    // ── EpollPosixIO smoke tests (real socketpair, real epoll fd) ───
    //
    // Backend-specific coverage for `src/io/epoll_posix_io.zig`. Only
    // meaningful on Linux (skipped at runtime on other platforms via the
    // test's `skipIfUnavailable`). The bulk of the EpollPosixIO inline
    // tests are pulled in via `src/io/root.zig` → `_ = epoll_posix_io;`;
    // this addTest target exists so engineers can iterate on a focused
    // build step (`zig build test-epoll-posix-io`) instead of running the
    // full suite.
    const epoll_posix_io_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/epoll_posix_io_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_epoll_posix_io_tests = b.addRunArtifact(epoll_posix_io_tests);
    const test_epoll_posix_io_step = b.step("test-epoll-posix-io", "Run EpollPosixIO smoke tests (real socketpair + real epoll)");
    test_epoll_posix_io_step.dependOn(&run_epoll_posix_io_tests.step);
    test_step.dependOn(&run_epoll_posix_io_tests.step);

    // ── EpollMmapIO smoke tests (mmap-backed file ops) ──────────────
    //
    // Backend-specific coverage for `src/io/epoll_mmap_io.zig`. Linux-only
    // (skipped at runtime on other platforms via `skipIfUnavailable`). The
    // inline tests in `epoll_mmap_io.zig` are pulled in via
    // `src/io/root.zig` -> `_ = epoll_mmap_io;`; this addTest target adds
    // integration coverage focused on the mmap remap / truncate /
    // msync paths.
    const epoll_mmap_io_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/epoll_mmap_io_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_epoll_mmap_io_tests = b.addRunArtifact(epoll_mmap_io_tests);
    const test_epoll_mmap_io_step = b.step("test-epoll-mmap-io", "Run EpollMmapIO smoke tests (mmap remap + msync coverage)");
    test_epoll_mmap_io_step.dependOn(&run_epoll_mmap_io_tests.step);
    test_step.dependOn(&run_epoll_mmap_io_tests.step);

    // ── KqueuePosixIO MVP tests ────────────────────────────
    // Standalone target: compiles `src/io/kqueue_posix_io.zig` directly,
    // with its `@import("io_interface.zig")` sibling resolving naturally.
    // No dependency on `varuna_mod`, so this target cross-compiles cleanly
    // for macOS even though the daemon does not.
    //
    // Inline tests in `src/io/kqueue_posix_io.zig` cover both platform-
    // portable (timer heap, errno mapping) and macOS-only (real kqueue
    // syscalls) paths. The latter `return error.SkipZigTest` on non-darwin
    // targets; the bodies are still semantically analysed which catches
    // Zig API drift on cross-compilation.
    const kqueue_posix_io_inline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/io/kqueue_posix_io.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_kqueue_posix_io_step = b.step(
        "test-kqueue-posix-io",
        "Run KqueuePosixIO MVP tests (cross-compile-clean; mock-driven on Linux, full on macOS)",
    );
    // Cross-compiled binaries can't run on the host — depend only on
    // the compile step in that case so `zig build test-kqueue-posix-io
    // -Dtarget=aarch64-macos` validates compilation without trying to
    // exec a macOS test binary on Linux.
    const can_exec_kqueue_posix_io_tests =
        target.result.os.tag == builtin.os.tag and
        target.result.cpu.arch == builtin.cpu.arch;
    if (can_exec_kqueue_posix_io_tests) {
        const run_kqueue_posix_io_inline_tests = b.addRunArtifact(kqueue_posix_io_inline_tests);
        test_kqueue_posix_io_step.dependOn(&run_kqueue_posix_io_inline_tests.step);
        test_step.dependOn(&run_kqueue_posix_io_inline_tests.step);
    } else {
        test_kqueue_posix_io_step.dependOn(&kqueue_posix_io_inline_tests.step);
    }

    // Bridge tests via varuna_mod (Linux-only; pulls kqueue_posix_io
    // through `varuna.io.kqueue_posix_io`). Cross-targets that skip
    // varuna_mod also skip this; that's fine — the standalone target
    // above keeps the cross-compile signal clean.
    const kqueue_posix_io_bridge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kqueue_posix_io_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_kqueue_posix_io_bridge_tests = b.addRunArtifact(kqueue_posix_io_bridge_tests);
    const test_kqueue_posix_io_bridge_step = b.step(
        "test-kqueue-posix-io-bridge",
        "Run KqueuePosixIO bridge tests via varuna_mod (Linux-only by construction)",
    );
    test_kqueue_posix_io_bridge_step.dependOn(&run_kqueue_posix_io_bridge_tests.step);
    if (build_daemon) test_step.dependOn(&run_kqueue_posix_io_bridge_tests.step);

    // ── KqueueMmapIO MVP tests ─────────────────────────────
    // Standalone target: compiles `src/io/kqueue_mmap_io.zig` directly.
    // Same model as the POSIX variant — the readiness layer (sockets,
    // timers, cancel) is identical; the file-op submission methods
    // diverge to use mmap + msync + F_PREALLOCATE on macOS.
    //
    // Inline tests in `src/io/kqueue_mmap_io.zig` cover both platform-
    // portable (timer heap, errno mapping, fstore_t layout) and macOS-
    // only (init, real timeout-via-kevent, mmap round-trip) paths. The
    // latter `return error.SkipZigTest` on non-darwin targets; the
    // bodies are still semantically analysed under cross-compile.
    const kqueue_mmap_io_inline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/io/kqueue_mmap_io.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_kqueue_mmap_io_step = b.step(
        "test-kqueue-mmap-io",
        "Run KqueueMmapIO MVP tests (cross-compile-clean; mock-driven on Linux, full on macOS)",
    );
    const can_exec_kqueue_mmap_io_tests =
        target.result.os.tag == builtin.os.tag and
        target.result.cpu.arch == builtin.cpu.arch;
    if (can_exec_kqueue_mmap_io_tests) {
        const run_kqueue_mmap_io_inline_tests = b.addRunArtifact(kqueue_mmap_io_inline_tests);
        test_kqueue_mmap_io_step.dependOn(&run_kqueue_mmap_io_inline_tests.step);
        test_step.dependOn(&run_kqueue_mmap_io_inline_tests.step);
    } else {
        test_kqueue_mmap_io_step.dependOn(&kqueue_mmap_io_inline_tests.step);
    }

    // Bridge tests via varuna_mod (Linux-only; pulls kqueue_mmap_io
    // through `varuna.io.kqueue_mmap_io`). Reuses the shared
    // `tests/kqueue_mmap_io_test.zig` file for fixtures that prefer
    // the varuna_mod surface over the standalone file.
    const kqueue_mmap_io_bridge_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/kqueue_mmap_io_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_kqueue_mmap_io_bridge_tests = b.addRunArtifact(kqueue_mmap_io_bridge_tests);
    const test_kqueue_mmap_io_bridge_step = b.step(
        "test-kqueue-mmap-io-bridge",
        "Run KqueueMmapIO bridge tests via varuna_mod (Linux-only by construction)",
    );
    test_kqueue_mmap_io_bridge_step.dependOn(&run_kqueue_mmap_io_bridge_tests.step);
    if (build_daemon) test_step.dependOn(&run_kqueue_mmap_io_bridge_tests.step);

    // ── SimIO socketpair / parking / fault-injection tests ────────
    //
    // `tests/sim_socketpair_test.zig` is itself a top-level test file
    // — its tests are defined inline in that file, NOT pulled in from
    // `src/io/sim_io.zig` despite the `const sim_io = varuna.io.sim_io`
    // import. Cross-package namespace import in Zig 0.15.2 doesn't
    // propagate test discovery; only the explicitly-named symbols the
    // test body references get pulled in. The inline `test "..."`
    // blocks in `src/io/sim_io.zig` are now wired via mod_tests:
    // `src/root.zig` opts in `_ = io;` and `src/io/root.zig` has
    // `test { _ = sim_io; }` (Track 2 #7).
    const sim_io_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_socketpair_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_io_tests = b.addRunArtifact(sim_io_tests);
    const test_sim_io_step = b.step("test-sim-io", "Run SimIO socketpair / parking / fault-injection wrapper tests");
    test_sim_io_step.dependOn(&run_sim_io_tests.step);
    test_step.dependOn(&run_sim_io_tests.step);

    // ── SimIO durability (write/fsync/crash) tests ────────
    //
    // Algorithm-level tests for the per-fd dirty/durable byte model
    // added to SimIO so simulator tests can faithfully reproduce a
    // crash between a write CQE and the matching fsync CQE. Sits
    // alongside the broader sim-io tests but is wired separately so
    // the durability surface can be iterated without rerunning the
    // whole socketpair / parking suite.
    const sim_io_durability_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_io_durability_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_io_durability_tests = b.addRunArtifact(sim_io_durability_tests);
    const test_sim_io_durability_step = b.step(
        "test-sim-io-durability",
        "Run SimIO durability model tests (write/fsync/crash byte-layer semantics)",
    );
    test_sim_io_durability_step.dependOn(&run_sim_io_durability_tests.step);
    test_step.dependOn(&run_sim_io_durability_tests.step);

    // ── Resume-DB durability gate (32-seed BUGGIFY) ───────
    //
    // 32-seed harness for the production durability gate (commit
    // `aee2f09 storage: gate resume completions on durability`). Drives
    // the real `EventLoopOf(SimIO)` write → sync sweep → resume DB
    // pipeline and fires `sim.crash()` at varied ticks to assert that
    // every piece the DB claims complete has its bytes durable in the
    // SimIO durability layer. Replaces the earlier deliberately-
    // failing single-seed bug repro now that the production fix has
    // landed; this step is part of the default `test_step` aggregate.
    const resume_durability_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/resume_durability_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_resume_durability_buggify_tests = b.addRunArtifact(resume_durability_buggify_tests);
    const test_resume_durability_buggify_step = b.step(
        "test-resume-durability-buggify",
        "32-seed BUGGIFY harness for the resume-DB durability barrier",
    );
    test_resume_durability_buggify_step.dependOn(&run_resume_durability_buggify_tests.step);
    test_step.dependOn(&run_resume_durability_buggify_tests.step);

    // ── SimPeer protocol tests ─────────────────────────────
    const sim_peer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_peer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_peer_tests = b.addRunArtifact(sim_peer_tests);
    const test_sim_peer_step = b.step("test-sim-peer", "Run SimPeer behavior / protocol tests");
    test_sim_peer_step.dependOn(&run_sim_peer_tests.step);
    test_step.dependOn(&run_sim_peer_tests.step);

    // ── Minimal Simulator swarm test ───────────────────────
    const sim_minimal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_minimal_swarm_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_minimal_tests = b.addRunArtifact(sim_minimal_tests);
    const test_sim_minimal_step = b.step("test-sim-minimal", "Run minimal Simulator swarm test");
    test_sim_minimal_step.dependOn(&run_sim_minimal_tests.step);
    test_step.dependOn(&run_sim_minimal_tests.step);

    // ── Simulator unit + BUGGIFY tests ─────────────────────
    const sim_simulator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_simulator_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_simulator_tests = b.addRunArtifact(sim_simulator_tests);
    const test_sim_simulator_step = b.step("test-sim-simulator", "Run Simulator init / step / BUGGIFY tests");
    test_sim_simulator_step.dependOn(&run_sim_simulator_tests.step);
    test_step.dependOn(&run_sim_simulator_tests.step);

    // ── Sim-only smart-ban protocol regression ─────────────
    const sim_smart_ban_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_protocol_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_tests = b.addRunArtifact(sim_smart_ban_tests);
    const test_sim_smart_ban_step = b.step("test-sim-smart-ban", "Run protocol-only smart-ban regression (8 seeds)");
    test_sim_smart_ban_step.dependOn(&run_sim_smart_ban_tests.step);
    test_step.dependOn(&run_sim_smart_ban_tests.step);

    // ── Smart-ban EventLoop integration test ────────────────────
    const sim_smart_ban_eventloop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_eventloop_tests = b.addRunArtifact(sim_smart_ban_eventloop_tests);
    const test_sim_smart_ban_eventloop_step = b.step("test-sim-smart-ban-eventloop", "Run smart-ban EventLoop integration tests");
    test_sim_smart_ban_eventloop_step.dependOn(&run_sim_smart_ban_eventloop_tests.step);
    test_step.dependOn(&run_sim_smart_ban_eventloop_tests.step);

    // ── Phase 2A multi-source piece assembly: protocol-only test ─
    const sim_multi_source_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_multi_source_protocol_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_multi_source_protocol_tests = b.addRunArtifact(sim_multi_source_protocol_tests);
    const test_sim_multi_source_protocol_step = b.step("test-sim-multi-source-protocol", "Run multi-source piece assembly algorithm test (bare DownloadingPiece)");
    test_sim_multi_source_protocol_step.dependOn(&run_sim_multi_source_protocol_tests.step);
    test_step.dependOn(&run_sim_multi_source_protocol_tests.step);

    // ── Phase 2A multi-source EventLoop integration ──────────────
    const sim_multi_source_eventloop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_multi_source_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_multi_source_eventloop_tests = b.addRunArtifact(sim_multi_source_eventloop_tests);
    const test_sim_multi_source_eventloop_step = b.step("test-sim-multi-source-eventloop", "Run multi-source piece assembly EventLoop integration");
    test_sim_multi_source_eventloop_step.dependOn(&run_sim_multi_source_eventloop_tests.step);
    test_step.dependOn(&run_sim_multi_source_eventloop_tests.step);

    // ── Phase 2B smart-ban Phase 1-2 EventLoop integration ───────
    const sim_smart_ban_phase12_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_phase12_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_phase12_tests = b.addRunArtifact(sim_smart_ban_phase12_tests);
    const test_sim_smart_ban_phase12_step = b.step("test-sim-smart-ban-phase12", "Run smart-ban Phase 1-2 per-block attribution EventLoop integration");
    test_sim_smart_ban_phase12_step.dependOn(&run_sim_smart_ban_phase12_tests.step);
    test_step.dependOn(&run_sim_smart_ban_phase12_tests.step);

    // ── Event loop health tests ────────────────────────────
    const el_health_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/event_loop_health_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_el_health = b.addRunArtifact(el_health_tests);
    const test_el_health_step = b.step("test-event-loop", "Run event loop health tests (fd leaks, thread counts)");
    test_el_health_step.dependOn(&run_el_health.step);
    test_step.dependOn(&run_el_health.step);

    // ── Cross-backend smoke: validates the daemon's selected `-Dio=` ─
    // backend can construct an EventLoop, drain a timeout CQE, and tear
    // down without leaking fds. Re-runs the focused subset of test
    // targets that exercise the backend through the comptime selector.
    // Intended invocation pattern:
    //   zig build test-backends -Dio=epoll_posix
    //   zig build test-backends -Dio=epoll_mmap
    //   zig build test-backends                     # default io_uring
    //
    // Sim builds skip the daemon install entirely (`build_daemon == false`
    // when -Dio=sim), so this step is meaningful only for the three
    // production Linux backends.
    const test_backends_step = b.step(
        "test-backends",
        "Run cross-backend boot/tick smoke (selected via -Dio=...)",
    );
    test_backends_step.dependOn(&run_el_health.step);
    if (build_daemon) {
        // The IO-parity test compiles only against `varuna.io.real_io.RealIO`
        // (always io_uring) and `SimIO`, so re-running it under -Dio=epoll_*
        // doesn't add coverage; the contract surface check is comptime
        // anyway. We still include it under the default io_uring build so
        // `zig build test-backends` (no -Dio=) covers the parity check.
        test_backends_step.dependOn(&run_io_parity.step);
    }

    // ── Transfer integration test (single-process piece transfer) ──
    const transfer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/transfer_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_transfer_tests = b.addRunArtifact(transfer_tests);
    const test_transfer_step = b.step("test-transfer", "Run single-process piece transfer integration test");
    test_transfer_step.dependOn(&run_transfer_tests.step);
    test_step.dependOn(&run_transfer_tests.step);

    // ── Seed-serve-after-freePieces regression test ─────────
    // Reproduces the freePieces() bug from commit a4579e9: a seeder that
    // has called Session.freePieces() must still serve REQUESTs. Without
    // the planPieceSpans helper (Defense 1), this test times out because
    // every REQUEST gets silently dropped.
    const seed_serve_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/seed_serve_after_free_pieces_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_seed_serve_tests = b.addRunArtifact(seed_serve_tests);
    const test_seed_serve_step = b.step(
        "test-seed-serve-after-free",
        "Regression: seeder serves REQUEST after Session.freePieces()",
    );
    test_seed_serve_step.dependOn(&run_seed_serve_tests.step);
    test_step.dependOn(&run_seed_serve_tests.step);

    // ── Sim swarm tests (VirtualPeer, clock injection) ──────
    const sim_swarm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_swarm_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_swarm_tests = b.addRunArtifact(sim_swarm_tests);
    const test_sim_swarm_step = b.step("test-sim", "Run virtual-peer swarm simulation tests");
    test_sim_swarm_step.dependOn(&run_sim_swarm_tests.step);
    test_step.dependOn(&run_sim_swarm_tests.step);

    // ── uTP byte stream tests ─────────────────────────────
    const utp_bs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/utp_bytestream_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_utp_bs = b.addRunArtifact(utp_bs_tests);
    const test_utp_bs_step = b.step("test-utp", "Run uTP byte stream tests (handshake, messages, fragmentation)");
    test_utp_bs_step.dependOn(&run_utp_bs.step);
    test_step.dependOn(&run_utp_bs.step);

    // ── Recheck tests (parallel recheck, fast resume) ─────
    const recheck_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/recheck_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_recheck_tests = b.addRunArtifact(recheck_tests);
    const test_recheck_step = b.step("test-recheck", "Run recheck tests (parallel, fast resume)");
    test_recheck_step.dependOn(&run_recheck_tests.step);
    test_step.dependOn(&run_recheck_tests.step);

    // ── Recheck BUGGIFY safety harness (Task A3) ──────────
    const recheck_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/recheck_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_recheck_buggify_tests = b.addRunArtifact(recheck_buggify_tests);
    const test_recheck_buggify_step = b.step(
        "test-recheck-buggify",
        "Run recheck-surface safety-under-randomized-inputs harness (32 seeds)",
    );
    test_recheck_buggify_step.dependOn(&run_recheck_buggify_tests.step);
    test_step.dependOn(&run_recheck_buggify_tests.step);

    // ── SimResumeBackend tests ────────────────────────────
    //
    // Algorithm-level tests for the in-memory `SimResumeBackend` resume DB
    // (Path A from `docs/sqlite-simulation-and-replacement.md`). Pins the
    // public API surface against the `SqliteBackend` baseline and verifies
    // the BUGGIFY-shaped fault knobs (`commit_failure_probability`,
    // `read_failure_probability`, `read_corruption_probability`,
    // `silent_drop_probability`) fire correctly under deterministic seeds.
    const sim_resume_backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_resume_backend_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_resume_backend_tests = b.addRunArtifact(sim_resume_backend_tests);
    const test_sim_resume_backend_step = b.step(
        "test-sim-resume-backend",
        "Run SimResumeBackend algorithm + fault-injection tests",
    );
    test_sim_resume_backend_step.dependOn(&run_sim_resume_backend_tests.step);
    test_step.dependOn(&run_sim_resume_backend_tests.step);

    // ── Recheck live-pipeline BUGGIFY harness (Track 2 #6) ─
    //
    // Wraps the `AsyncRecheckOf(SimIO)` integration tests in
    // `tests/recheck_test.zig` with per-tick `injectRandomFault` plus
    // per-op `FaultConfig.read_error_probability` over 32 deterministic
    // seeds. Catches live-wiring failures the algorithm-level harness
    // can't see: slot cleanup under read-error injection, hasher
    // submission failures, partial completion races.
    const recheck_live_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/recheck_live_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_recheck_live_buggify_tests = b.addRunArtifact(recheck_live_buggify_tests);
    const test_recheck_live_buggify_step = b.step(
        "test-recheck-live-buggify",
        "Run recheck live-pipeline (EventLoopOf(SimIO)) BUGGIFY harness (32 seeds × 3 variants)",
    );
    test_recheck_live_buggify_step.dependOn(&run_recheck_live_buggify_tests.step);
    test_step.dependOn(&run_recheck_live_buggify_tests.step);

    // ── API endpoint tests ─────────────────────────────────
    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/api_endpoints_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_api_tests = b.addRunArtifact(api_tests);
    const test_api_step = b.step("test-api", "Run API endpoint tests");
    test_api_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_api_tests.step);

    // ── API happy-path tests by endpoint family (T4) ───────
    const api_happy_path_tests = [_][]const u8{
        "tests/api_categories_test.zig",
        "tests/api_share_limits_test.zig",
        "tests/api_tracker_edits_test.zig",
        "tests/api_sync_export_test.zig",
    };
    for (api_happy_path_tests) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .imports = &varuna_import,
            }),
        });
        const run_t = b.addRunArtifact(t);
        test_api_step.dependOn(&run_t.step);
        test_step.dependOn(&run_t.step);
    }

    // ── Transport disposition tests ──────────────────────────
    const transport_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/transport_disposition_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_transport_tests = b.addRunArtifact(transport_tests);
    const test_transport_step = b.step("test-transport", "Run transport disposition integration tests");
    test_transport_step.dependOn(&run_transport_tests.step);
    test_step.dependOn(&run_transport_tests.step);

    // ── RPC arena tests (Stage 2 zero-alloc bump allocator) ──
    const rpc_arena_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rpc_arena_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_rpc_arena_tests = b.addRunArtifact(rpc_arena_tests);
    const test_rpc_arena_step = b.step("test-rpc-arena", "Run Stage 2 RPC bump arena tests");
    test_rpc_arena_step.dependOn(&run_rpc_arena_tests.step);
    test_step.dependOn(&run_rpc_arena_tests.step);

    // ── RPC arena BUGGIFY tests (Track C: fault-injection coverage) ──
    const rpc_arena_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rpc_arena_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_rpc_arena_buggify_tests = b.addRunArtifact(rpc_arena_buggify_tests);
    const test_rpc_arena_buggify_step = b.step("test-rpc-arena-buggify", "Run BUGGIFY-style fault-injection coverage for the RPC bump arenas");
    test_rpc_arena_buggify_step.dependOn(&run_rpc_arena_buggify_tests.step);
    test_step.dependOn(&run_rpc_arena_buggify_tests.step);

    // ── Piece tracker cache BUGGIFY tests (Task #5 fix safety-under-faults) ──
    const piece_tracker_cache_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/piece_tracker_cache_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_piece_tracker_cache_buggify_tests = b.addRunArtifact(piece_tracker_cache_buggify_tests);
    const test_piece_tracker_cache_buggify_step = b.step("test-piece-tracker-cache-buggify", "Run BUGGIFY-style randomised stress test for the wanted_completed_count cache");
    test_piece_tracker_cache_buggify_step.dependOn(&run_piece_tracker_cache_buggify_tests.step);
    test_step.dependOn(&run_piece_tracker_cache_buggify_tests.step);

    // ── DHT KRPC + RoutingTable BUGGIFY tests ─────────────
    const dht_krpc_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dht_krpc_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_dht_krpc_buggify_tests = b.addRunArtifact(dht_krpc_buggify_tests);
    const test_dht_krpc_buggify_step = b.step(
        "test-dht-krpc-buggify",
        "Run BUGGIFY-style fuzz coverage for the DHT KRPC parser and routing table",
    );
    test_dht_krpc_buggify_step.dependOn(&run_dht_krpc_buggify_tests.step);
    test_step.dependOn(&run_dht_krpc_buggify_tests.step);

    // ── Shared bencode scanner BUGGIFY / fuzz tests ────────
    const bencode_scanner_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bencode_scanner_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_bencode_scanner_buggify_tests = b.addRunArtifact(bencode_scanner_buggify_tests);
    const test_bencode_scanner_buggify_step = b.step(
        "test-bencode-scanner-buggify",
        "Run BUGGIFY-style fuzz coverage for the shared bencode scanner",
    );
    test_bencode_scanner_buggify_step.dependOn(&run_bencode_scanner_buggify_tests.step);
    test_step.dependOn(&run_bencode_scanner_buggify_tests.step);

    // ── BEP 19 web seed BUGGIFY / fuzz tests ───────────────
    const web_seed_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/web_seed_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_web_seed_buggify_tests = b.addRunArtifact(web_seed_buggify_tests);
    const test_web_seed_buggify_step = b.step(
        "test-web-seed-buggify",
        "Run BUGGIFY-style fuzz coverage for the BEP 19 web seed manager",
    );
    test_web_seed_buggify_step.dependOn(&run_web_seed_buggify_tests.step);
    test_step.dependOn(&run_web_seed_buggify_tests.step);

    // ── BEP 9 ut_metadata + uTP SACK BUGGIFY / fuzz tests ──
    const ut_metadata_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ut_metadata_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_ut_metadata_buggify_tests = b.addRunArtifact(ut_metadata_buggify_tests);
    const test_ut_metadata_buggify_step = b.step(
        "test-ut-metadata-buggify",
        "Run BUGGIFY-style fuzz coverage for the BEP 9 ut_metadata parser and uTP SACK decoder",
    );
    test_ut_metadata_buggify_step.dependOn(&run_ut_metadata_buggify_tests.step);
    test_step.dependOn(&run_ut_metadata_buggify_tests.step);

    // ── Stage 4 zero-alloc: ut_metadata fetch buffer tests ──
    const metadata_fetch_shared_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/metadata_fetch_shared_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_metadata_fetch_shared_tests = b.addRunArtifact(metadata_fetch_shared_tests);
    const test_metadata_fetch_shared_step = b.step(
        "test-metadata-fetch-shared",
        "Run Stage 4 zero-alloc shared-buffer ut_metadata fetch tests",
    );
    test_metadata_fetch_shared_step.dependOn(&run_metadata_fetch_shared_tests.step);
    test_step.dependOn(&run_metadata_fetch_shared_tests.step);

    // ── AsyncMetadataFetchOf(SimIO) integration tests ──────
    //
    // Foundation tests that drive the parameterised metadata-fetch
    // state machine through `EventLoopOf(SimIO)`. Forces the second
    // instantiation through the typechecker and exercises the connect
    // / send / recv error-handling paths inside the state machine.
    const metadata_fetch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/metadata_fetch_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_metadata_fetch_tests = b.addRunArtifact(metadata_fetch_tests);
    const test_metadata_fetch_step = b.step(
        "test-metadata-fetch",
        "Run AsyncMetadataFetchOf(SimIO) integration tests through EventLoopOf(SimIO)",
    );
    test_metadata_fetch_step.dependOn(&run_metadata_fetch_tests.step);
    test_step.dependOn(&run_metadata_fetch_tests.step);

    // ── AsyncMetadataFetchOf(SimIO) live BUGGIFY harness ────
    //
    // 32-seed BUGGIFY harness: per-tick `injectRandomFault` plus per-op
    // FaultConfig (recv/send error probabilities) wraps the happy-path
    // metadata-fetch scenario. Catches handshake-recovery races, partial-
    // send retries, slot cleanup under recv-error injection, and
    // assembler-reset paths the foundation tests can't see.
    const metadata_fetch_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/metadata_fetch_live_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_metadata_fetch_buggify_tests = b.addRunArtifact(metadata_fetch_buggify_tests);
    const test_metadata_fetch_buggify_step = b.step(
        "test-metadata-fetch-live-buggify",
        "Run AsyncMetadataFetchOf(SimIO) live-pipeline BUGGIFY harness (32 seeds)",
    );
    test_metadata_fetch_buggify_step.dependOn(&run_metadata_fetch_buggify_tests.step);
    test_step.dependOn(&run_metadata_fetch_buggify_tests.step);

    // ── PieceStoreOf(SimIO) integration tests ──────────────
    //
    // Exercises the new fallocate + fsync ops on the IO contract via
    // PieceStoreOf(SimIO) — happy path, fault-injected fallocate
    // returning NoSpaceLeft, fault-injected fsync returning IoError,
    // and the skip-when-do_not_download path. Forces the SimIO
    // instantiation through the typechecker (pattern #10).
    const storage_writer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_writer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_storage_writer_tests = b.addRunArtifact(storage_writer_tests);
    const test_storage_writer_step = b.step(
        "test-storage-writer",
        "Run PieceStoreOf(SimIO) integration tests for the new fallocate / fsync contract surface",
    );
    test_storage_writer_step.dependOn(&run_storage_writer_tests.step);
    test_step.dependOn(&run_storage_writer_tests.step);

    // ── PieceStoreOf(SimIO) LIVE BUGGIFY harness ──
    // Wraps the foundation scenarios from `tests/storage_writer_test.zig`
    // with per-tick `injectRandomFault` (via SimIO.pre_tick_hook) plus
    // per-op `FaultConfig` over 32 deterministic seeds. Catches
    // errdefer-cleanup issues, sync's pending-counter under fsync error
    // storms, per-span resubmit racing with cancellation, and
    // mmap-fallback-to-truncate edge cases under composed fault
    // injection.
    const storage_writer_live_buggify_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage_writer_live_buggify_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_storage_writer_live_buggify_tests = b.addRunArtifact(storage_writer_live_buggify_tests);
    const test_storage_writer_live_buggify_step = b.step(
        "test-storage-writer-live-buggify",
        "Run PieceStoreOf(SimIO) live-pipeline BUGGIFY harness (32 seeds × 4 scenarios)",
    );
    test_storage_writer_live_buggify_step.dependOn(&run_storage_writer_live_buggify_tests.step);
    test_step.dependOn(&run_storage_writer_live_buggify_tests.step);

    // ── Per-torrent durability sync tests (R6 fix) ──
    // Drives `EventLoopOf(SimIO).submitTorrentSync` and the periodic
    // sync timer. See `progress-reports/2026-04-28-correctness-fixes.md`
    // for the audit-finding chain.
    const torrent_sync_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/torrent_sync_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_torrent_sync_tests = b.addRunArtifact(torrent_sync_tests);
    const test_torrent_sync_step = b.step(
        "test-torrent-sync",
        "Run per-torrent durability sync wiring tests (submitTorrentSync, periodic timer, shutdown drain)",
    );
    test_torrent_sync_step.dependOn(&run_torrent_sync_tests.step);
    test_step.dependOn(&run_torrent_sync_tests.step);

    // ── RPC server stress test (Track C: connect/disconnect churn) ──
    const rpc_server_stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rpc_server_stress_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_rpc_server_stress_tests = b.addRunArtifact(rpc_server_stress_tests);
    const test_rpc_server_stress_step = b.step("test-rpc-server-stress", "Stress-test ApiServer lifecycle under random close-mid-flight strategies");
    test_rpc_server_stress_step.dependOn(&run_rpc_server_stress_tests.step);
    test_step.dependOn(&run_rpc_server_stress_tests.step);

    // ── Soak test (long-running resource leak detection) ──
    const soak_exe = b.addExecutable(.{
        .name = "varuna-soak-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soak_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const soak_step = b.step("soak-test", "Run long-running soak test for resource leak detection");
    soak_step.dependOn(&b.addRunArtifact(soak_exe).step);

    // ── Swarm integration test ─────────────────────────────
    // Runs the demo_swarm.sh script which starts a tracker, seeder, and
    // downloader, transfers a file, and verifies data integrity.
    const swarm_step = b.step("test-swarm", "Run end-to-end swarm transfer test (requires opentracker)");
    const swarm_cmd = b.addSystemCommand(&.{"./scripts/demo_swarm.sh"});
    swarm_cmd.step.dependOn(b.getInstallStep());
    swarm_step.dependOn(&swarm_cmd.step);

    const swarm_backends_step = b.step("test-swarm-backends", "Run end-to-end swarm transfer test across Linux IO backends");
    const swarm_backends_cmd = b.addSystemCommand(&.{ "env", "SKIP_BUILD=1", "bash", "./scripts/backend_swarm_matrix.sh" });
    swarm_backends_cmd.step.dependOn(b.getInstallStep());
    swarm_backends_step.dependOn(&swarm_backends_cmd.step);

    const perf_swarm_backends_step = b.step("perf-swarm-backends", "Measure live swarm transfer throughput across Linux IO backends");
    const perf_swarm_backends_cmd = b.addSystemCommand(&.{
        "env",
        "SKIP_BUILD=1",
        "SWARM_MATRIX_MODE=perf",
        "bash",
        "./scripts/backend_swarm_matrix.sh",
    });
    perf_swarm_backends_cmd.step.dependOn(b.getInstallStep());
    perf_swarm_backends_step.dependOn(&perf_swarm_backends_cmd.step);

    // ── Benchmarks ────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name = "varuna-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const bench_step = b.step("bench", "Run bootstrap microbenchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    const perf_workload_exe = b.addExecutable(.{
        .name = "varuna-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    if (build_companion_tools) b.installArtifact(perf_workload_exe);

    const perf_workload_step = b.step("perf-workload", "Run synthetic allocation and cache workload scenarios");
    const perf_workload_run = b.addRunArtifact(perf_workload_exe);
    perf_workload_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_workload_run.addArgs(args);
    perf_workload_step.dependOn(&perf_workload_run.step);

    // ── Profiling helpers ─────────────────────────────────
    const installed_exe_path = b.getInstallPath(.bin, "varuna");
    const perf_exe_path = resolvePerfExecutable(b);

    const trace_step = b.step("trace-syscalls", "Run varuna under strace and write perf/output/strace.log");
    const trace_cmd = b.addSystemCommand(&.{
        "strace", "-f", "-yy", "-s", "256", "-o", "perf/output/strace.log", installed_exe_path,
    });
    trace_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| trace_cmd.addArgs(args);
    trace_step.dependOn(&trace_cmd.step);

    const perf_stat_step = b.step("perf-stat", "Run varuna under perf stat and write perf/output/perf-stat.txt");
    const perf_stat_cmd = b.addSystemCommand(&.{
        perf_exe_path, "stat", "-d", "--output", "perf/output/perf-stat.txt", installed_exe_path,
    });
    perf_stat_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_stat_cmd.addArgs(args);
    perf_stat_step.dependOn(&perf_stat_cmd.step);

    const perf_record_step = b.step("perf-record", "Run varuna under perf record and write perf/output/perf.data");
    const perf_record_cmd = b.addSystemCommand(&.{
        perf_exe_path, "record", "-o", "perf/output/perf.data", "--call-graph", "dwarf", installed_exe_path,
    });
    perf_record_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_record_cmd.addArgs(args);
    perf_record_step.dependOn(&perf_record_cmd.step);
}

fn resolvePerfExecutable(b: *std.Build) []const u8 {
    const uts = std.posix.uname();
    const release = std.mem.sliceTo(&uts.release, 0);

    const exact_candidates = [_][]const u8{
        b.pathJoin(&.{ "/usr/lib/linux-tools", release, "perf" }),
        b.fmt("/usr/lib/linux-tools-{s}/perf", .{release}),
    };
    for (exact_candidates) |candidate| {
        if (pathExists(candidate)) return candidate;
    }

    if (findNewestPerfInDir(b, "/usr/lib/linux-tools")) |candidate| return candidate;
    if (findNewestPrefixedPerfInDir(b, "/usr/lib", "linux-tools-")) |candidate| return candidate;

    return "perf";
}

fn findNewestPerfInDir(b: *std.Build, base_dir_path: []const u8) ?[]const u8 {
    var dir = std.fs.openDirAbsolute(base_dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_key: ?[]const u8 = null;
    var best_path: ?[]const u8 = null;
    var iter = dir.iterate();
    while (iter.next() catch return best_path) |entry| {
        switch (entry.kind) {
            .directory, .sym_link => {},
            else => continue,
        }

        const candidate = b.pathJoin(&.{ base_dir_path, entry.name, "perf" });
        if (!pathExists(candidate)) continue;

        if (best_key == null or compareVersionStrings(entry.name, best_key.?) == .gt) {
            best_key = b.dupe(entry.name);
            best_path = candidate;
        }
    }

    return best_path;
}

fn findNewestPrefixedPerfInDir(b: *std.Build, base_dir_path: []const u8, prefix: []const u8) ?[]const u8 {
    var dir = std.fs.openDirAbsolute(base_dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_key: ?[]const u8 = null;
    var best_path: ?[]const u8 = null;
    var iter = dir.iterate();
    while (iter.next() catch return best_path) |entry| {
        switch (entry.kind) {
            .directory, .sym_link => {},
            else => continue,
        }
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

        const version_key = entry.name[prefix.len..];
        const candidate = b.pathJoin(&.{ base_dir_path, entry.name, "perf" });
        if (!pathExists(candidate)) continue;

        if (best_key == null or compareVersionStrings(version_key, best_key.?) == .gt) {
            best_key = b.dupe(version_key);
            best_path = candidate;
        }
    }

    return best_path;
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn compareVersionStrings(a: []const u8, b: []const u8) std.math.Order {
    var a_index: usize = 0;
    var b_index: usize = 0;

    while (true) {
        while (a_index < a.len and isVersionSeparator(a[a_index])) : (a_index += 1) {}
        while (b_index < b.len and isVersionSeparator(b[b_index])) : (b_index += 1) {}

        if (a_index >= a.len and b_index >= b.len) return .eq;
        if (a_index >= a.len) return .lt;
        if (b_index >= b.len) return .gt;

        const a_is_digit = std.ascii.isDigit(a[a_index]);
        const b_is_digit = std.ascii.isDigit(b[b_index]);

        if (a_is_digit and b_is_digit) {
            const a_start = a_index;
            while (a_index < a.len and std.ascii.isDigit(a[a_index])) : (a_index += 1) {}
            const b_start = b_index;
            while (b_index < b.len and std.ascii.isDigit(b[b_index])) : (b_index += 1) {}

            const order = compareNumericChunks(a[a_start..a_index], b[b_start..b_index]);
            if (order != .eq) return order;
            continue;
        }

        if (a_is_digit != b_is_digit) return if (a_is_digit) .gt else .lt;

        const a_start = a_index;
        while (a_index < a.len and !isVersionSeparator(a[a_index]) and !std.ascii.isDigit(a[a_index])) : (a_index += 1) {}
        const b_start = b_index;
        while (b_index < b.len and !isVersionSeparator(b[b_index]) and !std.ascii.isDigit(b[b_index])) : (b_index += 1) {}

        const order = std.ascii.orderIgnoreCase(a[a_start..a_index], b[b_start..b_index]);
        if (order != .eq) return order;
    }
}

fn compareNumericChunks(a: []const u8, b: []const u8) std.math.Order {
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (a_index < a.len and a[a_index] == '0') : (a_index += 1) {}
    while (b_index < b.len and b[b_index] == '0') : (b_index += 1) {}

    const a_trimmed = a[a_index..];
    const b_trimmed = b[b_index..];
    if (a_trimmed.len < b_trimmed.len) return .lt;
    if (a_trimmed.len > b_trimmed.len) return .gt;

    if (a_trimmed.len == 0) return .eq;
    return std.mem.order(u8, a_trimmed, b_trimmed);
}

fn isVersionSeparator(byte: u8) bool {
    return !std.ascii.isAlphanumeric(byte);
}

/// DNS resolver backend selection.
const DnsBackend = enum {
    /// Default: uses getaddrinfo on background threads with 5-second timeout.
    threadpool,
    /// c-ares async DNS library with epoll fd monitoring.
    /// Requires libc-ares-dev (Debian/Ubuntu) or c-ares-devel (RHEL/Fedora).
    c_ares,
    /// In-tree Zig-native resolver living under `src/io/dns_custom/`.
    /// Honors `network.bind_device` (closing the DNS leak the threadpool
    /// backend has, see `docs/custom-dns-design-round2.md` §1) and is
    /// generic over the IO contract so SimIO tests can drive scripted
    /// DNS responses deterministically.
    ///
    /// HTTP and UDP tracker executors instantiate
    /// `DnsResolverOf(IO).resolveAsync()` directly when this backend is
    /// selected. The legacy public `DnsResolver` facade remains available for
    /// non-executor callers that still expect the threadpool-compatible shape.
    custom,
};

/// TLS backend selection.
pub const TlsBackend = enum {
    /// Vendored BoringSSL — enables HTTPS tracker support.
    boringssl,
    /// No TLS — HTTPS tracker URLs will return error.HttpsNotSupported.
    none,
};

/// IO backend selection.
///
/// The daemon today is hard-wired to `io_uring` (Linux). The other backends
/// exist as MVPs that compile their respective IO modules (and tests)
/// cleanly, so cross-compilation can be validated even though the daemon
/// itself does not yet run on those backends.
///
/// File-I/O strategy is a separate axis from the readiness layer. POSIX
/// (`pread`/`pwrite` on a thread pool) and mmap (memcpy + msync) trade off
/// against each other; each readiness backend has both variants so that
/// neither tradeoff is hidden inside the other.
pub const IoBackend = enum {
    /// Default: Linux io_uring via `src/io/real_io.zig`. Production
    /// backend. The only flag under which the full daemon is installed.
    io_uring,
    /// Linux epoll readiness + POSIX file-op thread pool via
    /// `src/io/epoll_posix_io.zig`. Used in sandboxes or seccomp policies
    /// that block io_uring. Sockets + timers + cancel today; file-op
    /// pool is a follow-up.
    epoll_posix,
    /// Linux epoll readiness + mmap-backed file I/O via
    /// `src/io/epoll_mmap_io.zig`. Same readiness layer as `epoll_posix`;
    /// file ops are `memcpy` against a per-fd `mmap` mapping with
    /// `msync(MS_SYNC)` durability.
    epoll_mmap,
    /// macOS / BSD kqueue readiness + POSIX file-op thread pool via
    /// `src/io/kqueue_posix_io.zig`. Sockets + timers + cancel today;
    /// file-op pool is a follow-up.
    kqueue_posix,
    /// macOS / BSD kqueue readiness + mmap-backed file I/O via
    /// `src/io/kqueue_mmap_io.zig` (memcpy + msync, F_PREALLOCATE for
    /// fallocate emulation).
    kqueue_mmap,
    /// In-process SimIO simulator promoted to a top-level option so test
    /// builds can drop the simulator into code currently hard-wired to
    /// io_uring's `RealIO`. Resolves `backend.RealIO` to `sim_io.SimIO`.
    /// Daemon install is skipped; only the IO module + tests are built.
    sim,
};

/// Cryptographic algorithm backend selection.
pub const CryptoBackend = enum {
    /// Default: our SHA-1 with runtime SHA-NI/AArch64 hardware detection,
    /// our RC4, and std SHA-256.
    varuna,
    /// Zig standard library: std.crypto.hash.Sha1, std.crypto.hash.sha2.Sha256.
    /// RC4 falls back to our implementation (no stdlib RC4).
    stdlib,
    /// BoringSSL: SHA1_Init/SHA256_Init/RC4_set_key via @cImport.
    /// Requires -Dtls=boringssl so BoringSSL is linked.
    boringssl,
};

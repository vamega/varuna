const std = @import("std");
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
        "DNS resolver backend: 'threadpool' uses getaddrinfo on background threads (default), 'c-ares' uses the c-ares async DNS library",
    ) orelse .threadpool;

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

    // ── Build options module (dns backend + tls backend + crypto backend) ─
    const build_options = b.addOptions();
    build_options.addOption(DnsBackend, "dns_backend", dns_backend);
    build_options.addOption(TlsBackend, "tls_backend", tls_backend);
    build_options.addOption(CryptoBackend, "crypto_backend", crypto_backend);

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

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
    b.installArtifact(daemon_exe);

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
    b.installArtifact(ctl_exe);

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
    b.installArtifact(tools_exe);

    // ── Run targets ───────────────────────────────────────
    const run_step = b.step("run", "Run the varuna daemon");
    const run_cmd = b.addRunArtifact(daemon_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .root_module = varuna_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const daemon_tests = b.addTest(.{ .root_module = daemon_exe.root_module });
    const run_daemon_tests = b.addRunArtifact(daemon_tests);

    const test_step = b.step("test", "Run the full test suite");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_daemon_tests.step);

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

    // ── SimIO inline tests (socketpair, parking, fault injection) ─
    //
    // The inline `test` blocks in `src/io/sim_io.zig` aren't reachable
    // from any of the other test roots (mod_tests/daemon_tests don't
    // discover transitively imported tests in this codebase). This
    // wrapper imports sim_io.zig directly so its unit tests run.
    const sim_io_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_socketpair_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_io_tests = b.addRunArtifact(sim_io_tests);
    const test_sim_io_step = b.step("test-sim-io", "Run SimIO inline unit tests (socketpair, parking, fault injection)");
    test_sim_io_step.dependOn(&run_sim_io_tests.step);
    test_step.dependOn(&run_sim_io_tests.step);

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

    // ── Smart-ban swarm test (pre-scaffolded for EventLoop swap) ─
    const sim_smart_ban_swarm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_swarm_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_swarm_tests = b.addRunArtifact(sim_smart_ban_swarm_tests);
    const test_sim_smart_ban_swarm_step = b.step("test-sim-smart-ban-swarm", "Run smart-ban swarm test (8 seeds, EventLoop-shaped)");
    test_sim_smart_ban_swarm_step.dependOn(&run_sim_smart_ban_swarm_tests.step);
    test_step.dependOn(&run_sim_smart_ban_swarm_tests.step);

    // ── Smart-ban EventLoop integration test (scaffold only today) ─
    const sim_smart_ban_eventloop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_eventloop_tests = b.addRunArtifact(sim_smart_ban_eventloop_tests);
    const test_sim_smart_ban_eventloop_step = b.step("test-sim-smart-ban-eventloop", "Run smart-ban EventLoop integration (scaffold; lights up after Stage 2 #12)");
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

    // ── Phase 2A multi-source EventLoop integration scaffold ─────
    const sim_multi_source_eventloop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_multi_source_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_multi_source_eventloop_tests = b.addRunArtifact(sim_multi_source_eventloop_tests);
    const test_sim_multi_source_eventloop_step = b.step("test-sim-multi-source-eventloop", "Run multi-source piece assembly EventLoop integration (scaffold; lights up with getBlockAttribution)");
    test_sim_multi_source_eventloop_step.dependOn(&run_sim_multi_source_eventloop_tests.step);
    test_step.dependOn(&run_sim_multi_source_eventloop_tests.step);

    // ── Phase 2B smart-ban Phase 1-2 EventLoop integration scaffold ─
    const sim_smart_ban_phase12_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sim_smart_ban_phase12_eventloop_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_sim_smart_ban_phase12_tests = b.addRunArtifact(sim_smart_ban_phase12_tests);
    const test_sim_smart_ban_phase12_step = b.step("test-sim-smart-ban-phase12", "Run smart-ban Phase 1-2 per-block attribution EventLoop integration (scaffold)");
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

    // ── Piece tracker cache tests (Task #5 tick_sparse_torrents fix) ──
    const piece_tracker_cache_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/piece_tracker_cache_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &varuna_import,
        }),
    });
    const run_piece_tracker_cache_tests = b.addRunArtifact(piece_tracker_cache_tests);
    const test_piece_tracker_cache_step = b.step("test-piece-tracker-cache", "Run wanted_completed_count cache regression tests");
    test_piece_tracker_cache_step.dependOn(&run_piece_tracker_cache_tests.step);
    test_step.dependOn(&run_piece_tracker_cache_tests.step);

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
    b.installArtifact(perf_workload_exe);

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
};

/// TLS backend selection.
pub const TlsBackend = enum {
    /// Vendored BoringSSL — enables HTTPS tracker support.
    boringssl,
    /// No TLS — HTTPS tracker URLs will return error.HttpsNotSupported.
    none,
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

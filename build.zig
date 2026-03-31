const std = @import("std");
const boringssl = @import("build/boringssl.zig");

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

    const tls_backend = b.option(
        TlsBackend,
        "tls",
        "TLS backend: 'boringssl' links vendored BoringSSL for HTTPS tracker support (default), 'none' disables TLS",
    ) orelse .boringssl;

    // ── Build options module (dns backend + tls backend selection) ────────
    const build_options = b.addOptions();
    build_options.addOption(DnsBackend, "dns_backend", dns_backend);
    build_options.addOption(TlsBackend, "tls_backend", tls_backend);

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
        varuna_mod.linkSystemLibrary("cares", .{});
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

    // ── Profiling helpers ─────────────────────────────────
    const installed_exe_path = b.getInstallPath(.bin, "varuna");

    const trace_step = b.step("trace-syscalls", "Run varuna under strace and write perf/output/strace.log");
    const trace_cmd = b.addSystemCommand(&.{
        "strace", "-f", "-yy", "-s", "256", "-o", "perf/output/strace.log", installed_exe_path,
    });
    trace_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| trace_cmd.addArgs(args);
    trace_step.dependOn(&trace_cmd.step);

    const perf_stat_step = b.step("perf-stat", "Run varuna under perf stat and write perf/output/perf-stat.txt");
    const perf_stat_cmd = b.addSystemCommand(&.{
        "perf", "stat", "-d", "--output", "perf/output/perf-stat.txt", installed_exe_path,
    });
    perf_stat_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_stat_cmd.addArgs(args);
    perf_stat_step.dependOn(&perf_stat_cmd.step);

    const perf_record_step = b.step("perf-record", "Run varuna under perf record and write perf/output/perf.data");
    const perf_record_cmd = b.addSystemCommand(&.{
        "perf", "record", "-o", "perf/output/perf.data", "--call-graph", "dwarf", installed_exe_path,
    });
    perf_record_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_record_cmd.addArgs(args);
    perf_record_step.dependOn(&perf_record_cmd.step);
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

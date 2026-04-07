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

    // ── varuna-tui (terminal UI) ──────────────────────────
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const tui_exe = b.addExecutable(.{
        .name = "varuna-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigzag", .module = zigzag_dep.module("zigzag") },
                .{ .name = "zio", .module = zio_dep.module("zio") },
            },
        }),
    });
    b.installArtifact(tui_exe);

    const run_tui_step = b.step("tui", "Run the varuna TUI");
    const run_tui_cmd = b.addRunArtifact(tui_exe);
    run_tui_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui_cmd.addArgs(args);
    run_tui_step.dependOn(&run_tui_cmd.step);

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

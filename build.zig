const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_mode = b.option(
        enum { system, bundled },
        "sqlite",
        "SQLite linking strategy: 'system' links libsqlite3, 'bundled' compiles the amalgamation from vendor/sqlite/",
    ) orelse .system;

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

    const varuna_mod = b.addModule("varuna", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod },
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

    const exe = b.addExecutable(.{
        .name = "varuna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "varuna", .module = varuna_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the varuna daemon");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = varuna_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run the full test suite");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "varuna-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "varuna", .module = varuna_mod },
            },
        }),
    });

    const bench_step = b.step("bench", "Run bootstrap microbenchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

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

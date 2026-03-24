# Repository Guidelines

## Project Structure & Module Organization
This repository is currently in bootstrap stage. Keep the root minimal and move implementation under `src/` as the codebase forms. Use `src/main.zig` for the entrypoint, and split major subsystems into focused directories such as `src/core/`, `src/net/`, `src/storage/`, `src/tracker/`, and `src/rpc/`. Put reusable test fixtures in `testdata/`. Keep benchmarking and profiling helpers in `perf/` or `scripts/`. Use `reference-codebases/` for local study of `rtorrent`, both `libtorrent` codebases, `qbittorrent`, and `vortex` when validating protocol behavior, startup strategies, storage design, or API compatibility.

## Build, Test, and Development Commands
Use Zig stable only: Zig `0.15.2` or the latest stable release, never nightly.
Use `mise` to install project tools locally, and keep tool versions pinned in `mise.toml`.

- `mise install`: install pinned developer tools from `mise.toml`.
- `zig build`: compile the daemon and default targets.
- `zig build test`: run the full unit and integration test suite.
- `zig build bench`: run microbenchmarks and storage/network performance checks.
- `zig fmt .`: format all Zig sources.

Add new commands to `build.zig` instead of ad hoc shell scripts when practical.

## Coding Style & Naming Conventions
Use `zig fmt` as the formatting authority. Prefer small modules, explicit ownership, and low-allocation designs. Default to arena or slab-backed allocation where dynamic memory is unavoidable. Use `snake_case` for files, functions, and local variables; `PascalCase` for types; and descriptive subsystem names like `piece_picker.zig` or `disk_scheduler.zig`. Keep Linux- and io_uring-specific code explicit rather than hidden behind generic abstractions.

## Testing Guidelines
Write tests alongside code with `test` blocks for unit coverage, and place broader scenarios under `tests/` as the suite grows. Prioritize protocol correctness, piece verification, persistence safety, and performance regressions. Include benchmarks for HDD, SSD, and mergerfs-oriented access patterns. Name tests after behavior, for example `test "rejects invalid bencode length"`.

## Commit & Pull Request Guidelines
There is no history yet, so start with short imperative commit subjects, for example `storage: add piece file mapper`. Keep commits scoped to one subsystem. Pull requests should include intent, major design tradeoffs, test coverage, and benchmark deltas when performance-sensitive code changes. Include kernel or filesystem assumptions when relevant.

## Scope Notes
Target Linux only, modern kernels only, and a headless daemon first. Private-tracker BEPs come before public-tracker features. Network filesystems are out of scope.

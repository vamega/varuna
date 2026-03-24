# Repository Guidelines

## Project Structure & Module Organization
Keep the root minimal and move implementation under `src/` as the codebase forms. Use `src/main.zig` for the entrypoint, and split major subsystems into focused directories such as `src/core/`, `src/net/`, `src/storage/`, `src/tracker/`, and `src/rpc/`. Put reusable test fixtures in `testdata/`. Keep benchmarking and profiling helpers in `perf/` or `scripts/`. Use `reference-codebases/` for local study of `rtorrent`, both `libtorrent` codebases, `qbittorrent`, and `vortex` when validating protocol behavior, startup strategies, storage design, or API compatibility.

Keep [DECISIONS.md](DECISIONS.md) updated whenever scope, constraints, architecture choices, or profiling strategy change. Keep [perf/README.md](perf/README.md) aligned with the actual profiling workflow and available build steps.

## Build, Test, and Development Commands
Use Zig stable only: Zig `0.15.2` or the latest stable release, never nightly.
Use `mise` to install project tools locally, and keep tool versions pinned in `mise.toml`.

Ensure local developer documentation is available before doing substantial Linux or `io_uring` work. On Ubuntu 24.04 this means keeping `man-db`, `manpages`, `manpages-dev`, `manpages-posix`, `manpages-posix-dev`, and `liburing-dev` installed so syscall, POSIX, and `io_uring` man pages are locally searchable. `liburing-dev` specifically provides the `io_uring_*` man pages and the `io_uring_setup(2)` / `io_uring_enter(2)` / `io_uring_register(2)` pages.

Ensure the repositories under `reference-codebases/` remain checked out and readable before relying on them for protocol, tracker, storage, or startup-behavior comparisons.

Expected reference repositories:
- `reference-codebases/libtorrent`
- `reference-codebases/libtorrent-rakshasa`
- `reference-codebases/qbittorrent`
- `reference-codebases/rtorrent`
- `reference-codebases/vortex`

Clone commands to restore them:

```bash
mkdir -p reference-codebases
git clone https://github.com/arvidn/libtorrent.git reference-codebases/libtorrent
git clone https://github.com/rakshasa/libtorrent.git reference-codebases/libtorrent-rakshasa
git clone https://github.com/qbittorrent/qBittorrent.git reference-codebases/qbittorrent
git clone https://github.com/rakshasa/rtorrent.git reference-codebases/rtorrent
git clone https://github.com/Nehliin/vortex.git reference-codebases/vortex
```

- `mise install`: install pinned developer tools from `mise.toml`.
- `zig build`: compile the daemon and default targets.
- `zig build test`: run the full unit and integration test suite.
- `zig build bench`: run microbenchmarks and storage/network performance checks.
- `zig build trace-syscalls -- ...`: run `varuna` under `strace` and write `perf/output/strace.log`.
- `zig build perf-stat -- ...`: run `varuna` under `perf stat` and write `perf/output/perf-stat.txt`.
- `zig build perf-record -- ...`: run `varuna` under `perf record` and write `perf/output/perf.data`.
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

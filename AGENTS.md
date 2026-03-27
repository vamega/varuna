# Repository Guidelines

## Project Structure & Module Organization
Keep the root minimal and move implementation under `src/` as the codebase forms. Use `src/main.zig` for the entrypoint, and split major subsystems into focused directories such as `src/core/`, `src/net/`, `src/storage/`, `src/tracker/`, and `src/rpc/`. Put reusable test fixtures in `testdata/`. Keep benchmarking and profiling helpers in `perf/` or `scripts/`. Use `reference-codebases/` for local study of `rtorrent`, both `libtorrent` codebases, `qbittorrent`, and `vortex` when validating protocol behavior, startup strategies, storage design, or API compatibility.

Keep [DECISIONS.md](DECISIONS.md) updated whenever scope, constraints, architecture choices, or profiling strategy change. Keep [STATUS.md](STATUS.md) updated with completed work, next work, and known issues. Keep [perf/README.md](perf/README.md) aligned with the actual profiling workflow and available build steps. When existing markdown files are no longer enough to capture ongoing decisions, plans, workflows, compatibility notes, or risks, add a new markdown file in the appropriate location and link it from `AGENTS.md` plus the most relevant existing document so later agents can discover it quickly.

## Progress Reports & Work Log
After completing meaningful work (bug fixes, new features, architectural changes), write a short report in `progress-reports/`. Each file should be named descriptively (e.g., `2026-03-27-connect-sqe-dangling-pointer.md`) and contain:
- What was done and why
- What was learned (especially non-obvious things about io_uring, Zig, or BitTorrent protocol)
- Any remaining issues or follow-up work
- Code references (file:line) for key changes

This serves as institutional memory -- future agents can read these to understand past decisions, pitfalls encountered, and patterns that worked. Keep entries concise but include enough detail that someone unfamiliar with the change can understand the root cause and fix.

## Build, Test, and Development Commands
Use Zig stable only: Zig `0.15.2` or the latest stable release, never nightly.
Use `mise` to install project tools locally, and keep tool versions pinned in `mise.toml`.

SQLite3 is required for resume state persistence. Install `libsqlite3-dev` on Ubuntu/Debian. If the `-dev` package is not available, the `lib/libsqlite3.so` symlink in the project root points to the system shared library. SQLite operations MUST run on a background thread, never on the io_uring event loop thread (see `docs/io-uring-syscalls.md`).

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
- `./scripts/demo_swarm.sh`: build a local `.torrent`, start the packaged `opentracker`, run one `varuna seed` and one `varuna download`, and verify the payload transfer.

Add new commands to `build.zig` instead of ad hoc shell scripts when practical.

For local tracker validation, prefer `scripts/tracker.sh` plus `varuna inspect` or `scripts/demo_swarm.sh` instead of inventing new one-off workflows. The Ubuntu `opentracker` package in this repository is built in whitelist mode, so agents must pass `--whitelist-hash <info-hash>` to `scripts/tracker.sh` for any torrent they expect the tracker to authorize.

## io_uring Policy (IMPORTANT -- applies to `varuna` daemon only)
The `varuna` daemon is the performance-critical binary. All hot-path I/O in the daemon MUST go through `io_uring` via `src/io/ring.zig`. Do NOT use `std.fs.File` read/write/sync methods or `std.net.Stream` read/write methods for daemon I/O. These generate conventional syscalls instead of `io_uring_enter`.

**Daemon I/O (`varuna`) -- must use io_uring:**
- Piece storage reads and writes (`PieceStore` in `src/storage/writer.zig`)
- Peer wire protocol send and receive (event loop in `src/io/event_loop.zig`)
- TCP connect, accept, and socket creation for peer connections
- HTTP API server accept, recv, send (`src/rpc/server.zig`)
- HTTP tracker client connect, send, recv (`src/io/http.zig`)
- File fsync/fdatasync, fallocate

**`varuna-ctl` and `varuna-tools` -- no io_uring requirement:**
These are short-lived CLI tools, not performance-critical. They MAY use io_uring if convenient (and currently do for HTTP), but standard library I/O (`std.net`, `std.fs`, `std.http`) is perfectly acceptable. Simplicity and correctness matter more than syscall efficiency for these binaries.

**Acceptable exceptions in the daemon** (not hot path):
- File creation, directory setup, and truncation during `PieceStore.init` (one-time setup)
- Stdout logging via `std.Io.Writer` (infrequent status messages)
- Test helpers that simulate peers/trackers (not production code)
- The `uname` syscall in runtime probing
- SQLite operations (run on a background thread, not the event loop)

When adding new I/O paths to the daemon, always use the Ring or event loop. Verify with `strace -f -yy -c` that daemon hot paths route through `io_uring_enter`.

See [docs/io-uring-syscalls.md](docs/io-uring-syscalls.md) for the full syscall reference, current io_uring coverage, and notes on DNS resolution, SHA hardware acceleration, and SQLite resume state.

See [docs/future-features.md](docs/future-features.md) for planned features: systemd-notify, SHA-NI acceleration, uTP, SO_BINDTODEVICE, socket activation, UDP tracker, DHT/PEX, magnet links, encryption.

## Coding Style & Naming Conventions
Use `zig fmt` as the formatting authority. Prefer small modules, explicit ownership, and low-allocation designs. Default to arena or slab-backed allocation where dynamic memory is unavoidable. Use `snake_case` for files, functions, and local variables; `PascalCase` for types; and descriptive subsystem names like `piece_picker.zig` or `disk_scheduler.zig`. Keep Linux- and io_uring-specific code explicit rather than hidden behind generic abstractions.

## Testing Guidelines
Write tests alongside code with `test` blocks for unit coverage, and place broader scenarios under `tests/` as the suite grows. Prioritize protocol correctness, piece verification, persistence safety, and performance regressions. Include benchmarks for HDD, SSD, and mergerfs-oriented access patterns. Name tests after behavior, for example `test "rejects invalid bencode length"`.

## Commit & Pull Request Guidelines
There is no history yet, so start with short imperative commit subjects, for example `storage: add piece file mapper`. Keep commits scoped to one subsystem. Pull requests should include intent, major design tradeoffs, test coverage, and benchmark deltas when performance-sensitive code changes. Include kernel or filesystem assumptions when relevant.

## Scope Notes
Target Linux only, modern kernels only, and a headless daemon first. Private-tracker BEPs come before public-tracker features. Network filesystems are out of scope.

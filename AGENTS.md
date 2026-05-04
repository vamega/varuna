# Repository Guidelines

## Current Layout
Keep implementation under `src/`. The current major subsystems are:
- `src/daemon/` - session orchestration, torrent lifecycle, queueing, relocation
- `src/io/` - io_uring event loop, peer handlers, protocol I/O, HTTP client, sockets, async recheck, async metadata fetch
- `src/torrent/` - metainfo parsing, piece tracking, layouts, torrent state, creation
- `src/storage/` - piece storage, verification, state persistence (state_db.zig), disk integrity
- `src/net/` - peer helpers, web seeds, metadata fetch, PEX, uTP
- `src/tracker/` - HTTP/UDP tracker announce and scrape behavior
- `src/dht/` - DHT engine, lookups, KRPC, routing, persistence
- `src/rpc/` - qBittorrent-compatible WebAPI handlers, sync state, auth, HTTP server
- `src/crypto/` - MSE, hashing helpers, RC4, crypto backends
- `src/runtime/` - runtime/kernel probing and startup gating
- `src/sim/` - simulator, virtual peers, deterministic I/O backend for simulation-first tests
- `src/ctl/` - `varuna-ctl` daemon control CLI
- `src/tools/` - `varuna-tools` (torrent create / inspect)
- `src/bench/` - CPU microbenchmarks (parser, bencode, SHA-1, metainfo) wired through `zig build bench`
- `src/perf/` - benchmarks and profiling helpers exposed through `build.zig`
- `src/automation/` - Zig-based repository automation and harnesses that replace ad hoc shell scripting; intentionally isolated from daemon/core modules

Keep reusable fixtures in `testdata/`. Keep profiling helpers in `perf/` or `scripts/`.

Read these first when orienting:
- [STYLE.md](STYLE.md) - coding style, design goals, IO abstraction model, simulation-first testing philosophy
- [STATUS.md](STATUS.md) - current implementation state, completed work, known issues, next work
- [progress-reports/2026-04-06-codebase-review.md](progress-reports/2026-04-06-codebase-review.md) - subsystem inventory and review notes
- [docs/api-compatibility.md](docs/api-compatibility.md) - qBittorrent WebAPI compatibility status
- [docs/dht-bep52-plan.md](docs/dht-bep52-plan.md) - remaining BEP 52 creation work and longer-range DHT follow-up

Keep [DECISIONS.md](DECISIONS.md), [STATUS.md](STATUS.md), and [perf/README.md](perf/README.md) current. If new markdown is needed for plans, risks, workflows, or compatibility notes, add it in the right location and link it from `AGENTS.md` and the most relevant existing doc.

## Progress Reports
After meaningful work, add a short file under `progress-reports/` named like `2026-03-27-connect-sqe-dangling-pointer.md` with:
- what changed and why
- what was learned
- remaining issues or follow-up
- key code references (`file:line`)

These reports are institutional memory. Keep them concise but specific.

## Build And Test
Use Zig stable only: `0.15.2` or the latest stable release, never nightly.

Use `mise` for pinned tools in `mise.toml`:
- run `mise trust` in new checkouts/worktrees before `mise exec`
- run `mise install` to install pinned tools

Required local setup:
- SQLite dev package: `libsqlite3-dev` on Ubuntu/Debian
- c-ares dev package (`libc-ares-dev`) when using `-Ddns=c_ares -Dcares=system`
- BoringSSL package when using `-Dtls=system_boringssl`; otherwise initialize `vendor/boringssl`
- local Linux/io_uring docs for substantial kernel work: `man-db`, `manpages`, `manpages-dev`, `manpages-posix`, `manpages-posix-dev`, `liburing-dev`
- git submodules initialized with `git submodule update --init`
- `vendor/boringssl` and `vendor/c-ares` initialized for default bundled builds, or use the system-link build flags with matching system packages
- do not add checked-in `libsqlite3.so` symlinks; use system SQLite from the distro/Nix dev shell or pass Zig `--search-prefix`

### Worktree setup

`git worktree add` does NOT auto-populate submodules — they start empty in the new tree. After creating a worktree, run:

```
scripts/setup-worktree.sh <worktree-path>
```

That shallow-initializes (`--depth 1`) the build-dep submodules `vendor/boringssl` + `vendor/c-ares`, symlinks `reference-codebases/` from the main checkout (read-only — never modify reference codebases inside a worktree, the symlink reaches main's submodule pointers), and symlinks `.zig-cache/` to the main checkout so worker builds share the compiler cache. `zig-out/` stays per-worktree so branch builds do not overwrite each other's binaries. The script also marks the tracked `reference-codebases/*` gitlinks as `skip-worktree` in the worker checkout and adds local excludes for setup symlinks, so those artifacts do not appear in `git status`.

Note: `reference-codebases/*` submodules are *registered* in `.gitmodules` but **not** initialized by `setup-worktree.sh` (the script only creates the symlink). In a fresh main checkout they are empty until you run `git submodule update --init reference-codebases/<name>` explicitly. In worktrees, the symlink resolves to the main checkout's reference-codebases tree, so they appear populated only if main has initialized them.

Reference repos under `reference-codebases/`:
- `libtorrent` - arvidn/libtorrent
- `libtorrent-rakshasa` - rakshasa/libtorrent
- `qbittorrent` - qBittorrent
- `rtorrent` - rakshasa/rtorrent
- `vortex` - Nehliin/vortex
- `qui` - autobrr/qui
- `tigerbeetle` - tigerbeetle/tigerbeetle
- `libxev` - mitchellh/libxev
- `zio` - lalinsky/zio

Core commands:
- `zig build`
- `zig build test`
- `zig build test-torrent-session`
- `zig build bench`
- `zig build test-swarm`
- `zig build perf-swarm-backends`
- `zig build perf-real-torrents -- ...`
- `zig build trace-syscalls -- ...`
- `zig build perf-stat -- ...`
- `zig build perf-record -- ...`
- `zig fmt .`

Run `zig build --help` for the full list — there are 40+ focused test/sim/buggify/parity targets beyond the ones above (e.g. `test-sim-*`, `test-api`, `test-recheck`, `test-event-loop`, `test-bind-device`, `test-swarm`, `soak-test`).

Rules:
- add practical new commands to `build.zig` instead of one-off shell scripts
- avoid adding new shell scripts for repeatable repo automation; add Zig code under `src/automation/` or a focused tool binary instead
- when touching existing shell-driven workflows, prefer migrating them to `src/automation/` and calling them from `build.zig`
- do not rely on direct-file `zig test src/...`; this repo is wired through `build.zig`
- when a subsystem becomes a repeated hotspot, add a focused `zig build <step>` target for it
- for tracker validation, prefer `zig build test-swarm` / `zig build perf-swarm-backends`; legacy scripts in `scripts/` should be treated as compatibility shims or migration candidates
- the packaged Ubuntu `opentracker` runs in whitelist mode; pass `--whitelist-hash <info-hash>` to `scripts/tracker.sh`

## io_uring Policy
This is a current operating rule for the daemon, not a design aspiration.

The `varuna` daemon is performance-critical. **All daemon networking and file I/O must go through `io_uring`** via the event loop and ring plumbing in `src/io/`. Do not use `std.fs.File` read/write/sync methods, `std.net.Stream` read/write methods, or raw `posix.connect`/`posix.read`/`posix.write`/`posix.sendto`/`posix.recvfrom` for any daemon I/O. This applies to all paths, not just "hot" paths.

Daemon paths that must use `io_uring`:
- piece storage reads and writes (including recheck/verification)
- peer wire send and receive
- peer TCP connect, accept, and socket creation
- RPC server accept, recv, and send
- HTTP tracker client connect, send, and recv
- UDP tracker client sendto and recvfrom
- metadata fetch (BEP 9) peer connections and wire I/O
- fsync/fdatasync and fallocate
- timers and delays (use timerfd on the ring, not `Thread.sleep`)

`varuna-ctl` and `varuna-tools` are different: standard library I/O is acceptable there.

Allowed daemon exceptions (background threads only):
- SQLite operations -- the resume database (`src/storage/state_db.zig`) is opened with `SQLITE_OPEN_FULLMUTEX`, so SQLite's own internal mutex serialises concurrent access. The shared `ResumeDb` connection (held in `SessionManager.resume_db`) is intentionally accessed concurrently from worker threads (`TorrentSession.startWorker` background init), RPC handlers (settings / tracker-overrides loads), and the `QueueManager` (queue position persistence). The single hard invariant: never call SQLite from the event-loop thread, since SQLite syscalls block.
- CPU-bound piece hashing -- the hasher thread pool in `src/io/hasher.zig`
- one-time file creation, directory setup, and truncation during `PieceStore.init`
- stdout logging
- test helpers that simulate peers or trackers
- `uname` for runtime probing
- sd_notify (`src/daemon/systemd.zig`) -- one-shot AF_UNIX `connect`/`write` to the `$NOTIFY_SOCKET` for `READY=1` / `STOPPING=1`. Best-effort startup/shutdown notification, not on any hot path.

**Do not spawn background threads for I/O.** If something needs to happen concurrently, submit it as io_uring SQEs. Background threads are only for CPU-bound work (hashing) and APIs that cannot use io_uring (SQLite, DNS without c-ares). The multi-tracker announce thread pool and the `startWorker` blocking-I/O patterns are known violations being removed.

When adding daemon I/O, use the ring or event loop and verify with `strace -f -yy -c` that it routes through `io_uring_enter`.

See [docs/io_uring_static_violation_analysis.md](docs/io_uring_static_violation_analysis.md) for the static analysis of current and historical violations.

## Key Docs
- [docs/io-uring-syscalls.md](docs/io-uring-syscalls.md) - syscall reference and current io_uring coverage
- [docs/future-features.md](docs/future-features.md) - deferred and follow-up work only, not a missing-feature inventory
- [docs/dht-bep52-plan.md](docs/dht-bep52-plan.md) - planning/follow-up context; check [STATUS.md](STATUS.md) before assuming items are still pending
- [docs/api-compatibility.md](docs/api-compatibility.md) - endpoint coverage, placeholders, unsupported endpoints
- [docs/sim-test-setup.md](docs/sim-test-setup.md) - sim test API requirements (Phase 0 smart-ban / `EventLoopOf(SimIO)` baseline)
- [docs/multi-source-test-setup.md](docs/multi-source-test-setup.md) - Phase 2A multi-source piece assembly + Phase 2B smart-ban Phase 1-2 test API surface

Before assuming a feature is absent, check [STATUS.md](STATUS.md), recent `progress-reports/`, and the relevant subsystem under `src/`.

## Style
Use `zig fmt`. Prefer small modules, explicit ownership, and low-allocation designs. Use `snake_case` for files/functions/locals and `PascalCase` for types. Keep Linux- and io_uring-specific code explicit.

For the simulation-first testing model and the IO abstraction that backs it, see [STYLE.md](STYLE.md), [docs/simulation-roadmap.md](docs/simulation-roadmap.md), and [docs/io-abstraction-plan.md](docs/io-abstraction-plan.md).

## Testing
Write unit tests inline with `test` blocks. Put broader scenarios under `tests/`. Prioritize protocol correctness, piece verification, persistence safety, and performance regressions. Name tests after behavior, for example `test "rejects invalid bencode length"`.

## Commits And PRs
Use short imperative commit subjects, for example `storage: add piece file mapper`. Keep commits scoped to one subsystem. PRs should include intent, design tradeoffs, test coverage, and benchmark deltas for performance-sensitive changes.

## Scope
Linux + io_uring is the design focus. Private-tracker BEPs come before public-tracker features. Network filesystems are out of scope.

Alternate IO backends exist for narrow reasons:
- `epoll` (`src/io/epoll_posix_io.zig`, `src/io/epoll_mmap_io.zig`) — for users who want to run varuna inside a container or sandbox that blocks the `io_uring` syscalls.
- `kqueue` (`src/io/kqueue_*.zig`) — for development on macOS only.

These are not the primary deployment target. New daemon I/O code must still use the ring (see io_uring Policy); the alternate backends ride on the same `EventLoopOf(...)` contract surface so they pick up new behavior automatically when the contract is implemented correctly.

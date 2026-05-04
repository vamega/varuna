# Varuna

Varuna is a headless BitTorrent client in Zig for Linux, currently at an early minimal-client stage. The project is named after the Hindu god of water and also ties back to the author’s name. The design target is still a high-performance daemon that leans heavily on `io_uring`, keeps allocations tightly controlled, and scales to thousands or tens of thousands of torrents.

## Current Status

Varuna is a functional headless BitTorrent daemon with:

- **Full download/seed pipeline**: multi-peer rarest-first piece selection, endgame mode, tit-for-tat choking, block pipelining, selective file download, sequential mode.
- **All I/O through io_uring**: peer connections, disk reads/writes, tracker HTTP/UDP, uTP, DHT, API server, timers. Verified via bpftrace — zero daemon networking syscalls bypass io_uring.
- **Tracker support**: HTTP, HTTPS (BoringSSL), UDP (BEP 15), multi-tracker (BEP 12), scrape. All async via ring-based executors.
- **Protocol extensions**: uTP (BEP 29), DHT (BEP 5), PEX (BEP 11), magnet links (BEP 9), MSE/PE encryption (BEP 6), super-seeding (BEP 16), partial seeds (BEP 21), BEP 52 v2/hybrid support.
- **Web seeds (BEP 19)**: HTTP Range-based piece downloads with multi-piece batching, connection pooling, configurable request size.
- **qBittorrent-compatible API**: 71 endpoints for WebUI clients (Flood, VueTorrent, qui).
- **Tooling**: `varuna-tools create` for torrent creation (mktorrent-compatible, parallel hashing at 3+ GB/s), `varuna-tools inspect` for torrent inspection. `varuna-ctl` for daemon control.

```bash
# Daemon
varuna                                    # starts daemon (reads varuna.toml)

# CLI control
varuna-ctl add /path/to/file.torrent
varuna-ctl add --magnet "magnet:?xt=..."
varuna-ctl list
varuna-ctl info <hash>

# Tooling
varuna-tools create -a http://tracker/announce -o out.torrent /path/to/file
varuna-tools create --hybrid -w http://webseed/file -t 8 /path/to/file
varuna-tools inspect file.torrent
```

### Known Limitations

- **`network.bind_device` is silently bypassed by the default threadpool DNS backend**: peer connections, uTP/DHT, RPC, and tracker clients honor `bind_device`, but `getaddrinfo` owns its own UDP socket internally with no hook for `SO_BINDTODEVICE`. Workaround: build with `-Ddns=c_ares`, which applies `bind_device` for every socket the c-ares channel opens. Full fix queued behind the custom-DNS work in `docs/custom-dns-design-round2.md` §1.

The living scope and architecture record lives in [DECISIONS.md](DECISIONS.md). Keep that file updated as constraints and design choices change.
Use [STATUS.md](STATUS.md) as the current ledger for what is already implemented, what is next, and which issues are still open.

## Testing

```bash
zig build test                    # all unit tests
zig build test-swarm              # e2e: seeder → downloader via tracker (TCP + uTP)
./scripts/test_web_seed.sh        # e2e: web seed download (3 scenarios, BEP 19)
```

The swarm harness creates a torrent with `varuna-tools create`, starts opentracker with the info hash whitelisted, runs a seeder and downloader daemon, and verifies the downloaded payload.

## Project Direction
Varuna is intended for local Linux storage only. SSDs, HDDs, mergerfs, ext4, xfs, btrfs, bcachefs, and zfs matter; network filesystems such as NFS and CIFS do not. The initial focus is private-tracker functionality and operational reliability, not broad feature coverage or plugin systems.
Private-tracker compatibility should be good enough to meet or exceed common rTorrent workflows.

The current baseline kernel target is Linux `6.6`, matching WSL2. If `io_uring` behavior in Linux `6.8` turns out to be materially better for the storage or networking design, `6.8` is an acceptable minimum instead. Newer kernel features should be used through runtime capability detection rather than by dropping support for `6.6` immediately.

Reference implementations worth studying:
- `libtorrent`: protocol behavior, tracker compatibility, operational features
- `rtorrent`: long-lived private-tracker workflows and headless ergonomics
- `vortex`: examples of a BitTorrent client built around `io_uring`

## Building from source

Linux only. Kernel `6.6` minimum (WSL2 baseline).

System packages (Ubuntu/Debian):

```bash
sudo apt install libsqlite3-dev liburing-dev
```

The build links system SQLite by default. With Nix, enter the dev shell; it
provides SQLite, c-ares, and BoringSSL packages for system-link builds. Outside
Nix, pass package prefixes explicitly when they are not on the default linker
path, for example `zig build --search-prefix /path/to/sqlite-prefix`.

HTTPS support defaults to vendored BoringSSL (`-Dtls=boringssl`). For faster
clean rebuilds in environments that provide BoringSSL, use
`-Dtls=system_boringssl` with matching `--search-prefix` values for the library
and headers.

Toolchain — Zig stable (`0.15.2` or the latest stable; never nightly), pinned via `mise`:

```bash
mise trust          # in new checkouts/worktrees, before mise exec
mise install
```

Submodules and build:

```bash
git submodule update --init       # vendor/boringssl, vendor/c-ares, reference-codebases
zig build                         # produces varuna, varuna-ctl, varuna-tools
zig build test                    # all unit tests
```

For worktrees, run `scripts/setup-worktree.sh <path>` instead of plain `git submodule update --init` — it initializes the build-dep submodules and symlinks `reference-codebases/` from the main checkout. See [AGENTS.md](AGENTS.md) for the full contributor workflow.

## Working Principles
- Prefer `io_uring` where it actually improves the design.
- Avoid unnecessary allocations; prefer slab or arena strategies.
- Keep configuration minimal and high-level.
- Detect hardware characteristics automatically where possible.
- Treat benchmarks and soak tests as core project work, not cleanup.
- Prefer compatibility with Flood by implementing a useful subset of the qBittorrent Web API early.
- Limit v0 ingestion to `.torrent` files; magnet support can follow.
- Use SQLite for initial resume-state persistence, then revisit if a more `io_uring`-friendly approach is justified by measurements.
- Select a storage target per torrent at add time; do not build application-level multi-disk placement when the filesystem can already provide that behavior.
- Let memory targets follow measurement. Optimize for compact state, but do not pick an arbitrary hard RAM ceiling before benchmark data exists.

## Performance Tooling
Use [perf/README.md](perf/README.md) as the operational playbook for syscall and CPU inspection.

Available helper commands:

- `zig build trace-syscalls -- ...`
- `zig build perf-stat -- ...`
- `zig build perf-record -- ...`

## Open Design Questions
The next high-value decision is how aggressively startup should trade initialization work for steady-state performance.

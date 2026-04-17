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

- **No smart ban**: When a peer sends corrupt data that fails piece hash verification, the piece is re-downloaded but the peer is not penalized or banned. A smart ban implementation (per-block SHA-1 tracking with cross-reference on piece pass, matching libtorrent's approach) is planned. See `docs/future-features.md` for the implementation plan.
- **No multi-source piece assembly**: Each piece is downloaded from a single peer. Requesting different blocks of the same piece from multiple peers simultaneously is not yet supported. This is a prerequisite for the full smart ban algorithm to be effective in mixed-peer scenarios.
- MSE/PE encryption handshake has known issues in mixed mode (`vc_not_found` / `req1_not_found`).

The living scope and architecture record lives in [DECISIONS.md](DECISIONS.md). Keep that file updated as constraints and design choices change.
Use [STATUS.md](STATUS.md) as the current ledger for what is already implemented, what is next, and which issues are still open.

## Testing

```bash
zig build test                    # all unit tests
./scripts/demo_swarm.sh           # e2e: seeder → downloader via tracker (TCP + uTP)
./scripts/test_web_seed.sh        # e2e: web seed download (3 scenarios, BEP 19)
```

The demo swarm creates a torrent with `varuna-tools create`, starts opentracker with the info hash whitelisted, runs a seeder and downloader daemon, and verifies the downloaded payload.

## Project Direction
Varuna is intended for local Linux storage only. SSDs, HDDs, mergerfs, ext4, xfs, btrfs, bcachefs, and zfs matter; network filesystems such as NFS and CIFS do not. The initial focus is private-tracker functionality and operational reliability, not broad feature coverage or plugin systems.
Private-tracker compatibility should be good enough to meet or exceed common rTorrent workflows.

The current baseline kernel target is Linux `6.6`, matching WSL2. If `io_uring` behavior in Linux `6.8` turns out to be materially better for the storage or networking design, `6.8` is an acceptable minimum instead. Newer kernel features should be used through runtime capability detection rather than by dropping support for `6.6` immediately.

Reference implementations worth studying:
- `libtorrent`: protocol behavior, tracker compatibility, operational features
- `rtorrent`: long-lived private-tracker workflows and headless ergonomics
- `vortex`: examples of a BitTorrent client built around `io_uring`

## Initial Build Approach
The repository is still at bootstrap stage. The first implementation steps should be:

1. Add `build.zig` and a small `src/main.zig` daemon entrypoint.
2. Establish subsystem boundaries under `src/` for protocol, storage, tracker, and control plane code.
3. Build a test-first foundation for bencode, metainfo parsing, hashing, and piece mapping.
4. Add an `io_uring` event loop, kernel capability probing, and storage abstraction before higher-level torrent management.
5. Expose an HTTP control API over both Unix socket and TCP socket transports.

Use Zig `0.15.2` or the latest stable Zig release. Do not use nightly builds.
Use `mise` to install pinned tools for this repository.

```bash
mise install
```

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

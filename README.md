# Varuna

Varuna is a headless BitTorrent client in Zig for Linux, currently at an early minimal-client stage. The project is named after the Hindu god of water and also ties back to the author’s name. The design target is still a high-performance daemon that leans heavily on `io_uring`, keeps allocations tightly controlled, and scales to thousands or tens of thousands of torrents.

## Current Status
The repository now includes a minimal end-to-end download path:

- Load a `.torrent` file and derive its file layout.
- Announce to an HTTP tracker with compact peer support.
- Recheck existing on-disk data and reuse pieces that already verify.
- Connect to a peer over the BitTorrent wire protocol.
- Download pieces sequentially, verify SHA-1 hashes, and write data to disk.
- Seed verified on-disk data back to one inbound peer.

Current CLI:

```bash
zig build run -- download /path/to/file.torrent /path/to/download-root --port 6882
zig build run -- seed /path/to/file.torrent /path/to/data-root --port 6881
zig build run -- inspect /path/to/file.torrent
```

Current scope limits:

- HTTP trackers only.
- Compact peer lists only.
- One active peer at a time.
- Sequential piece download and a single inbound seed connection.
- `.torrent` files only; no magnet support yet.
- Resume is currently based on full piece recheck at startup, not persisted resume metadata.

The living scope and architecture record lives in [DECISIONS.md](DECISIONS.md). Keep that file updated as constraints and design choices change.
Use [STATUS.md](STATUS.md) as the current ledger for what is already implemented, what is next, and which issues are still open.

## Local Swarm Demo
The repository includes a reproducible local smoke test that uses an off-the-shelf tracker:

```bash
./scripts/demo_swarm.sh
```

That script:

- Creates a small `.torrent` file with the Node helper in `scripts/create_torrent.mjs`.
- Uses `varuna inspect` to derive the torrent info hash.
- Starts `scripts/tracker.sh`, which wraps the Ubuntu `opentracker` package.
- Whitelists the torrent info hash because the packaged `opentracker` build rejects unlisted torrents.
- Runs one `varuna seed` instance and one `varuna download` instance against the tracker.
- Verifies the downloaded payload with `cmp`.

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

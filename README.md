# Varuna

Varuna is a planned headless BitTorrent client in Zig for Linux. The project is named after the Hindu god of water and also ties back to the author’s name. The design target is a high-performance daemon that leans heavily on `io_uring`, keeps allocations tightly controlled, and scales to thousands or tens of thousands of torrents.

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

## Open Design Questions
The next high-value decision is how aggressively startup should trade initialization work for steady-state performance.

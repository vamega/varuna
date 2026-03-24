# Varuna Plan

## Vision
Varuna is a headless Linux BitTorrent client written in Zig, optimized for high throughput, low allocation pressure, and deep use of `io_uring`. It should scale from a few torrents to tens of thousands, handle both HDDs and SSDs, and work well on local filesystems including mergerfs, ext4, xfs, btrfs, bcachefs, and zfs.

## Explicit Goals
- Linux only, modern kernels only.
- Zig `0.15.2` or latest stable Zig release.
- Prefer `io_uring` everywhere it is technically sound.
- Keep dependencies light.
- Favor private-tracker needs first.
- Support at least the level of private-tracker compatibility expected from rTorrent.
- Build for headless operation and automation.
- Include correctness, stress, and performance tests from the start.
- Target Linux `6.6` as the baseline because it matches current WSL2, while keeping `6.8` as the preferred minimum if specific `io_uring` behavior proves materially better.

## Explicit Non-Goals
- Non-Linux support.
- Older kernels.
- Network filesystems such as NFS or CIFS.
- Plugins or hooks in the initial versions.
- Broad public-tracker feature coverage before private-tracker essentials are solid.

## Early Architecture Direction
- Single daemon process with well-bounded subsystems: session, peer wire, disk I/O, tracker, metadata, and control API.
- Central event loop built around `io_uring`, with bounded worker threads only where kernel support or CPU-heavy work demands it.
- Storage layer should detect rotational vs non-rotational devices and adapt queue depth, read-ahead, and write coalescing.
- Configuration should stay high-level: bandwidth caps, storage roots, and operational limits instead of low-level tuning knobs.
- Control plane should be HTTP over either a Unix domain socket or TCP socket.
- API compatibility should target Flood usability early, likely by implementing enough of the qBittorrent Web API to interoperate.
- v0 should accept `.torrent` files only; magnet support can land later.
- Observability should include logs and metrics, but not tracing in the initial design.
- Resume state should use SQLite initially for simplicity and operational safety, with the option to replace it later if it becomes a performance or architecture constraint.
- Varuna should not implement its own multi-disk placement layer. Each torrent should be assigned a target path at add time, and any cross-disk distribution should be delegated to the underlying filesystem or mount layout.
- Memory usage should be treated as an optimization target informed by measurement, not by an arbitrary early cap. The architecture should still favor compact state and avoid obviously unbounded per-torrent overhead.

## Phase Plan
1. Bootstrap: `build.zig`, CLI entrypoint, logging, config skeleton, metrics, test harness, kernel capability probing.
2. Core protocol: bencode, metainfo, piece map, hashing, peer wire basics.
3. Storage engine: file layout, piece verification, resume data, HDD/SSD scheduling, mergerfs validation.
4. Private tracker support: announce/scrape, auth flows, HTTPS, passkey-safe behavior, and an rTorrent-level compatibility target for private trackers.
5. Operations: HTTP control API, qBittorrent/Flood compatibility slice, rate control, observability, soak tests, benchmarks.

## Kernel Notes
- Linux `6.6` already includes faster asynchronous direct I/O paths for `io_uring`, which is relevant for torrent storage workloads.
- Linux `6.8` adds `IORING_OP_FIXED_FD_INSTALL` and a method to return the provided-buffer-ring head; these are useful but not obviously mandatory for a first implementation.
- Newer kernels continue to add `io_uring` improvements, for example better zerocopy send performance in `6.10` and ring resizing plus fixed wait regions in `6.13`.
- Varuna should probe `io_uring` capabilities at runtime and switch code paths when newer features are available instead of hard-coding a single-kernel assumption.

## Performance Notes
Startup behavior is important enough to track separately. See `startup-performance-considerations.md` for known causes of slow startup in torrent clients, recent rTorrent optimization work, and the resulting design rules for Varuna.

Use [DECISIONS.md](DECISIONS.md) as the living record of scope and architecture decisions, and [perf/README.md](perf/README.md) as the profiling playbook for `strace`, `perf`, and eBPF/bpftrace-based syscall inspection.
Use `scripts/demo_swarm.sh` as the current end-to-end local swarm smoke test while the client is still in its minimal single-peer stage.

## Questions To Answer Next
- Should startup optimize for fastest possible availability or for loading richer in-memory indexes up front?

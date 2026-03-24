# Varuna Decision Log

This file is the living record of product, architecture, and workflow decisions for Varuna.
Update it whenever scope changes, constraints are widened or tightened, profiling strategy changes, or a notable implementation tradeoff is chosen.

## Active Constraints

- Minimal client ingestion is `.torrent` files only. Magnet, DHT, PEX, LSD, and uTP are not in scope yet.
- The currently verified tracker path is HTTP announce with compact peer lists.
- The current peer strategy is one active peer and sequential piece download.
- The current transfer path is download-only. Varuna does not yet listen for inbound peers or seed data back out.
- Pieces are SHA-1 verified before being committed to disk.

## Decision Entries

### 2026-03-24: Minimal Client Contract

Context:
The repository had parsing and layout foundations but no end-to-end transfer path.

Decision:
- Build the smallest useful torrent client first.
- Limit the first contract to `.torrent` files, compact tracker peers, one active peer, and sequential block requests.
- Optimize for correctness and testability before concurrency or richer tracker behavior.

Reasoning:
- This creates a real download path quickly.
- It keeps failure modes understandable while storage, protocol, and tracker code are still young.
- It gives a clean baseline before parallel peer scheduling and `io_uring` transport work land.

Follow-up triggers:
- Widen peer concurrency only after the single-peer path is stable and measured.
- Expand tracker behavior only after verified compatibility needs justify it.

### 2026-03-24: Torrent Session Ownership

Context:
Metainfo parsing stored slices into the caller-provided `.torrent` buffer, which is unsafe for a CLI that reads the file and then frees that buffer.

Decision:
- `Session.load` now duplicates the torrent bytes and owns that backing storage for the lifetime of the session.

Reasoning:
- Prevents borrowed-slice lifetime bugs in real file-backed execution.
- Keeps metainfo, piece hashes, and path slices stable without deep-copying every field.

### 2026-03-24: Storage Commit Strategy

Context:
The first client path needed a simple write flow that stayed correct across single-file and multi-file torrents.

Decision:
- Create target directories and files up front.
- Verify each piece hash before writing it.
- Use piece-to-file span mapping to write verified data directly to the correct offsets.

Reasoning:
- Keeps disk writes deterministic and easy to test.
- Avoids persisting corrupted data from bad peer payloads.

### 2026-03-24: Resume Via Full Piece Recheck

Context:
The first minimal client always redownloaded the torrent payload, even when valid data already existed on disk.

Decision:
- Recheck all on-disk pieces before announcing to the tracker.
- Reuse pieces whose SHA-1 hashes already match the torrent metadata.
- Skip tracker and peer work entirely when the target data is already complete.

Reasoning:
- This gives the minimal client a real resume path without introducing resume databases yet.
- It keeps correctness simple because reuse is gated by the same piece-hash verification used for downloads.
- Skipping network activity for already-complete data avoids making tracker claims that the current one-shot CLI cannot back up with seeding behavior.

Current behavior:
- Existing files are opened and extended to the target sizes if needed.
- Every piece is re-read and hash-checked before download starts.
- Only missing or invalid pieces are requested from the peer.

### 2026-03-24: Performance Inspection Workflow

Context:
Varuna is intended to move toward heavy `io_uring` usage, so the project needs a repeatable way to see which syscalls still escape that path.

Decision:
- Keep the operational playbook in [perf/README.md](perf/README.md).
- Add build-step helpers for `strace`, `perf stat`, and `perf record`.
- Treat syscall mix checks as a routine validation tool when storage or networking code changes.

Current tooling strategy:
- Use `zig build trace-syscalls -- ...` for full syscall traces written to `perf/output/strace.log`.
- Use `zig build perf-stat -- ...` for high-level counters written to `perf/output/perf-stat.txt`.
- Use `zig build perf-record -- ...` for sampled call stacks written to `perf/output/perf.data`.
- Use `strace -f -yy -c` when a fast syscall summary is enough.
- Use `bpftrace`/eBPF for targeted confirmation of `io_uring` entry/completion behavior and for spotting fallback syscalls such as `read`, `write`, `sendto`, `recvfrom`, `epoll_wait`, or blocking disk I/O.

Follow-up triggers:
- Add dedicated `io_uring` tracepoints and regression checks once the transport and storage paths actually use `io_uring`.

### 2026-03-24: WSL Profiling Findings

Context:
The profiling helpers were exercised on WSL2 after installing tracing tools.

Findings:
- `zig build trace-syscalls -- banner` works and writes `perf/output/strace.log`.
- `strace -f -yy -c` shows the current binary is still using conventional syscalls; there is no `io_uring` activity yet.
- `perf stat` on this host still needs a kernel-matched `linux-tools-<kernel>` package for `6.6.87.2-microsoft-standard-WSL2`.
- `bpftrace` requires root privileges, which is expected and should be treated as part of the workflow requirements.

Implication:
- Keep `strace` as the default unprivileged syscall audit path.
- Treat `perf` and `bpftrace` as environment-dependent tools whose availability must be verified per machine.

# Varuna Decision Log

This file is the living record of product, architecture, and workflow decisions for Varuna.
Update it whenever scope changes, constraints are widened or tightened, profiling strategy changes, or a notable implementation tradeoff is chosen.
Use [STATUS.md](STATUS.md) for the running list of completed work, next work, and currently known issues.

## Active Constraints

- Client ingestion supports `.torrent` files and magnet links (BEP 9). DHT, PEX, LSD are not in scope yet.
- The currently verified tracker path is HTTP announce with compact peer lists.
- The current peer strategy is one active peer at a time, sequential piece download, and a single inbound seed connection.
- Seeder behavior is minimal: announce as complete, accept one inbound peer, serve requests sequentially, and exit after that peer disconnects.
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

### 2026-03-24: Minimal Seeding And Local Swarm Verification

Context:
The next milestone after resume support was proving that two `varuna` instances could transfer a torrent through a real tracker, without building tracker logic into the client yet.

Decision:
- Add a minimal seed mode that only runs when all torrent data already verifies on disk.
- Keep the seeding contract narrow: one listening socket, one inbound peer, sequential block serving, and exit after the downloader disconnects.
- Add `varuna inspect` so scripts can read the torrent info hash without duplicating metainfo parsing logic.
- Use the Ubuntu-packaged `opentracker` binary as the current external tracker helper, wrapped by `scripts/tracker.sh`.
- Whitelist torrent info hashes explicitly when starting that tracker, because the packaged `opentracker` build rejects unlisted torrents.
- Keep `scripts/demo_swarm.sh` as the reproducible local proof path for one seed and one downloader.

Reasoning:
- This gets the project to a real swarm milestone quickly while keeping peer-state and lifetime rules simple.
- Requiring a full recheck before seeding avoids serving corrupt or partial data.
- `varuna inspect` keeps tracker bootstrapping and future debugging workflows inside the project instead of pushing them into ad hoc parsing scripts.
- Using a packaged tracker is faster than building tracker support in Zig before peer/storage behavior is settled.

Current behavior:
- `varuna seed` listens on one configured TCP port and announces with `left=0`.
- `varuna download` and `varuna seed` can run concurrently against the local tracker helper.
- The current external tracker demo has been verified with `scripts/demo_swarm.sh`.

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

### 2026-03-25: Safety, Quality, And Throughput Improvements

Context:
Code review revealed safety bugs, duplicated logic, missing protocol events, and a serial block download path that paid one full RTT per 16KB block.

Decisions:
- Replace all `@panic` calls in bencode type-checking helpers (`expectDict`, `expectBytes`, `expectPositiveU64`, etc.) with proper error returns. These helpers process untrusted input from `.torrent` files and tracker responses.
- Unify `PieceSet` (verify.zig) and `PieceAvailability` (client.zig) into a shared `Bitfield` type in `src/bitfield.zig`.
- Filter self-peers (127.0.0.1 and 0.0.0.0 on the client's own port) from tracker responses before attempting connections.
- Send best-effort `completed` tracker event after successful download and `stopped` event on seed exit and download failure. Errors from these announces are silently ignored.
- Pipeline up to 5 block requests per piece instead of the previous send-one-wait-one pattern. Handle choke during pipeline by clearing outstanding requests and re-requesting after unchoke.
- Expand the benchmark suite to cover bencode parsing, SHA-1 piece hashing, and metainfo parsing throughput.

Reasoning:
- The `@panic` on untrusted input was a crasher bug; malformed `.torrent` files or bad tracker responses would kill the process.
- Shared `Bitfield` eliminates ~50 lines of duplicated bit-manipulation logic and creates a reusable primitive for future multi-peer work.
- Self-peer filtering eliminates wasted connection attempts in local tracker workflows.
- Tracker events are required for private tracker compatibility and proper peer list hygiene.
- Request pipelining is the single largest throughput improvement for the single-peer model. With 50ms RTT, serial requests cap throughput at ~320KB/s; pipelining 5 raises it to ~1.6MB/s.

### 2026-03-25: io_uring Transition For Hot-Path I/O

Context:
The project targets io_uring for all performance-critical I/O. The codebase was using conventional blocking syscalls (`pread64`, `pwrite64`, `read`, `write`, `sendto`, `recvfrom`) for file and network operations.

Decision:
- Create `src/io/ring.zig` wrapping `std.os.linux.IoUring` with blocking convenience methods (submit one SQE, wait for one CQE per call).
- Route all hot-path file I/O (`PieceStore.readPiece`, `writePiece`, `sync`) through `Ring.pread_all`, `pwrite_all`, `fsync`.
- Route all peer wire protocol I/O through `Ring.send_all` and `Ring.recv_exact`.
- Add `src/net/transport.zig` with `tcpConnect` and `tcpAccept` that create sockets conventionally but connect/accept via io_uring.
- Keep file creation/setup, HTTP tracker, and stdout logging as conventional I/O (not hot path).
- Add io_uring availability probe to startup banner.

Reasoning:
- Blocking wrappers maintain the current synchronous code structure while routing all I/O through `io_uring_enter` instead of individual syscalls.
- This is the correct foundation before a full async event loop (which requires multi-peer concurrency to justify).
- Vortex (reference codebase) also keeps file open, HTTP tracker, and logging as conventional I/O.
- The Ring entry count (16) is sufficient for blocking mode; it will increase when batched event loop lands.

Follow-up triggers:
- Convert to batched event loop when multi-peer concurrency is implemented.
- Replace `std.http.Client` with ring-based HTTP when tracker round-trip time becomes a bottleneck.
- Consider registered file descriptors and buffer rings for further kernel overhead reduction.

### 2026-03-28: Speed Restrictions via Token Bucket

Context:
Rate limiting is a standard feature in BitTorrent clients. Users need to control bandwidth usage per-torrent and globally.

Decision:
- Use token bucket algorithm with 1-second burst capacity (capacity = rate in bytes/sec).
- Rate limiting happens at the event loop level, not at the kernel/socket level.
- Download throttling: skip piece assignment and pipeline filling when bucket is empty. Already-received data is still processed (we cannot un-receive bytes from io_uring).
- Upload throttling: drop piece requests from peers when bucket is empty. Peers will re-request.
- Per-torrent limits checked first, then global limits. Both must allow the transfer.
- A rate of 0 means unlimited (all operations pass through with no overhead).
- API follows qBittorrent conventions for compatibility with existing frontends.

Reasoning:
- Token bucket is the industry standard for BitTorrent rate limiting (libtorrent, qBittorrent, rtorrent all use variants).
- Non-blocking throttling (skip work instead of sleep) maintains the io_uring event loop policy: no blocking calls on the event loop thread.
- Checking tokens in `tryAssignPieces`/`tryFillPipeline` is more efficient than throttling at the socket level, because it avoids submitting io_uring SQEs that would just be delayed.
- Dropping upload requests when throttled is simpler and more efficient than queuing them. Peers implement retry logic per the BitTorrent protocol.

Follow-up triggers:
- Add alternative speed mode (qBittorrent's "alt speed" with scheduler) if needed.
- Consider SO_MAX_PACING_RATE for kernel-level pacing if application-level throttling proves too coarse.
- Add rate limit persistence across daemon restarts (currently only in-memory and config file).

### 2026-03-30: Magnet Link Support (BEP 9)

Context:
Magnet links are the dominant way users share torrents. The daemon already advertised ut_metadata in BEP 10 handshakes but did not implement the metadata download protocol.

Decision:
- Implement BEP 9 metadata download as a synchronous background thread operation, not through the async event loop.
- Metadata fetch runs before the normal download path: announce to trackers with just the info-hash, connect to peers one at a time, perform BEP 10 + BEP 9 handshake, download metadata pieces sequentially.
- Once metadata is verified (SHA-1 matches info-hash), synthesize a minimal .torrent file and fall through to the normal Session.load/download path.
- Serve metadata to peers who request it via the event loop's protocol handler (using tracked sends for io_uring buffer safety).
- Extension handshake now includes metadata_size when we have torrent data.
- API follows qBittorrent convention: `urls=` parameter in the add endpoint accepts magnet URIs.

Reasoning:
- Running metadata fetch on a background thread (blocking Ring) keeps the code simple and avoids adding metadata assembly state to every peer slot in the event loop. Metadata download is a one-time operation per torrent.
- Synthesizing .torrent bytes from the info dictionary allows the rest of the codebase (Session, PieceStore, tracker announces) to work unchanged.
- Serving metadata to other peers via the event loop is important for swarm health and is a relatively small addition.
- The 10 MiB metadata size cap guards against malicious peers.

Follow-up triggers:
- Add parallel metadata piece requests when multiple peers are available.
- Add retry logic across peers if metadata hash verification fails.
- Support trackerless magnets once DHT is implemented.

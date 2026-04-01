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

### 2026-04-01: Keep Peer Listener `accept_multishot`, But Only On Measured Low-Concurrency Evidence

Context:
The shared peer listener still submitted one accept SQE per inbound connection. Earlier review suggested `accept_multishot` should be an easy `io_uring` win, but unlike the API path there was no workload that exercised the real `EventLoop` accept handler, peer-slot allocation, and handshake-recv arming sequence.

Decision:
- Add a real `peer_accept_burst` workload to `varuna-perf` that drives loopback inbound TCP connections through the production `EventLoop` listener path.
- Change the peer listener from one-shot `accept` to `accept_multishot`.
- Only re-arm accept from `handleAccept()` when the kernel drops `IORING_CQE_F_MORE` or returns an error that terminates the multishot stream.

Reasoning:
- The peer listener change is small and does not alter peer ownership or handshake state.
- A loopback inbound benchmark is sufficient to answer the narrow question of whether repeated accept re-submission is measurable on this host.
- The measured improvement is workload-dependent: it shows up when connections arrive more serially, which is closer to the expected “mostly idle seeding torrent” pattern than a dense 8-thread connection flood.

Measured effect:
- `peer_accept_burst --iterations=4000 --clients=1`
  one-shot baseline: `727995472 ns`, `739372927 ns`
  multishot: `699668951 ns`, `715792574 ns`, `657787147 ns`
  average improvement vs the one-shot baseline used for the A/B check: about `5.8%`
- `peer_accept_burst --iterations=4000 --clients=8`
  one-shot baseline: `150735516 ns`, `158715184 ns`
  multishot: `151998395 ns`, `164377673 ns`
  result: effectively flat/noisy on this host

Follow-up triggers:
- If inbound peer bursts in real swarm traces are often highly concurrent, do not assume this listener change is a large end-to-end win by itself.
- The next `io_uring` network experiments should focus on uTP receive and large seed sends, where the remaining syscall and copy costs are more substantial than accept re-submission.

### 2026-03-31: Keep API `accept_multishot`, Reject API `recv_multishot` For Now

Context:
The API server still paid one heap allocation per client request for its receive buffer and re-submitted a fresh accept SQE after every incoming connection. Earlier profiling suggested `accept_multishot`, `recv_multishot`, and provided-buffer rings were the next obvious `io_uring` wins, but they needed end-to-end measurement instead of assuming the newer opcodes would help automatically.

Decision:
- Add two real socket-level API burst workloads to `varuna-perf`: `api_get_burst` for short request/response traffic and `api_upload_burst` for upload-sized request bodies.
- Keep `accept_multishot` on the API listener.
- Replace the per-client initial heap receive buffer with an inline `8 KiB` request buffer and only allocate heap storage when a request actually outgrows it.
- Do not keep the API `recv_multishot` + provided-buffer implementation in this pass.

Reasoning:
- `accept_multishot` is low-risk and directly removes one accept re-submission per inbound connection.
- The inline receive buffer removes the dominant short-request allocation without adding lifecycle complexity.
- The `recv_multishot` prototype did reduce allocator churn, but on this workload it required extra shutdown/cancel bookkeeping on teardown and did not deliver a convincing latency win once the full request lifecycle was measured.
- Keeping only the measured win is better than landing a more complex receive path on faith.

Measured effect:
- `api_get_burst --iterations=4000 --clients=8` stayed effectively flat on wall time (`~220.29 ms` before vs `~220.43 ms` average after) while dropping alloc calls from `8000` to `4000` and transient bytes from `33.28 MB` to `512 KB`.
- `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536` improved from `~129.54 ms` to `~126.19 ms` average while dropping alloc calls from `3000` to `2000` and transient bytes from `73.97 MB` to `65.78 MB`.

Follow-up triggers:
- Revisit API `recv_multishot` only if a broader HTTP design change also removes the teardown cost, for example persistent connections or a request parser that does not rely on connection close.
- The next `io_uring` networking pass should target the peer listener accept path and then uTP `recvmsg_multishot`, each behind its own benchmark.

### 2026-03-31: Shared Event Loop Torrent Registry Uses Dynamic `u32` IDs

Context:
The shared daemon `EventLoop` capped active torrents at 64 because it stored torrent state in a fixed `[64]?TorrentContext` table and used `u8` torrent IDs throughout the peer, uTP, hasher, and session-integration code. Inbound TCP/uTP handshakes and DHT results also linearly scanned that table by info-hash, and disk-write CQEs encoded `torrent_id` inside the 40-bit `user_data.context`, which prevented widening IDs cleanly.

Decision:
- Replace the fixed torrent table with a dynamically sized slot array, a free-list, and stable `u32` torrent IDs.
- Add a hash map from inbound info-hash to torrent ID for O(1) routing of inbound TCP handshakes, inbound uTP handshakes, DHT peer results, and MSE responder completion.
- Replace disk-write CQE correlation with a dedicated per-write ID, so `torrent_id` no longer needs to fit inside `user_data.context`.
- Change inbound MSE responder setup from a fixed `[64][20]u8` hash list to a dynamically allocated slice built from the current active torrent IDs.
- Avoid eager per-torrent PEX-state allocation and skip speed-counter work when there are no connected peers.

Reasoning:
- The fixed array was the actual architectural cap for active torrents in daemon mode, not just a type-size problem.
- Tens of thousands of mostly idle seeding torrents require lookup by info-hash, not repeated scans over all registered torrents on each inbound connection.
- Write IDs decouple CQE matching from torrent-ID width and are safer than overpacking multiple identities into 40 context bits.
- Idle-seeding scale needs not only more slots, but also lower background work when there are zero peers attached.

Validation:
- `zig build test` passes with the new dynamic registry.
- A new regression test adds `20,000` torrent contexts, validates hashed lookup, removes one slot, and confirms slot reuse with a new info-hash.

Follow-up triggers:
- If `/sync` polling or periodic torrent housekeeping shows up with very large torrent counts, add a hot torrent-summary registry instead of pulling state from full `TorrentSession` objects on demand.
- If idle seeding still spends measurable time in housekeeping, rate-limit or event-drive partial-seed state checks instead of scanning all active torrents every tick.

### 2026-03-31: Second Memory Pass Uses Session Arenas And API Vectored Sends

Context:
The first allocation pass removed most of the short-lived churn in request batching, seed batching, extension decode, and `/sync/maindata`, but two obvious ownership costs remained:
- `Session.load` still spread long-lived torrent metadata across many small general-allocator allocations.
- The API server still concatenated HTTP headers and body into a fresh response buffer even when the handler already owned the body.

Decision:
- Make `Session.load` allocate the session-owned torrent bytes, metainfo, layout, and manifest from a session-local `ArenaAllocator`, and tear the whole session down by destroying that arena.
- Change the API server send path to build only the HTTP header buffer, then send header and body as separate iovecs via `io_uring` `sendmsg`.
- Extend the synthetic `peer_scan` workload so active density can be varied with `--scale`, which makes sparse-table scan behavior measurable instead of assuming a dense active set.

Reasoning:
- Session metadata is immutable after load and naturally shares a lifetime, so an arena removes allocator bookkeeping and fragmentation without complicating ownership.
- The API server was paying for one avoidable full-body copy per response. Keeping handler-owned bodies alive until send completion is simpler and cheaper than rebuilding the entire response payload.
- Sparse active-peer density is the case where the earlier active-slot scan change should help most, so the harness needs a direct way to exercise it.

Measured effect:
- `http_response` fell from `10,001` allocs / `48.6 MB` transient bytes / `9.93e7 ns` to `5,001` allocs / `648 KB` transient bytes / `4.63e7 ns`.
- `session_load` fell from `14,004` allocs / `5.05e7 ns` to `2,004` allocs / `1.33e7 ns`.

Follow-up triggers:
- If API polling still shows up in end-to-end profiles, add per-client request arenas and reuse for request-body growth.
- The peer path still needs a real hot/cold split or SoA conversion if scan-side cache pressure remains measurable after the active-slot pass.

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
- The Ubuntu `/usr/bin/perf` wrapper on this host refuses to run without an exact kernel-matched `linux-tools-<kernel>` backend for `6.6.87.2-microsoft-standard-WSL2`.
- `bpftrace` requires root privileges, which is expected and should be treated as part of the workflow requirements.

Implication:
- Keep `strace` as the default unprivileged syscall audit path.
- Treat `perf` and `bpftrace` as environment-dependent tools whose availability must be verified per machine.

### 2026-03-31: WSL Perf Backend Detection

Context:
On this Ubuntu 24.04 WSL host, `perf` is installed, but `/usr/bin/perf` is only a wrapper script. That wrapper fails because it wants an exact `linux-tools-6.6.87.2-microsoft-standard-WSL2` backend path, even though a usable backend exists at `/usr/lib/linux-tools-6.8.0-106/perf`.

Decision:
- Teach the profiling build steps to resolve a real `perf` backend from `/usr/lib/linux-tools/.../perf` or `/usr/lib/linux-tools-.../perf` before falling back to plain `perf`.
- Keep `perf stat` and `perf record` wired through those build steps so the profiling workflow remains one command.

Reasoning:
- The failure mode on WSL is a wrapper-script packaging problem, not a hard requirement for root or a proof that `perf` is unusable on the host.
- Calling the real backend directly keeps the workflow working without local symlink hacks or shell aliases.
- This preserves normal Linux behavior because the fallback is still plain `perf` when no backend binary is found.

Current behavior:
- `zig build perf-stat -- ...` and `zig build perf-record -- ...` now bypass the broken wrapper automatically when a backend binary is installed.
- On this WSL host, software counters and sampled profiles work through `/usr/lib/linux-tools-6.8.0-106/perf`.
- Several hardware counters (`cycles`, `instructions`, `branches`) still report `<not supported>`, which appears to be a WSL/kernel capability limit rather than a build-step issue.

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
- Consider SO_MAX_PACING_RATE for kernel-level pacing if application-level throttling proves too coarse.
- Add rate limit persistence across daemon restarts (currently only in-memory and config file).

Explicitly out of scope:
- Time-based alternative speed scheduling (qBittorrent's "alt speed" scheduler). Varuna will not implement automatic time-of-day speed switching. Users who need scheduled rate changes should use external tooling (cron + varuna-ctl) to set limits at desired times.

### 2026-03-30: Peer Exchange (BEP 11)

Context:
PEX is the standard mechanism for BitTorrent peers to exchange peer lists without relying solely on tracker announces. The BEP 10 extension protocol was already implemented, and ut_pex was advertised in the handshake (disabled for private torrents).

Decision:
- Implement BEP 11 with delta encoding: each PEX message contains only peers added/dropped since the last exchange with that particular peer.
- Use per-peer PexState to track previously sent peer sets, and per-torrent TorrentPexState for the current connected peer set.
- Allocate PEX state lazily (on first use) so private torrents and non-PEX peers have zero overhead.

### 2026-03-31: Memory Baseline Workflow And First Allocation Reduction Pass

Context:
The daemon had several clear allocation-heavy paths, but there was no repeatable way to compare them without live swarm traffic. The current host is WSL2, and `perf stat` / `perf record` are blocked until the matching `linux-tools-6.6.87.2-microsoft-standard-WSL2` package is installed.

Decision:
- Add a dedicated synthetic workload binary, `varuna-perf`, for stable before/after measurements of peer scans, request batching, seed batching, `/sync/maindata`, metadata parsing, and session loading.
- Measure allocation churn in that binary with an in-process counting allocator.
- On WSL hosts where `perf` is unavailable, use `cachegrind` for cache-miss comparisons and `heaptrack` for stack-attributed allocation traces.
- Land the first low-risk memory pass before attempting a full peer/uTP hot/cold split:
  - piece-verification planning now accepts caller scratch spans with heap fallback,
  - tracked sends use a fixed small-send pool for small async buffers,
  - seed batching keeps block descriptors into the piece buffer instead of heap-copying every block,
  - `/sync/maindata` uses fixed `[40]u8` snapshot keys and a request arena for transient JSON work,
  - BEP 10 and BEP 9 control-message decoders use fixed-shape parsers instead of allocating bencode trees,
  - scan-heavy peer-policy code iterates dense active-slot lists instead of walking every peer slot.

Reasoning:
- The synthetic harness makes the allocator and cache effects reproducible without needing a real swarm or WebUI client in the loop.
- The WSL `perf` limitation is an environment issue, not a code issue, so the workflow needs a documented fallback instead of blocking optimization work.
- These changes target the highest-yield short-lived allocations first and reduce memory traffic without changing public behavior.

Follow-up triggers:
- If the peer-policy scans are still prominent after the active-slot pass, split hot peer state from cold per-peer storage and benchmark a fuller SoA layout.
- Apply the same request-arena pattern to other RPC endpoints that still materialize temporary object graphs.
- Connect to PEX-discovered peers through the existing addPeerForTorrent machinery, respecting all connection limits.
- Cap added/dropped lists at 50 peers per message and enforce 60-second intervals per peer, as recommended by BEP 11.

### 2026-04-01: Sparse Torrent Tick And Peer-Churn Registry Pass

Context:
The shared event loop had already been widened to support many more torrents, but the hot periodic paths still paid for repeated scans over peer and torrent collections. The remaining `/sync` path also rebuilt categories/tags JSON on every poll, and peer-list bookkeeping still used linear duplicate checks.

Decision:
- Keep a dense per-torrent peer slot list and a `torrents_with_peers` list so periodic torrent work only touches active torrents.
- Add per-peer indices for the idle and active peer lists so `markIdle` / `unmarkIdle` / `markActivePeer` / `unmarkActivePeer` are O(1).
- Cache category and tag JSON in the daemon stores and reuse that cache from `/sync/maindata`.
- Add benchmark surfaces in `src/perf/workloads.zig` for `tick_sparse_torrents`, `peer_churn`, and `sync_delta` so the hot paths can be measured before and after layout changes.

Reasoning:
- The sparse-torrent benchmark showed that cross-product scans are the real cost, not allocation churn, when most torrents are idle seeds.
- Peer-churn work validated that the linear membership scans were pure overhead; the O(1) index change removes them entirely.
- `/sync` still benefits from cache reuse, but the biggest wins came from reducing traversal work first.

Follow-up triggers:
- If `/sync` continues to dominate, move more torrent state into a dedicated hot-summary registry instead of deriving it from live torrent/session objects on every poll.
- If seed or uTP profiles still show allocator or syscall overhead after these registry changes, revisit plaintext scatter/gather and outbound UDP queueing with the same benchmark discipline.

Reasoning:
- Delta encoding is required by BEP 11 and minimizes bandwidth (only changes are sent).
- Lazy allocation avoids wasting memory for private torrents where PEX is forbidden.
- Reusing addPeerForTorrent ensures PEX connections go through the same limit checks, dedup, and half-open tracking as tracker-discovered peers.
- The tick-based approach (scanning peers each cycle) is simple and correct; the connected peer set is always accurate even if peers disconnect between PEX messages.

Follow-up triggers:
- Add PEX-specific connection rate limiting if PEX amplification becomes a concern.
- Add integration test with multiple daemon instances exchanging peers via PEX.

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

### 2026-04-01: Keep API Connections Alive And Precompute MSE Responder Matches

Context:
The existing `api_get_seq` workload was dominated by repeated accept/connect/close churn for WebUI-style polling, and the inbound MSE responder path still allocated and copied all active torrent hashes per connection before recomputing `hashReq2` linearly across them.

Decision:
- Keep HTTP/1.1 connections alive by default in the RPC server, reusing the client slot and buffered receive storage across sequential requests unless the client explicitly sends `Connection: close`.
- Parse request framing into a consumed-length result so the server can retain pipelined leftovers in the receive buffer instead of forcing one-request-per-connection behavior.
- Maintain a shared `req2 -> info_hash` lookup table in the shared event loop and initialize inbound MSE responder handshakes from that lookup instead of heap-copying the torrent hash list into every peer.
- Add explicit perf workloads for sequential API polling, MSE responder preparation, and tracker HTTP reuse potential.

Reasoning:
- The sequential RPC workload improved from `2.41e8 ns` to `9.56e7 ns` and `8.71e7 ns` on repeat runs with the same `4000` requests / `8` clients shape, which is a large enough win to justify the extra request-framing logic.
- The MSE responder-prep workload improved from `1.019e9 ns`, `2001` allocs, and `800 MB` of churn to `5.21e4 ns` / `3.57e4 ns` and only setup-time map allocations at `20,000` torrents, which is exactly the kind of scale-path improvement the shared daemon needs.
- A tracker-like loopback benchmark showed strong microbenchmark upside for connection reuse (`~7.31e8 ns` / `7.04e8 ns` fresh versus `~2.83e8 ns` / `2.72e8 ns` reused for `2000` requests), but that result is still benchmark-only. The current daemon still needs a broader shared tracker-client ownership model before reusing connections across real torrent sessions.

Follow-up triggers:
- If WebUI polling remains prominent, consider header-buffer reuse in the API server so the keep-alive path also cuts the remaining per-response header allocation.
- If tracker reuse is pursued in production, do it as a shared executor/pool across torrent sessions instead of a per-session connection cache.

### 2026-04-01: Share Tracker I/O And Reuse HTTP Tracker Connections

Context:
The daemon-side tracker path still spawned detached announce/scrape threads and lazily created per-session tracker rings. A loopback benchmark already showed strong upside for HTTP keep-alive, but that transport reuse was not wired into the real announce/scrape path.

Decision:
- Add a shared `TrackerExecutor` for daemon-side announces and scrapes. It owns one ring, one DNS resolver, and one persistent HTTP client instead of letting each `TorrentSession` lazily create tracker I/O state.
- Route `SessionManager.forceReannounce`, seed-transition completion announces, and periodic scrapes through that executor. Keep the old per-session detached-thread path only as a fallback when no shared executor is attached.
- Extend `io/http.zig` with optional plain-HTTP keep-alive reuse, owned by the executor's client. HTTPS and UDP tracker requests still use one-shot transports.
- Add a real benchmark surface for the production tracker path: `tracker_announce_fresh` versus `tracker_announce_executor`.
- Do not move tracker jobs onto the shared peer `EventLoop` ring in this pass.

Reasoning:
- The real announce-path benchmark improved from `8.49e8 ns` / `8.80e8 ns` fresh to `4.28e8 ns` / `4.50e8 ns` through the shared executor at `2000` requests. That is a repeatable `~1.9x` to `2.0x` win on this host.
- Sharing tracker I/O state removes the per-session ring ownership model without introducing a general threadpool. There is one worker and one queue for tracker jobs.
- Using the main peer `EventLoop` ring safely would require turning tracker HTTP/HTTPS/UDP flows into proper asynchronous state machines. The current `HttpClient.get()` API is a synchronous wrapper over io_uring and would stall peer processing if called directly on the shared peer loop thread.

Follow-up triggers:
- If HTTP tracker reuse still matters after this pass, teach the executor-owned client to pool more than the current small set of plain HTTP endpoints and measure mixed-tracker workloads.
- If the daemon needs tracker work on the main peer ring, first redesign tracker I/O as incrementally-driven state machines with explicit CQE routing instead of calling the current synchronous HTTP helper on the peer loop thread.

### 2026-04-01: Cache Live Torrent Byte Totals For `/sync` Stats

Context:
The sparse peer/torrent registry pass removed the worst cross-product scans, but the live stats path still rebuilt per-torrent byte totals by summing every attached peer inside `getSpeedStats()` and `updateSpeedCounters()`. A dedicated workload was needed to measure the live `SessionManager.getAllStats()` path, not just `/sync` JSON formatting.

Decision:
- Add `downloaded_bytes` and `uploaded_bytes` to `TorrentContext` and update them incrementally when piece payload bytes are received or sent.
- Make `EventLoop.getSpeedStats()` and `peer_policy.updateSpeedCounters()` read those cached totals instead of rescanning each torrent's peer list.
- Add a live synthetic workload, `sync_stats_live`, that builds a shared-loop `SessionManager` with `10k` torrents and sparse active peers, then measures the hot stats path directly.
- Keep `seed_plaintext_burst` and `utp_outbound_burst` in the perf harness as measurement surfaces, but do not land new production changes for those paths in this pass.

Reasoning:
- The new live-stats workload improved from `19,509,532 ns` to `4,886,050 ns` and `4,046,868 ns` on repeat runs at `10,000` torrents / `1,000` peers / `scale=20`, which is a large enough win to justify the narrow cache.
- This is a smaller and safer change than a full torrent hot-summary registry. The expensive part of the current path was repeated byte aggregation, not queue position lookup or JSON emission.
- The cached totals also fix semantics: torrent byte totals are now cumulative across peer disconnects instead of being derived only from currently attached peers.
- A first outbound uTP queue cleanup pass removed allocator churn, but benchmark time stayed noisy and roughly flat, so it was explicitly rejected for now instead of being carried as speculative complexity.

Follow-up triggers:
- If `/sync/maindata` still dominates at very high torrent counts, move more fields into a dedicated hot registry rather than repeatedly walking `TorrentSession` objects.
- Revisit seed plaintext scatter/gather only if the new `seed_plaintext_burst` workload justifies the buffer-lifetime refactor needed for a correct `sendmsg` path.
- Revisit uTP queueing only with a design that can show a clear wall-clock win, not just fewer allocations.

### 2026-04-01: Seed Upload Syscall Feasibility Favors `sendmsg`, Not `splice`

Context:
The remaining obvious seeding opportunity is the plaintext upload path, which still copies piece payloads into one contiguous heap buffer before each send. The question was whether to pursue vectored `sendmsg`, `sendmsg_zc`, `splice`/`sendfile`, or fixed buffers for the upload path.

Decision:
- Add benchmark-only workload surfaces for:
  - contiguous copy over TCP: `seed_send_copy_burst`
  - vectored header + piece slices over TCP: `seed_sendmsg_burst`
  - file-to-pipe-to-socket transfer via `io_uring` `splice`: `seed_splice_burst`
- Do not land a production seed `sendmsg` path yet.
- Do not pursue `splice` / `sendfile` for the current seed path.
- Do not prioritize `READ_FIXED` / `WRITE_FIXED` for seeding yet.

Reasoning:
- On the same TCP benchmark shape (`200` iterations, `8` blocks per burst), vectored `sendmsg` improved from roughly `54` to `59 ms` down to roughly `39` to `46 ms`, about a `23%` to `33%` win, and reduced transient bytes from `26.2 MB` to `72 KB`.
- `splice` was much slower on the same shape, around `149` to `180 ms`. That lines up with the extra syscall/CQE count and the fact that BitTorrent piece framing still needs a separate header send per block.
- `sendfile` is not the right abstraction for the current daemon design. `io_uring` exposes `splice`, and `sendfile` semantics still do not solve the header problem, multi-file block spans, or MSE encryption.
- `READ_FIXED` / `WRITE_FIXED` help the disk-buffer layer, not the socket-framing layer. They could reduce piece-read buffer churn, but they do not remove the need to keep message headers and payload pages alive across the socket send. The current huge-page piece cache already addresses part of that memory/TLB problem.
- The real blocker for a production vectored seed send is buffer lifetime: queued responses currently reference cached piece buffers that can be replaced before the send CQE arrives. A correct `sendmsg` implementation needs explicit ownership, likely refcounted piece-buffer objects or equivalent tracked lifetimes.

Follow-up triggers:
- If the plaintext upload path matters in real swarms, implement tracked vectored sends with explicit piece-buffer ownership and partial-send fallback.
- Consider `sendmsg_zc` only after that ownership model exists, because zero-copy notifications add CQE complexity but do not remove the lifetime requirement.

# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, and piece/file layout mapping are implemented.
- Target files are created up front and verified pieces are written with piece-to-file span mapping.
- Startup resume works through full piece recheck and on-disk SHA-1 verification.
- HTTP tracker announce works with compact peer lists.
- Sequential single-peer download works end to end.
- Minimal seeding works for one inbound peer when the torrent data is already complete on disk.
- `varuna inspect` prints torrent metadata and info hash for scripting and tracker bootstrapping.
- Local tracker tooling exists:
  - `scripts/create_torrent.mjs` creates `.torrent` files.
  - `scripts/tracker.sh` wraps the Ubuntu `opentracker` package.
  - `scripts/demo_swarm.sh` verifies one `varuna seed` instance and one `varuna download` instance against that tracker.
- Profiling workflow exists through `strace`, `perf`, and `bpftrace` documentation and build helpers.
- Bencode/metainfo parsing returns errors instead of panicking on malformed untrusted input.
- Shared `Bitfield` type unifies `PieceSet` and `PieceAvailability`.
- Self-peers are filtered from tracker responses before connection attempts.
- Tracker lifecycle events: `completed` sent after download, `stopped` sent on seed exit and download failure.
- Block request pipelining (depth 5) reduces per-block RTT overhead.
- Benchmark suite covers kernel parsing, bencode parsing, SHA-1 hashing, and metainfo parsing.
- Multi-peer download: thread-per-peer workers with PieceTracker coordination, `--max-peers` option (default 5).
- Rarest-first piece selection: PieceTracker tracks per-piece availability counts from have/bitfield messages.
- Connection timeout: 10-second default via io_uring linked timeout (IOSQE_IO_LINK + LINK_TIMEOUT).
- Tracker re-announce: periodic re-announce on tracker interval to discover new peers; address deduplication.
- Performance baselines (ReleaseFast): SHA-1 1,096 MB/s, bencode 32 MB/s, metainfo 37 MB/s.
- Multi-peer seeding: accept up to `--max-peers` inbound connections, each served on a dedicated thread.
- Endgame mode: when all remaining pieces are in-progress, multiple workers race to finish the last pieces.
- Download progress reporting: periodic piece count, percentage, and peer count.
- Worker error resilience: hash mismatch releases piece back to pool instead of killing the worker.
- fdatasync instead of fsync for faster piece persistence (skips metadata flush).
- fallocate for file pre-allocation via io_uring (avoids fragmentation, catches disk-full early).
- `have` message broadcast after piece completion in download workers.
- `varuna verify` command for integrity checking without starting a transfer.
- `varuna create` command for native .torrent file creation (single-file).
- Bencode encoder with parse-encode roundtrip verification.
- Dead single-peer code removed from client.zig (-330 lines).
- Announce-list support (BEP 12): multiple tracker URLs with fallback.
- Private tracker support: private flag parsing, key and numwant announce parameters.
- `varuna create` command for native .torrent file creation from Zig.
- Bencode encoder, comment field, improved inspect output.
- Multi-file torrent creation from directories (`varuna create` auto-detects file vs directory).
- IPv6 peer support: compact peers6 (BEP 7), IPv6 self-peer detection, IPv6-aware connect.
- Upload while downloading: download workers serve piece requests from peers (tit-for-tat).
- `writeKeepAlive`, `writeNotInterested`, `writeHave` protocol messages.
- `std.http.Client` eliminated: tracker HTTP now routes through io_uring HTTP client (`src/io/http.zig`).
- Event loop skeleton (`src/io/event_loop.zig`): single-threaded io_uring event loop with user_data encoding, peer state machine, message framing, and piece download. Ready to replace thread-per-peer.
- SQLite resume state (`src/storage/resume.zig`): persists completed pieces to SQLite (WAL mode, prepared statements). Integrated into download flow with periodic flush.
- Bundled SQLite build option: `-Dsqlite=bundled` compiles amalgamation for self-contained binary, `-Dsqlite=system` (default) links libsqlite3.
- **Event loop replaces thread-per-peer**: `client.download()` now uses single-threaded io_uring `EventLoop` for all peer I/O. Scales to thousands of peers on one thread.
- Resume fast path: loads known-complete pieces from SQLite config `resume_db` and skips SHA-1 rehashing them.
- TOML config file (`varuna.toml`): configurable port, max_peers, hasher_threads, pipeline_depth, resume_db path.
- **Seeding uses event loop**: thread-per-peer seed workers deleted. Accept + serve via io_uring event loop.
- **peer_worker.zig and seed_worker.zig deleted**: all I/O through single-threaded event loop.
- SHA-1 verification threadpool (configurable thread count via config).
- Graceful SIGINT/SIGTERM shutdown: flushes resume DB, sends tracker stopped event, closes connections.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **qBittorrent-compatible HTTP API over io_uring**: all API I/O (accept, recv, send) via io_uring. Endpoints: webapiVersion, preferences, transfer/info, torrents/info, torrents/add, torrents/delete, torrents/pause, torrents/resume.
- **TorrentSession + SessionManager**: multi-torrent state management with lifecycle (checking, downloading, seeding, paused, stopped, error).
- **varuna-ctl**: CLI client that talks to daemon via HTTP over io_uring. Commands: list, add, pause, resume, delete, version, stats.
- TOML config file with `[daemon]` section (api_port, api_bind).
- **Real swarm verified**: `demo_swarm.sh` passes with opentracker + varuna-tools seed + varuna-tools download. Full io_uring event loop piece transfer verified with `cmp`.
- io_uring is the I/O path for all hot-path file and network operations:
  - `src/io/ring.zig` wraps `std.os.linux.IoUring` with blocking convenience methods.
  - `PieceStore` read/write/sync routes through `Ring.pread_all`/`pwrite_all`/`fsync`.
  - Peer wire protocol send/recv routes through `Ring.send_all`/`recv_exact`.
  - TCP connect and accept use `Ring.connect`/`Ring.accept` via `src/net/transport.zig`.
  - Startup banner reports io_uring availability.

## Next

- ~~Filter or otherwise handle self-peers more cleanly~~ Done: `isSelfPeer` skips `127.0.0.1` and `0.0.0.0` on the client's own port.
- ~~Send `completed`/`stopped` tracker events~~ Done: best-effort `completed` after download, `stopped` on seed exit and download failure.
- Improve tracker lifecycle behavior:
  - handle stale peers and tracker edge cases more deliberately
  - validate behavior against more private-tracker expectations
- Widen peer behavior past the current minimal contract:
  - ~~more than one active peer~~ Done: thread-per-peer workers with PieceTracker coordination, --max-peers option
  - better piece selection than strict sequential download (rarest-first -- Cycle 2)
  - stronger peer/session state handling
  - ~~pipeline block requests~~ Done: pipeline depth of 5 outstanding requests per piece
- ~~Replace full startup-only resume with persisted resume state~~ Done: SQLite resume DB persists completed pieces. Full recheck still runs but results are cached.
- ~~Begin the actual `io_uring` transition for storage and networking.~~ Done: file I/O, peer wire, connect, and accept all use io_uring.
- Transition remaining I/O to io_uring: HTTP tracker, file open/close, batched event loop for multi-peer.
- Add broader integration coverage around CLI workflows and tracker compatibility.

## Known Issues

- ~~In the verified local `opentracker` swarm demo, the downloader could receive its own announced endpoint back.~~ Resolved: self-peers are now filtered before connection attempts.
- The packaged Ubuntu `opentracker` build used by `scripts/tracker.sh` is not open-by-default for arbitrary torrents. It requires explicit info-hash whitelisting, so tracker demos must pass `--whitelist-hash`.
- ~~Seeder behavior was narrow.~~ Resolved: multi-peer seeding with `--max-peers`, per-peer worker threads.
- Resume currently depends on full piece recheck, which is correct but can become expensive on large datasets.
- ~~The runtime still uses conventional syscalls.~~ Resolved: hot-path file and network I/O now routes through io_uring. HTTP tracker requests still use conventional I/O via `std.http.Client`.
- Some restricted or sandboxed environments can interfere with local tracker startup and socket behavior. Validate the swarm demo in a normal host shell when tracker setup looks suspect.

## Last Verified Milestone

- `torrent: add multi-file torrent creation from directories` (`e3484ff`)
- Verified with:
  - `mise exec -- zig build test` (all tests pass including multi-peer download/seed)
  - `mise exec -- zig build` (clean build)
  - `mise exec -- zig build bench -Doptimize=ReleaseFast` (baseline metrics)

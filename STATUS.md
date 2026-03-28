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
- Multi-peer download with PieceTracker coordination, `--max-peers` option (default 5).
- Rarest-first piece selection: PieceTracker tracks per-piece availability counts from have/bitfield messages.
- Connection timeout: 10-second default via io_uring linked timeout (IOSQE_IO_LINK + LINK_TIMEOUT).
- Tracker re-announce: periodic re-announce on tracker interval to discover new peers; address deduplication.
- Performance baselines (ReleaseFast): SHA-1 1,096 MB/s, bencode 32 MB/s, metainfo 37 MB/s.
- Multi-peer seeding via io_uring event loop.
- Endgame mode: when all remaining pieces are in-progress, multiple workers race to finish the last pieces.
- Download progress reporting: periodic piece count, percentage, and peer count.
- Worker error resilience: hash mismatch releases piece back to pool instead of killing the worker.
- fdatasync instead of fsync for faster piece persistence (skips metadata flush).
- fallocate for file pre-allocation via io_uring (avoids fragmentation, catches disk-full early).
- `have` message broadcast after piece completion in download workers.
- `varuna verify` command for integrity checking without starting a transfer.
- `varuna create` command for native .torrent file creation (single-file and directories).
- Bencode encoder with parse-encode roundtrip verification.
- Announce-list support (BEP 12): multiple tracker URLs with fallback.
- Private tracker support: private flag parsing, key and numwant announce parameters.
- IPv6 peer support: compact peers6 (BEP 7), IPv6 self-peer detection, IPv6-aware connect.
- Upload while downloading: download workers serve piece requests from peers (tit-for-tat).
- `std.http.Client` eliminated: tracker HTTP now routes through io_uring HTTP client (`src/io/http.zig`).
- **Single-threaded event loop** (`src/io/event_loop.zig`): all peer I/O through io_uring. Replaces thread-per-peer.
- SQLite resume state (`src/storage/resume.zig`): persists completed pieces (WAL mode, prepared statements).
- Bundled SQLite build option: `-Dsqlite=bundled` compiles amalgamation, `-Dsqlite=system` (default) links libsqlite3.
- Resume fast path: loads known-complete pieces from SQLite and skips SHA-1 rehashing.
- TOML config file (`varuna.toml`): configurable port, max_peers, hasher_threads, pipeline_depth, resume_db path. `[daemon]` section for api_port, api_bind.
- SHA-1 verification threadpool (configurable thread count via config).
- Graceful SIGINT/SIGTERM shutdown: flushes resume DB, sends tracker stopped event, closes connections.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **qBittorrent-compatible HTTP API over io_uring**: all API I/O (accept, recv, send) via io_uring. Endpoints: webapiVersion, preferences, transfer/info, torrents/info, torrents/add, torrents/delete, torrents/pause, torrents/resume.
- **TorrentSession + SessionManager**: multi-torrent state management with lifecycle (checking, downloading, seeding, paused, stopped, error).
- **varuna-ctl**: CLI client that talks to daemon via HTTP. Commands: list, add (with --save-path), pause, resume, delete, version, stats.
- **Real swarm verified**: `demo_swarm.sh` passes with opentracker + varuna-tools seed + varuna-tools download. Full io_uring event loop piece transfer verified with `cmp`.
- io_uring is the I/O path for all hot-path file and network operations (storage, peer wire, connect, accept, HTTP API, tracker HTTP).
- **Shared multi-torrent event loop**: daemon runs all torrents on a single `EventLoop` thread. `TorrentContext` per torrent. Background threads only for recheck + tracker announce.
- **Async seed disk reads**: `IORING_OP_READ` for serving piece requests, with piece cache. No blocking fallback.
- **Batched block sends**: cache-hit piece block responses queued per tick and flushed as one combined send buffer per peer (~4x fewer send SQEs).
- **Daemon end-to-end download verified**: tracker + seeder + daemon download with file comparison.
- **Resume DB in daemon mode**: `TorrentSession` opens SQLite resume DB on start, loads known-complete pieces to skip rehash, persists new completions periodically (~5s), and flushes on stop/pause/shutdown. Shared DB path from config (`storage.resume_db`) or default `~/.local/share/varuna/resume.db`.

- **Daemon seeding after download**: announces event=completed, creates listen socket, accepts inbound peers. Multi-torrent inbound handshake matching.
- **Per-torrent peer count**: getStats() reports peer count for specific torrent, not global.
- **Data corruption fixes**: inline SHA-1 uses actual piece size, PendingWrite/PendingSend lifetime fixes, hasher result carries torrent_id.
- **Daemon swarm integration test**: `scripts/demo_daemon_swarm.sh` tests full daemon API flow with file verification.

- **systemd-notify support**: `READY=1` after API server is listening, `STOPPING=1` on shutdown. Direct `AF_UNIX`/`SOCK_DGRAM` socket protocol, no libsystemd dependency. Supports abstract sockets.

- **Download and upload speed restrictions**: Token bucket rate limiting at the event loop level. Per-torrent and global (daemon-wide) limits. Config file support (`network.dl_limit`, `network.ul_limit`). qBittorrent-compatible API endpoints (`app/preferences`, `app/setPreferences`, `torrents/setDownloadLimit`, `torrents/setUploadLimit`, `torrents/downloadLimit`, `torrents/uploadLimit`). CLI commands (`set-dl-limit`, `set-ul-limit`, `get-dl-limit`, `get-ul-limit`). Non-blocking design: throttling skips piece assignment and pipeline filling rather than blocking the event loop.

## Next

- Improve tracker lifecycle: handle stale peers, validate against additional private-tracker edge cases.
- Broader integration test coverage (larger files, multi-torrent daemon, resume across restart).
- Test daemon seeding: verify a second downloader can download from the daemon after it seeds.
- UDP tracker support (BEP 15) — partially implemented in src/tracker/udp.zig.

## Known Issues

- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- Resume fast path depends on SQLite DB integrity; if deleted/corrupted, full recheck occurs (safe fallback).
- Some restricted or sandboxed environments can interfere with local tracker startup.

## Last Verified Milestone

- `test: add daemon swarm integration test script` (`eb25bb0`)
- Verified with:
  - `zig build test` (all tests pass)
  - `zig build` (clean build)
  - `scripts/demo_swarm.sh` (standalone swarm passes)
  - `scripts/demo_daemon_swarm.sh` (daemon download + file verification)

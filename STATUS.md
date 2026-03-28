# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, and piece/file layout mapping.
- Target files created up front, verified pieces written with piece-to-file span mapping.
- Startup resume through full piece recheck and on-disk SHA-1 verification.
- HTTP and UDP tracker announce with compact peer lists (BEP 15 for UDP).
- Multi-peer download with rarest-first piece selection, endgame mode, tit-for-tat choking.
- Multi-peer seeding via io_uring event loop with batched block sends.
- Block request pipelining (depth 5), connection timeout (10s via io_uring linked timeout).
- Tracker re-announce on interval, announce-list fallback (BEP 12), completed/stopped events.
- Private tracker support: private flag parsing, per-session key, numwant parameter.
- IPv6 peer support (BEP 7): compact peers6, IPv6-aware connect.
- `varuna inspect`, `varuna verify`, `varuna create` (single-file and directories).
- Bencode encoder with parse-encode roundtrip verification.
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API through io_uring.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Shared multi-torrent event loop**: daemon runs all torrents on a single EventLoop thread with TorrentContext per torrent.
- **SQLite resume state**: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- **Bundled SQLite**: `-Dsqlite=bundled` compiles amalgamation, `-Dsqlite=system` (default) links system lib.
- **TOML config file**: daemon, storage, network, performance sections. XDG config path support.
- **SHA-1 verification threadpool**: configurable thread count.
- **Graceful shutdown**: SIGINT/SIGTERM → flush resume DB, send tracker stopped event, close connections.
- **qBittorrent-compatible HTTP API**: webapiVersion, preferences, transfer/info, torrents/info, add, delete, pause, resume, speed limit endpoints.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete, version, stats, set-dl-limit, set-ul-limit, get-dl-limit, get-ul-limit.
- **Daemon seeding after download**: announces completed, creates listen socket, accepts inbound peers, multi-torrent handshake matching.
- **Async seed disk reads**: IORING_OP_READ with piece cache, no blocking fallback.
- **systemd-notify**: READY=1 / STOPPING=1 via AF_UNIX, no libsystemd dependency.
- **Download/upload speed restrictions**: token bucket rate limiter, per-torrent + global limits, non-blocking throttling. Config, API, CLI support.
- **Performance optimizations**: popcount bitfield, inline message buffers, idle peers list (O(k) not O(4096)), HashMap pending_writes (O(1) not O(n)), claimPiece scan hint, error logging for silent catches.
- **Selective file download**: per-file priorities (normal/high/do_not_download), piece-mask based filtering, boundary-piece handling for cross-file pieces, lazy file creation for previously-skipped files.
- **Sequential download mode**: per-torrent toggle switches PieceTracker from rarest-first to lowest-index selection, enabling streaming playback while downloading.
- **Testing**: 19 peer wire protocol tests, bencode fuzz/edge tests, HTTP parser edge tests, comprehensive transfer test matrix (23 test cases: 1KB-50MB, 16KB/64KB/256KB pieces, multi-file torrents).

## Next

### Essential for Private Tracker Use
- **Bind interface / SO_BINDTODEVICE**: restrict daemon to specific NIC/VPN interface (config + socket option).
- **SOCKS/HTTP proxy support**: for tracker and peer connections (privacy, region-locked trackers).
- **BEP 10 (Extension Protocol)**: extension handshake in reserved bytes — prerequisite for MSE, ut_metadata, PEX.
- **MSE encryption (BEP 6)**: message stream encryption, required by many private trackers.
- **Scrape support**: query peer counts without announcing.
- ~~**Selective file download**: skip files in multi-file torrents, file priority levels.~~ (Done)

### Common Features
- **uTP (BEP 29)**: UDP-based transport with LEDBAT congestion control.
- **API auth**: /api/v2/auth/login for daemon security.
- **Torrent properties API**: /api/v2/torrents/properties (ETA, ratio, creation date).
- **Torrent files API**: /api/v2/torrents/files (file list with sizes, progress, priority).
- **Torrent trackers API**: /api/v2/torrents/trackers.
- **Sync API**: /api/v2/sync/maindata for Flood WebUI live updates.
- **Force reannounce / recheck**: API endpoints for manual trigger.
- **Categories/labels**: organize torrents.
- **Watch folders**: auto-add torrents from directory.

### Nice-to-Have
- **Magnet links (BEP 9)**: requires BEP 10 extension protocol.
- **DHT (BEP 5) / PEX (BEP 11)**: trackerless peer discovery.
- **SHA-NI acceleration**: hardware SHA-1 for faster piece verification.
- **systemd socket activation**: zero-downtime restarts.
- **RSS feed integration**.

## Known Issues

- Intermittent data mismatch in test matrix when tests run in rapid sequence (likely port reuse / process cleanup timing). Individual tests pass in isolation.
- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- Resume fast path depends on SQLite DB integrity; if deleted/corrupted, full recheck occurs (safe fallback).
- `private=1` flag is parsed but not fully enforced (no DHT/PEX/LSD disable since those aren't implemented yet).

## Last Verified Milestone

- `Merge branch 'varuna-speed-restrictions'` (`fa59bbf`)
- Verified with:
  - `zig build test` (all tests pass)
  - `zig build` (clean build)
  - `scripts/demo_swarm.sh` (standalone swarm passes)

# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

### Core Protocol
- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, piece/file layout mapping.
- HTTP and UDP tracker announce (BEP 15) with compact peer lists, announce-list fallback (BEP 12).
- Tracker scrape (HTTP + UDP): seeders/leechers/snatches queried every 30 minutes.
- Private tracker support: private flag parsing and enforcement (BEP 27). Per-session key, numwant, compact=1. PEX disabled for private torrents.
- IPv6 peer support (BEP 7): compact peers6, IPv6-aware connect.
- BEP 10 Extension Protocol: handshake negotiation, extension message dispatch, advertises ut_metadata and ut_pex (ut_pex omitted for private torrents).
- uTP (BEP 29): packet codec, UtpSocket state machine, LEDBAT congestion control, UtpManager multiplexer, io_uring event loop integration (UDP socket, RECVMSG/SENDMSG, inbound connection accept, peer wire protocol bridge, timeout processing). 30+ tests.
- Multi-peer download: rarest-first piece selection, endgame mode, tit-for-tat choking, block pipelining (depth 5).
- Multi-peer seeding: io_uring event loop, batched block sends, async disk reads with piece cache.
- Selective file download: per-file priorities (normal/high/do_not_download), piece-mask filtering, boundary-piece handling, lazy file creation. Wired into daemon event loop piece picker.
- Sequential download mode: per-torrent toggle for streaming playback.

### Architecture
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API, tracker HTTP through io_uring. Split into focused sub-modules: event_loop.zig (core), peer_handler.zig, protocol.zig, seed_handler.zig, peer_policy.zig, utp_handler.zig.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Shared multi-torrent event loop**: all torrents on one EventLoop thread with TorrentContext per torrent.
- **Shared announce ring**: tracker announces reuse a single ring instead of spawning per-announce threads.
- **Connection limits**: global (500), per-torrent (100), half-open (50). Announce jitter ±10% with initial stagger.
- **Reference codebases as git submodules**: libtorrent (arvidn), libtorrent-rakshasa, qBittorrent, rtorrent, vortex, qui (autobrr).

### Storage & Resume
- SQLite resume state: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- Bundled SQLite option: `-Dsqlite=bundled` or `-Dsqlite=system`.
- Resume fast path: loads known-complete pieces from SQLite, skips SHA-1 rehashing.
- Lifetime transfer stats: total_uploaded/total_downloaded persisted to SQLite, loaded as baseline on startup so share ratio survives daemon restarts.
- Categories and tags persisted to SQLite (write-through on change, load at startup).
- fdatasync, fallocate pre-allocation via io_uring.
- io_uring op coverage: shutdown, statx, renameat, unlinkat, send_zc, cancel, timeout, link_timeout, fixed buffers (READ_FIXED/WRITE_FIXED with registered buffer pool).

### Configuration
- TOML config file with daemon, storage, network, performance sections. XDG config path support.
- Bind interface (SO_BINDTODEVICE), bind address, port ranges (port_min/port_max).
- Download/upload speed limits (per-torrent + global), connection limits, hasher threads, pipeline depth.
- API credentials (api_username, api_password).

### API (qBittorrent v2 compatible)
- **Auth**: login/logout with session cookies (SID), 1-hour timeout, configurable credentials.
- **Core**: webapiVersion, preferences, setPreferences, transfer/info.
- **Torrents**: info, add (multipart + raw), delete, pause, resume, properties, files, trackers.
- **Controls**: filePrio, setSequentialDownload, setDownloadLimit, setUploadLimit, downloadLimit, uploadLimit, forceReannounce, recheck.
- **Categories & Tags**: categories (create/edit/remove/list/setCategory), tags (create/delete/addTags/removeTags/list).
- **Sync**: /api/v2/sync/maindata delta protocol (rid-based, Wyhash change detection, 100-snapshot circular buffer).
- **Multipart form-data**: zero-copy parser for Flood/WebUI torrent uploads.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete, version, stats, speed limits (set/get), --username/--password auth.

### Daemon Features
- Graceful SIGINT/SIGTERM shutdown: flush resume DB, send tracker stopped, close connections.
- systemd-notify: READY=1 / STOPPING=1 via AF_UNIX.
- Daemon seeding after download: announces completed, creates listen socket, multi-torrent handshake matching.
- ETA calculation and share ratio tracking (lifetime, persisted).
- Download/upload speed tracking with 2-second rolling window.

### Performance & Hardening
- **SHA-1 hardware acceleration**: runtime CPU detection for x86_64 SHA-NI (~2x to ~2.2 GB/s) and AArch64 SHA1 crypto extensions. Atomic-cached dispatch, automatic fallback to software.
- popcount bitfield counting, inline message buffers (16-byte for small messages).
- Idle peers list (O(k) not O(4096)), HashMap pending_writes (O(1) not O(n)).
- claimPiece scan hint + min_availability for faster rarest-first selection.
- Hasher TOCTOU fix (atomic drainResultsInto), proper drain loop, endgame duplicate write skip.
- timeout_pending tracking, write error checking in handleDiskWrite, error logging for silent catches.
- io_uring send buffer UAF fix: split free-one vs free-all pending sends, stale-CQE guards, SQE-submit-failure fix.
- IORING_OP_CLOSE for hot-path fd cleanup in RPC server.
- Session use-after-free fix: RPC handlers copy data under mutex instead of holding raw session pointers.
- Shared event loop lifetime hardening: pause/stop/resume now detach torrents from the shared EventLoop before freeing runtime state, and resume preserves daemon/shared-loop integration.
- Tracker background-worker hardening: session teardown now waits for both announce and scrape workers, and announce/scrape serialize access to the shared announce ring.
- Hasher OOM resilience: free piece buffer and log on result append failure.
- JSON injection prevention: escape helper for all user-provided strings in API responses.
- Partial send buffer matching: monotonic send_id in CQE context to match correct in-flight buffer.
- RPC server partial-send handling: API responses now track send progress until the full body is written.
- Seed/read-path correctness: queued seed responses own exact block copies, async seed reads use unique IDs, and only successfully submitted reads/writes contribute to pending completion counts.

### Testing
- 19 peer wire protocol tests, 10 BEP 10 extension tests, 31 uTP/LEDBAT tests, 5 categories tests, 8 resume DB tests.
- Bencode fuzz + edge case tests, HTTP parser fuzz tests.
- Fuzz tests for: multipart parser, tracker response, uTP packets, BEP 10 extensions, scrape response (18 fuzz tests total).
- Regression tests for API partial-send progress, unique seed read IDs, seed block-copy batching, shared-event-loop detach on stop, shared-loop preservation on resume, and failed disk-write release.
- 10 io_uring Ring tests: pread/pwrite roundtrip, short reads, probe, shutdown, statx, renameat, unlinkat, cancel, timeout, link_timeout, send_zc, fixed buffer roundtrip.
- Transfer test matrix: 24 tests (1KB-100MB, 16KB/64KB/256KB pieces, multi-file torrents). All pass.
- Daemon swarm integration test, daemon-to-peer seeding test, selective download integration test.
- SHA-1 benchmarks: std vs SHA-NI vs direct vs memory bandwidth baseline.
- Profiling workflow: strace, perf, bpftrace build helpers.

## Next

### Protocol
- **uTP outbound connections**: initiate uTP connections to peers (currently inbound-only).
- **PEX (BEP 11)**: peer exchange via BEP 10 extensions. Discover peers through existing connections.
- **DHT (BEP 5)**: trackerless peer discovery (large feature).
- **Magnet links (BEP 9)**: metadata download via ut_metadata extension.
- **MSE encryption (BEP 6)**: message stream encryption/obfuscation (deferred).

### Operational
- **Flood/qui WebUI validation**: test against real Flood or qui instance to find API gaps.
- **systemd socket activation**: fd inheritance from systemd.
- **Torrent data relocation**: move completed downloads to a different path via API.

## Known Issues

- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- uTP supports inbound connections only; outbound uTP connect not yet implemented.

## Last Verified Milestone

- Working tree bugfix pass: shared-event-loop lifetime, seed read/response correctness, RPC accessor safety, API partial-send handling
- Transfer test matrix: 24/24 pass
- `zig build test`: all tests pass
- `zig build`: clean build
- `scripts/demo_swarm.sh`: standalone swarm passes

# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

### Core Protocol
- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, piece/file layout mapping.
- HTTP and UDP tracker announce (BEP 15) with compact peer lists, announce-list fallback (BEP 12).
- Tracker scrape (HTTP + UDP): seeders/leechers/snatches queried every 30 minutes.
- Private tracker support: private flag parsing, per-session key, numwant, compact=1.
- IPv6 peer support (BEP 7): compact peers6, IPv6-aware connect.
- BEP 10 Extension Protocol: handshake negotiation, extension message dispatch, advertises ut_metadata and ut_pex.
- uTP protocol layer (BEP 29): packet codec, UtpSocket state machine, LEDBAT congestion control, UtpManager multiplexer, io_uring event loop integration (UDP socket, RECVMSG/SENDMSG, inbound connection accept, peer wire protocol bridge). 30+ tests.
- Multi-peer download: rarest-first piece selection, endgame mode, tit-for-tat choking, block pipelining (depth 5).
- Multi-peer seeding: io_uring event loop, batched block sends, async disk reads with piece cache.
- Selective file download: per-file priorities (normal/high/do_not_download), piece-mask filtering, boundary-piece handling, lazy file creation.
- Sequential download mode: per-torrent toggle for streaming playback.

### Architecture
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API, tracker HTTP through io_uring.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Shared multi-torrent event loop**: all torrents on one EventLoop thread with TorrentContext per torrent.
- **Shared announce ring**: tracker announces reuse a single ring instead of spawning per-announce threads.
- **Connection limits**: global (500), per-torrent (100), half-open (50). Announce jitter ±10% with initial stagger.

### Storage & Resume
- SQLite resume state: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- Bundled SQLite option: `-Dsqlite=bundled` or `-Dsqlite=system`.
- Resume fast path: loads known-complete pieces from SQLite, skips SHA-1 rehashing.
- Lifetime transfer stats: total_uploaded/total_downloaded persisted to SQLite `transfer_stats` table, loaded as baseline on startup so share ratio survives daemon restarts.
- fdatasync, fallocate pre-allocation via io_uring.

### Configuration
- TOML config file with daemon, storage, network, performance sections. XDG config path support.
- Bind interface (SO_BINDTODEVICE), bind address, port ranges (port_min/port_max).
- Download/upload speed limits (per-torrent + global), connection limits, hasher threads, pipeline depth.

### API (qBittorrent v2 compatible)
- **Auth**: login/logout with session cookies (SID), 1-hour timeout, configurable credentials.
- **Core**: webapiVersion, preferences, setPreferences, transfer/info, app/shutdown.
- **Torrents**: info, add (multipart + raw), delete, pause, resume, properties, files, trackers.
- **Controls**: filePrio, setSequentialDownload, setDownloadLimit, setUploadLimit, downloadLimit, uploadLimit, forceReannounce, recheck.
- **Categories & Tags**: categories (create/edit/remove/list/setCategory), tags (create/delete/addTags/removeTags/list). In-memory stores, per-torrent assignment, included in torrents/info and sync/maindata. Category accepted in torrents/add.
- **Sync**: /api/v2/sync/maindata delta protocol (rid-based, Wyhash change detection, 100-snapshot circular buffer, categories/tags sections).
- **Multipart form-data**: zero-copy parser for Flood/WebUI torrent uploads with savepath and options.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete, version, stats, speed limits (set/get), --username/--password auth.

### Daemon Features
- Graceful SIGINT/SIGTERM shutdown: flush resume DB, send tracker stopped, close connections.
- systemd-notify: READY=1 / STOPPING=1 via AF_UNIX.
- Daemon seeding after download: announces completed, creates listen socket, multi-torrent handshake matching.
- ETA calculation and share ratio tracking in Stats.
- Download/upload speed tracking with 2-second rolling window.

### Performance & Hardening
- **SHA-1 hardware acceleration with runtime CPU detection**: `src/crypto/sha1.zig` supports x86_64 SHA-NI and AArch64 SHA1 crypto extensions. Detection is runtime via CPUID (x86_64) or getauxval/AT_HWCAP (AArch64), cached in an atomic global. A binary compiled on a generic target will still use hardware acceleration when run on a capable CPU.
- popcount bitfield counting, inline message buffers (16-byte for small messages).
- Idle peers list (O(k) not O(4096)), HashMap pending_writes (O(1) not O(n)).
- claimPiece scan hint + min_availability for faster rarest-first selection.
- Hasher TOCTOU fix (atomic drainResultsInto), proper drain loop, endgame duplicate write skip.
- timeout_pending tracking, write error checking in handleDiskWrite, error logging for silent catches.
- **io_uring send buffer UAF fix**: split free-one vs free-all pending sends, stale-CQE guards on handleSend/handleRecv/handleConnect, SQE-submit-failure dangling-pointer fix. Tools binary restored from c_allocator to GPA.
- IORING_OP_CLOSE for hot-path fd cleanup in RPC server.

### Testing
- 19 peer wire protocol tests, 10 BEP 10 extension tests, 31 uTP/LEDBAT tests.
- Bencode fuzz tests + HTTP parser edge case tests.
- Transfer test matrix: 24 tests (1KB-100MB, 16KB/64KB/256KB pieces, multi-file torrents). All pass.
- Daemon swarm integration test, daemon-to-peer seeding test, selective download integration test.
- Profiling workflow: strace, perf, bpftrace build helpers.

## Next

- ~~Use-after-free investigation~~: **Fixed.** `freePendingSend` freed all buffers for a slot per CQE; now `freeOnePendingSend` frees one. `removePeer` now calls `freeAllPendingSends`. Stale-CQE guards added. Tools restored to GPA.
- ~~uTP event loop integration~~: **Done.** UDP socket, RECVMSG/SENDMSG via io_uring, inbound uTP connection accept, peer wire protocol bridge, timeout processing. Outbound uTP connect deferred.
- **uTP outbound connections**: initiate uTP connections to peers (currently only inbound is supported).
- **Statistics persistence**: persist lifetime uploaded/downloaded bytes to resume DB so ratio survives daemon restarts.
- ~~Event loop module split~~: **Done.** event_loop.zig split into peer_handler, protocol, seed_handler, peer_policy, utp_handler modules (~730 lines core + 5 focused sub-modules).
- **Private flag enforcement**: disable PEX/DHT/LSD when `private=1` is set in torrent metadata.
- **SHA-NI acceleration**: hardware SHA-1 on x86_64 (Goldmont+, Zen+) for faster piece verification.
- **Categories/labels**: torrent organization with qBittorrent-compatible API endpoints.
- **PEX (BEP 11)**: peer exchange via BEP 10 extensions.
- **DHT (BEP 5)**: trackerless peer discovery.
- **Magnet links (BEP 9)**: metadata download via ut_metadata extension.
- **MSE encryption (BEP 6)**: message stream encryption/obfuscation.

## Known Issues

- Transfer test matrix (`scripts/test_transfer_matrix.sh`) failing with `NoReachablePeers` -- peer connect/handshake regression, unrelated to the (now-fixed) UAF.
- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- Resume DB doesn't persist lifetime upload/download totals (ratio resets on restart).
- `private=1` flag is parsed but enforcement (disable PEX when implemented) not yet wired.

## Last Verified Milestone

- `rpc: add multipart form-data parsing for torrents/add` (`c8cbd8d`)
- Transfer test matrix: 24/24 pass (including 100MB)
- `zig build test`: all tests pass
- `scripts/demo_swarm.sh`: standalone swarm passes

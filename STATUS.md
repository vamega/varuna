# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

### Core Protocol
- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, piece/file layout mapping.
- HTTP, HTTPS, and UDP tracker announce (BEP 15) with compact peer lists, multi-tracker simultaneous announce (BEP 12). All tiers queried in parallel; first successful response wins. Async DNS resolution with TTL-based caching (`src/io/dns.zig`). Build-time configurable backend: threadpool (default) or c-ares (`-Ddns=c-ares`). HTTPS via vendored BoringSSL with BIO pair transport (all network I/O stays on io_uring); build-time configurable: `-Dtls=boringssl` (default) or `-Dtls=none`.
- Full UDP tracker support (BEP 15): connect/announce/scrape protocol, connection ID caching (2-minute TTL), exponential backoff retries (15 * 2^n seconds), error response handling. io_uring-based async executor (`IORING_OP_SENDMSG`/`IORING_OP_RECVMSG`) for daemon hot path; blocking client for CLI tools. Daemon auto-detects `udp://` URLs and routes to UDP executor. 35+ tests including loopback socket integration tests.
- Tracker scrape (HTTP + UDP): seeders/leechers/snatches queried every 30 minutes.
- Private tracker support: private flag parsing and enforcement (BEP 27). Per-session key, numwant, compact=1. PEX disabled for private torrents.
- IPv6 peer support (BEP 7): compact peers6, IPv6-aware connect.
- BEP 10 Extension Protocol: handshake negotiation, extension message dispatch, advertises ut_metadata and ut_pex (ut_pex omitted for private torrents). Extension handshake includes metadata_size (BEP 9).
- BEP 11 Peer Exchange (PEX): parse incoming ut_pex messages (added/dropped IPv4/IPv6 peers with flags), build and send outbound PEX messages every ~60s with delta encoding, connect to PEX-discovered peers through existing connection machinery, private torrent enforcement (PEX completely disabled).
- BEP 9 Magnet Links (ut_metadata): magnet URI parsing (hex + base32 info-hash, dn=, tr= params), metadata download from peers piece-by-piece with SHA-1 verification, metadata serving to peers via event loop, `metadata_fetching` state. CLI: `varuna-ctl add --magnet <uri>`. API: `urls=` param in `/api/v2/torrents/add`.
- BEP 9 Magnet Link Resilience (`src/net/metadata_fetch.zig`): multi-peer retry (try next peer on disconnect/timeout/reject), per-peer 30s socket timeout (SO_RCVTIMEO/SO_SNDTIMEO), overall 5-minute fetch timeout, peer deduplication, failed-peer retry with backoff (up to 3 attempts), DHT peer provider interface stub (`PeerProvider`), metadata fetch progress reporting (pieces received/total, peers attempted/active/with-metadata, elapsed time, error messages) exposed through `Stats` and API.
- uTP (BEP 29): packet codec, UtpSocket state machine, LEDBAT congestion control, UtpManager multiplexer, io_uring event loop integration (UDP socket, RECVMSG/SENDMSG, inbound and outbound connections, peer wire protocol bridge, timeout processing, retransmission buffer with owned payload tracking, RTO-based retransmission with exponential backoff, fast retransmit on triple duplicate ACK). Fine-grained transport disposition (`TransportDisposition` packed struct) for per-direction TCP/uTP control, with TOML config presets (`tcp_and_utp`/`tcp_only`/`utp_only`), backwards-compatible `enable_utp` fallback, and runtime API control via granular fields or integer bitfield. 40+ tests.
- Multi-peer download: rarest-first piece selection, endgame mode, tit-for-tat choking, block pipelining (depth 5).
- Multi-peer seeding: io_uring event loop, batched block sends, async disk reads with piece cache.
- Selective file download: per-file priorities (normal/high/do_not_download), piece-mask filtering, boundary-piece handling, lazy file creation. Wired into daemon event loop piece picker.
- Sequential download mode: per-torrent toggle for streaming playback.
- MSE/PE (BEP 6): Message Stream Encryption with DH key exchange (768-bit prime), RC4 stream cipher with 1024-byte discard, SKEY identification from info-hash, crypto_provide/crypto_select negotiation, both initiator and responder roles, configurable modes (forced/preferred/enabled/disabled). Transparent encrypt/decrypt integrated into event loop send/recv paths. Async MSE handshake state machine (`MseInitiatorHandshake`/`MseResponderHandshake`) for non-blocking io_uring event loop integration. Auto-fallback: outbound "preferred" mode tries MSE then reconnects plaintext; inbound detects MSE vs BT by first-byte heuristic; per-peer `mse_rejected`/`mse_fallback` tracking prevents retry loops.
- Super-seeding (BEP 16): initial seed optimization. Sends HAVE messages instead of bitfield, tracks per-peer piece distribution, advertises rarest-first to maximize piece diversity. API toggle via `/api/v2/torrents/setSuperSeeding`.
- Partial seeds (BEP 21): `upload_only` extension in BEP 10 handshake. Parse and store `upload_only` flag from peers. Advertise `upload_only: 1` when we are a partial seed (selective download complete but torrent incomplete). Automatic partial seed detection from piece tracker. Skip piece assignment when upload_only. Re-send extension handshake to all peers on state transition. Exposed in API (torrentPeers, properties, maindata).

### Architecture
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API, tracker HTTP, piece verification reads, and metadata fetch through io_uring. Split into focused sub-modules: event_loop.zig (core), peer_handler.zig, protocol.zig, seed_handler.zig, peer_policy.zig, utp_handler.zig, recheck.zig, metadata_handler.zig.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Fail-closed startup/config policy**: malformed config files now abort startup instead of silently falling back to defaults; invalid encryption modes are rejected; daemon startup now blocks on unsupported kernels or missing `io_uring`; removed dead config knobs `connect_timeout_secs`, `performance.pipeline_depth`, and `performance.ring_entries`.
- **Shared multi-torrent event loop**: all torrents on one EventLoop thread with TorrentContext per torrent.
- **Dynamic shared-torrent registry**: the shared EventLoop now uses dynamic slot storage, free-list reuse, `u32` torrent IDs, and hashed info-hash lookup instead of the old fixed 64-slot table.
- **Shared announce ring**: tracker announces reuse a single ring instead of spawning per-announce threads. The blocking `multi_announce.zig` thread pool has been removed; all tracker I/O goes through the ring-based `TrackerExecutor` and `UdpTrackerExecutor`.
- **Per-torrent announce handoff**: background tracker callbacks now queue discovered peers against the correct `torrent_id` instead of using one global mailbox, and background reannounce/scrape fan out across the full effective tracker set (metainfo plus overrides).
- **Async torrent startup**: `doStart()` split into background-thread phase (SQLite+parse only) and event-loop phase. Piece verification uses io_uring reads pipelined through `AsyncRecheck` (4 concurrent pieces) with hasher pool for SHA. Announce scheduling uses timerfd for jittered delay. Background thread exits in milliseconds.
- **Async metadata fetch (BEP 9)**: magnet link metadata download runs as an `AsyncMetadataFetch` state machine on the event loop with up to 3 concurrent peer connections via io_uring connect/send/recv. Replaces the blocking TCP socket path.
- **Timerfd-based scheduling**: event loop supports one-shot timer callbacks via `timerfd_create`/`timerfd_settime`, used for jittered announce delays (replacing `Thread.sleep`).
- **Tracked peer-wire control sends and shutdown drain**: `submitMessage` now routes all peer-wire messages through tracked send ownership instead of borrowing `handshake_buf`, seed reads validate per-span completion lengths, and EventLoop shutdown now dispatches late CQEs until tracked read/write/send state is retired before freeing buffers.
- **Resume/state integrity hardening**: `ResumeWriter.flush()` now swaps and re-queues batches instead of clearing a shared pending slice after unlock, `clearTorrent()` now removes all torrent-scoped resume tables in one transaction, and v2 multi-piece piece checks now fail closed with `DeferredMerkleVerificationRequired` instead of accepting arbitrary payloads.
- **Torrent-core v2/hybrid consistency**: pure-v2 layouts now reject flat v1 `pieceHash()` access, hybrids keep v1 piece-grid mapping semantics instead of being treated like file-aligned v2 layouts, and metainfo parsing now rejects `piece length = 0`.
- **Tracker announce failover correctness**: `multi_announce` now returns as soon as the first tracker with peers wins instead of blocking on every worker thread, and UDP announce retries now validate against the live retry transaction ID after cached-connection recovery.
- **Peer/DHT routing correctness**: uTP packets are keyed by remote address plus connection ID, unknown-connection resets preserve the real sender address, PEX dropped-peer deltas remain pending when capped, DHT lookups requeue candidates when the pending table is full, DHT replies match on sender as well as transaction ID, and persisted IPv6 nodes now round-trip correctly.
- **RPC delta/auth hardening**: form/query parameters are centrally URL-decoded, `/sync/torrentPeers` now uses rid-based per-torrent peer deltas with `peers_removed`, login cookies are explicitly `SameSite=Lax`, wildcard CORS no longer advertises credentialed cookie access, and `setPreferences` now rejects malformed JSON/form values instead of silently ignoring them.
- **MSE / RC4 input hardening**: MSE now rejects invalid DH public keys before shared-secret derivation, both blocking and async responder paths bound initial payload length, and RC4 initialization rejects empty keys.
- **Queue/runtime operational cleanup**: queue enforcement consolidated into `QueueManager.enforce()` (single entry point for both promotion and demotion), runtime DHT toggles flip `engine.enabled` instead of dropping the engine pointer, `setLocation()` no longer holds the global session mutex across filesystem moves, and `/sync/maindata` now returns the sync body directly instead of arena-building then duplicating it.
- **Connection limits**: global (500), per-torrent (100), half-open (50). Announce jitter ±10% with initial stagger. max_connections for uTP reduced from 4096 to 512.
- **EventLoop heap-allocated in main()**: reduces stack pressure; the prior inline allocation contributed to debug-mode stack overflow risk.
- **TCP listen socket created at startup**: both seeders and downloaders now create a TCP listen socket during startup (not deferred until seeding), so inbound peer connections work during download.
- **UtpSocket heap-allocated on demand**: `connections` array changed from `[4096]UtpSocket` (24 MB inline) to `[512]?*UtpSocket` (4 KB pointers). Sockets allocated on connect, freed on close. Zero-connection baseline: 24 MB to 4 KB.
- **BencodeScanner shared across extension parsers**: `src/net/bencode_scanner.zig` provides a zero-allocation bencode scanner shared between `extensions.zig` and `ut_metadata.zig`, replacing two near-identical inline parsers.
- **main.zig decomposed into 4 named init helpers**: startup logic extracted from a single 530-line `main()` into `initConfig`, `initStorage`, `initNetwork`, and `initEventLoop` for readability.
- **Codebase clarity pass (82 fixes across 62 files)**: unified `addressEql` via `src/net/address.zig` (by-pointer, IPv4+IPv6), extracted `U768` bigint to `src/crypto/bigint.zig`, extracted tracker shared types to `src/tracker/types.zig`, renamed `resume.zig` to `state_db.zig`, renamed `PeerMode.seed/.download` to `.inbound/.outbound`, added `Bitfield.clear()`, removed dead code across all subsystems.
- **Peer listener multishot accept**: the shared `EventLoop` listener now uses `accept_multishot` and only re-arms when the kernel ends the multishot stream.
- **API vectored-send path**: the HTTP API server now sends headers and body as separate iovecs through `io_uring` `sendmsg` instead of concatenating them into one response buffer first.
- **API listener multishot accept**: the RPC server now keeps one `accept_multishot` armed and uses inline per-client request storage for the common short-request case instead of heap-allocating an `8 KiB` receive buffer up front.
- **Reference codebases as git submodules**: libtorrent (arvidn), libtorrent-rakshasa, qBittorrent, rtorrent, vortex, qui (autobrr).
- **BoringSSL TLS**: vendored BoringSSL built as static libraries via pure Zig build (`build/boringssl.zig`). BIO pair transport decouples TLS record processing from socket I/O, keeping all network I/O on io_uring. TlsStream provides feedRecv/pendingSend interface for ciphertext shuttle.

### Storage & Resume
- SQLite resume state: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- Bundled SQLite option: `-Dsqlite=bundled` or `-Dsqlite=system`.
- Resume fast path: loads known-complete pieces from SQLite, skips SHA-1 rehashing. Now integrated with `AsyncRecheck` — known-complete pieces are skipped without io_uring reads.
- Session-owned metadata arena: `Session.load` now allocates torrent bytes, metainfo, layout, and manifest from one arena and frees them as a unit on session teardown.
- **Piece hash lifecycle (Track A, [docs/piece-hash-lifecycle.md](docs/piece-hash-lifecycle.md))**: three-phase memory management for the v1/hybrid SHA-1 piece hash table. **Phase 1 (piece-by-piece + endgame)**: `Session.zeroPieceHash(i)` clobbers a verified piece's 20-byte hash, `Session.freePieces()` releases the entire heap-owned table once `pt.isComplete()`. Wired through `peer_policy.onPieceVerifiedAndPersisted`, fired from both disk-write completion (`peer_handler.zig`) and the do_not_download skipped-spans path. Smart-ban records are consumed in `processHashResults` before disk writes are submitted, so the lifecycle hook is safe by the time it runs. **Multi-source race guard**: `peer_policy.completePieceDownload` checks `pt.isPieceComplete(piece_index)` before reading the layout hash and routes already-complete pieces through the new `cleanupDuplicateCompletion` helper — fixes a race where a second peer's contribution to a multi-source piece would re-enter the hash check after the first peer's verification zeroed the hash, causing a false hash-mismatch attribution to an honest peer. **Phase 2 (seeding-only zero-cost)**: `Session.loadForSeeding` skips `pieces` parsing entirely; `metainfo.parseSeedingOnly` is the underlying surface. The daemon also calls `freePieces()` whenever it determines a torrent is fully complete at startup (skip-recheck full bitfield, recheck full bitfield) so existing fast-path loads get the same steady-state memory profile. **Phase 3 (on-demand recheck)**: `Session.loadPiecesForRecheck()` re-parses the v1 hash table from `torrent_bytes` (held in the session arena). The daemon's `forceRecheck` API path goes through stop+start which re-runs `Session.load` (full materialisation), giving Phase 3 semantics implicitly; the explicit `loadPiecesForRecheck` API is available for future direct-on-existing-session callers. **v2/hybrid analog**: `MerkleCache.evictCompletedFile(file_idx, complete_pieces)` drops the cached per-piece SHA-256 tree once every piece in a file is complete; the small per-file `pieces_root` (32 bytes) stays in metainfo. Wired alongside the v1 hook in `onPieceVerifiedAndPersisted`. Memory savings: a 50 GB v1 torrent at 256 KB pieces frees ~3.9 KB of hash table piece-by-piece during download and `piece_count * 20` bytes (e.g. ~3.9 KB at 256 KB pieces, ~128 MB at 16 KB pieces for 100 GB) at completion; a seeding box of 50 already-complete 50 GB torrents at 256 KB pieces holds zero piece-hash bytes (was ~100 MB). 15 algorithm + boundary tests in `tests/piece_hash_lifecycle_test.zig` (including the smart-ban-friendly "hash-stays-live-across-failed-piece" invariant). Suite: 223 → 238 tests, stable across 3 back-to-back runs. Subsequent Task #6/#9 housekeeping landed `addTest` wiring fixes (+24 tests) plus subsystem `test { _ = ... }` blocks that pull in source-side `test "..."` blocks under `zig build test` (Zig 0.15.2 doesn't propagate test discovery through plain `pub const` imports — see STYLE.md "The Test Hierarchy"). Total post-Track-A suite: **511/511** tests passing (5+ back-to-back stable runs), exposing 2 production bugs along the way (merkle_cache double-deinit, manifest errdefer UAF) plus ~10 stale test expectations updated.
- Lifetime transfer stats: total_uploaded/total_downloaded persisted to SQLite, loaded as baseline on startup so share ratio survives daemon restarts.
- Categories and tags persisted to SQLite (write-through on change, load at startup).
- Per-torrent rate limits persisted to SQLite (saved on change, loaded at startup).
- fdatasync, fallocate pre-allocation via io_uring.
- io_uring op coverage: shutdown, statx, renameat, unlinkat, send_zc, cancel, timeout, link_timeout, fixed buffers (READ_FIXED/WRITE_FIXED with registered buffer pool).

### Configuration
- TOML config file with daemon, storage, network, performance sections. XDG config path support. Malformed discovered config now aborts startup instead of silently falling back to defaults.
- Bind interface (SO_BINDTODEVICE), bind address, port ranges (port_min/port_max).
- Download/upload speed limits (per-torrent + global), connection limits, hasher threads, piece cache sizing.
- API credentials (api_username, api_password).
- Build options: `-Dsqlite=system|bundled`, `-Ddns=threadpool|c-ares`, `-Dtls=boringssl|none`, `-Dcrypto=varuna|stdlib|boringssl`.
- Configurable crypto backend (`-Dcrypto`): `varuna` (default, SHA-1 with runtime SHA-NI/AArch64 hardware detection), `stdlib` (Zig std.crypto), `boringssl` (vendored BoringSSL SHA/RC4). Unified dispatch via `src/crypto/backend.zig`. Build-time validation prevents `-Dcrypto=boringssl` when `-Dtls=none`.
- Peer ID masquerading: `network.masquerade_as` config option to identify as qBittorrent, rTorrent, uTorrent, Deluge, or Transmission. Useful for private trackers with client whitelists.

### API (qBittorrent v2 compatible)
- **Auth**: login/logout with session cookies (SID), 1-hour timeout, configurable credentials.
- **Core**: webapiVersion, version, buildInfo, preferences (40+ fields), setPreferences (form + JSON), transfer/info (with connection_status, real DHT node count from routing table), speedLimitsMode, defaultSavePath, toggleSpeedLimitsMode (stub), transfer/downloadLimit, transfer/uploadLimit, transfer/setDownloadLimit, transfer/setUploadLimit.
- **Torrents**: info (40+ fields matching qui Torrent interface, real infohash_v2 for BEP 52 torrents), add (multipart + raw), delete, pause, resume, properties (30+ fields with hash, name, created_by, creation_date, scrape-based peers_total/seeds_total, v2 info-hash, completion_date), files (with index, availability, real piece_range), trackers (with msg field), pieceStates, pieceHashes, export (.torrent file).
- **Controls**: filePrio, setSequentialDownload, toggleSequentialDownload, setDownloadLimit, setUploadLimit, downloadLimit, uploadLimit, forceReannounce, recheck, setLocation, connDiagnostics, setShareLimits, rename, setForceStart, setAutoManagement (stub), renameFile (stub), renameFolder (stub), addPeers.
- **Categories & Tags**: categories (create/edit/remove/list/setCategory), tags (create/delete/addTags/removeTags/list).
- **Sync**: /api/v2/sync/maindata delta protocol (rid-based, Wyhash change detection, 100-snapshot circular buffer, real DHT node count in server_state, infohash_v2 in torrent objects), sync/torrentPeers with real peer data (IP, flags, progress, transfer stats, per-peer dl/ul speed, client name from peer ID).
- **Compatibility**: qBittorrent state strings (downloading/uploading/pausedDL/pausedUP/etc), CORS headers on all responses, OPTIONS preflight handler, magnet URI generation, percent-encoding, content_path building, HTTP 404 for unknown API paths. Validated against qui (autobrr/qui) TypeScript interfaces. See [docs/api-compatibility.md](docs/api-compatibility.md) for full endpoint coverage and known placeholder fields.
- **Multipart form-data**: zero-copy parser for Flood/WebUI torrent uploads.
- **Tracker editing**: add, remove, and edit tracker URLs per-torrent via API and CLI. User overrides persisted to SQLite `tracker_overrides` table, loaded on startup. Overrides applied on top of metainfo announce-list. Re-announce triggered on add/edit. qBittorrent-compatible endpoints: `addTrackers`, `removeTrackers`, `editTracker`.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete (--delete-files), move, conn-diag, add-tracker, remove-tracker, edit-tracker, version, stats, speed limits (set/get), --username/--password auth.

### Daemon Features
- Graceful SIGINT/SIGTERM shutdown with in-flight transfer draining: on signal, stops new work, drains pending disk writes/hashes/downloads, sends tracker stopped announces, flushes resume DB, configurable timeout (default 10s), double-signal escape hatch for forced exit.
- systemd-notify: READY=1 / STOPPING=1 via AF_UNIX.
- systemd socket activation: inherits listen fds from systemd via $LISTEN_FDS/$LISTEN_PID (sd_listen_fds protocol). Supports API server and peer listener sockets.
- Daemon seeding after download: announces completed, creates listen socket, multi-torrent handshake matching.
- ETA calculation and share ratio tracking (lifetime, persisted).
- Download/upload speed tracking with 2-second rolling window (torrent-level and per-peer).
- Per-peer client identification from peer ID (Azureus-style, Shadow-style, Mainline formats).
- Per-torrent rate limit persistence: dl_limit/ul_limit saved to SQLite, restored on daemon restart.
- Torrent data relocation: move completed torrent data to a new path via API (setLocation endpoint).
- Per-torrent connection diagnostics: connection attempts/failures/timeouts exposed via connDiagnostics API.
- Partial download cleanup: delete torrent with --delete-files removes data files and empty directories.
- Torrent queueing: configurable limits for active downloads/uploads/total (`queueing_enabled`, `max_active_downloads`, `max_active_uploads`, `max_active_torrents` in `[daemon]` config). `queued` state added to `TorrentSession.State`. Auto-management: when an active torrent completes/pauses/is removed, next queued torrent starts. Queue positions (1-based) persisted to SQLite. API endpoints: `increasePrio`, `decreasePrio`, `topPrio`, `bottomPrio` (qBittorrent-compatible). Preferences API wired to real queue config. CLI: `queue-top`, `queue-bottom`, `queue-up`, `queue-down`.
- Share ratio limits: automatic pause or remove when torrents reach a target upload/download ratio or seeding time. Global limits configurable via TOML config and preferences API. Per-torrent overrides via `setShareLimits` endpoint. Limits and completion timestamps persisted to SQLite. Enforcement runs every ~30 seconds in the main loop.

### Performance & Hardening
- **SHA-1 hardware acceleration**: runtime CPU detection for x86_64 SHA-NI (~2x to ~2.2 GB/s) and AArch64 SHA1 crypto extensions. Atomic-cached dispatch, automatic fallback to software.
- popcount bitfield counting, inline message buffers (16-byte for small messages).
- Idle peers list (O(k) not O(4096)), HashMap pending_writes (O(1) not O(n)).
- Shared torrent routing no longer scans the full torrent table on inbound TCP/uTP/DHT paths; info-hash lookup is O(1), and disk-write CQEs use dedicated write IDs instead of packing torrent IDs into `user_data.context`.
- claimPiece scan hint + min_availability for faster rarest-first selection.
- Hasher TOCTOU fix (atomic drainResultsInto), proper drain loop, endgame duplicate write skip.
- timeout_pending tracking, write error checking in handleDiskWrite, error logging for silent catches.
- io_uring send buffer UAF fix: split free-one vs free-all pending sends, stale-CQE guards, SQE-submit-failure fix.
- EventLoop deinit UAF fix: phased shutdown (close fds, drain CQEs, then free buffers) prevents GPA debug-poison UAF.
- IORING_OP_CLOSE for hot-path fd cleanup in RPC server.
- Session use-after-free fix: RPC handlers copy data under mutex instead of holding raw session pointers.
- Shared event loop lifetime hardening: pause/stop/resume now detach torrents from the shared EventLoop before freeing runtime state, and resume preserves daemon/shared-loop integration.
- Tracker executor consolidation: daemon torrent sessions now use only the shared tracker executor for announces and scrapes; the old per-session tracker ring/DNS fallback path is gone.
- Hasher OOM resilience: free piece buffer and log on result append failure.
- JSON injection prevention: escape helper for all user-provided strings in API responses.
- Partial send buffer matching: monotonic send_id in CQE context to match correct in-flight buffer.
- RPC server partial-send handling: API responses now track send progress until the full body is written.
- Seed/read-path correctness: queued seed responses own exact block copies, async seed reads use unique IDs, and only successfully submitted reads/writes contribute to pending completion counts.
- **Piece cache with transparent huge-page hinting**: reusable mmap-backed buffer pool for seed piece reads. It applies `madvise(MADV_HUGEPAGE)` without requiring explicit huge-page provisioning. Freed pooled slices are returned to the cache and merged for reuse. Config: `performance.piece_cache_size` (`0` = default `64 MiB`).
- **TorrentSession cleanup**: removed the old standalone/per-session network path, `getStats()` is now side-effect free, and `SessionManager` deduplicates torrent/magnet session registration.
- **Synthetic memory baseline harness**: `varuna-perf` with allocator-counting scenarios for peer scans, request batching, seed batching, extension parsing, session loading, and `/sync/maindata`. Supports stable before/after comparisons without a live swarm.
- **Piece buffer pool**: `EventLoop` now reuses `PieceBuffer` wrappers and retains common heap-backed piece sizes behind a bounded pool instead of reallocating them on every seed-read cycle.
- **Vectored send-state pool**: plaintext seed uploads now reuse packed `sendmsg` state blocks by batch capacity instead of allocating one aligned block per batch.
- **Synthetic API burst harness**: `varuna-perf` now includes `api_get_burst` and `api_upload_burst`, which drive the real RPC server over loopback sockets with configurable client concurrency and upload body size.
- **API steady-state allocation removal**: standard RPC responses now write headers into inline per-client storage, `api_get_burst` is allocation-free, and upload-sized request buffers are retained per slot up to `256 KiB` instead of reallocating on every disconnect.
- **Synthetic peer accept harness**: `varuna-perf` now includes `peer_accept_burst`, which drives the real shared `EventLoop` listener with inbound loopback TCP connects and measures accept-slot-recv-EOF teardown cost.
- **First allocation-reduction pass**: request batches now avoid heap allocation, seed batching no longer heap-copies each queued block, `/sync/maindata` uses fixed-size snapshot keys plus a request arena, BEP 9/BEP 10 decode paths are allocation-free, and scan-heavy peer-policy paths use dense active-slot lists.

### BEP 52 (BitTorrent v2 / Hybrid Torrents)
- Torrent version detection: v1/v2/hybrid based on `pieces` vs `file tree` field presence.
- v2 file tree parser (`src/torrent/file_tree.zig`): recursive walk of nested bencode dictionaries, empty-string leaf markers, `pieces root` extraction.
- SHA-256 Merkle tree (`src/torrent/merkle.zig`): tree construction from piece hashes, root computation, per-piece verification, Merkle proof generation and verification, power-of-2 padding with zero-hashes.
- v2 info-hash calculation (`src/torrent/info_hash.zig`): SHA-256 of bencoded info dict using `std.crypto.hash.sha2.Sha256` (hardware-accelerated).
- Extended `Metainfo` struct: `version`, `info_hash_v2`, `file_tree_v2` fields. Pure v2 torrents populate v1 `files` array from file tree for backward compatibility.
- File-aligned piece layout (`src/torrent/layout.zig`): v2 pieces never cross file boundaries, each file has its own piece range, `mapPieceV2` always returns single-file spans.
- Dual-hash verification (`src/storage/verify.zig`): `PiecePlan.hash_type` selects SHA-1 or SHA-256, `verifyPieceBuffer` supports both. Per-file Merkle root verification for multi-piece v2 files (`recheckV2`), `verifyV2FileComplete` and `verifyV2MerkleRoot` for file-level Merkle tree validation.
- Hasher thread pool SHA-256 support (`src/io/hasher.zig`): `Job.hash_type` field, worker function dispatches to SHA-1 or SHA-256.
- Dual info-hash handshake matching (`src/io/peer_handler.zig`, `src/io/utp_handler.zig`): inbound and outbound peers matched on v1 or truncated v2 info-hash for hybrid torrents. BEP 52 v2 reserved bit (`reserved[7] & 0x10`) advertised in handshake for v2/hybrid torrents.
- `TorrentContext.info_hash_v2` field: truncated 20-byte v2 hash stored per-torrent in the event loop for handshake matching.
- Tracker announce v2 info-hash (`src/tracker/announce.zig`): `Request.info_hash_v2` field adds a second `info_hash` parameter with truncated v2 hash for v2-aware trackers.
- Resume DB v2 info-hash (`src/storage/resume.zig`): `info_hash_v2` table stores the full 32-byte SHA-256 hash, `saveInfoHashV2`/`loadInfoHashV2` methods.
- `TorrentSession.info_hash_v2` field: v2 hash propagated from metainfo to session, persisted to and loaded from resume DB, passed in all announce calls.
- BEP 52 hash exchange wire protocol (`src/net/hash_exchange.zig`): `hash request` (msg 21), `hashes` (msg 22), `hash reject` (msg 23) message encode/decode. Merkle proof building from tree. Integrated into `src/io/protocol.zig` message dispatch.
- Runtime Merkle tree cache (`src/torrent/merkle_cache.zig`): per-file Merkle tree cache with LRU eviction (`TorrentContext.merkle_cache`). Trees built lazily on first hash request via async hasher threadpool (no event loop blocking). No piece-count limit (removed previous 4096-piece cap). Multiple peers requesting the same file's tree are coalesced into a single build job. Pending requests cleaned up on peer disconnect. Cache validated against `pieces_root` from torrent metadata. Protocol handler (`handleHashRequest` in `src/io/protocol.zig`) serves hashes from cache or submits async build. 11 merkle cache tests, 2 async hasher merkle tests.
- DHT v2 announce/lookup (`src/dht/dht.zig`): `requestPeers`, `forceRequery`, `announcePeer` accept an optional truncated v2 info-hash (`info_hash_v2[0..20]`). Hybrid torrents register/announce both hashes so v1-only and v2-only DHT searchers both find us. `TorrentSession.dhtV2HashTruncated()` centralises the truncation; magnet-path and seed-announce sites in `src/main.zig` and `src/daemon/torrent_session.zig` thread the v2 hash through.
- Peer-provided leaf hash storage (`src/torrent/leaf_hashes.zig`): `LeafHashStore` per-piece map of verified BEP 52 leaf hashes. `verifyAndStoreHashesResponse` walks a peer's hashes-message proof up to the file's `pieces_root`; verified leaves are stored under their global piece index for later piece-completion validation. `handleHashesResponse` in `src/io/protocol.zig` lazily allocates the store on the first valid response. Padded leaves past `file_piece_count` are not stored. Conflicting re-stores rejected.

### DHT (BEP 5) — Distributed Hash Table
- 160-bit node ID generation, XOR distance, bucket index calculation (`src/dht/node_id.zig`). Compact node info encode/decode (26-byte BEP 5 format). Random ID generation within bucket range for refresh.
- Routing table with 160 k-buckets (K=8), node classification (good/questionable/bad per BEP 5 section 2), eviction of bad nodes, bucket staleness detection for 15-minute refresh (`src/dht/routing_table.zig`). findClosest returns K nodes sorted by XOR distance.
- Zero-allocation KRPC protocol layer (`src/dht/krpc.zig`): manual bencode parse/encode for ping, find_node, get_peers, announce_peer queries and responses, error messages. No heap allocation for parsing incoming UDP datagrams.
- Token management (`src/dht/token.zig`): SipHash-2-4 HMAC tokens bound to querier IP, 5-minute secret rotation with overlap window for announce_peer security.
- Iterative lookup state machine (`src/dht/lookup.zig`): alpha=3 concurrent queries, candidate tracking sorted by XOR distance, peer collection for get_peers, token saving for announce_peer follow-up.
- Bootstrap from hard-coded nodes (router.bittorrent.com, dht.transmissionbt.com, router.utorrent.com, dht.libtorrent.org). DNS resolution at startup before event loop.
- DHT engine (`src/dht/dht.zig`): main coordinator tying routing table, KRPC, lookups, tokens, and bootstrap together. Responds to incoming queries (ping, find_node, get_peers, announce_peer). Drives iterative lookups. Sends announce_peer after get_peers completes. Outbound packet queue for event loop integration.
- SQLite persistence (`src/dht/persistence.zig`): dht_config and dht_nodes tables. Saves/loads node ID and up to 300 routing table nodes. Runs on background thread.
- Event loop integration (`src/io/dht_handler.zig`): DHT/uTP demux by first byte ('d' for KRPC, else uTP). DHT tick in event loop. Outbound packets sent via shared UDP socket. Discovered peers fed into existing peer connection pipeline via addPeerForTorrent.
- **DHT activation wiring** (`src/main.zig`): DhtEngine instantiated at startup, bootstrap nodes resolved, UDP socket started before event loop, `requestPeers()` called when torrents integrate, `announcePeer()` called on seed setup, event loop ticks when UDP socket is open.
- **IPv4/IPv6 dual-stack UDP socket** (`src/io/event_loop.zig`): `startUtpListener()` now creates an AF.INET6 socket with `IPV6_V6ONLY=0`, applies `SO_BINDTODEVICE` from config, binds to `::`. Recv address buffer upgraded to `std.net.Address` (large enough for IPv6). IPv4-mapped addresses (`::ffff:x.x.x.x`) normalized on recv, converted back on send.
- **BEP 32 KRPC**: `nodes6` and `values6` fields parsed in responses. `encodeCompactNode6`/`decodeCompactNode6` for 38-byte IPv6 compact node info. IPv6 peers parsed from `values6` (18-byte format).
- **Disable-trackers mode**: `[network] disable_trackers = true` skips tracker announces for non-private torrents; relies on DHT/PEX. Tracker failure is now a warning (not fatal); DHT fills peers asynchronously.

### Testing
- 19 peer wire protocol tests, 16 BEP 10 extension tests (including 6 BEP 21 upload_only tests), 15 PEX tests, 31 uTP/LEDBAT tests, 5 categories tests, 10 resume DB tests, 25 MSE/RC4 tests, 13 magnet URI tests, 13 ut_metadata tests, 12 metadata fetch resilience tests.
- Focused build-driven subsystem test entrypoints now exist for faster iteration, starting with `zig build test-torrent-session` for `src/daemon/torrent_session.zig`. Direct-file `zig test src/...` remains unsupported for repo modules wired through `build.zig`.
- 13 async MSE state machine tests (initiator phases, responder phases, VC scan limit, fallback, first-byte detection).
- Bencode fuzz + edge case tests, HTTP parser fuzz tests.
- Fuzz tests for: multipart parser, tracker response, uTP packets, BEP 10 extensions, scrape response (18 fuzz tests total).
- Regression tests for API partial-send progress, unique seed read IDs, seed block-copy batching, shared-event-loop detach on stop, shared-loop preservation on resume, and failed disk-write release.
- Shared EventLoop high-count regression: `20,000` active torrent contexts with hashed lookup and freed-slot reuse.
- 10 io_uring Ring tests: pread/pwrite roundtrip, short reads, probe, shutdown, statx, renameat, unlinkat, cancel, timeout, link_timeout, send_zc, fixed buffer roundtrip.
- Transfer test matrix: 24 tests (1KB-100MB, 16KB/64KB/256KB pieces, multi-file torrents). All pass.
- Daemon swarm integration test, daemon-to-peer seeding test, selective download integration test.
- SHA-1 benchmarks: std vs SHA-NI vs direct vs memory bandwidth baseline.
- Profiling workflow: strace, perf, bpftrace build helpers.
- Profiling build steps auto-detect a real `perf` backend under `/usr/lib/linux-tools.../perf` and bypass Ubuntu's `/usr/bin/perf` wrapper on WSL hosts.
- Adversarial peer tests (35 tests): oversized messages, invalid IDs, wrong lengths, malformed handshake, unrequested pieces, OOB piece indices, garbage extension bencode, bitfield bounds, connection limit sanity.
- Private tracker simulation tests (25 tests): required announce fields (compact, numwant, key, event), per-session key generation, private flag enforcement (no ut_pex), tracker error responses (failure reason, missing fields, invalid formats, negative interval), compact peer parsing.
- Soak test framework (`zig build soak-test`): multi-torrent piece tracker stress, allocator leak detection (GPA), FD leak monitoring, tick latency tracking, bitfield stress cycles.
- 5 super-seed (BEP 16) tests, 4 partial seed (BEP 21) tests, 2 multi-announce tests, 7 huge page cache tests.
- BEP 52 tests: 11 Merkle tree tests, 8 file tree parser tests, 7 v2 metainfo tests, 4 v2 layout tests, 1 v2 info-hash test, 8 hash exchange tests, 2 v2 announce URL tests, 2 v2 resume DB tests, 11 Merkle cache tests, 2 async Merkle hasher tests, 4 v2 Merkle verification tests (single-piece/multi-piece/file-complete/root-verify), 5 v2 handshake tests (v2 reserved bit, supportsV2, compatibility), 8 leaf-hash store tests (init/get/count, full leaf layer, wrong root rejection, partial proof, conflicting store rejection, non-power-of-two rejection, padding skip, encode/decode round-trip).
- DHT tests: 7 node_id tests, 8 routing_table tests, 8 krpc tests, 8 token tests, 7 lookup tests, 9 dht_engine tests (including hybrid v1/v2 requestPeers/forceRequery/announcePeer fan-out), 1 persistence test (48 total).
- 4 tracker override persistence tests (add/load, edit with orig_url, remove/clear, per-torrent isolation).
- 10 peer ID client identification tests (Azureus-style, Shadow-style, Mainline, unknown).
- 17 peer ID masquerading tests: all 5 client formats, case insensitivity, malformed input, unsupported client error, random suffix validation.
- 4 TLS tests: TlsStream init/deinit, ClientHello generation, garbage ciphertext handling, stub error returns. 3 HTTPS URL parsing tests.
- 10 queue manager tests: position management, remove/compact, move to top/bottom, increase/decrease priority, boundary no-ops, disabled queue, enforcement with limits. 1 compat test for queued state mapping.
- Compile-time safety tests (`zig build test-safety`): parameter size checks (by-value vs by-pointer thresholds), struct init safety, size regression tests for key data structures.
- SO_BINDTODEVICE tests (`zig build test-bind-device`): socket creation wrappers with enforced `bind_device` (via `createTcpSocket`/`createUdpSocket` in `src/net/socket.zig`).
- strace policy validator script (`scripts/validate_strace.sh`): automated verification that daemon network I/O routes through `io_uring_enter` with no direct `connect`/`send`/`recv`/`sendto`/`recvfrom`/`sendmsg`/`recvmsg` syscalls.
- `zig build test-swarm`: automated end-to-end swarm transfer test — creates a torrent, starts a seeder and downloader daemon, verifies piece transfer completes.
- Docker cross-client conformance test infrastructure (`test/docker/`): containerized testing harness for validating protocol compatibility with third-party clients.

### IO Abstraction (Stages 2-5 complete; daemon generic over IO backend)

**Resulting architectural shape** (post all five stages):
- `pub fn EventLoopOf(comptime IO: type) type` in `src/io/event_loop.zig` is the daemon event loop, generic over its IO backend. Two concrete instantiations exist: `EventLoop = EventLoopOf(RealIO)` is the production type used by `varuna`, `varuna-ctl`, and `varuna-tools` (zero behavior change); `EventLoopOf(SimIO)` is the deterministic-simulation type used by sim tests.
- `RealIO` and `SimIO` share `src/io/io_interface.zig` as their parity contract; backend-specific state is kept in opaque `Completion._backend_state[64]`. Comptime parity is enforced by `tests/io_backend_parity_test.zig`; all fd-touching ops (including `closeSocket`) are required methods rather than direct `posix.close` calls.
- Deterministic simulation is now a first-class test mode. `SimulatorOf(comptime Driver: type)` + `SimPeer` (10 protocol behaviours) + BUGGIFY (`SimIO.injectRandomFault` per-step + `FaultConfig` per-op) form the harness; `SimIO.Config.max_ops_per_tick` (default 4096) models real `io_uring`'s CQE batch boundary so EL periodic-policy passes interleave with I/O completions.
- The smart-ban algorithm is the canonical demonstration of the layered testing strategy (see `STYLE.md > Layered Testing Strategy`): algorithm test in `sim_smart_ban_protocol_test.zig`, integration test in `sim_smart_ban_eventloop_test.zig` (8 seeds, no faults), safety-under-faults test in the same file's BUGGIFY case (32 seeds, vacuous-pass guard at 50% ban rate).

**Components**:
- **Public IO contract (`src/io/io_interface.zig`)**: `Operation` and `Result` tagged unions (one variant per op), `CallbackAction = enum { disarm, rearm }`, single-callback signature, caller-owned `Completion` with opaque per-backend state (`backend_state_size = 64`, comptime-asserted by each backend). `_backend_state` defaults to all-zero so backends can safely read flags like `in_flight` on a fresh completion.
- **`SimIO` (`src/io/sim_io.zig`)**: in-process simulation backend with min-heap pending queue, seeded `std.Random.DefaultPrng`, `FaultConfig` (per-op error probabilities + latency injection). Zero-alloc after init. 8 unit tests cover timeout ordering, fault injection, queue-full, cancel, rearm.
- **`SimIO` socketpair / parking (Stage 3 #13)**: pre-allocated `[]SimSocket` slot pool sized by `Config.socket_capacity`, `createSocketpair() -> [2]fd_t` allocates two slots and links them as partners, `closeSocket(fd)` fails parked recv with `error.ConnectionResetByPeer` (and the partner's parked recv too). `recv` on an empty queue parks the completion on the socket; `send` appends to partner's ring buffer and unparks the partner's recv. `cancel` handles parked completions. Zero-alloc on the data path. 15 socketpair tests in `tests/sim_socketpair_test.zig` (round-trip, parking, partial recv, queue accumulation, close, cancel, mixed heap+park, capacity exhaustion).
- **`SimPeer` (`src/sim/sim_peer.zig`, Stage 4 #6 partial)**: scriptable BitTorrent seeder driven by SimIO completions. Plays the seeder side of the wire protocol (handshake → bitfield → unchoke → piece) over a SimIO socketpair. Behaviours: honest, slow (real `delay_per_block_ns` throttle via `step()`), corrupt, wrong_data, silent_after, disconnect_after, lie_bitfield, greedy (accept-no-respond), lie_extensions (BEP 10 ext-handshake stub). 10 unit tests in `tests/sim_peer_test.zig` exercise the seeder against a manual test-side downloader.
- **`Simulator` (`src/sim/simulator.zig`, Stage 3 #5)**: `SimulatorOf(comptime Driver: type)` with `Driver.tick(*Driver, *SimIO)` as the only contract requirement. `pub const Simulator = SimulatorOf(StubDriver)` is the default for tests that don't need an EventLoop on the other end. Owns SimIO + a fixed-capacity SimSwarm + a seeded RNG + a clock. `step(delta_ns)` advances clock_ns, drives each peer, optionally injects a BUGGIFY fault, calls `driver.tick(&io)`, then ticks the IO backend. `runUntilFine(cond, max_steps, idle_step_ns)` jumps directly to the next pending heap deadline (deterministic ordering). With Stage 2 #12 done and EventLoop parameterised over its IO backend, `SimulatorOf(EventLoop(SimIO))` is the integration. `tests/sim_minimal_swarm_test.zig` drives a 4-piece transfer through one honest SimPeer seeder and a hand-rolled downloader on the other end of a SimIO socketpair.
- **Protocol-only smart-ban regression (`tests/sim_smart_ban_protocol_test.zig`)**: extracted smart-ban Phase 0 algorithm (`trust_points -|= 2` on hash failure; ban at `trust_points <= -7`) running against 5 honest + 1 corrupt SimPeer seeders over a SimIO socketpair. Asserts across 8 seeds: all 4 pieces verify; corrupt peer is banned with `hashfails >= 4`; no honest peer is banned or has hashfails.
- **Smart-ban swarm test (`tests/sim_smart_ban_swarm_test.zig`)**: same 8-seed scenario as the protocol regression, but uses `corrupt: { probability = 1.0 }` (single-bit corruption) and structures the `SwarmDownloader` to mirror the future EventLoop API surface (`getPeerView`, `isPieceComplete`).
- **Smart-ban EventLoop integration test (`tests/sim_smart_ban_eventloop_test.zig`, Stage 4 #6)**: drives the production `EventLoopOf(SimIO)` against 5 honest + 1 corrupt `SimPeer` seeders for 8 deterministic seeds. Uses option (1) bitfield layout — corrupt peer = `{0}`, honest peers = `{1, 2, 3}` — so the rarest-first picker forces piece 0 onto the corrupt peer; after 4 hash failures (trust 0 → -8, threshold -7) the EL fires `BanList.banIp`. Closes Stage 4 DoD #2 + #3. Light-up required `RealIO.closeSocket` parity (so `EL.deinit`/`cleanupPeer` route through `self.io.closeSocket`), `addConnectedPeerWithAddress(fd, tid, addr_opt)` for distinct per-peer addresses, a runtime `SimIO.Config.max_ops_per_tick` cap (default 4096) to model io_uring batch semantics, and a few residual `*EventLoop`→`anytype`/`@ptrCast` conversions in `dht_handler` / `seed_handler` / `utp_handler` / `web_seed_handler`. Detail in `progress-reports/2026-04-25-smart-ban-eventloop-light-up.md`.
- **BUGGIFY smart-ban (Stage 5 #7)**: a second test in `tests/sim_smart_ban_eventloop_test.zig` reruns the same scenario over 32 deterministic seeds under randomized fault injection. Two fault paths in concert: `SimIO.FaultConfig` per-op probabilities (recv/send 0.003, read/write 0.001) for dense per-submission failures, and per-tick heap-probe `SimIO.injectRandomFault` (p=0.02) for off-heap fault timing diversity. Lowered `max_ops_per_tick` to 128 so the active workload spans many ticks instead of bursting. Asserts the safety invariant only (no honest peer wrongly banned, no panic, no leak); liveness is intentionally relaxed because under randomized faults the corrupt peer's socket can die before 4 hash-fails. Closes DoD #4. Detail in `progress-reports/2026-04-25-buggify-smart-ban.md`.
- **Sim-test setup recipe (`docs/sim-test-setup.md`)**: requirements doc for `EventLoop(SimIO)` test hooks: `simulator_mode` config flag (disable listener/tracker/DHT/SQLite), `addTestTorrent` + `addInboundPeer` test-only paths, read-only `getPeerView` / `isPieceComplete` accessors, and an `InMemoryStore` adapter.
- **BUGGIFY (`src/io/sim_io.zig:injectRandomFault`, `Simulator.BuggifyConfig`, Stage 5 #7)**: per-step probability of overwriting a randomly-chosen in-flight heap entry's result with a fault appropriate to its op type (recv → ConnectionResetByPeer, write → NoSpaceLeft, etc.). Heap order is preserved. Optional log sink writes "fault injected: <op>" so failing seeds are diagnosable. 7 simulator tests in `tests/sim_simulator_test.zig` cover init/step/runUntil plus BUGGIFY at probability 0.0, 1.0, and 0.5.
- **`RealIO` (`src/io/real_io.zig`)**: io_uring backend implementing the same interface. Encodes `Completion*` as SQE `user_data`; multishot accept honours `IORING_CQE_F_MORE`; connect deadlines submit a paired `link_timeout`. `dispatchCqe` clears `in_flight` *before* invoking the callback (multishot still preserves the flag) so callbacks can re-arm the same completion in the natural "header → body → next header" pattern.
- **Backend parity test (`tests/io_backend_parity_test.zig`)**: comptime check that both backends expose the required method set + runtime tests running identical bodies against each. Wired into `zig build test` and `zig build test-io-parity`.
- **Stage 2 (event-loop migration) — DONE.** Every async op in the daemon runs through the io_interface backend. The legacy `ring: linux.IoUring` field, the giant CQE dispatch switch, `OpType` / `OpData` / `encodeUserData` / `decodeUserData` are all deleted.
  - **Sub-tasks #8/#9/#10/#11/#12** all committed across `e17cd19` ... `cd8435c`.
  - Peer recv/send, outbound peer socket/connect, multishot accept, signal poll, recheck reads, disk reads/writes (including PieceStore.sync's async fsync), HTTP executor (socket/connect/send/recv with deadline-bounded connect), RPC server (accept/recv/sendmsg with per-op gen-stamped tracking struct), metadata fetch (connect/send/recv per Slot), uTP recvmsg/sendmsg, UDP tracker (socket/sendmsg/recvmsg per Slot), timerfd → native io.timeout — all migrated.
  - `posix.fdatasync` and `timerfd_*` calls no longer appear anywhere in the daemon hot path.
  - Two patterns settled: (a) **single Completion per long-lived slot** for serial state machines; (b) **heap-allocated tracking struct** with embedded Completion for fan-out parallel ops (per-span piece writes/reads, per-PendingSend tracked sends, per-client RPC ops with generation guard).

### Sim test surface (post-Stage-2)
For sim-driven integration tests (smart-ban et al.) per `docs/sim-test-setup.md`:
- **`EventLoop.addInboundPeer(torrent_id, fd, peer_addr) -> u16`** (commit `8a93275`) — drop a paired socketpair fd directly into a peer slot in `.inbound_handshake_recv` state, skipping `accept_multishot`. Pre-attaches to the torrent.
- **`EventLoop.PeerView` + `EventLoop.getPeerView(slot) -> ?PeerView`** (commit `8a93275`) — read-only snapshot exposing `address`, `trust_points`, `hashfails`, `is_banned`, `blocks_received`, `bytes_downloaded`, `bytes_uploaded`. Returns null for unused slots.
- **`EventLoop.isPieceComplete(torrent_id, piece_index) -> bool`** (commit `8a93275`) — read-only proxy to `PieceTracker.isPieceComplete`.
- **Hasher inline mode** (commit `139da15`) — `Hasher.create(allocator, 0)` selects no-thread inline-execution: `submitVerifyEx` computes the SHA synchronously and pushes the result before returning, so the next `peer_policy.processHashResults` sees it deterministically per tick.

See `progress-reports/2026-04-25-stage2-event-loop-migration.md` for the Stage 2 slice-by-slice writeup.

## Next

### Protocol
- ~~**uTP outbound connections**~~: (DONE) outbound uTP connections, retransmission buffer, RTO retransmission.
- ~~**PEX (BEP 11)**~~: (DONE) peer exchange via BEP 10 extensions, delta encoding, private torrent enforcement.
- ~~**DHT (BEP 5)**~~: (DONE) trackerless peer discovery — Phases 1-3 (core protocol, active lookups, announce and persistence).
- ~~**DHT Phase 4 (partial)**~~: (DONE) IPv6 support (BEP 32 dual-stack socket, `nodes6`/`values6` parsing, IPv4-mapped address normalization). Remaining: rate limiting outbound queries, fuzz tests for incoming KRPC messages.
- ~~**Magnet links (BEP 9)**~~: (DONE) metadata download via ut_metadata extension.
- ~~**Magnet link resilience**~~: (DONE) multi-peer retry with per-peer/overall timeouts, DHT peer provider interface stub, metadata fetch progress reporting via Stats/API.
- ~~**MSE encryption (BEP 6)**~~: (DONE) message stream encryption/obfuscation.
- ~~**BEP 52 Phase 4**~~: (DONE) peer wire handshake dual info-hash matching, tracker announce with v2 info-hash, resume DB v2 info-hash column, TorrentSession v2 hash propagation.
- ~~**BEP 52 Phase 5**~~: (DONE) hash request/hashes/hash reject message encode/decode, Merkle proof building from tree, protocol handler integration.
- ~~**BEP 52 Phase 6**~~: (DONE) runtime Merkle tree caching for hash serving. Per-file trees built lazily from disk, LRU eviction, `handleHashRequest` serves real hashes.
- ~~**BEP 52 Phase 7 (DHT v2 announce/lookup, R4)**~~: (DONE) DHT client API extended to accept an optional truncated v2 info-hash; hybrid torrents now announce against and search for both v1 and (truncated) v2 hashes. Pure-v1 callers pass `null` and behave unchanged. Plumbed through `src/main.zig` (magnet path), `src/daemon/torrent_session.zig` (integrate + seed-announce). See `progress-reports/2026-04-29-bep52-dht-and-hashes.md`.
- ~~**BEP 52 Phase 8 (peer-provided leaf hash storage, R5)**~~: (DONE) `LeafHashStore` stores per-piece SHA-256 leaves received via the BEP 52 `hashes` message after their Merkle proof has been verified against the file's `pieces_root`. Lazily attached to `TorrentContext`. `handleHashesResponse` no longer drops verified hashes — they are now persisted and addressable by piece index. Follow-up (separate work): consult the store during piece-completion validation so multi-piece pure-v2 torrents can verify pieces incrementally.

### Operational
- ~~**Flood/qui WebUI validation**~~: (DONE)
- ~~**API placeholder cleanup**~~: (DONE)
- ~~**API keep-alive for polling**~~: (DONE)
- ~~**Shared MSE responder lookup**~~: (DONE)
- ~~**Shared tracker executor / connection reuse**~~: (DONE)
- ~~**Seed plaintext scatter/gather**~~: (DONE)
- ~~**Tracker work on the shared peer ring**~~: (DONE)
- ~~**Magnet initial peer collection**~~: (DONE) `collectMagnetPeers` replaced with `submitMagnetAnnounces` — magnet tracker announces now go through ring-based `TrackerExecutor`/`UdpTrackerExecutor`. Zero blocking I/O on the background thread.
- ~~**uTP BT send bridge**~~: (DONE) uTP data transfer works end-to-end. Fixed seq_nr off-by-one in `acceptSyn` and inbound state machine stall after extension handshake. `demo_swarm.sh` runs with `enable_utp = true`.
- ~~**Wave 5 BEP 52 creation**~~: (DONE) `varuna-tools create --hybrid` produces BEP 52 hybrid v1+v2 torrents with SHA-256 Merkle trees, file tree structure, and pieces root.
- ~~**Generic HttpExecutor**~~: (DONE) extracted from TrackerExecutor (~1011 lines). Supports custom headers (Range), target buffer for zero-copy body writes, HTTPS via BoringSSL. TrackerExecutor is now a thin 92-line wrapper.
- ~~**BEP 19 web seed downloads**~~: (DONE) piece downloads via HTTP Range requests through HttpExecutor. Multi-piece batched requests (configurable `web_seed_max_request_bytes`, default 4MB). WebSeedManager handles URL management, piece-to-file mapping, backoff. E2e verified: 3 scenarios (1-request, multi-request, many-small-requests) all pass.
- ~~**Blocking HttpClient retired**~~: (DONE) no daemon code path imports the blocking `io/http.zig` HttpClient. URL parsing extracted to `io/url.zig`. Only CLI tools and tests use the blocking client.
- ~~**Transport disposition**~~: (DONE) fine-grained TCP/uTP control via `TransportDisposition` packed struct. TOML config accepts presets or flag lists. Runtime start/stop of TCP and UDP listeners via `reconcileListeners()`. Cancel-before-close with IORING_OP_ASYNC_CANCEL. 25 integration tests.
- ~~**IORING_OP_SOCKET for hot-path socket creation**~~: (DONE) peer connections, tracker requests, and UDP tracker all use async socket creation. Startup socket() count: 13 → 3.
- ~~**varuna-tools create**~~: (DONE) native Zig torrent creator with mktorrent feature parity. Parallel hashing (11x speedup at 16 threads). All test scripts use `varuna-tools create` — Node.js dependency eliminated.
- ~~**Smart ban Phase 0**~~: (DONE) trust-point banning on hash failure. `hashfails`/`trust_points` fields on `Peer`, penalization in `processHashResults`, ban at threshold -7, slow recovery on success. Web seed slots excluded. `hashfails` exposed in torrentPeers API.
- ~~**Smart ban Phase 1-2 (per-block SHA-1 attribution + ban-targeting)**~~: (DONE) per-block peer attribution captured in `BlockInfo.delivered_address` at receive time (decoupled from peer-slot lifetime so attribution survives disconnect/IP churn — fixed a real production gap where corrupt-and-disconnect peers escaped attribution). `SmartBan.snapshotAttribution` records on piece complete; `onPieceFailed` stores per-block SHA-1 + peer-address records; `onPiecePassed` (after re-download) compares per-block hashes and bans only the peers whose blocks mismatched. `peer_policy.snapshotAttributionForSmartBan` and `smartBanCorruptPeers` bridge the EL. Phase 2's discriminating power (honest peer co-located on a corrupt piece is NOT banned) demonstrated end-to-end in `tests/sim_smart_ban_phase12_eventloop_test.zig`'s disconnect-rejoin scenario — 8 deterministic seeds, peer 0 banned via Phase 2 attribution-survives-disconnect, peers 1+2 acquitted despite contributing to the same failed piece. See `progress-reports/2026-04-26-phase-2-smart-ban.md` for the arc.
- ~~**Multi-source piece assembly (transient correctness)**~~: (DONE) piece can now be assembled from multiple peers — disconnect-mid-piece releases blocks via `releaseBlocksForPeer` + `tryJoinExistingPiece`; survivors absorb and complete the piece. Picker fair-share + per-call cap (`peer_policy.tryFillPipeline`) provides steady-state correctness.
- ~~**Late-peer block-stealing (Task #23)**~~: (DONE) `tryFillPipeline` issues duplicate REQUESTs for `.requested`-state blocks attributed to other peers once `nextUnrequestedBlock` returns null; `tryJoinExistingPiece` accepts fully-claimed DPs that have stealable blocks, gated by the existing bitfield check `peer_bf.has(dp.piece_index)`. Closes the "3 peers all hold full piece, peer A drains the entire piece in one tick before B+C handshake" race; the BUGGIFY safety invariant (no honest peer accumulates hashfails) holds because the bitfield gate prevents an honest peer from joining a corrupt-only DP. `tests/sim_multi_source_eventloop_test.zig` distribution-proportion assertions now live (`peers_with_uploads >= 2`, `max × 10 ≤ total × 9`).
- **MSE simultaneous handshake robustness**: timing-dependent crash in `checkPeerTimeouts -> removePeer -> cleanupPeer` when both inbound and outbound MSE handshakes are in flight. Disappears under GDB. Needs generation counters or explicit handshake-in-progress guards.
- **Peer hot/cold split / partial SoA**: the active-slot pass removes a lot of wasted scans, but the `Peer` struct is still wide. The next performance step is separating hot scheduling/state fields from cold crypto/buffering state.
- **Torrent hot-summary registry**: cached cumulative byte totals now remove the hottest `/sync` stats scan, but a denser registry is still the next step if queue position, state derivation, or other per-torrent fields dominate at `10k+` torrents.
- **Broader RPC arena coverage**: `/sync/maindata` now uses an arena for transient work; the other list-heavy endpoints still allocate temporary object graphs and strings.
- **uTP outbound queueing**: the UDP path still has room for a ring queue and multiple in-flight sends if uTP becomes hot in real swarms.
- **uTP multishot receive**: `recvmsg_multishot` plus a provided-buffer strategy still needs a workload and a measured implementation before it should land.
- **Dynamic outbound buffer for UtpSocket**: fixed `[128]OutPacket` should become ArrayList for high-throughput uTP connections.
- **c-ares io_uring integration**: proof-of-concept in `~/projects/c-ares` — native io_uring event engine with SENDMSG/RECVMSG for DNS queries (zero direct syscalls). Could replace varuna's DNS threadpool to eliminate background-thread DNS.
- **Live-pipeline BUGGIFY harness for AsyncRecheckOf(SimIO)**: `AsyncRecheck` is now generic over its IO backend (`AsyncRecheckOf(IO)` in `src/io/recheck.zig`; daemon callers stay on the `AsyncRecheckOf(RealIO)` alias). `SimIO.setFileBytes(fd, bytes)` registers caller-owned content so reads return real piece data instead of `usize=0`. The foundation integration tests (`tests/recheck_test.zig` — happy path, corrupt-piece detection, fast-path skip) drive `AsyncRecheckOf(SimIO)` through `EventLoopOf(SimIO)` end-to-end. The next deliverable is the canonical BUGGIFY wrapper around them — per-tick `injectRandomFault` + per-op `FaultConfig` × 32 seeds — to catch live-wiring recovery paths the algorithm-level harness can't see (AsyncRecheck slot cleanup under read-error injection, hasher submission failures, partial completion races). Estimated 0.5-1 day now that the refactor + setFileBytes are in place.
- ~~**`krpc.skipValue` recursive bencode parsing → explicit stack**~~: (DONE 2026-04-27) rewritten as a fixed-size container stack with `skip_max_depth = 64` cap; structurally cannot blow the native call stack regardless of input size. Mirrors `bencode_scanner.skipValue` shape. See `progress-reports/2026-04-27-quick-wins.md`.
- ~~**`web_seed.MultiPieceRange.length` u32 truncation**~~: (DONE 2026-04-27) `computeMultiPieceRanges` now rejects with `error.RunTooLarge` when the byte span would overflow u32, instead of panicking on the inner `@intCast`. Investigation showed `MultiPieceRange.length` is never read by the production handler and the rest of the pipeline is u32-byte-bounded throughout, so the entry-validation form is the cleanest fix. Regression test added in `tests/web_seed_buggify_test.zig`.
- ~~**`bencode_scanner.skipValue` explicit-stack rewrite**~~: (DONE 2026-04-27) replaced the recursion-with-depth-counter form with the same explicit container stack used by `krpc.skipValue`. Same `max_depth = 64` cap, same observable behaviour, but no recursion. Hand-rolled because Zig 0.15.2 does not expose `std.BoundedArray`.
- ~~**BT PIECE block_index regression test**~~: (DONE 2026-04-27) inline tests in `src/io/protocol.zig` covering `block_offset = 1 GiB` (the exact pre-fix panic value) and `block_offset = maxInt(u32)` (the absolute upper bound of the wire field). Now visible because round-1 dark-test audit landed `src/io/root.zig`'s `test {}` block.
- ~~**Happy-path `AsyncMetadataFetchOf(SimIO)` integration test.**~~ Closed 2026-04-29. `connectPeer` now submits via `self.io.socket()` instead of the synchronous `posix.socket()` (new `SlotState.socket_creating` + `metadataSocketComplete` callback), and `releaseSlot` routes through `self.io.closeSocket()`. Two SimIO additions wire the test: `enqueueSocketResult(fd)` (next `socket()` returns this specific fd) and `pushSocketRecvBytes(fd, bytes)` (the scripted-peer mirror of `setFileBytes`, including the parked-recv wake-up path). Happy-path test (`tests/metadata_fetch_test.zig`): one peer, scripted BT handshake reply + extension handshake (with `metadata_size` and a non-zero `ut_metadata` ID) + ut_metadata data response carrying a 256-byte info dictionary. Assertions: `completed`, `had_metadata`, `result_len == 256`, first/last byte match. `socket_util.configurePeerSocket` is now gated behind a comptime `IO != SimIO` check because `posix.setsockopt` panics on BADF (unreachable, not a returned error) for synthetic SimIO fds. See `progress-reports/2026-04-29-executor-genericization.md`.
- ~~**Live-pipeline BUGGIFY harness for AsyncMetadataFetchOf(SimIO).**~~ Closed 2026-04-29. `tests/metadata_fetch_live_buggify_test.zig` runs the canonical 32-seed BUGGIFY pattern (per-tick `injectRandomFault` p=0.05, per-op `FaultConfig` recv/send 0.05 each) against 5 scripted peers (more than `max_slots = 3` so retry refill is exercised). Asserts safety invariants only — every seed completes, `result_bytes` is either null or matches the original info dict exactly, `peers_attempted` is bounded; anti-vacuous-pass guard requires `seeds_with_metadata > 0`. Current run: 32/32 complete, 32/32 deliver metadata, 124 total peers attempted (28 fault-induced retries). Wired through new `zig build test-metadata-fetch-live-buggify` step. See `progress-reports/2026-04-29-executor-genericization.md`.
- ~~**uTP extension chain not consumed in production.**~~ (DONE 2026-04-28) `src/net/utp_manager.zig` now walks the BEP 29 extension chain via `stripExtensions` and hands the trailing bytes to the BT framing layer. Truncated chains and over-cap SACK lengths (> `sack_bitmask_max`) are rejected with `null` — manager drops the malformed datagram cleanly. 9 inline regression tests (single SACK, multi-hop, truncated, missing per-extension header, oversized SACK, non-terminating chain, plus full-pipeline tests). See `progress-reports/2026-04-28-utp-fixes-and-net-wiring.md`.
- ~~**uTP reorder buffer indexing mismatch + dangling-slice UAF.**~~ (DONE 2026-04-28) Both `bufferReorder` and `deliverReordered` now index by absolute `seq_nr % max_reorder_buf`, so out-of-order packets are reachable. `ReorderEntry.data` is `?[]u8` (owned heap copy) instead of a borrowed slice into the shared `utp_recv_buf` — fixes the latent UAF. Slot eviction frees the prior occupant; `UtpSocket.delivered_payloads` keeps slices alive across the result-handling window then frees on the next `processPacket`/`deinit`. 8 inline regression tests including the exact UAF scenario. Production wiring: `PacketResult` now carries `reorder_data`/`reorder_delivered` and `src/io/utp_handler.zig` drains the buffered payloads into `deliverUtpData`. See `progress-reports/2026-04-28-utp-fixes-and-net-wiring.md`.
- ~~**`writePiece` / `readPiece` migration to the IO contract.**~~ Closed 2026-04-28. PieceStore's per-piece write and read paths now route through `self.io.write` / `self.io.read` with caller-owned per-span completions and a multi-completion drain loop (mirrors `sync`'s shape). Removes the last synchronous `posix.pwrite` / `posix.pread` in storage. See `progress-reports/2026-04-28-storage-rw-io-contract.md`.
- ~~**`truncate` op on the IO contract.**~~ Closed 2026-04-28. New `TruncateOp` + `Result.truncate` variant on `io_interface.zig`. RealIO implementation is synchronous (`posix.ftruncate`) because `IORING_OP_FTRUNCATE` requires kernel 6.9, above varuna's floor (6.6 minimum / 6.8 preferred); the call site is `PieceStore.init`'s filesystem-portability fallback, which already runs on a background thread, so synchronous syscall has zero event-loop impact. SimIO implementation plus `truncate_error_probability` + `fallocate_unsupported_probability` fault knobs. Both `setEndPos` call sites in `src/storage/writer.zig` (`preallocateAll` and `preallocateOne`) now route through `self.io.truncate`. See `progress-reports/2026-04-28-truncate-op.md`.
- ~~**Switch RealIO.truncate to `IORING_OP_FTRUNCATE` once kernel floor bumps to 6.9+.**~~ Closed 2026-04-29. Resolved as a runtime decision instead of a kernel-floor bump: `RealIO.init` now caches a `feature_support: FeatureSupport` field populated by `probeFeatures(&ring)` (issues `IORING_REGISTER_PROBE` once at init), and `RealIO.truncate` branches — async `IORING_OP_FTRUNCATE` SQE when supported (kernel ≥6.9 or any kernel with the op backported), synchronous `posix.ftruncate(2)` otherwise. Varuna's overall floor stays at 6.6 minimum / 6.8 preferred. The `FeatureSupport` struct is the seed for cleaning up the broader floor-blocked op set (filed below). See `progress-reports/2026-04-29-runtime-feature-probe.md`.
- **Generalize `FeatureSupport` to cover other kernel-floor-blocked ops.** AGENTS.md tracks `IORING_OP_SETSOCKOPT` (6.7+) and `IORING_OP_BIND`/`LISTEN` (6.11+) as currently-synchronous ops gated on the overall kernel floor. Now that `src/io/ring.zig`'s `FeatureSupport` exists, those can drop their ad-hoc kernel-version arithmetic in favor of per-op probe flags (add `supports_setsockopt`, `supports_bind`, `supports_listen` to `FeatureSupport`, branch in the relevant submission methods, keep the synchronous fallback alongside). Same shape as the truncate landing. Estimated 0.5-1 day per op group once the day-one daemon paths are pinned down.
- **Live-pipeline BUGGIFY harness for `PieceStoreOf(SimIO)`.** Wrap the integration tests in `tests/storage_writer_test.zig` with the canonical BUGGIFY shape — per-tick `injectRandomFault` + per-op `FaultConfig` × 32 seeds. Catches recovery paths the foundation tests can't see (errdefer cleanup of partially-opened files when the 2nd of 5 fallocates fails; sync's pending-counter under fsync error storms; per-span resubmit racing with cancellation under read/write fault injection). Reference shape: `tests/recheck_live_buggify_test.zig`. Estimated 0.5-1 day. Now also covers writePiece/readPiece short-write/short-read loops.
- **SimHasher — make the hasher pool deterministic.** Today `src/io/hasher.zig` spawns real OS threads via `std.Thread.spawn`; this is one of two remaining nondeterminism boundaries after the SimClock + SimRandom landings. Workers must consume scheduled tasks from the simulator's clock in test builds, eliminating the thread-spawn boundary entirely. The "accept real threads, EL stays deterministic" alternative is rejected — leaving real threads in the picture means hashing-related races and re-orderings remain non-reproducible, defeating the point of single-daemon-deterministic simulation. Tagged-union shape (mirror Clock/Random) probably wins given the existing precedent and smaller call-site footprint. Estimated 2-3 days. See `docs/simulation-roadmap.md` Phase 2 #3.
- **Migrate `std.crypto.random` callers to a daemon-seeded CSPRNG.** The 2026-04-29 SimRandom round documented 5 callers (MSE keys, peer ID, DHT node ID, DHT tokens, RPC SID) as a "crypto-determinism boundary" deliberately left on `std.crypto.random` for production unpredictability — but that means sim tests touching those paths can't be byte-deterministic, defeating single-daemon full-determinism. Resolved direction: at daemon startup, seed a CSPRNG (e.g. `std.Random.ChaCha`) once from a real cryptographic source (`std.crypto.random.bytes(&seed)`), then route ALL random reads through that seeded CSPRNG. Production keeps cryptographic strength because a 256-bit seed from a real source plus a modern CSPRNG is computationally indistinguishable from a true random source for the lifetime of a single daemon process — standard "seed once, generate many" pattern. Sim builds inject a deterministic seed via the same surface; same CSPRNG implementation, same code paths, just a known seed. This closes the crypto-determinism boundary entirely. Implementation likely requires plumbing a `*Random` reference through to the 5 sensitive callers (injection rather than module global, so tests can vary the seed per test case). Estimated 3-4 days. The existing `runtime.Random` (currently `RealRandom = wraps std.crypto.random` vs `SimRandom = DefaultPrng`) gets retrofitted: both variants use the same ChaCha-based CSPRNG; only the seed source differs.

### Testing
- ~~**External-review test gaps T2/T3/T4.**~~ Closed 2026-04-30. (T2) Private-torrent → DHT gating proven. The privacy gate now lives in three `TorrentSession` helpers (`dhtRegisterPeers` / `dhtForceRequery` / `dhtAnnouncePeer`) — all three former call sites in `src/main.zig` and `src/daemon/torrent_session.zig` now route through them so the gate is enforced in one place. New `tests/private_torrent_dht_test.zig` verifies private/public symmetry across all three operations including hybrid v2 truncation. (T3) `tests/rpc_server_stress_test.zig` extended with 6 routing tests that wire a real `ApiHandler` onto a real `ApiServer`, fire HTTP requests through real posix sockets, and assert end-to-end auth → routing → handler → response (login round-trip, auth-required 403, app/version, app/buildInfo, app/defaultSavePath, torrents/info, torrents/categories + createCategory, unknown-path 404 from the handler). (T4) Happy-path coverage added in 4 endpoint-family files: `tests/api_categories_test.zig`, `tests/api_share_limits_test.zig`, `tests/api_tracker_edits_test.zig`, `tests/api_sync_export_test.zig`. 40 new tests total. See `progress-reports/2026-04-30-api-tests-t2-t3-t4.md`.
- ~~**Dark inline test audit, round 2: net / tracker / rpc.**~~ Closed 2026-04-27. `src/net/root.zig` (14 files wired; bencode_scanner / web_seed deferred to quick-wins-engineer), `src/tracker/root.zig` (3 files), `src/rpc/root.zig` (8 files) all wired. Surfaced two production bugs and one bit-rotted test. See `progress-reports/2026-04-27-dark-test-audit-r2r3.md`.
- ~~**Dark inline test audit, round 3: runtime / sim / daemon.**~~ Closed 2026-04-27. `src/runtime/root.zig` (3 files), `src/sim/root.zig` (1 file), `src/daemon/root.zig` (5 files) wired through `mod_tests` (`src/root.zig`'s `_ = daemon;` reaches `daemon/root.zig` directly — round 1's note about needing a separate `daemon_exe.root_module` opt-in turned out to be unnecessary in practice). Surfaced one production safety fix (`isListenSocketOnPort` panic on negative fd). See `progress-reports/2026-04-27-dark-test-audit-r2r3.md`.
- ~~**Wider `{any}` formatter audit.**~~ Closed 2026-04-27. 23 sites audited; one production bug surfaced (`session_manager.formatPeerIp` was emitting ~640-byte struct dumps as the qBittorrent peer-list JSON `ip` field), 10 log-verbosity sites (uTP, event_loop, dht, peer_policy) shrunk from 700-byte multi-line dumps to plain `IP:port`, 12 test-diagnostic sites kept (benign — `{any}` on `anyerror` prints the error name). Regression test asserts `{f}` form for IPv4 and IPv6, and explicitly that the output contains no struct-dump tokens. See `progress-reports/2026-04-27-any-formatter-audit.md`.
- ~~**Wire `src/net/bencode_scanner.zig` + `src/net/web_seed.zig`.**~~ (DONE 2026-04-28) Both files added to `src/net/root.zig`'s `test {}` block; ~25 inline tests now reachable through `mod_tests`. Verification per the standard protocol: intentional `try testing.expect(false)` break in one test in each file caught by the runner with the correct test name; reverted. See `progress-reports/2026-04-28-utp-fixes-and-net-wiring.md`.

## Known Issues

- **`bind_device` is silently bypassed by the threadpool DNS backend (the build default).** `network.bind_device = "wg0"` is correctly applied to peer connections (TCP listen + connect), uTP / DHT UDP listener, RPC server accept, HTTP tracker client, and UDP tracker client — but DNS queries via the default `-Ddns=threadpool` backend leak out the default route. `getaddrinfo` owns its own UDP socket internally and offers no hook for the application to apply `SO_BINDTODEVICE`. Workaround: build with `-Ddns=c_ares`, which registers an `ares_set_socket_callback` on the c-ares channel that calls `applyBindDevice` for every UDP/TCP socket the channel opens — closes the gap fully on that backend. The plumbing is now an explicit `bind_device` field on `dns.Config`, threaded from `cfg.network.bind_device` through `SessionManager.bind_device` → `HttpExecutor.Config.bind_device` / `UdpTrackerExecutor.Config.bind_device` → `DnsResolver.init`. Full fix queued behind the custom-DNS-library work in `docs/custom-dns-design-round2.md` §1; the custom resolver controls its own sockets and applies `SO_BINDTODEVICE` natively. (2026-04-28)
- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- On WSL2, `perf stat`/`perf record` require kernel-matched `linux-tools` package; many hardware counters report `<not supported>`.
- `zig build test-torrent-session` intermittently hits Zig cache/toolchain failures (`manifest_create Unexpected`).
- ~~**Smart ban Phases 1-2 not yet implemented**~~: closed 2026-04-26. Phase 1 (per-block SHA-1 attribution on hash failure) and Phase 2 (ban-targeting on re-download pass) live in `src/net/smart_ban.zig` and `src/io/peer_policy.zig`; attribution survives peer-slot freeing via `BlockInfo.delivered_address`. End-to-end validation in `tests/sim_smart_ban_phase12_eventloop_test.zig`.
- **MSE handshake failures in mixed encryption mode**: `vc_not_found` and `req1_not_found` errors occur during simultaneous inbound+outbound MSE handshakes. Timing-dependent, disappears under GDB. `demo_swarm.sh` runs with `encryption = "disabled"` as workaround.
- ~~**Daemon graceful shutdown**~~: Fixed. In-flight transfer draining with configurable timeout now ensures clean exit on SIGTERM/SIGINT.
- `IORING_OP_SETSOCKOPT` (kernel 6.7+), `IORING_OP_BIND`/`LISTEN` (kernel 6.11+) not available on current kernel 6.6. Per-peer setsockopt (TCP_NODELAY, buffer sizes) remains synchronous.

## Last Verified Milestone (2026-04-29 — runtime Clock + Random abstractions for sim-time determinism)

Lifts wall-clock and crypto-random reads out of the daemon hot path so
single-daemon-deterministic simulation (`SimulatorOf(EventLoopOf(SimIO))`)
can drive everything that previously hit `std.time.*` or
`std.crypto.random` directly. Closes a long-standing simulation
nondeterminism boundary called out in the simulation roadmap.

**Design choice**

Tagged-union dispatch (Option A from the team-lead's two-option brief)
for both `runtime.Clock` and `runtime.Random`. Sized the choice
empirically: ~50 production callers reach for `std.time.timestamp`,
~25 reach for `std.crypto.random`. A comptime cascade
(`ClockOf(comptime Impl: type)`, mirroring the existing IO contract)
would force every consumer's generic graph to widen for what's
ultimately a single switch on a 24-byte union — the IO contract
deserves comptime because IO type is fundamental to the call surface;
Clock and Random just return values with nothing to monomorphise over.
A single `union(enum) { real: void, sim: T }` tagged dispatch is one
branch-predicted switch per call.

**`runtime.Clock` (`src/runtime/clock.zig`)**

Three resolutions backed by a single u64-ns sim variant:

- `now()`   → i64 seconds (matches `std.time.timestamp()`)
- `nowMs()` → i64 milliseconds (matches `std.time.milliTimestamp()`)
- `nowNs()` → u64 nanoseconds (narrower than
  `std.time.nanoTimestamp()`'s `i128` on purpose — see below)

Constructors `Clock.simAtSecs`/`simAtMs`/`simAtNs` plus
`advance{Secs,Ms,Ns}` / `set{Secs,Ms,Ns}`. The existing shim at
`src/io/clock.zig` re-exports the type so `EventLoop.clock`,
peer/protocol/web-seed/uTP handlers continue to compile unchanged.

**ns width: u64, not i128.** The whole simulation timeline
(`SimIO.now_ns: u64`, `Simulator.clock_ns: u64`,
`PendingEntry.deadline_ns: u64`) was already u64; matching that
invariant cuts a cache line off the TokenBucket struct, lets future
callers fit ns timestamps in `std.atomic.Value(u64)`, and avoids a
128-bit conversion at every `EventLoop → SimIO` boundary. u64 ns
since Unix epoch wraps in **year ~2554** (`2^64 ns ≈ 584.5 years`) —
enormously more headroom than a daemon needs. A
`@sizeOf(Clock) <= 16` regression test guards the invariant.

**`runtime.Random` (`src/runtime/random.zig`)**

`.real` wraps `std.crypto.random` (production CSPRNG). `.sim` wraps a
seeded `std.Random.DefaultPrng`. `bytes`/`int`/`uintLessThan` cover
the call shapes the daemon actually uses.

**Migrations landed**

- `src/io/rate_limiter.zig` — `TokenBucket` no longer reads
  `std.time.nanoTimestamp()` internally. `consume`/`available`/
  `delayNs`/`refill`/`setRate` renamed to `*At` variants and take an
  absolute `now_ns: u64` parameter. EventLoop snapshots
  `self.clock.nowNs()` once per consume/throttle path. The
  `last_refill_ns == 0` magic-value sentinel was replaced with
  `last_refill_ns: ?u64` so a sim test anchored at `t = 0` no longer
  re-seeds on every refill. Inline tests rewritten on deterministic
  timestamps; new tests assert refill credits 250 ms / 1 s
  deterministically, clock-going-backward is a no-op, and the t=0
  anchor doesn't credit a half-millennium of tokens.

- `src/io/peer_policy.zig` — 13 in-source test sites swap
  `std.time.timestamp()` → `el.clock.now()` so peer-policy unit tests
  inherit sim-clock semantics for free. Production peer_policy paths
  already used `self.clock.now()`.

- `src/io/event_loop.zig` — gains `random: Random = .real` next to
  `clock: Clock = .real`, establishing the convention for follow-up
  callers.

- `src/tracker/types.zig:Request.generateKey(rng: *Random)` — first
  Random migration, demonstrating the pattern. Caller in
  `src/daemon/torrent_session.zig` and tests in
  `tests/private_tracker_test.zig` updated.

**Documented exemptions**

`src/io/dns_cares.zig` (synchronous c-ares resolve runs against real
`epoll_wait` on a worker thread; deadline computation must match real
wall time without parallel virtualisation of c-ares' IO).
`src/io/kqueue_posix_io.zig` and `src/io/kqueue_mmap_io.zig`
(`monotonicNs()` IS the kqueue backend's own time source — routing
through `Clock` would be circular). Each gets an inline comment so
future work doesn't try to "fix" them.

**Cryptographic randomness preserved** in MSE handshake DH keys / pad
lengths (`src/crypto/mse.zig`), peer ID suffix
(`src/torrent/peer_id.zig`), DHT node ID (`src/dht/node_id.zig`), DHT
announce_peer tokens (`src/dht/token.zig`), RPC session SID
(`src/rpc/auth.zig`). The `runtime.Random` module-level docstring
spells out the safe-vs-must-stay-on-CSPRNG list as institutional
memory.

**Crypto-determinism boundary, explicitly accepted (option 1+4
hybrid).** Code paths that consume the five preserved-CSPRNG sites
above are non-deterministic across sim runs by design — predictability
in production would break the protocols' security properties. Sim
tests that need byte-determinism configure around the crypto sites
(`encryption_mode = .disabled`, hardcoded peer IDs); sim tests that
exercise crypto paths use behavioural assertions ("handshake
completed", "did not panic") rather than byte-equality. This matches
what varuna's existing sim tests already do without anyone documenting
it. Test classes affected: `src/crypto/mse.zig` inline tests (~32
tests, behavioural), `tests/dht_krpc_buggify_test.zig` (calls
`node_id.generateRandom()` once, fuzz iteration uses its own seeded
PRNG), and the four `tests/sim_*_eventloop_test.zig` files (dodge the
boundary entirely). Build-flag-gated comptime redirection (TigerBeetle
pattern) reserved as an escape hatch in case a future bug reproduces
only under specific crypto bytes; rejected for routine use because the
five sites are isolated enough that the test discipline scales without
shipping a sim-build with weakened crypto. See
`src/runtime/random.zig` module docstring for the full policy.

**Determinism win demonstrated**

`tests/clock_random_determinism_test.zig` drives a
TokenBucket consume sequence across 1.35 s of sim time and a
`Request.generateKey` sequence across 5 seeds, asserting byte-for-byte
identical output across runs. Includes a combined-sources test that
runs a rate-limit + key-gen pipeline twice with the same seed and
expects identical output, then again with a different seed and
expects identical bucket math but divergent keys.

**Follow-ups**

- UDP tracker transaction IDs (`src/tracker/udp.zig:generateTransactionId`)
  and uTP connection IDs (`src/net/utp.zig:UtpSocket.connect`) are safe
  to migrate but their callers (`UdpTrackerExecutor`, `UtpSocket`) need
  a `*Random` field plumbed in from EventLoop. Tracked separately.
- `src/io/dns_cares.zig` milliTimestamp routing through Clock requires
  also virtualising c-ares' epoll layer — a larger DNS-sim project.
- `src/perf/workloads.zig:1418` nanoTimestamp left as-is (tmpfile
  uniqifier; not a time-domain operation).

**Files**

- `src/runtime/clock.zig` (new)
- `src/runtime/random.zig` (new)
- `src/io/clock.zig` (now a re-export shim)
- `src/io/event_loop.zig`, `src/io/rate_limiter.zig`,
  `src/io/peer_policy.zig`
- `src/tracker/types.zig`, `src/tracker/announce.zig`,
  `src/daemon/torrent_session.zig`
- `src/io/dns_cares.zig`, `src/io/kqueue_posix_io.zig`,
  `src/io/kqueue_mmap_io.zig` (exemption comments)
- `src/runtime/root.zig` (module exports)
- `tests/clock_random_determinism_test.zig` (new),
  `tests/private_tracker_test.zig`,
  `tests/sim_smart_ban_eventloop_test.zig`,
  `tests/sim_smart_ban_phase12_eventloop_test.zig`,
  `tests/sim_multi_source_eventloop_test.zig`,
  `tests/sim_swarm_test.zig` (sim-clock constructor migration)
- `progress-reports/2026-04-29-clock-random.md`
## Last Verified Milestone (2026-04-29 — Custom DNS library (Phases A–E foundation, F deferred))

Lays the groundwork for replacing c-ares + the threadpool backend
with a contract-native DNS resolver under `src/io/dns_custom/`. Per
the Round-1+2 design docs (`docs/custom-dns-design.md`,
`docs/custom-dns-design-round2.md`), Option A — build a custom
contract-native DNS library — is the path forward. This milestone
lands the foundation: parser, cache, resolv.conf, query state
machine, top-level resolver. The `-Ddns=custom` build dispatch
(Phase F) is deferred to a follow-up; the existing `threadpool`
(default) and `c_ares` backends are untouched.

**Files added (~1 500 LOC + tests)**

- `src/io/dns_custom/message.zig` — DNS wire format encode/decode
  (RFC 1035, RFC 3596). 35 tests. Hardening patterns ported
  directly from the round-1-through-round-4 KRPC / bencode
  audits: saturating-subtraction length-prefix bounds,
  compression-pointer strict-decrease invariant + hop cap, label
  cap (63), wire-name cap (255), rdlength bound, mismatched-
  question rejection, A=4 / AAAA=16 rdlength check, adversarial
  fuzz no-panic.
- `src/io/dns_custom/cache.zig` — bounded TTL cache with positive
  + negative entries, per-record TTL clamping, sweep helper.
  12 tests.
- `src/io/dns_custom/resolv_conf.zig` — `/etc/resolv.conf`
  parser. 14 tests. IPv4/IPv6, zone-id stripping, comments, CRLF,
  glibc-style invalid-IP skip-and-continue.
- `src/io/dns_custom/query.zig` — `QueryOf(IO)` per-lookup state
  machine generic over the IO contract. socket → optional
  applyBindDevice → connect → send → recv with per-server +
  total timeouts, multi-server fallback, txid match, NXDOMAIN
  delivery, CNAME chain target surfaced.
- `src/io/dns_custom/resolver.zig` — `DnsResolverOf(IO)`
  composing cache + servers + Query. Public surface mirrors the
  existing `dns.zig` backends (cacheLookup / cacheAuthoritative
  / cacheNxdomain / invalidate / clearAll). `bind_device` plumbed
  through Config (Phase E).

**What this fixes / unlocks**

- The latent `bind_device` DNS leak (the existing threadpool
  backend silently bypasses `network.bind_device = "wg0"` because
  glibc's `getaddrinfo` owns its own UDP socket — see Known
  Issues). Phase E in the new resolver applies `SO_BINDTODEVICE`
  to every DNS UDP socket natively.
- Per-record TTL respect (the threadpool backend uses `cap_s`
  as a fixed lifetime because `getaddrinfo` doesn't expose TTL).
- Negative caching for NXDOMAIN / SERVFAIL, capped at the floor.
- Eventual elimination of the `vendor/c-ares/` 45 KLoC C
  dependency once Phase F lands.
- `SimIO.injectRandomFault` BUGGIFY testability for the resolver
  (Phase E follow-up; the resolver is generic over IO so the
  same fault-injection harness that drives KRPC, AsyncRecheck,
  and metadata-fetch will apply).

**Phases completed**: A (parser + tests), B (UDP transport state
machine, compile-checked), C (cache + TTL respect), D
(resolv.conf), E (bind_device hook).

**Phase F deferred**: the `-Ddns=custom` build flag dispatch and
the SimIO end-to-end smoke test are queued. Per the design doc
this is a 1-day mechanical follow-up; deferred to a separate
session to keep this milestone scoped to the foundation.

**Test count delta**: +73 tests (1 604 → 1 677).

See `progress-reports/2026-04-29-custom-dns-library.md` for the
arc.

## Last Verified Milestone (2026-04-29 — DHT correctness: KRPC sender_id required + IPv6 outbound + announce_peer storage)

Closes three external-reviewer issues against the DHT subsystem (R1, R2,
R3 in the parallel-engineer triage). All three were real correctness /
spec-compliance gaps, not just feature stubs.

**R1 — KRPC sender_id**

`parseQuery` and `parseResponse` initialised `sender_id = undefined`
and only assigned it when the `id` key was present in the bencoded
body. Per BEP 5 every KRPC query and response MUST carry the sender's
20-byte node id; an absent id field is malformed. Today's parser
silently propagated the `undefined` into `RoutingTable.addNode` /
`markResponded` — undefined behaviour, real security/correctness bug.

- `src/dht/krpc.zig` — both parsers now track an `id_seen` flag and
  reject the message with `error.InvalidKrpc` when the key is absent.
  The single caller (`handleIncoming`) already catches and logs at
  debug; malformed-but-not-actionable inputs are common in DHT swarms
  and dropping them is correct.

**R2 — IPv6 outbound (BEP 32 dual-stack)**

`respondFindNode` and `respondGetPeers` previously dropped every IPv6
node from the closest set with `if (family != AF.INET) continue;`,
even though the parser already accepted inbound `nodes6`. Per BEP 32 a
dual-stack DHT must echo IPv6 nodes in `nodes6` (38 bytes per entry:
20-byte id + 16-byte v6 addr + 2-byte port) alongside `nodes` (26
bytes per IPv4 entry).

- `src/dht/krpc.zig` — extend the private `encodeResponse` to take
  optional `nodes6` and `values6` parameters, emitted in lexicographic
  dict order (id < nodes < nodes6 < token < values < values6) and
  skipped when empty. Add `encodeFindNodeResponseDual` and a more
  general `encodeGetPeersResponseFull` public helper. Existing
  `encodeFindNodeResponse` / `encodeGetPeersResponseValues` /
  `encodeGetPeersResponseNodes` keep their previous signatures for
  back-compat.
- `src/dht/dht.zig` — `respondFindNode` / `respondGetPeers` now split
  closest-node packing by address family and pass both buffers to the
  new dual-stack encoder. Send buffer raised from 1024 to 1500 (UDP
  MTU) so a full v4+v6 set fits.

**R3 — peer storage for announce_peer (BEP 5 §"Peers")**

`respondAnnouncePeer` validated the token, queued a ping reply, and
discarded the announce. `get_peers` therefore always fell through to
closest-nodes only — varuna would tell peers "yes, I'll remember you
announced" and never serve them back, lying to the swarm.

- New `PeerStore` private struct in `src/dht/dht.zig`:
  - `std.AutoHashMap([20]u8, ArrayListUnmanaged(Entry))`.
  - 30-min TTL per BEP 5; 100 peers/hash cap; FIFO eviction at cap.
  - `announce`, `encodeValues`, `sweep`, `peerCount`/`hashCount`
    (the last two for tests).
- `respondAnnouncePeer` — after token validation, honour BEP 5's
  `implied_port` flag (use sender's UDP source port when set, else
  the announced port), then `peer_store.announce(info_hash, peer_addr)`.
- `respondGetPeers` — lazy-sweep + look up peers, emit them in
  `values` (v4) / `values6` (v6), still always include the closest
  `nodes` / `nodes6` fallback so well-behaved clients can keep
  iterating.
- `tick` — also calls `peer_store.sweep` so memory stays bounded
  even when no `get_peers` query triggers the lazy path.

**Tests**

- `tests/dht_krpc_buggify_test.zig` — 4 R1 tests (query without id
  rejected, response without id rejected, deterministic round-trip
  for both), 2 R2 tests (find_node and get_peers responses both emit
  nodes + nodes6 with correct wire-format byte counts), 6 R3 tests
  (full announce → store → get_peers round-trip including wire-level
  values decoding, invalid token does not store, implied_port=1 uses
  source port, sweep removes expired entries, FIFO eviction at cap,
  re-announce refreshes expiry without duplicating).

**Verification**

- `nix develop --command zig fmt .` clean.
- `nix develop --command zig build` green.
- `nix develop --command zig build test` exit 0. New tests:
  +12 (4 R1 + 2 R2 + 6 R3) over the prior baseline.

**Predictable conflict zones with parallel `bep52-dht-engineer`**

- `src/dht/dht.zig` — both engineers edited this file. Our changes
  are confined to the response handlers (`respondFindNode`,
  `respondGetPeers`, `respondAnnouncePeer`) plus a new private
  `PeerStore` struct and engine field. R4's changes are in the
  client-side methods (`requestPeers`, `forceRequery`, `announcePeer`).
  Different functions; expect trivial line-position conflicts only.
- `src/dht/krpc.zig` — encoder helpers added (`encodeFindNodeResponseDual`,
  `encodeGetPeersResponseFull`) and the private `encodeResponse`
  signature changed from 6 args to 8. R4 work shouldn't touch this
  surface, so conflicts unlikely.
- `tests/dht_krpc_buggify_test.zig` — new tests appended at the end of
  the file. R4 may add tests in a different file (`tests/dht_*_test.zig`).
- `STATUS.md` — both engineers will add a milestone entry. Standard
  pattern; R4's entry will appear above ours when they merge.

See `progress-reports/2026-04-29-dht-correctness.md` for the full arc.

## Last Verified Milestone (2026-04-28 — DNS bind_device cleanup: module-global → explicit Config plumbing)

Closes the "module-level global is a wart" follow-up filed by the
2026-04-28 correctness-fixes round (commit `955ce61`). That round
shipped the c-ares `bind_device` fix as `dns.setDefaultBindDevice` /
`dns.defaultBindDevice` — a process-wide write-once global the
engineer themselves described as "gross-but-contained" and queued for
revisit. The merge-conflict constraint that drove that workaround
(parallel work in `HttpExecutor` / `UdpTrackerExecutor` /
`SessionManager`) is now gone, so this milestone does the clean
refactor.

**What landed**

- `src/io/dns.zig` — new `pub const Config = struct { bind_device:
  ?[]const u8 = null, ttl_bounds: TtlBounds = TtlBounds.default }`.
  Replaces `setDefaultBindDevice` / `defaultBindDevice` /
  `module_default_bind_device`. `DnsResolver.init` now takes
  `(allocator, Config)` on both backends.
- `src/io/dns_cares.zig` — c-ares socket-callback wiring sources
  `bind_device` from `Config.bind_device` instead of the global.
  Heap-allocated `BindDeviceCell` (lifetime tied to the resolver) is
  registered as `user_data` on the callback so the callback
  dereferences a stable pointer, not a global. Existing socket
  callback semantics preserved (apply errors logged + return 0).
- `src/io/dns_threadpool.zig` — threadpool backend stores
  `Config.bind_device` for API parity (the existing "Known
  limitation" docstring is preserved verbatim — `getaddrinfo` still
  can't honour it, custom-DNS-library is the queued fix).
- `src/io/http_executor.zig`, `src/io/http_blocking.zig` — `HttpExecutor.Config`
  gains `bind_device: ?[]const u8 = null`, forwarded into
  `DnsResolver.init`. (`http_blocking.zig` only owns parse/blocking
  helpers used by varuna-ctl/varuna-tools per AGENTS.md, no daemon I/O.)
- `src/daemon/tracker_executor.zig` — `TrackerExecutor.Config.bind_device`
  forwards into `HttpExecutor.Config.bind_device`.
- `src/daemon/udp_tracker_executor.zig` — `UdpTrackerExecutor.Config.bind_device`
  forwards into `DnsResolver.init`.
- `src/daemon/session_manager.zig` — new `SessionManager.bind_device`
  field. Both `ensureTrackerExecutor` and `ensureUdpTrackerExecutor`
  pass it through.
- `src/main.zig` — sets `sm.bind_device = cfg.network.bind_device`
  (the daemon-lifetime config-arena slice). The
  `varuna.io.dns.setDefaultBindDevice(...)` call is gone; the
  module-level `module_default_bind_device` global is gone.
- Tests — new c-ares coverage exercises the Config path: `Config.bind_device`
  captured to `resolver.bind_device` and `resolver.bind_device_cell`,
  default config leaves both null, the socket-callback applies
  bind_device to a real fd (tolerating
  `BindDevicePermissionDenied` / `BindDeviceNotFound`), and the
  callback is a no-op when invoked with null user_data. Two
  cross-backend tests in `dns.zig` exercise the field through
  whichever backend is active.

**Verification**

- `grep -rn 'defaultBindDevice\|setDefaultBindDevice\|module_default_bind_device' src/`
  returns zero hits.
- `nix develop --command zig build` (default `-Dio=io_uring -Ddns=threadpool`) green.
- `nix develop --command zig build test` exit 0; test count 1525 → 1531
  (+6 new c-ares + cross-backend tests).
- `-Ddns=c_ares` build still hits the pre-existing `ares_build.h not
  found` issue documented in `progress-reports/2026-04-28-correctness-fixes.md`,
  unrelated to this milestone.

**What was deliberately not changed**

- The threadpool backend's "Known limitation" docstring stayed
  verbatim. The bind_device gap on that backend is queued behind the
  custom-DNS-library work in `docs/custom-dns-design-round2.md` §1.
- The c-ares socket-callback registration logic itself is unchanged;
  only its `bind_device` source moved from a module global to a
  `BindDeviceCell` user_data heap cell.

See `progress-reports/2026-04-28-dns-bind-device-cleanup.md` for the
full arc.

## Last Verified Milestone (2026-04-28 — Resume DB simulation: `ResumeDbOf(Backend)` + `SimResumeBackend`)

Lands Path A from `docs/sqlite-simulation-and-replacement.md` (storage
research round, commit `17157ac`). Defers Path B (custom storage engine)
indefinitely, contingent on profiling evidence or operational surprises.
The recommendation in §5 of that doc explicitly favored A-only — this
milestone closes that loop.

**What landed**

- `src/storage/state_db.zig` — types (`TransferStats`, `RateLimits`,
  `ShareLimits`, `IpFilterConfig`, `TrackerOverride`, `SavedCategory`,
  `SavedBannedIp`, `SavedBannedRange`, `QueuePosition`) lifted to
  file-level so both backends share identical signatures. `ResumeDb`
  struct renamed to `SqliteBackend`. New identity functor
  `pub fn ResumeDbOf(comptime Backend: type) type { return Backend; }`
  parallels `EventLoopOf(IO)` / `AsyncRecheckOf(IO)`. Daemon alias
  `pub const ResumeDb = ResumeDbOf(SqliteBackend)` keeps every existing
  consumer compiling unchanged.

- `src/storage/sim_resume_backend.zig` — new in-memory drop-in
  implementation of the same 49-method public surface. Per-table
  `std.AutoHashMapUnmanaged` / `std.ArrayListUnmanaged` (slice-bearing
  rows can't go through `AutoHashMap` cleanly, so tags + tracker
  overrides are unsorted lists; per-torrent N is bounded). Explicit
  `std.Thread.Mutex` mirrors `SQLITE_OPEN_FULLMUTEX`'s multi-thread
  invariant. Four FaultConfig knobs:
  - `commit_failure_probability` — random write returns `error.SqliteCommitFailed`
  - `read_failure_probability` — random read returns "no rows"
  - `read_corruption_probability` — `loadCompletePieces` returns wrong bits
  - `silent_drop_probability` — write reports success but isn't applied
  Each knob mirrors the per-op-probability shape of
  `src/io/sim_io.zig`'s `FaultConfig`.

- `tests/sim_resume_backend_test.zig` — 22 algorithm-level tests
  covering load/store roundtrip on every table, atomic-swap semantics
  for `replaceCompletePieces`, `clearTorrent` cascade across all
  torrent-keyed tables, and each fault knob at probability 1.0.

- `tests/recheck_buggify_test.zig` — rewired from
  `ResumeDb.open(":memory:")` (real SQLite) to
  `SimResumeBackend.init(allocator, seed)` (in-memory, deterministic).
  Existing 32-seed cross-product harness keeps the same assertions but
  drops the SQLite link dependency. Adds a new BUGGIFY pass that
  injects 50% commit failure on `replaceCompletePieces` and asserts
  the in-memory `PieceTracker` state stays consistent even when the
  resume DB write fails — the testability win that wasn't previously
  reachable.

**Test delta**: 1494 → 1525 (+31). New runners:
`zig build test-sim-resume-backend`.

**Out of scope**: Path B (custom storage engine, append-log shape).
The research doc deferred it indefinitely; this milestone does not
revisit the decision. SQLite remains the production path with no
behaviour change.
## Last Verified Milestone (2026-04-28 — Correctness fixes: PieceStore.sync wiring, c-ares bind_device, SQLite policy)

Three contained correctness gaps from recent research rounds, batched
into one milestone. Branch: `worktree-correctness-fixes`. See
`progress-reports/2026-04-28-correctness-fixes.md` for the full arc.

**Fix 1 — `PieceStore.sync` was only called from a test (R6 from
`docs/mmap-durability-audit.md`)**: the daemon never called fsync on
completed pieces, so the OS pagecache controlled durability under
whatever dirty-writeback policy the kernel chose. A SIGKILL or power
loss seconds after a piece verified-and-persisted could lose it from
disk. New `EventLoop.submitTorrentSync` submits one async fsync per
non-skipped fd in `tc.shared_fds`; bookkeeping lives on
`TorrentContext.dirty_writes_since_sync` (a plain u32 — EL-thread-only,
no atomics). Wired at three points: a periodic 30 s timer (matches
Linux's `vm.dirty_expire_centisecs = 3000` so we don't add write
amplification, while bounding worst-case post-crash data loss); the
torrent-completion lifecycle hook (forced fsync regardless of dirty
count, so completion is a stable on-disk milestone); and the
graceful-shutdown drain (Phase 0.5 — submit fsync sweeps for every
dirty torrent then tick until they drain). Idempotent under
`tc.sync_in_flight` so the three triggers don't pile parallel sweeps
on the same fds. Test coverage: 9 inline tests in
`tests/torrent_sync_test.zig` driving `EventLoopOf(SimIO)` end-to-end.

**Fix 2 — `bind_device` silently bypassed by every DNS path
(`docs/custom-dns-design-round2.md` §1)**: `network.bind_device =
"wg0"` correctly applied to peer / tracker / RPC traffic, but DNS
queries leaked out the default route. Investigation found c-ares
exposes `ares_set_socket_callback(channel, fn(fd, type, ud))` that
fires once per UDP/TCP socket the channel opens — sufficient to apply
`SO_BINDTODEVICE` via the existing `applyBindDevice` helper.
`getaddrinfo` (the threadpool backend, build default) has no
equivalent hook, so it remains a Known Issue tied to the
custom-DNS-library follow-up. New `dns.setDefaultBindDevice` /
`dns.defaultBindDevice` module-level API publishes the value once at
daemon startup; `dns_cares.zig` reads it from `init` and registers the
socket callback. Workaround for users who need bound DNS: build with
`-Ddns=c_ares`. Documented in `STATUS.md` "Known Issues",
`src/io/dns_threadpool.zig` top docstring, and the `bind_device`
config field's docstring.

**Fix 3 — AGENTS.md SQLite-threading policy was stale
(`docs/sqlite-simulation-and-replacement.md` finding)**: the policy
section said "SQLite operations -- must run on a dedicated background
thread, never on the event-loop thread." The production reality is
multi-threaded access via `SQLITE_OPEN_FULLMUTEX`
(`src/storage/state_db.zig:31`); the shared `ResumeDb` connection is
intentionally accessed from worker threads, RPC handlers, and the
queue manager via SQLite's own mutex. Updated AGENTS.md to describe
the actual design accurately. The single hard invariant (never call
SQLite from the event-loop thread, since SQLite syscalls block) is
unchanged.

Commits:

  - `280e159` — `io: per-torrent durability sync via submitTorrentSync + periodic timer`
  - `955ce61` — `io/dns: bind_device wiring for c-ares; document threadpool gap`
  - `5f546c1` — `docs/AGENTS: correct SQLite-threading policy to match reality`

Test count delta: 1509 → 1518 (9 new tests in `torrent_sync_test.zig`).
Build green at HEAD on the default backend; c-ares backend has a
pre-existing `ares_build.h` build issue unrelated to this change.
## Last Verified Milestone (2026-04-28 — Daemon rewired onto comptime IO backend selector)

The daemon's hot callers were physically pinned to `io_uring` even after
the `IoBackend` 6-way enum, the comptime selector at `src/io/backend.zig`,
and all five non-`io_uring` backend MVPs landed. Rewires the production
import path so `-Dio=epoll_posix` (and friends) actually produce a daemon
binary backed by the chosen implementation.

What changed:

- **Category A** alias swaps in `event_loop`, `recheck`, `metadata_handler`,
  `http_executor`, and `storage/writer`: `RealIO` now resolves through
  `backend.RealIO` (which dispatches on `-Dio=`) instead of importing
  `real_io.zig` directly.
- **Category B** init call sites in `daemon/torrent_session.zig` (the two
  `PieceStore.init` one-shot rings) and `storage/writer.zig` test fixtures
  now go through a new `backend.initOneshot(allocator)` helper. The helper
  branches on the comptime-selected backend and supplies the right
  `init` signature for each (RealIO takes `Config{ .entries, .flags }`;
  the readiness backends take `(allocator, Config)` with backend-specific
  fields).
- **Category C** type-import swaps in `rpc/server`, `daemon/tracker_executor`,
  `daemon/udp_tracker_executor`: same alias rewire, plus the 3 `RealIO.init`
  test fixtures in `rpc/server.zig`.
- **`backend.initEventLoop`** new helper for the daemon's primary long-lived
  ring. Replaces the hard-coded `RealIO.init(.{ entries=256, flags=COOP_TASKRUN|SINGLE_ISSUER })`
  in `EventLoopOf(IO).initBare`. Under `-Dio=io_uring` (default) the
  io_uring branch is byte-equivalent to the prior call; under
  `epoll_posix`/`epoll_mmap` it picks per-backend production sizing.
- **`build.zig`**: previous `build_full_daemon = io_backend == .io_uring`
  splits into `build_daemon = io_backend != .sim` (gates `varuna` + `varuna-ctl`)
  and `build_companion_tools = io_backend == .io_uring` (gates `varuna-tools`
  + `varuna-perf`, which stay hard-coded to `io_uring` per the AGENTS.md
  exemption — `app.zig`, `storage/verify.zig`, `perf/workloads.zig` are
  CLI/benchmark code, not daemon paths).

Validation matrix (Linux native):

  | `-Dio=` flag    | daemon binary | tests             |
  |-----------------|---------------|-------------------|
  | `io_uring`      | PASS          | PASS (default)    |
  | `epoll_posix`   | PASS (NEW)    | PASS (per-bridge) |
  | `epoll_mmap`    | PASS (NEW)    | PASS (per-bridge) |
  | `kqueue_posix`  | FAIL¹         | per-bridge only   |
  | `kqueue_mmap`   | FAIL¹         | per-bridge only   |
  | `sim`           | (skipped)     | sim suite         |

  ¹ Pre-existing — `kqueue_*_io.zig` references `std.c.EVFILT.READ` which
  is undefined on Linux (and the macOS cross-compile fails on unrelated
  `huge_page_cache.zig` / `IoUring.zig` Linux/Darwin type mismatches).
  Out of daemon-rewire scope.

Branch: `worktree-daemon-rewire`. See
`progress-reports/2026-04-28-daemon-rewire.md` for the full breakdown
and surprise notes on `EventLoop.initBare` cascading into a second helper.

## Last Verified Milestone (2026-04-30 — DNS resolver: connect-failure invalidate + bounded TTL honoring)

Closes Open Question #1 from `docs/custom-dns-design.md` (the just-merged
research round, commit `5c866e5`). Two contained correctness fixes to the
existing `DnsResolver` cache, independent of the larger custom-DNS
question.

**Fix 1 — connect-failure invalidation (`698871c`)**: `DnsResolver.invalidate()`
was exported but never called. When a tracker IP migrated or a CDN
repointed, every subsequent announce would burn the full TTL window
(then 5 min, now 1 h — see Fix 2) on the same dead IP. Now the four DNS
consumers (HttpExecutor, HttpClient, UdpTrackerExecutor, plus
`tracker/announce.zig` via HttpClient) call `invalidate(host)` on
connect-failure variants that imply a stale resolved IP. Classification
helper `dns.shouldInvalidateOnConnectError(err) -> bool`:

  - **Invalidate**: `ConnectionRefused`, `ConnectionTimedOut` (covers
    both kernel ETIMEDOUT and the io_uring `link_timeout` deadline),
    `NetworkUnreachable`, `HostUnreachable`.
  - **Keep cache**: `ConnectionResetByPeer`, `BrokenPipe`,
    `ConnectionAborted`, `OperationCanceled`, `SubmitFailed`,
    `SocketCreateFailed`, `RequestTimedOut`, parse / 4xx / 5xx errors.

UDP-specific: BEP 15 has no separate connect surface, so `UdpTrackerExecutor`
invalidates when either the overall 2-min deadline expires or the
exponential-backoff retransmit schedule runs out — both mean "we sent
datagrams to the resolved IP and nothing came back," the moral analog
of TCP's `ConnectionTimedOut`.

**Fix 2 — bounded TTL honoring (`5fe7e25`)**: the cache previously
applied a fixed 5-minute TTL regardless of the authoritative response.
Tracker announce intervals are typically 30-60 min, so steady-state
re-announces re-resolved before nearly every request. New shared
`TtlBounds` config (`floor_s = 30`, `cap_s = 3600`):

  - **Floor (30 s)**: bounds the case where an authoritative server
    publishes TTL=0 / a very low TTL (e.g. during a planned
    migration). Without it, the cache would be defeated.
  - **Cap (1 h)**: matches the upper end of typical announce
    intervals; bounds the worst-case stale-IP window when a server
    publishes very long TTLs. Recovery from a real IP migration is
    bounded by this cap OR the Fix 1 invalidate hook, whichever
    fires first.

Backend behavior:

  - `dns_threadpool` (default, `-Ddns=threadpool`): `getaddrinfo`
    cannot expose the authoritative TTL, so this backend uses
    `cap_s` as a fixed cache lifetime. Old default 5 min → new
    default 1 h: ~12× reduction in steady-state lookups.
  - `dns_cares` (`-Ddns=c_ares`): switches from the deprecated
    `ares_gethostbyname` to `ares_getaddrinfo`, whose
    `ares_addrinfo_node.ai_ttl` exposes the authoritative TTL.
    Each cached entry's lifetime is `clamp(ai_ttl, floor_s, cap_s)`.
    A TTL ≤ 0 (synthetic /etc/hosts records, etc.) falls back
    to the floor.

`ttl_bounds` is a public field on each backend's `DnsResolver` so
callers / future config wiring can override per-instance.

Branch: `worktree-dns-fixes`.

## Last Verified Milestone (2026-04-30 — POSIX file-op thread pool: EpollPosixIO + KqueuePosixIO)

Wires `EpollPosixIO` and `KqueuePosixIO` file ops (read/write/fsync/
fallocate/truncate) through a shared `PosixFilePool`. Closes the
"file ops return Unimplemented / OperationNotSupported" gap left by
the 2026-04-30 epoll + kqueue bifurcations. See
`progress-reports/2026-04-30-posix-file-thread-pool.md` for the
round-by-round rationale and `docs/epoll-kqueue-design.md` §4.2 for
the unconditional-thread-pool-offload pattern (zio).

Three commits on `worktree-posix-thread-pool`, all green at HEAD:

- `e791960` — `io: add PosixFilePool for EpollPosixIO/KqueuePosixIO file ops`.
  New `src/io/posix_file_pool.zig` (~480 LOC, 9 inline tests).
  Worker thread pool: bounded mutex+condvar pending queue, bounded
  completed queue, callback-shaped `setWakeup` hook so each backend
  wires its own readiness primitive's wake mechanism. Worker loop
  mirrors `hasher.zig` (Pattern #15 — read existing invariants);
  per-op syscall execution branches Linux/Darwin for fallocate
  (Linux `posix.fallocate` vs. macOS `fcntl(F_PREALLOCATE)` +
  `ftruncate`, copying the `fstore_t` layout from
  `src/io/kqueue_mmap_io.zig`). Tests cover create/deinit, queue-full
  backpressure, write+read round-trip, bad-fd fault, hasPendingWork,
  wakeup callback firing, deinit cancels still-pending, and a
  256-op stress run across 4 workers.
- `c004d6a` — `io/epoll_posix: wire file ops through PosixFilePool`.
  Replaces the five `error.Unimplemented` stubs with submissions to
  the pool. Workers signal via the existing `wakeup_fd` eventfd;
  `tick` drains the pool both before and after `epoll_pwait`.
  Cancel grew a fourth best-effort branch for pool-pending file
  ops. New `bindWakeup` post-init helper (the pool's wake fn
  needs a stable `*EpollPosixIO`, which init's return-by-value
  can't supply directly). Inline + bridge tests now exercise:
  fsync/truncate/fallocate completion, write→read round-trip,
  64-op concurrency, and a closed-fd fault. The MVP-scope-marker
  test was rewritten from "asserts Unimplemented" to "asserts real
  fsync via pool".
- `747b9df` — `io/kqueue_posix: wire file ops through PosixFilePool`.
  Same shape, with the wake primitive swapped from eventfd to
  `EVFILT_USER` + `NOTE_TRIGGER`. Init registers a single user
  event at fixed ident `0xFADEFADE` with `EV_CLEAR`; workers issue
  `NOTE_TRIGGER` on completion; `tick` recognises the user-event
  filter and skips the per-event dispatch (drainPool picks up the
  result). `evfilt_user` constant carries a NetBSD-binding-bug
  workaround mirrored from zio. Bridge tests gained 2 new
  platform-gated round-trip tests; cross-compile clean for
  `aarch64-macos`.

Test count delta: **+9 inline (pool) + 4 bridge (epoll) + 2 bridge
(kqueue) = +15 tests**. Daemon binary still builds under
`-Dio=io_uring` (default).

Validation:
- `zig build` (default io_uring): clean
- `zig build -Dio=epoll_posix`: clean
- `zig build -Dio=kqueue_posix`: clean
- `zig build -Dtarget=aarch64-macos -Dio=kqueue_posix`: clean
- `zig build test`: green (~1502 tests; sporadic flakes in
  `recheck_test.zig` are pre-existing SimIO-driven and unrelated)
- `zig build test-epoll-posix-io`: green
- `zig build test-kqueue-posix-io-bridge`: green
- `zig build test-kqueue-posix-io`: green (Linux runs the
  platform-portable subset; macOS-gated tests SkipZigTest)
- `zig fmt .`: clean

What needs real-host validation (cross-compile validates types, not
runtime semantics): `EVFILT_USER` + `NOTE_TRIGGER` actually breaks
`kevent()` on darwin; `fcntl(F_PREALLOCATE)` error mapping under
APFS / FAT32 / FUSE; worker contention under heavy fsync load on
macOS (we use `fsync(2)`, not `F_FULLFSYNC`).

Follow-ups (not in scope here):
- Daemon-side rewire (`src/storage/writer.zig`, `src/io/recheck.zig`,
  …) onto `backend.RealIO` once the file-op coverage is mature in at
  least one non-`io_uring` backend.
- Page-fault mitigation for `EpollMmapIO` / `KqueueMmapIO` — those
  backends deliberately don't use this pool. If profiling shows
  page-fault stalls, repurpose the same pool to run the memcpy.
- BUGGIFY-style fault tests for the pool (random worker delays,
  queue full at random ticks).

Branch: `worktree-posix-thread-pool`.

## Last Verified Milestone (2026-04-30 — EpollIO bifurcation + 6-way IoBackend selector)

Bifurcates the previous `EpollIO` MVP into two backends along the
file-I/O strategy axis (POSIX `pread`/`pwrite`-on-thread-pool vs
mmap-backed `memcpy`/`msync`), and extends `IoBackend` to a 6-way
selector that lines up with the parallel `KqueueIO` engineer's
matching split:

  - `io_uring` — production proactor (unchanged; only flag that
    installs the daemon binary).
  - `epoll_posix` — rename target for the previous `EpollIO` MVP
    (`src/io/epoll_io.zig` → `src/io/epoll_posix_io.zig`,
    `EpollIO` → `EpollPosixIO`). Sockets + timers + cancel real;
    file ops still `error.Unimplemented` pending the POSIX
    file-op thread pool.
  - `epoll_mmap` — new backend (`src/io/epoll_mmap_io.zig`).
    Readiness layer mirrors `EpollPosixIO`. File ops use a per-fd
    lazy `mmap(PROT_READ | PROT_WRITE, MAP_SHARED)` plus
    `madvise(MADV_WILLNEED)` for prefetch; `pread`/`pwrite` are
    `memcpy` against the mapping; `fsync` is `msync(MS_SYNC)`;
    `fallocate` calls `posix.fallocate` and drops the stale
    mapping; `truncate` calls `posix.ftruncate` and drops the
    mapping. Page-fault stalls on the EL thread are documented as
    the deliberate MVP limitation; the mitigation is to run
    `memcpy` on a thread pool if profiling shows it matters.
  - `kqueue_posix`, `kqueue_mmap` — STUB files on this branch
    (`src/io/kqueue_posix_io.zig`, `src/io/kqueue_mmap_io.zig`)
    that return `error.Unimplemented` from every op so the 6-way
    selector compiles. The parallel kqueue-bifurcation engineer
    replaces both with real implementations on their branch.
  - `sim` — promotes `SimIO` to a top-level option. `RealIO`
    resolves to `sim_io.SimIO` for test builds that want to exercise
    the comptime selector itself. `build_full_daemon` stays gated
    to `.io_uring`.

Three bisectable commits on `worktree-epoll-bifurcation`:

  - `774a7d4` — `io: bifurcate EpollIO scaffold + extend IoBackend
    to 6-way`. File renames + scaffolding; SimIO wiring; stub
    kqueue files; updated `IoBackend` enum and `-Dio=` flag help.
  - `de100f2` — `io: build out EpollMmapIO MVP — sockets/timers/
    cancel + mmap file ops`. Mirrors readiness-layer code from
    `EpollPosixIO` and adds the mmap-backed file ops with
    integration coverage in 7 inline tests (init/deinit, timeout,
    socket, recv-on-socketpair, cancel-on-parked-recv,
    pwrite/pread/fsync round-trip, read-past-EOF returns zero).
  - `<commit 3>` — `docs/tests: progress report + STATUS
    milestone for epoll bifurcation`. Adds
    `tests/epoll_mmap_io_test.zig` (4 tests covering remap on
    file growth, msync round-trip, truncate-invalidates-mapping)
    plus `progress-reports/2026-04-30-epoll-bifurcation.md` and
    this STATUS entry.

`zig fmt .`: clean. `zig build`, `zig build -Dio=epoll_posix`,
`zig build -Dio=epoll_mmap`, `zig build -Dio=kqueue_posix`,
`zig build -Dio=kqueue_mmap`, `zig build -Dio=sim`: all clean.
`zig build test` (default `-Dio=io_uring`): green;
`zig build test -Dio=epoll_posix`: green; `zig build test
-Dio=epoll_mmap`: green; `zig build test-epoll-mmap-io`: green.

Test step rename: `test-epoll-io` → `test-epoll-posix-io`. New
focused step: `test-epoll-mmap-io`.

Expected merge conflicts with the parallel kqueue-bifurcation
engineer: `build.zig` and `src/io/backend.zig` (both engineers
extend the IoBackend enum); `src/io/kqueue_posix_io.zig` and
`src/io/kqueue_mmap_io.zig` (my stubs vs. their real
implementations — take theirs); `src/io/root.zig` (kqueue
imports). All trivial.

Follow-ups:
- ~~POSIX file-op thread pool for `EpollPosixIO`~~: closed
  2026-04-30 by the `worktree-posix-thread-pool` engineer (see
  the milestone immediately below).
- Page-fault thread-pool memcpy for `EpollMmapIO` if profiling
  shows page faults stalling the EL.
- Daemon-side: rewire `src/storage/writer.zig`, `src/io/recheck.zig`
  et al. onto `backend.RealIO` once the file-op coverage is
  complete in at least one non-`io_uring` backend.

Branch: `worktree-epoll-bifurcation`.

## Last Verified Milestone (2026-04-30 — Kqueue file-op bifurcation: `KqueuePosixIO` + `KqueueMmapIO`)

Splits the 2026-04-29 `KqueueIO` MVP into two file-op-strategy variants. The readiness layer (sockets, timers, cancel) is identical; only the file-op submission methods diverge. Mirrors the parallel `worktree-epoll-bifurcation` engineer's `EpollPosixIO` / `EpollMmapIO` split on the Linux side. See `progress-reports/2026-04-30-kqueue-bifurcation.md` for the round-by-round rationale and `docs/epoll-kqueue-design.md` for the file-op strategy survey.

Two impl + one docs commit on `worktree-kqueue-bifurcation`, all green at HEAD. Test count: **+8 inline** in `src/io/kqueue_mmap_io.zig` (state size, timer-heap ordering, errno mapping, fstore_t layout drift detection, makeCancelledResult tag preservation), **+3 platform-only** (init/deinit, real timeout-via-kevent, full mmap round-trip fallocate→write→fsync→read; skip on Linux), **+2 Linux bridge** in `tests/kqueue_mmap_io_test.zig`. Daemon binary still builds under `-Dio=io_uring` (default); the existing `-Dio=kqueue` flag continues to resolve to `KqueuePosixIO` until the sibling's 6-way IoBackend split lands.

- `a15c9de` — `io: rename KqueueIO → KqueuePosixIO (file-op strategy bifurcation)`. Mechanical: `git mv src/io/kqueue_io.zig src/io/kqueue_posix_io.zig`; 52 occurrences of `KqueueIO` → `KqueuePosixIO`; `git mv tests/kqueue_io_test.zig tests/kqueue_posix_io_test.zig`; build steps `test-kqueue-io` → `test-kqueue-posix-io` and `test-kqueue-io-bridge` → `test-kqueue-posix-io-bridge`. `src/io/backend.zig` updated transitionally (sibling will overwrite at merge time); IoBackend enum docstring notes the rename and the upcoming 6-way split.
- `d5d170e` — `io: add KqueueMmapIO MVP — mmap-based file ops for the macOS dev backend`. New `src/io/kqueue_mmap_io.zig` (~960 LOC). File-op strategy:
  - **read/write** → bounds-checked memcpy against an mmap'd region. First access fstats the fd and mmaps PROT_READ\|PROT_WRITE / MAP_SHARED; optional `MADV.WILLNEED` (closest macOS equivalent of Linux's MAP_POPULATE).
  - **fsync** → `msync(MS_SYNC)` over the mapping; falls back to plain `fsync(2)` for unmapped fds. Darwin's msync has no datasync-only mode; both `op.datasync = true/false` map to MSF.SYNC. F_FULLFSYNC is out of scope for a dev backend.
  - **fallocate** → `fcntl(F_PREALLOCATE)` + `ftruncate`. Pattern from `tigerbeetle/src/io/darwin.zig:fs_allocate`. Tries ALLOCATECONTIG\|ALLOCATEALL first, falls back to ALLOCATEALL. Maps EOPNOTSUPP → `error.OperationNotSupported`.
  - **truncate** → unmap-if-mapped + `ftruncate`. Darwin lacks `mremap`, so a resize must drop the mapping; the next access remaps at the new size.
  Per-completion `KqueueState`, timer heap, kevent dispatch, errno-mapping helpers all mirror KqueuePosixIO. `fstore_t` extern struct inlined locally with size+alignment drift-detection assert. Build wiring: `test-kqueue-mmap-io` (standalone, cross-compile-clean) and `test-kqueue-mmap-io-bridge` (varuna_mod-side, Linux-only).
- (commit 3) — `docs: progress report + STATUS milestone for kqueue bifurcation`. This entry plus `progress-reports/2026-04-30-kqueue-bifurcation.md`.

Validation:
- `zig build` (Linux io_uring): clean
- `zig build test`: green (full daemon suite still passes)
- `zig build test-kqueue-posix-io` / `test-kqueue-mmap-io`: green (native inline)
- `zig build -Dtarget=aarch64-macos -Dio=kqueue`: clean cross-compile
- `zig build test-kqueue-posix-io -Dtarget=aarch64-macos -Dio=kqueue`: clean
- `zig build test-kqueue-mmap-io -Dtarget=aarch64-macos -Dio=kqueue`: clean
- `zig fmt .`: clean

What needs real-macOS validation (cross-compile validates types, not runtime semantics): the mmap round-trip on a real darwin filesystem (PROT_READ\|PROT_WRITE acceptance, F_PREALLOCATE error mapping, msync(MS_SYNC) timing); page-fault latency on the EL thread under workloads with working-set > RAM (the whole point of bifurcating from POSIX is comparability); F_PREALLOCATE error mapping confirmation; plus all KqueuePosixIO concerns inherited (EVFILT mask values, BSD errno mapping, std.c.recvmsg/sendmsg compatibility, connect-with-deadline race, posix.SOCK.NONBLOCK value match).

Coordination: `worktree-epoll-bifurcation` engineer owns the IoBackend enum split (3-way → 6-way: `io_uring`, `epoll_posix`, `epoll_mmap`, `kqueue_posix`, `kqueue_mmap`, `sim`) and the dispatch in `src/io/backend.zig`. Expected merge conflicts in `build.zig` (test wiring lines), `src/io/root.zig` (module references), and `src/io/backend.zig` (sibling's 6-way dispatch supersedes my transitional 1-line import-rename). The contract (`src/io/io_interface.zig`) is unchanged.

Branch: `worktree-kqueue-bifurcation`.

## Last Verified Milestone (2026-04-29 — EpollIO MVP: socket + timer + cancel surface)

Implements a minimum-viable `EpollIO` Linux readiness backend behind a new `-Dio=` build flag. `EpollIO` is the fallback for environments where `io_uring` is forbidden (seccomp policies, ancient kernels, hostile sandboxes); see `docs/epoll-kqueue-design.md` for the full design and `progress-reports/2026-04-29-epoll-io-mvp.md` for the round-by-round rationale.

Two bisectable commits, all green at HEAD. Test count: **1418 → 1430 (+12)**: 6 inline tests in `src/io/epoll_io.zig`, 5 in `tests/epoll_io_test.zig`, 1 in `src/io/backend.zig`. Daemon binary: builds under both `-Dio=io_uring` (default) and `-Dio=epoll`.

- `91eb57e` — `io: add EpollIO MVP backend (sockets + timers + cancel)`. ~720 LOC of `src/io/epoll_io.zig` covering `socket`, `connect`, `accept`, `recv`, `send`, `recvmsg`, `sendmsg`, `poll`, `timeout`, `cancel`, plus `tick` (epoll_pwait + flat-array timer "heap" + wakeup eventfd). File ops (`read`, `write`, `pread`, `pwrite`, `fallocate`, `fsync`, `truncate`) intentionally return `error.Unimplemented` — they require a worker thread pool because epoll cannot signal regular-file readiness, and that thread pool is the next big follow-up. New `src/io/backend.zig` comptime selector resolves the daemon's `RealIO` alias to the chosen backend; daemon callers still `@import("real_io.zig")` directly today (rewiring gated on file-op follow-up). New `-Dio=io_uring|epoll` build flag with `kqueue` slot reserved for the parallel macOS engineer.
- `d6b2af8` — `io: add tests/epoll_io_test.zig + zig build test-epoll-io step`. Standalone smoke tests covering multi-tick socketpair round-trip (recv parks → send unparks → callback fires on next tick), multiple concurrent timers in deadline order, cancel of registered recv with `OperationCanceled` delivery, file-op `Unimplemented` contract, and non-blocking-fd socket creation. Wired into `zig build test` and exposed as the focused `zig build test-epoll-io` step.

Architecture choices worth flagging:
- **Self-contained submission methods.** Each socket method runs its own `.rearm` loop; mutual recursion through callbacks would otherwise produce an inferred-error-set cycle Zig 0.15.2 cannot resolve. Same trick `real_io.zig`'s `truncate` uses.
- **EPOLLONESHOT, not EPOLLET.** Per design doc recommendation; varuna's hot path has at most one outstanding op per fd.
- **Flat-array timer heap.** O(n) `peekMin`. ~hundreds of timers in the hot path; promote to binary heap when profiled.
- **Single eventfd** for cross-thread wakeup. Wired in `tick` so the file-op worker pool follow-up doesn't need to revisit lifecycle.

What does NOT yet work under `-Dio=epoll`: any daemon path that touches the storage IO contract (PieceStore reads/writes, recheck verification, fsync-after-batch, fallocate-on-init, truncate fallback). The MVP is enough to run the daemon's network surface (peer wire, RPC, tracker, DHT, uTP) in isolation; full daemon end-to-end requires the file-op worker pool. See `progress-reports/2026-04-29-epoll-io-mvp.md` for the prioritised follow-up list.

`zig fmt .`: clean. `zig build`: clean. `zig build -Dio=epoll`: clean. `zig build test`: green. `zig build test -Dio=epoll`: green. `zig build test-epoll-io`: green.

Branch: `worktree-epoll-io`.

## Last Verified Milestone (2026-04-29 — runtime per-op feature probe + RealIO.truncate async on supporting kernels)

Converted the previous "switch RealIO.truncate to `IORING_OP_FTRUNCATE` once kernel floor bumps to 6.9+" follow-up into a runtime decision. New `FeatureSupport` struct in `src/io/ring.zig` (currently one flag, `supports_ftruncate`) populated by `probeFeatures(&ring)` (calls `IoUring.get_probe()` → `IORING_REGISTER_PROBE`). `RealIO.init` caches the result; `RealIO.truncate` branches — async `IORING_OP_FTRUNCATE` SQE on supporting kernels (kernel ≥6.9 or backports), synchronous `posix.ftruncate(2)` fallback otherwise. Varuna's overall floor is unchanged (6.6 minimum / 6.8 preferred). Picks up backports / custom kernels that the kernel-version-string approach would miss.

Three bisectable commits, all green at HEAD. Test count: **1420/1421 → 1422/1423 (+2)**; 1 skipped (intentional). Daemon binary: builds.

Dev-machine probe result (kernel 7.0.1): `supports_ftruncate = true`. The async path is the one actually exercised in CI on the dev machine.

- `54f2f9a` — `io: add IORING_REGISTER_PROBE wrapper + FeatureSupport struct`. New `FeatureSupport` (one bool field per kernel-floor-blocked op we care about) plus `probeFeatures(*linux.IoUring)` in `src/io/ring.zig`. Kernels too old to support the probe register itself (kernel <5.6, returns EINVAL) get mapped to `FeatureSupport.none` (all-false), which is observably equivalent to "nothing extra is supported". Three inline tests.
- `ea99efb` — `io: route RealIO.truncate through IORING_OP_FTRUNCATE when supported`. `RealIO.feature_support` field cached at init; `RealIO.truncate` dispatches on `supports_ftruncate`. Async path uses `prep_rw(.FTRUNCATE, fd, addr=0, len=0, offset=length)` (the kernel reads the new file length from `sqe->off`; addr/len/rw_flags/buf_index/splice_fd_in must be zero or it returns EINVAL). `buildResult` returns `voidOrError(cqe)` for `.truncate` (was `error.UnknownOperation`, no longer reachable on supporting kernels). Sync fallback path unchanged. Three new inline tests (runtime-detected path, async-only path, async-shrink), one updated.
- (commit 3) — `docs: progress report + STATUS milestone for runtime feature probe`. Adds `progress-reports/2026-04-29-runtime-feature-probe.md` and the STATUS entries. Files a new follow-up: "Generalize `FeatureSupport` to cover other kernel-floor-blocked ops" (`IORING_OP_SETSOCKOPT` 6.7+, `IORING_OP_BIND`/`LISTEN` 6.11+).

`zig build` (full daemon binary): clean. `zig fmt .`: clean. `zig build test --summary all`: 90/90 steps, 1422/1423 tests passed, 1 skipped (intentional). See `progress-reports/2026-04-29-runtime-feature-probe.md`.

Branch: `worktree-runtime-detect`.

## Last Verified Milestone (2026-04-29 — KqueueIO MVP: macOS / BSD developer backend)

Lands a minimum-viable kqueue(2) backend (`src/io/kqueue_io.zig`) plus the
`-Dio={io_uring,kqueue}` build flag. Production stays Linux/io_uring; this
exists so varuna can be developed (and cross-compile-validated) on macOS.
Per the strategy in `docs/epoll-kqueue-design.md` and the survey in
`progress-reports/2026-04-27-epoll-kqueue-research.md`.

One bisectable commit on `worktree-kqueue-io` (skeleton + impl together —
splitting at op-family granularity would have added throwaway intermediate
states for ~zero bisectability gain on a brand-new file).

- `8384b6a` — `io: add KqueueIO MVP backend + -Dio= build flag`. Implements
  lifecycle (init/deinit/tick/closeSocket), timer heap + `timeout` op,
  socket lifecycle (`socket` with macOS fcntl O_NONBLOCK / FD_CLOEXEC,
  `connect` with deadline via timer heap, `accept` single-shot + multishot
  via re-register), stream IO (`recv`/`send`), datagram IO
  (`recvmsg`/`sendmsg`), `poll`, best-effort `cancel`, synchronous
  `truncate` (mirrors RealIO's pattern). File ops (`read`/`write`/`fsync`/
  `fallocate`) stubbed to deliver `error.OperationNotSupported`
  synchronously — the thread-pool-offload follow-up is the next milestone.

  `build.zig` gates the daemon install steps on `io_backend == .io_uring`
  (the daemon graph hard-references RealIO; under any other backend
  `zig build` succeeds without producing the daemon, which is what
  cross-compile validation needs). New `test-kqueue-io` step compiles
  `src/io/kqueue_io.zig` directly — independent of `varuna_mod` — so
  `-Dtarget=aarch64-macos -Dio=kqueue` cross-compiles cleanly. Bridge
  step `test-kqueue-io-bridge` runs varuna_mod-side tests on Linux.

Validation:
- `zig build` (Linux io_uring): clean
- `zig build test`: clean (1418/1418 inherited + KqueueIO inline tests
  on the platform-portable subset)
- `zig build test-kqueue-io`: clean
- `zig build -Dtarget=aarch64-macos -Dio=kqueue`: clean cross-compile
- `zig build test-kqueue-io -Dtarget=aarch64-macos -Dio=kqueue`: clean
  cross-compile (run step skipped — host can't exec macOS binaries)
- `zig fmt .`: clean

What needs real-macOS validation (cross-compile validates types, not
runtime semantics): the `EVFILT.READ` / `EV.ADD|ENABLE|ONESHOT` mask
values, `posix.recv`/`send`/`accept` errno mapping on darwin's BSD
errno layout, `std.c.recvmsg`/`sendmsg` signature compatibility,
connect-with-deadline race ordering, `posix.SOCK.NONBLOCK` value match.
See `progress-reports/2026-04-29-kqueue-io-mvp.md`.

Coordination: `epoll-io-engineer` is adding `-Dio=epoll` to the same
`IoBackend` enum on a parallel branch. The merge conflict is intentionally
trivial — extend the choice list.

Branch: `worktree-kqueue-io`.

## Last Verified Milestone (2026-04-28 — `truncate` op on the IO contract: storage fallback async)

Closed the last synchronous disk-syscall holdout in `src/storage/writer.zig`. PieceStore's filesystem-portability fallback (when fallocate returns `error.OperationNotSupported` on tmpfs <5.10 / FAT32 / certain FUSE FSes) was the only `setEndPos` left after the 2026-04-27 fallocate/fsync routing and the 2026-04-28 writePiece/readPiece migration. Now routes through `self.io.truncate`, BUGGIFY-injectable from SimIO and forward-compatible with the queued EpollIO/KqueueIO research round.

Three bisectable commits, all green at HEAD. Test count: **1413 → 1418 (+5)**. Daemon binary: builds.

- `6150f85` — `io: add truncate op to contract; sync RealIO + SimIO with fault knob`. New `TruncateOp` + `Result.truncate` variant on `io_interface.zig`. RealIO implementation is synchronous (`posix.ftruncate`, fires the callback inline) because `IORING_OP_FTRUNCATE` requires kernel 6.9 (above varuna's 6.6/6.8 floor); the only daemon caller runs on a background thread, so synchronous syscall has zero event-loop impact. SimIO implementation plus `truncate_error_probability` knob (delivers `error.InputOutput`); companion entries added to `cancelResultFor` + `buggifyResultFor`. Three algorithm tests in `tests/sim_socketpair_test.zig` (success, fault, plus an inline RealIO test asserting the file actually grew on disk).
- `c058db4` — `storage: route preallocate fallback through io.truncate`. Both `preallocateAll` and `preallocateOne` now submit `io.truncate` after their fallocate drain when `error.OperationNotSupported` is observed. New `TruncateCtx` + `truncateCallback` mirror the existing `PreallocCtx` shape; `PreallocSlot.needs_truncate` flag avoids submitting a second op from inside the fallocate callback. Re-uses the per-slot completions that just disarmed during the fallocate drain.
- `9a3fdb3` — `tests: integration tests for the PieceStore truncate fallback path`. New `fallocate_unsupported_probability` knob on SimIO so tests can force the historical filesystem-portability case (`error.OperationNotSupported`) independently of the existing `fallocate_error_probability` (which delivers `NoSpaceLeft`). Two integration tests in `tests/storage_writer_test.zig`: success path (fallocate forced unsupported → io.truncate succeeds → init returns cleanly) and failure path (fallocate forced unsupported + truncate forced to InputOutput → init propagates InputOutput).

Combined commits 1+2 (contract addition + RealIO + SimIO + algorithm tests) because Zig's exhaustive switches over the operation tag in both backends would fail to compile if the new variant landed without matching dispatch + result-builder + fault-table updates. Same constraint the 2026-04-27 storage-io and 2026-04-28 storage-rw rounds hit.

`zig build` (full daemon binary): clean. `zig fmt .`: clean. `zig build test --summary all`: 90/90 steps, 1418/1419 tests passed, 1 skipped (intentional). See `progress-reports/2026-04-28-truncate-op.md`.

Branch: `worktree-truncate-op`.

## Last Verified Milestone (2026-04-28 — uTP correctness fixes + net test wiring)

Closed three round-3-audit follow-ups on `worktree-utp-fixes`. Four
bisectable commits, all green at HEAD.

- `9ed7200 net/utp: fix reorder buffer indexing + slice ownership` —
  two coupled bugs from the round-3 audit. The indexing bug
  (`bufferReorder` indexed by offset, `deliverReordered` by absolute
  `seq_nr % 64`) silently dropped every out-of-order packet. The
  slice-ownership bug (`ReorderEntry.data` was borrowed into the
  shared `utp_recv_buf`) would have become a UAF the moment the
  indexing bug was fixed. Both fixed together: indexing aligned on
  absolute `seq_nr % max_reorder_buf` in both methods; payload copied
  into per-slot owned storage at `bufferReorder`; `delivered_payloads`
  on `UtpSocket` keeps slices alive across the result-handling
  window and frees on the next `processPacket` or `deinit`.
  Production caller (`src/io/utp_handler.zig`) now drains the
  buffered payloads into `deliverUtpData` after the in-order packet,
  so out-of-order delivery actually works end-to-end. 8 inline
  regression tests — including the exact UAF scenario where the
  source buffer is mutated between buffering and delivery.
- `873ff44 net/utp_manager: walk and strip extension chain before BT
  framing` — `processPacket` now walks `(next_ext, len, [len]u8)*`
  via `stripExtensions` and hands the trailing slice to the BT
  layer. Truncated chains and SACK extensions exceeding
  `sack_bitmask_max = 32` are rejected with `null` (manager drops
  the malformed datagram). 9 inline regression tests including a
  full-pipeline test that constructs a DATA packet with
  `hdr.extension = selective_ack` and 4 BT keepalive bytes after the
  bitmask, asserting the BT layer receives only the keepalive.
- `1b6cfd1 net: wire bencode_scanner + web_seed into net/root.zig
  test discovery` — closes the round-2 dark-test follow-up that was
  blocked on parallel quick-wins work. ~25 inline tests now
  reachable. Verification: `try testing.expect(false)` in one test
  per file caught by the runner with the correct names; reverted.

`zig build`: clean. `zig fmt .`: clean. `zig build test`: green
(after one self-resolving flake of the pre-existing
`sim_smart_ban_phase12_eventloop_test` retry-on-second-run pattern,
also seen in the round-2/3 dark-test report). See
`progress-reports/2026-04-28-utp-fixes-and-net-wiring.md`.

Branch: `worktree-utp-fixes`.

## Last Verified Milestone (2026-04-28 — Storage IO contract: writePiece + readPiece via the contract)

Routed `src/storage/writer.zig`'s remaining synchronous syscall paths through the IO contract. `PieceStore.writePiece` and `PieceStore.readPiece` now submit one `self.io.write` / `self.io.read` per span (one span per file the piece touches) with caller-owned per-span completions, and drain via `io.tick(1)` until every completion lands. Together with the 2026-04-27 fallocate/fsync routing, every disk syscall the store performs now goes through the contract — BUGGIFY-injectable from SimIO and forward-compatible with the queued EpollIO/KqueueIO research round.

Four bisectable commits, all green at HEAD. Test count: **1393 → 1397 (+4)**.

- `78c03a9` — `sim_io: write returns op.buf.len on success`. SimIO previously returned 0 on a successful write, which makes any caller that loops on short writes (the standard `pwriteAll` shape) loop forever against the simulator. Real `write(2)` and `IORING_OP_WRITE` return the bytes accepted, normally the full buffer length on regular files. Existing daemon callers (`peer_handler.diskWriteCompleteFor`) only check `r >= 0` for success, so they're unaffected. Mechanical prep for the writePiece migration.
- `c7ac41a` — `storage: writePiece async migration via io.write`. New `WriteSpanState` per-span tracking struct (heap-allocated inside the caller's `states` slice) carries its own `Completion`, the (possibly shrinking) `remaining` buffer slice, and the advancing `offset`. The callback handles short writes by re-submitting the remainder; a 0-byte success surfaces as `error.UnexpectedEndOfFile`, matching the pre-refactor `pwriteAll` semantic. Submission-failure path adjusts `pending` to match what was actually submitted so the drain loop terminates cleanly. Same shape as `sync()`.
- `63c5061` — `storage: readPiece async migration; remove dead PieceIO + helpers`. Mirror of the writePiece commit for reads. Short reads re-submit the remainder; a 0-byte completion before the span is satisfied surfaces as `error.UnexpectedEndOfFile`. Removes the now-unused `pwriteAll`/`preadAll` helpers and the `PieceIO` struct (which existed only as a "lightweight piece I/O using pre-opened fds" wrapper but had no callers anywhere in the repo — the daemon's hot piece-write path uses `peer_policy`'s direct `self.io.write` calls).
- `2a671bf` — `tests: PieceStoreOf(SimIO) integration tests for writePiece/readPiece`. Four tests in `tests/storage_writer_test.zig`: 2-span round-trip (uses `SimIO.setFileBytes` to register expected post-write content for the read leg), writePiece SimIO write fault → `error.NoSpaceLeft` propagates, readPiece SimIO read fault → `error.InputOutput` propagates, 3-span round-trip (new `torrent_3file` fixture: alpha + beta + gamma, 3 bytes each, 9-byte single piece) confirms `pending` decrements correctly across N > 2 callbacks.

`zig build` (full daemon binary): clean. `zig fmt .`: clean. `zig build test --summary all`: 90/90 steps, 1396/1397 tests passed, 1 skipped (intentional). Pre-existing intermittent flake on `sim_multi_source_eventloop_test` and `recheck_test.AsyncRecheckOf(SimIO)` is unrelated and pre-dates this work — see `progress-reports/2026-04-27-dark-test-audit-r2r3.md` and `progress-reports/2026-04-27-quick-wins.md`. See `progress-reports/2026-04-28-storage-rw-io-contract.md`.

Branch: `worktree-storage-io-rw`.

### Investigation findings (Pattern #14)

- The daemon's hot piece-write path does **NOT** go through `PieceStore.writePiece`. Peer-wire-to-disk pieces are submitted by `src/io/peer_policy.zig`'s direct `self.io.write` calls (callback `peer_handler.diskWriteCompleteFor`) using the shared fds from `PieceStore.fileHandles(...)`. `writePiece`/`readPiece` are reached only from the `varuna verify` CLI command (`recheckExistingData` / `recheckV2` in `src/storage/verify.zig`) and tests that drive the store directly. Both contexts spin up their own io ring and block on `io.tick` until completions land — the "submit + drain" shape is the correct semantic.
- `PieceIO` (the "lightweight piece I/O using pre-opened fds" wrapper) had zero callers anywhere in the repo. Removed alongside the unused `pwriteAll` / `preadAll` synchronous helpers.

## Last Verified Milestone (2026-04-27 — `{any}` formatter audit)

Systematic follow-up to the round-1 IPv6 persistence bug (commit `d340bc8`). Audited every `{any}` format specifier in the codebase to find other instances of the Zig 0.15.2 semantic drift (`{any}` no longer delegates to a type's `format` method; emits a generic struct dump instead).

23 production/test sites surveyed. Two bisectable commits, all green at HEAD.

- `377c216 session_manager: fix peer-list IP becoming a 642-byte struct dump` — **production bug**. `getTorrentPeers` formatted `peer.address` with `"{any}"` and shipped the result through the qBittorrent peer-list JSON `ip` field. For `std.net.Address` (an `extern union`) `{any}` produces a ~640-byte dump covering every overlapping field (`.any`, `.in`, `.in6`, `.un` with its 108-byte path) instead of `127.0.0.1`. Every peer reported via the WebAPI had a malformed `ip` field, breaking the qBittorrent web UI peer table since the Zig 0.15.2 upgrade. Same class as the round-1 persistence bug — different consumer (JSON vs. fixed-size buffer). New `formatPeerIp` helper + three regression tests asserting bare-IP form for IPv4/IPv6 and explicitly that the output contains no struct-dump tokens.
- `763c831 io,dht: replace {any} with {f} on std.net.Address log lines` — 10 log-only sites across `src/io/utp_handler.zig`, `src/io/event_loop.zig`, `src/dht/dht.zig`, `src/io/peer_policy.zig`. No correctness impact (log writers grow), but every smart-ban warning was a 700-byte multi-line dump that buried the real signal. After the fix, the same line reads `[event_loop] (warn): banning peer 10.0.0.6:0 (slot 5): trust_points=-8, hashfails=4`.

12 test-diagnostic sites left as-is — `{any}` on `anyerror` calls `printErrorSet` and emits `error.OutOfMemory` (not a struct dump), so those are benign.

`zig build`: clean. `zig fmt .`: clean. `zig build test`: green. See `progress-reports/2026-04-27-any-formatter-audit.md`.

Branch: `worktree-any-audit`.

## Last Verified Milestone (2026-04-27 — Dark inline test audit, rounds 2 + 3: net / tracker / rpc / runtime / sim / daemon)

Wired previously-dark inline `test "..."` blocks across the six
remaining subsystems (net, tracker, rpc, runtime, sim, daemon) into
`mod_tests` discovery. Surfaced two production bugs / safety fixes
plus one bit-rotted test, fixed under separately-labelled commits.

Eight bisectable commits, all green at HEAD. Test count:
**~1200 → 1385** (+185 inline tests now reachable; mix of net-new
discovery and previously-transitive coverage now pinned by explicit
`_ = file;` references).

- `c4aeb99 runtime/sim: wire dark inline tests through root.zig` —
  runtime (kernel/probe/requirements, 8 tests), sim (simulator,
  8 tests). All passed unmodified.
- `44dd55e tracker: wire dark inline tests through tracker/root.zig` —
  announce / scrape / udp (63 tests). One bit-rotted bencode length
  fixed (`scrape.zig` test had `7:denied` for the 6-byte string).
- `62730f0 net/ipfilter_parser: parse zero-padded eMule DAT IPv4
  octets` — **production bug**. `std.net.Address.parseIp4` rejects
  zero-padded segments (`001.009.096.105`) with `error.NonCanonical`,
  so every line of every real eMule DAT file silently failed to
  parse. ipfilter import was broken for the canonical eMule format
  the feature exists to consume. Added `parseDatIp4` that strips
  leading zeros per octet.
- `cad9c53 net: wire dark inline tests through net/root.zig` —
  14 files (ban_list, extensions, hash_exchange, ipfilter_parser,
  ledbat, metadata_fetch, peer_id, peer_wire, pex, smart_ban,
  socket, ut_metadata, utp, utp_manager). Excluded
  `bencode_scanner.zig` + `web_seed.zig` (owned by quick-wins-
  engineer this round). `address.zig` has no inline tests today.
- `a0bc7aa rpc: wire dark inline tests through rpc/root.zig` —
  8 files (auth, compat, handlers, json, multipart, scratch, server,
  sync; ~122 tests). One daemon test bit-rot fixed
  (`buildTrackerUrls includes effective tracker set with overrides`
  declared bencode lengths `18:`/`20:` for 19-byte URLs; the test
  was newly visible through rpc's transitive cascade and corrupted
  the test stack on iteration of the malformed announce_list).
- `0a57ab0 daemon/systemd: defend isListenSocketOnPort against
  negative fd` — **production safety fix**. Zig 0.15.2's
  `std.posix.getsockname` treats `EBADF` as `unreachable`, so
  `isListenSocketOnPort(-1, ...)` aborted with SIGABRT instead of
  returning false. A future caller that mishandled an empty
  socket-activation slot would have crashed the daemon at startup.
  Short-circuit on `fd < 0`.
- `43f4b91 daemon: wire dark inline tests through daemon/root.zig` —
  5 files (categories, queue_manager, session_manager, systemd,
  torrent_session; 28 tests). Round 1 noted daemon needed a
  separate opt-in via `daemon_exe.root_module`; in practice
  `mod_tests` reaches `daemon/root.zig` through the same import
  graph, so the standard `_ = daemon;` recipe works.

`zig build` (daemon): clean. `zig fmt .`: clean. `zig build test`:
green (1385/1385 with 1 deterministic skip;
`tests/sim_multi_source_eventloop_test.zig` `multi-source: 3 peers
all hold full piece, picker spreads load (8 seeds)` is flaky and
passes on rerun — pre-existing, not caused by this round). See
`progress-reports/2026-04-27-dark-test-audit-r2r3.md`.

Branch: `worktree-dark-test-r2r3`.

## Last Verified Milestone (2026-04-27 — Quick wins: 4 round-2/3 audit follow-ups closed)

Resolved the four short-tail audit follow-ups filed under round-2 and
round-3 untrusted-input audits:

- `61e8a17 krpc: rewrite skipValue with explicit container stack` —
  Task #4. Fixed-size container stack sized at `skip_max_depth = 64`.
  Structurally cannot blow the native call stack; satisfies STYLE.md's
  "no recursion" rule. 4096-deep regression test added.
- `89df10c bencode_scanner: rewrite skipValue with explicit container stack` —
  Task #10. Same shape applied to the BEP 10 / BEP 9 shared scanner
  (Pattern #17 audit-pattern-transfer). Hand-rolled container stack
  because Zig 0.15.2 does not expose `std.BoundedArray`. 1024+ deep
  regression test added.
- `5b63065 web_seed: reject multi-piece runs > maxInt(u32) bytes` —
  Task #5. Investigation (Pattern #14): `MultiPieceRange.length` is
  never read by the production handler and the rest of the pipeline
  is u32-byte-bounded throughout; entry-validation with
  `error.RunTooLarge` is the cleanest fix. Closes the misconfigured
  `web_seed_max_request_bytes = 8 GiB` daemon-crash vector.
- `7e13b8e protocol: regression test for BT PIECE block_index u16 cast` —
  Task #9. Two inline tests in `src/io/protocol.zig` pin the round-3
  fix at lines 166-178: `block_offset = 1 GiB` (exact pre-fix panic
  value) and `block_offset = maxInt(u32)` (absolute wire-field upper
  bound). No production code changes — round-1 dark-test audit
  unblocked source-side test discovery.

`zig build` (daemon): clean. `zig fmt .`: clean. `zig build test`:
green (1 pre-existing flaky sim-eventloop test unrelated; pinned to
the same baseline 812e104 produces). Test count: +5 (3 BUGGIFY
deeply-nested / runs-too-large + 2 protocol regression).

Branch: `worktree-quick-wins`. See `progress-reports/2026-04-27-quick-wins.md`.

## Last Verified Milestone (2026-04-27 — EpollIO / KqueueIO design survey, research-only)

Read-only research round: produced `docs/epoll-kqueue-design.md`, a survey of
what an `EpollIO` (Linux fallback under seccomp) and `KqueueIO` (macOS
developer build) backend would look like against the existing IO contract
(`src/io/io_interface.zig`). No source code modified.

Survey methodology:
- Read each contract op against libxev's `epoll.zig` / `kqueue.zig`, ZIO's
  `ev/backends/{epoll,kqueue}.zig` + `ev/loop.zig`, and tigerbeetle's
  `io/{linux,darwin}.zig`.
- Mapped each op to readiness-syscall, native-primitive, or thread-pool
  fallback, with semantic-gap callouts.
- Cross-checked DNS, SQLite, `PieceStore.init`, and background-thread
  ownership against the `AGENTS.md` io_uring policy to confirm no policy
  changes needed.

Headline recommendations:
- Heap-of-deadlines for `timeout` on both backends — copy libxev's
  no-EVFILT_TIMER / no-timerfd choice to avoid per-timer syscalls.
- Unconditional thread-pool offload for `read`/`write`/`fsync`/`fallocate`
  on both backends — readiness APIs cannot deliver completions for regular
  files (always-ready). Confirmed by ZIO's identical design.
- Build-time backend selection: `-Dio=io_uring|epoll|kqueue` with per-OS
  defaults. Daemon callers stay on `XOf(RealIO)` aliases unchanged.
- Effort estimate: ~1 work-week for minimum-viable EpollIO; ~1.5 for
  minimum-viable KqueueIO; ~1 calendar month to bring both to production
  parity (BUGGIFY-style fault tests, perf baselining).
- No contract signature changes required. `cancel` weakens to best-effort
  for thread-pool ops — already documented as best-effort.

`zig build`: not run (research-only, no source modified).
`zig fmt .`: clean (no Zig changed).

Branch: `worktree-epoll-research`. Document at `docs/epoll-kqueue-design.md`
(~3.1k words across 5 sections + open-questions appendix). Closes the queued
EpollIO/KqueueIO research task referenced from the 2026-04-27 storage-IO
follow-ups.

## Previously Verified Milestone (2026-04-27 — Dark inline test audit, round 1: io / storage / dht)

Wired previously-dark inline `test "..."` blocks across the three
mandatory subsystems (io, storage, dht) into `mod_tests` discovery.
Surfaced two real production bugs that had been silently shipping —
both fixed under separately-labelled commits.

Six bisectable commits, all green at HEAD. Test count:
**713 → ~1200** (+490 inline tests now reachable; transitive
discovery cascades through `_ = event_loop;` etc into net/rpc/tracker
files faster than the per-file audit anticipated).

- `255820a net/pex: fix port byte-order in CompactPeer.fromAddress` —
  PEX `added`/`dropped` lists carried byte-swapped ports because
  `ip4.port` (already in network byte order) was passed through
  `writeInt(.., .big)`, double-swapping on LE hosts. Receivers parsing
  our PEX would fail to connect to listed peers. Tests now assert
  the round trip.
- `89e4187 io: wire dark inline tests + clean up bit-rot` — wires 22
  io files; rewrites 7 tests for current production behavior; deletes
  one bit-rotted test (bitfield handler now requires `tc.session`).
- `e2ec92d tests: fix bit-rotted unit tests pulled in transitively
  by io wiring` — 4 inline tests across net/utp, net/utp_manager,
  rpc/auth, tracker/udp got pulled into discovery via
  io's `@import` chain. Each rewritten to track production semantics.
- `8635a30 storage: wire dark inline tests through storage/root.zig` —
  all 51 tests passed unmodified.
- `d340bc8 dht/persistence: fix IPv6 address formatting (was silently
  dropping nodes)` — `formatAddress` used `"{any}"` which in Zig
  0.15.2 is the generic struct-dump formatter, overflowing the 46-byte
  caller buffer. Every IPv6 node was dropped from routing-table
  snapshots. Switched to `"{f}"`.
- `46b4efc dht: wire dark inline tests through dht/root.zig` — 48/49
  tests pass unmodified; the one failure was the IPv6 formatter bug
  fixed above.

`zig build` (daemon): clean. `zig fmt .`: clean. `zig build test`:
green. See `progress-reports/2026-04-27-dark-test-audit.md`.

Branch: `worktree-dark-test-engineer`.

Mandatory subsystems complete. ~448 dark inline tests across 41 files
remain across `src/net/`, `src/tracker/`, `src/rpc/`, `src/runtime/`,
`src/sim/`, `src/daemon/` — see "Next > Testing" follow-ups below.

## Earlier Verified Milestone (2026-04-27 — Storage IO contract: fallocate + fsync via the contract)

Routed `src/storage/writer.zig`'s direct syscall paths through the IO
contract. `PieceStore.init`'s three `linux.fallocate` call sites and
the `PieceStore.sync` method now go through `self.io.fallocate` /
`self.io.fsync` — both BUGGIFY-injectable from SimIO and forward-
compatible with the queued EpollIO/KqueueIO research round.

Four bisectable commits, all green at HEAD. Test count: **704 → 713 (+9)**.

- `c1dba64` — `io: add fallocate op to contract; fault knobs for fallocate + fsync`. New `FallocateOp` + `Result.fallocate` variant on `io_interface.zig`. `RealIO.fallocate` wired to `IORING_OP_FALLOCATE` (kernel ≥5.6, well below varuna's floor). `SimIO.fallocate` schedules synchronous completion through the heap; new `FaultConfig.fallocate_error_probability` (delivers `error.NoSpaceLeft`) and `FaultConfig.fsync_error_probability` (delivers `error.InputOutput`).
- `fdd2b79` — `tests: SimIO algorithm tests for fallocate + fsync ops`. 5 tests in `tests/sim_socketpair_test.zig` covering success, fault probability 1.0, distribution sanity at 0.5, fsync fault, and `injectRandomFault` rewriting a fallocate result.
- `efced8e` — `storage: parameterise PieceStore over the IO backend`. `PieceStoreOf(comptime IO: type)` returning the existing struct; `PieceStore = PieceStoreOf(RealIO)` alias preserves the daemon surface. `init` takes `*IO`; `sync` drops its `*real_io.RealIO` parameter. Daemon callers (`app.zig`, `torrent_session.zig`, tests) updated to spin up one-shot RealIO rings or pass `&el.io`. ftruncate fallback preserved on `error.OperationNotSupported` (tmpfs <5.10, FAT32, FUSE).
- `b3ab4d5` — `tests: PieceStoreOf(SimIO) integration tests`. 4 tests in `tests/storage_writer_test.zig`: happy path, fallocate fault → init returns NoSpaceLeft, fsync fault → sync returns IoError, do_not_download skip path. New `test-storage-writer` step in `build.zig`.

`zig build` (full daemon binary): clean. `zig fmt .`: clean. `zig build test --summary all`: 88/88 steps, 713/713 passed. See `progress-reports/2026-04-27-storage-io-contract.md`.

Branch: `worktree-storage-io-engineer`.

## Previously Verified Milestone (2026-04-26 — Track 1: untrusted-input parser audit hunt round 3)

Round-3 follow-up to the round-1 KRPC hardening
(`worktree-krpc-hardening` / commit `3108167`). Audited five
peer-controlled parsers per the standdown brief: uTP wire codecs,
MSE handshake, HTTP/UDP tracker response, and BEP 9 metadata-fetch
network glue. Spot-checked adjacent code (`extensions.zig`,
`pex.zig`, `http_parse.zig`).

### Critical finding — every-peer-trivial daemon panic / stack overflow

`src/net/ut_metadata.zig:decode` (the BEP 9 ut_metadata extension
parser) was invoked from `src/io/protocol.zig:handleUtMetadata` for
every BEP 10 ut_metadata extension message a connected peer sends.
The inline `findDictEnd` / `skipByteString` / `skipBencodeValue`
helpers carried two of the same bug shapes round 1 fixed in DHT KRPC:

* `skipByteString` computed `idx + length` directly. A peer-controlled
  declared length of `maxInt(u64)` (the literal digit string
  `"18446744073709551615"`) parses successfully and overflows the
  addition, panicking "integer overflow" in safe builds.
* `skipBencodeValue` recursed without a depth bound. The BEP 10
  extension-message ceiling is 1 MiB
  (`peer_wire.max_message_length`), so a payload of `lll...l` would
  blow the native call stack.

Both reachable for *every* connected peer — same shape and reachability
as the round-1 BT PIECE crash. Dropped the hand-rolled helpers
entirely; replaced with a single `Scanner.skipValue()` over the
hardened `BencodeScanner` (already capped at 20-digit length prefixes,
21-char integer scans, and `max_depth = 64`).

### Defense-in-depth fix — uTP SACK decoder

`src/net/utp.zig:SelectiveAck.decode` accepted a peer-controlled
`len ∈ {36, 40, …, 252}` (multiple of 4, > 32) and panicked the
`@memcpy` into the 32-byte `bitmask`. Not currently peer-reachable
(uTP packets bypass the SACK extension chain — see "uTP extension
chain not consumed" follow-up above), but pinned now so it can't
regress when SACK parsing lands. New `sack_bitmask_max` constant
ties the array size and the input cap together.

### Subsystems audited and cleared

* uTP wire codecs (`src/net/utp.zig`, `src/net/utp_manager.zig`,
  `src/io/utp_handler.zig`) — header decode bounded; recv buffer
  is 1500 bytes so `data_len = @intCast(payload.len)` to u16 is
  safe.
* MSE handshake (`src/crypto/mse.zig`) — all `pad_b/c/d_len`,
  `ia_len`, `pad_c_len` are bounded before use; the
  `remaining_buf` and `ia_buf` arrays are sized to the bound. No
  findings.
* HTTP tracker announce/scrape (`src/tracker/announce.zig`,
  `src/tracker/scrape.zig`) — routes through hardened
  `bencode.parse` + `dictGet` + `expectU32/U64`. No findings.
* UDP tracker (`src/tracker/udp.zig`,
  `src/daemon/udp_tracker_executor.zig`) — fixed-size structured
  records with explicit length checks. `recv_buf[max_response_size = 4096]`
  bounds `n: usize = @intCast(cqe.res)`. No findings.
* BEP 9 metadata-fetch network glue (`src/net/metadata_fetch.zig`)
  — calls `ut_metadata.decode` (now hardened); `msg_buf[2 + meta_msg.data_offset ..]`
  is now bounds-safe via the hardened scanner. No further findings.
* BEP 10 extension handshake (`src/net/extensions.zig`) — already
  routes through the hardened scanner. No findings.
* ut_pex (`src/net/pex.zig`) — `bencode.parse` + bounded compact-peer
  arithmetic. No findings.

### Tests

New `tests/ut_metadata_buggify_test.zig` (17 tests) wired through
`zig build test-ut-metadata-buggify`:

* ut_metadata.decode random-byte fuzz: 32 seeds × 1024 random
  buffers (length 0..2048) = 32 768 panic-free probes.
* ut_metadata adversarial corpus (10 tests): the killer
  `maxInt(u64)` length-prefix; 21-digit length flood; 1024-deep `l`
  recursion attack; 65-deep `d` recursion attack; truncated input;
  negative msg_type / piece; out-of-u32 piece; non-dict top-level;
  request/reject/data round-trips with `data_offset` correctness.
* uTP SACK adversarial probe: every `len ∈ [0, 255]`. Killer
  inputs (36 and 252) pinned as named regression tests.
* uTP SACK roundtrip pinning: every legal `len` in `[4, 8, …, 32]`.
* uTP SACK random-byte fuzz: 32 seeds × 512 random buffers.

### One pre-existing bug surfaced

The previous `src/net/ut_metadata.zig:findDictEnd basic cases`
test asserted `findDictEnd("d1:ai1ee") == 12` for an 8-byte string.
The test was silently dark — the `src/net/` source-side test
hierarchy is the same one Task #7 has already filed. Replaced with
a `decode`-based test that exercises the same invariant through the
public surface, plus three adversarial-input regression tests.

### Test count

648 → 665 project tests (+17). All green at every commit on
`worktree-parser-audit-roundN`. `nix develop --command zig build test`
clean.

### Filed follow-ups (round 3)

* uTP extension chain not consumed in production
  (`src/net/utp_manager.zig:85`).
* uTP reorder buffer indexing mismatch + dangling-slice UAF
  (`src/net/utp.zig:667-689`).

### Commit chain (on `worktree-parser-audit-roundN`)

* `199a0b6 ut_metadata: harden BEP 9 parser via shared bencode_scanner`
* `76a7043 utp: bound SelectiveAck.decode len to bitmask capacity`
* `c026158 tests: BUGGIFY harness for ut_metadata parser + uTP SACK decoder`

Reference: `progress-reports/2026-04-26-audit-hunt-round3.md`.

## Last Verified Milestone (2026-04-29 — Executor genericization R1: HttpExecutor / UdpTrackerExecutor / AsyncMetadataFetch)

Closes the C2/C3 follow-ups from the external review. Four
bisectable commits, tests pass at every commit (pattern #8).

### EG1 — `HttpExecutorOf(comptime IO: type)` (commit `317d177`)

`src/io/http_executor.zig` was hardcoded to `io: *RealIO` despite
sitting alongside three already-generic state machines
(`AsyncRecheckOf`, `AsyncMetadataFetchOf`, `PieceStoreOf`). Wrapped
the struct in `pub fn HttpExecutorOf(comptime IO: type) type` with
`Self = @This()` inside; daemon-side `pub const HttpExecutor =
HttpExecutorOf(RealIO)` keeps every caller compiling unchanged.
Internal references switched from `*HttpExecutor` to `*Self`. The
existing two inline tests (`appendRecvData` target_buf paths) stayed
inside the struct and now compile under the alias.

### EG2 — `UdpTrackerExecutorOf(comptime IO: type)` (commit `be294b1`)

Same shape applied to `src/daemon/udp_tracker_executor.zig`. Daemon
alias `pub const UdpTrackerExecutor = UdpTrackerExecutorOf(RealIO)`
preserves the existing public surface (`SessionManager`, `EventLoop`,
`TorrentSession` callers all unchanged).

### EG3 — `AsyncMetadataFetch` socket lifecycle through IO contract (commit `55d4111`)

Replaced the synchronous `posix.socket()` in `connectPeer` with the
async `self.io.socket()` op + a new `metadataSocketComplete`
callback that chains the connect once the fd is available. Replaced
`posix.close()` in `releaseSlot` with `self.io.closeSocket()` so
SimIO can reclaim its socket-pool slots correctly. Added a new
`SlotState.socket_creating` between `.free` and `.connecting` to
gate `releaseSlot` idempotence (the existing `.free` check still
works because `state` is only set to `.socket_creating` after
successful submit; allocation failures roll back through the
existing buffer-OOM error path).

`socket_util.configurePeerSocket` is gated behind a comptime
`IO != SimIO` check because `posix.setsockopt` panics on BADF
(`unreachable`, not a returned error) when handed a SimIO synthetic
fd — `catch {}` doesn't catch a hard panic. Real backends still
get TCP_NODELAY / SNDBUF / RCVBUF tuning unchanged.

### EG4 — `AsyncMetadataFetchOf(SimIO)` happy-path integration test + SimIO scripted-recv extension (commit `ccb0df3`)

Added `enqueueSocketResult(fd)` and `pushSocketRecvBytes(fd, bytes)`
to `src/io/sim_io.zig` (~50 LOC). The first overrides the next
`socket()` op result so tests can wire the fetcher to a specific
`createSocketpair` half; the second is the scripted-peer mirror of
`setFileBytes`, appending bytes directly to a socket's recv queue
(with parked-recv wake-up if applicable). Both have crisp error
contracts (`InvalidFd`, `SocketClosed`, `RecvQueueFull`).

The new `tests/metadata_fetch_test.zig` test
"AsyncMetadataFetchOf(SimIO): happy-path scripted peer delivers
verified info dict" pre-loads three protocol responses onto the
fetcher's recv queue (BT handshake reply with the BEP 10 reserved
bit set; bencoded extension handshake advertising
`metadata_size`+`ut_metadata=2`; ut_metadata data response carrying
a 256-byte info dictionary), starts the fetch with one peer, drives
SimIO ticks, and asserts:
- callback fires with `result_bytes != null`
- `result_bytes.len == 256`
- first / last byte of result match the original info bytes (the
  SHA-1 verify path succeeded, otherwise `assembler.reset()` would
  have been called and `result_bytes` would be null)

Test count delta: 4 → 4 in `test-metadata-fetch` (the deferred
test landed alongside replacing the deferral comment).

### EG metrics
- 4 commits, all bisectable (pattern #8)
- 3 backends remain: io_uring, epoll_posix verified at every step
- 1552/1568 tests pass on full suite (15 skipped, ~1 flaky in
  unrelated UDP/uTP areas — pre-existing, runs 4-of-5 green)
- `test-metadata-fetch` passes 4/4 deterministically
- `progress-reports/2026-04-29-executor-genericization.md` for the
  full narrative

## Last Verified Milestone (2026-04-26 — Track 3: AsyncMetadataFetch IO-generic refactor)

Mirrors the Track B (AsyncRecheck) IO-generic refactor against the BEP 9
metadata fetch state machine (`src/io/metadata_handler.zig`). Two coherent
commits, tests pass at every commit (pattern #8). Test count: 689 → 692
(+3 `AsyncMetadataFetchOf(SimIO)` integration tests).

### 3A — `AsyncMetadataFetchOf(comptime IO: type)` (commit `69c9287`)

`src/io/metadata_handler.zig` defines `AsyncMetadataFetchOf(IO)` returning
the state machine struct. `pub const AsyncMetadataFetch = AsyncMetadataFetchOf(RealIO)`
preserves the daemon-side surface; daemon callers
(`src/daemon/torrent_session.zig`, `tests/metadata_fetch_shared_test.zig`)
stay unchanged. Method bodies use `self: *Self`; the three per-op
completion callbacks (`metadataConnectComplete`, `metadataSendComplete`,
`metadataRecvComplete`) dispatch through `*Self` so each instantiation
gets its own concrete type. Lazy method compilation (pattern #10) means
the `AsyncMetadataFetchOf(SimIO)` instantiation only forces methods
through the type-checker when a SimIO test actually drives them.
`EventLoopOf` declares `pub const AsyncMetadataFetch = metadata_handler.AsyncMetadataFetchOf(IO)`
so per-IO `metadata_fetch: ?*AsyncMetadataFetch`, `startMetadataFetch`'s
`on_complete` callback signature, and the `AsyncMetadataFetch.create`
call all reference the matching IO type.

No SimIO extension was needed: unlike the recheck refactor's `setFileBytes`
disk-read content registration, metadata fetch's I/O is bidirectional
network protocol. The integration tests below exercise error paths
through SimIO's existing connect / send / recv simulation.

### 3B — `AsyncMetadataFetchOf(SimIO)` integration tests (commit `478fa19`)

Three foundation tests in `tests/metadata_fetch_test.zig`:
- "no peers finishes immediately" — empty peer list. `start()` must call
  `finish(false)` synchronously; callback fires before any ticks.
- "connect-error fault drains all peers and finishes" — five peers (more
  than `max_slots = 3`) with `connect_error_probability = 1.0`. Drives
  the connect → fail → tryNextPeer refill loop. Asserts `peers_attempted == 5`.
- "legacy-fd send path causes all peers to fail" — three peers, no fault
  injection. `posix.socket()` returns a real kernel fd below SimIO's
  `socket_fd_base = 1000`, so SimIO's `slotForFd` returns null and `send`
  returns 0 → `onSendComplete` treats as failure → cleanup. Drives the
  connect → send → fail → next-peer cycle through three slots.

Together these prove `AsyncMetadataFetchOf(IO)` is real (not just
typechecks) and force compilation of every method that the state
machine traverses for connect / send / recv error handling.

The happy-path test (peer scripts a valid info dictionary, assembler
completes, `verifyAndComplete` fires) is filed as a follow-up in "Next"
— it requires either a refactor of `connectPeer`'s `posix.socket()` to
route through the IO interface, or a SimIO `setSocketRecvScript`-style
extension that scripts BEP 9 protocol responses on arbitrary fds. The
state machine's bidirectional protocol shape is substantively different
from the recheck refactor's one-way disk-read shape; `setFileBytes`
doesn't trivially port.

## Last Verified Milestone (2026-04-26 — Track B: AsyncRecheck IO-generic refactor)

Completes the post-Stage-2 IO abstraction migration for the recheck
state machine, which had escaped the original sweep. Three coherent
commits, tests pass at every commit (pattern #8). Test count: 620 → 631
(+11): 8 new SimIO `setFileBytes` algorithm tests in
`tests/sim_socketpair_test.zig` + 3 new `AsyncRecheckOf(SimIO)`
integration tests in `tests/recheck_test.zig`.

### B1 — `AsyncRecheckOf(comptime IO: type)` (commit `1394a20`)
`src/io/recheck.zig` defines `AsyncRecheckOf(IO)` returning the state
machine struct. `pub const AsyncRecheck = AsyncRecheckOf(RealIO)`
preserves the daemon-side surface; daemon callers
(`src/daemon/torrent_session.zig`, `tests/recheck_test.zig`) stay
unchanged. Method bodies use `self: *Self`; the per-completion
`ReadOp.parent` becomes `*Self` so each instantiation gets its own
concrete type. Lazy method compilation (pattern #10) means the
`AsyncRecheckOf(SimIO)` instantiation only forces a method body
through the type-checker when a SimIO test actually drives it.
`EventLoopOf` declares `pub const AsyncRecheck = recheck_mod.AsyncRecheckOf(IO)`
so per-IO `rechecks: std.ArrayList(*AsyncRecheck)`, `startRecheck`'s
`on_complete` callback signature, and the recheck list reset all
reference the matching IO type.

### B2 — `SimIO.setFileBytes(fd, bytes)` (commit `9ece885`)
Caller-owned content registration. `SimIO` keeps a
`std.AutoHashMap(posix.fd_t, []const u8)` and consults it in `read`:
when `fd` is registered, returns
`bytes[offset..][0..min(buf.len, len - offset)]`; otherwise falls
through to the legacy `usize=0` success path so unrelated tests see
no change. Fault injection still wins over registered content (a
`read_error_probability == 1.0` returns `error.InputOutput` even on
a registered fd). 8 algorithm tests in `tests/sim_socketpair_test.zig`
cover offset, short reads, post-end zero, per-fd isolation, replace,
and fault interaction.

### B3 — `AsyncRecheckOf(SimIO)` integration tests (commit `be76359`)
Three end-to-end tests in `tests/recheck_test.zig`:
- "all pieces verify against registered file content" — happy path
  (4-piece × 32-byte torrent, hash registered bytes, drive recheck,
  assert all 4 verify and bytes_complete matches).
- "corrupt piece is reported incomplete" — overwrite piece 2's
  content after hashing; assert p0/p1/p3 set, p2 unset.
- "all-known-complete fast path skips disk reads" — every bit set
  in known_complete, NO setFileBytes registration. Asserted "all
  4 complete" only holds if no reads fire.

These prove the parameterisation is real (not just typecheck) and
the SimIO read content path delivers correctly through the full
state machine. The follow-up live-pipeline BUGGIFY wrapper (per-tick
`injectRandomFault` + per-op `FaultConfig` × 32 seeds) is filed
as the next deliverable in "Next" — estimated 0.5-1 day now that
the refactor + setFileBytes are in place.

### Methodology

- **Pattern #15 (read existing invariants).** Mirrored the
  `EventLoopOf(IO)` / Stage 2 migration shape exactly — same
  `Self` substitution, same alias declaration, same per-IO nested
  type pattern. No new design decisions, just reapplied an existing
  one.
- **Pattern #10 (lazy method compilation).** Daemon-side callers
  stayed on the `AsyncRecheckOf(RealIO)` alias and didn't recompile
  their method bodies through the type-checker — only the SimIO
  test paths force the second instantiation, when those tests
  actually call into the state machine.
- **Pattern #14 (investigation discipline).** Discovered en route
  that `src/io/sim_io.zig`'s inline `test` blocks have been silently
  dark — `mod_tests` doesn't pull in the `io` subsystem (deliberate
  per `src/root.zig`'s opt-in test {}-block), and `addTest` against
  `tests/sim_socketpair_test.zig` only sees that file's tests. Did
  not chase the wider opt-in coverage — outside scope. Filed as a
  follow-up.
- **Pattern #8 (tests pass at every commit).** Three coherent
  commits, each compiling and passing the full suite. Bisectable.

### Follow-ups filed
- **Live-pipeline BUGGIFY harness for `AsyncRecheckOf(SimIO)`** — see
  the "Next" → operational subsection for the canonical shape.
  Estimated 0.5-1 day.
- **`src/io/sim_io.zig` inline tests are dark.** The wrapper at
  `tests/sim_socketpair_test.zig` (root for the `test-sim-io` step)
  doesn't pull in `sim_io.zig`'s own `test` blocks; the original 8
  inline tests + the `setFileBytes` ones I added would all sit dark
  if put inline. Worked around by putting the new tests directly in
  `tests/sim_socketpair_test.zig`, but the original 8 should
  ideally be wired too. Mechanical fix (adding `_ = sim_io;` works
  for namespace-side tests but `addTest` doesn't follow into
  package-boundary modules in Zig 0.15.2; either move the tests
  or add an explicit wrapper file).

## Last Verified Milestone (2026-04-26 — KRPC hardening round)

KRPC parser + DHT untrusted-input audit (`parser-engineer` Track A on the correctness-2026-04-26 team), with three real adversarial-input bug fixes beyond the encoder bug filed by the prior round. Fuzz harness extended.

### A1: KRPC encoder bounds checks (`dht: encoder bounds checks via Writer cursor`)
- All 8 KRPC encoders rerouted through a new `Writer` cursor (`src/dht/krpc.zig:340-410`). Every byte goes through a saturating-subtraction bounds check; the `EncodeError = error{NoSpaceLeft}` return type is now sound.
- Closes the bug filed by `progress-reports/2026-04-26-stage-4-and-buggify-exploration.md` ("KRPC encoders lack bounds checking, panic on too-small buffers").
- 9 new "encoder returns NoSpaceLeft on tiny buffers" contract tests cover every encoder.

### A2: Untrusted-input audit on `src/dht/`
Three real overflow / clamp bugs surfaced in the audit beyond the encoder finding:
- **`parseByteString` length-prefix overflow.** `i + len > data.len` overflowed `usize` for adversarial `len` near `maxInt(usize)` (panic in Debug, UB in Release). Replaced with saturating-subtraction form `len > data.len - i` and a 20-digit cap on the prefix scan.
- **`parseError` u32 clamp.** `@intCast(@max(code, 0))` panicked when an error response carried `code > maxInt(u32)`. Now clamps both ends.
- **`handleResponse` compact peer-list digit flood.** IPv4 / IPv6 peer-list parser had `dlen = dlen * 10 + d` and `vpos += dlen` with no bound — both overflowed `usize` on `999...:` prefixes. Refactored into a dedicated `parseCompactPeers` helper with a 5-digit cap and saturating remainder.
- One STYLE.md violation (`skipValue` recursive bencode parsing) deferred per pattern #14: bounded by UDP MTU in production, but a TCP-framed KRPC variant would expose it. Filed for explicit-stack rewrite (~1-2 hours).

### A3: Fuzz harness extended (`tests/dht_krpc_buggify_test.zig`)
+22 new tests bringing the bundle from 7 to 29 tests. Coverage adds: encoder NoSpaceLeft contract (9), parser length-prefix / integer-overflow / error-code clamp / pathological-string / type-confusion / off-by-one node-id / round-trip regression (7), token forgery fuzz (2), adversarial bencode-shaped envelope fuzz (1), compact peer-list adversarial inputs end-to-end through `DhtEngine.handleIncoming` (1), unsolicited-response and short-txn-id no-state-mutation tests (2).

### Track C — web seed BUGGIFY exploration (`tests/web_seed_buggify_test.zig`)
Small focused algorithm-layer fuzz harness for `WebSeedManager`. Coverage: state-machine random op sequences (assignPiece/markSuccess/markFailure/disable), `computePieceRanges` single- and multi-file with sum-to-piece-bytes invariant, `computeMultiPieceRanges`, URL-encoder over random bytes.
**One real bug surfaced**: `computeMultiPieceRanges` writes `length: u32` derived from a `u64` byte span — `@intCast` panics on runs > 4 GB. Production today bounded by `web_seed_max_request_bytes` (TOML config, default 4 MB) so the bug is reachable only by misconfiguration; filed as STATUS.md "Next". 7 new tests, wired at `test-web-seed-buggify`.

### Combined
**620 → 648 (+28)** tests passing across the suite. Detail in `progress-reports/2026-04-26-krpc-hardening.md`.

### Round-2 audit extension (continued from Track A)
The same audit pattern (saturating-subtraction bounds + digit caps + explicit recursion limits) generalised to three more peer-controlled parsing surfaces, surfacing **three additional production bugs**:
- **`src/torrent/bencode.zig:parseBytes`** had the same `i + len > data.len` overflow as the old `krpc.parseByteString` — adversarial metainfo / BEP 9 metadata payloads with `len` near `maxInt(usize)` panicked in safe mode. Fixed in-place: saturating-subtraction form + 20-digit prefix cap + 21-char `parseInteger` cap.
- **`src/net/bencode_scanner.zig`** (shared zero-alloc scanner used by BEP 10 + BEP 9): same `parseBytes` overflow + caps; plus an explicit `max_depth = 64` recursion bound on `skipValue` — the recursive form would blow the native call stack on hostile `dddd...` chains carried in extension messages (which can be ~1 MiB, far past UDP MTU). Defensive bound; explicit-stack rewrite filed similarly to `krpc.skipValue` (Task #4 shape).
- **`src/io/protocol.zig` BT PIECE handler**: `block_index: u16 = @intCast(block_offset / block_size)` panicked on peer-controlled `block_offset >= 1 GiB` (real DoS vector). Fixed in-place with a u32 → u16 range check before the cast.

Test count delta this round: **648 → 661 (+13)**: 3 inline in `bencode.zig` + 10 in the new `tests/bencode_scanner_buggify_test.zig` (parseBytes ×4, parseInteger ×2, skipValue ×3, random-byte fuzz ×1). Wired at `test-bencode-scanner-buggify`.

## Last Verified Milestone (2026-04-26 — followups-2 round)

Combined work from two parallel engineers: recheck-engineer closed three recheck-adjacent followups; explorer-engineer closed Zero-alloc Stage 4 plus a DHT BUGGIFY exploration that surfaced a real production bug.

### Recheck followups (recheck-engineer): A1 + A2 + A3
Three contained recheck-adjacent followups deferred from the prior post-Phase-2 + cleanup-engineer sessions.
- **Task A1 — Resume DB stale-entry pruning on recheck** (`state_db: replaceCompletePieces for atomic recheck pruning`).
  Added `ResumeDb.replaceCompletePieces(info_hash, indices)` — atomic delete-then-insert in a single `BEGIN IMMEDIATE` / `COMMIT` transaction. Both `onRecheckComplete` (stop+start) and `onLiveRecheckComplete` (live force-recheck Task B) now call it instead of additive `markCompleteBatch`. Closes the bug where pieces marked complete pre-recheck but found incomplete kept stale rows in the `pieces` table that would corrupt fast-resume on next daemon start. 4 inline tests for the method's edge cases (stale pruning, empty replacement, multi-info_hash isolation, idempotent no-change).
- **Task A2 — Surgical `in_progress` preservation across recheck** (`piece_tracker: surgical in_progress preservation across recheck`).
  `PieceTracker.applyRecheckResult` previously dropped ALL in_progress claims on recheck. Now applies a per-piece truth table: `new_in_progress[i] = old_in_progress[i] AND NOT new_complete[i]`. The "keep claim" branch (`was_in_progress` AND `now_complete=false`) is the optimization — when a peer is mid-downloading piece N and the recheck correctly finds N incomplete-on-disk (some blocks haven't flushed), the prior heavy clear forced re-claim and re-request of buffered blocks; the surgical update preserves the DP/buf state. The rare row-1 race (`was_in_progress` AND `now_complete=true`) drops in_progress; the orphaned DP cleans up via the normal `completePieceDownload` → `completePiece`-returns-false-as-duplicate flow. 4 truth-table tests + 1 mixed cross-product (replacing the prior heavy-clear test).
- **Task A3 — Safety harness for the recheck surfaces** (`recheck: 32-seed safety harness for A1+A2 surfaces`).
  `tests/recheck_buggify_test.zig` — a 32-seed randomized cross-product safety harness for both A1 + A2 surfaces. Per seed, randomize pre-recheck `complete` + `in_progress` bitfields, recheck-result bitfield, `piece_count` ∈ [4, 256], and info_hash. Drive the surfaces in production order; assert: storage `bits.ptr` stable, complete bits match recheck, in_progress matches surgical truth table, bytes_complete reflects recheck, resume DB pieces table = recheck result exactly, no leak, no panic. Vacuous-pass guards pin coverage at ≥28/32 seeds per branch; empirically all three surfaces saturate at 32/32. First run telemetry: `RECHECK BUGGIFY summary: 32 seeds, piece_count [13, 255], A2 preserved in 32/32, A2 race-dropped in 32/32, A1 pruned in 32/32; total 516 preserved blocks, 1076 stale rows pruned`. Wired at `test-recheck-buggify`.
- **A3 scope honesty.** The full-pipeline EL+SimIO BUGGIFY harness (per-tick `injectRandomFault` + per-op `FaultConfig` over 32 seeds at the live recheck pipeline) is blocked on `AsyncRecheck` being hard-coded to `*RealIO` (`src/io/recheck.zig:34`). Per pattern #14 (investigation discipline), filed the recheck-IO-generic refactor as a follow-up and shipped the algorithm-level cross-product harness now. The two surfaces are pure algorithmic — algorithm-level testing captures their full safety contract per the layered-testing-strategy "safety properties are fault-invariant" rule.

### Stage 4 + DHT BUGGIFY exploration (explorer-engineer)
- **Task B1 — Zero-alloc Stage 4: ut_metadata fetch buffer** (`zero-alloc: Stage 4 — pre-allocated ut_metadata fetch buffer`).
  EventLoop now owns one `[max_metadata_size]u8` buffer + one `[max_piece_count]bool` array (lazy-allocated on first `startMetadataFetch`, freed in `deinit`). `MetadataAssembler.initShared` routes through caller-owned storage with a panicking allocator vtable as a tripwire — the zero-alloc invariant is self-auditing under fuzz/BUGGIFY. `resetForNewFetch` cycles between fetches. The existing `metadata_fetch != null` invariant on EventLoop already serialises fetches across torrents (`event_loop.zig:1859`), so a single shared buffer suffices — multi-day savings from reading the existing invariant rather than designing a pool. 9 layered tests in `tests/metadata_fetch_shared_test.zig`.
- **Task B2 — BUGGIFY exploration: DHT KRPC + RoutingTable** (`dht: BUGGIFY fuzz coverage for KRPC parser + RoutingTable`).
  Added 7 fuzz/BUGGIFY tests in `tests/dht_krpc_buggify_test.zig`: random-byte fuzz of `krpc.parse` (32 seeds × 1024 packets), bit-flip mutation of valid ping queries, deeply-nested KRPC dict at UDP MTU, `decodeCompactNode` fuzz, RoutingTable adversarial flood with k-bucket invariant checks, and `findClosest` zero-buf safety.
- **Bug found**: KRPC encoders (`encodePingQuery`, etc.) take `buf: []u8` and return `!usize` implying error-on-overflow, but internal `writeByteString` (`krpc.zig:638`) and `writeInteger` (`krpc.zig:647`) write directly into the slice with no bounds checks. Calling any encoder with a too-small buffer panics in Debug, UB in Release. Currently safe in production (only caller uses MTU-sized buffer) but the API contract is unsound. Filed as Task #6/#7 for ~30 min mechanical fix.

### Combined test count
**599 → 624 (+25)** stable across full-suite runs. Broken down:
- Recheck round: +9 (A1: 4, A2: 3 net, A3: 2)
- Stage 4 + BUGGIFY: +16 (Stage 4: 9, KRPC BUGGIFY: 7)
- `zig build`: clean. `zig fmt`: clean.

Detail in `progress-reports/2026-04-26-recheck-followups.md` and `progress-reports/2026-04-26-stage-4-and-buggify-exploration.md`.

## Last Verified Milestone (2026-04-26 — followups round)

### Followups round (cleanup-engineer): app/config test discovery + live force-recheck
- **Task A — app/config source-side test discovery** (`src: enable app/config source-side test discovery`).
  Adding `_ = app; _ = config;` to `src/root.zig`'s test-context block surfaced 5 latent test bugs in code that had never been reached as test-context (Zig 0.15.2's "lazy-compile until reached as test-context" rule). The "comptime-eval error" the prior session diagnosed was actually three independent test bugs in `src/io/io_interface.zig` and `src/io/ring.zig`, plus 5 broken bencode literals in `src/storage/{writer,verify}.zig` (one trailing `e` past the close of the outer dict), plus 3 toml-parser `error_info` leaks in `src/config.zig`. Each fix is localised — no production code path changed.
- **Task B — live force-recheck via `loadPiecesForRecheck`** (`daemon: live force-recheck path via loadPiecesForRecheck`).
  `SessionManager.forceRecheck` now prefers an in-place rebuild of the `PieceTracker` bitfield over the heavyweight stop+start path. The live path (taken when state is downloading or seeding with a live EL torrent slot) calls `Session.loadPiecesForRecheck` to re-materialise the SHA-1 hash table when Phase 2 dropped it, submits an `AsyncRecheck` against the existing torrent_id, and on completion calls the new `PieceTracker.applyRecheckResult` to overwrite the existing `complete` Bitfield's bits in place — no reallocation, EL's `*const Bitfield` pointer stays valid. Stop+start remains the fallback for any other state (paused, stopped, error, checking, metadata_fetching).
- **Test count**: 531 → 599 (+68; Task A's `_ = app; _ = config;` pulled in +64 inline subsystem tests, Task B added 4 new tests — 3 algorithm + 1 EL integration). Stable across 3 back-to-back full-suite runs.
- `zig build`: clean. `zig fmt`: clean.

Detail in `progress-reports/2026-04-26-followups.md`.

## Last Verified Milestone (2026-04-26)

### Late-peer block-stealing (Task #23) — closes Phase 2A distribution race
- **Picker activation.** Block-stealing helper `DownloadingPiece.nextStealableBlock(exclude_peer_slot)` (committed at `0986cd2`, then dormant) is now active in two call sites:
  - `peer_policy.tryFillPipeline`: after the `markBlockRequested` loop exhausts unrequested blocks, fall back to issuing **duplicate REQUESTs** for blocks attributed to other peers, bounded by the same `per_call_cap = pipeline_depth / max_peers_per_piece`. The duplicate response decrements `peer.inflight_requests` unconditionally (`protocol.zig:170`); whoever arrives first wins attribution via `markBlockReceived`; the loser's data is discarded.
  - `peer_policy.tryJoinExistingPiece`: now accepts DPs with `unreq == 0` if they have at least one stealable block, ranked behind DPs with unique work via a `unreq * 2 + steal_present` score. The pre-existing bitfield gate `peer_bf.has(dp.piece_index)` is preserved — this is the smart-ban safety guard (without it, an honest peer could join a corrupt-only piece's DP, deliver canonical bytes that race against corrupt's bad data, and end up framed by `processHashResults`'s `result.slot` penalty when the mixed-buffer hash fails).
- **Closes the "3 peers at tick 0" multi-source race.** `tests/sim_multi_source_eventloop_test.zig`'s distribution-proportion assertions (`peers_with_uploads >= 2`, `max × 10 ≤ total × 9`) are now live; `multi_source_landed = true`. Steady-state distribution under both scenarios (concurrent connect, mid-piece disconnect) holds across all 8 seeds, single-piece × 4 MiB.
- **BUGGIFY safety holds: 96/96.** `tests/sim_smart_ban_eventloop_test.zig`'s 32-seed × p=0.02 fault-injection run still verifies all 96 honest-piece × seed pairs with zero honest hashfails. The previous activation attempt (mentioned in `0986cd2`'s message) regressed to 94/96 — the activation that landed here keeps the bitfield check intact at the join site, which was hypothesis #1 of the four filed at revert time and proved correct.
- **Perf bench unchanged.** `tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`: 3.39e6 / 3.46e6 / 3.56e6 ns over three back-to-back ReleaseFast runs; comfortably within the post-cache `3.4e6–4.3e6 ns` window. 0 allocs / 0 transient.
- **Test count**: 531 → 531 (no new tests; the activation re-uses existing scaffolding by flipping `multi_source_landed` and exercising the helper that was already shipped). All 531 pass; no leaks.
- See `progress-reports/2026-04-26-block-stealing.md` for the diagnostic trace and the four hypotheses' fates.

### Phase 2: multi-source piece assembly + smart-ban Phase 1-2 closure
- **Smart-ban Phase 2 discriminating power demonstrated end-to-end.** `tests/sim_smart_ban_phase12_eventloop_test.zig`'s `disconnect-rejoin one-corrupt-block` scenario over 8 seeds: peer 0 corrupts block 5 + delivers 8 blocks + disconnects mid-piece; survivors complete the piece (with peer 0's bad data already mixed in); first hash fails; re-download via survivors passes; `SmartBan.onPiecePassed` per-block compare identifies peer 0's address as the corruptor; ban applied to peer 0 only. Peers 1, 2 NOT banned despite contributing to the same failed piece. Result is `[true, false, false]` consistently across all 8 seeds; full-suite stable over 5 back-to-back runs.
- **Real production gap surfaced via test-first scaffolding.** Reading `peer_policy.snapshotAttributionForSmartBan` to validate the disconnect-rejoin scenario revealed that the snapshot was connection-state-aware: it dereferenced `peer_slot` at hash-result time, so a corrupt peer that disconnected before piece completion lost their attribution and escaped Phase 2 entirely. The fix (commit `371582d`): added `BlockInfo.delivered_address: ?std.net.Address` populated at `markBlockReceived` time, decoupled attribution lifetime from peer connection lifetime. Worked example of test-first methodology surfacing a production hole that wasn't visible from reading production code in isolation.
- **Adjacent gaps fixed during Phase 2A**: Gap 2 (commit `07f4093`) `.ghost`-state PendingSend storage closed pool slot reuse while Completion still in SimIO heap; Task #25 (commit `08161bc`) gates `completePieceDownload` on `self.draining` so residual late piece-block recvs during EL teardown drain don't trigger `submitVerify` against a winding-down hasher. Both also fixed latent flakiness in pre-existing `sim_swarm_test`.
- **Three new test files** matching the layered testing strategy:
  - `tests/sim_multi_source_protocol_test.zig` — algorithm test, 8 tests against bare `DownloadingPiece`. No EL/SimIO. Locks in the per-block attribution + multi-peer block reservation + release-on-disconnect invariants.
  - `tests/sim_multi_source_eventloop_test.zig` — integration test, 2 EL-driven scenarios live (piece-completes + safety; disconnect → survivors complete) plus the now-live distribution-proportion assertions (`peers_with_uploads >= 2`, `max × 10 ≤ total × 9`) ungated when Task #23 landed.
  - `tests/sim_smart_ban_phase12_eventloop_test.zig` — Phase 1-2 integration test, 4 tests live (3 sanity + disconnect-rejoin discriminating-power). Two scenarios (two-peer corruption, steady-state honest co-located) gated on Task #23.
- **Sim-test infrastructure extensions**: SimPeer gained `block_mask: ?[]const bool`, `Behavior.corrupt_blocks: { indices }`, `disconnect()` helper, `action_queue_capacity: 32 → 128`. EL gained `getBlockAttribution(torrent_id, piece_index, out)` accessor for live-DP per-block attribution. `runScenario` infrastructure with staged peer connect/disconnect via per-peer `add_at_tick` / `disconnect_at_tick` config.
- **Test count**: 218 → 223 (+5 net new; +16 raw across the three new files, with some restructured/renamed tests). Across the full IO-abstraction-through-Phase-2 arc: 163 → 223 = +60 tests.
- All 4 sim-engineer DoD items (Phase 0 + Phase 2A + Phase 2B + the simulation-first testing methodology) closed.
- `zig build test`: 223/223 pass, no leaks, stable over 5 back-to-back runs.
- `zig build`: clean.
- BUGGIFY (32 seeds, p=0.02) reproduces 23/32 banned + 96/96 honest pieces verified.

Detail in `progress-reports/2026-04-26-phase-2-smart-ban.md`.

## Last Verified Milestone (2026-04-25)

### Architecture / test infrastructure
- **IO abstraction landed end-to-end.** Daemon EventLoop is now generic over its IO backend: `pub fn EventLoopOf(comptime IO: type) type`. Two backends in production: `RealIO` (`linux.IoUring`, the only instantiation in `varuna`/`varuna-ctl`/`varuna-tools` — zero behaviour change) and `SimIO` (deterministic in-process simulation). Comptime parity enforced by `tests/io_backend_parity_test.zig`.
- **Stage 2 (event-loop migration to io_interface)** complete: every async op in the daemon — peer recv/send, outbound peer socket/connect, multishot accept, signal poll, recheck reads, disk reads/writes (including `PieceStore.sync`'s async fsync), HTTP executor, RPC server, metadata fetch, uTP recvmsg/sendmsg, UDP tracker, timerfd → native `io.timeout` — runs through the io_interface backend. Legacy `ring: linux.IoUring` field, the giant CQE dispatch switch, `OpType`/`OpData`/`encodeUserData`/`decodeUserData` all deleted.
- **Stages 3-5 (sim infrastructure + integration tests)** complete: `SimIO` socketpair pool with parking semantics; `SimulatorOf(comptime Driver)` deterministic harness; `SimPeer` with 10 wire-protocol behaviours (honest, slow, corrupt, wrong_data, silent_after, disconnect_after, lie_bitfield, greedy, lie_extensions); BUGGIFY (`SimIO.injectRandomFault` per-step + `FaultConfig` per-op) randomized fault injection; `SimIO.Config.max_ops_per_tick` runtime cap modelling real io_uring's CQE batch boundary.
- **Three layered smart-ban tests** (canonical demo of `STYLE.md > Layered Testing Strategy`):
  - `tests/sim_smart_ban_protocol_test.zig` — algorithm test, 8 seeds, no faults.
  - `tests/sim_smart_ban_eventloop_test.zig` (clean run) — integration test, real `EventLoopOf(SimIO)`, 8 seeds, no faults.
  - `tests/sim_smart_ban_eventloop_test.zig` (BUGGIFY run) — safety-under-faults test, 32 seeds with `recv/send_error_probability=0.003`, `read/write=0.001`, per-tick injection probability=0.02. Vacuous-pass guard demands ≥ half the seeds observe a real ban; empirically 23/32 ban + 96/96 honest pieces verify.
- **STYLE.md migration-pattern catalogue** at 13 entries: patterns 1-7 (Stage 2 lessons), 8-10 (single-coherent-commits, bench-companion, lazy-compilation-shipping), 11 (`@TypeOf(self.*).X` namespace access in anytype methods), 12 (`closeSocket` on the IO interface — fd-touching syscalls round-trip through the backend), 13 (`max_ops_per_tick` modelling kernel CQE batch boundaries). Plus the new "Layered Testing Strategy" top-level section codifying the algorithm/integration/safety-under-faults split.
- **Hasher cleanup race fix** (Task #16): `hasher.deinit` now frees valid `completed_results` bufs alongside invalid ones, so the daemon shutdown path is leak-clean even if processHashResults didn't drain results before EL teardown. The smart-ban EL test's drain phase remains as belt-and-suspenders.
- Test count: 163 → 204 (+41 across Stages 2-5 + cleanup; sim-engineer added the smart-ban EL + BUGGIFY tests, migration-engineer's #16 fix wired three pre-existing `event_loop_health_test.zig` tests into the main `test` step).
- All four sim-engineer DoD items closed: SimIO socketpair, Simulator runs `EventLoopOf(SimIO)`, smart-ban over 8 seeds, BUGGIFY over 32 seeds.
- `zig build test`: 204/204 pass, no leaks.
- `zig build`: clean.

### Perf benches (ReleaseFast, post-warm vs 2026-04-16 baselines)
- `peer_accept_burst --iterations=4000 --clients=1`: `~5.0e7 ns` (vs baseline `~6.91e8 ns`, **14× faster** — io_interface multishot path dropped most of the per-accept overhead). 1 alloc / 128 B (was 0/0 — minor regression in alloc count, transient).
- `seed_plaintext_burst --iterations=500 --scale=8`: `6.7e6 ns` to `8.7e6 ns` post-warm (vs baseline `6.79e6 ns` to `6.93e6 ns`, **stable to slightly variable**). 2 allocs / 704 B (matches baseline shape after PendingSend pool refactor in #12).
- `api_get_burst --iterations=4000 --clients=8`: `~6.5e7 ns` to `~7.0e7 ns` (vs baseline `2.13e8 ns` to `2.31e8 ns`, **3× faster**). 8000 allocs / 1.98 MB transient, all freed (peak_live = 1984 B). **Allocation count regressed from baseline `0/0`; tracked as Task #20.**
- `tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`: `~1.5e7 ns` post-warm (vs baseline `1.09e7 ns`, **~1.4× regression — under 2× threshold**). 0 allocs / 0 transient, matches baseline shape. **Tracked as Task #21.**

Conclusions: no `>2×` regressions; Stage 2 perf is clean for shipping. `peer_accept_burst` and `api_get_burst` are substantially faster than 2026-04-16 baselines — io_interface migration is a net perf win on the accept path and the RPC GET path. The 14× accept-burst speedup is suspiciously large for "we just changed dispatch shape" — hypothesis is that legacy dispatch had redundant accept-handling work that multishot consolidated; worth a focused profile pass post-Phase-2 to document. Two watch-items (api_get_burst alloc regression, tick_sparse_torrents 1.4× regression) filed as Tasks #20 / #21 for post-Phase-2 cleanup.

### Zero-alloc Stage 2: control-plane bump arena (Track B / runtime-engineer)
- **Spec**: `docs/zero-alloc-plan.md` Stage 2 — replace per-request `ArrayList(u8)` growth with a bounded bump arena reset between operations.
- **`src/rpc/scratch.zig`** (new module): two arenas, both bounded.
  - `RequestArena` — single fixed-size slab; `error.OutOfMemory` past the cap. Used for the tracker stack arena.
  - `TieredArena` — small slab fast path + transparent spill to the parent allocator under a single hard cap; `reset()` returns the slab bump pointer to zero AND walks the spill chain to free spilled allocations in one sweep. Used for the per-slot RPC arena.
- **`src/rpc/server.zig`** — per-`ApiClient` slot `TieredArena` pre-allocated at `init`/`initWithFd`/`initWithDevice` for all 64 slots: `request_arena_slab` = 256 KiB fast path + `request_arena_capacity` = 64 MiB hard cap. Total upfront slab footprint = 16 MiB. Reset between requests at `processBufferedRequest` entry — guaranteed safe because `handleSend` calls `releaseClientResponse` on send-complete *before* re-entering. Retained across slot reuse like `recv_buf`. Handler signature unchanged; the server passes the arena allocator instead of the parent. `releaseOwnedResponseBody` skips the parent free when the body lives in arena memory; `closeClient` retains the arena across slot reuse; `deinit` frees all per-slot arenas.
- **Embedded `recv_op` + `send_op` per ApiClient** (Pattern #1 in `STYLE.md`): replaces the per-recv/per-send `allocator.create(ClientOp)` from the post-Stage-2-#12 RealIO migration. Each slot has at most one in-flight recv and one in-flight send at a time, so static storage suffices; stale-completion filtering still works via the `gen` snapshot taken at submission. This is the change that closes Task #4 — the arena alone wasn't sufficient because the regression was on per-op tracker allocations, not handler-side.
- **Cap chosen for sync_delta-class workloads**: the plan suggested 8 MiB; `/sync/maindata` for 10K torrents has a transient peak of ~21 MiB (HashMaps + stats array + JSON growth). 64 MiB gives ~3× margin without making per-slot pre-allocation enormous. The two-tier design lets us pre-allocate only the 256 KiB fast path while keeping a hard upper bound on cumulative slab+spill.
- **`src/daemon/torrent_session.zig`** — `announceComplete` + `magnetHttpAnnounceComplete` parse the bencoded tracker response into a 64 KiB stack-allocated `FixedBufferAllocator`. Zero heap churn during announce parsing; oversize responses fail the announce attempt, tracker retried later. Bound covers ~10K compact-IPv4 peers + dict overhead, well past realistic responses.
- **Test count: 223 → 230** (`tests/rpc_arena_test.zig` adds 7 algorithm + integration + safety-under-fault tests; `src/rpc/scratch.zig` inline tests cover both arenas, 8/8 via direct `zig test`). No leaks across the suite under the GPA leak detector.
- **Bench deltas (`-Doptimize=ReleaseFast`):**
  - **`api_get_burst --iterations=4000 --clients=8`**: `8000 allocs / 1.98 MB` (post-Phase-2 baseline) → **`0 allocs / 0 bytes / 6.12e7 ns`** — pre-allocated per-slot arena + embedded ClientOp eliminates all parent-allocator calls in steady state. **Closes Task #4** (the post-Stage-2-#12 8000-alloc regression).
  - **`sync_delta --iterations=200 --torrents=10000`**: alloc calls `4,229,925` → `222,970` (−19×); bytes `4.27 GB` → `449 MB` (−9.5×); wall `3.13e10 ns` → `3.13e9 ns` (−10×). Remaining 222K allocs are `SyncState` snapshot HashMap (parent-allocator persistent state, not per-request transient).
  - `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`: unchanged (`8` allocs / `525 KB` / `2.86e7 ns`).
  - `sync_stats_live --iterations=1 --torrents=10000`: unchanged (`8` allocs / `4.5 MB` peak / `3.67e6 ns`).
- DHT tick-scoped arena, PEX per-peer encode buffer, and extension handshake stack-buffer encoder deferred (modest per-event churn; cross-module lifetime reasoning needed for the DHT case). Detail in `progress-reports/2026-04-26-zero-alloc-stage-2.md`.

### Task #5: tick_sparse_torrents 1.4× regression closed (Track B follow-up)
- **Root cause**: `peer_policy.checkPartialSeed` calls `PieceTracker.isPartialSeed` once per torrent per tick; `isPartialSeed` -> `wantedRemaining` -> `wantedCompletedCountLocked` was an O(piece_count) bitfield AND-loop. At 500 active torrents × 500 iterations, that's 250K calls × ~70 ns/call ≈ 17 ms per bench run, dominating wall time. NOT generic-dispatch overhead from `EventLoopOf(IO)` (the original hypothesis); machine code is identical between concrete `*EventLoop` and `anytype self` instantiations under ReleaseFast.
- **Fix** (`src/torrent/piece_tracker.zig`): cache `wanted_completed_count` on the tracker, maintained incrementally — `completePiece` increments it when the completed piece is wanted; `setWanted` / `swapWanted` recompute on mask transitions (cold path). `wantedCompletedCountLocked` becomes a one-line read.
- **Bench delta on `tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`**: `1.5e7–2.2e7 ns` (post-Stage-2 regression) → **`3.4e6–4.3e6 ns`** — **3× faster than the 2026-04-16 baseline `1.09e7 ns`**. Allocs unchanged: 0/0.
- **Isolated bench via diagnostic harness**: `isPartialSeed` per call 70.2 ns → 12.0 ns (5.8×); `checkPartialSeed` per torrent per iter 60.7 ns → 12.6 ns (4.8×).
- **Test count**: 230 → 233 (`tests/piece_tracker_cache_test.zig` adds three regression guards: complete-with-mask, mask-transition recompute, mask-removal recompute).

### Track C: BUGGIFY-against-RPC + cache invariant exploration (no bugs surfaced)
- **`tests/rpc_arena_buggify_test.zig`** (5 tests) — 64 seeds × random allocation sequences against `TieredArena`, with a custom `FailingAllocator` that rejects parent calls past a per-seed `fail_after` count. Each seed runs the same sequence twice — first to count parent calls, second with `fail_after` chosen randomly inside that range — deterministically exploring the OOM recovery path of `reset()` and `deinit()` chains. Asserts no leaks (GPA detector), no bump corruption, hard cap invariant, idempotent reset, partial-spill-chain deinit. 5/5 green.
- **`tests/piece_tracker_cache_buggify_test.zig`** (3 tests) — 64 seeds × random op sequences against the new `wanted_completed_count` cache. Assertion: `cached == |{ wanted ∩ complete }|` after every mutation, computed via direct bitfield intersection as the oracle. Op mix: 75% `completePiece`, 12.5% `setWanted` with random mask, 12.5% `swapWanted(null)`. Plus idempotent-completePiece and known-transition `setWanted`-to-subset-of-complete. 3/3 green.
- **`tests/rpc_server_stress_test.zig`** (2 tests) — integration stress against the real `ApiServer` on `RealIO`, 32 seeds × 4 random close-mid-flight strategies (`happy_path`, `close_mid_request`, `close_before_send_complete`, `close_immediately`), plus a rapid-reconnect test exercising the embedded `recv_op`/`send_op` generation filter under tight slot churn. Non-blocking client sockets to interleave server polls with client reads. 2/2 green.
- **No bugs surfaced** — both pieces of Track B/Task #5 work hold up under the randomised exploration. Test count: 233 → 243 (+10 across the three Track C files).

## Last Verified Milestone (2026-04-16)

- Demo swarm end-to-end with uTP enabled: `demo_swarm.sh` runs TCP+uTP, seeder-to-downloader transfer verified
- bpftrace audit: zero daemon networking syscalls bypass io_uring. All 75 "violations" were DNS threadpool `getaddrinfo` calls (allowed exception). Hot-path socket creation via IORING_OP_SOCKET (startup socket() count: 13 → 3).
- Web seed (BEP 19) e2e: 3 scenarios pass — 1MB/1-request (1s), 4MB/5-requests (1s), 8MB/17-requests (1s). Multi-piece batched Range requests with configurable `web_seed_max_request_bytes`.
- `varuna-tools create`: info hashes byte-identical to mktorrent. Parallel hashing: 100MB in 30ms (3.3 GB/s, 16 threads). Hybrid v1+v2 torrent creation (BEP 52). Node.js dependency eliminated.
- Transport disposition: runtime start/stop of TCP/UDP listeners via API, 25 integration tests.
- 71 qBittorrent API endpoints implemented (16 added this session).
- `zig build test`: all tests pass
- `zig build`: clean build
- `zig build -Doptimize=ReleaseFast perf-workload -- http_response --iterations=5000`: `1` alloc, `8 KB` transient bytes, `1.77e6 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_burst --iterations=4000 --clients=8`: `0` allocs, `0` transient bytes, `2.13e8 ns` to `2.31e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`: `8` allocs, `525 KB` retained bytes, `1.24e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_accept_burst --iterations=4000 --clients=1`: multishot listener `~6.91e8 ns` vs one-shot A/B baseline `~7.34e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_seq --iterations=4000 --clients=8`: keep-alive server `7.33e7 ns` / `7.92e7 ns` vs pre-change `2.41e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- mse_responder_prep --iterations=2000 --torrents=20000`: shared lookup `5.21e4 ns` / `3.57e4 ns` vs pre-change `1.02e9 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_http_fresh --iterations=2000`: `7.31e8 ns` / `7.04e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_http_reuse_potential --iterations=2000`: `2.83e8 ns` / `2.72e8 ns` (benchmark-only potential, not yet wired into production tracker flow)
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_announce_fresh --iterations=2000`: `8.49e8 ns` / `8.80e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_announce_executor --iterations=2000`: `4.28e8 ns` / `4.50e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`: `2.80e9 ns` -> `1.09e7 ns`, `0` allocs before and after
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_churn --iterations=5000 --peers=4096 --scale=128`: `1.13e9 ns` -> `3.81e6 ns`, `0` allocs before and after
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_delta --iterations=200 --torrents=10000`: `3.26e10 ns` -> `3.21e10 ns`, alloc calls `4,229,117` -> `4,228,317`
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_stats_live --iterations=1 --torrents=10000 --peers=1000 --scale=20`: `1.95e7 ns` -> `4.89e6 ns`, repeat `4.05e6 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_plaintext_burst --iterations=500 --scale=8`: `~2.73e7 ns` to `~3.04e7 ns` -> `6.79e6 ns` to `6.93e6 ns`, alloc calls `501` -> `2`, transient bytes `65.6 MB` -> `672 B`
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_send_copy_burst --iterations=200 --scale=8`: `5.40e7 ns` to `5.93e7 ns`, `200` allocs, `26.2 MB` transient bytes
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_sendmsg_burst --iterations=200 --scale=8`: `3.92e7 ns` to `4.55e7 ns`, `400` allocs, `72 KB` transient bytes
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_splice_burst --iterations=200 --scale=8`: `1.80e8 ns`, `0` allocs
- `zig build -Doptimize=ReleaseFast perf-workload -- utp_outbound_burst --iterations=200 --scale=64`: baseline surface only, `~8.13e7 ns` to `~1.10e8 ns` across runs; first queue cleanup pass removed allocs but did not show a stable latency win

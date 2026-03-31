# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

### Core Protocol
- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, piece/file layout mapping.
- HTTP, HTTPS, and UDP tracker announce (BEP 15) with compact peer lists, multi-tracker simultaneous announce (BEP 12). All tiers queried in parallel; first successful response wins. Async DNS resolution with TTL-based caching (`src/io/dns.zig`). Build-time configurable backend: threadpool (default) or c-ares (`-Ddns=c-ares`). HTTPS via vendored BoringSSL with BIO pair transport (all network I/O stays on io_uring); build-time configurable: `-Dtls=boringssl` (default) or `-Dtls=none`.
- Tracker scrape (HTTP + UDP): seeders/leechers/snatches queried every 30 minutes.
- Private tracker support: private flag parsing and enforcement (BEP 27). Per-session key, numwant, compact=1. PEX disabled for private torrents.
- IPv6 peer support (BEP 7): compact peers6, IPv6-aware connect.
- BEP 10 Extension Protocol: handshake negotiation, extension message dispatch, advertises ut_metadata and ut_pex (ut_pex omitted for private torrents). Extension handshake includes metadata_size (BEP 9).
- BEP 11 Peer Exchange (PEX): parse incoming ut_pex messages (added/dropped IPv4/IPv6 peers with flags), build and send outbound PEX messages every ~60s with delta encoding, connect to PEX-discovered peers through existing connection machinery, private torrent enforcement (PEX completely disabled).
- BEP 9 Magnet Links (ut_metadata): magnet URI parsing (hex + base32 info-hash, dn=, tr= params), metadata download from peers piece-by-piece with SHA-1 verification, metadata serving to peers via event loop, `metadata_fetching` state. CLI: `varuna-ctl add --magnet <uri>`. API: `urls=` param in `/api/v2/torrents/add`.
- BEP 9 Magnet Link Resilience (`src/net/metadata_fetch.zig`): multi-peer retry (try next peer on disconnect/timeout/reject), per-peer 30s socket timeout (SO_RCVTIMEO/SO_SNDTIMEO), overall 5-minute fetch timeout, peer deduplication, failed-peer retry with backoff (up to 3 attempts), DHT peer provider interface stub (`PeerProvider`), metadata fetch progress reporting (pieces received/total, peers attempted/active/with-metadata, elapsed time, error messages) exposed through `Stats` and API.
- uTP (BEP 29): packet codec, UtpSocket state machine, LEDBAT congestion control, UtpManager multiplexer, io_uring event loop integration (UDP socket, RECVMSG/SENDMSG, inbound and outbound connections, peer wire protocol bridge, timeout processing, retransmission buffer with owned payload tracking, RTO-based retransmission with exponential backoff, fast retransmit on triple duplicate ACK). 40+ tests.
- Multi-peer download: rarest-first piece selection, endgame mode, tit-for-tat choking, block pipelining (depth 5).
- Multi-peer seeding: io_uring event loop, batched block sends, async disk reads with piece cache.
- Selective file download: per-file priorities (normal/high/do_not_download), piece-mask filtering, boundary-piece handling, lazy file creation. Wired into daemon event loop piece picker.
- Sequential download mode: per-torrent toggle for streaming playback.
- MSE/PE (BEP 6): Message Stream Encryption with DH key exchange (768-bit prime), RC4 stream cipher with 1024-byte discard, SKEY identification from info-hash, crypto_provide/crypto_select negotiation, both initiator and responder roles, configurable modes (forced/preferred/enabled/disabled). Transparent encrypt/decrypt integrated into event loop send/recv paths. Async MSE handshake state machine (`MseInitiatorHandshake`/`MseResponderHandshake`) for non-blocking io_uring event loop integration. Auto-fallback: outbound "preferred" mode tries MSE then reconnects plaintext; inbound detects MSE vs BT by first-byte heuristic; per-peer `mse_rejected`/`mse_fallback` tracking prevents retry loops.
- Super-seeding (BEP 16): initial seed optimization. Sends HAVE messages instead of bitfield, tracks per-peer piece distribution, advertises rarest-first to maximize piece diversity. API toggle via `/api/v2/torrents/setSuperSeeding`.

### Architecture
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API, tracker HTTP through io_uring. Split into focused sub-modules: event_loop.zig (core), peer_handler.zig, protocol.zig, seed_handler.zig, peer_policy.zig, utp_handler.zig.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Shared multi-torrent event loop**: all torrents on one EventLoop thread with TorrentContext per torrent.
- **Shared announce ring**: tracker announces reuse a single ring instead of spawning per-announce threads.
- **Connection limits**: global (500), per-torrent (100), half-open (50). Announce jitter ±10% with initial stagger.
- **Reference codebases as git submodules**: libtorrent (arvidn), libtorrent-rakshasa, qBittorrent, rtorrent, vortex, qui (autobrr).
- **BoringSSL TLS**: vendored BoringSSL built as static libraries via pure Zig build (`build/boringssl.zig`). BIO pair transport decouples TLS record processing from socket I/O, keeping all network I/O on io_uring. TlsStream provides feedRecv/pendingSend interface for ciphertext shuttle.

### Storage & Resume
- SQLite resume state: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- Bundled SQLite option: `-Dsqlite=bundled` or `-Dsqlite=system`.
- Resume fast path: loads known-complete pieces from SQLite, skips SHA-1 rehashing.
- Lifetime transfer stats: total_uploaded/total_downloaded persisted to SQLite, loaded as baseline on startup so share ratio survives daemon restarts.
- Categories and tags persisted to SQLite (write-through on change, load at startup).
- Per-torrent rate limits persisted to SQLite (saved on change, loaded at startup).
- fdatasync, fallocate pre-allocation via io_uring.
- io_uring op coverage: shutdown, statx, renameat, unlinkat, send_zc, cancel, timeout, link_timeout, fixed buffers (READ_FIXED/WRITE_FIXED with registered buffer pool).

### Configuration
- TOML config file with daemon, storage, network, performance sections. XDG config path support.
- Bind interface (SO_BINDTODEVICE), bind address, port ranges (port_min/port_max).
- Download/upload speed limits (per-torrent + global), connection limits, hasher threads, pipeline depth.
- API credentials (api_username, api_password).
- Build options: `-Dsqlite=system|bundled`, `-Ddns=threadpool|c-ares`, `-Dtls=boringssl|none`.
- Peer ID masquerading: `network.masquerade_as` config option to identify as qBittorrent, rTorrent, uTorrent, Deluge, or Transmission. Useful for private trackers with client whitelists.

### API (qBittorrent v2 compatible)
- **Auth**: login/logout with session cookies (SID), 1-hour timeout, configurable credentials.
- **Core**: webapiVersion, version, buildInfo, preferences (40+ fields), setPreferences (form + JSON), transfer/info (with connection_status, dht_nodes), speedLimitsMode.
- **Torrents**: info (40+ fields matching qui Torrent interface), add (multipart + raw), delete, pause, resume, properties (30+ fields with hash, name, created_by), files (with index, availability, real piece_range), trackers (with msg field).
- **Controls**: filePrio, setSequentialDownload, setDownloadLimit, setUploadLimit, downloadLimit, uploadLimit, forceReannounce, recheck, setLocation, connDiagnostics.
- **Categories & Tags**: categories (create/edit/remove/list/setCategory), tags (create/delete/addTags/removeTags/list).
- **Sync**: /api/v2/sync/maindata delta protocol (rid-based, Wyhash change detection, 100-snapshot circular buffer), sync/torrentPeers with real peer data (IP, flags, progress, transfer stats, per-peer dl/ul speed, client name from peer ID).
- **Compatibility**: qBittorrent state strings (downloading/uploading/pausedDL/pausedUP/etc), CORS headers on all responses, OPTIONS preflight handler, magnet URI generation, percent-encoding, content_path building. Validated against qui (autobrr/qui) TypeScript interfaces.
- **Multipart form-data**: zero-copy parser for Flood/WebUI torrent uploads.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete (--delete-files), move, conn-diag, version, stats, speed limits (set/get), --username/--password auth.

### Daemon Features
- Graceful SIGINT/SIGTERM shutdown: flush resume DB, send tracker stopped, close connections.
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

### Performance & Hardening
- **SHA-1 hardware acceleration**: runtime CPU detection for x86_64 SHA-NI (~2x to ~2.2 GB/s) and AArch64 SHA1 crypto extensions. Atomic-cached dispatch, automatic fallback to software.
- popcount bitfield counting, inline message buffers (16-byte for small messages).
- Idle peers list (O(k) not O(4096)), HashMap pending_writes (O(1) not O(n)).
- claimPiece scan hint + min_availability for faster rarest-first selection.
- Hasher TOCTOU fix (atomic drainResultsInto), proper drain loop, endgame duplicate write skip.
- timeout_pending tracking, write error checking in handleDiskWrite, error logging for silent catches.
- io_uring send buffer UAF fix: split free-one vs free-all pending sends, stale-CQE guards, SQE-submit-failure fix.
- EventLoop deinit UAF fix: phased shutdown (close fds, drain CQEs, then free buffers) prevents GPA debug-poison UAF.
- IORING_OP_CLOSE for hot-path fd cleanup in RPC server.
- Session use-after-free fix: RPC handlers copy data under mutex instead of holding raw session pointers.
- Shared event loop lifetime hardening: pause/stop/resume now detach torrents from the shared EventLoop before freeing runtime state, and resume preserves daemon/shared-loop integration.
- Tracker background-worker hardening: session teardown now waits for both announce and scrape workers, and announce/scrape serialize access to the shared announce ring.
- Hasher OOM resilience: free piece buffer and log on result append failure.
- JSON injection prevention: escape helper for all user-provided strings in API responses.
- Partial send buffer matching: monotonic send_id in CQE context to match correct in-flight buffer.
- RPC server partial-send handling: API responses now track send progress until the full body is written.
- Seed/read-path correctness: queued seed responses own exact block copies, async seed reads use unique IDs, and only successfully submitted reads/writes contribute to pending completion counts.
- **Huge page piece cache**: optional `mmap(MAP_HUGETLB)` buffer pool for seed piece reads. Falls back to `madvise(MADV_HUGEPAGE)` (transparent huge pages), then regular pages. Config: `performance.use_huge_pages`, `performance.piece_cache_size`. Reduces TLB pressure for large torrents.

### BEP 52 (BitTorrent v2 / Hybrid Torrents)
- Torrent version detection: v1/v2/hybrid based on `pieces` vs `file tree` field presence.
- v2 file tree parser (`src/torrent/file_tree.zig`): recursive walk of nested bencode dictionaries, empty-string leaf markers, `pieces root` extraction.
- SHA-256 Merkle tree (`src/torrent/merkle.zig`): tree construction from piece hashes, root computation, per-piece verification, Merkle proof generation and verification, power-of-2 padding with zero-hashes.
- v2 info-hash calculation (`src/torrent/info_hash.zig`): SHA-256 of bencoded info dict using `std.crypto.hash.sha2.Sha256` (hardware-accelerated).
- Extended `Metainfo` struct: `version`, `info_hash_v2`, `file_tree_v2` fields. Pure v2 torrents populate v1 `files` array from file tree for backward compatibility.
- File-aligned piece layout (`src/torrent/layout.zig`): v2 pieces never cross file boundaries, each file has its own piece range, `mapPieceV2` always returns single-file spans.
- Dual-hash verification (`src/storage/verify.zig`): `PiecePlan.hash_type` selects SHA-1 or SHA-256, `verifyPieceBuffer` supports both.
- Hasher thread pool SHA-256 support (`src/io/hasher.zig`): `Job.hash_type` field, worker function dispatches to SHA-1 or SHA-256.
- Dual info-hash handshake matching (`src/io/peer_handler.zig`, `src/io/utp_handler.zig`): inbound and outbound peers matched on v1 or truncated v2 info-hash for hybrid torrents.
- `TorrentContext.info_hash_v2` field: truncated 20-byte v2 hash stored per-torrent in the event loop for handshake matching.
- Tracker announce v2 info-hash (`src/tracker/announce.zig`): `Request.info_hash_v2` field adds a second `info_hash` parameter with truncated v2 hash for v2-aware trackers.
- Resume DB v2 info-hash (`src/storage/resume.zig`): `info_hash_v2` table stores the full 32-byte SHA-256 hash, `saveInfoHashV2`/`loadInfoHashV2` methods.
- `TorrentSession.info_hash_v2` field: v2 hash propagated from metainfo to session, persisted to and loaded from resume DB, passed in all announce calls.
- BEP 52 hash exchange wire protocol (`src/net/hash_exchange.zig`): `hash request` (msg 21), `hashes` (msg 22), `hash reject` (msg 23) message encode/decode. Merkle proof building from tree. Integrated into `src/io/protocol.zig` message dispatch.
- Runtime Merkle tree cache (`src/torrent/merkle_cache.zig`): per-file Merkle tree cache with LRU eviction (`TorrentContext.merkle_cache`). Trees built lazily on first hash request via async hasher threadpool (no event loop blocking). No piece-count limit (removed previous 4096-piece cap). Multiple peers requesting the same file's tree are coalesced into a single build job. Pending requests cleaned up on peer disconnect. Cache validated against `pieces_root` from torrent metadata. Protocol handler (`handleHashRequest` in `src/io/protocol.zig`) serves hashes from cache or submits async build. 11 merkle cache tests, 2 async hasher merkle tests.

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

### Testing
- 19 peer wire protocol tests, 10 BEP 10 extension tests, 15 PEX tests, 31 uTP/LEDBAT tests, 5 categories tests, 9 resume DB tests, 25 MSE/RC4 tests, 13 magnet URI tests, 13 ut_metadata tests, 12 metadata fetch resilience tests.
- 13 async MSE state machine tests (initiator phases, responder phases, VC scan limit, fallback, first-byte detection).
- Bencode fuzz + edge case tests, HTTP parser fuzz tests.
- Fuzz tests for: multipart parser, tracker response, uTP packets, BEP 10 extensions, scrape response (18 fuzz tests total).
- Regression tests for API partial-send progress, unique seed read IDs, seed block-copy batching, shared-event-loop detach on stop, shared-loop preservation on resume, and failed disk-write release.
- 10 io_uring Ring tests: pread/pwrite roundtrip, short reads, probe, shutdown, statx, renameat, unlinkat, cancel, timeout, link_timeout, send_zc, fixed buffer roundtrip.
- Transfer test matrix: 24 tests (1KB-100MB, 16KB/64KB/256KB pieces, multi-file torrents). All pass.
- Daemon swarm integration test, daemon-to-peer seeding test, selective download integration test.
- SHA-1 benchmarks: std vs SHA-NI vs direct vs memory bandwidth baseline.
- Profiling workflow: strace, perf, bpftrace build helpers.
- Adversarial peer tests (35 tests): oversized messages, invalid IDs, wrong lengths, malformed handshake, unrequested pieces, OOB piece indices, garbage extension bencode, bitfield bounds, connection limit sanity.
- Private tracker simulation tests (25 tests): required announce fields (compact, numwant, key, event), per-session key generation, private flag enforcement (no ut_pex), tracker error responses (failure reason, missing fields, invalid formats, negative interval), compact peer parsing.
- Soak test framework (`zig build soak-test`): multi-torrent piece tracker stress, allocator leak detection (GPA), FD leak monitoring, tick latency tracking, bitfield stress cycles.
- 5 super-seed (BEP 16) tests, 2 multi-announce tests, 5 huge page cache tests.
- BEP 52 tests: 11 Merkle tree tests, 8 file tree parser tests, 7 v2 metainfo tests, 4 v2 layout tests, 1 v2 info-hash test, 8 hash exchange tests, 2 v2 announce URL tests, 2 v2 resume DB tests, 11 Merkle cache tests, 2 async Merkle hasher tests.
- DHT tests: 7 node_id tests, 8 routing_table tests, 8 krpc tests, 8 token tests, 7 lookup tests, 5 dht_engine tests, 1 persistence test (44 total).
- 10 peer ID client identification tests (Azureus-style, Shadow-style, Mainline, unknown).
- 17 peer ID masquerading tests: all 5 client formats, case insensitivity, malformed input, unsupported client error, random suffix validation.
- 4 TLS tests: TlsStream init/deinit, ClientHello generation, garbage ciphertext handling, stub error returns. 3 HTTPS URL parsing tests.

## Next

### Protocol
- ~~**uTP outbound connections**~~: (DONE) outbound uTP connections, retransmission buffer, RTO retransmission.
- ~~**PEX (BEP 11)**~~: (DONE) peer exchange via BEP 10 extensions, delta encoding, private torrent enforcement.
- ~~**DHT (BEP 5)**~~: (DONE) trackerless peer discovery — Phases 1-3 (core protocol, active lookups, announce and persistence).
- **DHT Phase 4**: rate limiting outbound queries, IPv6 support (BEP 32), fuzz tests for incoming KRPC messages.
- ~~**Magnet links (BEP 9)**~~: (DONE) metadata download via ut_metadata extension.
- ~~**Magnet link resilience**~~: (DONE) multi-peer retry with per-peer/overall timeouts, DHT peer provider interface stub, metadata fetch progress reporting via Stats/API.
- ~~**MSE encryption (BEP 6)**~~: (DONE) message stream encryption/obfuscation.
- ~~**BEP 52 Phase 4**~~: (DONE) peer wire handshake dual info-hash matching, tracker announce with v2 info-hash, resume DB v2 info-hash column, TorrentSession v2 hash propagation.
- ~~**BEP 52 Phase 5**~~: (DONE) hash request/hashes/hash reject message encode/decode, Merkle proof building from tree, protocol handler integration.
- ~~**BEP 52 Phase 6**~~: (DONE) runtime Merkle tree caching for hash serving. Per-file trees built lazily from disk, LRU eviction, `handleHashRequest` serves real hashes.

### Operational
- ~~**Flood/qui WebUI validation**~~: (DONE) populated remaining stub fields (tracker URL, trackers_count, piece_range, content_path, magnet_uri, super_seeding, properties hash/name/created_by), added real peer data to torrentPeers endpoint.

## Known Issues

- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- uTP send queue previously truncated data packets to header-only size (fixed).

## Last Verified Milestone

- HTTPS tracker support via vendored BoringSSL (BIO pair + io_uring transport)
- DHT (BEP 5) Phases 1-3
- BEP 52 (BitTorrent v2 / Hybrid) Phases 1-6 (including runtime Merkle tree cache)
- MSE/PE (BEP 6) async handshake + auto-fallback
- All protocol features merged, all API stubs populated
- `zig build test`: all tests pass
- `zig build`: clean build (with `-Dtls=boringssl` default and `-Dtls=none`)

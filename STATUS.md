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
- Partial seeds (BEP 21): `upload_only` extension in BEP 10 handshake. Parse and store `upload_only` flag from peers. Advertise `upload_only: 1` when we are a partial seed (selective download complete but torrent incomplete). Automatic partial seed detection from piece tracker. Skip piece assignment when upload_only. Re-send extension handshake to all peers on state transition. Exposed in API (torrentPeers, properties, maindata).

### Architecture
- **Single-threaded io_uring event loop**: all peer I/O, disk I/O, HTTP API, tracker HTTP through io_uring. Split into focused sub-modules: event_loop.zig (core), peer_handler.zig, protocol.zig, seed_handler.zig, peer_policy.zig, utp_handler.zig.
- **3-binary architecture**: `varuna` (daemon), `varuna-ctl` (CLI client), `varuna-tools` (standalone utilities).
- **Shared multi-torrent event loop**: all torrents on one EventLoop thread with TorrentContext per torrent.
- **Dynamic shared-torrent registry**: the shared EventLoop now uses dynamic slot storage, free-list reuse, `u32` torrent IDs, and hashed info-hash lookup instead of the old fixed 64-slot table.
- **Shared announce ring**: tracker announces reuse a single ring instead of spawning per-announce threads.
- **Connection limits**: global (500), per-torrent (100), half-open (50). Announce jitter ±10% with initial stagger.
- **Peer listener multishot accept**: the shared `EventLoop` listener now uses `accept_multishot` and only re-arms when the kernel ends the multishot stream.
- **API vectored-send path**: the HTTP API server now sends headers and body as separate iovecs through `io_uring` `sendmsg` instead of concatenating them into one response buffer first.
- **API listener multishot accept**: the RPC server now keeps one `accept_multishot` armed and uses inline per-client request storage for the common short-request case instead of heap-allocating an `8 KiB` receive buffer up front.
- **Reference codebases as git submodules**: libtorrent (arvidn), libtorrent-rakshasa, qBittorrent, rtorrent, vortex, qui (autobrr).
- **BoringSSL TLS**: vendored BoringSSL built as static libraries via pure Zig build (`build/boringssl.zig`). BIO pair transport decouples TLS record processing from socket I/O, keeping all network I/O on io_uring. TlsStream provides feedRecv/pendingSend interface for ciphertext shuttle.

### Storage & Resume
- SQLite resume state: WAL mode, prepared statements, background thread. Daemon persists completions every ~5s.
- Bundled SQLite option: `-Dsqlite=bundled` or `-Dsqlite=system`.
- Resume fast path: loads known-complete pieces from SQLite, skips SHA-1 rehashing.
- Session-owned metadata arena: `Session.load` now allocates torrent bytes, metainfo, layout, and manifest from one arena and frees them as a unit on session teardown.
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
- Build options: `-Dsqlite=system|bundled`, `-Ddns=threadpool|c-ares`, `-Dtls=boringssl|none`, `-Dcrypto=varuna|stdlib|boringssl`.
- Configurable crypto backend (`-Dcrypto`): `varuna` (default, SHA-1 with runtime SHA-NI/AArch64 hardware detection), `stdlib` (Zig std.crypto), `boringssl` (vendored BoringSSL SHA/RC4). Unified dispatch via `src/crypto/backend.zig`. Build-time validation prevents `-Dcrypto=boringssl` when `-Dtls=none`.
- Peer ID masquerading: `network.masquerade_as` config option to identify as qBittorrent, rTorrent, uTorrent, Deluge, or Transmission. Useful for private trackers with client whitelists.

### API (qBittorrent v2 compatible)
- **Auth**: login/logout with session cookies (SID), 1-hour timeout, configurable credentials.
- **Core**: webapiVersion, version, buildInfo, preferences (40+ fields), setPreferences (form + JSON), transfer/info (with connection_status, real DHT node count from routing table), speedLimitsMode.
- **Torrents**: info (40+ fields matching qui Torrent interface, real infohash_v2 for BEP 52 torrents), add (multipart + raw), delete, pause, resume, properties (30+ fields with hash, name, created_by, creation_date, scrape-based peers_total/seeds_total, v2 info-hash, completion_date), files (with index, availability, real piece_range), trackers (with msg field).
- **Controls**: filePrio, setSequentialDownload, setDownloadLimit, setUploadLimit, downloadLimit, uploadLimit, forceReannounce, recheck, setLocation, connDiagnostics, setShareLimits.
- **Categories & Tags**: categories (create/edit/remove/list/setCategory), tags (create/delete/addTags/removeTags/list).
- **Sync**: /api/v2/sync/maindata delta protocol (rid-based, Wyhash change detection, 100-snapshot circular buffer, real DHT node count in server_state, infohash_v2 in torrent objects), sync/torrentPeers with real peer data (IP, flags, progress, transfer stats, per-peer dl/ul speed, client name from peer ID).
- **Compatibility**: qBittorrent state strings (downloading/uploading/pausedDL/pausedUP/etc), CORS headers on all responses, OPTIONS preflight handler, magnet URI generation, percent-encoding, content_path building, HTTP 404 for unknown API paths. Validated against qui (autobrr/qui) TypeScript interfaces. See [docs/api-compatibility.md](docs/api-compatibility.md) for full endpoint coverage and known placeholder fields.
- **Multipart form-data**: zero-copy parser for Flood/WebUI torrent uploads.
- **Tracker editing**: add, remove, and edit tracker URLs per-torrent via API and CLI. User overrides persisted to SQLite `tracker_overrides` table, loaded on startup. Overrides applied on top of metainfo announce-list. Re-announce triggered on add/edit. qBittorrent-compatible endpoints: `addTrackers`, `removeTrackers`, `editTracker`.
- **varuna-ctl**: list, add (--save-path), pause, resume, delete (--delete-files), move, conn-diag, add-tracker, remove-tracker, edit-tracker, version, stats, speed limits (set/get), --username/--password auth.

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
- Tracker background-worker hardening: session teardown now waits for both announce and scrape workers, and announce/scrape serialize access to the shared announce ring.
- Hasher OOM resilience: free piece buffer and log on result append failure.
- JSON injection prevention: escape helper for all user-provided strings in API responses.
- Partial send buffer matching: monotonic send_id in CQE context to match correct in-flight buffer.
- RPC server partial-send handling: API responses now track send progress until the full body is written.
- Seed/read-path correctness: queued seed responses own exact block copies, async seed reads use unique IDs, and only successfully submitted reads/writes contribute to pending completion counts.
- **Huge page piece cache**: optional `mmap(MAP_HUGETLB)` buffer pool for seed piece reads. Falls back to `madvise(MADV_HUGEPAGE)` (transparent huge pages), then regular pages. Config: `performance.use_huge_pages`, `performance.piece_cache_size`. Reduces TLB pressure for large torrents.
- **Synthetic memory baseline harness**: `varuna-perf` with allocator-counting scenarios for peer scans, request batching, seed batching, extension parsing, session loading, and `/sync/maindata`. Supports stable before/after comparisons without a live swarm.
- **Synthetic API burst harness**: `varuna-perf` now includes `api_get_burst` and `api_upload_burst`, which drive the real RPC server over loopback sockets with configurable client concurrency and upload body size.
- **Synthetic peer accept harness**: `varuna-perf` now includes `peer_accept_burst`, which drives the real shared `EventLoop` listener with inbound loopback TCP connects and measures accept-slot-recv-EOF teardown cost.
- **First allocation-reduction pass**: request batches now avoid heap allocation, seed batching no longer heap-copies each queued block, `/sync/maindata` uses fixed-size snapshot keys plus a request arena, BEP 9/BEP 10 decode paths are allocation-free, and scan-heavy peer-policy paths use dense active-slot lists.

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
- 19 peer wire protocol tests, 16 BEP 10 extension tests (including 6 BEP 21 upload_only tests), 15 PEX tests, 31 uTP/LEDBAT tests, 5 categories tests, 10 resume DB tests, 25 MSE/RC4 tests, 13 magnet URI tests, 13 ut_metadata tests, 12 metadata fetch resilience tests.
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
- 5 super-seed (BEP 16) tests, 4 partial seed (BEP 21) tests, 2 multi-announce tests, 5 huge page cache tests.
- BEP 52 tests: 11 Merkle tree tests, 8 file tree parser tests, 7 v2 metainfo tests, 4 v2 layout tests, 1 v2 info-hash test, 8 hash exchange tests, 2 v2 announce URL tests, 2 v2 resume DB tests, 11 Merkle cache tests, 2 async Merkle hasher tests.
- DHT tests: 7 node_id tests, 8 routing_table tests, 8 krpc tests, 8 token tests, 7 lookup tests, 5 dht_engine tests, 1 persistence test (44 total).
- 4 tracker override persistence tests (add/load, edit with orig_url, remove/clear, per-torrent isolation).
- 10 peer ID client identification tests (Azureus-style, Shadow-style, Mainline, unknown).
- 17 peer ID masquerading tests: all 5 client formats, case insensitivity, malformed input, unsupported client error, random suffix validation.
- 4 TLS tests: TlsStream init/deinit, ClientHello generation, garbage ciphertext handling, stub error returns. 3 HTTPS URL parsing tests.
- 10 queue manager tests: position management, remove/compact, move to top/bottom, increase/decrease priority, boundary no-ops, disabled queue, enforcement with limits. 1 compat test for queued state mapping.

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
- ~~**API placeholder cleanup**~~: (DONE) wired real DHT node count into transfer/info and sync/maindata, wired real infohash_v2 (BEP 52) into torrent info/properties/sync, wired scrape data into properties peers_total/seeds_total, parsed creation_date from .torrent files. Documented unsupported endpoints in `docs/api-compatibility.md`.
- ~~**API keep-alive for polling**~~: (DONE) HTTP/1.1 clients now stay connected across sequential requests, and the server keeps buffered leftovers instead of forcing one request per socket.
- ~~**Shared MSE responder lookup**~~: (DONE) inbound encrypted handshakes now consult a shared `req2 -> info_hash` table instead of copying and scanning all torrent hashes per peer.
- ~~**Shared tracker executor / connection reuse**~~: (DONE) daemon-side reannounce, completion announce, and scrape jobs now run through one shared tracker executor with a persistent HTTP client instead of detached per-session tracker threads.
- **Peer hot/cold split / partial SoA**: the active-slot pass removes a lot of wasted scans, but the `Peer` struct is still wide. The next performance step is separating hot scheduling/state fields from cold crypto/buffering state.
- **Torrent hot-summary registry**: cached cumulative byte totals now remove the hottest `/sync` stats scan, but a denser registry is still the next step if queue position, state derivation, or other per-torrent fields dominate at `10k+` torrents.
- **Broader RPC arena coverage**: `/sync/maindata` now uses an arena for transient work; the other list-heavy endpoints still allocate temporary object graphs and strings.
- **API request-body growth / reuse**: the short-request path now uses inline storage, but large request bodies still allocate on demand and are freed on disconnect. A per-client arena or reuse pool is still available if API uploads remain allocator-heavy.
- **Seed plaintext scatter/gather**: benchmark-only syscall comparison now shows plain vectored `sendmsg` is promising, but the production path still needs explicit piece-buffer ownership before it can replace the current copy-based send path.
- **uTP outbound queueing**: the UDP path still has room for a ring queue and multiple in-flight sends if uTP becomes hot in real swarms.
- **uTP multishot receive**: `recvmsg_multishot` plus a provided-buffer strategy still needs a workload and a measured implementation before it should land.
- **Tracker work on the shared peer ring**: the daemon now shares tracker I/O through one executor, but the executor still owns its own ring. Moving tracker work onto the shared peer `EventLoop` ring requires an async tracker state machine rather than the current synchronous HTTP helper.

## Known Issues

- The packaged Ubuntu `opentracker` build requires explicit info-hash whitelisting (`--whitelist-hash`).
- On WSL2, the real `perf` backend works for `perf stat` and `perf record`, but many hardware counters still report `<not supported>`.
- uTP send queue previously truncated data packets to header-only size (fixed).
- On this WSL2 host, `perf stat` and `perf record` still require the kernel-matched `linux-tools-6.6.87.2-microsoft-standard-WSL2` package. `cachegrind` is the current cache-miss fallback.
- The `peer_scan` harness is now parameterized by active density (`--scale`), but the production peer table is still a wide AoS. Sparse synthetic scans are measurable; a full hot/cold split is still pending.
- The shared EventLoop no longer has a 64-torrent cap, and the sparse peer/torrent registry pass removed the main cross-product scans. Cached live byte totals further reduced `/sync` stats cost, but a broader hot-summary registry may still be needed for `10k+` torrents.
- The first outbound uTP queue cleanup experiment removed allocator churn but did not show a convincing wall-clock improvement on the loopback workload, so it was not kept in production.
- The seed upload comparison pass found a real benchmark win for vectored `sendmsg`, but no production change is landed yet because queued piece buffers do not currently have a lifetime model that is safe across async send CQEs.
- `splice` / sendfile-style upload is currently a poor fit for BitTorrent framing and multi-file spans. The benchmark prototype was slower than both contiguous copy and `sendmsg`.

## Last Verified Milestone

- HTTPS tracker support via vendored BoringSSL (BIO pair + io_uring transport)
- DHT (BEP 5) Phases 1-3
- BEP 52 (BitTorrent v2 / Hybrid) Phases 1-6 (including runtime Merkle tree cache)
- MSE/PE (BEP 6) async handshake + auto-fallback
- All protocol features merged, API placeholder values replaced with real data where available
- `zig build test`: all tests pass
- Shared EventLoop registry validated with `20,000` active torrent contexts and hashed inbound lookup
- `zig build`: clean build (with `-Dtls=boringssl` default and `-Dtls=none`)
- `zig build -Doptimize=ReleaseFast perf-workload -- http_response --iterations=5000`: `5,001` allocs, `648 KB` transient bytes, `4.63e7 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- session_load --iterations=1000`: `2,004` allocs, `1.33e7 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_burst --iterations=4000 --clients=8`: `4,000` allocs, `512 KB` transient bytes, `~2.20e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`: `2,000` allocs, `65.8 MB` transient bytes, `~1.26e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_accept_burst --iterations=4000 --clients=1`: multishot listener `~6.91e8 ns` vs one-shot A/B baseline `~7.34e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_seq --iterations=4000 --clients=8`: keep-alive server `9.56e7 ns` / `8.71e7 ns` vs pre-change `2.41e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- mse_responder_prep --iterations=2000 --torrents=20000`: shared lookup `5.21e4 ns` / `3.57e4 ns` vs pre-change `1.02e9 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_http_fresh --iterations=2000`: `7.31e8 ns` / `7.04e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_http_reuse_potential --iterations=2000`: `2.83e8 ns` / `2.72e8 ns` (benchmark-only potential, not yet wired into production tracker flow)
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_announce_fresh --iterations=2000`: `8.49e8 ns` / `8.80e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tracker_announce_executor --iterations=2000`: `4.28e8 ns` / `4.50e8 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`: `2.80e9 ns` -> `1.09e7 ns`, `0` allocs before and after
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_churn --iterations=5000 --peers=4096 --scale=128`: `1.13e9 ns` -> `3.81e6 ns`, `0` allocs before and after
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_delta --iterations=200 --torrents=10000`: `3.26e10 ns` -> `3.21e10 ns`, alloc calls `4,229,117` -> `4,228,317`
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_stats_live --iterations=1 --torrents=10000 --peers=1000 --scale=20`: `1.95e7 ns` -> `4.89e6 ns`, repeat `4.05e6 ns`
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_plaintext_burst --iterations=500 --scale=8`: `~2.73e7 ns` to `~3.04e7 ns`, `501` allocs, `65.6 MB` transient bytes
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_send_copy_burst --iterations=200 --scale=8`: `5.40e7 ns` to `5.93e7 ns`, `200` allocs, `26.2 MB` transient bytes
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_sendmsg_burst --iterations=200 --scale=8`: `3.92e7 ns` to `4.55e7 ns`, `400` allocs, `72 KB` transient bytes
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_splice_burst --iterations=200 --scale=8`: `1.80e8 ns`, `0` allocs
- `zig build -Doptimize=ReleaseFast perf-workload -- utp_outbound_burst --iterations=200 --scale=64`: baseline surface only, `~8.13e7 ns` to `~1.10e8 ns` across runs; first queue cleanup pass removed allocs but did not show a stable latency win

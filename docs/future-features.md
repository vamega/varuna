# Future Features

Features to implement eventually, tracked here for reference. Not prioritized for immediate work.

## 0. ~~Blocking Call Removal~~ (DONE)

Seed async pread is implemented via `IORING_OP_READ` with piece cache and batched block sends.

## 1. ~~systemd-notify support~~ (DONE)

Implemented in `src/daemon/systemd.zig`. Sends `READY=1` after API server is listening and `STOPPING=1` on shutdown. Uses standard POSIX `AF_UNIX`/`SOCK_DGRAM` socket (one-time setup, not hot path). No libsystemd dependency. Supports both filesystem and abstract (`@`-prefixed) sockets.

## 2. ~~SHA-NI and hardware-accelerated SHA-1~~ (DONE)

Implemented in `src/crypto/sha1.zig` with runtime CPU detection and multi-architecture support:

- **x86_64 SHA-NI**: `sha1rnds4`, `sha1nexte`, `sha1msg1`, `sha1msg2` via inline assembly. Runtime detection via CPUID (leaf 7 for SHA, leaf 1 for SSE4.1).
- **AArch64 SHA1 Crypto Extensions**: `sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0`, `sha1su1` via inline assembly. Runtime detection via `getauxval(AT_HWCAP)` checking `HWCAP_SHA1`.
- **Software fallback**: Same algorithm as `std.crypto.hash.Sha1` for CPUs without hardware support.

Detection runs once on first use, result cached in `std.atomic.Value`. A binary compiled on a generic x86_64 target (without `-Dcpu=native`) will still use SHA-NI when run on a capable CPU.

All `std.crypto.hash.Sha1` usages in the codebase replaced with `src/crypto/sha1.zig`.

Note: Zig std lib SHA-256 already has SHA-NI acceleration. SHA-256 for BEP 52 (BitTorrent v2) would use std lib directly.

## 3. ~~uTP support (BEP 29)~~ (Protocol layer DONE, event loop integration TODO)

Core protocol implemented in `src/net/utp.zig`, `src/net/ledbat.zig`, `src/net/utp_manager.zig`:
- Packet header encoding/decoding (20-byte BEP 29 header, all 5 packet types)
- Selective ACK extension
- UtpSocket connection state machine (IDLE -> SYN_SENT/SYN_RECV -> CONNECTED -> FIN_SENT/CLOSED/RESET)
- Three-way handshake (SYN, SYN-ACK, data)
- LEDBAT congestion control (delay-based, 100ms target, slow start + congestion avoidance)
- RTT estimation with Karn's algorithm
- Receive reorder buffer for out-of-order packets
- UtpManager multiplexer: routes packets by connection_id, accept queue for inbound connections

**All integration items completed:**
- ~~Register UDP socket with io_uring event loop (`IORING_OP_RECVMSG` / `IORING_OP_SENDMSG`)~~ DONE
- ~~Add `utp_recv` / `utp_send` OpType variants to event_loop.zig~~ DONE
- ~~Wire UtpManager into PeerState so uTP and TCP peers coexist in the same session~~ DONE
- ~~Outbound retransmission buffer with actual payload tracking~~ DONE
- ~~Timer integration for RTO-based retransmission~~ DONE
- ~~Outbound uTP connections (connect, handshake, peer wire bridge)~~ DONE

## 4. ~~SO_BINDTODEVICE support~~ (DONE)

Implemented in `src/net/socket.zig`. Applied to peer listen socket, outbound peer sockets, and API server socket. Also added `bind_address` for IP-level binding and port range support (`port_min`/`port_max`).

Config:
```toml
[network]
bind_device = "wg0"       # restrict to this interface
bind_address = "10.0.0.1"  # bind to specific IP
port_min = 6881            # port range start
port_max = 6889            # port range end
```

## 5. ~~systemd socket activation~~ (DONE)

Implemented in `src/daemon/systemd.zig`. Checks `$LISTEN_FDS` and `$LISTEN_PID` at startup per sd_listen_fds(3). If present, uses fd 3+ instead of creating listen sockets. Supports multiple inherited fds (first for API server, second for peer listener). Sets FD_CLOEXEC on inherited fds. Integrated into daemon startup in `src/main.zig` and `src/rpc/server.zig` (initWithFd).

## 6. UDP tracker support (BEP 15)

Many real-world trackers are UDP-only. Our HTTP-only tracker client can't reach them. This is a significant gap for real-world usability.

Protocol: connect (transaction_id exchange) -> announce -> scrape. All UDP datagrams.
Uses `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` for io_uring integration.

## 7. DHT (BEP 5) and PEX (BEP 11)

Distributed Hash Table for trackerless peer discovery. Peer Exchange for discovering peers through existing connections. Both essential for public torrents.

See [dht-bep52-plan.md](dht-bep52-plan.md) for the detailed implementation plan covering DHT module layout, routing table design, KRPC protocol, io_uring integration, and phasing.

## 7a. ~~BEP 52 (BitTorrent v2 / Hybrid Torrents)~~ -- Phase 1-5 DONE

All phases implemented:
- **Phase 1-3**: version detection (v1/v2/hybrid), v2 file tree parsing (`src/torrent/file_tree.zig`), SHA-256 Merkle tree (`src/torrent/merkle.zig`), v2 info-hash calculation, file-aligned piece layout, dual-hash verification (SHA-1/SHA-256), hasher thread pool SHA-256 support.
- **Phase 4**: peer wire handshake dual info-hash matching (`src/io/peer_handler.zig`, `src/io/event_loop.zig`), tracker announce with v2 info-hash (`src/tracker/announce.zig`), resume DB schema for v2 info-hash (`src/storage/resume.zig`), BEP 52 v2 reserved bit in handshake (`src/net/peer_wire.zig`).
- **Phase 5**: hash request/hashes/hash reject message exchange (`src/net/hash_exchange.zig`), Merkle proof exchange (`src/io/protocol.zig`), per-file Merkle tree cache (`src/torrent/merkle_cache.zig`), per-file Merkle root verification for multi-piece v2 files (`src/storage/verify.zig`).

See [dht-bep52-plan.md](dht-bep52-plan.md) for the full plan.

## 8. ~~Magnet links (BEP 9)~~ (DONE)

Download torrent metadata from peers via the extension protocol. Implemented: magnet URI parsing, metadata download via ut_metadata, metadata serving to peers, CLI and API support. Remaining: parallel piece requests, trackerless magnet support (needs DHT).

## 9. ~~Encryption (BEP 6 / MSE)~~ (DONE)

Implemented in `src/crypto/mse.zig` and `src/crypto/rc4.zig`:

- **DH key exchange**: 768-bit prime from BEP 6, custom big-integer arithmetic (U768), modular exponentiation
- **RC4 stream cipher**: KSA + PRGA, 1024-byte discard per BEP 6
- **SKEY identification**: HASH('req1', S), HASH('req2', SKEY) ^ HASH('req3', S) pattern
- **Crypto negotiation**: crypto_provide/crypto_select bitmask, supports plaintext (0x01) and RC4 (0x02)
- **Both roles**: initiator (outbound) and responder (inbound) handshake implementations
- **Configurable modes**: forced (RC4 only), preferred (RC4 > plaintext), enabled (both), disabled (plaintext only)
- **Event loop integration**: transparent encrypt/decrypt in peer_handler.zig recv path, protocol.zig and seed_handler.zig send paths
- **API**: encryption mode exposed via qBittorrent-compatible preferences endpoint

Config:
```toml
[network]
encryption = "preferred"  # forced, preferred, enabled, disabled
```

Remaining work for full production readiness:
- Async MSE handshake state machine in the event loop (currently has blocking Ring-based handshake for tools)
- Automatic MSE fallback: try encrypted first, fall back to plaintext on failure
- Connection-level MSE initiation before BT handshake in the event loop connect flow

## DHT Improvements

### Done

- ~~**Persist routing table to SQLite**~~: Saves to `~/.local/share/varuna/dht.db` on shutdown, loads on startup. Warm table skips bootstrap entirely.
- ~~**Parallel bootstrap**~~: Two parallel `find_node` lookups (own ID + random) with full K=8 fan-out. Cold bootstrap completes in ~1 second.
- ~~**`forceRequery` on torrent integration**~~: Fixes race where DHT peers were found before the torrent was registered in the event loop.

### Remaining

- **Seed from PEX-discovered nodes**: when PEX messages arrive with DHT port info, add those nodes to the routing table immediately.
- **Bootstrap from connected peers**: after BT handshake, if the peer sent a PORT message (BEP 5), ping that node as a bootstrap entry.
- **Pull-based peer delivery model**: Switch DHT from a push-based global queue to a pull/callback model (like libtorrent) where the torrent initiates its own DHT search and receives peers via callback. This would eliminate the `forceRequery` workaround. Low priority — the current approach is functionally correct. See [dht-callback-model.md](dht-callback-model.md) for full analysis.

## API Compatibility

See [api-compatibility.md](api-compatibility.md) for the full qBittorrent WebAPI compatibility matrix, including which endpoints are implemented, which return placeholder data, and which are explicitly unsupported or deferred.

## Will Not Implement

### Time-based alternative speed scheduling

qBittorrent offers an "alt speed" scheduler that automatically switches between normal and reduced speed limits based on time of day. Varuna will not implement this. Users who need scheduled rate changes should use external tooling (e.g., `cron` + `varuna-ctl setDownloadLimit`/`setUploadLimit`) to adjust limits at desired times. This keeps the daemon simpler and avoids embedding a scheduler for a feature that cron handles better.

### Watch folder auto-add

Monitoring a directory for new `.torrent` files and auto-adding them is out of scope for the varuna daemon. This functionality should be implemented as a separate lightweight daemon that watches the folder and uses the varuna API (`/api/v2/torrents/add`) to add torrents. Tools like `inotifywait` + a shell script, or a purpose-built sidecar, are better suited for this than embedding filesystem watching into the torrent daemon.

### RSS feed auto-download

Monitoring RSS feeds for new torrents (e.g., for TV show automation) is out of scope for the varuna daemon. This should be a separate daemon/service that polls RSS feeds, filters entries, and uses the varuna API to add matching torrents. Keeping RSS parsing, feed scheduling, and filter rule management out of the torrent daemon avoids unnecessary complexity and allows users to choose their preferred RSS tooling.

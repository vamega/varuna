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

## 5. systemd socket activation

Let systemd manage the listen socket and pass it to the daemon via file descriptor inheritance. Allows:
- Zero-downtime restarts (systemd holds the socket while daemon restarts)
- On-demand daemon startup (systemd starts daemon when first connection arrives)
- Consistent socket ownership and permissions

Implementation: check `$LISTEN_FDS` and `$LISTEN_PID` environment variables at startup. If present, use fd 3+ instead of creating our own listen socket.

Reference: https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html

## 6. UDP tracker support (BEP 15)

Many real-world trackers are UDP-only. Our HTTP-only tracker client can't reach them. This is a significant gap for real-world usability.

Protocol: connect (transaction_id exchange) -> announce -> scrape. All UDP datagrams.
Uses `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` for io_uring integration.

## 7. DHT (BEP 5) and PEX (BEP 11)

Distributed Hash Table for trackerless peer discovery. Peer Exchange for discovering peers through existing connections. Both essential for public torrents.

See [dht-bep52-plan.md](dht-bep52-plan.md) for the detailed implementation plan covering DHT module layout, routing table design, KRPC protocol, io_uring integration, and phasing.

## 7a. BEP 52 (BitTorrent v2 / Hybrid Torrents)

Per-file Merkle tree piece verification (SHA-256), v2 info-hash, file-aligned pieces, and hybrid torrent support. See [dht-bep52-plan.md](dht-bep52-plan.md) for the full plan.

## 8. Magnet links (BEP 9)

Download torrent metadata from peers via the extension protocol. Most users interact with magnet links, not .torrent files.

## 9. Encryption (BEP 6 / MSE)

Message Stream Encryption for obfuscating BitTorrent traffic. Required by some private trackers and useful for avoiding ISP throttling.

## Will Not Implement

### Time-based alternative speed scheduling

qBittorrent offers an "alt speed" scheduler that automatically switches between normal and reduced speed limits based on time of day. Varuna will not implement this. Users who need scheduled rate changes should use external tooling (e.g., `cron` + `varuna-ctl setDownloadLimit`/`setUploadLimit`) to adjust limits at desired times. This keeps the daemon simpler and avoids embedding a scheduler for a feature that cron handles better.

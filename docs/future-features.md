# Future Features

Features to implement eventually, tracked here for reference. Not prioritized for immediate work.

## 0. ~~Blocking Call Removal~~ (DONE)

Seed async pread is implemented via `IORING_OP_READ` with piece cache and batched block sends.

## 1. ~~systemd-notify support~~ (DONE)

Implemented in `src/daemon/systemd.zig`. Sends `READY=1` after API server is listening and `STOPPING=1` on shutdown. Uses standard POSIX `AF_UNIX`/`SOCK_DGRAM` socket (one-time setup, not hot path). No libsystemd dependency. Supports both filesystem and abstract (`@`-prefixed) sockets.

## 2. ~~SHA-NI and hardware-accelerated SHA-1~~ (DONE)

Implemented in `src/crypto/sha1.zig`. Uses x86_64 SHA-NI instructions (`sha1rnds4`, `sha1nexte`, `sha1msg1`, `sha1msg2`) via Zig inline assembly when compiled for a CPU with SHA-NI support. Falls back to software SHA-1 (same algorithm as `std.crypto.hash.Sha1`) on CPUs without SHA-NI.

Benchmark results (ReleaseFast, 256KB pieces): std = ~1,075 MB/s vs SHA-NI = ~2,145 MB/s (2x speedup). Detection is comptime via `builtin.cpu.has(.x86, .sha)`, which is automatically enabled when building on a machine with SHA-NI (Zig's default target uses native CPU features).

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

**Remaining work for full integration:**
- Register UDP socket with io_uring event loop (`IORING_OP_RECVMSG` / `IORING_OP_SENDMSG`)
- Add `utp_recv` / `utp_send` OpType variants to event_loop.zig
- Wire UtpManager into PeerState so uTP and TCP peers coexist in the same session
- Outbound retransmission buffer with actual payload tracking
- Timer integration for RTO-based retransmission

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

## 8. Magnet links (BEP 9)

Download torrent metadata from peers via the extension protocol. Most users interact with magnet links, not .torrent files.

## 9. Encryption (BEP 6 / MSE)

Message Stream Encryption for obfuscating BitTorrent traffic. Required by some private trackers and useful for avoiding ISP throttling.

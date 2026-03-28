# Future Features

Features to implement eventually, tracked here for reference. Not prioritized for immediate work.

## 0. ~~Blocking Call Removal~~ (DONE)

Seed async pread is implemented via `IORING_OP_READ` with piece cache and batched block sends.

## 1. ~~systemd-notify support~~ (DONE)

Implemented in `src/daemon/systemd.zig`. Sends `READY=1` after API server is listening and `STOPPING=1` on shutdown. Uses standard POSIX `AF_UNIX`/`SOCK_DGRAM` socket (one-time setup, not hot path). No libsystemd dependency. Supports both filesystem and abstract (`@`-prefixed) sockets.

## 2. SHA-NI and hardware-accelerated SHA instructions

Zig std lib SHA-1 is software-only (~1.1 GB/s in release mode). SHA-NI instructions on x86_64 (Intel Goldmont+ 2016, AMD Zen 2017+) can achieve ~3-5 GB/s.

Reference implementation: https://github.com/noloader/SHA-Intrinsics -- shows how to detect and use SHA-1/SHA-256 hardware acceleration via intrinsics on x86 (SHA-NI), ARM (SHA extensions), and POWER8 (SHA).

Steps:
1. Create benchmarks comparing std lib SHA-1 vs SHA-NI implementation
2. Runtime CPU feature detection (`cpuid` for SHA-NI support)
3. Implement SHA-1 and SHA-256 (for BEP 52 / BitTorrent v2) with intrinsics
4. Fallback to std lib on CPUs without SHA-NI

Note: Zig std lib SHA-256 already has SHA-NI acceleration. Only SHA-1 needs custom work.

## 3. uTP support (BEP 29)

uTP (Micro Transport Protocol) is a UDP-based transport used by uTorrent and many other clients. It provides TCP-like reliability with better congestion control for BitTorrent traffic (LEDBAT algorithm). Many peers only support uTP.

Key aspects:
- UDP-based, so uses `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG`
- Implements its own congestion control (LEDBAT -- Less than Best Effort)
- Connection management, retransmission, ordering
- Can coexist with TCP peers on the same session

Reference: libtorrent (arvidn) has a mature uTP implementation in `src/utp_stream.cpp`.

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

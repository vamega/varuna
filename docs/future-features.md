# Future Features

Features to implement eventually, tracked here for reference. Not prioritized for immediate work.

## 0. Blocking Call Removal (from strace audit)

**Seed async pread:** Replace `posix.pread` in `servePieceRequest` (event_loop.zig) with `IORING_OP_READ`. Currently blocks the event loop for each piece block request. Requires async state machine: submit read SQE → on CQE build piece message → submit send SQE. See `progress-reports/2026-03-27-strace-blocking-audit.md` for full audit.

## 1. systemd-notify support (without libsystemd dependency)

Notify systemd when the daemon is ready, stopping, or reloading. Implement by writing to the `$NOTIFY_SOCKET` Unix domain socket directly -- no libsystemd dependency needed.

Reference implementation: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html (C and Python examples at the bottom of the page show the raw socket protocol).

Protocol: send `READY=1\n` to the `AF_UNIX`/`SOCK_DGRAM` socket at the path in `$NOTIFY_SOCKET`. Also supports `STATUS=...`, `STOPPING=1`, `WATCHDOG=1`.

Ideally route through io_uring (`IORING_OP_SENDMSG` on the Unix socket) so it doesn't block the event loop.

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

## 4. SO_BINDTODEVICE support

Restrict the daemon to a specific network interface. Useful for:
- Binding to a VPN interface only (privacy)
- Multi-homed servers where torrent traffic should use a specific NIC
- Preventing traffic from leaking to the wrong interface

Implementation: `setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, "eth0", 4)` before `bind()`. Can be done via io_uring `IORING_OP_SETSOCKOPT` (kernel 6.7+) or conventional `setsockopt` at socket creation.

Config:
```toml
[network]
bind_device = "wg0"  # restrict to this interface
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

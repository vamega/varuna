# Async Socket Creation via IORING_OP_SOCKET

**Date:** 2026-04-15

## What Changed

Moved all hot-path `posix.socket()` calls to `IORING_OP_SOCKET` (kernel 5.19+),
eliminating synchronous socket syscalls from the event loop's per-connection path.

### Converted callsites (4):
1. `event_loop.zig:addPeerForTorrent` — every outbound TCP peer connection
2. `peer_handler.zig:reconnectPeer` — every peer reconnection attempt
3. `tracker_executor.zig:startConnect` — every HTTP tracker announce/scrape
4. `udp_tracker_executor.zig:startUdpRequest` — every UDP tracker request

### Pattern:
Old (synchronous): `posix.socket() → setsockopt → ring.connect()`
New (async): `ring.socket() → CQE: setsockopt → ring.connect()`

Each callsite now submits a SOCKET SQE. A new CQE handler (`handleSocketCreated`)
configures the returned fd (TCP options, SO_BINDTODEVICE, local bind) and chains
the CONNECT SQE.

### Not converted (3 startup-only sockets):
- `main.zig:createListenSocket` — TCP listen (needs bind+listen)
- `rpc/server.zig:initWithDevice` — API server (needs bind+listen)
- `event_loop.zig:startUtpListener` — UDP listener (needs bind)

These stay as `posix.socket()` because `IORING_OP_BIND` and `IORING_OP_LISTEN`
require kernel 6.11+, and the minimum supported kernel is 6.6. They're one-time
startup operations.

## Syscall impact

Startup socket() count: 13 → 3 (the 3 remaining are startup-only bind+listen sockets).

## What Was Learned

- `IORING_OP_SOCKET`: kernel 5.19+ (available on min 6.6)
- `IORING_OP_BIND`: kernel 6.11+ (NOT available on min 6.6 or preferred 6.8)
- `IORING_OP_LISTEN`: kernel 6.11+ (NOT available on min 6.6 or preferred 6.8)
- The Zig std lib `io-uring-syscalls.md` doc previously claimed socket was "done" but
  no `Ring.socket` function existed — all callsites were using `posix.socket()`.
- UDP `connect()` just sets the destination address (no handshake), so it's safe
  to keep synchronous after the async socket creation completes.

## Key Code References

- `src/io/types.zig:23-25` — new OpType values: `peer_socket`, `http_socket`, `udp_socket`
- `src/io/peer_handler.zig:handleSocketCreated` — peer socket CQE handler
- `src/daemon/tracker_executor.zig:handleSocketCreated` — HTTP tracker socket CQE handler
- `src/daemon/udp_tracker_executor.zig:handleSocketCreated` — UDP tracker socket CQE handler
- `docs/io-uring-syscalls.md` — updated coverage table

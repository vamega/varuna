# Testing Infrastructure and Development Progress

**Date:** 2026-04-12

## Testing Infrastructure Completed

### Compile-time safety tests (`zig build test-safety`)
- Parameter size checks: verify `addressEql` takes pointers, not 112-byte Address by value
- Struct initialization safety: verify `UtpSocket.out_buf` initializes `packet_buf` to null
- Size regression tests: UtpSocket < 8KB, Address ≤ 128, OutPacket ≤ 64
- fd leak detection helper (`countOpenFds` via /proc/self/fd)
- Thread count helper (`countThreads` via /proc/self/task)

### SO_BINDTODEVICE tests (`zig build test-bind-device`)
- Bind to "lo" with EPERM skip for unprivileged CI
- Empty device no-op verification
- Oversized device name rejection (> IFNAMSIZ)
- Empty device name rejection
- Non-existent device error handling

### Event loop health tests (`zig build test-event-loop`)
- fd leak detection on init/deinit cycle
- Thread count bounds (hasher + DNS pool only)
- Bounded thread count with hasher threads

### strace policy validator (`scripts/validate_strace.sh`)
- Parses `strace -f -c` summary output
- Fails on forbidden direct I/O syscalls (connect, send, recv, accept)
- Allows documented exceptions (SQLite, logging, one-time setup)

### End-to-end swarm test (`zig build test-swarm`)
- Runs `scripts/demo_swarm.sh` as a build step
- Creates tracker + seeder + downloader, transfers file, verifies integrity
- Currently TCP-only (uTP disabled due to send bridge issues)

### Docker cross-client conformance tests (`test/docker/`)
- Dockerfile.varuna: minimal Ubuntu 24.04 image
- docker-compose.yml: opentracker + qBittorrent + Varuna (seed and download)
- run_conformance.sh: automated test runner with SHA-256 verification
- README.md: setup and usage instructions

### Socket creation wrappers (`src/net/socket.zig`)
- `createTcpSocket()`: creates TCP socket with SO_BINDTODEVICE enforced
- `createUdpSocket()`: creates UDP socket with SO_BINDTODEVICE enforced
- Centralizes socket creation to prevent forgotten bind_device

## Development Progress

### uTP BT send bridge (partial)
- `src/io/protocol.zig`: all send paths now check `peer.transport == .utp` and route through `utpSendData`
- `src/io/peer_policy.zig`: `submitPipelineRequests` routes uTP sends correctly
- **Status:** Compiles and unit tests pass. The demo_swarm still uses TCP-only because the uTP send bridge needs further integration testing (the daemon crashes when uTP is re-enabled, suggesting the utp_handler's send path has additional issues beyond what was patched).

### Items deferred
- Move collectMagnetPeers to TrackerExecutor: complex orchestration, event loop must be active first
- Dynamic outbound buffer for UtpSocket: low priority, heap allocation already eliminates 24MB baseline
- Re-enable uTP in demo_swarm: blocked on uTP send bridge stability
- MSE handshake investigation: vc_not_found/req1_not_found in mixed mode needs deep protocol analysis
- Single-process integration tests: complex, needs in-process seeder↔downloader with real io_uring

## Build Targets Summary

| Target | Purpose |
|--------|---------|
| `zig build test` | Unit tests |
| `zig build test-torrent-session` | Focused session tests |
| `zig build test-safety` | Compile-time and runtime safety |
| `zig build test-bind-device` | SO_BINDTODEVICE tests |
| `zig build test-event-loop` | Event loop health |
| `zig build test-swarm` | End-to-end swarm transfer |
| `zig build soak-test` | Resource leak detection |
| `docker compose` (test/docker/) | Cross-client conformance |

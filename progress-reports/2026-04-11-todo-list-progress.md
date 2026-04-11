# Todo List Progress

**Date:** 2026-04-11

## Completed

### 1. strace verification
strace installed and run against daemon. Confirmed all network I/O routes through `io_uring_enter` (290 calls). No direct `connect/send/recv/sendto/recvfrom/sendmsg/recvmsg`. Only allowed exceptions: SQLite pread/pwrite (background thread), stdout pwritev (logging), socket/bind (one-time setup).

### 4. Heap-allocate UtpSocket on demand
Changed `connections: [4096]UtpSocket` (24 MB inline) to `connections: [512]?*UtpSocket` (4 KB pointers). Sockets heap-allocated on connect, freed on close. Zero-connection baseline: 24 MB → 4 KB.

### 5. Reduce uTP max_connections
Reduced from 4096 to 512. libtorrent defaults to ~200 total connections.

### Also: Stack frame investigation
Investigated why a 128-byte value created a 46MB stack frame. Root cause: Zig debug mode materializes the full UtpSocket (~6KB) for every array index access `self.connections[i]`, and allocates separate stack slots per loop iteration (no reuse). Fixed by using pointer-capture in for loop: `for (self.slot_active, self.connections[0..], 0..) |active, *conn, i|`. Stack frame: 46 MB → 23 MB → **4.5 KB** (10,790x reduction).

## In Progress

### 3. Demo swarm download stall
Investigation found:
- Both daemons crash-free, connect via TCP+MSE and uTP
- Seeder correctly sets `complete_pieces` and sends BITFIELD
- Downloader connects to seeder via uTP (not TCP, since downloader has no TCP listener in download mode)
- The uTP→BT handshake data delivery path (`deliverUtpData`) may have issues — uTP peers don't use MSE, use a plain BT handshake over the uTP byte stream
- The downloader doesn't create a TCP listen socket in download mode (only seeders create listeners via `integrateSeedIntoEventLoop`)
- The seeder's outbound TCP connection to the downloader fails silently (no listener)

The stall appears to be in the uTP data delivery bridge — pre-existing in the uTP handler code, not introduced by the io_uring migration.

## Remaining

### 2. Move collectMagnetPeers to TrackerExecutor
Deferred — requires the event loop to be active before magnet peer collection can happen, needs careful orchestration.

### 6. Dynamic outbound buffer
Deferred — keeping `[128]OutPacket` inline for now. The heap-allocated socket already eliminates the 24MB baseline. Dynamic ArrayList would be a further optimization.

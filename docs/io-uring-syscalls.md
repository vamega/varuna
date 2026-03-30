# System Calls for a Torrent Client vs io_uring

This document tracks which syscalls the `varuna` **daemon** uses, which are routed through io_uring, and which remain conventional. The io_uring policy applies to the daemon only -- `varuna-ctl` and `varuna-tools` are short-lived CLI tools where standard library I/O is acceptable.

## Current Varuna Status

### On io_uring (hot path)

| Syscall | io_uring Op | Where in Varuna | Status |
|---------|------------|-----------------|--------|
| `pread()` | `IORING_OP_READ` | `PieceStore.readPiece` via `Ring.pread_all` | Done |
| `pwrite()` | `IORING_OP_WRITE` | `PieceStore.writePiece` via `Ring.pwrite_all` | Done |
| `fsync()` | `IORING_OP_FSYNC` | `PieceStore.sync` via `Ring.fsync` | Done |
| `send()` | `IORING_OP_SEND` | `peer_wire` via `Ring.send_all` | Done |
| `recv()` | `IORING_OP_RECV` | `peer_wire` via `Ring.recv_exact` | Done |
| `connect()` | `IORING_OP_CONNECT` | `transport.tcpConnect` via `Ring.connect` | Done |
| `accept()` | `IORING_OP_ACCEPT` | `transport.tcpAccept` via `Ring.accept` | Done |
| `socket()` | `IORING_OP_SOCKET` | `transport.tcpConnect` via `Ring.socket` | Done |
| `fdatasync()` | `IORING_OP_FSYNC` + `DATASYNC` | `PieceStore.sync` via `Ring.fdatasync` | Done |
| `fallocate()` | `IORING_OP_FALLOCATE` | `PieceStore.init` via `Ring.fallocate` | Done |

### Remaining conventional I/O (not hot path)

| Syscall | Where | Why conventional | Could move to io_uring? |
|---------|-------|-----------------|------------------------|
| `openat()` | `PieceStore.init` -- file creation | One-time setup | Yes (`IORING_OP_OPENAT`, kernel 5.6) |
| `mkdirat()` | `PieceStore.init` -- directory creation | One-time setup | Yes (`IORING_OP_MKDIRAT`, kernel 5.15) |
| `ftruncate()` | `PieceStore.init` -- pre-allocate file size | One-time setup | Yes (`IORING_OP_FTRUNCATE`, kernel 6.2) |
| `close()` | `PieceStore.deinit`, peer socket cleanup | Cleanup path | Yes (`IORING_OP_CLOSE`, kernel 5.6) |
| `openat+read+close` | `app.zig` -- reading `.torrent` file | Once at startup | Low value |
| ~~`socket()`~~ | ~~`transport.tcpConnect`~~ | ~~Moved to io_uring~~ | Done via `Ring.socket` |
| `socket+bind+listen` | `client.zig` seed mode -- listen socket | Once at startup | Low value |
| HTTP stack | `std.http.Client` in `announce.zig` | Tracker announce | See notes below |
| `pwritev` | stdout logging via `std.Io.Writer` | Infrequent status messages | Low value -- not hot path |
| `openat+read+close` | `app.zig` -- `.torrent` file read | Once at startup | Low value |
| `openat+write+close` | `app.zig` -- `.torrent` file creation | Once per `varuna create` | Low value |
| `uname` | `probe.zig` -- kernel detection | Once at startup | No equivalent |
| HTTP stack (multiple) | `announce.zig` via `std.http.Client` | Initial + re-announce | **Biggest remaining blocker**: DNS + TCP + HTTP blocks main thread. Replace with async HTTP or dedicated tracker thread in event loop cycle. |
| `std.Thread.sleep` | ~~`client.zig` progress loop~~ | ~~2s polling~~ | **Resolved**: replaced with condvar + timedWait |

### Not yet implemented

| Syscall | io_uring Op | Kernel | Potential use in Varuna |
|---------|------------|--------|------------------------|
| `fallocate()` | `IORING_OP_FALLOCATE` | 5.6 | Pre-allocating file space on download start |
| `fdatasync()` | `IORING_OP_FSYNC` + `IORING_FSYNC_DATASYNC` | 5.1 | Flush data without metadata (faster than fsync) |
| `statx()` | `IORING_OP_STATX` | 5.6 | Checking file size/existence for resume |
| `renameat()` | `IORING_OP_RENAMEAT` | 5.11 | Finalizing completed downloads |
| `unlinkat()` | `IORING_OP_UNLINKAT` | 5.11 | Deleting partial downloads |
| `splice()` | `IORING_OP_SPLICE` | 5.7 | Zero-copy between fds |
| `sendmsg()` | `IORING_OP_SENDMSG` | 5.3 | Scatter/gather for DHT UDP |
| `recvmsg()` | `IORING_OP_RECVMSG` | 5.3 | Scatter/gather for DHT UDP |
| `send()` (zero-copy) | `IORING_OP_SEND_ZC` | 6.0 | Zero-copy piece sends to peers |
| `shutdown()` | `IORING_OP_SHUTDOWN` | 5.11 | Clean peer disconnects |
| timeout | `IORING_OP_TIMEOUT` | 5.4 | Choke/unchoke cycles, announce intervals, keep-alives |
| linked timeout | `IORING_OP_LINK_TIMEOUT` | 5.5 | Per-operation deadlines (peer connect timeout) |
| cancel | `IORING_OP_ASYNC_CANCEL` | 5.5 | Cancelling stalled peer ops |
| `setsockopt()` | `IORING_OP_SETSOCKOPT` | 6.7 | Socket buffer sizes, TCP options |
| `getsockopt()` | `IORING_OP_GETSOCKOPT` | 6.7 | Reading socket state |
| `epoll_ctl()` | `IORING_OP_EPOLL_CTL` | 5.6 | Managing fd watch sets (unlikely needed if io_uring is primary) |
| `madvise()` | `IORING_OP_MADVISE` | 5.6 | Hinting huge page usage on piece cache |
| fixed buffers | `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED` | 5.1 | Read/write into pinned huge-page buffers |

## Replaceable with io_uring (full reference)

### File I/O

| Syscall | io_uring Op | Kernel | Used For |
|---------|------------|--------|----------|
| `openat()` | `IORING_OP_OPENAT` | 5.6 | Opening torrent data files |
| `openat2()` | `IORING_OP_OPENAT2` | 5.6 | Opening with extended flags |
| `close()` | `IORING_OP_CLOSE` | 5.6 | Closing file descriptors |
| `read()`/`pread()` | `IORING_OP_READ` | 5.6 | Reading pieces from disk |
| `readv()`/`preadv()` | `IORING_OP_READV` | 5.1 | Scatter reads across buffers |
| (registered buf) | `IORING_OP_READ_FIXED` | 5.1 | Read into pinned huge-page buffers |
| `write()`/`pwrite()` | `IORING_OP_WRITE` | 5.6 | Writing downloaded pieces |
| `writev()`/`pwritev()` | `IORING_OP_WRITEV` | 5.1 | Scatter writes |
| (registered buf) | `IORING_OP_WRITE_FIXED` | 5.1 | Write from pinned huge-page buffers |
| `fsync()` | `IORING_OP_FSYNC` | 5.1 | Flushing pieces to disk |
| `fdatasync()` | `IORING_OP_FSYNC` + flag | 5.1 | Flush data without metadata |
| `fallocate()` | `IORING_OP_FALLOCATE` | 5.6 | Preallocating file space on download start |
| `ftruncate()` | `IORING_OP_FTRUNCATE` | 6.2 | Resizing files |
| `statx()` | `IORING_OP_STATX` | 5.6 | Checking file size/existence |
| `renameat()` | `IORING_OP_RENAMEAT` | 5.11 | Finalizing completed downloads |
| `unlinkat()` | `IORING_OP_UNLINKAT` | 5.11 | Deleting files/partial downloads |
| `mkdirat()` | `IORING_OP_MKDIRAT` | 5.15 | Creating directory structure |
| `madvise()` | `IORING_OP_MADVISE` | 5.6 | Hinting huge page usage on cache |
| `splice()` | `IORING_OP_SPLICE` | 5.7 | Zero-copy between fds |

### Networking

| Syscall | io_uring Op | Kernel | Used For |
|---------|------------|--------|----------|
| `socket()` | `IORING_OP_SOCKET` | 5.19 | Creating peer/tracker/DHT sockets |
| `connect()` | `IORING_OP_CONNECT` | 5.5 | Connecting to peers |
| `accept()` | `IORING_OP_ACCEPT` | 5.5 | Accepting incoming peer connections |
| `send()` | `IORING_OP_SEND` | 5.6 | Sending protocol messages |
| `recv()` | `IORING_OP_RECV` | 5.6 | Receiving protocol messages |
| `sendmsg()` | `IORING_OP_SENDMSG` | 5.3 | Sending with scatter/gather (DHT UDP) |
| `recvmsg()` | `IORING_OP_RECVMSG` | 5.3 | Receiving with scatter/gather |
| (zero-copy) | `IORING_OP_SEND_ZC` | 6.0 | Zero-copy piece sends to peers |
| (zero-copy) | `IORING_OP_SENDMSG_ZC` | 6.0 | Zero-copy sendmsg |
| `shutdown()` | `IORING_OP_SHUTDOWN` | 5.11 | Closing peer connections cleanly |
| `setsockopt()` | `IORING_OP_SETSOCKOPT` | 6.7 | Setting socket buffer sizes, TCP options |
| `getsockopt()` | `IORING_OP_GETSOCKOPT` | 6.7 | Reading socket state |
| `epoll_ctl()` | `IORING_OP_EPOLL_CTL` | 5.6 | Managing fd watch sets |

### Timers / Control

| Syscall | io_uring Op | Kernel | Used For |
|---------|------------|--------|----------|
| `timer_*` / timerfd | `IORING_OP_TIMEOUT` | 5.4 | Choke/unchoke cycles, announce intervals, keep-alives |
| (linked timeout) | `IORING_OP_LINK_TIMEOUT` | 5.5 | Per-operation deadlines (peer connect timeout) |
| `io_cancel()` | `IORING_OP_ASYNC_CANCEL` | 5.5 | Cancelling stalled peer ops |

## No io_uring Equivalent

| Syscall | Used For | Workaround |
|---------|----------|------------|
| `getaddrinfo()` | Resolving tracker hostnames | Threadpool, or c-ares async resolver (see DNS notes below) |
| `bind()` | Binding listen socket, DHT UDP port | Call once at startup, not on hot path |
| `listen()` | Listening for incoming peers | Call once at startup |
| `getpeername()`/`getsockname()` | Getting peer address after accept | Call inline after `IORING_OP_ACCEPT`, not on hot path |
| `mmap()` | Allocating huge-page piece cache | Call at startup during pool setup, not on hot path |
| `mlock()` | Pinning piece cache in RAM | Call once after mmap() |
| `sysctl`/`ioctl` | Network tuning, interface info | Startup only |

## Practical Kernel Target

| Kernel | Capability Unlocked |
|--------|-------------------|
| 5.1 | Fixed buffers, basic file I/O, fsync |
| 5.5 | accept/connect, timeouts |
| 5.6 | Full file + socket op coverage |
| 5.11 | shutdown, rename, unlink |
| 5.19 | Async socket creation |
| 6.0 | `SEND_ZC` -- the zero-copy seeding path |
| 6.2 | ftruncate async |
| 6.7 | Async setsockopt/getsockopt |

Varuna's current minimum kernel is 6.6, which covers everything up to and including `SEND_ZC`. The preferred kernel is 6.8.

## DNS Resolution Notes

`getaddrinfo()` is a blocking call with no io_uring equivalent. Current approach: `std.http.Client` calls it internally for tracker announces. Options for the future:

1. **Threadpool offload**: Run `getaddrinfo()` in a background thread. Simplest approach. Use `io_uring_register_iowq_max_workers` to size the kernel's internal worker pool.

2. **c-ares integration**: c-ares is an async DNS library that gives you fd-based sockets to watch. It doesn't use io_uring directly but can be integrated:
   - c-ares gives you fds via `ares_getsock()`
   - Submit `IORING_OP_POLL_ADD` on those fds via io_uring
   - When the poll CQE fires (fd is readable), call `ares_process_fd()` to let c-ares read the response
   - c-ares fires your callback with the resolved addresses
   - This is a two-step approach: io_uring wakes you when the fd is readable, then c-ares does a normal `recvmsg` internally. You get io_uring as a poller but not true io_uring receive on the DNS socket.

3. **Build option**: Future configurable build option to build with c-ares. For now, threadpool offload is simpler and sufficient.

## SHA Hardware Acceleration Notes

The codebase uses `src/crypto/sha1.zig` for all SHA-1 piece verification. This module supports hardware acceleration on two architectures:

- **x86_64 SHA-NI**: Intel Goldmont+ (2016), AMD Zen (2017+). Uses `sha1rnds4`, `sha1nexte`, `sha1msg1`, `sha1msg2` instructions.
- **AArch64 SHA1 Crypto Extensions**: ARMv8-A with Crypto. Uses `sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0`, `sha1su1` instructions.
- **Software fallback**: Same algorithm as `std.crypto.hash.Sha1`.

**Current benchmarks (ReleaseFast, x86_64, 256KB pieces):**
- Software (std lib): ~1,075 MB/s
- SHA-NI (varuna):    ~2,145 MB/s (2x speedup)

Detection is runtime: CPUID on x86_64, `getauxval(AT_HWCAP)` on AArch64. The result is cached in an atomic global after the first call. A binary compiled with `-Dcpu=baseline` will still use hardware acceleration when run on a capable CPU.

**BEP 52 (BitTorrent v2)**: Uses SHA-256 instead of SHA-1. Zig's `std.crypto.hash.sha2` already has SHA-NI acceleration for SHA-256, so no custom implementation is needed for v2 support.

## SQLite / Resume State Notes

Resume state (tracking which pieces are complete across restarts) is currently done via full piece recheck on startup -- correct but expensive on large torrents.

Future plan: persist resume state in SQLite.

**Important constraint**: SQLite operations are blocking and must NOT run on the io_uring event loop thread. Options:

1. **Dedicated background thread**: SQLite writes happen in a separate thread. The main io_uring loop sends completed piece indices to the SQLite thread via a lock-free queue or channel.

2. **Write-ahead logging (WAL) mode**: Use SQLite in WAL mode for better concurrent read/write performance. Readers (startup recheck) don't block writers (piece completion logging).

3. **Batch writes**: Buffer multiple piece completions and flush to SQLite periodically (e.g., every N pieces or every M seconds) rather than per-piece. This amortizes the syscall and journaling overhead.

4. **Schema**: Minimal schema -- torrent info hash, piece index, completion timestamp. Optionally track per-file byte ranges for partial piece resume.

5. **Fallback**: If SQLite is unavailable, fall back to full piece recheck (current behavior). Resume state is an optimization, not a correctness requirement.

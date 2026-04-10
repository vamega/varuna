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
| `shutdown()` | `IORING_OP_SHUTDOWN` | `Ring.shutdown` -- clean peer disconnects | Done |
| `statx()` | `IORING_OP_STATX` | `Ring.statx` -- async file stat for resume checks | Done |
| `renameat()` | `IORING_OP_RENAMEAT` | `Ring.renameat` -- async file rename for data relocation | Done |
| `unlinkat()` | `IORING_OP_UNLINKAT` | `Ring.unlinkat` -- async file deletion for partial cleanup | Done |
| `send()` (zero-copy) | `IORING_OP_SEND_ZC` | `Ring.send_zc` / `Ring.send_zc_all` -- zero-copy piece sends | Done |
| cancel | `IORING_OP_ASYNC_CANCEL` | `Ring.cancel` -- cancel stalled peer operations | Done |
| timeout | `IORING_OP_TIMEOUT` | `Ring.timeout` -- native io_uring timers | Done |
| linked timeout | `IORING_OP_LINK_TIMEOUT` | `Ring.link_timeout` -- per-operation deadlines | Done |
| fixed buffers | `IORING_OP_READ_FIXED` / `WRITE_FIXED` | `Ring.pread_fixed` / `Ring.pwrite_fixed` with registered buffer pool | Done |
| `sendmsg()` | `IORING_OP_SENDMSG` | uTP handler, DHT handler, UDP tracker executor, API server | Done |
| `recvmsg()` | `IORING_OP_RECVMSG` | uTP handler, DHT handler, UDP tracker executor | Done |
| `read()` (timerfd) | `IORING_OP_READ` | Event loop timerfd for scheduled callbacks | Done |
| `pread()` (recheck) | `IORING_OP_READ` | `AsyncRecheck` piece verification reads | Done |
| `connect()` (metadata) | `IORING_OP_CONNECT` | `AsyncMetadataFetch` BEP 9 peer connections | Done |
| `send()` (metadata) | `IORING_OP_SEND` | `AsyncMetadataFetch` handshake/request sends | Done |
| `recv()` (metadata) | `IORING_OP_RECV` | `AsyncMetadataFetch` handshake/piece receives | Done |

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
| ~~HTTP stack~~ | ~~`std.http.Client` in `announce.zig`~~ | ~~Tracker announce~~ | **Resolved**: blocking tracker functions removed; all tracker I/O through ring-based executors |
| `pwritev` | stdout logging via `std.Io.Writer` | Infrequent status messages | Low value -- not hot path |
| `openat+read+close` | `app.zig` -- `.torrent` file read | Once at startup | Low value |
| `openat+write+close` | `app.zig` -- `.torrent` file creation | Once per `varuna create` | Low value |
| `uname` | `probe.zig` -- kernel detection | Once at startup | No equivalent |
| HTTP stack (multiple) | `announce.zig` via `io/http.zig` | Initial + re-announce | **Resolved**: HTTP I/O goes through io_uring. DNS resolution runs on background threads with TTL-based caching (`io/dns.zig`). |
| ~~`std.Thread.sleep`~~ | ~~`client.zig` progress loop~~ | ~~2s polling~~ | **Resolved**: replaced with condvar + timedWait |
| ~~`std.Thread.sleep`~~ | ~~`torrent_session.zig` announce jitter~~ | ~~Startup delay~~ | **Resolved**: replaced with timerfd on event loop |
| ~~blocking pread~~ | ~~`recheckExistingData` in verify.zig~~ | ~~Piece verification~~ | **Resolved**: `AsyncRecheck` uses io_uring reads + hasher pool |
| ~~blocking TCP~~ | ~~`metadata_fetch.zig` BEP 9~~ | ~~Magnet metadata~~ | **Resolved**: `AsyncMetadataFetch` state machine on event loop |

### Not yet implemented

| Syscall | io_uring Op | Kernel | Potential use in Varuna |
|---------|------------|--------|------------------------|
| `splice()` | `IORING_OP_SPLICE` | 5.7 | Zero-copy between fds |
| ~~`sendmsg()`~~ | ~~`IORING_OP_SENDMSG`~~ | ~~5.3~~ | ~~Scatter/gather for DHT UDP~~ Done: uTP, DHT, UDP tracker, API vectored send |
| ~~`recvmsg()`~~ | ~~`IORING_OP_RECVMSG`~~ | ~~5.3~~ | ~~Scatter/gather for DHT UDP~~ Done: uTP, DHT, UDP tracker |
| `setsockopt()` | `IORING_OP_SETSOCKOPT` | 6.7 | Socket buffer sizes, TCP options |
| `getsockopt()` | `IORING_OP_GETSOCKOPT` | 6.7 | Reading socket state |
| `epoll_ctl()` | `IORING_OP_EPOLL_CTL` | 5.6 | Managing fd watch sets (unlikely needed if io_uring is primary) |
| `madvise()` | `IORING_OP_MADVISE` | 5.6 | Hinting huge page usage on piece cache |

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

`getaddrinfo()` is a blocking call with no io_uring equivalent. `src/io/dns.zig` provides a unified `DnsResolver` interface with **two build-time configurable backends**:

### Backend selection

Build with `-Ddns=threadpool` (default) or `-Ddns=c-ares`:

| Backend | Flag | Library | How it resolves |
|---------|------|---------|-----------------|
| Threadpool | `-Ddns=threadpool` | None (glibc) | `getaddrinfo()` on a background thread, 5-second timeout |
| c-ares | `-Ddns=c-ares` | `libc-ares-dev` | c-ares async DNS with epoll fd monitoring, 5-second timeout |

### Shared behavior (both backends)

1. **Short-circuits numeric IPs** (IPv4 and IPv6): parsed inline with no syscall.
2. **Caches resolved addresses** with a 5-minute TTL and up to 64 entries. LRU eviction on overflow. Thread-safe via mutex.
3. **5-second timeout** on cache miss.

The daemon's `TorrentSession` lazily creates a `DnsResolver` on first tracker operation. The resolver is shared across all announce and scrape requests for that torrent. Since tracker hostnames rarely change, the cache eliminates nearly all DNS lookups after the first announce.

For callers that don't need caching (e.g., one-off UDP tracker connections), `dns.resolveOnce()` provides the same pattern without a cache.

### Threadpool backend (default)

Implementation: `src/io/dns_threadpool.zig`. Spawns a background thread per cache miss to call `getaddrinfo()`. Simple, no extra dependencies. Suitable for typical torrent workloads with a small number of tracker hostnames.

### c-ares backend

Implementation: `src/io/dns_cares.zig`. Uses the c-ares async DNS library. On cache miss, c-ares issues DNS queries on its own UDP/TCP sockets. The resolver uses `epoll_wait()` on c-ares's fds to wait for responses without blocking the io_uring event loop thread.

**When to use c-ares**: high-throughput DHT scenarios with hundreds of concurrent DNS lookups, where thread-per-lookup overhead becomes significant. For typical private tracker usage, the threadpool backend is sufficient.

**Requirements**: `libc-ares-dev` (Debian/Ubuntu) or `c-ares-devel` (RHEL/Fedora).

### Architecture

```
src/io/dns.zig           -- public interface (dispatches based on build_options)
src/io/dns_threadpool.zig -- threadpool backend (getaddrinfo + background thread)
src/io/dns_cares.zig     -- c-ares backend (async DNS + epoll fd monitoring)
```

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

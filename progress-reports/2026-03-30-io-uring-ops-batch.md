# io_uring Operations Batch Enhancement

## What was done

Added 8 new io_uring operation wrappers to `src/io/ring.zig`, with tests for each:

1. **IORING_OP_SHUTDOWN** (`Ring.shutdown`) -- Clean peer disconnects. Handles ENOTCONN gracefully (peer already gone). Wired into `EventLoop.cleanupPeer` for TCP peers (conventional syscall on cleanup path; async wrapper available for hot-path use).

2. **IORING_OP_STATX** (`Ring.statx`) -- Async file stat. Accepts dir_fd, path, flags, mask. Useful for resume file existence checks without blocking the event loop.

3. **IORING_OP_RENAMEAT** (`Ring.renameat`) -- Async file rename. For torrent data relocation (moving completed downloads to a different path).

4. **IORING_OP_UNLINKAT** (`Ring.unlinkat`) -- Async file deletion. For partial download cleanup. Supports AT.REMOVEDIR for directory removal.

5. **IORING_OP_ASYNC_CANCEL** (`Ring.cancel`) -- Cancel stalled operations. Returns bool: true if found/cancelled, false if not found. Handles EALREADY (in-progress) as success.

6. **IORING_OP_TIMEOUT / IORING_OP_LINK_TIMEOUT** (`Ring.timeout`, `Ring.link_timeout`) -- Native io_uring timers. `timeout` submits a standalone timer. `link_timeout` is a building block for per-operation deadlines (used with IOSQE_IO_LINK). The existing `connect_timeout` already uses this pattern.

7. **IORING_OP_SEND_ZC** (`Ring.send_zc`, `Ring.send_zc_all`) -- Zero-copy sends. Correctly handles the two-CQE protocol (operation result + NOTIF for buffer release). `send_zc_all` falls back to regular `send_all` on EINVAL.

8. **Fixed/registered buffers** (`Ring.registerBuffers`, `Ring.claimFixedBuffer`, `Ring.releaseFixedBuffer`, `Ring.pread_fixed`, `Ring.pwrite_fixed`) -- Pre-registered buffer pool for READ_FIXED/WRITE_FIXED. Up to 64 mmap'd buffers. Slot claim/release API for safe concurrent use.

## What was learned

- `send_zc` on Linux produces two CQEs: the operation result and a NOTIF CQE (flagged with IORING_CQE_F_NOTIF) that signals buffer ownership is returned. The first CQE has IORING_CQE_F_MORE set when the NOTIF will follow. If MORE is not set, the kernel fell back to copy and no NOTIF arrives.

- Zig 0.15 has `linux.socketpair` but NOT `posix.socketpair`. For test socket pairs, use the raw linux syscall.

- `linux.SHUT.RDWR` is the constant for full duplex shutdown (value 2), matching `SHUT_RDWR` from POSIX.

- The event loop uses `linux.IoUring` directly (raw stdlib type) with async CQE dispatch, while `Ring` is the synchronous wrapper for blocking callers like `PieceStore`. New ops are in `Ring` for the synchronous path; the event loop already has its own async patterns for timeout/link_timeout.

## Code references

- `src/io/ring.zig` -- all new operations and tests
- `src/io/event_loop.zig:1030-1045` -- TCP shutdown in cleanupPeer
- `docs/io-uring-syscalls.md` -- tracking table updated

## Remaining work

- Wire `send_zc` into the seed path for large piece sends (requires event loop integration with two-CQE handling)
- Wire `statx` into resume DB for file existence checks
- Wire `renameat` into torrent data relocation API endpoint
- Wire `unlinkat` into partial download cleanup
- Wire fixed buffers into PieceStore for piece I/O
- Integrate `cancel` into peer connect timeout handling

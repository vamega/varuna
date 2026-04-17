# c-ares Native io_uring Integration

**Date:** 2026-04-16

## What Changed

Implemented a native io_uring event engine for the c-ares DNS library at
`~/projects/c-ares`. This is a proof-of-concept for replacing varuna's DNS
threadpool backend with a zero-syscall DNS resolver.

### Phase 1: Poll-based engine
- New `ARES_EVSYS_IO_URING = 6` enum value
- `ares_event_iouring.c` (~400 lines) implementing the `ares_event_sys_t` interface
- Uses `IORING_OP_POLL_ADD` for fd readiness monitoring (replaces epoll)
- `eventfd` for wake signal (more efficient than pipe)
- Oneshot poll with automatic rearm after each CQE

### Phase 2: True direct I/O
- Expanded to ~853 lines with dual-ring architecture
- **Poll ring** (64 entries): fd readiness monitoring
- **I/O ring** (16 entries): actual network operations
- Custom `ares_socket_functions_ex` callbacks installed on the channel:
  - `IORING_OP_SOCKET` for socket creation
  - `IORING_OP_CONNECT` for TCP connections
  - `IORING_OP_SENDMSG` for DNS query sends
  - `IORING_OP_RECVMSG` for DNS response receives
  - `IORING_OP_CLOSE` for socket cleanup
- `MSG_DONTWAIT` on RECVMSG/SENDMSG (critical: without it, io_uring RECVMSG
  blocks, breaking c-ares's non-blocking read-again loop)
- Graceful fallback to regular syscalls if SQE allocation fails

### Verification
strace confirmed **zero** direct network syscalls:
```
io_uring_enter     32
io_uring_setup      2
```
No socket, connect, bind, sendto, recvfrom, sendmsg, or recvmsg.

### Files (in ~/projects/c-ares)
- `src/lib/event/ares_event_iouring.c` — io_uring event engine
- `include/ares.h` — ARES_EVSYS_IO_URING enum
- `docs/io_uring_event_engine.md` — design document
- `test/test_iouring.c` — test program
- `CMakeLists.txt` — liburing detection

### Future
Could replace varuna's DNS threadpool backend to eliminate the last
background-thread syscalls (the 75 "violations" from bpftrace that were
all getaddrinfo on DNS threads).

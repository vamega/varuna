# Epoll mmap close cancels pending sends

## What changed and why

- `EpollMmapIO.closeSocket` now completes registered fd operations with `error.OperationCanceled` instead of only clearing backend state. This lets tracked send callbacks release `PendingSend` accounting when a peer fd is closed during teardown (`src/io/epoll_mmap_io.zig:260`, `src/io/epoll_mmap_io.zig:1006`).
- Peer teardown now marks peers as `.disconnecting` and clears `peer.fd` before closing fds when embedded completions may fire inline. That preserves the existing io_uring callback state contract for readiness backends that synthesize cancellation synchronously (`src/io/event_loop.zig:633`, `src/io/event_loop.zig:1787`).
- Added a focused regression proving that closing an epoll-mmap socket with a parked send invokes the send callback with `OperationCanceled` (`tests/epoll_mmap_io_test.zig:183`).

## What was learned

`removePeer` already ghosted tracked sends before fd close, but epoll-mmap fd close removed the epoll registration without delivering the send callback. The ghost entry then survived until `EventLoop.deinit`, where shutdown reported one pending send.

## Remaining issues or follow-up

- The focused `test-transfer -Dio=epoll_mmap` warning is fixed.
- Epoll-posix has similar close-clearing code and may deserve the same cancellation semantics in a separate scoped change.

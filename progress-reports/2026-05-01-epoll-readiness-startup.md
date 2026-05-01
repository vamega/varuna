# Epoll readiness startup paths

## What changed and why

- `EpollPosixIO.closeSocket` now reports `error.OperationCanceled` to registered fd completions, matching the epoll-mmap close-drain behavior and preventing parked sends from surviving teardown (`src/io/epoll_posix_io.zig:349`, `src/io/epoll_posix_io.zig:1009`).
- Both epoll socket backends now complete synchronous `connect` success immediately instead of parking on `EPOLLOUT` after the socket is already connected (`src/io/epoll_posix_io.zig:626`, `src/io/epoll_mmap_io.zig:507`).
- Runtime startup checks now apply the kernel floor and `io_uring` availability probe only when the selected backend is `io_uring`, so epoll builds can run in environments that block ring syscalls (`src/runtime/probe.zig:24`, `src/runtime/probe.zig:29`).
- HTTP, peer, and UDP tracker startup paths now set their state before socket submission. Readiness backends can complete socket creation inline, so post-submit state updates were clobbering callbacks and stalling swarm startup (`src/io/http_executor.zig:509`, `src/io/event_loop.zig:1191`, `src/io/peer_handler.zig:163`, `src/tracker/udp_executor.zig:400`).
- Added close-cancel and close-delimited HTTP regressions for the epoll test suites (`tests/epoll_posix_io_test.zig:247`, `tests/epoll_posix_io_test.zig:296`, `tests/epoll_mmap_io_test.zig:282`).

## What was learned

- The default io_uring demo swarm was healthy while both epoll variants stalled at 0% progress, which narrowed the failure to readiness backend semantics rather than tracker setup.
- Epoll socket creation and connection can complete inline. Callers must establish state before submission, the same way they would before invoking a function that may synchronously call back.
- The Nix `opentracker` whitelist warning is noisy but not causal; default, epoll-posix, and epoll-mmap swarms all complete with that warning present.

## Remaining issues or follow-up

- Deeper lifecycle risks remain in async metadata fetch, async recheck cancellation, and UDP tracker request completion ownership.
- BUGGIFY-heavy tests still emit expected warning output when they inject disk, metadata, tracker, or corrupt-peer failures.

## Verification

- `zig build test-epoll-posix-io` passed.
- `zig build test-epoll-mmap-io` passed.
- `zig build test -Dio=epoll_posix --summary failures` passed.
- `zig build test -Dio=epoll_mmap --summary failures` passed.
- `scripts/demo_swarm.sh` passed with the default backend.
- `IO_BACKEND=epoll_posix scripts/demo_swarm.sh` passed.
- `IO_BACKEND=epoll_mmap scripts/demo_swarm.sh` passed.
- `zig build test --summary failures` passed.
- `git diff --check` passed.

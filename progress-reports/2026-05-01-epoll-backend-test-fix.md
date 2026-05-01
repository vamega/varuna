# Epoll backend test fixes

## What changed
- Routed tests and tools through the selected IO backend with `backend.initWithCapacity(...)`, so `-Dio=epoll_posix` and `-Dio=epoll_mmap` exercise the configured backend instead of hard-coding real io_uring.
- Fixed `EpollPosixIO` by using a stable file-pool wakeup fd context, per-fd read/write/poll readiness lanes, readiness-based socket operations, and nonblocking `tick(0)` polling while active work exists.
- Made `EpollMmapIO` match the epoll_posix socket readiness behavior and queue mmap file completions for delivery from `tick`.
- Canceled pending listener accepts during event-loop teardown without closing caller-owned listener fds, and made canceled accepts disarm cleanly.
- Cleaned up pending sends on submit failure and fixed RPC stress-test fixture pointer lifetimes.

## What was learned
- `epoll` keeps one user-data value per registered fd, so using it as a single completion pointer loses independent send/recv/poll state on the same socket.
- Inline mmap file completions violate callers that update in-flight counters after submission; file results need the same tick-delivery semantics as async backends.
- Closing a caller-owned listen fd while accept is still registered can leave the epoll backend active with no future event.

## Remaining issues
- Transfer tests still emit a shutdown warning about one pending send in some paths. The suites no longer hang and pass, but shutdown send-drain cleanup could be tightened separately.
- BUGGIFY tests remain intentionally noisy when injected failures are exercised.

## Verification
- `zig build test -Dio=epoll_mmap` passed.
- `zig build test -Dio=epoll_posix` passed.
- `zig build test` passed.
- Focused checks passed: `test-epoll-mmap-io`, `test-transfer -Dio=epoll_mmap`, `test-recheck -Dio=epoll_mmap`, and `test-seed-serve-after-free -Dio=epoll_mmap`.
- `git diff --check` passed.

## Key references
- `src/io/backend.zig:138` selected-backend capacity initialization.
- `src/io/epoll_posix_io.zig:226` stable wakeup context; `src/io/epoll_posix_io.zig:364` tick semantics; `src/io/epoll_posix_io.zig:495` fd readiness dispatch; `src/io/epoll_posix_io.zig:915` per-fd registration.
- `src/io/epoll_mmap_io.zig:193` queued mmap completions; `src/io/epoll_mmap_io.zig:273` tick delivery; `src/io/epoll_mmap_io.zig:401` fd readiness dispatch; `src/io/epoll_mmap_io.zig:919` per-fd registration.
- `src/io/event_loop.zig:628` accept cancellation during teardown.
- `src/io/peer_handler.zig:45` canceled accepts disarm.
- `src/io/protocol.zig:525` pending-send cleanup on submit failure.
- `tests/rpc_server_stress_test.zig:244` heap-stable RPC fixture.

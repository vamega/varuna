# Peer Socket Setup IO-Contract Cleanup

## What Changed

- Extended `AcceptOp` with optional caller-owned address storage. The peer listener passes that storage, so `peer_handler` receives the accepted remote address from the accept result instead of calling `getpeername`.
- Updated RealIO to use single-shot accept plus callback rearm when accept address storage is supplied. Native multishot accept still remains available for callers that do not need per-CQE address storage.
- Replaced direct peer-path `configurePeerSocket` / `applyBindConfig` calls with ordered IO-contract setup:
  - peer TCP tuning: `setsockopt(TCP_NODELAY)`, `setsockopt(SO_RCVBUF)`, `setsockopt(SO_SNDBUF)`
  - outbound peer bind device: `setsockopt(SO_BINDTODEVICE)`
  - outbound peer bind address: `bind`
- Rewired metadata-fetch sockets to use the same IO-contract `setsockopt` tuning before connect.
- Removed the now-unused blocking peer/bind socket convenience helpers from `src/net/socket.zig`; the remaining `applyBindDevice` helper is only for c-ares socket callbacks and startup port probing.
- Added a focused `zig build test-sim-mse-handshake` target and fixed the SimIO MSE peer harness to feed short recv completions directly into the state-machine-owned buffer, matching real socket behavior.
- Fixed epoll backend `tick(1)` semantics so a stale eventfd wake cannot satisfy the wait before a user callback fires. Readiness callbacks now count toward `wait_at_least` as well as timer and worker-pool completions.
- Updated the keepalive policy test to use a real AF_UNIX socketpair instead of `/dev/null`, which correctly fails socket sends with `ENOTSOCK` after the RealIO errno mapping cleanup.

## What Was Learned

- The IO contract already exposed `Accepted.addr`; RealIO was the remaining backend that intentionally left it empty for the peer path.
- Single-shot peer accept is the safer shape when a caller needs the remote address because one multishot accept SQE cannot provide unique stable address storage for several queued CQEs.
- Reusing `Peer.connect_completion` for socket setup works because outbound socket setup and connect are still a strict one-in-flight sequence; inbound setup uses the same completion but is tracked with the existing disconnecting-completion accounting.
- The MSE simultaneous-handshake failure was a harness bug: a 59-byte crypto request is a valid short recv, but the test driver was waiting for a 64-byte scan buffer before calling `feedRecv`.
- BlockingOpPool wakeups are level-like at the eventfd but edge-like at the completed queue. A previous worker completion can leave a readable wake fd after the result has already been drained, so `tick(wait_at_least > 0)` must loop until callbacks actually fire.

## Remaining Issues

- RPC accept still uses multishot accept because it does not need remote address storage for peer identity.
- `main.zig` startup port probing remains synchronous and pre-event-loop by design.
- c-ares still applies `SO_BINDTODEVICE` through its socket callback on the DNS worker path, outside the event loop.
- Mmap backend read/write page faults remain the documented explicit blocking caveat.

## References

- `src/io/io_interface.zig:326`
- `src/io/real_io.zig:859`
- `src/io/event_loop.zig:274`
- `src/io/peer_handler.zig:58`
- `src/io/peer_handler.zig:150`
- `src/io/metadata_handler.zig:232`
- `src/io/epoll_posix_io.zig:422`
- `src/io/epoll_mmap_io.zig:375`
- `src/io/peer_policy.zig:2647`
- `tests/sim_mse_handshake_test.zig:139`
- `build.zig:420`
- `src/io/ring.zig:128`
- `docs/io-uring-syscalls.md:134`

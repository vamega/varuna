# 2026-03-31: API `accept_multishot` and inline request buffers

## What was done and why

- Added real socket-level API workloads to `varuna-perf` so the RPC server can be measured under short request bursts and upload-sized request bursts without needing an external WebUI client.
- Switched the RPC listener to `accept_multishot` and removed the per-client eager `8 KiB` heap receive allocation by using inline request storage for the common case.
- Kept the existing single-shot `recv` path for request bodies after testing a `recv_multishot` + provided-buffer prototype and finding that its teardown costs erased the latency win on these workloads.

## What was learned

- `accept_multishot` is a low-risk win on the RPC side because it reduces accept re-submission without forcing a new lifetime model on client sockets.
- The bigger allocation win on the request path came from ownership, not from newer `io_uring` opcodes: removing the eager heap receive buffer was more valuable than changing the receive opcode.
- API `recv_multishot` on a short-lived connection is not automatically better. In this codebase it needed extra shutdown/cancel bookkeeping to avoid leaving the connection open, and that extra work offset the expected latency gain.

## Measured results

ReleaseFast on the local loopback harness:

- `api_get_burst --iterations=4000 --clients=8`
  Before: `8000` allocs, `33.28 MB` transient bytes, `219241483 ns` and `221335441 ns`
  After: `4000` allocs, `512 KB` transient bytes, `219065928 ns` and `221787442 ns`
- `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`
  Before: `3000` allocs, `73.97 MB` transient bytes, `129940486 ns` and `129132222 ns`
  After: `2000` allocs, `65.78 MB` transient bytes, `126192247 ns` and `126194258 ns`

Interpretation:

- Short-request latency stayed effectively flat while allocator churn was cut sharply.
- Upload-sized requests improved by about `2.6%` on wall time while also reducing allocations.

## Remaining issues / follow-up

- The peer listener still uses one accept SQE per inbound connection and should get its own benchmark before changing it to `accept_multishot`.
- uTP `recvmsg_multishot` and seed-path `send_zc` remain unimplemented in this pass because they need more invasive lifetime handling and a clearer benchmark surface.
- The temporary `EventLoop.TorrentId` compile break in this branch was fixed by normalizing a few call sites to `u32` so the benchmark work could build cleanly.

## Code references

- API server listener + inline request buffer: `src/rpc/server.zig:15`
- API burst workloads and CLI knobs: `src/perf/workloads.zig:27`, `src/perf/main.zig:20`
- Supporting build-fix call sites for `TorrentId`: `src/daemon/torrent_session.zig:193`, `src/daemon/session_manager.zig:1518`, `src/io/protocol.zig:444`

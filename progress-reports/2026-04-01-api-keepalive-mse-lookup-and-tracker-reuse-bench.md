## What Changed

- The RPC server now keeps HTTP/1.1 connections alive across sequential requests and retains any buffered leftover bytes between requests instead of forcing one request per socket.
- Inbound MSE responder setup now uses a shared `req2 -> info_hash` lookup table owned by the event loop instead of allocating and copying every active torrent hash into each peer handshake.
- The perf harness now has explicit workloads for sequential API polling, MSE responder preparation at large torrent counts, and tracker HTTP reuse potential.

## Why

- The sequential API workload was spending too much time in repeated accept/connect/close churn for WebUI-style polling.
- The MSE responder path was O(active torrents) in both allocation and CPU on every inbound encrypted connection, which is the wrong shape for a daemon expected to keep many idle torrents active.
- Tracker connection reuse was worth benchmarking separately before attempting a broader production pool design.

## What Was Learned

- Server-side API keep-alive is a large measured win here. `api_get_seq --iterations=4000 --clients=8` moved from `241075138 ns` to `95649970 ns` and `87088833 ns`.
- The shared MSE lookup is an outsized scale-path win. `mse_responder_prep --iterations=2000 --torrents=20000` moved from `1019382516 ns`, `2001` allocs, and `800400000` allocated bytes to `52077 ns` / `35677 ns` with only setup-time map allocation.
- Tracker HTTP reuse has strong microbenchmark potential. The benchmark-only loopback workload moved from `730731535 ns` / `704347260 ns` fresh to `282904495 ns` / `272008017 ns` reused, but that is not yet wired into the daemon’s real tracker lifecycle.

## Remaining Work

- The API keep-alive path still allocates one header buffer per response. If WebUI polling remains hot, header reuse is the next low-risk step.
- Tracker reuse still needs a production ownership model, likely a shared tracker executor or pool rather than a per-session cache.
- The shared event loop still has other periodic full-scan paths for large torrent counts; the MSE fix only removed one of the more obvious O(torrents) setup costs.

## Code References

- API keep-alive request framing and response reuse: `src/rpc/server.zig`
- Shared MSE lookup helpers: `src/crypto/mse.zig`
- Event loop MSE lookup ownership: `src/io/event_loop.zig`
- Inbound responder initialization: `src/io/peer_handler.zig`
- Benchmark workloads: `src/perf/workloads.zig`

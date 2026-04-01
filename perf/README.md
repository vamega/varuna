# Performance Tooling

Varuna is expected to move toward aggressive `io_uring` usage over time. This directory holds the profiling and syscall-inspection playbook used to measure what the binary actually does today.

Generated artifacts should go under `perf/output/`.

## Prerequisites

These tools are external Linux packages, not Zig dependencies. The helper steps in `build.zig` expect the following binaries to be present on the host:

- `strace`
- `perf`
- `bpftrace`
- `heaptrack`
- `valgrind` / `cachegrind`
- `pahole`

On many distributions this means packages similar to `strace`, `linux-perf` or `perf`, and `bpftrace`.
On Ubuntu and WSL, `/usr/bin/perf` may be a wrapper script that refuses to run unless an exact kernel-matched backend exists. The build helpers in `build.zig` detect and prefer a real backend binary from `/usr/lib/linux-tools.../perf` when one is installed.

## Goals

- Confirm which syscalls are still used directly instead of through `io_uring`.
- Find CPU hotspots and call stacks before optimizing blindly.
- Keep a repeatable workflow for comparing changes across iterations.

## Build-Step Helpers

These commands build `varuna` first and then run it under the selected tool. Pass normal `varuna` CLI arguments after `--`.

- `zig build trace-syscalls -- banner`
  Writes a full syscall trace to `perf/output/strace.log`.
- `zig build perf-stat -- banner`
  Writes `perf stat` counters to `perf/output/perf-stat.txt`.
- `zig build perf-record -- banner`
  Writes sampled profiling data to `perf/output/perf.data`.
- `zig build perf-workload -- request_batch --iterations=100000`
  Runs the synthetic workload harness (`zig-out/bin/varuna-perf`) for targeted allocation and cache baselines.

## Synthetic Workloads

Use `varuna-perf` when you need deterministic allocator and cache comparisons without a real swarm or API client.

- `zig build perf-workload -- list`
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_scan --iterations=20000`
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_scan --iterations=20000 --peers=4096 --scale=8`
- `zig build -Doptimize=ReleaseFast perf-workload -- peer_accept_burst --iterations=4000 --clients=1`
- `zig build -Doptimize=ReleaseFast perf-workload -- request_batch --iterations=100000`
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_batch --iterations=5000`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_get_burst --iterations=4000 --clients=8`
- `zig build -Doptimize=ReleaseFast perf-workload -- api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536`
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_delta --iterations=200 --torrents=64`

Current scenarios:

- `peer_scan`
- `peer_accept_burst`
- `request_batch`
- `seed_batch`
- `http_response`
- `api_get_burst`
- `api_upload_burst`
- `extension_decode`
- `ut_metadata_decode`
- `session_load`
- `sync_delta`

Scenario-specific notes:

- `peer_scan`: `--scale` controls active-slot density. `--scale=1` keeps the table dense; larger values keep fewer slots active and are more representative when you want to measure scan cost instead of connection-state churn.
- `peer_accept_burst`: drives the real shared `EventLoop` listener with inbound loopback TCP connects that immediately disconnect. `--clients` controls concurrent connector threads. Very high iteration counts may hit loopback ephemeral-port limits on some hosts.
- `http_response`: models the API response assembly path, including header formatting and body ownership.
- `api_get_burst`: drives the real RPC server over loopback with one short request per connection. `--clients` controls concurrent client threads.
- `api_upload_burst`: drives the real RPC server with upload-sized POST bodies. `--clients` controls concurrent client threads and `--body-bytes` controls request size.
- `session_load`: measures immutable torrent-session metadata setup and teardown.

High-count active-torrent validation currently lives in unit tests rather than `varuna-perf`:

- `zig test src/io/event_loop.zig --test-filter "high torrent counts"`
- `zig build test`

That regression adds `20,000` torrent contexts to the shared EventLoop, validates info-hash lookup, removes one slot, and confirms that the freed slot is reused.

## Direct Tool Usage

Fast syscall summary:

```bash
strace -f -yy -c ./zig-out/bin/varuna banner
```

Full syscall trace:

```bash
strace -f -yy -s 256 -o perf/output/strace.log ./zig-out/bin/varuna banner
```

CPU counters:

```bash
perf stat -d --output perf/output/perf-stat.txt ./zig-out/bin/varuna banner
```

If `/usr/bin/perf` prints `perf not found for kernel ...`, run the real backend directly instead:

```bash
/usr/lib/linux-tools-*/perf stat -d --output perf/output/perf-stat.txt ./zig-out/bin/varuna banner
```

When `perf` is unavailable on WSL because the matching kernel tools package is missing, use `cachegrind` as the cache-miss fallback:

```bash
zig build -Doptimize=ReleaseFast -Dcpu=baseline install
valgrind --tool=cachegrind --cache-sim=yes --branch-sim=yes ./zig-out/bin/varuna-perf request_batch --iterations=5000
```

Use `heaptrack` for stack-attributed allocation traces:

```bash
heaptrack ./zig-out/bin/varuna-perf sync_delta --iterations=50 --torrents=64
heaptrack_print heaptrack.varuna-perf.<pid>.zst
```

Use `pahole` to confirm struct size and field placement:

```bash
pahole ./zig-out/bin/varuna
```

Sampled profile:

```bash
perf record -o perf/output/perf.data --call-graph dwarf ./zig-out/bin/varuna banner
perf report -i perf/output/perf.data
```

And likewise for direct backend invocation:

```bash
/usr/lib/linux-tools-*/perf record -o perf/output/perf.data --call-graph dwarf ./zig-out/bin/varuna banner
/usr/lib/linux-tools-*/perf report -i perf/output/perf.data
```

## eBPF / bpftrace Strategy

Use `bpftrace` when you need targeted kernel-level visibility rather than a full `strace` log.
This generally requires running as root.

Count all syscall entry tracepoints for the running process:

```bash
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_* /comm == "varuna"/ { @[probe] = count(); }'
```

Check whether `io_uring` entry is happening at all:

```bash
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_io_uring_enter /comm == "varuna"/ { @io_uring_enter = count(); }'
```

Look for fallback blocking I/O syscalls:

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_read /comm == "varuna"/ { @read = count(); }
tracepoint:syscalls:sys_enter_write /comm == "varuna"/ { @write = count(); }
tracepoint:syscalls:sys_enter_recvfrom /comm == "varuna"/ { @recvfrom = count(); }
tracepoint:syscalls:sys_enter_sendto /comm == "varuna"/ { @sendto = count(); }
'
```

## Benchmark Baselines (ReleaseFast, 2026-03-25)

Host: WSL2, kernel 6.6.87.2, x86_64

| Benchmark | Per-iteration | Throughput | Notes |
|-----------|--------------|------------|-------|
| kernel_parser | <1ns | N/A | Compiler optimizes away in release |
| bencode_parse | 79us | 32 MB/s | 200-entry dictionary |
| sha1_256kb | 228us | 1,096 MB/s | Software SHA-1, LLVM auto-vectorized |
| metainfo_parse | 36us | 37 MB/s | Full parse including info_hash |

SHA-1 at 1.1 GB/s means piece verification is not a bottleneck for typical network speeds (<100 MB/s). Hardware SHA-NI would add ~2x but is not urgent.

## Memory Optimization Snapshot (ReleaseFast, 2026-03-31)

Synthetic workload deltas from the first allocation-reduction pass:

| Scenario | Before | After |
|----------|--------|-------|
| `request_batch` | 100,000 allocs, 8.63e8 ns | 0 allocs, 1.20e6 ns |
| `seed_batch` | 45,001 allocs, 1.31 GB transient bytes, 5.10e8 ns | 5,001 allocs, 656 MB transient bytes, 2.27e8 ns |
| `extension_decode` | 200,003 allocs, 1.16e9 ns | 3 allocs (setup only), 1.99e6 ns |
| `ut_metadata_decode` | 50,004 allocs, 4.18e8 ns | 4 allocs (setup only), 1.51e6 ns |
| `sync_delta` | 46,946 allocs, 3.63e7 transient bytes, 1.38e8 ns | 32,491 allocs, 3.61e7 transient bytes, 1.77e8 ns |

Cachegrind deltas on the baseline-CPU build:

- `request_batch`: D1 misses fell from `22,472` to `4,076`, LLd misses from `21,586` to `3,406`.
- `seed_batch`: D1 misses fell from `2,066,789` to `1,240,358`, LLd misses from `825,732` to `415,460`.
- `sync_delta`: D1 misses fell from `127,624` to `80,271`, LLd misses from `73,839` to `41,528`.

## Second Memory Pass Snapshot (ReleaseFast, 2026-03-31)

Synthetic workload deltas from the second allocation pass:

| Scenario | Before | After |
|----------|--------|-------|
| `http_response` | 10,001 allocs, 48.6 MB transient bytes, 9.93e7 ns | 5,001 allocs, 648 KB transient bytes, 4.63e7 ns |
| `session_load` | 14,004 allocs, 5.05e7 ns | 2,004 allocs, 1.33e7 ns |

Interpretation:

- `http_response` improved because the server now keeps handler-owned bodies in place and only allocates a header buffer before issuing `sendmsg`.
- `session_load` improved because immutable session metadata now shares one arena-backed lifetime instead of many independent frees.

## API Listener Snapshot (ReleaseFast, 2026-03-31)

Measured with the real loopback RPC server workloads:

| Scenario | Before | After |
|----------|--------|-------|
| `api_get_burst --iterations=4000 --clients=8` | 8,000 allocs, 33.28 MB transient bytes, ~2.20e8 ns | 0 allocs, 0 transient bytes, `2.13e8 ns` to `2.31e8 ns` |
| `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536` | 3,000 allocs, 73.97 MB transient bytes, ~1.30e8 ns | 8 allocs, 525 KB retained bytes, `1.24e8 ns` |

Interpretation:

- The measured wins that held up were `accept_multishot`, inline per-client request storage, inline response headers, and bounded per-slot retention of grown upload buffers.
- The burst workloads now send `Connection: close` explicitly so they still measure one request per connection after the server began honoring HTTP/1.1 keep-alive by default.
- A prototype API `recv_multishot` + provided-buffer path was tested and rejected in this pass because teardown overhead erased the latency gain on these workloads.

## Peer Listener Snapshot (ReleaseFast, 2026-04-01)

Measured with the real `EventLoop` inbound listener workload:

| Scenario | Before | After |
|----------|--------|-------|
| `peer_accept_burst --iterations=4000 --clients=1` | `727995472 ns`, `739372927 ns` | `699668951 ns`, `715792574 ns`, `657787147 ns` |
| `peer_accept_burst --iterations=4000 --clients=8` | `150735516 ns`, `158715184 ns` | `151998395 ns`, `164377673 ns` |

Interpretation:

- `accept_multishot` produced a modest but repeatable improvement for the low-concurrency inbound case on this host, roughly `5.8%` against the direct one-shot A/B baseline.
- The more concurrent 8-thread burst was effectively flat/noisy, so do not treat this change as a broad listener throughput breakthrough by itself.

## API Keep-Alive Snapshot (ReleaseFast, 2026-04-01)

Measured with the sequential polling workload against the real loopback RPC server:

| Scenario | Before | After |
|----------|--------|-------|
| `api_get_seq --iterations=4000 --clients=8` | `241075138 ns` | `95649970 ns`, `87088833 ns` |

Interpretation:

- Server-side HTTP/1.1 keep-alive is a real win for WebUI-style polling on this host, roughly `2.5x` to `2.8x` faster on the measured sequential request shape.
- Response-header allocation is now eliminated on the steady-state path, so repeat runs are allocation-free and measured `73276685 ns` and `79175258 ns` on this host.

## API Header / Upload Buffer Reuse Snapshot (ReleaseFast, 2026-04-01)

Measured after switching the server to inline response headers with heap fallback and retaining grown upload receive buffers per slot up to `256 KiB`:

| Scenario | Before | After |
|----------|--------|-------|
| `http_response --iterations=5000` | `5,001` allocs, `648 KB` transient bytes, `4.63e7 ns` | `1` alloc, `8 KB` transient bytes, `1.80e6 ns`, repeat `1.77e6 ns` |
| `api_get_seq --iterations=4000 --clients=8` | `95649970 ns`, `87088833 ns` | `73276685 ns`, `79175258 ns` |
| `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536` | `2,000` allocs, `65.78 MB` transient bytes, `~1.26e8 ns` | `8` allocs, `525 KB` retained bytes, `123901066 ns` |

Interpretation:

- Inline response headers remove the last steady-state allocation from ordinary API GET responses and make the isolated response assembly benchmark dramatically cheaper.
- Bounded per-slot receive-buffer retention is a good fit for repeated upload-sized requests: it turns per-request heap growth into one retained buffer per active API slot instead of one allocate/free pair per connection.
- This deliberately keeps the retention policy simple and bounded. Uploads larger than the retained cap still allocate on demand, which is the next thing to revisit only if real API traces justify it.

## MSE Responder Snapshot (ReleaseFast, 2026-04-01)

Measured with the synthetic inbound MSE setup workload at `20,000` active torrents:

| Scenario | Before | After |
|----------|--------|-------|
| `mse_responder_prep --iterations=2000 --torrents=20000` | `1.019e9 ns`, `2001` allocs, `800.4 MB` allocated | `52077 ns`, `14` allocs, `3.09 MB` allocated |

Repeat after:

- `35677 ns`

Interpretation:

- Replacing the per-connection copied hash list plus linear `hashReq2` recomputation with a shared lookup table is a very large scale-path win.
- This specifically targets the “many active but mostly idle torrents” case, where inbound peer arrivals should not pay O(torrents) setup cost.

## Tracker HTTP Reuse Potential (ReleaseFast, 2026-04-01)

Measured against a tracker-like loopback HTTP server:

| Scenario | Result |
|----------|--------|
| `tracker_http_fresh --iterations=2000` | `730731535 ns`, `704347260 ns` |
| `tracker_http_reuse_potential --iterations=2000` | `282904495 ns`, `272008017 ns` |

Interpretation:

- Reusing a single HTTP connection for repeated tracker-style GETs is about `2.5x` faster in this microbenchmark and eliminates the per-request allocator churn entirely.
- This is still a transport-level lower bound rather than the full production path. The daemon now uses a shared tracker executor with a persistent client, but the executor benchmark below is the honest end-to-end number to use for production comparisons.

## Tracker Announce Executor Snapshot (ReleaseFast, 2026-04-01)

Measured against the real tracker announce path, including request URL building and bencode response parsing:

| Scenario | Result |
|----------|--------|
| `tracker_announce_fresh --iterations=2000` | `849301098 ns`, `879521023 ns` |
| `tracker_announce_executor --iterations=2000` | `427559358 ns`, `449506041 ns` |

Interpretation:

- The production daemon path now has a measured win, not just a transport microbenchmark. Sharing tracker I/O and reusing the executor-owned HTTP connection cuts loopback announce time by roughly `1.9x` to `2.0x` on this host.
- The executor-backed path keeps a small amount of live memory at the end of the workload because the persistent client still owns its reusable tracker connection and host metadata.
- This pass still does not run tracker jobs on the shared peer `EventLoop` ring. The current HTTP helper is synchronous, so moving tracker jobs onto that ring would require a dedicated async state machine rather than this executor model.

## Sparse Registry Snapshot (ReleaseFast, 2026-04-01)

Synthetic workload deltas from the active-registry and peer-bookkeeping pass:

| Scenario | Before | After |
|----------|--------|-------|
| `tick_sparse_torrents` | 2.80e9 ns | 1.09e7 ns |
| `peer_churn` | 1.13e9 ns | 3.81e6 ns |
| `sync_delta` | 4,229,117 allocs, 3.26e10 ns | 4,228,317 allocs, 3.21e10 ns |

Interpretation:

- `tick_sparse_torrents` improved because the shared loop now walks dense torrent/peer membership lists instead of cross-product scans over all torrents and peers.
- `peer_churn` improved because peer-list membership checks now use per-peer indices instead of linear duplicate scans.
- `sync_delta` only moved modestly; the cached categories/tags JSON removes some churn, but the poll path is still dominated by torrent snapshot materialization.

## Live `/sync` Stats Snapshot (ReleaseFast, 2026-04-01)

Measured with a shared-loop `SessionManager` workload that stresses `getAllStats()` directly:

| Scenario | Before | After |
|----------|--------|-------|
| `sync_stats_live --iterations=1 --torrents=10000 --peers=1000 --scale=20` | `19509532 ns` | `4886050 ns`, repeat `4046868 ns` |
| `sync_delta --iterations=200 --torrents=10000` | `3.26e10 ns` | `3.19e10 ns` |

Interpretation:

- The live stats path was still paying to rescan torrent peer byte counters even after the sparse registry pass. Caching cumulative upload/download byte totals in `TorrentContext` removes that hot traversal directly.
- The isolated stats workload shows the real win clearly, roughly `3.5x` to `4x` on this host. The full `/sync` delta path improves more modestly because it still spends most of its time allocating snapshots and serializing JSON.
- This pass is intentionally narrower than a full torrent hot-summary registry. It addresses the measured hot spot first and leaves a denser registry for a follow-up if `/sync` still dominates.

## Seed / uTP Experiment Surfaces (ReleaseFast, 2026-04-01)

New benchmark-only workloads added in this pass:

| Scenario | Result |
|----------|--------|
| `seed_plaintext_burst --iterations=500 --scale=8` | before: `30384358 ns`, `27940324 ns`, `28669060 ns`; after: `10659949 ns`, `12832968 ns`; alloc calls `501`, `276 KB` transient bytes |
| `seed_send_copy_burst --iterations=200 --scale=8` | `59303132 ns`, `54058775 ns`; `200` allocs, `26.2 MB` transient bytes |
| `seed_sendmsg_burst --iterations=200 --scale=8` | `45529205 ns`, `39205524 ns`; `400` allocs, `72 KB` transient bytes |
| `seed_splice_burst --iterations=200 --scale=8` | `180185989 ns`; `0` allocs |
| `utp_outbound_burst --iterations=200 --scale=64` | `81276385 ns`, `110159182 ns`, `90773293 ns` |

Interpretation:

- `seed_plaintext_burst` is now the production plaintext upload path. Refcounted piece buffers plus tracked vectored `sendmsg` improved wall-clock time by about `2.2x` to `2.8x` on this host and cut transient bytes from `65.6 MB` down to `276 KB`.
- `seed_sendmsg_burst` is the clearest syscall win so far for plaintext seeding. On the same loopback TCP shape as the contiguous-copy benchmark, vectored header + payload send improved wall-clock time by about `23%` to `33%` and cut transient bytes from `26.2 MB` to `72 KB`.
- `seed_splice_burst` shows why `sendfile` / `splice` are a poor fit for the current BitTorrent upload path. The protocol still needs a per-block header send, `splice(2)` still requires a pipe on one side, and the measured prototype was much slower than either copy or vectored `sendmsg`.
- `READ_FIXED` / `WRITE_FIXED` are not the first lever for this path. They can help if piece-read buffers are pre-registered, but they do not solve message framing or the need to keep piece pages alive until the socket-send CQE arrives.
- Packing the tracked vectored send state into its backing allocation removed the extra allocator traffic from the first `sendmsg` landing. The next optional lever here is pooling those packed blocks or trying `sendmsg_zc` if real swarm traces still show plaintext seeding as a hotspot.
- The huge-page piece cache is now reusable rather than bump-only. Freed pooled piece buffers return to the mapped cache and adjacent free ranges merge back together instead of exhausting the cache after one pass.
- `utp_outbound_burst` is a real loopback UDP path benchmark. A first queue-cleanup prototype removed allocator churn but did not produce a stable wall-clock win, so it was not kept in production.

## Interpretation Notes

- A minimal-client build that still shows `read`, `write`, `connect`, `recvfrom`, or `sendto` is expected until the networking and storage paths are moved to `io_uring`.
- Treat unexpected `openat`, `statx`, `futex`, or timer-heavy behavior as prompts to inspect startup, buffering, and lock behavior.
- Record which command was run and what changed in [DECISIONS.md](../DECISIONS.md) when a profiling pass leads to a design choice.

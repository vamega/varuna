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
On WSL kernels, `perf` may additionally require a kernel-matched `linux-tools-<kernel>` package before `perf stat` or `perf record` will run successfully.

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
- `zig build -Doptimize=ReleaseFast perf-workload -- request_batch --iterations=100000`
- `zig build -Doptimize=ReleaseFast perf-workload -- seed_batch --iterations=5000`
- `zig build -Doptimize=ReleaseFast perf-workload -- sync_delta --iterations=200 --torrents=64`

Current scenarios:

- `peer_scan`
- `request_batch`
- `seed_batch`
- `http_response`
- `extension_decode`
- `ut_metadata_decode`
- `session_load`
- `sync_delta`

Scenario-specific notes:

- `peer_scan`: `--scale` controls active-slot density. `--scale=1` keeps the table dense; larger values keep fewer slots active and are more representative when you want to measure scan cost instead of connection-state churn.
- `http_response`: models the API response assembly path, including header formatting and body ownership.
- `session_load`: measures immutable torrent-session metadata setup and teardown.

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

## Interpretation Notes

- A minimal-client build that still shows `read`, `write`, `connect`, `recvfrom`, or `sendto` is expected until the networking and storage paths are moved to `io_uring`.
- Treat unexpected `openat`, `statx`, `futex`, or timer-heavy behavior as prompts to inspect startup, buffering, and lock behavior.
- Record which command was run and what changed in [DECISIONS.md](../DECISIONS.md) when a profiling pass leads to a design choice.
